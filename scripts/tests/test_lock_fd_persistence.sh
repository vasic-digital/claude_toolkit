#!/usr/bin/env bash
# test_lock_fd_persistence.sh — the eph/cfg launch locks must ACTUALLY LOCK.
#
# Field failure (2026-07-25): _cma_eph_lock / _cma_cfg_lock opened their lock
# fd as `{ exec 9>>FILE; } 2>/dev/null`. Hardcoded LOW fds (9/10) collide with
# the shell's OWN redirection bookkeeping (bash saves/restores fds around
# compound-command redirections and command substitutions onto low free fds),
# so the fd the inner exec opened did not survive the group — proven live on
# bash 5.2.37: the very next `flock -w 5 9` failed "Bad file descriptor"
# (hidden by the group's own 2>/dev/null), the "5s timeout" handler fired
# spuriously, and EVERY critical section — the ephemeral-marker
# read-modify-write, the per-alias config.json route upsert, the exit
# un-fossilise — ran UNLOCKED while the comments claimed mutual exclusion.
# The interactive launch also leaked `bash: line 1: 10: Bad file descriptor`
# onto the operator's terminal.
#
# The competing trap is the reason low suppressed opens were tried at all:
# `exec 9>>FILE 2>/dev/null` (no braces) applies the 2>/dev/null to the
# CURRENT INTERACTIVE SHELL permanently — one provider launch silenced the
# terminal's stderr for the rest of its life.
#
# The correct shape is dynamic fd allocation: `exec {_cma_eph_fd}>>FILE` —
# the shell picks a guaranteed-free fd (no hardcoded number to collide) and
# stderr is never touched. This test exercises the SHIPPED function bodies
# (extracted verbatim from lib.sh, not re-typed) and proves:
#   1. the lock is really HELD (an external flock contender times out),
#   2. it is really RELEASED on unlock (the contender then acquires),
#   3. stderr survives the whole sequence,
#   4. no "Bad file descriptor" appears anywhere,
#   5. two racing writers under the lock produce the exact serialized count
#      (the lost-update race the lock exists to prevent),
#   6. lint: hardcoded-fd opens and brace-group opens never return.
#
# Capture note: proofs run in `( exec 2>FILE; ... )` subshells, NOT
# `out="$( ... )" 2>FILE` — fd games inside a command substitution interact
# with the substitution's own fd save/restore and can bypass the outer
# redirection (the same collision class this test exists to catch).
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
set +e

LIB="$SCRIPTS_DIR/lib.sh"

# --- extraction: pull the SHIPPED function bodies out of lib.sh -------------
# The functions are nested inside the emitted cma_run_provider body at 4-space
# indent; the awk range runs from the definition line to the matching closing
# brace at the same indent. If a refactor moves them, this test must fail
# loudly rather than grade nothing.
extract_fn() { # $1=name -> prints body
  awk -v n="$1" '
    $0 ~ "^    " n "\\(\\) \\{" { inf=1 }
    inf { print }
    inf && /^    \}/ { exit }
  ' "$LIB"
}

eph_lock_body="$(extract_fn _cma_eph_lock)"
eph_unlock_body="$(extract_fn _cma_eph_unlock)"
cfg_lock_body="$(extract_fn _cma_cfg_lock)"
cfg_unlock_body="$(extract_fn _cma_cfg_unlock)"

it "lock functions extractable from shipped lib.sh"
[[ "$eph_lock_body" == *"_cma_eph_lock()"* && "$eph_lock_body" == *'flock -w 5 "$_cma_eph_fd"'* ]] \
  && _pass "_cma_eph_lock extracted" || _fail "_cma_eph_lock extraction" "body missing or changed shape"
[[ "$cfg_lock_body" == *"_cma_cfg_lock()"* && "$cfg_lock_body" == *'flock -w 5 "$_cma_cfg_fd"'* ]] \
  && _pass "_cma_cfg_lock extracted" || _fail "_cma_cfg_lock extraction" "body missing or changed shape"

it "lint: no hardcoded-fd or brace-group lock opens in code (comments ignored)"
# Strip comment lines before matching — the analysis comments quote the broken
# shapes verbatim, and they SHOULD (they are the historical record).
code_only="$(grep -v '^[[:space:]]*#' "$LIB")"
for bad in '{ exec 9>>' '{ exec 10>>' 'exec 9>>"$_eph_lock"' 'exec 10>>"$_lock"'; do
  if printf '%s\n' "$code_only" | grep -qF "$bad"; then
    _fail "forbidden lock-open shape in code" "'$bad' present in lib.sh code"
  else
    _pass "code lacks '$bad'"
  fi
done

it "lint: locks use dynamic fd allocation"
assert_file_contains "$LIB" 'exec {_cma_eph_fd}>>"$_eph_lock" || return 0' "eph open shape"
assert_file_contains "$LIB" 'exec {_cma_cfg_fd}>>"$_lock" || return 0'     "cfg open shape"

if ! command -v flock >/dev/null 2>&1; then
  # macOS: the toolkit degrades to the documented unlocked best-effort path
  # there, so the behavioral half is Linux-only by construction.
  it "behavioral lock proofs (flock present)"
  _fail "flock not available" "behavioral proofs require flock (Linux); suite must run them where the locks are live"
  summary; exit $?
fi

# --- behavioral: define the SHIPPED bodies in a subshell --------------------
eval "$eph_lock_body"
eval "$eph_unlock_body"
eval "$cfg_lock_body"
eval "$cfg_unlock_body"

lockdir="$SANDBOX_HOME/locks"; mkdir -p "$lockdir"

it "eph lock is really HELD, really RELEASED, stderr alive"
(
  exec 2>"$lockdir/stderr.txt"
  _eph_lock="$lockdir/eph.lock"
  _cma_eph_fd=""
  _cma_eph_lock
  # While we hold it, an INDEPENDENT process must fail to take the same lock.
  flock -w 1 "$lockdir/eph.lock" -c true 2>/dev/null
  printf 'contender_rc=%d\n' "$?" > "$lockdir/eph.contender"
  echo "stderr-survives-lock" >&2
  _cma_eph_unlock
  flock -w 2 "$lockdir/eph.lock" -c true 2>/dev/null
  printf 'post_release_rc=%d\n' "$?" > "$lockdir/eph.post"
)
assert_file_contains "$lockdir/stderr.txt" "stderr-survives-lock" "stderr survives the lock/unlock"
cont_rc="$(sed -n 's/^contender_rc=//p' "$lockdir/eph.contender")"
post_rc="$(sed -n 's/^post_release_rc=//p' "$lockdir/eph.post")"
[[ -n "$cont_rc" && "$cont_rc" != "0" ]] && _pass "external contender blocked while held (rc=$cont_rc)" \
  || _fail "lock NOT held" "external contender acquired the lock while we held it (rc=$cont_rc)"
assert_eq "0" "$post_rc" "contender acquires after unlock"
assert_file_not_contains "$lockdir/stderr.txt" "Bad file descriptor" "eph sequence clean"

it "cfg lock is really HELD, really RELEASED, stderr alive"
cfgfile="$lockdir/cfg.json"; printf '{}\n' > "$cfgfile"
(
  exec 2>"$lockdir/stderr2.txt"
  _cma_cfg_fd=""
  _cma_cfg_lock "$cfgfile"
  flock -w 1 "$cfgfile.lock" -c true 2>/dev/null
  printf 'contender_rc=%d\n' "$?" > "$lockdir/cfg.contender"
  echo "stderr-survives-cfg-lock" >&2
  _cma_cfg_unlock
  flock -w 2 "$cfgfile.lock" -c true 2>/dev/null
  printf 'post_release_rc=%d\n' "$?" > "$lockdir/cfg.post"
)
assert_file_contains "$lockdir/stderr2.txt" "stderr-survives-cfg-lock" "stderr survives the cfg lock/unlock"
cont_rc="$(sed -n 's/^contender_rc=//p' "$lockdir/cfg.contender")"
post_rc="$(sed -n 's/^post_release_rc=//p' "$lockdir/cfg.post")"
[[ -n "$cont_rc" && "$cont_rc" != "0" ]] && _pass "external contender blocked while held (rc=$cont_rc)" \
  || _fail "cfg lock NOT held" "external contender acquired the lock while we held it (rc=$cont_rc)"
assert_eq "0" "$post_rc" "contender acquires after cfg unlock"
assert_file_not_contains "$lockdir/stderr2.txt" "Bad file descriptor" "cfg sequence clean"

it "mutual exclusion: racing writers serialize to the exact count"
# The lost-update race the lock exists to prevent: two writers each doing 40
# read-increment-write cycles MUST end at 80 if and only if the lock is real.
# Without the lock this fails with near-certainty (each cycle sleeps between
# read and write, so the interleaving drops updates). Proven against the
# pre-fix code: it ended at 40.
counter="$lockdir/counter"; printf '0\n' > "$counter"
racer() {
  local i n _cma_cfg_fd=""
  for (( i = 0; i < 40; i++ )); do
    _cma_cfg_lock "$counter"
    n="$(cat "$counter")"
    sleep 0.01   # widen the read/write window so an unlocked run MUST collide
    printf '%d\n' "$(( n + 1 ))" > "$counter"
    _cma_cfg_unlock
  done
}
racer & r1=$!
racer & r2=$!
wait "$r1" "$r2"
assert_eq "80" "$(cat "$counter")" "two racing writers x 40 increments"

it "unfossilise early returns release the cfg lock (fd-leak audit 2026-07-25)"
# _cma_ccr_unfossilise takes the cfg lock, then has TWO early returns (CAS-1
# mismatch; mktemp failure). In the operator's INTERACTIVE shell a leaked
# flock is never kernel-released (the shell never dies): every later cfg-lock
# on that config stalls the full 5s budget and degrades to unlocked, and each
# occurrence leaks one fd. Both returns must pass through _cma_cfg_unlock.
unf_body="$(extract_fn _cma_ccr_unfossilise)"
[[ "$unf_body" == *"_cma_ccr_unfossilise()"* ]] \
  && _pass "_cma_ccr_unfossilise extracted" || _fail "_cma_ccr_unfossilise extraction" "body missing"
eval "$unf_body"
uf_cfg="$lockdir/uf.json"
printf '%s\n' '{"Providers":[{"name":"testprov","api_base_url":"http://OTHER/v1/chat/completions","api_key":"k","models":["m"]}],"Router":{"default":"testprov,m"}}' > "$uf_cfg"
(
  exec 2>"$lockdir/stderr3.txt"
  _cma_cfg_fd=""
  printf 'fds_before=%d\n' "$(ls /proc/self/fd | wc -l)" > "$lockdir/uf.cas1"
  # CAS-1 fires: the stored api_base_url (http://OTHER/...) is NOT our eph.
  _cma_ccr_unfossilise "$uf_cfg" testprov "http://127.0.0.1:39999/v1/chat/completions" \
    "https://real.example/v1/chat/completions" "testprov,m" "testprov,m" "" "" "$lockdir/eph-marker.json"
  # Measured INSIDE the subshell that held the lock: a leaked lock fd would
  # still be open here (measuring in the parent would be vacuous — a leak
  # dies with the subshell).
  printf 'fds_after=%d\n' "$(ls /proc/self/fd | wc -l)" >> "$lockdir/uf.cas1"
  printf 'fd_after_return=%s\n' "${_cma_cfg_fd:-EMPTY}" >> "$lockdir/uf.cas1"
  # The lock must be FREE: an external contender acquires immediately.
  flock -w 1 "$uf_cfg.lock" -c true 2>/dev/null
  printf 'lock_free_rc=%d\n' "$?" >> "$lockdir/uf.cas1"
)
assert_file_contains "$lockdir/uf.cas1" "fd_after_return=EMPTY" "CAS-1 early return clears the fd var"
assert_file_contains "$lockdir/uf.cas1" "lock_free_rc=0"     "CAS-1 early return releases the flock"
_uf_b="$(sed -n 's/^fds_before=//p' "$lockdir/uf.cas1")"; _uf_a="$(sed -n 's/^fds_after=//p' "$lockdir/uf.cas1")"
assert_eq "$_uf_b" "$_uf_a" "no fd leaked by the CAS-1 early return (measured inside the holding shell)"
# mktemp-failure path: CAS-1 passes (addr matches), mktemp is stubbed to fail.
printf '%s\n' '{"Providers":[{"name":"testprov","api_base_url":"http://EPH/v1/chat/completions","api_key":"k","models":["m"]}],"Router":{"default":"testprov,m"}}' > "$uf_cfg"
(
  exec 2>"$lockdir/stderr4.txt"
  _cma_cfg_fd=""
  printf 'fds_before=%d\n' "$(ls /proc/self/fd | wc -l)" > "$lockdir/uf.mktemp"
  mktemp() { return 1; }
  _cma_ccr_unfossilise "$uf_cfg" testprov "http://EPH/v1/chat/completions" \
    "https://real.example/v1/chat/completions" "testprov,m" "testprov,m" "" "" "$lockdir/eph-marker.json"
  printf 'fds_after=%d\n' "$(ls /proc/self/fd | wc -l)" >> "$lockdir/uf.mktemp"
  printf 'fd_after_return=%s\n' "${_cma_cfg_fd:-EMPTY}" >> "$lockdir/uf.mktemp"
  unset -f mktemp
  flock -w 1 "$uf_cfg.lock" -c true 2>/dev/null
  printf 'lock_free_rc=%d\n' "$?" >> "$lockdir/uf.mktemp"
)
assert_file_contains "$lockdir/uf.mktemp" "fd_after_return=EMPTY" "mktemp-fail early return clears the fd var"
assert_file_contains "$lockdir/uf.mktemp" "lock_free_rc=0"        "mktemp-fail early return releases the flock"
_uf_b="$(sed -n 's/^fds_before=//p' "$lockdir/uf.mktemp")"; _uf_a="$(sed -n 's/^fds_after=//p' "$lockdir/uf.mktemp")"
assert_eq "$_uf_b" "$_uf_a" "no fd leaked by the mktemp-fail early return (measured inside the holding shell)"

summary
