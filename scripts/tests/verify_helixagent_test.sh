#!/usr/bin/env bash
# verify_helixagent_test.sh — hermetic test for the HelixAgent PATH-detection
# provider (detect_helixagent_record + resolve_records merge in
# claude-providers.sh).
#
# Fully self-contained: a sandboxed $HOME (make_sandbox), a FAKE `helixagent`
# binary placed on PATH, and a REAL local HTTP server answering `/v1/models`
# with an OpenAI-shaped model list. It then runs `claude-providers.sh sync`
# offline+no-verify and asserts the HelixAgent alias + <id>.env + resolved
# record were created with transport=router and the LIVE-enumerated models —
# real captured evidence (§11.4.69), not a mock that proves nothing.
#
# Four groups prove the honest behaviour of the detector + resolver merge:
#   A. binary on PATH + server up  -> alias/env/record with live models
#   B. binary NOT on PATH          -> NO helixagent alias/env (PATH gate)
#   C. binary on PATH + server DOWN -> alias/env STILL created off the pins,
#                                      honest 'unverified' (installed-not-running)
#   D. resolve_records loud-fail guards (the C1 fix): a resolver that exits
#      nonzero (D1) OR exits 0 but prints a non-array (D2) MUST make
#      resolve_records cma_die loudly and emit NO provider set — never silently
#      drop the real providers down to a HelixAgent-only/empty list.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
PROOF_DIR="$TESTS_DIR/proof"
mkdir -p "$PROOF_DIR"
PROOF="$PROOF_DIR/82-helixagent-detect.txt"
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

# The detector now loads facade pins from a git-tracked providers/helixagent.json
# ($LIB_DIR/providers/helixagent.json) when present (Variant B). $LIB_DIR is the
# REAL repo scripts dir (NOT this sandboxed $HOME), so the repo pins-file would
# leak its repo-pin values (base 127.0.0.1:7061, strong/fast HelixAgent/HelixLLM,
# ctx 24576) into CASES A/B/C which assert the BUILT-IN defaults. Point the
# pins-file path at an ABSENT sandbox file so the default-relying cases exercise
# the built-in defaults + env exactly as before. The pins-file OPT-IN path is
# proven independently by CASE E below.
export CMA_HELIXAGENT_PINS_FILE="$HOME/.no-helix-pins-$$.json"
[[ -e "$CMA_HELIXAGENT_PINS_FILE" ]] && rm -f "$CMA_HELIXAGENT_PINS_FILE"

# Empty models.dev catalog: HelixAgent is a LOCAL provider, never in the
# catalog. The resolver will emit only an 'unmapped' record for the key var;
# the detector supplies the real resolved HelixAgent record.
echo '{}' > "$PCACHE"

# Keys file with the HelixAgent key-var NAME (value is a dummy, never launched).
KEYS="$HOME/api_keys.sh"
cat > "$KEYS" <<'SH'
export HELIXAGENT_API_KEY="dummy-helix-key-never-real"
SH

# --- REAL local /v1/models server (ephemeral port) --------------------------
# The mock's ids are DELIBERATELY DIFFERENT from the CMA_HELIXAGENT_STRONG/FAST
# *configured pins* ("helix-debate"/"helix-llm", see detect_helixagent_record's
# defaults in claude-providers.sh). If the mock returned the SAME strings as
# the defaults, CASE A ("live fetch happened") and CASE C ("server down, honest
# fallback to the configured pins") would assert the identical values and the
# test could not tell a genuine live fetch from a fetch that silently never
# happened — the exact gap this distinct-id fixture closes.
PORT_FILE="$HOME/.helix_srv_port"
python3 - "$PORT_FILE" >/dev/null 2>&1 <<'PY' &
import http.server, socketserver, sys, json
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.rstrip('/').endswith('/models'):
            body = json.dumps({"object": "list", "data": [
                {"id": "helix-live-strong", "object": "model"},
                {"id": "helix-live-fast",   "object": "model"},
            ]}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()
    def log_message(self, *a):  # silence
        pass
srv = socketserver.TCPServer(('127.0.0.1', 0), H)
open(sys.argv[1], 'w').write(str(srv.server_address[1]))
srv.serve_forever()
PY
SRV_PID=$!

# --- SECOND local server: REQUIRES `Authorization: Bearer <token>` ----------
# Proves the `--config -` stdin-auth branch of detect_helixagent_record
# actually authenticates (a broken/regressed auth branch would 401 and the
# function would honestly fall back to the configured pins instead of these
# distinct auth-only ids — see CASE A2 below).
AUTH_TOKEN="test-secret-token-$$-$(date +%s 2>/dev/null || echo 0)"
AUTH_PORT_FILE="$HOME/.helix_auth_srv_port"
python3 - "$AUTH_PORT_FILE" "$AUTH_TOKEN" >/dev/null 2>&1 <<'PY' &
import http.server, socketserver, sys, json
expected_auth = 'Bearer ' + sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.rstrip('/').endswith('/models'):
            if self.headers.get('Authorization', '') != expected_auth:
                self.send_response(401); self.end_headers()
                return
            body = json.dumps({"object": "list", "data": [
                {"id": "helix-auth-strong", "object": "model"},
                {"id": "helix-auth-fast",   "object": "model"},
            ]}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()
    def log_message(self, *a):  # silence
        pass
srv = socketserver.TCPServer(('127.0.0.1', 0), H)
open(sys.argv[1], 'w').write(str(srv.server_address[1]))
srv.serve_forever()
PY
AUTH_SRV_PID=$!

# Ensure both servers are always reaped even if the sandbox trap fires first.
trap '[[ -n "${SRV_PID:-}" ]] && kill "$SRV_PID" 2>/dev/null; [[ -n "${AUTH_SRV_PID:-}" ]] && kill "$AUTH_SRV_PID" 2>/dev/null; cleanup_sandbox' EXIT

for _ in $(seq 1 50); do [[ -s "$PORT_FILE" ]] && break; sleep 0.1; done
PORT="$(cat "$PORT_FILE" 2>/dev/null)"
for _ in $(seq 1 50); do [[ -s "$AUTH_PORT_FILE" ]] && break; sleep 0.1; done
AUTH_PORT="$(cat "$AUTH_PORT_FILE" 2>/dev/null)"

# --- fake helixagent binary on PATH -----------------------------------------
mkdir -p "$HOME/.local/bin"
sandbox_stub "$HOME/.local/bin/helixagent" <<'EOF'
#!/usr/bin/env bash
# fake helixagent stub — only needs to exist for `command -v`.
echo "helixagent (test stub)"
EOF
chmod +x "$HOME/.local/bin/helixagent"
export PATH="$HOME/.local/bin:$PATH"

# Point the detector at the real local server (all knobs are env-overridable).
export CMA_HELIXAGENT_HOST=127.0.0.1
export CMA_HELIXAGENT_PORT="$PORT"
export CMA_HELIXAGENT_KEYVAR=HELIXAGENT_API_KEY

{
  echo "=== verify_helixagent_test.sh evidence ==="
  echo "date: $(date -u +%FT%TZ)"
  echo "server port: $PORT   pid: $SRV_PID"
  echo "PATH helixagent: $(command -v helixagent)"
  echo "--- live GET http://127.0.0.1:$PORT/v1/models ---"
  curl -s --max-time 8 "http://127.0.0.1:$PORT/v1/models"
  echo
} >> "$PROOF" 2>&1

# ===========================================================================
# CASE A — binary on PATH + server up
# ===========================================================================
it "CASE A: sync with helixagent on PATH + live server"
bash "$PROVIDERS_SH" sync --offline --no-verify --keys-file "$KEYS" \
  >>"$PROOF" 2>&1
a_rc=$?
assert_eq 0 "$a_rc" "sync exits cleanly"

assert_file "$PDIR/helixagent.env" "helixagent env file created (PATH-detected)"

it "CASE A: env file carries router transport + live base_url + enumerated models"
grep -qE "^CMA_PROVIDER_TRANSPORT='?router'?" "$PDIR/helixagent.env"
assert_eq 0 $? "transport=router (OpenAI-compat -> ccr)"
grep -qF "http://127.0.0.1:$PORT/v1" "$PDIR/helixagent.env"
assert_eq 0 $? "base_url = live endpoint"
# These ids ("helix-live-strong"/"helix-live-fast") come ONLY from the mock
# server's /v1/models response and are DELIBERATELY DIFFERENT from the
# CMA_HELIXAGENT_STRONG/FAST configured pins ("helix-debate"/"helix-llm") — a
# match here can ONLY happen if the live fetch genuinely occurred; a broken
# fetch would (per CASE C below) fall back to the pins instead.
grep -qE "^CMA_PROVIDER_MODEL='?helix-live-strong'?" "$PDIR/helixagent.env"
assert_eq 0 $? "strong model = helix-live-strong (proves a REAL live /v1/models fetch, not the configured pin)"
grep -qE "^CMA_PROVIDER_FAST_MODEL='?helix-live-fast'?" "$PDIR/helixagent.env"
assert_eq 0 $? "fast model = helix-live-fast (proves a REAL live /v1/models fetch, not the configured pin)"
grep -qE "^CMA_PROVIDER_KEYVAR='?HELIXAGENT_API_KEY'?" "$PDIR/helixagent.env"
assert_eq 0 $? "key-var NAME recorded (secret never stored)"

it "CASE A: live-fetched models genuinely differ from the configured fallback pins"
assert_file_not_contains "$PDIR/helixagent.env" "CMA_PROVIDER_MODEL='helix-debate'" \
  "strong model is NOT the fallback pin (would indicate the live fetch silently never happened)"
assert_file_not_contains "$PDIR/helixagent.env" "CMA_PROVIDER_FAST_MODEL='helix-llm'" \
  "fast model is NOT the fallback pin (would indicate the live fetch silently never happened)"

it "CASE A: NO secret value leaked into the env file"
assert_file_not_contains "$PDIR/helixagent.env" "dummy-helix-key-never-real" \
  "secret value absent from helixagent.env"

it "CASE A: shell alias registered -> cma_run_provider helixagent"
grep -q '^alias helixagent="cma_run_provider helixagent"' "$ALIAS_FILE"
assert_eq 0 $? "helixagent alias line present"

it "CASE A: verification status persisted (unverified under --no-verify)"
assert_eq "unverified" "$(cma_status_read helixagent)" "helixagent status persisted"

it "CASE A: exactly ONE helixagent.env (no duplicate registration)"
n_env="$(ls "$PDIR"/helixagent.env 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "1" "$n_env" "exactly one helixagent.env"

it "CASE A: detector emits a well-formed resolved record with live models"
# The module is source-guarded, so sourcing loads the functions without running
# dispatch — we can call detect_helixagent_record directly and assert its JSON.
DET="$(CMA_HELIXAGENT_HOST=127.0.0.1 CMA_HELIXAGENT_PORT="$PORT" \
       CMA_HELIXAGENT_KEYVAR=HELIXAGENT_API_KEY \
       bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_helixagent_record')"
echo "--- detect_helixagent_record output (CASE A) ---" >> "$PROOF"
echo "$DET" >> "$PROOF"
assert_eq "resolved"          "$(jq -r '.[0].status'        <<<"$DET")" "record status=resolved"
assert_eq "helixagent"        "$(jq -r '.[0].provider_id'   <<<"$DET")" "provider_id=helixagent"
assert_eq "router"            "$(jq -r '.[0].transport'     <<<"$DET")" "transport=router"
# Live-mock ids, NOT the configured pins -> proves this ran a genuine fetch.
assert_eq "helix-live-strong" "$(jq -r '.[0].strong_model'  <<<"$DET")" "strong=helix-live-strong (live fetch, not fallback pin helix-debate)"
assert_eq "helix-live-fast"   "$(jq -r '.[0].fast_model'    <<<"$DET")" "fast=helix-live-fast (live fetch, not fallback pin helix-llm)"
assert_eq "128000"            "$(jq -r '.[0].context_limit' <<<"$DET")" "context_limit=128000"

# ===========================================================================
# CASE A2 — auth curl-config (`--config -` stdin) path: the Authorization
# header is actually built + actually reaches the server, and the secret is
# never placed on curl's argv (so it never appears in `ps`/`/proc/*/cmdline`).
# ===========================================================================
it "CASE A2: key-var exported -> Authorization: Bearer <token> reaches the auth-gated server"
DET_AUTH_OK="$(env -u HELIXAGENT_API_KEY CMA_HELIXAGENT_HOST=127.0.0.1 \
       CMA_HELIXAGENT_PORT="$AUTH_PORT" CMA_HELIXAGENT_KEYVAR=HELIXAGENT_API_KEY \
       HELIXAGENT_API_KEY="$AUTH_TOKEN" \
       bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_helixagent_record')"
echo "--- detect_helixagent_record output (CASE A2, authed) ---" >> "$PROOF"
echo "$DET_AUTH_OK" >> "$PROOF"
assert_eq "helix-auth-strong" "$(jq -r '.[0].strong_model' <<<"$DET_AUTH_OK")" \
  "authed request reaches the Authorization-gated mock (strong) -- proves --config - stdin auth actually authenticates"
assert_eq "helix-auth-fast"   "$(jq -r '.[0].fast_model'   <<<"$DET_AUTH_OK")" \
  "authed request reaches the Authorization-gated mock (fast) -- proves --config - stdin auth actually authenticates"

it "CASE A2: WITHOUT the key exported, the same auth-gated server 401s -> honest fallback to the configured pins"
DET_AUTH_NOKEY="$(env -u HELIXAGENT_API_KEY CMA_HELIXAGENT_HOST=127.0.0.1 \
       CMA_HELIXAGENT_PORT="$AUTH_PORT" CMA_HELIXAGENT_KEYVAR=HELIXAGENT_API_KEY \
       bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_helixagent_record')"
echo "--- detect_helixagent_record output (CASE A2, no key -> 401) ---" >> "$PROOF"
echo "$DET_AUTH_NOKEY" >> "$PROOF"
assert_eq "helix-debate" "$(jq -r '.[0].strong_model' <<<"$DET_AUTH_NOKEY")" \
  "no key -> 401 -> honest fallback to the configured strong pin (never a bluffed live value)"
assert_eq "helix-llm"    "$(jq -r '.[0].fast_model'   <<<"$DET_AUTH_NOKEY")" \
  "no key -> 401 -> honest fallback to the configured fast pin (never a bluffed live value)"

it "CASE A2: static check — the authed branch pipes the header via curl --config - (stdin), never -H on argv"
grep -qE -- '--config[[:space:]]+-' "$SCRIPTS_DIR/claude-providers.sh"
assert_eq 0 $? "curl --config - (stdin) present -- the mechanism that keeps the secret off argv"
_leak_hits=0
grep -nE -- '-H[[:space:]]+"?Authorization: Bearer' "$SCRIPTS_DIR/claude-providers.sh" >/dev/null 2>&1 && _leak_hits=1
assert_eq 0 "$_leak_hits" "no direct curl -H \"Authorization: Bearer \$key\" on argv anywhere in the script (would leak the secret via ps/proc)"

# ===========================================================================
# CASE B — binary NOT on PATH -> PATH gate blocks registration
# ===========================================================================
it "CASE B: no helixagent binary on PATH -> detector emits empty array"
DET_B="$(CMA_HELIXAGENT_BIN=helixagent-not-installed-xyz \
         bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_helixagent_record')"
assert_eq "[]" "$(echo "$DET_B" | tr -d '[:space:]')" "empty record when binary absent"

it "CASE B: a fresh sandbox with NO helixagent gets NO helixagent alias"
# Remove the fake binary + prior artefacts, re-sync, assert nothing registered.
rm -f "$HOME/.local/bin/helixagent" "$PDIR/helixagent.env"
bash "$PROVIDERS_SH" sync --offline --no-verify --keys-file "$KEYS" >>"$PROOF" 2>&1
[[ ! -f "$PDIR/helixagent.env" ]]; assert_eq 0 $? "no helixagent.env when binary off PATH"

# ===========================================================================
# CASE C — binary on PATH but server DOWN -> honest installed-not-running
# ===========================================================================
it "CASE C: helixagent present but server down -> alias STILL created off pins"
# Restore the binary, kill the server (simulate 'installed but not running').
sandbox_stub "$HOME/.local/bin/helixagent" <<'EOF'
#!/usr/bin/env bash
echo "helixagent (test stub)"
EOF
chmod +x "$HOME/.local/bin/helixagent"
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""
# Point at a dead port so /v1/models is genuinely unreachable.
export CMA_HELIXAGENT_PORT=1   # port 1 is not listening
export CMA_HELIXAGENT_HTTP_TIMEOUT=2
bash "$PROVIDERS_SH" sync --offline --no-verify --keys-file "$KEYS" >>"$PROOF" 2>&1
assert_file "$PDIR/helixagent.env" "helixagent.env created even with server down"
grep -qE "^CMA_PROVIDER_MODEL='?helix-debate'?" "$PDIR/helixagent.env"
assert_eq 0 $? "strong model falls back to configured pin (helix-debate)"
grep -qE "^CMA_PROVIDER_FAST_MODEL='?helix-llm'?" "$PDIR/helixagent.env"
assert_eq 0 $? "fast model falls back to configured pin (helix-llm)"
assert_eq "unverified" "$(cma_status_read helixagent)" "honest unverified when unreachable"

# ===========================================================================
# CASE D — resolve_records loud-fail guards (§11.4.115 RED-polarity regression
# guard for the C1 fix: "die loudly instead of silently dropping providers").
# Two sub-cases, each isolating ONE of the two loud-fail guards so that
# neutering that guard alone flips this board RED (the silent-regression hole
# the C1 Critical closed — previously reintroducible with a green board):
#   D1. resolver EXITS NONZERO (but prints a valid []) -> only the
#       `if (( rc != 0 ))` guard can catch it (the array check passes on []).
#   D2. resolver EXITS 0 but prints a NON-ARRAY ({})   -> only the
#       `jq -e 'type=="array"'` validation guard can catch it.
# resolve_records is driven through the SAME `records="$(resolve_records)"`
# command-substitution context cmd_sync/cmd_sync_multi use — the documented
# nested-command-substitution errexit quirk is exactly why the explicit guards
# exist, so a direct call would bypass them and misrepresent production. The
# fake helixagent binary is deliberately ABSENT here (detect_helixagent_record
# returns []) so a neutered guard would emit an empty/HelixAgent-only set — the
# real silent drop — proving the guards, not the detector, are under test.
# Real invocation + captured stdout/stderr/exit — no metadata-only assertion.
# ===========================================================================
D_OUT="$HOME/case_d.out"; D_ERR="$HOME/case_d.err"

# RED fixture D1: emit a VALID empty array yet EXIT NONZERO. Only the
# `if (( rc != 0 ))` guard stands between this and a silent merge.
STUB_FAIL="$HOME/stub_resolver_fail.py"
cat > "$STUB_FAIL" <<'PY'
import sys
print("[]")        # valid JSON array -> array-validation guard would PASS
sys.exit(7)        # ...but nonzero exit MUST be caught by the rc!=0 guard
PY

# RED fixture D2: EXIT 0 but print a NON-ARRAY ({}). Only the
# `jq -e 'type=="array"'` validation guard can catch this.
STUB_NONARRAY="$HOME/stub_resolver_nonarray.py"
cat > "$STUB_NONARRAY" <<'PY'
print("{}")        # exit 0, but not an array -> validation guard MUST fire
PY

# Drive resolve_records through cmd_sync's command-substitution context with a
# stubbed RESOLVER; echo the real exit code, leaving stdout/stderr in files.
_run_resolve() {   # $1 = stub resolver path
  CMA_KEYS_FILE="$KEYS" CMA_HELIXAGENT_BIN=helixagent-absent-xyz \
    bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1
             RESOLVER="'"$1"'"
             records="$(resolve_records)"
             printf "%s" "$records"' >"$D_OUT" 2>"$D_ERR"
  echo $?
}

it "CASE D1: resolver EXITS NONZERO -> resolve_records dies loudly, drops nothing"
d_rc="$(_run_resolve "$STUB_FAIL")"
{
  echo "--- CASE D1 (resolver prints [] then exit 7) rc=$d_rc ---"
  echo "STDOUT=[$(cat "$D_OUT")]"
  echo "STDERR=[$(cat "$D_ERR")]"
} >> "$PROOF"
[[ "$d_rc" -ne 0 ]]; assert_eq 0 $? "resolve_records exits nonzero when the resolver crashes (loud-fail, not silent drop)"
assert_file_contains "$D_ERR" "providers_resolve.py failed (exit" "cma_die fired with the resolver-crash message"
[[ ! -s "$D_OUT" ]]; assert_eq 0 $? "NO provider set emitted on stdout (no partial / HelixAgent-only silent drop)"

it "CASE D2: resolver EXITS 0 but prints a NON-ARRAY -> resolve_records dies loudly"
d_rc="$(_run_resolve "$STUB_NONARRAY")"
{
  echo "--- CASE D2 (resolver prints {} exit 0) rc=$d_rc ---"
  echo "STDOUT=[$(cat "$D_OUT")]"
  echo "STDERR=[$(cat "$D_ERR")]"
} >> "$PROOF"
[[ "$d_rc" -ne 0 ]]; assert_eq 0 $? "resolve_records exits nonzero when the resolver prints non-array JSON (loud-fail)"
assert_file_contains "$D_ERR" "produced no/invalid JSON output" "cma_die fired with the invalid-JSON message"
[[ ! -s "$D_OUT" ]]; assert_eq 0 $? "NO provider set emitted on stdout (no silent drop of all real providers)"

# ===========================================================================
# CASE E — git-tracked pins-file OPT-IN (Variant B facade). The facade registers
# off providers/helixagent.json even with NO helixagent binary on PATH (gate
# relax), the pins OVERRIDE the built-in defaults, and process-env still WINS
# over the pins (precedence env > pins-file > built-in default). Uses a DEAD
# base_url so the model GET fails and the record honestly falls back to the
# pins' strong/fast — no live server, fully hermetic.
# ===========================================================================
it "CASE E: pins-file present + binary ABSENT -> detector fires off the pins (no stub binary)"
PINS_E="$HOME/helixagent.pins.json"
cat > "$PINS_E" <<'JSON'
{ "bin":"helixagent", "id":"helixagent",
  "base_url":"http://127.0.0.1:1/v1", "transport":"router",
  "strong_model":"HelixAgent/HelixLLM", "fast_model":"HelixAgent/HelixLLM",
  "key_var":"HELIXAGENT_GATEWAY_KEY", "context_limit":24576, "max_output":8192 }
JSON
DET_E="$(env -u CMA_HELIXAGENT_HOST -u CMA_HELIXAGENT_PORT -u CMA_HELIXAGENT_KEYVAR \
     CMA_HELIXAGENT_PINS_FILE="$PINS_E" CMA_HELIXAGENT_BIN=helixagent-absent-xyz \
     CMA_HELIXAGENT_HTTP_TIMEOUT=2 \
     bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_helixagent_record')"
echo "--- detect_helixagent_record output (CASE E, pins opt-in, no binary) ---" >> "$PROOF"
echo "$DET_E" >> "$PROOF"
assert_eq "1" "$(jq 'length' <<<"$DET_E")" "detector emits ONE record off the pins-file with NO binary on PATH (gate relax)"
assert_eq "router"              "$(jq -r '.[0].transport'     <<<"$DET_E")" "transport from pins = router"
assert_eq "HelixAgent/HelixLLM" "$(jq -r '.[0].strong_model'  <<<"$DET_E")" "strong from pins = HelixAgent/HelixLLM (dead endpoint -> honest fallback to the pin)"
assert_eq "HelixAgent/HelixLLM" "$(jq -r '.[0].fast_model'    <<<"$DET_E")" "fast from pins = HelixAgent/HelixLLM"
assert_eq "http://127.0.0.1:1/v1" "$(jq -r '.[0].base_url'    <<<"$DET_E")" "base_url from pins (overrides the built-in 127.0.0.1:7061 default)"
assert_eq "HELIXAGENT_GATEWAY_KEY" "$(jq -r '.[0].key_var'    <<<"$DET_E")" "key_var from pins = HELIXAGENT_GATEWAY_KEY"
assert_eq "24576"               "$(jq -r '.[0].context_limit' <<<"$DET_E")" "context_limit from pins = 24576 (overrides built-in 128000)"

it "CASE E: process-env WINS over the pins-file (precedence env > pins > default)"
DET_E2="$(env -u CMA_HELIXAGENT_HOST -u CMA_HELIXAGENT_PORT -u CMA_HELIXAGENT_KEYVAR \
     CMA_HELIXAGENT_PINS_FILE="$PINS_E" CMA_HELIXAGENT_BIN=helixagent-absent-xyz \
     CMA_HELIXAGENT_HTTP_TIMEOUT=2 CMA_HELIXAGENT_STRONG=env-wins-strong \
     bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_helixagent_record')"
assert_eq "env-wins-strong" "$(jq -r '.[0].strong_model' <<<"$DET_E2")" "env CMA_HELIXAGENT_STRONG overrides the pins-file strong_model"

it "CASE E: NO pins-file AND NO binary -> detector emits empty (gate still honest)"
DET_E3="$(env -u CMA_HELIXAGENT_HOST -u CMA_HELIXAGENT_PORT -u CMA_HELIXAGENT_KEYVAR \
     CMA_HELIXAGENT_PINS_FILE="$HOME/.absent-pins-xyz.json" CMA_HELIXAGENT_BIN=helixagent-absent-xyz \
     bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_helixagent_record')"
assert_eq "[]" "$(echo "$DET_E3" | tr -d '[:space:]')" "no pins-file + no binary -> empty record (opt-in preserved)"

echo >> "$PROOF"
echo "=== helixagent.env (final) ===" >> "$PROOF"
cat "$PDIR/helixagent.env" >> "$PROOF" 2>&1

summary
