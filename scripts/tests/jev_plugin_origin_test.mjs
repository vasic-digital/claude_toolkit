// jev_plugin_origin_test.mjs - drives scripts/opencode-jev-plugin.js with a mocked
// fetch and reports what would have left the machine. One scenario per process
// (the plugin reads its environment at call time, the test sets it per process).
// Output: one JSON line {calls:[{url,auth,auth_is_dummy,redirect}], exploit:bool, log:<decision>}.
// "auth" is null or the literal "present" - an Authorization VALUE is never printed;
// auth_is_dummy says whether it carried JEV_TEST_DUMMY (the test's dummy key).
import { existsSync, readFileSync } from "node:fs";

// Safety: the plugin reads $HOME/api_keys.sh when it resolves a key. Refuse to run
// unless the caller declares a scratch HOME (JEV_TEST_SCRATCH_HOME must equal HOME),
// so this harness can never read the operator's real key file.
if (!process.env.JEV_TEST_SCRATCH_HOME || process.env.JEV_TEST_SCRATCH_HOME !== process.env.HOME) {
  process.stderr.write("jev_plugin_origin_test: refusing to run: set HOME to a scratch dir and JEV_TEST_SCRATCH_HOME to the same path\n");
  process.exit(2);
}
import { JevGate } from "../opencode-jev-plugin.js";

const calls = [];
globalThis.fetch = async (url, init) => {
  const h = (init && init.headers) || {};
  const a = h.Authorization || h.authorization || null;
  const dummy = process.env.JEV_TEST_DUMMY || "";
  calls.push({ url: String(url), auth: a ? "present" : null,
    auth_is_dummy: !!(a && dummy && String(a).includes(dummy)),
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
