#!/usr/bin/env bash
# test_quota_concurrency.sh — unit/integration tests for
# scripts/claude-providers.sh's `_cma_quota_probe_all` (T017b): the
# bounded-concurrency probe orchestration across every provider-account
# group (T015's _cma_quota_group_accounts) and every native account
# (T016's _cma_quota_list_native_accounts).
#
# This is the Review Focus #3 / SC-008 test: timing IS the property under
# test for scenario (a), so a REAL slow subprocess (an actual local HTTP
# server that sleeps past the configured timeout) is used rather than a
# mocked instant return -- a mock would prove nothing about concurrency.
#
# ISOLATION NOTE: _cma_quota_probe_all (and T015's _cma_quota_group_accounts,
# which it calls) resolve their provider-endpoint spec file from
# "${LIB_DIR:-${SCRIPTS_DIR:-}}/providers/quota-endpoints.json" with NO env-var
# override -- and claude-providers.sh unconditionally recomputes LIB_DIR from
# its OWN location (BASH_SOURCE[0]) every time it is sourced. To inject
# fixture provider ids into that spec file without ever touching the real,
# tracked scripts/providers/quota-endpoints.json, this file sources an
# ISOLATED COPY of the four files actually needed at runtime (lib.sh,
# claude-providers.sh, quota_probe.py, model_verify.py) from a sandboxed
# directory, with its OWN providers/quota-endpoints.json fixture sitting next
# to it. Sourcing that copy makes LIB_DIR resolve inside the sandbox, so every
# path the function derives from it (spec file, quota_probe.py, the cache
# file under $HOME) is fully sandboxed and never touches the real repo.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox

# --- isolated lib dir: a sandboxed copy of the 4 files _cma_quota_probe_all
# actually needs at runtime, plus OUR OWN providers/quota-endpoints.json. ----
ISO_LIB_DIR="$HOME/_iso_scripts"
mkdir -p "$ISO_LIB_DIR/providers"
cp "$SCRIPTS_DIR/lib.sh" "$ISO_LIB_DIR/lib.sh"
cp "$SCRIPTS_DIR/claude-providers.sh" "$ISO_LIB_DIR/claude-providers.sh"
cp "$SCRIPTS_DIR/quota_probe.py" "$ISO_LIB_DIR/quota_probe.py"
cp "$SCRIPTS_DIR/model_verify.py" "$ISO_LIB_DIR/model_verify.py"

# Fixture provider ids used across the three scenarios below. Each test
# scenario below documents exactly which ids it adds and why.
cat > "$ISO_LIB_DIR/providers/quota-endpoints.json" <<JSONEOF
{
  "p0": {"url": "__FAST_URL__", "auth": "bearer",
    "windows": [{"window": "daily", "signals": [
      {"path": ["remaining"], "type": "amount_remaining"},
      {"path": ["limit"], "type": "limit_total"},
      {"path": ["used"], "type": "amount_used"},
      {"path": [], "type": "unit_literal", "value": "requests"}
    ]}]},
  "p1": {"url": "__FAST_URL__", "auth": "bearer",
    "windows": [{"window": "daily", "signals": [
      {"path": ["remaining"], "type": "amount_remaining"},
      {"path": ["limit"], "type": "limit_total"},
      {"path": ["used"], "type": "amount_used"},
      {"path": [], "type": "unit_literal", "value": "requests"}
    ]}]},
  "p3": {"url": "__FAST_URL__", "auth": "bearer",
    "windows": [{"window": "daily", "signals": [
      {"path": ["remaining"], "type": "amount_remaining"},
      {"path": ["limit"], "type": "limit_total"},
      {"path": ["used"], "type": "amount_used"},
      {"path": [], "type": "unit_literal", "value": "requests"}
    ]}]},
  "p4": {"url": "__FAST_URL__", "auth": "bearer",
    "windows": [{"window": "daily", "signals": [
      {"path": ["remaining"], "type": "amount_remaining"},
      {"path": ["limit"], "type": "limit_total"},
      {"path": ["used"], "type": "amount_used"},
      {"path": [], "type": "unit_literal", "value": "requests"}
    ]}]},
  "p2": {"url": "__SLOW_URL__", "auth": "bearer",
    "windows": [{"window": "daily", "signals": [
      {"path": ["remaining"], "type": "amount_remaining"},
      {"path": ["limit"], "type": "limit_total"},
      {"path": ["used"], "type": "amount_used"},
      {"path": [], "type": "unit_literal", "value": "requests"}
    ]}]},
  "pcache": {"url": "__UNREACHABLE_URL__", "auth": "bearer",
    "windows": [{"window": "daily", "signals": [
      {"path": ["remaining"], "type": "amount_remaining"},
      {"path": ["limit"], "type": "limit_total"},
      {"path": ["used"], "type": "amount_used"},
      {"path": [], "type": "unit_literal", "value": "requests"}
    ]}]},
  "c3": {"url": "__UNREACHABLE_URL__", "auth": "bearer",
    "windows": [{"window": "daily", "signals": [
      {"path": ["remaining"], "type": "amount_remaining"},
      {"path": ["limit"], "type": "limit_total"},
      {"path": ["used"], "type": "amount_used"},
      {"path": [], "type": "unit_literal", "value": "requests"}
    ]}]}
}
JSONEOF

# --- real local HTTP fixture server (scenario a) ----------------------------
#
# A genuine ThreadingHTTPServer, not a mock: "/" responds 200 with real JSON
# after a real 1-second sleep (simulates real network latency on a HEALTHY
# provider); "/slow" NEVER responds at all, so the client (quota_probe.py's
# own http_get_json, via urlopen(..., timeout=...)) genuinely times out at
# the configured --timeout -- the failure is real, not injected.
cat > "$HOME/_fixture_server.py" <<'PYEOF'
import http.server
import socketserver
import time
import json
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/slow"):
            time.sleep(9999)
            return
        time.sleep(1.0)
        body = json.dumps({"used": 10, "remaining": 90, "limit": 100}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a, **k):
        pass


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


srv = Server(("127.0.0.1", 0), Handler)
print(srv.server_address[1], flush=True)
sys.stdout.flush()
srv.serve_forever()
PYEOF

PORT_FILE="$HOME/_fixture_server.port"
python3 "$HOME/_fixture_server.py" > "$PORT_FILE" 2>"$HOME/_fixture_server.err" &
FIXTURE_SERVER_PID=$!
# `disown` is load-bearing, not cosmetic: _cma_quota_probe_all's own bare
# `wait` (no args) waits for EVERY currently-tracked background job of the
# CURRENT shell, not just the ones it itself just spawned -- and this
# long-running server (serve_forever, never exits on its own) is a
# background job of this SAME shell (sourced functions run in-process, no
# subshell boundary). Without disowning it here, the very first call to
# _cma_quota_probe_all hangs forever on its own `wait`, waiting on a server
# that will never finish. Reproduced and confirmed live before adding this.
disown "$FIXTURE_SERVER_PID" 2>/dev/null || true
# Chain cleanup onto the trap make_sandbox already installed (EXIT ->
# cleanup_sandbox) -- overwriting it outright would skip sandbox removal.
trap 'kill "$FIXTURE_SERVER_PID" 2>/dev/null; cleanup_sandbox' EXIT

# Poll for the server to report its assigned port (bound to port 0 so a
# re-run never collides with a leftover listener from a previous run).
_waited=0
while [[ ! -s "$PORT_FILE" ]]; do
  sleep 0.1
  _waited=$((_waited + 1))
  if (( _waited > 50 )); then
    echo "FATAL: fixture HTTP server never reported its port" >&2
    cat "$HOME/_fixture_server.err" >&2 2>/dev/null || true
    exit 98
  fi
done
FIXTURE_PORT="$(cat "$PORT_FILE")"
FAST_URL="http://127.0.0.1:${FIXTURE_PORT}/"
SLOW_URL="http://127.0.0.1:${FIXTURE_PORT}/slow"
# Port 1 ("tcpmux") is privileged and essentially never bound by anything on
# a normal host -> a real, fast, deterministic connection-refused failure.
# Used to PROVE "no network attempt happened" in scenario (b): if the cached
# path were skipped and a live probe were genuinely attempted against this
# address, it would fail (absence_reason=probe_failed, windows=[]) instead
# of returning the good cached data.
UNREACHABLE_URL="http://127.0.0.1:1/"

# Portable in-place edit (no `sed -i`, whose flag syntax differs between GNU
# and BSD sed per this project's own portability notes): write to a temp file
# then move it into place.
sed \
  -e "s#__FAST_URL__#${FAST_URL}#g" \
  -e "s#__SLOW_URL__#${SLOW_URL}#g" \
  -e "s#__UNREACHABLE_URL__#${UNREACHABLE_URL}#g" \
  "$ISO_LIB_DIR/providers/quota-endpoints.json" > "$ISO_LIB_DIR/providers/quota-endpoints.json.tmp"
mv "$ISO_LIB_DIR/providers/quota-endpoints.json.tmp" "$ISO_LIB_DIR/providers/quota-endpoints.json"

# shellcheck source=../../claude-providers.sh
source "$ISO_LIB_DIR/claude-providers.sh"
set +e   # claude-providers.sh (and the lib.sh it sources) set -e; the
         # harness asserts on failures rather than aborting on the first one.

it "ISOLATION SANITY: LIB_DIR resolved to the sandboxed copy, not the real repo"
assert_eq "$ISO_LIB_DIR" "$LIB_DIR" "LIB_DIR points at the isolated copy (fixture spec file is never the real tracked one)"

pdir="$(cma_providers_dir)"; mkdir -p "$pdir"

# =============================================================================
# Scenario (a): bounded wall-clock, not linear in alias count.
#
# 5 provider-account fixtures: p0, p1, p3, p4 all point at the FAST endpoint
# (real 1s network latency, genuinely succeeds); p2 points at the SLOW
# endpoint (never responds -> genuinely times out at --timeout). All 5 fit in
# ONE batch under the default CMA_QUOTA_MAX_PARALLEL_PROBES (8), so bounded
# concurrency means total wall-clock should be close to max(fast, timeout),
# NOT the sum of all 5 (which sequential probing would produce).
# =============================================================================

for p in p0 p1 p3 p4 p2; do
  cma_provider_write_env "$p" "" router "http://example.invalid" "model-x" "model-x" \
    "$HOME/.claude-prov-$p" 128000 8192 "$p"
done

SECONDS=0
out_a="$(_cma_quota_probe_all 1 2)"   # fresh=1 (force live probe), timeout=2s
elapsed_a=$SECONDS

it "scenario (a): total wall-clock is well under N x timeout (bounded concurrency, not sequential)"
# N=5, timeout=2s. Sequential would be ~= 4 x (1s fast + overhead) + 1 x (2s
# timeout + overhead) ~= 7-8s. Bounded-concurrency (all 5 in one batch) is
# ~= max(1s, 2s) + small overhead ~= 2-3s. 6s is a real, meaningful cutoff
# squarely between the two -- it is NOT "it finished eventually".
echo "    (measured elapsed_a=${elapsed_a}s)"
if (( elapsed_a < 6 )); then under_bound=1; else under_bound=0; fi
assert_eq "1" "$under_bound" "elapsed=${elapsed_a}s must be < 6s (N=5 x timeout=2s sequential would be ~7-8s)"

it "scenario (a): the slow provider (p2) carries an honest failure absence_reason"
p2_absence="$(echo "$out_a" | jq -r 'select(.provider_id=="p2") | .absence_reason')"
assert_eq "probe_failed" "$p2_absence" "p2 (slow/never-responding endpoint) reports probe_failed"
p2_windows_len="$(echo "$out_a" | jq -r 'select(.provider_id=="p2") | .windows | length')"
assert_eq "0" "$p2_windows_len" "p2 has no windows (the probe never got a usable response)"

it "scenario (a): every OTHER provider (p0,p1,p3,p4) still produced its real live result"
all_ok=1
for p in p0 p1 p3 p4; do
  absence="$(echo "$out_a" | jq -r --arg p "$p" 'select(.provider_id==$p) | .absence_reason')"
  src="$(echo "$out_a" | jq -r --arg p "$p" 'select(.provider_id==$p) | .data_source')"
  wlen="$(echo "$out_a" | jq -r --arg p "$p" 'select(.provider_id==$p) | .windows | length')"
  [[ "$absence" == "null" && "$src" == "live" && "$wlen" -ge 1 ]] || all_ok=0
done
assert_eq "1" "$all_ok" "p0,p1,p3,p4 each have absence_reason=null, data_source=live, and a real resolved window"

# =============================================================================
# Scenario (b): cache hit skips the network entirely.
#
# "pcache" is pre-seeded with a valid cache entry directly (via
# qp.save_quota_cache), including a per-record _cached_at seeded to ~300s in
# the past so data_age_seconds reflects a real, known age. Its
# quota-endpoints.json url points at UNREACHABLE_URL (port 1, instant
# connection-refused) -- if the cache path were skipped, a genuinely-attempted
# live probe would fail FAST and return absence_reason=probe_failed with
# empty windows. Getting back the pre-seeded GOOD data instead is the proof
# that no network attempt was made: there is no other way this data could
# appear.
# =============================================================================

cma_provider_write_env pcache "" router "http://example.invalid" "model-x" "model-x" \
  "$HOME/.claude-prov-pcache" 128000 8192 pcache

CACHE_FILE="$HOME/.local/share/claude-multi-account/quota-cache.json"
SEEDED_AGE=300
python3 - "$ISO_LIB_DIR" "$CACHE_FILE" "$SEEDED_AGE" <<'PYEOF'
import sys, time
sys.path.insert(0, sys.argv[1])
import quota_probe as qp

cache_path = sys.argv[2]
seeded_age = float(sys.argv[3])
data = qp.load_quota_cache(cache_path)
data.setdefault("providers", {})["pcache"] = {
    "provider_id": "pcache",
    "windows": [{
        "window": "daily", "amount_used": 5, "amount_remaining": 95,
        "limit_total": 100, "unit": "requests", "percent_remaining": 95.0,
        "resets": False, "reset_at": None,
    }],
    "account_blocked": False,
    "absence_reason": None,
    "http_status": 200,
    "_cached_at": time.time() - seeded_age,
}
qp.save_quota_cache(cache_path, data)
PYEOF

out_b="$(_cma_quota_probe_all 0 1)"   # fresh=0 (allow cache), timeout=1s

it "scenario (b): pcache's row has data_source=cached"
src_b="$(echo "$out_b" | jq -r 'select(.provider_id=="pcache") | .data_source')"
assert_eq "cached" "$src_b" "pcache served from cache, not a live probe"

it "scenario (b): pcache's data_age_seconds is a correct, non-null number close to the seeded age"
age_b="$(echo "$out_b" | jq -r 'select(.provider_id=="pcache") | .data_age_seconds')"
age_is_number=0
case "$age_b" in ''|null) age_is_number=0 ;; *) age_is_number=1 ;; esac
assert_eq "1" "$age_is_number" "data_age_seconds is non-null (got: $age_b)"
# Generous window: seeded 300s in the past, this whole scenario setup + probe
# run should take well under a minute.
age_in_range=0
if [[ "$age_is_number" == "1" ]] && (( age_b >= 295 && age_b <= 360 )); then
  age_in_range=1
fi
assert_eq "1" "$age_in_range" "data_age_seconds (${age_b}) is within [295,360] of the seeded ~300s age"

it "scenario (b): pcache's windows match the PRE-SEEDED good data (proves no live probe was attempted against the unreachable URL)"
remaining_b="$(echo "$out_b" | jq -r 'select(.provider_id=="pcache") | .windows[0].amount_remaining')"
assert_eq "95" "$remaining_b" "amount_remaining=95 (the seeded value) -- a real attempt against port 1 would have failed instantly with absence_reason=probe_failed and empty windows instead"

it "scenario (b): pcache's absence_reason is null (a real probe_failed would prove the network WAS hit)"
absence_b="$(echo "$out_b" | jq -r 'select(.provider_id=="pcache") | .absence_reason')"
assert_eq "null" "$absence_b" "absence_reason is null for the cache-hit row"

# =============================================================================
# Scenario (c): exactly N rows, no duplicates, no missing.
#
# Fresh provider/account set for this scenario (the provider dir is reset so
# earlier scenarios' fixtures don't leak into the count): c1, c2 have NO
# entry in quota-endpoints.json (endpoint_spec_present=false, handled
# synchronously with zero network activity); c3 DOES have an entry (pointing
# at the unreachable URL -- its outcome doesn't matter for this scenario,
# only that exactly one row is produced). Plus two native accounts
# (never de-duplicated, per T016).
# =============================================================================

rm -f "$pdir"/*.env
: > "$ALIAS_FILE" 2>/dev/null || true

cma_provider_write_env c1 "" router "http://example.invalid" "model-x" "model-x" \
  "$HOME/.claude-prov-c1" 128000 8192 c1
cma_provider_write_env c2 "" router "http://example.invalid" "model-x" "model-x" \
  "$HOME/.claude-prov-c2" 128000 8192 c2
cma_provider_write_env c3 "" router "http://example.invalid" "model-x" "model-x" \
  "$HOME/.claude-prov-c3" 128000 8192 c3

dirA="$(make_account nativeA)"
cat > "$dirA/.claude.json" <<'EOF'
{"oauthAccount": {"organizationRateLimitTier": "default_claude_pro"}}
EOF
dirB="$(make_account nativeB)"
cat > "$dirB/.claude.json" <<'EOF'
{"oauthAccount": {"organizationRateLimitTier": "default_claude_max_20x"}}
EOF

it "scenario (c): c1 and c2 are both endpoint_spec_present=false (sanity on the fixture itself)"
present_c1="$(_cma_quota_group_accounts | jq -r 'select(.provider_id=="c1") | .endpoint_spec_present')"
present_c2="$(_cma_quota_group_accounts | jq -r 'select(.provider_id=="c2") | .endpoint_spec_present')"
assert_eq "false" "$present_c1" "c1 has no quota-endpoints.json entry"
assert_eq "false" "$present_c2" "c2 has no quota-endpoints.json entry"

out_c="$(_cma_quota_probe_all 1 1)"

it "scenario (c): exactly 5 total rows (3 provider accounts + 2 native accounts)"
total_c="$(echo "$out_c" | jq -s 'length')"
assert_eq "5" "$total_c" "c1 + c2 + c3 + nativeA + nativeB = 5 rows, no more, no fewer"

it "scenario (c): no duplicate provider_id/account_id across the result set"
ids_c="$(echo "$out_c" | jq -r '(.provider_id // .account_id)' | sort)"
unique_count="$(echo "$ids_c" | sort -u | wc -l | tr -d ' ')"
total_count="$(echo "$ids_c" | wc -l | tr -d ' ')"
assert_eq "$total_count" "$unique_count" "every id is unique -- no duplicates"

it "scenario (c): the exact expected id set is present, nothing missing"
expected_ids="$(printf 'c1\nc2\nc3\nnativeA\nnativeB\n' | sort)"
actual_ids="$(echo "$ids_c" | sort)"
assert_eq "$expected_ids" "$actual_ids" "id set matches exactly"

it "scenario (c): c1 and c2 (no endpoint spec) honestly report not_reported_by_provider, zero network"
abs_c1="$(echo "$out_c" | jq -r 'select(.provider_id=="c1") | .absence_reason')"
abs_c2="$(echo "$out_c" | jq -r 'select(.provider_id=="c2") | .absence_reason')"
assert_eq "not_reported_by_provider" "$abs_c1" "c1 absence_reason"
assert_eq "not_reported_by_provider" "$abs_c2" "c2 absence_reason"

it "scenario (c): nativeA and nativeB are present as native-account rows, never merged"
tier_a="$(echo "$out_c" | jq -r 'select((.account_id // "") | endswith("nativeA")) | .plan_tier')"
tier_b="$(echo "$out_c" | jq -r 'select((.account_id // "") | endswith("nativeB")) | .plan_tier')"
assert_eq "default_claude_pro" "$tier_a" "nativeA's own cached tier"
assert_eq "default_claude_max_20x" "$tier_b" "nativeB's own cached tier, different from nativeA's -- proving no cross-contamination"

summary
