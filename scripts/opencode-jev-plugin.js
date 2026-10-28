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
// | enforce (throw to block on deny). Fail-open on any error. Precedence: env JEV_MODE >
// ~/.config/jev/env (jev-setup --mode) > shadow.

import { readFileSync, appendFileSync, mkdirSync, statSync, accessSync, constants as fsConstants } from "node:fs";
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
// Mode precedence: process env JEV_MODE > ~/.config/jev/env (written by `jev-setup --mode`; $JEV_CONFIG_DIR/env when set) > shadow.
// The file is parsed, never executed: only an exact JEV_MODE=shadow|enforce line counts (last wins).
function resolveMode() {
  if (process.env.JEV_MODE) return process.env.JEV_MODE;
  try {
    const f = join(process.env.JEV_CONFIG_DIR || join(homedir(), ".config/jev"), "env");
    const hits = readFileSync(f, "utf8").split("\n").filter((l) => /^JEV_MODE=(shadow|enforce)$/.test(l.replace(/\r$/, "")));
    if (hits.length) return hits[hits.length - 1].replace(/\r$/, "").split("=")[1];
  } catch { /* no file: default */ }
  return "shadow";
}
const MODE = resolveMode();
// Hosted endpoints never enforce: a Jev whose host is not loopback / RFC1918 / link-local / *.local / *.lan is a third party;
// its answers are logged (shadow) but never block. Same rule and grammar as jev-gate.sh (_jev_host_is_local). An authority with
// userinfo, backslash, percent or whitespace is ambiguous and counts as hosted.
function hostIsLocal(url) {
  let a = String(url || "").replace(/^[a-z][a-z0-9+.-]*:\/\//i, "");
  a = a.split(/[\/?#]/)[0];
  if (!a || /[@\\%\s]/.test(a)) return false;
  const h = (a.startsWith("[") ? a.slice(0, a.indexOf("]") + 1) : a.split(":")[0]).toLowerCase();
  if (h === "localhost" || h === "[::1]") return true;
  if (/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.(local|lan)$/.test(h)) return true;
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(h);
  if (!m) return false;
  const o = m.slice(1).map(Number);
  if (o.some((n) => n > 255)) return false;
  return o[0] === 127 || o[0] === 10 || (o[0] === 192 && o[1] === 168)
    || (o[0] === 172 && o[1] >= 16 && o[1] <= 31) || (o[0] === 169 && o[1] === 254);
}
function effectiveMode(baseUrl) {
  return MODE === "enforce" && !hostIsLocal(baseUrl) ? "shadow" : MODE;
}
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
// SHIPPED_ORIGINS: https://api.typesafe.ai=TYPESAFE_API_KEY https://openrouter.ai=OPENROUTER_API_KEY
const SHIPPED_ORIGINS = ["https://api.typesafe.ai=TYPESAFE_API_KEY",
  "https://openrouter.ai=OPENROUTER_API_KEY"];
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
  // ONE comparison everywhere: ORIGIN (scheme://authority) of the configured base
  // against the ORIGIN of the shipped base (openrouter's base carries /api).
  if (SHIPPED_ORIGINS.includes(`${origin}=${keyVar}`)) return true;
  for (const t of (process.env.CMA_JEV_TRUSTED_ORIGINS || "").split(/\s+/)) {
    const i = t.indexOf("=");
    if (i > 0 && t.slice(0, i) === origin && t.slice(i + 1) === keyVar) return true;
  }
  return false;
}

// Key-file fallback (same order as jev-gate.sh and jev_mcp.py): env var > keys file (~/api_keys.sh) > the key files named by the
// non-secret pointer ($CMA_JEV_KEY_FILES, then the lines of $JEV_CONFIG_DIR/key-files = ~/.config/jev/key-files; `jev-setup --key-file`).
// A key file is PARSED, never executed: regular readable file owned by the current user; last `NAME=` / `export NAME=` line wins; CR and
// trailing blanks stripped; ONE pair of matching quotes removed; nothing expanded. Shared vectors: scripts/tests/test_jev_keyfile.sh.
function keyfileCandidates() {
  const out = (process.env.CMA_JEV_KEY_FILES || "").split(":");
  try {
    const cfg = join(process.env.JEV_CONFIG_DIR || join(homedir(), ".config/jev"), "key-files");
    out.push(...readFileSync(cfg, "utf8").replace(/\r/g, "").split("\n"));
  } catch { /* no pointer file */ }
  return out.map((p) => p.trim()).filter((p) => p && !p.startsWith("#"))
    .map((p) => (p.startsWith("~/") ? join(homedir(), p.slice(2)) : p));
}
function keyfileLookup(name) {
  if (!name || !KEYVAR_RE.test(name)) return "";
  for (const p of keyfileCandidates()) {
    let text;
    try {
      const st = statSync(p);
      if (!st.isFile() || st.uid !== process.getuid()) continue;
      accessSync(p, fsConstants.R_OK);
      text = readFileSync(p, "utf8");
    } catch { continue; }
    let found = null;
    for (const raw of text.split("\n")) {
      let line = raw.endsWith("\r") ? raw.slice(0, -1) : raw;
      line = line.replace(/^[ \t]+/, "").replace(/^export[ \t]+/, "");
      if (line.startsWith(name + "=")) found = line.slice(name.length + 1);
    }
    if (found === null) continue;
    let v = found.replace(/[ \t]+$/, "");
    if (v.length >= 2 && v[0] === v[v.length - 1] && (v[0] === '"' || v[0] === "'")) v = v.slice(1, -1);
    if (v) return v;
  }
  return "";
}
// llmctl's bearer contract: LLMCTL_API_KEY must match [A-Za-z0-9_-]{32,512} as a WHOLE single-line value (no multiline flag; the
// character class excludes newlines, so a trailing newline is rejected). A malformed value (a shell-profile 1-char placeholder,
// garbage, a multi-line injection) counts as ABSENT at its source and the next source is consulted. Other key variables are not
// format-checked. Same rule as jev-gate.sh `_key_valid` and jev_mcp.py (shared vectors: scripts/tests/test_jev_key_contract.sh).
const LLMCTL_KEY_RE = /^[A-Za-z0-9_-]{32,512}$/;
function keyValid(name, v) {
  if (!v) return false;
  return name === "LLMCTL_API_KEY" ? LLMCTL_KEY_RE.test(v) && !v.includes("\n") : true;
}
function keyFor(keyVar) {
  // "local" is the keyless-loopback PLACEHOLDER jev-setup bakes into a registration; it is not a credential.
  if (process.env.JEV_API_KEY && process.env.JEV_API_KEY !== "local") return process.env.JEV_API_KEY;
  if (!KEYVAR_RE.test(keyVar)) return "";
  if (keyValid(keyVar, process.env[keyVar])) return process.env[keyVar];
  let v = "";
  try {
    // key_var travels as DATA in the environment, never inside the script text. The ambient value is unset first so only the keys file answers.
    v = execFileSync("bash", ["-c",
      'unset "$KV"; source "${CMA_KEYS_FILE:-$HOME/api_keys.sh}" >/dev/null 2>&1; printf %s "${!KV:-}"'],
      { timeout: 2000, env: { ...process.env, KV: keyVar } }).toString();
  } catch { v = ""; }
  if (keyValid(keyVar, v)) return v;
  const kf = keyfileLookup(keyVar);
  return keyValid(keyVar, kf) ? kf : "";
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

    const mode = effectiveMode(ep.base_url);
    const t0 = Date.now();
    let answer = floor, risky = 0, confidence = 0, fallback = null;
    try {
      const resp = await fetch(`${ep.base_url}/v1/systemone`, {
        method: "POST",
        redirect: "error",     // a bearer must never follow a redirect to another origin
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
      endpoint: ep.provider_id, mode, enforced: mode === "enforce", fallback });

    if (mode === "enforce" && answer === "deny") {
      throw new Error(`jev-gate: denied (choice=${answer} risky=${risky})`);
    }
  },

  "session.created": async () => {
    const ep = loadEndpoint();
    try {
      client?.app?.log?.({ service: "jev-gate", level: "info",
        message: ep ? `Jev decision layer: ACTIVE (endpoint: ${ep.provider_id}, mode: ${effectiveMode(ep.base_url)})`
                    : "Jev decision layer: INACTIVE (no endpoint cache)" });
    } catch { /* best-effort */ }
  },
});

export default JevGate;
