#!/usr/bin/env bash
# test_helixllm_facade_model_reality.sh — the two HelixLLM facade aliases must
# name a model their endpoint ACTUALLY SERVES, and a route configured by
# `helixllm-export --apply` must SURVIVE the next `claude-providers sync`.
#
# TWO LIVE DEFECTS, measured 2026-09-07, both green in the suite before this file
# existed.
#
# DEFECT 1 — the facades were pinned to a model that does not exist.
#   scripts/providers/helixllm-gateway.json and helixagent-native.json both
#   declared strong/fast = "helixllm-multi", and claude-providers.sh repeated it
#   as the built-in `:=` fallback. `grep -rn helixllm-multi submodules/helix_llm`
#   returns ZERO hits: the name was invented (commit 8695577) and never served.
#   Against the live gateway, in the same second:
#     {"model":"helixllm-multi"}                     -> HTTP 503
#     {"model":"<an id from that host's /v1/models>"} -> HTTP 200
#   Neither facade could therefore ever reach `verified`, so neither was ever
#   listed by `claude-providers list` (verified-only) — invisible, not loud.
#   test_helix_endpoint_reality.sh guards the base_url of these very records
#   against exactly this class and stayed green, because it grades the PORT and
#   the SCHEME and never the MODEL.
#
# DEFECT 2 — `helixllm-export --apply` and `sync` silently undid each other.
#   Export writes per-model provider records; FR-018 deliberately keeps that
#   fan-out OUT of the default sync. cma_find_orphans then saw every one of them
#   as "no longer resolves against the current catalog/keys" and cma_demote_orphans
#   flipped it to `orphaned`, which the launch gate refuses. Measured, one sync
#   after an export + verify:
#     helixllm-anton-...-f6771589d190: verified -> orphaned
#   So a route the operator had just configured and PROVED working stopped
#   working on the next sync, every time.
#
# WHAT THIS TEST DRIVES (real code paths, no fixtures of the thing under test):
#   a REAL local model-serving mock, the REAL `helixllm-export --apply`, the REAL
#   `claude-providers verify`, and the REAL `claude-providers sync`.
#
#   1. the facade records carry the id the MOCK is serving
#   2. the invented literal appears in NO emitted record and NO written file
#   3. a pins-file model the host does NOT serve loses to what the host serves
#      (the precise behaviour that let `helixllm-multi` survive every sync)
#   4. a process-env pin still wins verbatim (operator override not regressed)
#   5. with nothing resolvable the record is REFUSED, not invented
#   6. DURABILITY ROUND TRIP: export --apply -> verify -> sync -> STILL verified
#   7. control needle (§11.4.201(7)(b)): the mock really was queried, so a green
#      cannot come from a dead endpoint quietly falling back to a pin
#
# RED_MODE (§11.4.115) — ONE source, two roles.
#   RED_MODE=1 asserts the DEFECTS ARE PRESENT; it is meant to be run against the
#   pre-fix artifact, which is what proves this test can fail:
#     CMA_TEST_SCRIPTS_DIR=<pre-fix tree> RED_MODE=1 bash test_..._reality.sh
#   RED_MODE=0 (the default, and how the suite runs it) is the standing
#   regression guard asserting the defects are ABSENT.
# Paired §1.1 mutation: restore `: "${_lgw_strong:=helixllm-multi}"` (or drop the
# CMA_PROVIDER_SOURCE skip in cma_find_orphans) -> RED_MODE=0 FAILS.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# The tree under test. Overridable so the RED leg can point at the PRE-FIX tree
# and genuinely reproduce the defect instead of merely asserting it inverted.
SCRIPTS_DIR="${CMA_TEST_SCRIPTS_DIR:-$DEFAULT_SCRIPTS_DIR}"
PROOF_DIR="$TESTS_DIR/proof"
mkdir -p "$PROOF_DIR"
PROOF="${CMA_TEST_PROOF:-$PROOF_DIR/94-helixllm-facade-model-reality.txt}"
: > "$PROOF"

RED_MODE="${RED_MODE:-0}"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e   # lib.sh sets -e; this harness asserts on failures.

command -v jq      >/dev/null 2>&1 || { echo "SKIP: jq is required";      exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 is required"; exit 0; }

PROVIDERS_SH="$SCRIPTS_DIR/claude-providers.sh"
PDIR="$HOME/.local/share/claude-multi-account/providers"
mkdir -p "$PDIR"
echo '{}' > "$PDIR/models.dev.cache.json"

KEYS="$HOME/api_keys.sh"
printf 'export HELIXLLM_GATEWAY_KEY="dummy-helix-key-never-real"\n' > "$KEYS"

# The invented name this whole file exists to keep out of the tree.
INVENTED='helixllm-multi'

# --- a REAL local HelixLLM-shaped server ------------------------------------
# /v1/models answers in the shape the serving layer really uses: a derived
# charset-safe `id`, the human-readable `model_identity` that marks it as
# LOCALLY served, and an explicit `availability: serving`. /v1/chat/completions
# answers well enough for providers-verify.sh to reach `verified` (sentinel +
# a tool call). Every /v1/models hit is recorded: that is the control needle.
SERVED_ID="helixllm-mock-qwen-test-abc123"
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
    def do_GET(self):
        if self.path.rstrip('/').endswith('/models'):
            with open(hit_file, 'a') as f:
                f.write('models-hit\n')
            self._send(200, {"object": "list", "data": [{
                "id": served_id, "object": "model", "owned_by": "llamacpp",
                "model_identity": "helixllm/mock/qwen-test",
                "host": "mock", "availability": "serving"}]})
        else:
            self.send_response(404); self.end_headers()
    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(n).decode('utf-8', 'replace')
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

# --- pins pointed at the mock ------------------------------------------------
# Shaped exactly like the tracked pins AFTER the fix: real endpoint config, and
# NO model name — because a served model is discovered, never declared.
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
unset CMA_HELIXLLM_GW_STRONG CMA_HELIXLLM_GW_FAST \
      CMA_HELIXLLM_NATIVE_STRONG CMA_HELIXLLM_NATIVE_FAST 2>/dev/null

{
  echo "=== test_helixllm_facade_model_reality.sh evidence ==="
  echo "date:        $(date -u +%FT%TZ)"
  echo "RED_MODE:    $RED_MODE   (1 = assert the defects ARE present, pre-fix tree)"
  echo "tree under test: $SCRIPTS_DIR"
  echo "mock:        $MOCK_V1   serving id: $SERVED_ID"
  echo "--- live GET $MOCK_V1/models ---"
  curl -s --max-time 8 "$MOCK_V1/models"
  echo
} >> "$PROOF" 2>&1

det() { bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_helixllm_records' 2>/dev/null; }
model_of() { jq -r --arg i "$2" '.[] | select(.provider_id==$i) | .strong_model' <<<"$1" 2>/dev/null; }

# red_expect WANT_WHEN_FIXED — the value to assert, flipped by RED_MODE.
# Used only where the pre-fix answer is a single known string.
# ===========================================================================
# 1-2. the facade model is the id the host is SERVING, never the invention
# ===========================================================================
it "the facades resolve their model from the host's own /v1/models listing"
DET="$(det)"
{ echo "--- detect_helixllm_records ---"; echo "$DET" | jq -c '.[]|{provider_id,base_url,strong_model,fast_model}'; } >> "$PROOF" 2>&1

if (( RED_MODE )); then
  assert_eq "$INVENTED" "$(model_of "$DET" helixllm-gateway)" \
    "RED: helixllm-gateway carries the invented, unservable '$INVENTED'"
  assert_eq "$INVENTED" "$(model_of "$DET" helixagent-native)" \
    "RED: helixagent-native carries the invented, unservable '$INVENTED'"
else
  assert_eq "$SERVED_ID" "$(model_of "$DET" helixllm-gateway)" \
    "helixllm-gateway strong_model is the id the host is serving"
  assert_eq "$SERVED_ID" "$(model_of "$DET" helixagent-native)" \
    "helixagent-native strong_model is the id the host is serving"
  assert_eq "$SERVED_ID" "$(jq -r '.[]|select(.provider_id=="helixllm-gateway")|.fast_model' <<<"$DET")" \
    "fast_model too (both fields were pinned to the invention, so both are graded)"
  it "the invented model name appears in NO emitted record"
  if grep -qF -- "$INVENTED" <<<"$DET"; then
    _fail "'$INVENTED' is still emitted" "$DET"
  else
    _pass "no record mentions '$INVENTED'"
  fi
fi

it "the advertised context window is the backend's real ceiling, not a 7x fiction"
# The tracked pins used to advertise 229376 for both facades, and the built-in
# `:=` defaults repeated it. Measured 2026-09-07: the model this gateway fronts
# publishes n_ctx = 32768 on its own /v1/models, and the gateway answers HTTP 413
# above that rather than truncating. CLAUDE_CODE_AUTO_COMPACT_WINDOW is derived
# from this number, so a 7x overstatement makes a session compact far too late
# and then hit a refusal it was told was impossible.
for _pin in "$SCRIPTS_DIR/providers/helixllm-gateway.json" \
            "$SCRIPTS_DIR/providers/helixagent-native.json"; do
  _ctx="$(jq -r '.context_limit // empty' "$_pin" 2>/dev/null)"
  if (( RED_MODE )); then
    assert_eq "229376" "$_ctx" "RED: $(basename "$_pin") advertises the disproven 229376"
  elif [[ "$_ctx" == "229376" ]]; then
    _fail "$(basename "$_pin") still advertises 229376" "the backend publishes n_ctx=32768"
  else
    _pass "$(basename "$_pin") advertises $_ctx (not the disproven 229376)"
  fi
done

it "control needle: the mock's /v1/models was really queried"
[[ -s "$HIT_FILE" ]]
assert_eq 0 $? "the listing was fetched (a zero here would make every assertion above vacuous)"

# ===========================================================================
# 3. a pins-file model the host does NOT serve loses to what the host serves
# ===========================================================================
# This is the precise behaviour that let `helixllm-multi` survive: a pinned name
# outranking a live listing that does not contain it. A pin is a preference;
# the serving layer is the fact.
it "a pins-file model the host does not serve is replaced by one it does"
GW_BAD="$HOME/gw-bad.json"
jq --arg m "$INVENTED" '. + {strong_model:$m, fast_model:$m}' "$GW_PINS" > "$GW_BAD"
DET_BAD="$(CMA_HELIXLLM_PINS_FILE="$GW_BAD" det)"
{ echo "--- pins pin an unserved model ---"; echo "$DET_BAD" | jq -c '.[]|{provider_id,strong_model}'; } >> "$PROOF" 2>&1
if (( RED_MODE )); then
  assert_eq "$INVENTED" "$(model_of "$DET_BAD" helixllm-gateway)" \
    "RED: the unserved pin survives the live listing (this is the defect)"
else
  assert_eq "$SERVED_ID" "$(model_of "$DET_BAD" helixllm-gateway)" \
    "the unserved pin loses to the id the host is serving"
fi

it "a pins-file model the host DOES serve is kept (a real choice is not overridden)"
GW_OK="$HOME/gw-ok.json"
jq --arg m "$SERVED_ID" '. + {strong_model:$m, fast_model:$m}' "$GW_PINS" > "$GW_OK"
assert_eq "$SERVED_ID" "$(model_of "$(CMA_HELIXLLM_PINS_FILE="$GW_OK" det)" helixllm-gateway)" \
  "a served pin is honoured"

# ===========================================================================
# 4. the documented process-env pin still wins verbatim
# ===========================================================================
it "CMA_HELIXLLM_GW_STRONG still overrides everything (operator override intact)"
DET_ENV="$(CMA_HELIXLLM_GW_STRONG='operator-said-so' det)"
assert_eq "operator-said-so" "$(model_of "$DET_ENV" helixllm-gateway)" \
  "an explicit process-env pin is never second-guessed"
if (( RED_MODE )); then
  assert_eq "$INVENTED" "$(model_of "$DET_ENV" helixagent-native)" \
    "RED: the un-overridden facade still falls back to the invention"
else
  assert_eq "$SERVED_ID" "$(model_of "$DET_ENV" helixagent-native)" \
    "and it does not leak into the other facade"
fi

# ===========================================================================
# 5. nothing resolvable -> the record is REFUSED, not invented
# ===========================================================================
it "with no live host, no catalogue and no pin: endpoint still visible, but NOT resolved"
# The record travels so the ENDPOINT stays inspectable (that configuration is
# true even while the host is down, and test_helix_endpoint_reality.sh grades
# it), but it carries status "skipped" and an empty model, so cmd_sync's
# `[[ "$status" == "resolved" ]]` guard writes no alias and no env record.
# What must never happen is a `resolved` record naming an unservable model.
DEAD_PINS="$HOME/dead.json"
sed "s#$MOCK_V1#http://127.0.0.1:1/v1#" "$GW_PINS" > "$DEAD_PINS"
DET_DEAD="$(CMA_HELIXLLM_PINS_FILE="$DEAD_PINS" \
            CMA_HELIXLLM_NATIVE_PINS_FILE="$DEAD_PINS" \
            CMA_PROVIDERS_DIR="$HOME/empty-pdir" det)"
{ echo "--- nothing resolvable ---"; echo "$DET_DEAD"; } >> "$PROOF" 2>&1
if (( RED_MODE )); then
  if grep -qF -- "$INVENTED" <<<"$DET_DEAD"; then
    _pass "RED: an unreachable host still yields a record carrying '$INVENTED'"
  else
    _fail "RED expected the invented fallback" "$DET_DEAD"
  fi
else
  assert_eq "0" "$(jq '[.[] | select(.status=="resolved")] | length' <<<"${DET_DEAD:-[]}")" \
    "NO record resolves — nothing is pinned to a name no endpoint accepts"
  assert_eq "" "$(jq -r '[.[].strong_model] | map(select(. != "")) | join(",")' <<<"${DET_DEAD:-[]}")" \
    "and no model name was invented to fill the gap"
  # Both facades are pointed at the same dead pins file here, so both records
  # carry that id; take the first rather than comparing against two lines.
  assert_eq "http://127.0.0.1:1/v1" \
    "$(jq -r '[.[]|select(.provider_id=="helixllm-gateway")|.base_url][0] // ""' <<<"${DET_DEAD:-[]}")" \
    "but the configured ENDPOINT is still visible (it is true whether or not the host is up)"
fi

# ===========================================================================
# 6. DURABILITY: export --apply -> verify -> sync -> STILL verified
# ===========================================================================
# The whole point of defect 2. Each step is the REAL subcommand.
it "helixllm-export --apply writes the per-model provider record"
# Layers 1 and 2 (existence + tool call) are graded for real against the mock.
# Layer 3 (semantic code-visibility) is deterministically made a SKIP, and
# layer 1's LLMsVerifier strategy deterministically unavailable — the same
# discipline test_helix_endpoint_reality.sh applies with CMA_VERIFIER_BIN.
# Neither is what this test grades: judging a mock's prose would measure the
# mock, and `skip` is the driver's own documented "precondition absent" value,
# which never downgrades a verdict. What IS graded is that the verdict, once
# earned, SURVIVES a sync.
export CMA_VERIFIER_BIN=/nonexistent
SEM_STUB="$HOME/semantic-skip.sh"
printf '#!/usr/bin/env bash\necho skip\n' > "$SEM_STUB"; chmod +x "$SEM_STUB"
export CMA_PROVIDERS_SEMANTIC="$SEM_STUB"
bash "$PROVIDERS_SH" helixllm-export --apply --keys-file "$KEYS" >>"$PROOF" 2>&1
assert_file "$PDIR/$SERVED_ID.env" "export --apply created $SERVED_ID.env"
assert_file_contains "$PDIR/$SERVED_ID.env" "CMA_PROVIDER_SOURCE='helixllm-export'" \
  "the provenance marker — the only thing that identifies this record's owner"

it "the exported route verifies through the real verify subcommand"
VOUT="$(bash "$PROVIDERS_SH" verify "$SERVED_ID" --keys-file "$KEYS" 2>>"$PROOF")"
assert_eq "verified" "$(printf '%s' "$VOUT" | tr -d '[:space:]')" \
  "verify reports verified against the live mock"
assert_eq "verified" "$(jq -r --arg k "$SERVED_ID" '.[$k].status' "$PDIR/status.json")" \
  "status.json records it as verified (the launch gate trusts only this)"

it "a full sync does NOT undo it — the route survives"
bash "$PROVIDERS_SH" sync --offline --no-verify --keys-file "$KEYS" >>"$PROOF" 2>&1
AFTER="$(jq -r --arg k "$SERVED_ID" '.[$k].status' "$PDIR/status.json")"
{ echo "--- status after sync ---"; jq -c --arg k "$SERVED_ID" '.[$k]' "$PDIR/status.json"; } >> "$PROOF" 2>&1
if (( RED_MODE )); then
  assert_eq "orphaned" "$AFTER" \
    "RED: sync demoted the export-written record to 'orphaned' (this is the defect)"
else
  assert_eq "verified" "$AFTER" \
    "the export-written record is STILL verified after sync (it has an owner; sync is not it)"
  assert_file "$PDIR/$SERVED_ID.env" "and its env record is still in place"
fi

it "sync still demotes a genuine orphan (the fix narrows the sweep, not disables it)"
# A record with NO owner marker whose id resolves against nothing must still be
# demoted — otherwise the fix would have traded one silent-trust bug for another.
printf "CMA_PROVIDER_ID='ghost-provider'\nCMA_PROVIDER_MODEL='m'\n" > "$PDIR/ghost-provider.env"
jq '. + {"ghost-provider":{"status":"verified","model":"m","checked_at":"x","failing_layer":""}}' \
  "$PDIR/status.json" > "$PDIR/status.json.tmp" && mv "$PDIR/status.json.tmp" "$PDIR/status.json"
bash "$PROVIDERS_SH" sync --offline --no-verify --keys-file "$KEYS" >>"$PROOF" 2>&1
assert_eq "orphaned" "$(jq -r '.["ghost-provider"].status' "$PDIR/status.json")" \
  "an unowned, unresolved record is still demoted"

echo >> "$PROOF"
echo "=== result: pass=$TESTS_PASSED fail=$TESTS_FAILED ===" >> "$PROOF"

summary
