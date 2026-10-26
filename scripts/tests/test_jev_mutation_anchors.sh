#!/usr/bin/env bash
# test_jev_mutation_anchors.sh — FAST structural guard for the mutation table (round-7 M1).
# Editing an anchored source line silently strands a row of lib/jev_mutations.py and turns the
# multi-hour harness (test_jev_detect_https_mutation.sh) red. This checks in seconds that every
# row's `old` text is still present in its target file as often as the row expects.
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

it "every mutation row's anchor is present exactly as the harness expects (HEAD tree)"
python3 "$TBL" check "$REPO_ROOT" 2>"$HOME/err.txt"; rc=$?
assert_eq 0 "$rc" "no stale mutation row ($(cat "$HOME/err.txt" | head -3 | tr '\n' ' '))"
want_n="$(python3 "$TBL" list | wc -l)"
assert_eq "1" "$([ "$want_n" -ge 135 ] && echo 1 || echo 0)" "positive control: the table lists $want_n rows (>= 135)"

it "negative control: a deliberately stale anchor copy is detected"
CP="$HOME/stalecopy"; mkdir -p "$CP/scripts"
cp "$REPO_ROOT/scripts/jev-gate.sh" "$CP/scripts/jev-gate.sh"
# strand the anchor of the 'shipped-pin check dropped' row, the way an unrelated edit would
sed -i 's/\[ -f "\$_pinsf" \] && jq -e/[ -r "$_pinsf" ] \&\& jq -e/' "$CP/scripts/jev-gate.sh"
python3 "$TBL" check "$CP" 2>"$HOME/err2.txt"; rc2=$?
assert_eq 3 "$rc2" "stale copy -> rc 3"
assert_eq "1" "$(grep -c 'shipped-pin check dropped' "$HOME/err2.txt" | awk '{print ($1>=1)?1:0}')" "the stranded row is named on stderr"
summary
