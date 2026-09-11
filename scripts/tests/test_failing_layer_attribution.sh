#!/usr/bin/env bash
# test_failing_layer_attribution.sh — status.json's `failing_layer` may name
# only a layer the evidence IDENTIFIED. It may never assert one nothing
# determined.
#
# Sibling of test_failure_cause_attribution.sh, one field over: that file pins
# failure MESSAGES to observed evidence; this one pins the machine-readable
# FIELD those failures are recorded under.
#
# THE DEFECT. claude-providers.sh wrote `existence` as a literal on every
# verification failure:
#
#   2409  cma_status_write "$pid" failed "$model" existence      (cmd_sync)
#   2740  cma_status_write "$id"  failed "$model" existence      (cmd_verify)
#   2741  cma_status_write "$id"  unverified "$model" existence  (cmd_verify)
#   2450  the `else` arm that hardcodes flayer="existence"       (cmd_sync)
#   3161  cma_status_write "$aname" unverified "$strong" existence (low score)
#
# providers-verify.sh returns a NON-verified verdict from many distinct
# conditions, and most are not existence: the model made no tool call
# (:476/:480), the VERIFY_OK sentinel was missing (:423), the context window is
# smaller than the probe itself (:440), the base_url IS the ccr gateway so no
# verdict is attributable at all (:202), the LLMsVerifier binary declined
# (:212), or no probe was even attempted (:512). Measured consequence: the
# live `helixagent` alias recorded failing_layer=existence while its model
# demonstrably EXISTED and answered — the verifier's own reason was "tool
# calling unsupported (required by Claude Code)".
#
# WHY IT IS NOT COSMETIC. The field escapes the toolkit: the challenges
# submodule renders `failing_layer=<value>` straight into a QA artefact, so a
# never-determined value is published as evidence. And it cost real
# investigation time, which is the failure mode §11.4.6 exists to prevent — a
# confident wrong diagnostic is worse than an honest "unknown", because an
# honest unknown sends you to look while a wrong one sends you somewhere else.
#
# THE UPSTREAM HALF (same fix, first in order). cmd_sync ran the verifier with
# `2>/dev/null`, so the verifier's EXPLANATION — the only place the real layer
# was ever stated — was destroyed before anything could record it. cmd_verify
# already keeps it (claude-providers.sh:2724-2739, "KEEP THE REASON"); the
# identical treatment was simply never applied to cmd_sync. A layer cannot be
# recorded honestly while its evidence is being discarded upstream, so both
# halves are pinned here.
#
# CASES.
#   L0  control: the real providers-verify.sh really does emit non-verified
#       verdicts from MANY sites (otherwise "the layer is derivable" is a
#       claim about a file that does not have the branches).
#   L1  REAL verifier, REAL fixture endpoint: a backend that chats fine but
#       never tool-calls -> verdict failed, layer `tool_call`, NOT existence.
#   L2  REAL verifier: base_url IS the ccr gateway -> layer `attribution`.
#       (No probe is sent: providers-verify.sh's gate 0 short-circuits before
#       any network call, so this touches no port anyone owns.)
#   L3  cmd_sync end-to-end: a tool_call failure is PERSISTED as tool_call.
#   L4  cmd_verify end-to-end: same.
#   L5  a verifier that determines NO layer is recorded as `unknown` — never
#       as a confident wrong value. This is the honesty floor.
#   L6  control: where existence genuinely IS the layer, it is still recorded
#       as existence (the fix must not simply relabel everything).
#   L7  cmd_sync KEEPS THE VERIFIER'S REASON: a failed sync surfaces the
#       verifier's stderr instead of sending it to /dev/null.
#   L8  cmd_sync failure still leaves the provider DIAGNOSABLE — the reason is
#       recoverable without re-running a whole-fleet sync.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

command -v jq      >/dev/null 2>&1 || { echo "SKIP: jq is required";      exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 is required"; exit 0; }
command -v curl    >/dev/null 2>&1 || { echo "SKIP: curl is required";    exit 0; }

PROVIDERS_SH="$SCRIPTS_DIR/claude-providers.sh"
VERIFY_SH="$SCRIPTS_DIR/providers-verify.sh"
[[ -f "$PROVIDERS_SH" && -f "$VERIFY_SH" ]] || { echo "SKIP: scripts not found"; exit 0; }

make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e

# Hermetic + fast: `sync` runs the per-model multi phase by DEFAULT
# (claude-providers.sh:3290-3296), which walks the shipped provider overrides
# and probes real vendor endpoints. Nothing here is about that phase, and a
# test that reaches the public internet is neither hermetic nor reproducible
# (§11.4.50). The documented knob turns it off.
export CMA_SYNC_MULTI=0

FIX="$HOME/layerfix"; mkdir -p "$FIX" "$HOME/fakebin"

# ---------------------------------------------------------------------------
# Fixture backend. Plain HTTP on an EPHEMERAL loopback port (bind :0, port read
# back), so it can never collide with a port another agent owns (§11.4.119).
# providers-verify.sh probes a loopback-with-explicit-port endpoint keylessly,
# so no credential is needed or sent.
#
#   mode=notools : chats correctly (VERIFY_OK) but NEVER returns tool_calls
#                  -> the tool-calling layer is what fails.
#   mode=nosentinel : answers 200 with the wrong content
#                  -> the existence layer is what fails.
# ---------------------------------------------------------------------------
cat > "$FIX/server.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
MODE = sys.argv[1]

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def _send(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            req = {}
        if MODE == "nosentinel":
            content = "I am a chatty model that ignores instructions."
        else:
            content = "VERIFY_OK"
        # notools: even when the request carries tools, answer with prose only.
        self._send({"id": "c1", "object": "chat.completion",
                    "model": req.get("model", "m"),
                    "choices": [{"index": 0,
                                 "message": {"role": "assistant", "content": content},
                                 "finish_reason": "stop"}],
                    "usage": {"prompt_tokens": 5, "completion_tokens": 3,
                              "total_tokens": 8}})
    def do_GET(self):
        self._send({"object": "list", "data": [{"id": "m1", "object": "model"}]})

srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
print("PORT %d" % srv.server_address[1], flush=True)
srv.serve_forever()
PY

SRV_PIDS=()
start_server() {  # start_server MODE -> echoes port
  local log; log="$(mktemp "${TMPDIR:-/tmp}/cma-layerfix.XXXXXX")"
  python3 "$FIX/server.py" "$1" > "$log" 2>&1 &
  SRV_PIDS+=("$!")
  local i port=""
  for ((i=0; i<60; i++)); do
    port="$(awk '/^PORT /{print $2; exit}' "$log" 2>/dev/null)"
    [[ -n "$port" ]] && break
    sleep 0.1
  done
  rm -f "$log"; echo "$port"
}
# Reap only the PIDs THIS file started (§11.4.174/§11.4.263 — never a pattern
# kill, never a pgid, and never a pid <= 1).
stop_servers() {
  local p
  for p in ${SRV_PIDS[@]+"${SRV_PIDS[@]}"}; do
    [[ "$p" =~ ^[0-9]+$ ]] && (( p > 1 )) && kill "$p" 2>/dev/null
  done
}
trap 'stop_servers; cleanup_sandbox' EXIT

# run_verify BASEURL MODEL -> sets V_OUT (verdict), V_ERR (reason), V_LAYER
# CMA_VERIFIER_BIN is pointed at a non-existent path so strategy 1
# (LLMsVerifier) is provably unavailable and the live probes are what run.
run_verify() {
  local lf; lf="$(mktemp "${TMPDIR:-/tmp}/cma-layer.XXXXXX")"; : > "$lf"
  local ef; ef="$(mktemp "${TMPDIR:-/tmp}/cma-verr.XXXXXX")"
  V_OUT="$(CMA_VERIFIER_BIN=/nonexistent/model-verification \
           CMA_VERIFY_LAYER_FILE="$lf" \
           bash "$VERIFY_SH" --provider lp --model "${2:-m1}" \
             --key-var LP_API_KEY --base-url "$1" 2>"$ef")"
  V_RC=$?
  V_ERR="$(cat "$ef")"; V_LAYER="$(cat "$lf" 2>/dev/null)"
  rm -f "$lf" "$ef"
}

# ---------------------------------------------------------------------------
it "L0 control: the real verifier emits non-verified verdicts from MANY sites"
# If this were 1, "the layer is derivable from what the verifier already knows"
# would be false and every case below would be arguing about nothing.
_n_failed="$(grep -c 'emit failed' "$VERIFY_SH")"
_n_unver="$(grep -c 'emit unverified' "$VERIFY_SH")"
cond=0; (( _n_failed >= 5 )) && cond=1
assert_eq 1 "$cond" "L0 >=5 distinct 'emit failed' sites exist (found $_n_failed)"
cond=0; (( _n_unver >= 4 )) && cond=1
assert_eq 1 "$cond" "L0 >=4 distinct 'emit unverified' sites exist (found $_n_unver)"
# Positive control for the two greps (§11.4.273): the same pattern style finds
# a string that IS there, so the counts above are measurements, not artefacts.
cond=0; (( $(grep -c 'emit verified' "$VERIFY_SH") >= 1 )) && cond=1
assert_eq 1 "$cond" "L0 control: 'emit verified' is also found (grep works)"

# ---------------------------------------------------------------------------
it "L1 REAL verifier + REAL backend that chats but never tool-calls -> tool_call"
PORT_NT="$(start_server notools)"
if [[ -z "$PORT_NT" ]]; then
  echo "    SKIP-CASE: notools fixture did not come up"
else
  run_verify "http://127.0.0.1:$PORT_NT/v1"
  assert_eq "failed" "$V_OUT" "L1 verdict is failed"
  # The reason is the control that says WHICH layer the evidence identified —
  # without it, asserting the layer would be asserting an unproven claim.
  case "$V_ERR" in
    *"tool call"*|*"tool calling"*|*"tool-calling"*)
      _pass "L1 the verifier's own reason is about tool calling: $V_ERR" ;;
    *) _fail "L1 fixture did not drive the tool-calling branch" "reason=$V_ERR" ;;
  esac
  assert_eq "tool_call" "$V_LAYER" "L1 layer recorded is tool_call, NOT existence"
fi

# ---------------------------------------------------------------------------
it "L2 REAL verifier: a ccr-gateway base_url is unattributable -> attribution"
# Gate 0 in providers-verify.sh short-circuits BEFORE any probe, so this sends
# no traffic to 3456 (or anywhere). It is a pure source-of-verdict test.
run_verify "http://127.0.0.1:3456/v1"
assert_eq "failed" "$V_OUT" "L2 verdict is failed"
assert_eq "attribution" "$V_LAYER" "L2 layer is attribution, NOT existence"

# ---------------------------------------------------------------------------
it "L6 control: where existence genuinely IS the layer, existence is recorded"
# The fix must not relabel everything — this is the case the old literal got
# RIGHT, and it must stay right.
PORT_NS="$(start_server nosentinel)"
if [[ -z "$PORT_NS" ]]; then
  echo "    SKIP-CASE: nosentinel fixture did not come up"
else
  run_verify "http://127.0.0.1:$PORT_NS/v1"
  assert_eq "failed" "$V_OUT" "L6 verdict is failed (reason=$V_ERR)"
  assert_eq "existence" "$V_LAYER" "L6 layer is existence (correctly)"
fi

# ---------------------------------------------------------------------------
# End-to-end through claude-providers.sh. Stub verifiers stand in for the real
# one so each layer can be driven deterministically; L1/L2/L6 above are what
# prove the REAL verifier produces these tokens.
# ---------------------------------------------------------------------------
PCACHE="$HOME/.local/share/claude-multi-account/providers/models.dev.cache.json"
mkdir -p "$(dirname "$PCACHE")"
cat > "$PCACHE" <<'JSON'
{
  "beta": {"env":["BETA_API_KEY"],"api":"https://api.beta.ai/v1","npm":"@ai-sdk/openai-compatible",
           "models":{"f":{"id":"beta-x","reasoning":false,"release_date":"2025-06-01",
                          "limit":{"context":128000},"cost":{"input":1,"output":5},"tool_call":true}}}
}
JSON
KEYS="$HOME/api_keys.sh"; echo 'export BETA_API_KEY="dummy-beta"' > "$KEYS"

# A verifier stub that honours the layer contract: verdict on stdout, reason on
# stderr, machine-readable layer into $CMA_VERIFY_LAYER_FILE — exactly what the
# real providers-verify.sh does.
mk_stub() {  # mk_stub NAME VERDICT LAYER REASON
  cat > "$HOME/fakebin/$1" <<EOF
#!/usr/bin/env bash
echo "$2"
echo "providers-verify[stub]: $4" >&2
[[ -n "\${CMA_VERIFY_LAYER_FILE:-}" ]] && printf '%s' "$3" > "\$CMA_VERIFY_LAYER_FILE"
exit 0
EOF
  chmod +x "$HOME/fakebin/$1"
}
# A verifier that determines NOTHING about the layer (the old contract).
cat > "$HOME/fakebin/verify-silent" <<'EOF'
#!/usr/bin/env bash
echo failed
EOF
chmod +x "$HOME/fakebin/verify-silent"

mk_stub verify-toolcall failed tool_call \
  "chat probe passed but the model made no tool call (tool calling is required by Claude Code)"
mk_stub verify-existence failed existence \
  "chat probe HTTP 404 (model missing)"

# STALE-READ GUARD. Every case below asserts on status.json AFTER a sync. If a
# sync does not reach the point of writing status — a crash, a timeout, a host
# under heavy load — the record still holds the PREVIOUS case's value, and the
# assertion then silently grades stale data: it can pass when it should fail
# (the previous case wrote the same token) or fail with a misleading `got=`.
# Both were observed for real while three suites shared this host.
#
# Stamping a sentinel first removes the ambiguity in both directions: a case
# that sees SENTINEL-NOT-WRITTEN knows the sync never recorded, which is a
# different (and honestly reported) failure from "recorded the wrong layer"
# (§11.4.201 — a wrong verdict is a defect whichever way it points).
seed_sentinel() {  # seed_sentinel ID MODEL
  cma_status_write "$1" pending "$2" "SENTINEL-NOT-WRITTEN"
}

sync_with() {  # sync_with VERIFY_STUB -> stdout+stderr of the sync
  seed_sentinel beta beta-x
  CMA_PROVIDERS_VERIFY="$HOME/fakebin/$1" \
  CMA_PROVIDERS_SEMANTIC="$HOME/fakebin/semantic-ok" \
  BETA_API_KEY=sk-test \
    bash "$PROVIDERS_SH" sync --keys-file "$KEYS" 2>&1
}
cat > "$HOME/fakebin/semantic-ok" <<'EOF'
#!/usr/bin/env bash
echo verified
EOF
chmod +x "$HOME/fakebin/semantic-ok"

# ---------------------------------------------------------------------------
it "L3 cmd_sync persists the REAL layer a tool-calling failure identified"
sync_with verify-toolcall >/dev/null
assert_eq "failed" "$(cma_status_read beta)" "L3 status is failed"
assert_jq "$(cma_status_cache)" '.beta.failing_layer' "tool_call" \
  "L3 failing_layer=tool_call (the helixagent case), NOT existence"

# ---------------------------------------------------------------------------
it "L6b control: cmd_sync still records existence when THAT is the layer"
sync_with verify-existence >/dev/null
assert_jq "$(cma_status_cache)" '.beta.failing_layer' "existence" \
  "L6b existence is still recorded where it is the truth"

# ---------------------------------------------------------------------------
it "L5 a verifier that determines NO layer is recorded as unknown, not existence"
sync_with verify-silent >/dev/null
assert_eq "failed" "$(cma_status_read beta)" "L5 status is failed"
assert_jq "$(cma_status_cache)" '.beta.failing_layer' "unknown" \
  "L5 an undetermined layer is 'unknown' — never a confident wrong value"

# ---------------------------------------------------------------------------
it "L7 cmd_sync KEEPS the verifier's reason instead of sending it to /dev/null"
_out="$(sync_with verify-toolcall)"
case "$_out" in
  *"made no tool call"*) _pass "L7 the verifier's explanation reaches the operator" ;;
  *) _fail "L7 the verifier's stderr must not be discarded" "sync output=$_out" ;;
esac
# Control: a VERIFIED run must not start spraying the verifier's chatter.
mk_stub verify-okquiet verified "" "LLMsVerifier confirmed model + code visibility"
_out_ok="$(sync_with verify-okquiet)"
case "$_out_ok" in
  *"LLMsVerifier confirmed"*) _fail "L7 control: a verified run must stay quiet" "output=$_out_ok" ;;
  *) _pass "L7 control: a verified run does not echo the verifier's reason" ;;
esac

# ---------------------------------------------------------------------------
it "L4 cmd_verify persists the REAL layer too"
cma_provider_write_env "gamma" "GAMMA_API_KEY" "router" "https://api.gamma.ai/v1" \
  "gamma-x" "" "$HOME/.claude-prov-gamma" "" "" "gamma"
seed_sentinel gamma gamma-x
out="$(CMA_PROVIDERS_VERIFY="$HOME/fakebin/verify-toolcall" \
       CMA_PROVIDERS_SEMANTIC="$HOME/fakebin/semantic-ok" \
       bash "$PROVIDERS_SH" verify gamma 2>/dev/null)"
assert_eq "failed" "$out" "L4 cmd_verify stdout: failed"
assert_jq "$(cma_status_cache)" '.gamma.failing_layer' "tool_call" \
  "L4 cmd_verify records tool_call, NOT existence"

seed_sentinel gamma gamma-x
out="$(CMA_PROVIDERS_VERIFY="$HOME/fakebin/verify-silent" \
       CMA_PROVIDERS_SEMANTIC="$HOME/fakebin/semantic-ok" \
       bash "$PROVIDERS_SH" verify gamma 2>/dev/null)"
assert_jq "$(cma_status_cache)" '.gamma.failing_layer' "unknown" \
  "L4 cmd_verify records unknown when nothing determined a layer"

# ---------------------------------------------------------------------------
it "L8 an unverified (not failed) verdict also carries its real layer"
mk_stub verify-unver-tool unverified tool_call \
  "chat probe passed but tool probe rate-limited (HTTP 429)"
sync_with verify-unver-tool >/dev/null
assert_eq "unverified" "$(cma_status_read beta)" "L8 status is unverified"
assert_jq "$(cma_status_cache)" '.beta.failing_layer' "tool_call" \
  "L8 unverified verdicts are not blanket-labelled existence either"

summary
