#!/usr/bin/env bash
# test_mechanical_tools_acceptance.sh — the toolkit-side acceptance for the
# §11.4.274 mechanical-work tools that this repository's own suites depend on.
#
# WHY THIS FILE IS HERE AND NOT IN THE CONSTITUTION
#   The tools live in the constitution submodule and are inherited BY REFERENCE
#   (§11.4.177 / §11.4.28): they are project-agnostic and their own hermetic
#   suites may not depend on any consuming project's harness. But the acceptance
#   this feature demands is deliberately NOT synthetic — it is that the harness
#   reproduces a MEASURED outcome of THIS repository: the kimi wire/status suite
#   reports 58 passed / 0 failed unmutated, and FAILS under mutation D5e. That
#   claim is about the toolkit, so its test belongs to the toolkit.
#
#   The dependency therefore runs one way only. This file reaches OUT to the
#   constitution; nothing in the constitution reaches in here, and no project
#   path is hardcoded in either direction.
#
# WHAT IT ASSERTS
#   1. The three tools are reachable, or the absence is announced (never silent).
#   2. Each tool's REFUSAL paths actually refuse — an instrument that cannot see
#      must not emit a result, and a bounded wait that expired must not read as
#      success. These are the properties the toolkit's own suites lean on when
#      they use these tools, so a regression here is a regression in every
#      verdict they produce.
#   3. Opt-in: the full acceptance run (baseline 58/0 + D5e FAIL) against this
#      very repository. Opt-in because it copies the tree and runs a suite twice
#      — several minutes — and `run-all.sh` runs 70 files.
#
# HONEST DEGRADATION (US3 / §11.4.272(G))
#   With no constitution checkout reachable, this file SKIPs with a reason that
#   names what is unavailable, what still works, and how to supply it. It never
#   silently passes, and it never fails the suite for an absence that is a
#   legitimate deployment of this repository as a standalone toolkit.
#
# HERMETIC (§11.4.98): the fast checks build their own fixture trees; no
# network, no credentials, no reliance on the operator's provider records.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$TESTS_DIR/.." && pwd)}"
REPO_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cma-mechacc.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --- resolve the mechanical tools, project-agnostically (§11.4.177) ---------
# Order: explicit override, then an in-tree checkout, then an ancestor search.
# NO project name appears anywhere in this resolution — hardcoding one is the
# coupling §11.4.177 exists to forbid.
resolve_mech() {
  local d
  if [[ -n "${CMA_CONSTITUTION_DIR:-}" ]]; then
    d="$CMA_CONSTITUTION_DIR/scripts/mechanical"
    [[ -d "$d" ]] && { printf '%s\n' "$d"; return 0; }
    return 1   # an explicit override that does not resolve is an error, not a
               # cue to go hunting elsewhere and silently use something else
  fi
  [[ -d "$REPO_ROOT/constitution/scripts/mechanical" ]] && {
    printf '%s\n' "$REPO_ROOT/constitution/scripts/mechanical"; return 0; }
  local p="$REPO_ROOT"
  while [[ "$p" != "/" ]]; do
    for d in "$p"/*/constitution/scripts/mechanical "$p"/constitution/scripts/mechanical; do
      [[ -d "$d" ]] && { printf '%s\n' "$d"; return 0; }
    done
    p="$(dirname "$p")"
  done
  return 1
}

MECH="$(resolve_mech)" || MECH=""

if [[ -z "$MECH" ]]; then
  echo "SKIP: the §11.4.274 mechanical tools are not reachable from this checkout."
  echo "  UNAVAILABLE : constitution/scripts/mechanical (mutation_harness.sh, census_query.sh, await_condition.sh)"
  echo "  STILL WORKS : every other suite in this directory — these tools are used BY tests, not by the toolkit at runtime."
  echo "  TO SUPPLY   : set CMA_CONSTITUTION_DIR=/path/to/constitution, or place a constitution checkout beside this repo."
  echo
  echo "0 passed, 0 failed"
  exit 0
fi

CENSUS="$MECH/census_query.sh"
AWAIT="$MECH/await_condition.sh"
HARNESS="$MECH/mutation_harness.sh"

echo "== mechanical-tools acceptance (tools: $MECH) =="

# ---------------------------------------------------------------------------
it "all three tools are present and executable"
# ---------------------------------------------------------------------------
for t in "$CENSUS" "$AWAIT" "$HARNESS"; do
  if [[ -x "$t" ]]; then _pass "executable: $(basename "$t")"
  else _fail "missing or not executable" "$t"; fi
done

# --- fixture used by the census checks --------------------------------------
FIX="$WORK/fixture"; mkdir -p "$FIX"
printf 'planted_positive_needle\ncounted_line\ncounted_line\n' > "$FIX/a.txt"

# ---------------------------------------------------------------------------
it "census_query REFUSES a count when its positive control cannot be found"
#   This is the property every census in this suite relies on. Without it an
#   empty result and a blind instrument are the same output (§11.4.273).
# ---------------------------------------------------------------------------
out="$("$CENSUS" --tree "$FIX" --pattern 'counted_line' \
        --positive 'needle_that_is_definitely_absent' \
        --negative 'zzz_fabricated_needle' --label blind 2>&1)"; rc=$?
assert_eq 2 "$rc" "blind instrument exits CANNOT_RUN"
case "$out" in *matches=*) _fail "a count was emitted despite a failed control" "$out" ;;
               *) _pass "no count emitted when the instrument is unproven" ;; esac

# ---------------------------------------------------------------------------
it "census_query REFUSES a count when its negative control IS found"
#   The too-broad half: a matcher that finds a needle it must not cannot be
#   trusted about the needle it must.
# ---------------------------------------------------------------------------
out="$("$CENSUS" --tree "$FIX" --pattern 'counted_line' \
        --positive 'planted_positive_needle' \
        --negative 'counted_line' --label broad 2>&1)"; rc=$?
assert_eq 2 "$rc" "too-broad matcher exits CANNOT_RUN"
case "$out" in *matches=*) _fail "a count was emitted despite a failed control" "$out" ;;
               *) _pass "no count emitted when the negative control fired" ;; esac

# ---------------------------------------------------------------------------
it "census_query still reports an HONEST zero when both controls hold"
#   'found nothing' and 'could not look' must stay two different answers.
# ---------------------------------------------------------------------------
out="$("$CENSUS" --tree "$FIX" --pattern 'pattern_matching_nothing_here' \
        --positive 'planted_positive_needle' \
        --negative 'zzz_fabricated_needle' --label zero 2>&1)"; rc=$?
assert_eq 0 "$rc" "a proven instrument finding nothing exits OK"
case "$out" in *matches=0*) _pass "the honest zero is reported: $out" ;;
               *) _fail "expected matches=0" "$out" ;; esac

# ---------------------------------------------------------------------------
it "await_condition cannot report a timeout as success"
# ---------------------------------------------------------------------------
out="$("$AWAIT" --until 'false' --timeout 2 --interval 1 --label neverholds 2>&1)"; rc=$?
assert_eq 3 "$rc" "expired wait exits with its own distinct code"
case "$out" in *TIMEOUT*) _pass "the outcome it exited on is named: TIMEOUT" ;;
               *) _fail "timeout not named in the outcome line" "$out" ;; esac

out="$("$AWAIT" --until 'true' --timeout 5 --interval 1 --label holds 2>&1)"; rc=$?
assert_eq 0 "$rc" "a satisfied wait exits OK"
case "$out" in *SATISFIED*) _pass "the outcome it exited on is named: SATISFIED" ;;
               *) _fail "satisfaction not named in the outcome line" "$out" ;; esac

# ---------------------------------------------------------------------------
it "mutation_harness REFUSES to report a suite result for an unapplied mutation"
#   A result from a mutation whose text was never found describes nothing. This
#   is the trap that makes a paired §1.1 mutation look green while testing the
#   unmutated code.
# ---------------------------------------------------------------------------
MT="$WORK/mtree"; mkdir -p "$MT"
printf '#!/usr/bin/env bash\necho "1 passed, 0 failed"\n' > "$MT/suite.sh"
printf 'ORIGINAL_TOKEN\n' > "$MT/subject.sh"
chmod +x "$MT/suite.sh"

out="$("$HARNESS" --tree "$MT" --suite suite.sh --name absent-from \
        --file subject.sh --from 'TEXT_THAT_IS_NOT_IN_THE_FILE' --to 'X' 2>&1)"; rc=$?
assert_eq 2 "$rc" "unapplied mutation exits CANNOT_RUN"
case "$out" in *"EXPECTED-FAIL got"*) _fail "a suite verdict was reported for an unapplied mutation" "$out" ;;
               *) _pass "no suite verdict reported for an unapplied mutation" ;; esac

# ---------------------------------------------------------------------------
it "mutation_harness measures a real suite it CAN apply a mutation to"
#   The mirror direction. A refusal-only check would pass on a tool that refuses
#   everything, which is the §11.4.201 false-positive failure in the other
#   direction.
# ---------------------------------------------------------------------------
printf '#!/usr/bin/env bash\nif grep -q ORIGINAL_TOKEN "$(dirname "$0")/subject.sh"; then echo "1 passed, 0 failed"; else echo "1 failed, 0 passed"; fi\n' > "$MT/suite.sh"
out="$("$HARNESS" --tree "$MT" --suite suite.sh --name real --expect fail \
        --file subject.sh --from 'ORIGINAL_TOKEN' --to 'MUTATED_TOKEN' 2>&1)"; rc=$?
assert_eq 0 "$rc" "an applied mutation that breaks its suite is reported as expected-fail"
case "$out" in *"1 failed"*) _pass "the mutated suite's real counts are reported" ;;
               *) _fail "expected the mutated suite to report a failure" "$out" ;; esac

# ---------------------------------------------------------------------------
it "ACCEPTANCE: the harness reproduces this repository's measured outcome"
#   Opt-in. Copies this tree twice and runs the kimi wire/status suite twice —
#   minutes, against a 70-file default run. Not skipped silently: the exact
#   command is printed so it is one paste away.
# ---------------------------------------------------------------------------
if [[ "${CMA_MECH_ACCEPTANCE:-0}" != "1" ]]; then
  echo "    [INFO] not run — set CMA_MECH_ACCEPTANCE=1 to include it."
  echo "    [INFO]   CMA_MECH_ACCEPTANCE=1 bash $TESTS_DIR/$(basename "${BASH_SOURCE[0]}")"
  echo "    [INFO] measured 2026-09-08: BASELINE 58 passed/0 failed; D5e EXPECTED-FAIL [OK]."
else
  SUITE_REL="scripts/tests/test_kimi_wire_and_status_freshness.sh"
  out="$(env -u KIMI_API_KEY -u HELIXLLM_GATEWAY_KEY "$HARNESS" \
          --tree "$REPO_ROOT" --suite "$SUITE_REL" --name BASELINE --expect pass \
          --timeout 600 --unset KIMI_API_KEY --unset HELIXLLM_GATEWAY_KEY 2>&1)"; rc=$?
  assert_eq 0 "$rc" "unmutated baseline runs and matches expectation"
  case "$out" in *"0 failed / 58 passed"*) _pass "baseline reproduces the measured 58/0" ;;
                 *) _fail "baseline did not reproduce 58 passed / 0 failed" "$out" ;; esac

  out="$(env -u KIMI_API_KEY -u HELIXLLM_GATEWAY_KEY "$HARNESS" \
          --tree "$REPO_ROOT" --suite "$SUITE_REL" --name D5e --expect fail \
          --timeout 600 --file scripts/kimi-providers.sh \
          --from 'alias=$1; pid=$2; status=$3' \
          --to   'alias=$2; pid=$1; status=$3' \
          --unset KIMI_API_KEY --unset HELIXLLM_GATEWAY_KEY 2>&1)"; rc=$?
  assert_eq 0 "$rc" "D5e is applied and the suite FAILS under it"
  case "$out" in *"EXPECTED-FAIL"*"[OK]"*) _pass "D5e makes the guard fail, as §1.1 requires" ;;
                 *) _fail "D5e did not turn the suite red" "$out" ;; esac
fi

summary
