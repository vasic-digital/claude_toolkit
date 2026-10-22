#!/usr/bin/env bash
# test_jev_gate.sh — hermetic tests for scripts/jev-gate.sh against the stdlib
# fake systemone fixture (scripts/tests/fixtures/jev_server.py, canonical §1.2 dialect).
#
# Cases:
#   a. shadow mode: fixture answers deny -> exit 0 + JSON allow + jsonl line
#      with "mode":"shadow","answer":"deny"
#   b. enforce: deny -> permissionDecision "deny" JSON + exit 2
#   c. risk floor: fixture answers allow with risky 0.9 -> ask
#   d. deterministic pattern floor: rm -rf / with allow/low-risk -> ask
#   e. timeout fail-open: 3s-sleep fixture, JEV_GATE_TIMEOUT=1 -> allow +
#      fallback "timeout", wall-clock < 3s
#   f. JEV_GATE=off -> instant allow, nothing logged
#   g. decisions.jsonl schema keys present; raw secret NOT logged
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
set +e

GATE="$SCRIPTS_DIR/jev-gate.sh"
FIXTURE="$SCRIPTS_DIR/tests/fixtures/jev_server.py"
export JEV_STATE_DIR="$HOME/.local/state/jev"

_pick_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

_start_fixture() { # _start_fixture <responses-json> [delay]
  local port; port=$(_pick_port)
  printf '%s' "$1" > "$HOME/fixture-responses.json"
  CMA_JEV_FIXTURE_RESPONSES="$HOME/fixture-responses.json" \
  CMA_JEV_FIXTURE_DELAY="${2:-0}" \
    python3 "$FIXTURE" "$port" &
  FIX_PID=$!
  local i
  for i in $(seq 1 40); do
    curl -sf -m 1 "http://127.0.0.1:$port/healthz" >/dev/null 2>&1 && break
    sleep 0.1
  done
  JEV_FIX_PORT="$port"
}

_stop_fixture() { kill "$FIX_PID" 2>/dev/null; wait "$FIX_PID" 2>/dev/null; }

HOOK_LS='{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'

it "shadow mode logs the would-be decision and passes through (never asserts allow)"
_start_fixture '{"gate":"deny"}'
out=$(printf '%s' "$HOOK_LS" | JEV_BASE_URL="http://127.0.0.1:$JEV_FIX_PORT" JEV_MODE=shadow bash "$GATE")
rc=$?
assert_eq 0 "$rc" "shadow gate exits 0"
assert_eq "" "$out" "shadow mode emits no JSON (passthrough -- never asserts permissionDecision:allow)"
assert_file "$JEV_STATE_DIR/decisions.jsonl" "shadow decision logged"
line=$(tail -n1 "$JEV_STATE_DIR/decisions.jsonl")
assert_eq '["deny","shadow",false]' "$(printf '%s' "$line" | jq -c '[.answer,.mode,.enforced]')" "shadow jsonl answer/mode/enforced"
_stop_fixture

it "enforce mode denies with JSON + exit 2"
_start_fixture '{"gate":"deny"}'
out=$(printf '%s' "$HOOK_LS" | JEV_BASE_URL="http://127.0.0.1:$JEV_FIX_PORT" JEV_MODE=enforce JEV_AGENT=claude bash "$GATE" 2>/dev/null)
rc=$?
assert_eq 2 "$rc" "enforce deny exits 2"
case "$out" in *'"permissionDecision":"deny"'*) _pass "enforce JSON says deny" ;; *) _fail "enforce JSON" "$out" ;; esac
assert_eq '"claude"' "$(tail -n1 "$JEV_STATE_DIR/decisions.jsonl" | jq -c '.agent')" "agent field from JEV_AGENT"
_stop_fixture

it "risk floor: allow + risky 0.9 escalates to ask"
_start_fixture '{"gate":"allow","risky":0.9}'
out=$(printf '%s' "$HOOK_LS" | JEV_BASE_URL="http://127.0.0.1:$JEV_FIX_PORT" JEV_MODE=enforce bash "$GATE")
rc=$?
assert_eq 0 "$rc" "ask exits 0"
case "$out" in *'"permissionDecision":"ask"'*) _pass "risk floor says ask" ;; *) _fail "risk floor JSON" "$out" ;; esac
_stop_fixture

it "deterministic pattern floor: rm -rf / forced to at least ask"
_start_fixture '{"gate":"allow","risky":0.1}'
out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"rm -rf / --no-preserve-root"}}' \
  | JEV_BASE_URL="http://127.0.0.1:$JEV_FIX_PORT" JEV_MODE=enforce bash "$GATE")
case "$out" in *'"permissionDecision":"ask"'*|*'"permissionDecision":"deny"'*) _pass "pattern floor escalated" ;; *) _fail "pattern floor" "$out" ;; esac
_stop_fixture

it "timeout fail-open within budget (passthrough, never asserts allow)"
_start_fixture '{}' 3
t0=$SECONDS
out=$(printf '%s' "$HOOK_LS" | JEV_BASE_URL="http://127.0.0.1:$JEV_FIX_PORT" JEV_MODE=enforce JEV_GATE_TIMEOUT=1 bash "$GATE")
dt=$(( SECONDS - t0 ))
rc=$?
assert_eq 0 "$rc" "timeout exits 0"
assert_eq "" "$out" "timeout fail-open emits no JSON (passthrough -- never asserts permissionDecision:allow)"
if (( dt < 3 )); then _pass "fail-open within ${dt}s (<3s)"; else _fail "fail-open too slow" "${dt}s"; fi
assert_eq '"timeout"' "$(tail -n1 "$JEV_STATE_DIR/decisions.jsonl" | jq -c '.fallback')" "fallback recorded as timeout"
_stop_fixture

it "JEV_GATE=off is instant allow with no log"
before=$(wc -l < "$JEV_STATE_DIR/decisions.jsonl" 2>/dev/null || echo 0)
out=$(printf '%s' "$HOOK_LS" | JEV_GATE=off JEV_BASE_URL="http://127.0.0.1:1" bash "$GATE")
rc=$?
after=$(wc -l < "$JEV_STATE_DIR/decisions.jsonl" 2>/dev/null || echo 0)
assert_eq 0 "$rc" "gate off exits 0"
assert_eq "$before" "$after" "gate off logs nothing"

it "a calibrated decisions.lock.json lowers the ask threshold below its 0.7 default"
_start_fixture '{"gate":"allow","risky":0.5}'
# Without a lock file, risky=0.5 stays under the default 0.7 ask floor -> allow.
out=$(printf '%s' "$HOOK_LS" | JEV_BASE_URL="http://127.0.0.1:$JEV_FIX_PORT" JEV_MODE=enforce bash "$GATE")
case "$out" in *'"permissionDecision":"allow"'*) _pass "no lock file: default 0.7 threshold -> allow" ;; *) _fail "expected allow with no lock file" "$out" ;; esac
# With a calibrated lock file lowering ask_threshold to 0.3, the same risky=0.5 now escalates.
printf '{"ask_threshold":0.3,"deny_threshold":0.95,"calibrated_at":"test","sample_size":4}' > "$JEV_STATE_DIR/decisions.lock.json"
out=$(printf '%s' "$HOOK_LS" | JEV_BASE_URL="http://127.0.0.1:$JEV_FIX_PORT" JEV_MODE=enforce bash "$GATE")
case "$out" in *'"permissionDecision":"ask"'*) _pass "lock file ask_threshold=0.3 escalates risky=0.5 to ask" ;; *) _fail "lock file threshold not honored" "$out" ;; esac
# An explicit env var still wins over the lock file (0.95 > 0.5 -> back to allow).
out=$(printf '%s' "$HOOK_LS" | JEV_BASE_URL="http://127.0.0.1:$JEV_FIX_PORT" JEV_MODE=enforce JEV_RISKY_THRESHOLD=0.95 bash "$GATE")
case "$out" in *'"permissionDecision":"allow"'*) _pass "explicit env var overrides the lock file" ;; *) _fail "explicit env JEV_RISKY_THRESHOLD should override the lock file" "$out" ;; esac
rm -f "$JEV_STATE_DIR/decisions.lock.json"
_stop_fixture

it "jsonl schema keys present and raw secret absent"
line=$(tail -n1 "$JEV_STATE_DIR/decisions.jsonl")
keys=$(printf '%s' "$line" | jq -c 'keys')
for k in ts agent tool state_hash question answer latency_ms endpoint mode enforced; do
  case "$keys" in *"\"$k\""*) _pass "schema key: $k" ;; *) _fail "schema missing key" "$k" ;; esac
done
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"echo SUPERSECRETPASS123"}}' \
  | JEV_GATE=on JEV_BASE_URL="http://127.0.0.1:1" JEV_GATE_TIMEOUT=1 bash "$GATE" >/dev/null
if grep -q 'SUPERSECRETPASS123' "$JEV_STATE_DIR/decisions.jsonl"; then
  _fail "raw state leaked into decisions.jsonl"
else
  _pass "raw state not logged (hash only)"
fi

summary
