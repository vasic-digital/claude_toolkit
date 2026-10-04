#!/usr/bin/env bash
# test_quota_rendering.sh — unit tests for scripts/lib.sh's `quota`/`limits`
# rendering helpers: severity classification, color-enable gating, and
# (in later tasks extending this same file) the text/JSON renderers
# themselves.
#
# This file is INTENTIONALLY RED at the time it is first written: this
# task (T007) is test-only (TDD discipline). The implementation
# (_cma_quota_severity in scripts/lib.sh) lands in the next task, T008.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e   # lib.sh sets -e; the harness asserts on failures, so relax it.

it "_cma_quota_severity(100) is green"
out="$(_cma_quota_severity 100)"
assert_eq "green" "$out" "100% remaining is green"

it "_cma_quota_severity(30) is green (inclusive lower bound)"
out="$(_cma_quota_severity 30)"
assert_eq "green" "$out" "exactly 30% remaining is green, not yellow"

it "_cma_quota_severity(29.99) is yellow"
out="$(_cma_quota_severity 29.99)"
assert_eq "yellow" "$out" "29.99% remaining is yellow"

it "_cma_quota_severity(10) is yellow (inclusive lower bound)"
out="$(_cma_quota_severity 10)"
assert_eq "yellow" "$out" "exactly 10% remaining is yellow, not red"

it "_cma_quota_severity(9.99) is red"
out="$(_cma_quota_severity 9.99)"
assert_eq "red" "$out" "9.99% remaining is red"

it "_cma_quota_severity(0.01) is red"
out="$(_cma_quota_severity 0.01)"
assert_eq "red" "$out" "0.01% remaining is still red, not limit_exceeded"

it "_cma_quota_severity(0) is limit_exceeded"
out="$(_cma_quota_severity 0)"
assert_eq "limit_exceeded" "$out" "exactly 0% remaining is limit_exceeded"

it "_cma_quota_severity(-5) is limit_exceeded (negative remaining still classifies)"
out="$(_cma_quota_severity -5)"
assert_eq "limit_exceeded" "$out" "negative remaining (e.g. after overage) is limit_exceeded, never undefined"

summary
