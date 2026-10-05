#!/usr/bin/env bash
# test_release_gate.sh — hermetic coverage for claude-release-gate.sh's layer-2
# SINK-SIDE ROUTE PROOF: after the live smoke, a router-transport provider must
# have its ccr route read from the PER-ALIAS CCR_HOME
# (~/.claude-code-router/<provider-id>/config.json), which is where lib.sh's
# cma_run_provider has written it since 5f9d82f (2026-07-24). The gate's read
# predated that change and pointed at the GLOBAL ~/.claude-code-router/
# config.json — the same drift class as verify_superpowers_tui.sh — so on a
# real host it would compare against a stale global route and fail (or worse,
# pass) against a file nothing writes any more.
#
# Hermetic: --skip-suite (never runs run-all.sh / takes the suite lock), a
# stub claude-providers, and a fake cma_run_provider that prints GATE-OK and
# writes $FAKE_ROUTE into the provider's per-alias config — exactly what the
# real launcher does. A STALE GLOBAL config naming a different provider is
# planted once and never touched: a gate reading the global dir (pre-fix
# behaviour) fails case (a), the fixed gate passes it.
#
# Cases:
#   (a) router, per-alias route correct, global STALE -> GREEN (per-alias wins)
#   (b) router, per-alias route FOREIGN -> FAIL "sink-side route mismatch"
#   (c) native transport -> no route read at all, GREEN
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
set +e

# Script under test. The override lets the suite re-run case (a) against the
# PRE-FIX gate to prove the assertions have teeth (same pattern as
# CMA_STUI_BIN in test_layer4_route_attribution.sh).
GATE="${CMA_GATE_BIN:-$SCRIPTS_DIR/claude-release-gate.sh}"

PDIR="$HOME/.local/share/claude-multi-account/providers"
ALIAS_FILE="$HOME/.local/share/claude-multi-account/aliases.sh"
mkdir -p "$PDIR" "$(dirname "$ALIAS_FILE")"

# --- fixtures ----------------------------------------------------------------
# Provider env files. Only the transport line matters to the gate's branch.
printf 'CMA_PROVIDER_ID=%s\nCMA_PROVIDER_TRANSPORT=%s\n' "'gateprov'" "'router'" > "$PDIR/gateprov.env"
printf 'CMA_PROVIDER_ID=%s\nCMA_PROVIDER_TRANSPORT=%s\n' "'gatenative'" "'native'" > "$PDIR/gatenative.env"

# Fake cma_run_provider: mirrors the real launcher's per-alias CCR_HOME write
# (lib.sh router branch), then answers the smoke prompt. $FAKE_ROUTE controls
# the route it "applies"; empty means it writes nothing (native path shape).
cat > "$ALIAS_FILE" <<'EOF'
cma_run_provider() {
  local id="$1"
  if [[ -n "${FAKE_ROUTE:-}" ]]; then
    local d="$HOME/.claude-code-router/$id"
    mkdir -p "$d"
    printf '{"Providers":[],"Router":{"default":"%s","background":"%s"}}\n' \
      "$FAKE_ROUTE" "$FAKE_ROUTE" > "$d/config.json"
  fi
  echo "GATE-OK"
}
EOF

# The gate refreshes aliases via the INSTALLED claude-providers; stub it.
# sandbox_stub, not a bare redirect: in a real $HOME this name is a symlink
# into the repo and `>` would write THROUGH it into production.
# It also answers `quota --json` (layer 2.6) from $FAKE_QUOTA_JSON on stdout,
# optional $FAKE_QUOTA_STDERR noise on stderr, and exit $FAKE_QUOTA_RC — so
# the quota leg is driven from fixtures and never probes a real endpoint.
sandbox_stub "$HOME/.local/bin/claude-providers" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "quota" ]; then
  [ -n "${FAKE_QUOTA_STDERR:-}" ] && printf '%s\n' "$FAKE_QUOTA_STDERR" >&2
  printf '%s\n' "${FAKE_QUOTA_JSON:-}"
  exit "${FAKE_QUOTA_RC:-0}"
fi
exit 0
STUB

# Quota fixtures (contract shape: quota-limits-cli-contract.md).
_qrow() { # KIND NAME ABSENCE  (ABSENCE "" -> null with one window)
  if [ -z "$3" ]; then
    printf '{"kind":"%s","display_name":"%s","absence_reason":null,"windows":[{"window":"subscription","amount_remaining":5}]}' "$1" "$2"
  else
    printf '{"kind":"%s","display_name":"%s","absence_reason":"%s","windows":[]}' "$1" "$2" "$3"
  fi
}
_qdoc() { printf '{"generated_at":"2026-10-05T00:00:00Z","scoped_to":null,"unknown_alias":false,"rows":[%s]}' "$1"; }
Q_HEALTHY="$(_qdoc "$(_qrow provider_account gateprov '')","$(_qrow provider_account gatenative probe_failed)","$(_qrow native_account claude1 not_reported_by_provider)")"
Q_ALL_FAILED="$(_qdoc "$(_qrow provider_account gateprov probe_failed)","$(_qrow provider_account gatenative probe_failed)","$(_qrow native_account claude1 not_reported_by_provider)")"
Q_NO_ROWS="$(_qdoc '')"
Q_NATIVE_ONLY="$(_qdoc "$(_qrow native_account claude1 not_reported_by_provider)")"
export FAKE_QUOTA_JSON="$Q_HEALTHY"

# The stale GLOBAL config (pre-isolation layout). Never rewritten by any case:
# the decoy a pre-fix gate would read instead of the per-alias one.
mkdir -p "$HOME/.claude-code-router"
printf '{"Providers":[],"Router":{"default":"deepseek,deepseek-v4-pro","background":"deepseek,deepseek-v4-pro"}}\n' \
  > "$HOME/.claude-code-router/config.json"

# run_gate PROVIDER [FAKE_ROUTE] -> sets $GATE_OUT, $GATE_RC in the caller.
GATE_OUT=""; GATE_RC=0
run_gate() {
  # $HOME/.local/bin first on PATH: the stubbed claude-providers must win over
  # any real one on the host PATH (a real one would probe real endpoints).
  GATE_OUT="$( PATH="$HOME/.local/bin:$PATH" FAKE_ROUTE="${2:-}" bash "$GATE" --skip-suite --provider "$1" 2>&1 )"
  GATE_RC=$?
}

# ===========================================================================
# (a) router, per-alias route correct, global stale -> GREEN
# ===========================================================================
it "router provider: sink-side route read from the PER-ALIAS config (global decoy ignored)"
run_gate gateprov 'gateprov,gate-model'
assert_eq 0 "$GATE_RC" "gate GREEN when the per-alias route names the provider"
grep -q 'sink-side route confirmed' <<<"$GATE_OUT"; assert_eq 0 $? "the confirmation line names the sink-side proof"
grep -q 'ALL LAYERS GREEN' <<<"$GATE_OUT"; assert_eq 0 $? "gate reaches the release verdict"
# Teeth: the decoy is still there, so a gate reading the GLOBAL config (the
# pre-fix behaviour) would have failed this run with a route mismatch.
assert_file_contains "$HOME/.claude-code-router/config.json" 'deepseek,deepseek-v4-pro' "the stale GLOBAL config still names another provider — it was NOT what got read"
assert_file_contains "$HOME/.claude-code-router/gateprov/config.json" '"default":"gateprov,gate-model"' "the PER-ALIAS config is what the launcher wrote"

# ===========================================================================
# (b) router, per-alias route foreign -> FAIL (the gate still has teeth)
# ===========================================================================
it "router provider: a foreign per-alias route still FAILS the gate"
run_gate gateprov 'otherprov,other-model'
assert_eq 1 "$GATE_RC" "gate FAILS when the per-alias route names a different provider"
grep -q 'sink-side route mismatch' <<<"$GATE_OUT"; assert_eq 0 $? "the failure names the sink-side mismatch"
grep -q 'DO NOT RELEASE' <<<"$GATE_OUT"; assert_eq 0 $? "the failure is fail-closed"

# ===========================================================================
# (c) native transport -> the route branch is not taken at all
# ===========================================================================
it "native provider: no ccr route exists and none is demanded"
run_gate gatenative ''
assert_eq 0 "$GATE_RC" "gate GREEN for a native provider with no ccr config at all"
grep -q 'sink-side route' <<<"$GATE_OUT"; assert_eq 1 $? "no route read is even attempted for native transport"

# ===========================================================================
# (d) layer 2.6: every provider probe FAILED -> the gate must FAIL.
#     F5-gate-shallow: the leg used to check only rc + valid JSON + top-level
#     keys, so a fleet where no probe succeeded was reported GREEN.
# ===========================================================================
it "quota leg: a fleet where EVERY provider probe failed FAILS the gate"
FAKE_QUOTA_JSON="$Q_ALL_FAILED" run_gate gatenative ''
assert_eq 1 "$GATE_RC" "gate FAILS when every provider_account row is probe_failed"
grep -q 'every provider quota probe failed' <<<"$GATE_OUT"; assert_eq 0 $? "the failure names the all-probes-failed condition"
grep -q 'ALL LAYERS GREEN' <<<"$GATE_OUT"; assert_eq 1 $? "no release verdict is printed"

it "quota leg: zero rows (nothing exercised) FAILS the gate"
FAKE_QUOTA_JSON="$Q_NO_ROWS" run_gate gatenative ''
assert_eq 1 "$GATE_RC" "gate FAILS on an empty rows array"
grep -q 'no provider_account rows' <<<"$GATE_OUT"; assert_eq 0 $? "the failure names the missing provider rows"

it "quota leg: native rows only (no provider exercised) FAILS the gate"
FAKE_QUOTA_JSON="$Q_NATIVE_ONLY" run_gate gatenative ''
assert_eq 1 "$GATE_RC" "gate FAILS when no provider_account row exists"

it "quota leg: a non-zero quota exit still FAILS the gate"
FAKE_QUOTA_RC=3 run_gate gatenative ''
assert_eq 1 "$GATE_RC" "gate FAILS when quota --json exits non-zero"
grep -q 'exited 3' <<<"$GATE_OUT"; assert_eq 0 $? "the failure names the exit code"

# ===========================================================================
# (e) layer 2.6: stderr noise must not be parsed as part of the JSON.
# ===========================================================================
it "quota leg: stderr diagnostics do not corrupt the JSON the gate validates"
FAKE_QUOTA_STDERR="warning: cache refresh slow" run_gate gatenative ''
assert_eq 0 "$GATE_RC" "gate GREEN: valid stdout JSON + stderr noise"
grep -q 'quota/limits LIVE leg GREEN' <<<"$GATE_OUT"; assert_eq 0 $? "the quota leg reports GREEN"

# ===========================================================================
# (f) run-proof.sh quota leg — the SAME source text, executed against stubs.
#     Extracted between its own banner and the next leg's banner, so the test
#     runs exactly what run-proof.sh runs.
# ===========================================================================
PROOF_SH="${CMA_RUN_PROOF_BIN:-$TESTS_DIR/run-proof.sh}"
QUOTA_BLOCK="$(awk '/^echo "==> live quota\/limits verification/{on=1} /^echo "==> constitution/{on=0} on' "$PROOF_SH")"
STUB_SCRIPTS="$HOME/stub-scripts"; mkdir -p "$STUB_SCRIPTS" "$HOME/proof-out"
cp "$HOME/.local/bin/claude-providers" "$STUB_SCRIPTS/claude-providers.sh"
ln -sf "$GATE" "$STUB_SCRIPTS/claude-release-gate.sh"
PROOF_OUT=""; PROOF_RC=""
run_proof_quota() {
  PROOF_OUT="$( SCRIPTS_DIR="$STUB_SCRIPTS" PDIR_LIVE="$PDIR" PROOF_DIR="$HOME/proof-out" \
    bash -c 'set -uo pipefail; eval "$1"; printf "QUOTA_RC=%s\n" "$quota_rc"' _ "$QUOTA_BLOCK" 2>&1 )"
  PROOF_RC="$(sed -nE 's/^QUOTA_RC=([0-9]+)$/\1/p' <<<"$PROOF_OUT")"
}

it "run-proof quota leg: block extracted from run-proof.sh"
[ -n "$QUOTA_BLOCK" ]; assert_eq 0 $? "the quota leg source text was found"

it "run-proof quota leg: a fleet where EVERY provider probe failed is a FAIL"
FAKE_QUOTA_JSON="$Q_ALL_FAILED" run_proof_quota
assert_eq 1 "$PROOF_RC" "quota_rc=1 when every provider_account row is probe_failed"
grep -q '^FAIL:' "$HOME/proof-out/47-quota-live.log"; assert_eq 0 $? "the proof log records a FAIL line"

it "run-proof quota leg: healthy JSON with stderr noise is a PASS"
FAKE_QUOTA_STDERR="warning: cache refresh slow" run_proof_quota
assert_eq 0 "$PROOF_RC" "quota_rc=0 for valid stdout JSON with a succeeding probe"
grep -q '^PASS:' "$HOME/proof-out/47-quota-live.log"; assert_eq 0 $? "the proof log records a PASS line"

it "run-proof quota leg: zero provider rows is a FAIL"
FAKE_QUOTA_JSON="$Q_NO_ROWS" run_proof_quota
assert_eq 1 "$PROOF_RC" "quota_rc=1 when nothing was probed"

summary
