#!/usr/bin/env bash
# test_install.sh — exercises scripts/install.sh end-to-end in a sandbox HOME.
#
# install.sh is otherwise never executed by the suite (it is only statically
# referenced), so this is the sole coverage that the bootstrap actually works:
#   * exits 0 in a clean $HOME
#   * symlinks every claude-*.sh onto PATH (~/.local/bin -> SCRIPTS_DIR)
#   * symlinks every kimi-*.sh onto PATH the same way (kimi family, v1.27.0)
#   * creates the managed alias file with the cma_run wrapper + CLAUDE_BIN export
#   * appends its PATH line to a pre-existing rc file
#   * is idempotent (a 2nd run exits 0 and does not duplicate cma_run/PATH line)
#   * registers claude<N> aliases for pre-existing account dirs
#   * registers kimi<N> aliases for pre-existing kimi account dirs (install-time
#     kimi-unify, the 5b step)
#
# Honest side effect: install.sh runs `npm install` in the REAL repo root for
# the optional TOON utility. It is idempotent (a no-op once deps are present,
# a soft warning if npm is absent) and only ever touches the gitignored
# node_modules/ — no tracked file is modified. Everything else stays inside the
# sandboxed $HOME / $SHARED_DIR. This test does NOT source lib.sh.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
export SCRIPTS_DIR

source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"

# fresh_sandbox — tear down the current sandbox (if any) and stand up a new one.
#
# This test deliberately needs TWO sandboxes: the second half re-runs install.sh
# against a $HOME that has no prior alias file, to prove claude<N> aliases are
# registered for pre-existing account dirs. Calling make_sandbox twice directly
# is wrong on two counts:
#   1. It reassigns SANDBOX_HOME and re-arms the EXIT trap, orphaning the first
#      mktemp dir — one leaked temp dir per run, forever.
#   2. Every path DERIVED from the old sandbox ($RC_FILE, $install_log) would
#      silently keep pointing into that orphan, so the second half would write
#      its install log and rc file outside the live sandbox.
# Recomputing the derived paths here keeps both correct.
fresh_sandbox() {
  cleanup_sandbox          # no-op before the first sandbox exists
  make_sandbox

  # Choose the rc file install.sh would target, the SAME way lib.sh derives
  # CMA_RC_FILES (Darwin -> ~/.zshrc only; Linux -> ~/.bashrc + ~/.zshrc).
  # install.sh only appends its PATH/source lines to rc files that ALREADY
  # exist, so pre-create one — otherwise the PATH-line assertion is vacuous.
  if [[ "$(uname -s)" == "Darwin" ]]; then
    RC_FILE="$HOME/.zshrc"
  else
    RC_FILE="$HOME/.bashrc"
  fi
  : > "$RC_FILE"

  install_log="$SANDBOX_HOME/install.log"
}

fresh_sandbox

# The exact literal install.sh writes (single-quoted: $HOME/$PATH stay literal).
# shellcheck disable=SC2016  # intentional literal, must match the rc-file content verbatim
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'

# Run install.sh with the SAME bash that runs this test. install.sh needs
# bash 4+ (and re-execs to a Homebrew bash on macOS); using $BASH guarantees a
# compatible interpreter on every host. BIN_DIR is pinned into the sandbox.
run_install() {
  BIN_DIR="$HOME/.local/bin" "${BASH:-bash}" "$SCRIPTS_DIR/install.sh" >"$install_log" 2>&1
}

it "install.sh exits 0 in a clean sandbox HOME"
run_install
rc=$?
assert_eq 0 "$rc" "install.sh exit code"
# Surface the cause if it failed (sandbox is torn down on EXIT).
[[ $rc -eq 0 ]] || sed 's/^/    install.log| /' "$install_log"

it "install.sh symlinks claude-* commands into ~/.local/bin -> SCRIPTS_DIR"
assert_symlink_to "$HOME/.local/bin/claude-unify"         "$SCRIPTS_DIR/claude-unify.sh"         "claude-unify linked"
assert_symlink_to "$HOME/.local/bin/claude-add-account"   "$SCRIPTS_DIR/claude-add-account.sh"   "claude-add-account linked"
assert_symlink_to "$HOME/.local/bin/claude-list-accounts" "$SCRIPTS_DIR/claude-list-accounts.sh" "claude-list-accounts linked"

it "install.sh symlinks kimi-* commands into ~/.local/bin -> SCRIPTS_DIR"
assert_symlink_to "$HOME/.local/bin/kimi-unify"          "$SCRIPTS_DIR/kimi-unify.sh"          "kimi-unify linked"
assert_symlink_to "$HOME/.local/bin/kimi-add-account"    "$SCRIPTS_DIR/kimi-add-account.sh"    "kimi-add-account linked"
assert_symlink_to "$HOME/.local/bin/kimi-list-accounts"  "$SCRIPTS_DIR/kimi-list-accounts.sh"  "kimi-list-accounts linked"
assert_symlink_to "$HOME/.local/bin/kimi-remove-account" "$SCRIPTS_DIR/kimi-remove-account.sh" "kimi-remove-account linked"
assert_symlink_to "$HOME/.local/bin/kimi-rollback"       "$SCRIPTS_DIR/kimi-rollback.sh"       "kimi-rollback linked"
assert_symlink_to "$HOME/.local/bin/kimi-providers"      "$SCRIPTS_DIR/kimi-providers.sh"      "kimi-providers linked"

it "install.sh banner names the kimi family"
assert_file_contains "$install_log" "kimi-{unify,add-account,remove-account,list-accounts,rollback,providers}" "banner lists the kimi commands"
assert_file_contains "$install_log" "kimi-add-account --alias kimi1" "banner shows the kimi onboarding hint"

it "install.sh creates the managed alias file with the wrapper + CLAUDE_BIN export"
assert_file "$ALIAS_FILE" "alias file created"
assert_file_contains "$ALIAS_FILE" "cma_run()"         "cma_run wrapper present"
assert_file_contains "$ALIAS_FILE" "cma_run_kimi()"    "cma_run_kimi wrapper present"
assert_file_contains "$ALIAS_FILE" "cma_run_kimi_provider()" "cma_run_kimi_provider wrapper present"
assert_file_contains "$ALIAS_FILE" "export CLAUDE_BIN=" "CLAUDE_BIN exported"

it "install.sh appends its PATH line to a pre-existing rc file"
assert_file_contains "$RC_FILE" "$PATH_LINE"            "PATH line appended"

it "install.sh is idempotent on a second run"
run_install
rc=$?
assert_eq 0 "$rc" "second install.sh exit code"
[[ $rc -eq 0 ]] || sed 's/^/    install.log| /' "$install_log"
# cma_run() must be defined exactly once (literal-paren match also excludes
# cma_run_provider()). A duplicate would mean the idempotency guard regressed.
cma_run_count="$(grep -c '^cma_run()' "$ALIAS_FILE" || true)"
assert_eq 1 "$cma_run_count" "cma_run defined exactly once after re-run"
# ...and the PATH line must not be doubled in the rc file.
path_line_count="$(grep -F -c -- "$PATH_LINE" "$RC_FILE" || true)"
assert_eq 1 "$path_line_count" "PATH line not duplicated after re-run"

# ── install.sh against pre-existing account dirs ─────────────────────────────
# Regression: install.sh symlinked scripts and created the alias file, but did
# NOT register claude<N> aliases for ~/.claude-* dirs that already existed.
# Users saw "claude1: command not found" after a "successful" install.

it "install.sh registers claude<N> aliases for pre-existing account dirs"
# Start fresh: new sandbox HOME with no prior state (and the OLD sandbox is
# torn down rather than orphaned — see fresh_sandbox above).
fresh_sandbox
# Create two account dirs that look like real Claude accounts.
mkdir -p "$HOME/.claude-1/projects" "$HOME/.claude-2/projects"
printf '{"account":"one"}\n' > "$HOME/.claude-1/.credentials.json"
printf '{"account":"two"}\n' > "$HOME/.claude-2/.credentials.json"
printf '{"name":"one"}\n' > "$HOME/.claude-1/.claude.json"
printf '{"name":"two"}\n' > "$HOME/.claude-2/.claude.json"
run_install
rc=$?
assert_eq 0 "$rc" "install.sh exit code with pre-existing accounts"
[[ $rc -eq 0 ]] || sed 's/^/    install.log| /' "$install_log"
assert_file_contains "$ALIAS_FILE" "alias claude1=\"CLAUDE_CONFIG_DIR=$HOME/.claude-1 cma_run\"" "claude1 alias registered"
assert_file_contains "$ALIAS_FILE" "alias claude2=\"CLAUDE_CONFIG_DIR=$HOME/.claude-2 cma_run\"" "claude2 alias registered"
alias_count="$(grep -cE '^alias claude[0-9]+=' "$ALIAS_FILE" || true)"
assert_eq 2 "$alias_count" "exactly two claudeN aliases registered"

# ── install.sh against pre-existing KIMI account dirs ────────────────────────
# The install-time kimi unify (step 5b) must register kimi<N> aliases for
# ~/.kimi-code-* dirs that already exist — the kimi analogue of the claudeN
# regression this file was built around.

it "install.sh registers kimi<N> aliases for pre-existing kimi account dirs"
fresh_sandbox
mkdir -p "$HOME/.kimi-code-1/sessions" "$HOME/.kimi-code-2/sessions"
printf '{"session":"a","msg":"A"}\n' > "$HOME/.kimi-code-1/sessions/a.jsonl"
printf '{"session":"b","msg":"B"}\n' > "$HOME/.kimi-code-2/sessions/b.jsonl"
run_install
rc=$?
assert_eq 0 "$rc" "install.sh exit code with pre-existing kimi accounts"
[[ $rc -eq 0 ]] || sed 's/^/    install.log| /' "$install_log"
assert_file_contains "$ALIAS_FILE" "alias kimi1=\"KIMI_CODE_HOME=$HOME/.kimi-code-1 cma_run_kimi\"" "kimi1 alias registered"
assert_file_contains "$ALIAS_FILE" "alias kimi2=\"KIMI_CODE_HOME=$HOME/.kimi-code-2 cma_run_kimi\"" "kimi2 alias registered"
kimi_alias_count="$(grep -cE '^alias kimi[0-9]+=' "$ALIAS_FILE" || true)"
assert_eq 2 "$kimi_alias_count" "exactly two kimiN aliases registered"

summary
