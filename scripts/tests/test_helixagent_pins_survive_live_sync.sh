#!/usr/bin/env bash
# test_helixagent_pins_survive_live_sync.sh — regression guard for the
# 2026-07-23 live defect: `claude-providers list` showed
# STRONG_MODEL=/models/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf for the
# `helixagent` facade although the git-tracked pins
# (scripts/providers/helixagent.json) declare strong/fast =
# "HelixAgent/HelixLLM".
#
# ROOT CAUSE (claude-providers.sh, detect_helixagent_record): when the live
# `/v1/models` endpoint answers but does NOT list the pinned facade id, the
# positional fallbacks (`head -n1` / `sed -n 2p`) OVERWRITE the explicitly
# pinned strong/fast models with whatever the endpoint reports — llama.cpp
# reports the loaded .gguf PATH as its model id — while every other pinned
# field (base_url, key_var, context_limit) survives.
#
# WHY THE EXISTING SUITE STAYED GREEN (hermetic-green / live-divergent,
# §11.4.196(F)): verify_helixagent_test.sh CASE E exercises pins with a DEAD
# endpoint (honest fallback keeps the pins) and CASE A exercises a LIVE
# endpoint with NO pins file (built-in defaults, live enumeration is the
# intended winner). The failing combination — pins file present AND live
# endpoint up AND the facade id absent from the live listing — was never
# exercised, and the .env record the REAL sync path generates was asserted
# only in the no-pins case.
#
# THIS test drives the REAL `claude-providers.sh sync` end-to-end (not a
# fixture-driven detector call) against a REAL local HTTP server that answers
# /v1/models with a llama.cpp-style .gguf path id, with the pins file
# PRESENT, and asserts on the GENERATED providers/helixagent.env record:
#   1. CMA_PROVIDER_MODEL      == the pinned facade (HelixAgent/HelixLLM)
#   2. CMA_PROVIDER_FAST_MODEL == the pinned facade
#   3. the .gguf path appears NOWHERE in the record
#   4. control needle (§11.4.201(7)(b)): the live fetch REALLY happened —
#      the proof log carries the server's request hit — so a green result
#      cannot come from a silently-dead endpoint falling back to the pins.
#   5. no-pins behaviour is UNCHANGED: a second sync in the same sandbox with
#      the pins file absent still selects the live-enumerated id
#      (CASE A compatibility — the fix must not regress data-driven selection).
#
# RED  (pre-fix):  assertions 1-3 FAIL — the .env carries the .gguf path.
# GREEN (post-fix): all assertions PASS.
# Paired §1.1 mutation: re-introduce the positional overwrite for pinned
# models in detect_helixagent_record -> assertions 1-3 FAIL again.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
PROOF_DIR="$TESTS_DIR/proof"
mkdir -p "$PROOF_DIR"
PROOF="$PROOF_DIR/93-helixagent-pins-survive-live-sync.txt"
: > "$PROOF"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e   # lib.sh sets -e; the harness asserts on failures, so relax it.

PROVIDERS_SH="$SCRIPTS_DIR/claude-providers.sh"
PDIR="$HOME/.local/share/claude-multi-account/providers"
PCACHE="$PDIR/models.dev.cache.json"
mkdir -p "$PDIR"
echo '{}' > "$PCACHE"

KEYS="$HOME/api_keys.sh"
cat > "$KEYS" <<'SH'
export HELIXAGENT_GATEWAY_KEY="dummy-helix-key-never-real"
SH

# --- REAL local /v1/models server answering with a llama.cpp-style id -------
# The id is a .gguf PATH — exactly what the production llama-server reports —
# and is DELIBERATELY NOT the pinned facade id. Every hit on /v1/models is
# appended to $HIT_FILE: that is the control needle proving the live fetch
# genuinely happened (a dead server would ALSO leave the pins in place, which
# would make a green here meaningless without this needle).
GGUF_ID="/models/Qwen3-Test-Model-Q4_K_M.gguf"
PORT_FILE="$HOME/.helix_pins_srv_port"
HIT_FILE="$HOME/.helix_pins_srv_hits"
: > "$HIT_FILE"
python3 - "$PORT_FILE" "$HIT_FILE" "$GGUF_ID" >/dev/null 2>&1 <<'PY' &
import http.server, socketserver, sys, json
port_file, hit_file, gguf_id = sys.argv[1], sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.rstrip('/').endswith('/models'):
            with open(hit_file, 'a') as f:
                f.write('models-hit\n')
            body = json.dumps({"object": "list", "data": [
                {"id": gguf_id, "object": "model", "owned_by": "llamacpp"},
            ]}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()
    def log_message(self, *a):
        pass
srv = socketserver.TCPServer(('127.0.0.1', 0), H)
open(port_file, 'w').write(str(srv.server_address[1]))
srv.serve_forever()
PY
SRV_PID=$!
trap '[[ -n "${SRV_PID:-}" ]] && kill "$SRV_PID" 2>/dev/null; cleanup_sandbox' EXIT
for _ in $(seq 1 50); do [[ -s "$PORT_FILE" ]] && break; sleep 0.1; done
PORT="$(cat "$PORT_FILE" 2>/dev/null)"
[[ -n "$PORT" ]] || { echo "FATAL: mock server did not start" >&2; exit 1; }

# --- pins file: the facade contract (mirrors scripts/providers/helixagent.json,
# but with base_url pointed at THIS test's live server) ------------------------
PINS="$HOME/helixagent.pins.json"
cat > "$PINS" <<JSON
{ "bin":"helixagent", "id":"helixagent",
  "base_url":"http://127.0.0.1:$PORT/v1", "transport":"router",
  "strong_model":"HelixAgent/HelixLLM", "fast_model":"HelixAgent/HelixLLM",
  "key_var":"HELIXAGENT_GATEWAY_KEY", "context_limit":229376, "max_output":8192 }
JSON
export CMA_HELIXAGENT_PINS_FILE="$PINS"
# No stub binary: the pins-file gate (Variant B) admits the record on its own.
# Make sure no ambient CMA_HELIXAGENT_* leaks in from the invoking shell.
unset CMA_HELIXAGENT_STRONG CMA_HELIXAGENT_FAST CMA_HELIXAGENT_BASE_URL \
      CMA_HELIXAGENT_HOST CMA_HELIXAGENT_PORT CMA_HELIXAGENT_KEYVAR \
      CMA_HELIXAGENT_BIN CMA_HELIXAGENT_TRANSPORT 2>/dev/null

{
  echo "=== test_helixagent_pins_survive_live_sync.sh evidence ==="
  echo "date: $(date -u +%FT%TZ)"
  echo "server port: $PORT   pid: $SRV_PID   live id: $GGUF_ID"
  echo "--- live GET http://127.0.0.1:$PORT/v1/models ---"
  curl -s --max-time 8 "http://127.0.0.1:$PORT/v1/models"
  echo
} >> "$PROOF" 2>&1

# ===========================================================================
# CASE 1 — pins present + live server up + facade id NOT in the live listing:
#          the pinned facade models MUST survive into the GENERATED .env.
# ===========================================================================
it "pins + live-but-divergent endpoint: real sync path runs"
bash "$PROVIDERS_SH" sync --offline --no-verify --keys-file "$KEYS" >>"$PROOF" 2>&1
assert_eq 0 $? "sync exits cleanly"
assert_file "$PDIR/helixagent.env" "helixagent env record generated by the sync path"

{
  echo "--- generated $PDIR/helixagent.env (CASE 1) ---"
  cat "$PDIR/helixagent.env"
} >> "$PROOF" 2>&1

it "control needle: the live /v1/models fetch REALLY happened (server hit recorded)"
[[ -s "$HIT_FILE" ]]
assert_eq 0 $? "mock /v1/models received >=1 request during sync (a zero here would make the pin-survival assertions vacuous)"

it "pinned facade models survive the live sync into the GENERATED record"
grep -qE "^CMA_PROVIDER_MODEL='?HelixAgent/HelixLLM'?$" "$PDIR/helixagent.env"
assert_eq 0 $? "CMA_PROVIDER_MODEL is the pinned facade HelixAgent/HelixLLM (NOT the endpoint-reported id)"
grep -qE "^CMA_PROVIDER_FAST_MODEL='?HelixAgent/HelixLLM'?$" "$PDIR/helixagent.env"
assert_eq 0 $? "CMA_PROVIDER_FAST_MODEL is the pinned facade HelixAgent/HelixLLM (NOT the endpoint-reported id)"
assert_file_not_contains "$PDIR/helixagent.env" "$GGUF_ID" \
  "the endpoint-reported .gguf path appears NOWHERE in the generated record"

# --- §11.4.120 RECONCILIATION -----------------------------------------------
# This file's own committed proof artifact (proof/93-...txt) RECORDED a broken
# state as the expected output of a passing run. Every green run wrote — and
# re-blessed — these two lines:
#
#   provider 'helixagent-native' -> alias 'helixagent-native' [native] model=helixllm-multi
#   provider 'helixllm-gateway'  -> alias 'helixllm-gateway'  [router] model=helixllm-multi
#
# `helixllm-multi` is a model no HelixLLM has ever served (zero hits in
# submodules/helix_llm; HTTP 503 from the live gateway while a real id returned
# 200 in the same second). This test never asserted on it — it grades the
# `helixagent` facade — so the artifact accumulated evidence of a live defect
# while reporting pass=10 fail=0.
#
# Per §11.4.120 the gate is RECONCILED, not deleted and not weakened: the file
# that used to RECORD the invention now REFUSES it. The positive assertions —
# that the facades carry a live-resolved model — live in
# test_helixllm_facade_model_reality.sh, which stands up its own serving mock;
# this file guards the artifact it actually produces.
# Paired §1.1 mutation: restore `: "${_lgw_strong:=helixllm-multi}"` in
# detect_helixllm_records -> this assertion FAILS.
it "the sync this test drives never names a model no endpoint serves (§11.4.120)"
assert_file_not_contains "$PROOF" "helixllm-multi" \
  "'helixllm-multi' — an invented, unservable model id — appears nowhere in the captured sync output"
if compgen -G "$PDIR/*.env" >/dev/null 2>&1 && grep -lF -- "helixllm-multi" "$PDIR"/*.env >/dev/null 2>&1; then
  _fail "a generated provider record still pins 'helixllm-multi'" \
        "$(grep -lF -- 'helixllm-multi' "$PDIR"/*.env | tr '\n' ' ')"
else
  _pass "no generated provider record pins 'helixllm-multi'"
fi

it "the other pinned fields survive too (they always did — regression floor)"
grep -qF "http://127.0.0.1:$PORT/v1" "$PDIR/helixagent.env"
assert_eq 0 $? "base_url = pinned endpoint"
grep -qE "^CMA_PROVIDER_KEYVAR='?HELIXAGENT_GATEWAY_KEY'?$" "$PDIR/helixagent.env"
assert_eq 0 $? "key_var = pinned name"
grep -qE "^CMA_PROVIDER_CONTEXT_LIMIT='?229376'?$" "$PDIR/helixagent.env"
assert_eq 0 $? "context_limit = pinned value"

# ===========================================================================
# CASE 2 — NO pins: live enumeration must still win (CASE A compatibility;
#          the fix must not regress the data-driven default path).
# ===========================================================================
it "no-pins control: live enumeration still selected when nothing is pinned"
export CMA_HELIXAGENT_PINS_FILE="$HOME/.absent-pins-$$.json"
rm -f "$CMA_HELIXAGENT_PINS_FILE" "$PDIR/helixagent.env"
# The pins-file gate needs EITHER a pins file OR a binary: provide the stub.
mkdir -p "$HOME/.local/bin"
sandbox_stub "$HOME/.local/bin/helixagent" <<'EOF'
#!/usr/bin/env bash
echo "helixagent (test stub)"
EOF
chmod +x "$HOME/.local/bin/helixagent"
export PATH="$HOME/.local/bin:$PATH"
DET2="$(env -u CMA_HELIXAGENT_STRONG -u CMA_HELIXAGENT_FAST \
        CMA_HELIXAGENT_HOST=127.0.0.1 CMA_HELIXAGENT_PORT="$PORT" \
        CMA_HELIXAGENT_HTTP_TIMEOUT=4 \
        bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_helixagent_record')"
{
  echo "--- detect_helixagent_record output (CASE 2, no pins) ---"
  echo "$DET2"
} >> "$PROOF" 2>&1
assert_eq "$GGUF_ID" "$(jq -r '.[0].strong_model' <<<"$DET2")" \
  "with NOTHING pinned, the live-enumerated id is still selected (data-driven default preserved)"

echo >> "$PROOF"
echo "=== result: pass=$TESTS_PASSED fail=$TESTS_FAILED ===" >> "$PROOF"

summary
