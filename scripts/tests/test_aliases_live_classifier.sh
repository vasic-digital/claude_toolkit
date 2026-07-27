#!/usr/bin/env bash
# test_aliases_live_classifier.sh — hermetic tests for the ACCOUNT-class leg of
# verify_aliases_live.sh (test_claude_alias).
#
# Motivation (2026-07-26 live proof): the primary native account milos85vasic
# FAILed the 43-live-aliases leg with ZERO captured detail. Reproduction showed
# the account's OAuth session had expired (refresh token dead since 2026-07-22,
# .credentials.json carrying empty tokens — a PRIVATE_ITEM the toolkit never
# touches): "Failed to authenticate: OAuth session expired and could not be
# refreshed". That is an account-SIDE state (needs an interactive `claude
# /login`), not a toolkit failure — the classifier had quota patterns but no
# auth bucket, and the FAIL path discarded the captured output entirely.
#
# These tests stub cma_run (via a fake aliases.sh in the sandbox HOME) so no
# real account, network, or quota is touched.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
set +e

# verify_aliases_live.sh honours PROOF_DIR — point it INSIDE the sandbox so the
# real scripts/tests/proof/alias-verify-evidence.txt is never clobbered.
export PROOF_DIR="$SANDBOX_HOME/proof"

# The account leg iterates the hardcoded dir names under $HOME; create exactly
# one of them per case.
ACCT_DIR="$SANDBOX_HOME/.claude-milos85vasic"
mkdir -p "$ACCT_DIR"

ALIAS_STUB="$SANDBOX_HOME/.local/share/claude-multi-account/aliases.sh"
mkdir -p "$(dirname "$ALIAS_STUB")"

# write_cma_run_stub BEHAVIOR — installs a cma_run into the sandbox aliases.sh.
# Behaviors: auth-stdout | auth-stderr | quota | pass | garbage
write_cma_run_stub() {
  case "$1" in
    auth-stdout)
      cat > "$ALIAS_STUB" <<'EOF'
cma_run() { printf 'Failed to authenticate: OAuth session expired and could not be refreshed\n'; return 1; }
EOF
      ;;
    auth-stderr)
      cat > "$ALIAS_STUB" <<'EOF'
cma_run() { printf 'Failed to authenticate: OAuth session expired and could not be refreshed\n' >&2; return 1; }
EOF
      ;;
    quota)
      cat > "$ALIAS_STUB" <<'EOF'
cma_run() { printf "You've hit your usage limit\n"; return 1; }
EOF
      ;;
    pass)
      cat > "$ALIAS_STUB" <<'EOF'
cma_run() { printf 'OK\n'; return 0; }
EOF
      ;;
    garbage)
      cat > "$ALIAS_STUB" <<'EOF'
cma_run() { printf 'some unexpected explosion\n'; return 1; }
EOF
      ;;
  esac
}

run_leg() {
  bash "$TESTS_DIR/verify_aliases_live.sh" 2>&1
}

it "auth-expired account (stdout) is SKIP-AUTH, never a toolkit FAIL"
write_cma_run_stub auth-stdout
out="$(run_leg)"; rc=$?
case "$out" in
  *"milos85vasic: SKIP-AUTH"*) _pass "auth-expired bucketed as SKIP-AUTH" ;;
  *) _fail "expected SKIP-AUTH" "$out" ;;
esac
assert_eq "0" "$rc" "exit code counts no toolkit failure"

it "auth-expired account (stderr) is still SKIP-AUTH (classifier consults stderr)"
write_cma_run_stub auth-stderr
out="$(run_leg)"; rc=$?
case "$out" in
  *"milos85vasic: SKIP-AUTH"*) _pass "stderr auth error bucketed as SKIP-AUTH" ;;
  *) _fail "expected SKIP-AUTH for stderr-carried error" "$out" ;;
esac
assert_eq "0" "$rc" "exit code counts no toolkit failure"

it "quota wording is still SKIP-QUOTA (pre-existing bucket untouched)"
write_cma_run_stub quota
out="$(run_leg)"
case "$out" in
  *"milos85vasic: SKIP-QUOTA"*) _pass "quota bucketed as SKIP-QUOTA" ;;
  *) _fail "expected SKIP-QUOTA" "$out" ;;
esac

it "healthy account still PASSes"
write_cma_run_stub pass
out="$(run_leg)"; rc=$?
case "$out" in
  *"✓ milos85vasic: PASS"*) _pass "healthy account PASSes" ;;
  *) _fail "expected PASS" "$out" ;;
esac
assert_eq "0" "$rc" "exit code 0 on PASS"

it "a genuine FAIL records the captured output as evidence detail"
write_cma_run_stub garbage
out="$(run_leg)"; rc=$?
case "$out" in
  *"✗ milos85vasic: FAIL"*) _pass "garbage output FAILs" ;;
  *) _fail "expected FAIL" "$out" ;;
esac
assert_eq "1" "$rc" "exit code counts the genuine failure"
if grep -q 'detail(milos85vasic): some unexpected explosion' "$PROOF_DIR/alias-verify-evidence.txt" 2>/dev/null; then
  _pass "evidence carries the captured error detail"
else
  _fail "evidence missing captured detail" "$(cat "$PROOF_DIR/alias-verify-evidence.txt" 2>/dev/null)"
fi

summary
