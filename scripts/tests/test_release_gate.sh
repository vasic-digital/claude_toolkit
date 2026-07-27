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
sandbox_stub "$HOME/.local/bin/claude-providers" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

# The stale GLOBAL config (pre-isolation layout). Never rewritten by any case:
# the decoy a pre-fix gate would read instead of the per-alias one.
mkdir -p "$HOME/.claude-code-router"
printf '{"Providers":[],"Router":{"default":"deepseek,deepseek-v4-pro","background":"deepseek,deepseek-v4-pro"}}\n' \
  > "$HOME/.claude-code-router/config.json"

# run_gate PROVIDER [FAKE_ROUTE] -> sets $GATE_OUT, $GATE_RC in the caller.
GATE_OUT=""; GATE_RC=0
run_gate() {
  GATE_OUT="$( FAKE_ROUTE="${2:-}" bash "$GATE" --skip-suite --provider "$1" 2>&1 )"
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

summary
