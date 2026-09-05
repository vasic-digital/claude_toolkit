#!/usr/bin/env bash
# kimi-unify.sh — Unify N Kimi Code account config dirs into a single shared
# store area ($SHARED_DIR/kimi) so every account sees the same sessions,
# session index, plugins, skills, and AGENTS.md. Family mirror of
# claude-unify.sh; every family-specific knob stays scoped to the kimi area
# of the shared store (claude's $SHARED_DIR/** is never touched).
#
# Inputs:
#   * Positional args: one or more Kimi account config directories. If none
#     are given, all `~/.kimi-code-*` directories are auto-detected.
#   * Env vars:
#       SHARED_DIR       shared store root (default: ~/.claude-shared)
#       KIMI_DEFAULT_DIR user-scope Kimi root (default: ~/.kimi-code)
#
# Use --rollback to restore the .preunify.* backups and move the kimi shared
# area aside. Safe to re-run any time.

set -euo pipefail

# macOS ships bash 3.2 which lacks `mapfile`. Re-exec under Homebrew bash
# if available; otherwise tell the user how to install it.
if (( BASH_VERSINFO[0] < 4 )); then
  for newer in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$newer" ]] && exec "$newer" "$0" "$@"
  done
  echo "kimi-unify requires bash 4+. Install via: brew install bash" >&2
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

KIMI_DEFAULT_DIR="${KIMI_DEFAULT_DIR:-$(cma_kimi_home)}"
SHARED_AREA="$SHARED_DIR/$KIMI_SHARED_SUBDIR"

cma_require rsync
cma_require jq
cma_require awk

# The one canonical list (CMA_KIMI_SHARED_ITEMS in lib.sh) — never a second
# copy that can drift. AGENTS.md is the memory analog of CLAUDE.md: promoted
# from the newest account and symlinked from every Kimi home (see
# promote_agents_md), so it is handled out-of-band from the dir loop.
KIMI_SHARED_ITEMS=( "${CMA_KIMI_SHARED_ITEMS[@]}" )

# Never shared (cp. claude's PRIVATE_ITEMS). config.toml / credentials/ /
# oauth/ / device_id are the account's private auth state; bin/ logs/ tui.toml
# are install-local.
PRIVATE_ITEMS=(
  config.toml
  credentials
  oauth
  device_id
  bin
  logs
  tui.toml
)

ts() { date +%Y%m%d%H%M%S; }

already_linked_to_shared() {
  [[ -L "$1" ]] || return 1
  [[ "$(cma_realpath "$1")" == "$(cma_realpath "$2")" ]]
}

# Every destructive replacement funnels through here so rollback can undo it.
backup_and_remove() {
  local p="$1"
  [[ -e "$p" || -L "$p" ]] || return 0
  mv "$p" "${p}.preunify.$(ts)"
}

link_to_shared() {
  local item="$1" acct
  # Never create a dangling symlink: if the merge step did not produce the
  # shared item, leave each account's real file untouched.
  [[ -e "$SHARED_AREA/$item" ]] || return 0
  for acct in "${ACCOUNTS[@]}"; do
    [[ -d "$acct" ]] || continue
    local target="$acct/$item"
    already_linked_to_shared "$target" "$SHARED_AREA/$item" && continue
    backup_and_remove "$target"
    mkdir -p "$(dirname "$target")"
    ln -s "$SHARED_AREA/$item" "$target"
  done
}

# Directories: two-pass rsync. First pass --ignore-existing per account
# (preserves the union); second pass overlays every account with rsync -u so
# the newest-mtime copy wins on file conflicts (not just the lexically-last
# account). Tolerates rsync 23/24 (benign partial-transfer warnings, common
# on macOS when symlinks straddle the tree).
merge_dir_into_shared() {
  local item="$1" exclude="${2:-}" acct rc
  local excl=()
  [[ -n "$exclude" ]] && excl=(--exclude "$exclude")
  mkdir -p "$SHARED_AREA/$item"
  for acct in "${ACCOUNTS[@]}"; do
    if [[ -d "$acct/$item" && ! -L "$acct/$item" ]]; then
      rc=0
      rsync -a --ignore-existing "${excl[@]}" "$acct/$item/" "$SHARED_AREA/$item/" || rc=$?
      (( rc == 0 || rc == 23 || rc == 24 )) || return $rc
    fi
  done
  for acct in "${ACCOUNTS[@]}"; do
    if [[ -d "$acct/$item" && ! -L "$acct/$item" ]]; then
      rc=0
      rsync -au "${excl[@]}" "$acct/$item/" "$SHARED_AREA/$item/" || rc=$?
      (( rc == 0 || rc == 23 || rc == 24 )) || return $rc
    fi
  done
}

# session_index.jsonl is the kimi analog of history.jsonl: concat all sources
# + line-dedupe (each session UUID is unique per account).
merge_session_index() {
  local acct srcs=() tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
  for acct in "${ACCOUNTS[@]}"; do
    local f="$acct/session_index.jsonl"
    if [[ -f "$f" && ! -L "$f" ]]; then srcs+=("$f"); fi
  done
  if [[ -f "$SHARED_AREA/session_index.jsonl" && ! -L "$SHARED_AREA/session_index.jsonl" ]]; then
    srcs+=("$SHARED_AREA/session_index.jsonl")
  fi
  if (( ${#srcs[@]} )); then
    awk 'NF && !seen[$0]++' "${srcs[@]}" > "$tmp"
    mv "$tmp" "$SHARED_AREA/session_index.jsonl"
  else
    : > "$SHARED_AREA/session_index.jsonl"
    rm -f "$tmp"
  fi
  return 0
}

# AGENTS.md (user-scope memory) is promoted from the NEWEST account (by
# mtime) into the shared area and symlinked from every Kimi home — the
# ~/.claude/CLAUDE.md promotion analog. The default root
# $KIMI_DEFAULT_DIR/AGENTS.md is a candidate too, so a user-scope edit wins
# when it is the freshest.
promote_agents_md() {
  local shared_md="$SHARED_AREA/AGENTS.md" newest="" src acct
  mkdir -p "$KIMI_DEFAULT_DIR"
  for src in "$KIMI_DEFAULT_DIR/AGENTS.md" "${ACCOUNTS[@]%/}/AGENTS.md"; do
    [[ -f "$src" && ! -L "$src" ]] || continue
    if [[ -z "$newest" || "$src" -nt "$newest" ]]; then newest="$src"; fi
  done
  if [[ -n "$newest" ]]; then cp -p "$newest" "$shared_md"; fi
  [[ -f "$shared_md" ]] || return 0
  local targets=("$KIMI_DEFAULT_DIR/AGENTS.md")
  for acct in "${ACCOUNTS[@]}"; do
    [[ -d "$acct" ]] || continue
    targets+=("$acct/AGENTS.md")
  done
  for tgt in "${targets[@]}"; do
    already_linked_to_shared "$tgt" "$shared_md" && continue
    backup_and_remove "$tgt"
    mkdir -p "$(dirname "$tgt")"
    ln -s "$shared_md" "$tgt"
  done
}

# User-scope plugins installed into ~/.kimi-code/plugins are absorbed into
# the shared area so every account sees them (cp. claude's
# absorb_default_plugins); kimi has no installed_plugins.json manifest to
# path-rewrite.
absorb_kimi_default_plugins() {
  [[ -d "$KIMI_DEFAULT_DIR/plugins" && ! -L "$KIMI_DEFAULT_DIR/plugins" ]] || return 0
  mkdir -p "$SHARED_AREA/plugins"
  local rc=0
  rsync -a --ignore-existing "$KIMI_DEFAULT_DIR/plugins/" "$SHARED_AREA/plugins/" || rc=$?
  (( rc == 0 || rc == 23 || rc == 24 )) || return $rc
  return 0
}

rollback() {
  cma_log "kimi rollback: restoring .preunify.* backups"
  local root
  local roots=("$KIMI_DEFAULT_DIR" "$KIMI_DEFAULT_DIR/plugins" "$SHARED_AREA")
  for root in "${ACCOUNTS[@]}"; do roots+=("$root"); done
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    # Restore backups oldest-first (suffix is a timestamp, so sort -z order is
    # chronological; the earliest backup is the true pre-unify original).
    while IFS= read -r -d '' bk; do
      local orig="${bk%.preunify.*}"
      [[ -L "$orig" ]] && rm -f "$orig"
      [[ -e "$orig" ]] || { mv "$bk" "$orig"; cma_log "restored $orig"; }
    done < <(find "$root" -maxdepth 1 -name '*.preunify.*' -print0 2>/dev/null | sort -z)
    [[ "$root" == "$SHARED_AREA" ]] && continue
    # Remove leftover symlinks pointing into the kimi shared area — only links
    # whose target is under $SHARED_AREA; claude's links into $SHARED_DIR/**
    # are untouched.
    while IFS= read -r -d '' lnk; do
      local tgt; tgt="$(readlink "$lnk")"
      case "$tgt" in
        "$SHARED_AREA"|"$SHARED_AREA"/*) rm -f "$lnk"; cma_log "removed shared-area symlink $lnk" ;;
      esac
    done < <(find "$root" -maxdepth 1 -type l -print0 2>/dev/null)
  done
  if [[ -d "$SHARED_AREA" ]]; then
    mv "$SHARED_AREA" "$SHARED_DIR/kimi.removed.$(ts)"
    cma_log "moved $SHARED_AREA aside"
  fi
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [--rollback] [account-dir ...]

Without args, auto-detects all ~/$KIMI_ACCOUNT_PREFIX* directories.
With --rollback, restores .preunify.* backups and removes the kimi shared area.

Env: SHARED_DIR=$SHARED_DIR KIMI_DEFAULT_DIR=$KIMI_DEFAULT_DIR
Private items kept per-account: ${PRIVATE_ITEMS[*]}
EOF
}

# === main ===

ACCOUNTS=()
DO_ROLLBACK=0
while (( $# )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --rollback) DO_ROLLBACK=1; shift ;;
    --) shift; while (( $# )); do ACCOUNTS+=("$1"); shift; done ;;
    -*) cma_die "unknown flag: $1" ;;
    *)  ACCOUNTS+=("$1"); shift ;;
  esac
done

if (( ${#ACCOUNTS[@]} == 0 )); then
  mapfile -t ACCOUNTS < <(cma_detect_kimi_accounts)
fi

(( ${#ACCOUNTS[@]} >= 1 )) || cma_die "no account dirs given and none auto-detected at ~/$KIMI_ACCOUNT_PREFIX*"

cma_log "kimi accounts: ${ACCOUNTS[*]}"
cma_log "kimi shared:   $SHARED_AREA"

if (( DO_ROLLBACK )); then rollback; exit 0; fi

mkdir -p "$SHARED_AREA"
absorb_kimi_default_plugins

for item in "${KIMI_SHARED_ITEMS[@]}"; do
  [[ "$item" == "AGENTS.md" ]] && continue   # handled out-of-band below
  case "$item" in
    session_index.jsonl) merge_session_index ;;
    *)                   merge_dir_into_shared "$item" ;;
  esac
  link_to_shared "$item"
  cma_log "ok: $item"
done

promote_agents_md
cma_log "ok: AGENTS.md (promoted from newest account; symlinked from every Kimi home)"
cma_log "ok: private items kept per-account: ${PRIVATE_ITEMS[*]}"

# Ensure every detected account has an invocable kimiN alias. Mirrors
# claude-unify's registration: first pass keeps an explicit kimi<N> basename,
# second pass assigns the lowest free kimi<N>.
cma_ensure_alias_file
declare -A ALIAS_OF_DIR=()
if [[ -f "$ALIAS_FILE" ]]; then
  while IFS= read -r line; do
    [[ "$line" =~ ^alias[[:space:]]+([a-zA-Z0-9_-]+)=.*KIMI_CODE_HOME=([^[:space:]]+) ]] || continue
    ALIAS_OF_DIR["${BASH_REMATCH[2]}"]="${BASH_REMATCH[1]}"
  done < "$ALIAS_FILE"
fi
for acct in "${ACCOUNTS[@]}"; do
  if [[ -z "${ALIAS_OF_DIR[$acct]:-}" ]]; then
    base="$(basename "$acct")"
    suffix="${base#${KIMI_ACCOUNT_PREFIX}}"
    if [[ "$suffix" =~ ^kimi([0-9]+)$ ]]; then
      wanted="kimi${BASH_REMATCH[1]}"
      if ! cma_existing_kimi_aliases | grep -qx "$wanted"; then
        cma_write_kimi_alias "$wanted" "$acct"
        cma_log "registered alias: $wanted -> $acct"
        continue
      fi
    fi
  fi
done
_cma_lowest_free_kimin() {
  local n=1
  while cma_existing_kimi_aliases | grep -qx "kimi$n"; do
    n=$((n + 1))
    (( n < 1000 )) || { cma_warn "could not find a free kimi<N> alias"; return 1; }
  done
  printf 'kimi%s\n' "$n"
}
for acct in "${ACCOUNTS[@]}"; do
  if [[ -z "${ALIAS_OF_DIR[$acct]:-}" ]]; then
    if grep -qE "alias[[:space:]]+[^=]+=.*KIMI_CODE_HOME=$acct([[:space:]]|$)" "$ALIAS_FILE"; then
      ALIAS_OF_DIR[$acct]="$(grep -E "alias[[:space:]]+[^=]+=.*KIMI_CODE_HOME=$acct([[:space:]]|$)" "$ALIAS_FILE" | head -1 | sed -E 's/^alias[[:space:]]+([^=]+)=.*/\1/')"
      continue
    fi
    next_alias="$(_cma_lowest_free_kimin)"
    cma_write_kimi_alias "$next_alias" "$acct"
    cma_log "registered alias: $next_alias -> $acct"
  fi
done

cma_log "done. kimi shared: $SHARED_AREA"