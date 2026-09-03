#!/usr/bin/env bash
# test_helixllm_model_export.sh — per-model-per-host HelixLLM provider export.
#
# Covers three tasks that all land in scripts/claude-providers.sh:
#
#   T047  the HelixLLM detector fans out from ONE record per instance to ONE
#         RECORD PER MODEL PER HOST, driven by each host's live /v1/models.
#   T048  the export is IDEMPOTENT: re-running UPDATES the existing catalogue
#         entries instead of appending duplicates. Stable key = the published
#         `id` (derived, charset-safe, unique per model per host).
#   T044  on-demand retrieval (FR-018): `claude-providers helixllm-export`
#         lets a user obtain the configuration and apply it THEMSELVES
#         (--apply), rather than waiting for — or being surprised by — an
#         automatic sync writing their alias file behind their back.
#
# WHY EACH ASSERTION EXISTS (anti-bluff; every case below can genuinely fail):
#
#  * IDENTIFIER SAFETY. HelixLLM publishes BOTH `id` (derived, charset-safe)
#    and `model_identity` (`helixllm/<host>/<model>[:<variant>]`). The identity
#    contains `/` and `:`, which BOTH toolkit validators reject on purpose —
#    the provider-id charset guard in lib.sh is a shell-injection control (the
#    id "is interpolated into the alias body and re-parsed when the alias is
#    invoked"). This test feeds the exporter a HOSTILE id containing `;rm -rf`
#    and asserts it is DROPPED, and it runs every exported id through the REAL
#    lib.sh validators. Widening a validator to make a name fit would be a
#    security regression, so it must never be the way this passes.
#
#  * IDENTITY AS A VALUE. `model_identity` must survive into the catalogue as
#    DATA and must never become an alias name or a provider id.
#
#  * IDENTITY FIDELITY (CASE 6). The identity must arrive BYTE-FOR-BYTE as the
#    host published it. The corpus therefore contains an identity with a real
#    BACKSLASH in it: reading the listing through jq's `@tsv` silently doubled
#    it, and the serving side treats `\` as its own escape character, so the
#    doubled form no longer round-trips. A corpus with no backslash in it is
#    exactly why that defect survived, so the fixture IS the test.
#
#  * WITHHELD OPTIONS (CASE 8). `_CMA_HELIXLLM_SERVING_JQ` is ONE definition
#    doing TWO jobs — choosing what is exported, and deciding whether a host
#    proved it is SERVING (gate 2 of the retirement sweep). Every other case
#    here exercises only its `model_identity` clause; its `availability` clause
#    could be DELETED and this file still passed 71/0, measured. A withheld
#    option now carries `model_identity`, so without that clause it would be
#    exported as a usable alias for a model the host is refusing to serve AND
#    counted as proof of serving — reopening the data-loss door CASE 7 closed.
#    CASE 8 feeds it `availability:"withheld"` with a `withheld_reason`, and
#    reads the filter OUT OF the script rather than restating it, so the
#    assertion cannot drift from the definition it is about.
#
#  * REMOTE VENDOR MODELS. HelixLLM deliberately omits `model_identity` for
#    remote vendor models — that omission is the ONLY signal distinguishing a
#    locally-served model from a passthrough. A vendor model exported as a
#    local HelixLLM provider would point an alias at a model this host does not
#    serve, so the exclusion is asserted directly.
#
#  * UNREACHABLE HOSTS. A host that does not answer must contribute NOTHING —
#    never an entry that a user would read as available.
#
#  * CREDENTIAL CORRECTNESS (CASE 5). `/v1/models` is guarded by one
#    middleware, and it accepts exactly one credential: an entry from the
#    server's configured API-key list. The gateway key IS that credential, so
#    the mock servers record the Authorization header and this test asserts the
#    gateway key arrives. The discovery secret is NOT that credential — no HTTP
#    middleware on the server reads it at all — so the test also exports one
#    and asserts it reaches NO server and NO written file. Both halves are
#    needed: the positive one proves the request is authenticated at all, the
#    negative one proves we stopped shipping a credential to endpoints that
#    cannot use it.
#
#  * CONVERGENCE AND ITS SAFETY GATES (CASE 7). `--apply` must make the
#    configuration MATCH the catalogue, so a model the host stopped serving
#    stops being invocable. Deleting from a user's configuration is the
#    dangerous direction, so the same case asserts the gates that bound it, and
#    what those gates require is POSITIVE EVIDENCE THE HOST IS SERVING — not
#    merely that it replied. Kept, therefore: a provider whose host was
#    UNREACHABLE (a sleeping laptop must not wipe a working config); a provider
#    whose host REPLIED WHILE SERVING NOTHING, which is how a HelixLLM answers
#    while its backend is still loading and how it answers if it truly stopped
#    serving everything, indistinguishably; a provider whose host listed only
#    REMOTE VENDOR passthroughs, which stay reachable while the local backend
#    is down; and any provider this tool did not create. Retired, therefore:
#    only a model absent from a listing that named other models the host IS
#    serving. Both directions are asserted, so neither a too-eager sweep nor a
#    sweep that has quietly stopped retiring anything can pass.
#
# RED (pre-implementation): `helixllm-export` does not exist; the catalogue is
#   never written and every case below fails.
# GREEN (post): all cases pass.
# Paired 1.1 mutations, one per defect this file guards:
#   * make the catalogue merge APPEND instead of UPDATE -> the idempotency
#     cases fail (entry count doubles / duplicate ids appear).
#   * read the model listing back through `@tsv` -> CASE 6 fails (the
#     backslash identity comes back doubled).
#   * send the discovery secret as the Bearer token again -> CASE 5 fails on
#     both the gateway-key assertion and the secret-containment assertion.
#   * drop the retirement sweep -> CASE 7's convergence assertions fail;
#     drop its unreachable-host gate -> CASE 7's survival assertions fail.
#   * revert gate 2 to "the host answered" (drop _CMA_HELIXLLM_SERVING_JQ from
#     the host-evidence check) -> the empty-listing and vendor-only survival
#     assertions fail: a host mid-restart deletes the user's config again.
#   * make gate 2 reject every host (never populate hosts_serving) -> the
#     genuine-withdrawal assertions fail: nothing is ever retired, proving the
#     survival assertions above cannot be satisfied by disabling retirement.
#   * delete the `availability` clause from _CMA_HELIXLLM_SERVING_JQ -> CASE 8
#     fails: the derived-filter assertion counts the withheld entry as kept,
#     the withheld model appears in the catalogue and as an env record, and
#     beta is reported as SERVING on a listing of nothing but a withheld
#     option — so the retirement sweep would act on a backend that is refusing
#     to serve. (Before CASE 8 existed this mutation changed no result here.)
#   * make that clause reject everything (e.g. require an availability field
#     that is never sent) -> CASE 8's serving-sibling assertions fail: the
#     sibling is not exported and the withdrawn model is never retired.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
PROOF_DIR="$TESTS_DIR/proof"
mkdir -p "$PROOF_DIR"
PROOF="$PROOF_DIR/97-helixllm-model-export.txt"
: > "$PROOF"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e   # lib.sh sets -e; the harness asserts on failures, so relax it.

PROVIDERS_SH="$SCRIPTS_DIR/claude-providers.sh"
PDIR="$HOME/.local/share/claude-multi-account/providers"
mkdir -p "$PDIR"
echo '{}' > "$PDIR/models.dev.cache.json"

CATALOGUE="$PDIR/helixllm-models.json"

# The gateway API key. This is the credential /v1/models actually accepts, and
# the same key the applied provider records use at launch against the same
# base_url — so asking for the model list with it creates no new trust.
GWKEY="dummy-gateway-key-never-real"
KEYS="$HOME/api_keys.sh"
cat > "$KEYS" <<SH
export HELIXLLM_GATEWAY_KEY="$GWKEY"
SH

# The discovery pre-shared secret. It is deliberately SET for the whole run:
# the assertions below prove it now travels NOWHERE — not to a server, not into
# a written file. (It is a fleet-wide trust credential consumed by the
# discovery client's own attestation path; no HTTP middleware on the model
# endpoint reads it, so sending it there disclosed it for nothing.)
SECRET="psk-DO-NOT-SEND-8f31c0aa"
export HELIXLLM_DISCOVERY_SECRET="$SECRET"

# --- two REAL /v1/models servers (two hosts) + one dead port ----------------
# Each server records every hit AND the Authorization header it received, and
# re-reads its model list from a FILE on every request so a test can change what
# a host serves mid-run (needed for the convergence case). Creating the server's
# "down" file makes it answer 503 — a host that has stopped answering, without
# the port churn of killing and rebinding a listener.
start_models_server() {   # $1=port-file $2=hit-file $3=models-file $4=down-file
  python3 - "$1" "$2" "$3" "$4" >/dev/null 2>&1 <<'PY' &
import http.server, socketserver, sys, json, os
port_file, hit_file, models_file, down_file = sys.argv[1:5]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if os.path.exists(down_file):
            self.send_response(503); self.end_headers(); return
        if self.path.rstrip('/').endswith('/models'):
            with open(hit_file, 'a') as f:
                f.write('hit auth=%s\n' % self.headers.get('Authorization', '<none>'))
            data = json.load(open(models_file))
            body = {"object": "list", "data": data}
            if not data:
                # Faithful to the real gateway: HandleListModels attaches this
                # reason whenever a backend is configured but Brain.Models() is
                # empty -- which is what a host answers while its backend is
                # still LOADING (llama.cpp /health is 503 during the load, so
                # the option is dropped as unavailable). The identical string
                # is sent when a host has genuinely stopped serving everything,
                # which is exactly why it cannot be read as either.
                body["reason"] = ("a model-serving backend is configured but "
                                  "is currently serving no models")
            payload = json.dumps(body).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        else:
            self.send_response(404); self.end_headers()
    def log_message(self, *a):
        pass
srv = socketserver.TCPServer(('127.0.0.1', 0), H)
open(port_file, 'w').write(str(srv.server_address[1]))
srv.serve_forever()
PY
  echo $!
}

HOSTILE_ID='evil;rm -rf /tmp/pwned'
# An identity carrying a REAL backslash. Built through jq rather than written as
# a JSON literal so the byte that matters is unambiguous: this shell string
# holds exactly one backslash, and jq emits exactly the JSON escape for it.
BS_IDENTITY='helixllm/alpha/org\llama3:8b'
BS_ID='helixllm-org-llama3-bbccddeeff00'

# Host ALPHA: 4 local models (model_identity present, one of them carrying a
# backslash), 1 remote vendor model (no model_identity -> must be excluded),
# 1 hostile id (must be rejected).
MODELS_A_FILE="$HOME/.models_a.json"
jq -n --arg hostile "$HOSTILE_ID" --arg bsid "$BS_ID" --arg bs "$BS_IDENTITY" '
 [ {id:"helixllm-llama3-8b-a1b2c3d4e5f6",       object:"model", owned_by:"helixllm",
    model_identity:"helixllm/alpha/llama3:8b"},
   {id:"helixllm-qwen3-coder-30b-0f1e2d3c4b5a", object:"model", owned_by:"helixllm",
    model_identity:"helixllm/alpha/qwen3-coder:30b"},
   {id:"helixllm-mistral-7b-998877665544",      object:"model", owned_by:"helixllm",
    model_identity:"helixllm/alpha/mistral:7b"},
   {id:$bsid,                                   object:"model", owned_by:"helixllm",
    model_identity:$bs},
   {id:"gpt-4o",                                object:"model", owned_by:"openai"},
   {id:$hostile,                                object:"model", owned_by:"helixllm",
    model_identity:"helixllm/alpha/evil"} ]' > "$MODELS_A_FILE"

# Host BETA: 2 local models.
MODELS_B_FILE="$HOME/.models_b.json"
cat > "$MODELS_B_FILE" <<'JSON'
[
 {"id":"helixllm-phi4-14b-aabbccddeeff","object":"model","owned_by":"helixllm",
  "model_identity":"helixllm/beta/phi4:14b"},
 {"id":"helixllm-gemma3-27b-112233445566","object":"model","owned_by":"helixllm",
  "model_identity":"helixllm/beta/gemma3:27b"}
]
JSON

PORT_A="$HOME/.srv_a_port"; HIT_A="$HOME/.srv_a_hits"; DOWN_A="$HOME/.srv_a_down"; : > "$HIT_A"
PORT_B="$HOME/.srv_b_port"; HIT_B="$HOME/.srv_b_hits"; DOWN_B="$HOME/.srv_b_down"; : > "$HIT_B"
SRV_A=$(start_models_server "$PORT_A" "$HIT_A" "$MODELS_A_FILE" "$DOWN_A")
SRV_B=$(start_models_server "$PORT_B" "$HIT_B" "$MODELS_B_FILE" "$DOWN_B")
trap 'kill "$SRV_A" "$SRV_B" 2>/dev/null; cleanup_sandbox' EXIT
for _ in $(seq 1 60); do [[ -s "$PORT_A" && -s "$PORT_B" ]] && break; sleep 0.1; done
PA="$(cat "$PORT_A" 2>/dev/null)"; PB="$(cat "$PORT_B" 2>/dev/null)"
[[ -n "$PA" && -n "$PB" ]] || { echo "FATAL: mock servers did not start" >&2; exit 1; }

# A deliberately DEAD host: bind a socket, read its port, close it. Nothing is
# listening there, so the exporter must treat it as unavailable.
DEAD_PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"

BASE_A="http://127.0.0.1:$PA/v1"
BASE_B="http://127.0.0.1:$PB/v1"
BASE_DEAD="http://127.0.0.1:$DEAD_PORT/v1"

export CMA_HELIXLLM_HOSTS="$BASE_A $BASE_B $BASE_DEAD"
export CMA_HELIXLLM_HTTP_TIMEOUT=5

{
  echo "=== test_helixllm_model_export.sh evidence ==="
  echo "date: $(date -u +%FT%TZ)"
  echo "host alpha: $BASE_A   host beta: $BASE_B   dead: $BASE_DEAD"
  echo "--- live GET $BASE_A/models ---"; curl -s --max-time 5 "$BASE_A/models"; echo
  echo "--- live GET $BASE_B/models ---"; curl -s --max-time 5 "$BASE_B/models"; echo
} >> "$PROOF" 2>&1

# ===========================================================================
# CASE 1 — on-demand export (T044) fans out one entry per model per host (T047)
# ===========================================================================
it "helixllm-export runs on demand and writes a catalogue"
bash "$PROVIDERS_SH" helixllm-export --keys-file "$KEYS" >>"$PROOF" 2>&1
assert_eq 0 $? "helixllm-export exits cleanly"
assert_file "$CATALOGUE" "per-model catalogue written"

{ echo "--- catalogue after first export ---"; cat "$CATALOGUE" 2>/dev/null; echo; } >> "$PROOF" 2>&1

it "control needle: both live hosts were really queried, carrying the gateway key"
[[ -s "$HIT_A" && -s "$HIT_B" ]]
assert_eq 0 $? "each live host received >=1 /v1/models request"
grep -q "auth=Bearer $GWKEY" "$HIT_A"
assert_eq 0 $? "host alpha received the gateway API key as a Bearer header"
grep -q "auth=Bearer $GWKEY" "$HIT_B"
assert_eq 0 $? "host beta received the gateway API key as a Bearer header"

it "one entry per model per host (T047)"
assert_jq "$CATALOGUE" '.entries | length' 6 \
  "6 entries = 4 local models on alpha + 2 on beta"
assert_jq "$CATALOGUE" '[.entries[] | select(.base_url|test("'"$PA"'"))] | length' 4 \
  "alpha contributes 4 entries"
assert_jq "$CATALOGUE" '[.entries[] | select(.base_url|test("'"$PB"'"))] | length' 2 \
  "beta contributes 2 entries"
assert_jq "$CATALOGUE" '[.entries[].id] | (length == (unique|length))' true \
  "every catalogue id is distinct"

it "remote vendor models (no model_identity) are NOT exported as local providers"
assert_jq "$CATALOGUE" '[.entries[] | select(.id=="gpt-4o")] | length' 0 \
  "the vendor passthrough model is excluded"

it "an unreachable host contributes nothing and is never presented as available"
assert_jq "$CATALOGUE" '[.entries[] | select(.base_url|test("'"$DEAD_PORT"'"))] | length' 0 \
  "the dead host produced no entries"
assert_file_not_contains "$CATALOGUE" ":$DEAD_PORT" \
  "the dead host's endpoint appears nowhere in the catalogue"

# ===========================================================================
# CASE 2 — identifier safety: the published `id` is used, the identity is data
# ===========================================================================
it "every exported id satisfies BOTH real lib.sh validators, unmodified"
_bad_alias=0 _bad_charset=0
while read -r _eid; do
  [[ -n "$_eid" ]] || continue
  ( cma_validate_alias "$_eid" ) >/dev/null 2>&1 || _bad_alias=$((_bad_alias+1))
  case "$_eid" in ''|*[!A-Za-z0-9._-]*) _bad_charset=$((_bad_charset+1)) ;; esac
done < <(jq -r '.entries[].id' "$CATALOGUE" 2>/dev/null)
assert_eq 0 "$_bad_alias"   "no exported id is rejected by the real cma_validate_alias"
assert_eq 0 "$_bad_charset" "no exported id violates the provider-id charset guard"

it "a hostile model id is DROPPED, never written anywhere"
assert_file_not_contains "$CATALOGUE" "rm -rf" \
  "the hostile id never reaches the catalogue"
( cma_validate_alias "$HOSTILE_ID" ) >/dev/null 2>&1
assert_eq 1 $? "control: the hostile id really is rejected by cma_validate_alias (so the drop is meaningful)"

it "the human-readable identity travels as a VALUE, never as an identifier"
assert_jq "$CATALOGUE" '[.entries[] | select(.model_identity|startswith("helixllm/"))] | length' 6 \
  "every entry carries its helixllm/<host>/<model> identity as data"
assert_jq "$CATALOGUE" '[.entries[] | select(.id|test("[/:]"))] | length' 0 \
  "no entry uses the identity (or anything containing / or :) as its id"

# ===========================================================================
# CASE 3 — idempotency (T048): re-running UPDATES, never duplicates
# ===========================================================================
it "re-export updates existing entries instead of appending duplicates"
FIRST_SEEN="$(jq -r '.entries[0].first_seen' "$CATALOGUE" 2>/dev/null)"
IDS_BEFORE="$(jq -rS '[.entries[].id]|sort|join(",")' "$CATALOGUE" 2>/dev/null)"
bash "$PROVIDERS_SH" helixllm-export --keys-file "$KEYS" >>"$PROOF" 2>&1
bash "$PROVIDERS_SH" helixllm-export --keys-file "$KEYS" >>"$PROOF" 2>&1
{ echo "--- catalogue after three exports ---"; cat "$CATALOGUE" 2>/dev/null; echo; } >> "$PROOF" 2>&1
assert_jq "$CATALOGUE" '.entries | length' 6 \
  "still 6 entries after three exports (updated, not appended)"
assert_jq "$CATALOGUE" '[.entries[].id] | (length == (unique|length))' true \
  "still no duplicate ids after three exports"
assert_eq "$IDS_BEFORE" "$(jq -rS '[.entries[].id]|sort|join(",")' "$CATALOGUE" 2>/dev/null)" \
  "the id set is unchanged across re-exports"
assert_eq "$FIRST_SEEN" "$(jq -r '.entries[0].first_seen' "$CATALOGUE" 2>/dev/null)" \
  "first_seen is PRESERVED on update (proving an update, not a replace-by-append)"

# ===========================================================================
# CASE 4 — apply on demand (FR-018), and only on demand
# ===========================================================================
it "without --apply nothing else is touched; with --apply the config is written"
_env_before="$(find "$PDIR" -maxdepth 1 -name '*.env' | wc -l)"
bash "$PROVIDERS_SH" helixllm-export --apply --keys-file "$KEYS" >>"$PROOF" 2>&1
assert_eq 0 $? "helixllm-export --apply exits cleanly"
_env_after="$(find "$PDIR" -maxdepth 1 -name '*.env' | wc -l)"
[[ "$_env_after" -ge $(( _env_before + 6 )) ]]
assert_eq 0 $? "--apply wrote a provider env record per exported model (before=$_env_before after=$_env_after)"
_first_id="$(jq -r '.entries[0].id' "$CATALOGUE")"
assert_file "$PDIR/$_first_id.env" "env record for the first exported model"
assert_file_contains "$PDIR/$_first_id.env" "CMA_PROVIDER_MODEL='$_first_id'" \
  "the env record sends the PUBLISHED id as the model name"

it "--apply is idempotent too: re-applying updates the same records"
bash "$PROVIDERS_SH" helixllm-export --apply --keys-file "$KEYS" >>"$PROOF" 2>&1
_env_again="$(find "$PDIR" -maxdepth 1 -name '*.env' | wc -l)"
assert_eq "$_env_after" "$_env_again" "re-applying created no additional env records"
assert_jq "$CATALOGUE" '.entries | length' 6 "catalogue still holds exactly 6 entries"

# ===========================================================================
# CASE 5 — the export sends the credential the endpoint accepts, and only that
#
# /v1/models is guarded by a single middleware that compares the Bearer token
# against the server's configured API-key list and nothing else. So the gateway
# key must arrive, and the discovery secret — which no HTTP middleware on that
# server reads — must not be transmitted at all, nor written into anything the
# export produces.
# ===========================================================================
it "the gateway key is what reaches the wire; the discovery secret is not"
# Reset the recorders so this window contains ONLY the exporter's own requests.
# (The test itself probes /models with a plain curl for the evidence file; those
# hits are legitimately unauthenticated and must not be counted as the
# exporter's.)
: > "$HIT_A"; : > "$HIT_B"
bash "$PROVIDERS_SH" helixllm-export --keys-file "$KEYS" >>"$PROOF" 2>&1
assert_file_contains "$HIT_A" "auth=Bearer $GWKEY" \
  "alpha's recorded Authorization header carries the gateway key"
assert_file_not_contains "$HIT_A" "$SECRET" \
  "the discovery secret was never sent to alpha"
assert_file_not_contains "$HIT_B" "$SECRET" \
  "the discovery secret was never sent to beta"
# CONTROL: every request in this window was authenticated with the gateway key.
# Comparing the two counts (rather than asserting "no <none> appears") is what
# makes this fail if the credential were dropped for some hosts but not others.
_tot="$(grep -c 'hit auth=' "$HIT_A" 2>/dev/null)"
_keyed="$(grep -c "auth=Bearer $GWKEY" "$HIT_A" 2>/dev/null)"
[[ "${_tot:-0}" -ge 1 ]]
assert_eq 0 $? "the exporter really issued at least one request in this window (tot=${_tot:-0})"
assert_eq "${_tot:-0}" "${_keyed:-0}" \
  "every request the exporter made carried the gateway key"

it "with NO gateway key configured, no Authorization header is sent at all"
: > "$HIT_A"
: > "$HOME/nokeys.sh"
bash "$PROVIDERS_SH" helixllm-export --keys-file "$HOME/nokeys.sh" >>"$PROOF" 2>&1
assert_file_contains "$HIT_A" "auth=<none>" \
  "an open-access host is queried with no credential rather than a useless one"
assert_file_not_contains "$HIT_A" "$SECRET" \
  "and still no discovery secret on the wire"
# Restore the keyed, applied state for the cases below.
bash "$PROVIDERS_SH" helixllm-export --apply --keys-file "$KEYS" >>"$PROOF" 2>&1

it "the discovery pre-shared secret is in NO exported artefact"
# POSITIVE EVIDENCE FIRST. A grep that crashed — or that was pointed at an empty
# directory — returns exactly the same "no matches" as a genuinely clean sweep,
# so "found no leaks" proves nothing on its own. Assert how many files were
# really examined, and that the sweep exited cleanly, BEFORE claiming zero leaks.
_scanned=()
while IFS= read -r _f; do _scanned+=("$_f"); done < <(find "$PDIR" -maxdepth 1 -type f | sort)
[[ -f "$ALIAS_FILE" ]] && _scanned+=("$ALIAS_FILE")
[[ ${#_scanned[@]} -ge 7 ]]
assert_eq 0 $? "the sweep really examined the exported files (${#_scanned[@]} scanned; the catalogue + 6 env records at least)"
_leaks="$(grep -lF -- "$SECRET" "${_scanned[@]}")"; _leak_rc=$?
# grep: 0 = a match (a leak), 1 = no match (clean), >1 = the sweep itself failed.
[[ $_leak_rc -le 1 ]]
assert_eq 0 $? "the sweep ran without error (grep rc=$_leak_rc — an rc of 2 would make an empty result meaningless)"
assert_eq "" "$_leaks" "no exported file under $PDIR (or the alias file) contains the secret"
assert_file_not_contains "$CATALOGUE" "$SECRET" "the catalogue does not carry the secret"

# ===========================================================================
# CASE 6 — the identity arrives byte-for-byte as the host published it
#
# The corpus deliberately contains an identity with a real backslash in it. A
# reader that applies an escaping format (jq's @tsv) and never unescapes turns
# `org\llama3` into `org\\llama3` — a different string, which the serving side's
# own parser (where `\` is the escape character) no longer round-trips.
# ===========================================================================
it "an identity containing a backslash survives the export unchanged"
# Control first: prove the fixture really does contain one backslash, so a pass
# cannot come from a corpus that never exercised the path.
_served="$(curl -s --max-time 5 "$BASE_A/models" | jq -r --arg i "$BS_ID" '.data[]|select(.id==$i)|.model_identity')"
assert_eq "$BS_IDENTITY" "$_served" \
  "control: the host really serves the backslash-bearing identity"
assert_eq 1 "$(printf '%s' "$_served" | tr -cd '\\' | wc -c | tr -d ' ')" \
  "control: that identity carries exactly ONE backslash on the wire"

_stored="$(jq -r --arg i "$BS_ID" '.entries[]|select(.id==$i)|.model_identity' "$CATALOGUE")"
assert_eq "$BS_IDENTITY" "$_stored" \
  "the catalogue stores the identity exactly as served (no doubled backslash)"
assert_eq 1 "$(printf '%s' "$_stored" | tr -cd '\\' | wc -c | tr -d ' ')" \
  "the stored identity still carries exactly ONE backslash, not two"

it "ordinary org/model and hf.co/... shapes are unaffected too"
assert_jq "$CATALOGUE" \
  '[.entries[]|select(.model_identity=="helixllm/alpha/qwen3-coder:30b")]|length' 1 \
  "a slash+colon identity round-trips unchanged"

# ===========================================================================
# CASE 7 — --apply CONVERGES, and the gates that make removal safe
# ===========================================================================
it "control: the records this case is about exist before anything is withdrawn"
# A hand-authored provider in the same directory, pointing at the SAME live host
# — the worst case for a sweep that keyed off anything but provenance.
cat > "$PDIR/hand-authored-thing.env" <<EOF
CMA_PROVIDER_ID='hand-authored-thing'
CMA_PROVIDER_BASE_URL='$BASE_B'
CMA_PROVIDER_MODEL='written-by-a-person'
EOF
_gone_id="helixllm-gemma3-27b-112233445566"
_kept_id="helixllm-phi4-14b-aabbccddeeff"
_alpha_survivor="helixllm-llama3-8b-a1b2c3d4e5f6"
assert_file "$PDIR/$_gone_id.env"  "beta's gemma3 provider exists before the host drops it"
assert_file "$PDIR/$_kept_id.env"  "beta's phi4 provider exists too"
assert_file "$PDIR/hand-authored-thing.env" "the hand-authored provider is in place"

it "when a reachable host stops serving a model, --apply retires it"
cat > "$MODELS_B_FILE" <<'JSON'
[
 {"id":"helixllm-phi4-14b-aabbccddeeff","object":"model","owned_by":"helixllm",
  "model_identity":"helixllm/beta/phi4:14b"}
]
JSON
{ echo "--- beta now serves only phi4; running --apply ---"; } >> "$PROOF" 2>&1
bash "$PROVIDERS_SH" helixllm-export --apply --keys-file "$KEYS" >>"$PROOF" 2>&1
assert_eq 0 $? "--apply exits cleanly after the host dropped a model"
[[ ! -f "$PDIR/$_gone_id.env" ]]
assert_eq 0 $? "the withdrawn model's env record is gone"
grep -q "cma_run_provider $_gone_id" "$ALIAS_FILE" 2>/dev/null
assert_eq 1 $? "the withdrawn model's alias is gone — it is no longer invocable"
assert_jq "$CATALOGUE" '[.entries[]|select(.id=="'"$_gone_id"'")]|length' 0 \
  "and it is out of the catalogue"
assert_file "$PDIR/$_kept_id.env" "the model beta STILL serves was left alone"
assert_file "$PDIR/hand-authored-thing.env" \
  "the hand-authored provider was not touched (it never claimed this tool wrote it)"
_backups="$(find "$HOME" -maxdepth 1 -name "*${_gone_id}.preunify.*" -type d | wc -l | tr -d ' ')"
assert_eq 1 "$_backups" "the retired provider's config dir was BACKED UP, not deleted"

it "an UNREACHABLE host never causes a removal — silence is not evidence"
assert_file "$PDIR/$_alpha_survivor.env" "control: alpha's provider exists before alpha goes away"
: > "$DOWN_A"          # alpha stops answering (laptop asleep / VPN down)
_out="$(bash "$PROVIDERS_SH" helixllm-export --apply --keys-file "$KEYS" 2>&1)"
printf '%s\n' "$_out" >> "$PROOF"
assert_file "$PDIR/$_alpha_survivor.env" \
  "alpha's providers SURVIVE while alpha is unreachable (a sleeping host must not wipe a working config)"
assert_file "$PDIR/$BS_ID.env" \
  "every one of alpha's providers survives, not just the first"
printf '%s' "$_out" | grep -q "did not answer this run"
assert_eq 0 $? "and the user is TOLD they were kept because the host was unreachable, not silently skipped"
rm -f "$DOWN_A"

it "--dry-run reports the retirement without performing it"
# beta swaps phi4 out for a different model: a listing that PROVES beta is
# serving, and that no longer names phi4 -- so phi4 is genuinely withdrawn and
# a retirement is due. (An EMPTY listing would prove nothing; see the next
# case. Using one here would make this assertion pass for the wrong reason.)
cat > "$MODELS_B_FILE" <<'JSON'
[
 {"id":"helixllm-codestral-22b-778899aabbcc","object":"model","owned_by":"helixllm",
  "model_identity":"helixllm/beta/codestral:22b"}
]
JSON
_before="$(find "$PDIR" -maxdepth 1 -name '*.env' | wc -l | tr -d ' ')"
_dry="$(bash "$PROVIDERS_SH" helixllm-export --apply --dry-run --keys-file "$KEYS" 2>&1)"
printf '%s\n' "$_dry" >> "$PROOF"
printf '%s' "$_dry" | grep -q "would retire"
assert_eq 0 $? "--dry-run announces what it would retire"
assert_eq "$_before" "$(find "$PDIR" -maxdepth 1 -name '*.env' | wc -l | tr -d ' ')" \
  "--dry-run changed nothing on disk"

# ---------------------------------------------------------------------------
# A REPLY IS NOT EVIDENCE OF WITHDRAWAL.
#
# This case replaces one that asserted the opposite — "a host that answers with
# an EMPTY list still converges … its last provider is retired too" — and that
# assertion was the defect, pinned. The reasoning behind it was that an empty
# answer "is a real answer", so it converges. It is not: a HelixLLM whose
# gateway is up while its backend is still loading answers with exactly that
# empty list, because /health is 503 during the load, the option is dropped as
# unavailable, and the listing comes back `{"data":[], "reason":...}`. Under
# the old gate, a user who ran `--apply` in the first seconds after a restart
# lost the whole configuration for that host — env files and aliases deleted.
#
# So the invariant is inverted, and it is the one asserted here: a listing that
# names nothing the host is serving is treated exactly like silence — REPORTED
# and KEPT. Retirement still requires positive evidence the host is serving,
# which the `it "when a reachable host stops serving a model"` case above and
# the final sub-case below both prove is still delivered.
#
# Live proof of the defect and of this guard: bash scripts/tests/repro_helixllm_loading_host.sh
# ---------------------------------------------------------------------------
it "a host that replies while serving NOTHING is kept — an empty answer is not proof of withdrawal"
cat > "$MODELS_B_FILE" <<'JSON'
[]
JSON
_out="$(bash "$PROVIDERS_SH" helixllm-export --apply --keys-file "$KEYS" 2>&1)"
printf '%s\n' "$_out" >> "$PROOF"
printf '%s' "$_out" | grep -q '"reason"\|serving no models\|named no model it is serving'
assert_eq 0 $? "control: beta really did answer 200 with an empty, reasoned listing"
assert_file "$PDIR/$_kept_id.env" \
  "beta's provider SURVIVES an empty listing (a host mid-restart must not wipe a working config)"
grep -q "cma_run_provider $_kept_id" "$ALIAS_FILE" 2>/dev/null
assert_eq 0 $? "and its alias is still invocable, not just its env file"
printf '%s' "$_out" | grep -q "named no model it is serving"
assert_eq 0 $? "and the user is TOLD why it was kept, rather than it being silently skipped"
assert_file "$PDIR/$_alpha_survivor.env" "alpha, still serving, is untouched"
assert_file "$PDIR/hand-authored-thing.env" "and the hand-authored provider still stands"

it "a listing of nothing but REMOTE vendor models is not proof either"
# A remote passthrough stays reachable while the local backend is down, so a
# vendor-only listing is another face of the same loading host. It carries no
# model_identity, so it is not evidence that any LOCAL model was withdrawn.
cat > "$MODELS_B_FILE" <<'JSON'
[
 {"id":"gpt-4o","object":"model","owned_by":"openai"}
]
JSON
_out="$(bash "$PROVIDERS_SH" helixllm-export --apply --keys-file "$KEYS" 2>&1)"
printf '%s\n' "$_out" >> "$PROOF"
assert_file "$PDIR/$_kept_id.env" \
  "beta's local provider survives a listing that names only a vendor passthrough"

it "and once beta is demonstrably serving again, convergence finally happens"
# The negative control for the two cases above: proof they made removal
# CONDITIONAL, not impossible. Beta comes back serving a different model, which
# IS positive evidence — so phi4 is now genuinely withdrawn and is retired.
cat > "$MODELS_B_FILE" <<'JSON'
[
 {"id":"helixllm-codestral-22b-778899aabbcc","object":"model","owned_by":"helixllm",
  "model_identity":"helixllm/beta/codestral:22b"}
]
JSON
bash "$PROVIDERS_SH" helixllm-export --apply --keys-file "$KEYS" >>"$PROOF" 2>&1
[[ ! -f "$PDIR/$_kept_id.env" ]]
assert_eq 0 $? "beta named what it serves and phi4 was not in it, so phi4 IS retired"
grep -q "cma_run_provider $_kept_id" "$ALIAS_FILE" 2>/dev/null
assert_eq 1 $? "and its alias is gone — it is no longer invocable"
assert_file "$PDIR/helixllm-codestral-22b-778899aabbcc.env" \
  "the model beta now serves was written"
assert_file "$PDIR/hand-authored-thing.env" "and the hand-authored provider still stands"

# ===========================================================================
# CASE 8 — a WITHHELD entry is not a served model, and the guard that says so
#          is exercised here rather than only in the serving repo
#
# WHY THIS CASE EXISTS AT ALL. `_CMA_HELIXLLM_SERVING_JQ` is ONE definition
# doing TWO jobs: it selects what gets exported, and it decides whether a host
# proved it is SERVING — gate 2 of the retirement sweep, the gate that stops
# `--apply` deleting a user's configuration for a host whose backend is merely
# loading. Every case above exercises only its FIRST clause (`model_identity`
# non-empty). Nothing in this repository fed it an entry carrying an explicit
# `availability` other than "serving", so its SECOND clause could be deleted
# outright and this file still passed 71/0 — measured, not assumed. A guard
# that can be removed without its own repository noticing is not a guard.
#
# WHAT A WITHHELD ENTRY IS. The serving layer no longer drops an unavailable
# option before rendering; it PUBLISHES it with `availability:"withheld"` and a
# `withheld_reason`. That is what lets a LOADING backend be told apart from a
# WITHDRAWN model instead of both arriving as silence — and it is precisely why
# such an entry must count as NEITHER an exportable model NOR evidence of
# serving. It now carries `model_identity` too, so the first clause alone lets
# it straight through: it would be exported as a usable alias pointing at a
# model the host is refusing to serve, AND it would license the retirement
# sweep to start deleting — the exact data-loss door CASE 7 closed, reopened
# from the front.
#
# THE DEGENERATE-FILTER TRAP. A filter that rejected EVERYTHING would satisfy
# "the withheld entry is not exported" and "the host is not serving" while
# breaking the product completely — that is the failure mode the fix behind
# CASE 7 had to avoid. So the serving-sibling sub-case below is not decoration:
# it asserts a sibling on the SAME host is still exported and can still license
# a genuine retirement, which no reject-everything filter can satisfy.
# ===========================================================================
_withheld_id="helixllm-deepseek-r1-70b-ffeeddccbbaa"
_sibling_id="helixllm-nemotron-9b-0a1b2c3d4e5f"
_stale_id="helixllm-codestral-22b-778899aabbcc"

# Beta lists NOTHING but a withheld option. It is identity-bearing, so the
# `model_identity` clause alone would admit it.
cat > "$MODELS_B_FILE" <<'JSON'
[
 {"id":"helixllm-deepseek-r1-70b-ffeeddccbbaa","object":"model","owned_by":"helixllm",
  "model_identity":"helixllm/beta/deepseek-r1:70b",
  "availability":"withheld","withheld_reason":"provider_unavailable"}
]
JSON

it "control: beta really publishes a withheld, identity-bearing option"
# Without this control a pass could come from a corpus that never exercised the
# path — which is exactly how the clause went unguarded in the first place.
_wh="$(curl -s --max-time 5 "$BASE_B/models" | jq -c --arg i "$_withheld_id" '.data[]|select(.id==$i)')"
printf 'withheld entry as served: %s\n' "$_wh" >> "$PROOF"
assert_eq "withheld"             "$(jq -r '.availability'    <<<"$_wh")" "it is published with availability=withheld"
assert_eq "provider_unavailable" "$(jq -r '.withheld_reason' <<<"$_wh")" "and carries a withheld_reason"
assert_eq "helixllm/beta/deepseek-r1:70b" "$(jq -r '.model_identity' <<<"$_wh")" \
  "and it DOES carry a model_identity — so the identity clause alone would admit it"

it "the serving filter itself — read from the script, not restated — rejects it"
# DERIVED, NOT COPIED. The filter is read out of claude-providers.sh at run
# time, so this assertion cannot drift from the definition it is about: edit
# the definition and this reads the edited one. (A literal copy of the filter
# kept in another repository can silently disagree with it; a copy kept HERE
# would silently disagree too. Deriving it is what removes that failure mode
# on this side.)
_serving_jq="$( ( set +e; set --; source "$PROVIDERS_SH" >/dev/null 2>&1
                  printf '%s' "${_CMA_HELIXLLM_SERVING_JQ:-}" ) )"
[[ -n "$_serving_jq" ]]
assert_eq 0 $? "control: the filter was really read out of the script (empty would make every count below meaningless)"
printf 'derived _CMA_HELIXLLM_SERVING_JQ: %s\n' "$_serving_jq" >> "$PROOF"
_kept_by_filter="$(curl -s --max-time 5 "$BASE_B/models" \
  | jq "[.data[]? | $_serving_jq] | length" 2>/dev/null)"
assert_eq 0 "${_kept_by_filter:-x}" "the withheld entry does not survive the serving filter"
# ...and the same filter, unchanged, still admits alpha's genuinely served
# models. This is the guard against "it passed because the filter rejects
# everything" — the one way the assertion above could be satisfied wrongly.
_alpha_kept="$(curl -s --max-time 5 "$BASE_A/models" \
  | jq "[.data[]? | $_serving_jq] | length" 2>/dev/null)"
[[ "${_alpha_kept:-0}" -ge 4 ]]
assert_eq 0 $? "control: that same filter still admits alpha's served models (kept=${_alpha_kept:-0}) — it is selective, not empty"

it "a withheld option is never exported as a usable model"
bash "$PROVIDERS_SH" helixllm-export --apply --keys-file "$KEYS" >>"$PROOF" 2>&1
assert_eq 0 $? "--apply exits cleanly against a withheld-only listing"
assert_jq "$CATALOGUE" '[.entries[]|select(.id=="'"$_withheld_id"'")]|length' 0 \
  "the withheld model is absent from the catalogue"
assert_file_not_contains "$CATALOGUE" "deepseek-r1" \
  "nothing of it reaches the catalogue under any key"
[[ ! -f "$PDIR/$_withheld_id.env" ]]
assert_eq 0 $? "and no provider record was written for it — it is not invocable"

it "a host whose only identity-bearing options are WITHHELD is answered-not-serving"
# Asserted on the detector's own envelope, because that field is what gate 2 of
# the retirement sweep consumes; the surviving config below is the consequence.
_env_json="$( ( set +e; set --; export CMA_KEYS_FILE="$KEYS"
                source "$PROVIDERS_SH" >/dev/null 2>&1
                detect_helixllm_model_records ) 2>/dev/null )"
printf 'envelope (withheld-only beta): %s\n' "$_env_json" >> "$PROOF"
assert_eq "true" "$(jq -r --arg b "$BASE_B" '(.hosts_answered_not_serving//[])|index($b)!=null' <<<"$_env_json")" \
  "beta is reported as answered-but-not-serving"
assert_eq "true" "$(jq -r --arg b "$BASE_B" '(.hosts_serving//[])|index($b)==null' <<<"$_env_json")" \
  "and it is NOT counted among the hosts that proved they are serving"
assert_eq "true" "$(jq -r --arg b "$BASE_A" '(.hosts_serving//[])|index($b)!=null' <<<"$_env_json")" \
  "control: alpha, genuinely serving, IS in hosts_serving in the same envelope"

it "so the user's existing configuration for that host is KEPT, not deleted"
assert_file "$PDIR/$_stale_id.env" \
  "beta's existing provider survives a withheld-only listing (a backend refusing to serve is not a withdrawal)"
grep -q "cma_run_provider $_stale_id" "$ALIAS_FILE" 2>/dev/null
assert_eq 0 $? "and its alias is still invocable, not merely its env file"
assert_file "$PDIR/hand-authored-thing.env" "and the hand-authored provider still stands"
_out="$(bash "$PROVIDERS_SH" helixllm-export --apply --keys-file "$KEYS" 2>&1)"
printf '%s\n' "$_out" >> "$PROOF"
printf '%s' "$_out" | grep -q "named no model it is serving"
assert_eq 0 $? "and the user is TOLD it was kept because the host named nothing it serves"

it "a SERVING sibling on the same host is still exported, and still licenses retirement"
# The negative control for everything above: prove the withheld entry was
# excluded because it is withheld, not because the host or the filter was
# written off. Beta now publishes the same withheld option ALONGSIDE a model it
# really is serving — so the sibling must be exported, the withheld one must
# still not be, and beta has now given the positive evidence that makes the
# genuinely-withdrawn model retirable.
cat > "$MODELS_B_FILE" <<'JSON'
[
 {"id":"helixllm-deepseek-r1-70b-ffeeddccbbaa","object":"model","owned_by":"helixllm",
  "model_identity":"helixllm/beta/deepseek-r1:70b",
  "availability":"withheld","withheld_reason":"provider_unavailable"},
 {"id":"helixllm-nemotron-9b-0a1b2c3d4e5f","object":"model","owned_by":"helixllm",
  "model_identity":"helixllm/beta/nemotron:9b","availability":"serving"}
]
JSON
assert_file "$PDIR/$_stale_id.env" "control: the now-withdrawn model is still configured before this run"
bash "$PROVIDERS_SH" helixllm-export --apply --keys-file "$KEYS" >>"$PROOF" 2>&1
assert_eq 0 $? "--apply exits cleanly on a mixed withheld/serving listing"
assert_jq "$CATALOGUE" '[.entries[]|select(.id=="'"$_sibling_id"'")]|length' 1 \
  "the SERVING sibling is exported (an explicit availability of \"serving\" is honoured)"
assert_file "$PDIR/$_sibling_id.env" "and it has a provider record — it is invocable"
assert_jq "$CATALOGUE" '[.entries[]|select(.id=="'"$_withheld_id"'")]|length' 0 \
  "while the withheld option beside it is STILL not exported"
[[ ! -f "$PDIR/$_withheld_id.env" ]]
assert_eq 0 $? "and still has no provider record"
[[ ! -f "$PDIR/$_stale_id.env" ]]
assert_eq 0 $? "beta proved it is serving and did not name the old model, so THAT one is retired"
grep -q "cma_run_provider $_stale_id" "$ALIAS_FILE" 2>/dev/null
assert_eq 1 $? "and the retired model's alias is gone — retirement still works, it was only made conditional"
assert_file "$PDIR/hand-authored-thing.env" "and the hand-authored provider still stands"

echo >> "$PROOF"
echo "=== result: pass=$TESTS_PASSED fail=$TESTS_FAILED ===" >> "$PROOF"

summary
