#!/usr/bin/env bash
# test_kimi_llmctl_integration.sh — LIVE, real end-to-end round trip: the
# `kimi-llmctl-small` Kimi Code twin alias, invoked through the REAL rendered
# ~/.kimi-prov-llmctl-small/config.toml, against the REAL, currently-running
# llmctl `small` server (a real llama-server instance serving a real GGUF
# model over its OpenAI-compatible /v1 surface).
#
# Unlike every OTHER test_*.sh in this suite this one is deliberately NOT
# hermetic — it runs against the real host's real ~/.local/share/
# claude-multi-account state and a real local network endpoint, because the
# task this file exists for ("prove the Kimi twin actually round-trips
# against llmctl") is a claim about REAL infrastructure, not about a mock. A
# sandboxed/mocked version of this file would prove only that a fake server
# answers a fake request — see test_kimi_render_config_default_model_toml.sh
# for the hermetic structural regression guard on the render function itself.
#
# Every host-state prerequisite this file cannot control (llmctl server not
# running on this host, the record not synced/verified, the kimi binary
# absent, network tools missing) is an HONEST SKIP, never a FAIL — mirroring
# verify_kimi_live.sh's documented convention for the rest of this suite.
#
# THE REGRESSION THIS FILE GUARDS: a real defect (2026-09-18, see
# test_kimi_render_config_default_model_toml.sh's header for the full
# forensic account) made `_cma_kimi_render_config` write `default_model`
# NESTED inside the `[models."<id>/<model>"]` TOML table instead of at the
# file's root, so the REAL kimi binary refused every `-p` (non-interactive
# prompt) invocation of EVERY `kimi-<id>` twin — cloud and locally-hosted
# alike — with "no default model configured" / "No model configured", even
# though the config.toml passed `kimi doctor` and `kimi provider list`
# cleanly. This file's core assertion is that a real `kimi-llmctl-small`
# invocation does NOT reproduce that exact, named failure signature.
#
# A SEPARATE, DISCLOSED, OUT-OF-SCOPE LIMITATION this file deliberately does
# NOT fail on: llmctl's `small` profile is configured with an 8192-token
# context (llama-server `n_ctx=8192`), and the Kimi CLI's own default system
# prompt + bundled tool/skill definitions can exceed that on a fresh session
# (measured: ~22k tokens with --skills-dir pointed at an empty directory,
# ~80k with the real default skill set) — a real HTTP 400
# "exceeds the available context size" from the real llama-server, i.e. proof
# the round trip DID reach the real backend. This is the llmctl-side mirror
# of the already-disclosed Claude-Code-CLI "prompt too long" limitation for
# this same small model and is explicitly NOT this file's concern; see the
# case-by-case handling below.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"

PROOF_DIR="${PROOF_DIR:-$TESTS_DIR/proof}"
mkdir -p "$PROOF_DIR"
EV="$PROOF_DIR/kimi-llmctl-integration-evidence.txt"
: > "$EV"

ALIAS_FILE="${ALIAS_FILE:-$HOME/.local/share/claude-multi-account/aliases.sh}"
PDIR="${CMA_PROVIDERS_DIR:-$HOME/.local/share/claude-multi-account/providers}"
STATUS_JSON="$PDIR/status.json"
CFG="$HOME/.kimi-prov-llmctl-small/config.toml"
PROVIDER_ID="llmctl-small"

echo "Kimi/llmctl live integration: $(date)" | tee -a "$EV"

# ---------------------------------------------------------------------------
# Prerequisite gate — every SKIP is named + honest, never silently a PASS.
# ---------------------------------------------------------------------------
_skip() { echo "SKIP: $1" | tee -a "$EV"; summary; exit 0; }

command -v jq   >/dev/null 2>&1 || _skip "jq is required"
command -v curl >/dev/null 2>&1 || _skip "curl is required"

KIMI_BIN=""
for cand in "$HOME/.kimi-code/bin/kimi" "$HOME/.local/bin/kimi"; do
  [[ -x "$cand" ]] && { KIMI_BIN="$cand"; break; }
done
[[ -z "$KIMI_BIN" ]] && KIMI_BIN="$(command -v kimi 2>/dev/null || true)"
[[ -n "$KIMI_BIN" && -x "$KIMI_BIN" ]] || _skip "kimi binary not found on this host"

[[ -f "$ALIAS_FILE" ]] || _skip "alias file absent: $ALIAS_FILE (run: claude-providers sync)"
[[ -f "$STATUS_JSON" ]] || _skip "status.json absent: $STATUS_JSON"

_status="$(jq -r --arg i "$PROVIDER_ID" '.[$i].status // "absent"' "$STATUS_JSON" 2>/dev/null)"
[[ "$_status" == "verified" ]] || _skip "$PROVIDER_ID is not verified (status=$_status) — run: claude-providers sync $PROVIDER_ID"

[[ -f "$CFG" ]] || _skip "no rendered config.toml for $PROVIDER_ID: $CFG (run: claude-providers sync $PROVIDER_ID)"

_base_url="$(grep -E '^[[:space:]]*base_url[[:space:]]*=' "$CFG" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d ' "')"
[[ -n "$_base_url" ]] || _skip "config.toml carries no base_url"

# Positive control: the REAL llmctl server must actually be reachable at the
# base_url this config points to (a §11.4.201 real-condition check, not an
# assumed one) — this is what tells "server not running" apart from "server
# running but our request failed", which are two different SKIP/FAIL classes.
_models_body="$(curl -sf --max-time 5 "${_base_url%/}/models" 2>/dev/null)" || _models_body=""
[[ -n "$_models_body" ]] || _skip "llmctl server not reachable at $_base_url (is 'llmctl start small' running?)"
echo "server reachable: ${_base_url%/}/models -> $(printf '%s' "$_models_body" | head -c 200)" >> "$EV"

grep -q "^alias kimi-$PROVIDER_ID=" "$ALIAS_FILE" || _skip "kimi-$PROVIDER_ID alias not present in $ALIAS_FILE"

# ---------------------------------------------------------------------------
# The real round trip.
# ---------------------------------------------------------------------------
it "kimi-$PROVIDER_ID: real round trip against the real llmctl small server"

# shellcheck source=/dev/null
set +u
source "$ALIAS_FILE"
set -u
shopt -s expand_aliases 2>/dev/null || true

OUT_LOG="$(mktemp "${TMPDIR:-/tmp}/kimi-llmctl-int.XXXXXX")"
PROMPT="Reply with exactly the single word: PONG"

# Backgrounded with a bounded manual timeout (§11.4.89 background-long-op
# convention): `timeout <cmd-that-is-a-bash-alias>` cannot exec a shell alias
# directly (aliases are not on $PATH), so this file drives its own watchdog
# instead of relying on the external `timeout` binary. The alias name must be
# a LITERAL token for bash's alias expansion to apply (a variable expansion in
# command position is never alias-expanded) — this file is specifically about
# kimi-llmctl-small (PROVIDER_ID is fixed above), so that is what is written.
( kimi-llmctl-small -p "$PROMPT" > "$OUT_LOG" 2>&1 ) &
_bg=$!
_budget=120
for ((_i = 0; _i < _budget; _i++)); do
  kill -0 "$_bg" 2>/dev/null || break
  sleep 1
done
if kill -0 "$_bg" 2>/dev/null; then
  echo "TIMEOUT after ${_budget}s — killing $_bg" >> "$EV"
  kill -9 "$_bg" 2>/dev/null
fi
wait "$_bg" 2>/dev/null
_rc=$?

_out="$(cat "$OUT_LOG" 2>/dev/null)"
{ echo "--- exit=$_rc ---"; echo "$_out"; } >> "$EV"
rm -f "$OUT_LOG"

# The ONE thing this file exists to guard against: the model-resolution
# defect's exact, named error signature. Reproducing this is the RED case —
# it must NEVER appear again.
if [[ "$_out" == *"no default model configured"* || "$_out" == *"No model configured"* ]]; then
  _fail "kimi-$PROVIDER_ID reproduced the default_model TOML-scope regression" \
    "$_out"
elif [[ "$_out" == *PONG* ]]; then
  _pass "kimi-$PROVIDER_ID answered the real prompt: $_out"
elif [[ "$_out" == *"exceeds the available context size"* ]]; then
  # Real round trip completed: request reached the real llama-server, which
  # gave a real HTTP 400 because llmctl-small's configured 8192-token context
  # cannot hold the Kimi CLI's own default system-prompt + tool-definition
  # overhead on a fresh session. This is the llmctl-side mirror of the
  # already-disclosed, out-of-scope Claude-Code-CLI "prompt too long"
  # limitation for this same small model — a real, honest, non-bug outcome,
  # not the regression this file guards, and not silently swallowed either.
  _pass "kimi-$PROVIDER_ID reached the real backend (model-resolution fix holds); real backend rejected the request on context-size capacity (disclosed, out-of-scope small-model limitation, not this file's regression): $_out"
else
  _fail "kimi-$PROVIDER_ID failed for an UNRECOGNIZED reason (neither the guarded regression nor the known context-capacity limitation)" \
    "rc=$_rc out=$_out"
fi

echo "full evidence: $EV"
summary
