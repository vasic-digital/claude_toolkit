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
  "pcache": {"url": "__FAST_URL__", "auth": "bearer",
    "windows": [{"window": "daily", "signals": [
      {"path": ["remaining"], "type": "amount_remaining"},
      {"path": ["limit"], "type": "limit_total"},
      {"path": ["used"], "type": "amount_used"},
      {"path": [], "type": "unit_literal", "value": "requests"}
    ]}]},
  "pfail": {"url": "__UNREACHABLE_URL__", "auth": "bearer",
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
    ]}]},
  "q0": {"url": "__RACE_URL__", "auth": "bearer",
    "windows": [{"window": "daily", "signals": [
      {"path": ["remaining"], "type": "amount_remaining"},
      {"path": ["limit"], "type": "limit_total"},
      {"path": ["used"], "type": "amount_used"},
      {"path": [], "type": "unit_literal", "value": "requests"}
    ]}]},
  "q1": {"url": "__RACE_URL__", "auth": "bearer",
    "windows": [{"window": "daily", "signals": [
      {"path": ["remaining"], "type": "amount_remaining"},
      {"path": ["limit"], "type": "limit_total"},
      {"path": ["used"], "type": "amount_used"},
      {"path": [], "type": "unit_literal", "value": "requests"}
    ]}]},
  "q2": {"url": "__RACE_URL__", "auth": "bearer",
    "windows": [{"window": "daily", "signals": [
      {"path": ["remaining"], "type": "amount_remaining"},
      {"path": ["limit"], "type": "limit_total"},
      {"path": ["used"], "type": "amount_used"},
      {"path": [], "type": "unit_literal", "value": "requests"}
    ]}]},
  "q3": {"url": "__RACE_URL__", "auth": "bearer",
    "windows": [{"window": "daily", "signals": [
      {"path": ["remaining"], "type": "amount_remaining"},
      {"path": ["limit"], "type": "limit_total"},
      {"path": ["used"], "type": "amount_used"},
      {"path": [], "type": "unit_literal", "value": "requests"}
    ]}]},
  "q4": {"url": "__RACE_URL__", "auth": "bearer",
    "windows": [{"window": "daily", "signals": [
      {"path": ["remaining"], "type": "amount_remaining"},
      {"path": ["limit"], "type": "limit_total"},
      {"path": ["used"], "type": "amount_used"},
      {"path": [], "type": "unit_literal", "value": "requests"}
    ]}]},
  "q5": {"url": "__RACE_URL__", "auth": "bearer",
    "windows": [{"window": "daily", "signals": [
      {"path": ["remaining"], "type": "amount_remaining"},
      {"path": ["limit"], "type": "limit_total"},
      {"path": ["used"], "type": "amount_used"},
      {"path": [], "type": "unit_literal", "value": "requests"}
    ]}]},
  "q6": {"url": "__RACE_URL__", "auth": "bearer",
    "windows": [{"window": "daily", "signals": [
      {"path": ["remaining"], "type": "amount_remaining"},
      {"path": ["limit"], "type": "limit_total"},
      {"path": ["used"], "type": "amount_used"},
      {"path": [], "type": "unit_literal", "value": "requests"}
    ]}]},
  "q7": {"url": "__RACE_URL__", "auth": "bearer",
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

# A SECOND, independent fast-only server for scenario (e)'s concurrent-write
# race test, so that test never depends on whether scenario (b) has already
# killed the main fixture server (see scenario (b) below). Same handler
# shape, reused verbatim rather than writing a second script.
cat > "$HOME/_race_server.py" <<'PYEOF'
import http.server
import socketserver
import time
import json
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        time.sleep(0.3)
        body = json.dumps({"used": 1, "remaining": 1, "limit": 2}).encode()
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

RACE_PORT_FILE="$HOME/_race_server.port"
python3 "$HOME/_race_server.py" > "$RACE_PORT_FILE" 2>"$HOME/_race_server.err" &
RACE_SERVER_PID=$!
disown "$RACE_SERVER_PID" 2>/dev/null || true

# Chain cleanup onto the trap make_sandbox already installed (EXIT ->
# cleanup_sandbox) -- overwriting it outright would skip sandbox removal.
trap 'kill "$FIXTURE_SERVER_PID" "$RACE_SERVER_PID" 2>/dev/null; cleanup_sandbox' EXIT

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

_waited=0
while [[ ! -s "$RACE_PORT_FILE" ]]; do
  sleep 0.1
  _waited=$((_waited + 1))
  if (( _waited > 50 )); then
    echo "FATAL: race HTTP server never reported its port" >&2
    cat "$HOME/_race_server.err" >&2 2>/dev/null || true
    exit 98
  fi
done
RACE_PORT="$(cat "$RACE_PORT_FILE")"
RACE_URL="http://127.0.0.1:${RACE_PORT}/"

# Port 1 ("tcpmux") is privileged and essentially never bound by anything on
# a normal host -> a real, fast, deterministic connection-refused failure.
# Used to PROVE "a probe genuinely failed" in scenarios (b)/(d): if a live
# probe were genuinely attempted against this address, it would fail
# (absence_reason=probe_failed, windows=[]) rather than returning any good
# data.
UNREACHABLE_URL="http://127.0.0.1:1/"

# Portable in-place edit (no `sed -i`, whose flag syntax differs between GNU
# and BSD sed per this project's own portability notes): write to a temp file
# then move it into place.
sed \
  -e "s#__FAST_URL__#${FAST_URL}#g" \
  -e "s#__SLOW_URL__#${SLOW_URL}#g" \
  -e "s#__UNREACHABLE_URL__#${UNREACHABLE_URL}#g" \
  -e "s#__RACE_URL__#${RACE_URL}#g" \
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
# REVIEW ROUND 1 REDESIGN: the previous version of this scenario hand-seeded
# a per-record "_cached_at" directly into the cache file -- a shape
# production never actually produces (the original _cma_quota_probe_all
# only ever wrote a FILE-level _cached_at, never a per-record one), which is
# exactly why the review-round-1 "cache age always reports garbage" bug was
# invisible to this test. This version exercises a REAL write-back-then-read
# cycle instead: "pcache" points at the real FAST endpoint, so the FIRST
# call is a genuine successful live probe that goes through the fixed
# sequential merge-and-save pass and writes a REAL per-record _cached_at.
# The fixture server is then KILLED before the SECOND call -- if the cache
# path were skipped and a live probe were genuinely re-attempted, it would
# now fail (the server is gone) with absence_reason=probe_failed and empty
# windows. Getting back the original good data (data_source=cached, a small
# positive data_age_seconds, matching windows) is the proof both that no
# network attempt was made AND that the real per-record timestamp round-
# trips correctly.
# =============================================================================

cma_provider_write_env pcache "" router "http://example.invalid" "model-x" "model-x" \
  "$HOME/.claude-prov-pcache" 128000 8192 pcache

CACHE_FILE="$HOME/.local/share/claude-multi-account/quota-cache.json"

out_b1="$(_cma_quota_probe_all 1 3)"   # fresh=1 (force live), timeout=3s -- the real first write

it "scenario (b) setup: the first (live) probe for pcache genuinely succeeded"
src_b1="$(echo "$out_b1" | jq -r 'select(.provider_id=="pcache") | .data_source')"
absence_b1="$(echo "$out_b1" | jq -r 'select(.provider_id=="pcache") | .absence_reason')"
assert_eq "live" "$src_b1" "first call is a genuine live probe"
assert_eq "null" "$absence_b1" "first call's probe succeeded (sanity precondition for the rest of this scenario)"

it "scenario (b) setup: the real cache file now carries pcache with a REAL per-record _cached_at (not file-level-only)"
rec_has_own_cached_at="$(
python3 - "$ISO_LIB_DIR" "$CACHE_FILE" <<'PYEOF'
import sys, json
sys.path.insert(0, sys.argv[1])
import quota_probe as qp
data = qp.load_quota_cache(sys.argv[2])
rec = data.get("providers", {}).get("pcache")
print("yes" if (rec and isinstance(rec.get("_cached_at"), (int, float))) else "no")
PYEOF
)"
assert_eq "yes" "$rec_has_own_cached_at" "pcache's cache record carries its OWN _cached_at field (review round 1 fix #1)"

# Kill the fixture server now -- everything from here on proves the SECOND
# call never needs it.
kill "$FIXTURE_SERVER_PID" 2>/dev/null || true

out_b2="$(_cma_quota_probe_all 0 1)"   # fresh=0 (allow cache), timeout=1s, server is DEAD

it "scenario (b): pcache's SECOND-call row has data_source=cached (the dead server proves no network attempt)"
src_b2="$(echo "$out_b2" | jq -r 'select(.provider_id=="pcache") | .data_source')"
assert_eq "cached" "$src_b2" "pcache served from cache on the second call, not a (now-impossible) live probe"

it "scenario (b): pcache's data_age_seconds is a small, real, non-null age (review round 1 fix #1)"
age_b2="$(echo "$out_b2" | jq -r 'select(.provider_id=="pcache") | .data_age_seconds')"
age_is_number=0
case "$age_b2" in ''|null) age_is_number=0 ;; *) age_is_number=1 ;; esac
assert_eq "1" "$age_is_number" "data_age_seconds is non-null (got: $age_b2)"
age_in_range=0
if [[ "$age_is_number" == "1" ]] && (( age_b2 >= 0 && age_b2 < 10 )); then
  age_in_range=1
fi
assert_eq "1" "$age_in_range" "data_age_seconds (${age_b2}) is small (<10s) and real -- NOT the ~epoch-sized garbage the pre-fix code produced (reviewer measured ~1791121821 live)"

it "scenario (b): pcache's windows match the ORIGINAL live-probe data (proves no new network attempt happened against the now-dead server)"
remaining_b2="$(echo "$out_b2" | jq -r 'select(.provider_id=="pcache") | .windows[0].amount_remaining')"
assert_eq "90" "$remaining_b2" "amount_remaining=90 (the fixture server's fixed response) -- a real re-attempt against the dead server would have produced absence_reason=probe_failed and empty windows instead"

it "scenario (b): pcache's absence_reason is null on the second call too"
absence_b2="$(echo "$out_b2" | jq -r 'select(.provider_id=="pcache") | .absence_reason')"
assert_eq "null" "$absence_b2" "absence_reason is null for the cache-hit row"

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

# =============================================================================
# Scenario (d): a failed probe is NEVER cached (review round 1, bug #2).
#
# "pfail" always points at the UNREACHABLE_URL (port 1). Its first call
# genuinely fails (connection refused). The old code cached that failure
# shape unconditionally, and the cached-branch's output hard-coded
# absence_reason:null regardless of what was actually cached -- so a SECOND
# call used to report data_source=cached, absence_reason=null (a false
# "clean" result) for up to the 6h TTL. The fix only pending-caches a
# SUCCESSFUL probe (absence_reason==""), so pfail is never written to the
# shared cache at all; a second call must therefore re-probe live (and fail
# again) -- it must never claim a clean cached result for a provider that
# has only ever failed.
# =============================================================================

rm -f "$pdir"/*.env
cma_provider_write_env pfail "" router "http://example.invalid" "model-x" "model-x" \
  "$HOME/.claude-prov-pfail" 128000 8192 pfail

out_d1="$(_cma_quota_probe_all 1 1)"   # fresh=1, timeout=1s -- genuinely fails (unreachable)

it "scenario (d) setup: pfail's first probe genuinely failed"
absence_d1="$(echo "$out_d1" | jq -r 'select(.provider_id=="pfail") | .absence_reason')"
assert_eq "probe_failed" "$absence_d1" "first call against the unreachable URL fails for real"

it "scenario (d) setup: the failed probe was NOT written to the shared cache file"
pfail_in_cache="$(
python3 - "$ISO_LIB_DIR" "$CACHE_FILE" <<'PYEOF'
import sys, json
sys.path.insert(0, sys.argv[1])
import quota_probe as qp
data = qp.load_quota_cache(sys.argv[2])
print("present" if "pfail" in data.get("providers", {}) else "absent")
PYEOF
)"
assert_eq "absent" "$pfail_in_cache" "a probe_failed result is never persisted to the cache (review round 1 fix #2)"

out_d2="$(_cma_quota_probe_all 0 1)"   # fresh=0 (allow cache) -- there is nothing to hit, so this MUST re-probe live

it "scenario (d): the second call NEVER reports a false clean cached result for a provider that only ever failed"
src_d2="$(echo "$out_d2" | jq -r 'select(.provider_id=="pfail") | .data_source')"
absence_d2="$(echo "$out_d2" | jq -r 'select(.provider_id=="pfail") | .absence_reason')"
false_clean_cache=0
if [[ "$src_d2" == "cached" && "$absence_d2" == "null" ]]; then
  false_clean_cache=1
fi
assert_eq "0" "$false_clean_cache" "data_source=$src_d2 absence_reason=$absence_d2 -- never (cached, null) for an always-failing provider"

it "scenario (d): the second call honestly re-probed live and failed again"
assert_eq "live" "$src_d2" "no cache entry exists for pfail, so the second call re-probes live"
assert_eq "probe_failed" "$absence_d2" "the re-probe against the still-unreachable URL fails again, honestly"

# =============================================================================
# Scenario (e): concurrent writes don't lose records (review round 1, bug #3).
#
# 8 distinct providers (q0..q7), all needing a genuine live probe in the
# SAME batch, all pointed at the independent race server (scenario (b)
# killed the main fixture server already, so this uses its own). The old
# code had each backgrounded job do its OWN load_quota_cache -> merge-one-
# record -> save_quota_cache round trip against the ONE shared file --
# reproduced by the reviewer as a 5-of-8-lost race. The fix replaces that
# with pending-cache files plus a single sequential merge-and-save pass
# after the batch's `wait`, so there is now only ONE reader/writer of the
# shared file per call. Run several trials, inspecting the ACTUAL on-disk
# cache file after each one (not just the function's own stdout), to prove
# zero records are lost.
# =============================================================================

rm -f "$pdir"/*.env
for q in q0 q1 q2 q3 q4 q5 q6 q7; do
  cma_provider_write_env "$q" "" router "http://example.invalid" "model-x" "model-x" \
    "$HOME/.claude-prov-$q" 128000 8192 "$q"
done

RACE_TRIALS=5
race_all_ok=1
race_detail=""
for trial in $(seq 1 "$RACE_TRIALS"); do
  rm -f "$CACHE_FILE"
  CMA_QUOTA_MAX_PARALLEL_PROBES=10 _cma_quota_probe_all 1 3 >/dev/null   # fresh=1, all 8 genuinely concurrent

  present_count="$(
  python3 - "$ISO_LIB_DIR" "$CACHE_FILE" <<'PYEOF'
import sys, json
sys.path.insert(0, sys.argv[1])
import quota_probe as qp
data = qp.load_quota_cache(sys.argv[2])
providers = data.get("providers", {})
expected = ["q0", "q1", "q2", "q3", "q4", "q5", "q6", "q7"]
present = [p for p in expected if p in providers]
print(len(present))
PYEOF
  )"
  if [[ "$present_count" != "8" ]]; then
    race_all_ok=0
    race_detail="${race_detail}trial $trial: only $present_count/8 present; "
  fi
done

it "scenario (e): all 8 concurrently-probed providers survive in the on-disk cache, across $RACE_TRIALS trials (zero records lost)"
assert_eq "1" "$race_all_ok" "every trial has all 8/8 providers present in the real cache file on disk${race_detail:+ -- failures: $race_detail}"

# =============================================================================
# Scenario (f): a concurrent READER never sees a torn cache write (known-
# issues T17b-race-test-weak / T17b-crossprocess-race).
#
# Scenario (e) cannot prove the cross-process race: within one run there is a
# single writer, and it inspects the file only after the writer is done, so it
# stays green against a save_quota_cache that truncates the file in place and
# dumps into it. The real exposure is the cached-branch read, which is NOT
# under the cache lock: another `quota` run can load the file WHILE a save is
# in flight. A non-atomic save leaves a window in which the file is empty or
# half-written; the loader then degrades to an empty cache and the reader
# silently loses every record.
#
# The real save_quota_cache / load_quota_cache from the isolated copy are
# hammered from two processes: a writer saving a large (multi-MB, so each
# dump spans many write syscalls) cache repeatedly, and a reader loading it in
# a tight loop until the writer finishes. Every load must return the sentinel
# record. The reader's load count is asserted too, so a reader that never
# overlapped the writer cannot pass vacuously.
# =============================================================================

torn_out="$(
python3 - "$ISO_LIB_DIR" "$HOME/torn-cache/quota-cache.json" <<'PYEOF'
import os, sys, time
sys.path.insert(0, sys.argv[1])
import quota_probe as qp
path = sys.argv[2]
win = [{"window": "daily", "amount_used": 1, "amount_remaining": 9, "limit_total": 10,
        "unit": "requests", "percent_remaining": 90.0, "resets": False, "reset_at": None}]
def payload():
    provs = {"sentinel": {"provider_id": "sentinel", "windows": win, "_cached_at": time.time()}}
    for i in range(6000):
        provs["pad%05d" % i] = {"provider_id": "pad%05d" % i, "windows": win,
                                "note": "x" * 200, "_cached_at": time.time()}
    return {"providers": provs}
qp.save_quota_cache(path, payload())   # the file exists and is whole before the reader starts
child = os.fork()
if child == 0:
    for _ in range(25):
        qp.save_quota_cache(path, payload())
    os._exit(0)
loads = torn = 0
while True:
    done = os.waitpid(child, os.WNOHANG)[0] != 0
    d = qp.load_quota_cache(path)
    loads += 1
    if "sentinel" not in d.get("providers", {}):
        torn += 1
    if done:
        break
print(loads, torn)
PYEOF
)"
torn_loads="${torn_out% *}"; torn_count="${torn_out#* }"

it "scenario (f): the reader genuinely overlapped the writer (non-vacuous)"
torn_overlap=0; [[ "$torn_loads" =~ ^[0-9]+$ ]] && (( torn_loads >= 20 )) && torn_overlap=1
assert_eq "1" "$torn_overlap" "the reader must complete many loads while the writer runs (got loads='$torn_loads')"

it "scenario (f): a concurrent reader NEVER observes a torn cache write (atomic temp+rename save)"
assert_eq "0" "$torn_count" "every concurrent load must return the sentinel record; $torn_count of $torn_loads loads saw an empty or half-written cache"

summary
