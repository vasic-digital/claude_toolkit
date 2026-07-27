#!/usr/bin/env bash
# test_verify_scripts.sh — hermetic coverage for the two verification helpers
# that previously had ZERO tests:
#
#   * scripts/model_verify.py     — HTTP model-probe/scoring engine
#   * scripts/providers-verify.sh — provider key/model verification adapter
#
# Both scripts are fundamentally network-driven (they probe live LLM endpoints),
# so the HTTP layer is mocked out — no live network is ever touched:
#
#   model_verify.py     : py_compile (syntax), --help, argparse required-arg
#                         handling, the CMA_PROBE_KEY guard, the no-models guard
#                         (all of which return BEFORE any HTTP), its pure helper
#                         functions imported directly as a module (endpoint
#                         normalisation, anti-bluff detection, response
#                         extraction across OpenAI/Anthropic/Google shapes,
#                         tool/reasoning detection, request building, catalog
#                         enrichment, and the versioned cache round-trip), plus
#                         verify_model itself with http_post_json monkeypatched
#                         (VERIFY_OK sentinel gate, tool-calling hard gate).
#   providers-verify.sh : bash -n (syntax), unknown-arg validation, the offline
#                         "strategy 3 / no verifier binary" path, and the full
#                         strategy-2 contract (chat sentinel probe + tool-calling
#                         probe in OpenAI and Anthropic shapes, and every
#                         verified/failed/unverified branch) via a stub `curl`
#                         placed first in PATH that serves canned responses.
#
# NOT covered here (needs live providers / a real LLMsVerifier build — see
# verify_providers_live.sh): the LLMsVerifier-binary strategy 1, and real
# end-to-end probes against actual provider endpoints.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
# Keep Python from scattering __pycache__/*.pyc into the real source tree when
# the pure-function tests import model_verify; everything else stays in $HOME.
export PYTHONDONTWRITEBYTECODE=1

MODEL_VERIFY="$SCRIPTS_DIR/model_verify.py"
PROVIDERS_VERIFY="$SCRIPTS_DIR/providers-verify.sh"

HAVE_PY=0
command -v python3 >/dev/null 2>&1 && HAVE_PY=1

# pyval BODY — run a Python snippet with model_verify importable as `mv` and
# print whatever the snippet prints. Used to assert on the pure helpers.
pyval() {
  python3 -c "import sys; sys.path.insert(0, '$SCRIPTS_DIR'); import model_verify as mv
$1"
}

# ===========================================================================
# model_verify.py
# ===========================================================================

if (( HAVE_PY )); then
  it "model_verify.py compiles cleanly under python3 -W error (py_compile)"
  # Equivalent to `python3 -W error -m py_compile`, but we direct the compiled
  # output into the sandbox (cfile=) so we never write __pycache__ into the repo.
  assert_exit 0 python3 -W error -c \
    'import py_compile,sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' \
    "$MODEL_VERIFY" "$HOME/model_verify.compiled.pyc"

  it "model_verify.py imports as a module (top level is side-effect free)"
  imp="$(pyval 'print("IMPORT_OK")' 2>&1)"
  assert_eq "IMPORT_OK" "$imp" "module imports + a helper call works"

  it "model_verify.py --help exits 0 and documents its flags"
  help_out="$(python3 "$MODEL_VERIFY" --help 2>&1)"; rc=$?
  assert_eq 0 "$rc" "--help exit 0"
  echo "$help_out" | grep -q -- "--provider"; assert_eq 0 $? "--help lists --provider"
  echo "$help_out" | grep -q -- "--endpoint"; assert_eq 0 $? "--help lists --endpoint"

  it "model_verify.py errors (exit 2) when required args are missing"
  missing="$( (unset CMA_PROBE_KEY; python3 "$MODEL_VERIFY") 2>&1 )"; rc=$?
  assert_eq 2 "$rc" "argparse exit 2 on missing required args"
  echo "$missing" | grep -qi "required\|--provider\|--endpoint"; assert_eq 0 $? "usage names the required args"

  it "model_verify.py exits 1 without CMA_PROBE_KEY (key check precedes any HTTP)"
  nokey="$( (unset CMA_PROBE_KEY; python3 "$MODEL_VERIFY" \
             --provider x --endpoint http://127.0.0.1 --no-cache --models foo) 2>&1 )"; rc=$?
  assert_eq 1 "$rc" "exit 1 when CMA_PROBE_KEY unset"
  echo "$nokey" | grep -q "CMA_PROBE_KEY"; assert_eq 0 $? "error names CMA_PROBE_KEY"

  it "model_verify.py exits 1 when key is set but no models and no catalog"
  # Returns at model selection, before the ThreadPoolExecutor — so still no HTTP.
  nomodels="$( CMA_PROBE_KEY=dummy-not-real python3 "$MODEL_VERIFY" \
               --provider x --endpoint http://127.0.0.1 --no-cache 2>&1 )"; rc=$?
  assert_eq 1 "$rc" "exit 1 with no models/catalog"
  echo "$nomodels" | grep -q "no models specified"; assert_eq 0 $? "error: no models specified"

  it "normalize_endpoint_for_probe maps /anthropic -> /v1, leaves /v1/... alone"
  assert_eq "https://api.x.com/v1" \
    "$(pyval 'print(mv.normalize_endpoint_for_probe("https://api.x.com/anthropic"))')" "anthropic->v1"
  assert_eq "https://api.x.com/v1/chat/completions" \
    "$(pyval 'print(mv.normalize_endpoint_for_probe("https://api.x.com/v1/chat/completions"))')" "v1 unchanged"

  it "is_bluff_response flags empty + error-in-200-body, accepts real content, trusts non-200"
  assert_eq "True"  "$(pyval 'print(mv.is_bluff_response("",200,{})[0])')"                          "empty body is bluff"
  assert_eq "False" "$(pyval 'print(mv.is_bluff_response("VERIFY_OK",200,{})[0])')"                 "real content not bluff"
  assert_eq "True"  "$(pyval 'print(mv.is_bluff_response("hi",200,{"error":{"message":"boom"}})[0])')" "error-in-200 is bluff"
  assert_eq "False" "$(pyval 'print(mv.is_bluff_response("x",404,{})[0])')"                          "non-200 is honest failure"

  it "extract_response_content handles OpenAI, Anthropic and Google shapes"
  assert_eq "HELLO" "$(pyval 'print(mv.extract_response_content({"choices":[{"message":{"content":"HELLO"}}]},""))')" "openai shape"
  assert_eq "ANT"   "$(pyval 'print(mv.extract_response_content({"content":[{"type":"text","text":"ANT"}]},""))')"     "anthropic shape"
  assert_eq "GOO"   "$(pyval 'print(mv.extract_response_content({"candidates":[{"content":{"parts":[{"text":"GOO"}]}}]},""))')" "google shape"

  it "has_tool_call_support / has_reasoning_support read the right fields"
  assert_eq "True"  "$(pyval 'print(mv.has_tool_call_support({"choices":[{"message":{"tool_calls":[1]}}]}))')" "tool_calls present"
  assert_eq "False" "$(pyval 'print(mv.has_tool_call_support({"choices":[{"message":{"content":"x"}}]}))')"    "no tool_calls"
  assert_eq "True"  "$(pyval 'print(mv.has_reasoning_support({"choices":[{"message":{"reasoning_content":"b"}}]}))')" "reasoning_content present"

  it "build_probe_request picks the right auth header + body per endpoint"
  assert_eq "True True mid" \
    "$(pyval 'u,h,b=mv.build_probe_request("mid","https://api/v1/chat/completions","KEY"); print("Authorization" in h, h["Authorization"].startswith("Bearer"), b["model"])')" \
    "openai-compatible -> Bearer auth"
  assert_eq "True 2023-06-01" \
    "$(pyval 'u,h,b=mv.build_probe_request("mid","https://api/v1/messages","KEY"); print("x-api-key" in h, h.get("anthropic-version"))')" \
    "anthropic -> x-api-key + version"
  assert_eq "https://api.example.com/chat/completions" \
    "$(pyval 'u,h,b=mv.build_probe_request("mid","https://api.example.com","KEY"); print(u)')" \
    "unknown endpoint gets /chat/completions appended"

  it "enrich_from_catalog adds context window, free bonus, and prunes tiny models"
  assert_eq "200000 True True" \
    "$(pyval 'm=[{"model_id":"big","score":25,"capabilities":{}}]
c={"big":{"limit":{"context":200000,"output":8000},"cost":{"input":0,"output":0}}}
mv.enrich_from_catalog(m,c)
print(m[0]["capabilities"]["context_window"], m[0]["capabilities"].get("is_free"), m[0]["score"]>25)')" \
    "genuinely-free model (input AND output cost 0) enriched + scored up"
  # Reconciled to the v1.24.0 credit-aware classification (§11.4.120): a model is
  # free ONLY when input AND output cost are both 0. PARTIAL pricing (input:0 with
  # no output cost) is tier 'unknown', never free — so a subscription/plan-gated
  # {input:0} entry is never mistaken for a free model. The context-window bonus
  # still applies; only the free bonus + is_free flag do not.
  assert_eq "None unknown" \
    "$(pyval 'm=[{"model_id":"p","score":25,"capabilities":{}}]
c={"p":{"limit":{"context":200000,"output":8000},"cost":{"input":0}}}
mv.enrich_from_catalog(m,c)
print(m[0]["capabilities"].get("is_free"), m[0].get("credit_tier"))')" \
    "partial pricing (input:0 only) is unknown, never free"
  assert_eq "False True" \
    "$(pyval 'm=[{"model_id":"t","score":25,"capabilities":{},"verified":True}]
c={"t":{"limit":{"context":1000,"output":500},"cost":{"input":1}}}
mv.enrich_from_catalog(m,c)
print(m[0]["verified"], "too small" in m[0]["failure_reason"])')" \
    "sub-threshold context window unverifies the model"

  it "save_cache + load_cache round-trip a fresh cache within TTL"
  # Compare against the module's CURRENT schema version, not a hardcoded number:
  # 88b4695 (v1.24.0) bumped CACHE_VERSION 2 -> 3 when credit-aware selection
  # changed the cache semantics, and a literal '== 2' went stale with it.
  assert_eq "True True True True" \
    "$(pyval 'import os
p=os.path.join(os.environ["HOME"],"vcache.json")
mv.save_cache(p, {"prov":{"x":1}})
d=mv.load_cache(p)
print(os.path.exists(p), "prov" in d, "_cached_at" in d, d.get("_cache_version") == mv.CACHE_VERSION)')" \
    "cache writes, stamps (_cached_at + current _cache_version), and reloads"

  it "load_cache rejects pre-v2 caches (old verified-without-tools results are never replayed)"
  assert_eq "True True True" \
    "$(pyval 'import os,json
p=os.path.join(os.environ["HOME"],"vcache_old.json")
json.dump({"prov":{"x":1},"_cached_at":mv.time.time()}, open(p,"w"))
old_rejected = mv.load_cache(p) == {}
# A cache stamped with the PREVIOUS schema version must be rejected too —
# otherwise the v3 bump (88b4695) would silently replay v2 verdicts.
json.dump({"prov":{"x":1},"_cached_at":mv.time.time(),"_cache_version":mv.CACHE_VERSION-1}, open(p,"w"))
prev_rejected = mv.load_cache(p) == {}
mv.save_cache(p, {"prov":{"x":1}})
print(old_rejected, prev_rejected, "prov" in mv.load_cache(p))')" \
    "unversioned + previous-version caches -> {}; rewritten at current version -> loads"

  it "verify_model: sentinel + tool call -> verified=True"
  assert_eq "True True" \
    "$(pyval 'def fake(url, body, headers=None, timeout=30):
    if "tools" in body:
        return 200, {"choices":[{"message":{"tool_calls":[{"id":"c"}]},"finish_reason":"tool_calls"}]}, 5
    return 200, {"choices":[{"message":{"content":"VERIFY_OK"}}]}, 5
mv.http_post_json = fake
r = mv.verify_model("m","p","https://api/v1/chat/completions","k")
print(r["verified"], r["capabilities"]["tool_call"])')" \
    "chat + tools both pass -> verified"

  it "verify_model: chat OK but no tool call -> verified=False (tools are a hard gate, score still reported)"
  assert_eq "False tool calling unsupported (required by Claude Code) True" \
    "$(pyval 'mv.http_post_json = lambda url, body, headers=None, timeout=30: (200, {"choices":[{"message":{"content":"VERIFY_OK"}}]}, 5)
r = mv.verify_model("m","p","https://api/v1/chat/completions","k")
print(r["verified"], r["failure_reason"], r["score"] > 0)')" \
    "tool-less chat model is NOT verified (Claude Code is tool-driven)"

  it "verify_model: 200 without the VERIFY_OK sentinel -> anti-bluff failure"
  assert_eq "False sentinel VERIFY_OK missing from response" \
    "$(pyval 'mv.http_post_json = lambda url, body, headers=None, timeout=30: (200, {"choices":[{"message":{"content":"Hello, how can I help?"}}]}, 5)
r = mv.verify_model("m","p","https://api/v1/chat/completions","k")
print(r["verified"], r["failure_reason"])')" \
    "a reply that dodges the sentinel is a bluff, not a success"
else
  it "model_verify.py python coverage (skipped — python3 not installed)"
  _pass "SKIP: python3 absent; py_compile + import + pure-function tests not run"
fi

# ===========================================================================
# providers-verify.sh
# ===========================================================================
# Strategy 1 (LLMsVerifier binary confirmation) needs a built verifier binary
# and stays out of scope here; it lives in verify_providers_live.sh. Everything
# else IS covered hermetically: the syntax check, arg validation, the offline /
# no-binary "strategy 3" contract, and the full strategy-2 probe contract via a
# stub `curl` first in PATH (no real network).

it "providers-verify.sh passes bash -n syntax check"
assert_exit 0 bash -n "$PROVIDERS_VERIFY"

it "providers-verify.sh rejects an unknown arg (exit 2, names it on stderr)"
# Arg parsing happens before any strategy, so this is deterministic on every host.
bogus="$(bash "$PROVIDERS_VERIFY" --bogus-flag 2>&1)"; rc=$?
assert_eq 2 "$rc" "unknown arg exit 2"
echo "$bogus" | grep -q "unknown arg"; assert_eq 0 $? "stderr names the unknown arg"

# Run against a COPY inside the sandbox so the script's VERIFIER_BIN resolves
# relative to $HOME (where no submodules/LLMsVerifier exists) — making strategy 1
# deterministically unavailable regardless of whether the real repo built it.
COPY="$HOME/providers-verify-copy.sh"
cp "$PROVIDERS_VERIFY" "$COPY"

it "providers-verify.sh strategy 3 (no binary, --offline) emits 'unverified' / exit 2"
s3out="$(bash "$COPY" --provider acme --model m --key-var CMA_PV_UNSET --offline 2>"$HOME/s3.err")"; rc=$?
assert_eq 2 "$rc" "strategy-3 exit 2"
assert_eq "unverified" "$s3out" "stdout is the single word 'unverified'"
assert_file_contains "$HOME/s3.err" "LLMsVerifier" "stderr points to building the submodule"

it "providers-verify.sh --offline gates the HTTP probe even with key + base-url set"
# With a real key var AND a base-url present, only --offline should keep it from
# probing the network — proving the OFFLINE guard short-circuits strategy 2.
ofout="$(CMA_PV_KEY="not-a-real-secret" bash "$COPY" \
          --provider acme --model m --key-var CMA_PV_KEY \
          --base-url https://127.0.0.1:9 --offline 2>"$HOME/of.err")"; rc=$?
assert_eq 2 "$rc" "offline still 'unverified' (no probe attempted)"
assert_eq "unverified" "$ofout" "offline path yields 'unverified'"

it "providers-verify.sh never echoes the key value to stdout or stderr"
echo "$ofout" | grep -q "not-a-real-secret"; assert_eq 1 $? "secret absent from stdout"
assert_file_not_contains "$HOME/of.err" "not-a-real-secret" "secret absent from stderr"

# ---------------------------------------------------------------------------
# Strategy 2 (chat sentinel + tool-calling probes) via a stub `curl`.
# The stub serves canned responses selected by MOCK_CURL_SCENARIO and logs
# every request URL/body, so the whole contract runs offline. Response shape
# follows the URL the script builds: /v1/messages -> Anthropic content blocks,
# anything else -> OpenAI-compatible choices[].
# ---------------------------------------------------------------------------
MOCKBIN="$HOME/mockbin"; mkdir -p "$MOCKBIN"
cat > "$MOCKBIN/curl" <<'EOF'
#!/usr/bin/env bash
set -u
out="" body="" url=""
while (( $# )); do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -d) body="$2"; shift 2 ;;
    -H|--config|-w|--max-time) shift 2 ;;
    -s) shift ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$url" >> "${MOCK_CURL_LOG}.urls"
printf '%s\n' "$body" >> "${MOCK_CURL_LOG}.bodies"
is_tools=0; [[ "$body" == *'"tools"'* ]] && is_tools=1
code=200; resp='{}'
case "${MOCK_CURL_SCENARIO:-ok}" in
  ok)
    if [[ "$url" == */v1/messages ]]; then
      if (( is_tools )); then resp='{"content":[{"type":"tool_use","id":"t1","name":"get_weather","input":{"city":"Paris"}}]}'
      else resp='{"content":[{"type":"text","text":"VERIFY_OK"}]}'; fi
    else
      if (( is_tools )); then resp='{"choices":[{"message":{"tool_calls":[{"id":"c1","type":"function","function":{"name":"get_weather","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}'
      else resp='{"choices":[{"message":{"content":"VERIFY_OK"}}]}'; fi
    fi ;;
  no-sentinel) resp='{"choices":[{"message":{"content":"Hello, how can I help?"}}]}' ;;
  error-200)   resp='{"error":{"message":"boom"}}' ;;
  no-tools)
    if (( is_tools )); then resp='{"choices":[{"message":{"content":"It is sunny in Paris."}}]}'
    else resp='{"choices":[{"message":{"content":"VERIFY_OK"}}]}'; fi ;;
  flap-404)
    # First request 404s (bad gateway node), everything after is healthy.
    n="$(wc -l < "${MOCK_CURL_LOG}.urls" 2>/dev/null || echo 1)"
    if (( n <= 1 )); then code=404; resp='{"error":{"message":"transient node miss"}}'
    elif (( is_tools )); then resp='{"choices":[{"message":{"tool_calls":[{"id":"c1","type":"function","function":{"name":"get_weather","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}'
    else resp='{"choices":[{"message":{"content":"VERIFY_OK"}}]}'; fi ;;
  flap-sentinel)
    # First chat answer misses the sentinel (weak-model flake), retry has it.
    n="$(wc -l < "${MOCK_CURL_LOG}.urls" 2>/dev/null || echo 1)"
    if (( n <= 1 )); then resp='{"choices":[{"message":{"content":"Hello, how can I help?"}}]}'
    elif (( is_tools )); then resp='{"choices":[{"message":{"tool_calls":[{"id":"c1","type":"function","function":{"name":"get_weather","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}'
    else resp='{"choices":[{"message":{"content":"VERIFY_OK"}}]}'; fi ;;
  flap-tools)
    # First tools answer has no tool call (model discretion), retry calls it.
    nt="$(grep -c '"tools"' "${MOCK_CURL_LOG}.bodies" 2>/dev/null || echo 0)"
    if (( ! is_tools )); then resp='{"choices":[{"message":{"content":"VERIFY_OK"}}]}'
    elif (( nt <= 1 )); then resp='{"choices":[{"message":{"content":"It is sunny in Paris."}}]}'
    else resp='{"choices":[{"message":{"tool_calls":[{"id":"c1","type":"function","function":{"name":"get_weather","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}'; fi ;;
  *) code="$MOCK_CURL_SCENARIO" ;;  # numeric scenarios: bare HTTP code, empty body
esac
[[ -n "$out" ]] && printf '%s' "$resp" > "$out"
printf '%s' "$code"
EOF
chmod +x "$MOCKBIN/curl"

# pv_run SCENARIO BASEURL — run the sandboxed copy of providers-verify.sh
# against the stub curl. stdout is captured by the caller; stderr lands in
# $HOME/pv.err; request logs in $HOME/pv.urls / $HOME/pv.bodies.
pv_run() {
  rm -f "$HOME/pv.urls" "$HOME/pv.bodies"
  MOCK_CURL_SCENARIO="$1" MOCK_CURL_LOG="$HOME/pv" CMA_PV_KEY=sk-test \
    PATH="$MOCKBIN:$PATH" \
    bash "$COPY" --provider acme --model acme-big --key-var CMA_PV_KEY \
    --base-url "$2" 2>"$HOME/pv.err"
}

it "strategy 2: sentinel + tool call -> 'verified' / exit 0 (OpenAI shape)"
out="$(pv_run ok https://api.acme.test/v1)"; rc=$?
assert_eq 0 "$rc" "exit 0"
assert_eq "verified" "$out" "stdout is 'verified'"
assert_lines "$HOME/pv.urls" 2 "exactly two probes fired (chat, then tools)"
assert_eq "https://api.acme.test/v1/chat/completions" "$(sed -n 1p "$HOME/pv.urls")" \
  "base /v1 normalized, chat endpoint probed with the selected model"
sed -n 1p "$HOME/pv.bodies" | grep -q 'VERIFY_OK'; assert_eq 0 $? "probe 1 asks for the sentinel"
sed -n 2p "$HOME/pv.bodies" | grep -q '"tools"'; assert_eq 0 $? "probe 2 carries the tools payload"
grep -qs 'sk-test' "$HOME/pv.urls" "$HOME/pv.bodies" "$HOME/pv.err"; assert_eq 1 $? "key absent from URL, bodies and stderr"

it "strategy 2: 200 but sentinel missing -> 'failed' / exit 1 (bluff)"
out="$(pv_run no-sentinel https://api.acme.test/v1)"; rc=$?
assert_eq 1 "$rc" "exit 1"
assert_eq "failed" "$out" "stdout is 'failed'"
assert_file_contains "$HOME/pv.err" "VERIFY_OK" "reason names the missing sentinel"

it "strategy 2: HTTP 402 -> 'failed' / exit 1 (billing is definitive)"
out="$(pv_run 402 https://api.acme.test/v1)"; rc=$?
assert_eq 1 "$rc" "exit 1"
assert_eq "failed" "$out" "stdout is 'failed'"
assert_lines "$HOME/pv.urls" 1 "tool probe never fires after a definitive chat failure"

it "strategy 2: HTTP 429 -> 'unverified' / exit 2 (transient)"
out="$(pv_run 429 https://api.acme.test/v1)"; rc=$?
assert_eq 2 "$rc" "exit 2"
assert_eq "unverified" "$out" "stdout is 'unverified'"

it "strategy 2: HTTP 400 -> 'failed' / exit 1 (model rejected is definitive)"
out="$(pv_run 400 https://api.acme.test/v1)"; rc=$?
assert_eq 1 "$rc" "exit 1"
assert_eq "failed" "$out" "stdout is 'failed'"

it "strategy 2: HTTP 412 -> 'failed' / exit 1 (account suspended is definitive)"
out="$(pv_run 412 https://api.acme.test/v1)"; rc=$?
assert_eq 1 "$rc" "exit 1"
assert_eq "failed" "$out" "stdout is 'failed'"
assert_lines "$HOME/pv.urls" 2 "flappy code retried exactly once before failing"

it "strategy 2: persistent 404 -> 'failed' after exactly one retry"
out="$(pv_run 404 https://api.acme.test/v1)"; rc=$?
assert_eq 1 "$rc" "exit 1"
assert_eq "failed" "$out" "stdout is 'failed'"
assert_lines "$HOME/pv.urls" 2 "404 retried once, then definitive"

it "strategy 2: transient 404 then healthy -> 'verified' (retry absorbs gateway flap)"
out="$(pv_run flap-404 https://api.acme.test/v1)"; rc=$?
assert_eq 0 "$rc" "exit 0"
assert_eq "verified" "$out" "stdout is 'verified'"
assert_lines "$HOME/pv.urls" 3 "chat 404 + chat retry + tools probe = 3 requests"

it "strategy 2: HTTP 402 is NOT retried (billing is deterministic)"
out="$(pv_run 402 https://api.acme.test/v1)"; rc=$?
assert_eq 1 "$rc" "exit 1"
assert_lines "$HOME/pv.urls" 1 "no retry on 402"

it "strategy 2: chat OK but no tool call on both attempts -> 'failed' / exit 1 (tool support is required)"
out="$(pv_run no-tools https://api.acme.test/v1)"; rc=$?
assert_eq 1 "$rc" "exit 1"
assert_eq "failed" "$out" "stdout is 'failed'"
assert_file_contains "$HOME/pv.err" "tool" "reason explains tool calling is required"
assert_lines "$HOME/pv.urls" 3 "chat probe + two tool-call attempts"

it "strategy 2: sentinel flake then pass -> 'verified' (one retry absorbs weak-model flake)"
out="$(pv_run flap-sentinel https://api.acme.test/v1)"; rc=$?
assert_eq 0 "$rc" "exit 0"
assert_eq "verified" "$out" "stdout is 'verified'"
assert_lines "$HOME/pv.urls" 3 "two chat attempts + one tools probe"

it "strategy 2: tool-call flake then pass -> 'verified' (one retry absorbs model discretion)"
out="$(pv_run flap-tools https://api.acme.test/v1)"; rc=$?
assert_eq 0 "$rc" "exit 0"
assert_eq "verified" "$out" "stdout is 'verified'"
assert_lines "$HOME/pv.urls" 3 "chat probe + two tool-call attempts"

it "strategy 2: error object in a 200 body -> 'failed' / exit 1"
out="$(pv_run error-200 https://api.acme.test/v1)"; rc=$?
assert_eq 1 "$rc" "exit 1"
assert_eq "failed" "$out" "stdout is 'failed'"

it "strategy 2: /anthropic base -> Anthropic shape POSTed under the KEPT /anthropic prefix"
out="$(pv_run ok https://api.native.test/anthropic)"; rc=$?
assert_eq 0 "$rc" "exit 0"
assert_eq "verified" "$out" "stdout is 'verified'"
assert_eq "https://api.native.test/anthropic/v1/messages" "$(sed -n 1p "$HOME/pv.urls")" \
  "/anthropic prefix kept, native /v1/messages probed beneath it"
sed -n 2p "$HOME/pv.bodies" | grep -q '"input_schema"'; assert_eq 0 $? "anthropic tools shape (input_schema) sent"
sed -n 2p "$HOME/pv.bodies" | grep -q '"type":"function"'; assert_eq 1 $? "OpenAI tools shape NOT sent"

it "strategy 2: /anthropic base with trailing /v1 -> no doubled version segment"
out="$(pv_run ok https://api.native.test/anthropic/v1)"; rc=$?
assert_eq 0 "$rc" "exit 0"
assert_eq "https://api.native.test/anthropic/v1/messages" "$(sed -n 1p "$HOME/pv.urls")" \
  "trailing /v1 collapsed before appending /v1/messages"

it "strategy 2: versioned non-v1 base (/paas/v4) -> only /chat/completions appended"
out="$(pv_run ok https://api.zed.test/api/coding/paas/v4)"; rc=$?
assert_eq 0 "$rc" "exit 0"
assert_eq "verified" "$out" "stdout is 'verified'"
assert_eq "https://api.zed.test/api/coding/paas/v4/chat/completions" "$(sed -n 1p "$HOME/pv.urls")" \
  "no bogus /v1 inserted into an already-versioned path"

it "strategy 2: base already ending in /chat/completions -> used verbatim"
out="$(pv_run ok https://api.direct.test/v1/chat/completions)"; rc=$?
assert_eq 0 "$rc" "exit 0"
assert_eq "https://api.direct.test/v1/chat/completions" "$(sed -n 1p "$HOME/pv.urls")" \
  "full chat endpoint passed through unchanged"

summary
