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
#   2.5 kimi smoke    : cma_run_kimi_provider <id> -p "Reply with exactly:
#                       GATE-OK" through the REAL rendered ~/.kimi-prov-<id>/
#                       config.toml (--kimi-gate-provider, default
#                       kimi-deepseek). UNLIKE layer 2 this layer is honest-SKIP:
#                       a host that has not materialized the kimi aliases
#                       (no sync, not signed in, key absent, quota'd) records
#                       a SKIP, never a release FAIL — the kimi capability is
#                       validated to the extent the host can support it.
#   2.6 quota live    : claude-providers quota --json against this host's
#                       REAL installed state, asserting rc=0, valid JSON on
#                       STDOUT (stderr is kept apart, never parsed), the
#                       correct top-level shape, at least one provider_account
#                       row, and that NOT every provider probe failed — a
#                       fleet where no probe succeeded is a FAIL, not a pass
#                       (known-issues F5-gate-shallow). MANDATORY (fail-closed,
#                       not opt-in) — claude-providers is always present on
#                       any host able to run this gate at all.
#   3. providers scan : claude-verify-providers            (opt-in:
#                       --verify-providers; slower, exercises every model)
#
# Usage:
#   claude-release-gate.sh [--provider <id>] [--kimi-gate-provider <id|off>] \
#                          [--skip-suite] [--verify-providers]
#   claude-release-gate.sh --check-quota-json <file>
#       Run ONLY the layer-2.6 content check on a saved `quota --json` stdout
#       document and exit 0/1 (shared with scripts/tests/run-proof.sh so the
#       two gates cannot drift apart).
#
# Provider selection: --provider, else $CMA_GATE_PROVIDER, else helixagent.
# The provider must exist and be verified; a missing/broken gate provider is
# a gate FAILURE (fix it or pick another with --provider), never a skip.
# Kimi selection: --kimi-gate-provider, else kimi-deepseek, else off.
set -uo pipefail

_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _tgt="$(readlink "$_src")"
  case "$_tgt" in /*) _src="$_tgt" ;; *) _src="$(dirname "$_src")/$_tgt" ;; esac
done
SCRIPTS_DIR="$(cd "$(dirname "$_src")" && pwd)"
unset _src _tgt

PROVIDER="${CMA_GATE_PROVIDER:-helixagent}"
KIMI_GATE="${CMA_KIMI_GATE_PROVIDER:-kimi-deepseek}"
SKIP_SUITE=0
VERIFY_PROVIDERS=0
CHECK_QUOTA_JSON=""
usage() {
  sed -n '2,/^set -uo pipefail$/p' "${BASH_SOURCE[0]}" | sed -E 's/^# ?//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --provider) PROVIDER="${2:?--provider needs an id}"; shift 2 ;;
    --kimi-gate-provider) KIMI_GATE="${2:-kimi-deepseek}"; shift 2 ;;
    --skip-suite) SKIP_SUITE=1; shift ;;
    --verify-providers) VERIFY_PROVIDERS=1; shift ;;
    --check-quota-json) CHECK_QUOTA_JSON="${2:?--check-quota-json needs a file}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'claude-release-gate: unknown arg %s\n' "$1" >&2; exit 2 ;;
  esac
done

log()  { printf '[release-gate] %s\n' "$*" >&2; }
fail() { printf '[release-gate] FAIL: %s\n[release-gate] DO NOT RELEASE.\n' "$*" >&2; exit 1; }

# cma_gate_quota_check FILE — the layer-2.6 content check on a `quota --json`
# STDOUT document. Prints the reason and returns 1 on any failure. Exit code +
# valid JSON + top-level keys alone are NOT the real condition: a fleet where
# every probe fails still produces all three (each failed probe degrades to a
# row with absence_reason "probe_failed"), so the leg must also prove that at
# least one provider_account row exists and that not every one of them failed.
# native_account rows never probe anything ("not_reported_by_provider" by
# construction), so they cannot satisfy the leg on their own.
cma_gate_quota_check() {
  local f="$1" keys n_prov n_failed
  if ! jq -e . "$f" >/dev/null 2>&1; then
    echo "claude-providers quota --json did not produce valid JSON on stdout"; return 1
  fi
  keys="$(jq -Sc 'keys' "$f" 2>/dev/null)"
  if [ "$keys" != '["generated_at","rows","scoped_to","unknown_alias"]' ]; then
    echo "claude-providers quota --json top-level shape mismatch: got keys $keys"; return 1
  fi
  if ! jq -e '.rows | type == "array"' "$f" >/dev/null 2>&1; then
    echo "claude-providers quota --json: .rows is not an array"; return 1
  fi
  n_prov="$(jq '[.rows[] | select(.kind == "provider_account")] | length' "$f")"
  n_failed="$(jq '[.rows[] | select(.kind == "provider_account" and .absence_reason == "probe_failed")] | length' "$f")"
  if [ "$n_prov" -eq 0 ]; then
    echo "claude-providers quota --json has no provider_account rows — no provider was probed at all"; return 1
  fi
  if [ "$n_failed" -eq "$n_prov" ]; then
    echo "every provider quota probe failed ($n_failed/$n_prov provider_account rows are probe_failed) — the quota path is not working"; return 1
  fi
  echo "valid JSON, correct top-level shape, $((n_prov - n_failed))/$n_prov provider probes answered"
  return 0
}

if [ -n "$CHECK_QUOTA_JSON" ]; then
  [ -f "$CHECK_QUOTA_JSON" ] || { echo "no such file: $CHECK_QUOTA_JSON"; exit 1; }
  cma_gate_quota_check "$CHECK_QUOTA_JSON"
  exit $?
fi

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

# ── Layer 2.5: Kimi smoke — honest-SKIP (v1.27.0) ───────────────────────────
# Unlike layer 2 (mandatory, fail-closed), the kimi layer may SKIP: the kimi
# aliases are MATERIALIZED by a v1.27.0+ `claude-providers sync`, so a host
# that has not synced (or has no key / is quota'd) cannot exercise the real
# chain. Recording that honestly beats a fake pass — and must never block a
# release of the toolkit itself.
KIMI_OUTCOME="unexercised"
if [ -z "$KIMI_GATE" ] || [ "$KIMI_GATE" = "off" ]; then
  log "layer 2.5 (kimi smoke): DISABLED (--kimi-gate-provider off)"
  KIMI_OUTCOME="disabled"
else
  if [[ "$KIMI_GATE" == kimi-* ]] && [ -n "${KIMI_GATE#kimi-}" ]; then
    KIMI_ID="${KIMI_GATE#kimi-}"
  else
    fail "kimi gate provider '$KIMI_GATE' is not a kimi-<id> alias (kc-* names ride line via --provider)"
  fi
  KIMI_PDIR="$HOME/.local/share/claude-multi-account/providers"
  KIMI_CONFIG="$HOME/.kimi-prov-$KIMI_ID/config.toml"
  KIMI_BIN=""
  for _c in "$HOME/.kimi-code/bin/kimi" "$HOME/.local/bin/kimi"; do
    [ -x "$_c" ] && { KIMI_BIN="$_c"; break; }
  done
  if [ -z "$KIMI_BIN" ] && command -v kimi >/dev/null 2>&1; then KIMI_BIN="$(command -v kimi)"; fi
  if [ -z "$KIMI_BIN" ]; then
    log "layer 2.5 (kimi <$KIMI_GATE>): SKIP — kimi binary absent on this host"
    KIMI_OUTCOME="SKIP (no kimi binary)"
  elif ! compgen -G "$HOME/.kimi-code/credentials/*.json" >/dev/null 2>&1; then
    log "layer 2.5 (kimi <$KIMI_GATE>): SKIP — kimi not signed in (no OAuth credentials slot in ~/.kimi-code/credentials)"
    KIMI_OUTCOME="SKIP (not signed in)"
  elif ! grep -qE "^alias $KIMI_GATE=\"cma_run_kimi_provider $KIMI_ID\"$" "$ALIAS_FILE" 2>/dev/null; then
    log "layer 2.5 (kimi <$KIMI_GATE>): SKIP — '$KIMI_GATE' not materialized in the alias file (run 'claude-providers sync' after install)"
    KIMI_OUTCOME="SKIP (kimi alias not materialized)"
  elif [ ! -f "$KIMI_CONFIG" ]; then
    log "layer 2.5 (kimi <$KIMI_GATE>): SKIP — $KIMI_CONFIG not rendered (run 'claude-providers sync')"
    KIMI_OUTCOME="SKIP (config.toml not rendered)"
  else
    KIMI_ST="$(jq -r --arg x "$KIMI_ID" '.[$x].status // "pending"' "$KIMI_PDIR/status.json" 2>/dev/null)"
    KIMI_EF="$KIMI_PDIR/$KIMI_ID.env"
    if [ "$KIMI_ST" != "verified" ]; then
      log "layer 2.5 (kimi <$KIMI_GATE>): SKIP — $KIMI_ID status=$KIMI_ST (verification gate would refuse without --force)"
      KIMI_OUTCOME="SKIP (status=$KIMI_ST)"
    elif [ ! -f "$KIMI_EF" ]; then
      log "layer 2.5 (kimi <$KIMI_GATE>): SKIP — env record $KIMI_EF missing"
      KIMI_OUTCOME="SKIP (env record missing)"
    else
      KIMI_KV="$(sed -nE 's/^CMA_PROVIDER_KEYVAR=(.*)$/\1/p' "$KIMI_EF" | head -1 | tr -d "\"'")"
      KIMI_HAVE=""
      if [ "$KIMI_KV" = "_CMA_KIMICODE_OAUTH_" ]; then
        compgen -G "$HOME/.kimi-code/credentials/*.json" >/dev/null 2>&1 && KIMI_HAVE=1
      elif [ -n "$KIMI_KV" ]; then
        ( set +u; source "${CMA_KEYS_FILE:-$HOME/api_keys.sh}" 2>/dev/null
          eval "printf '%s' \"\${$KIMI_KV:-}\"" ) | grep -q . && KIMI_HAVE=1
      fi
      if [ -z "$KIMI_HAVE" ]; then
        log "layer 2.5 (kimi <$KIMI_GATE>): SKIP — no usable key for $KIMI_ID on this host (account/key absent)"
        KIMI_OUTCOME="SKIP (no usable key)"
      else
        log "layer 2.5: LIVE Kimi smoke via '$KIMI_GATE' (real config.toml, fresh prompt) …"
        _kout="$(bash -c '
          set +eu
          source "$1"
          cma_run_kimi_provider "$2" -p "Reply with exactly: GATE-OK" --output-format text 2>&1
        ' _ "$ALIAS_FILE" "$KIMI_ID")"
        _krc=$?
        if [ "$_krc" -ne 0 ]; then
          if printf '%s' "$_kout" | grep -qiE 'usage limit|quota will reset|5-hour window|auth_error.*403'; then
            log "layer 2.5 (kimi <$KIMI_GATE>): SKIP — account quota (usage limit) at smoke time"
            KIMI_OUTCOME="SKIP (account quota)"
          else
            printf '%s\n' "$_kout" | tail -6 >&2
            fail "kimi live smoke exited $_krc — check the rendered config for $KIMI_ID"
          fi
        elif printf '%s' "$_kout" | grep -q 'GATE-OK'; then
          log "layer 2.5: Kimi smoke GREEN (GATE-OK served through $KIMI_CONFIG)"
          KIMI_OUTCOME="GREEN"
        else
          printf '%s\n' "$_kout" | tail -6 >&2
          fail "kimi live reply did not contain GATE-OK — served model/route is wrong for $KIMI_GATE"
        fi
      fi
    fi
  fi
fi

# ── Layer 2.6: quota/limits live leg ────────────────────────────────────────
log "layer 2.6: LIVE quota/limits leg (claude-providers quota --json) …"
# STDOUT and STDERR are captured APART: merging them (2>&1) made any stderr
# diagnostic part of the "JSON" and the leg could not tell noise from a broken
# document. The installed claude-providers is used, as in layer 2's refresh.
_qerr="$(mktemp "${TMPDIR:-/tmp}/cma-gate-quota-err.XXXXXX")"
_qjson="$(mktemp "${TMPDIR:-/tmp}/cma-gate-quota-json.XXXXXX")"
bash -c '
  set +eu
  source "$1"
  "$HOME/.local/bin/claude-providers" quota --json
' _ "$ALIAS_FILE" >"$_qjson" 2>"$_qerr"
_qrc=$?
if [ "$_qrc" -ne 0 ]; then
  tail -10 "$_qerr" >&2
  rm -f "$_qerr" "$_qjson"
  fail "claude-providers quota --json exited $_qrc"
fi
if ! _qmsg="$(cma_gate_quota_check "$_qjson")"; then
  tail -10 "$_qjson" >&2; tail -10 "$_qerr" >&2
  rm -f "$_qerr" "$_qjson"
  fail "$_qmsg"
fi
rm -f "$_qerr" "$_qjson"
log "layer 2.6: quota/limits LIVE leg GREEN ($_qmsg)"

# ── Layer 3 (opt-in): full provider/model verification ──────────────────────
if [ "$VERIFY_PROVIDERS" -eq 1 ]; then
  log "layer 3: claude-verify-providers (LLMsVerifier) …"
  "$HOME/.local/bin/claude-verify-providers" || fail "provider verification not green"
  log "layer 3: provider verification GREEN"
else
  log "layer 3 (verify-providers): skipped (opt-in via --verify-providers)"
fi

log "layer 2.5 kimi smoke outcome: $KIMI_OUTCOME"
log "ALL LAYERS GREEN — release may proceed."
