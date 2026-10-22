#!/usr/bin/env bash
# test_jev_calibrate.sh — jev-calibrate.sh's label/sweep/check subcommands
# against hand-verifiable fixtures (threshold/accuracy values are exact
# rational comparisons; ECE/MCE are sanity-bounded, Brier is hand-verified).
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
set +e

CAL="$SCRIPTS_DIR/jev-calibrate.sh"
WORK="$HOME/jev-cal-work"
mkdir -p "$WORK"

# --- label: merges operator-supplied ground truth by line index ---
cat > "$WORK/decisions.jsonl" <<'EOF'
{"ts":1,"risky_p":0.2}
{"ts":2,"risky_p":0.6}
EOF
cat > "$WORK/labels.json" <<'EOF'
[{"index":0,"ground_truth_ask":false,"ground_truth_deny":false},
 {"index":1,"ground_truth_ask":true,"ground_truth_deny":false}]
EOF

it "label merges ground truth by index into labeled.jsonl"
out=$(bash "$CAL" label --data "$WORK/decisions.jsonl" --labels "$WORK/labels.json" --out "$WORK/labeled_small.jsonl")
rc=$?
assert_eq 0 "$rc" "exit 0"
assert_eq "false" "$(sed -n '1p' "$WORK/labeled_small.jsonl" | jq -r '.ground_truth_ask')" "row0 ground_truth_ask"
assert_eq "true" "$(sed -n '2p' "$WORK/labeled_small.jsonl" | jq -r '.ground_truth_ask')" "row1 ground_truth_ask"
assert_eq "false" "$(sed -n '2p' "$WORK/labeled_small.jsonl" | jq -r '.ground_truth_deny')" "row1 ground_truth_deny"

# --- sweep: hand-verified fixture ---
# Points (risky_p, gt_ask, gt_deny): (0.2,F,F) (0.6,T,F) (0.75,T,F) (0.9,T,T)
# Lowest tau reaching 100% accuracy on ask:  0.6  (tau=0.0/0.2 only reach 75%)
# Lowest tau reaching 100% accuracy on deny: 0.9  (tau<0.9 reach at most 75%)
# Brier (ask) = mean((p-y)^2) = (0.04+0.16+0.0625+0.01)/4 = 0.068125
cat > "$WORK/labeled.jsonl" <<'EOF'
{"risky_p":0.2,"ground_truth_ask":false,"ground_truth_deny":false}
{"risky_p":0.6,"ground_truth_ask":true,"ground_truth_deny":false}
{"risky_p":0.75,"ground_truth_ask":true,"ground_truth_deny":false}
{"risky_p":0.9,"ground_truth_ask":true,"ground_truth_deny":true}
EOF

it "sweep finds the exact hand-verified thresholds and Brier score"
out=$(bash "$CAL" sweep --data "$WORK/labeled.jsonl" --target-accuracy 1.0 --lock "$WORK/decisions.lock.json" --json)
rc=$?
assert_eq 0 "$rc" "exit 0"
assert_eq "0.6" "$(printf '%s' "$out" | jq -r '.ask_threshold')" "ask_threshold"
assert_eq "1.0" "$(printf '%s' "$out" | jq -r '.ask_threshold_accuracy')" "ask_threshold_accuracy"
assert_eq "0.9" "$(printf '%s' "$out" | jq -r '.deny_threshold')" "deny_threshold"
assert_eq "1.0" "$(printf '%s' "$out" | jq -r '.deny_threshold_accuracy')" "deny_threshold_accuracy"
assert_eq "0.068125" "$(printf '%s' "$out" | jq -r '.brier')" "brier (hand-verified)"
assert_eq "4" "$(printf '%s' "$out" | jq -r '.sample_size')" "sample_size"
assert_eq "1" "$([ -f "$WORK/decisions.lock.json" ] && echo 1 || echo 0)" "lock file written"
assert_eq "0.6" "$(jq -r '.ask_threshold' "$WORK/decisions.lock.json")" "lock file ask_threshold"
# ECE=0.2375, MCE=0.4 hand-verified: each of the 4 points falls in its own
# 10-wide bin (0.2/0.6/0.75/0.9), so avg_pred==p and the per-bin gap is
# |p - (1 or 0)|; weighted average over 4 equal-size bins is the mean of
# (0.2, 0.4, 0.25, 0.1) = 0.2375; MCE is the largest single gap, 0.4.
assert_eq "0.2375" "$(printf '%s' "$out" | jq -r '.ece')" "ece (hand-verified)"
assert_eq "0.4" "$(printf '%s' "$out" | jq -r '.mce')" "mce (hand-verified)"

it "sweep's ECE/MCE stay within the general calibration-metric bound"
ece=$(printf '%s' "$out" | jq -r '.ece')
mce=$(printf '%s' "$out" | jq -r '.mce')
assert_eq "1" "$(awk -v e="$ece" 'BEGIN{print (e>=0 && e<=1)?1:0}')" "ece in [0,1]"
assert_eq "1" "$(awk -v m="$mce" 'BEGIN{print (m>=0 && m<=1)?1:0}')" "mce in [0,1]"
assert_eq "1" "$(awk -v e="$ece" -v m="$mce" 'BEGIN{print (m>=e)?1:0}')" "mce >= ece (max gap can't be below weighted-average gap)"

# --- sweep: unreachable target is reported honestly as null, not fudged ---
cat > "$WORK/unreachable.jsonl" <<'EOF'
{"risky_p":0.5,"ground_truth_ask":true,"ground_truth_deny":false}
{"risky_p":0.5,"ground_truth_ask":false,"ground_truth_deny":false}
EOF
it "sweep reports null threshold when no cutoff can separate identical risky_p with conflicting ground truth"
out2=$(bash "$CAL" sweep --data "$WORK/unreachable.jsonl" --target-accuracy 1.0 --lock - --json)
assert_eq "null" "$(printf '%s' "$out2" | jq -r '.ask_threshold')" "ask_threshold null when unreachable"
assert_eq "true" "$(printf '%s' "$out2" | jq -r 'has("ask_note")')" "ask_note explains why"

# --- check: fresh data against the lock from the first sweep should PASS with ~0% drift ---
# Bounds are set to the hand-verified ECE/MCE (0.2375/0.4) themselves, since a
# 4-point toy fixture is nowhere near the 0.05/0.15 production targets the
# POC doc recommends -- this proves the PASS/drift math, not that the toy
# fixture is "calibrated" in any real sense.
it "check against the same labeled data the lock was built from reports PASS with ~0 drift"
out3=$(bash "$CAL" check --data "$WORK/labeled.jsonl" --lock "$WORK/decisions.lock.json" --max-ece 0.3 --max-mce 0.5 --json)
rc=$?
assert_eq 0 "$rc" "exit 0"
assert_eq "PASS" "$(printf '%s' "$out3" | jq -r '.verdict')" "verdict PASS"
assert_eq "0.0" "$(printf '%s' "$out3" | jq -r '.drift_pct')" "0% drift against its own calibration data"

it "check FAILs (exit 1) when ECE bound is set below the actual ECE"
bash "$CAL" check --data "$WORK/labeled.jsonl" --lock "$WORK/decisions.lock.json" --max-ece 0.0001 --json >/tmp/_jevcal_check_fail.$$  2>&1
rc=$?
assert_eq 1 "$rc" "exit 1 on bounds exceeded"
assert_eq "FAIL" "$(jq -r '.verdict' </tmp/_jevcal_check_fail.$$)" "verdict FAIL"
rm -f /tmp/_jevcal_check_fail.$$

it "check exits 2 on a missing lock file (config error, not a silent pass)"
bash "$CAL" check --data "$WORK/labeled.jsonl" --lock "$WORK/does-not-exist.json" >/dev/null 2>&1
assert_eq 2 "$?" "exit 2 config error"

it "--help prints usage without requiring any subcommand args"
bash "$CAL" --help >/tmp/_jevcal_help.$$ 2>&1
assert_eq 0 "$?" "exit 0"
assert_eq "1" "$(grep -qi 'label\|sweep\|check' /tmp/_jevcal_help.$$ && echo 1 || echo 0)" "help mentions subcommands"
rm -f /tmp/_jevcal_help.$$

summary
