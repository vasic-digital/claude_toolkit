#!/usr/bin/env bash
# test_stui_kimi_refusal_classification.sh — hermetic proof for independent
# review finding 2 (Opus/xhigh, feature 001-llmctl-integration-hardening):
# verify_superpowers_tui.sh's --agent kimi branch grep-matched the refusal
# prefix `^(claude-providers|cma_run_kimi_provider):` UNCONDITIONALLY, before
# ever checking krc or the challenge answer. `_cma_llmctl_ensure_active`
# (lib.sh:1311) prints `claude-providers: switching llmctl to profile %s
# (currently: %s)...` on every SUCCESSFUL switch — purely informational. So
# any Kimi launch that triggers a real llmctl switch and then genuinely
# succeeds (krc=0, correct challenge answer present) was misclassified
# `FAIL: launch-refused-kimi`, which is a false FAIL (§11.4.1): the evidence
# claims no turn ran when one demonstrably did.
#
# Isolates just the classification body (verify_superpowers_tui.sh, between
# the Kimi launch's `rmdir "$ktmpd"` line and the closing `fi` of the
# `--agent kimi` branch) via a PATTERN-anchored sed range, not hardcoded line
# numbers — the same discipline test_layer4_route_attribution.sh's
# _scrub_set_named() established, so this test survives unrelated edits to
# the surrounding script instead of silently extracting the wrong range.
# This is the same "extract a function/body in isolation" technique already
# established in this suite for a script whose top-level arg parsing calls
# `exit` (see CLAUDE.md's test-harness conventions) — this script SKIPs/exits
# long before reaching this body on any real invocation without full live
# preconditions, so running the real body in isolation is the only hermetic
# way to exercise it.
set -uo pipefail
TESTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$TESTS_ROOT/lib/assert.sh"
# shellcheck source=tests/lib/sandbox.sh
. "$TESTS_ROOT/lib/sandbox.sh"
set +e

make_sandbox >/dev/null

STUI="$TESTS_ROOT/../verify_superpowers_tui.sh"
BODY_SNIPPET="$(mktemp "${TMPDIR:-/tmp}/cma-test.stui-kimi-body.XXXXXX")"
# Range: from the line AFTER `rmdir "$ktmpd"` (the launch's own cleanup,
# unique in this file) through the line BEFORE the next bare `fi` at column 0
# (the close of the `--agent kimi` branch — also the first such `fi` after
# the anchor, since nothing between them is unindented).
awk '
  /rmdir "\$ktmpd"/ { grabbing=1; next }
  grabbing && /^fi$/ { exit }
  grabbing { print }
' "$STUI" > "$BODY_SNIPPET"
[[ -s "$BODY_SNIPPET" ]] || { echo "FATAL: pattern-anchored extraction from $STUI found nothing — anchors drifted" >&2; exit 2; }

# run_body KOUT KRC CHALLENGE_ANSWER RC_FILE -> runs the isolated body,
# writes its real exit code to RC_FILE (a side channel, NOT a shared shell
# variable — a plain `rc=$?` set inside a command-substitution call cannot
# propagate to the caller, since command substitution always forks its own
# subshell; a file survives across that fork), and prints the resulting
# evidence-file ($OUT) content to stdout for the caller to capture directly.
run_body() {
  local kout="$1" krc="$2" CHALLENGE_ANSWER="$3" rc_file="$4" body_rc
  local out_file="$(mktemp "${TMPDIR:-/tmp}/cma-test.stui-kimi-out.XXXXXX")"
  ( ALIAS_ID="fake-alias" COMMAND="using-superpowers" OUT="$out_file" \
    kout="$kout" krc="$krc" CHALLENGE_ANSWER="$CHALLENGE_ANSWER" \
    CMA_STUI_NO_KIMI_WRAPPER="__unused__" ALIASES_FILE="/dev/null" \
    bash "$BODY_SNIPPET" >/dev/null 2>&1 )
  body_rc=$?
  printf '%s' "$body_rc" > "$rc_file"
  cat "$out_file"
  rm -f "$out_file"
}

RC_FILE="$(mktemp "${TMPDIR:-/tmp}/cma-test.stui-kimi-rc.XXXXXX")"

echo "=== Case A: krc=0, correct answer present, output ALSO carries the"
echo "    informational 'claude-providers: switching llmctl...' line -> MUST PASS"
body_out="$(run_body $'claude-providers: switching llmctl to profile fast (currently: small)...\nThe skill text says: Skills evolve. Read current version.' 0 'Skills evolve. Read current version.' "$RC_FILE")"
case_rc="$(<"$RC_FILE")"
assert_eq 0 "$case_rc" "krc=0 + switching line + correct answer -> exit 0 (PASS), not launch-refused"
grep -qF '# PASS' <<<"$body_out"; assert_eq 0 $? "evidence records # PASS, not # FAIL: launch-refused-kimi"
grep -qF 'launch-refused-kimi' <<<"$body_out"; assert_eq 1 $? "evidence does NOT carry the false launch-refused-kimi marker"

echo
echo "=== Case B (control): krc!=0 AND no challenge answer AND a genuine"
echo "    refusal-prefix line -> MUST still FAIL as launch-refused-kimi"
body_out="$(run_body 'cma_run_kimi_provider: alias not verified, refusing to launch' 3 'Skills evolve. Read current version.' "$RC_FILE")"
case_rc="$(<"$RC_FILE")"
assert_eq 1 "$case_rc" "krc=3 + genuine refusal text + no answer in output -> exit 1 (FAIL)"
grep -qF '# FAIL: launch-refused-kimi' <<<"$body_out"; assert_eq 0 $? "evidence correctly records launch-refused-kimi for a REAL refusal (krc!=0)"

echo
echo "=== Case C (control): krc!=0, no refusal-prefix text at all -> FAIL,"
echo "    but classified as kimi-unclassified-nonzero, never launch-refused-kimi"
body_out="$(run_body 'some unrelated kimi CLI crash' 1 'Skills evolve. Read current version.' "$RC_FILE")"
case_rc="$(<"$RC_FILE")"
assert_eq 1 "$case_rc" "krc=1 + no refusal text -> exit 1 (FAIL)"
grep -qF '# FAIL: kimi-unclassified-nonzero (rc=1)' <<<"$body_out"; assert_eq 0 $? "unrelated nonzero failures are NOT misclassified as launch-refused-kimi"

echo
echo "=== Case D (control): krc=0, switching line present, but the challenge"
echo "    answer is ACTUALLY absent -> must FAIL as no-engagement, not refused"
body_out="$(run_body $'claude-providers: switching llmctl to profile fast (currently: small)...\nI am not sure what skill you mean.' 0 'Skills evolve. Read current version.' "$RC_FILE")"
case_rc="$(<"$RC_FILE")"
assert_eq 1 "$case_rc" "krc=0 + switching line + answer genuinely absent -> exit 1 (FAIL)"
grep -qF '# FAIL: no-engagement-kimi' <<<"$body_out"; assert_eq 0 $? "a genuine non-engagement is reported as no-engagement-kimi, not launch-refused-kimi"
grep -qF 'launch-refused-kimi' <<<"$body_out"; assert_eq 1 $? "still never misclassified as launch-refused-kimi"

rm -f "$RC_FILE"

rm -f "$BODY_SNIPPET"
summary
