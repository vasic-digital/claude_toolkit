#!/usr/bin/env bash
# test_proxy_daemon_stdio.sh — the cma-proxy daemon must not inherit its
# launcher's stdio, and must not be orphaned when its listener cannot be
# confirmed.
#
# ── THE DEFECT ──────────────────────────────────────────────────────────────
# lib.sh's cma_run_provider backgrounded the proxy with NO redirection:
#
#     CMA_PROVIDER_BASE_URL="$CMA_PROVIDER_BASE_URL" \
#       "$_proxy_bin" --provider "$CMA_PROVIDER_ID" --port "$_proxy_port" &
#
# A backgrounded daemon inherits the caller's stdout/stderr, and therefore holds
# the WRITE END of any pipe the caller installed. Two distinct consequences, one
# conditional and one unconditional:
#
#   (1) HANG. Callers capture the launch with command substitution
#       (verify_superpowers_tui.sh, claude-release-gate.sh). `$(...)` returns on
#       EOF, and EOF cannot arrive while a live daemon still holds the pipe — so
#       the capture blocks for the proxy's ENTIRE lifetime. Measured on this
#       host: 30005ms with the inherited pipe vs 5ms with redirection, both
#       rc=0. It bites on the SUCCESS path, where `timeout` has already reaped
#       its own child and can bound nothing. It is reached deterministically
#       whenever the proxy is orphaned — which the `_proxy_pid=""` branch does
#       on every host lacking `lsof` (an undeclared dependency: there is no
#       `command -v lsof` anywhere in the repo, so the probe simply fails and
#       that branch is always taken).
#
#   (2) CORRUPTION — unconditional, and present even when the proxy IS reaped.
#       cma-proxy prints a startup banner to stderr, and callers apply `2>&1`
#       to the whole cma_run_provider call, so the banner lands INSIDE the
#       captured payload. That breaks `jq` on captured JSON; it survives today
#       only because both consumers happen to parse by substring.
#
# ── WHAT THIS FILE PINS ─────────────────────────────────────────────────────
# Structurally, that the spawn as EMITTED INTO THE ALIAS FILE (not merely as
# written in lib.sh — it lives inside a `cat <<'CMA_PROV_BODY_EOF'` heredoc, so
# the emitted text is the only thing that runs) redirects stdout, merges stderr
# and closes stdin; and that the failure branch kills before it clears.
#
# Behaviourally — the part that actually proves the bug — by EXECUTING the
# extracted spawn text against a stand-in daemon inside a command substitution
# and measuring how long the capture takes to return. The behavioural cases run
# the SHIPPED bytes, so they cannot be satisfied by a comment that merely looks
# like a fix.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e

# The file under test may be overridden so the RED proof can point this same
# suite at a pre-fix copy of lib.sh without editing the working tree.
LIB_UNDER_TEST="${CMA_TEST_LIB:-$SCRIPTS_DIR/lib.sh}"
LIVE_UNDER_TEST="${CMA_TEST_LIVE:-$TESTS_DIR/verify_aliases_live.sh}"

# ── helpers ────────────────────────────────────────────────────────────────

# extract_spawn FILE — print the complete LOGICAL command line that backgrounds
# cma-proxy: the line carrying both `_proxy_bin` and `--provider`, extended
# backwards and forwards across trailing-backslash continuations. Works on both
# the pre-fix 2-line form and the post-fix 3-line form, and on both callers
# (lib.sh's `--port "$_proxy_port"` and verify_aliases_live.sh's `${_up:+…}`).
#
# Portability: index()/regex only, no GNU-only 3-arg match().
extract_spawn() {
  awk '
    { L[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (index(L[i], "_proxy_bin") && index(L[i], "--provider")) {
          s = i; while (s > 1 && L[s-1] ~ /\\[[:space:]]*$/) s--
          e = i; while (L[e] ~ /\\[[:space:]]*$/) e++
          for (j = s; j <= e; j++) print L[j]
          exit
        }
      }
    }
  ' "$1"
}

# extract_lib_fail_branch FILE — print the "listener not confirmed" branch of
# cma_run_provider, from the `if ! lsof -a -p "$_proxy_pid"` guard through the
# `fi` that follows `_proxy_script=""`. The `seen` latch matters: the fixed body
# contains an inner `fi` (the kill guard) before that assignment.
extract_lib_fail_branch() {
  awk '
    /if ! lsof -a -p "\$_proxy_pid"/ { on = 1 }
    on { print }
    on && /_proxy_script=""/ { seen = 1; next }
    seen && /^[[:space:]]*fi[[:space:]]*$/ { exit }
  ' "$1"
}

# extract_live_fail_branch FILE — verify_aliases_live.sh's equivalent region:
# the `if lsof -a -p "$PROXY_PID"` guard through the line clearing PROXY_PID.
extract_live_fail_branch() {
  awk '
    /if lsof -a -p "\$PROXY_PID"/ { on = 1 }
    on { print }
    on && /PROXY_PID=""/ { exit }
  ' "$1"
}

# assert_redirected LABEL SPAWNTEXT — three independent facts, reported
# separately so a partial fix cannot hide behind an aggregate verdict.
assert_redirected() {
  local label="$1" spawn="$2" stripped
  # stdout: look for a `>` that is not the `2>&1` merge and not a `>&` dup.
  stripped="${spawn//2>&1/}"
  if [[ "$stripped" == *">"* ]]; then
    _pass "$label: daemon stdout is redirected to a file"
  else
    _fail "$label: daemon stdout is NOT redirected" \
          "it inherits the caller's stdout and holds any \$( ) pipe open: $spawn"
  fi
  if [[ "$spawn" == *"2>&1"* ]]; then
    _pass "$label: daemon stderr is merged away from the caller"
  else
    _fail "$label: daemon stderr is NOT redirected" \
          "its startup banner lands inside the caller's 2>&1 capture: $spawn"
  fi
  if [[ "$spawn" == *"</dev/null"* || "$spawn" == *"< /dev/null"* ]]; then
    _pass "$label: daemon stdin is closed"
  else
    _fail "$label: daemon stdin is NOT closed" \
          "expected </dev/null (mirrors ccr's spawn_unix.go): $spawn"
  fi
  if [[ "$spawn" == *"&" ]]; then
    _pass "$label: spawn is still backgrounded"
  else
    _fail "$label: spawn is no longer backgrounded" "$spawn"
  fi
}

# ── generate the alias file in the sandbox ─────────────────────────────────
# The wrapper is emitted through a quoted heredoc, so only the GENERATED text
# proves the edit survived that quoting.
mkdir -p "$(dirname "$ALIAS_FILE")" "$SANDBOX_HOME/.local/bin"
CMA_RC_FILES=("$SANDBOX_HOME/.unused-rc")
if [[ "$LIB_UNDER_TEST" != "$SCRIPTS_DIR/lib.sh" ]]; then
  # RED-proof mode: emit the alias file from the alternate lib.sh instead.
  ( set +u; source "$LIB_UNDER_TEST" >/dev/null 2>&1
    CMA_RC_FILES=("$SANDBOX_HOME/.unused-rc")
    cma_ensure_alias_file >/dev/null 2>&1 )
else
  cma_ensure_alias_file >/dev/null 2>&1
fi

it "the generated alias file really defines the provider wrapper"
assert_file "$ALIAS_FILE" "alias file generated"
assert_fn_from --source "$ALIAS_FILE" cma_run_provider "$ALIAS_FILE" \
  "wrapper provenance (graded text is the generated file, not the host's)"

# ── 1. structural: lib.sh's emitted spawn ──────────────────────────────────
it "cma_run_provider's emitted cma-proxy spawn redirects the daemon's stdio"
lib_spawn="$(extract_spawn "$ALIAS_FILE")"
if [[ -z "$lib_spawn" ]]; then
  _fail "extractor found no cma-proxy spawn in the generated alias file" \
        "the extractor, not the fix, is broken — investigate before trusting a green run"
else
  _pass "extracted spawn from generated alias file ($(printf '%s\n' "$lib_spawn" | wc -l | tr -d ' ') lines)"
  assert_redirected "alias-file spawn" "$lib_spawn"
fi

# ── 2. structural: verify_aliases_live.sh's spawn ──────────────────────────
it "verify_aliases_live.sh's cma-proxy spawn redirects the daemon's stdio"
live_spawn="$(extract_spawn "$LIVE_UNDER_TEST")"
if [[ -z "$live_spawn" ]]; then
  _fail "extractor found no cma-proxy spawn in verify_aliases_live.sh" \
        "the extractor, not the fix, is broken"
else
  _pass "extracted spawn from $(basename "$LIVE_UNDER_TEST") ($(printf '%s\n' "$live_spawn" | wc -l | tr -d ' ') lines)"
  assert_redirected "verify_aliases_live spawn" "$live_spawn"
fi

# ── 3. structural: the orphan branch kills before it clears ────────────────
it "the unconfirmed-listener branch kills the proxy before blanking its pid"
lib_branch="$(extract_lib_fail_branch "$ALIAS_FILE")"
if [[ -z "$lib_branch" ]]; then
  _fail "extractor found no unconfirmed-listener branch in the alias file" \
        "the extractor, not the fix, is broken"
else
  _pass "extracted branch ($(printf '%s\n' "$lib_branch" | wc -l | tr -d ' ') lines)"
  if [[ "$lib_branch" == *'kill "$_proxy_pid"'* ]]; then
    _pass "alias-file branch reaps the child before clearing _proxy_pid"
  else
    _fail "alias-file branch orphans the proxy" \
          "_proxy_pid is the only handle the exit reap is guarded on; blanking it without killing leaks a live daemon"
  fi
fi
live_branch="$(extract_live_fail_branch "$LIVE_UNDER_TEST")"
if [[ -z "$live_branch" ]]; then
  _fail "extractor found no unconfirmed-listener branch in verify_aliases_live.sh" \
        "the extractor, not the fix, is broken"
else
  _pass "extracted live branch ($(printf '%s\n' "$live_branch" | wc -l | tr -d ' ') lines)"
  if [[ "$live_branch" == *'kill "$PROXY_PID"'* ]]; then
    _pass "verify_aliases_live branch reaps the child before clearing PROXY_PID"
  else
    _fail "verify_aliases_live branch orphans the proxy" \
          "PROXY_PID is the only handle maybe_stop_proxy is guarded on"
  fi
fi

# ── 4. behavioural: a command substitution around the REAL spawn text ──────
# Stand-in daemon: writes to both streams (like cma-proxy's startup banner),
# then lives on. Its lifetime bounds the whole case, so no `timeout` is needed
# (macOS has no coreutils `timeout`) — a broken build costs DAEMON_LIFE seconds,
# it never hangs the suite.
DAEMON_LIFE=4
standin="$SANDBOX_HOME/standin-daemon.sh"
cat > "$standin" <<EOF
#!/usr/bin/env bash
printf 'CMA_PROXY_BANNER listening on 127.0.0.1\n' >&2
printf 'CMA_PROXY_STDOUT_NOISE\n'
sleep $DAEMON_LIFE
EOF
chmod +x "$standin"

ccrhome="$SANDBOX_HOME/ccr-home/testprov"
mkdir -p "$ccrhome"
harness="$SANDBOX_HOME/spawn-harness.sh"
{
  printf '%s\n' '#!/usr/bin/env bash' 'set -u'
  printf '_proxy_bin=%q\n'             "$standin"
  printf 'CMA_PROVIDER_ID=%q\n'        'testprov'
  printf 'CMA_PROVIDER_BASE_URL=%q\n'  'http://127.0.0.1:1/v1'
  printf '_proxy_port=%q\n'            '65535'
  printf '_ccr_home=%q\n'              "$ccrhome"
  printf '%s\n' "$lib_spawn"
  printf '%s\n' '_proxy_pid=$!' 'printf "LAUNCH_DONE\n"' 'exit 0'
} > "$harness"

it "a \$( ) capture of the spawn returns at launch, not at daemon exit"
_t0=$SECONDS
cap_out="$(bash "$harness" 2>&1)"
cap_rc=$?
elapsed=$((SECONDS - _t0))

assert_eq 0 "$cap_rc" "harness exit status"
if (( elapsed < 2 )); then
  _pass "capture returned in ${elapsed}s (daemon lives ${DAEMON_LIFE}s) — the pipe was not inherited"
else
  _fail "capture blocked for ${elapsed}s" \
        "the daemon inherited the caller's stdout and held the \$( ) pipe until it exited (daemon life ${DAEMON_LIFE}s)"
fi

it "the daemon's banner stays OUT of the captured payload"
assert_eq "LAUNCH_DONE" "$cap_out" "captured payload is exactly the launcher's own output"
if [[ "$cap_out" != *CMA_PROXY_BANNER* && "$cap_out" != *CMA_PROXY_STDOUT_NOISE* ]]; then
  _pass "no daemon output leaked into the capture"
else
  _fail "daemon output corrupted the captured payload" \
        "this is what breaks jq on captured JSON; got: $cap_out"
fi

it "the daemon's output lands in its own log instead"
sleep 1   # give the child a moment to flush its banner
assert_file "$ccrhome/cma-proxy.log" "per-provider proxy log created by the redirect"
assert_file_contains "$ccrhome/cma-proxy.log" "CMA_PROXY_BANNER" \
  "daemon stderr banner captured in the log"
assert_file_contains "$ccrhome/cma-proxy.log" "CMA_PROXY_STDOUT_NOISE" \
  "daemon stdout captured in the log"

# ── 5. behavioural: the orphan branch actually kills a live child ───────────
it "the unconfirmed-listener branch terminates a still-running proxy"
pidfile="$SANDBOX_HOME/reaped.pid"
reap_harness="$SANDBOX_HOME/reap-harness.sh"
{
  printf '%s\n' '#!/usr/bin/env bash' 'set -u'
  # Force the branch: lsof is an undeclared dependency, so "always fails" is
  # exactly the real-world state on a host without it.
  printf '%s\n' 'lsof() { return 1; }'
  printf 'CMA_PROVIDER_ID=%q\n' 'testprov'
  printf '_proxy_port=%q\n'     '65535'
  printf '%s\n' "sleep 30 >/dev/null 2>&1 </dev/null &" '_proxy_pid=$!' '_proxy_script="x"'
  printf 'printf %%s "$_proxy_pid" > %q\n' "$pidfile"
  printf '%s\n' "$lib_branch"
  printf '%s\n' 'exit 0'
} > "$reap_harness"
bash "$reap_harness" >/dev/null 2>&1
reap_rc=$?
assert_eq 0 "$reap_rc" "reap harness exit status"
assert_file "$pidfile" "reap harness recorded the child pid"
reaped_pid="$(cat "$pidfile" 2>/dev/null)"
sleep 1
if [[ -n "$reaped_pid" ]] && ! kill -0 "$reaped_pid" 2>/dev/null; then
  _pass "child pid $reaped_pid is gone after the branch ran"
else
  _fail "child pid ${reaped_pid:-<none>} survived the branch" \
        "the proxy was orphaned: it keeps its port, and pre-redirection kept the caller's pipe open forever"
  [[ -n "$reaped_pid" ]] && kill "$reaped_pid" 2>/dev/null
fi

summary
