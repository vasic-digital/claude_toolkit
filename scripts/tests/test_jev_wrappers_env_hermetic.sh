#!/usr/bin/env bash
# test_jev_wrappers_env_hermetic.sh — test_jev_wrappers.sh must be insensitive to an
# inherited JEV_*/LLMCTL_* environment. Runs the REAL suite twice (clean env, then with
# hostile inherited vars) and requires identical pass/fail counts, both green.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
set +e
SUITE="$TESTS_DIR/test_jev_wrappers.sh"

_counts() { sed 's/\x1b\[[0-9;]*m//g' | grep -E '[0-9]+ passed, [0-9]+ failed|[0-9]+ passed' | tail -1; }

it "H1 clean environment: suite is green"
clean="$(env -u JEV_BASE_URL -u JEV_MODE -u JEV_KEY_VAR -u JEV_MODEL -u LLMCTL_HOST -u LLMCTL_VALIDATE_STRICT bash "$SUITE" 2>&1)"; rc1=$?
assert_eq 0 "$rc1" "clean run exit"
c1="$(printf '%s\n' "$clean" | _counts)"

it "H2 hostile inherited JEV_*/LLMCTL_*: same outcome (inherited vars are scrubbed)"
dirty="$(JEV_BASE_URL=http://bogus.invalid:1 JEV_MODE=enforce JEV_KEY_VAR=BOGUS_KEY JEV_MODEL=bogus \
  JEV_API_KEY=leak-me LLMCTL_HOST=bogus.invalid LLMCTL_VALIDATE_STRICT=1 bash "$SUITE" 2>&1)"; rc2=$?
assert_eq 0 "$rc2" "hostile-env run exit"
c2="$(printf '%s\n' "$dirty" | _counts)"
assert_eq "$c1" "$c2" "pass/fail counts identical to the clean run"

summary
