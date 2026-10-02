#!/usr/bin/env bash
# test_llmctl_superpowers_determinism.sh — T028 (FR-013): proves the
# double-run-comparison LOGIC itself catches a non-deterministic verdict,
# via a hermetic fixture, before trusting it against the real
# verify_llmctl_superpowers_live.sh matrix.
#
# IMPORTANT (found live while writing this file): a real double-run of the
# live orchestrator MUST happen BEFORE any make_sandbox call, in the real
# environment. make_sandbox deliberately stubs CLAUDE_BIN=/usr/bin/true for
# hermetic safety elsewhere in this suite -- invoking the live orchestrator
# FROM INSIDE that sandbox silently turns a genuine live FAIL into an honest
# "no real claude binary" SKIP, which is test-environment contamination, not
# real non-determinism. The two concerns (real live double-run vs. hermetic
# oracle proof) are therefore kept in strictly separate process/env scopes
# below, never nested.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# compare_runs <run1.json> <run2.json> -> a JSON array of mismatching
# combination_ids (empty array = fully deterministic).
compare_runs() {
  local r1="$1" r2="$2"
  jq -n --slurpfile a "$r1" --slurpfile b "$r2" '
    ($a[0] | map({(.combination_id): .verdict}) | add // {}) as $va |
    ($b[0] | map({(.combination_id): .verdict}) | add // {}) as $vb |
    ( ($va | keys) + ($vb | keys) | unique ) as $ids |
    [ $ids[] | select( ($va[.] // "MISSING") != ($vb[.] // "MISSING") ) ]
  '
}

# =============================================================================
# PART 1 — a CHEAP real double-run: one single real combination invoked
# TWICE directly via verify_superpowers_tui.sh (never the full 6-combination
# orchestrator, which would mean 12 slow live model launches just for this
# proof), in the REAL (unsandboxed) environment, if llmctl is actually
# installed and serving something on this host. Informational: a live host's
# model/resource state can legitimately change between two runs seconds
# apart, so a mismatch here is REPORTED, never silently hidden, but is not
# itself a hard gate -- the hard, mandatory proof is Part 2's hermetic oracle.
# =============================================================================
if command -v llmctl >/dev/null 2>&1 && llmctl status 2>/dev/null | grep -q running; then
  PROFILE_ALIAS="$(cd "$(dirname "$TESTS_DIR")" && bash -c 'source claude-providers.sh >/dev/null 2>&1; detect_llmctl_records' 2>/dev/null | jq -r '.[0].alias // empty')"
  if [[ -n "$PROFILE_ALIAS" ]]; then
    echo "--- real double-run of ONE combination ($PROFILE_ALIAS / kimi / using-superpowers), unsandboxed ---"
    OUT1="$(mktemp "${TMPDIR:-/tmp}/sp-run1.XXXXXX.txt")"
    OUT2="$(mktemp "${TMPDIR:-/tmp}/sp-run2.XXXXXX.txt")"
    env -u CLAUDE_BIN bash "$TESTS_DIR/../verify_superpowers_tui.sh" --alias "$PROFILE_ALIAS" --command using-superpowers --agent kimi --out "$OUT1" >/dev/null 2>&1; RC1=$?
    env -u CLAUDE_BIN bash "$TESTS_DIR/../verify_superpowers_tui.sh" --alias "$PROFILE_ALIAS" --command using-superpowers --agent kimi --out "$OUT2" >/dev/null 2>&1; RC2=$?
    V1=pass; [[ $RC1 -ne 0 ]] && V1=fail
    V2=pass; [[ $RC2 -ne 0 ]] && V2=fail
    echo "run1 verdict=$V1 (rc=$RC1)  run2 verdict=$V2 (rc=$RC2)"
    if [[ "$V1" == "$V2" ]]; then
      echo "REAL double-run: deterministic ($V1 == $V2)"
    else
      echo "REAL double-run: MISMATCH ($V1 != $V2) -- informational, host state may have changed; see $OUT1 / $OUT2"
    fi
  else
    echo "no llmctl-backed alias currently resolvable -- skipping the real double-run"
  fi
else
  echo "llmctl not installed or nothing running on this host -- skipping the real double-run; hermetic oracle proof (Part 2) stands on its own"
fi

# =============================================================================
# PART 2 — hermetic oracle proof: compare_runs() itself MUST catch a real
# verdict mismatch. This is the mandatory, always-run proof for FR-013.
# =============================================================================
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
set +e

it "CASE A: two runs with IDENTICAL verdicts -> compare_runs reports zero mismatches"
cat > "$HOME/run1.json" <<'JSON'
[{"combination_id":"llmctl-fast__claude__using-superpowers","verdict":"pass"},
 {"combination_id":"llmctl-fast__kimi__using-superpowers","verdict":"fail"}]
JSON
cat > "$HOME/run2.json" <<'JSON'
[{"combination_id":"llmctl-fast__claude__using-superpowers","verdict":"pass"},
 {"combination_id":"llmctl-fast__kimi__using-superpowers","verdict":"fail"}]
JSON
MISMATCH="$(compare_runs "$HOME/run1.json" "$HOME/run2.json")"
assert_eq "[]" "$(echo "$MISMATCH" | tr -d '[:space:]')" "identical runs -> zero mismatches"

it "CASE B: a verdict that DIFFERS between runs -> compare_runs catches it (the oracle proof)"
cat > "$HOME/run2b.json" <<'JSON'
[{"combination_id":"llmctl-fast__claude__using-superpowers","verdict":"pass"},
 {"combination_id":"llmctl-fast__kimi__using-superpowers","verdict":"pass"}]
JSON
MISMATCH_B="$(compare_runs "$HOME/run1.json" "$HOME/run2b.json")"
assert_eq "1" "$(jq 'length' <<<"$MISMATCH_B")" "exactly one mismatching combination detected"
assert_eq "llmctl-fast__kimi__using-superpowers" "$(jq -r '.[0]' <<<"$MISMATCH_B")" "the mismatching id is named correctly"

it "CASE C: a combination present in run1 but MISSING from run2 -> flagged, never silently ignored"
cat > "$HOME/run2c.json" <<'JSON'
[{"combination_id":"llmctl-fast__claude__using-superpowers","verdict":"pass"}]
JSON
MISMATCH_C="$(compare_runs "$HOME/run1.json" "$HOME/run2c.json")"
assert_eq "1" "$(jq 'length' <<<"$MISMATCH_C")" "a dropped combination is detected as a mismatch (MISSING != fail)"

summary
