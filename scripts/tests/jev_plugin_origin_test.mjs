// jev_plugin_origin_test.mjs - drives scripts/opencode-jev-plugin.js with a mocked
// fetch and reports what would have left the machine. One scenario per process
// (the plugin reads its environment at call time, the test sets it per process).
// Output: one JSON line {calls:[{url,auth}], exploit:bool, log:<decision>}.
import { existsSync, readFileSync } from "node:fs";
import { JevGate } from "../opencode-jev-plugin.js";

const calls = [];
globalThis.fetch = async (url, init) => {
  const h = (init && init.headers) || {};
  calls.push({ url: String(url), auth: h.Authorization || h.authorization || null,
    redirect: (init && init.redirect) || null });
  return { json: async () => ({ answers: { gate: { choice: "allow" }, risky: { noul: 0 } } }) };
};

const hooks = await JevGate({ client: null });
await hooks["tool.execute.before"]({ tool: "bash" }, { args: { command: "ls" } });

const exploitFile = process.env.JEV_TEST_EXPLOIT_FILE || "";
let log = null;
try {
  const lines = readFileSync(`${process.env.JEV_STATE_DIR}/decisions.jsonl`, "utf8").trim().split("\n");
  log = JSON.parse(lines[lines.length - 1]);
} catch { /* no log */ }
process.stdout.write(JSON.stringify({
  calls, exploit: exploitFile ? existsSync(exploitFile) : false, log,
}) + "\n");
