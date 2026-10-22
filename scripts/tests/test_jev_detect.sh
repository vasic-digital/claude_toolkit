#!/usr/bin/env bash
# test_jev_detect.sh — hermetic test for the Jev decision-layer detector
# (detect_jev_records + `sync-jev` + ranked endpoint cache in
# claude-providers.sh). Clones the structure of test_llmctl_detect.sh.
#
# Jev endpoints are DECISION models, not chat models: every record must carry
# classification "decision" and an explicit `"alias": null`, and the detector
# discovers four sub-sources: (a) TypeSafe hosted (key-var presence, NO live
# call by default), (b) OpenRouter (same), (c) the local llmctl decide
# gateway (live /healthz + /v1/models probes), (d) user-declared LAN pins.
#
# Fully self-contained: a sandboxed $HOME (make_sandbox), REAL local HTTP
# fixtures (scripts/tests/fixtures/jev_server.py) on ephemeral ports, pins
# files via the CMA_JEV_PINS_FILE seam. No mocked curl/jq internals — every
# assertion is against genuine process output.
#
# Cases:
#   A. nothing configured anywhere                    -> detector emits []
#   B. local gateway fixture live (pins point at it)  -> jev-local record:
#      classification=decision, alias=null, real probed model id, priority 10
#   C. hosted key vars present, no gateway            -> jev-typesafe +
#      jev-openrouter records from key-var PRESENCE alone (no network)
#   D. full set -> sync-jev ranks local > openrouter > typesafe in
#      jev-endpoints.json; CMA_JEV_PREFER reorders
#   E. fixture down -> jev-local record absent (auto-disappear, like llmctl)
#   F. slow fixture (CMA_JEV_FIXTURE_DELAY) + 1s CMA_JEV_HTTP_TIMEOUT ->
#      jev-local absent AND the whole probe stays time-bounded
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=lib/proof.sh
source "$TESTS_DIR/lib/proof.sh"
PROOF_DIR="$(cma_proof_volatile_dir)"
PROOF_FINAL="$PROOF_DIR/99-jev-detect.txt"
PROOF="$(cma_proof_open "$PROOF_FINAL")"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e   # lib.sh sets -e; the harness asserts on failures, so relax it.
# These suites drive plain-http loopback fixtures; since v1.32.0 plain http is an
# explicit opt-in (TLS is the default). test_jev_detect_https.sh covers the default.
export CMA_JEV_ALLOW_HTTP=1

PROVIDERS_SH="$SCRIPTS_DIR/claude-providers.sh"
FIXTURE="$SCRIPTS_DIR/tests/fixtures/jev_server.py"
PDIR="$HOME/.local/share/claude-multi-account/providers"
mkdir -p "$PDIR"
KEYS="$HOME/api_keys.sh"
: > "$KEYS"

# --- REAL local fixture (ephemeral port) -------------------------------------
FIXTURE_PORT_FILE="$HOME/.jev_fixture_port"
python3 "$FIXTURE" 0 "$FIXTURE_PORT_FILE" >/dev/null 2>&1 &
FIXTURE_PID=$!
for _ in $(seq 1 50); do [[ -s "$FIXTURE_PORT_FILE" ]] && break; sleep 0.1; done
FIXTURE_PORT="$(cat "$FIXTURE_PORT_FILE" 2>/dev/null)"

# A second fixture with artificial latency for the timeout case.
SLOW_PORT_FILE="$HOME/.jev_slow_port"
CMA_JEV_FIXTURE_DELAY=4 python3 "$FIXTURE" 0 "$SLOW_PORT_FILE" >/dev/null 2>&1 &
SLOW_PID=$!
for _ in $(seq 1 50); do [[ -s "$SLOW_PORT_FILE" ]] && break; sleep 0.1; done
SLOW_PORT="$(cat "$SLOW_PORT_FILE" 2>/dev/null)"

reap() { kill "$FIXTURE_PID" "$SLOW_PID" 2>/dev/null; cleanup_sandbox; }
trap reap EXIT

# Pins seam: point the local gateway at the fixture; ship a disabled LAN
# entry (covered for real in test_jev_pins.sh) and keep hosted sources on
# their real pinned URLs (never probed — presence-only by default).
PINS="$HOME/jev-pins.json"
jq --argjson p "$FIXTURE_PORT" --argjson sp "$SLOW_PORT" '
  .local_gateway.port = $p
  | .lan = [ {"id":"lan-1","host":"127.0.0.1","port":$sp,"enabled":false} ]' \
  "$SCRIPTS_DIR/providers/jev.json" > "$PINS"
export CMA_JEV_PINS_FILE="$PINS"

detect() { # extra env passed by caller via env(1)
  env "$@" bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_jev_records'
}

{
  echo "=== test_jev_detect.sh evidence ==="
  echo "date: $(date -u +%FT%TZ)"
  echo "fixture port=$FIXTURE_PORT pid=$FIXTURE_PID"
  echo "slow fixture port=$SLOW_PORT pid=$SLOW_PID (delay 4s)"
  echo "pins: $PINS"
} >> "$PROOF" 2>&1

# ===========================================================================
# CASE A — nothing configured: no keys, gateway absent (pins file names a
# dead port) -> honest []
# ===========================================================================
it "CASE A: no key vars, gateway port dead -> detector emits []"
DET_A="$(CMA_JEV_PINS_FILE=<(jq '.local_gateway.port=1' "$PINS") detect)"
echo "--- detect_jev_records output (CASE A) ---" >> "$PROOF"; echo "$DET_A" >> "$PROOF"
assert_eq "[]" "$(echo "$DET_A" | tr -d '[:space:]')" "nothing configured -> empty record, no crash"

# ===========================================================================
# CASE B — local gateway fixture live -> jev-local record, correct shape
# ===========================================================================
it "CASE B: local gateway fixture live -> one jev-local decision record"
DET_B="$(detect)"
echo "--- detect_jev_records output (CASE B) ---" >> "$PROOF"; echo "$DET_B" >> "$PROOF"
REC_B="$(jq -c '[.[] | select(.provider_id=="jev-local")] | .[0] // "absent"' <<<"$DET_B")"
[[ "$REC_B" == "absent" ]] && { _fail "jev-local record present" "records: $DET_B"; REC_B='{}'; }
assert_eq "decision" "$(jq -r '.classification // "?"' <<<"$REC_B")" "classification = decision (NEVER llm)"
assert_eq "null" "$(jq -c '.alias' <<<"$REC_B")" "alias = null (explicit non-launchable marker)"
assert_eq "http://127.0.0.1:$FIXTURE_PORT" "$(jq -r '.base_url // "?"' <<<"$REC_B")" "base_url = the REAL probed fixture port"
assert_eq "jev-fixture-1" "$(jq -r '.strong_model // "?"' <<<"$REC_B")" "strong_model = the REAL model id the fixture /v1/models reported"
assert_eq "systemone" "$(jq -r '.transport // "?"' <<<"$REC_B")" "transport = systemone"
assert_eq "10" "$(jq -r '.priority // "?"' <<<"$REC_B")" "priority = 10 (local wins by default)"
assert_eq "resolved" "$(jq -r '.status // "?"' <<<"$REC_B")" "status = resolved"
# NOTE: `.lan_exposed // "?"` would misreport — jq's // treats `false` as
# empty. `| tostring` is the honest read of a boolean field.
assert_eq "false" "$(jq -r '.lan_exposed | tostring' <<<"$REC_B")" "lan_exposed = false for loopback gateway"

# ===========================================================================
# CASE C — hosted key vars present (gateway dead) -> presence-only records
# ===========================================================================
it "CASE C: TYPESAFE_API_KEY + OPENROUTER_API_KEY in keys file -> hosted decision records (no live call)"
cat > "$KEYS" <<'SH'
export TYPESAFE_API_KEY="dummy-ts-secret"
export OPENROUTER_API_KEY="dummy-or-secret"
SH
DET_C="$(CMA_JEV_PINS_FILE=<(jq '.local_gateway.port=1' "$PINS") detect)"
echo "--- detect_jev_records output (CASE C) ---" >> "$PROOF"; echo "$DET_C" >> "$PROOF"
assert_eq "2" "$(jq 'length' <<<"$DET_C")" "exactly two records (hosted presence-only; gateway dead)"
TS_REC="$(jq -c '[.[] | select(.provider_id=="jev-typesafe")] | .[0]' <<<"$DET_C")"
OR_REC="$(jq -c '[.[] | select(.provider_id=="jev-openrouter")] | .[0]' <<<"$DET_C")"
assert_eq "https://api.typesafe.ai" "$(jq -r '.base_url' <<<"$TS_REC")" "typesafe base_url from pins"
assert_eq "jev-latest" "$(jq -r '.strong_model' <<<"$TS_REC")" "typesafe default model = jev-latest"
assert_eq "40" "$(jq -r '.priority' <<<"$TS_REC")" "typesafe priority = 40 (last by default)"
assert_eq "TYPESAFE_API_KEY" "$(jq -r '.key_var' <<<"$TS_REC")" "typesafe record carries the key var NAME only"
assert_eq "https://openrouter.ai/api" "$(jq -r '.base_url' <<<"$OR_REC")" "openrouter base_url from pins"
assert_eq "typesafe/jev-1.13" "$(jq -r '.strong_model' <<<"$OR_REC")" "openrouter default model = typesafe/jev-1.13"
assert_eq "30" "$(jq -r '.priority' <<<"$OR_REC")" "openrouter priority = 30"
# Presence-only means presence-only: a declared-but-EMPTY key must not emit.
printf 'export EMPTY_JEV_KEY=\n' >> "$KEYS"
DET_C2="$(CMA_JEV_PINS_FILE=<(jq '.local_gateway.port=1 | .hosted.typesafe.key_var="EMPTY_JEV_KEY" | .hosted.openrouter.enabled=false' "$PINS") detect)"
assert_eq "0" "$(jq '[.[] | select(.provider_id=="jev-typesafe")] | length' <<<"$DET_C2")" \
  "declared-but-empty key var emits NO record (same rule as every other provider)"

# ===========================================================================
# CASE D — full set -> sync-jev ranks local > openrouter > typesafe in the
# endpoint cache; CMA_JEV_PREFER reorders.
# ===========================================================================
it "CASE D: sync-jev writes the ranked endpoint cache (local > openrouter > typesafe)"
cat > "$KEYS" <<'SH'
export TYPESAFE_API_KEY="dummy-ts-secret"
export OPENROUTER_API_KEY="dummy-or-secret"
SH
CACHE="$PDIR/jev-endpoints.json"
rm -f "$CACHE"
bash "$PROVIDERS_SH" sync-jev --quiet >/dev/null 2>&1
assert_file "$CACHE" "sync-jev writes jev-endpoints.json"
ORDER_D="$(jq -r '.endpoints[].provider_id' "$CACHE" | paste -sd, -)"
echo "--- endpoint cache (CASE D) ---" >> "$PROOF"; cat "$CACHE" >> "$PROOF"
assert_eq "jev-local,jev-openrouter,jev-typesafe" "$ORDER_D" "default ranking: local > openrouter > typesafe"

it "CASE D2: CMA_JEV_PREFER promotes the listed ids to the front, in listed order"
CMA_JEV_PREFER="jev-typesafe,jev-openrouter" bash "$PROVIDERS_SH" sync-jev --quiet >/dev/null 2>&1
ORDER_D2="$(jq -r '.endpoints[].provider_id' "$CACHE" | paste -sd, -)"
echo "--- endpoint cache (CASE D2, CMA_JEV_PREFER=jev-typesafe,jev-openrouter) ---" >> "$PROOF"; cat "$CACHE" >> "$PROOF"
assert_eq "jev-typesafe,jev-openrouter,jev-local" "$ORDER_D2" "CMA_JEV_PREFER reorders exactly as listed"

# ===========================================================================
# CASE E — fixture down -> jev-local disappears (auto-disappear, llmctl rule)
# ===========================================================================
it "CASE E: fixture killed -> jev-local record absent on the next detection"
kill "$FIXTURE_PID" 2>/dev/null; wait "$FIXTURE_PID" 2>/dev/null
DET_E="$(detect)"
echo "--- detect_jev_records output (CASE E, fixture down) ---" >> "$PROOF"; echo "$DET_E" >> "$PROOF"
assert_eq "0" "$(jq '[.[] | select(.provider_id=="jev-local")] | length' <<<"$DET_E")" \
  "dead gateway -> no jev-local record (auto-disappear, same contract as llmctl records)"
# hosted presence-only records survive (they never claimed reachability)
assert_eq "2" "$(jq 'length' <<<"$DET_E")" "hosted records unaffected by the local gateway dying"

# ===========================================================================
# CASE F — slow fixture + 1s timeout -> absent AND time-bounded
# ===========================================================================
it "CASE F: fixture answering after 4s with CMA_JEV_HTTP_TIMEOUT=1 -> no record, probe stays bounded"
SLOW_PINS="$HOME/jev-pins-slow.json"
jq --argjson sp "$SLOW_PORT" '.local_gateway.port=$sp' "$PINS" > "$SLOW_PINS"
_f_start="$(date +%s)"
DET_F="$(CMA_JEV_PINS_FILE="$SLOW_PINS" CMA_JEV_HTTP_TIMEOUT=1 detect)"
_f_end="$(date +%s)"
echo "--- detect_jev_records output (CASE F, slow fixture) ---" >> "$PROOF"; echo "$DET_F" >> "$PROOF"
assert_eq "0" "$(jq '[.[] | select(.provider_id=="jev-local")] | length' <<<"$DET_F")" \
  "endpoint slower than CMA_JEV_HTTP_TIMEOUT is honestly absent (never blocks detection)"
_f_elapsed=$(( _f_end - _f_start ))
echo "slow-probe wall time: ${_f_elapsed}s (timeout=1, fixture delay=4)" >> "$PROOF"
_f_bounded=1; (( _f_elapsed < 8 )) || _f_bounded=0
assert_eq 1 "$_f_bounded" "detection stayed time-bounded (${_f_elapsed}s << fixture delay 4s + margin)"

cma_proof_commit "$PROOF" "$PROOF_FINAL"
summary
