#!/usr/bin/env bash
# test_jev_stats.sh — jev-stats.sh computes exact counts/latencies/savings
# from a fixture decisions.jsonl, honors the documented estimate formula and
# its env-overridable constants, and prints the friendly zero-state message.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
set +e

STATS="$SCRIPTS_DIR/jev-stats.sh"
export JEV_STATE_DIR="$HOME/.local/state/jev"
mkdir -p "$JEV_STATE_DIR"
NOW=$(( $(date +%s) * 1000 ))

cat > "$JEV_STATE_DIR/decisions.jsonl" <<EOF
{"ts":$NOW,"agent":"claude","tool":"Bash","state_hash":"a","question":"gate","answer":"allow","risky_p":0.1,"confidence":0.9,"latency_ms":100,"endpoint":"jev-local","mode":"shadow","enforced":false,"fallback":null}
{"ts":$NOW,"agent":"claude","tool":"Bash","state_hash":"b","question":"gate","answer":"deny","risky_p":0.9,"confidence":0.8,"latency_ms":200,"endpoint":"jev-local","mode":"shadow","enforced":false,"fallback":null}
{"ts":$NOW,"agent":"kimi","tool":"Bash","state_hash":"c","question":"gate","answer":"ask","risky_p":0.5,"confidence":0.7,"latency_ms":300,"endpoint":"jev-local","mode":"enforce","enforced":true,"fallback":null}
{"ts":$NOW,"agent":"kimi","tool":"Bash","state_hash":"d","question":"gate","answer":"allow","risky_p":0.0,"confidence":0.0,"latency_ms":2000,"endpoint":"none","mode":"enforce","enforced":true,"fallback":"timeout"}
EOF

it "--json computes exact numbers"
out=$(bash "$STATS" --json)
rc=$?
assert_eq 0 "$rc" "exit 0"
assert_eq 4 "$(printf '%s' "$out" | jq -r '.total')" "total decisions"
assert_eq 2 "$(printf '%s' "$out" | jq -r '.by_answer.allow')" "allow count"
assert_eq 1 "$(printf '%s' "$out" | jq -r '.by_answer.deny')" "deny count"
assert_eq 1 "$(printf '%s' "$out" | jq -r '.by_answer.ask')" "ask count"
assert_eq 2 "$(printf '%s' "$out" | jq -r '.by_mode.shadow')" "shadow count"
assert_eq 2 "$(printf '%s' "$out" | jq -r '.by_agent.kimi')" "kimi count"
assert_eq 1 "$(printf '%s' "$out" | jq -r '.fallbacks')" "fallback count"
assert_eq 650 "$(printf '%s' "$out" | jq -r '.avg_latency_ms')" "avg latency (100+200+300+2000)/4"
# savings: 4*1500 + 1 enforced ask/deny * 200 = 6200
assert_eq 6200 "$(printf '%s' "$out" | jq -r '.est_tokens_saved')" "savings formula 4*1500+1*200"
assert_eq 1 "$(printf '%s' "$out" | jq -r '.shadow_would.deny')" "shadow would-deny"
assert_eq 1 "$(printf '%s' "$out" | jq -r '.enforced_ask_deny')" "enforced ask/deny"

it "formula constants are env-overridable"
out=$(JEV_EST_INPUT_TOKENS=100 JEV_EST_OUTPUT_TOKENS=10 bash "$STATS" --json)
assert_eq 410 "$(printf '%s' "$out" | jq -r '.est_tokens_saved')" "4*100+1*10 with overrides"
printf '%s' "$out" | jq -r '.formula' | grep -q '100' \
  && _pass "formula documents override values" || _fail "formula text"

it "human table renders and prints the formula"
out=$(bash "$STATS")
rc=$?
assert_eq 0 "$rc" "human exit 0"
case "$out" in
  *"ESTIMATE formula:"*"total decisions: 4"*"would-deny rate (shadow): 25.0%"*"ESTIMATED tokens saved: 6200"*)
    _pass "human table key lines" ;;
  *) _fail "human table" "$out" ;;
esac

it "empty log -> friendly zero-state, exit 0"
rm -f "$JEV_STATE_DIR/decisions.jsonl"
out=$(bash "$STATS")
rc=$?
assert_eq 0 "$rc" "zero-state exit 0"
case "$out" in *"No Jev decisions yet"*) _pass "zero-state message" ;; *) _fail "zero-state" "$out" ;; esac
out=$(bash "$STATS" --json)
assert_eq 0 "$(printf '%s' "$out" | jq -r '.total')" "zero-state json total"

it "--days filters old records"
mkdir -p "$JEV_STATE_DIR"
OLD=$(( NOW - 10 * 86400000 ))
printf '%s\n' \
  '{"ts":'$NOW',"agent":"claude","tool":"Bash","answer":"allow","latency_ms":100,"endpoint":"e","mode":"shadow","enforced":false,"fallback":null}' \
  '{"ts":'$OLD',"agent":"claude","tool":"Bash","answer":"deny","latency_ms":100,"endpoint":"e","mode":"shadow","enforced":false,"fallback":null}' \
  > "$JEV_STATE_DIR/decisions.jsonl"
out=$(bash "$STATS" --json --days 7)
assert_eq 1 "$(printf '%s' "$out" | jq -r '.total')" "--days 7 excludes the 10-day-old record"
out=$(bash "$STATS" --json)
assert_eq 2 "$(printf '%s' "$out" | jq -r '.total')" "no filter sees both"

summary
