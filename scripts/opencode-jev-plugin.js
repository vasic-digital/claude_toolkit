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
import { execSync } from "node:child_process";
import { createHash } from "node:crypto";
import { homedir } from "node:os";
import { join } from "node:path";

const CACHE = join(homedir(), ".local/share/claude-multi-account/providers/jev-endpoints.json");
const STATE_DIR = process.env.JEV_STATE_DIR || join(homedir(), ".local/state/jev");
const MODE = process.env.JEV_MODE || "shadow";
const TIMEOUT_MS = Number(process.env.JEV_GATE_TIMEOUT || 2) * 1000;
const RISKY_THRESHOLD = Number(process.env.JEV_RISKY_THRESHOLD || 0.7);

// Deterministic risk floor (mirrors jev-gate.sh — duplication is deliberate:
// the plugin shares nothing with the bash gate).
const FLOOR_PATTERNS = [/rm -rf \//, /rm -fr \//, /mkfs/, /:\(\)\{/, /> \/dev\/sd/,
  /git push (--force|-f)/, /\|\s*(ba)?sh\b/];

function loadEndpoint() {
  if (process.env.JEV_BASE_URL) {
    return {
      base_url: process.env.JEV_BASE_URL,
      key: process.env.JEV_API_KEY || process.env.TYPESAFE_API_KEY || "local",
      model: process.env.JEV_MODEL || "jev-latest",
      provider_id: process.env.CMA_JEV_ENDPOINT_ID || "env",
    };
  }
  try {
    const ttl = Number(process.env.CMA_JEV_CACHE_TTL || 300);
    if (Date.now() / 1000 - statSync(CACHE).mtimeMs / 1000 > ttl) return null;
    const cache = JSON.parse(readFileSync(CACHE, "utf8"));
    const ep = (cache.endpoints || [])[0];
    if (!ep || !ep.base_url) return null;
    let key = "local";
    if (ep.key_var) {
      try {
        key = execSync(
          `bash -c 'source "\${CMA_KEYS_FILE:-$HOME/api_keys.sh}" >/dev/null 2>&1; printf %s "\${${ep.key_var}:-}"'`,
          { timeout: 2000 }).toString() || "local";
      } catch { key = "local"; }
    }
    return { base_url: ep.base_url, key, model: ep.model || "jev-latest",
             provider_id: ep.provider_id || "jev" };
  } catch { return null; }
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

    const t0 = Date.now();
    let answer = floor, risky = 0, confidence = 0, fallback = null;
    try {
      const resp = await fetch(`${ep.base_url}/v1/systemone`, {
        method: "POST",
        signal: AbortSignal.timeout(TIMEOUT_MS),
        headers: { "Content-Type": "application/json",
                   Authorization: `Bearer ${ep.key}` },
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
