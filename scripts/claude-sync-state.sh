#!/usr/bin/env bash
# claude-sync-state.sh — Fast (no rsync) sync of the .claude.json projects /
# session index across every Claude Code account. Called by the cma_run alias
# wrapper before launch (pull) and after exit (push) so sessions/memory
# created in one account are immediately visible to all others.
#
# Distinct from claude-unify.sh: unify is the heavy one-shot merger of the
# whole shared store; this is the lightweight per-launch state hook.
#
# Modes:
#   claude-sync-state pull <account-dir>   Merge every account's .claude.json
#                                          into <account-dir>'s file.
#   claude-sync-state push <account-dir>   Merge <account-dir>'s freshly-
#                                          written .claude.json into all other
#                                          accounts' files.
#   claude-sync-state all                  Merge across every detected account.
#
# In every mode, each account keeps its OWN auth/identity keys (`userID`,
# `oauthAccount`, `firstStartTime`, `claudeCodeFirstTokenDate`) untouched —
# everything else (projects map, MCP server status, UX state, caches) is
# unioned across accounts. See CMA_CLAUDE_JSON_PRIVATE_KEYS in lib.sh.

set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  for newer in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$newer" ]] && exec "$newer" "$0" "$@"
  done
  echo "claude-sync-state requires bash 4+. Install via: brew install bash" >&2
  exit 1
fi

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

usage() {
  cat <<EOF
Usage:
  $(basename "$0") pull <account-dir>
  $(basename "$0") push <account-dir>
  $(basename "$0") all
  $(basename "$0") --help
EOF
}

[[ $# -ge 1 ]] || { usage; exit 2; }

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

mode="$1"; shift

# Discover every Claude account dir we should sync against.
# Include provider dirs so sessions created under any alias (claudeN, deepseek,
# opencode, xiaomi, …) are visible from every other alias on next launch.
mapfile -t ALL_ACCOUNTS < <(
  cma_detect_accounts
  for _d in "$HOME/${ACCOUNT_PREFIX}"prov-*/; do
    [[ -d "$_d" ]] && echo "${_d%/}"
  done 2>/dev/null
)
(( ${#ALL_ACCOUNTS[@]} >= 1 )) || { cma_warn "no account dirs detected; nothing to sync"; exit 0; }

case "$mode" in
  pull|push)
    [[ $# -ge 1 ]] || { usage; exit 2; }
    target="$1"
    # Canonicalize to absolute path so it matches what cma_detect_accounts emits.
    target="$(cd "$target" && pwd)"
    # For pull and push the math is identical: merge across every account,
    # rewriting every file. The "target" arg exists so the alias wrapper can
    # report which account triggered the sync (and we don't waste cycles when
    # there's only one account — nothing to merge from/to).
    #
    # KNOWN, ACCEPTED race: pull/push rewrite EVERY account's .claude.json, not
    # just the target's. Two claudeN launching concurrently can interleave; the
    # per-file mv is last-writer-wins, so a non-union scalar another account
    # just wrote can be lost. The projects subtree is unioned (the common case
    # is safe), and an in-flight partial write is caught by the jq guard and
    # skipped. We deliberately do NOT add a lock here: a cross-platform mutex
    # (no portable flock on macOS) with stale-lock recovery would add more
    # failure modes than the rare scalar-loss it prevents, on a hook that runs
    # on every launch. Revisit only if non-projects scalar state proves lossy.
    if (( ${#ALL_ACCOUNTS[@]} == 1 )); then
      cma_policy_enforce_all
      exit 0
    fi
    cma_merge_claude_json "${ALL_ACCOUNTS[@]}"
    cma_policy_enforce_all   # v1.34.0: curated plugin/MCP set (no-op without a captured policy)
    ;;
  all)
    cma_merge_claude_json "${ALL_ACCOUNTS[@]}"
    cma_policy_enforce_all
    ;;
  *)
    usage; exit 2 ;;
esac
