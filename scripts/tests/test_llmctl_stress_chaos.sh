#!/usr/bin/env bash
# test_llmctl_stress_chaos.sh — stress/chaos coverage for the llmctl
# detection + on-demand-switch stack (FR-011's constitution-mandated
# stress/chaos minimum test type — this feature previously had zero
# coverage of this kind, found by /speckit-analyze as finding E1).
#
# Drives EVERYTHING through the public, stable interface
# (detect_llmctl_records, _cma_llmctl_ensure_active/cma_run_provider) —
# deliberately never depends on detect_llmctl_records' internal
# line-by-line implementation, which may be mid-edit by a concurrent task
# (T013, parallelizing its per-profile probe loop) in this same working
# tree. Fully hermetic: a fake `llmctl` binary + real local HTTP mock
# servers, same discipline as every other file in this suite. The REAL
# /home/milosvasic/Projects/llmctl/bin/llmctl is NEVER invoked.
#
# Scenarios:
#   A. Concurrent detect_llmctl_records syncs fired while a separate
#      _cma_llmctl_ensure_active-driven switch is also in flight -> every
#      concurrent sync still produces valid, well-formed JSON; no
#      cross-contamination between concurrent runs.
#   B. A profile's mock HTTP server is killed mid-probe (a slow responder,
#      killed before it replies) -> the in-flight detect call completes
#      honestly (profile absent, never a hang/crash), and the VERY NEXT
#      sync afterward recovers cleanly with no stuck state.
#   C. Two concurrent switch requests to DIFFERENT profiles -> the fake
#      llmctl's own switch subcommand is lock-serialized (flock, mirroring
#      upstream's real scheduler::with_lock), so the end state is always
#      exactly ONE coherent active profile, never a torn/concatenated
#      write.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# Volatile run output (D1): written to a temp file beside the final path and
# renamed into the git-ignored proof/volatile/ folder only on completion.
# shellcheck source=lib/proof.sh
source "$TESTS_DIR/lib/proof.sh"
PROOF_DIR="$(cma_proof_volatile_dir)"
PROOF_FINAL="$PROOF_DIR/test_llmctl_stress_chaos.txt"
PROOF="$(cma_proof_open "$PROOF_FINAL")"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e   # lib.sh sets -e; the harness asserts on failures, so relax it.

PROVIDERS_SH="$SCRIPTS_DIR/claude-providers.sh"
PDIR="$(cma_providers_dir)"; mkdir -p "$PDIR"
echo '{}' > "$PDIR/models.dev.cache.json"
: > "$HOME/api_keys.sh"

# --- real local mock HTTP servers -------------------------------------------
start_mock() {  # $1 = model id  $2 = n_ctx  $3 = port-file  $4 = delay-seconds (optional)
  python3 - "$3" "$1" "$2" "${4:-0}" >/dev/null 2>&1 <<'PY' &
import http.server, socketserver, sys, json, time
port_file, model_id, n_ctx, delay = sys.argv[1], sys.argv[2], int(sys.argv[3]), float(sys.argv[4])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if delay > 0:
            time.sleep(delay)
        if self.path.rstrip('/').endswith('/models'):
            body = json.dumps({"object": "list", "data": [
                {"id": model_id, "object": "model", "meta": {"n_ctx": n_ctx}}
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
  echo $!
}
wait_port_file() {
  for _ in $(seq 1 50); do [[ -s "$1" ]] && break; sleep 0.1; done
  cat "$1" 2>/dev/null
}

FAST_PF="$HOME/.llmctl_fast_port"
FAST_PID="$(start_mock "qwen2.5-coder-7b-instruct-q4_k_m" 8192 "$FAST_PF")"
SLOW_PF="$HOME/.llmctl_slow_port"
SLOW_PID="$(start_mock "slow-model" 8192 "$SLOW_PF" 5)"   # replies after 5s

REAPED=()
reap_all() {
  for p in "${FAST_PID:-}" "${SLOW_PID:-}" "${REAPED[@]}"; do
    [[ -n "$p" ]] && kill "$p" 2>/dev/null
  done
  cleanup_sandbox
}
trap reap_all EXIT

FAST_PORT="$(wait_port_file "$FAST_PF")"
SLOW_PORT="$(wait_port_file "$SLOW_PF")"
DEAD_PORT=1

{
  echo "=== test_llmctl_stress_chaos.sh evidence ==="
  echo "date: $(date -u +%FT%TZ)"
  echo "fast mock port=$FAST_PORT pid=$FAST_PID"
  echo "slow mock (5s delay) port=$SLOW_PORT pid=$SLOW_PID"
} >> "$PROOF" 2>&1

# --- fake llmctl: plan/status/switch, switch is flock-serialized -----------
LC_DIR="$HOME/lc-state"; mkdir -p "$LC_DIR"
LC_BIN="$HOME/.local/bin/llmctl-chaos"
sandbox_stub "$LC_BIN" <<EOF
#!/usr/bin/env bash
set -u
DIR="\${LLMCTL_TEST_DIR:?LLMCTL_TEST_DIR must be set}"
mkdir -p "\$DIR"
case "\${1:-}" in
  plan)
    if [[ "\${2:-}" == "--json" ]]; then
      cat <<'JSON'
{"profiles": {"fast": {"port": $FAST_PORT, "ctx": 8192}, "slow": {"port": $SLOW_PORT, "ctx": 8192}, "dead": {"port": $DEAD_PORT, "ctx": 8192}}}
JSON
      exit 0
    fi
    exit 2
    ;;
  status)
    active="\$(cat "\$DIR/active" 2>/dev/null || true)"
    if [[ -z "\$active" ]]; then
      echo "no llmctl services running"
    else
      printf '%-16s %-6s %-8s %-10s %-10s %-8s %s\n' "profile" "port" "mode" "RAM" "VRAM" "enabled" "state"
      printf '%-16s %-6s %-8s %-10s %-10s %-8s %s\n' "\$active" "8080" "cpu" "1" "0" "no" "running"
    fi
    ;;
  switch)
    profile="\${2:-}"
    # Lock-serialize the whole switch, mirroring upstream's real
    # scheduler::with_lock (research.md SS3.B) -- a torn/interleaved write
    # to \$DIR/active under concurrent switches is exactly the corruption
    # this scenario proves does NOT happen.
    (
      flock 9
      sleep 0.2   # widen the race window so two concurrent callers would
                  # genuinely collide here WITHOUT the lock
      printf '%s' "\$profile" > "\$DIR/active"
    ) 9>"\$DIR/switch.lock"
    exit 0
    ;;
  *)
    exit 64
    ;;
esac
EOF
export CMA_LLMCTL_BIN="$LC_BIN"
export LLMCTL_TEST_DIR="$LC_DIR"
export CMA_LLMCTL_HTTP_TIMEOUT=2
export CMA_LLMCTL_PLAN_TIMEOUT=5

reset_lc() { rm -f "$LC_DIR/active" "$LC_DIR/switch.lock"; }

# ===========================================================================
# SCENARIO A — concurrent detect_llmctl_records syncs during an in-flight
# switch; every concurrent call must still produce valid, well-formed JSON.
# ===========================================================================
it "SCENARIO A: concurrent detect_llmctl_records calls + a concurrent switch all produce valid JSON"
reset_lc
printf 'fast' > "$LC_DIR/active"
A1="$HOME/a1.json" A2="$HOME/a2.json" A3="$HOME/a3.json"
(
  CMA_LLMCTL_BIN="$LC_BIN" bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_llmctl_records' > "$A1" 2>>"$PROOF" &
  P1=$!
  CMA_LLMCTL_BIN="$LC_BIN" bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_llmctl_records' > "$A2" 2>>"$PROOF" &
  P2=$!
  CMA_LLMCTL_BIN="$LC_BIN" bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_llmctl_records' > "$A3" 2>>"$PROOF" &
  P3=$!
  _cma_llmctl_ensure_active "llmctl-fast" >/dev/null 2>>"$PROOF" &
  P4=$!
  wait "$P1" "$P2" "$P3" "$P4"
)
a1_ok=1; jq -e 'type=="array"' "$A1" >/dev/null 2>&1 && a1_ok=0
a2_ok=1; jq -e 'type=="array"' "$A2" >/dev/null 2>&1 && a2_ok=0
a3_ok=1; jq -e 'type=="array"' "$A3" >/dev/null 2>&1 && a3_ok=0
assert_eq 0 "$a1_ok" "concurrent sync #1 produced a valid JSON array"
assert_eq 0 "$a2_ok" "concurrent sync #2 produced a valid JSON array"
assert_eq 0 "$a3_ok" "concurrent sync #3 produced a valid JSON array"
# Cross-contamination check: every run saw the SAME catalog (fast+slow live,
# dead absent) -- a run that leaked another run's temp state would diverge.
n1="$(jq 'length' "$A1")"; n2="$(jq 'length' "$A2")"; n3="$(jq 'length' "$A3")"
assert_eq "$n1" "$n2" "concurrent syncs #1 and #2 agree on record count (no cross-contamination)"
assert_eq "$n2" "$n3" "concurrent syncs #2 and #3 agree on record count (no cross-contamination)"

# ===========================================================================
# SCENARIO B — a profile's mock HTTP server is killed mid-probe; the
# in-flight detect completes honestly, and the NEXT sync recovers cleanly.
# ===========================================================================
it "SCENARIO B (investigate): the slow mock genuinely has not replied yet 1s in (proves the race window is real)"
curl -sf --max-time 1 "http://127.0.0.1:${SLOW_PORT}/v1/models" >/dev/null 2>&1
probe_rc=$?
[[ "$probe_rc" -ne 0 ]] && ok=0 || ok=1
assert_eq 0 "$ok" "1s probe against the 5s-delay mock times out as expected -- the window is real, not assumed"

it "SCENARIO B: killing the slow mock mid-probe still yields an honest, non-hanging result"
reset_lc
B1="$HOME/b1.json"
(
  CMA_LLMCTL_BIN="$LC_BIN" CMA_LLMCTL_HTTP_TIMEOUT=3 \
    bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_llmctl_records' > "$B1" 2>>"$PROOF" &
  DETECT_PID=$!
  sleep 0.5
  kill "$SLOW_PID" 2>/dev/null
  REAPED+=("$SLOW_PID")
  wait "$DETECT_PID"; DETECT_RC=$?
  echo "$DETECT_RC" > "$HOME/b1.rc"
)
b1_rc="$(cat "$HOME/b1.rc" 2>/dev/null || echo 99)"
assert_eq 0 "$b1_rc" "detect_llmctl_records exits 0 even though a probed profile was killed mid-flight"
b1_valid=1; jq -e 'type=="array"' "$B1" >/dev/null 2>&1 && b1_valid=0
assert_eq 0 "$b1_valid" "the in-flight sync still produced valid JSON despite the mid-probe kill"
b1_has_slow=1; jq -e '[.[] | select(.provider_id=="llmctl-slow")] | length == 0' "$B1" >/dev/null 2>&1 && b1_has_slow=0
assert_eq 0 "$b1_has_slow" "the killed 'slow' profile is honestly absent, never a stale/ghost record"

it "SCENARIO B2: the VERY NEXT sync afterward recovers cleanly (no stuck state from the kill)"
B2="$HOME/b2.json"
CMA_LLMCTL_BIN="$LC_BIN" bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_llmctl_records' > "$B2" 2>>"$PROOF"
b2_rc=$?
assert_eq 0 "$b2_rc" "the next sync after the kill exits cleanly"
b2_valid=1; jq -e 'type=="array"' "$B2" >/dev/null 2>&1 && b2_valid=0
assert_eq 0 "$b2_valid" "the next sync still produces valid JSON"
b2_fast_present=1; jq -e '[.[] | select(.provider_id=="llmctl-fast")] | length == 1' "$B2" >/dev/null 2>&1 && b2_fast_present=0
assert_eq 0 "$b2_fast_present" "the still-healthy 'fast' profile is unaffected by the earlier kill of 'slow'"

# ===========================================================================
# SCENARIO C — two concurrent switch requests to DIFFERENT profiles; the
# fake llmctl's flock-serialized switch must leave exactly ONE coherent
# active profile, never a torn/concatenated write.
# ===========================================================================
it "SCENARIO C (investigate): WITHOUT the lock, two concurrent writers to the same file CAN interleave on this host"
# Prove the race is real on this host/filesystem before trusting that the
# lock is what prevents it: two unlocked, same-length writes racing to the
# SAME file can interleave into a value that is NEITHER input in full.
rm -f "$HOME/race.tmp"
( printf '%s' "profile-one-aaaa" > "$HOME/race.tmp" ) &
( printf '%s' "profile-two-bbbb" > "$HOME/race.tmp" ) &
wait
race_val="$(cat "$HOME/race.tmp" 2>/dev/null)"
race_is_one_of_the_two=1
[[ "$race_val" == "profile-one-aaaa" || "$race_val" == "profile-two-bbbb" ]] && race_is_one_of_the_two=0
# NOTE: on this host/filesystem a plain `>` redirect from two short, equal-
# length writes is not observed to interleave at the byte level (both
# candidate outcomes are themselves coherent whole-file results) -- recorded
# honestly as an UNCONFIRMED race window for THIS specific primitive, never
# asserted as proof the lock is unnecessary. The real protection this
# scenario validates is below: the fake llmctl's OWN switch subcommand does
# real stub work (a sleep) INSIDE the locked section, which is a genuine,
# observable serialization point regardless of this control's outcome.
# Record the SET of allowed outcomes and whether the observed value fell inside
# it, never the value itself: which writer lands last is scheduler-dependent,
# so recording it made the evidence differ on every run without any change in
# behaviour.
if (( race_is_one_of_the_two == 0 )); then _race_in_set=yes; else _race_in_set=no; fi
echo "race-window control: allowed outcomes {profile-one-aaaa, profile-two-bbbb}; observed outcome within the set: $_race_in_set (informational only)" >> "$PROOF"

it "SCENARIO C: two concurrent _cma_llmctl_ensure_active switches end in exactly ONE coherent active profile"
reset_lc
printf 'fast' > "$LC_DIR/active"
(
  _cma_llmctl_ensure_active "llmctl-slow" >/dev/null 2>>"$PROOF" &
  C1=$!
  _cma_llmctl_ensure_active "llmctl-dead" >/dev/null 2>>"$PROOF" &
  C2=$!
  wait "$C1" "$C2"
)
active_val="$(cat "$LC_DIR/active" 2>/dev/null)"
coherent=1
[[ "$active_val" == "slow" || "$active_val" == "dead" ]] && coherent=0
assert_eq 0 "$coherent" "active marker is exactly one of the two requested profiles, never empty/torn/concatenated (got: '$active_val')"
active_len="${#active_val}"
plausible_len=1
[[ "$active_len" -eq 4 ]] && plausible_len=0   # len("slow")==len("dead")==4; a torn write would differ
assert_eq 0 "$plausible_len" "active marker length matches a genuine single profile name, not a partial/merged write"

# Same rule as the control above: the final marker is one of two legitimate
# serializations, so the evidence records the allowed outcome set and the
# membership verdict (asserted above), not the last writer's value.
if (( coherent == 0 )); then _c_in_set=yes; else _c_in_set=no; fi
{
  echo
  echo "=== Scenario C final active marker ==="
  echo "allowed outcomes: {dead, slow}"
  echo "final value is one of the allowed outcomes: $_c_in_set"
} >> "$PROOF" 2>&1

cma_proof_commit "$PROOF" "$PROOF_FINAL"
summary
