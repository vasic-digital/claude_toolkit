#!/usr/bin/env bash
# test_jev_detect_https_mutation.sh — paired mutation proof. Every defect class
# named by the independent review (key on argv, http bearer leak, loopback
# prefix match, TLS verification off, redirect replay, CA-path export, exit-75
# conflation, STRICT bypass, broken anchors/diagrams...) is re-introduced into
# a COPY of the repo (never the real tree) and the owning suite MUST then FAIL.
# The unmutated copy MUST pass. A mutation that leaves its suite green means
# the suite is decoration. The table lives in lib/jev_mutations.py.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
set +e
TBL="$TESTS_DIR/lib/jev_mutations.py"
WORK="$(mktemp -d "$HOME/mut.XXXXXX")"
mkdir -p "$HOME/inner"

fresh() {
  rm -rf "$WORK/repo"; mkdir -p "$WORK/repo"
  # everything tracked at the top level except heavyweight/irrelevant trees
  # (specs/ is KEPT: test_docs_hub_engine_release.sh asserts the git-tracked
  # specs/003-jev-decision-layer files, so excluding it made its rows vacuous - R5-3)
  ( cd "$REPO_ROOT" && tar --exclude=./node_modules --exclude=./.git --exclude=./tmp --exclude=./upstreams \
      --exclude=./submodules --exclude=./qa-results -cf - . ) | ( cd "$WORK/repo" && tar -xf - )
}
# A suite that never ends under a mutation (a lock that never gives up, a stale lock never broken)
# is a detected defect, not a stall of this harness: each suite run is time-bounded and rc 124
# counts as "FAILs under the mutation". The bound applies to the unmutated control too, where a
# timeout is a control failure. JEV_MUT_SUITE_TIMEOUT (seconds, default 900) tunes it.
runsuite() { # runsuite <suite-file>
  ( cd "$WORK/repo/scripts/tests" && env -i HOME="$HOME/inner" TMPDIR="$HOME/inner" PATH="$PATH" \
      timeout -k 5 "${JEV_MUT_SUITE_TIMEOUT:-900}" bash "$1" >"$WORK/out.txt" 2>&1 ); }

it "control: the unmutated copy passes every owning suite"
# every suite that owns a mutation row, derived from the table (plus the
# original three), so a suite added to the table is controlled automatically
CONTROL_SUITES="$( { printf '%s\n' test_jev_detect_https.sh test_llmctl_vision_gate_wiring.sh test_docs_hub_engine_release.sh test_hardening_r2.sh
  python3 "$TBL" list | cut -f2; } | sort -u )"
ctl_fail=0
for suite in $CONTROL_SUITES; do
  fresh; runsuite "$suite"; crc=$?; assert_eq 0 "$crc" "$suite passes unmutated"
  if (( crc != 0 )); then ctl_fail=$((ctl_fail+1)); echo "    control failure output ($suite):"; sed 's/^/      /' "$WORK/out.txt" | tail -20; fi
done
# A failing control makes every kill below vacuous (the suite fails with or without
# the mutation): stop loudly instead of counting those kills.
if (( ctl_fail > 0 )); then
  _fail "controls: $ctl_fail owning suite(s) fail on the UNMUTATED copy" "mutation results would be vacuous - aborting before any kill is counted"
  summary; exit 1
fi

n=0
while IFS=$'\t' read -r idx suite label; do
  n=$((n+1))
  it "mutation $idx: $label"
  fresh
  python3 "$TBL" apply "$idx" "$WORK/repo" 2>"$WORK/err.txt"; rc=$?
  if (( rc != 0 )); then _fail "mutation applies" "$(cat "$WORK/err.txt") (rc=$rc)"; continue; fi
  runsuite "$suite"; src=$?
  if (( src != 0 )); then _pass "$suite FAILs under the mutation"
  else _fail "$suite FAILs under the mutation" "suite stayed green: the defect class is not covered"; fi
done < <(python3 "$TBL" list)
want_n="$(python3 "$TBL" list | wc -l)"
(( n > 0 && n == want_n )) && _pass "positive control: all $n table mutations were run" || _fail "positive control" "ran $n of $want_n table mutations"

it "no fixture server survives the mutation run"
sleep 0.5
leak="$(pgrep -f "jev_https_server.py .*$WORK" | wc -l)"
assert_eq 0 "$leak" "no leaked fixture process under the mutation workspace"
summary
