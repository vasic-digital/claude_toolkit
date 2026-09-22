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
      printf '%-16s %-6s %-8s %-10s %-10s %-8s %s\n' "$active" "8080" "cpu" "100" "0" "no" "running"
    fi
    ;;
  switch)
    profile="${2:-}"
    printf 'switch %s\n' "$profile" >> "$DIR/calls"
    if [[ -f "$DIR/fail_switch" ]]; then
      echo "switch to '$profile' failed - restoring the previously-running set: (simulated)" >&2
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
  rm -f "$LC_DIR/calls" "$LC_DIR/active" "$LC_DIR/fail_switch" "$LC_DIR/fail_rc"
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

summary
