#!/usr/bin/env bash
# kimi-add-account.sh — Add a new Kimi Code account to the multi-account
# setup. Creates the per-account config directory, links every shared Kimi
# item to the shared store area ($SHARED_DIR/kimi), and registers a shell
# alias so the new account is invocable as e.g. `kimi3`. Family mirror of
# claude-add-account.sh.
#
# Modes:
#   * Interactive (default): prompts for alias name and config dir name.
#   * Non-interactive: pass --alias NAME and optionally --dir PATH.
#   * --login: drive Kimi's interactive device flow right away (requires a
#     terminal — headless login is a non-goal).
#
# After this script runs you still need to authenticate the new account
# with Moonshot — the script prints the exact command for that.

set -euo pipefail

# Resolve LIB_DIR through any symlinks (install.sh symlinks into ~/.local/bin).
_cma_src="${BASH_SOURCE[0]}"
while [ -L "$_cma_src" ]; do
  _cma_tgt="$(readlink "$_cma_src")"
  case "$_cma_tgt" in /*) _cma_src="$_cma_tgt" ;; *) _cma_src="$(dirname "$_cma_src")/$_cma_tgt" ;; esac
done
LIB_DIR="$(cd "$(dirname "$_cma_src")" && pwd)"
unset _cma_src _cma_tgt
# shellcheck source=lib.sh
source "$LIB_DIR/lib.sh"

ALIAS_NAME=""
CONFIG_DIR=""
NONINTERACTIVE=0
DO_LOGIN=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--alias NAME] [--dir PATH] [--yes] [--login]

  --alias NAME   Shell alias to create (e.g. kimi3 or work). Default:
                 next free kimiN.
  --dir   PATH   Config directory for the new account. Default:
                 ~/$KIMI_ACCOUNT_PREFIX<alias>.
  --yes          Skip prompts and use defaults / passed values.
  --login        Drive Kimi's interactive device flow after registering the
                 account. Requires a terminal (refused headless).
EOF
}

while (( $# )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --alias)   ALIAS_NAME="$2"; shift 2 ;;
    --dir)     CONFIG_DIR="$2"; shift 2 ;;
    --yes|-y)  NONINTERACTIVE=1; shift ;;
    --login)   DO_LOGIN=1; shift ;;
    *)         cma_die "unknown arg: $1" ;;
  esac
done

# --login drives Kimi's interactive device flow. If a terminal is unavailable
# there is nothing to type the code into, so refuse BEFORE creating anything.
if (( DO_LOGIN )) && { (( NONINTERACTIVE )) || ! cma_can_prompt; }; then
  cma_die "--login requires a terminal (Kimi login is an interactive device flow); run without --login in CI and log in later with: <alias> login"
fi

# Prompt with a default value, return whatever the user types (or default).
prompt() {
  local label="$1" default="$2" answer
  # Use the default when --yes was passed OR no terminal is available to
  # prompt from (CI, test sandbox, SSH without a PTY) — never block.
  if (( NONINTERACTIVE )) || ! cma_can_prompt; then echo "$default"; return; fi
  read -r -p "$label [$default]: " answer < /dev/tty
  echo "${answer:-$default}"
}

[[ -n "$ALIAS_NAME" ]] || ALIAS_NAME="$(cma_suggest_kimi_alias)"
ALIAS_NAME="$(prompt "Alias name" "$ALIAS_NAME")"
cma_validate_kimi_alias "$ALIAS_NAME"

# Reject if alias already exists in the alias file. Account aliases must also
# never collide with a provider namespace (validated above).
if cma_existing_kimi_aliases | grep -qx "$ALIAS_NAME"; then
  cma_die "alias '$ALIAS_NAME' already exists in $ALIAS_FILE"
fi

[[ -n "$CONFIG_DIR" ]] || CONFIG_DIR="$HOME/${KIMI_ACCOUNT_PREFIX}${ALIAS_NAME}"
CONFIG_DIR="$(prompt "Config directory" "$CONFIG_DIR")"
case "$CONFIG_DIR" in /*) ;; *) CONFIG_DIR="$HOME/$CONFIG_DIR" ;; esac

[[ -d "$CONFIG_DIR" ]] && cma_die "config dir already exists: $CONFIG_DIR (refusing to overwrite)"

mkdir -p "$CONFIG_DIR"
cma_log "created $CONFIG_DIR"

cma_link_kimi_shared_items "$CONFIG_DIR"
cma_log "linked ${#CMA_KIMI_SHARED_ITEMS[@]} shared items into $CONFIG_DIR"

# Add the alias. The status is CHECKED: report what actually happened and
# name the one command that finishes the job (mirror of claude-add-account).
if ! cma_write_kimi_alias "$ALIAS_NAME" "$CONFIG_DIR"; then
  cma_warn "the alias for '$ALIAS_NAME' was NOT written to $ALIAS_FILE"
  cma_warn "$CONFIG_DIR exists and its shared items are linked — only the alias is missing."
  cma_die  "Finish with:  kimi-unify   (re-registers an alias for every detected account)"
fi
cma_log "registered alias: $ALIAS_NAME -> $CONFIG_DIR"

if (( DO_LOGIN )); then
  _kbin="$(cma_resolve_kimi_bin)"
  cma_log "driving Kimi device flow with KIMI_CODE_HOME=$CONFIG_DIR"
  KIMI_CODE_HOME="$CONFIG_DIR" "$_kbin" login
fi

cat <<EOF

[done] new account: $ALIAS_NAME

Next steps:
  1. Reload your shell (or run: source $ALIAS_FILE).
  2. Authenticate the new account:
       $ALIAS_NAME login
  3. After login, run any project — sessions, plugins, skills, and memory
     will already match your other accounts via $SHARED_DIR/kimi.

To remove this account later:
  $LIB_DIR/kimi-remove-account.sh --alias $ALIAS_NAME
EOF

# Long-lived shells (tmux panes) may have sourced the alias file before this
# add; tell them to re-source (mirror of claude-add-account). The notice never
# sends keys; the broadcast is interactive, default No, and scoped to idle
# SHELL panes only.
cma_tmux_stale_shell_notice "$ALIAS_FILE" || true
if ! (( NONINTERACTIVE )) && cma_can_prompt; then
  _bc="$(prompt "Broadcast the re-source into idle tmux SHELL panes now? (y/N)" "N")"
  case "$_bc" in
    [Yy]*)
      _tdir="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
      for _sock in "$_tdir"/*; do
        [[ -S "$_sock" ]] || continue
        tmux -S "$_sock" list-panes -a -F '#{pane_id} #{pane_current_command}' 2>/dev/null \
          | awk '$2 ~ /^-?(bash|zsh|sh|dash|ksh|fish)$/{print $1}' \
          | while read -r _pane; do
              tmux -S "$_sock" send-keys -t "$_pane" C-u " source $ALIAS_FILE" Enter 2>/dev/null || true
            done
      done
      cma_log "re-source broadcast sent to idle shell panes" ;;
    *) : ;;
  esac
fi