#!/usr/bin/env bash
# test_proof_writers.sh — guards for the proof-tree contract (operator
# decisions D1 + D3, batch B-proof-writers).
#
# D1: regenerated run output is VOLATILE. It carries timestamps, ports, PIDs
#     and sandbox paths, so tracking it churned the tree on every run. Only
#     three curated files stay tracked (.gitkeep, PROOF.md, 00-summary.txt);
#     every other writer targets scripts/tests/proof/volatile/, which is
#     git-ignored.
#
# Atomicity: a writer that truncated its evidence file (`: > "$PROOF"`) and
#     then appended for the whole run let a concurrent reader see a partial
#     file (the 93-helixagent-pins case). Writers now build a temp file in the
#     SAME directory and rename it into place on completion, so a reader sees
#     either the previous complete file or the new complete file.
#
# D3: the host LAN address must never reach an output file. The LAN-exposure
#     test redacts it to a fixed placeholder at capture time.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox

# ---------------------------------------------------------------------------
it "D1: scripts/tests/proof/volatile/ is git-ignored; curated files are not"
if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$REPO_ROOT" check-ignore -q scripts/tests/proof/volatile/any-run-output.txt
  assert_eq 0 $? "volatile/ output is ignored"
  for c in .gitkeep PROOF.md 00-summary.txt; do
    git -C "$REPO_ROOT" check-ignore -q "scripts/tests/proof/$c"
    assert_eq 1 $? "curated $c is NOT ignored"
  done
else
  _pass "SKIP: not a git work tree"
fi

it "D1: exactly the three curated proof files are tracked"
if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  tracked="$(git -C "$REPO_ROOT" ls-files scripts/tests/proof/ | LC_ALL=C sort | tr '\n' ' ')"
  assert_eq "scripts/tests/proof/.gitkeep scripts/tests/proof/00-summary.txt scripts/tests/proof/PROOF.md " \
    "$tracked" "tracked proof set is the curated set"
else
  _pass "SKIP: not a git work tree"
fi

# ---------------------------------------------------------------------------
# Lint: no writer may default its output into the repo's top-level proof dir
# (or a non-volatile subfolder of it). A PROOF_DIR pointed into a sandbox
# ($SANDBOX_HOME, $HOME) is legitimate and not matched. Comment lines ignored.
# Positive evidence beside every "no violations" check: the number of shell
# files the lint actually swept, and grep's own exit status (1 = no match,
# anything above 1 = grep itself failed, which must never read as clean).
SWEPT="$(find "$SCRIPTS_DIR" -name '*.sh' -type f | wc -l | tr -d ' ')"
it "D1 lint: every PROOF_DIR default points into proof/volatile"
raw="$(grep -rnE --include='*.sh' \
        -e 'PROOF_DIR(:-|=)"?\$\{?(TESTS_DIR|TESTS_ROOT|REPO_ROOT|SCRIPTS_DIR)\}?[^[:space:]]*/proof(["}]|$)' \
        -e 'PROOF_DIR(:-|=)"?\$\{?(TESTS_DIR|TESTS_ROOT|REPO_ROOT|SCRIPTS_DIR)\}?[^[:space:]]*/proof/[^v"]' \
        "$SCRIPTS_DIR")"; grc=$?
(( grc <= 1 )); assert_eq 0 $? "grep ran cleanly (rc=$grc)"
(( SWEPT > 50 )); assert_eq 0 $? "the lint swept a real tree ($SWEPT shell files)"
bad="$(grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' <<<"$raw" | grep -v '^$')"
assert_eq "" "$bad" "no PROOF_DIR default outside proof/volatile"

it "atomic lint: no writer truncates its evidence file in place"
bad="$(grep -rnE --include='*.sh' \
        -e '^[[:space:]]*: ?> ?"\$(PROOF|EV|OUT|SUMMARY)"' \
        "$SCRIPTS_DIR")"; grc=$?
(( grc <= 1 )); assert_eq 0 $? "grep ran cleanly (rc=$grc) over $SWEPT shell files"
assert_eq "" "$bad" "no ': > \"\$PROOF\"'-style in-place truncation"

# ---------------------------------------------------------------------------
it "helper: lib/proof.sh exists and defines the writer API"
assert_file "$TESTS_DIR/lib/proof.sh" "lib/proof.sh present"
# shellcheck source=lib/proof.sh
source "$TESTS_DIR/lib/proof.sh" 2>/dev/null
for fn in cma_proof_volatile_dir cma_proof_open cma_proof_commit cma_proof_redact_ip; do
  declare -F "$fn" >/dev/null 2>&1; assert_eq 0 $? "$fn is defined"
done

it "helper: volatile dir is <tests>/proof/volatile"
assert_eq "$TESTS_DIR/proof/volatile" "$(cma_proof_volatile_dir 2>/dev/null)" "volatile dir path"

it "helper: open gives an empty temp in the SAME dir; final appears only on commit"
D="$HOME/pdir"; mkdir -p "$D"
FINAL="$D/ev.txt"
printf 'OLD COMPLETE\n' > "$FINAL"
TMPF="$(cma_proof_open "$FINAL" 2>/dev/null)"
[[ -n "$TMPF" && -f "$TMPF" && ! -s "$TMPF" ]]; assert_eq 0 $? "temp exists and is empty"
assert_eq "$D" "$(dirname "${TMPF:-/nonexistent/x}")" "temp is in the final file's directory"
printf 'NEW PARTIAL' >> "$TMPF" 2>/dev/null
assert_eq "OLD COMPLETE" "$(cat "$FINAL")" "a reader mid-write still sees the previous complete file"
ino_before="$(ls -i "$FINAL" 2>/dev/null | awk "{print \$1}")"
cma_proof_commit "$TMPF" "$FINAL" 2>/dev/null
assert_eq "NEW PARTIAL" "$(cat "$FINAL")" "after commit the final holds the new content"
[[ ! -e "$TMPF" ]]; assert_eq 0 $? "temp is gone after commit (renamed, not copied)"
ino_after="$(ls -i "$FINAL" 2>/dev/null | awk "{print \$1}")"
[[ -n "$ino_before" && "$ino_before" != "$ino_after" ]]; assert_eq 0 $? "commit replaced the inode (rename), never truncated in place"

it "helper: open creates a missing directory"
TMP2="$(cma_proof_open "$HOME/newdir/sub/ev2.txt" 2>/dev/null)"
[[ -f "$TMP2" ]]; assert_eq 0 $? "temp created under a fresh directory"

# ---------------------------------------------------------------------------
it "D3 helper: redact_ip replaces exactly the given IPv4 with 192.168.x.x"
out="$(printf 'LISTEN 0 1 192.168.1.115:53409 0.0.0.0:*\nbound to 192.168.1.115\n127.0.0.1:80 192x168x1x115\n' \
       | cma_proof_redact_ip "192.168.1.115" 2>/dev/null)"
assert_eq "LISTEN 0 1 192.168.x.x:53409 0.0.0.0:*
bound to 192.168.x.x
127.0.0.1:80 192x168x1x115" "$out" "only the literal address is replaced (dots are not wildcards)"

it "D3 helper: redact_ip never rewrites a longer address that shares the prefix"
out="$(printf '10.0.0.1 10.0.0.15 10.0.0.1\n' | cma_proof_redact_ip "10.0.0.1" 2>/dev/null)"
assert_eq "192.168.x.x 10.0.0.15 192.168.x.x" "$out" "boundary-safe replacement"

it "D3 helper: redact_ip with an empty address is a pass-through"
out="$(printf 'a 10.0.0.1 b\n' | cma_proof_redact_ip "" 2>/dev/null)"
assert_eq "a 10.0.0.1 b" "$out" "no address -> unchanged"

# ---------------------------------------------------------------------------
it "race lint: stress-chaos Scenario C records outcome sets, not the last writer"
SC="$TESTS_DIR/test_llmctl_stress_chaos.sh"
grep -qE 'observed value: \$race_val' "$SC"; assert_eq 1 $? "no last-writer race value recorded"
grep -qE 'allowed outcomes' "$SC"; assert_eq 0 $? "the allowed outcome set is recorded"

summary
