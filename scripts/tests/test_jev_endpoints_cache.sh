#!/usr/bin/env bash
# test_jev_endpoints_cache.sh — hermetic test for the Jev ranked endpoint
# cache ($CMA_PROVIDERS_DIR/jev-endpoints.json) written by
# _cma_jev_write_endpoint_cache via `claude-providers sync-jev`.
#
# This cache is the ONLY thing the launch-time cma_jev_env (lib.sh) reads —
# the launch path does zero probing — so its FORMAT is a cross-component
# contract: cma_jev_env reads `.endpoints[0]` and dereferences
# .base_url / .key_var (NAME only, never a value) / .model / .provider_id.
#
# Cases:
#   A. format: version/generated_at/ttl + per-endpoint field set (exact)
#   B. non-secret: key var NAMES only — no key VALUE ever lands in the cache
#   C. atomicity: concurrent sync-jev writers never leave a partial file
#      (a reader racing them always parses valid JSON)
#   D. TTL semantics: the stat-mtime staleness check cma_jev_env performs
#      (fresh cache not stale; cache older than CMA_JEV_CACHE_TTL stale)
#   E. auto-disappear: when every endpoint vanishes the cache is REWRITTEN
#      with an empty endpoints array (a dead endpoint can never linger)
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=lib/proof.sh
source "$TESTS_DIR/lib/proof.sh"
PROOF_DIR="$(cma_proof_volatile_dir)"
PROOF_FINAL="$PROOF_DIR/99-jev-endpoints-cache.txt"
PROOF="$(cma_proof_open "$PROOF_FINAL")"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e

PROVIDERS_SH="$SCRIPTS_DIR/claude-providers.sh"
FIXTURE="$SCRIPTS_DIR/tests/fixtures/jev_server.py"
PDIR="$HOME/.local/share/claude-multi-account/providers"
mkdir -p "$PDIR"
KEYS="$HOME/api_keys.sh"
CACHE="$PDIR/jev-endpoints.json"

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

cat > "$KEYS" <<'SH'
export TYPESAFE_API_KEY="dummy-ts-secret-VALUE-must-never-leak"
export OPENROUTER_API_KEY="dummy-or-secret"
SH

{
  echo "=== test_jev_endpoints_cache.sh evidence ==="
  echo "date: $(date -u +%FT%TZ)"
  echo "fixture port=$FIXTURE_PORT"
} >> "$PROOF" 2>&1

sync_jev() { env "$@" bash "$PROVIDERS_SH" sync-jev --quiet >/dev/null 2>&1; }

# ===========================================================================
# CASE A — cache format (the cma_jev_env contract)
# ===========================================================================
it "CASE A: cache has version/generated_at/ttl and the exact per-endpoint field set"
sync_jev
assert_file "$CACHE" "cache written by sync-jev"
echo "--- cache (CASE A) ---" >> "$PROOF"; cat "$CACHE" >> "$PROOF"
assert_jq "$CACHE" '.version' "1" "version = 1"
_gat="$(jq -r '.generated_at' "$CACHE")"
_now="$(date +%s)"
_gat_ok=0; [[ "$_gat" =~ ^[0-9]+$ ]] && (( _gat <= _now && _gat > _now - 60 )) && _gat_ok=1
assert_eq 1 "$_gat_ok" "generated_at is an epoch within the last minute ($_gat)"
assert_jq "$CACHE" '.ttl' "300" "ttl defaults to 300 (CMA_JEV_CACHE_TTL)"
KEYS0="$(jq -c '.endpoints[0] | keys' "$CACHE")"
assert_eq '["base_url","key_var","model","priority","probed_at","provider_id","reason"]' "$KEYS0" \
  "endpoint object carries EXACTLY the fields cma_jev_env dereferences (+priority/probed_at/reason)"
assert_jq "$CACHE" '.endpoints[0].provider_id' "jev-local" "endpoints[0] is the local gateway (top rank)"
assert_jq "$CACHE" '.endpoints[0].model' "jev-fixture-1" "endpoints[0].model (read by cma_jev_env as JEV_MODEL)"
# ttl override is recorded, not invented at read time
sync_jev CMA_JEV_CACHE_TTL=123
assert_jq "$CACHE" '.ttl' "123" "CMA_JEV_CACHE_TTL override lands in the cache"

# ===========================================================================
# CASE B — non-secret by construction
# ===========================================================================
it "CASE B: cache carries key var NAMES, never key VALUES"
_leak=0
grep -q 'dummy-ts-secret-VALUE-must-never-leak\|dummy-or-secret' "$CACHE" && _leak=1
assert_eq 0 "$_leak" "no key VALUE anywhere in jev-endpoints.json"
assert_jq "$CACHE" '[.endpoints[] | select(.provider_id=="jev-typesafe")][0].key_var' "TYPESAFE_API_KEY" \
  "only the key var NAME is recorded"

# ===========================================================================
# CASE C — atomicity under concurrent writers
# ===========================================================================
it "CASE C: 8 concurrent sync-jev writers — a racing reader always sees valid JSON"
# The reader runs backgrounded, so its counter CANNOT be a shell variable
# (subshell scope) — it writes the failure count to a file the parent reads
# after the wait.
_fails_file="$HOME/.jev_reader_fails"
( _rf=0
  for _ in $(seq 1 200); do
    jq -e . "$CACHE" >/dev/null 2>&1 || _rf=$((_rf+1))
    # no sleep: hammer reads through the whole writer burst
  done
  printf '%s' "$_rf" > "$_fails_file" ) &
_reader_pid=$!
# Wait ONLY on the writer pids, never a bare `wait`: the fixture server is
# also a background child of this shell and never exits, so a bare wait
# would hang the suite forever (observed live).
_writer_pids=()
for _ in $(seq 1 8); do sync_jev & _writer_pids+=("$!"); done
wait "$_reader_pid" 2>/dev/null
wait "${_writer_pids[@]}" 2>/dev/null
_read_fails="$(cat "$_fails_file" 2>/dev/null)"
echo "concurrent-reader jq parse failures: $_read_fails" >> "$PROOF"
assert_eq 0 "$_read_fails" "cache is always whole-file valid (mktemp+mv atomic write)"
assert_jq "$CACHE" '.endpoints | length' "3" "final cache intact after the writer burst"

# ===========================================================================
# CASE D — TTL semantics (mirrors cma_jev_env's stat-based staleness check:
# stale iff now - mtime > CMA_JEV_CACHE_TTL; a fresh cache is never stale)
# ===========================================================================
it "CASE D: fresh cache is not stale; cache older than the TTL is stale"
_mtime="$(stat -c %Y "$CACHE" 2>/dev/null || stat -f %m "$CACHE")"
_now="$(date +%s)"
_stale=0; (( _now - _mtime > 300 )) && _stale=1
assert_eq 0 "$_stale" "fresh cache: now-mtime <= 300 -> NOT stale (no background refresh kicked)"
touch -d '10 minutes ago' "$CACHE" 2>/dev/null || touch -t "$(date -v-10M +%Y%m%d%M%S)" "$CACHE"
_mtime="$(stat -c %Y "$CACHE" 2>/dev/null || stat -f %m "$CACHE")"
_now="$(date +%s)"
_stale=0; (( _now - _mtime > 300 )) && _stale=1
assert_eq 1 "$_stale" "10-minute-old cache: now-mtime > 300 -> stale (background sync-jev refresh)"
# restore freshness for CASE E
sync_jev

# ===========================================================================
# CASE E — auto-disappear: empty resolved set REWRITES the cache
# ===========================================================================
it "CASE E: all endpoints gone -> cache rewritten with endpoints: [] (never left stale)"
kill "$FIXTURE_PID" 2>/dev/null; wait "$FIXTURE_PID" 2>/dev/null
: > "$KEYS"
sync_jev
echo "--- cache (CASE E, everything gone) ---" >> "$PROOF"; cat "$CACHE" >> "$PROOF"
assert_jq "$CACHE" '.endpoints | length' "0" "dead endpoints are evicted on the next sync-jev (auto-disappear)"
assert_jq "$CACHE" '.version' "1" "the empty cache is still a well-formed v1 document"

cma_proof_commit "$PROOF" "$PROOF_FINAL"
summary
