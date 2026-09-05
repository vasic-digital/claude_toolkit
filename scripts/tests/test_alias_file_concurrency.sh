#!/usr/bin/env bash
# test_alias_file_concurrency.sh — the alias file must survive concurrent writers.
#
# WHY THIS FILE EXISTS
# --------------------
# On 2026-07-20 the live ~/.local/share/claude-multi-account/aliases.sh was
# destroyed: forensic snapshots show it going 37288 -> 282 -> 32112 -> 974 ->
# 909 -> 25682 -> 130 bytes inside four seconds, losing the header, BOTH wrapper
# functions and every `alias claudeN=` line. Nothing was wrong with any single
# writer. `cma_ensure_alias_file` ran a six-step whole-file read-modify-write
# migration (plus two direct `cat >>` appends) while `claude-providers list
# --refresh-aliases` — fired by the session hook on EVERY shell start — ran 21
# more whole-file rewrites. With no lock on the file, one writer's stale
# snapshot silently overwrote another's committed result. The corruption
# timestamp preceded the incidental SIGTERM by ~14 minutes, so this is
# clean-run reachable, NOT an interrupt-only hazard.
#
# Every test below therefore drives REAL concurrent processes against a real
# alias file. There are TWO storms, and they are not interchangeable:
#
#   Section 1  — many writers writing the SAME content, graded by a sampler
#                that reads the file continuously. It proves no writer ever
#                PUBLISHES a structurally broken file. It says nothing about
#                mutual exclusion: its writers heal each other's losses, and
#                deleting the lock acquire from cma_alias_commit leaves it
#                passing 3/3.
#   Section 1b — N one-shot writers each adding a DIFFERENT alias, so a lost
#                update is permanent and visible, graded against the status
#                each writer was TOLD. This is the one with teeth for the lock,
#                and it is what caught the mkdir backend failing to exclude.
#
# Claims about what is covered are kept honest deliberately: where a mechanism
# survives deletion with the suite still green, the comment says so instead of
# implying coverage (see section 2 on the INT/TERM mask).
#
# RUNNING IT AGAINST OTHER CODE (how the teeth were verified)
#   CMA_SCRIPTS_UNDER_TEST=/path/to/other/scripts bash test_alias_file_concurrency.sh
# points every worker at a different scripts/ directory (e.g. one carrying
# `git show HEAD:scripts/lib.sh`). A concurrency test that passes both before
# and after a fix proves nothing, so this knob is how "it fails before" is
# demonstrated rather than asserted.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${CMA_SCRIPTS_UNDER_TEST:-$(cd "$TESTS_DIR/.." && pwd)}"
export SCRIPTS_DIR

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
# lib.sh enables `set -e`; the harness asserts on non-zero exits.
set +e

PROVIDERS_DIR="$HOME/.local/share/claude-multi-account/providers"
ACCOUNTS=(claude1 claude2 claude3 claude4)
PROVIDERS=(alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima)

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# An alias file in the shape the live host had: a correct header, OUTDATED
# wrapper bodies (so the pre-fix code's drop-then-re-append migration actually
# fires — that is the writer that lost the race), the account aliases, and the
# provider alias lines.
seed_alias_file() {
  mkdir -p "$(dirname "$ALIAS_FILE")"
  {
    printf '# Managed by claude-multi-account. Do not edit by hand; use\n'
    printf '# ~/.local/bin/claude-add-account to add accounts.\n'
    printf 'export CLAUDE_BIN="/usr/bin/true"\n'
    printf '\n'
    printf '# Wrapper: keeps .claude.json projects/session index synced across every\n'
    printf '# logged-in account. Pulls merged state from every account into the launching\n'
    printf '# one before claude runs; pushes the post-session state back out after exit.\n'
    printf '# Cheap (jq deep-merge of one ~50KB file per account), runs unconditionally.\n'
    printf 'cma_run() {\n'
    printf '  "$CLAUDE_BIN" "$@"\n'
    printf '}\n'
    printf '\n'
    printf 'cma_run_provider() {\n'
    printf '  local id="$1"; shift 2>/dev/null || true\n'
    printf '  "$CLAUDE_BIN" "$@"\n'
    printf '}\n'
    local a p
    for a in "${ACCOUNTS[@]}"; do
      printf 'alias %s="CLAUDE_CONFIG_DIR=%s/.claude-%s cma_run"\n' "$a" "$HOME" "$a"
    done
    for p in "${PROVIDERS[@]}"; do
      printf 'alias %s="cma_run_provider %s"\n' "$p" "$p"
    done
  } > "$ALIAS_FILE"
}

# The provider env cache the --refresh-aliases fast path reads.
seed_provider_cache() {
  mkdir -p "$PROVIDERS_DIR"
  local p
  for p in "${PROVIDERS[@]}"; do
    {
      printf 'CMA_PROVIDER_ID=%s\n' "$p"
      printf 'CMA_PROVIDER_ALIAS=%s\n' "$p"
    } > "$PROVIDERS_DIR/$p.env"
  done
}

# Account dirs, so cma_detect_accounts (used by the commit sanity gate) sees
# the same four accounts the alias file names.
seed_accounts() {
  local a
  for a in "${ACCOUNTS[@]}"; do
    mkdir -p "$HOME/.claude-$a/projects"
  done
}

# A worker that calls cma_ensure_alias_file in a loop, in its own process.
WORKER="$HOME/cma-ensure-worker.sh"
write_worker() {
  cat > "$WORKER" <<'WORKER_EOF'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=/dev/null
source "$SCRIPTS_DIR/lib.sh"
set +e
gate="$1"; iterations="${2:-3}"
if [[ -n "$gate" ]]; then while [[ ! -f "$gate" ]]; do :; done; fi
i=0
while (( i < iterations )); do
  cma_ensure_alias_file >/dev/null 2>&1
  i=$(( i + 1 ))
done
exit 0
WORKER_EOF
  chmod +x "$WORKER"
}

# A worker that runs the session hook's real fast path: one full
# `claude-providers list --refresh-aliases`, i.e. one whole-file rewrite per
# cached provider env file.
REFRESHER="$HOME/cma-refresh-worker.sh"
write_refresher() {
  cat > "$REFRESHER" <<'REFRESH_EOF'
#!/usr/bin/env bash
set -uo pipefail
gate="$1"; iterations="${2:-3}"
if [[ -n "$gate" ]]; then while [[ ! -f "$gate" ]]; do :; done; fi
i=0
while (( i < iterations )); do
  "$SCRIPTS_DIR/claude-providers.sh" list --quiet --refresh-aliases >/dev/null 2>&1
  i=$(( i + 1 ))
done
exit 0
REFRESH_EOF
  chmod +x "$REFRESHER"
}

# A sampler that watches the alias file for as long as the storm runs and
# records every structurally INVALID state it observes.
#
# This — not the post-storm state — is the assertion with teeth. A rename is
# atomic, so every state a reader can observe is a state some writer COMMITTED.
# Checking only the end state is too weak: the writers heal each other, so the
# file usually converges even when the pre-fix code publishes a headless,
# wrapper-less or alias-less file mid-flight (the live incident is a snapshot of
# exactly such a state, taken at the wrong instant). The property that actually
# has to hold is "no writer ever publishes a broken file", and that is what the
# render-once + single-rename design guarantees.
SAMPLER="$HOME/cma-sampler.sh"
write_sampler() {
  cat > "$SAMPLER" <<'SAMPLER_EOF'
#!/usr/bin/env bash
# args: <alias file> <expected account aliases> <run flag> <bad log>
set -uo pipefail
f="$1"; want_acct="$2"; flag="$3"; bad="$4"
while [[ -f "$flag" ]]; do
  [[ -f "$f" ]] || { printf 'MISSING FILE\n' >> "$bad"; continue; }
  # One awk pass = one read of one inode, so the sample is a single committed
  # state and never a mixture of two.
  s="$(awk '
    /^export CLAUDE_BIN=/          { h++ }
    /^cma_run\(\) [{]/             { r++ }
    /^cma_run_provider\(\) [{]/    { p++ }
    /^alias claude[0-9]*=/         { a++ }
    END { printf "%d %d %d %d", h+0, r+0, p+0, a+0 }
  ' "$f" 2>/dev/null)"
  case "$s" in
    "1 1 1 $want_acct") : ;;
    *) printf '%s\n' "$s" >> "$bad" ;;
  esac
done
exit 0
SAMPLER_EOF
  chmod +x "$SAMPLER"
}

# Structural report of the alias file: the four things the incident destroyed.
alias_file_report() {
  local f="$ALIAS_FILE" hdr=0 run=0 prov=0 acct=0 provaliases=0 dupes=0 p n
  [[ -f "$f" ]] || { printf 'MISSING\n'; return 0; }
  grep -q '^export CLAUDE_BIN=' "$f" && hdr=1
  run="$(grep -c '^cma_run() {' "$f" 2>/dev/null || true)";  [[ -n "$run" ]]  || run=0
  prov="$(grep -c '^cma_run_provider() {' "$f" 2>/dev/null || true)"; [[ -n "$prov" ]] || prov=0
  acct="$(grep -c '^alias claude[0-9]*=' "$f" 2>/dev/null || true)"; [[ -n "$acct" ]] || acct=0
  for p in "${PROVIDERS[@]}"; do
    n="$(grep -c "^alias $p=" "$f" 2>/dev/null || true)"; [[ -n "$n" ]] || n=0
    (( n >= 1 )) && provaliases=$(( provaliases + 1 ))
    (( n > 1 ))  && dupes=$(( dupes + 1 ))
  done
  printf 'header=%s cma_run=%s cma_run_provider=%s accounts=%s providers=%s dupes=%s bytes=%s\n' \
    "$hdr" "$run" "$prov" "$acct" "$provaliases" "$dupes" "$(wc -c < "$f" | tr -d ' ')"
}

# ---------------------------------------------------------------------------
# 1. The concurrency storm — the acceptance criterion
# ---------------------------------------------------------------------------
it "storm: concurrent refreshers + ensure runs never lose header, wrappers or aliases"
seed_accounts
seed_provider_cache
seed_alias_file
write_worker
write_refresher
write_sampler
GATE="$HOME/.storm-go"
RUNFLAG="$HOME/.storm-running"
BADLOG="$HOME/.storm-bad"
rm -f "$GATE" "$BADLOG"
: > "$RUNFLAG"
"$SAMPLER" "$ALIAS_FILE" "${#ACCOUNTS[@]}" "$RUNFLAG" "$BADLOG" & sampler_pid=$!
pids=()
for _i in 1 2 3 4 5 6 7 8; do
  "$REFRESHER" "$GATE" 3 & pids+=("$!")
done
for _i in 1 2 3 4; do
  "$WORKER" "$GATE" 3 & pids+=("$!")
done
: > "$GATE"                      # release every worker at once
for _p in "${pids[@]}"; do wait "$_p" 2>/dev/null; done
rm -f "$RUNFLAG"
wait "$sampler_pid" 2>/dev/null

storm_bad=0
if [[ -s "$BADLOG" ]]; then
  storm_bad="$(grep -c . "$BADLOG" || true)"
  printf '    %s broken states were published during the storm, e.g.:\n' "$storm_bad"
  sort "$BADLOG" | uniq -c | sort -rn | head -5 | sed 's/^/      /'
  printf '      (fields: CLAUDE_BIN headers, cma_run defs, cma_run_provider defs, account aliases;\n'
  printf '       expected "1 1 1 %s")\n' "${#ACCOUNTS[@]}"
fi
assert_eq 0 "$storm_bad" "no writer ever published a structurally broken alias file"

storm_report="$(alias_file_report)"
printf '    storm result: %s\n' "$storm_report"
storm_hdr="$(printf '%s' "$storm_report"  | sed -n 's/.*header=\([0-9]*\).*/\1/p')"
storm_run="$(printf '%s' "$storm_report"  | sed -n 's/.*cma_run=\([0-9]*\).*/\1/p')"
storm_prov="$(printf '%s' "$storm_report" | sed -n 's/.*cma_run_provider=\([0-9]*\).*/\1/p')"
storm_acct="$(printf '%s' "$storm_report" | sed -n 's/.*accounts=\([0-9]*\).*/\1/p')"
storm_pal="$(printf '%s' "$storm_report"  | sed -n 's/.*providers=\([0-9]*\).*/\1/p')"
storm_dup="$(printf '%s' "$storm_report"  | sed -n 's/.*dupes=\([0-9]*\).*/\1/p')"
assert_eq 1 "${storm_hdr:-0}"  "export CLAUDE_BIN header survived the storm"
assert_eq 1 "${storm_run:-0}"  "cma_run() present exactly once after the storm"
assert_eq 1 "${storm_prov:-0}" "cma_run_provider() present exactly once after the storm"
assert_eq "${#ACCOUNTS[@]}" "${storm_acct:-0}" "all account aliases survived the storm"
assert_eq "${#PROVIDERS[@]}" "${storm_pal:-0}" "all provider aliases survived the storm"
assert_eq 0 "${storm_dup:-1}" "no provider alias duplicated by the storm"
bash -n "$ALIAS_FILE" 2>/dev/null; assert_eq 0 $? "alias file still parses after the storm"

# ---------------------------------------------------------------------------
# 1b. Mutual exclusion — the property the storm above does NOT measure
# ---------------------------------------------------------------------------
# HONESTY NOTE, and the reason this block exists. Deleting the
# _cma_alias_lock_acquire call from cma_alias_commit left section 1 passing
# 3/3. That is not a flaw in section 1 — it measures the right thing (no writer
# ever PUBLISHES a broken file), and render-once plus a single rename delivers
# that with no lock at all. What a missing lock actually costs is the LOST
# UPDATE that destroyed the live file: two writers read the same state, both
# render, and the second rename silently discards the first's committed result.
#
# Section 1 cannot see that, for two reasons: its workers all write the SAME
# content, so any lost update is re-derived by the next iteration, and its
# sampler grades structure rather than content. So the deltas here are chosen
# to be non-convergent instead: N processes, each adding a DIFFERENT alias,
# each doing EXACTLY ONE write, all released together. Nothing re-adds a lost
# alias, so a single lost update is permanent and visible.
#
# The mkdir backend is forced (CMA_ALIAS_LOCK_NO_FLOCK=1) because it is the
# macOS path, it is the weaker of the two, and it is the one whose stale-break
# logic could plausibly hand the lock to two contenders at once.
it "storm: N one-shot DISTINCT writes all survive (this is what the lock earns)"
seed_accounts
seed_provider_cache
seed_alias_file
UNIQ_WORKER="$HOME/cma-unique-worker.sh"
cat > "$UNIQ_WORKER" <<'UNIQ_EOF'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=/dev/null
source "$SCRIPTS_DIR/lib.sh"
set +e
gate="$1"; name="$2"; rcfile="$3"
while [[ ! -f "$gate" ]]; do :; done
cma_write_alias "$name" "$HOME/.claude-$name" >/dev/null 2>&1
# The rc is the whole point of the assertion: it is what the caller was TOLD.
printf '%s %s\n' "$name" "$?" >> "$rcfile"
exit 0
UNIQ_EOF
chmod +x "$UNIQ_WORKER"
UNIQ_GATE="$HOME/.uniq-go"
UNIQ_RC="$HOME/.uniq-rc"
rm -f "$UNIQ_GATE"; : > "$UNIQ_RC"
_uq_pids=()
for _i in 01 02 03 04 05 06 07 08 09 10 11 12; do
  CMA_ALIAS_LOCK_NO_FLOCK=1 "$UNIQ_WORKER" "$UNIQ_GATE" "stormuniq$_i" "$UNIQ_RC" & _uq_pids+=("$!")
done
: > "$UNIQ_GATE"                 # release all twelve at once
for _p in "${_uq_pids[@]}"; do wait "$_p" 2>/dev/null; done
# THE ASSERTION, stated exactly. A write that reported SUCCESS must be in the
# file — that is the lost-update property, and it is the one a missing or
# non-excluding lock breaks. A write that reported 75 is honestly absent (the
# caller was told to retry) and is only counted, not failed: this is a real
# contention storm and starving one writer past its deadline is allowed
# behaviour, whereas telling a writer "done" and dropping its delta is not.
_uq_lost=""; _uq_declined=0
while read -r _n _rc; do
  [[ -n "$_n" ]] || continue
  if [[ "$_rc" == 0 ]]; then
    grep -q "^alias $_n=" "$ALIAS_FILE" 2>/dev/null || _uq_lost="$_uq_lost $_n"
  else
    _uq_declined=$(( _uq_declined + 1 ))
  fi
done < "$UNIQ_RC"
(( _uq_declined > 0 )) && printf '    %s of 12 writers were honestly declined (rc 75) under contention\n' "$_uq_declined"
assert_eq "" "$_uq_lost" "every write that REPORTED SUCCESS is in the file (no lost update)" \
  "reported rc=0 but absent:$_uq_lost"
_uq_ran="$(grep -c . "$UNIQ_RC" || true)"
assert_eq 12 "${_uq_ran:-0}" "CONTROL: all 12 writers actually ran and recorded a status"
# The pre-existing content must be intact too — a lost update can just as easily
# discard an alias nobody was touching.
_uq_acct="$(grep -c '^alias claude[0-9]*=' "$ALIAS_FILE" || true)"
assert_eq "${#ACCOUNTS[@]}" "${_uq_acct:-0}" "the original account aliases survived the distinct-write storm"
bash -n "$ALIAS_FILE" 2>/dev/null; assert_eq 0 $? "alias file parses after the distinct-write storm"

# ---------------------------------------------------------------------------
# 2. Interrupt atomicity
# ---------------------------------------------------------------------------
# A SIGTERM during a write must leave EITHER the untouched original OR the
# complete new file — never a third state. The pre-fix code could be killed
# between the drop-`mv` and the re-append `cat >>`, permanently losing a
# wrapper.
#
# WHAT THIS DOES AND DOES NOT PIN. It pins render-once + a single mv(2): those
# are what make every observable state a complete one. It does NOT pin the
# committer's `trap '' INT TERM` — deleting that mask leaves all 15 iterations
# passing, because the atomicity comes from the rename, not from the mask. The
# header here used to credit the mask; that was an overclaim and is corrected
# rather than papered over with a test that cannot really distinguish it. See
# the "What protects WHAT" note in lib.sh.
it "interrupt: SIGTERM mid-write never leaves a partial alias file"
int_bad=0
for _i in $(seq 1 15); do
  seed_alias_file
  "$WORKER" "" 1 >/dev/null 2>&1 &
  _wpid=$!
  sleep 0.0$(( (RANDOM % 9) + 1 )) 2>/dev/null || sleep 1
  kill -TERM "$_wpid" 2>/dev/null
  wait "$_wpid" 2>/dev/null
  _r="$(alias_file_report)"
  case "$_r" in
    "header=1 cma_run=1 cma_run_provider=1 accounts=${#ACCOUNTS[@]} "*) : ;;
    *) int_bad=$(( int_bad + 1 )); printf '    third state: %s\n' "$_r" ;;
  esac
  bash -n "$ALIAS_FILE" 2>/dev/null || int_bad=$(( int_bad + 1 ))
done
assert_eq 0 "$int_bad" "15 interrupted writes, no partial/unparseable file"

# ---------------------------------------------------------------------------
# 3. Idempotence — a second identical run must not even rename
# ---------------------------------------------------------------------------
# The no-op guard is what keeps steady-state shell starts out of the race
# entirely: if the render matches what is on disk, nothing is written and the
# lock is never taken. Inode identity (not mtime) is the check, because a
# rename always changes the inode while mtime has 1-second granularity on some
# filesystems.
it "idempotence: re-running the same writes performs no rename at all"
seed_accounts
seed_provider_cache
rm -f "$ALIAS_FILE"
cma_ensure_alias_file >/dev/null 2>&1
for a in "${ACCOUNTS[@]}"; do cma_write_alias "$a" "$HOME/.claude-$a" >/dev/null 2>&1; done
for p in "${PROVIDERS[@]}"; do cma_provider_write_alias "$p" "$p" >/dev/null 2>&1; done
cma_install_session_hook >/dev/null 2>&1
cp "$ALIAS_FILE" "$HOME/.alias-before"
ino_before="$(ls -i "$ALIAS_FILE" | awk '{print $1}')"
cma_ensure_alias_file >/dev/null 2>&1
for a in "${ACCOUNTS[@]}"; do cma_write_alias "$a" "$HOME/.claude-$a" >/dev/null 2>&1; done
for p in "${PROVIDERS[@]}"; do cma_provider_write_alias "$p" "$p" >/dev/null 2>&1; done
cma_install_session_hook >/dev/null 2>&1
ino_after="$(ls -i "$ALIAS_FILE" | awk '{print $1}')"
cmp -s "$HOME/.alias-before" "$ALIAS_FILE"; assert_eq 0 $? "second pass is byte-identical"
assert_eq "$ino_before" "$ino_after" "second pass performed zero renames (same inode)"

it "idempotence: the refresh fast path is a no-op too"
ino_before="$(ls -i "$ALIAS_FILE" | awk '{print $1}')"
"$SCRIPTS_DIR/claude-providers.sh" list --quiet --refresh-aliases >/dev/null 2>&1
ino_after="$(ls -i "$ALIAS_FILE" | awk '{print $1}')"
cmp -s "$HOME/.alias-before" "$ALIAS_FILE"; assert_eq 0 $? "refresh left the file byte-identical"
assert_eq "$ino_before" "$ino_after" "refresh performed zero renames (same inode)"

# ---------------------------------------------------------------------------
# 4. Stale-cache seeding
# ---------------------------------------------------------------------------
# The refresh path must seed from the alias FILE, never rebuild from the
# provider cache: with the cache emptied, the account aliases and both wrappers
# must still be there afterwards. (The corrupted live file was alias-only —
# exactly what a cache-sourced rebuild would produce.)
it "stale cache: an emptied provider cache never costs the file its accounts"
rm -f "$PROVIDERS_DIR"/*.env
"$SCRIPTS_DIR/claude-providers.sh" list --quiet --refresh-aliases >/dev/null 2>&1
_r="$(alias_file_report)"
printf '    after empty-cache refresh: %s\n' "$_r"
assert_file_contains "$ALIAS_FILE" "export CLAUDE_BIN=" "header survived an empty provider cache"
assert_file_contains "$ALIAS_FILE" "cma_run() {" "cma_run survived an empty provider cache"
assert_file_contains "$ALIAS_FILE" "cma_run_provider() {" "cma_run_provider survived an empty provider cache"
_acct="$(grep -c '^alias claude[0-9]*=' "$ALIAS_FILE" || true)"
assert_eq "${#ACCOUNTS[@]}" "$_acct" "account aliases survived an empty provider cache"
seed_provider_cache

# ---------------------------------------------------------------------------
# 5. Orphan-comment regression
# ---------------------------------------------------------------------------
# The old drop-awk started at the `cma_run() {` line, so the 4-line
# `# Wrapper:` comment above it was left behind while the re-append put the
# function at the end. Every migration leaked 5 dead lines; ~15 orphaned copies
# had accumulated on the live host before the incident.
it "no orphan comments: 20 ensure runs leave exactly one wrapper comment block"
seed_alias_file
for _i in $(seq 1 20); do cma_ensure_alias_file >/dev/null 2>&1; done
_orphans="$(grep -c '^# Wrapper: keeps \.claude\.json' "$ALIAS_FILE" || true)"
assert_eq 1 "${_orphans:-0}" "exactly one '# Wrapper:' comment block after 20 runs"
_runs="$(grep -c '^cma_run() {' "$ALIAS_FILE" || true)"
assert_eq 1 "${_runs:-0}" "exactly one cma_run() after 20 runs"
_provs="$(grep -c '^cma_run_provider() {' "$ALIAS_FILE" || true)"
assert_eq 1 "${_provs:-0}" "exactly one cma_run_provider() after 20 runs"
_acct="$(grep -c '^alias claude[0-9]*=' "$ALIAS_FILE" || true)"
assert_eq "${#ACCOUNTS[@]}" "$_acct" "account aliases intact after 20 runs"

# ---------------------------------------------------------------------------
# 6. The session hook can never block a shell start
# ---------------------------------------------------------------------------
it "lock: CMA_ALIAS_LOCK_WAIT=0 gives up instantly instead of waiting"
_lock_probe() {
  # Hold the lock in a background process for 5s, then time a zero-wait
  # acquisition attempt from this one. $1/$2 select the backend (name + value,
  # passed through `env` rather than a split `export $var`).
  local mode_name="$1" mode_val="$2"
  cat > "$HOME/cma-lock-holder.sh" <<'HOLD_EOF'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=/dev/null
source "$SCRIPTS_DIR/lib.sh"
set +e
_cma_alias_lock_acquire || exit 9
: > "$HOME/.lock-held"
sleep 5
_cma_alias_lock_release
HOLD_EOF
  chmod +x "$HOME/cma-lock-holder.sh"
  rm -f "$HOME/.lock-held"
  env "$mode_name=$mode_val" "$HOME/cma-lock-holder.sh" &
  local hpid=$!
  local waited=0
  while [[ ! -f "$HOME/.lock-held" ]] && (( waited < 300 )); do
    sleep 0.01 2>/dev/null || sleep 1; waited=$(( waited + 1 ))
  done
  local t0 t1
  t0="$(date +%s)"
  env "$mode_name=$mode_val" CMA_ALIAS_LOCK_WAIT=0 bash -c '
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib.sh"; set +e
    _cma_alias_lock_acquire' >/dev/null 2>&1
  local rc=$?
  t1="$(date +%s)"
  kill "$hpid" 2>/dev/null; wait "$hpid" 2>/dev/null
  rm -rf "$(dirname "$ALIAS_FILE")/.aliases.lockdir" 2>/dev/null
  printf '%s %s\n' "$rc" "$(( t1 - t0 ))"
}
_probe="$(_lock_probe CMA_ALIAS_LOCK_PROBE 1)"
assert_eq 1 "$(printf '%s' "$_probe" | awk '{print $1}')" "zero-wait acquisition reports contention"
_elapsed="$(printf '%s' "$_probe" | awk '{print $2}')"
_fast=1; (( _elapsed <= 2 )) && _fast=0
assert_eq 0 "$_fast" "zero-wait acquisition returned immediately (${_elapsed}s)"

it "lock: the portable mkdir backend behaves the same (macOS has no flock)"
_probe="$(_lock_probe CMA_ALIAS_LOCK_NO_FLOCK 1)"
assert_eq 1 "$(printf '%s' "$_probe" | awk '{print $1}')" "mkdir backend reports contention"
_elapsed="$(printf '%s' "$_probe" | awk '{print $2}')"
_fast=1; (( _elapsed <= 2 )) && _fast=0
assert_eq 0 "$_fast" "mkdir backend returned immediately (${_elapsed}s)"

it "lock: a contended commit leaves the file untouched and SAYS SO (75), unless opted out"
# RECONCILED, on purpose, against the assertion that used to stand here — which
# required a contended write to report SUCCESS to every caller. That contract
# WAS the bug: a skip means the caller's delta is not in the file, and telling
# everyone "done" made two callers act on a write that never happened.
# claude-add-account created the config dir, linked the shared items, got 0 from
# cma_write_alias and announced an account with NO alias (whose retry then dies
# on "config dir already exists" — the user is wedged); claude-remove-account
# got 0 from cma_remove_alias and went on to ARCHIVE the directory out from
# under a still-live alias. Skipping is right for exactly one caller, so it is
# now an explicit opt-in and BOTH directions are pinned here.
seed_alias_file
cp "$ALIAS_FILE" "$HOME/.alias-locked-before"
rm -f "$HOME/.lock-held"
cat > "$HOME/cma-lock-holder.sh" <<'HOLD2_EOF'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=/dev/null
source "$SCRIPTS_DIR/lib.sh"
set +e
_cma_alias_lock_acquire || exit 9
: > "$HOME/.lock-held"
sleep 8
_cma_alias_lock_release
HOLD2_EOF
chmod +x "$HOME/cma-lock-holder.sh"
"$HOME/cma-lock-holder.sh" & _hpid=$!
_w=0; while [[ ! -f "$HOME/.lock-held" ]] && (( _w < 300 )); do sleep 0.01 2>/dev/null || sleep 1; _w=$(( _w + 1 )); done
# (a) an ordinary caller must be told the write did not happen.
env CMA_ALIAS_LOCK_WAIT=0 bash -c '
  # shellcheck source=/dev/null
  source "$SCRIPTS_DIR/lib.sh"; set +e
  cma_provider_write_alias newprov newprov' >/dev/null 2>&1
assert_eq 75 $? "an ordinary caller gets 75 (EX_TEMPFAIL), not a false success"
cmp -s "$HOME/.alias-locked-before" "$ALIAS_FILE"; assert_eq 0 $? "contended write left the file untouched"
# (b) the session hook's opt-in, and ONLY it, turns the skip back into success —
#     while still writing nothing.
env CMA_ALIAS_LOCK_WAIT=0 CMA_ALIAS_SKIP_ON_CONTENTION=1 bash -c '
  # shellcheck source=/dev/null
  source "$SCRIPTS_DIR/lib.sh"; set +e
  cma_provider_write_alias newprov newprov' >/dev/null 2>&1
assert_eq 0 $? "CMA_ALIAS_SKIP_ON_CONTENTION=1 makes a contended skip a success"
cmp -s "$HOME/.alias-locked-before" "$ALIAS_FILE"; assert_eq 0 $? "the opted-in skip also left the file untouched"
kill "$_hpid" 2>/dev/null; wait "$_hpid" 2>/dev/null

it "the session hook asks for a zero wait AND opts in to skip-on-contention"
rm -f "$ALIAS_FILE"; cma_ensure_alias_file >/dev/null 2>&1
cma_install_session_hook >/dev/null 2>&1
# Both halves are load-bearing and both are in the emitted line: the zero wait
# keeps a shell start from ever blocking, and the opt-in is what makes the
# resulting skip a non-error for THIS caller alone.
assert_file_contains "$ALIAS_FILE" "CMA_ALIAS_LOCK_WAIT=0 CMA_ALIAS_SKIP_ON_CONTENTION=1 claude-providers list" \
  "hook body pins a zero lock wait and the skip opt-in"
# The opt-in must stay confined to the hook emitter. If a second script starts
# setting it, the false-success bug is back for that script's callers.
_optin_files="$(grep -l 'CMA_ALIAS_SKIP_ON_CONTENTION=1' "$SCRIPTS_DIR"/*.sh 2>/dev/null | wc -l | tr -d ' ')"
assert_eq 1 "$_optin_files" "exactly one script sets the skip opt-in (lib.sh's hook emitter)"

# ---------------------------------------------------------------------------
# 7. The sanity gate refuses to publish a lossy render
# ---------------------------------------------------------------------------
it "callers: add-account and remove-account both REACT to a contended write"
# The other half of the 75 contract. Returning a truthful status is only worth
# something if the callers act on it, and these two are the ones whose damage
# was reported: add-account created the config dir, was told 0, and announced
# an account with no alias (its retry then dies on "config dir already exists",
# wedging the user); remove-account was told 0, logged "alias removed", and
# ARCHIVED the config dir out from under a still-live alias.
seed_accounts
seed_alias_file
cp "$ALIAS_FILE" "$HOME/.alias-callers-before"
rm -f "$HOME/.lock-held"
cat > "$HOME/cma-caller-holder.sh" <<'HOLD3_EOF'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=/dev/null
source "$SCRIPTS_DIR/lib.sh"
set +e
_cma_alias_lock_acquire || exit 9
: > "$HOME/.lock-held"
sleep 10
_cma_alias_lock_release
HOLD3_EOF
chmod +x "$HOME/cma-caller-holder.sh"
"$HOME/cma-caller-holder.sh" & _chpid=$!
_w=0; while [[ ! -f "$HOME/.lock-held" ]] && (( _w < 400 )); do sleep 0.01 2>/dev/null || sleep 1; _w=$(( _w + 1 )); done

# --- add-account ---------------------------------------------------------
_add_out="$(CMA_ALIAS_LOCK_WAIT=0 "$SCRIPTS_DIR/claude-add-account.sh" \
             --alias contended1 --yes 2>&1)"; _add_rc=$?
_ne=1; (( _add_rc != 0 )) && _ne=0
assert_eq 0 "$_ne" "add-account fails loudly when the alias write was skipped (rc=$_add_rc)"
case "$_add_out" in *"[done]"*) _hit=1 ;; *) _hit=0 ;; esac
assert_eq 0 "$_hit" "add-account does NOT print [done] for an account with no alias"
case "$_add_out" in *claude-unify*) _hit=0 ;; *) _hit=1 ;; esac
assert_eq 0 "$_hit" "add-account names the command that finishes the job"
_added="$(grep -c '^alias contended1=' "$ALIAS_FILE" 2>/dev/null || true)"
assert_eq 0 "${_added:-1}" "CONTROL: the alias really was not written"

# --- remove-account ------------------------------------------------------
# The load-bearing assertion is the DIRECTORY: a dangling alias over a moved
# dir is the unrecoverable half of this bug.
_rm_out="$(CMA_ALIAS_LOCK_WAIT=0 "$SCRIPTS_DIR/claude-remove-account.sh" \
            --alias claude1 --yes 2>&1)"; _rm_rc=$?
_ne=1; (( _rm_rc != 0 )) && _ne=0
assert_eq 0 "$_ne" "remove-account fails loudly when the alias removal was skipped (rc=$_rm_rc)"
assert_dir "$HOME/.claude-claude1" "the config dir was NOT archived behind a still-live alias"
_arch="$(ls -d "$HOME"/.claude-claude1.removed.* 2>/dev/null | wc -l | tr -d ' ')"
assert_eq 0 "$_arch" "nothing was archived"
_still="$(grep -c '^alias claude1=' "$ALIAS_FILE" 2>/dev/null || true)"
assert_eq 1 "${_still:-0}" "the alias is still there, consistent with the dir still being there"
cmp -s "$HOME/.alias-callers-before" "$ALIAS_FILE"
assert_eq 0 $? "neither caller changed the alias file"
kill "$_chpid" 2>/dev/null; wait "$_chpid" 2>/dev/null
rm -rf "$HOME/.claude-contended1"

it "gate: a candidate missing a wrapper or an alias is rejected"
seed_alias_file
_cand="$HOME/.cand"
grep -v '^cma_run_provider() {' "$ALIAS_FILE" > "$_cand"
( _cma_alias_gate "$_cand" "$ALIAS_FILE" "" "" ) >/dev/null 2>&1
assert_eq 1 $? "candidate without cma_run_provider() rejected"
grep -v '^alias claude1=' "$ALIAS_FILE" > "$_cand"
( _cma_alias_gate "$_cand" "$ALIAS_FILE" "" "" ) >/dev/null 2>&1
assert_eq 1 $? "candidate that dropped an account alias rejected"
grep -v '^export CLAUDE_BIN=' "$ALIAS_FILE" > "$_cand"
( _cma_alias_gate "$_cand" "$ALIAS_FILE" "" "" ) >/dev/null 2>&1
assert_eq 1 $? "candidate without the CLAUDE_BIN header rejected"
cp "$ALIAS_FILE" "$_cand"
( _cma_alias_gate "$_cand" "$ALIAS_FILE" "" "" ) >/dev/null 2>&1
assert_eq 0 $? "an intact candidate is accepted (gate is not vacuously failing)"

it "gate integration: a rejected candidate never reaches the live file"
# WHY THIS EXISTS SEPARATELY FROM THE FOUR ASSERTIONS ABOVE. Those call
# _cma_alias_gate directly, so they grade the gate in isolation and say nothing
# about whether the committer consults it: replacing cma_alias_commit's
# `elif ! _cma_alias_gate …` with `elif false` left every one of them green.
# A gate nobody calls is not a gate, so this drives a LOSSY candidate through
# the real cma_alias_commit and pins all three consequences.
#
# Only the renderer is stubbed — it is the one thing whose output has to be
# lossy, and there is no way to make the real renderer lose an alias on demand.
# The lock, the no-op guard, the gate call, the parking of the rejected
# candidate and the return status are all production code.
seed_accounts
seed_alias_file
rm -f "$ALIAS_FILE".rejected.*
cp "$ALIAS_FILE" "$HOME/.alias-gate-before"
_real_render="$(declare -f _cma_alias_render)"
_cma_alias_render() {
  # The incident's exact signature: a candidate that lost every account alias.
  grep -v '^alias claude[0-9]*=' "$1" > "$5"
}
( cma_alias_commit "" "" keep ) >/dev/null 2>&1
_gate_rc=$?
eval "$_real_render"                       # restore before any assertion can abort
assert_eq 1 "$_gate_rc" "a gate-rejected commit returns non-zero"
cmp -s "$HOME/.alias-gate-before" "$ALIAS_FILE"
assert_eq 0 $? "the live alias file is byte-unchanged after a rejected commit"
_rej_n="$(ls "$ALIAS_FILE".rejected.* 2>/dev/null | wc -l | tr -d ' ')"
assert_eq 1 "$_rej_n" "the rejected candidate is parked as \$ALIAS_FILE.rejected.<ts>"
_rej_f="$(ls "$ALIAS_FILE".rejected.* 2>/dev/null | head -1)"
_rej_acct="$(grep -c '^alias claude[0-9]*=' "$_rej_f" 2>/dev/null || true)"
assert_eq 0 "${_rej_acct:-9}" "the parked file is the LOSSY candidate, not a copy of the live file"
rm -f "$ALIAS_FILE".rejected.*
# CONTROL: with the renderer restored the very same commit succeeds, so the
# rejection above came from the gate and not from a broken fixture.
( cma_alias_commit "" "" keep ) >/dev/null 2>&1
assert_eq 0 $? "CONTROL: the same commit succeeds once the render is honest again"

it "lock: the commit RELEASES the lock (a later writer is not locked out)"
# Deleting _cma_alias_lock_release left this whole file green: every existing
# case observed the lock only while it was held or contended, never AFTER a
# successful commit. A leaked lock is invisible until the next writer.
seed_accounts
seed_alias_file
cma_write_alias claude9 "$HOME/.claude-claude9" >/dev/null 2>&1
# flock backend: the holder is THIS shell's fd 8. If it were never released,
# another process could not take it — not even at a zero wait, where there is
# no retry to paper over it.
env CMA_ALIAS_LOCK_WAIT=0 bash -c '
  # shellcheck source=/dev/null
  source "$SCRIPTS_DIR/lib.sh"; set +e; _cma_alias_lock_acquire' >/dev/null 2>&1
assert_eq 0 $? "a zero-wait acquire from another process succeeds after a commit"
# mkdir backend (macOS path): the evidence is on disk, so check it directly.
# There is no EXIT trap on this lock by design, so a missing release leaves the
# directory behind for good.
_lockdir="$(dirname "$ALIAS_FILE")/.aliases.lockdir"
rm -rf "$_lockdir"
env CMA_ALIAS_LOCK_NO_FLOCK=1 bash -c '
  # shellcheck source=/dev/null
  source "$SCRIPTS_DIR/lib.sh"; set +e
  cma_write_alias claude8 "$HOME/.claude-claude8"' >/dev/null 2>&1
_ld_left=0; [[ -d "$_lockdir" ]] && _ld_left=1
assert_eq 0 "$_ld_left" "the mkdir backend leaves no lock directory behind after a commit"
_wrote8="$(grep -c '^alias claude8=' "$ALIAS_FILE" 2>/dev/null || true)"
assert_eq 1 "${_wrote8:-0}" "CONTROL: that mkdir-backend commit really did write"

it "lock: neither acquire nor release may silence the caller's stderr"
# `exec 8>&- 2>/dev/null` reads as "close fd 8, quietly". It is not. A
# command-less `exec` applies EVERY redirection on the line to the shell
# PERMANENTLY, so that line also points the whole process's stderr at
# /dev/null for the rest of its life. Both lock paths had it, and neither
# failure was visible from the lock's own behaviour — which is why nothing
# caught it until claude-add-account's recovery message went missing under
# contention. The release site was the worse one: it is on the SUCCESS path,
# so every process that committed an alias lost every later diagnostic.
_se="$HOME/.stderr-probe"
# (a) the CONTENDED acquire path.
rm -f "$HOME/.lock-held" "$_se"
"$HOME/cma-lock-holder.sh" & _sepid=$!
_w=0; while [[ ! -f "$HOME/.lock-held" ]] && (( _w < 400 )); do sleep 0.01 2>/dev/null || sleep 1; _w=$(( _w + 1 )); done
env CMA_ALIAS_LOCK_WAIT=0 bash -c '
  # shellcheck source=/dev/null
  source "$SCRIPTS_DIR/lib.sh"; set +e
  _cma_alias_lock_acquire
  printf "MARKER_AFTER_CONTENDED_ACQUIRE\n" >&2' 2>"$_se" >/dev/null
assert_file_contains "$_se" "MARKER_AFTER_CONTENDED_ACQUIRE" \
  "stderr still works after a contended acquire"
kill "$_sepid" 2>/dev/null; wait "$_sepid" 2>/dev/null
# (b) the SUCCESSFUL acquire+release path.
rm -f "$_se"
bash -c '
  # shellcheck source=/dev/null
  source "$SCRIPTS_DIR/lib.sh"; set +e
  _cma_alias_lock_acquire
  _cma_alias_lock_release
  printf "MARKER_AFTER_RELEASE\n" >&2' 2>"$_se" >/dev/null
assert_file_contains "$_se" "MARKER_AFTER_RELEASE" \
  "stderr still works after a successful acquire+release"
# (c) and through the real committer, which is how a user meets it.
rm -f "$_se"
bash -c '
  # shellcheck source=/dev/null
  source "$SCRIPTS_DIR/lib.sh"; set +e
  cma_write_alias claude7 "$HOME/.claude-claude7" >/dev/null 2>/dev/null
  printf "MARKER_AFTER_COMMIT\n" >&2' 2>"$_se" >/dev/null
assert_file_contains "$_se" "MARKER_AFTER_COMMIT" \
  "stderr still works after a real alias commit"

it "lock: a genuinely dead holder's lock is still reclaimed (the breaker still breaks)"
# The breaker was rewritten to inspect the lock IN PLACE under its own
# exclusivity claim, instead of renaming it aside and restoring it — the
# restore was the window that let two processes hold the lock at once. This
# pins the other half of that change: making the breaker safe must not make it
# useless, or a single crashed writer wedges every later one.
_lockdir="$(dirname "$ALIAS_FILE")/.aliases.lockdir"
rm -rf "$_lockdir" "$_lockdir.breaker"
mkdir -p "$_lockdir"
printf '999999\n' > "$_lockdir/pid"        # a pid that cannot be alive
env CMA_ALIAS_LOCK_NO_FLOCK=1 CMA_ALIAS_LOCK_WAIT=5 bash -c '
  # shellcheck source=/dev/null
  source "$SCRIPTS_DIR/lib.sh"; set +e; _cma_alias_lock_acquire' >/dev/null 2>&1
assert_eq 0 $? "a lock owned by a dead pid is reclaimed"
# ...and a pid-less lock, once past the grace window, likewise.
rm -rf "$_lockdir" "$_lockdir.breaker"
mkdir -p "$_lockdir"                       # no pid file at all
env CMA_ALIAS_LOCK_NO_FLOCK=1 CMA_ALIAS_LOCK_WAIT=10 CMA_ALIAS_LOCK_STALE_GRACE=1 bash -c '
  # shellcheck source=/dev/null
  source "$SCRIPTS_DIR/lib.sh"; set +e; _cma_alias_lock_acquire' >/dev/null 2>&1
assert_eq 0 $? "a pid-less lock is reclaimed after the stale grace"
# CONTROL: a LIVE holder is never broken, however long the contender waits.
rm -rf "$_lockdir" "$_lockdir.breaker"
rm -f "$HOME/.lock-held"
cat > "$HOME/cma-live-holder.sh" <<'LIVE_EOF'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=/dev/null
source "$SCRIPTS_DIR/lib.sh"
set +e
_cma_alias_lock_acquire || exit 9
: > "$HOME/.lock-held"
# Live until the test explicitly stops us. A fixed `sleep 6` lifetime races
# the breaker loop under scheduler pressure: when the holder exits it LEAVES
# the dead-pid lockdir behind (it has no release trap), and the CONTROL that
# later re-reads that pid correctly reports the recorded owner as gone. The
# holder must survive the whole loop, not merely its first six seconds.
while [[ ! -f "$HOME/.lock-stop" ]]; do sleep 0.1 2>/dev/null || sleep 1; done
exit 0
LIVE_EOF
chmod +x "$HOME/cma-live-holder.sh"
CMA_ALIAS_LOCK_NO_FLOCK=1 "$HOME/cma-live-holder.sh" & _live_pid=$!
_w=0; while [[ ! -f "$HOME/.lock-held" ]] && (( _w < 400 )); do sleep 0.01 2>/dev/null || sleep 1; _w=$(( _w + 1 )); done
env CMA_ALIAS_LOCK_NO_FLOCK=1 CMA_ALIAS_LOCK_WAIT=2 CMA_ALIAS_LOCK_STALE_GRACE=1 bash -c '
  # shellcheck source=/dev/null
  source "$SCRIPTS_DIR/lib.sh"; set +e; _cma_alias_lock_acquire' >/dev/null 2>&1
assert_eq 1 $? "CONTROL: a LIVE holder's lock is never broken"
: > "$HOME/.lock-stop"
kill "$_live_pid" 2>/dev/null; wait "$_live_pid" 2>/dev/null
rm -f "$HOME/.lock-stop"
rm -rf "$_lockdir" "$_lockdir.breaker"

# The transient-absence property, sampled directly. The section-1b storm does
# catch a non-excluding breaker, but only probabilistically (it has to lose a
# race to notice), so restoring the old breaker survived a whole run of it.
# This case is the deterministic one.
#
# The old breaker renamed the lock ASIDE, inspected the pid, and renamed it
# BACK when the pid was not the one it had been told was dead. Its END STATE is
# correct, which is exactly why an end-state assertion is blind to it: during
# the round trip the lock DOES NOT EXIST, and any contender's `mkdir` succeeds
# in that window and joins the holder inside the critical section. So what is
# graded here is the absence itself — a live holder's lock must never blink out
# of existence, not even for a moment, no matter what a breaker was told.
it "lock: breaking a 'stale' lock never makes a LIVE holder's lock blink out"
_lockdir="$(dirname "$ALIAS_FILE")/.aliases.lockdir"
rm -rf "$_lockdir" "$_lockdir.breaker"
rm -f "$HOME/.lock-held" "$HOME/.lock-stop"
CMA_ALIAS_LOCK_NO_FLOCK=1 "$HOME/cma-live-holder.sh" & _blink_pid=$!
_w=0; while [[ ! -f "$HOME/.lock-held" ]] && (( _w < 400 )); do sleep 0.01 2>/dev/null || sleep 1; _w=$(( _w + 1 )); done
_blink_flag="$HOME/.blink-running"; _blink_log="$HOME/.blink-absences"
rm -f "$_blink_log"; : > "$_blink_flag"
cat > "$HOME/cma-blink-sampler.sh" <<'BLINK_EOF'
#!/usr/bin/env bash
# Tight loop: record every sample in which the lock directory is absent.
set -uo pipefail
dir="$1"; flag="$2"; log="$3"
while [[ -f "$flag" ]]; do
  [[ -d "$dir" ]] || printf 'ABSENT\n' >> "$log"
done
exit 0
BLINK_EOF
chmod +x "$HOME/cma-blink-sampler.sh"
"$HOME/cma-blink-sampler.sh" "$_lockdir" "$_blink_flag" "$_blink_log" & _blink_sampler=$!
# Drive the breaker directly. It reads $_cma_alias_lock_file/_mode, which only
# _cma_alias_lock_acquire normally sets, so this shell sets them itself — the
# point is to exercise break_stale against a lock it does NOT own.
_cma_alias_lock_mode="mkdir"
_cma_alias_lock_file="$_lockdir"
for _i in $(seq 1 200); do
  # 999999 cannot be alive, so the breaker is being told "that holder is gone"
  # while a DIFFERENT, live process actually owns the directory.
  _cma_alias_lock_break_stale 999999 >/dev/null 2>&1
done
rm -f "$_blink_flag"
wait "$_blink_sampler" 2>/dev/null
_blinks="$(grep -c . "$_blink_log" 2>/dev/null || true)"
assert_eq 0 "${_blinks:-0}" "200 stale-breaks never removed the live holder's lock, even transiently"
# CONTROL: the holder really did hold it throughout, so the sampler had
# something to observe.
_held_pid="$(head -1 "$_lockdir/pid" 2>/dev/null | tr -d '[:space:]')"
_alive=1; [[ -n "$_held_pid" ]] && kill -0 "$_held_pid" 2>/dev/null && _alive=0
assert_eq 0 "$_alive" "CONTROL: a live holder still owns the lock after 200 break attempts"
: > "$HOME/.lock-stop"
kill "$_blink_pid" 2>/dev/null; wait "$_blink_pid" 2>/dev/null
rm -f "$HOME/.lock-stop"
rm -rf "$_lockdir" "$_lockdir.breaker"
_cma_alias_lock_mode=""; _cma_alias_lock_file=""


it "recovery: an externally truncated file is rebuilt without losing its aliases"
# Defence in depth for damage this toolkit no longer causes but cannot rule out
# (an editor crash, a full disk, another tool): a file cut off INSIDE the
# managed block has an opening sentinel with no closing one and an unterminated
# wrapper. The carryover must not let either swallow the alias lines below.
rm -f "$ALIAS_FILE"
cma_ensure_alias_file >/dev/null 2>&1
for a in "${ACCOUNTS[@]}"; do cma_write_alias "$a" "$HOME/.claude-$a" >/dev/null 2>&1; done
head -30 "$ALIAS_FILE" > "$HOME/.alias-trunc"
for a in "${ACCOUNTS[@]}"; do
  printf 'alias %s="CLAUDE_CONFIG_DIR=%s/.claude-%s cma_run"\n' "$a" "$HOME" "$a" >> "$HOME/.alias-trunc"
done
cp "$HOME/.alias-trunc" "$ALIAS_FILE"
cma_ensure_alias_file >/dev/null 2>&1
_r="$(alias_file_report)"
printf '    after truncation repair: %s\n' "$_r"
_runs="$(grep -c '^cma_run() {' "$ALIAS_FILE" || true)"
assert_eq 1 "${_runs:-0}" "cma_run() rebuilt after an external truncation"
_provs="$(grep -c '^cma_run_provider() {' "$ALIAS_FILE" || true)"
assert_eq 1 "${_provs:-0}" "cma_run_provider() rebuilt after an external truncation"
_acct="$(grep -c '^alias claude[0-9]*=' "$ALIAS_FILE" || true)"
assert_eq "${#ACCOUNTS[@]}" "$_acct" "no account alias lost to the truncation repair"
bash -n "$ALIAS_FILE" 2>/dev/null; assert_eq 0 $? "repaired alias file parses"

it "user-added content outside the managed block is carried over"
seed_alias_file
printf 'MY_CUSTOM_VAR=preserved\n' >> "$ALIAS_FILE"
cma_ensure_alias_file >/dev/null 2>&1
assert_file_contains "$ALIAS_FILE" "MY_CUSTOM_VAR=preserved" "user line survives a full re-render"

summary
