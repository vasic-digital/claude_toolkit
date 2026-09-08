#!/usr/bin/env bash
# test_kimi_wire_and_status_freshness.sh — three defects that all shared one
# shape: a surface that ASSERTED something it had not established.
#
# WHY THIS EXISTS (three live defects, 2026-09-07/08, all measured, none hypothetical).
#
# D1 — `claude-providers list` printed a STATUS with no age, so a `verified`
#      written before an outage kept reading as present-tense success. Measured:
#      `helixllm-gateway` displayed STATUS `verified` while a live probe of that
#      exact endpoint returned HTTP 401. The record already carried `checked_at`;
#      the renderer simply never looked at it. The surface an operator reads most
#      was the one surface that could not be wrong out loud.
#
# D2 — `helixllm-export --apply` wrote the Claude env + alias through the shared
#      writers but never emitted the Kimi twin, unlike the two OTHER alias-
#      emitting paths (cmd_sync and the multi-sync leg), which both call
#      _cma_kimi_twin_alias + _cma_kimi_render_config under `(( KIMI_ALIASES ))`.
#      Measured on the operator's host: claude alias
#      `helixllm-anton-qwen2-5-coder-3b-instruct-q4_k_m-f6771589d190` existed with
#      neither a `kimi-` twin alias nor a ~/.kimi-prov-<id>/config.toml.
#
# D3 — _cma_kimi_render_config chose the Kimi WIRE from the base-URL SHAPE
#      (`*/anthropic*`), so a provider that speaks Anthropic natively but whose
#      URL does not say so was typed `openai`. Measured against the real gateway
#      at https://127.0.0.1:8443 (transport `native`, base with no `/v1`):
#
#        GET  /v1/models            200      GET  /models              404
#        POST /v1/chat/completions  400      POST /chat/completions    404
#        POST /v1/messages          400
#
#      The bundled openai SDK inside the kimi binary posts "/chat/completions"
#      RELATIVE to base_url, so the openai wire aimed the twin at a 404. The
#      bundled @anthropic-ai/sdk posts "/v1/messages" relative to base_url —
#      which is the route that exists. The base_url is NOT wrong: it is correct
#      for its own native/Anthropic transport. Only the wire label was.
#
#      THE FIX IS NOT "APPEND /v1". `deepseek` (https://api.deepseek.com),
#      `kilo` (/api/gateway) and `zai` (/paas/v4) are openai-typed twins with no
#      `/v1`, and a blind append would break all three. The discriminator is the
#      TRANSPORT — providers_resolve.transport_for: "native iff the provider
#      speaks the Anthropic API natively" — not the URL string. Section 3 below
#      carries that negative control as a first-class assertion.
#
# D5 — `kimi-providers list` re-parses the engine's table BY POSITION, and the
#      D1 fix inserted CHECKED between STATUS and LAYER without updating it.
#      Measured on this fixture: the wrapper printed the AGE under LAYER, the
#      LAYER under STRONG_MODEL, and no model at all — on the operator's only
#      Kimi-framed inventory, and the only view that reports `no-twin` drift.
#      No suite asserted that command's columns, which is why a fix to one file
#      could silently relabel another's output. Section 4 is that assertion.
#
# RED_MODE (§11.4.115) — ONE source, two roles.
#   RED_MODE=1 asserts the DEFECTS ARE PRESENT; run it against the PRE-FIX tree,
#   which is what proves this test can fail:
#     CMA_TEST_SCRIPTS_DIR=<pre-fix tree> RED_MODE=1 bash test_kimi_wire_and_status_freshness.sh
#   RED_MODE=0 (the default, and how the suite runs it) is the standing
#   regression guard asserting the defects are ABSENT.
#
# Paired §1.1 mutations (each makes RED_MODE=0 FAIL):
#   D5e: swap `alias=$2; pid=$1` in kimi-providers.sh's positional parse
#                                                            -> section 4 FAILs
#        THE ONE THIS FILE USED TO SURVIVE. The fixture named each alias
#        identically to its provider id, so ALIAS and PROVIDER held the same
#        string and swapping those two columns rendered IDENTICAL output: 52/0,
#        green, against a real column swap — under a comment claiming no two
#        cells in a row share a value. The `al-` prefix on the fixture alias is
#        what makes that claim true; do not simplify it away.
#   W2d: DELETE either helper definition outright             -> section 1b FAILs
#        Distinct from W2c, which replaces the BODIES. This one removes the
#        definitions, and it is the mutation the first version of the RED-leg
#        fix SURVIVED at 53/0 — because the absence probe was top-level rather
#        than gated on RED_MODE, so a GREEN run reported the deletion as an
#        honest skip labelled `RED:`. The probe is now RED-gated and the GREEN
#        leg FAILs on absence.
#   W2c: replace the bodies of cma_status_age_human / cma_status_is_stale with
#        constants                                          -> section 1b FAILs
#        Those two wrappers shipped with ZERO callers and ZERO assertions, so a
#        constant body was indistinguishable from a working one at 52/0.
#   D1:  drop the age/stale rendering from _list_rows            -> section 1 FAILs
#   D1c: render an UNKNOWN age as `0s` instead of `?` in
#        cma_status_age_human_s (mutation "M1c")                 -> section 1 FAILs
#        NAMES THE `_s` VARIANT DELIBERATELY: that is where the `?` is decided.
#        `cma_status_age_human` is a one-line wrapper that measures and delegates,
#        and _list_rows calls the `_s` form directly (it measures the age once
#        and derives both the string and the stale verdict from it), so mutating
#        the wrapper would change nothing the renderer sees — a mutation that
#        cannot fail is not a mutation.
#        Listed explicitly because it is the one this file used to SURVIVE: the
#        unknown-age case asserted `grep -q '?'` against the whole row, which
#        matched the ALIAS column's own `?` and so passed no matter what the
#        CHECKED column said. M1c left the suite at 27 passed / 0 failed. The
#        assertion now reads column 4, which is the property it always claimed.
#   D2:  delete the twin block from cmd_helixllm_export --apply  -> section 2 FAILs
#   D3:  restore `local api_key="" typ="openai"` with no
#        transport rule in _cma_kimi_render_config               -> section 3 FAILs
#   D5:  shift the wrapper's column indices back (`layer=$4; model=$5` in
#        scripts/kimi-providers.sh) so it reads the engine's pre-CHECKED
#        layout                                                  -> section 4 FAILs
#   D4:  delete the twin restore from the --refresh-aliases loop  -> section 2's
#        "--refresh-aliases rebuilds the kimi twin too" case FAILs.
#        The OPPOSITE mutation — deleting that restore's
#        `-f ~/.kimi-prov-<id>/config.toml` gate so it fires for every record —
#        is NOT caught by this file, and saying so is the point: that gate is
#        what keeps the session hook's fast path from rewriting the alias file
#        on every shell start, and its teeth are the "the refresh fast path is a
#        no-op too" case in tests/test_alias_file_concurrency.sh, which FAILs
#        without it. The two mutations pull in opposite directions and each has
#        its own suite; neither file guards both.
#
# Hermetic + re-runnable (§11.4.98): its own mock on an ephemeral port, its own
# sandbox HOME, no real keys, no network, no reliance on the host's HelixLLM.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# The tree under test. Overridable so the RED leg can point at the PRE-FIX tree
# and genuinely reproduce the defects instead of merely asserting them inverted.
SCRIPTS_DIR="${CMA_TEST_SCRIPTS_DIR:-$DEFAULT_SCRIPTS_DIR}"
export SCRIPTS_DIR
PROOF_DIR="$TESTS_DIR/proof"
mkdir -p "$PROOF_DIR"
PROOF="${CMA_TEST_PROOF:-$PROOF_DIR/98-kimi-wire-and-status-freshness.txt}"
: > "$PROOF"

RED_MODE="${RED_MODE:-0}"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
# HERMETICITY (§11.4.98): make_sandbox scrubs HOME and the provider dirs but not
# these two knobs, and three sections now render or judge verdict AGE. An
# operator with either exported would see this suite fail for a reason that has
# nothing to do with the code under test. Measured before pinning:
# CMA_STATUS_TTL=60 -> 4 FAIL, =500000 -> 3 FAIL, CMA_MODELS_DEV_TTL=500000 ->
# 3 FAIL (that second knob became effective when the TTL lookup moved to call
# time). Pinned rather than unset so the horizon under test is stated, not
# inherited.
export CMA_STATUS_TTL=86400
export CMA_MODELS_DEV_TTL=86400
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e   # lib.sh sets -e; this harness asserts on failures.

command -v jq      >/dev/null 2>&1 || { echo "SKIP: jq is required";      exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 is required"; exit 0; }
command -v curl    >/dev/null 2>&1 || { echo "SKIP: curl is required";    exit 0; }

PROVIDERS_SH="$SCRIPTS_DIR/claude-providers.sh"
PDIR="$(cma_providers_dir)"; mkdir -p "$PDIR"

# ---------------------------------------------------------------------------
# Mock gateway — ROUTE-AWARE, mirroring the real host's measured shape so the
# wire assertions in section 3 are wire REALITY, not string equality:
#   GET  /v1/models            200        GET  /models             404
#   POST /v1/chat/completions  200        POST /chat/completions   404
#   POST /v1/messages          200        POST /messages           404
# A 404 here is the same verdict the real gateway gives, so "the wire this
# config implies actually resolves" is a real, falsifiable question.
# ---------------------------------------------------------------------------
SERVED_ID="helixllm-mockmodel-a1b2c3d4e5f6"
PORT_FILE="$HOME/.mock_port"; HIT_FILE="$HOME/.mock_hits"; : > "$HIT_FILE"
trap '[[ -n "${SRV_PID:-}" ]] && kill "$SRV_PID" 2>/dev/null; cleanup_sandbox' EXIT
python3 - "$PORT_FILE" "$HIT_FILE" "$SERVED_ID" >/dev/null 2>&1 <<'PY' &
import http.server, socketserver, sys, json
port_file, hit_file, served_id = sys.argv[1], sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def _log(self, what):
        with open(hit_file, 'a') as f:
            f.write('%s %s\n' % (what, self.path))
    def do_GET(self):
        # ONLY /v1/models exists — exactly like the measured gateway.
        if self.path.rstrip('/') == '/v1/models':
            self._log('GET')
            self._send(200, {"object": "list", "data": [{
                "id": served_id, "object": "model", "owned_by": "llamacpp",
                "model_identity": "helixllm/mock/qwen-test",
                "host": "mock", "availability": "serving"}]})
        else:
            self._log('GET-404')
            self.send_response(404); self.end_headers()
    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(n).decode('utf-8', 'replace')
        p = self.path.rstrip('/')
        if p not in ('/v1/chat/completions', '/v1/messages'):
            self._log('POST-404')
            self.send_response(404); self.end_headers(); return
        self._log('POST')
        if '"tools"' in body:
            msg = {"tool_calls": [{"id": "c1", "type": "function",
                                   "function": {"name": "get_weather", "arguments": "{}"}}]}
        else:
            msg = {"content": "VERIFY_OK"}
        self._send(200, {"model": served_id, "choices": [{"message": msg}]})
    def log_message(self, *a): pass
srv = socketserver.TCPServer(('127.0.0.1', 0), H)
open(port_file, 'w').write(str(srv.server_address[1]))
srv.serve_forever()
PY
SRV_PID=$!
for _ in $(seq 1 60); do [[ -s "$PORT_FILE" ]] && break; sleep 0.1; done
PORT="$(cat "$PORT_FILE" 2>/dev/null)"
[[ -n "$PORT" ]] || { echo "FATAL: mock server did not start" >&2; exit 1; }
MOCK_V1="http://127.0.0.1:$PORT/v1"
MOCK_ROOT="http://127.0.0.1:$PORT"

# --- pins pointed at the mock ----------------------------------------------
# helixllm-gateway: router/OpenAI, base ENDS in /v1  -> must stay type=openai.
# helixagent-native: native/Anthropic, base has NO /v1 and no `/anthropic`
#                    -> the shape the URL heuristic could never classify.
GW_PINS="$HOME/gw.json"; NAT_PINS="$HOME/nat.json"
cat > "$GW_PINS" <<JSON
{ "bin":"helixllm", "id":"helixllm-gateway", "base_url":"$MOCK_V1",
  "transport":"router", "key_var":"HELIXLLM_GATEWAY_KEY",
  "context_limit":229376, "max_output":8192 }
JSON
cat > "$NAT_PINS" <<JSON
{ "bin":"helixllm", "id":"helixagent-native", "base_url":"$MOCK_ROOT",
  "transport":"native", "key_var":"HELIXLLM_GATEWAY_KEY",
  "context_limit":229376, "max_output":8192 }
JSON
export CMA_HELIXLLM_PINS_FILE="$GW_PINS" CMA_HELIXLLM_NATIVE_PINS_FILE="$NAT_PINS"
export CMA_HELIXLLM_HOSTS="$MOCK_V1"
export CMA_HELIXLLM_HTTP_TIMEOUT=5
unset CMA_HELIXLLM_GW_STRONG CMA_HELIXLLM_GW_FAST \
      CMA_HELIXLLM_NATIVE_STRONG CMA_HELIXLLM_NATIVE_FAST 2>/dev/null

# Silence every OTHER pinned detector so this run is about the two Helix records.
for _pin in HELIXAGENT OPENCODE_ZEN OPENCODE_GO CHUTES HYPER; do
  export "CMA_${_pin}_PINS_FILE=$HOME/.none-${_pin}-pins.json"
done
unset _pin
export CMA_SYNC_MULTI=0

KEYS="$HOME/api_keys.sh"
cat > "$KEYS" <<'SH'
export HELIXLLM_GATEWAY_KEY="dummy-helixllm"
SH
for _f in key-aliases overrides legacy-renames; do echo '{}' > "$HOME/$_f.json"; done
unset _f
export CMA_PROVIDERS_KEY_ALIASES="$HOME/key-aliases.json"
export CMA_PROVIDERS_OVERRIDES="$HOME/overrides.json"
export CMA_PROVIDERS_LEGACY_RENAMES="$HOME/legacy-renames.json"

# Minimal valid models.dev cache so ensure_catalog is satisfied offline.
CACHE="$PDIR/models.dev.cache.json"
cat > "$CACHE" <<'JSON'
{"beta":{"env":["BETA_API_KEY"],"api":"https://api.beta.ai/v1","npm":"@ai-sdk/openai-compatible",
 "models":{"f":{"id":"beta-x","reasoning":false,"release_date":"2025-06-01",
 "limit":{"context":128000},"cost":{"input":1,"output":5},"tool_call":true}}}}
JSON

{
  echo "=== test_kimi_wire_and_status_freshness.sh evidence ==="
  echo "date:            $(date -u +%FT%TZ)"
  echo "RED_MODE:        $RED_MODE   (1 = assert the defects ARE present, pre-fix tree)"
  echo "tree under test: $SCRIPTS_DIR"
  echo "mock:            $MOCK_ROOT   serving id: $SERVED_ID"
  echo "--- mock route shape (the real gateway's measured shape) ---"
  for _p in /v1/models /models; do
    printf 'GET  %-22s %s\n' "$_p" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$MOCK_ROOT$_p")"
  done
  for _p in /v1/chat/completions /chat/completions /v1/messages; do
    printf 'POST %-22s %s\n' "$_p" \
      "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST -H 'content-type: application/json' -d '{}' "$MOCK_ROOT$_p")"
  done
} >> "$PROOF" 2>&1

# probe_wire BASE TYPE -> the HTTP code the kimi CLI's SDK for TYPE would get.
# openai    -> the bundled openai SDK posts "/chat/completions" relative to base
# anthropic -> the bundled @anthropic-ai/sdk posts "/v1/messages" relative to base
probe_wire() {
  local base="$1" typ="$2" path
  case "$typ" in
    anthropic) path="/v1/messages" ;;
    *)         path="/chat/completions" ;;
  esac
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST \
    -H 'content-type: application/json' -d '{}' "${base%/}$path"
}

# ===========================================================================
# Section 1 — D1: `list` cannot present a stale verdict as a current one
# ===========================================================================
it "list shows the age of every verdict and marks one older than CMA_STATUS_TTL"

# Two env records, identical but for their verdict AGE. Written by hand so the
# only variable under test is checked_at.
for _id in newprov oldprov; do
  cat > "$PDIR/$_id.env" <<ENVF
CMA_PROVIDER_ID='$_id'
CMA_PROVIDER_KEYVAR='DUMMY_KEY'
CMA_PROVIDER_TRANSPORT='router'
CMA_PROVIDER_BASE_URL='https://example.invalid/v1'
CMA_PROVIDER_MODEL='m-$_id'
CMA_PROVIDER_FAST_MODEL='m-$_id'
ENVF
done
unset _id
_now_epoch="$(date -u +%s)"
_fresh_ts="$(date -u -d "@$((_now_epoch - 60))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
             || date -u -r "$((_now_epoch - 60))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
_stale_ts="$(date -u -d "@$((_now_epoch - 400000))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
             || date -u -r "$((_now_epoch - 400000))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
if [[ -z "$_fresh_ts" || -z "$_stale_ts" ]]; then
  echo "SKIP: neither GNU nor BSD date could format an epoch (§11.4.3)"; exit 0
fi
jq -n --arg ft "$_fresh_ts" --arg st "$_stale_ts" '{
  newprov: {status:"verified", model:"m-newprov", checked_at:$ft, failing_layer:""},
  oldprov: {status:"verified", model:"m-oldprov", checked_at:$st, failing_layer:""}
}' > "$PDIR/status.json"

LIST_OUT="$(bash "$PROVIDERS_SH" list 2>/dev/null)"
{ echo "--- claude-providers list (fresh=$_fresh_ts stale=$_stale_ts) ---"; echo "$LIST_OUT"; } >> "$PROOF" 2>&1

_stale_row="$(echo "$LIST_OUT" | grep -E '(^|[[:space:]])oldprov([[:space:]]|$)' | head -1)"
_fresh_row="$(echo "$LIST_OUT" | grep -E '(^|[[:space:]])newprov([[:space:]]|$)' | head -1)"
assert_eq 0 "$([[ -n "$_stale_row" ]] && echo 0 || echo 1)" "list still lists the stale provider (it is not hidden)"
assert_eq 0 "$([[ -n "$_fresh_row" ]] && echo 0 || echo 1)" "list lists the fresh provider"

# The load-bearing assertion: a 4-day-old verdict and a 1-minute-old verdict
# MUST NOT render identically. Compare the two rows with the id masked out.
_stale_masked="$(echo "$_stale_row" | sed 's/oldprov//g; s/m-oldprov//g' | tr -s ' ')"
_fresh_masked="$(echo "$_fresh_row" | sed 's/newprov//g; s/m-newprov//g' | tr -s ' ')"
if (( RED_MODE )); then
  assert_eq "$_fresh_masked" "$_stale_masked" \
    "RED: a 4-day-old verdict renders IDENTICALLY to a 1-minute-old one"
  if echo "$_stale_row" | grep -qi 'stale'; then
    _fail "RED: the row already carries a staleness marker" "$_stale_row"
  else
    _pass "RED: nothing in the row says the verdict is old"
  fi
else
  if [[ "$_stale_masked" == "$_fresh_masked" ]]; then
    _fail "a stale verdict renders identically to a fresh one" "stale=[$_stale_row] fresh=[$_fresh_row]"
  else
    _pass "a stale verdict does NOT render like a fresh one"
  fi
  echo "$_stale_row" | grep -qi 'stale'; assert_eq 0 $? "the stale row is marked stale"
  echo "$_fresh_row" | grep -qi 'stale' && _m=1 || _m=0
  assert_eq 0 "$_m" "the fresh row is NOT marked stale (no blanket marking)"
  # The age itself must be shown, not merely a boolean.
  echo "$_stale_row" | grep -qE '[0-9]+[smhd]'; assert_eq 0 $? "the stale row shows a concrete age"
  echo "$_fresh_row" | grep -qE '[0-9]+[smhd]'; assert_eq 0 $? "the fresh row shows a concrete age"
  echo "$LIST_OUT" | head -1 | grep -q 'CHECKED'; assert_eq 0 $? "the header names the age column"
fi

it "a record with no checked_at reports an UNKNOWN age, never a fresh one (§11.4.6)"
jq -n '{noage: {status:"verified", model:"m-noage", failing_layer:""}}' > "$PDIR/status.json"
cat > "$PDIR/noage.env" <<'ENVF'
CMA_PROVIDER_ID='noage'
CMA_PROVIDER_KEYVAR='DUMMY_KEY'
CMA_PROVIDER_TRANSPORT='router'
CMA_PROVIDER_BASE_URL='https://example.invalid/v1'
CMA_PROVIDER_MODEL='m-noage'
CMA_PROVIDER_FAST_MODEL='m-noage'
ENVF
NOAGE_OUT="$(bash "$PROVIDERS_SH" list 2>/dev/null)"
{ echo "--- list with a checked_at-less record ---"; echo "$NOAGE_OUT"; } >> "$PROOF" 2>&1
_noage_row="$(echo "$NOAGE_OUT" | grep -E '(^|[[:space:]])noage([[:space:]]|$)' | head -1)"
if (( RED_MODE )); then
  _pass "RED: no age column exists to report an unknown age in"
else
  assert_eq 0 "$([[ -n "$_noage_row" ]] && echo 0 || echo 1)" "the record is still listed"
  # READ THE CHECKED COLUMN, NOT THE ROW. A whole-row `grep -q '?'` passed here
  # for the wrong reason and could not fail: this record has no alias line, so
  # `${alias:-?}` already puts a literal `?` in column 1 and the row matches
  # whatever column 4 says. Rendering an unknown age as `0s` (mutation M1c) left
  # the suite fully green. The row is `? noage verified ? - m-noage`; the
  # renderer emits six always-non-empty fields (alias, provider, status,
  # checked, layer, strong_model — `?` and `-` are the empty-value defaults), so
  # awk's $4 IS the CHECKED column.
  _noage_checked="$(echo "$_noage_row" | awk '{print $4}')"
  assert_eq '?' "$_noage_checked" "an absent checked_at renders CHECKED as '?' (unknown)"
  # ...and separately the §11.4.6 property that `?` is only a spelling of: an
  # age we do not know must never be presented as one we do. Asserted on the
  # column rather than the row so a model name containing digits can never
  # satisfy or break it.
  echo "$_noage_checked" | grep -qE '[0-9]+[smhd]' && _noage_agey=1 || _noage_agey=0
  assert_eq 0 "$_noage_agey" "an unknown age is never rendered as a concrete age"
fi
rm -f "$PDIR/newprov.env" "$PDIR/oldprov.env" "$PDIR/noage.env" "$PDIR/status.json"

# ===========================================================================
# Section 1b — W-2: the timestamp-taking status helpers are covered, not just
#                   shipped (they had zero callers and zero assertions)
# ===========================================================================
it "the timestamp-taking status helpers are exercised, not merely shipped"

# WHY THIS EXISTS. `cma_status_age_human` and `cma_status_is_stale` are the
# convenience forms that take a TIMESTAMP and measure the age for you; the
# renderer calls the `_s` forms, which take an age already measured, so these
# two had ZERO callers and ZERO coverage. Measured: replacing both bodies with a
# constant left the whole suite at 52/0 — shipped code that nothing could prove
# wrong (§11.4.224 coverage floor, §11.4.124 do not ship unwired code on faith).
# They are kept rather than deleted because they are the honest entry point for
# a caller holding a timestamp; keeping them obliges us to assert them.
_h_now="$(date -u +%s)"
_h_fresh="$(date -u -d "@$((_h_now - 120))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || date -u -r "$((_h_now - 120))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
_h_old="$(date -u -d "@$((_h_now - 400000))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
          || date -u -r "$((_h_now - 400000))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
_helpers_absent() {
  ! declare -F cma_status_age_human >/dev/null 2>&1 \
    || ! declare -F cma_status_is_stale >/dev/null 2>&1
}
if (( RED_MODE )) && _helpers_absent; then
  # RED LEG ONLY. The pre-fix tree ships NEITHER helper, so there is nothing
  # here to assert and saying so is the honest verdict (§11.4.6). Section 4
  # gates its equivalent "this engine prints no CHECKED column" branch on
  # RED_MODE FIRST, and this must too — an earlier revision of this block was
  # top-level and therefore fired on the GREEN leg as well, so DELETING both
  # helpers outright yielded 53/0 with a PASS labelled `RED:`. Removing the
  # exact code this section exists to cover was reported as success: a
  # §11.4.201 false-negative introduced by the fix for the RED leg.
  _pass "RED: this tree ships no timestamp-taking helpers — nothing to exercise"
elif _helpers_absent; then
  # GREEN LEG. A tree that is SUPPOSED to ship these helpers and does not is a
  # defect, never a skip. This is the assertion whose absence let the deletion
  # pass.
  _fail "the timestamp-taking helpers are missing from a tree that should ship them" \
        "cma_status_age_human / cma_status_is_stale not defined after sourcing lib.sh"
elif [[ -z "$_h_fresh" || -z "$_h_old" ]]; then
  echo "SKIP: neither GNU nor BSD date could format an epoch (§11.4.3)"
else
  assert_eq "2m" "$(cma_status_age_human "$_h_fresh")" \
    "cma_status_age_human renders a measured age from a timestamp"
  assert_eq "?"  "$(cma_status_age_human "")" \
    "cma_status_age_human renders an ABSENT timestamp as unknown, never as fresh"
  assert_eq "?"  "$(cma_status_age_human "not-a-timestamp")" \
    "cma_status_age_human renders an UNPARSEABLE timestamp as unknown"
  if cma_status_is_stale "$_h_old"; then
    _pass "cma_status_is_stale reports a verdict past the horizon as stale"
  else
    _fail "cma_status_is_stale missed a stale verdict" "ts=$_h_old ttl=${CMA_STATUS_TTL:-unset}"
  fi
  if cma_status_is_stale "$_h_fresh"; then
    _fail "cma_status_is_stale called a fresh verdict stale" "ts=$_h_fresh"
  else
    _pass "cma_status_is_stale leaves a fresh verdict alone"
  fi
  # An unknown age is NOT stale — it is unknown. Reporting it stale would be a
  # different lie from reporting it fresh, and both are forbidden (§11.4.6).
  if cma_status_is_stale ""; then
    _fail "cma_status_is_stale reported an UNKNOWN age as stale" "empty timestamp"
  else
    _pass "cma_status_is_stale treats an unknown age as unknown, not stale"
  fi
fi

# ===========================================================================
# Section 2 — D2: helixllm-export --apply emits the Kimi twin like every
#                 other alias-emitting path
# ===========================================================================
it "helixllm-export --apply emits a kimi twin alias + config for every record it writes"
bash "$PROVIDERS_SH" helixllm-export --apply --offline --keys-file "$KEYS" >>"$PROOF" 2>&1
_apply_rc=$?
assert_eq 0 "$_apply_rc" "helixllm-export --apply exits cleanly"

# The ids --apply actually wrote, read back from its own provenance marker so
# this never asserts against a name we invented.
EXPORTED_IDS="$(grep -l "CMA_PROVIDER_SOURCE='helixllm-export'" "$PDIR"/*.env 2>/dev/null \
                | while read -r f; do basename "$f" .env; done)"
{ echo "--- ids written by helixllm-export --apply ---"; echo "$EXPORTED_IDS"; } >> "$PROOF" 2>&1
_n_exported="$(printf '%s\n' "$EXPORTED_IDS" | grep -c '[^[:space:]]')"
if (( _n_exported == 0 )); then
  _fail "precondition: --apply wrote no records at all" "nothing to assert a twin against"
else
  _pass "--apply wrote $_n_exported provider record(s)"
  _missing_alias=0 _missing_cfg=0
  for _eid in $EXPORTED_IDS; do
    grep -q "^alias kimi-$_eid=" "$ALIAS_FILE" 2>/dev/null || _missing_alias=$((_missing_alias+1))
    [[ -f "$HOME/.kimi-prov-$_eid/config.toml" ]] || _missing_cfg=$((_missing_cfg+1))
  done
  unset _eid
  { echo "--- twin coverage: missing_alias=$_missing_alias missing_config=$_missing_cfg of $_n_exported ---"
    grep '^alias kimi-' "$ALIAS_FILE" 2>/dev/null; } >> "$PROOF" 2>&1
  if (( RED_MODE )); then
    assert_eq "$_n_exported" "$_missing_alias" "RED: NOT ONE exported record got a kimi twin alias"
    assert_eq "$_n_exported" "$_missing_cfg"   "RED: NOT ONE exported record got a kimi config.toml"
  else
    assert_eq 0 "$_missing_alias" "every exported record has a kimi-<id> twin alias"
    assert_eq 0 "$_missing_cfg"   "every exported record has a ~/.kimi-prov-<id>/config.toml"
  fi
fi

it "--refresh-aliases rebuilds the kimi twin too, not just the claude alias"
# Found by pushing on the same class rather than stopping at the reported path
# (§11.4.118): --refresh-aliases is the session hook's fast path and it is what
# REBUILDS the alias file, so omitting the twin there meant that after the file
# was lost or rotated, every claude alias came back and no kimi twin did — the
# same "claude alias present, twin missing" symptom, reached a different way.
_ref_id="$(printf '%s\n' $EXPORTED_IDS | head -1)"
if [[ -z "$_ref_id" ]]; then
  _fail "precondition: no exported id to rebuild" "section 2 wrote nothing"
else
  bash "$PROVIDERS_SH" helixllm-export --apply --offline --keys-file "$KEYS" >>"$PROOF" 2>&1
  grep -q "^alias kimi-$_ref_id=" "$ALIAS_FILE" 2>/dev/null
  _pre=$?
  rm -f "$ALIAS_FILE"
  bash "$PROVIDERS_SH" list --refresh-aliases --quiet >/dev/null 2>&1
  grep -q "cma_run_provider $_ref_id" "$ALIAS_FILE" 2>/dev/null; _claude_back=$?
  grep -q "^alias kimi-$_ref_id=" "$ALIAS_FILE" 2>/dev/null; _kimi_back=$?
  { echo "--- alias file rebuilt from cache after deletion ---"
    grep -E "^alias (kimi-)?$_ref_id=" "$ALIAS_FILE" 2>/dev/null; } >> "$PROOF" 2>&1
  assert_eq 0 "$_claude_back" "the claude alias is rebuilt from the cached env record"
  if (( RED_MODE )); then
    assert_eq 1 "$_kimi_back" "RED: the kimi twin is NOT rebuilt — it is silently lost"
  else
    assert_eq 0 "$_kimi_back" "the kimi twin is rebuilt alongside it"
  fi
fi

it "--no-kimi-aliases still suppresses the twin on the export path (opt-out honoured)"
rm -rf "$HOME"/.kimi-prov-* 2>/dev/null
bash "$PROVIDERS_SH" helixllm-export --apply --offline --no-kimi-aliases --keys-file "$KEYS" >>"$PROOF" 2>&1
_optout_dirs="$(ls -d "$HOME"/.kimi-prov-* 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "0" "$_optout_dirs" "--no-kimi-aliases writes no kimi config dirs on the export path"

# ===========================================================================
# Section 3 — D3: the Kimi wire follows the TRANSPORT, and the wire it names
#                 actually resolves on the host
# ===========================================================================
it "a native (Anthropic-speaking) provider gets the anthropic wire, whatever its URL looks like"
rm -rf "$HOME"/.kimi-prov-* 2>/dev/null
bash "$PROVIDERS_SH" sync --offline --no-verify --keys-file "$KEYS" >>"$PROOF" 2>&1

NAT_CFG="$HOME/.kimi-prov-helixagent-native/config.toml"
GW_CFG="$HOME/.kimi-prov-helixllm-gateway/config.toml"
{ echo "--- rendered kimi configs (api_key redacted) ---"
  for _c in "$NAT_CFG" "$GW_CFG"; do
    echo "## $_c"; sed 's/^api_key = .*/api_key = "<redacted>"/' "$_c" 2>/dev/null || echo "(absent)"
  done; } >> "$PROOF" 2>&1

assert_file "$NAT_CFG" "native provider config.toml rendered"
assert_file "$GW_CFG"  "router provider config.toml rendered"

_nat_type="$(grep -E '^type = ' "$NAT_CFG" 2>/dev/null | head -1 | cut -d'"' -f2)"
_nat_base="$(grep -E '^base_url = ' "$NAT_CFG" 2>/dev/null | head -1 | cut -d'"' -f2)"
_gw_type="$(grep -E '^type = ' "$GW_CFG" 2>/dev/null | head -1 | cut -d'"' -f2)"
_gw_base="$(grep -E '^base_url = ' "$GW_CFG" 2>/dev/null | head -1 | cut -d'"' -f2)"

if (( RED_MODE )); then
  assert_eq "openai" "$_nat_type" "RED: the native provider is mislabelled as the openai wire"
else
  assert_eq "anthropic" "$_nat_type" "native transport -> anthropic wire"
fi

# NEGATIVE CONTROL — the deepseek / kilo / zai protection, asserted mechanically:
# a router provider keeps the openai wire and an UNTOUCHED base_url in BOTH legs.
assert_eq "openai"    "$_gw_type" "router transport keeps the openai wire (deepseek/kilo/zai class)"
assert_eq "$MOCK_V1"  "$_gw_base" "router base_url is passed through verbatim — no /v1 surgery"
assert_eq "$MOCK_ROOT" "$_nat_base" "native base_url is passed through verbatim — no /v1 appended"

it "the wire each config names is a route the host actually answers (§11.4.5 runtime evidence)"
_nat_code="$(probe_wire "$_nat_base" "$_nat_type")"
_gw_code="$(probe_wire "$_gw_base" "$_gw_type")"
{ echo "--- wire reality ---"
  echo "native  base=$_nat_base type=$_nat_type -> HTTP $_nat_code"
  echo "router  base=$_gw_base type=$_gw_type -> HTTP $_gw_code"; } >> "$PROOF" 2>&1
if (( RED_MODE )); then
  assert_eq "404" "$_nat_code" "RED: the wire the native config names is a 404 on the host"
else
  assert_eq "200" "$_nat_code" "the native config's wire resolves on the host"
fi
assert_eq "200" "$_gw_code" "the router config's wire resolves on the host (both legs)"

# Control needle (§11.4.201(7)(b)): a green above must not be obtainable from a
# dead mock that never saw a request.
it "control: the mock really was driven (a green cannot come from a silent endpoint)"
grep -q '^POST /v1/' "$HIT_FILE"; assert_eq 0 $? "the mock recorded the wire probes it answered"
grep -q '^GET /v1/models' "$HIT_FILE"; assert_eq 0 $? "the mock recorded the export's model listing"

{ echo "--- mock hit log ---"; sort "$HIT_FILE" | uniq -c; } >> "$PROOF" 2>&1


# ===========================================================================
# Section 4 — D5: `kimi-providers list` renders the engine's columns UNSHIFTED
#
# The wrapper re-parses the engine's fixed-width table BY POSITION. That makes
# the engine's column order a contract, and D1 broke it: adding CHECKED between
# STATUS and LAYER left the wrapper reading `layer=$4; model=$5`, so every row
# printed the AGE under LAYER, the LAYER under STRONG_MODEL, and dropped the
# model entirely. Nothing failed — no suite asserted this command's columns at
# all (the only coverage was a symlink check), so an operator's Kimi-framed
# inventory — the one view that reports `no-twin` drift — silently relabelled
# two of its columns. This section is the missing guard: every cell of every row
# is asserted BY POSITION, so the next column change fails here instead.
# ===========================================================================
it "kimi-providers list puts every engine column under its own heading"

KIMI_SH="$SCRIPTS_DIR/kimi-providers.sh"

# A purpose-built fixture: no two cells in a row share a value, so a shift by
# one CANNOT satisfy the assertions by coincidence. That property is NOT free —
# it holds only because the claude alias is written `al-<id>` below. When this
# section was first written the alias equalled the provider id, the claim was
# therefore false for every `claude` row, and a swap of ALIAS and PROVIDER
# passed undetected at 52/0. Three records cover the
# three renderings the wrapper produces — a wired twin, an unwired one, and a
# verdict past the horizon (whose `stale:` prefix is the widest STATUS this
# table ever prints, and so the likeliest to shunt its neighbours).
rm -f "$PDIR"/*.env "$PDIR/status.json" 2>/dev/null
rm -rf "$HOME"/.kimi-prov-* 2>/dev/null
: > "$ALIAS_FILE"
for _cid in colcheck notwin oldcheck; do
  cat > "$PDIR/$_cid.env" <<ENVF
CMA_PROVIDER_ID='$_cid'
CMA_PROVIDER_KEYVAR='DUMMY_KEY'
CMA_PROVIDER_TRANSPORT='router'
CMA_PROVIDER_BASE_URL='https://example.invalid/v1'
CMA_PROVIDER_MODEL='mdl-$_cid'
CMA_PROVIDER_FAST_MODEL='fst-$_cid'
ENVF
  # `al-` PREFIX IS LOAD-BEARING, do not simplify it away. With the alias named
  # identically to its provider id, ALIAS and PROVIDER hold the same string and
  # a parser that swaps those two columns renders IDENTICAL output — the suite
  # passed 52/0 against exactly that mutation until this prefix was added. The
  # section's whole claim is that no two cells in a row share a value; this line
  # is what makes that claim true for the `claude` rows.
  printf 'alias al-%s=%s\n' "$_cid" "'cma_run_provider $_cid \"\$@\"'" >> "$ALIAS_FILE"
done
unset _cid
# Only colcheck and oldcheck are REALLY wired (alias line AND config.toml);
# notwin is the drift case the wrapper must report as `no-twin`.
for _cid in colcheck oldcheck; do
  printf 'alias kimi-%s=%s\n' "$_cid" "'cma_run_kimi_provider $_cid \"\$@\"'" >> "$ALIAS_FILE"
  mkdir -p "$HOME/.kimi-prov-$_cid"
  printf 'default_model = "mdl-%s"\nbase_url = "https://example.invalid/v1"\n' "$_cid" \
    > "$HOME/.kimi-prov-$_cid/config.toml"
done
unset _cid
_c_now="$(date -u +%s)"
_c_fresh="$(date -u -d "@$((_c_now - 120))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || date -u -r "$((_c_now - 120))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
_c_old="$(date -u -d "@$((_c_now - 400000))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
          || date -u -r "$((_c_now - 400000))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
if [[ -z "$_c_fresh" || -z "$_c_old" ]]; then
  echo "SKIP: neither GNU nor BSD date could format an epoch (§11.4.3)"; summary
fi
# Each record carries a DIFFERENT failing_layer so a column that shows "the
# layer" can be told apart from one that shows some other row's layer.
jq -n --arg f "$_c_fresh" --arg o "$_c_old" '{
  colcheck: {status:"verified", model:"mdl-colcheck", checked_at:$f, failing_layer:"semantic"},
  notwin:   {status:"verified", model:"mdl-notwin",   checked_at:$f, failing_layer:"wire"},
  oldcheck: {status:"verified", model:"mdl-oldcheck", checked_at:$o, failing_layer:"probe"}
}' > "$PDIR/status.json"

KLIST="$(bash "$KIMI_SH" list 2>/dev/null)"
ELIST="$(bash "$PROVIDERS_SH" list 2>/dev/null)"
{ echo "--- claude-providers list (engine, column contract) ---"; echo "$ELIST"
  echo "--- kimi-providers list (wrapper, re-parsed by position) ---"; echo "$KLIST"; } >> "$PROOF" 2>&1

# _kf <row> <n>  -> field n of a whitespace-split row (the wrapper's own format).
_kf() { echo "$1" | awk -v n="$2" '{print $n}'; }
_krow() { echo "$KLIST" | awk -v a="$1" -v p="$2" '$1==a && $3==p {print; exit}'; }

_hdr="$(echo "$KLIST" | head -1)"
_row_c="$(_krow claude colcheck)"
_row_k="$(_krow kimi   colcheck)"
_row_n="$(_krow kimi   notwin)"
_row_o="$(_krow kimi   oldcheck)"

if (( RED_MODE )); then
  # The RED leg is only meaningful against a tree whose ENGINE already prints
  # CHECKED — that column is what the wrapper failed to account for. Against an
  # older tree that never grew it, the shift cannot exist, and saying so is the
  # honest verdict (§11.4.6), not a defect the test pretends to find.
  if ! echo "$ELIST" | head -1 | grep -qw CHECKED; then
    _pass "RED: this engine prints no CHECKED column — the shift defect cannot exist in this tree"
  else
    assert_eq "2m"       "$(_kf "$_row_c" 5)" "RED: the AGE is printed under the LAYER heading"
    assert_eq "semantic" "$(_kf "$_row_c" 6)" "RED: the LAYER is printed under the STRONG_MODEL heading"
    assert_eq ""         "$(_kf "$_row_c" 7)" "RED: the model has no column at all — it is dropped"
  fi
else
  # The heading order IS the contract the awk indices encode.
  assert_eq "AGENT ALIAS PROVIDER STATUS CHECKED LAYER STRONG_MODEL" \
    "$(echo "$_hdr" | awk '{print $1,$2,$3,$4,$5,$6,$7}')" \
    "header names all seven columns in engine order"

  # Cell-by-cell, both agents. Every expected value is unique within its row, so
  # an off-by-one in the parser cannot satisfy any of these.
  assert_eq "claude"       "$(_kf "$_row_c" 1)" "claude row: AGENT"
  assert_eq "al-colcheck"  "$(_kf "$_row_c" 2)" "claude row: ALIAS (distinct from PROVIDER by construction)"
  assert_eq "colcheck"     "$(_kf "$_row_c" 3)" "claude row: PROVIDER"
  assert_eq "verified"     "$(_kf "$_row_c" 4)" "claude row: STATUS"
  assert_eq "2m"           "$(_kf "$_row_c" 5)" "claude row: CHECKED carries the verdict age"
  assert_eq "semantic"     "$(_kf "$_row_c" 6)" "claude row: LAYER"
  assert_eq "mdl-colcheck" "$(_kf "$_row_c" 7)" "claude row: STRONG_MODEL"

  assert_eq "kimi"          "$(_kf "$_row_k" 1)" "kimi row: AGENT"
  assert_eq "kimi-colcheck" "$(_kf "$_row_k" 2)" "kimi row: ALIAS"
  assert_eq "colcheck"      "$(_kf "$_row_k" 3)" "kimi row: PROVIDER"
  assert_eq "verified"      "$(_kf "$_row_k" 4)" "kimi row: STATUS"
  assert_eq "2m"            "$(_kf "$_row_k" 5)" "kimi row: CHECKED (twins share one record, so one age)"
  assert_eq "semantic"      "$(_kf "$_row_k" 6)" "kimi row: LAYER"
  assert_eq "mdl-colcheck"  "$(_kf "$_row_k" 7)" "kimi row: STRONG_MODEL"

  # Drift row: the wrapper's own verdict replaces STATUS/CHECKED/LAYER, and the
  # model still lands in the model column.
  assert_eq "no-twin"     "$(_kf "$_row_n" 4)" "unwired twin: STATUS says no-twin"
  assert_eq "-"           "$(_kf "$_row_n" 5)" "unwired twin: CHECKED has no verdict of its own"
  assert_eq "run-sync"    "$(_kf "$_row_n" 6)" "unwired twin: LAYER says how to repair it"
  assert_eq "mdl-notwin"  "$(_kf "$_row_n" 7)" "unwired twin: STRONG_MODEL"

  # Widest-STATUS row: `stale:verified` must not shunt its neighbours along.
  assert_eq "stale:verified" "$(_kf "$_row_o" 4)" "stale row: the widest STATUS this table prints"
  assert_eq "4d"             "$(_kf "$_row_o" 5)" "stale row: CHECKED still holds the age beside it"
  assert_eq "probe"          "$(_kf "$_row_o" 6)" "stale row: LAYER is unshifted by the wider STATUS"
  assert_eq "mdl-oldcheck"   "$(_kf "$_row_o" 7)" "stale row: STRONG_MODEL is unshifted"

  # The point of carrying CHECKED through at all: a verdict repeated in this
  # view must not lose the age that says whether to believe it (the D1 property,
  # asserted on the surface D1 was never asserted on).
  _stale_masked="$(echo "$_row_o" | sed 's/oldcheck//g; s/mdl-//g' | tr -s ' ')"
  _fresh_masked="$(echo "$_row_k" | sed 's/colcheck//g; s/mdl-//g' | tr -s ' ')"
  if [[ "$_stale_masked" == "$_fresh_masked" ]]; then
    _fail "a stale verdict renders identically to a fresh one in the kimi view" \
          "stale=[$_row_o] fresh=[$_row_k]"
  else
    _pass "a 4-day-old verdict and a 2-minute-old one render differently here too"
  fi
fi

summary
