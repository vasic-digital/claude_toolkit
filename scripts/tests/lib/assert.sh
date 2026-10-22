#!/usr/bin/env bash
# assert.sh — small assertion helpers for the test suite. Each helper
# emits `[PASS]` or `[FAIL]` lines and increments counters in the caller.
# A test file should source this once and then call the helpers inside
# `it` blocks.

TESTS_PASSED="${TESTS_PASSED:-0}"
TESTS_FAILED="${TESTS_FAILED:-0}"
TESTS_FAILURES=()
TESTS_SKIPPED="${TESTS_SKIPPED:-0}"
CURRENT_TEST="${CURRENT_TEST:-(unknown)}"

# Mark the start of an individual test case. Use as:  it "merges history.jsonl"
it() {
  CURRENT_TEST="$*"
  printf '\n  • %s\n' "$CURRENT_TEST"
}

_pass() {
  TESTS_PASSED=$((TESTS_PASSED + 1))
  printf '    \033[32m[PASS]\033[0m %s\n' "$1"
}

# _skip <reason>: an honest, COUNTED skip (never a pass); summary() reports it.
_skip() {
  TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
  printf '    \033[33m[SKIP]\033[0m %s\n' "$1"
}

_fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  TESTS_FAILURES+=("$CURRENT_TEST :: $1")
  printf '    \033[31m[FAIL]\033[0m %s\n' "$1"
  [[ -n "${2:-}" ]] && printf '           %s\n' "$2"
}

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-equality}"
  if [[ "$expected" == "$actual" ]]; then _pass "$msg ($expected)"
  else _fail "$msg" "want=$expected got=$actual"; fi
}

assert_file() {
  local path="$1" msg="${2:-file exists}"
  if [[ -f "$path" ]]; then _pass "$msg: $path"
  else _fail "$msg" "missing: $path"; fi
}

assert_dir() {
  local path="$1" msg="${2:-dir exists}"
  if [[ -d "$path" ]]; then _pass "$msg: $path"
  else _fail "$msg" "missing dir: $path"; fi
}

# Portable realpath for the harness. BSD/macOS `readlink` has no `-f`, so
# `readlink -f` is a hard error there (empty output) — which would make the
# symlink assertions below pass/fail spuriously on macOS. Self-contained
# (mirrors lib.sh's cma_realpath) so assert.sh works even in test files that
# don't source lib.sh (e.g. test_add_remove.sh).
_assert_realpath() {
  local p="$1" t dir base
  while [ -L "$p" ]; do
    t="$(readlink "$p")"
    case "$t" in /*) p="$t" ;; *) p="$(dirname "$p")/$t" ;; esac
  done
  dir="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || dir="$(dirname "$p")"
  base="$(basename "$p")"
  printf '%s/%s\n' "$dir" "$base"
}

assert_symlink_to() {
  local link="$1" expected="$2" msg="${3:-symlink target}"
  if [[ ! -L "$link" ]]; then
    _fail "$msg" "not a symlink: $link"
    return
  fi
  local actual; actual="$(_assert_realpath "$link")"
  local want;   want="$(_assert_realpath "$expected")"
  if [[ "$actual" == "$want" ]]; then _pass "$msg: $link -> $expected"
  else _fail "$msg" "want=$want got=$actual"; fi
}

assert_not_symlink() {
  local p="$1" msg="${2:-not a symlink}"
  if [[ -L "$p" ]]; then _fail "$msg" "is a symlink: $p"
  else _pass "$msg: $p"; fi
}

assert_file_contains() {
  local path="$1" needle="$2" msg="${3:-file contains}"
  if grep -F -q -- "$needle" "$path" 2>/dev/null; then _pass "$msg: '$needle' in $(basename "$path")"
  else _fail "$msg" "'$needle' not found in $path"; fi
}

assert_file_not_contains() {
  local path="$1" needle="$2" msg="${3:-file lacks}"
  if grep -F -q -- "$needle" "$path" 2>/dev/null; then _fail "$msg" "'$needle' found in $path"
  else _pass "$msg: '$needle' absent from $(basename "$path")"; fi
}

assert_jq() {
  local path="$1" expr="$2" expected="$3" msg="${4:-jq check}"
  local actual; actual="$(jq -r "$expr" "$path" 2>/dev/null || echo '<jq-error>')"
  if [[ "$actual" == "$expected" ]]; then _pass "$msg ($expr = $expected)"
  else _fail "$msg" "expr=$expr want=$expected got=$actual"; fi
}

assert_lines() {
  local path="$1" expected="$2" msg="${3:-line count}"
  local actual; actual="$(wc -l < "$path" 2>/dev/null || echo 0)"
  actual="${actual// /}"
  if [[ "$actual" == "$expected" ]]; then _pass "$msg ($expected lines)"
  else _fail "$msg" "want=$expected got=$actual lines in $path"; fi
}

# assert_fn_from — assert that a shell FUNCTION was defined by an EXPECTED file.
#
#   assert_fn_from FN EXPECTED_FILE [MSG]
#       Check FN as it is defined in the CALLER's shell.
#   assert_fn_from --source FILE FN [MSG]
#       Source FILE in a throwaway subshell first, then check FN's provenance
#       there. For call sites whose `source` lives inside a `( … )` subshell:
#       only the sourcing is subshelled, so the pass/fail still lands in the
#       caller's counters and reaches `summary`.
#
# WHY THIS EXISTS — the guard that failed under the conditions of its own bug.
# The login profile exports BASH_ENV=~/.bashrc, so EVERY non-interactive bash —
# including run-all.sh's `bash "$f"` per test — sources the PRODUCTION alias file
# before the test's first line. cma_run and cma_run_provider are therefore
# ALREADY defined, from the host, in every test shell. A test that sources its
# sandbox $ALIAS_FILE and then calls the wrapper looks correct, but the tests
# run with `set +e`: if that source silently fails, execution falls straight
# through to the fully-working HOST function and the test passes — while
# grading live host code instead of the code under test. Tests written to prove
# cma_ensure_alias_file emits a correct body then report green for exactly the
# regression they exist to catch.
#
# `shopt -s extdebug` makes `declare -F NAME` print "name lineno file", which is
# the only way to see WHERE a function came from. Naming both the expected and
# the actual file in the failure message is deliberate: "wrong provenance" is
# useless without "…it came from the host alias file instead".
assert_fn_from() {
  local file="" fn expected msg src had_extdebug
  if [[ "${1:-}" == "--source" ]]; then
    file="$2"; fn="$3"; expected="$2"; msg="${4:-function provenance}"
  else
    fn="$1"; expected="$2"; msg="${3:-function provenance}"
  fi

  if [[ -n "$file" ]]; then
    # set +u: an alias file may reference unset vars while being sourced.
    src="$( set +u; source "$file" >/dev/null 2>&1
            shopt -s extdebug; declare -F "$fn" 2>/dev/null | awk '{print $3}' )"
  else
    had_extdebug="$(shopt -p extdebug)"
    shopt -s extdebug
    src="$(declare -F "$fn" 2>/dev/null | awk '{print $3}')"
    eval "$had_extdebug"
  fi

  if [[ -z "$src" ]]; then
    _fail "$msg" "$fn is not defined at all (expected it from $expected)"
  elif [[ "$src" == "$expected" ]]; then
    _pass "$msg: $fn came from $expected"
  else
    _fail "$msg" "$fn was defined by $src, NOT by the expected $expected"
  fi
}

assert_exit() {
  local expected="$1"; shift
  local out; out="$("$@" 2>&1)"; local rc=$?
  if (( rc == expected )); then _pass "exit $expected for: $*"
  else _fail "exit code mismatch" "want=$expected got=$rc cmd=$* out=$out"; fi
}

summary() {
  echo
  # A file that asserted nothing proves nothing: never a pass (no vacuous green).
  if (( TESTS_PASSED + TESTS_FAILED == 0 )); then
    printf '\033[31m✗ no assertions ran (0 passed, 0 failed) - a test that checks nothing is not a pass\033[0m\n'
    return 1
  fi
  if (( TESTS_FAILED == 0 )); then
    if (( TESTS_SKIPPED > 0 )); then
      printf '\033[32m✓ %d passed, 0 failed\033[0m (%d skipped)\n' "$TESTS_PASSED" "$TESTS_SKIPPED"
    else
      printf '\033[32m✓ %d passed, 0 failed\033[0m\n' "$TESTS_PASSED"
    fi
    return 0
  fi
  printf '\033[31m✗ %d failed, %d passed\033[0m\n' "$TESTS_FAILED" "$TESTS_PASSED"
  printf '\nFailures:\n'
  for f in "${TESTS_FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  return 1
}
