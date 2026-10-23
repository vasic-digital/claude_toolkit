#!/usr/bin/env bash
# jev-lockdir-lib.sh - mutual-exclusion mkdir-lockdir primitive (sourced, never executed).
#
# The mkdir fallback of the Kimi config lock (jev-kimi-lib.sh) used to be a naive
# "kill -0 then rm/rmdir" loop. With three or more contenders that is NOT mutually
# exclusive (round-5 review R5-1: overlap measured in 5/10 and 8/10 runs): two waiters
# both see the same dead pid, one removes the dir and re-creates it, the other then
# removes the NEW holder's dir; release was a blind rmdir.
#
# This file is the same algorithm scripts/lib.sh already solves for the alias file
# (_cma_alias_lock_acquire / _release / _break_stale), parameterised on a lock
# directory and free of lib.sh globals so that it is safe under `set -e` and without:
#   * claim with mkdir and then take the lock by creating <dir>/pid with an O_EXCL
#     (noclobber) write. mkdir ALONE is not an atomic mutex on every host: uutils
#     coreutils 0.8.0 (the default `mkdir` of current Ubuntu) reports an EEXIST race as
#     success - measured 2026-10-23, more than one winner in 66 of 200 rounds of 6
#     racing `mkdir d`. The exclusive pid-file create is the real mutex; mkdir only
#     provides the directory it lives in. After the create the pid is RE-READ (tie-break:
#     a pid that is not ours means a breaker removed our dir under us -> retry);
#   * a dead holder is broken ONLY through a breaker lock (<dir>.breaker) and only
#     after re-reading the evidence: the pid we OBSERVED must still be the pid in the
#     dir, and dead (or, for a pid-less dir, still pid-less);
#   * a pid-less dir (holder between mkdir and the pid write) is given a grace period
#     (CMA_LOCKDIR_GRACE seconds, default 10) before it is treated as stale;
#   * the wait deadline is checked on EVERY pass (the lib.sh loop `continue`s after a
#     break and skips it);
#   * release removes the dir only if its pid is still ours.
#
#   cma_lockdir_acquire <dir> <wait-seconds>   0 acquired, 1 timed out / error
#   cma_lockdir_release <dir>                  no-op unless the pid file is ours

_cma_lockdir_pid() { # prints the digits-only pid recorded in <dir>/pid, or nothing
  local p
  p="$(head -n 1 "$1/pid" 2>/dev/null)" || p=""
  case "$p" in '' | *[!0-9]*) p="" ;; esac
  printf '%s' "$p"
}

_cma_lockdir_alive() { [ -n "${1-}" ] && kill -0 "$1" 2>/dev/null; }

# _cma_lockdir_claim <dir>: atomically create <dir>/pid holding OUR pid. Exactly one
# caller can succeed while the file exists: noclobber makes bash open it O_CREAT|O_EXCL,
# which the kernel decides, unlike mkdir's exit status on some coreutils builds.
# Fails (non-zero) if the file exists or the directory is gone.
_cma_lockdir_claim() { ( set -C; printf '%s\n' "$$" > "$1/pid" ) 2>/dev/null; }

# break a stale lock. $2 = the pid observed by the caller ("" = pid-less dir).
_cma_lockdir_break_stale() {
  local dir="$1" observed="${2-}" br cur bp
  br="${dir}.breaker"
  if ! mkdir "$br" 2>/dev/null; then
    # someone else is breaking; reap the breaker only when ITS owner is dead
    bp="$(_cma_lockdir_pid "$br")"
    if [ -n "$bp" ] && ! _cma_lockdir_alive "$bp"; then
      rm -f "$br/pid" 2>/dev/null; rmdir "$br" 2>/dev/null
    fi
    return 0
  fi
  # mkdir alone is not a mutex (see the header): the breaker role is the O_EXCL pid create
  if ! _cma_lockdir_claim "$br"; then return 0; fi
  cur="$(_cma_lockdir_pid "$dir")"
  if [ -d "$dir" ]; then
    if { [ -n "$observed" ] && [ "$cur" = "$observed" ] && ! _cma_lockdir_alive "$cur"; } \
      || { [ -z "$observed" ] && [ -z "$cur" ]; }; then
      rm -f "$dir/pid" 2>/dev/null; rmdir "$dir" 2>/dev/null
    fi
  fi
  rm -f "$br/pid" 2>/dev/null; rmdir "$br" 2>/dev/null
  return 0
}

cma_lockdir_acquire() {
  local dir="${1-}" wait="${2-30}" grace="${CMA_LOCKDIR_GRACE:-10}"
  local start now holder empty_since="" n
  [ -n "$dir" ] || return 1
  case "$wait" in '' | *[!0-9]*) wait=30 ;; esac
  case "$grace" in '' | *[!0-9]*) grace=10 ;; esac
  start="$SECONDS"
  while :; do
    mkdir "$dir" 2>/dev/null    # may "succeed" on an existing dir (racy mkdir): only the claim counts
    if _cma_lockdir_claim "$dir"; then
      if [ "$(_cma_lockdir_pid "$dir")" = "$$" ]; then return 0; fi
      # a breaker removed our dir between the claim and the re-read: fall through, retry
    elif [ -d "$dir" ]; then
      # the claim failed because the pid file exists (or is being created): evaluate the holder
      holder="$(_cma_lockdir_pid "$dir")"
      if [ -n "$holder" ]; then
        empty_since=""
        if ! _cma_lockdir_alive "$holder"; then _cma_lockdir_break_stale "$dir" "$holder"; fi
      elif [ -d "$dir" ]; then
        now="$SECONDS"; [ -n "$empty_since" ] || empty_since="$now"
        if [ $((now - empty_since)) -ge "$grace" ]; then
          _cma_lockdir_break_stale "$dir" ""; empty_since=""
        fi
      fi
    fi
    now="$SECONDS"
    [ $((now - start)) -ge "$wait" ] && return 1
    sleep 0.1
  done
}

cma_lockdir_release() {
  local dir="${1-}"
  [ -n "$dir" ] || return 0
  if [ "$(_cma_lockdir_pid "$dir")" = "$$" ]; then
    rm -f "$dir/pid" 2>/dev/null; rmdir "$dir" 2>/dev/null
  fi
  return 0
}
