#!/usr/bin/env bash
# test_suite_lock.sh — prove that two test-suite runs cannot overlap.
#
# Why this exists (a real incident, not a hypothetical):
#
# A forensic investigation caught scripts/tests/run-proof.sh (PID 170365)
# executing concurrently with scripts/tests/run-all.sh (PID 581986) while a
# third agent created a new test file mid-run. A repo that mutates while its
# own tests execute produces results that cannot be reproduced — that is the
# structural reason a set of deterministic tests appeared "flaky". Serializing
# suite runs removes that whole class of false signal, and this file is what
# keeps the serialization honest.
#
# What is covered:
#   1. the lock is actually WIRED INTO both entry points (run-all, run-proof)
#   2. a second concurrent run is refused, naming the holding PID  [flock]
#   3. the same, on the portable fallback used where flock is absent  [mkdir]
#   4. a stale lock owned by a dead PID does NOT wedge the suite  [both backends]
#   5. re-entrancy: run-proof -> run-all inherits instead of deadlocking
#   6. a FORGED inherit env var cannot bypass a real holder
#   7. the lock is released on Ctrl-C (SIGINT), not just on clean exit
#   8. the lock file never lands in the tracked tree
#
# Anti-vacuous-pass guards are marked inline: each contention assertion is
# paired with a control that must SUCCEED, so the test cannot pass by simply
# failing everything, and cannot pass at all if the locking were removed.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"
set +e

LOCKLIB="$TESTS_DIR/lib/suite-lock.sh"

make_sandbox

# This file runs UNDER run-all.sh, which holds the real suite lock and exports
# the inherit vars. Drop them and point every child at a sandbox-local lock
# home so nothing here can touch, inherit, or wedge the real one.
unset CMA_SUITE_LOCK_OWNER CMA_SUITE_LOCK_PATH CMA_SUITE_LOCK_NO_FLOCK
export CMA_SUITE_LOCK_DIR="$SANDBOX_HOME/lockhome"
mkdir -p "$CMA_SUITE_LOCK_DIR"

HOLDER_PIDS=()
# SIGTERM first: the holder traps it and exits cleanly, so the shell prints no
# "Killed" job notification into the test output. SIGKILL is only an escape
# hatch so a wedged holder can never hang the suite that is testing it.
kill_holders() {
  local p waited
  for p in ${HOLDER_PIDS[@]+"${HOLDER_PIDS[@]}"}; do
    kill -TERM "$p" 2>/dev/null
  done
  for p in ${HOLDER_PIDS[@]+"${HOLDER_PIDS[@]}"}; do
    waited=0
    while [[ $waited -lt 20 ]] && kill -0 "$p" 2>/dev/null; do
      sleep 0.1 2>/dev/null || sleep 1
      waited=$((waited + 1))
    done
    kill -KILL "$p" 2>/dev/null
  done
  wait 2>/dev/null
}
# Chain onto (not over) the sandbox cleanup make_sandbox installed.
trap 'kill_holders; cleanup_sandbox' EXIT

BIN="$SANDBOX_HOME/bin"
mkdir -p "$BIN"

# sigreset.sh — execs its arguments with SIGINT/SIGQUIT reset to SIG_DFL.
# See start_holder below for why a holder must not be born with SIG_IGN.
sandbox_stub "$BIN/sigreset.sh" <<'RESET_EOF'
#!/usr/bin/env bash
exec python3 -c '
import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
signal.signal(signal.SIGQUIT, signal.SIG_DFL)
os.execv("/bin/bash", sys.argv[1:])
' "$@"
RESET_EOF

# holder.sh — acquires the lock and sits on it.
#
# The sleep is BACKGROUNDED and waited on deliberately. Bash defers a trapped
# signal until the current FOREGROUND command finishes, so a plain `sleep 60`
# would swallow the SIGINT test's signal for a full minute. Interrupting the
# `wait` builtin runs the trap immediately — which is exactly the Ctrl-C
# behaviour a real suite run has.
sandbox_stub "$BIN/holder.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
source "$LOCKLIB"
cma_suite_lock_acquire suite
echo "HOLDER-ACQUIRED \$\$"
sleep "\${HOLD_FOR:-10}" &
wait \$!
EOF

# contender.sh — a stand-in for a second suite run.
sandbox_stub "$BIN/contender.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
source "$LOCKLIB"
cma_suite_lock_acquire suite
echo "CONTENDER-ACQUIRED \$\$"
EOF

# unlocked.sh — identical to contender.sh MINUS the locking. This is the
# anti-vacuous-pass instrument: it simulates "the lock was removed".
sandbox_stub "$BIN/unlocked.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
echo "CONTENDER-ACQUIRED \$\$"
EOF

# nested.sh — models run-proof.sh calling run-all.sh inside the same tree.
sandbox_stub "$BIN/nested.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
source "$LOCKLIB"
cma_suite_lock_acquire suite
echo "OUTER-ACQUIRED \$\$"
bash "$BIN/contender.sh"
echo "INNER-RC=\$?"
EOF

# start_holder [HOLD_SECONDS] — launch a background holder and block until it
# owns the lock.
#
# Sets HOLDER_PID; deliberately NOT called via $(...). Command substitution
# runs in a subshell, so `HOLDER_PIDS+=` there would be discarded and the
# holders would leak into later cases and poison them.
#
# SIGINT determinism, whatever way the suite itself was launched: POSIX gives a
# shell starting a NON-job-controlled background job a SIGINT/SIGQUIT of
# SIG_IGN, and bash forbids trapping or resetting a signal it inherited as
# ignored — so a plain `cmd &` holder is structurally deaf to Ctrl-C. This is
# not hypothetical for this file: run-all.sh is launched as a background/nohup
# job in production, so every holder spawned under it inherits SIG_IGN through
# the whole chain. The previous `set -m` jobctl mode only restored default
# dispositions when a controlling terminal was present, and silently failed to
# (leaving a deaf holder) when there was none — which is exactly what this file
# saw red under a real run-all launch. sigreset.sh reinstalls SIG_DFL at the OS
# level (glibc has no entry-ignored scruple) and execs the holder, so the trap
# below cannot fail for the scheduler's sake. python3 is a hard toolkit
# dependency (providers machinery); on a pythonless host the plain fallback
# still runs, and is only signal-deaf in that nohup-launched case.
HOLDER_PID=""
start_holder() {
  local out="$SANDBOX_HOME/holder.$RANDOM.out" waited=0
  : > "$out"
  if command -v python3 >/dev/null 2>&1; then
    HOLD_FOR="${1:-10}" "$BIN/sigreset.sh" bash "$BIN/holder.sh" > "$out" 2>&1 &
  else
    HOLD_FOR="${1:-10}" bash "$BIN/holder.sh" > "$out" 2>&1 &
  fi
  HOLDER_PID=$!
  HOLDER_PIDS+=("$HOLDER_PID")
  # 30s budget: a fork/exec of the holder on a loaded host can be slow, and
  # this test must grade signal handling, not the scheduler.
  while [[ $waited -lt 300 ]]; do
    grep -q 'HOLDER-ACQUIRED' "$out" 2>/dev/null && return 0
    sleep 0.1 2>/dev/null || sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# lock_path_of — ask the library where the lock lives WITHOUT taking it.
# Probing by acquiring would release the live holder we are trying to observe.
lock_path_of() {
  bash -c "source '$LOCKLIB'; cma_suite_lock_resolve suite; cma_suite_lock_path"
}

now() { date '+%s'; }

# --- 1. wiring ---------------------------------------------------------------
# If someone deletes the locking from an entry point, everything below still
# passes (it tests the library directly) — this is the check that would not.
it "both suite entry points actually acquire the lock"
for entry in run-all.sh run-proof.sh; do
  src_ok=0; call_ok=0
  grep -q 'lib/suite-lock.sh' "$TESTS_DIR/$entry" && src_ok=1
  grep -q 'cma_suite_lock_acquire' "$TESTS_DIR/$entry" && call_ok=1
  assert_eq 1 "$src_ok"  "$entry sources lib/suite-lock.sh"
  assert_eq 1 "$call_ok" "$entry calls cma_suite_lock_acquire"
done

# --- 2. contention, flock backend -------------------------------------------
it "a second concurrent run is refused while the first holds the lock (flock)"
start_holder 8; rc=$?
assert_eq 0 "$rc" "background holder acquired the lock"
hpid="$HOLDER_PID"
out="$(CMA_SUITE_LOCK_WAIT=2 bash "$BIN/contender.sh" 2>&1)"; rc=$?
assert_eq 75 "$rc" "second concurrent run exits 75 (EX_TEMPFAIL) instead of running"
if printf '%s' "$out" | grep -q "PID $hpid"; then
  _pass "contention message names the holding PID ($hpid)"
else
  _fail "contention message does not name the holder" "want PID $hpid, got: $out"
fi
if printf '%s' "$out" | grep -q 'CONTENDER-ACQUIRED'; then
  _fail "the second run proceeded anyway" "$out"
else
  _pass "the second run never reached its body"
fi

# ANTI-VACUOUS-PASS GUARD (a): with the SAME holder still running, a script
# that does not take the lock sails straight through. So the refusal above is
# caused by the locking, not by the environment, the sandbox, or bad luck.
it "anti-vacuous guard: without the lock, the same concurrent run succeeds"
out="$(CMA_SUITE_LOCK_WAIT=2 bash "$BIN/unlocked.sh" 2>&1)"; rc=$?
assert_eq 0 "$rc" "an unlocked second run is NOT blocked (proves the lock is what blocks)"
if printf '%s' "$out" | grep -q 'CONTENDER-ACQUIRED'; then
  _pass "unlocked run reached its body while the lock was held"
else
  _fail "unlocked control did not run" "$out"
fi
kill_holders; HOLDER_PIDS=()

# ANTI-VACUOUS-PASS GUARD (b): with NO holder, the locked contender must
# succeed. A lock that refused unconditionally would pass guard (a) but fail
# here, so the two together pin the behaviour from both sides.
it "anti-vacuous guard: with no holder, a locked run acquires normally"
out="$(CMA_SUITE_LOCK_WAIT=2 bash "$BIN/contender.sh" 2>&1)"; rc=$?
assert_eq 0 "$rc" "uncontended run exits 0"
if printf '%s' "$out" | grep -q 'CONTENDER-ACQUIRED'; then
  _pass "uncontended run reached its body"
else
  _fail "uncontended run was blocked" "$out"
fi
if [[ -z "$out" || "$out" == *"CONTENDER-ACQUIRED"* ]] && ! printf '%s' "$out" | grep -q '\[LOCK\]'; then
  _pass "uncontended run prints no lock noise (normal path unchanged)"
else
  _fail "lock added output noise to the normal path" "$out"
fi

# --- 3. contention, portable mkdir fallback ----------------------------------
# macOS commonly ships without flock; force the fallback so the path this
# toolkit relies on there is covered on Linux too.
it "a second concurrent run is refused on the portable fallback (no flock)"
export CMA_SUITE_LOCK_NO_FLOCK=1
start_holder 8
hpid="$HOLDER_PID"
out="$(CMA_SUITE_LOCK_WAIT=2 bash "$BIN/contender.sh" 2>&1)"; rc=$?
assert_eq 75 "$rc" "fallback refuses the second concurrent run"
if printf '%s' "$out" | grep -q "PID $hpid"; then
  _pass "fallback contention message names the holding PID ($hpid)"
else
  _fail "fallback message does not name the holder" "want PID $hpid, got: $out"
fi
if printf '%s' "$out" | grep -q 'lockdir'; then
  _pass "fallback really used the mkdir lock (not flock)"
else
  _fail "fallback did not engage" "$out"
fi
kill_holders; HOLDER_PIDS=()

# --- 4. stale locks ----------------------------------------------------------
# A crashed run must not wedge the suite forever. 999999 is above the default
# pid_max on Linux and macOS, so it is reliably a dead PID.
it "a stale mkdir lock owned by a dead PID does not wedge the suite"
lockdir="$(CMA_SUITE_LOCK_NO_FLOCK=1 lock_path_of)"
mkdir -p "$lockdir"
printf '999999\n' > "$lockdir/pid"
assert_dir "$lockdir" "planted a stale lock dir"
t0="$(now)"
out="$(CMA_SUITE_LOCK_WAIT=30 bash "$BIN/contender.sh" 2>&1)"; rc=$?
elapsed=$(( $(now) - t0 ))
assert_eq 0 "$rc" "stale lock is broken and the run proceeds"
if (( elapsed < 25 )); then
  _pass "stale lock broken promptly (${elapsed}s, well under the 30s wait)"
else
  _fail "stale lock was waited out instead of broken" "elapsed=${elapsed}s of a 30s budget"
fi
unset CMA_SUITE_LOCK_NO_FLOCK

it "a stale flock lockfile naming a dead PID does not wedge the suite"
lockfile="$(lock_path_of)"
printf '999999\n' > "$lockfile"
assert_file "$lockfile" "planted a stale lock file"
t0="$(now)"
out="$(CMA_SUITE_LOCK_WAIT=30 bash "$BIN/contender.sh" 2>&1)"; rc=$?
elapsed=$(( $(now) - t0 ))
assert_eq 0 "$rc" "unheld lock file with a dead PID is taken immediately"
if (( elapsed < 25 )); then
  _pass "stale lock file did not block (${elapsed}s)"
else
  _fail "stale lock file blocked the run" "elapsed=${elapsed}s"
fi

# The stale break is the one place the portable fallback could destroy a LIVE
# lock: a contender decides "PID N is dead", and before it swaps the directory
# away another contender breaks the lock and legitimately acquires it. Deleting
# blindly there would leave two suites running. Exercised directly because the
# race window is microseconds wide and cannot be hit reliably from outside.
it "a stale break that finds a DIFFERENT owner restores the lock instead of destroying it"
probe="$SANDBOX_HOME/breakprobe"
mkdir -p "$probe"
cat > "$probe/run.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
source "$LOCKLIB"
_cma_lock_mode=mkdir
_cma_lock_path="\$1"
_cma_lock_break_stale "\$2"
EOF
# Case 1: we judged PID 999999 stale, but the lock now belongs to live PID 4242.
victim="$probe/live.lockdir"
mkdir -p "$victim"; printf '4242\n' > "$victim/pid"
bash "$probe/run.sh" "$victim" 999999
if [[ -d "$victim" && "$(cat "$victim/pid" 2>/dev/null)" == "4242" ]]; then
  _pass "a live lock owned by someone else survives the break attempt intact"
else
  _fail "the break destroyed a live lock" "a second suite could now run alongside its owner"
fi
# Case 2: the owner really is the dead PID we judged — it must be discarded.
dead="$probe/dead.lockdir"
mkdir -p "$dead"; printf '999999\n' > "$dead/pid"
bash "$probe/run.sh" "$dead" 999999
if [[ ! -d "$dead" ]]; then
  _pass "a genuinely stale lock is discarded (break is not a no-op)"
else
  _fail "the stale lock was not broken" "$dead still exists — the suite would stay wedged"
fi

# --- 5. re-entrancy ----------------------------------------------------------
# This is the case a naive lock gets wrong: run-proof.sh holds the lock and
# then invokes run-all.sh, which asks for the same lock. Without inheritance
# the suite deadlocks against itself.
it "a nested suite run inherits the lock instead of deadlocking (run-proof -> run-all)"
t0="$(now)"
out="$(CMA_SUITE_LOCK_WAIT=20 bash "$BIN/nested.sh" 2>&1)"; rc=$?
elapsed=$(( $(now) - t0 ))
assert_eq 0 "$rc" "outer run exits 0"
if printf '%s' "$out" | grep -q 'INNER-RC=0'; then
  _pass "nested inner run acquired via inheritance"
else
  _fail "nested inner run did not succeed" "$out"
fi
if (( elapsed < 15 )); then
  _pass "nested run did not block on itself (${elapsed}s)"
else
  _fail "nested run deadlocked against its own parent" "elapsed=${elapsed}s of a 20s budget"
fi

# ANTI-VACUOUS-PASS GUARD (c): inheritance is the one door through the lock,
# so it must not be openable by simply setting the env var. Here the vars are
# forged to name THIS shell (alive, but not the recorded holder).
it "anti-vacuous guard: a forged inherit env var cannot bypass a real holder"
start_holder 8
lockfile="$(lock_path_of)"
out="$(CMA_SUITE_LOCK_OWNER=$$ CMA_SUITE_LOCK_PATH="$lockfile" CMA_SUITE_LOCK_WAIT=2 \
       bash "$BIN/contender.sh" 2>&1)"; rc=$?
assert_eq 75 "$rc" "forged inheritance is rejected and the run is still refused"
if printf '%s' "$out" | grep -q 'CONTENDER-ACQUIRED'; then
  _fail "forged env var opened the lock" "$out"
else
  _pass "forged env var did not open the lock"
fi
kill_holders; HOLDER_PIDS=()

# --- 6. release on Ctrl-C ----------------------------------------------------
it "the lock is released on Ctrl-C (SIGINT), not only on clean exit"
export CMA_SUITE_LOCK_NO_FLOCK=1
start_holder 60
hpid="$HOLDER_PID"
lockdir="$(lock_path_of)"
assert_dir "$lockdir" "lock is held while the run is alive"
kill -INT "$hpid" 2>/dev/null
# Generous window on purpose. The property under test is that the trap RUNS and
# releases the lock — not that it wins a race against the scheduler. A host
# running other suites/tooling can hold a descheduled holder for seconds before
# the kernel even delivers the queued INT, which is exactly how a correct
# implementation once looked broken here. 30s still fails a genuinely broken
# release (compare the 600s a real competing run tolerates in production).
# Release is judged by the STRONGER condition — the holder EXITING and the
# directory disappearing — so a trap that merely returns (but fails to remove
# the lock) cannot pass the first gate and then trip the second.
waited=0
while [[ $waited -lt 300 ]]; do
  if ! kill -0 "$hpid" 2>/dev/null && [[ ! -d "$lockdir" ]]; then
    break
  fi
  sleep 0.1 2>/dev/null || sleep 1
  waited=$((waited + 1))
done
if [[ ! -d "$lockdir" ]] && ! kill -0 "$hpid" 2>/dev/null; then
  _pass "SIGINT released the lock (holder exited, dir gone after ${waited}×0.1s)"
else
  _fail "SIGINT left the lock behind" "$lockdir still exists; holder_alive=$(kill -0 "$hpid" 2>/dev/null && echo yes || echo no)"
fi
out="$(CMA_SUITE_LOCK_WAIT=2 bash "$BIN/contender.sh" 2>&1)"; rc=$?
assert_eq 0 "$rc" "a run after an interrupted one is not blocked"
kill_holders; HOLDER_PIDS=()
unset CMA_SUITE_LOCK_NO_FLOCK

# --- 7. lock location --------------------------------------------------------
it "the lock never lands in the tracked tree"
real_path="$(unset CMA_SUITE_LOCK_DIR; bash -c "source '$LOCKLIB'; _cma_lock_home")"
gitdir="$(git -C "$TESTS_DIR" rev-parse --absolute-git-dir 2>/dev/null)"
if [[ -n "$gitdir" && "$real_path" == "$gitdir" ]]; then
  _pass "default lock home is the git dir (never tracked): $real_path"
elif [[ "$real_path" == "${TMPDIR:-/tmp}" ]]; then
  _pass "default lock home falls back to the temp dir: $real_path"
else
  _fail "default lock home is not a safe location" "got: $real_path"
fi
if [[ "$real_path" == "$SCRIPTS_DIR"/* ]]; then
  _fail "lock would be written under scripts/" "$real_path"
else
  _pass "lock home is outside scripts/ — cannot show up in git status"
fi

summary
