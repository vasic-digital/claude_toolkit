#!/usr/bin/env bash
# claude-unify.sh — Unify N Claude Code account config dirs into a single
# shared store so every account sees the same projects/conversations,
# memory, history, todos, plans, plugins, and settings.
#
# Inputs:
#   * Positional args: one or more account config directories. If none
#     are given, all `~/.claude-*` directories are auto-detected (excluding
#     the shared store itself).
#   * Env vars:
#       SHARED_DIR    target shared store (default: ~/.claude-shared)
#       DEFAULT_DIR   user-scope plugin root (default: ~/.claude)
#
# Use --rollback to restore the .preunify.* backups and remove the shared
# store. Safe to re-run any time.

set -euo pipefail

# macOS ships bash 3.2 which lacks `mapfile`. Re-exec under Homebrew bash
# if available; otherwise tell the user how to install it.
if (( BASH_VERSINFO[0] < 4 )); then
  for newer in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$newer" ]] && exec "$newer" "$0" "$@"
  done
  echo "claude-unify requires bash 4+. Install via: brew install bash" >&2
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

DEFAULT_DIR="${DEFAULT_DIR:-$HOME/.claude}"

cma_require rsync
cma_require jq
cma_require awk

# Items each account dir contributes to the shared store. Order matters
# only insofar as we want plugins last so the path-rewrite step has all
# manifest entries to rewrite at once.
SHARED_ITEMS=(
  projects
  todos
  tasks
  plans
  file-history
  paste-cache
  shell-snapshots
  session-env
  telemetry
  sessions
  backups
  cache
  stats-cache.json
  history.jsonl
  plugins
  daemon
  jobs
)
# NOTE (§11.4 own-settings): settings.json is DELIBERATELY NOT in SHARED_ITEMS,
# so it is never symlinked into an account dir. Unify does NOT blanket-merge full
# account settings into the shared store (that re-leaks per-alias permissions/
# model/hooks to shared and thence to every dir). Instead it ONLY unions the
# enabledPlugins map into the shared TEMPLATE (union_enabled_plugins_into_template)
# and then re-seeds each dir's OWN settings.json from it (seed_own_settings) so
# newly-enabled plugins propagate while every other per-alias key stays local.
# This list MUST stay == CMA_SHARED_ITEMS (lib.sh) minus the CLAUDE.md special-
# case (enforced by the drift-guard test in test_unify.sh).

PRIVATE_ITEMS=(
  .credentials.json
  .claude.json
  mcp-needs-auth-cache.json
)

ts() { date +%Y%m%d%H%M%S; }

already_linked_to_shared() {
  [[ -L "$1" ]] || return 1
  # cma_realpath (not `readlink -f`, which is absent on BSD/macOS — there the
  # old check always failed, so unify re-linked every item on every re-run).
  [[ "$(cma_realpath "$1")" == "$(cma_realpath "$2")" ]]
}

backup_and_remove() {
  local p="$1"
  [[ -e "$p" || -L "$p" ]] || return 0
  mv "$p" "${p}.preunify.$(ts)"
}

link_to_shared() {
  local item="$1" acct
  # Never create a dangling symlink: if the merge step did not produce the
  # shared item (e.g. settings.json skipped because every account file was
  # invalid JSON, or a stats-cache.json that no account had), leave each
  # account's real file untouched rather than backing it up and pointing it at a
  # missing target — that would silently replace a valid live config with a
  # broken link.
  [[ -e "$SHARED_DIR/$item" ]] || return 0
  for acct in "${ACCOUNTS[@]}"; do
    [[ -d "$acct" ]] || continue
    local target="$acct/$item"
    already_linked_to_shared "$target" "$SHARED_DIR/$item" && continue
    backup_and_remove "$target"
    mkdir -p "$(dirname "$target")"
    ln -s "$SHARED_DIR/$item" "$target"
  done
}

merge_dir_into_shared() {
  local item="$1" exclude="${2:-}" acct rc
  local excl=()
  [[ -n "$exclude" ]] && excl=(--exclude "$exclude")
  mkdir -p "$SHARED_DIR/$item"
  # First pass: each account fills only gaps (--ignore-existing) so the
  # union is preserved across N accounts.
  for acct in "${ACCOUNTS[@]}"; do
    if [[ -d "$acct/$item" && ! -L "$acct/$item" ]]; then
      rc=0
      rsync -a --ignore-existing "${excl[@]}" "$acct/$item/" "$SHARED_DIR/$item/" || rc=$?
      # rsync exit 23/24 are partial transfers ("some files vanished" / "some
      # files couldn't be transferred") that we treat as warnings — common on
      # macOS for `unlinkat: Directory not empty` when symlinks straddle the
      # tree. Anything else is fatal.
      (( rc == 0 || rc == 23 || rc == 24 )) || return $rc
    fi
  done
  # Second pass: overlay every account with rsync -u (update-only) so the file
  # carrying the NEWEST mtime wins each conflict, regardless of how many accounts
  # there are or what they're named. The previous code overlaid only
  # ACCOUNTS[-1] — the alphabetically-last dir, not necessarily the most recently
  # active one — which let a stale lexically-last account clobber fresher content
  # (e.g. memory/*.md) from an earlier account.
  for acct in "${ACCOUNTS[@]}"; do
    if [[ -d "$acct/$item" && ! -L "$acct/$item" ]]; then
      rc=0
      rsync -au "${excl[@]}" "$acct/$item/" "$SHARED_DIR/$item/" || rc=$?
      (( rc == 0 || rc == 23 || rc == 24 )) || return $rc
    fi
  done
}

# daemon/roster.json is the background-agent WORKER REGISTRY. The generic
# dir merge's per-file last-wins would keep only ONE alias's registry and
# silently drop every other alias's workers. Union them instead via
# cma_union_rosters (lib.sh): newer updatedAt wins per worker, proto and
# supervisorPid from the newest roster, top-level updatedAt is the max.
merge_daemon_roster() {
  local acct f srcs=()
  for acct in "${ACCOUNTS[@]}"; do
    f="$acct/daemon/roster.json"
    [[ -f "$f" && ! -L "$f" ]] && srcs+=("$f")
  done
  f="$SHARED_DIR/daemon/roster.json"
  [[ -f "$f" && ! -L "$f" ]] && srcs+=("$f")
  (( ${#srcs[@]} )) || return 0
  cma_union_rosters "$SHARED_DIR/daemon/roster.json" "${srcs[@]}" || \
    cma_warn "daemon roster union failed (invalid roster.json?) — last-wins file kept"
  return 0
}

merge_history_jsonl() {
  local acct srcs=() tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
  for acct in "${ACCOUNTS[@]}"; do
    local f="$acct/history.jsonl"
    if [[ -f "$f" && ! -L "$f" ]]; then srcs+=("$f"); fi
  done
  if [[ -f "$SHARED_DIR/history.jsonl" && ! -L "$SHARED_DIR/history.jsonl" ]]; then
    srcs+=("$SHARED_DIR/history.jsonl")
  fi
  # Feed the files straight to awk rather than cat'ing them together first: awk
  # starts a fresh record at every file boundary, so a source missing its
  # trailing newline cannot fuse its last line onto the next file's first line
  # (plain `cat` would). Write via a temp file so we never truncate shared while
  # it is also one of the inputs.
  if (( ${#srcs[@]} )); then
    awk 'NF && !seen[$0]++' "${srcs[@]}" > "$tmp"
    mv "$tmp" "$SHARED_DIR/history.jsonl"
  else
    : > "$SHARED_DIR/history.jsonl"
    rm -f "$tmp"
  fi
  return 0
}

# §11.4 own-settings: unify NEVER blanket-merges full account settings into the
# shared store — that would re-leak each alias's permissions/model/hooks to
# shared and, through the shared symlink, to every other alias. Instead it ONLY
# extracts the enabledPlugins map from every account's OWN settings.json and
# UNIONs it (any-true) into the shared TEMPLATE's enabledPlugins, leaving every
# other key of the template — and every key of each dir's OWN settings.json —
# untouched. seed_own_settings then propagates that union back into each dir.
union_enabled_plugins_into_template() {
  local acct files=() resolved f tmpl="$SHARED_DIR/settings.json"
  for acct in "${ACCOUNTS[@]}"; do
    f="$acct/settings.json"
    if [[ -L "$f" ]]; then
      resolved="$(cma_realpath "$f")"  # readlink -f is unavailable on BSD/macOS
      if [[ -f "$resolved" ]]; then files+=("$resolved"); fi
    elif [[ -f "$f" ]]; then
      files+=("$f")
    fi
  done
  # Include the existing template so a plugin enabled on a prior run (any-true)
  # persists even if no current account carries it.
  [[ -f "$tmpl" ]] && files+=("$tmpl")
  # De-duplicate. On re-runs two account paths can resolve to the same file, and
  # passing the same path twice would double-count (harmless for a union, but we
  # keep the set clean).
  if (( ${#files[@]} > 1 )); then
    mapfile -t files < <(printf '%s\n' "${files[@]}" | awk '!seen[$0]++')
  fi
  # Drop any file that is not valid JSON so one hand-edited/corrupt account
  # settings.json can't sink the whole union — jq -s slurps every file and fails
  # wholesale on a single parse error. See test R3.
  local validf=()
  for f in ${files[@]+"${files[@]}"}; do
    if jq empty "$f" 2>/dev/null; then
      validf+=("$f")
    else
      cma_warn "settings.json in $(dirname "$f") is not valid JSON — excluded from enabledPlugins union"
    fi
  done
  files=(${validf[@]+"${validf[@]}"})
  (( ${#files[@]} )) || return 0
  mkdir -p "$SHARED_DIR"
  [[ -f "$tmpl" ]] || printf '{}\n' > "$tmpl"
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
  # Two-step so the shared template's OWN non-plugin keys (if any) survive and no
  # per-account non-plugin key ever enters shared:
  #   1. build the any-true union of enabledPlugins across every valid file,
  #      with keys SORTED so the template is byte-stable across re-runs
  #      regardless of per-account key order (idempotency, test line ~93);
  #   2. set ONLY .enabledPlugins on the existing template to that union.
  local union
  if union="$(jq -s '
        reduce .[] as $x ({};
          reduce (($x.enabledPlugins // {}) | to_entries[]) as $e (.;
            .[$e.key] = ((.[$e.key] // false) or $e.value)))
        | to_entries | sort_by(.key) | from_entries
      ' "${files[@]}" 2>/dev/null)" \
     && printf '%s' "$union" | jq empty 2>/dev/null \
     && cma_jq_edit "$tmpl" --argjson u "$union" '.enabledPlugins = $u'; then
    rm -f "$tmp"
  else
    rm -f "$tmp"
    cma_warn "settings.json: enabledPlugins union NOT applied (jq error above; the shared template is unchanged)"
  fi
  return 0
}

# Give every account dir its OWN real settings.json (§11.4 own-settings): seed
# from the shared TEMPLATE when absent/legacy-symlink, else additively merge the
# template's enabledPlugins in (own keys always win). Per-alias non-plugin keys
# stay local — they never leak to shared or to a sibling dir. Delegates to the
# single canonical seeder in lib.sh so unify/add-account/providers/bootstrap all
# agree.
seed_own_settings() {
  local acct
  for acct in "${ACCOUNTS[@]}"; do
    [[ -d "$acct" ]] || continue
    cma_own_settings_seed "$acct"
  done
}

merge_file_into_shared() {
  local item="$1" acct newest=""
  for acct in "${ACCOUNTS[@]}"; do
    local f="$acct/$item"
    if [[ -L "$f" ]]; then continue; fi
    if [[ ! -f "$f" ]]; then continue; fi
    if [[ -z "$newest" || "$f" -nt "$newest" ]]; then newest="$f"; fi
  done
  if [[ -n "$newest" ]]; then cp -p "$newest" "$SHARED_DIR/$item"; fi
  return 0
}

absorb_default_plugins() {
  [[ -d "$DEFAULT_DIR/plugins" && ! -L "$DEFAULT_DIR/plugins" ]] || return 0
  mkdir -p "$SHARED_DIR/plugins"
  local rc=0
  rsync -a --ignore-existing "$DEFAULT_DIR/plugins/" "$SHARED_DIR/plugins/" || rc=$?
  (( rc == 0 || rc == 23 || rc == 24 )) || return $rc
  return 0
}

rewrite_plugin_paths() {
  local f="$SHARED_DIR/plugins/installed_plugins.json"
  if [[ -f "$f" ]]; then
    local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
    jq --arg shared "$SHARED_DIR" '
      .plugins |= with_entries(
        .value |= map(
          if ((.installPath // "") | test(".*/plugins/cache/"))
          then .installPath = ($shared + "/plugins/cache/" + (.installPath | sub(".*/plugins/cache/"; "")))
          else . end
        )
      )' "$f" > "$tmp" && mv "$tmp" "$f"
  fi
  local km="$SHARED_DIR/plugins/known_marketplaces.json"
  if [[ -f "$km" ]]; then
    local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
    jq --arg shared "$SHARED_DIR" '
      with_entries(
        if ((.value.installLocation // "") | test(".*/plugins/marketplaces/"))
        then .value.installLocation = ($shared + "/plugins/marketplaces/" + (.value.installLocation | sub(".*/plugins/marketplaces/"; "")))
        else . end
      )' "$km" > "$tmp" && mv "$tmp" "$km"
  fi
}

# Repoint ~/.claude/plugins/cache and ~/.claude/plugins/marketplaces at
# the shared store so future user-scope installs land in one place.
link_default_plugin_subdirs() {
  for sub in cache marketplaces; do
    local src="$SHARED_DIR/plugins/$sub" tgt="$DEFAULT_DIR/plugins/$sub"
    [[ -d "$src" ]] || continue
    already_linked_to_shared "$tgt" "$src" && continue
    mkdir -p "$DEFAULT_DIR/plugins"
    backup_and_remove "$tgt"
    ln -s "$src" "$tgt"
  done
}

# CLAUDE.md (user-scope memory) lives at ~/.claude/CLAUDE.md by default.
# We promote it to the shared store and symlink all three locations (each
# account dir + ~/.claude) so any account writing user memory updates the
# same file.
sync_claude_md() {
  local shared_md="$SHARED_DIR/CLAUDE.md" src
  if [[ ! -f "$shared_md" ]]; then
    if [[ -f "$DEFAULT_DIR/CLAUDE.md" && ! -L "$DEFAULT_DIR/CLAUDE.md" ]]; then
      cp -p "$DEFAULT_DIR/CLAUDE.md" "$shared_md"
    else
      for acct in "${ACCOUNTS[@]}"; do
        if [[ -f "$acct/CLAUDE.md" && ! -L "$acct/CLAUDE.md" ]]; then
          cp -p "$acct/CLAUDE.md" "$shared_md"; break
        fi
      done
    fi
    [[ -f "$shared_md" ]] || return 0
  fi
  local targets=("$DEFAULT_DIR/CLAUDE.md")
  for acct in "${ACCOUNTS[@]}"; do targets+=("$acct/CLAUDE.md"); done
  for tgt in "${targets[@]}"; do
    [[ -d "$(dirname "$tgt")" ]] || continue
    already_linked_to_shared "$tgt" "$shared_md" && continue
    backup_and_remove "$tgt"
    ln -s "$shared_md" "$tgt"
  done
}

rollback() {
  cma_log "rollback: restoring .preunify.* backups"
  local root
  local roots=("$DEFAULT_DIR" "$DEFAULT_DIR/plugins" "$SHARED_DIR")
  for root in "${ACCOUNTS[@]}"; do roots+=("$root"); done
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    # Restore backups oldest-first. The suffix is a YYYYMMDDHHMMSS timestamp, so
    # `sort -z` orders lexically = chronologically; the earliest backup is the
    # true pre-unify original and wins when a path has more than one .preunify.*.
    while IFS= read -r -d '' bk; do
      local orig="${bk%.preunify.*}"
      [[ -L "$orig" ]] && rm -f "$orig"
      [[ -e "$orig" ]] || { mv "$bk" "$orig"; cma_log "restored $orig"; }
    done < <(find "$root" -maxdepth 1 -name '*.preunify.*' -print0 2>/dev/null | sort -z)
    # Don't scan the shared store itself (its contents move aside intact below);
    # only external roots can hold links that would dangle.
    [[ "$root" == "$SHARED_DIR" ]] && continue
    # Remove leftover symlinks pointing into the shared store. unify created
    # these for items an account never had (so there's no backup to restore);
    # without this they dangle once SHARED_DIR is moved aside.
    while IFS= read -r -d '' lnk; do
      local tgt; tgt="$(readlink "$lnk")"
      case "$tgt" in
        "$SHARED_DIR"|"$SHARED_DIR"/*) rm -f "$lnk"; cma_log "removed shared-store symlink $lnk" ;;
      esac
    done < <(find "$root" -maxdepth 1 -type l -print0 2>/dev/null)
  done
  if [[ -d "$SHARED_DIR" ]]; then
    mv "$SHARED_DIR" "${SHARED_DIR}.removed.$(ts)"
    cma_log "moved $SHARED_DIR aside"
  fi
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [--rollback] [account-dir ...]

Without args, auto-detects all ~/${ACCOUNT_PREFIX}* directories.
With --rollback, restores .preunify.* backups and removes the shared store.

Env: SHARED_DIR=$SHARED_DIR DEFAULT_DIR=$DEFAULT_DIR
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
  mapfile -t ACCOUNTS < <(cma_detect_accounts)
fi

(( ${#ACCOUNTS[@]} >= 1 )) || cma_die "no account dirs given and none auto-detected at ~/${ACCOUNT_PREFIX}*"

cma_log "accounts: ${ACCOUNTS[*]}"
cma_log "shared:   $SHARED_DIR"

if (( DO_ROLLBACK )); then rollback; exit 0; fi

mkdir -p "$SHARED_DIR"
absorb_default_plugins

for item in "${SHARED_ITEMS[@]}"; do
  case "$item" in
    history.jsonl)    merge_history_jsonl ;;
    stats-cache.json) merge_file_into_shared "$item" ;;
    daemon)           merge_dir_into_shared "$item" "roster.json" && merge_daemon_roster ;;
    *)                merge_dir_into_shared "$item" ;;
  esac
  [[ "$item" == "plugins" ]] && rewrite_plugin_paths
  link_to_shared "$item"
  cma_log "ok: $item"
done

# §11.4 own-settings: settings.json is NOT a shared symlink. Union each account's
# enabledPlugins into the shared template, then re-seed every dir's OWN copy so
# the union propagates while per-alias non-plugin keys stay local.
union_enabled_plugins_into_template
seed_own_settings
cma_log "ok: settings.json (per-dir OWN copy; enabledPlugins union propagated; per-alias keys kept local)"

link_default_plugin_subdirs
sync_claude_md

# Merge the projects/session index inside .claude.json across every account.
# This is the single most important step for cross-account session resume:
# without it, account A's session UUIDs are invisible to account B even though
# the JSONL transcripts are already shared on disk via projects/.
cma_merge_claude_json "${ACCOUNTS[@]}"
cma_log "ok: .claude.json (projects/session index merged; auth keys preserved per-account)"

# Ensure every detected account has an invocable alias. install.sh and direct
# unify runs may discover pre-existing ~/.claude-* dirs that were never
# registered (e.g. the user ran install.sh after creating the dirs). Without
# this step `claude1` etc. are undefined even though the dirs exist.
cma_ensure_alias_file
declare -A ALIAS_OF_DIR=()
if [[ -f "$ALIAS_FILE" ]]; then
  while IFS= read -r line; do
    [[ "$line" =~ ^alias[[:space:]]+([a-zA-Z0-9_-]+)=.*CLAUDE_CONFIG_DIR=([^[:space:]]+) ]] || continue
    ALIAS_OF_DIR["${BASH_REMATCH[2]}"]="${BASH_REMATCH[1]}"
  done < "$ALIAS_FILE"
fi
# First pass: dirs whose suffix (after ~/.claude-) is already "claude<N>"
# (e.g. ~/.claude-claude4) keep that number, so user expectations about named
# dirs are preserved.
for acct in "${ACCOUNTS[@]}"; do
  if [[ -z "${ALIAS_OF_DIR[$acct]:-}" ]]; then
    base="$(basename "$acct")"
    suffix="${base#${ACCOUNT_PREFIX}}"
    if [[ "$suffix" =~ ^claude([0-9]+)$ ]]; then
      wanted="claude${BASH_REMATCH[1]}"
      if ! cma_existing_aliases | grep -qx "$wanted"; then
        cma_write_alias "$wanted" "$acct"
        cma_log "registered alias: $wanted -> $acct"
        continue
      fi
    fi
  fi
done
# Lowest free claude<N> (fills gaps left by explicit claudeM basenames).
_cma_lowest_free_clauden() {
  local n=1
  while cma_existing_aliases | grep -qx "claude$n"; do
    n=$((n + 1))
    (( n < 1000 )) || { cma_warn "could not find a free claude<N> alias"; return 1; }
  done
  printf 'claude%s\n' "$n"
}

# Second pass: anything still unaliased gets the lowest free claude<N>.
for acct in "${ACCOUNTS[@]}"; do
  if [[ -z "${ALIAS_OF_DIR[$acct]:-}" ]]; then
    if grep -qE "alias[[:space:]]+[^=]+=.*CLAUDE_CONFIG_DIR=$acct([[:space:]]|$)" "$ALIAS_FILE"; then
      # A newly-written pass-1 alias now points at this dir; update our map.
      ALIAS_OF_DIR[$acct]="$(grep -E "alias[[:space:]]+[^=]+=.*CLAUDE_CONFIG_DIR=$acct([[:space:]]|$)" "$ALIAS_FILE" | head -1 | sed -E 's/^alias[[:space:]]+([^=]+)=.*/\1/')"
      continue
    fi
    next_alias="$(_cma_lowest_free_clauden)"
    cma_write_alias "$next_alias" "$acct"
    cma_log "registered alias: $next_alias -> $acct"
  fi
done

cma_log "done. shared: $SHARED_DIR"
cma_log "private per-account: ${PRIVATE_ITEMS[*]}"
