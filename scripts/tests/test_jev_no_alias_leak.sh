#!/usr/bin/env bash
# test_jev_no_alias_leak.sh — proves decision-classification (Jev) records
# NEVER leak into the launchable-provider surfaces, through the REAL full
# `claude-providers sync` dispatch path (modeled on test_kimi_aliases.sh):
#
#   * NO `alias jev-*` / `kimi-jev-*` / `pi-jev-*` lines in the managed alias
#     file (the twin-emission loop must skip classification=="decision")
#   * NO <id>.env records for jev ids in the providers state dir
#   * NO ~/.claude-prov-jev-* / ~/.kimi-prov-jev-* / ~/.pi-prov-jev-* dirs —
#     i.e. decision records never reach _cma_kimi_render_config /
#     _cma_pi_render_config / cma_provider_write_env
#   * normal (llm-classification) provider aliases are UNAFFECTED by the
#     presence of decision records in the same resolve set
#   * status.json DOES carry the decision records with classification
#     "decision" (health bookkeeping is their one intended surface)
#   * CMA_JEV_DISABLE=1 opts out completely (no status entries, no cache)
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=lib/proof.sh
source "$TESTS_DIR/lib/proof.sh"
PROOF_DIR="$(cma_proof_volatile_dir)"
PROOF_FINAL="$PROOF_DIR/99-jev-no-alias-leak.txt"
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

# Single-alias path only (multi-sync leg runs live model_verify.py).
export CMA_SYNC_MULTI=0

PROVIDERS_SH="$SCRIPTS_DIR/claude-providers.sh"
FIXTURE="$SCRIPTS_DIR/tests/fixtures/jev_server.py"
PDIR="$(cma_providers_dir)"
mkdir -p "$PDIR"
CACHE="$PDIR/models.dev.cache.json"
STATUS="$PDIR/status.json"
JEV_CACHE="$PDIR/jev-endpoints.json"

# Fresh models.dev cache (written NOW -> inside CMA_MODELS_DEV_TTL, so
# ensure_catalog never fetches even without --offline): one normal provider
# (acme) as the positive control that llm-classification records still get
# their full alias/env/config treatment alongside the decision records.
cat > "$CACHE" <<'JSON'
{
  "acme": {"env":["ACME_API_KEY"],"api":"https://api.acme.com/anthropic","npm":"@ai-sdk/anthropic",
           "models":{"b":{"id":"acme-big","reasoning":true,"release_date":"2025-05-01","limit":{"context":200000},"cost":{"input":3,"output":15},"tool_call":true}}}
}
JSON

KEYS="$HOME/api_keys.sh"
cat > "$KEYS" <<'SH'
export ACME_API_KEY="dummy-acme"
export TYPESAFE_API_KEY="dummy-ts"
export OPENROUTER_API_KEY="dummy-or"
SH

# Sandbox copies of the operator-editable data files (cmd_migrate_names +
# resolve_records must never rewrite the TRACKED repo files inside a test).
echo '{}' > "$HOME/key-aliases.json"
echo '{}' > "$HOME/overrides.json"
echo '{}' > "$HOME/legacy-renames.json"
export CMA_PROVIDERS_KEY_ALIASES="$HOME/key-aliases.json"
export CMA_PROVIDERS_OVERRIDES="$HOME/overrides.json"
export CMA_PROVIDERS_LEGACY_RENAMES="$HOME/legacy-renames.json"

# Jev local gateway: fixture on an ephemeral port via the pins seam.
FIXTURE_PORT_FILE="$HOME/.jev_fixture_port"
python3 "$FIXTURE" 0 "$FIXTURE_PORT_FILE" >/dev/null 2>&1 &
FIXTURE_PID=$!
for _ in $(seq 1 50); do [[ -s "$FIXTURE_PORT_FILE" ]] && break; sleep 0.1; done
FIXTURE_PORT="$(cat "$FIXTURE_PORT_FILE" 2>/dev/null)"
trap 'kill "$FIXTURE_PID" 2>/dev/null; cleanup_sandbox' EXIT

PINS="$HOME/jev-pins.json"
jq --argjson p "$FIXTURE_PORT" '.local_gateway.port = $p' \
  "$SCRIPTS_DIR/providers/jev.json" > "$PINS"
export CMA_JEV_PINS_FILE="$PINS"

{
  echo "=== test_jev_no_alias_leak.sh evidence ==="
  echo "date: $(date -u +%FT%TZ)"
  echo "fixture port=$FIXTURE_PORT"
} >> "$PROOF" 2>&1

# ===========================================================================
# Full sync through the real dispatch path.
# ===========================================================================
it "sync runs cleanly with decision records present in the resolve set"
bash "$PROVIDERS_SH" sync --no-verify --keys-file "$KEYS" >"$HOME/sync.out" 2>&1
sync_rc=$?
echo "--- sync output ---" >> "$PROOF"; cat "$HOME/sync.out" >> "$PROOF"
assert_eq 0 "$sync_rc" "sync exit 0"

it "NO jev aliases of any family in the managed alias file"
_n_jev="$(grep -c '^alias jev' "$ALIAS_FILE" 2>/dev/null)" || _n_jev=0
assert_eq 0 "$_n_jev" "no 'alias jev-*' lines (no cma_run_provider aliases for decision records)"
_n_kimi_jev="$(grep -c 'kimi-jev' "$ALIAS_FILE" 2>/dev/null)" || _n_kimi_jev=0
assert_eq 0 "$_n_kimi_jev" "no kimi-jev-* twin lines"
_n_pi_jev="$(grep -c 'pi-jev' "$ALIAS_FILE" 2>/dev/null)" || _n_pi_jev=0
assert_eq 0 "$_n_pi_jev" "no pi-jev-* twin lines"
_n_any_jev="$(grep -cE 'cma_run_(kimi_|pi_)?provider jev' "$ALIAS_FILE" 2>/dev/null)" || _n_any_jev=0
assert_eq 0 "$_n_any_jev" "no wrapper invocation names a jev id at all"

it "NO jev env records, config dirs, or renderer output"
_n_env=0
compgen -G "$PDIR/jev-*.env" >/dev/null 2>&1 && _n_env=1
assert_eq 0 "$_n_env" "no jev-*.env records in the providers state dir"
_n_dirs=0
compgen -G "$HOME/.claude-prov-jev-*" >/dev/null 2>&1 && _n_dirs=1
compgen -G "$HOME/.kimi-prov-jev-*"   >/dev/null 2>&1 && _n_dirs=1
compgen -G "$HOME/.pi-prov-jev-*"     >/dev/null 2>&1 && _n_dirs=1
assert_eq 0 "$_n_dirs" "no .claude-prov-/.kimi-prov-/.pi-prov- dirs for jev ids (renderers never saw the records)"

it "normal (llm-classification) provider aliases are UNAFFECTED"
grep -q '^alias acme="cma_run_provider acme"$' "$ALIAS_FILE" \
  && _pass "acme base alias emitted alongside the decision records" \
  || _fail "acme base alias emitted alongside the decision records" "$(grep '^alias' "$ALIAS_FILE" 2>/dev/null)"
assert_file "$PDIR/acme.env" "acme got its env record (the decision filter did not eat llm records)"
assert_dir "$HOME/.kimi-prov-acme" "acme got its kimi twin config (renderers still run for llm records)"

it "status.json DOES carry the decision records with classification=decision"
assert_jq "$STATUS" '.["jev-local"].classification' "decision" "jev-local status entry classified decision"
assert_jq "$STATUS" '.["jev-typesafe"].classification' "decision" "jev-typesafe status entry classified decision"
assert_jq "$STATUS" '.["jev-openrouter"].classification' "decision" "jev-openrouter status entry classified decision"
assert_jq "$STATUS" '.["jev-local"].status' "resolved" "jev-local live-probed -> resolved"
_n_reason="$(jq -r '.["jev-local"].reason | length > 0' "$STATUS")"
assert_eq "true" "$_n_reason" "status entry carries the honest detector reason"

it "endpoint cache written with the ranked local endpoint on top"
assert_file "$JEV_CACHE" "jev-endpoints.json written by the full sync too"
assert_jq "$JEV_CACHE" '.endpoints[0].provider_id' "jev-local" "local gateway ranks first"

it "`claude-providers list` shows decision endpoints in their OWN read-only section"
list_out="$(bash "$PROVIDERS_SH" list 2>/dev/null)"
echo "--- list output ---" >> "$PROOF"; echo "$list_out" >> "$PROOF"
echo "$list_out" | grep -q '## Decision endpoints (Jev)' \
  && _pass "list renders the decision-endpoints section" \
  || _fail "list renders the decision-endpoints section" "$list_out"
echo "$list_out" | grep -q 'not launchable' \
  && _pass "section is marked not-launchable" \
  || _fail "section is marked not-launchable" "$list_out"
# ...but never as launchable rows: above the decision section (the agent
# table proper), no row may name a jev id in its ALIAS (first) column.
_n_list_alias="$(echo "$list_out" | sed '/## Decision endpoints/,$d' | awk 'NF {print $1}' | grep -c '^jev')" || _n_list_alias=0
assert_eq 0 "$_n_list_alias" "no jev id ever appears as a launchable alias row"

it "prune never evicts decision status entries (they have no .env BY DESIGN)"
# The status-only orphan sweep removes any status.json record with no backing
# .env — without the classification filter it would delete every Jev health
# record on every prune. Decision entries must survive a full prune.
bash "$PROVIDERS_SH" prune >/dev/null 2>&1
assert_jq "$STATUS" '.["jev-local"].classification' "decision" "jev-local status survives prune"
assert_jq "$STATUS" '.["jev-typesafe"].classification' "decision" "jev-typesafe status survives prune"

it "CMA_JEV_DISABLE=1 opts out completely"
rm -f "$STATUS" "$JEV_CACHE"
CMA_JEV_DISABLE=1 bash "$PROVIDERS_SH" sync --no-verify --keys-file "$KEYS" >/dev/null 2>&1
assert_eq 0 "$?" "sync with CMA_JEV_DISABLE=1 exits cleanly"
_n_disabled=0
{ [[ -f "$STATUS" ]] && jq -e '[to_entries[] | select(.value.classification == "decision")] | length > 0' "$STATUS" >/dev/null 2>&1; } && _n_disabled=1
assert_eq 0 "$_n_disabled" "no decision status entries written when disabled"
[[ -f "$JEV_CACHE" ]] && _n_disabled=1
assert_eq 0 "$_n_disabled" "no endpoint cache written when disabled (identical pre-Jev behavior)"
# and the normal provider still synced fine
grep -q '^alias acme=' "$ALIAS_FILE" \
  && _pass "normal provider sync unaffected by CMA_JEV_DISABLE=1" \
  || _fail "normal provider sync unaffected by CMA_JEV_DISABLE=1" ""

cma_proof_commit "$PROOF" "$PROOF_FINAL"
summary
