#!/usr/bin/env bash
# test_sync_failing_layer_attribution.sh — cmd_sync may record only the failing
# layer the EVIDENCE shows. It may never assert one the evidence contradicts.
#
# THE DEFECT. `claude-providers sync` runs the verifier like this:
#
#     vstatus="$( ( ... bash "$VERIFY" "${vargs[@]}" 2>/dev/null ) )" || true
#
# providers-verify.sh:59 defines its output contract as
#
#     emit() { echo "$1"; [[ -n "${2:-}" ]] && echo "providers-verify[...]: $2" >&2; }
#
# — the STATUS goes to stdout and the REASON goes to STDERR. cmd_sync captures
# the stdout and sends the stderr to /dev/null, so the reason is destroyed at
# the moment it is produced. The very next branch then writes a confident,
# specific cause that nothing measured:
#
#     cma_status_write "$pid" failed "$model" existence
#
# `existence` is a LITERAL, not a measurement. providers-verify.sh emits eight
# distinct `failed` reasons and only one of them is about the model existing:
#
#   :79   base_url is the ccr gateway itself          -> route/config, not existence
#   :89   LLMsVerifier did not confirm                -> existence
#   :198  chat probe 200 with an error body           -> chat
#   :205  VERIFY_OK sentinel missing (bluff)          -> sentinel
#   :222  context-inadequate (backend 400)            -> context
#   :224  chat probe HTTP <code>                      -> existence *or* auth/billing/suspended
#   :246  model made no tool call (Claude Code needs it) -> tool_calling
#   :250  tool-calling probe rejected HTTP <code>     -> tool_calling
#
# Seven of the eight are recorded as `existence` anyway. This is not cosmetic:
# it sends the next investigation looking for a missing model that is not
# missing. Measured live on this host, `helixagent` at :7061 answers a nonce
# prompt correctly — the model plainly EXISTS — and fails only because it does
# not support tool calling (:246). Its status row says `failing_layer=existence`.
# A working capability presented as broken, with a fabricated reason, is the
# same defect class scripts/tests/test_failure_cause_attribution.sh already pins
# at providers-semantic.sh and verify_providers_live.sh. This is the third site.
#
# WHAT THIS FILE PINS. That the layer written to status.json is DERIVED from the
# verifier's own emitted reason, and that an unrecognised or absent reason is
# recorded honestly as `unknown` rather than as a specific wrong noun (§11.4.6,
# §11.4.201: a confident false cause is worse than a stated absence). It does
# NOT change which providers are disabled — every case below asserts
# `status=failed` alongside the layer, because a "fix" that quietly stopped
# disabling a failing provider would be a far worse regression than the wrong
# noun it set out to correct. Case E is the control from the other side: where
# the evidence genuinely IS existence-shaped, the answer must STILL be
# `existence`.
#
# HERMETIC: no network, no live provider, no real claude. A stub $VERIFY mirrors
# providers-verify.sh's real stdout/stderr contract exactly, so the code under
# test exercises its own real capture path rather than a test-only one.
#
# TEETH (§11.4.115 polarity switch). The decision region is EXTRACTED FROM THE
# REAL claude-providers.sh by content anchor — not retyped here — so an
# assertion cannot be satisfied by a literal that has been commented out, and
# the extraction fails loudly if the anchors ever move.
#
#   RED_MODE=0 (default, and what the suite runs) asserts the DEFECT IS ABSENT:
#              the layer tracks the evidence. This is the standing regression
#              guard (§11.4.135).
#   RED_MODE=1 asserts the DEFECT IS PRESENT. It is the proof the guard has
#              teeth, and it only holds against a PRE-FIX body — which is how it
#              was demonstrated RED, without editing the checkout:
#
#                PRE=$(mktemp); git show <pre-fix-rev>:scripts/claude-providers.sh > "$PRE"
#                RED_MODE=1 CMA_PROVIDERS_BIN="$PRE" bash scripts/tests/test_sync_failing_layer_attribution.sh
#
#              Reproduced 13/13 against 1888-line body sha256:f2d9871df424…,
#              where all six evidence classes collapse to `existence`.
#
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
set +e

RED_MODE="${RED_MODE:-0}"
SUBJECT="${CMA_PROVIDERS_BIN:-$SCRIPTS_DIR/claude-providers.sh}"

# --- extract the real decision region ---------------------------------------
# Anchored on content, never on line numbers (§11.4.111): line numbers in this
# file have already drifted by ~1000 lines once, and a stale offset silently
# extracts the wrong code and "passes".
#
# The region begins INSIDE `if (( ! NO_VERIFY )); then` and ends INSIDE
# `if [[ "$vstatus" == "failed" ]]; then`, so the raw slice carries an orphan
# `fi` at the top and an unterminated `if` at the bottom. `if :; then` … `fi`
# balances it WITHOUT retyping one line of the decision logic: every statement
# that decides the layer is still the real file's own bytes.
FRAGMENT="$SANDBOX_HOME/decision-region.sh"
{
  echo 'if :; then'
  awk '
    # Two possible openers so ONE test source drives both bodies (§11.4.115):
    # the pre-fix body starts the region at the verifier invocation, the fixed
    # body starts one line earlier, at the mktemp that captures its stderr.
    /_vreason_f="\$\(mktemp/            { if (!inside) inside = 1 }
    /vstatus="\$\( \(/                   { if (!inside) inside = 1 }
    inside                               { print }
    /n_disabled=\$\(\(n_disabled\+1\)\)/ { if (inside) exit }
  ' "$SUBJECT"
  echo 'fi'
} > "$FRAGMENT"

it "the decision region extracts from the real claude-providers.sh"
if [[ ! -s "$FRAGMENT" ]]; then
  _fail "extraction produced nothing" "anchors moved in $SUBJECT — fix the anchors, do not weaken the test"
  summary; exit 1
fi
# Positive control on the extractor itself (§11.4.273): the region MUST contain
# both the verifier invocation and the status write, or we extracted the wrong
# thing and every assertion below would be measuring nothing.
if grep -q 'bash "$VERIFY"' "$FRAGMENT" && grep -q 'cma_status_write' "$FRAGMENT"; then
  _pass "extracted region contains both the verifier call and the status write"
else
  _fail "extraction captured the wrong region" "$(cat "$FRAGMENT")"
  summary; exit 1
fi
# Negative control: the extractor must not have swallowed the whole file.
it "the extracted region is a region, not the whole script"
_frag_lines=$(wc -l < "$FRAGMENT")
if (( _frag_lines > 2 && _frag_lines < 42 )); then
  _pass "region is $_frag_lines lines"
else
  _fail "region size implausible" "got $_frag_lines lines; anchors are probably wrong"
  summary; exit 1
fi

# --- stub verifier mirroring providers-verify.sh's real contract -------------
STUB_VERIFY="$SANDBOX_HOME/stub-verify.sh"
sandbox_stub "$STUB_VERIFY" <<'EOF'
#!/usr/bin/env bash
# Mirrors providers-verify.sh emit(): status on stdout, reason on stderr.
printf '%s\n' "${STUB_STATUS:-failed}"
[[ -n "${STUB_REASON:-}" ]] && printf 'providers-verify[%s]: %s\n' "${STUB_PID:-probeprov}" "$STUB_REASON" >&2
exit "${STUB_RC:-1}"
EOF

# shellcheck source=/dev/null
source "$SCRIPTS_DIR/lib.sh" 2>/dev/null || source "$SCRIPTS_DIR/lib.sh"

STATUS_JSON="$(cma_status_cache)"
mkdir -p "$(dirname "$STATUS_JSON")"

# run_case <pid> <reason> -> echoes the failing_layer written to status.json
run_case() {
  local pid="$1" reason="$2"
  rm -f "$STATUS_JSON"
  (
    set +e
    VERIFY="$STUB_VERIFY"
    CMA_KEYS_FILE="$SANDBOX_HOME/nonexistent-keys.sh"
    NO_VERIFY=0
    vargs=(--provider "$pid" --model probe-model --key-var TEST_KEY)
    vstatus="unverified"
    model="probe-model"
    n_disabled=0
    # Mirrors the real `local _vreason="" _vreason_f=""`, which sits a few lines
    # ABOVE the extracted region. Without it, case F (no reason emitted) reads
    # an unset var under `set -u`, the substitution dies, and the layer lands
    # empty — a harness artefact that looks exactly like a product bug. The
    # assertion below pins that the real declaration still exists, so mirroring
    # it here cannot hide its removal.
    _vreason="" _vreason_f=""
    export STUB_STATUS=failed STUB_REASON="$reason" STUB_PID="$pid" STUB_RC=1
    # shellcheck source=/dev/null
    source "$FRAGMENT"
  ) >/dev/null 2>&1
  jq -r --arg id "$pid" '.[$id].failing_layer // "<absent>"' "$STATUS_JSON" 2>/dev/null
}
run_status() {
  jq -r --arg id "$1" '.[$id].status // "<absent>"' "$STATUS_JSON" 2>/dev/null
}

# --- the cases ---------------------------------------------------------------
# reason text is quoted from providers-verify.sh's real emit() call sites.
R_TOOL='chat probe passed but the model made no tool call at https://x/v1 on both attempts (tool calling is required by Claude Code)'
R_SENTINEL='chat probe 200 but VERIFY_OK sentinel missing at https://x/v1 on both attempts (bluff or non-functional model)'
R_CONTEXT='context-inadequate: the model context window is smaller than even the verification probe at https://x/v1 (backend 400: context overflow) — relaunch the backing server with a larger context'
R_ROUTE='base_url (https://x/v1) is the ccr gateway itself — any probe is answered by whichever provider ccr routes to, so no verdict is attributable to this alias. Repoint it at its real backing endpoint.'
R_EXISTENCE='LLMsVerifier did not confirm (see its output)'

check() {  # check <label> <pid> <reason> <expected_layer_when_fixed>
  local label="$1" pid="$2" reason="$3" want="$4"
  local got; got="$(run_case "$pid" "$reason")"
  local st;  st="$(run_status "$pid")"

  it "$label — the provider is still disabled (guard: the fix must not stop failing)"
  assert_eq "failed" "$st" "status for $pid"

  if (( RED_MODE )); then
    it "$label — RED: the reason is discarded and the layer collapses to 'existence'"
    if [[ "$got" == "existence" ]]; then
      _pass "defect reproduced: evidence said '${reason:0:48}...' but layer=existence"
    else
      _fail "RED did not reproduce" "expected the pre-fix literal 'existence', got '$got' — is the fix already applied? run with RED_MODE=0"
    fi
  else
    it "$label — GREEN: the layer is derived from the verifier's own reason"
    assert_eq "$want" "$got" "failing_layer for $pid"
  fi
}

if (( ! RED_MODE )); then
  # The harness mirrors this declaration inside run_case; if the real one is
  # deleted, cmd_sync reads an unset var under `set -u` on the --no-verify path
  # and the mirror would hide it. Pin it here instead.
  it "the fixed body declares the reason locals outside the region"
  if grep -q 'local _vreason="" _vreason_f=""' "$SUBJECT"; then
    _pass "cmd_sync declares _vreason/_vreason_f before the verify block"
  else
    _fail "reason locals missing" "cmd_sync must declare them, or --no-verify hits an unset read under set -u"
  fi
fi

check "A tool-calling unsupported" toolprov  "$R_TOOL"      "tool_calling"
check "B sentinel missing (bluff)" sentprov  "$R_SENTINEL"  "sentinel"
check "C context inadequate"       ctxprov   "$R_CONTEXT"   "context"
check "D ccr self-route"           routeprov "$R_ROUTE"     "route"
# E is the control from the other side: genuinely existence-shaped evidence must
# STILL be recorded as existence. A fix that renamed everything away from
# `existence` would be just as wrong as the one that named everything it.
check "E existence (control)"      existprov "$R_EXISTENCE" "existence"

# F: no reason at all. The honest answer is `unknown` — never a confident guess.
it "F absent reason — honest 'unknown', not a fabricated cause"
_got_f="$(run_case noreasonprov "")"
if (( RED_MODE )); then
  if [[ "$_got_f" == "existence" ]]; then
    _pass "defect reproduced: no evidence at all, yet layer=existence"
  else
    _fail "RED did not reproduce" "expected 'existence', got '$_got_f'"
  fi
else
  assert_eq "unknown" "$_got_f" "failing_layer with no reason emitted"
fi

summary
