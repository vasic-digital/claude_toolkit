#!/usr/bin/env bash
# test_jev_pins.sh — pins-file schema + LAN-pin behavior for Jev detection.
#
# Cases:
#   A. the SHIPPED scripts/providers/jev.json validates against the schema
#      the detector depends on (hosted.typesafe/openrouter, local_gateway,
#      lan as an array — shipped EMPTY by design)
#   B. malformed pins JSON -> detector warns, skips, exits 0 with []
#   C. a DISABLED lan entry is never probed (fixture live on its port,
#      enabled=false -> no record)
#   D. an ENABLED lan entry is probed -> jev-<id> record with
#      lan_exposed=true, priority 20
#   E. a lan entry with an invalid id (shell/JSON-hostile chars) is skipped
#      with a warning, never fabricated into a record
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=lib/proof.sh
source "$TESTS_DIR/lib/proof.sh"
PROOF_DIR="$(cma_proof_volatile_dir)"
PROOF_FINAL="$PROOF_DIR/99-jev-pins.txt"
PROOF="$(cma_proof_open "$PROOF_FINAL")"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e
# These suites drive plain-http loopback fixtures; since v1.32.0 plain http is an
# explicit opt-in (TLS is the default). test_jev_detect_https.sh covers the default.
export CMA_JEV_ALLOW_HTTP=1

PROVIDERS_SH="$SCRIPTS_DIR/claude-providers.sh"
SHIPPED_PINS="$SCRIPTS_DIR/providers/jev.json"
FIXTURE="$SCRIPTS_DIR/tests/fixtures/jev_server.py"
KEYS="$HOME/api_keys.sh"
: > "$KEYS"

FIXTURE_PORT_FILE="$HOME/.jev_fixture_port"
python3 "$FIXTURE" 0 "$FIXTURE_PORT_FILE" >/dev/null 2>&1 &
FIXTURE_PID=$!
for _ in $(seq 1 50); do [[ -s "$FIXTURE_PORT_FILE" ]] && break; sleep 0.1; done
FIXTURE_PORT="$(cat "$FIXTURE_PORT_FILE" 2>/dev/null)"
trap 'kill "$FIXTURE_PID" 2>/dev/null; cleanup_sandbox' EXIT

detect() { env "$@" bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_jev_records' 2>>"$PROOF"; }

{
  echo "=== test_jev_pins.sh evidence ==="
  echo "date: $(date -u +%FT%TZ)"
  echo "fixture port=$FIXTURE_PORT"
} >> "$PROOF" 2>&1

# ===========================================================================
# CASE A — shipped pins schema
# ===========================================================================
it "CASE A: shipped providers/jev.json matches the schema the detector consumes"
assert_jq "$SHIPPED_PINS" '.hosted.typesafe.key_var' "TYPESAFE_API_KEY" "typesafe key_var"
assert_jq "$SHIPPED_PINS" '.hosted.typesafe.base_url' "https://api.typesafe.ai" "typesafe base_url"
assert_jq "$SHIPPED_PINS" '.hosted.typesafe.enabled' "true" "typesafe enabled"
assert_jq "$SHIPPED_PINS" '.hosted.openrouter.key_var' "OPENROUTER_API_KEY" "openrouter key_var"
assert_jq "$SHIPPED_PINS" '.hosted.openrouter.base_url' "https://openrouter.ai/api" "openrouter base_url"
assert_jq "$SHIPPED_PINS" '.hosted.openrouter.systemone_path' "/v1/systemone" "openrouter systemone path"
assert_jq "$SHIPPED_PINS" '.local_gateway.host' "127.0.0.1" "local gateway host"
assert_jq "$SHIPPED_PINS" '.local_gateway.port' "8095" "local gateway port (llmctl decide gateway)"
assert_jq "$SHIPPED_PINS" '.local_gateway.health_path' "/healthz" "local gateway health path"
assert_jq "$SHIPPED_PINS" '.local_gateway.models_path' "/v1/models" "local gateway models path"
assert_jq "$SHIPPED_PINS" '.lan | type' "array" "lan is an array"
assert_jq "$SHIPPED_PINS" '.lan | length' "0" "lan ships EMPTY (user-declared entries only; example lives in docs)"

# ===========================================================================
# CASE B — malformed pins JSON -> warn + skip, never a crash
# ===========================================================================
it "CASE B: malformed pins file -> detector warns and emits [] with exit 0"
BAD_PINS="$HOME/jev-bad.json"
printf '{ this is not json ' > "$BAD_PINS"
DET_B_OUT="$(CMA_JEV_PINS_FILE="$BAD_PINS" detect)"
b_rc=$?
assert_eq 0 "$b_rc" "detector exits cleanly on malformed pins"
assert_eq "[]" "$(echo "$DET_B_OUT" | tr -d '[:space:]')" "malformed pins -> honest empty record"
DET_B_ERR="$(CMA_JEV_PINS_FILE="$BAD_PINS" bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_jev_records' 2>&1 >/dev/null)"
echo "$DET_B_ERR" | grep -qi 'warn' \
  && _pass "malformed pins produces a warning (not silent)" \
  || _fail "malformed pins produces a warning (not silent)" "stderr: $DET_B_ERR"

# ===========================================================================
# CASE C — disabled lan entry is never probed
# ===========================================================================
it "CASE C: lan entry with enabled=false -> NOT probed, no record (fixture live on its port)"
PINS_C="$HOME/jev-pins-disabled.json"
jq --argjson p "$FIXTURE_PORT" '
  .local_gateway.enabled = false
  | .hosted.typesafe.enabled = false | .hosted.openrouter.enabled = false
  | .lan = [ {"id":"lan-1","host":"127.0.0.1","port":$p,"key_var":"LAN_JEV_KEY","enabled":false} ]' \
  "$SHIPPED_PINS" > "$PINS_C"
DET_C="$(CMA_JEV_PINS_FILE="$PINS_C" detect)"
echo "--- detect output (CASE C) ---" >> "$PROOF"; echo "$DET_C" >> "$PROOF"
assert_eq "[]" "$(echo "$DET_C" | tr -d '[:space:]')" "disabled lan entry -> zero records even with a live endpoint behind it"

# ===========================================================================
# CASE D — enabled lan entry -> jev-<id> with lan_exposed=true
# ===========================================================================
it "CASE D: lan entry with enabled=true -> jev-lan-1 record, lan_exposed=true, priority 20"
PINS_D="$HOME/jev-pins-lan.json"
jq --argjson p "$FIXTURE_PORT" '
  .local_gateway.enabled = false
  | .hosted.typesafe.enabled = false | .hosted.openrouter.enabled = false
  | .lan = [ {"id":"lan-1","host":"127.0.0.1","port":$p,"key_var":"LAN_JEV_KEY","models":["jev-latest"],"enabled":true} ]' \
  "$SHIPPED_PINS" > "$PINS_D"
DET_D="$(CMA_JEV_PINS_FILE="$PINS_D" detect)"
echo "--- detect output (CASE D) ---" >> "$PROOF"; echo "$DET_D" >> "$PROOF"
assert_eq "1" "$(jq 'length' <<<"$DET_D")" "exactly one record for the one enabled lan entry"
REC_D="$(jq -c '.[0]' <<<"$DET_D")"
assert_eq "jev-lan-1" "$(jq -r '.provider_id' <<<"$REC_D")" "provider_id = jev-<id>"
assert_eq "true" "$(jq -r '.lan_exposed' <<<"$REC_D")" "lan_exposed = true (user-declared remote endpoint)"
assert_eq "20" "$(jq -r '.priority' <<<"$REC_D")" "lan priority = 20 (between local and openrouter)"
assert_eq "decision" "$(jq -r '.classification' <<<"$REC_D")" "lan record classification = decision"
assert_eq "null" "$(jq -c '.alias' <<<"$REC_D")" "lan record alias = null"
assert_eq "http://127.0.0.1:$FIXTURE_PORT" "$(jq -r '.base_url' <<<"$REC_D")" "lan record base_url = the probed host:port"
assert_eq "" "$(jq -r '.key_var' <<<"$REC_D")" "plain-http lan record carries NO key var (no consumer may send a bearer over http)"

# ===========================================================================
# CASE E — invalid lan id -> skipped with warning, never fabricated
# ===========================================================================
it "CASE E: lan entry whose id has hostile characters -> skipped, warned, other entries unaffected"
PINS_E="$HOME/jev-pins-badid.json"
jq --argjson p "$FIXTURE_PORT" '
  .local_gateway.enabled = false
  | .hosted.typesafe.enabled = false | .hosted.openrouter.enabled = false
  | .lan = [ {"id":"bad;rm -rf","host":"127.0.0.1","port":$p,"enabled":true},
             {"id":"good","host":"127.0.0.1","port":$p,"enabled":true} ]' \
  "$SHIPPED_PINS" > "$PINS_E"
DET_E="$(CMA_JEV_PINS_FILE="$PINS_E" detect)"
echo "--- detect output (CASE E) ---" >> "$PROOF"; echo "$DET_E" >> "$PROOF"
assert_eq "1" "$(jq 'length' <<<"$DET_E")" "only the valid lan entry produces a record"
assert_eq "jev-good" "$(jq -r '.[0].provider_id' <<<"$DET_E")" "the surviving record is the valid one"
_n_badid="$(jq '[.[] | select(.provider_id | test("bad"))] | length' <<<"$DET_E")"
assert_eq "0" "$_n_badid" "the hostile id never reaches a provider_id"

cma_proof_commit "$PROOF" "$PROOF_FINAL"
summary
