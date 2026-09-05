#!/usr/bin/env bash
# test_curl_install.sh — hermetic tests for the curl-install bootstrap script.
#
# Tests the script's logic without network access by mocking git and verifying
# the shell-level decisions (platform detection, dependency checking, path
# construction, idempotency logic).
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
set +e

INSTALL_SCRIPT="$SCRIPTS_DIR/curl-install.sh"

# ── 1. Syntax and basic properties ─────────────────────────────────────────────

it "curl-install.sh passes bash -n syntax check"
bash -n "$INSTALL_SCRIPT"
assert_eq 0 $? "bash -n passes"

it "curl-install.sh is executable"
_exec=1; [[ -x "$INSTALL_SCRIPT" ]] && _exec=0
assert_eq 0 "$_exec" "executable"

it "curl-install.sh has the canonical underscore REPO_URL (F4-005)"
assert_file_contains "$INSTALL_SCRIPT" "https://github.com/vasic-digital/claude_toolkit.git" "canonical REPO_URL present"
# The legacy hyphen name is a GitHub rename-alias of the same repo
# (gh repo id R_kgDOSn8-DQ, verified 2026-09-05); the bootstrap must not
# depend on the redirect.
assert_file_not_contains "$INSTALL_SCRIPT" 'REPO_URL="https://github.com/vasic-digital/claude-toolkit.git"' "legacy hyphen REPO_URL absent"

it "curl-install.sh uses --recursive for submodule clone"
assert_file_contains "$INSTALL_SCRIPT" "git clone --recursive" "clone uses --recursive"

it "curl-install.sh defaults INSTALL_DIR to ~/claude-toolkit"
# shellcheck disable=SC2016  # matching literal $HOME in the script text
assert_file_contains "$INSTALL_SCRIPT" 'INSTALL_DIR="${CLAUDE_TOOLKIT_DIR:-$HOME/claude-toolkit}"' "default install dir"

it "curl-install.sh is idempotent (checks for existing .git dir)"
# shellcheck disable=SC2016  # matching literal string in the script
assert_file_contains "$INSTALL_SCRIPT" '-d "$INSTALL_DIR/.git"' "checks for existing repo"

it "curl-install.sh runs install.sh after clone/pull"
# shellcheck disable=SC2016  # matching literal string in the script
assert_file_contains "$INSTALL_SCRIPT" 'bash "$INSTALL_DIR/scripts/install.sh"' "runs install.sh"

# ── 2. Platform detection ─────────────────────────────────────────────────────

it "curl-install.sh detects OS via uname -s"
# shellcheck disable=SC2016  # matching literal string in the script
assert_file_contains "$INSTALL_SCRIPT" 'OS="$(uname -s)"' "platform detection"

it "curl-install.sh detects shell for rc-file selection"
assert_file_contains "$INSTALL_SCRIPT" 'SHELL_RC=' "shell rc detection"

it "curl-install.sh has package managers for Linux (apt, dnf, apk, pacman)"
assert_file_contains "$INSTALL_SCRIPT" "apt-get" "apt support"
assert_file_contains "$INSTALL_SCRIPT" "dnf" "dnf support"
assert_file_contains "$INSTALL_SCRIPT" "apk" "apk support"
assert_file_contains "$INSTALL_SCRIPT" "pacman" "pacman support"

it "curl-install.sh has Homebrew for macOS"
assert_file_contains "$INSTALL_SCRIPT" "brew install" "brew support"

# ── 3. Dependency checking ────────────────────────────────────────────────────

it "curl-install.sh checks for jq, rsync, awk as hard dependencies"
assert_file_contains "$INSTALL_SCRIPT" 'for cmd in jq rsync awk' "hard dep check"

it "curl-install.sh also requires git"
assert_file_contains "$INSTALL_SCRIPT" 'for cmd in jq rsync awk git' "git in final check"

# ── 4. Error handling ─────────────────────────────────────────────────────────

it "curl-install.sh uses set -euo pipefail"
assert_file_contains "$INSTALL_SCRIPT" 'set -euo pipefail' "strict mode"

it "curl-install.sh dies on missing dependencies"
assert_file_contains "$INSTALL_SCRIPT" 'die "could not auto-install' "fatal on missing deps"

it "curl-install.sh exits non-zero on git clone failure"
assert_file_contains "$INSTALL_SCRIPT" 'die "git clone failed"' "dies on clone failure"

# ── 5. End-user output ────────────────────────────────────────────────────────

it "curl-install.sh prints next-steps (claude-list-accounts)"
assert_file_contains "$INSTALL_SCRIPT" "claude-list-accounts" "next-steps guidance"

it "curl-install.sh prints next-steps (claude-providers sync)"
assert_file_contains "$INSTALL_SCRIPT" "claude-providers sync" "providers guidance"

it "curl-install.sh supports CLAUDE_TOOLKIT_DIR env override"
assert_file_contains "$INSTALL_SCRIPT" 'CLAUDE_TOOLKIT_DIR' "env override supported"

# ── 6. Sandboxed bootstrap dry-run (F4-005 test_plan) ─────────────────────────
#
# Hermetic end-to-end of the clone path: a sandbox_stub'd git records its
# arguments and fabricates the cloned repo (with a no-op install.sh), so the
# bootstrap runs to completion with no network and never touches real
# ~/.claude state. The assertion that matters: git clone is invoked with the
# canonical underscore REPO_URL.

it "sandboxed bootstrap clones via the canonical underscore URL"
GIT_LOG="$SANDBOX_HOME/git-invocations.log"
CLONE_DIR="$SANDBOX_HOME/ct-install"
sandbox_stub "$SANDBOX_HOME/bin/git" <<STUB
#!/usr/bin/env bash
# Record every invocation, then fabricate a clone good enough for the
# bootstrap's post-clone step (scripts/install.sh must exist and exit 0).
printf '%s\n' "\$*" >> "$GIT_LOG"
if [[ "\$1" == "clone" ]]; then
  dest="\${@: -1}"
  mkdir -p "\$dest/.git" "\$dest/scripts"
  printf '#!/usr/bin/env bash\nexit 0\n' > "\$dest/scripts/install.sh"
fi
exit 0
STUB

CLAUDE_TOOLKIT_DIR="$CLONE_DIR" PATH="$SANDBOX_HOME/bin:$PATH" \
  bash "$INSTALL_SCRIPT" >/dev/null 2>&1
assert_eq 0 $? "bootstrap completes against stubbed git"

CLONE_LINE="$(grep '^clone ' "$GIT_LOG" | head -n1)"
assert_file_contains "$GIT_LOG" "clone --recursive https://github.com/vasic-digital/claude_toolkit.git" "git clone invoked with canonical underscore URL"
case "$CLONE_LINE" in
  *claude-toolkit*) _fail "clone used legacy hyphen alias" "clone line: $CLONE_LINE" ;;
esac
assert_dir "$CLONE_DIR/.git" "stub created cloned repo"

summary
