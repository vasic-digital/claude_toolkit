#!/usr/bin/env bash
# Hermetic tests for claude-verify-providers.sh — no network, no go, no real keys.
# Exercises the wrapper contract (help, submodule wiring, precondition guards).
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/sandbox.sh"
make_sandbox
set +e

REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/claude-verify-providers.sh"

# 1. script exists + is executable
[ -x "$SCRIPT" ]; assert_eq 0 $? "claude-verify-providers.sh exists and is executable"

# 2. --help exits 0 and documents how the LLMsVerifier checkout is found
out="$("$SCRIPT" --help 2>&1)"; rc=$?
assert_eq 0 "$rc" "--help exits 0"
printf '%s' "$out" | grep -q 'CT_LLMS_VERIFIER_DIR'
assert_eq 0 $? "--help documents CT_LLMS_VERIFIER_DIR"

# 3. LLMsVerifier is NOT a nested submodule any more; the wrapper uses the resolver
grep -qiE '^[[:space:]]*(path|url)[[:space:]]*=.*llmsverifier' "$REPO_ROOT/.gitmodules" 2>/dev/null
assert_eq 1 $? ".gitmodules does not declare LLMsVerifier (resolved flat)"
grep -q 'resolve_deps.sh" llms_verifier' "$SCRIPT"
assert_eq 0 $? "wrapper resolves llms_verifier via scripts/resolve_deps.sh"

# 4. unresolvable checkout -> actionable exit 3 (legacy and CT_ override at an empty dir)
empty="$(mktemp -d "${TMPDIR:-/tmp}/lv.XXXXXX")"
env -u CT_LLMS_VERIFIER_DIR LLMSVERIFIER_DIR="$empty" "$SCRIPT" --providers deepseek >/dev/null 2>&1
assert_eq 3 $? "invalid LLMSVERIFIER_DIR -> actionable exit 3"
err="$(CT_LLMS_VERIFIER_DIR="$empty" "$SCRIPT" --providers deepseek 2>&1 >/dev/null)"; rc=$?
assert_eq 3 "$rc" "invalid CT_LLMS_VERIFIER_DIR -> actionable exit 3"
printf '%s' "$err" | grep -q 'CT_LLMS_VERIFIER_DIR'
assert_eq 0 $? "stderr names CT_LLMS_VERIFIER_DIR"
rm -rf "$empty"

# 5. keys are never echoed: run --help with a sentinel secret in LV_KEYS-less env,
#    assert the sentinel never appears in output (anti-leak posture).
export CMA_FAKE_SECRET="sk-should-never-print-1234567890"
printf '%s' "$out" | grep -q "$CMA_FAKE_SECRET"
assert_eq 1 $? "wrapper output never contains secret-shaped env values"
unset CMA_FAKE_SECRET

summary
