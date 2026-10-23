#!/usr/bin/env bash
# test_jev_kimi_lock.sh — the Kimi config lock (round-6 fix of the round-5 review).
#
# Every case here drives the REAL scripts (scripts/jev-kimi-lib.sh, scripts/jev-setup.sh,
# scripts/claude-providers.sh) through their real entry points - nothing re-implements or
# text-extracts the guarded logic.
#
#   K1  mutual exclusion under N=8 contenders, 20 runs each, on the mkdir backend:
#         (a) a STALE lockdir (dead holder pid)   (b) a lock that GOES stale mid-run
#       asserted by an enter/exit marker log written INSIDE the critical section
#       (max concurrency must be 1, every contender must enter, none may fail).
#       CONTROLS: with no lock the same harness MUST see overlap (positive control: the
#       harness can see a violation); the flock backend MUST show none (negative control).
#   K2  a stale lockdir with a dead pid is acquired            (kills "never breaks stale")
#   K3  the pid file exists and equals the holder              (kills "never writes its pid")
#   K4  nested acquire: the inner release must not drop the outer lock   (both backends)
#   K5  flock wait timeout is a FAILURE: jev-setup exits 1, "nothing written", no stamp,
#       config unchanged                                        (kills "-w timeout fails open")
#   K6  the hooks block is decided UNDER the lock               (kills "block computed before")
#   K7  refresh: an unterminated / variant BEGIN leaves the file untouched, warns, returns
#       nonzero; a well-formed block is replaced; blank lines outside the block survive
#   K8  jev-setup does not hold the config lock while a slow child runs, and no child
#       outlives its parent holding the lock
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${CMA_TEST_SCRIPTS_DIR:-$(cd "$TESTS_DIR/.." && pwd)}"
export SCRIPTS_DIR
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required"; exit 0; }
set +e
unset JEV_MODE JEV_STATE_DIR JEV_BASE_URL JEV_API_KEY JEV_CA_FILE JEV_GATE JEV_SETUP_CONSENT JEV_KIMI_LOCK_WAIT JEV_KIMI_LOCK_NO_FLOCK
export CMA_JEV_ALLOW_HTTP=1

BASE="$SANDBOX_HOME"
LIB="$SCRIPTS_DIR/jev-kimi-lib.sh"
SETUP="$SCRIPTS_DIR/jev-setup.sh"
PROVS="$SCRIPTS_DIR/claude-providers.sh"
RUNS="${JEV_LOCK_STRESS_RUNS:-20}"
NCONT=8
HAVE_FLOCK=0; command -v flock >/dev/null 2>&1 && HAVE_FLOCK=1
N=0

# --- the contender: a real process that sources the real lib and logs E/X INSIDE the section ---
cat > "$BASE/contender.sh" <<'EOF'
#!/usr/bin/env bash
mode=$1 sd=$2 log=$3 barrier=$4 lib=$5
. "$lib" || exit 9
while [ ! -e "$barrier" ]; do sleep 0.005; done
if [ "$mode" = lock ]; then jev_kimi_lock "$sd" || { echo "F $$" >> "$log"; exit 3; }; fi
echo "E $$" >> "$log"; sleep 0.03; echo "X $$" >> "$log"
[ "$mode" = lock ] && jev_kimi_unlock
exit 0
EOF

# _stress <lock|nolock> <nf:1=mkdir backend,0=flock> <none|stale|fresh> [fakebin]  -> "max enters fails"
# fakebin = a directory prepended to PATH for the contenders (used to substitute a racy mkdir)
_stress() {
  local mode=$1 nf=$2 setup=$3 fakebin="${4-}" sd log barrier i hp
  sd="$(mktemp -d "$BASE/sd.XXXXXX")"; log="$sd.log"; barrier="$sd.go"; : > "$log"
  case "$setup" in
    stale) sleep 0 & hp=$!; wait "$hp" 2>/dev/null
           mkdir "$sd/kimi-config.lock.d"; echo "$hp" > "$sd/kimi-config.lock.d/pid" ;;
    fresh) sleep 0.7 & hp=$!
           mkdir "$sd/kimi-config.lock.d"; echo "$hp" > "$sd/kimi-config.lock.d/pid" ;;
  esac
  for i in $(seq 1 $NCONT); do
    env PATH="${fakebin:+$fakebin:}$PATH" JEV_KIMI_LOCK_NO_FLOCK="$nf" JEV_KIMI_LOCK_WAIT=120 bash "$BASE/contender.sh" "$mode" "$sd" "$log" "$barrier" "$LIB" >/dev/null 2>&1 &
  done
  sleep 0.2; : > "$barrier"
  wait 2>/dev/null
  awk '$1=="E"{c++; e++; if(c>m)m=c} $1=="X"{c--} $1=="F"{f++} END{print m+0, e+0, f+0}' "$log"
  rm -rf "$sd" "$log" "$barrier"
}
_stress_series() { # <lock|nolock> <nf> <setup> <runs> [fakebin] -> "overlapped_runs bad_runs"
  local mode=$1 nf=$2 setup=$3 runs=$4 fakebin="${5-}" r out ov=0 bad=0 m e f
  for r in $(seq 1 "$runs"); do
    out="$(_stress "$mode" "$nf" "$setup" "$fakebin")"; read -r m e f <<<"$out"
    [ "${m:-0}" -gt 1 ] && ov=$((ov + 1))
    { [ "${m:-0}" -ne 1 ] || [ "${e:-0}" -ne $NCONT ] || [ "${f:-0}" -ne 0 ]; } && bad=$((bad + 1))
  done
  echo "$ov $bad"
}

it "K1-control: with NO lock the harness sees overlap (it can detect a violation)"
read -r ov bad <<<"$(_stress_series nolock 1 none 5)"
[ "$ov" -ge 1 ] && _pass "overlap detected in $ov/5 unlocked runs" || _fail "harness blind: no overlap seen without a lock"

it "K1a: mkdir backend, STALE lockdir (dead pid), $NCONT contenders x $RUNS runs: max concurrency 1, all enter, none fail"
read -r ov bad <<<"$(_stress_series lock 1 stale "$RUNS")"
assert_eq 0 "$ov" "runs with overlapping critical sections (of $RUNS)"
assert_eq 0 "$bad" "runs with max!=1, a contender not entering, or a lock failure (of $RUNS)"

it "K1b: mkdir backend, lock that GOES stale mid-run (live holder exits), $NCONT contenders x $RUNS runs"
read -r ov bad <<<"$(_stress_series lock 1 fresh "$RUNS")"
assert_eq 0 "$ov" "runs with overlapping critical sections (of $RUNS)"
assert_eq 0 "$bad" "runs with max!=1, a contender not entering, or a lock failure (of $RUNS)"

it "K1c: flock backend (negative control), $NCONT contenders x 5 runs"
if [ "$HAVE_FLOCK" = 1 ]; then
  read -r ov bad <<<"$(_stress_series lock 0 none 5)"
  assert_eq 0 "$ov" "flock runs with overlap (of 5)"
  assert_eq 0 "$bad" "flock runs with max!=1/non-entry/failure (of 5)"
else _skip "flock(1) not installed"; fi

it "K1d: mkdir is NOT atomic on this host class (uutils coreutils reports an EEXIST race as success) - the lock must not rest on it"
# Measured 2026-10-23 on uutils coreutils 0.8.0: 6 racing `mkdir d` calls gave more than one
# winner in 66 of 200 rounds. The fake mkdir below reproduces that failure deterministically:
# mkdir on an EXISTING directory reports success. A lock whose exclusion rests on mkdir's
# exit status alone then lets every contender in.
FAKEBIN="$BASE/fakebin"; mkdir -p "$FAKEBIN"
REALMKDIR="$(command -v mkdir)"
{
  echo '#!/bin/sh'
  echo '# racy mkdir emulation: an existing target directory is reported as created'
  echo 'if [ "$#" -eq 1 ] && [ -d "$1" ]; then exit 0; fi'
  echo "exec \"$REALMKDIR\" \"\$@\""
} > "$FAKEBIN/mkdir"
chmod +x "$FAKEBIN/mkdir"
td="$(mktemp -d "$BASE/k1d.XXXXXX")"; mkdir "$td/x"
PATH="$FAKEBIN:$PATH" mkdir "$td/x" && _pass "control: the substituted mkdir reports success on an existing dir (reproduces the host defect)" || _fail "control: the substituted mkdir did not reproduce the defect"
mkdir "$td/x" 2>/dev/null && _fail "control: the real mkdir reports success on an existing dir" || _pass "control: the real mkdir still fails on an existing dir"
read -r ov bad <<<"$(_stress_series lock 1 none "$RUNS" "$FAKEBIN")"
assert_eq 0 "$ov" "racy-mkdir host: runs with overlapping critical sections (of $RUNS)"
assert_eq 0 "$bad" "racy-mkdir host: runs with max!=1 / a contender not entering / a lock failure (of $RUNS)"
read -r ov bad <<<"$(_stress_series lock 1 fresh "$RUNS" "$FAKEBIN")"
assert_eq 0 "$ov" "racy-mkdir host, lock goes stale mid-run: overlapping runs (of $RUNS)"
assert_eq 0 "$bad" "racy-mkdir host, lock goes stale mid-run: bad runs (of $RUNS)"

_lockrc() { # _lockrc <nf> <state-dir> [wait] -> rc of a fresh process taking the lock once
  # time-bounded: a lock that never gives up (deadline not enforced) must surface as rc 124 (a
  # failed assertion), not as a hung suite
  timeout -k 2 25 env JEV_KIMI_LOCK_NO_FLOCK="$1" JEV_KIMI_LOCK_WAIT="${3:-3}" bash -c '. "$1"; jev_kimi_lock "$2"; echo $?' _ "$LIB" "$2" 2>/dev/null | tail -1
  [ "${PIPESTATUS[0]}" -eq 124 ] && echo 124
}

it "K2: a stale lockdir with a dead pid is broken and acquired"
SD="$(mktemp -d "$BASE/k2.XXXXXX")"
sleep 0 & hp=$!; wait "$hp" 2>/dev/null
mkdir "$SD/kimi-config.lock.d"; echo "$hp" > "$SD/kimi-config.lock.d/pid"
assert_eq 0 "$(_lockrc 1 "$SD" 3)" "lock acquired over a dead holder (wait 3s)"

it "K2b: a LIVE holder is never broken (acquire times out)"
SD="$(mktemp -d "$BASE/k2b.XXXXXX")"
( mkdir "$SD/kimi-config.lock.d"; echo "$BASHPID" > "$SD/kimi-config.lock.d/pid"; sleep 4 ) & hv=$!
sleep 0.4
assert_eq 1 "$(_lockrc 1 "$SD" 1)" "rc 1 while a live process holds the lockdir"
wait "$hv" 2>/dev/null

it "K2e: the stale breaker re-reads the lock and never removes a lock that changed owner or is alive (observed-pid compare)"
SD="$(mktemp -d "$BASE/k2e.XXXXXX")"; LD="$SD/kimi-config.lock.d"
( : ) & dead=$!; wait "$dead" 2>/dev/null          # a pid that has really exited
sleep 30 >/dev/null 2>&1 & live=$!
mkdir "$LD"; echo "$live" > "$LD/pid"
bash -c '. "$1"; _cma_lockdir_break_stale "$2" "$3"' _ "$SCRIPTS_DIR/jev-lockdir-lib.sh" "$LD" "$dead" 2>/dev/null
[ -d "$LD" ] && [ "$(cat "$LD/pid" 2>/dev/null)" = "$live" ] && _pass "lock re-taken by a live owner after we observed a dead one: not removed" || _fail "breaker removed a live owner's lock (stale observation)"
bash -c '. "$1"; _cma_lockdir_break_stale "$2" "$3"' _ "$SCRIPTS_DIR/jev-lockdir-lib.sh" "$LD" "$live" 2>/dev/null
[ -d "$LD" ] && _pass "observed == current but the owner is alive: not removed" || _fail "breaker removed a lock whose owner is alive"
echo "$dead" > "$LD/pid"
bash -c '. "$1"; _cma_lockdir_break_stale "$2" "$3"' _ "$SCRIPTS_DIR/jev-lockdir-lib.sh" "$LD" "$dead" 2>/dev/null
[ ! -d "$LD" ] && _pass "observed == current and the owner is dead: removed (positive control)" || _fail "breaker did not remove a genuinely stale lock"
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null

it "K2f: a breaker that is already held is not entered even when mkdir wrongly reports success on it (O_EXCL breaker claim)"
# The breaker lock keeps two stale-breakers from interleaving (one could remove the lock a
# new owner just took). On a host whose mkdir reports an EEXIST race as success (K1d), mkdir
# alone cannot tell "I created the breaker" from "somebody else holds it": only the pid claim can.
SD="$(mktemp -d "$BASE/k2f.XXXXXX")"; LD="$SD/kimi-config.lock.d"; BR="$LD.breaker"
( : ) & dead=$!; wait "$dead" 2>/dev/null
sleep 30 >/dev/null 2>&1 & live=$!
mkdir "$LD"; echo "$dead" > "$LD/pid"
mkdir "$BR"; echo "$live" > "$BR/pid"               # another process is mid-break
PATH="$FAKEBIN:$PATH" bash -c '. "$1"; _cma_lockdir_break_stale "$2" "$3"' _ "$SCRIPTS_DIR/jev-lockdir-lib.sh" "$LD" "$dead" 2>/dev/null
[ -d "$LD" ] && [ "$(cat "$LD/pid" 2>/dev/null)" = "$dead" ] && _pass "breaker held by a live process: the stale lock is left to its owner (racy-mkdir host)" || _fail "a second breaker entered while the breaker was held"
[ "$(cat "$BR/pid" 2>/dev/null)" = "$live" ] && _pass "the held breaker's pid file is untouched" || _fail "the held breaker was overwritten or removed"
rm -f "$BR/pid"; rmdir "$BR" 2>/dev/null           # positive control: no breaker held
PATH="$FAKEBIN:$PATH" bash -c '. "$1"; _cma_lockdir_break_stale "$2" "$3"' _ "$SCRIPTS_DIR/jev-lockdir-lib.sh" "$LD" "$dead" 2>/dev/null
[ ! -d "$LD" ] && [ ! -d "$BR" ] && _pass "positive control: with no breaker held the stale lock is removed and the breaker released" || _fail "positive control failed: stale lock or breaker left behind"
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null

it "K3: the lockdir pid file exists during the critical section and equals the holder"
SD="$(mktemp -d "$BASE/k3.XXXXXX")"
out="$(JEV_KIMI_LOCK_NO_FLOCK=1 bash -c '. "$1"; jev_kimi_lock "$2" || exit 9; printf "%s %s\n" "$$" "$(cat "$2/kimi-config.lock.d/pid" 2>/dev/null)"' _ "$LIB" "$SD")"
read -r me recorded <<<"$out"
assert_eq "$me" "$recorded" "pid file == holder pid"
[ -n "$me" ] && [ "$me" = "$recorded" ] && _pass "non-empty" || _fail "no pid recorded"

it "K2c: an EMPTY pid file (holder died between the O_EXCL create and the pid write) is broken only after the grace period"
SD="$(mktemp -d "$BASE/k2c.XXXXXX")"
mkdir "$SD/kimi-config.lock.d"; : > "$SD/kimi-config.lock.d/pid"
# control: a short wait with a long grace must NOT break it (the grace is honoured, not skipped)
out="$(CMA_LOCKDIR_GRACE=30 JEV_KIMI_LOCK_NO_FLOCK=1 JEV_KIMI_LOCK_WAIT=2 bash -c '. "$1"; jev_kimi_lock "$2"; echo $?' _ "$LIB" "$SD" 2>/dev/null | tail -1)"
assert_eq 1 "$out" "empty pid file NOT broken before the grace period (grace 30s, wait 2s)"
out="$(CMA_LOCKDIR_GRACE=1 JEV_KIMI_LOCK_NO_FLOCK=1 JEV_KIMI_LOCK_WAIT=6 bash -c '. "$1"; jev_kimi_lock "$2"; echo $?' _ "$LIB" "$SD" 2>/dev/null | tail -1)"
assert_eq 0 "$out" "empty pid file acquired after grace 1s (wait 6s)"
SD="$(mktemp -d "$BASE/k2c2.XXXXXX")"; mkdir "$SD/kimi-config.lock.d"     # no pid file at all
out="$(CMA_LOCKDIR_GRACE=30 JEV_KIMI_LOCK_NO_FLOCK=1 JEV_KIMI_LOCK_WAIT=2 bash -c '. "$1"; jev_kimi_lock "$2"; echo $?' _ "$LIB" "$SD" 2>/dev/null | tail -1)"
assert_eq 0 "$out" "a lockdir with no pid file is claimed at once (no grace needed)"

it "K2d: release never removes a lock owned by ANOTHER process (owner-checked release)"
SD="$(mktemp -d "$BASE/k2d.XXXXXX")"
( mkdir "$SD/kimi-config.lock.d"; echo "$BASHPID" > "$SD/kimi-config.lock.d/pid"; sleep 3 ) & hv=$!
sleep 0.4
bash -c '. "$1"; cma_lockdir_release "$2/kimi-config.lock.d"' _ "$SCRIPTS_DIR/jev-lockdir-lib.sh" "$SD" 2>/dev/null
[ -d "$SD/kimi-config.lock.d" ] && [ "$(cat "$SD/kimi-config.lock.d/pid" 2>/dev/null)" = "$hv" ] && _pass "foreign lock intact after a stray release" || _fail "a release by a non-owner removed the lock"
wait "$hv" 2>/dev/null

it "K4: nested acquire - the inner release must NOT drop the outer lock"
for nf in 1 0; do
  [ "$nf" = 0 ] && [ "$HAVE_FLOCK" = 0 ] && { _skip "flock backend: flock(1) not installed"; continue; }
  SD="$(mktemp -d "$BASE/k4.XXXXXX")"
  out="$(JEV_KIMI_LOCK_NO_FLOCK=$nf JEV_KIMI_LOCK_WAIT=0 bash -c '
    . "$1"; sd="$2"
    probe() { JEV_KIMI_LOCK_WAIT=0 bash -c ". \"\$1\"; jev_kimi_lock \"\$2\"; echo \$?" _ "$1" "$sd" 2>/dev/null | tail -1; }
    jev_kimi_lock "$sd" || exit 9
    jev_kimi_lock "$sd" || exit 9
    jev_kimi_unlock
    a="$(probe "$1")"           # outer still held -> 1
    jev_kimi_unlock
    b="$(probe "$1")"           # fully released   -> 0
    echo "$a $b"' _ "$LIB" "$SD")"
  assert_eq "1 0" "$out" "backend nf=$nf: held after inner unlock (1), free after outer unlock (0)"
done

# --- a sandbox HOME with one kimi native home, one kimi twin, a cache and (optionally) keys ----
_cell() {
  N=$((N + 1))
  export HOME="$BASE/cell$N"
  export SHARED_DIR="$HOME/.claude-shared"
  mkdir -p "$HOME/.claude-acct1" "$HOME/.kimi-code-1" "$HOME/.kimi-prov-bar" "$SHARED_DIR" \
           "$HOME/.local/bin" "$HOME/.local/share/claude-multi-account/providers"
  echo '{"model":"opus"}' > "$HOME/.claude-acct1/settings.json"
  printf 'default_model = "k1"\n' > "$HOME/.kimi-code-1/config.toml"
  printf 'default_model = "b1"\n' > "$HOME/.kimi-prov-bar/config.toml"
  printf '{"version":1,"generated_at":1,"ttl":300,"endpoints":[{"provider_id":"p","base_url":"https://127.0.0.1:1","model":"m","priority":1}]}\n' \
    > "$HOME/.local/share/claude-multi-account/providers/jev-endpoints.json"
  SD="$HOME/.local/state/jev"
  STAMP="$SD/installed.stamp"; LOCKF="$SD/kimi-config.lock"
  GATE="$HOME/.local/share/claude-multi-account/jev/jev-gate.sh"
  KNAT="$HOME/.kimi-code-1/config.toml"; KPROV="$HOME/.kimi-prov-bar/config.toml"
}
_setup() { bash "$SETUP" --quiet "$@" >"$HOME/.out" 2>&1; echo $? > "$HOME/.rc"; }
_render() { bash -c 'source "$1" >/dev/null 2>&1; set +e; _cma_kimi_render_config bar BAR_KEY native https://api.example.invalid m-1 8192' _ "$PROVS" 2>"$HOME/.render.err"; }
_nhook() { grep -c 'cma-jev:hooks BEGIN' "$1" 2>/dev/null; }
_hold() { # _hold <flock|mkdir> <secs>: hold the config lock from ANOTHER live process, return once held
  mkdir -p "$SD"
  if [ "$1" = flock ]; then ( exec 9>>"$LOCKF"; flock 9; sleep "$2" ) >/dev/null 2>&1 &
  else ( mkdir "$SD/kimi-config.lock.d"; echo "$BASHPID" > "$SD/kimi-config.lock.d/pid"; sleep "$2"
         rm -f "$SD/kimi-config.lock.d/pid"; rmdir "$SD/kimi-config.lock.d" ) >/dev/null 2>&1 &
  fi
  HOLDER=$!; sleep 0.4
}

it "K5: flock wait timeout is a FAILURE - jev-setup exits 1, 'nothing written', no stamp, config unchanged"
if [ "$HAVE_FLOCK" = 1 ]; then
  _cell; before="$(sha256sum "$KNAT" | cut -d' ' -f1)"
  _hold flock 6
  JEV_KIMI_LOCK_WAIT=1 bash "$SETUP" --quiet --yes --agents kimi >"$HOME/.out" 2>&1; rc=$?
  assert_eq 1 "$rc" "jev-setup rc while the lock is held elsewhere"
  grep -q 'nothing written' "$HOME/.out" && _pass "reports 'nothing written'" || _fail "no 'nothing written' message" "$(cat "$HOME/.out")"
  [ ! -e "$STAMP" ] && _pass "no installed.stamp written" || _fail "stamp written despite the failed lock"
  assert_eq "$before" "$(sha256sum "$KNAT" | cut -d' ' -f1)" "native kimi config unchanged"
  assert_eq 0 "$(_nhook "$KNAT")" "no hook block written"
  kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
else _skip "flock(1) not installed"; fi

it "K6: the hooks block is decided UNDER the lock (consent revoked while the render waits)"
for be in flock mkdir; do
  [ "$be" = flock ] && [ "$HAVE_FLOCK" = 0 ] && { _skip "flock(1) not installed"; continue; }
  _cell; _setup --yes --agents kimi
  assert_eq 0 "$(cat "$HOME/.rc")" "[$be] precondition: install ok"
  [ -x "$GATE" ] && [ -s "$STAMP" ] && _pass "[$be] precondition: stamp + gate present" || _fail "[$be] no stamp/gate"
  _hold "$be" 2
  ( export JEV_KIMI_LOCK_NO_FLOCK=$([ "$be" = mkdir ] && echo 1 || echo 0) JEV_KIMI_LOCK_WAIT=20; _render ) & RP=$!
  sleep 0.5
  rm -f "$STAMP" "$GATE"                       # consent revoked + gate removed while the render is waiting
  wait "$RP" 2>/dev/null; wait "$HOLDER" 2>/dev/null
  assert_eq 0 "$(_nhook "$KPROV")" "[$be] no hook block rendered from the pre-lock (stale) state"
done

# --- K7: refresh ------------------------------------------------------------------------------
_refresh() { bash -c 'source "$1" >/dev/null 2>&1; set +e; _cma_kimi_jev_hooks_refresh; echo "rc=$?"' _ "$PROVS" 2>"$HOME/.refresh.err" | tail -1; }

it "K7a: variant BEGIN with no END (reviewer repro) - file untouched, warning, nonzero"
_cell; _setup --yes --agents kimi
printf 'default_model = "bar/m-1"\n\n# cma-jev:hooks BEGIN-stale (unterminated...)\nmodel_param = 1\n[providers.bar]\nbase_url = "https://x"\n' > "$KPROV"
cp "$KPROV" "$HOME/before.toml"
rc="$(_refresh)"
assert_eq "$(sha256sum "$HOME/before.toml" | cut -d' ' -f1)" "$(sha256sum "$KPROV" | cut -d' ' -f1)" "config byte-identical (no truncation after the variant BEGIN)"
grep -q 'model_param = 1' "$KPROV" && grep -q 'base_url = "https://x"' "$KPROV" && _pass "lines after the variant BEGIN survive" || _fail "lines after the variant BEGIN were deleted"
[ "$rc" != "rc=0" ] && _pass "refresh returns nonzero ($rc)" || _fail "refresh returned 0 on a malformed block"
grep -q 'left untouched' "$HOME/.refresh.err" && _pass "warns on stderr" || _fail "no warning" "$(cat "$HOME/.refresh.err")"

it "K7b: exact BEGIN marker with no END - file untouched, warning, nonzero"
_cell; _setup --yes --agents kimi
printf 'default_model = "bar/m-1"\n\n# cma-jev:hooks BEGIN\n[[hooks]]\nevent = "PreToolUse"\n\n[providers.bar]\nbase_url = "https://x"\n' > "$KPROV"
cp "$KPROV" "$HOME/before.toml"
rc="$(_refresh)"
assert_eq "$(sha256sum "$HOME/before.toml" | cut -d' ' -f1)" "$(sha256sum "$KPROV" | cut -d' ' -f1)" "config byte-identical"
[ "$rc" != "rc=0" ] && _pass "refresh returns nonzero ($rc)" || _fail "refresh returned 0 on an unterminated block"
grep -q 'left untouched' "$HOME/.refresh.err" && _pass "warns on stderr" || _fail "no warning" "$(cat "$HOME/.refresh.err")"

it "K7c: a well-formed block is replaced, rc 0, blank lines OUTSIDE the block are kept"
_cell; _setup --yes --agents kimi
printf 'default_model = "bar/m-1"\n\n\n[providers.bar]\nbase_url = "https://x"\n\n# cma-jev:hooks BEGIN\n[[hooks]]\nevent = "PreToolUse"\nmatcher = "OLD"\ncommand = "/gone"\ntimeout = 5\n# cma-jev:hooks END\n' > "$KPROV"
rc="$(_refresh)"
assert_eq "rc=0" "$rc" "refresh rc"
assert_eq 1 "$(_nhook "$KPROV")" "exactly one block"
grep -q 'matcher = "OLD"' "$KPROV" && _fail "old block content survived" || _pass "old block content replaced"
blank_run="$(sed -n '2,3p' "$KPROV" | grep -c '^$')"
assert_eq 2 "$blank_run" "two consecutive blank lines outside the block not collapsed"
before="$(sha256sum "$KPROV" | cut -d' ' -f1)"; rc2="$(_refresh)"
assert_eq "$before" "$(sha256sum "$KPROV" | cut -d' ' -f1)" "second refresh is a byte-identical no-op"

# --- K8: lock scope in jev-setup ----------------------------------------------------------------
_stubs() { # fake npm/pi: pi 'installs' for 3s and leaves a background child behind
  mkdir -p "$HOME/stubbin"
  cat > "$HOME/stubbin/npm" <<'EOF'
#!/bin/sh
exit 0
EOF
  cat > "$HOME/stubbin/pi" <<'EOF'
#!/bin/sh
: > "$HOME/pi.ran"
( sleep 15 >/dev/null 2>&1 & )
sleep 3
exit 0
EOF
  chmod +x "$HOME/stubbin/npm" "$HOME/stubbin/pi"
  mkdir -p "$HOME/.pi-1"
}

it "K8a: a concurrent render succeeds while a slow pi child runs (jev-setup holds no config lock then)"
if [ "$HAVE_FLOCK" = 1 ]; then
  _cell; _stubs
  PATH="$HOME/stubbin:$PATH" bash "$SETUP" --quiet --yes --agents pi >"$HOME/.out" 2>&1 & SP=$!
  sleep 1.2
  t0=$SECONDS
  ( export JEV_KIMI_LOCK_WAIT=1; _render ); rrc=$?
  el=$((SECONDS - t0))
  assert_eq 0 "$rrc" "render rc while the pi installer sleeps"
  [ -e "$HOME/pi.ran" ] && _pass "pi stub really ran" || _fail "pi stub never ran - test would be vacuous"
  [ "$el" -le 2 ] && _pass "render did not wait for the installer (${el}s)" || _fail "render blocked ${el}s behind the installer"
  wait "$SP" 2>/dev/null
else _skip "flock(1) not installed"; fi

it "K8b: no child outlives jev-setup holding the config lock (backgrounded pi child)"
if [ "$HAVE_FLOCK" = 1 ]; then
  _cell; _stubs
  PATH="$HOME/stubbin:$PATH" bash "$SETUP" --quiet --yes --agents pi >"$HOME/.out" 2>&1
  [ -e "$HOME/pi.ran" ] && _pass "pi stub really ran" || _fail "pi stub never ran - test would be vacuous"
  flock -n "$LOCKF" -c true 2>/dev/null && _pass "lock free after jev-setup exits although its child still runs" || _fail "a child of jev-setup still holds the config lock"
else _skip "flock(1) not installed"; fi

it "K8c: no child spawned INSIDE a locked section inherits the lock (api_keys.sh background child, --agents kimi)"
if [ "$HAVE_FLOCK" = 1 ]; then
  _cell
  printf ': > "$HOME/keys.ran"\n( sleep 15 >/dev/null 2>&1 & )\nexport JEV_TEST_KEY=abc\n' > "$HOME/keys.sh"
  printf '{"version":1,"generated_at":1,"ttl":300,"endpoints":[{"provider_id":"p","base_url":"https://127.0.0.1:1","model":"m","priority":1,"key_var":"JEV_TEST_KEY"}]}\n' \
    > "$HOME/.local/share/claude-multi-account/providers/jev-endpoints.json"
  CMA_KEYS_FILE="$HOME/keys.sh" bash "$SETUP" --quiet --yes --agents kimi >"$HOME/.out" 2>&1; rc=$?
  assert_eq 0 "$rc" "jev-setup rc"
  [ -e "$HOME/keys.ran" ] && _pass "keys file was really sourced (child spawned)" || _fail "keys file never sourced - test would be vacuous"
  flock -n "$LOCKF" -c true 2>/dev/null && _pass "lock free after jev-setup exits although the keys-file child still runs" || _fail "the keys-file child inherited the config lock"
else _skip "flock(1) not installed"; fi

it "K8d: a keys-file process still running when jev-setup is SIGKILLed does not keep the config lock"
if [ "$HAVE_FLOCK" = 1 ]; then
  _cell
  printf ': > "$HOME/keys.ran"\nsleep 25 >/dev/null 2>&1 &\necho $! > "$HOME/kid"\nwait\nexport JEV_TEST_KEY=abc\n' > "$HOME/keys.sh"
  printf '{"version":1,"generated_at":1,"ttl":300,"endpoints":[{"provider_id":"p","base_url":"https://127.0.0.1:1","model":"m","priority":1,"key_var":"JEV_TEST_KEY"}]}\n' \
    > "$HOME/.local/share/claude-multi-account/providers/jev-endpoints.json"
  CMA_KEYS_FILE="$HOME/keys.sh" bash "$SETUP" --quiet --yes --agents kimi >"$HOME/.out" 2>&1 & SP=$!
  n=0; while [ ! -s "$HOME/kid" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n+1)); done
  [ -s "$HOME/kid" ] && _pass "keys-file child is running inside the locked section" || _fail "keys file never reached its blocking point - test would be vacuous"
  flock -n "$LOCKF" -c true 2>/dev/null && _fail "lock not held while jev-setup is inside the kimi section - test would be vacuous" || _pass "lock is held inside the section (positive control)"
  kill -9 "$SP" 2>/dev/null; wait "$SP" 2>/dev/null
  sleep 0.5
  flock -n "$LOCKF" -c true 2>/dev/null && _pass "lock free after SIGKILL although the keys-file process still runs" || _fail "the keys-file process inherited fd 7 and keeps the config lock"
  kid="$(cat "$HOME/kid" 2>/dev/null)"; [ -n "$kid" ] && kill "$kid" 2>/dev/null
  # the orphaned keys-file shell exits once its sleep is gone
  sleep 0.3
else _skip "flock(1) not installed"; fi

it "K9: the Kimi config section takes the lock itself (a holder appearing AFTER the pre-flight probe blocks it)"
if [ "$HAVE_FLOCK" = 1 ]; then
  _cell
  # The keys file is sourced by the claude step, which runs BEFORE the kimi section and after the
  # pre-flight probe: it starts a detached holder of the config lock and waits until it really holds it.
  printf '( flock -x "%s" -c ": > \"%s/held\"; sleep 8" >/dev/null 2>&1 7>&- & )\nn=0; while [ ! -e "%s/held" ] && [ $n -lt 40 ]; do sleep 0.1; n=$((n+1)); done\nexport JEV_TEST_KEY=abc\n' \
    "$LOCKF" "$HOME" "$HOME" > "$HOME/keys.sh"
  printf '{"version":1,"generated_at":1,"ttl":300,"endpoints":[{"provider_id":"p","base_url":"https://127.0.0.1:1","model":"m","priority":1,"key_var":"JEV_TEST_KEY"}]}\n' \
    > "$HOME/.local/share/claude-multi-account/providers/jev-endpoints.json"
  before="$(cat "$KNAT")"
  JEV_KIMI_LOCK_WAIT=2 CMA_KEYS_FILE="$HOME/keys.sh" bash "$SETUP" --quiet --yes --agents claude,kimi >"$HOME/.out" 2>&1; rc=$?
  [ -e "$HOME/held" ] && _pass "the holder really held the lock (test not vacuous)" || _fail "holder never started - test would be vacuous"
  assert_eq 1 "$rc" "jev-setup rc when the kimi section cannot take the lock"
  grep -q 'remaining steps skipped' "$HOME/.out" && _pass "reports the skipped steps" || _fail "no 'remaining steps skipped' message: $(cat "$HOME/.out")"
  assert_eq "$before" "$(cat "$KNAT")" "kimi config untouched"
else _skip "flock(1) not installed"; fi

summary
