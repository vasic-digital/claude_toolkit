// opencode-jev-plugin.js — OpenCode plugin gating tool execution through a
// Jev systemone decision endpoint (design: toolkit-jev-design §2.7).
//
// HONEST UPSTREAM CAVEATS (do not remove):
//   - `tool.execute.before` does NOT intercept MCP tool calls (opencode
//     upstream bug #2319) — this gate covers built-in tools only.
//   - It also does NOT intercept subagent tool calls (upstream #5894).
// The gate is therefore partial by design; Claude/Kimi hooks are the
// complete coverage path.
//
// OpenCode is NOT launched through the cma wrappers, so wrapper-exported
// JEV_* env may be absent. The plugin therefore reads the ranked endpoint
// cache (~/.local/share/claude-multi-account/providers/jev-endpoints.json)
// directly, with the same TTL semantics as cma_jev_env, and resolves the key
// var NAME from ~/api_keys.sh via a tiny shell-out. Env vars, when present,
// take precedence.
//
// Modes: JEV_MODE=shadow (default — log the would-be decision, never block)
// | enforce (throw to block on deny). Fail-open on any error.

import { readFileSync, appendFileSync, mkdirSync, statSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { homedir } from "node:os";
import { join } from "node:path";

// Computed at call time so CMA_PROVIDERS_DIR (and a changed HOME) is honoured,
// exactly like the shell side (cma_jev_env).
function cachePath() {
  const dir = process.env.CMA_PROVIDERS_DIR
    || join(homedir(), ".local/share/claude-multi-account/providers");
  return join(dir, "jev-endpoints.json");
}
const STATE_DIR = process.env.JEV_STATE_DIR || join(homedir(), ".local/state/jev");
const MODE = process.env.JEV_MODE || "shadow";
const TIMEOUT_MS = Number(process.env.JEV_GATE_TIMEOUT || 2) * 1000;
const RISKY_THRESHOLD = Number(process.env.JEV_RISKY_THRESHOLD || 0.7);

// Deterministic risk floor (mirrors jev-gate.sh — duplication is deliberate:
// the plugin shares nothing with the bash gate).
const FLOOR_PATTERNS = [/rm -rf \//, /rm -fr \//, /mkfs/, /:\(\)\{/, /> \/dev\/sd/,
  /git push (--force|-f)/, /\|\s*(ba)?sh\b/];

// Key-origin rule (same as jev-gate.sh / jev_mcp.py): a key is released to an
// https origin ONLY when it is loopback, one of the SHIPPED pins below with the
// SAME key variable, or listed by the operator in CMA_JEV_TRUSTED_ORIGINS
// ("origin=KEYVAR" pairs). Plain http never carries a key. The cache file is
// NOT an attestation. A test keeps this list equal to providers/jev.json.
// SHIPPED_ORIGINS: https://api.typesafe.ai=TYPESAFE_API_KEY https://openrouter.ai/api=OPENROUTER_API_KEY
const SHIPPED_ORIGINS = ["https://api.typesafe.ai=TYPESAFE_API_KEY",
  "https://openrouter.ai/api=OPENROUTER_API_KEY"];
const KEYVAR_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;

function originAllowsKey(baseUrl, keyVar) {
  const m = /^(https:\/\/[^/?#]+)/.exec(baseUrl || "");
  if (!m) return false;
  const origin = m[1];
  const hostport = origin.slice("https://".length);
  if (/[@\\%\s]/.test(hostport)) return false;
  const host = hostport.startsWith("[") ? hostport.split("]")[0] + "]" : hostport.split(":")[0];
  if (/^(127(\.[0-9]{1,3}){3}|localhost|\[::1\])$/.test(host)
      && !host.split(".").some((o) => /^\d+$/.test(o) && Number(o) > 255)) return true;
  // The shipped list is matched on the PATH-bearing base too (openrouter lives under /api).
  const pair = `${origin}=${keyVar}`;
  const base = `${(baseUrl || "").replace(/\/+$/, "")}=${keyVar}`;
  if (SHIPPED_ORIGINS.includes(pair) || SHIPPED_ORIGINS.includes(base)) return true;
  for (const t of (process.env.CMA_JEV_TRUSTED_ORIGINS || "").split(/\s+/)) {
    const i = t.indexOf("=");
    if (i > 0 && t.slice(0, i) === origin && t.slice(i + 1) === keyVar) return true;
  }
  return false;
}

function keyFor(keyVar) {
  if (process.env.JEV_API_KEY) return process.env.JEV_API_KEY;
  if (!KEYVAR_RE.test(keyVar)) return "";
  if (process.env[keyVar]) return process.env[keyVar];
  try {
    // key_var travels as DATA in the environment, never inside the script text.
    return execFileSync("bash", ["-c",
      'source "${CMA_KEYS_FILE:-$HOME/api_keys.sh}" >/dev/null 2>&1; printf %s "${!KV:-}"'],
      { timeout: 2000, env: { ...process.env, KV: keyVar } }).toString();
  } catch { return ""; }
}

// Returns {base_url, key, model, provider_id, key_unpinned?}. key is "" when
// none is to be sent (plain http, no key, or an origin that is not allowed).
function loadEndpoint() {
  let base, keyVar, model, pid;
  if (process.env.JEV_BASE_URL) {
    base = process.env.JEV_BASE_URL;
    keyVar = process.env.JEV_KEY_VAR || "TYPESAFE_API_KEY";
    model = process.env.JEV_MODEL || "jev-latest";
    pid = process.env.CMA_JEV_ENDPOINT_ID || "env";
  } else {
    try {
      const ttl = Number(process.env.CMA_JEV_CACHE_TTL || 300);
      const cache = cachePath();
      if (Date.now() / 1000 - statSync(cache).mtimeMs / 1000 > ttl) return null;
      const ep = (JSON.parse(readFileSync(cache, "utf8")).endpoints || [])[0];
      if (!ep || !ep.base_url) return null;
      base = ep.base_url;
      keyVar = ep.key_var || "TYPESAFE_API_KEY";
      model = ep.model || "jev-latest";
      pid = ep.provider_id || "jev";
    } catch { return null; }
  }
  const out = { base_url: base, key: "", model, provider_id: pid, key_unpinned: false };
  if (/^https:\/\//i.test(base)) {
    if (!originAllowsKey(base, keyVar)) { out.key_unpinned = true; return out; }
    out.key = keyFor(keyVar);
  }
  return out;
}

function logDecision(rec) {
  try {
    mkdirSync(STATE_DIR, { recursive: true });
    appendFileSync(join(STATE_DIR, "decisions.jsonl"), JSON.stringify(rec) + "\n");
  } catch { /* evidence logging never blocks */ }
}

export const JevGate = async ({ client }) => ({
  "tool.execute.before": async (input, output) => {
    if ((process.env.JEV_GATE || "on") === "off") return;
    const tool = input?.tool || "unknown";
    const argsStr = JSON.stringify(output?.args ?? {});
    const state = (`tool=${tool} input=${argsStr}`).slice(0, 12000);
    const stateHash = createHash("sha256").update(state).digest("hex").slice(0, 16);
    const floor = FLOOR_PATTERNS.some((re) => re.test(argsStr)) ? "ask" : "allow";

    const ep = loadEndpoint();
    if (!ep) {
      logDecision({ ts: Date.now(), agent: "opencode", tool, state_hash: stateHash,
        question: "gate", answer: floor, risky_p: 0, confidence: 0, latency_ms: 0,
        endpoint: "none", mode: MODE, enforced: false, fallback: "endpoint_error" });
      return; // fail-open
    }

    if (ep.key_unpinned) {
      logDecision({ ts: Date.now(), agent: "opencode", tool, state_hash: stateHash,
        question: "gate", answer: floor, risky_p: 0, confidence: 0, latency_ms: 0,
        endpoint: ep.provider_id, mode: MODE, enforced: false, fallback: "key_unpinned" });
      return; // fail-open, but NO request: the key never leaves for an unvalidated host
    }
    if (/^https:\/\//i.test(ep.base_url) && !ep.key) {
      logDecision({ ts: Date.now(), agent: "opencode", tool, state_hash: stateHash,
        question: "gate", answer: floor, risky_p: 0, confidence: 0, latency_ms: 0,
        endpoint: ep.provider_id, mode: MODE, enforced: false, fallback: "no_key" });
      return;
    }

    const t0 = Date.now();
    let answer = floor, risky = 0, confidence = 0, fallback = null;
    try {
      const resp = await fetch(`${ep.base_url}/v1/systemone`, {
        method: "POST",
        signal: AbortSignal.timeout(TIMEOUT_MS),
        headers: ep.key
          ? { "Content-Type": "application/json", Authorization: `Bearer ${ep.key}` }
          : { "Content-Type": "application/json" },
        body: JSON.stringify({
          model: ep.model, state,
          // Verified systemone wire format (research §1.2): name -> question map.
          questions: {
            gate: { type: "choice",
              instructions: "Should an AI coding agent be allowed to execute this tool call? allow=routine safe action, ask=needs human confirmation, deny=must not run.",
              criteria: {
                allow: "Routine, reversible, local, no secrets involved.",
                ask: "Potentially destructive, externally visible, or ambiguous — a human should confirm.",
                deny: "Clearly dangerous: data loss, secret exposure, or irreversible external side effects." } },
            risky: { type: "noul",
              instructions: "Does this action risk data loss, secret exposure, or irreversible external side effects?",
              criteria: { "true": "Real risk of data loss, secret exposure, or irreversible external side effects.",
                          "false": "Routine, reversible, local." } } } }),
      });
      const data = await resp.json();
      const answers = data.answers || {};
      const gate = answers.gate || {};
      const risk = answers.risky || {};
      const rawChoice = gate.choice ?? gate.answer;
      const choice = ["allow", "ask", "deny"].includes(rawChoice) ? rawChoice : "allow";
      const rawRisk = risk.noul ?? risk.answer;
      risky = typeof rawRisk === "number" ? rawRisk
        : rawRisk === "yes" ? (risk.probabilities?.yes ?? 0.9)
        : rawRisk === "no" ? (risk.probabilities?.yes ?? 0.1)
        : (risk.probabilities?.yes ?? 0);
      confidence = typeof gate.confidence === "number" ? gate.confidence : 0;
      answer = choice;
      if (answer === "allow" && risky > RISKY_THRESHOLD) answer = "ask";
      if (floor === "ask" && answer === "allow") answer = "ask";
    } catch {
      answer = floor; fallback = "endpoint_error"; // fail-open
    }

    logDecision({ ts: Date.now(), agent: "opencode", tool, state_hash: stateHash,
      question: "gate", answer, risky_p: risky, confidence, latency_ms: Date.now() - t0,
      endpoint: ep.provider_id, mode: MODE, enforced: MODE === "enforce", fallback });

    if (MODE === "enforce" && answer === "deny") {
      throw new Error(`jev-gate: denied (choice=${answer} risky=${risky})`);
    }
  },

  "session.created": async () => {
    const ep = loadEndpoint();
    try {
      client?.app?.log?.({ service: "jev-gate", level: "info",
        message: ep ? `Jev decision layer: ACTIVE (endpoint: ${ep.provider_id}, mode: ${MODE})`
                    : "Jev decision layer: INACTIVE (no endpoint cache)" });
    } catch { /* best-effort */ }
  },
});

export default JevGate;
