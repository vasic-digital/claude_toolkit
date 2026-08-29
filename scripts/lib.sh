#!/usr/bin/env bash
# lib.sh — shared functions for the Claude multi-account toolkit.
# Sourced by the other scripts; no side effects on its own.

set -euo pipefail

# Which rc files to source the alias file from. macOS interactive shell is
# zsh; touching .bashrc there just creates noise the user has to clean up.
# On Linux we keep both because either may be the login shell.
if [[ "$(uname -s)" == "Darwin" ]]; then
  CMA_RC_FILES=("$HOME/.zshrc")
else
  CMA_RC_FILES=("$HOME/.bashrc" "$HOME/.zshrc")
fi

# Resolve paths the user can override. SHARED_DIR is the single canonical
# location for cross-account state; ALIAS_FILE is the rc-sourced file we
# manage aliases through; ACCOUNT_PREFIX is the dir-name prefix for new
# per-account config directories.
: "${SHARED_DIR:=$HOME/.claude-shared}"
: "${ALIAS_FILE:=$HOME/.local/share/claude-multi-account/aliases.sh}"
: "${ACCOUNT_PREFIX:=.claude-}"

# Resolve the Claude Code binary for the alias wrappers. Prefer an explicit
# CLAUDE_BIN, then $PATH, then the common install locations. npm's global prefix
# varies per host (e.g. ~/.npm-global vs ~/.local vs Homebrew), so a fixed
# ~/.local/bin default mis-points on hosts where `npm i -g @anthropic-ai/...`
# landed elsewhere — making EVERY alias launch fail "No such file". Checking
# the real locations keeps a fresh install working without a manual symlink.
cma_resolve_claude_bin() {
  if [ -n "${CLAUDE_BIN:-}" ]; then printf '%s\n' "$CLAUDE_BIN"; return 0; fi
  local c; if c="$(command -v claude 2>/dev/null)"; then printf '%s\n' "$c"; return 0; fi
  local p
  for p in "$HOME/.local/bin/claude" "$HOME/.npm-global/bin/claude" \
           /opt/homebrew/bin/claude /usr/local/bin/claude; do
    [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
  done
  printf '%s\n' "$HOME/.local/bin/claude"   # fallback (created by install/symlink)
}
# Resolved once at source time for callers that want the default without paying
# for a re-probe. The alias renderer does NOT use it — it prefers the value
# already recorded in the alias file when that still resolves (see
# _cma_alias_claude_bin), so a working per-host path is never clobbered.
# shellcheck disable=SC2034  # part of lib.sh's public surface for sourcing scripts
CLAUDE_BIN_DEFAULT="$(cma_resolve_claude_bin)"

cma_log()  { printf '\033[36m[cma]\033[0m %s\n' "$*" >&2; }
cma_warn() { printf '\033[33m[cma warn]\033[0m %s\n' "$*" >&2; }
cma_err()  { printf '\033[31m[cma err]\033[0m %s\n' "$*" >&2; }
cma_die()  { cma_err "$*"; exit 1; }

cma_require() {
  command -v "$1" >/dev/null 2>&1 || cma_die "missing required tool: $1"
}

# Keys inside .claude.json that must NEVER leak across accounts (auth + identity).
# Everything else in .claude.json — projects map, UX state, caches, etc. — is
# safely shareable. New auth keys should be added here, not assumed shareable.
CMA_CLAUDE_JSON_PRIVATE_KEYS='["userID","oauthAccount","firstStartTime","claudeCodeFirstTokenDate"]'

# Deep-merge every account's .claude.json so each account's file ends up with
# its OWN auth keys + the UNION of all other top-level keys (rightmost-wins
# for scalar conflicts, recursive object merge for `projects` and friends).
#
# Args: one or more account config dirs.
# Side effect: rewrites each $acct/.claude.json in place. Skips an account
# that doesn't yet have a .claude.json (e.g. brand-new dir before first login).
cma_merge_claude_json() {
  local accts=("$@")
  (( ${#accts[@]} >= 1 )) || return 0
  cma_require jq

  # Build the merged "shared portion" (everything except private keys).
  local shared_tmp; shared_tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
  printf '{}\n' > "$shared_tmp"
  local acct prev="$shared_tmp"
  for acct in "${accts[@]}"; do
    local f="$acct/.claude.json"
    [[ -s "$f" ]] || continue
    local next; next="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
    # $a (accumulator) * ($b stripped of private keys). jq's `*` is recursive
    # deep-merge for objects; rightmost wins on scalar conflicts AND on array
    # values (arrays are replaced, not element-unioned — e.g. a per-project
    # prompt-history array takes the last account's copy). This is a deliberate
    # deep-merge trade-off: the projects subtree is unioned at the object-key
    # level (which is what the cross-account session/MCP/memory index needs);
    # blind element-level array union would be wrong for config-style arrays.
    if ! jq -s --argjson priv "$CMA_CLAUDE_JSON_PRIVATE_KEYS" '
      . as [$a, $b]
      | ($b | with_entries(select(.key as $k | $priv | index($k) | not))) as $shared_b
      | ($a // {}) * ($shared_b // {})
    ' "$prev" "$f" > "$next"; then
      rm -f "$next"
      cma_warn ".claude.json in $acct is not valid JSON — skipping its contribution"
      continue
    fi
    rm -f "$prev"
    prev="$next"
  done

  # Sticky-true TRUST preservation (§11.4 anti-bluff config hygiene): the jq `*`
  # merge above is last-writer-wins on scalars, so a per-project
  # `projects[<path>].hasTrustDialogAccepted` bit trusted under one alias could be
  # DEMOTED true->false by a later account that lacks it — which made Claude Code's
  # per-workspace trust dialog ("read, edit, and execute files here") reappear on
  # every provider alias. Fix: OR the trust bit across all accounts — once a
  # project path is trusted anywhere, it stays trusted in the merged portion.
  local _tr_files=() _tr_acct
  for _tr_acct in "${accts[@]}"; do [[ -s "$_tr_acct/.claude.json" ]] && _tr_files+=("$_tr_acct/.claude.json"); done
  if (( ${#_tr_files[@]} >= 1 )); then
    local _trusted
    _trusted="$(jq -s '[ .[] | (.projects // {}) | to_entries[]
                        | select(.value.hasTrustDialogAccepted == true) | .key ] | unique' \
                "${_tr_files[@]}" 2>/dev/null || printf '[]')"
    if [[ -n "$_trusted" && "$_trusted" != "[]" ]]; then
      local _tt; _tt="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
      if jq --argjson trusted "$_trusted" '
            .projects //= {}
            | reduce ($trusted[]) as $p (.; .projects[$p].hasTrustDialogAccepted = true)
          ' "$prev" > "$_tt" 2>/dev/null && jq -e . "$_tt" >/dev/null 2>&1; then
        command mv -f "$_tt" "$prev"
      else rm -f "$_tt"; fi
    fi
  fi

  # Now $prev holds the merged shared portion. Write each account's file with
  # its own private keys overlaid on top of the shared portion.
  for acct in "${accts[@]}"; do
    local f="$acct/.claude.json" out
    out="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
    if [[ -s "$f" ]]; then
      # Guard against set -e: a corrupt $f makes jq fail, which would abort
      # the whole loop and leave the remaining accounts unsynced.
      if ! jq -s --argjson priv "$CMA_CLAUDE_JSON_PRIVATE_KEYS" '
        . as [$shared, $own]
        | ($own | with_entries(select(.key as $k | $priv | index($k)))) as $priv_only
        | ($shared // {}) * $priv_only
      ' "$prev" "$f" > "$out" 2>/dev/null; then
        rm -f "$out"
        cma_warn ".claude.json for $acct could not be merged (invalid JSON?) — leaving original alone"
        continue
      fi
    else
      # New account, no existing .claude.json. Seed with shared content only.
      cp "$prev" "$out"
    fi
    # Final sanity: only replace if the output is parseable JSON.
    if jq -e . "$out" >/dev/null 2>&1; then
      command mv -f "$out" "$f"
    else
      rm -f "$out"
      cma_warn "merged .claude.json for $acct was invalid — leaving original file untouched"
    fi
  done
  rm -f "$prev"
}

# Detect Linux vs macOS for platform-specific commands.
cma_os() {
  case "$(uname -s)" in
    Linux*)   echo linux ;;
    Darwin*)  echo macos ;;
    *)        echo unknown ;;
  esac
}

# Portable realpath. BSD/macOS `readlink` has no `-f`, so `readlink -f` is a hard
# error there (prints "illegal option -- f", returns empty) even after a bash-4
# re-exec, because /usr/bin/readlink stays BSD. This resolves a path to its
# canonical absolute form by walking the symlink chain with single-arg
# `readlink` (supported everywhere) plus `pwd -P` — the same technique every
# script's LIB_DIR resolver uses. Safe under `set -e`.
cma_realpath() {
  local p="$1" t dir base
  while [ -L "$p" ]; do
    t="$(readlink "$p")"
    case "$t" in /*) p="$t" ;; *) p="$(dirname "$p")/$t" ;; esac
  done
  dir="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || dir="$(dirname "$p")"
  base="$(basename "$p")"
  printf '%s/%s\n' "$dir" "$base"
}

# cma_probe_run SECONDS BIN [ARG...] — BOUNDED run of a binary with any probe
# grammar; prints the first 20 lines of its combined output, never hangs, and
# never stalls its caller.
#
# Why not `timeout 15 "$bin" ... | head -20` (the previous shape):
#   1. `timeout` is absent on macOS without coreutils, and the fallback that
#      shipped there ran the binary UNBOUNDED — a wedged router hung the
#      installer forever (review finding I1, 2026-07-22).
#   2. Even where `timeout` exists, a probed binary that spawns a child which
#      inherits stdout keeps the PIPE open after the parent is killed, so the
#      `head` reader can still wait forever on EOF. The PROBE's output goes to
#      a temp FILE instead: a file read cannot block on a straggler's open
#      descriptor. That protects against stragglers of the PROBE — the
#      watchdog arm needs its own discipline, next point.
#   3. The WATCHDOG below is backgrounded, so it inherits the CALLER's stdio —
#      and when the caller captures this function through a command
#      substitution, that stdout IS the $( ) pipe. After a fast probe the
#      disarm kill orphaned the watchdog's `sleep SECONDS` child, which kept
#      the pipe write-end open, so the caller blocked for the FULL budget
#      even though the verdict was already correct (+15s on every healthy
#      install/verify — review finding I3, 2026-07-23, measured). The
#      watchdog's stdio is therefore detached to /dev/null: a background
#      helper must never hold a descriptor its caller waits on. The guard for
#      this class is behavioural — test_install_clean_host_ccr.sh case I
#      times a fast probe through a command substitution.
# One implementation for every host and every probe grammar — a single
# instrument to validate, instead of a proven branch plus an unproven fallback
# (§11.4.201: the path is part of the instrument).
#
# Returns the probe's own exit code, or 124 when the watchdog had to kill it
# (deliberately the same convention coreutils `timeout` uses, so callers can
# classify "wedged" with one check). Safe under `set -e` callers.
cma_probe_run() {
  local _budget="$1" _bin="$2"
  shift 2
  local _tmp _rc _pid _wpid
  _tmp="$(mktemp "${TMPDIR:-/tmp}/cma-probe.XXXXXX")" || return 1
  "$_bin" "$@" </dev/null >"$_tmp" 2>&1 &
  _pid=$!
  # Watchdog: TERM at the budget, KILL 2s later for a TERM-ignoring probe. It
  # drops a marker file BEFORE killing so "watchdog fired" is a recorded fact,
  # not inferred from an exit status the probe could also produce on its own.
  # stdio detached — header point 3 (I3): its orphaned sleep must not hold
  # the caller's command-substitution pipe.
  ( sleep "$_budget"; : >"${_tmp}.killed"; kill -TERM "$_pid" 2>/dev/null
    sleep 2; kill -KILL "$_pid" 2>/dev/null ) >/dev/null 2>&1 &
  _wpid=$!
  _rc=0; wait "$_pid" 2>/dev/null || _rc=$?
  kill "$_wpid" 2>/dev/null || true      # probe finished: disarm the watchdog
  wait "$_wpid" 2>/dev/null || true
  [ -e "${_tmp}.killed" ] && _rc=124
  head -20 "$_tmp"
  rm -f "$_tmp" "${_tmp}.killed"
  return "$_rc"
}

# cma_probe_help BIN [SECONDS] — BOUNDED `--help` probe: cma_probe_run with
# the one grammar every binary is expected to answer. Kept as the named entry
# point because "--help, default budget 15" is the contract the install-seam
# callers (claude-install-verify.sh, claude-ccr-build.sh) share.
cma_probe_help() {
  cma_probe_run "${2:-15}" "$1" --help
}

# cma_proxy_transform_family ID — does provider ID belong to a family cma-proxy
# transforms? Exit 0 when yes. Used by cma_run_provider to decide whether a
# MISSING cma-proxy is worth a warning: a provider with no shim loses nothing,
# so warning there would be a false positive (§11.4.201(1)).
#
# Normally the proxy binary itself answers (`cma-proxy --has-transform ID`),
# but with no binary present we cannot ask it — this list mirrors the
# registrations in scripts/proxy/*.go (registerRequest/registerResponse).
# KEEP IN SYNC with that registry: test_cma_proxy.sh asserts, in BOTH
# directions, that these families EQUAL the registered set, so a new transform
# provider added to the proxy without a family here fails the suite instead of
# silently missing its warning. Prefix-matched because ids carry variant
# suffixes (poe2 -> poe, kimi-k2 -> kimi) — the same folds providerKey() does.
cma_proxy_transform_family() {
  case "$1" in
    helixagent*|poe*|kimi*|sarvam*|nvidia*) return 0 ;;
    *) return 1 ;;
  esac
}

# Find all existing Claude account config directories under $HOME, matching
# the convention `.claude-<name>`. Echoes absolute paths, one per line,
# sorted. The default `~/.claude` is intentionally excluded because we treat
# it as the shared user-scope spot, not an account dir.
cma_detect_accounts() {
  local d
  while IFS= read -r d; do
    [[ "$d" == *"-shared" ]] && continue
    # Provider-alias dirs (~/.claude-prov-<id>, created by claude-providers)
    # are account-like for SHARED state but must NEVER be merged into
    # real-account auth/identity or unify, so they're excluded from detection
    # exactly like *-shared. This is the linchpin that keeps the existing
    # claudeN accounts and add-account untouched by the provider feature.
    [[ "$(basename "$d")" == "${ACCOUNT_PREFIX}prov-"* ]] && continue
    # The claude-code-router config dir and any *.lock dir are not accounts.
    [[ "$(basename "$d")" == "${ACCOUNT_PREFIX}code-router" ]] && continue
    [[ "$(basename "$d")" == *.lock ]] && continue
    # Archived removals (claude-remove-account's DEFAULT mode renames the dir to
    # `<dir>.removed.<timestamp>`) are NOT accounts. They keep their `projects/`
    # marker, so without this they kept counting forever — and the alias-commit
    # floor at _cma_alias_gate arms only while `src_acct >= n_acct`, so one
    # ordinary removal (2 aliases vs 3 "detected") silently disarmed that floor
    # PERMANENTLY on that host. It failed open rather than wrong, but a guard
    # that quietly stops guarding is not a guard.
    [[ "$(basename "$d")" == *.removed.* ]] && continue
    # Same reasoning for the pre-unify backups `backup_and_remove` leaves behind.
    [[ "$(basename "$d")" == *.preunify.* ]] && continue
    # Empty dirs always count (a brand-new account before any claude run).
    if [[ -z "$(ls -A "$d" 2>/dev/null)" ]]; then
      echo "$d"
      continue
    fi
    # Non-empty: must look like a Claude account (at least one tell-tale
    # file/dir). Filters out dirs that merely match the `.claude-*` prefix
    # but belong to other tools (e.g. `.claude-server-commander`).
    if [[ -d "$d/projects" || -d "$d/todos" || -d "$d/plugins" \
       || -f "$d/.claude.json" || -f "$d/.credentials.json" \
       || -f "$d/history.jsonl" ]]; then
      echo "$d"
    fi
  done < <(find "$HOME" -maxdepth 1 -type d -name "${ACCOUNT_PREFIX}*" 2>/dev/null | sort)
}

# Read all aliases of the form `alias name=...` from $ALIAS_FILE and print
# their names (one per line). Returns nothing if the file is absent.
cma_existing_aliases() {
  [[ -f "$ALIAS_FILE" ]] || return 0
  awk -F'[ =]+' '/^[[:space:]]*alias[[:space:]]+/{print $2}' "$ALIAS_FILE"
}

# Suggest the next free `claude<N>` alias by scanning current aliases.
# E.g., if claude1 and claude2 exist, returns "claude3".
cma_suggest_alias() {
  local highest=0 n
  for a in $(cma_existing_aliases); do
    if [[ "$a" =~ ^claude([0-9]+)$ ]]; then
      n="${BASH_REMATCH[1]}"
      (( n > highest )) && highest="$n"
    fi
  done
  echo "claude$((highest + 1))"
}

# Validate that an alias name is safe to embed in a generated `alias ...=`
# line — strictly alphanumeric + underscore/hyphen, starting with a letter.
cma_validate_alias() {
  [[ "$1" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]] || cma_die "invalid alias name: $1"
}

# Match an rc-file line that sources an aliases.sh, capturing the path:
#   BASH_REMATCH[2] = the (possibly $HOME/~/quoted) target path.
# Anchored so leading-# comment lines (e.g. "# migrated to …/aliases.sh: …")
# never match. Used by the prune + dedup helpers below.
CMA_ALIAS_SRC_RE='^[[:space:]]*(source|\.)[[:space:]]+"?([^"[:space:]]*aliases\.sh)"?[[:space:]]*$'

# The one managed header that heads the `source "<alias-file>"` block in every
# rc file. Spelled once here so the writer (append) and the reader (prune) agree
# on exactly what a "managed block" is — the bug that lost the operator's
# ~/.bashrc was the two disagreeing: the append wrote this header, the prune did
# not know to remove it, so every dropped source line left the header ORPHANED.
CMA_ALIAS_RC_HEADER='# Claude multi-account aliases'

# True if $1 is an `aliases.sh` source line (source|. form). Sets BASH_REMATCH.
_cma_is_alias_src_line() { [[ "$1" =~ $CMA_ALIAS_SRC_RE ]]; }
# Echo the resolved target path an alias-source line ($1) points at, or nothing.
_cma_alias_src_target() {
  [[ "$1" =~ $CMA_ALIAS_SRC_RE ]] || return 1
  local t="${BASH_REMATCH[2]}"; t="${t/#\$HOME/$HOME}"; t="${t/#\~/$HOME}"
  printf '%s' "$t"
}

# Portable mtime (epoch seconds). GNU `stat -c %Y`; BSD/macOS `stat -f %m`
# (which has no `-c`). Deliberately NOT `date -r <path>`: on BSD `date -r` reads
# its argument as epoch seconds rather than a file, silently returning 0 for
# every path — the macOS breakage that made this a §11.4.68 / §11.4.81 finding.
_cma_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# Newest existing rolling backup for $rc, by mtime (empty if none).
cma_newest_rc_backup() {
  local rc="$1" f newest="" ntime=-1 t
  for f in "$rc".cma-backup.*; do
    [[ -e "$f" ]] || continue
    t="$(_cma_mtime "$f")"
    if (( t >= ntime )); then ntime="$t"; newest="$f"; fi
  done
  printf '%s' "$newest"
}

# cma_backup_rc_file <rc>
# Protect a user rc file BEFORE the toolkit modifies it. Two backups:
#   * <rc>.cma-orig — the PRISTINE original, written exactly ONCE and NEVER
#     overwritten. This is the load-bearing recovery point: once a corrupted
#     state exists on disk it can never bury the true original.
#   * <rc>.cma-backup.<epoch> — a rolling snapshot of recent state, RATE-LIMITED:
#     skipped when byte-identical to the newest existing rolling backup. Without
#     this, BASH_ENV=~/.bashrc firing the prune->ensure cycle on every
#     non-interactive bash would spray hundreds of identical copies.
# Returns 0 when the rc is protected (or does not exist yet, so a fresh create
# loses nothing). Returns 1 when the PRISTINE backup could not be taken — the
# caller MUST then refuse to modify rather than proceed unprotected.
cma_backup_rc_file() {
  local rc="$1" orig="$1.cma-orig" newest ts cand i=0
  [[ -f "$rc" ]] || return 0                 # nothing on disk => nothing to lose

  # 1. Pristine original: create once, never overwrite. A failure here is fatal
  #    to the modification — an unwritable dir can still allow an append (which
  #    needs only file-write), so refusing here is what actually prevents an
  #    unprotected write.
  if [[ ! -e "$orig" ]]; then
    if ! cp -p -- "$rc" "$orig" 2>/dev/null; then
      cma_warn "cannot write pristine backup $orig — refusing to modify $rc"
      return 1
    fi
  fi

  # 2. Rolling snapshot, rate-limited. Best-effort: the pristine copy above is
  #    the guarantee; a rolling-backup failure does not block the modification
  #    (the recovery point already exists).
  newest="$(cma_newest_rc_backup "$rc")"
  if [[ -n "$newest" ]] && cmp -s -- "$rc" "$newest"; then
    return 0
  fi
  ts="$(date +%s)"
  cand="$rc.cma-backup.$ts"
  while [[ -e "$cand" ]]; do i=$((i+1)); cand="$rc.cma-backup.$ts.$i"; done
  cp -p -- "$rc" "$cand" 2>/dev/null || true
  return 0
}

# _cma_rc_rewrite_ok <rc> <candidate> <intended_removed_lines>
# Sanity gate for any rc rewrite, mirroring cma_alias_commit's alias-file gate.
# Refuse to publish a candidate that: is empty while it was meant to keep lines;
# fails a shell syntax parse (bash -n for a .bashrc, zsh -n for a .zshrc when zsh
# is present); or lost more lines than the operation intended to remove.
_cma_rc_rewrite_ok() {
  local rc="$1" cand="$2" removed="$3" src_lines cand_lines expected
  src_lines="$(grep -c '' "$rc"   2>/dev/null || echo 0)"
  cand_lines="$(grep -c '' "$cand" 2>/dev/null || echo 0)"
  expected=$(( src_lines - removed ))
  (( expected < 0 )) && expected=0

  # 1. Empty candidate that was supposed to preserve content = truncation.
  if [[ ! -s "$cand" ]] && (( expected > 0 )); then
    cma_warn "rc rewrite rejected: empty candidate for $rc would drop $expected intended line(s)"
    return 1
  fi
  # 2. Must still parse in the target shell.
  case "$rc" in
    *.zshrc)
      if command -v zsh >/dev/null 2>&1; then
        zsh -n "$cand" 2>/dev/null || { cma_warn "rc rewrite rejected: zsh -n failed on candidate for $rc"; return 1; }
      fi ;;
    *)
      bash -n "$cand" 2>/dev/null || { cma_warn "rc rewrite rejected: bash -n failed on candidate for $rc"; return 1; } ;;
  esac
  # 3. Must not have lost lines the operation did not intend to remove.
  if (( cand_lines < expected )); then
    cma_warn "rc rewrite rejected: candidate for $rc lost $(( expected - cand_lines )) unintended line(s)"
    return 1
  fi
  return 0
}

# ── Managed rc-block sentinels + the single rc-rewrite committer ──────────────
# A managed rc block is delimited by a BEGIN/END sentinel PAIR (unlike the legacy
# single `CMA_ALIAS_RC_HEADER` comment, which had NO END marker — that is exactly
# what ORPHANED when its source line was pruned, piling up ~93 headers). One
# stable marker id per block ("path", …); begin/end are derived from the marker
# through one builder so the writer and the reader can never disagree.
_cma_rc_begin() { printf '# cma-rc:%s BEGIN — managed by claude-multi-account; do not edit inside' "$1"; }
_cma_rc_end()   { printf '# cma-rc:%s END' "$1"; }
# Named sentinels for the markers in use (tests + code share one source of truth).
# shellcheck disable=SC2034  # public surface: consumed by test_rc_safety.sh, which sources lib.sh
CMA_RC_PATH_BEGIN="$(_cma_rc_begin path)"
# shellcheck disable=SC2034  # public surface: consumed by test_rc_safety.sh, which sources lib.sh
CMA_RC_PATH_END="$(_cma_rc_end path)"

# cma_rc_safe_rewrite <rc> <candidate_tmp> <intended_removed_lines>
# THE single committer for any WHOLE-FILE rc rewrite — the rc analogue of
# cma_alias_commit. Every path that would `mv` a rebuilt file over a live rc
# funnels through here. Order is load-bearing and mirrors the proven prune path:
#   1. no-op guard      — a byte-identical candidate ⇒ discard, touch nothing;
#   2. sanity gate       — _cma_rc_rewrite_ok (empty/parse/content-loss). A reject
#                          is PARKED as <rc>.rejected.<ts>; the live rc is untouched;
#   3. backup-or-refuse  — cma_backup_rc_file; no pristine backup ⇒ DO NOT modify
#                          (§11.4.167(D));
#   4. publish           — one command mv, INT/TERM masked across the rename.
# Consumes <candidate_tmp> (moved or removed) on every return path.
# Returns 0 published (or no-op), 1 rejected/refused.
cma_rc_safe_rewrite() {
  local rc="$1" cand="$2" removed="${3:-0}" prev_int prev_term rc2=0
  [[ -f "$cand" ]] || return 1

  # 1. No-op guard (before any backup): a settled host writes nothing.
  if [[ -f "$rc" ]] && cmp -s -- "$cand" "$rc"; then rm -f "$cand"; return 0; fi

  # 2. Sanity gate — refuse a content-losing / unparseable candidate; park it.
  if ! _cma_rc_rewrite_ok "$rc" "$cand" "$removed"; then
    command mv -f "$cand" "$rc.rejected.$(date +%s)" 2>/dev/null || rm -f "$cand"
    cma_warn "$rc left untouched; rewrite candidate kept as $rc.rejected.*"
    return 1
  fi

  # 3. Backup-or-refuse — no pristine backup ⇒ no modify.
  if ! cma_backup_rc_file "$rc"; then rm -f "$cand"; return 1; fi

  # 4. Publish — one rename, INT/TERM masked (mirrors cma_alias_commit F4).
  prev_int="$(trap -p INT || true)"
  prev_term="$(trap -p TERM || true)"
  trap '' INT TERM
  if command mv -f "$cand" "$rc"; then rc2=0; else rm -f "$cand"; rc2=1; fi
  trap - INT TERM
  if [[ -n "$prev_int" ]]; then eval "$prev_int"; fi
  if [[ -n "$prev_term" ]]; then eval "$prev_term"; fi
  return "$rc2"
}

# cma_rc_append_managed <rc> <marker> <payload-line...>
# Append a BEGIN/END-delimited managed block to <rc>, backup-first and idempotent:
#   * no-op if a live block for <marker> is already present;
#   * refuses to modify if the pristine backup cannot be taken (§11.4.167(D));
#   * an absent rc is first-touched (cma_backup_rc_file returns 0 for absent, and
#     there is nothing to lose).
cma_rc_append_managed() {
  local rc="$1" marker="$2"; shift 2
  local begin end
  begin="$(_cma_rc_begin "$marker")"
  end="$(_cma_rc_end "$marker")"
  if [[ -f "$rc" ]] && grep -qxF -- "$begin" "$rc"; then return 0; fi   # idempotent
  if ! cma_backup_rc_file "$rc"; then
    cma_warn "skipped managed '$marker' block in $rc (could not back it up)"
    return 1
  fi
  { printf '\n%s\n' "$begin"; printf '%s\n' "$@"; printf '%s\n' "$end"; } >> "$rc"
  cma_log "added managed '$marker' block to $rc"
}

# cma_rc_remove_block <rc> <marker>
# Remove the managed <marker> block (BEGIN..END) as a UNIT; no-op if absent. An
# unterminated BEGIN (file truncated inside the block by an outside tool) removes
# from BEGIN to EOF — never leaving a half block / orphan header. The rewrite is
# published through cma_rc_safe_rewrite (gate + backup + mv).
cma_rc_remove_block() {
  local rc="$1" marker="$2" begin end tmp removed
  [[ -f "$rc" ]] || return 0
  begin="$(_cma_rc_begin "$marker")"
  end="$(_cma_rc_end "$marker")"
  grep -qxF -- "$begin" "$rc" || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")" || return 1
  awk -v b="$begin" -v e="$end" '
    $0==b {skip=1; c++; next}
    skip && $0==e {skip=0; c++; next}
    skip {c++; next}
    {print}
    END {print c+0 > "/dev/stderr"}' "$rc" 2>"$tmp.n" >"$tmp" || true
  removed="$(cat "$tmp.n" 2>/dev/null || echo 0)"; rm -f "$tmp.n"
  cma_rc_safe_rewrite "$rc" "$tmp" "${removed:-0}"
}

# Remove rc-file lines that source an aliases.sh whose target no longer exists
# (a stale path from a moved install, or a transient ALIAS_FILE used in testing).
# Without this, a deleted alias file leaves a dangling line that errors
# "-bash: …/aliases.sh: No such file or directory" on every new login shell.
#
# The managed `# Claude multi-account aliases` header and its source line are
# treated as ONE block: a dead block drops both (never orphaning the header), and
# a header that no longer heads a live source line is collapsed away (self-heal
# for the orphans a pre-fix toolkit already accumulated). A bare source line with
# no managed header is still pruned when its target is gone. Every rewrite is
# guarded by the sanity gate + a mandatory backup: a bad candidate is parked as
# <rc>.rejected.<ts> and the live rc is left untouched; if the backup cannot be
# taken the rc is not modified at all.
cma_prune_stale_alias_sources() {
  local rc="$1" tmp removed=0 n i line target
  [[ -f "$rc" ]] || return 0

  local lines=()
  while IFS= read -r line || [[ -n "$line" ]]; do lines+=("$line"); done < "$rc"
  n=${#lines[@]}

  tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")" || return 0
  i=0
  while (( i < n )); do
    line="${lines[$i]}"
    if [[ "$line" == "$CMA_ALIAS_RC_HEADER" ]]; then
      if (( i + 1 < n )) && _cma_is_alias_src_line "${lines[$((i+1))]}"; then
        target="$(_cma_alias_src_target "${lines[$((i+1))]}")"
        if [[ -f "$target" ]]; then
          printf '%s\n' "$line" >> "$tmp"                 # live block: keep header
          printf '%s\n' "${lines[$((i+1))]}" >> "$tmp"    # ...and its source line
        else
          removed=$((removed + 2))                        # dead block: drop both
        fi
        i=$((i + 2)); continue
      fi
      removed=$((removed + 1)); i=$((i + 1)); continue     # orphan header: collapse
    fi
    if _cma_is_alias_src_line "$line"; then
      target="$(_cma_alias_src_target "$line")"
      if [[ ! -f "$target" ]]; then removed=$((removed + 1)); i=$((i + 1)); continue; fi
    fi
    printf '%s\n' "$line" >> "$tmp"
    i=$((i + 1))
  done

  if (( removed == 0 )); then rm -f "$tmp"; return 0; fi

  # Publish through the single rc-rewrite committer (gate → backup-or-refuse →
  # INT/TERM-masked mv, with a .rejected.<ts> park on a bad candidate). The
  # candidate-building block/orphan logic above is unchanged.
  cma_rc_safe_rewrite "$rc" "$tmp" "$removed" \
    && cma_log "pruned stale/orphaned managed alias block(s) from $rc"
}

# True if $rc already sources a file resolving to $2 (across `.`/`source` and
# $HOME/~/absolute forms), so we never append a duplicate source line.
cma_rc_sources_alias_file() {
  local rc="$1" want="$2" line target want_real
  [[ -f "$rc" ]] || return 1
  want_real="$(cma_realpath "$want" 2>/dev/null || printf '%s' "$want")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $CMA_ALIAS_SRC_RE ]]; then
      target="${BASH_REMATCH[2]}"; target="${target/#\$HOME/$HOME}"; target="${target/#\~/$HOME}"
      [[ "$(cma_realpath "$target" 2>/dev/null || printf '%s' "$target")" == "$want_real" ]] && return 0
    fi
  done < "$rc"
  return 1
}

# ===========================================================================
# Alias file: one renderer, one lock, one rename.
# ===========================================================================
# WHY THIS SHAPE — forensics of the 2026-07-20 alias-file destruction. The live
# aliases.sh collapsed 37288 -> 282 -> 32112 -> 974 -> 909 -> 25682 -> 130 bytes
# inside four seconds, losing the header, BOTH wrapper functions and every
# `alias claudeN=` line. No single writer was buggy: `cma_ensure_alias_file`
# performed SIX sequential whole-file read-modify-write migrations plus two
# direct `cat >> "$ALIAS_FILE"` appends, while `claude-providers list
# --refresh-aliases` — fired by the session hook on EVERY shell start —
# performed 21 more whole-file rewrites. Each was atomic and content-preserving
# in isolation; together, with no lock anywhere on the file, one writer's stale
# snapshot silently overwrote another writer's committed result (lost update).
# The corruption timestamp preceded the incidental SIGTERM by ~14 minutes, so
# this is clean-run reachable, not an interrupt-only hazard.
#
# The three properties that fix it, in order of leverage:
#
#   1. RENDER ONCE. The complete file (managed block + carried lines + the
#      session-hook block) is built in ONE temp and committed with a SINGLE
#      rename. There is no intermediate on-disk state for a concurrent reader
#      or writer to snapshot, and the drop-then-re-append migrations disappear
#      entirely — the wrappers are always emitted at their current version, so
#      there is nothing to "migrate". That also kills the orphaned `# Wrapper:`
#      comment leak: the old drop-awk started at the `cma_run() {` line and left
#      the 4-line comment above it behind while the re-append put the function
#      at the end, leaking 5 dead lines and reordering the file on every firing
#      (~15 orphans had accumulated on the live host).
#
#   2. NO-OP GUARD. If the render is byte-identical to what is on disk, nothing
#      is written and the lock is never even taken. On a steady-state host this
#      turns 21 renames per shell start into zero writes, so the common path
#      cannot enter the race at all. This is the highest-leverage part.
#
#   3. EXCLUSIVE LOCK. The remaining read-render-rename is still a
#      read-modify-write, so it runs under an $ALIAS_FILE-scoped exclusive lock.
#      Contention policy is caller-set via CMA_ALIAS_LOCK_WAIT: the session hook
#      uses 0 (give up instantly — a shell start must NEVER block, and a skipped
#      refresh is harmless because the next writer re-renders from the file).
#
# Plus a sanity gate (never commit a file missing the header, either wrapper, or
# any alias it did not explicitly drop).
#
# What protects WHAT, stated precisely, INCLUDING what the test suite does and
# does not cover. Two earlier versions of this comment overclaimed here; both
# corrections below were established by deleting the mechanism and re-running.
#
#   * No half-file can be published because of RENDER-ONCE + a single mv(2).
#     That property holds with the signal mask removed, and a 15-iteration
#     SIGTERM test cannot tell the difference. The mask is not what earns it.
#
#   * The INT/TERM mask is DEFENCE IN DEPTH WITH NO TEST-VISIBLE EFFECT, and
#     saying otherwise was the second overclaim. The narrow thing it was
#     credited with — stopping a signal between the rename and the lock release
#     from leaking the lock — is not, in fact, a hazard either backend suffers:
#       - flock: the lock is an fd. Process death releases it in the kernel,
#         mask or no mask. There is nothing to leak.
#       - mkdir: a leaked lock dir names a dead pid, and the very next acquire
#         reclaims it via _cma_alias_lock_break_stale — inside the SAME call,
#         at any wait including 0. It does not make later writers skip.
#     So deleting `trap '' INT TERM` leaves the suite green, and no honest test
#     distinguishes it. What it genuinely buys is that the saved INT/TERM traps
#     are restored rather than left disarmed for the caller. It is kept for
#     that and for the narrow interrupt-safety it costs nothing to have — NOT
#     because anything here proves it necessary. Do not cite it as tested.
#
#   * MUTUAL EXCLUSION is the lock's job and nothing else's. The storm in
#     test_alias_file_concurrency.sh section 1 does NOT measure it: its writers
#     all write the SAME content, so a lost update is re-derived on the next
#     iteration, and deleting the lock acquire outright leaves that section
#     passing 3/3. Section 1b is what measures it — N one-shot DISTINCT writes,
#     nothing to re-derive a loss — and that is the case which found the mkdir
#     backend was not excluding at all (see _cma_alias_lock_break_stale).

# Sentinels bracketing the machine-owned region. Everything between them is
# regenerated verbatim on every write; everything outside is carried over
# untouched (user additions survive — see the "unrelated user line preserved"
# coverage test). Pre-sentinel files are recognised by content instead, once,
# by _cma_alias_carryover's legacy rules.
CMA_ALIAS_MANAGED_BEGIN='# cma-managed BEGIN — regenerated by claude-multi-account; do not edit inside'
CMA_ALIAS_MANAGED_END='# cma-managed END'
CMA_ALIAS_HOOK_BEGIN='# cma-providers-session-refresh BEGIN'
CMA_ALIAS_HOOK_END='# cma-providers-session-refresh END'

# --- exclusive lock on the alias file ---------------------------------------
# This deliberately MIRRORS scripts/tests/lib/suite-lock.sh (flock(1) where
# present, otherwise an atomic mkdir(2) lock with rename-verified stale
# breaking — macOS ships no flock) rather than sourcing it. suite-lock.sh is
# test infrastructure: its acquire() `exit 75`s the process on contention and
# installs its own EXIT/INT/TERM traps. Both are unacceptable in a library that
# runs inside install scripts and, transitively, shell startup — so the same
# primitive is re-implemented here with a returns-a-status contract, no process
# exit, and no trap hijacking.
#
# KNOBS
#   CMA_ALIAS_LOCK_WAIT        seconds to wait on contention (default 30);
#                              0 = fail fast, used by the session hook
#   CMA_ALIAS_LOCK_NO_FLOCK=1  force the portable fallback (tests exercise the
#                              macOS path on Linux)
#   CMA_ALIAS_LOCK_STALE_GRACE seconds a pid-less lock dir may exist before it
#                              is treated as stale (default 10)
CMA_ALIAS_LOCK_WAIT="${CMA_ALIAS_LOCK_WAIT:-30}"
CMA_ALIAS_LOCK_STALE_GRACE="${CMA_ALIAS_LOCK_STALE_GRACE:-10}"
_cma_alias_lock_depth=0
_cma_alias_lock_mode=""
_cma_alias_lock_file=""

# Sanitised wait, in seconds. A junk value must not abort the caller under
# `set -e` when it reaches an arithmetic test.
_cma_alias_lock_wait() {
  case "${CMA_ALIAS_LOCK_WAIT:-}" in
    ''|*[!0-9]*) printf '30\n' ;;
    *)           printf '%s\n' "$CMA_ALIAS_LOCK_WAIT" ;;
  esac
}

_cma_alias_lock_pid() {
  local p=""
  if [[ "$_cma_alias_lock_mode" == "mkdir" ]]; then
    p="$(head -1 "$_cma_alias_lock_file/pid" 2>/dev/null || true)"
  else
    p="$(head -1 "$_cma_alias_lock_file" 2>/dev/null || true)"
  fi
  printf '%s' "$p" | tr -d '[:space:]'
}

# Discard a lock whose owner is gone.
#
# WHY THIS IS NOT THE OBVIOUS "rename it aside and look at it".
# It used to be. That version renamed the lock directory to a private path,
# read the pid inside, and renamed it BACK when the pid was not the one it had
# judged dead. Two flaws compounded, and together they cost the mkdir backend
# mutual exclusion outright — measured, not theorised: 12 one-shot concurrent
# writers each adding a DIFFERENT alias lost at least one COMMITTED alias in
# roughly 40% of runs, with the caller told rc 0. That is a lost update, the
# very failure that destroyed the live alias file.
#
#   1. TOCTOU on the holder's identity. The caller samples the pid, then tests
#      liveness. A holder that RELEASED NORMALLY and then exited is
#      indistinguishable from one that died holding the lock: by the time
#      `kill -0` runs the pid is gone, while the directory has already been
#      re-created by a different, LIVE writer. The audit trace for this bug
#      shows the judged holder exiting 1ms before the test that condemned it.
#   2. The restore was not atomic. Between `mv lock aside` and `mv aside lock`
#      the lock DOES NOT EXIST, so any contender's `mkdir` succeeds there. The
#      displaced holder never learns it lost the lock, and two processes enter
#      the critical section together. Every double-hold in the audit is
#      preceded, within ~15ms, by exactly this restore.
#
# So the directory is never moved. It is inspected IN PLACE and removed only
# once proven stale, under a short-lived breaker lock that makes
# inspect-then-remove exclusive among breakers. That closes the window: a
# directory whose recorded pid is dead cannot be released by its owner (it is
# dead) and cannot be removed by another breaker (we hold the breaker lock), so
# nothing can re-create it under a LIVE owner between the check and the removal.
#
# NOTE: tests/lib/suite-lock.sh carries the older shape. It is deliberately NOT
# converged with this one — it is global-by-design test infrastructure with a
# different contract (it exits the process on contention) — but it has the same
# hazard, at far lower stakes (one suite run per checkout).
_cma_alias_lock_break_stale() {
  local observed="${1:-}" brk="${_cma_alias_lock_file}.breaker" bpid got
  # Breaker exclusivity: mkdir(2) is the atomic claim. Losing it is not an
  # error — someone else is already breaking, so we simply retry the acquire.
  if ! mkdir "$brk" 2>/dev/null; then
    # A breaker that died mid-break would wedge every later one, so a breaker
    # lock whose owner is gone is reaped. This is the ONLY thing this branch
    # may remove; it never touches the alias lock itself.
    bpid="$(head -1 "$brk/pid" 2>/dev/null || true)"
    bpid="$(printf '%s' "$bpid" | tr -d '[:space:]')"
    if [[ -n "$bpid" ]] && ! kill -0 "$bpid" 2>/dev/null; then
      rm -rf "$brk" 2>/dev/null || true
    fi
    return 0
  fi
  printf '%s\n' "$$" > "$brk/pid" 2>/dev/null || true

  # Re-read the evidence as late as possible and grade the directory we are
  # about to delete, never a pid the caller sampled an iteration ago.
  got="$(_cma_alias_lock_pid)"
  if [[ -n "$observed" ]]; then
    # Still the same holder we judged, and still gone.
    if [[ "$got" == "$observed" ]] && ! kill -0 "$got" 2>/dev/null; then
      rm -rf "$_cma_alias_lock_file" 2>/dev/null || true
    fi
  elif [[ -z "$got" ]]; then
    # Pid-less. The caller only asks for this after CMA_ALIAS_LOCK_STALE_GRACE
    # seconds of CONTINUOUS emptiness, which is what separates "the winner has
    # not written its pid yet" (microseconds) from "the winner died in between".
    # That grace, not this re-read, is the guard for the empty case.
    rm -rf "$_cma_alias_lock_file" 2>/dev/null || true
  fi

  rm -rf "$brk" 2>/dev/null || true
  return 0
}

# Acquire (or re-enter) the alias-file lock. Returns 1 on contention timeout —
# never exits, never blocks longer than CMA_ALIAS_LOCK_WAIT.
_cma_alias_lock_acquire() {
  _cma_alias_lock_depth=$(( _cma_alias_lock_depth + 1 ))
  if (( _cma_alias_lock_depth > 1 )); then return 0; fi   # re-entrant

  local dir wait_s deadline holder empty_since=""
  dir="$(dirname "$ALIAS_FILE")"
  mkdir -p "$dir" 2>/dev/null || true
  wait_s="$(_cma_alias_lock_wait)"

  if command -v flock >/dev/null 2>&1 && [[ -z "${CMA_ALIAS_LOCK_NO_FLOCK:-}" ]]; then
    _cma_alias_lock_mode="flock"
    _cma_alias_lock_file="$dir/.aliases.lock"
    # APPEND mode on purpose: `exec 8>file` truncates at open, erasing a live
    # holder's PID record before we even contend.
    if ! exec 8>>"$_cma_alias_lock_file"; then
      _cma_alias_lock_depth=0; return 1
    fi
    if ! flock -n 8; then
      if (( wait_s <= 0 )) || ! flock -w "$wait_s" 8; then
        # BRACES ARE LOAD-BEARING. `exec 8>&- 2>/dev/null` is NOT "close fd 8,
        # quietly": a command-less `exec` applies EVERY redirection on the line
        # to the shell PERMANENTLY, so the `2>/dev/null` silences this
        # process's stderr for the rest of its life. That fired here on every
        # contended acquire — precisely when the caller has something to say —
        # and it swallowed claude-add-account's whole "here is how to finish
        # the job" message, leaving a user with a config dir, no alias, and no
        # explanation. Scoping the redirection to a group closes the fd and
        # leaves stderr alone.
        { exec 8>&-; } 2>/dev/null || true
        _cma_alias_lock_depth=0
        return 1
      fi
    fi
    printf '%s\n' "$$" > "$_cma_alias_lock_file" 2>/dev/null || true
    return 0
  fi

  _cma_alias_lock_mode="mkdir"
  _cma_alias_lock_file="$dir/.aliases.lockdir"
  deadline=$(( $(date +%s) + wait_s ))
  while :; do
    if mkdir "$_cma_alias_lock_file" 2>/dev/null; then
      printf '%s\n' "$$" > "$_cma_alias_lock_file/pid" 2>/dev/null || true
      # A contender mid stale-break could have swapped the dir out from under
      # us; the recorded PID is the tiebreaker.
      if [[ "$(_cma_alias_lock_pid)" != "$$" ]]; then continue; fi
      return 0
    fi
    holder="$(_cma_alias_lock_pid)"
    if [[ -z "$holder" ]]; then
      # mkdir won but the pid write has not landed yet — or the winner died in
      # between. Give it a grace window before declaring the lock stale.
      [[ -n "$empty_since" ]] || empty_since="$(date +%s)"
      if (( $(date +%s) - empty_since >= CMA_ALIAS_LOCK_STALE_GRACE )); then
        _cma_alias_lock_break_stale ""
        empty_since=""
        continue
      fi
    else
      empty_since=""
      if ! kill -0 "$holder" 2>/dev/null; then
        _cma_alias_lock_break_stale "$holder"
        continue
      fi
    fi
    if (( $(date +%s) >= deadline )); then
      _cma_alias_lock_depth=0
      return 1
    fi
    sleep 0.1 2>/dev/null || sleep 1
  done
}

_cma_alias_lock_release() {
  (( _cma_alias_lock_depth > 0 )) || return 0
  _cma_alias_lock_depth=$(( _cma_alias_lock_depth - 1 ))
  if (( _cma_alias_lock_depth > 0 )); then return 0; fi
  if [[ "$_cma_alias_lock_mode" == "mkdir" ]]; then
    # Only remove a lock we still own — after a stale break the directory may
    # belong to someone else.
    if [[ "$(_cma_alias_lock_pid)" == "$$" ]]; then
      rm -rf "$_cma_alias_lock_file" 2>/dev/null || true
    fi
  else
    # The file is deliberately NOT unlinked: unlinking a flock target races a
    # contender who already opened the old inode.
    flock -u 8 2>/dev/null || true
    # Braces, for the reason spelled out in _cma_alias_lock_acquire. This site
    # was the worse of the two: it is on the SUCCESS path, so every process
    # that committed an alias — install.sh, claude-add-account,
    # claude-providers sync — ran the rest of its life with stderr pointed at
    # /dev/null and lost every warning and error it later tried to report.
    { exec 8>&-; } 2>/dev/null || true
  fi
  return 0
}

# --- the managed block -------------------------------------------------------
# One emitter per piece. These are the ONLY definitions of the wrappers; the
# renderer always emits the current text, which is why no drop/re-append
# migration (and no orphan-comment leak) exists any more.

# The ccr-self-reference test, as ONE definition serving THREE call sites:
# cma_run_provider (which lives inside the emitted alias file and therefore has
# no access to lib.sh's functions), providers-verify.sh, and lib.sh itself. The
# emitter below is the single source of the text; the alias file gets it via
# _cma_emit_managed, and this shell gets it via the `eval` immediately after, so
# the two copies cannot drift. The previous arrangement — a `case` duplicated at
# lib.sh's launch gate and providers-verify.sh's Gate 0 — under-matched every
# spelling except the four it literally listed, so `127.0.1.1:3456` (Debian's
# DEFAULT loopback for the local hostname), any other 127/8 address, the
# v4-mapped and fully-expanded IPv6 loopbacks, `LOCALHOST`, a `user@` prefix and
# a `?query`/`#fragment` suffix all sailed through the guard and re-armed the
# exact helixagent hazard the guard exists to stop.
_cma_emit_ccr_gateway_guard() {
  cat <<'CMA_CCRGW_EOF'
# True when $1 is a URL pointing at the LOCAL ccr gateway (port $2, default
# $CMA_CCR_PORT or 3456). Such a base_url has no upstream: routing through it
# means serving whatever provider ccr last routed to, with no error anywhere.
# Matches the whole 127/8 range, 0.0.0.0, `localhost` in any case, and IPv6
# loopback in every spelling (::1, 0:0:0:0:0:0:0:1, ::ffff:127.0.0.1, …),
# tolerating userinfo, path, query and fragment. A different port, a
# non-loopback host, or a remote https base is NOT a match.
_cma_is_ccr_gateway() {
  local url="${1:-}" want="${2:-${CMA_CCR_PORT:-3456}}" hp host port v4 squash
  [[ -n "$url" ]] || return 1
  hp="${url#*://}"          # drop the scheme
  hp="${hp%%/*}"            # drop the path
  hp="${hp%%\?*}"           # drop a query that followed no path
  hp="${hp%%#*}"            # drop a fragment that followed no path
  hp="${hp##*@}"            # drop userinfo (greedy: the LAST '@' wins)
  case "$hp" in
    \[*\]:*) host="${hp%]:*}"; host="${host#[}"; port="${hp##*]:}" ;;
    *:*)     host="${hp%%:*}"; port="${hp##*:}" ;;
    *)       return 1 ;;    # no explicit port -> not the gateway
  esac
  [[ "$port" == "$want" ]] || return 1
  host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  case "$host" in
    localhost|localhost.localdomain) return 0 ;;
    0.0.0.0) return 0 ;;
    # 127/8, but only as a real dotted quad: `127.example.com` is a hostname.
    127.*) case "$host" in *[!0-9.]*) return 1 ;; *) return 0 ;; esac ;;
    # IPv4-mapped/compatible IPv6 (::ffff:127.0.0.1): grade the embedded v4.
    *:*.*.*.*)
      v4="${host##*:}"
      case "$v4" in
        *[!0-9.]*) return 1 ;;
        127.*|0.0.0.0) return 0 ;;
        *) return 1 ;;
      esac ;;
    # Pure IPv6: loopback (::1) and unspecified (::) in any zero-compression.
    *:*)
      squash="${host//:/}"; squash="${squash//0/}"
      [[ -z "$squash" || "$squash" == "1" ]] && return 0
      return 1 ;;
  esac
  return 1
}
CMA_CCRGW_EOF
}
# Define it in THIS shell from the exact same bytes the alias file receives.
eval "$(_cma_emit_ccr_gateway_guard)"

# Dynamic account dispatcher (live defect 2026-07-23, `claude5`): a newly
# added account's alias is INVISIBLE to every shell that sourced the alias
# file BEFORE the add — and long-lived shells are the norm (tmux panes
# survive SSH re-logins; re-attaching does NOT restart the pane's shell, so
# "log out and back in" does not pick the alias up). The static per-account
# `alias claudeN=…` lines can never fix that class: an alias must exist at
# shell start.
#
# The dispatcher closes the class STRUCTURALLY: a command-not-found handler
# (bash: command_not_found_handle; zsh: command_not_found_handler) resolves
# `<name>` -> $HOME/<prefix><name> at INVOCATION time from the config dirs,
# so ANY account added AFTER a shell sourced a dispatcher-bearing alias file
# works in that shell immediately, with no re-source. It is a pure FALLBACK:
# defined aliases/functions/binaries always win (the handler only fires when
# nothing else matched), a pre-existing handler (e.g. Ubuntu's
# command-not-found) is preserved and chained for non-account names, and a
# non-account miss still reports "command not found" with rc 127.
#
# Honest boundary: shells that sourced a PRE-dispatcher alias file remain
# stale until they re-source once (claude-add-account warns about exactly
# this) — the dispatcher eliminates the staleness class from then on, it
# cannot retroactively appear in old shells. Accounts created with a custom
# --dir that does not follow the $HOME/<prefix><alias> pattern are resolved
# by their (re-sourced) alias line only; the dispatcher cannot infer such a
# mapping and does not guess (§11.4.6).
_cma_emit_account_dispatch() {
  # The account-dir prefix is embedded at render time (like CLAUDE_BIN above)
  # so the emitted file is self-contained; the runtime fallback keeps a
  # hand-truncated header from breaking dispatch entirely.
  printf '_CMA_ACCOUNT_PREFIX=%q\n' "${ACCOUNT_PREFIX:-.claude-}"
  cat <<'CMA_DISPATCH_EOF'
# True when $1 names a launchable ACCOUNT: a plain command word (no path
# separator, not an option, not dot-prefixed) whose $HOME/<prefix>$1 config
# dir exists. Provider config dirs (<prefix>prov-*) and the router's own dir
# (<prefix>code-router) are NOT accounts — providers launch via
# cma_run_provider and must never be hijacked by the account fallback.
_cma_is_account_cmd() {
  case "${1:-}" in ''|*/*|-*|.*) return 1 ;; esac
  case "$1" in prov-*|code-router) return 1 ;; esac
  [ -d "$HOME/${_CMA_ACCOUNT_PREFIX:-.claude-}$1" ]
}
_cma_cnf_impl() {
  if _cma_is_account_cmd "${1:-}"; then
    local _cma_d="$HOME/${_CMA_ACCOUNT_PREFIX:-.claude-}$1"
    shift
    CLAUDE_CONFIG_DIR="$_cma_d" cma_run "$@"
    return $?
  fi
  # Not an account: hand off to whatever handler existed before this file was
  # sourced (captured below), else reproduce the shell's stock behaviour.
  if declare -f _cma_prev_cnf_handle >/dev/null 2>&1; then
    _cma_prev_cnf_handle "$@"
    return $?
  fi
  printf '%s: command not found\n' "${1:-}" >&2
  return 127
}
# Preserve a PRE-EXISTING handler exactly once. Idempotent across re-sources:
# a definition that already routes through _cma_cnf_impl is OURS and must not
# be captured as "previous" (that would chain the handler to itself).
if [ -n "${BASH_VERSION:-}" ]; then
  _cma_cnf_name=command_not_found_handle
else
  _cma_cnf_name=command_not_found_handler
fi
_cma_cnf_def="$(declare -f "$_cma_cnf_name" 2>/dev/null || true)"
case "$_cma_cnf_def" in
  *_cma_cnf_impl*) : ;;
  '') : ;;
  *) eval "_cma_prev_cnf_handle() ${_cma_cnf_def#*'()'}" ;;
esac
unset _cma_cnf_def _cma_cnf_name
# Define BOTH spellings; each shell consults only its own, the other is inert.
command_not_found_handle()  { _cma_cnf_impl "$@"; }
command_not_found_handler() { _cma_cnf_impl "$@"; }
CMA_DISPATCH_EOF
}

# ATM-850 remediation half 2 (2026-07-23): operator-facing tmux staleness
# notice. The dispatcher above closes the new-account staleness class for
# every shell that sourced a dispatcher-bearing alias file; shells older than
# that render still hold pre-dispatcher definitions until they re-source ONCE.
# tmux pane shells are the canonical long-lived case (five servers from 00:00
# survived the 15:14 add in the live incident; SSH re-login re-attaches the
# SAME server). This function only DETECTS and PRINTS — the exact re-source
# command plus a per-server broadcast one-liner scoped to idle SHELL panes —
# and NEVER sends keys itself: an autonomous send-keys could type into a pane
# the operator is mid-edit in. Callers may offer an interactive,
# default-No broadcast on top (claude-add-account does).
cma_tmux_stale_shell_notice() {
  local alias_file="${1:-$ALIAS_FILE}"
  command -v tmux >/dev/null 2>&1 || return 0
  local tdir="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u 2>/dev/null || echo 0)"
  [[ -d "$tdir" ]] || return 0
  local sock cmds n total=0
  local -a servers=()
  for sock in "$tdir"/*; do
    [[ -S "$sock" ]] || continue
    cmds="$(tmux -S "$sock" list-panes -a -F '#{pane_current_command}' 2>/dev/null)" || continue
    [[ -n "$cmds" ]] || continue
    n="$(printf '%s\n' "$cmds" | grep -cE '^-?(bash|zsh|sh|dash|ksh|fish)$')" || n=0
    servers+=("$n:$sock"); total=$(( total + n ))
  done
  (( ${#servers[@]} )) || return 0
  printf '\n[tmux] %d running tmux server(s) detected — their pane shells read the alias file when THEY started, not now.\n' "${#servers[@]}"
  if grep -q '_cma_cnf_impl' "$alias_file" 2>/dev/null; then
    printf '[tmux] This alias file carries the dynamic account dispatcher: shells that sourced a\n'
    printf '[tmux] dispatcher-bearing render resolve NEW accounts at invocation time — no re-source needed there.\n'
    printf '[tmux] Only shells that sourced an OLDER (pre-dispatcher) render still need ONE re-source:\n'
  else
    printf '[tmux] Every pre-existing shell needs a re-source to see this account:\n'
  fi
  printf '           source %s\n' "$alias_file"
  printf '[tmux] %d shell pane(s) detected across those servers. To push the re-source into the idle\n' "$total"
  printf '[tmux] SHELL panes of a server (editors/agents/panes running programs are skipped):\n'
  local ent
  for ent in "${servers[@]}"; do
    sock="${ent#*:}"
    printf "         tmux -S %s list-panes -a -F '#{pane_id} #{pane_current_command}' | awk '\$2 ~ /^-?(bash|zsh|sh|dash|ksh|fish)\$/{print \$1}' | xargs -r -I{} tmux -S %s send-keys -t {} C-u ' source %s' Enter\n" "$sock" "$sock" "$alias_file"
  done
  return 0
}

_cma_emit_cma_run() {
  cat <<'CMA_RUN_BODY_EOF'
# Wrapper: keeps .claude.json projects/session index synced across every
# logged-in account. Pulls merged state from every account into the launching
# one before claude runs; pushes the post-session state back out after exit.
# Cheap (jq deep-merge of one ~50KB file per account), runs unconditionally.
cma_run() {
  # Self-heal CLAUDE_BIN: the alias file normally exports it at the top, but if
  # that header line is missing (corrupted or hand-edited alias file) every
  # invocation would silently expand to an empty command ("-bash: : command
  # not found"). Mirrors cma_resolve_claude_bin inline so the function body is
  # self-contained regardless of the header state. §11.4.185.
  if ! command -v "${CLAUDE_BIN:-}" >/dev/null 2>&1; then
    if command -v claude >/dev/null 2>&1; then
      CLAUDE_BIN="$(command -v claude)"
    else
      for _cma_cb in "$HOME/.local/bin/claude" "$HOME/.npm-global/bin/claude" \
                     /opt/homebrew/bin/claude /usr/local/bin/claude; do
        [ -x "$_cma_cb" ] && { CLAUDE_BIN="$_cma_cb"; break; }
      done
      if ! command -v "${CLAUDE_BIN:-}" >/dev/null 2>&1; then
        printf 'cma_run: claude binary not found — check PATH or re-run install.sh\n' >&2
        return 127
      fi
    fi
  fi
  # Provider-env isolation: native claudeN must talk to the real Anthropic API.
  # A provider alias run earlier in THIS shell exports ANTHROPIC_BASE_URL etc.;
  # those persist and would otherwise leak into this native launch (claude1
  # silently using a provider's endpoint). Clear them so native is always clean.
  # The 4 ANTHROPIC_DEFAULT_*_MODEL tier-map vars are exported by
  # cma_run_provider (native transport) and PERSIST after that alias returns; a
  # subsequent native claudeN launch MUST clear them too, else the opus/sonnet/
  # haiku/fable tier resolution silently points at the previous provider's
  # serving model instead of the real Anthropic tier.
  unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL
  unset ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL
  # Token-guard isolation: cma_run_provider exports CLAUDE_CODE_MAX_OUTPUT_TOKENS
  # (output cap, clamped <=128000), CLAUDE_CODE_AUTO_COMPACT_WINDOW (input
  # compact trigger) and CLAUDE_CODE_MAX_CONTEXT_TOKENS (the provider's real
  # context size for client-side accounting) for every provider alias; ALL
  # persist in this shell after that alias returns. A subsequent native claudeN
  # launch MUST clear them, else native inherits a provider's (possibly small)
  # output cap, compact window, or context size instead of the real Anthropic
  # per-model defaults — silently capping native's output or early-compacting
  # its context. Parallels the ANTHROPIC_DEFAULT_* tier-map isolation above.
  unset CLAUDE_CODE_MAX_OUTPUT_TOKENS CLAUDE_CODE_AUTO_COMPACT_WINDOW CLAUDE_CODE_MAX_CONTEXT_TOKENS
  # Working-dir hook (opt-in; no-op when absent). Resolution order:
  #   1. CMA_CWD_HOOK env var               — explicit user override
  #   2. <git-toplevel>/.claude-cwd-hook     — per-project hook (each repo
  #      gets its own multitrack resolver, preventing a single global hook
  #      from hijacking every project’s sessions)
  #   3. ~/.local/bin/claude-cwd-hook        — global fallback
  # The hook runs before claude-session (below) so auto-session keys to the
  # resolved worktree root. Escape hatch: MULTITRACK_DISABLE=1 (honored
  # inside the hook itself; the toolkit does not check it).
  local _cma_cwd_hook _cma_cwd_label _cma_cwd_target
  if [[ -n "${CMA_CWD_HOOK:-}" ]]; then
    _cma_cwd_hook="$CMA_CWD_HOOK"
  else
    local _cma_hook_root
    _cma_hook_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    if [[ -x "$_cma_hook_root/.claude-cwd-hook" ]]; then
      _cma_cwd_hook="$_cma_hook_root/.claude-cwd-hook"
    else
      _cma_cwd_hook="$HOME/.local/bin/claude-cwd-hook"
    fi
  fi
  if [[ -x "$_cma_cwd_hook" ]] && ! git rev-parse --show-toplevel >/dev/null 2>&1; then
    _cma_cwd_label="$(basename "${CLAUDE_CONFIG_DIR:-claude}")"; _cma_cwd_label="${_cma_cwd_label#.claude-}"
    _cma_cwd_target="$("$_cma_cwd_hook" "$_cma_cwd_label" 2>/dev/null || true)"
    if [[ -n "$_cma_cwd_target" && -d "$_cma_cwd_target" ]]; then cd "$_cma_cwd_target" 2>/dev/null || true; fi
  fi
  if [[ -x "$HOME/.local/bin/claude-sync-state" ]]; then
    "$HOME/.local/bin/claude-sync-state" pull "$CLAUDE_CONFIG_DIR" 2>/dev/null || true
  fi
  # Auto session-per-project: when launched with NO args, resume (or create) the
  # one long-lived session for this project root, name it after the root dir,
  # trust the workspace, and hint the alias color. Only when bare so explicit
  # user flags (-p, --resume, a prompt, …) are always respected verbatim.
  # claude-session emits only "--resume <uuid>" or "--session-id <uuid> --name
  # <kebab>" (no shell metacharacters), so eval-splitting is safe and works in
  # both bash and zsh (zsh does not word-split unquoted expansions).
  local _cma_label=""
  if [[ $# -eq 0 && -x "$HOME/.local/bin/claude-session" ]]; then
    local _cma_sf
    _cma_sf="$("$HOME/.local/bin/claude-session" flags "$CLAUDE_CONFIG_DIR" 2>/dev/null || true)"
    _cma_label="$(basename "${CLAUDE_CONFIG_DIR:-claude}")"; _cma_label="${_cma_label#.claude-}"
    "$HOME/.local/bin/claude-session" hint "$_cma_label" 2>/dev/null || true
    eval "set -- $_cma_sf"
    # Auto-apply the per-alias color: a resumable session's jsonl exists now, so
    # colour it before launch; a brand-new session's file appears during launch,
    # so we colour it again after exit (see post-launch call below).
    "$HOME/.local/bin/claude-session" apply-color "$CLAUDE_CONFIG_DIR" "$_cma_label" 2>/dev/null || true
  fi
  "$CLAUDE_BIN" "$@"
  local rc=$?
  if [[ -x "$HOME/.local/bin/claude-sync-state" ]]; then
    "$HOME/.local/bin/claude-sync-state" push "$CLAUDE_CONFIG_DIR" 2>/dev/null || true
  fi
  [[ -n "$_cma_label" && -x "$HOME/.local/bin/claude-session" ]] && \
    "$HOME/.local/bin/claude-session" apply-color "$CLAUDE_CONFIG_DIR" "$_cma_label" 2>/dev/null || true
  return $rc
}
CMA_RUN_BODY_EOF
}

_cma_emit_cma_run_provider() {
  cat <<'CMA_PROV_BODY_EOF'
cma_run_provider() {
  # Self-heal CLAUDE_BIN (same as cma_run — §11.4.185). Prevents "-bash: : command
  # not found" when the alias-file header export line is missing. Also resolves
  # the binary for the native-transport path ("$CLAUDE_BIN" "$@") below.
  if ! command -v "${CLAUDE_BIN:-}" >/dev/null 2>&1; then
    if command -v claude >/dev/null 2>&1; then
      CLAUDE_BIN="$(command -v claude)"
    else
      for _cma_cb in "$HOME/.local/bin/claude" "$HOME/.npm-global/bin/claude" \
                     /opt/homebrew/bin/claude /usr/local/bin/claude; do
        [ -x "$_cma_cb" ] && { CLAUDE_BIN="$_cma_cb"; break; }
      done
    fi
  fi
  if ! command -v "${CLAUDE_BIN:-}" >/dev/null 2>&1; then
    printf 'claude-providers: claude binary not found — check PATH or re-run install.sh\n' >&2
    return 127
  fi
  # --force bypasses the activation gate (operator override). Accepted BOTH as
  # the very first arg (direct call: cma_run_provider --force <id>) and as the
  # first arg after the id (alias path: `<alias> --force` expands to
  # cma_run_provider <id> --force). Either way it is consumed, not forwarded.
  local _cma_force=0
  if [[ "${1:-}" == "--force" ]]; then _cma_force=1; shift; fi
  local id="$1"; shift 2>/dev/null || true
  if [[ "${1:-}" == "--force" ]]; then _cma_force=1; shift; fi
  local pdir="$HOME/.local/share/claude-multi-account/providers"
  local envf="$pdir/$id.env"
  if [[ ! -f "$envf" ]]; then
    printf 'claude-providers: unknown provider %s (missing %s)\n' "$id" "$envf" >&2
    return 1
  fi
  # shellcheck disable=SC1090
  source "$envf"
  # Cross-alias env isolation: unset any ANTHROPIC_*/CLAUDE_CODE_* vars that
  # leaked from a PREVIOUS cma_run_provider invocation in this shell. The
  # transport-specific branches below re-export them from this provider's
  # CMA_PROVIDER_* vars (fresh from source "$envf"), so the unset here is
  # only clearing the leftover from the previous alias — identical to how
  # cma_run (the native claudeN wrapper) isolates its ANTHROPIC_* vars.
  unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL
  # The 4 tier-default-model vars this same wrapper exports (native branch below)
  # also persist into a following alias invocation; clear the previous run's
  # values so this provider re-exports its own from CMA_PROVIDER_MODEL below.
  unset ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL
  unset CLAUDE_CODE_AUTO_COMPACT_WINDOW CLAUDE_CODE_MAX_OUTPUT_TOKENS
  # Working-dir hook (same 3-tier resolution as cma_run). This must run
  # BEFORE sync-state pull + session flags so the resolved directory is the
  # session's canonical cwd. Without this, provider aliases ignore the
  # multitrack resolver and launch in whatever $PWD the user happened to be in.
  local _cma_cwd_hook _cma_cwd_label _cma_cwd_target
  if [[ -n "${CMA_CWD_HOOK:-}" ]]; then
    _cma_cwd_hook="$CMA_CWD_HOOK"
  else
    local _cma_hook_root
    _cma_hook_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    if [[ -x "$_cma_hook_root/.claude-cwd-hook" ]]; then
      _cma_cwd_hook="$_cma_hook_root/.claude-cwd-hook"
    else
      _cma_cwd_hook="$HOME/.local/bin/claude-cwd-hook"
    fi
  fi
  if [[ -x "$_cma_cwd_hook" ]] && ! git rev-parse --show-toplevel >/dev/null 2>&1; then
    _cma_cwd_label="$(basename "${CLAUDE_CONFIG_DIR:-claude}")"; _cma_cwd_label="${_cma_cwd_label#.claude-}"
    _cma_cwd_target="$("$_cma_cwd_hook" "$_cma_cwd_label" 2>/dev/null || true)"
    if [[ -n "$_cma_cwd_target" && -d "$_cma_cwd_target" ]]; then cd "$_cma_cwd_target" 2>/dev/null || true; fi
  fi
  # Activation gate: only a 'verified' alias launches Claude Code. A non-verified
  # alias (unverified / failed / pending) prints a clear, actionable message and
  # refuses to launch, so a broken provider never surfaces as a confusing
  # in-session error. Status comes from the non-secret status cache; this body is
  # self-contained (no cma_* helpers) so it reads status.json with jq inline.
  if (( ! _cma_force )); then
    local _cma_sf="$pdir/status.json" _cma_st="pending"
    if command -v jq >/dev/null 2>&1 && [[ -s "$_cma_sf" ]]; then
      _cma_st="$(jq -r --arg i "$CMA_PROVIDER_ID" '.[$i].status // "pending"' "$_cma_sf" 2>/dev/null)"
      [[ -n "$_cma_st" && "$_cma_st" != "null" ]] || _cma_st="pending"
    fi
    if [[ "$_cma_st" != "verified" ]]; then
      printf 'claude-providers: alias %s is %s — not launching.\n' "$CMA_PROVIDER_ID" "$_cma_st" >&2
      printf '  Re-verify: claude-providers sync   (re-runs verification for %s)\n' "$CMA_PROVIDER_ID" >&2
      printf '  Override (operator): run the alias with --force\n' >&2
      return 3
    fi
  fi
  local keysf="${CMA_KEYS_FILE:-$HOME/api_keys.sh}"
  # Disable nounset while sourcing the user-controlled keys file: it may have
  # dangling refs (e.g. `export X=$UNSET`) that would abort the source under a
  # caller's `set -u`, leaving the token empty. Save/restore so we never change
  # the user's interactive shell options.
  if [[ -f "$keysf" ]]; then
    case $- in *u*) local _cma_had_u=1 ;; *) local _cma_had_u=0 ;; esac
    set -a +u; source "$keysf"; set +a
    (( _cma_had_u )) && set -u
  fi
  # Indirect-expand the key var name. ${!var} is bash-only and a fatal error in
  # zsh (the default macOS interactive shell this alias file is sourced into),
  # so use eval, which works in both. CMA_PROVIDER_KEYVAR is a validated env
  # var name ([A-Za-z_][A-Za-z0-9_]*), so this eval is safe.
  local token="" _cma_xt=""
  # Suppress xtrace around the indirect key read so an active `set -x` in the
  # user's shell can't echo the secret to the terminal or a redirected log.
  case $- in *x*) _cma_xt=1; set +x ;; esac
  # Kimi Code OAuth sentinel: the OAuth token is SHORT-LIVED (~15 min), so a
  # sync-time snapshot is stale by the next launch. Freshness order:
  #  1. the LIVE kimi-code credentials file, when unexpired (60s skew);
  #  2. a CLI-triggered refresh (kimi -p hi) followed by a re-read of 1;
  #  3. the token-file snapshot written at sync (last resort only).
  if [[ "$CMA_PROVIDER_KEYVAR" == "_CMA_KIMICODE_OAUTH_" ]]; then
    local _cma_kcred="$HOME/.kimi-code/credentials/kimi-code.json"
    if [[ -f "$_cma_kcred" ]] && command -v jq >/dev/null 2>&1; then
      local _cma_kexp; _cma_kexp="$(jq -r '.expires_at // 0' "$_cma_kcred" 2>/dev/null || echo 0)"
      if (( _cma_kexp > $(date +%s) + 60 )); then
        token="$(jq -r '.access_token // ""' "$_cma_kcred" 2>/dev/null)"
      fi
    fi
    if [[ -z "$token" && -f "$_cma_kcred" ]] && command -v kimi >/dev/null 2>&1; then
      timeout 20 kimi -p "hi" --output-format text >/dev/null 2>&1 || true
      token="$(jq -r '.access_token // ""' "$_cma_kcred" 2>/dev/null)"
    fi
    if [[ -z "$token" ]]; then
      local _cma_ktok="$pdir/${CMA_PROVIDER_ID}.token"
      [[ -f "$_cma_ktok" ]] && token="$(cat "$_cma_ktok" 2>/dev/null)" || token=""
    fi
  else
    eval "token="\${$CMA_PROVIDER_KEYVAR:-}""
  fi
  [[ -n "$_cma_xt" ]] && set -x
  if [[ -z "$token" ]]; then
    printf 'claude-providers: $%s is empty (set it in %s)\n' "$CMA_PROVIDER_KEYVAR" "$keysf" >&2
    return 1
  fi
  export CLAUDE_CONFIG_DIR="$CMA_PROVIDER_CONFIG_DIR"
  # Input-context guard (fixes "400 exceeded model token limit: 262144
  # (requested: 311786)"): tell Claude Code this provider's REAL context window
  # so it auto-compacts (at window-13000) before a request overshoots the
  # provider's hard input limit. Without this, Claude Code assumes Anthropic's
  # own large (~1M) window and lets the prompt grow past a smaller provider's
  # cap. Fully dynamic — the value is CMA_PROVIDER_CONTEXT_LIMIT, resolved from
  # the models.dev catalog (limit.context) per selected model. Applies to BOTH
  # transports (native + router), so every provider alias is protected.
  # NOTE: this caps INPUT context; CLAUDE_CODE_MAX_OUTPUT_TOKENS (set just
  # below, before the transport branch, BOTH transports, clamped <=128000)
  # caps OUTPUT — the two are independent halves of the guard.
  # Auto-compact cap: only lower the window; never raise it above ~200K.
  # Providers with >200K context (DeepSeek 1M, Xiaomi 1M) do not need the full
  # window — exporting it disables auto-compaction until ~987K, filling the
  # session before compacting. CMA_AUTO_COMPACT_CAP overrides.
  #
  # _cma_in_guard (v1.24.0): the input guard is exported for EVERY provider
  # with a known context, CLAMPED — never skipped. The previous gate
  # ("export only when CONTEXT_LIMIT <= cap") was FAIL-OPEN and backwards: a
  # provider whose context was LARGER than the cap got no input guard at all,
  # which is precisely the case that needs one. openrouter (catalog context
  # 1000000) therefore ran unguarded on the input side while the output side
  # reserved 128000, and the request overshot the endpoint's real 262144
  # window: 33796 + 103687 + 128000 = 265483. See _cma_out_guard below for the
  # matching output half; the window is computed AFTER it, from ctx - out, so
  # the two halves cannot sum past the context.
  # --- cma-token-guards:begin --- (extracted verbatim by test_providers.sh;
  # the guards are pure arithmetic over CMA_PROVIDER_{CONTEXT_LIMIT,MAX_OUTPUT},
  # so the suite can exercise the SHIPPED source without launching anything.)
  local _cma_compact_cap="${CMA_AUTO_COMPACT_CAP:-200000}"
  # _cma_out_guard (v1.16.0) + <=128000 clamp (§11.4.108/§11.4.111): output-
  # token cap for BOTH transports, not just native. Without it, router
  # providers run with Claude Code's generic default output cap (128000 for
  # models it does not know) and long reasoning responses die with "Claude's
  # response exceeded the 128000 output token maximum". The value starts from
  # the provider model's REAL output limit (models.dev limit.output via
  # CMA_PROVIDER_MAX_OUTPUT); proxies may clamp further API-side
  # (sarvam_proxy's tier clamp). Exported ONCE here, before the transport
  # branch, so router AND native behave identically (previously only the
  # native branch re-exported it — an unclamped, transport-asymmetric raw
  # value).
  # Catalog caveat (live-proven on nvidia5): when limit.output >=
  # limit.context the "output" number is really the context size — exporting
  # it makes Claude Code request that many completion tokens, and
  # input+request overshoots the shared window (400 "maximum context length
  # is N … you requested M"). Only a genuinely separate output budget
  # (output < context) is exported.
  # Clamp caveat (live-proven, 128k Tier-1): exporting the model's THEORETICAL
  # limit.output when it exceeds the CLI's own custom-model ceiling (deepseek
  # 384000, xiaomi 131072) makes Claude Code request its OWN unknown-model
  # ceiling (128000) and then FATALLY abort any length-truncated response:
  # "…exceeded the 128000 output token maximum… set
  # CLAUDE_CODE_MAX_OUTPUT_TOKENS". The CLI hard-caps custom models to 128000
  # regardless, so any value >128000 is pointless — clamp to
  # min(CMA_PROVIDER_MAX_OUTPUT, 128000).
  # Sanitize-then-decide order is load-bearing (POSIX-shape so it behaves
  # identically whether this body is sourced by bash or zsh), and NO
  # arithmetic ever runs on an unsanitized value ([ N -gt .. ] errors past
  # 2^63-1, and (( )) errors on non-integers — CMA_PROVIDER_MAX_OUTPUT traces
  # to the user-settable CMA_HELIXAGENT_MAX_OUTPUT, fed via 'jq --argjson'
  # which preserves huge-int digits verbatim, so both shapes are reachable):
  #   1. empty / non-plain-integer (negatives, "1e6", "12.5") / zero -> NO
  #      export: no real output budget is known, and the CLI's own
  #      unknown-model default (128000) applies exactly as if the catalog had
  #      no entry. (The pre-merge always-export-128000 default was
  #      effect-equivalent for known models but could resurrect the nvidia5
  #      overshoot on small-context catalog-gap models — the conditional
  #      no-export subsumes it safely.)
  #   2. >18 digits: past intmax — no test/(( )) arithmetic is safe. Any real
  #      context (<=18 digits) is smaller, so with a usable context this is
  #      the mislabel shape (-> NO export); with no usable context it
  #      collapses to the 128000 cap WITHOUT arithmetic on the raw value.
  #   3. <=18 digits (test-safe): floor 0/00/000 to no-export, apply the
  #      nvidia5 mislabel skip (output >= context -> NO export), then the
  #      128000 clamp. A leading-zero form like 007 tests as 7 here, stays
  #      <=128000, and exports as "007" (Claude Code parses it as decimal 7 —
  #      min-semantics); a leading-zero 19+ digit form was already collapsed
  #      by rule 2, so it is NEVER re-read as octal.
  local _cma_out="${CMA_PROVIDER_MAX_OUTPUT:-}" _cma_octx="${CMA_PROVIDER_CONTEXT_LIMIT:-}"
  case "$_cma_octx" in
    ''|*[!0-9]*) _cma_octx="" ;;
    *) [ "${#_cma_octx}" -le 18 ] || _cma_octx="" ;;
  esac
  case "$_cma_out" in
    ''|*[!0-9]*) _cma_out="" ;;
    *) if [ "${#_cma_out}" -gt 18 ]; then
         # Past intmax no test/(( )) arithmetic is safe. With a known context
         # the carve-out below supplies the cap; with none, fall back to the
         # CLI ceiling WITHOUT arithmetic on the raw value (F2: never leak it
         # unclamped).
         if [ -n "$_cma_octx" ]; then _cma_out=""; else _cma_out=128000; fi
       elif [ "$_cma_out" -lt 1 ]; then _cma_out=""
       elif [ -n "$_cma_octx" ] && [ "$_cma_out" -ge "$_cma_octx" ]; then _cma_out=""
       fi ;;
  esac
  # Carve the output cap OUT of the context instead of trusting it alongside
  # the context (v1.24.0). Leaving it unset is NOT the safe fallback it looks
  # like: Claude Code's own default for an unknown model is 128000, so "no
  # export" IS a request for 128000 output tokens. kilo proves the point — its
  # catalog row is the impossible ctx==out==262144, the mislabel branch above
  # blanks the value, and the CLI default then reserves 128000 against a 262144
  # window that must also carry Claude Code's ~137K system-prompt + tool-schema
  # floor. Whenever the context is known we therefore always emit a cap that
  # provably fits: min(catalog output, context - input floor), bounded by the
  # CLI's own 128000 ceiling and floored at 8192.
  # Keep this in lockstep with CLAUDE_CODE_INPUT_FLOOR / MIN_SAFE_OUTPUT /
  # CLI_MAX_OUTPUT_TOKENS in providers_resolve.py: the resolver bakes these
  # numbers into the .env, and this block is the last line of defence for a
  # stale or hand-edited one.
  local _cma_in_floor="${CMA_INPUT_FLOOR:-160000}" _cma_cap=""
  if [ -n "$_cma_octx" ]; then
    _cma_cap=$(( _cma_octx - _cma_in_floor ))
    if [ "$_cma_cap" -gt 128000 ]; then _cma_cap=128000; fi
    if [ "$_cma_cap" -lt 8192 ]; then _cma_cap=8192; fi
    if [ -z "$_cma_out" ] || [ "$_cma_out" -gt "$_cma_cap" ]; then _cma_out="$_cma_cap"; fi
  elif [ -n "$_cma_out" ] && [ "$_cma_out" -gt 128000 ]; then
    _cma_out=128000
  fi
  if [ -n "$_cma_out" ]; then
    export CLAUDE_CODE_MAX_OUTPUT_TOKENS="$_cma_out"
  fi
  # Input half, computed from what the output half actually reserved so the two
  # can never sum past the context. Clamped to the auto-compact cap, and
  # exported for every known context — including the >cap ones the old gate
  # silently skipped. This also closes the 200K-270K "dead zone", where a real
  # window sat above the cap yet below cap+output and so got no guard at all.
  #
  # TOOL-SCHEMA BUDGET (live defect 2026-07-26, openrouter3): the old
  # co-derivation window = context - output pretended the request is only
  # text + output. The endpoint counts tools too — the provider's own 400
  # named it: "maximum context length is 262144 … you requested about 371727
  # tokens (199347 of text input, 70236 of tool input, 102144 in the output)".
  # With window = 262144 - 102144 = 160000 the compact trigger sat at ~147000,
  # and 147000 + 70236 tools + 102144 output = 319380 > 262144 — the endpoint
  # rejected BEFORE compaction could ever help, on the FIRST request. The
  # trigger must reserve for the tool payload as well:
  #   window = context - output - CMA_TOOL_TOKEN_BUDGET (default 80000).
  # BE EXACT ABOUT WHICH DIRECTION IS DANGEROUS — the earlier note here had it
  # backwards. An UNDERestimate does NOT merely "compact earlier": because the
  # output cap is derived as ctx - min_win - budget, too small a budget INFLATES
  # the output cap, and the request then overflows and the launch dies with a
  # 400. Measured live 2026-07-27 on a host with 227 enabled plugins: real tool
  # input 158112 against this 80000 default gave
  #   46536 text + 158112 tools + 62144 output = 266792  on a 262144 window.
  # Note further that 158112 + 120000 (min window) already exceeds 262144, so on
  # such a host NO output cap makes a 262144-context provider fit: the enabled
  # plugin surface has to shrink, or a wider-context provider must be used
  # (nvidia 1000000 and xiaomi 1048576 fit it comfortably). Override per host
  # via CMA_TOOL_TOKEN_BUDGET in the provider env or the shell. A context too
  # small to reserve the budget yields no window at all: that provider cannot
  # serve Claude Code's tool prefix regardless, and the launch must fail
  # loudly upstream (the proof's context-inadequate class) rather than be
  # lied to by a guard that cannot hold.
  if [ -n "$_cma_octx" ]; then
    local _cma_win="$_cma_octx" _cma_tool_budget="${CMA_TOOL_TOKEN_BUDGET:-80000}"
    local _cma_min_win="${CMA_MIN_COMPACT_WINDOW:-120000}"
    if [ -n "$_cma_out" ]; then _cma_win=$(( _cma_octx - _cma_out )); fi
    _cma_win=$(( _cma_win - _cma_tool_budget ))
    # Compression-loop guard: if the window is below the minimum viable size,
    # Claude Code triggers compaction on every request (system prompt + tool
    # schemas alone exceed the window), enters an infinite compression loop,
    # and never gets any work done. Raise the window by reducing the output
    # cap when possible, rather than exporting a window that cannot hold the
    # static overhead.
    if [ "$_cma_win" -lt "$_cma_min_win" ] && [ -n "$_cma_out" ] && [ "$_cma_out" -gt 8192 ]; then
      local _cma_new_out=$(( _cma_octx - _cma_min_win - _cma_tool_budget ))
      if [ "$_cma_new_out" -ge 8192 ]; then
        _cma_out="$_cma_new_out"
        _cma_win="$_cma_min_win"
        export CLAUDE_CODE_MAX_OUTPUT_TOKENS="$_cma_out"
      fi
    fi
    if [ "$_cma_win" -gt "$_cma_compact_cap" ]; then _cma_win="$_cma_compact_cap"; fi
    # Autocompact thrashing guard (v1.26.8): the raw window above consumes every
    # token the model can hold (text + tools + output = context). That leaves
    # zero headroom for the compacted summary itself, so after Claude Code
    # compacts the conversation the next large file read or tool output can
    # refill the context to the limit within a few turns — the exact "Autocompact
    # is thrashing" failure. Reserve a safety margin from the window so compaction
    # fires earlier and the post-compact context has meaningful breathing room.
    # The margin is applied ONLY when the provider can afford it without dropping
    # below the minimum viable window; tight providers keep their existing window
    # rather than trade one failure mode for another.
    local _cma_safety_margin="${CMA_AUTO_COMPACT_SAFETY_MARGIN:-24000}"
    case "$_cma_safety_margin" in
      ''|0|*[!0-9]*) _cma_safety_margin=0 ;;
    esac
    if [ "$_cma_safety_margin" -gt 0 ] && [ "$_cma_win" -gt "$_cma_min_win" ]; then
      local _cma_max_margin=$(( _cma_win - _cma_min_win ))
      if [ "$_cma_safety_margin" -gt "$_cma_max_margin" ]; then
        _cma_safety_margin="$_cma_max_margin"
      fi
      _cma_win=$(( _cma_win - _cma_safety_margin ))
    fi
    if [ "$_cma_win" -gt 0 ]; then
      export CLAUDE_CODE_AUTO_COMPACT_WINDOW="$_cma_win"
    fi
  fi
  # --- cma-token-guards:end ---
  # Sync .claude.json projects/session index across ALL accounts and providers
  # so sessions created under any alias are visible from every other alias.
  # Pull merged state before launch; push post-session state after exit.
  if [[ -x "$HOME/.local/bin/claude-sync-state" ]]; then
    "$HOME/.local/bin/claude-sync-state" pull "$CLAUDE_CONFIG_DIR" 2>/dev/null || true
  fi
  # _cma_session_flags (v1.17.0): per-project session resolution applies to
  # BOTH transports — previously the flags block lived only in the native
  # branch, so every router alias (kimi-*, poe, openrouter, …) always opened
  # a FRESH session and could never see the project session another alias
  # left behind. It also now covers conversation args: `alias -p "…"` used to
  # skip resolution entirely (verbatim-args rule) and start a new session
  # every time. Explicit session selectors and non-conversation subcommands
  # are always left verbatim.
  local _cma_psf=""
  if [[ -x "$HOME/.local/bin/claude-session" ]]; then
    if [[ $# -eq 0 ]]; then
      # TRIM providers skip the stored session flags here too: `flags` emits
      # `--resume <id> …` for an existing project session, which drags the
      # synced history into the INTERACTIVE path just like the auto-resume
      # below does for conversation args (live issue 2026-07-22 — both seams
      # must stay history-free or a local model's window overflows).
      if [[ "${CMA_PROVIDER_TRIM:-}" != "bare" ]]; then
        _cma_psf="$("$HOME/.local/bin/claude-session" flags "$CLAUDE_CONFIG_DIR" 2>/dev/null || true)"
      fi
      "$HOME/.local/bin/claude-session" hint "$CMA_PROVIDER_ID" 2>/dev/null || true
      eval "set -- $_cma_psf"
      # Auto-apply this provider alias's color to the session (idempotent).
      "$HOME/.local/bin/claude-session" apply-color "$CLAUDE_CONFIG_DIR" "$CMA_PROVIDER_ID" 2>/dev/null || true
      _cma_pcolor=1
    else
      case "$1" in
        --resume|--session-id|--continue|--fork-session|-c) ;;
        agents|mcp|export|doctor|install|update|config|plugin|setup|acp|server|web|provider) ;;
        *)
          # existing-id (NOT latest-id): latest-id falls back to the
          # deterministic UUID for never-used projects, and injecting --resume
          # with a session that was never created fails hard ("No conversation
          # found with session ID"). Inject only for a session that EXISTS.
          # TRIM providers (CMA_PROVIDER_TRIM=bare) SKIP the auto-resume: a
          # fresh session per launch keeps the synced session history out of
          # the request (live issue 2026-07-22: a 229,376-token local-model
          # window refused every helixagent launch under ~330k tokens of
          # resumed history — history must not ride along by default).
          if [[ "${CMA_PROVIDER_TRIM:-}" != "bare" ]]; then
            _cma_psf="$("$HOME/.local/bin/claude-session" existing-id "$CLAUDE_CONFIG_DIR" 2>/dev/null || true)"
            [[ -n "$_cma_psf" ]] && set -- --resume "$_cma_psf" "$@"
          fi
          ;;
      esac
    fi
  fi
  # TRIM providers launch MINIMAL: --bare skips the hook/plugin/MCP/CLAUDE.md
  # surface (~110k tokens of fixed tool schemas on a plugin-heavy host) so a
  # session actually fits a local model's context window. Conversation
  # launches only — non-conversation subcommands are left untouched.
  if [[ "${CMA_PROVIDER_TRIM:-}" == "bare" ]]; then
    case "${1:-}" in
      agents|mcp|export|doctor|install|update|config|plugin|setup|acp|server|web|provider) ;;
      *) set -- --bare "$@" ;;
    esac
  fi
  local rc
  local _proxy_pid=""
  # Model + tier maps for BOTH transports (live defect 2026-07-26, Claude Code
  # 2.1.220): these used to be exported only in the native branch below, so a
  # ROUTER-transport alias launched with no ANTHROPIC_MODEL and no tier maps.
  # 2.1.220 then resolves the tiers client-side — the fast/compact tier to
  # "Fable 5", which the binary reports as CURRENTLY UNAVAILABLE ("Claude
  # Fable 5 is currently unavailable. Please use Opus 4.8 or another available
  # model."). Auto-compaction runs on that fast tier, so on the first session
  # whose context crosses the compact trigger the compact call itself fails
  # client-side: the context is never freed, compaction retries forever, and
  # the alias is unusable — exactly the operator-reported compact loop, with
  # ZERO requests reaching the gateway (verified: no /v1/messages in the
  # per-alias service.log during the loop). Mapping every tier to the
  # provider's real serving model makes compact/fast/background calls
  # addressable; the gateway substitutes the route model regardless of the
  # requested id (proven: bogus ids and literal claude-* ids both get routed
  # and answered), so these exports change only the CLIENT-side resolution,
  # never the upstream model.
  export ANTHROPIC_MODEL="$CMA_PROVIDER_MODEL"
  [[ -n "${CMA_PROVIDER_FAST_MODEL:-}" ]] && export ANTHROPIC_SMALL_FAST_MODEL="$CMA_PROVIDER_FAST_MODEL"
  # ...and the REAL context size with it: an id Claude's table does not know
  # makes its context accounting fall back to a tiny default window, against
  # which the system+tool prefix alone overflows — "Prompt is too long" on a
  # 20-character prompt, or the same compact-retry loop on anything larger
  # (both reproduced live 2026-07-26 against 2.1.220 with ANTHROPIC_MODEL set
  # and this unset).
  [[ -n "${CMA_PROVIDER_CONTEXT_LIMIT:-}" ]] && export CLAUDE_CODE_MAX_CONTEXT_TOKENS="$CMA_PROVIDER_CONTEXT_LIMIT"
  export ANTHROPIC_DEFAULT_OPUS_MODEL="$CMA_PROVIDER_MODEL"
  export ANTHROPIC_DEFAULT_SONNET_MODEL="$CMA_PROVIDER_MODEL"
  export ANTHROPIC_DEFAULT_HAIKU_MODEL="${CMA_PROVIDER_FAST_MODEL:-$CMA_PROVIDER_MODEL}"
  export ANTHROPIC_DEFAULT_FABLE_MODEL="$CMA_PROVIDER_MODEL"
  if [[ "${CMA_PROVIDER_TRANSPORT:-native}" == "router" ]]; then
    # Resolve OUR router by its stable install identity, NOT by PATH order
    # (live issue 2026-07-22, §11.4.111 resolve-by-stable-name): the npm
    # @musistudio/claude-code-router also installs a `ccr` (nvm's bin dir
    # precedes ~/.local/bin on PATH) whose --help carries the same
    # "ccr start" / "ccr serve" fingerprint — it passes the identity gate
    # below — but has NO `restart` subcommand. Bare PATH resolution picked
    # it, every route-apply failed exactly like a stale bundled build, and
    # the self-heal rebuild (which repairs the BUNDLED binary) could never
    # fix it: a rebuild cannot fix PATH shadowing. claude-ccr-build installs
    # the bundled router at $HOME/.local/bin/ccr; that symlink IS the stable
    # identity (same idiom as claude-session above). CMA_CCR_BIN overrides
    # for tests/power users; PATH is the LAST resort, only when the bundled
    # install is absent.
    local _ccr="${CMA_CCR_BIN:-$HOME/.local/bin/ccr}"
    [[ -x "$_ccr" ]] || _ccr="$(command -v ccr 2>/dev/null || true)"
    if [[ -z "$_ccr" ]]; then
      printf 'claude-providers: provider %s needs claude-code-router (the `ccr` gateway).\n  Build the bundled Go router: claude-ccr-build\n' "$id" >&2
      return 127
    fi
    # Identity check: the bundled Go router MUST advertise `ccr restart` in its
    # --help. `ccr start`/`ccr serve` are CARRIER matches — the npm
    # @musistudio/claude-code-router also prints them — and the `restart`
    # subcommand is exactly what the npm build lacks and what makes route-apply
    # work (§11.4.201(7)(a) match STRUCTURE, not a substring a carrier also
    # carries). A binary at the stable install path that lacks it is STALE (built
    # before `restart` existed); trigger a rebuild. A binary found via PATH
    # fallback that lacks it is NOT ours — refuse cleanly (audit I3, 2026-07-23).
    local _ccr_help; _ccr_help="$("$_ccr" --help 2>&1 | head -20)"
    case "$_ccr_help" in
      *"ccr restart"*) ;;
      *)
        if [[ "$_ccr" == "$HOME/.local/bin/ccr" ]] && command -v claude-ccr-build >/dev/null 2>&1; then
          command -v cma_log >/dev/null 2>&1 \
            && cma_log "bundled ccr lacks 'ccr restart' in --help — rebuilding via claude-ccr-build …" \
            || printf 'claude-providers: bundled ccr lacks the required "restart" subcommand — rebuilding …\n' >&2
          claude-ccr-build >/dev/null 2>&1 || true
          _ccr_help="$("$_ccr" --help 2>&1 | head -20)"
          case "$_ccr_help" in
            *"ccr restart"*) ;; # OK after rebuild
            *)
              printf 'claude-providers: the bundled ccr at %s still lacks the "restart" subcommand after a rebuild.\n  Rebuild manually and retry: claude-ccr-build\n' "$_ccr" >&2
              return 127 ;;
          esac
        else
          printf 'claude-providers: resolved ccr (%s) is not the bundled claude-code-router.\n  Its --help does not show the "ccr restart" subcommand that the bundled Go router has.\n  Fix: claude-ccr-build   (builds and installs the bundled router at %s)\n  If an EARLIER PATH ccr shadows the bundled one, remove it:\n    npm rm -g @musistudio/claude-code-router\n' "$_ccr" "$HOME/.local/bin/ccr" >&2
          return 127
        fi
        ;;
    esac
    # Upsert THIS provider into ccr config with the live key (regenerated each
    # launch, chmod 600 — never stored by the toolkit), set it as the active
    # route, then launch through ccr.
    #
    # Per-alias port isolation (Defect 3 architecture fix): every router-type
    # provider alias gets its OWN ccr gateway instance on a unique port, so
    # concurrent aliases never compete for one config.json and no alias
    # silently inherits another's route.
    #   - CMA_CCR_PORT in the provider's .env assigns a pinned port.
    #   - When unset, we allocate a unique port deterministically from the
    #     provider id (base_port + hash), so the same alias always gets the
    #     same port and its own ccr instance survives across launches.
    #   - Per-alias config lives under ~/.claude-code-router/<provider-id>/
    #     so each alias has its own CCR_HOME with its own pidfile, config.json,
    #     and service.log — fully isolated from every other alias.
    local _ccr_port="${CMA_CCR_PORT:-}"
    # The hash is needed for BOTH ports, so compute it unconditionally: two
    # disjoint 500-port spaces are derived from it — gateway [3460,3959] and
    # management [3960,4459]. (Was 100-port spaces [3460,3559]/[3560,3659]:
    # with ~50 router aliases a birthday collision was not theoretical but
    # LIVE — xiaomi and opencode2 both hashed to 3519, the second child died
    # on bind, a foreign /health answer falsely proved it ready (fixed in the
    # submodule's waitForReady the same day), and the launch fell back to the
    # shared default ports. 500 slots per space make a collision ~25x rarer;
    # a surviving collision now fails LOUDLY (rc=78) instead of silently
    # degrading.)
    local _ccr_hash=0 _ccr_c _ccr_i=0
    while (( _ccr_i < ${#CMA_PROVIDER_ID} )); do
      _ccr_c="$(printf '%d' "'${CMA_PROVIDER_ID:_ccr_i:1}")"; _ccr_hash=$(( (_ccr_hash * 31 + _ccr_c) & 0x7FFFFFFF )); _ccr_i=$((_ccr_i + 1))
    done
    if [[ -z "$_ccr_port" ]]; then
      # Deterministic port from the provider name: hash the id into a port
      # offset from base 3460, bounded to [3460, 3959] (500 ports).
      _ccr_port=$(( 3460 + (_ccr_hash % 500) ))
    fi
    # Per-alias MANAGEMENT port (live defect 2026-07-25): the gateway port was
    # isolated per alias but the management port was left at ccr's default
    # 3458 for EVERY alias, so exactly ONE per-alias gateway could be up at a
    # time — every second alias's `ccr restart` child died with
    # "start management interface: listen on 127.0.0.1:3458: bind: address
    # already in use" and the launch refused with rc=78 (live-captured on
    # sarvam: 4 child starts, 4 bind failures, "did not become ready within
    # 15s"). Worse, the child's gateway socket binds BEFORE the management
    # bind fails, so waitForReady could WIN the race against the dying child —
    # a launch that "succeeded" against a gateway that was already exiting.
    # CMA_CCR_MGMT_PORT in the provider's .env pins it; otherwise derive from
    # the same hash in the disjoint [3960,4459] space.
    local _ccr_mgmt_port="${CMA_CCR_MGMT_PORT:-$(( 3960 + (_ccr_hash % 500) ))}"
    local _ccr_dir="$HOME/.claude-code-router"
    # Per-alias config isolation: each router-type alias gets its OWN
    # CCR_HOME directory so its pidfile (service.json), config.json, and
    # service.log live under ~/.claude-code-router/<provider-id>/ instead
    # of sharing the global ~/.claude-code-router/. This is load-bearing
    # for concurrent aliases: a `ccr restart` for alias A must never see
    # alias B's pidfile and kill its gateway. CCR_HOME is the Go router's
    # override for config.Dir() (added for this fix).
    local _ccr_home="$_ccr_dir/${CMA_PROVIDER_ID}"
    local cfg="$_ccr_home/config.json" base="$CMA_PROVIDER_BASE_URL"
    # Self-reference guard: when THIS provider's base_url IS the ccr gateway
    # itself, there is no upstream to route to — upserting a provider whose
    # api_base_url is ccr registers a ccr->ccr self-loop.
    #
    # This used to SKIP the upsert+restart and launch anyway, justified by
    # "under ccr v3.0.6 the live route is app_config (config.json is not
    # re-imported on restart), so the write is inert-for-routing". That claim
    # described the RETIRED JS router and is INVERTED for the Go router that now
    # serves every alias. The Go source documents the opposite —
    # submodules/claude-code-router/cmd/ccr/service.go, cmdRestart: the toolkit
    # "rewrites ~/.claude-code-router/config.json before every provider-alias
    # launch and then runs `ccr restart` to make that rewrite take effect."
    # Post-ATM-870 (`a6a24e0`) the mechanism is richer than that quote: the
    # running gateway applies a validated hot-reload IN PLACE via
    # `gw.SwapConfig` (atomic pointer swap; /health, /ready and routing follow
    # it per-request — only the startup-built outbound proxy client and
    # in-flight request snapshots do not follow). `ccr restart` nonetheless
    # stays on this path: it is the DETERMINISTIC apply-point — the swap's
    # timing is not observable from outside the process, so only the bounce
    # gives the launch a provable receipt that the route it wrote is the
    # route being served.
    #
    # So config.json IS the live route (once restarted), and skipping the
    # rewrite does not make the launch inert — it makes it INHERIT whichever
    # provider the gateway last served. That is exactly how `helixagent` earned
    # a `verified` badge on a turn served by `deepseek`: 157,419 tokens through
    # a nominally 24,576-token alias, with no `helixagent` provider present in
    # ccr's config at all. The verdict measured whoever ran last.
    #
    # There is no honest third state, so REFUSE. A ccr-self base cannot be
    # routed, and inheriting a foreign route is a silent wrong-model launch.
    # The provider must be pointed at its REAL backing endpoint (for the
    # HelixAgent facade that is the HelixLLM server itself, not the ccr gateway
    # standing in front of it).
    # _cma_is_ccr_gateway is emitted into this same alias file (see
    # _cma_emit_ccr_gateway_guard) — ONE definition shared with lib.sh and
    # providers-verify.sh, so the launch gate and the verify gate cannot drift.
    if _cma_is_ccr_gateway "$base"; then
      printf 'claude-providers: refusing to launch %s — its base_url (%s) IS the ccr gateway itself.\n' "$id" "$base" >&2
      printf '  A provider cannot route through the router it *is*. Skipping the route write (the old behaviour)\n  silently inherited whatever provider the gateway last served: the wrong model, with no error.\n' >&2
      printf '  Repoint %s at its real backing endpoint (its pins file / CMA_PROVIDER_BASE_URL) and re-run:\n    claude-providers sync\n' "$id" >&2
      return 78
    fi
    # Create the per-alias config dir + config with restrictive perms from the
    # start: this file will hold the live API key, so it must never be
    # group/world readable, even transiently or if a later jq rewrite fails.
    ( umask 077; mkdir -p "$_ccr_home"
      [[ -f "$cfg" ]] || echo '{"Providers":[],"Router":{}}' > "$cfg" )
    chmod 600 "$cfg" 2>/dev/null || true
    case "$base" in
      */chat/completions|*/v1beta/models/|*/v1beta/models) ;;
      *) base="${base%/}/chat/completions" ;;
    esac
    # Preserve the original CMA_PROVIDER_BASE_URL for the fossil marker.
    # `base` is mutated above (appends /chat/completions) but the fossil
    # marker must record the REAL backing endpoint, not the ephemeral proxy
    # address. RC4 (2026-07-27): the fix was to capture $CMA_PROVIDER_BASE_URL
    # BEFORE the case statement mutates it.
    local _real_base="$CMA_PROVIDER_BASE_URL" _eph_base=""
    local _eph_marker="$HOME/.claude-code-router/.cma-ephemeral.json"
    local _eph_lock="${_eph_marker}.lock"
    local _prior_default="" _prior_background=""
    local _wrote_default="" _wrote_background=""
    # fd slots for the two launch locks below, filled by bash's dynamic fd
    # allocation (`exec {var}>>FILE`). Declared here so the nested lock/unlock
    # helpers assign into THIS scope rather than leaking a global into the
    # operator's interactive shell.
    local _cma_eph_fd="" _cma_cfg_fd=""
    # Mutual exclusion for every read-modify-write touching $_eph_marker below
    # (reap-on-start here, add-on-launch further down, delete-on-exit inside
    # _cma_ccr_unfossilise). Two CONCURRENT cma_run_provider launches both
    # touch this one file; without a lock the classic lost update is live:
    # launch A reads the marker, adds its own key, and mv's the result in;
    # launch B — already holding a snapshot read from BEFORE A's write —
    # computes ITS OWN add against that stale snapshot and mv's it in too,
    # silently overwriting the whole file and dropping A's entry (the entry
    # A's own exit repair needs to prove, via CAS, that it still owns the
    # route it wrote). flock is per-open-file-description and released by the
    # KERNEL the instant the holding process dies (no stale-lock recovery is
    # needed here the way the mkdir-based _cma_alias_lock_* fallback
    # elsewhere in this file requires for its non-flock backend); an absent
    # `flock` binary (no macOS) degrades to the pre-existing UNLOCKED
    # behaviour rather than blocking a launch — consistent with this whole
    # section's best-effort discipline (a missing `jq` is handled the same
    # way, one line below).
    _cma_eph_lock() {
      command -v flock >/dev/null 2>&1 || return 0
      # The fd is DYNAMICALLY allocated (`exec {var}>>FILE`, bash >= 4.1 /
      # zsh): the shell picks a guaranteed-free fd and stores the number in
      # _cma_eph_fd. A HARDCODED fd number here was the defect, twice over:
      #   (a) `exec 9>>FILE 2>/dev/null` — `exec` without a command applies
      #       EVERY redirection on the line to the CURRENT SHELL permanently,
      #       so one provider launch silenced the interactive shell's stderr
      #       for the rest of its life (the original field failure).
      #   (b) `{ exec 9>>FILE; } 2>/dev/null` — the "fix" for (a), and itself
      #       a silent break: hardcoded LOW fds (9/10) collide with the
      #       shell's OWN redirection bookkeeping (bash saves/restores fds
      #       around compound-command redirections and command substitutions
      #       onto low free fds), so the fd the inner exec opened did not
      #       survive the group — proven live on bash 5.2.37: the very next
      #       `flock -w 5 9` failed "Bad file descriptor" (hidden by the
      #       group's own 2>/dev/null), and EVERY critical section below ran
      #       UNLOCKED while claiming mutual exclusion.
      # Dynamic allocation avoids both: no hardcoded number to collide, no
      # stderr redirection to leak. It only ever runs where `flock` exists
      # (the guard above), which is exactly the set of platforms where the
      # lock can exist at all — macOS degrades to the documented unlocked
      # best-effort path before reaching this line.
      exec {_cma_eph_fd}>>"$_eph_lock" || return 0
      # BOUNDED wait. Defensive hardening carried over from an earlier
      # independent review, NOT a fix for the reported exit-hang (that was
      # traced to the launch itself, and this lock/unlock pair provably
      # completes). An unbounded flock can never time out while any process
      # holds the lock, which on an interactive path is a latent stall by
      # construction; the guarded critical section is a tiny marker
      # read-modify-write, so a short bound is ample and a timeout degrades
      # to the same unlocked best-effort path this section already takes
      # when `flock` is absent entirely (macOS).
      # On timeout, SAY SO (§11.4.201(5): a guard reports its resolved
      # evidence). Swallowing it discards the acquired-vs-timed-out
      # distinction, leaving a real contention event undiagnosable.
      flock -w 5 "$_cma_eph_fd" 2>/dev/null || {
        command -v cma_log >/dev/null 2>&1 \
          && cma_log "eph-lock: 5s timeout — proceeding unlocked (best-effort)"
        true
      }
      return 0
    }
    _cma_eph_unlock() {
      [[ -n "$_cma_eph_fd" ]] || return 0
      flock -u "$_cma_eph_fd" 2>/dev/null || true
      exec {_cma_eph_fd}>&- || true
      _cma_eph_fd=""
      return 0
    }
    # Mutual exclusion for every read-modify-write touching THIS alias's
    # config.json below — the stale-fossil reap, the main route upsert, and
    # _cma_ccr_unfossilise. Two CONCURRENT cma_run_provider launches of the
    # SAME provider id both touch the same per-alias $cfg; without a lock the
    # classic lost update is live: launch A rewrites config.json with provider
    # route A, launch B — already holding a snapshot read BEFORE A's write —
    # rewrites it with provider route B, silently dropping A's entire config.
    # This is the race fixed by this lock.
    _cma_cfg_lock() {
      local _lock="$1.lock"
      command -v flock >/dev/null 2>&1 || return 0
      # Dynamic fd allocation for the same reason as _cma_eph_lock above:
      # a hardcoded `exec 10>>FILE` collides with the shell's redirection
      # save slots (live-proven: "flock: 10: Bad file descriptor", lock
      # silently never held), and any 2>/dev/null ON the exec line itself
      # would silence this interactive shell's stderr permanently.
      exec {_cma_cfg_fd}>>"$_lock" || return 0
      flock -w 5 "$_cma_cfg_fd" 2>/dev/null || {
        command -v cma_log >/dev/null 2>&1 \
          && cma_log "cfg-lock: 5s timeout on ${_lock} — proceeding unlocked (best-effort)"
        true
      }
      return 0
    }
    _cma_cfg_unlock() {
      [[ -n "$_cma_cfg_fd" ]] || return 0
      flock -u "$_cma_cfg_fd" 2>/dev/null || true
      exec {_cma_cfg_fd}>&- || true
      _cma_cfg_fd=""
      return 0
    }
    if command -v jq >/dev/null 2>&1; then
      _prior_default="$(jq -r '.Router.default // ""' "$cfg" 2>/dev/null || printf '')"
      _prior_background="$(jq -r '.Router.background // ""' "$cfg" 2>/dev/null || printf '')"
      # (2) stale-fossil reap. Entirely best-effort: any failure here must never
      # block a launch, so every step is guarded and the loop simply moves on.
      if [[ -s "$_eph_marker" ]]; then
        _cma_eph_lock
        local _rv_dead="[]" _rv_n _rv_pid _rv_tmp
        # `< <(jq …)` (process substitution) feeding a `while IFS= read -r`,
        # NOT `for x in $(jq …)` — an unquoted command substitution word-
        # splits on IFS, so a hypothetical whitespace-bearing provider id
        # would silently fan out into multiple bogus keys. NOT a trailing
        # `jq … | while …` pipe either: bash runs the LAST stage of a pipeline
        # in a subshell, so `_rv_dead` accumulated inside such a loop would
        # vanish the moment the loop exits and this reap would never see any
        # dead entry. Process substitution keeps the loop in THIS shell while
        # still reading one whole line at a time.
        while IFS= read -r _rv_n; do
          [[ -n "$_rv_n" ]] || continue
          _rv_pid="$(jq -r --arg k "$_rv_n" '.[$k].pid // 0' "$_eph_marker" 2>/dev/null || printf '0')"
          # Liveness PROVEN, never assumed — a live owner keeps its address.
          # Conservative-by-construction on PID reuse: if the ORIGINAL owner
          # died and the kernel later hands its pid to some UNRELATED later
          # process, `kill -0` reads that pid as alive, so this entry is kept
          # and NOT reaped this cycle. That is the SAFE direction — the worst
          # outcome is one stale fossil surviving an extra reap cycle, never a
          # live owner's address being ripped out from under it — and it
          # self-heals the next time the SAME provider launches: CAS-1 in
          # _cma_ccr_unfossilise (`_u_addr_now == _u_eph`) still fires on the
          # marker's own record, and a later reap catches it once the reused
          # pid itself is gone too.
          if [[ "$_rv_pid" != "0" ]] && kill -0 "$_rv_pid" 2>/dev/null; then continue; fi
          _rv_dead="$(jq -c --arg k "$_rv_n" '. + [$k]' <<<"$_rv_dead" 2>/dev/null || printf '%s' "$_rv_dead")"
        done < <(jq -r 'keys[]?' "$_eph_marker" 2>/dev/null)
        if [[ "$_rv_dead" != "[]" ]]; then
          _rv_tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX" 2>/dev/null)" && chmod 600 "$_rv_tmp" 2>/dev/null
          _cma_cfg_lock "$cfg"
          if [[ -n "$_rv_tmp" ]] && jq --argjson dead "$_rv_dead" --slurpfile mk "$_eph_marker" '
                .Providers = [ .Providers[]? as $p
                  | ($mk[0][$p.name] // null) as $m
                  | if ($m != null) and ([$p.name] | inside($dead)) and ($p.api_base_url == ($m.eph // ""))
                      and (($m.real // "") != "")
                    then $p + {api_base_url: $m.real} else $p end ]
              ' "$cfg" >| "$_rv_tmp" 2>/dev/null && [[ -s "$_rv_tmp" ]]; then
            command mv -f "$_rv_tmp" "$cfg" 2>/dev/null && chmod 600 "$cfg" 2>/dev/null
            command -v cma_log >/dev/null 2>&1 && cma_log "reaped stale cma-proxy fossil(s) from ccr config: $_rv_dead" || true
          else
            [[ -n "$_rv_tmp" ]] && rm -f "$_rv_tmp"
          fi
          _cma_cfg_unlock
          _rv_tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX" 2>/dev/null)" && chmod 600 "$_rv_tmp" 2>/dev/null
          if [[ -n "$_rv_tmp" ]] && jq --argjson dead "$_rv_dead" 'delpaths([$dead[] | [.]])' \
                "$_eph_marker" >| "$_rv_tmp" 2>/dev/null && [[ -s "$_rv_tmp" ]]; then
            command mv -f "$_rv_tmp" "$_eph_marker" 2>/dev/null
          else
            [[ -n "$_rv_tmp" ]] && rm -f "$_rv_tmp"
          fi
        fi
        _cma_eph_unlock
      fi
    fi
    # (1) Exit repair. Defined here (indented — a `}` at column 0 would end the
    # function body for _cma_alias_carryover's legacy scanner) so it travels with
    # this body into the emitted, self-contained alias file. Its inputs arrive as
    # positional args, with ONE deliberate exception: the resolved router binary
    # is read from the enclosing `$_ccr` via bash dynamic scoping rather than
    # being passed in. That is not laziness — test_ccr_conformance.sh derives the
    # REQUIRED router-subcommand set by scanning this file for `"$_ccr" <word>` at
    # command position, so passing the binary as an argument would (a) make the
    # call site read as a bogus invocation `ccr "$_eph_marker"` and (b) hide this
    # function's REAL `"$_ccr" restart` from the very gate that exists to catch an
    # unsupported subcommand. Both call sites are inside cma_run_provider, so
    # `$_ccr` is always in scope.
    _cma_ccr_unfossilise() {
      local _u_cfg="$1" _u_n="$2" _u_eph="$3" _u_real="$4" _u_wd="$5" _u_wb="$6"
      local _u_pd="$7" _u_pb="$8" _u_marker="$9"
      [[ -n "$_u_eph" ]] || return 0          # no proxy ran => nothing fossilised
      [[ -f "$_u_cfg" ]] || return 0
      command -v jq >/dev/null 2>&1 || return 0
      _cma_cfg_lock "$_u_cfg"
      local _u_addr_now _u_def_now _u_bg_now _u_mine=0 _u_tmp
      _u_addr_now="$(jq -r --arg n "$_u_n" \
        '[.Providers[]?|select(.name==$n)|.api_base_url][0] // ""' "$_u_cfg" 2>/dev/null || printf '')"
      # CAS-1 — repair ONLY while the stored address is still the one WE wrote.
      # If a newer launch re-stamped it, that launch owns the entry and will run
      # its own repair; touching it here would corrupt a live route.
      # Every early return between _cma_cfg_lock and _cma_cfg_unlock MUST pass
      # through the unlock: this runs in the operator's INTERACTIVE shell, which
      # never dies, so the kernel never releases a leaked flock — each leaked
      # acquisition stalls every later cfg-lock on this config for the full 5s
      # budget and silently degrades it to unlocked (audit-proven 2026-07-25:
      # a CAS-1 early return held the lock for the shell's life and stacked
      # +1 leaked fd per occurrence).
      if [[ "$_u_addr_now" != "$_u_eph" ]]; then _cma_cfg_unlock; return 0; fi
      _u_def_now="$(jq -r '.Router.default // ""' "$_u_cfg" 2>/dev/null || printf '')"
      _u_bg_now="$(jq -r '.Router.background // ""' "$_u_cfg" 2>/dev/null || printf '')"
      # CAS-2 — the route is still ours only if BOTH halves are unchanged.
      [[ "$_u_def_now" == "$_u_wd" && "$_u_bg_now" == "$_u_wb" ]] && _u_mine=1
      _u_tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX" 2>/dev/null)" || { _cma_cfg_unlock; return 0; }
      chmod 600 "$_u_tmp" 2>/dev/null || true
      if jq --arg n "$_u_n" --arg eph "$_u_eph" --arg real "$_u_real" \
             --arg pd "$_u_pd" --arg pb "$_u_pb" --argjson mine "$_u_mine" '
             .Providers = [ .Providers[]?
               | if .name == $n and .api_base_url == $eph then .api_base_url = $real else . end ]
             | if ($mine == 1) and ($pd != "") then .Router.default    = $pd else . end
             | if ($mine == 1) and ($pb != "") then .Router.background = $pb else . end
           ' "$_u_cfg" >| "$_u_tmp" 2>/dev/null && [[ -s "$_u_tmp" ]]; then
        command mv -f "$_u_tmp" "$_u_cfg" 2>/dev/null && chmod 600 "$_u_cfg" 2>/dev/null
        command -v cma_log >/dev/null 2>&1 && \
          cma_log "un-fossilised ccr config for $_u_n: api_base_url ephemeral -> real (route_restored=$_u_mine)" || true
        # Bounce ONLY when the route was still ours: restarting while ANOTHER
        # launch owns the route would drop that launch's in-flight requests.
        # (Post-ATM-870 the running gateway also picks the edit up live via
        # SwapConfig; the bounce remains the deterministic, receipt-provable
        # apply-point — and here, the repair to an ephemeral address that the
        # dead proxy no longer serves, it is what makes the restore effective
        # for in-flight consumers regardless of swap timing.)
        if [[ "$_u_mine" == "1" && -n "$_ccr" && -x "$_ccr" ]]; then
          CCR_HOME="$_ccr_home" "$_ccr" restart --gateway-port "$_ccr_port" --port "$_ccr_mgmt_port" >/dev/null 2>&1 || true
        fi
      else
        rm -f "$_u_tmp"
      fi
      _cma_cfg_unlock
      # Drop our marker entry last: until here it is the crash-recovery record.
      # Locked (§11.4.180/marker-lost-update hardening): _u_marker is derived
      # from $_eph_marker by the caller and $_eph_lock is visible here via the
      # SAME bash dynamic-scoping this function already relies on for $_ccr
      # (see the comment on this function's own definition) — _cma_eph_lock /
      # _cma_eph_unlock are defined once, before this function's first call
      # site, alongside $_eph_lock's declaration.
      if [[ -n "$_u_marker" && -s "$_u_marker" ]]; then
        _cma_eph_lock
        local _u_mt; _u_mt="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX" 2>/dev/null)"
        if [[ -n "$_u_mt" ]]; then
          chmod 600 "$_u_mt" 2>/dev/null || true
          if jq --arg k "$_u_n" 'del(.[$k])' "$_u_marker" >| "$_u_mt" 2>/dev/null && [[ -s "$_u_mt" ]]; then
            command mv -f "$_u_mt" "$_u_marker" 2>/dev/null
          else
            rm -f "$_u_mt"
          fi
        fi
        _cma_eph_unlock
      fi
      return 0
    }
    # Start the Go compatibility proxy (cma-proxy) when it transforms this
    # provider: helixagent Hermes tool-call recovery, or poe/kimi/sarvam request-
    # schema fixes (e.g. Poe requires `parameters` in tool definitions; Claude
    # Code sometimes omits it). cma-proxy resolves the family key itself
    # (poe2->poe, kimi-*->kimi), so the wrapper just asks `--has-transform`. It
    # lives in the INSTALLED share dir; this wrapper is self-contained in the
    # alias file and has NO $LIB_DIR (repo-only), so resolve against SHARED_DIR
    # with lib.sh's default. (Replaces the former per-provider python proxies.)
    local _cma_proxy_dir="${SHARED_DIR:-$HOME/.claude-shared}/proxy"
    local _proxy_bin="$_cma_proxy_dir/cma-proxy"
    local _proxy_script=""
    if [[ -x "$_proxy_bin" ]] && "$_proxy_bin" --has-transform "$CMA_PROVIDER_ID" >/dev/null 2>&1; then
      _proxy_script="$_proxy_bin"
    elif [[ ! -x "$_proxy_bin" ]]; then
      # HONEST SKIP-with-reason, never a silent degrade (§11.4.69).
      # This branch did not exist: with cma-proxy absent, _proxy_script stayed
      # empty, the whole shim block was skipped WITHOUT A WORD, and the alias
      # launched against the raw endpoint. The provider then failed in exactly
      # the ways the shims exist to prevent (helixagent Hermes tool-call
      # recovery; poe/kimi/sarvam request-schema fixes) with nothing anywhere
      # saying the shims were off — from the outside, indistinguishable from a
      # shim that ran and did not help.
      #
      # stderr only (never stdout, which is the agent's channel), and only for
      # providers that actually HAVE a transform: a provider with no shim loses
      # nothing, so warning there would be a false positive (§11.4.201(1)).
      # We normally ask the binary via --has-transform, but with no binary we
      # cannot — cma_proxy_transform_family mirrors the proxy's registry
      # (prefix-matched: poe2 -> poe, kimi-k2 -> kimi) and test_cma_proxy.sh
      # asserts the two stay EQUAL in both directions.
      if cma_proxy_transform_family "$CMA_PROVIDER_ID"; then
        printf 'claude-providers: cma-proxy is NOT installed (%s) — launching %s WITHOUT its compatibility shims.\n  Tool-call/request-schema fixes for this provider are inactive; failures here are expected until it is built.\n  Fix: claude-proxy-build   (then: claude-install-verify)\n' \
          "$_proxy_bin" "$CMA_PROVIDER_ID" >&2
      fi
    fi
    if [[ -n "$_proxy_script" ]]; then
      # HelixAgent pre-flight: check HelixLLM availability and mode.
      # If HelixLLM is not running and Helix Code is installed, auto-start it
      # in claude mode (229376-token context). HelixLLM in coder mode has only
      # 24576-token context; helixagent requires claude mode's 229376 tokens.
      if [[ "$CMA_PROVIDER_ID" == helixagent* ]]; then
        # cma_log/cma_warn are lib.sh helpers. THIS BODY IS EMITTED INTO THE
        # ALIAS FILE by the heredoc below, and that file never sources lib.sh —
        # so calling them bare prints `cma_warn: command not found` and DESTROYS
        # the message. Live-proven: providers-helixagent-superpowers.txt carries
        # exactly that line where the operator should have seen the coder-mode
        # remedy. Every older call site guards with `command -v cma_log && …`,
        # but that pattern SILENTLY DROPS the text when the helper is absent,
        # which is wrong here: for this pre-flight the message IS the feature —
        # it is the only thing that tells an operator to flip HelixLLM out of
        # coder mode. So emit either way, through the helper when it exists and
        # through a plain printf when it does not.
        _hl_log()  { if command -v cma_log  >/dev/null 2>&1; then cma_log  "$1"; else printf '[cma] %s\n' "$1" >&2; fi; }
        _hl_warn() { if command -v cma_warn >/dev/null 2>&1; then cma_warn "$1"; else printf '[cma warn] %s\n' "$1" >&2; fi; }
        local _hl_url="${CMA_PROVIDER_BASE_URL%/v1}" _hl_mode=""
        local _hl_healthy=0
        if command -v curl >/dev/null 2>&1; then
          # Some HelixLLM builds expose context_limit in /health; newer ones only
          # return {"status":"ok"}. Use /health for liveness and fall back to
          # /v1/models for the serving context size (n_ctx) when needed.
          if curl -sf --max-time 3 "${_hl_url}/health" >/dev/null 2>&1; then
            _hl_healthy=1
            _hl_mode="$(curl -sf --max-time 3 "${_hl_url}/health" 2>/dev/null | grep -o '"context_limit" *: *[0-9]*' | head -1 | sed 's/.*: *//' || true)"
          fi
          if [[ -z "$_hl_mode" ]] && curl -sf --max-time 3 "${_hl_url}/v1/models" >/dev/null 2>&1; then
            _hl_healthy=1
            _hl_mode="$(curl -sf --max-time 3 "${_hl_url}/v1/models" 2>/dev/null | grep -o '"n_ctx" *: *[0-9]*' | head -1 | sed 's/.*: *//' || true)"
          fi
        fi
        # Auto-start HelixLLM if not running and Helix Code is installed.
        #
        # OPT-IN ONLY (operator mandate 2026-07-27). Booting a Helix service is
        # a heavyweight, machine-wide side effect: HelixLLM claims the single
        # GPU, and starting it in claude mode EVICTS whatever HelixCode had
        # running in coder mode. A provider alias must not do that to a host
        # merely because someone launched it. Default is therefore FALSE; set
        # CMA_HELIX_AUTOSTART=1 (or true/yes/on) to allow it. When it is not
        # enabled we still say so, and still print the exact command to run —
        # the operator keeps the information and the choice.
        local _hl_autostart="${CMA_HELIX_AUTOSTART:-0}"
        case "${_hl_autostart,,}" in
          1|true|yes|on) _hl_autostart=1 ;;
          *)             _hl_autostart=0 ;;
        esac
        if [[ "$_hl_healthy" -eq 0 && "$_hl_autostart" -ne 1 ]]; then
          _hl_warn "helixagent: HelixLLM is not answering on ${_hl_url} and auto-start is OFF by default.
  Start it yourself (it claims the GPU and evicts HelixCode's coder mode):
    helix_code/scripts/helixllm-mode.sh claude
  Or opt in for this launch:
    CMA_HELIX_AUTOSTART=1 <alias>"
        fi
        if [[ "$_hl_healthy" -eq 0 && "$_hl_autostart" -eq 1 ]]; then
          local _hl_mode_script=""
          # Find helixllm-mode.sh in common locations
          for _hl_candidate in \
            "$HOME/projects/helix_code/scripts/helixllm-mode.sh" \
            "$HOME/helix_code/scripts/helixllm-mode.sh" \
            "/run/media/milosvasic/DATA4TB/Projects/helix_code/scripts/helixllm-mode.sh" \
            "${HELIX_CODE_DIR:-}/scripts/helixllm-mode.sh"; do
            if [[ -x "$_hl_candidate" ]]; then
              _hl_mode_script="$_hl_candidate"
              break
            fi
          done
          if [[ -n "$_hl_mode_script" ]]; then
            _hl_log "helixagent: HelixLLM not running — auto-starting in claude mode via $_hl_mode_script ..."
            if "$_hl_mode_script" claude 2>&1 | tail -5 >&2; then
              # Wait for HelixLLM to become healthy (up to 120s)
              local _hl_wait=0
              while [[ "$_hl_wait" -lt 24 ]]; do
                if curl -sf --max-time 5 "${_hl_url}/health" >/dev/null 2>&1; then
                  _hl_healthy=1
                  _hl_log "helixagent: HelixLLM started successfully"
                  break
                fi
                sleep 5
                _hl_wait=$((_hl_wait + 1))
              done
              if [[ "$_hl_healthy" -eq 0 ]]; then
                _hl_warn "helixagent: HelixLLM auto-start timed out after 120s.
  The container may still be loading the model. Check:
    podman logs helixllm-coder
    $_hl_mode_script status"
              fi
            else
              _hl_warn "helixagent: HelixLLM auto-start failed.
  Fix: manually start HelixLLM:
    $_hl_mode_script claude"
            fi
          else
            _hl_warn "helixagent: HelixLLM not running and helixllm-mode.sh not found.
  Install Helix Code or start HelixLLM manually on port 18434."
          fi
        fi
        # Check for coder mode (even if running)
        if [[ "$_hl_healthy" -eq 1 && "$_hl_mode" -eq 24576 ]] 2>/dev/null; then
          _hl_warn "helixagent: HelixLLM detected in CODER MODE (context_limit=24576).
  helixagent REQUIRES CLAUDE MODE (context_limit=229376).
  The first request (~67K system+tools) will immediately exceed the limit.
  Fix on the HelixLLM host:
    helix_code/scripts/helixllm-mode.sh claude
  Then re-run the alias."
        fi
      fi
      # Port-squatter guard (live-proven 2026-07-19: `poe: FAIL tools-params`).
      # Find a genuinely free port, then confirm OUR pid owns it — never point
      # `base` at a squatter (ccr once held 3457 for 21h, silently disabling the
      # proxy so every request bypassed its shims).
      local _proxy_port=3457 _pp_try=0
      while lsof -i ":$_proxy_port" >/dev/null 2>&1 && (( _pp_try < 20 )); do
        _proxy_port=$((_proxy_port + 1)); _pp_try=$((_pp_try + 1))
      done
      # Export the upstream to the proxy child: the env file is sourced WITHOUT
      # `set -a`, so CMA_PROVIDER_BASE_URL is not otherwise inherited, and
      # cma-proxy needs it to reach the real backend (a bare --port launch would
      # fall back to its built-in default).
      # STDIO REDIRECTION IS LOAD-BEARING, not tidiness. A backgrounded daemon
      # that inherits the caller's stdout/stderr holds the WRITE END of whatever
      # pipe the caller installed. Every caller that captures a launch with
      # command substitution — verify_superpowers_tui.sh, claude-release-gate.sh
      # — reads until EOF, and EOF never arrives while the proxy is alive: the
      # capture hangs for the proxy's whole lifetime (measured: 30005ms vs 5ms,
      # both rc=0). It bites hardest on the SUCCESS path, where `timeout` has
      # already reaped its own child and can bound nothing, and it is reached
      # deterministically whenever the proxy is orphaned by the `_proxy_pid=""`
      # branch below (lsof is an undeclared dependency; absent, that branch is
      # always taken). Independently and unconditionally, cma-proxy prints a
      # startup banner to stderr, and callers apply `2>&1` to the whole
      # cma_run_provider call — so the banner lands INSIDE the captured payload
      # and breaks `jq` on captured JSON. Both go away by giving the daemon its
      # own log file and closing its stdin (mirrors the router's own precedent
      # in cmd/ccr/spawn_unix.go). $_ccr_home is in scope here and already
      # mkdir -p'd above.
      CMA_PROVIDER_BASE_URL="$CMA_PROVIDER_BASE_URL" \
        "$_proxy_bin" --provider "$CMA_PROVIDER_ID" --port "$_proxy_port" \
        >>"$_ccr_home/cma-proxy.log" 2>&1 </dev/null &
      _proxy_pid=$!
      local _waited=0
      # Wait for OUR process to be listening — not merely for the port to be busy.
      while ! lsof -a -p "$_proxy_pid" -i ":$_proxy_port" >/dev/null 2>&1 && (( _waited < 25 )); do
        kill -0 "$_proxy_pid" 2>/dev/null || break   # proxy died: stop waiting
        sleep 0.2
        _waited=$((_waited + 1))
      done
      if ! lsof -a -p "$_proxy_pid" -i ":$_proxy_port" >/dev/null 2>&1; then
        # Never point at a foreign listener. Fall back to the provider's direct
        # endpoint and say so loudly, rather than silently losing the shims.
        command -v cma_log >/dev/null 2>&1 && \
          cma_log "WARNING: cma-proxy for $CMA_PROVIDER_ID did not start on port $_proxy_port — using the direct endpoint (compat shims INACTIVE)" || true
        # REAP BEFORE CLEARING. `_proxy_pid` is the ONLY handle the exit path
        # (the `kill "$_proxy_pid"` reap further down) is guarded on, so
        # blanking it here without killing first leaks the child: it survives
        # the launch, keeps its port, and — pre-redirection — kept the caller's
        # pipe open forever. This branch is not exotic: `lsof` is an undeclared
        # dependency of this file, so on any host without it the probe ALWAYS
        # fails and this orphan is produced on EVERY proxied launch.
        if [[ -n "$_proxy_pid" ]] && kill -0 "$_proxy_pid" 2>/dev/null; then
          kill "$_proxy_pid" 2>/dev/null || true
        fi
        _proxy_pid=""
        _proxy_script=""
      fi
    fi
    if [[ -n "$_proxy_script" ]]; then
      base="http://127.0.0.1:${_proxy_port}/v1/chat/completions"
      # THE fossil-producing assignment: `base` is now an EPHEMERAL address whose
      # lifetime is this launch. Record it (and the real endpoint it replaced) so
      # both the exit repair and the next launch's stale-reap can undo it. The
      # marker is a sidecar — never a field inside config.json, which the router
      # parses.
      _eph_base="$base"
      # cma_log is a lib.sh helper; the self-contained alias file has no such
      # function, so guard the call to avoid a 'cma_log: command not found' on
      # every proxied launch.
      command -v cma_log >/dev/null 2>&1 && cma_log "started cma-proxy for $CMA_PROVIDER_ID on port $_proxy_port (pid=$_proxy_pid)" || true
    fi
    # Route write + apply. EVERY failure here is FATAL, because the failure mode
    # is silent-and-wrong: the launch below serves whatever route the gateway
    # currently holds. The old code hid both halves — the jq/mv write ran under
    # `2>/dev/null` with a bare `else rm -f` (a failed write was
    # indistinguishable from a successful one) and `ccr restart` ran under
    # `|| true` (a config written but never applied still launched, serving the
    # PREVIOUS provider's model). That is what made the helixagent facade
    # invisible for a whole release. A route we cannot prove we set is a route
    # we must not launch against.
    local _route_err=0 _route_msg=""
    if ! command -v jq >/dev/null 2>&1; then
      _route_err=1
      _route_msg="jq is not on PATH, so the ccr route cannot be written"
    else
      local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"; chmod 600 "$tmp" 2>/dev/null || true
      # Lock the config.json read-modify-write against concurrent launches of
      # the SAME provider id. Two launches that both read the config before
      # either writes it will each produce a rewrite from the same stale
      # snapshot — the second mv silently overwrites the first, and the first
      # launch's provider route is lost. The per-alias config is isolated
      # ($cfg = $_ccr_home/config.json, one per provider-id), so the lock
      # targets only this config's own file.
      _cma_cfg_lock "$cfg"
      # Pass the secret through the environment ($ENV.tok), never as a jq argv
      # argument — argv is visible in ps/proc to other local users.
      # `>|` (force-clobber), NOT `>`: cma_run_provider runs in the user's
      # interactive shell, which may have `set -o noclobber`. Plain `>` onto the
      # just-created mktemp file fails there ("cannot overwrite existing file"),
      # silently dropping the router-config update so EVERY router provider breaks.
      local _jq_err _jq_rc _mv_err _mv_rc _rst_out _rst_rc
      _jq_err="$(CMA_TOK="$token" jq --arg n "$CMA_PROVIDER_ID" --arg u "$base" \
            --arg s "$CMA_PROVIDER_MODEL" --arg f "${CMA_PROVIDER_FAST_MODEL:-$CMA_PROVIDER_MODEL}" '
          .Providers = ([{name:$n, api_base_url:$u, api_key:$ENV.CMA_TOK, models:[$s,$f],
                transformer:{use:["cleancache","streamoptions"]}}])
          | .Router.default = ($n + "," + $s)
          | .Router.background = ($n + "," + $f)
        ' "$cfg" 2>&1 >| "$tmp")"
      _jq_rc=$?
      if (( _jq_rc != 0 )) || [[ ! -s "$tmp" ]]; then
        # An empty output file is a failed rewrite too: mv-ing it would leave an
        # unparseable config behind and the gateway would keep the old route.
        rm -f "$tmp"
        _route_err=1
        _route_msg="the jq rewrite of $cfg failed (rc=$_jq_rc)${_jq_err:+: $_jq_err}"
        _cma_cfg_unlock
      else
        _mv_err="$(command mv -f "$tmp" "$cfg" 2>&1)"; _mv_rc=$?
        if (( _mv_rc != 0 )); then
          rm -f "$tmp"
          _route_err=1
          _route_msg="installing the rewritten $cfg failed (mv rc=$_mv_rc)${_mv_err:+: $_mv_err}"
          _cma_cfg_unlock
        else
          chmod 600 "$cfg" 2>/dev/null || true
          _cma_cfg_unlock
          # Remember exactly what WE wrote, so the exit repair can compare-and-swap
          # instead of clobbering a newer launch's route.
          _wrote_default="$CMA_PROVIDER_ID,$CMA_PROVIDER_MODEL"
          _wrote_background="$CMA_PROVIDER_ID,${CMA_PROVIDER_FAST_MODEL:-$CMA_PROVIDER_MODEL}"
          # Crash-recovery marker: written the moment an ephemeral address becomes
          # durable, so a launch killed before its exit repair (SIGKILL, reboot)
          # still leaves the next launch enough to reap the fossil. $$ is the
          # owning shell; the next launch reaps only when `kill -0` proves it dead.
          # Locked (marker-lost-update hardening — see _eph_lock's declaration
          # above): read-modify-write against $_eph_marker under the same
          # cross-launch mutual exclusion as the reap loop and the exit repair.
          if [[ -n "$_eph_base" ]] && command -v jq >/dev/null 2>&1; then
            _cma_eph_lock
            local _mk_tmp
            [[ -f "$_eph_marker" ]] || ( umask 077; printf '{}\n' > "$_eph_marker" )
            _mk_tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX" 2>/dev/null)" && chmod 600 "$_mk_tmp" 2>/dev/null
            if [[ -n "$_mk_tmp" ]] && jq --arg k "$CMA_PROVIDER_ID" --arg e "$_eph_base" \
                  --arg r "$_real_base" --argjson p "$$" \
                  '.[$k] = {eph:$e, real:$r, pid:$p}' "$_eph_marker" >| "$_mk_tmp" 2>/dev/null \
                  && [[ -s "$_mk_tmp" ]]; then
              command mv -f "$_mk_tmp" "$_eph_marker" 2>/dev/null && chmod 600 "$_eph_marker" 2>/dev/null
            else
              [[ -n "$_mk_tmp" ]] && rm -f "$_mk_tmp"
            fi
            _cma_eph_unlock
          fi
           # `ccr restart` is what makes the write LIVE (service.go:cmdRestart).
           # Its failure means the file is right and the gateway is still wrong —
           # the most dangerous state of all, and the one `|| true` used to hide.
           _rst_out="$(CCR_HOME="$_ccr_home" "$_ccr" restart --gateway-port "$_ccr_port" --port "$_ccr_mgmt_port" 2>&1)"; _rst_rc=$?
          if (( _rst_rc != 0 )); then
            # SELF-HEAL the commonest cause. A "Profile … not found or is
            # disabled" reply means ccr parsed 'restart' as a profile NAME — the
            # installed ccr binary is STALE: it predates the 'restart' subcommand
            # this launch depends on (a current build lists it in `ccr --help`).
            # The binary is a gitignored build artifact, so a submodule bump does
            # NOT rebuild it, and because EVERY router-transport alias hits this
            # same step, one stale ccr bricks all of them at once. Rebuild once +
            # retry (bounded: one rebuild, one retry) so a launch cannot be
            # silently refused for a condition the toolkit can fix itself; if the
            # rebuild is unavailable or does not help, fall through to the
            # self-diagnosing error below.
            case "$_rst_out" in
              *'not found or is disabled'*)
                if command -v claude-ccr-build >/dev/null 2>&1; then
                  command -v cma_log >/dev/null 2>&1 \
                    && cma_log "bundled ccr is stale (no 'restart' subcommand) — rebuilding once via claude-ccr-build …" \
                    || printf 'claude-providers: bundled ccr is stale — rebuilding it once (this may take ~30s) …\n' >&2
                  claude-ccr-build >/dev/null 2>&1 || true
                  _rst_out="$(CCR_HOME="$_ccr_home" "$_ccr" restart --gateway-port "$_ccr_port" --port "$_ccr_mgmt_port" 2>&1)"; _rst_rc=$?
                fi ;;
            esac
          fi
          if (( _rst_rc != 0 )); then
            _route_err=1
            # Single quotes, not backticks: test_ccr_conformance.sh scans lib.sh
            # for `ccr <subcommand>` invocations by splitting on shell command
            # separators — a backtick here reads as a command substitution and
            # the scanner extracts the bogus subcommand 'restart\'.
            _route_msg="'ccr restart' failed (rc=$_rst_rc), so the new route was written but never applied${_rst_out:+: $_rst_out}"
            case "$_rst_out" in
              *'not found or is disabled'*)
                _route_msg="$_route_msg
  ROOT CAUSE: the bundled 'ccr' binary is STALE — it does not recognize the 'restart' subcommand (it read 'restart' as a profile), and an automatic rebuild was unavailable or did not resolve it. Rebuild manually, then retry: claude-ccr-build (needs the Go toolchain)." ;;
            esac
          fi
        fi
      fi
    fi
    if (( _route_err )); then
      # Defensive scrub: diagnostics are echoed from tool stderr, which must
      # never be allowed to carry the live key back to the terminal.
      [[ -n "$token" ]] && _route_msg="${_route_msg//"$token"/<redacted>}"
      printf 'claude-providers: refusing to launch %s — its ccr route was NOT applied.\n  %s\n' "$id" "$_route_msg" >&2
      printf '  Launching anyway would serve whichever provider the gateway last routed to (wrong model, no error).\n' >&2
      if [[ -n "$_proxy_pid" ]]; then
        kill "$_proxy_pid" 2>/dev/null || true
        command -v cma_log >/dev/null 2>&1 && cma_log "stopped proxy for $CMA_PROVIDER_ID (pid=$_proxy_pid) after route failure" || true
      fi
      # This path can ALSO leave a fossil: the jq+mv may have succeeded and only
      # `ccr restart` failed, in which case the ephemeral address is already
      # durable. Repair here too — the proxy we just killed is now dead.
      _cma_ccr_unfossilise "$cfg" "$CMA_PROVIDER_ID" "$_eph_base" "$_real_base" \
        "$_wrote_default" "$_wrote_background" "$_prior_default" "$_prior_background" \
        "$_eph_marker"
      return 78
    fi
    CCR_HOME="$_ccr_home" "$_ccr" default-claude-code -- "$@"; rc=$?
    # Stop proxy if we started one
    if [[ -n "$_proxy_pid" ]]; then
      kill "$_proxy_pid" 2>/dev/null || true
      command -v cma_log >/dev/null 2>&1 && cma_log "stopped proxy for $CMA_PROVIDER_ID (pid=$_proxy_pid)" || true
    fi
    # The proxy is dead as of the line above, so the address written into the
    # DURABLE config now names nothing. Undo it before returning — compare-and-
    # swap, so a launch that started after ours keeps its own route untouched.
    _cma_ccr_unfossilise "$cfg" "$CMA_PROVIDER_ID" "$_eph_base" "$_real_base" \
      "$_wrote_default" "$_wrote_background" "$_prior_default" "$_prior_background" \
      "$_eph_marker"
  else
    export ANTHROPIC_BASE_URL="$CMA_PROVIDER_BASE_URL"
    export ANTHROPIC_AUTH_TOKEN="$token"
    # ANTHROPIC_MODEL + the four ANTHROPIC_DEFAULT_*_MODEL tier maps are
    # exported ABOVE for BOTH transports (v1.26.1 — the 2.1.220 compact-loop
    # fix): a tier-pinned subagent dispatch or fast-tier call never leaks a
    # literal claude-* id to a native provider endpoint (which rejects it —
    # xiaomi HTTP 400 "Unsupported model" — or silently substitutes — deepseek
    # 200), and the router transport's client-side tier resolution (fast/
    # compact = Fable 5, unavailable in 2.1.220) maps to the serving model.
    # Session flags are applied ABOVE for both transports (v1.17.0) — see
    # _cma_session_flags. CLAUDE_CODE_MAX_OUTPUT_TOKENS is exported ABOVE too,
    # before the transport branch, CLAMPED to <=128000 for BOTH transports —
    # see the _cma_out_guard/output-token-clamp block. (Was formerly
    # re-exported here as the RAW, unclamped CMA_PROVIDER_MAX_OUTPUT — the
    # origin of the "128000" fatal.) CLAUDE_CODE_AUTO_COMPACT_WINDOW caps
    # INPUT — the two are independent halves of the guard.
    "$CLAUDE_BIN" "$@"; rc=$?
  fi
  # Push post-session state back to all accounts/providers for cross-alias visibility.
  if [[ -x "$HOME/.local/bin/claude-sync-state" ]]; then
    "$HOME/.local/bin/claude-sync-state" push "$CLAUDE_CONFIG_DIR" 2>/dev/null || true
  fi
  # Colour a freshly-created session too (its jsonl exists now), so the colour is
  # in place on the next resume even on the very first launch.
  [[ "${_cma_pcolor:-}" == 1 && -x "$HOME/.local/bin/claude-session" ]] && \
    "$HOME/.local/bin/claude-session" apply-color "$CLAUDE_CONFIG_DIR" "$CMA_PROVIDER_ID" 2>/dev/null || true
  return $rc
}
CMA_PROV_BODY_EOF
}

# The provider session-refresh hook: on every interactive shell start it
# re-writes provider aliases from cache (NO network) and, when the status cache
# is older than CMA_PROVIDERS_SYNC_TTL (default 24h), kicks a detached full sync.
#
# CMA_ALIAS_LOCK_WAIT=0 is LOAD-BEARING: this runs on every shell start, so it
# must never wait on another writer. On contention each alias write is skipped
# silently and the file is left exactly as the other writer leaves it.
_cma_emit_session_hook() {
  printf '%s\n' "$CMA_ALIAS_HOOK_BEGIN"
  cat <<'HOOK'
cma_providers_session_refresh() {
  command -v claude-providers >/dev/null 2>&1 || return 0
  # No-network: re-write alias functions from the cached env files. The
  # alias-file lock is taken with a ZERO wait so a shell start can never block
  # behind a concurrent sync; a skipped refresh is harmless.
  # CMA_ALIAS_SKIP_ON_CONTENTION=1 is the ONLY opt-in to "a contended write
  # reports success". It belongs here and nowhere else: a shell start must not
  # block, and a skipped refresh is genuinely harmless because the next writer
  # re-renders the same delta from the file. Every other caller gets rc 75.
  CMA_ALIAS_LOCK_WAIT=0 CMA_ALIAS_SKIP_ON_CONTENTION=1 claude-providers list --quiet --refresh-aliases >/dev/null 2>&1 || true
  # TTL-triggered background full sync (detached; never blocks the shell).
  local ttl="${CMA_PROVIDERS_SYNC_TTL:-86400}"
  local sf="$HOME/.local/share/claude-multi-account/providers/status.json"
  if [ -f "$sf" ]; then
    local now mtime age
    now="$(date +%s)"
    mtime="$(stat -c %Y "$sf" 2>/dev/null || stat -f %m "$sf" 2>/dev/null || echo "$now")"
    age=$(( now - mtime ))
    if [ "$age" -gt "$ttl" ]; then
      ( nohup claude-providers sync >/dev/null 2>&1 & disown ) 2>/dev/null || true
    fi
  fi
}
cma_providers_session_refresh
HOOK
  printf '%s\n' "$CMA_ALIAS_HOOK_END"
}

# Which CLAUDE_BIN the render should record. Keeps the value already on disk
# when it still resolves to an executable; otherwise re-resolves (an alias file
# carrying a stale path from another host makes EVERY alias launch an empty
# command). Only replaces when the replacement is actually executable.
_cma_alias_claude_bin() {
  local src="${1:-}" cur="" exp new
  if [[ -f "$src" ]]; then
    cur="$(grep -m1 '^export CLAUDE_BIN=' "$src" 2>/dev/null || true)"
    cur="${cur#export CLAUDE_BIN=}"; cur="${cur#\"}"; cur="${cur%\"}"
  fi
  exp="${cur/#\$HOME/$HOME}"; exp="${exp/#\~/$HOME}"
  if [[ -n "$cur" && -x "$exp" ]]; then printf '%s\n' "$cur"; return 0; fi
  new="$(cma_resolve_claude_bin)"
  if [[ -n "$cur" && ! -x "${new/#\$HOME/$HOME}" ]]; then printf '%s\n' "$cur"; return 0; fi
  printf '%s\n' "$new"
}

_cma_emit_managed() {
  local cb="$1"
  printf '%s\n' "$CMA_ALIAS_MANAGED_BEGIN"
  printf '# Managed by claude-multi-account. Do not edit by hand; use\n'
  printf '# ~/.local/bin/claude-add-account to add accounts.\n'
  printf 'export CLAUDE_BIN="%s"\n' "$cb"
  printf '\n'
  _cma_emit_ccr_gateway_guard
  printf '\n'
  _cma_emit_cma_run
  printf '\n'
  _cma_emit_cma_run_provider
  printf '\n'
  _cma_emit_account_dispatch
  printf '%s\n' "$CMA_ALIAS_MANAGED_END"
}

# Everything the toolkit does NOT own, in original order: alias lines plus any
# user-added content. Strips the managed block, the hook block, and — for files
# written before the sentinels existed — the legacy header/wrapper text by
# content, including the orphaned `# Wrapper:` comment copies the old
# drop/re-append migration left behind.
_cma_alias_carryover() {
  local src="$1" region=0 hookr=0 mtrunc=0 htrunc=0
  [[ -f "$src" ]] || return 0
  # A block is only treated as a block when BOTH of its sentinels are present.
  # An unterminated BEGIN (a file truncated by something outside this toolkit)
  # would otherwise swallow every alias below it.
  if grep -qxF "$CMA_ALIAS_MANAGED_BEGIN" "$src"; then
    if grep -qxF "$CMA_ALIAS_MANAGED_END" "$src"; then region=1; else mtrunc=1; fi
  fi
  if grep -qxF "$CMA_ALIAS_HOOK_BEGIN" "$src"; then
    if grep -qxF "$CMA_ALIAS_HOOK_END" "$src"; then hookr=1; else htrunc=1; fi
  fi
  # TRUNCATION RECOVERY, stated as a property of the block rather than of its
  # current contents. A BEGIN with no END means the file was cut INSIDE the
  # block, so what survives is a PREFIX of machine-owned text — an unterminated
  # function, a half-written `case`, whatever the emitters happened to open.
  # Carrying that prefix over as "user content" re-emits it above the alias
  # lines and makes the whole file unparseable: `bash -n` fails, so the rc file
  # sourcing it aborts and EVERY alias in it is dead. That is strictly worse
  # than the truncation itself.
  #
  # The end of the salvage window is derived, not enumerated: no emitted
  # managed/hook line is an `alias` at column 0, and no emitted managed line is
  # the hook's BEGIN sentinel, so the first of those is provably outside the
  # truncated block. Everything before it goes; everything from it on is kept.
  #
  # Deriving it this way is the point. The by-content legacy rules below list
  # the wrapper functions by name, and that list SILENTLY went stale when
  # _cma_emit_ccr_gateway_guard was added to the managed block: a file cut
  # inside the new guard (the block's first function, so the likeliest cut of
  # all) carried an unterminated `case` straight into the rebuilt file. A rule
  # phrased over the block's boundary cannot go stale that way.
  awk -v mb="$CMA_ALIAS_MANAGED_BEGIN" -v me="$CMA_ALIAS_MANAGED_END" \
      -v hb="$CMA_ALIAS_HOOK_BEGIN" -v he="$CMA_ALIAS_HOOK_END" \
      -v region="$region" -v hookr="$hookr" \
      -v mtrunc="$mtrunc" -v htrunc="$htrunc" '
    $0 == mb { if (region) { m = 1 } else if (mtrunc) { t = 1 }; next }
    $0 == me { m = 0; next }
    m        { next }
    # Salvage window ends at the first line that cannot be block content.
    t && /^alias[[:space:]]/ { t = 0 }
    t && $0 == hb            { t = 0 }
    t        { next }
    $0 == hb { if (hookr) { h = 1 } else if (htrunc) { t = 1 }; next }
    $0 == he { h = 0; next }
    h        { next }
    # --- legacy (pre-sentinel) managed content -------------------------------
    # NOTE: the parens are escaped for awk ERE, where \( is a LITERAL paren, so
    # /^cma_run\(\) ?\{/ cannot match "cma_run_provider() {". (The same spelling
    # in grep BRE would be an empty capture group and WOULD match it — that bug
    # once dropped the function entirely.)
    /^cma_run\(\) ?\{/          { f = 1 }
    /^cma_run_provider\(\) ?\{/ { f = 1 }
    # An `alias` at column 0 always ends the skip: no emitted wrapper body
    # contains such a line, so this cannot swallow one, and it means a wrapper
    # left UNTERMINATED by an external truncation can never eat the alias lines
    # below it. Without this the recovery path drops exactly the data the
    # recovery exists to save.
    f && /^alias[[:space:]]/    { f = 0 }
    f { if ($0 ~ /^\}/) f = 0; next }
    /^# Managed by claude-multi-account/            { next }
    /^# ~\/\.local\/bin\/claude-add-account to add/ { next }
    /^export CLAUDE_BIN=/                           { next }
    /^# Wrapper: keeps \.claude\.json/              { next }
    /^# logged-in account\. Pulls merged state/     { next }
    /^# one before claude runs; pushes the post/    { next }
    /^# Cheap \(jq deep-merge of one/               { next }
    { print }
  ' "$src"
}

# The existing hook block, verbatim (first one only). Requires BOTH sentinels:
# an unterminated BEGIN would otherwise copy the rest of the file into the hook
# position, duplicating every alias below it.
_cma_alias_extract_hook() {
  local src="$1"
  [[ -f "$src" ]] || return 0
  grep -qxF "$CMA_ALIAS_HOOK_BEGIN" "$src" || return 0
  grep -qxF "$CMA_ALIAS_HOOK_END" "$src"   || return 0
  awk -v b="$CMA_ALIAS_HOOK_BEGIN" -v e="$CMA_ALIAS_HOOK_END" '
    $0 == b && !seen { h = 1; seen = 1 }
    h { print }
    $0 == e { h = 0 }
  ' "$src"
}

# Alias names defined in a file, sorted and unique.
_cma_alias_names() {
  [[ -f "$1" ]] || return 0
  awk -F'[ =]+' '/^[[:space:]]*alias[[:space:]]+/{print $2}' "$1" | LC_ALL=C sort -u
}

# Names of the account aliases (the `CLAUDE_CONFIG_DIR=` form) in a file,
# sorted and unique — the input to the gate's account-alias floor.
_cma_alias_account_names() {
  [[ -f "$1" ]] || return 0
  grep '^alias[[:space:]][^=]*="CLAUDE_CONFIG_DIR=' "$1" 2>/dev/null \
    | awk -F'[ =]+' '{print $2}' | LC_ALL=C sort -u || true
}

# Count of account aliases (the `CLAUDE_CONFIG_DIR=` form) in a file.
_cma_alias_account_count() {
  local n=0
  if [[ -f "$1" ]]; then
    # `grep -c` prints 0 AND exits 1 on no-match, so the || must not print too.
    n="$(grep -c '^alias[[:space:]][^=]*="CLAUDE_CONFIG_DIR=' "$1" 2>/dev/null || true)"
    [[ -n "$n" ]] || n=0
  fi
  printf '%s\n' "$n"
}

_cma_alias_mktemp() {
  local dir; dir="$(dirname "$ALIAS_FILE")"
  # Same directory as the target on purpose: the commit is a rename, which is
  # only atomic within one filesystem, and a leaked temp is then visible where
  # it matters instead of accumulating invisibly in $TMPDIR (7743 leaked
  # $TMPDIR/cma.* snapshots were found during the incident).
  mktemp "$dir/.aliases.render.XXXXXX" 2>/dev/null
}

# _cma_alias_render <src> <drop_name> <add_line> <hook_mode> <out>
#   drop_name  alias to remove ("" = none)
#   add_line   full alias line to add ("" = none); replaces an existing
#              definition of the same name IN PLACE, else is appended
#   hook_mode  keep | install
# Emits the COMPLETE file. This is the only place the file's shape is decided.
_cma_alias_render() {
  local src="$1" drop="$2" add="$3" hook="$4" out="$5"
  local carry cb
  carry="$(_cma_alias_mktemp)" || return 1

  # 1. carry over everything we do not own
  _cma_alias_carryover "$src" > "$carry"

  # 2. legacy alias migration: pre-wrapper lines invoking $CLAUDE_BIN directly
  #    are rewritten to go through cma_run (idempotent — a line already using
  #    cma_run is left alone).
  # shellcheck disable=SC2016  # $CLAUDE_BIN is literal alias-file text here
  if grep -qE '^alias[[:space:]]+[^=]+=.*CLAUDE_CONFIG_DIR=[^ ]+[[:space:]]+\\?\$CLAUDE_BIN"$' "$carry" 2>/dev/null; then
    # shellcheck disable=SC2016
    sed -E 's|(^alias[[:space:]]+[^=]+=)"(CLAUDE_CONFIG_DIR=[^ ]+)[[:space:]]+\\?\$CLAUDE_BIN"$|\1"\2 cma_run"|' \
      "$carry" > "$carry.mig" && command mv -f "$carry.mig" "$carry"
  fi

  # 3. removal delta. Skipped when the SAME name is being rewritten: that case
  #    is a replace-in-place below, which is what keeps a repeated write
  #    byte-identical instead of permuting the file's alias order (drop+append
  #    would move the rewritten alias to the end on every call, so a repeat of
  #    the same two writes never converged and the no-op guard could never fire).
  local addname=""
  if [[ -n "$add" ]]; then
    addname="$(printf '%s\n' "$add" | awk -F'[ =]+' '{print $2}')"
  fi
  if [[ -n "$drop" && "$drop" != "$addname" ]]; then
    grep -v -E "^alias[[:space:]]+${drop}=" "$carry" > "$carry.d" || true
    command mv -f "$carry.d" "$carry"
  fi

  # 4. de-duplicate alias definitions (last one wins) and apply the add delta:
  #    an existing definition of the same name is replaced at its original
  #    position; a genuinely new alias is appended. Two passes over one file.
  #    The add text goes through ENVIRON, not -v, because -v applies backslash
  #    escape processing to the value.
  CMA_ADD_NAME="$addname" CMA_ADD_LINE="$add" awk -F'[ =]+' '
    NR == FNR { if ($0 ~ /^alias[[:space:]]+/) last[$2] = FNR; next }
    {
      if ($0 ~ /^alias[[:space:]]+/) {
        if (FNR != last[$2]) next
        if (ENVIRON["CMA_ADD_NAME"] != "" && $2 == ENVIRON["CMA_ADD_NAME"]) {
          print ENVIRON["CMA_ADD_LINE"]; added = 1; next
        }
      }
      print
    }
    END { if (ENVIRON["CMA_ADD_NAME"] != "" && !added) print ENVIRON["CMA_ADD_LINE"] }
  ' "$carry" "$carry" > "$carry.u" && command mv -f "$carry.u" "$carry"

  cb="$(_cma_alias_claude_bin "$src")"

  # The write status is PROPAGATED, and the stages are &&-chained so a failure
  # in any of them (not merely the last) is seen. Discarding it meant a
  # candidate truncated by ENOSPC — or one whose output file could not be opened
  # at all — was returned as a successful render. Against a zero-alias source
  # such a stump also clears the sanity gate, which only requires the header and
  # the two wrapper opening lines and has no aliases left to miss. A render we
  # cannot prove we wrote is a render we must not offer for commit.
  #
  # The open is probed SEPARATELY, with a simple command, because the two
  # failure modes reach us through different channels and the group form only
  # reports one of them:
  #   * ENOSPC  — the open SUCCEEDS, the writes fail; the group's own exit
  #               status carries it, and the &&-chain below sees it.
  #   * ENOENT/EACCES on the output path — the redirection fails BEFORE the
  #               group runs, and bash leaves the compound command's status at
  #               0 (verified on bash 5.2: `if ! { :; } > /nope/x` takes the
  #               else branch). A simple command with the same failed
  #               redirection does return 1, so that is what grades the open.
  # Without this probe an unwritable output path was reported as a successful
  # render of a file that does not exist.
  if ! : > "$out" 2>/dev/null; then
    rm -f "$carry" "$carry.mig" "$carry.d" "$carry.u" 2>/dev/null || true
    cma_warn "alias render: cannot open $out for writing (missing directory? permissions?)"
    return 1
  fi
  if ! { _cma_emit_managed "$cb" \
         && cat "$carry" \
         && if [[ "$hook" == "install" ]]; then
              _cma_emit_session_hook
            else
              _cma_alias_extract_hook "$src"
            fi
       } > "$out"; then
    rm -f "$carry" "$carry.mig" "$carry.d" "$carry.u" 2>/dev/null || true
    cma_warn "alias render: writing the candidate to $out failed (out of space? unwritable path?)"
    return 1
  fi

  rm -f "$carry" "$carry.mig" "$carry.d" "$carry.u" 2>/dev/null || true
  return 0
}

# Refuse to publish a candidate that lost something. Structural floor: the
# header and BOTH wrappers must be present. Content floor: the candidate's set
# of alias names must be exactly the source's set, minus an explicit drop, plus
# an explicit add — the incident's signature was account aliases silently
# vanishing from a file nobody asked to change. Account aliases are additionally
# floored against cma_detect_accounts, as far as the source file already
# satisfied it (a fresh install legitimately has fewer).
_cma_alias_gate() {
  local cand="$1" src="$2" drop="$3" add="$4"
  local want got n_acct src_acct cand_acct rc=0

  grep -q '^export CLAUDE_BIN=' "$cand"   || { cma_warn "alias render rejected: no CLAUDE_BIN header"; return 1; }
  grep -q '^cma_run() {' "$cand"          || { cma_warn "alias render rejected: no cma_run()"; return 1; }
  grep -q '^cma_run_provider() {' "$cand" || { cma_warn "alias render rejected: no cma_run_provider()"; return 1; }

  want="$(_cma_alias_mktemp)" || return 1
  got="$(_cma_alias_mktemp)"  || { rm -f "$want"; return 1; }
  {
    if [[ -n "$drop" ]]; then
      _cma_alias_names "$src" | grep -v -x -F -- "$drop" || true
    else
      _cma_alias_names "$src"
    fi
    if [[ -n "$add" ]]; then printf '%s\n' "$add" | awk -F'[ =]+' '{print $2}'; fi
  } | LC_ALL=C sort -u > "$want"
  _cma_alias_names "$cand" > "$got"
  if ! cmp -s "$want" "$got"; then
    cma_warn "alias render rejected: alias set changed unexpectedly ($(wc -l < "$want" | tr -d ' ') wanted, $(wc -l < "$got" | tr -d ' ') rendered)"
    rc=1
  fi
  rm -f "$want" "$got"
  (( rc == 0 )) || return 1

  # Account aliases specifically: every `CLAUDE_CONFIG_DIR=` alias the source
  # had must still be there, minus one the caller explicitly dropped. The
  # incident's signature was exactly these disappearing from a file nobody
  # asked to change.
  want="$(_cma_alias_mktemp)" || return 1
  got="$(_cma_alias_mktemp)"  || { rm -f "$want"; return 1; }
  if [[ -n "$drop" ]]; then
    _cma_alias_account_names "$src" | grep -v -x -F -- "$drop" > "$want" || true
  else
    _cma_alias_account_names "$src" > "$want"
  fi
  _cma_alias_account_names "$cand" > "$got"
  if [[ -n "$(LC_ALL=C comm -23 "$want" "$got")" ]]; then
    cma_warn "alias render rejected: account alias(es) lost: $(LC_ALL=C comm -23 "$want" "$got" | tr '\n' ' ')"
    rc=1
  fi
  rm -f "$want" "$got"
  (( rc == 0 )) || return 1

  # Secondary floor: cma_detect_accounts. Only meaningful when the source
  # already satisfied it AND no account is being removed — claude-remove-account
  # drops the alias BEFORE the directory, so the detected count legitimately
  # leads the alias count by one for the duration of that call.
  src_acct="$(_cma_alias_account_count "$src")"
  cand_acct="$(_cma_alias_account_count "$cand")"
  n_acct="$(cma_detect_accounts | wc -l | tr -d ' ')"
  if [[ -z "$drop" ]] && (( src_acct >= n_acct && cand_acct < n_acct )); then
    cma_warn "alias render rejected: $cand_acct account aliases < $n_acct detected accounts"
    return 1
  fi
  return 0
}

# cma_alias_commit [drop_name] [add_line] [hook_mode]
# THE single committer. Every mutation of $ALIAS_FILE in this toolkit goes
# through here; nothing else may write, append to, or rename onto the file.
cma_alias_commit() {
  local drop="${1:-}" add="${2:-}" hook="${3:-keep}"
  local dir cand rc=0 prev_int prev_term
  dir="$(dirname "$ALIAS_FILE")"
  mkdir -p "$dir" 2>/dev/null || true

  # (F3) No-op guard, taken WITHOUT the lock: render against the current file
  # and, if nothing would change, do nothing at all. Steady-state shell starts
  # perform zero writes and never contend.
  cand="$(_cma_alias_mktemp)" || { cma_warn "cannot create temp next to $ALIAS_FILE"; return 1; }
  if _cma_alias_render "$ALIAS_FILE" "$drop" "$add" "$hook" "$cand" \
     && [[ -f "$ALIAS_FILE" ]] && cmp -s "$cand" "$ALIAS_FILE"; then
    rm -f "$cand"
    return 0
  fi
  rm -f "$cand"

  if ! _cma_alias_lock_acquire; then
    # CONTENTION. The write did NOT happen: the file is byte-unchanged and the
    # caller's delta is not in it.
    #
    # Skipping is the right policy for exactly one caller — the session-refresh
    # hook, which runs on every shell start with CMA_ALIAS_LOCK_WAIT=0 and whose
    # delta the next writer re-derives from the file anyway. It is the WRONG
    # policy for everybody else, and reporting 0 to everybody else is how it
    # became a data-integrity bug: claude-add-account created the config dir,
    # linked the shared items, got 0 from cma_write_alias and announced success
    # for an account with NO alias (whose retry then dies on "config dir already
    # exists"), and claude-remove-account got 0 from cma_remove_alias and went on
    # to ARCHIVE the directory out from under a still-live alias.
    #
    # So the skip is now an explicit opt-in (CMA_ALIAS_SKIP_ON_CONTENTION=1, set
    # by _cma_emit_session_hook and nothing else). Every other caller gets 75
    # (EX_TEMPFAIL — "try again", as distinct from rc 1 "this render is bad") so
    # it can react instead of being told a lie.
    cma_warn "alias file busy — skipped update of $(basename "$ALIAS_FILE")"
    [[ "${CMA_ALIAS_SKIP_ON_CONTENTION:-}" == 1 ]] && return 0
    return 75
  fi

  # (F4) Mask INT/TERM across the critical section. NOT what makes the commit
  # atomic — render-once + a single mv(2) does that, with or without this mask
  # — and NOT what keeps the lock from leaking either: flock is released by the
  # kernel on death, and a leaked mkdir lock is reclaimed by the next acquire's
  # stale-breaker. Deleting these three lines leaves the suite green. They are
  # kept so the caller's own INT/TERM traps are restored rather than left
  # disarmed, and as cheap interrupt hygiene — not on the strength of any test.
  # See the "What protects WHAT" note above. Saved/restored, never clobbered.
  prev_int="$(trap -p INT || true)"
  prev_term="$(trap -p TERM || true)"
  trap '' INT TERM

  cand="$(_cma_alias_mktemp)" || cand=""
  if [[ -z "$cand" ]]; then
    rc=1
  elif ! _cma_alias_render "$ALIAS_FILE" "$drop" "$add" "$hook" "$cand"; then
    rm -f "$cand"; cma_warn "alias render failed — $ALIAS_FILE left untouched"; rc=1
  elif [[ -f "$ALIAS_FILE" ]] && cmp -s "$cand" "$ALIAS_FILE"; then
    rm -f "$cand"                                   # raced to identical; nothing to do
  elif ! _cma_alias_gate "$cand" "$ALIAS_FILE" "$drop" "$add"; then
    command mv -f "$cand" "$ALIAS_FILE.rejected.$(date +%s)" 2>/dev/null || rm -f "$cand"
    cma_warn "$ALIAS_FILE left untouched; candidate kept as $ALIAS_FILE.rejected.*"
    rc=1
  else
    command mv -f "$cand" "$ALIAS_FILE" || { rm -f "$cand"; rc=1; }
  fi

  trap - INT TERM
  if [[ -n "$prev_int" ]]; then eval "$prev_int"; fi
  if [[ -n "$prev_term" ]]; then eval "$prev_term"; fi
  _cma_alias_lock_release
  return $rc
}

# Ensure $ALIAS_FILE exists, is current, and is sourced from the user's rc
# files. Idempotent — safe to call repeatedly, and a no-op on disk when the
# rendered content already matches.
cma_ensure_alias_file() {
  mkdir -p "$(dirname "$ALIAS_FILE")"
  cma_alias_commit "" "" keep || return 1
  local rc src_line="source \"$ALIAS_FILE\""
  # ${arr[@]+"${arr[@]}"} (not bare "${arr[@]}") so an EMPTY CMA_RC_FILES does not
  # trip "unbound variable" under `set -u` on bash 3.2 (macOS ships 3.2; it errors
  # on empty-array expansion where bash 4.4+ treats it as empty). LOAD-BEARING.
  for rc in ${CMA_RC_FILES[@]+"${CMA_RC_FILES[@]}"}; do
    [[ -f "$rc" ]] || continue
    cma_prune_stale_alias_sources "$rc"   # self-heal: drop dangling aliases.sh source lines
    # Add the canonical source line only if no existing line already sources THIS
    # alias file (matched across .|source and $HOME/~/absolute forms) — prevents
    # duplicate source lines accumulating across re-installs with differing forms.
    # Back up BEFORE the append; refuse the write if the rc cannot be protected.
    if ! cma_rc_sources_alias_file "$rc" "$ALIAS_FILE"; then
      if cma_backup_rc_file "$rc"; then
        printf '\n%s\n%s\n' "$CMA_ALIAS_RC_HEADER" "$src_line" >> "$rc"
        cma_log "added source line to $rc"
      else
        cma_warn "skipped adding source line to $rc (could not back it up)"
      fi
    fi
  done
}

# Add (or refresh) a single alias entry in $ALIAS_FILE. Idempotent.
# The generated alias wraps `$CLAUDE_BIN` with sync-pull (before launch) and
# sync-push (after exit) so the project/session index inside .claude.json
# stays merged across every logged-in account without manual unify runs.
cma_write_alias() {
  local alias_name="$1" config_dir="$2"
  cma_validate_alias "$alias_name"
  # config_dir is interpolated into the alias body and re-parsed by the shell
  # when the alias is invoked. Reject shell metacharacters (injection) and
  # whitespace (an unquoted space would word-split the alias into a bogus
  # command — fail loud rather than write a silently-broken alias). Matched
  # literally per-char to avoid glob-bracket pitfalls.
  local _cma_c
  for _cma_c in '"' '$' '`' \\ ';' '&' '|' '<' '>' '(' ')'; do
    case "$config_dir" in *"$_cma_c"*)
      cma_warn "refusing to write alias '$alias_name': unsafe config dir"
      return 1 ;;
    esac
  done
  case "$config_dir" in *[[:space:]]*)
    cma_warn "refusing to write alias '$alias_name': config dir must not contain whitespace"
    return 1 ;;
  esac
  cma_ensure_alias_file
  # Note: bash aliases can't take args, so we use a quoted CLAUDE_CONFIG_DIR=
  # prefix plus a wrapped invocation. The wrapper is a shell function reference
  # (cma_run) emitted in the managed block by the renderer.
  # One delta, one render, one rename — see cma_alias_commit.
  cma_alias_commit "$alias_name" \
    "$(printf 'alias %s="CLAUDE_CONFIG_DIR=%s cma_run"' "$alias_name" "$config_dir")" keep
}

# Remove an alias line. Idempotent.
cma_remove_alias() {
  local alias_name="$1"
  [[ -f "$ALIAS_FILE" ]] || return 0
  cma_alias_commit "$alias_name" "" keep
}

# ===========================================================================
# Provider-alias helpers (used by claude-providers.sh)
# ===========================================================================

# The shared items every account/provider dir symlinks into $SHARED_DIR.
# Kept here (single source) so claude-add-account and claude-providers agree.
CMA_SHARED_ITEMS=(
  projects todos tasks plans file-history paste-cache shell-snapshots
  session-env telemetry sessions backups cache plugins
  stats-cache.json history.jsonl CLAUDE.md
  daemon jobs
)
# NOTE (§11.4 own-settings): settings.json is DELIBERATELY NOT in the shared set.
# Each config dir gets its OWN settings.json so per-alias permissions/model/hooks
# never leak across aliases/providers, while the plugin CACHE (`plugins`),
# history (`history.jsonl`), memory (`CLAUDE.md`) and sessions stay shared. Each
# dir's own settings.json is seeded from + kept enabledPlugins-synced with the
# shared template $SHARED_DIR/settings.json by cma_own_settings_seed (so
# superpowers et al. stay enabled everywhere). See cma_link_shared_items +
# cma_enable_plugins below.
# NOTE (daemon/jobs): `daemon` is Claude Code's background-agent registry
# (roster.json + dispatch). It MUST be shared or a background agent started
# under one alias is invisible to every other alias — the registry is
# config-dir-scoped, not session-scoped. `jobs` is its sibling job store.
# daemon/roster.json is union-merged (not last-wins) — see
# merge_daemon_roster in claude-unify.sh.

cma_providers_dir() { echo "$HOME/.local/share/claude-multi-account/providers"; }

# --- verification status cache ---------------------------------------------
# Single source of truth for "is this provider alias usable". Holds ONLY
# non-secret metadata: provider id -> {status, model, checked_at, failing_layer}.
# status is one of: verified | unverified | failed | pending. Consumed by the
# list family (claude-providers list/list-all/list-faulty) and the launch-time
# activation gate in cma_run_provider. NO key material ever lands here.
cma_status_cache() { echo "$(cma_providers_dir)/status.json"; }

# cma_status_write <id> <status> [<model> [<failing_layer>]]
# Upserts one record. failing_layer is "" for verified/pending. Atomic write.
cma_status_write() {
  local id="$1" status="$2" model="${3:-}" layer="${4:-}"
  cma_require jq
  local f; f="$(cma_status_cache)"; mkdir -p "$(dirname "$f")"
  [[ -s "$f" ]] || printf '{}\n' > "$f"
  # checked_at: portable UTC ISO-8601 (GNU + BSD date both accept -u +fmt).
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
  if jq --arg id "$id" --arg s "$status" --arg m "$model" \
        --arg l "$layer" --arg t "$now" \
        '.[$id] = {status:$s, model:$m, checked_at:$t, failing_layer:$l}' \
        "$f" > "$tmp" 2>/dev/null; then
    command mv -f "$tmp" "$f"
  else
    rm -f "$tmp"; cma_warn "could not update status cache $f"
  fi
}

# cma_status_read <id> -> status word (pending if absent/unreadable).
cma_status_read() {
  local id="$1" f; f="$(cma_status_cache)"
  [[ -s "$f" ]] || { echo pending; return 0; }
  local s; s="$(jq -r --arg id "$id" '.[$id].status // "pending"' "$f" 2>/dev/null)"
  [[ -n "$s" && "$s" != "null" ]] && echo "$s" || echo pending
}

# cma_status_all -> id<TAB>status<TAB>model<TAB>checked_at<TAB>failing_layer per record.
cma_status_all() {
  local f; f="$(cma_status_cache)"
  [[ -s "$f" ]] || return 0
  jq -r 'to_entries[] | [.key, .value.status, (.value.model // ""),
         (.value.checked_at // ""), (.value.failing_layer // "")] | @tsv' \
     "$f" 2>/dev/null || true
}

# Union daemon/roster.json files into one registry. workers are merged by id
# with the newer updatedAt winning per worker; proto and supervisorPid come
# from the newest roster; top-level updatedAt is the max. Used by
# claude-unify.sh (merge_daemon_roster) and cma_migrate_daemon_dirs_once.
# Usage: cma_union_rosters OUTFILE roster1.json [roster2.json ...]
cma_union_rosters() {
  local out="$1"; shift
  command -v jq >/dev/null 2>&1 || return 1
  (( $# >= 1 )) || return 1
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
  if jq -s '
    def newer($a; $b): if (($a.updatedAt // 0) >= ($b.updatedAt // 0)) then $a else $b end;
    ([.[] | {u: (.updatedAt // 0), p: (.proto // 1), s: (.supervisorPid // null), w: (.workers // {})}])
    | (map(.u) | max // 0) as $maxu
    | (sort_by(.u) | last) as $newest
    | (reduce .[] as $r ({}; . as $acc
        | reduce ($r.w | to_entries[]) as $e ($acc;
            if ($acc[$e.key] == null) then . + {($e.key): $e.value}
            else . + {($e.key): newer($acc[$e.key]; $e.value)} end))) as $workers
    | {proto: $newest.p, supervisorPid: $newest.s, updatedAt: $maxu, workers: $workers}
  ' "$@" >| "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
    command mv -f "$tmp" "$out"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# One-time migration for pre-v1.17.0 LOCAL daemon/jobs dirs under provider
# dirs: their contents (including background-agent rosters) must not be
# stranded when daemon/jobs become shared items. Merges every real provider
# daemon/jobs dir into $SHARED_DIR (roster.json excluded), backs it up,
# replaces it with the shared symlink, then union-merges every collected
# roster.json (incl. the shared one) with cma_union_rosters. Idempotent via a
# marker file; cma_link_shared_items handles all NEW provider dirs.
cma_migrate_daemon_dirs_once() {
  command -v rsync >/dev/null 2>&1 || return 0
  local marker="$SHARED_DIR/.daemon-migration-done"
  [[ -e "$marker" ]] && return 0
  local d item tgt roster_tmp=""
  for d in "$HOME/${CMA_PROVIDER_DIR_PREFIX:-.claude-prov-}"*/; do
    [[ -d "$d" ]] || continue
    for item in daemon jobs; do
      tgt="$d$item"
      [[ -d "$tgt" && ! -L "$tgt" ]] || continue
      mkdir -p "$SHARED_DIR/$item"
      rsync -a --exclude 'roster.json' "$tgt/" "$SHARED_DIR/$item/" 2>/dev/null || true
      if [[ -f "$tgt/roster.json" ]]; then
        # Stash roster CONTENT before the dir moves — collecting paths and
        # unioning afterwards would read the just-moved (missing) files.
        [[ -z "$roster_tmp" ]] && roster_tmp="$(mktemp -d "${TMPDIR:-/tmp}/cma.XXXXXX")"
        cp "$tgt/roster.json" "$roster_tmp/$(printf '%s' "$d" | md5sum | cut -c1-12).json"
      fi
      # Same backup convention as unify's backup_and_remove (defined there,
      # not in lib.sh): rename to <path>.preunify.<timestamp> — recoverable.
      command mv -f "$tgt" "${tgt}.preunify.$(date +%Y%m%d%H%M%S)"
      ln -s "$SHARED_DIR/$item" "$tgt"
    done
  done
  local srcs=()
  [[ -f "$SHARED_DIR/daemon/roster.json" && ! -L "$SHARED_DIR/daemon/roster.json" ]] && \
    srcs+=("$SHARED_DIR/daemon/roster.json")
  [[ -n "$roster_tmp" ]] && srcs+=("$roster_tmp"/*.json)
  if (( ${#srcs[@]} )); then
    cma_union_rosters "$SHARED_DIR/daemon/roster.json" "${srcs[@]}" || \
      cma_warn "daemon roster union failed during migration — last-wins file kept"
  fi
  [[ -n "$roster_tmp" ]] && rm -rf "$roster_tmp"
  # $SHARED_DIR may not exist yet (fresh host / first sync before any shared
  # item was linked). claude-providers.sh runs under `set -e`, so an unguarded
  # `: > $marker` onto a missing directory ABORTS the whole cmd_sync (captured
  # live: "line 1166: …/.claude-shared/.daemon-migration-done: No such file or
  # directory" -> sync exit 1, zero providers registered). The marker is only
  # a skip-optimization — the migration loop itself is idempotent (symlinked
  # dirs are skipped) — so a failed marker write must never kill the sync.
  mkdir -p "$SHARED_DIR" 2>/dev/null || true
  : > "$marker" 2>/dev/null || true
}

# Symlink every shared item into a config dir (account or provider), creating
# empty placeholders in $SHARED_DIR for any item that doesn't exist yet.
# Idempotent: skips items already present in the target.
cma_link_shared_items() {
  local cdir="$1" item src tgt
  mkdir -p "$SHARED_DIR" "$cdir"
  for item in "${CMA_SHARED_ITEMS[@]}"; do
    src="$SHARED_DIR/$item"; tgt="$cdir/$item"
    if [[ ! -e "$src" ]]; then
      case "$item" in
        *.json|*.jsonl|*.md) : > "$src" ;;
        *) mkdir -p "$src" ;;
      esac
    fi
    [[ -e "$tgt" || -L "$tgt" ]] || ln -s "$src" "$tgt"
  done
  # §11.4 own-settings: settings.json is NOT symlinked — give this dir its OWN copy.
  cma_own_settings_seed "$cdir"
}

# List all toolkit-managed config dirs (native accounts + providers). Used to
# fan out per-dir OWN settings.json enabledPlugins-sync.
cma_all_config_dirs() {
  local d
  for d in "$HOME"/.claude-claude* "$HOME"/.claude-prov-*; do
    [[ -d "$d" ]] && printf '%s\n' "$d"
  done
}

# Give a config dir its OWN settings.json (§11.4 own-settings). If it is a symlink
# (legacy shared layout) or absent, seed a REAL copy from the shared template so
# it inherits enabledPlugins + theme. If already a real file, additively merge the
# template's enabledPlugins in (own entries win — never clobber per-alias
# overrides). The shared template $SHARED_DIR/settings.json remains the single
# source of the always-on plugin set.
cma_own_settings_seed() {
  # NOTE: separate `local`s — a single `local a="$1" b="$a/x"` expands $a before
  # it is assigned, which aborts under `set -u` ("a: unbound variable").
  local cdir="${1:-}"
  [ -n "$cdir" ] || return 0
  local own="$cdir/settings.json"
  local tmpl="${SHARED_DIR:-$HOME/.claude-shared}/settings.json"
  local tmp=""
  command -v jq >/dev/null 2>&1 || return 0
  [[ -s "$tmpl" ]] || printf '{}\n' > "$tmpl"
  if [[ -L "$own" || ! -e "$own" ]]; then
    rm -f "$own" 2>/dev/null
    cp "$tmpl" "$own" 2>/dev/null || printf '{}\n' > "$own"
    return 0
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
  if jq -s '.[0] as $own | .[1] as $t
            | $own | .enabledPlugins = (($t.enabledPlugins // {}) + ($own.enabledPlugins // {}))' \
        "$own" "$tmpl" > "$tmp" 2>/dev/null && jq -e . "$tmp" >/dev/null 2>&1; then
    command mv -f "$tmp" "$own"
  else rm -f "$tmp"; fi
}

# Force-enable the always-on plugins in the shared settings.json enabledPlugins
# map (additive union — never removes a user's existing entries). Each arg is a
# plugin key as it appears in enabledPlugins (e.g. "superpowers@anthropics").
cma_enable_plugins() {
  cma_require jq
  local settings="$SHARED_DIR/settings.json" tmp
  mkdir -p "$SHARED_DIR"
  [[ -s "$settings" ]] || printf '{}\n' > "$settings"
  tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
  local args=() p i=0
  # Use a dedicated counter for the jq --arg names: each iteration appends THREE
  # elements (--arg, "pN", value), so deriving the index from ${#args[@]} drifts
  # (it produced p0,p1,p3,p4 for 4 plugins → $p2 undefined → jq failed silently
  # → no plugins enabled). The counter matches the $pN refs in the prog below.
  for p in "$@"; do args+=(--arg "p$i" "$p"); i=$((i+1)); done
  # Build a jq program that sets each provided key true if absent.
  local prog='.enabledPlugins //= {}'
  local i=0
  for p in "$@"; do
    prog+=" | .enabledPlugins[\$p$i] //= true"; i=$((i+1))
  done
  # ${args[@]+...} guards an empty array under set -u on bash 3.2 (reachable
  # via CMA_ALWAYS_ON_PLUGINS="" from non-re-exec'd claude-providers.sh).
  if jq ${args[@]+"${args[@]}"} "$prog" "$settings" > "$tmp" 2>/dev/null; then
    command mv -f "$tmp" "$settings"
  else
    rm -f "$tmp"; cma_warn "could not update enabledPlugins in $settings"
  fi
  # Fan the always-on plugin set out into every managed config dir's OWN
  # settings.json (settings.json is no longer a shared symlink — §11.4
  # own-settings) so enabling a plugin still reaches every alias/provider.
  local _cd
  while IFS= read -r _cd; do [[ -n "$_cd" ]] && cma_own_settings_seed "$_cd"; done < <(cma_all_config_dirs)
}

# Write the non-secret per-provider env file consumed by cma_run_provider.
# Args: id keyvar transport base_url model fast_model config_dir [context_limit [max_output]]
# context_limit and max_output are optional trailing args (default empty).
# cma_run_provider consumes both catalog limits to avoid the 400 "exceeded
# model token limit" error: CMA_PROVIDER_CONTEXT_LIMIT -> CLAUDE_CODE_AUTO_COMPACT_WINDOW
# (INPUT: compact before the prompt overshoots the provider's window) and
# CMA_PROVIDER_MAX_OUTPUT -> CLAUDE_CODE_MAX_OUTPUT_TOKENS (OUTPUT cap).
cma_provider_write_env() {
  local id="$1" keyvar="$2" transport="$3" base="$4" model="$5" fast="$6" cdir="$7"
  local context_limit="${8:-}" max_output="${9:-}" alias_name="${10:-}"
  # Normalize the literal "null" (from a missing JSON field) to empty so it
  # never leaks into the wrapper as a bogus value. transport+model were missed
  # originally — a null strong_model/transport wrote CMA_PROVIDER_MODEL='null'
  # (provider launches with a bogus model). Normalize every field for symmetry.
  [[ "$transport" == "null" ]] && transport=""
  [[ "$base" == "null" ]] && base=""
  [[ "$model" == "null" ]] && model=""
  [[ "$fast" == "null" ]] && fast=""
  [[ "$context_limit" == "null" ]] && context_limit=""
  [[ "$max_output" == "null" ]] && max_output=""
  [[ "$alias_name" == "null" ]] && alias_name=""
  local pdir; pdir="$(cma_providers_dir)"; mkdir -p "$pdir"
  # Preserve the opt-in per-provider TRIM knob (CMA_PROVIDER_TRIM) across
  # regeneration. It is NOT in the models.dev catalog nor the alias manifest, so
  # neither caller passes it — it is set on the env file itself. Because this
  # generator OVERWRITES the whole file (cat > below), an `add`/re-add would
  # otherwise DROP it. Read the current on-disk value BEFORE the cat truncates
  # the file and re-emit it below (same existing-value-from-env read as cmd_sync).
  # `unset CMA_PROVIDER_TRIM` first so only the file's value is preserved — never
  # a value that happens to be exported in the caller's shell.
  local trim=""
  if [[ -f "$pdir/$id.env" ]]; then
    # shellcheck disable=SC1090,SC1091
    trim="$( ( unset CMA_PROVIDER_TRIM; set -a; . "$pdir/$id.env" >/dev/null 2>&1; set +a; printf '%s' "${CMA_PROVIDER_TRIM:-}" ) )"
  fi
  [[ "$trim" == "null" ]] && trim=""
  # Values are single-quoted (with embedded-quote escaping) so sourcing the file
  # in the user's shell is safe regardless of characters in URLs/model ids.
  # POSIX single-quote escaping: replace each ' with '\'' via a loop.
  # Portable across all bash versions — avoids ${var/pattern/replacement} with
  # complex escape sequences that break on bash 3.2 and 5.3.
  _cma_q() {
    local _r="" _rem="$1"
    while true; do
      case "$_rem" in *\'*)
        _r="${_r}${_rem%%\'*}'\\''"; _rem="${_rem#*\'}" ;;
        *) _r="${_r}${_rem}"; break ;;
      esac
    done
    printf "'%s'" "$_r"
  }
  cat > "$pdir/$id.env" <<EOF
# generated by claude-providers — non-secret. Do not edit by hand.
# Secrets are NEVER stored here; the key is read from the keys file at launch.
CMA_PROVIDER_ID=$(_cma_q "$id")
CMA_PROVIDER_KEYVAR=$(_cma_q "$keyvar")
CMA_PROVIDER_TRANSPORT=$(_cma_q "$transport")
CMA_PROVIDER_BASE_URL=$(_cma_q "$base")
CMA_PROVIDER_MODEL=$(_cma_q "$model")
CMA_PROVIDER_FAST_MODEL=$(_cma_q "$fast")
CMA_PROVIDER_CONFIG_DIR=$(_cma_q "$cdir")
# Context-window limits from the models.dev catalog for the selected strong model.
# CMA_PROVIDER_CONTEXT_LIMIT: input context window (tokens); empty = unknown.
#   -> exported as CLAUDE_CODE_AUTO_COMPACT_WINDOW (input-side guard).
# CMA_PROVIDER_MAX_OUTPUT:    maximum output tokens; empty = unknown.
#   -> exported as CLAUDE_CODE_MAX_OUTPUT_TOKENS (output-side guard).
CMA_PROVIDER_CONTEXT_LIMIT=$(_cma_q "$context_limit")
CMA_PROVIDER_MAX_OUTPUT=$(_cma_q "$max_output")
# Alias name for this provider (used by 'list --refresh-aliases' to rebuild the
# alias shell line with NO network — the session hook's fast path). Empty is OK;
# refresh falls back to the provider id as the alias name.
CMA_PROVIDER_ALIAS=$(_cma_q "$alias_name")
EOF
  # Re-emit the preserved TRIM knob, ONLY when set — a provider without it must
  # stay without it (no spurious empty line). CMA_PROVIDER_TRIM=bare makes
  # cma_run_provider launch minimal (--bare, fresh session, no auto-resume).
  if [[ -n "$trim" ]]; then
    {
      printf '# Opt-in per-provider TRIM knob (preserved across regeneration).\n'
      printf '# CMA_PROVIDER_TRIM=bare launches minimal: --bare + fresh session (no auto-resume).\n'
      printf 'CMA_PROVIDER_TRIM=%s\n' "$(_cma_q "$trim")"
    } >> "$pdir/$id.env"
  fi
  unset -f _cma_q
}

# Write (or refresh) a provider alias: alias <name>="cma_run_provider <id>".
cma_provider_write_alias() {
  local alias_name="$1" id="$2"
  cma_validate_alias "$alias_name"
  # The provider id is interpolated into the alias body and re-parsed when the
  # alias is invoked. Provider ids are always [A-Za-z0-9._-]; reject anything
  # else so a hostile catalog/--id value can't inject shell commands.
  case "$id" in
    ''|*[!A-Za-z0-9._-]*)
      cma_warn "refusing to write alias '$alias_name': unsafe provider id"
      return 1 ;;
  esac
  # One delta, one render, one rename. This used to bootstrap-only (never
  # calling cma_ensure_alias_file on an existing file) because the old
  # drop/re-append migrations could reposition cma_run_provider relative to the
  # alias lines, making `--refresh-aliases` non-idempotent (see test_providers.sh
  # "--refresh-aliases is idempotent"). The renderer emits a fixed canonical
  # order, so position is now invariant and that hazard is gone — which is why
  # this path can safely render the managed block like every other writer.
  cma_alias_commit "$alias_name" \
    "$(printf 'alias %s="cma_run_provider %s"' "$alias_name" "$id")" keep
}

# Install (idempotently) the provider session-refresh hook into $ALIAS_FILE. On
# every interactive shell start the hook re-writes provider aliases from cache
# (NO network) and, when the status cache is older than CMA_PROVIDERS_SYNC_TTL
# (default 24h), kicks a detached full sync (§11.4.89 background — never blocks
# the shell). Bracketed by markers so a re-install replaces the block atomically
# (no duplication across re-installs).
cma_install_session_hook() {
  cma_ensure_alias_file
  # The hook text itself lives in _cma_emit_session_hook (next to the other
  # emitters); "install" tells the renderer to emit the current version instead
  # of carrying the existing block over.
  cma_alias_commit "" "" install
}

# True only when the toolkit may prompt the user interactively. Scripts read
# confirmations from /dev/tty (so prompts survive `curl | bash`), so this
# probes /dev/tty rather than stdin. It returns false when:
#   * CMA_NONINTERACTIVE=1 is exported — a global "never prompt" switch for
#     automation, CI, and the test suite (deterministic regardless of TTY); or
#   * no terminal is available — CI, a test sandbox, an SSH command with no PTY.
# When it returns false, callers MUST fall back to their non-interactive
# default instead of blocking or erroring on a failed read. This is what makes
# toolkit execution always non-interactive off a terminal.
cma_can_prompt() {
  [[ "${CMA_NONINTERACTIVE:-}" == 1 ]] && return 1
  ( exec </dev/tty ) 2>/dev/null
}
