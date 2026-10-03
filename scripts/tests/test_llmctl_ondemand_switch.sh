#!/usr/bin/env bash
# test_llmctl_ondemand_switch.sh — hermetic TDD coverage for the on-demand
# llmctl profile switch that must happen BEFORE an llmctl-<profile>-backed
# alias (base/kimi/pi) actually launches its CLI against that profile's
# fixed port.
#
# THE GAP THIS CLOSES. Every llmctl-<profile> provider record (see
# detect_llmctl_records / claude-providers.sh) is only ever REGISTERED while
# <profile> happens to already be the live model at its fixed port. Nothing
# in cma_run_provider / cma_run_kimi_provider / cma_run_pi_provider ever
# re-checks — let alone re-asserts — that <profile> is STILL the live model
# at launch time, so invoking e.g. `llmctl-fast` after the host switched to
# a different llmctl profile silently connects to whatever (or nothing) is
# now answering on that fixed port. The fix: before the underlying CLI is
# actually exec'd, each of the three wrapper families must call the shared,
# self-contained `_cma_llmctl_ensure_active <provider_id>` helper, which:
#   1. is a no-op for any non-"llmctl-*" provider id (every other provider
#      family is untouched);
#   2. checks whether <profile> is ALREADY the sole running llmctl profile
#      (via `llmctl status`, mirroring llmctl's OWN sched_switch no-op
#      condition) and, if so, returns 0 WITHOUT calling `llmctl switch` —
#      avoiding the needless latency of a switch call (let alone a model
#      reload) on repeated back-to-back invocations of the SAME alias;
#   3. otherwise calls `llmctl switch <profile>` and, on success, returns 0;
#   4. on `llmctl switch` failure (non-zero exit), aborts WITHOUT launching
#      the underlying CLI at all, propagating llmctl's own exit code and
#      citing llmctl's own stderr — never silently proceeding to connect
#      against a port that may now host the wrong model or nothing.
#
# Fully hermetic: a fake `llmctl` binary (bin resolved via CMA_LLMCTL_BIN,
# the SAME override `detect_llmctl_records` already honors — no new
# discovery mechanism invented) records every `status`/`switch` invocation
# to a plain file under a sandboxed temp dir and simulates both a successful
# and a failing `switch`. The REAL claude/kimi/pi binaries are NEVER invoked;
# each is stubbed the same way the existing test_pi_alias_file.sh /
# test_kimi_llmctl_integration.sh suites already stub their own CLI. The
# REAL /home/milosvasic/Projects/llmctl/bin/llmctl is NEVER invoked by this
# file — see the fake-llmctl section below.
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
set +e   # lib.sh sets -e; the harness asserts on failures, so relax it.

PDIR="$(cma_providers_dir)"; mkdir -p "$PDIR"
PROVIDER_ID="llmctl-fast"
PROFILE="fast"

# SAFETY: transport is 'native' for every provider record in this file (never
# 'router') so cma_run_provider NEVER reaches its ccr-gateway branch, which
# would resolve a REAL `ccr` off the inherited (non-sandboxed) PATH and spawn
# a REAL claude-code-router gateway process — reproduced live while writing
# this test (two real `ccr serve` processes spawned + a real `ccr
# default-claude-code -- -p hi` child, immediately killed once diagnosed).
# CMA_CCR_BIN is ALSO pointed at a nonexistent path as a second, independent
# guard in case any future edit here ever sets transport=router by accident.
export CMA_CCR_BIN="$HOME/no-such-ccr-must-never-resolve"
export ACME_API_KEY=x
export LLMCTL_API_KEY=x
: > "$HOME/api_keys.sh"
{ echo 'export ACME_API_KEY=x'; echo 'export LLMCTL_API_KEY=x'; } > "$HOME/api_keys.sh"

# --- fake llmctl: records every call, simulates status + switch -------------
LC_DIR="$HOME/lc-state"; mkdir -p "$LC_DIR"
LC_BIN="$HOME/.local/bin/llmctl-fake"
sandbox_stub "$LC_BIN" <<'EOF'
#!/usr/bin/env bash
set -u
DIR="${LLMCTL_TEST_DIR:?LLMCTL_TEST_DIR must be set}"
mkdir -p "$DIR"
case "${1:-}" in
  status)
    printf 'status\n' >> "$DIR/calls"
    active="$(cat "$DIR/active" 2>/dev/null || true)"
    if [[ -z "$active" ]]; then
      echo "no llmctl services running"
    else
      printf '%-16s %-6s %-8s %-10s %-10s %-8s %s\n' "profile" "port" "mode" "RAM MiB" "VRAM MiB" "enabled" "state"
      # $DIR/active may hold more than one name (one per line) to simulate a
      # real multi-profile-running host (finding 4 regression coverage) --
      # each gets its own data row, mirroring sched_status's real output.
      while IFS= read -r _active_row; do
        [[ -n "$_active_row" ]] || continue
        printf '%-16s %-6s %-8s %-10s %-10s %-8s %s\n' "$_active_row" "8080" "cpu" "100" "0" "no" "running"
      done <<<"$active"
    fi
    ;;
  switch)
    profile="${2:-}"
    printf 'switch %s\n' "$profile" >> "$DIR/calls"
    if [[ -f "$DIR/fail_rollback" ]]; then
      # Mirrors the real upstream llmctl's own disclosed degraded case
      # (lib/scheduler.sh ROLLBACK ALSO FAILED, research.md LLMCTL-F2): the
      # switch fails AND the best-effort restore of the previously-running
      # set also fails, so "active" is cleared rather than left pointing at
      # the prior profile.
      echo "switch to '$profile' failed - ROLLBACK ALSO FAILED - the host may have fewer services running than before" >&2
      rm -f "$DIR/active"
      exit "$(cat "$DIR/fail_rc" 2>/dev/null || echo 1)"
    fi
    if [[ -f "$DIR/fail_switch" ]]; then
      echo "switch to '$profile' failed - restoring the previously-running set: (simulated)" >&2
      # fail_switch_drop (independent-review finding 4 follow-up): names a
      # profile that, independently of the switch itself, is no longer
      # running by the time the caller re-probes -- the realistic "partial
      # survival" case (one of several previously-running profiles happens
      # to have also died) that an all-survived or all-gone fixture cannot
      # exercise.
      if [[ -f "$DIR/fail_switch_drop" ]]; then
        _drop="$(cat "$DIR/fail_switch_drop")"
        grep -vxF "$_drop" "$DIR/active" > "$DIR/active.tmp" 2>/dev/null || true
        mv "$DIR/active.tmp" "$DIR/active"
      fi
      exit "$(cat "$DIR/fail_rc" 2>/dev/null || echo 1)"
    fi
    printf '%s' "$profile" > "$DIR/active"
    exit 0
    ;;
  *)
    echo "llmctl-fake: unhandled args: $*" >&2
    exit 64
    ;;
esac
EOF

export CMA_LLMCTL_BIN="$LC_BIN"
export LLMCTL_TEST_DIR="$LC_DIR"

reset_lc() {
  rm -f "$LC_DIR/calls" "$LC_DIR/active" "$LC_DIR/fail_switch" "$LC_DIR/fail_rc" "$LC_DIR/fail_rollback" "$LC_DIR/fail_switch_drop"
}
lc_calls() { cat "$LC_DIR/calls" 2>/dev/null || true; }
lc_switch_count() { lc_calls | grep -c '^switch '; }
lc_status_count() { lc_calls | grep -c '^status$'; }

# --- write the shared llmctl-fast provider .env + verified status ----------
cat > "$PDIR/$PROVIDER_ID.env" <<EOF
CMA_PROVIDER_ID='$PROVIDER_ID'
CMA_PROVIDER_KEYVAR='LLMCTL_API_KEY'
CMA_PROVIDER_TRANSPORT='native'
CMA_PROVIDER_BASE_URL='http://127.0.0.1:8080/v1'
CMA_PROVIDER_MODEL='fast-model'
CMA_PROVIDER_FAST_MODEL='fast-model'
CMA_PROVIDER_CONFIG_DIR='claude-llmctl-fast'
CMA_PROVIDER_CONTEXT_LIMIT='8192'
CMA_PROVIDER_MAX_OUTPUT='4096'
CMA_PROVIDER_ALIAS='llmctl-fast'
EOF
cma_status_write "$PROVIDER_ID" verified fast-model ""

REC_DIR="$HOME/rec"; mkdir -p "$REC_DIR"

# ===========================================================================
# Family 1 — base cma_run_provider (native Claude Code twin)
# ===========================================================================
# The fake claude stub + CLAUDE_BIN export MUST land BEFORE
# cma_ensure_alias_file: the managed block's header line
# (`export CLAUDE_BIN="..."`) bakes in whatever CLAUDE_BIN resolves to AT
# GENERATION TIME, and sourcing the generated $ALIAS_FILE re-exports that
# baked value — clobbering a CLAUDE_BIN set only AFTER the file was written
# (reproduced live: doing this the other way round silently ran
# /usr/bin/true, make_sandbox's dummy, instead of the stub).
mkdir -p "$HOME/.local/bin"
sandbox_stub "$HOME/.local/bin/claude" <<EOF
#!/usr/bin/env bash
touch "$REC_DIR/claude-launched"
exit 0
EOF
export CLAUDE_BIN="$HOME/.local/bin/claude"
cma_ensure_alias_file

# shellcheck source=/dev/null
source "$ALIAS_FILE"
it "HYGIENE: cma_run_provider under test comes from the sandbox alias file"
assert_fn_from cma_run_provider "$ALIAS_FILE" "cma_run_provider from sandbox"

it "cma_run_provider: llmctl-fast already active -> no switch call, claude launches"
reset_lc
printf '%s' "$PROFILE" > "$LC_DIR/active"
rm -f "$REC_DIR/claude-launched"
( set +eu; cma_run_provider "$PROVIDER_ID" -p hi </dev/null >/dev/null 2>&1 ); rc=$?
assert_eq 0 "$rc" "already-active launch exits 0"
assert_eq 1 "$(lc_status_count)" "status consulted exactly once"
assert_eq 0 "$(lc_switch_count)" "no switch call when already active"
assert_file "$REC_DIR/claude-launched" "claude actually launched"

it "cma_run_provider: a DIFFERENT profile active -> switch IS called before launch"
reset_lc
printf 'vision' > "$LC_DIR/active"
rm -f "$REC_DIR/claude-launched"
( set +eu; cma_run_provider "$PROVIDER_ID" -p hi </dev/null >/dev/null 2>&1 ); rc=$?
assert_eq 0 "$rc" "switch-then-launch exits 0"
assert_eq 1 "$(lc_switch_count)" "switch called exactly once"
assert_eq "switch $PROFILE" "$(lc_calls | grep '^switch ')" "switch called with the correct profile name"
assert_file "$REC_DIR/claude-launched" "claude launched after successful switch"

it "cma_run_provider: llmctl switch FAILS -> launch aborts, claude never runs"
reset_lc
printf 'vision' > "$LC_DIR/active"
: > "$LC_DIR/fail_switch"; printf '7' > "$LC_DIR/fail_rc"
rm -f "$REC_DIR/claude-launched"
out="$( set +eu; cma_run_provider "$PROVIDER_ID" -p hi </dev/null 2>&1 )"; rc=$?
assert_eq 7 "$rc" "switch failure exit code propagated verbatim"
[[ ! -f "$REC_DIR/claude-launched" ]] && ok=0 || ok=1
assert_eq 0 "$ok" "claude was NEVER launched after a failed switch"
[[ "$out" == *"llmctl switch"* ]] && ok=0 || ok=1
assert_eq 0 "$ok" "abort message names llmctl switch"
[[ "$out" == *"$PROFILE"* ]] && ok=0 || ok=1
assert_eq 0 "$ok" "abort message names the target profile"

it "cma_run_provider: a NON-llmctl provider never touches llmctl at all"
cat > "$PDIR/acme.env" <<'EOF'
CMA_PROVIDER_ID='acme'
CMA_PROVIDER_KEYVAR='ACME_API_KEY'
CMA_PROVIDER_TRANSPORT='native'
CMA_PROVIDER_BASE_URL='https://api.acme.example/v1'
CMA_PROVIDER_MODEL='acme-model'
CMA_PROVIDER_FAST_MODEL='acme-model'
CMA_PROVIDER_CONFIG_DIR='claude-acme'
CMA_PROVIDER_CONTEXT_LIMIT=''
CMA_PROVIDER_MAX_OUTPUT=''
CMA_PROVIDER_ALIAS='acme'
EOF
cma_status_write acme verified acme-model ""
reset_lc
rm -f "$REC_DIR/claude-launched"
( set +eu; cma_run_provider acme -p hi </dev/null >/dev/null 2>&1 ); rc=$?
assert_eq 0 "$rc" "non-llmctl provider launches fine"
assert_eq 0 "$(lc_status_count)" "non-llmctl provider never calls llmctl status"
assert_eq 0 "$(lc_switch_count)" "non-llmctl provider never calls llmctl switch"
assert_file "$REC_DIR/claude-launched" "claude launched for the non-llmctl provider"

# ===========================================================================
# Family 2 — kimi-llmctl-fast (cma_run_kimi_provider)
# ===========================================================================
KIMI_HOME="$HOME/.kimi-prov-$PROVIDER_ID"; mkdir -p "$KIMI_HOME"
cat > "$KIMI_HOME/config.toml" <<EOF
default_model = "$PROVIDER_ID/fast-model"
base_url = "http://127.0.0.1:8080/v1"
EOF
mkdir -p "$HOME/.kimi-code/bin"
sandbox_stub "$HOME/.kimi-code/bin/kimi" <<EOF
#!/usr/bin/env bash
touch "$REC_DIR/kimi-launched"
exit 0
EOF

it "cma_run_kimi_provider: llmctl-fast already active -> no switch call, kimi launches"
reset_lc
printf '%s' "$PROFILE" > "$LC_DIR/active"
rm -f "$REC_DIR/kimi-launched"
( set +eu; cma_run_kimi_provider "$PROVIDER_ID" -p hi </dev/null >/dev/null 2>&1 ); rc=$?
assert_eq 0 "$rc" "kimi already-active launch exits 0"
assert_eq 1 "$(lc_status_count)" "kimi: status consulted exactly once"
assert_eq 0 "$(lc_switch_count)" "kimi: no switch call when already active"
assert_file "$REC_DIR/kimi-launched" "kimi actually launched"

it "cma_run_kimi_provider: a DIFFERENT profile active -> switch IS called before launch"
reset_lc
printf 'vision' > "$LC_DIR/active"
rm -f "$REC_DIR/kimi-launched"
( set +eu; cma_run_kimi_provider "$PROVIDER_ID" -p hi </dev/null >/dev/null 2>&1 ); rc=$?
assert_eq 0 "$rc" "kimi switch-then-launch exits 0"
assert_eq 1 "$(lc_switch_count)" "kimi: switch called exactly once"
assert_eq "switch $PROFILE" "$(lc_calls | grep '^switch ')" "kimi: switch called with the correct profile"
assert_file "$REC_DIR/kimi-launched" "kimi launched after successful switch"

it "cma_run_kimi_provider: llmctl switch FAILS -> launch aborts, kimi never runs"
reset_lc
printf 'vision' > "$LC_DIR/active"
: > "$LC_DIR/fail_switch"; printf '7' > "$LC_DIR/fail_rc"
rm -f "$REC_DIR/kimi-launched"
out="$( set +eu; cma_run_kimi_provider "$PROVIDER_ID" -p hi </dev/null 2>&1 )"; rc=$?
assert_eq 7 "$rc" "kimi: switch failure exit code propagated verbatim"
[[ ! -f "$REC_DIR/kimi-launched" ]] && ok=0 || ok=1
assert_eq 0 "$ok" "kimi was NEVER launched after a failed switch"
[[ "$out" == *"llmctl switch"* ]] && ok=0 || ok=1
assert_eq 0 "$ok" "kimi: abort message names llmctl switch"

# ===========================================================================
# Family 3 — pi-llmctl-fast (cma_run_pi_provider)
# ===========================================================================
PI_HOME_D="$HOME/.pi-prov-$PROVIDER_ID"; mkdir -p "$PI_HOME_D"
jq -n --arg pid "$PROVIDER_ID" --arg mid "fast-model" --arg base "http://127.0.0.1:8080/v1" \
  '{providers: {($pid): {baseUrl: $base, api: "openai-completions", apiKey: "x", models: [{id: $mid, contextWindow: 8192}]}}}' \
  > "$PI_HOME_D/models.json"
mkdir -p "$HOME/.pi/bin"
sandbox_stub "$HOME/.pi/bin/pi" <<EOF
#!/usr/bin/env bash
touch "$REC_DIR/pi-launched"
exit 0
EOF

it "cma_run_pi_provider: llmctl-fast already active -> no switch call, pi launches"
reset_lc
printf '%s' "$PROFILE" > "$LC_DIR/active"
rm -f "$REC_DIR/pi-launched"
( set +eu; cma_run_pi_provider "$PROVIDER_ID" hi </dev/null >/dev/null 2>&1 ); rc=$?
assert_eq 0 "$rc" "pi already-active launch exits 0"
assert_eq 1 "$(lc_status_count)" "pi: status consulted exactly once"
assert_eq 0 "$(lc_switch_count)" "pi: no switch call when already active"
assert_file "$REC_DIR/pi-launched" "pi actually launched"

it "cma_run_pi_provider: a DIFFERENT profile active -> switch IS called before launch"
reset_lc
printf 'vision' > "$LC_DIR/active"
rm -f "$REC_DIR/pi-launched"
( set +eu; cma_run_pi_provider "$PROVIDER_ID" hi </dev/null >/dev/null 2>&1 ); rc=$?
assert_eq 0 "$rc" "pi switch-then-launch exits 0"
assert_eq 1 "$(lc_switch_count)" "pi: switch called exactly once"
assert_eq "switch $PROFILE" "$(lc_calls | grep '^switch ')" "pi: switch called with the correct profile"
assert_file "$REC_DIR/pi-launched" "pi launched after successful switch"

it "cma_run_pi_provider: llmctl switch FAILS -> launch aborts, pi never runs"
reset_lc
printf 'vision' > "$LC_DIR/active"
: > "$LC_DIR/fail_switch"; printf '7' > "$LC_DIR/fail_rc"
rm -f "$REC_DIR/pi-launched"
out="$( set +eu; cma_run_pi_provider "$PROVIDER_ID" hi </dev/null 2>&1 )"; rc=$?
assert_eq 7 "$rc" "pi: switch failure exit code propagated verbatim"
[[ ! -f "$REC_DIR/pi-launched" ]] && ok=0 || ok=1
assert_eq 0 "$ok" "pi was NEVER launched after a failed switch"
[[ "$out" == *"llmctl switch"* ]] && ok=0 || ok=1
assert_eq 0 "$ok" "pi: abort message names llmctl switch"

# ---------------------------------------------------------------------------
# Direct unit coverage of the shared helper (binary-not-found path — hard to
# reach through any single wrapper's other guards without duplicating all of
# them, so exercised directly here).
# ---------------------------------------------------------------------------
it "_cma_llmctl_ensure_active: llmctl binary unresolvable -> refuses, non-zero rc"
out="$( set +eu; CMA_LLMCTL_BIN="/no/such/llmctl-binary-xyz" _cma_llmctl_ensure_active "$PROVIDER_ID" 2>&1 )"; rc=$?
[[ "$rc" -ne 0 ]] && ok=0 || ok=1
assert_eq 0 "$ok" "unresolvable llmctl binary is a non-zero refusal"
[[ "$out" == *"llmctl"* ]] && ok=0 || ok=1
assert_eq 0 "$ok" "refusal message names llmctl"

it "_cma_llmctl_ensure_active: non-llmctl provider id is an immediate no-op"
reset_lc
_cma_llmctl_ensure_active "acme"; rc=$?
assert_eq 0 "$rc" "non-llmctl id returns 0"
assert_eq 0 "$(lc_status_count)" "non-llmctl id never calls llmctl status"
assert_eq 0 "$(lc_switch_count)" "non-llmctl id never calls llmctl switch"

# ---------------------------------------------------------------------------
# T016/T017 — llmctl's own disclosed degraded case (research.md §3.B,
# LLMCTL-F2): a switch failure's rollback is best-effort and can itself
# fail, leaving the host with fewer services than before. The ordinary
# failure path (rollback held) and the rollback-also-failed path must be
# distinguishable, and EITHER path must re-probe the previously-active
# profile's real liveness afterward rather than trusting the switch
# command's exit code alone to mean "previous state preserved."
# ---------------------------------------------------------------------------
it "_cma_llmctl_ensure_active: ordinary switch failure -> no ROLLBACK-ALSO-FAILED marker, previous profile confirmed still running"
reset_lc
printf 'vision' > "$LC_DIR/active"
: > "$LC_DIR/fail_switch"; printf '7' > "$LC_DIR/fail_rc"
out="$( set +eu; _cma_llmctl_ensure_active "$PROVIDER_ID" 2>&1 )"; rc=$?
assert_eq 7 "$rc" "ordinary switch failure exit code propagated verbatim"
[[ "$out" == *"ROLLBACK ALSO FAILED"* ]] && ok=1 || ok=0
assert_eq 0 "$ok" "ordinary failure must NOT raise the rollback-also-failed marker"
assert_eq 2 "$(lc_status_count)" "status re-probed after the failure (first check + post-failure re-probe)"
[[ "$out" == *"vision"*"still running"* ]] && ok=0 || ok=1
assert_eq 0 "$ok" "output confirms the previous profile (vision) is still running after the ordinary failure"

it "_cma_llmctl_ensure_active: rollback-also-failed -> distinct marker + honest 'no longer running' re-probe"
reset_lc
printf 'vision' > "$LC_DIR/active"
: > "$LC_DIR/fail_rollback"; printf '7' > "$LC_DIR/fail_rc"
out="$( set +eu; _cma_llmctl_ensure_active "$PROVIDER_ID" 2>&1 )"; rc=$?
assert_eq 7 "$rc" "rollback-also-failed exit code still propagated verbatim"
# NOT a check for llmctl's own raw "ROLLBACK ALSO FAILED" passthrough text --
# that string already appears today via the existing verbatim stderr
# passthrough even with ZERO new handling, so asserting on it alone would
# trivially pass before any fix and prove nothing. This asserts on a marker
# this feature's OWN code must add, distinct from llmctl's raw text, so a
# caller/log-scraper can tell "ordinary refusal" and "rollback also failed"
# apart programmatically without parsing llmctl's own wording.
[[ "$out" == *"CRITICAL: llmctl rollback also failed"* ]] && ok=0 || ok=1
assert_eq 0 "$ok" "a distinct CRITICAL marker (added by claude_toolkit, not llmctl's own text) is present"
assert_eq 2 "$(lc_status_count)" "status re-probed after the rollback-also-failed case too"
[[ "$out" == *"vision"*"NO LONGER running"* ]] && ok=0 || ok=1
assert_eq 0 "$ok" "output honestly reports the previous profile is no longer running either"

# ---------------------------------------------------------------------------
# Independent-review finding 4 (NO-GO blocker): the pre-fix re-probe tracked
# only the LAST status row and required rows2==1 for "survived", so a host
# with 2+ profiles running before a failed switch got a FALSE "no longer
# running either" claim even when BOTH profiles were still up. Reproduced
# here with a real multi-row `status` output (not a single-profile fixture)
# so this genuinely exercises the bug the single-profile cases above cannot.
# ---------------------------------------------------------------------------
it "_cma_llmctl_ensure_active: 2 profiles running before an ordinary switch failure -> both honestly reported still running (finding 4)"
reset_lc
printf 'small\nmedium\n' > "$LC_DIR/active"
: > "$LC_DIR/fail_switch"; printf '3' > "$LC_DIR/fail_rc"
out="$( set +eu; _cma_llmctl_ensure_active "$PROVIDER_ID" 2>&1 )"; rc=$?
assert_eq 3 "$rc" "exit code still propagated verbatim with 2 profiles running"
[[ "$out" == *"NO LONGER running"* ]] && ok=1 || ok=0
assert_eq 0 "$ok" "must NEVER claim a profile is no longer running when BOTH survived the failed switch"
[[ "$out" == *"small"* && "$out" == *"medium"* && "$out" == *"still running"* ]] && ok=1 || ok=0
assert_eq 1 "$ok" "output names both small and medium as still running"

it "_cma_llmctl_ensure_active: nothing running before a failed switch -> distinct honest message, never 'no longer running'"
reset_lc
: > "$LC_DIR/fail_switch"; printf '3' > "$LC_DIR/fail_rc"
out="$( set +eu; _cma_llmctl_ensure_active "$PROVIDER_ID" 2>&1 )"; rc=$?
assert_eq 3 "$rc" "exit code propagated when nothing was running beforehand"
[[ "$out" == *"NO LONGER running"* ]] && ok=1 || ok=0
assert_eq 0 "$ok" "must never claim something is 'no longer running' when nothing was running to begin with"
[[ "$out" == *"nothing was running"* ]] && ok=1 || ok=0
assert_eq 1 "$ok" "output states plainly that nothing was running before this switch attempt"

# ---------------------------------------------------------------------------
# Follow-up independent review (NO-GO blocker): the "both survived" and
# "nothing running" cases above never exercised the THIRD, genuinely
# distinct outcome -- some previously-running profiles survived, others did
# not. This is the one case the old rows2==1 check and a naive "all-or-
# nothing" fix could both still get wrong (e.g. a fix that only compares
# row COUNTS rather than actual names would see 2-before/1-after and could
# misreport WHICH one survived).
# ---------------------------------------------------------------------------
it "_cma_llmctl_ensure_active: 2 profiles before, only ONE survives an ordinary failure -> names the right one on each side (finding 4, partial case)"
reset_lc
printf 'alpha\nbeta\n' > "$LC_DIR/active"
: > "$LC_DIR/fail_switch"; printf '3' > "$LC_DIR/fail_rc"
printf 'beta' > "$LC_DIR/fail_switch_drop"
out="$( set +eu; _cma_llmctl_ensure_active "$PROVIDER_ID" 2>&1 )"; rc=$?
assert_eq 3 "$rc" "exit code still propagated verbatim in the partial-survival case"
[[ "$out" == *"still running: alpha"* ]] && ok=1 || ok=0
assert_eq 1 "$ok" "alpha (the survivor) is named in the 'still running' half of the message"
[[ "$out" == *"NO LONGER running: beta"* ]] && ok=1 || ok=0
assert_eq 1 "$ok" "beta (the one that actually died) is named in the 'NO LONGER running' half -- never the survivor"
[[ "$out" == *"still running: beta"* || "$out" == *"NO LONGER running: alpha"* ]] && ok=1 || ok=0
assert_eq 0 "$ok" "the two names are never swapped -- alpha must never be reported gone, beta must never be reported surviving"

# ---------------------------------------------------------------------------
# Follow-up independent review (NO-GO blocker, finding 4 root cause): the
# pre-fix code used `for _cma_lc_name in $_cma_lc_row` -- bash's own default
# word-splitting of an UNQUOTED expansion. zsh does not word-split unquoted
# expansions by default, and this function body is emitted verbatim into the
# shared alias file sourced into whichever shell the operator runs (zsh on
# macOS, zsh via .zshrc on Linux per CMA_RC_FILES). zsh itself is not
# installed on this host (CI-portable hermetic suite), so this test proves
# the INVARIANT that actually matters instead: the fixed code must not
# depend on the CALLER's ambient $IFS/word-splitting behavior at all. Setting
# IFS to empty here reproduces exactly the symptom a zsh run would show
# (bash's own `for x in $var` stops splitting too when IFS is empty) --
# correct output under this condition is strong evidence the fix no longer
# relies on bash-specific unquoted-expansion splitting anywhere in its path.
# ---------------------------------------------------------------------------
it "_cma_llmctl_ensure_active: partial-survival case is correct even with the caller's IFS broken (zsh word-splitting-safety proxy, finding 4)"
reset_lc
printf 'alpha\nbeta\n' > "$LC_DIR/active"
: > "$LC_DIR/fail_switch"; printf '3' > "$LC_DIR/fail_rc"
printf 'beta' > "$LC_DIR/fail_switch_drop"
out="$( set +eu; IFS=''; _cma_llmctl_ensure_active "$PROVIDER_ID" 2>&1 )"; rc=$?
assert_eq 3 "$rc" "exit code still correct with IFS broken by the caller"
[[ "$out" == *"still running: alpha"* && "$out" == *"NO LONGER running: beta"* ]] && ok=1 || ok=0
assert_eq 1 "$ok" "correct partial-survival attribution survives an empty/broken ambient IFS -- the fix does not depend on bash's own word-splitting of an unquoted expansion"

# ---------------------------------------------------------------------------
# T019 — FR-006 structural regression lock: llmctl profile START is
# reachable ONLY from the three launch wrappers, never from a plain
# sync/detect code path.
# ---------------------------------------------------------------------------
it "T019 STATIC: _cma_llmctl_ensure_active is called ONLY from the three launch wrappers in lib.sh"
_t019_callsites="$(grep -n '_cma_llmctl_ensure_active "' "$SCRIPTS_DIR/lib.sh" | grep -v '^[0-9]*:_cma_llmctl_ensure_active() {' | grep -v 'CMA_LLMCTL_ENSURE_ACTIVE_EOF')"
_t019_bad=0
while IFS= read -r _t019_line; do
  [[ -n "$_t019_line" ]] || continue
  _t019_ln="${_t019_line%%:*}"
  # Each call site must fall within one of the three wrapper function bodies.
  # Resolve the nearest preceding function-definition line and confirm it is
  # one of the three launch wrappers (cma_run_provider / cma_run_kimi_provider
  # / cma_run_pi_provider), not detect_llmctl_records or any sync/detect path.
  _t019_fn="$(awk -v ln="$_t019_ln" 'NR<=ln && /^(cma_run_provider|cma_run_kimi_provider|cma_run_pi_provider|_cma_emit_llmctl_ensure_active)\(\)/ {f=$0} END{print f}' "$SCRIPTS_DIR/lib.sh")"
  case "$_t019_fn" in
    cma_run_provider\(\)*|cma_run_kimi_provider\(\)*|cma_run_pi_provider\(\)*) : ;;
    *) _t019_bad=1 ;;
  esac
done <<<"$_t019_callsites"
assert_eq 0 "$_t019_bad" "every _cma_llmctl_ensure_active call site in lib.sh is inside one of the three launch wrappers"

it "T019 STATIC: detect_llmctl_records's OWN function body (claude-providers.sh) never calls _cma_llmctl_ensure_active, llmctl switch, or llmctl start"
# Scoped to the function body itself (detect_llmctl_records .. the next
# top-level function, resolve_records) -- NOT the whole file, which
# legitimately contains a SEPARATE, explicitly operator-invoked sweep
# command (cmd_sync_all_llmctl) that does call `llmctl switch` through
# every catalog profile one at a time; that is a different, intentional
# feature, not the implicit detection path FR-006 constrains. An
# unscoped whole-file grep is a carrier-match false positive here
# (confirmed live: it also matches this function's own header COMMENT
# naming _cma_llmctl_ensure_active, and cmd_sync_all_llmctl's real calls).
_t019_body="$(awk '/^detect_llmctl_records\(\) \{/,/^resolve_records\(\) \{/' "$SCRIPTS_DIR/claude-providers.sh")"
printf '%s' "$_t019_body" | grep -qE '_cma_llmctl_ensure_active|"\$_lc_bin"[[:space:]]+(switch|start)\b'
assert_eq 1 $? "detect_llmctl_records's own body never references _cma_llmctl_ensure_active or invokes llmctl switch/start -- only plan --json and per-profile probes"

it "T019 DYNAMIC: a plain detect_llmctl_records sync never records a switch/start call against the fake llmctl"
reset_lc
printf '%s' "$PROFILE" > "$LC_DIR/active"
CMA_LLMCTL_BIN="$LC_BIN" bash -c 'source "'"$SCRIPTS_DIR/claude-providers.sh"'" >/dev/null 2>&1; detect_llmctl_records' >/dev/null 2>&1
# The fake stub's unhandled-args branch (which `plan --json` hits -- it only
# implements status/switch) never appends to $DIR/calls at all, so a clean
# run leaves the file genuinely ABSENT, not merely empty; grep on a missing
# file exits 2 (error), not 1 (no match) -- treat absent-file the same as
# no-match rather than mis-reading grep's own error code as a real failure.
if [[ -f "$LC_DIR/calls" ]]; then
  grep -qE '^(switch|start) ' "$LC_DIR/calls"; _t019_dyn_rc=$?
else
  _t019_dyn_rc=1
fi
assert_eq 1 "$_t019_dyn_rc" "no switch/start line appears in the fake llmctl's call log after a plain detect_llmctl_records run"

summary
