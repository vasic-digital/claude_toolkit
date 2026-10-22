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
  ( cd "$REPO_ROOT" && tar --exclude=./node_modules --exclude=./.git --exclude=./tmp --exclude=./upstreams \
      --exclude=./submodules --exclude=./qa-results --exclude=./specs -cf - . ) | ( cd "$WORK/repo" && tar -xf - )
}
runsuite() { # runsuite <suite-file>
  ( cd "$WORK/repo/scripts/tests" && env -i HOME="$HOME/inner" TMPDIR="$HOME/inner" PATH="$PATH" \
      bash "$1" >"$WORK/out.txt" 2>&1 ); }

it "control: the unmutated copy passes every owning suite"
for suite in test_jev_detect_https.sh test_llmctl_vision_gate_wiring.sh test_docs_hub_engine_release.sh; do
  fresh; runsuite "$suite"; assert_eq 0 "$?" "$suite passes unmutated"
done

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
(( n >= 25 )) && _pass "positive control: $n mutations were run" || _fail "positive control" "only $n mutations ran"

it "no fixture server survives the mutation run"
sleep 0.5
leak="$(pgrep -f "jev_https_server.py .*$WORK" | wc -l)"
assert_eq 0 "$leak" "no leaked fixture process under the mutation workspace"
summary
