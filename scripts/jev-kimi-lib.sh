#!/usr/bin/env bash
# jev-kimi-lib.sh — SOURCED helpers shared by BOTH writers of the Kimi Code
# `[[hooks]]` PreToolUse block: scripts/jev-setup.sh (native ~/.kimi-code-* homes)
# and scripts/claude-providers.sh (rendered ~/.kimi-prov-* twins). One validator,
# one constant file, one stamp reader: a rule fixed here is fixed for both
# writers (review round 2, class B: the gate-path guard had been added to only
# one of the two TOML writers).
#
# No side effects when sourced; nothing here writes a file.

# jev_realpath <path> — portable replacement for `readlink -f` (BSD/macOS readlink has
# no -f: it prints "illegal option" and yields nothing). Walks the symlink chain with
# single-argument `readlink` (supported everywhere), then canonicalises the directory
# with `cd -P`/`pwd -P`. Prints the canonical absolute path and returns 0; returns 1
# with NO stdout for an empty argument, a missing path, a dangling symlink, or a
# symlink loop (more than 40 hops) — callers decide their own fallback.
jev_realpath() {
  local p="${1-}" t d hops=0
  [ -n "$p" ] || return 1
  while [ -L "$p" ]; do
    hops=$((hops + 1))
    [ "$hops" -le 40 ] || return 1
    t="$(readlink -- "$p")" || return 1
    case "$t" in
      /*) p="$t" ;;
      *) p="$(dirname -- "$p")/$t" ;;
    esac
  done
  [ -e "$p" ] || return 1
  # CDPATH= : an exported CDPATH must never redirect a relative `cd` (it would also print the dir)
  d="$(CDPATH= cd -P -- "$(dirname -- "$p")" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s\n' "$d" "$(basename -- "$p")"
}

# jev_kimi_gate_path_safe <path> — 0 when <path> can be emitted inside a TOML
# basic string unescaped: non-empty, and no backslash, double quote or control
# character (newline, tab, DEL ...). 1 otherwise.
jev_kimi_gate_path_safe() {
  case "${1-}" in
    '' | *\\* | *\"* | *[[:cntrl:]]*) return 1 ;;
  esac
  return 0
}

# jev_kimi_matcher_valid <matcher> — 0 when it is a `|`-separated list of tool
# NAMES (letters only). Kimi Code tests the matcher with an UNANCHORED
# RegExp.test(toolName), so anything but plain names would over- or under-match.
jev_kimi_matcher_valid() {
  [[ "${1-}" =~ ^[A-Za-z]+(\|[A-Za-z]+)*$ ]]
}

# jev_kimi_matcher <scripts-dir> — prints the matcher read from the ONE constant
# file <scripts-dir>/jev-kimi-tools.txt and returns 0; returns 1 (reason on
# stderr, nothing on stdout) when the file is missing, unreadable or invalid.
# There is deliberately NO built-in fallback copy: a second hard-coded copy is
# exactly what drifted before.
jev_kimi_matcher() {
  local f="${1-}/jev-kimi-tools.txt" m
  if [ ! -r "$f" ]; then
    printf 'jev-kimi-tools.txt is missing or unreadable (%s)\n' "$f" >&2
    return 1
  fi
  m="$(tr -d '[:space:]' < "$f" 2>/dev/null)"
  if ! jev_kimi_matcher_valid "$m"; then
    printf 'jev-kimi-tools.txt is invalid (%s): expected a | separated list of tool names\n' "$f" >&2
    return 1
  fi
  printf '%s' "$m"
}

# jev_kimi_stamp_agents <stamp-file> — prints the comma list on the stamp's
# `agents=` line (empty for a missing file, a legacy empty stamp or no line).
jev_kimi_stamp_agents() {
  sed -n 's/^agents=//p' "${1-}" 2>/dev/null | head -n 1
}

# jev_kimi_stamp_has <stamp-file> <agent> — 0 only when the stamp EXISTS and its
# agents= list names <agent> (or `all`). A legacy/empty stamp names nobody: the
# consent to wire Kimi was never recorded, so fail closed.
jev_kimi_stamp_has() {
  [ -e "${1-}" ] || return 1
  case ",$(jev_kimi_stamp_agents "$1")," in
    *,"${2-}",* | *,all,*) return 0 ;;
  esac
  return 1
}

# --- Kimi config serialisation (R4-1) --------------------------------------
# EVERY writer of a Kimi config.toml (the native-home block writer in
# jev-setup.sh, the twin renderer and the twin refresh in claude-providers.sh)
# and every jev-setup install/uninstall run serialises on ONE lock, and decides
# what to write (stamp/consent, desired block) only AFTER it holds the lock.
# Without it a detached `claude-providers sync-jev` that read the config before
# a foreground render/uninstall replaces the file afterwards with its stale copy
# (a lost update: reverted model/api_key, or a resurrected hook block that
# points at a removed gate).
#
#   jev_kimi_lock <state-dir>   0 acquired (re-entrant), 1 not acquired
#   jev_kimi_unlock             release one level (no-op when not held)
#   jev_kimi_unlock_force       release everything (EXIT-trap safe, no-op unheld)
#
# Backend: flock(1) on fd 7 (append mode, so the file is never truncated); the
# mkdir-lockdir backend (jev-lockdir-lib.sh: breaker lock, pid tie-break, owner-checked release) is used when flock
# is missing or JEV_KIMI_LOCK_NO_FLOCK=1 (test seam). Wait budget:
# JEV_KIMI_LOCK_WAIT seconds (default 30; non-digit values fall back to 30).
: "${_JEV_LOCK_DEPTH:=0}"
: "${_JEV_LOCK_MODE:=}"
: "${_JEV_LOCK_DIR:=}"

# The mkdir backend is the shared algorithm in jev-lockdir-lib.sh (sibling file; resolved
# through symlinks so the installed ~/.local/lib copy finds it). Missing => fail closed.
_jev_lockdir_load() {
  declare -F cma_lockdir_acquire >/dev/null 2>&1 && return 0
  local here self
  self="$(jev_realpath "${BASH_SOURCE[0]}")" || return 1
  here="$(cd "$(dirname "$self")" 2>/dev/null && pwd)" || return 1
  # shellcheck source=jev-lockdir-lib.sh
  . "$here/jev-lockdir-lib.sh" 2>/dev/null || return 1
  declare -F cma_lockdir_acquire >/dev/null 2>&1
}

jev_kimi_lock() {
  local sd="${1-}" wait="${JEV_KIMI_LOCK_WAIT:-30}" i n
  [ -n "$sd" ] || return 1
  case "$wait" in '' | *[!0-9]*) wait=30 ;; esac
  if [ "$_JEV_LOCK_DEPTH" -gt 0 ]; then
    _JEV_LOCK_DEPTH=$((_JEV_LOCK_DEPTH + 1))
    return 0
  fi
  mkdir -p "$sd" 2>/dev/null || return 1
  if [ "${JEV_KIMI_LOCK_NO_FLOCK:-0}" != 1 ] && command -v flock >/dev/null 2>&1; then
    if ! exec 7>>"$sd/kimi-config.lock"; then return 1; fi
    if [ "$wait" -eq 0 ]; then flock -n 7 || { { exec 7>&-; } 2>/dev/null; return 1; }
    else flock -w "$wait" 7 || { { exec 7>&-; } 2>/dev/null; return 1; }
    fi
    _JEV_LOCK_MODE=flock
  else
    _JEV_LOCK_DIR="$sd/kimi-config.lock.d"
    _jev_lockdir_load || return 1
    cma_lockdir_acquire "$_JEV_LOCK_DIR" "$wait" || return 1
    _JEV_LOCK_MODE=mkdir
  fi
  _JEV_LOCK_DEPTH=1
  return 0
}

jev_kimi_unlock() {
  [ "$_JEV_LOCK_DEPTH" -gt 0 ] || return 0
  _JEV_LOCK_DEPTH=$((_JEV_LOCK_DEPTH - 1))
  [ "$_JEV_LOCK_DEPTH" -eq 0 ] || return 0
  if [ "$_JEV_LOCK_MODE" = flock ]; then
    flock -u 7 2>/dev/null; { exec 7>&-; } 2>/dev/null
  else
    cma_lockdir_release "$_JEV_LOCK_DIR"
  fi
  _JEV_LOCK_MODE=""
  return 0
}

jev_kimi_unlock_force() {
  [ "$_JEV_LOCK_DEPTH" -gt 0 ] || return 0
  _JEV_LOCK_DEPTH=1
  jev_kimi_unlock
}
