#!/usr/bin/env bash
# kimi-remove-account.sh — Remove a Kimi Code account from the multi-account
# setup. Drops the alias from the managed alias file and (optionally) deletes
# or archives the per-account config directory. Family mirror of
# claude-remove-account.sh.
#
# The shared store area is left untouched — only this one account's symlinks
# and credentials are removed. Other kimi accounts continue using
# $SHARED_DIR/kimi.

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
DELETE_DIR=0
NONINTERACTIVE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") --alias NAME [--delete | --archive] [--yes]

  --alias NAME   Required. Alias to remove (e.g. kimi3).
  --delete       Permanently delete the per-account config directory.
  --archive      Move the per-account dir to <dir>.removed.<timestamp>
                 instead of deleting (default).
  --yes          Skip confirmation prompts.
EOF
}

while (( $# )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --alias)   ALIAS_NAME="$2"; shift 2 ;;
    --delete)  DELETE_DIR=1; shift ;;
    --archive) DELETE_DIR=0; shift ;;
    --yes|-y)  NONINTERACTIVE=1; shift ;;
    *)         cma_die "unknown arg: $1" ;;
  esac
done

[[ -n "$ALIAS_NAME" ]] || { usage; exit 2; }
cma_validate_kimi_alias "$ALIAS_NAME"

# Resolve the config dir by inspecting the existing alias line. POSIX/2-arg
# awk match() only (the 3-arg capture form is GNU-awk-specific).
CONFIG_DIR=""
if [[ -f "$ALIAS_FILE" ]]; then
  CONFIG_DIR="$(awk -v a="$ALIAS_NAME" '
    $0 ~ "^alias[[:space:]]+"a"=" {
      if (match($0, /KIMI_CODE_HOME=[^ ]+/)) {
        s = substr($0, RSTART, RLENGTH)
        sub(/^KIMI_CODE_HOME=/, "", s)
        print s
      }
      exit
    }' "$ALIAS_FILE")"
fi
[[ -n "$CONFIG_DIR" ]] || cma_die "alias '$ALIAS_NAME' not found in $ALIAS_FILE"

cma_log "removing alias '$ALIAS_NAME' (config dir: $CONFIG_DIR)"

if (( ! NONINTERACTIVE )); then
  # Destructive op: when no terminal is available to confirm from, refuse
  # rather than block or guess — pass --yes to proceed non-interactively.
  cma_can_prompt || cma_die "no terminal to confirm removal; pass --yes to proceed non-interactively"
  read -r -p "Proceed? [y/N] " ans < /dev/tty
  [[ "$ans" =~ ^[Yy]$ ]] || cma_die "aborted"
fi

# The status is CHECKED, and the directory move below is gated on it — a live
# alias must never point at a moved dir (mirror of claude-remove-account).
if ! cma_remove_kimi_alias "$ALIAS_NAME"; then
  cma_warn "the alias '$ALIAS_NAME' was NOT removed from $ALIAS_FILE"
  cma_die  "$CONFIG_DIR left in place on purpose — a live alias must never point at a moved dir. Re-run to retry."
fi
cma_log "alias removed from $ALIAS_FILE"

if [[ -d "$CONFIG_DIR" ]]; then
  if (( DELETE_DIR )); then
    rm -rf -- "$CONFIG_DIR"
    cma_log "deleted $CONFIG_DIR"
  else
    mv -- "$CONFIG_DIR" "${CONFIG_DIR}.removed.$(date +%Y%m%d%H%M%S)"
    cma_log "archived $CONFIG_DIR -> ${CONFIG_DIR}.removed.*"
  fi
fi

cat <<EOF

[done] account '$ALIAS_NAME' removed.

Notes:
  * Shared store $SHARED_DIR/kimi is untouched — other kimi accounts still work.
  * Reload your shell so the alias change takes effect.
EOF