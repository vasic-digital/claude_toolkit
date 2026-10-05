#!/usr/bin/env bash
# test_dynamic_account_dispatch.sh — regression guard for the 2026-07-23 live
# defect: `claude-add-account --alias claude5` succeeded (config dir created,
# alias line written, a FRESH shell resolves claude5) yet the operator's shell
# kept answering "claude5: command not found" even after re-logging in —
# because SSH re-login re-attaches to the SAME persistent tmux server, whose
# pane shells sourced the alias file BEFORE the account existed and never
# re-source it. The static `alias claudeN=…` lines cannot fix that class.
#
# THE STRUCTURAL FIX under test: the alias file's managed block now emits a
# dynamic account dispatcher — a command-not-found handler that resolves
# `<name>` -> $HOME/.claude-<name> at INVOCATION time — so an account added
# AFTER a shell sourced the (dispatcher-bearing) alias file launches in that
# shell immediately, no re-source.
#
# SCENARIO (models the real defect sequence, §11.4.199): one long-lived shell
#   1. sources the alias file (as a tmux pane shell did at 00:00),
#   2. THEN the real claude-add-account.sh adds a new account (as the
#      operator did at 15:14 from another shell),
#   3. THEN — with NO re-source — invokes the new account's name.
#
# RED  (pre-fix alias file): step 3 exits 127 "command not found".
# GREEN (post-fix):          step 3 launches cma_run with the new account's
#                            CLAUDE_CONFIG_DIR (proven via a stub CLAUDE_BIN
#                            that prints the config dir it received).
# Paired §1.1 mutation: strip _cma_emit_account_dispatch from the managed
# block -> this test FAILs again.
#
# Guard-rails also proven (the §11.4.201 false-positive side):
#   * a non-account command still fails with 127 (no hijack);
#   * a PRE-EXISTING command_not_found_handle keeps firing for non-account
#     names (chained, not clobbered);
#   * provider config dirs (.claude-prov-*) are NOT dispatchable as accounts;
#   * zsh: the same alias file dispatches in zsh via command_not_found_handler
#     (skipped honestly if zsh is not installed).
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# Volatile run output (D1): written to a temp file beside the final path and
# renamed into the git-ignored proof/volatile/ folder only on completion.
# shellcheck source=lib/proof.sh
source "$TESTS_DIR/lib/proof.sh"
PROOF_DIR="$(cma_proof_volatile_dir)"
PROOF_FINAL="$PROOF_DIR/94-dynamic-account-dispatch.txt"
PROOF="$(cma_proof_open "$PROOF_FINAL")"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox

# Two seed accounts + a rendered alias file, exactly like test_add_remove.sh.
make_account acct1 >/dev/null
make_account acct2 >/dev/null
# shellcheck disable=SC2119
run_unify >/dev/null 2>&1

[[ -f "$ALIAS_FILE" ]] || { echo "FATAL: no alias file rendered" >&2; exit 1; }

# Stub claude binary: prints the config dir + args it was launched with, so a
# dispatch is proven by CONTENT (which account dir reached the binary), not by
# exit code alone.
STUB="$HOME/claude-stub"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
printf 'STUB-LAUNCH CFG=%s ARGS=%s\n' "${CLAUDE_CONFIG_DIR:-<unset>}" "$*"
EOF
chmod +x "$STUB"

{
  echo "=== test_dynamic_account_dispatch.sh evidence ==="
  echo "date: $(date -u +%FT%TZ)"
  echo "--- alias file (managed-block head) ---"
  head -8 "$ALIAS_FILE"
} >> "$PROOF" 2>&1

# --- the long-lived-shell simulation ----------------------------------------
# ONE bash process: source -> add account -> invoke WITHOUT re-source.
INNER="$HOME/inner.sh"
cat > "$INNER" <<EOF
source "$ALIAS_FILE" || exit 91
# The account is added AFTER this shell sourced the alias file (by the REAL
# add-account script, run non-interactively) — this shell never re-sources.
"$SCRIPTS_DIR/claude-add-account.sh" --alias claude9 --yes >/dev/null 2>&1 || exit 90
export CLAUDE_BIN="$STUB"
out="\$(claude9 --hello-from-stale-shell 2>&1)"; rc=\$?
printf 'rc=%s\nout=%s\n' "\$rc" "\$out"
EOF

it "a stale shell resolves a NEWLY added account with no re-source (the claude5 defect)"
RES="$(bash "$INNER" 2>&1)"
{
  echo "--- inner shell (bash) result ---"
  echo "$RES"
} >> "$PROOF"
grep -q '^rc=0$' <<<"$RES"
assert_eq 0 $? "new-account command exits 0 in the pre-add shell (pre-fix: rc=127 command not found)"
grep -q 'STUB-LAUNCH CFG=.*/.claude-claude9' <<<"$RES"
assert_eq 0 $? "launch reached claude with CLAUDE_CONFIG_DIR=…/.claude-claude9 (the ADDED account, resolved at invocation time)"

it "guard-rail: a non-account command is NOT hijacked (still 127)"
RES2="$(bash -c 'source "'"$ALIAS_FILE"'"; definitely-not-an-account-xyz 2>/dev/null; echo rc=$?')"
echo "--- non-account probe: $RES2 ---" >> "$PROOF"
grep -q '^rc=127$' <<<"$RES2"
assert_eq 0 $? "unknown command still exits 127"

it "guard-rail: a PRE-EXISTING command_not_found_handle is chained, not clobbered"
RES3="$(bash -c '
  command_not_found_handle() { echo "PREV-HANDLER:$1"; return 99; }
  source "'"$ALIAS_FILE"'"
  definitely-not-an-account-xyz; echo rc=$?')"
echo "--- chain probe: $RES3 ---" >> "$PROOF"
grep -q 'PREV-HANDLER:definitely-not-an-account-xyz' <<<"$RES3"
assert_eq 0 $? "previous handler still fires for non-account names"
grep -q '^rc=99$' <<<"$RES3"
assert_eq 0 $? "previous handler's exit code is preserved"

it "guard-rail: provider config dirs are not dispatchable accounts"
mkdir -p "$HOME/.claude-prov-fooprov"
RES4="$(bash -c 'source "'"$ALIAS_FILE"'"; export CLAUDE_BIN="'"$STUB"'"; prov-fooprov 2>/dev/null; echo rc=$?')"
echo "--- provider-dir probe: $RES4 ---" >> "$PROOF"
grep -q '^rc=127$' <<<"$RES4"
assert_eq 0 $? "prov-* name is refused (providers launch via cma_run_provider, never the account fallback)"

it "zsh: the same alias file dispatches a post-source account via command_not_found_handler"
if command -v zsh >/dev/null 2>&1; then
  RES5="$(zsh -c '
    source "'"$ALIAS_FILE"'" >/dev/null 2>&1
    mkdir -p "$HOME/.claude-zshacct"
    export CLAUDE_BIN="'"$STUB"'"
    out="$(zshacct --from-zsh 2>&1)"; rc=$?
    printf "rc=%s\nout=%s\n" "$rc" "$out"')"
  echo "--- zsh probe ---" >> "$PROOF"; echo "$RES5" >> "$PROOF"
  grep -q 'STUB-LAUNCH CFG=.*/.claude-zshacct' <<<"$RES5"
  assert_eq 0 $? "zsh dispatches the post-source account through command_not_found_handler"
else
  echo "  [SKIP] zsh not installed on this host (bash coverage above stands)" | tee -a "$PROOF"
fi

it "rendered alias file still parses (bash -n)"
bash -n "$ALIAS_FILE"
assert_eq 0 $? "alias file is bash-parseable with the dispatcher block"

echo >> "$PROOF"
echo "=== result: pass=$TESTS_PASSED fail=$TESTS_FAILED ===" >> "$PROOF"

cma_proof_commit "$PROOF" "$PROOF_FINAL"
summary
