#!/usr/bin/env bash
# sandbox.sh — utilities for running scripts against a temp HOME so the
# real ~/.claude state is never touched.
#
# Usage from a test file:
#
#   source "$TESTS_DIR/lib/sandbox.sh"
#   make_sandbox          # creates $SANDBOX_HOME, exports HOME, etc.
#   make_account acct1    # creates a fake ~/.claude-acct1 inside sandbox
#   make_account acct2 --plugins
#   run_unify             # runs claude-unify.sh against the sandbox
#   cleanup_sandbox       # rm -rf the sandbox (registered with trap)

SCRIPTS_DIR="${SCRIPTS_DIR:-$HOME/Documents/scripts}"

make_sandbox() {
  # Remember the real HOME before overriding, so vendored Go is reachable.
  export CMA_REAL_HOME="${HOME:-/home/$(whoami)}"
  SANDBOX_HOME="$(mktemp -d "${TMPDIR:-/tmp}/cma-test.XXXXXX")"
  # Override every env var the toolkit reads from. Pointing HOME at the
  # sandbox is the main switch; the other vars only matter if a caller
  # tests defaults explicitly.
  export HOME="$SANDBOX_HOME"
  export SHARED_DIR="$SANDBOX_HOME/.claude-shared"
  export ALIAS_FILE="$SANDBOX_HOME/.local/share/claude-multi-account/aliases.sh"
  export DEFAULT_DIR="$SANDBOX_HOME/.claude"
  export ACCOUNT_PREFIX=".claude-"
  export CLAUDE_BIN="/usr/bin/true"  # dummy; we never actually launch claude
  # Point at the real vendored Go toolchain so ccr-build/proxy-build work in
  # the sandbox (the sandbox HOME doesn't have ~/.local/share/claude-go).
  if [[ -x "$CMA_REAL_HOME/.local/share/claude-go/bin/go" ]]; then
    export VENDORED_GO="$CMA_REAL_HOME/.local/share/claude-go/bin/go"
  fi
  mkdir -p "$DEFAULT_DIR" "$SANDBOX_HOME/.local/bin"
  # Self-check: prove the switch actually took before any test writes.
  assert_sandboxed
  trap 'cleanup_sandbox' EXIT
}

# assert_sandboxed — abort loudly unless $HOME is a sandbox from make_sandbox.
#
# This exists because a test that writes to $HOME without a sandbox does not
# merely fail: in the REAL home, ~/.local/bin/claude-* are SYMLINKS into this
# repo (install.sh links every claude-*.sh there), and `cat >` follows symlinks.
# A single unsandboxed stub write therefore destroys the production script it
# points at. That is not hypothetical — it silently truncated
# scripts/claude-session.sh from 201 lines to an 8-line stub and
# scripts/claude-sync-state.sh from 103 lines to 2, which broke every provider
# alias with "No conversation found with session ID: 11111111-2222-...".
#
# Exits 99 rather than returning: there is no safe way to continue.
assert_sandboxed() {
  case "$(basename "${HOME:-/}")" in
    cma-test.*) return 0 ;;
  esac
  echo "FATAL: test tried to use HOME=${HOME:-<unset>}, which is not a make_sandbox temp dir." >&2
  echo "       Refusing to continue: writes under the real \$HOME follow symlinks into the repo" >&2
  echo "       and would destroy production scripts. Call make_sandbox first." >&2
  exit 99
}

# sandbox_stub PATH — install an executable stub (content on stdin) inside the
# sandbox. Use this instead of `cat > "$HOME/..."` for anything under
# $HOME/.local/bin.
#
# Three guarantees a bare `cat >` does not give:
#   1. $HOME is a real sandbox (assert_sandboxed).
#   2. The target is INSIDE that sandbox — a path that escaped it is a bug.
#   3. An existing symlink is REMOVED before writing, never written through.
#      Guarantee 3 is the one that matters: it is what turns "clobbered a
#      production script" into "replaced a link inside a temp dir".
sandbox_stub() {
  local target="$1"
  assert_sandboxed
  case "$target" in
    "$HOME"/*) : ;;
    *) echo "FATAL: sandbox_stub target escapes the sandbox: $target" >&2; exit 99 ;;
  esac
  mkdir -p "$(dirname "$target")"
  # Break the link rather than following it.
  [[ -L "$target" ]] && rm -f -- "$target"
  cat > "$target"
  chmod +x "$target"
}

cleanup_sandbox() {
  [[ -n "${SANDBOX_HOME:-}" && -d "$SANDBOX_HOME" ]] || return 0
  # Safety net: only delete if the path matches what mktemp would have
  # produced (cma-test.* somewhere under a tempdir root). Different
  # systems put mktemp output in different places (/tmp on most Linux,
  # /tmp/.private/<user>/ on this host, /var/folders/... on macOS) so
  # we anchor on the cma-test. prefix rather than the parent.
  case "$(basename "$SANDBOX_HOME")" in
    cma-test.*)
      # Go installs its module cache read-only (0444 files, 0555 dirs), so a
      # plain `rm -rf` fails with EACCES partway through and leaves a
      # ~13.5k-file `go/pkg/mod` skeleton behind on EVERY run of any
      # Go-building test. Because the sandbox IS $HOME, each such test also
      # re-downloads the whole cache — 500-850MB per sandbox, unshared — so the
      # residue is the dominant term in sandbox leakage (109 orphans totalling
      # 35GB were measured before this was fixed).
      #
      # Restore write permission first so the removal can actually complete.
      # Safe by construction: this only ever runs inside a path whose basename
      # matched cma-test.*, i.e. a mktemp dir this suite created.
      chmod -R u+w -- "$SANDBOX_HOME" 2>/dev/null || true
      rm -rf -- "$SANDBOX_HOME"
      ;;
    *) echo "refusing to rm sandbox at unexpected path: $SANDBOX_HOME" >&2 ;;
  esac
}

# make_account NAME [--plugins] [--settings JSON] [--history "line1|line2"] [--memory KEY:VALUE...]
make_account() {
  local name="$1" with_plugins=0 settings_json="" history_lines=()
  shift
  local memory_entries=() todo_entries=()
  while (( $# )); do
    case "$1" in
      --plugins) with_plugins=1; shift ;;
      --settings) settings_json="$2"; shift 2 ;;
      --history) IFS='|' read -r -a history_lines <<< "$2"; shift 2 ;;
      --memory)  memory_entries+=("$2"); shift 2 ;;
      --todo)    todo_entries+=("$2"); shift 2 ;;
      *) echo "make_account: unknown arg $1" >&2; return 1 ;;
    esac
  done

  local dir="$HOME/${ACCOUNT_PREFIX}${name}"
  mkdir -p "$dir/projects/-home-test/memory" "$dir/todos" "$dir/tasks" \
           "$dir/plans" "$dir/file-history" "$dir/paste-cache" \
           "$dir/shell-snapshots" "$dir/session-env" "$dir/telemetry" \
           "$dir/sessions" "$dir/backups" "$dir/cache" "$dir/plugins"

  # Fake credentials so list-accounts reports CREDS:yes.
  printf '{"account":"%s"}\n' "$name" > "$dir/.credentials.json"
  printf '{"name":"%s"}\n' "$name" > "$dir/.claude.json"

  # A unique transcript so the union-merge step has something to merge.
  printf '{"role":"user","msg":"hi from %s"}\n' "$name" \
    > "$dir/projects/-home-test/$(uuidgen 2>/dev/null || echo "session-${name}").jsonl"

  # Memory + todo content if requested.
  local m
  for m in ${memory_entries[@]+"${memory_entries[@]}"}; do
    local k="${m%%:*}" v="${m#*:}"
    printf -- '%s\n' "$v" > "$dir/projects/-home-test/memory/${k}.md"
  done
  local t
  for t in ${todo_entries[@]+"${todo_entries[@]}"}; do
    printf '{"subject":"%s"}\n' "$t" > "$dir/todos/$(uuidgen 2>/dev/null || echo "todo-${name}-$t").json"
  done

  # History lines (used to test concat+dedup later).
  if (( ${#history_lines[@]} )); then
    printf '%s\n' "${history_lines[@]}" > "$dir/history.jsonl"
  fi

  # Settings JSON if specified, else a minimal default.
  if [[ -n "$settings_json" ]]; then
    printf '%s\n' "$settings_json" > "$dir/settings.json"
  else
    printf '{"enabledPlugins":{"%s-plugin":true}}\n' "$name" > "$dir/settings.json"
  fi

  if (( with_plugins )); then
    mkdir -p "$dir/plugins/cache/test-marketplace/test-plugin/1.0.0"
    mkdir -p "$dir/plugins/marketplaces/test-marketplace"
    cat > "$dir/plugins/installed_plugins.json" <<EOF
{
  "version": 2,
  "plugins": {
    "test-plugin@test-marketplace": [
      {
        "scope": "project",
        "installPath": "$dir/plugins/cache/test-marketplace/test-plugin/1.0.0",
        "version": "1.0.0"
      }
    ]
  }
}
EOF
    cat > "$dir/plugins/known_marketplaces.json" <<EOF
{
  "test-marketplace": {
    "source": {"source": "github", "repo": "example/test"},
    "installLocation": "$dir/plugins/marketplaces/test-marketplace"
  }
}
EOF
  fi

  echo "$dir"
}

run_unify() {
  "$SCRIPTS_DIR/claude-unify.sh" "$@"
}

run_add_account() {
  "$SCRIPTS_DIR/claude-add-account.sh" "$@"
}

run_remove_account() {
  "$SCRIPTS_DIR/claude-remove-account.sh" "$@"
}

run_list_accounts() {
  "$SCRIPTS_DIR/claude-list-accounts.sh" "$@"
}

run_rollback() {
  "$SCRIPTS_DIR/claude-rollback.sh" "$@"
}
