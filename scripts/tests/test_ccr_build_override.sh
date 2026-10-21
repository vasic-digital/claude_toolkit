#!/usr/bin/env bash
# test_ccr_build_override.sh — test_ccr_build.sh must not swallow a BAD router
# override. A CT_CLAUDE_CODE_ROUTER_DIR that is set but invalid is an operator
# error the resolver reports loudly; test_ccr_build.sh must FAIL carrying that
# message, not SKIP as if the router were merely absent. Unset => SKIP is fine.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
set +e
TARGET="${CT_TEST_CCR_BUILD:-$TESTS_DIR/test_ccr_build.sh}"   # override only for mutation proofs
bad="$(mktemp -d "${TMPDIR:-/tmp}/cma-badccr.XXXXXX")"
trap 'rm -rf "$bad"' EXIT

it "set-but-invalid CT_CLAUDE_CODE_ROUTER_DIR => test_ccr_build.sh FAILs with the resolver's message"
out="$(CT_CLAUDE_CODE_ROUTER_DIR="$bad" bash "$TARGET" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && _pass "non-zero exit ($rc)" || _fail "exit 0 although the override is invalid" "$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'SKIP|✓|✗' | head -5)"
grep -q "CT_CLAUDE_CODE_ROUTER_DIR='$bad' is set but is not a valid claude_code_router checkout" <<<"$out" \
  && _pass "resolver message carried into the failure" || _fail "resolver message not shown" "$(printf '%s' "$out" | grep -m3 -iE 'skip|resolv')"
if grep -q '^SKIP: claude_code_router not resolvable' <<<"$out"; then _fail "reported as a plain SKIP"; else _pass "not reported as a plain SKIP"; fi

summary
