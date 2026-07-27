#!/usr/bin/env bash
# claude-release-gate.sh — the MANDATORY pre-release gate: sandbox suite PLUS
# a LIVE, real-host, real-alias smoke. A release commit must not be made
# unless this gate exits 0.
#
# WHY THIS EXISTS (forensics, 2026-07-22): v1.25.1 shipped with the whole
# sandbox suite green while EVERY router alias on the real host was bricked.
# The sandbox proves wrapper LOGIC; it is structurally blind to real-host
# state. Each live layer below caught a real field defect the same day it
# was added:
#   - the npm @musistudio/claude-code-router doppelgänger shadowing the
#     bundled ccr on PATH (launch refused; a rebuild can never fix it);
#   - the HelixLLM container serving 8 x 3,072-token slots (HTTP 400);
#   - ~330k tokens of auto-resumed session history overflowing a local
#     model's window (HTTP 400 on every launch).
# None of those are reachable from a sandbox. The live smoke drives the REAL
# generated alias through the REAL PATH, ccr, route-apply, proxy, and
# provider backend, and asserts the served reply.
#
# Layers (fail-closed — any failure means DO NOT RELEASE):
#   1. sandbox suite  : scripts/tests/run-all.sh          (--skip-suite to
#                       reuse a suite run you JUST completed green)
#   2. live smoke     : regenerate aliases from the current lib.sh, then
#                       cma_run_provider <id> --session-id <fresh> -p
#                       "Reply with exactly: GATE-OK" and assert rc=0, the
#                       GATE-OK reply, and (router transport) that the ccr
#                       route sink-side names the provider.
#   3. providers scan : claude-verify-providers            (opt-in:
#                       --verify-providers; slower, exercises every model)
#
# Usage:
#   claude-release-gate.sh [--provider <id>] [--skip-suite] [--verify-providers]
#
# Provider selection: --provider, else $CMA_GATE_PROVIDER, else helixagent.
# The provider must exist and be verified; a missing/broken gate provider is
# a gate FAILURE (fix it or pick another with --provider), never a skip.
set -uo pipefail

_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _tgt="$(readlink "$_src")"
  case "$_tgt" in /*) _src="$_tgt" ;; *) _src="$(dirname "$_src")/$_tgt" ;; esac
done
SCRIPTS_DIR="$(cd "$(dirname "$_src")" && pwd)"
unset _src _tgt

PROVIDER="${CMA_GATE_PROVIDER:-helixagent}"
SKIP_SUITE=0
VERIFY_PROVIDERS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --provider) PROVIDER="${2:?--provider needs an id}"; shift 2 ;;
    --skip-suite) SKIP_SUITE=1; shift ;;
    --verify-providers) VERIFY_PROVIDERS=1; shift ;;
    *) printf 'claude-release-gate: unknown arg %s\n' "$1" >&2; exit 2 ;;
  esac
done

log()  { printf '[release-gate] %s\n' "$*" >&2; }
fail() { printf '[release-gate] FAIL: %s\n[release-gate] DO NOT RELEASE.\n' "$*" >&2; exit 1; }

# ── Layer 1: sandbox suite ──────────────────────────────────────────────────
if [ "$SKIP_SUITE" -eq 1 ]; then
  log "layer 1 (sandbox suite): SKIPPED on request — only valid if you JUST ran it green"
else
  log "layer 1: running the sandbox suite (scripts/tests/run-all.sh) …"
  bash "$SCRIPTS_DIR/tests/run-all.sh" || fail "sandbox suite is not green"
  log "layer 1: sandbox suite GREEN"
fi

# ── Layer 2: LIVE alias smoke ───────────────────────────────────────────────
ALIAS_FILE="$HOME/.local/share/claude-multi-account/aliases.sh"
PROV_ENV="$HOME/.local/share/claude-multi-account/providers/$PROVIDER.env"

[ -f "$PROV_ENV" ] || fail "gate provider '$PROVIDER' has no env file ($PROV_ENV) — pick one with --provider"

log "layer 2: regenerating aliases from the CURRENT lib.sh …"
"$HOME/.local/bin/claude-providers" --refresh-aliases >/dev/null 2>&1 \
  || fail "claude-providers --refresh-aliases failed"
[ -f "$ALIAS_FILE" ] || fail "alias file missing after refresh ($ALIAS_FILE)"

log "layer 2: LIVE smoke via provider '$PROVIDER' (fresh session, real chain) …"
_sid="$(command -v uuidgen >/dev/null 2>&1 && uuidgen || cat /proc/sys/kernel/random/uuid)"
_out="$(bash -c '
  set +eu
  source "$1"
  cma_run_provider "$2" --session-id "$3" -p "Reply with exactly: GATE-OK" 2>&1
' _ "$ALIAS_FILE" "$PROVIDER" "$_sid")"
_rc=$?
if [ "$_rc" -ne 0 ]; then
  printf '%s\n' "$_out" | tail -6 >&2
  fail "live alias launch exited $_rc — the real chain is broken"
fi
case "$_out" in
  *GATE-OK*) ;;
  *) printf '%s\n' "$_out" | tail -6 >&2
     fail "live reply did not contain GATE-OK — served model/route is wrong" ;;
esac

# Sink-side route proof for router-transport providers: the gateway config
# must name the provider as its active route (the write-then-apply seam that
# broke in the field). The launcher isolates every router alias in its OWN
# CCR_HOME — ~/.claude-code-router/<provider-id>/config.json (lib.sh
# cma_run_provider router branch, since 5f9d82f) — so the read must name the
# per-alias dir, not the stale global one.
if grep -q "CMA_PROVIDER_TRANSPORT='router'" "$PROV_ENV" 2>/dev/null; then
  _route="$(jq -r '.Router.default // empty' "$HOME/.claude-code-router/$PROVIDER/config.json" 2>/dev/null)"
  case "$_route" in
    "$PROVIDER,"*) log "layer 2: sink-side route confirmed (Router.default=$_route)" ;;
    *) fail "sink-side route mismatch: Router.default='$_route', expected '$PROVIDER,…'" ;;
  esac
fi
log "layer 2: LIVE smoke GREEN (GATE-OK served end-to-end)"

# ── Layer 3 (opt-in): full provider/model verification ──────────────────────
if [ "$VERIFY_PROVIDERS" -eq 1 ]; then
  log "layer 3: claude-verify-providers (LLMsVerifier) …"
  "$HOME/.local/bin/claude-verify-providers" || fail "provider verification not green"
  log "layer 3: provider verification GREEN"
else
  log "layer 3 (verify-providers): skipped (opt-in via --verify-providers)"
fi

log "ALL LAYERS GREEN — release may proceed."
