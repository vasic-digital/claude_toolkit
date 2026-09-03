#!/usr/bin/env bash
# test_helix_endpoint_reality.sh — the three local Helix provider endpoints must
# point at a port something ACTUALLY listens on, and the probe must be able to
# say WHY when they don't.
#
# WHY THIS EXISTS (a live defect, 2026-09-03, not a hypothetical).
#
# `claude-providers list` shows only VERIFIED providers (cmd_list -> _list_rows
# verified). All three local Helix aliases were permanently invisible there, and
# the reason was upstream of every verification layer: their configured
# base_urls named ports that NOTHING has ever listened on.
#
#   provider           configured                        measured
#   helixagent         http://127.0.0.1:18434/v1         curl exit 7, HTTP 000
#   helixagent-native  http://127.0.0.1:18435            curl exit 7, HTTP 000
#   helixllm-gateway   http://127.0.0.1:18435/v1         curl exit 7, HTTP 000
#
# `ss -ltnp` on the operator's host says where they really are: HelixAgent's
# OpenAI-compatible /v1 on 7061 (`curl http://127.0.0.1:7061/v1/models` -> 200,
# five models), and HelixLLM on 8443 — over TLS, with a self-signed cert, so
# plain http there answers "Client sent an HTTP request to an HTTPS server".
# helixllm-gateway was therefore wrong twice: wrong port AND wrong scheme.
#
# The rest of the tree already knew: challenges/.../agentic_subagents_challenge.sh
# defaults HELIXAGENT_ENDPOINT to :7061, and constitution/.../helix_code_services.sh
# prints "HelixLLM gateway (:8443)". Only the toolkit had drifted.
#
# THREE THINGS ARE GUARDED HERE, and each one FAILS against the pre-fix tree:
#
#   1. The endpoints resolve to reality. Not by grepping a comment — by RUNNING
#      detect_helixagent_record / detect_helixllm_records and reading the
#      base_url out of the JSON record they emit.
#   2. The documented env override is REAL. The comment above
#      detect_helixllm_records has always promised "process-env >
#      CMA_HELIXLLM_GW_* / CMA_HELIXLLM_NATIVE_* override the pins", but the
#      loader assigned from the pins file UNCONDITIONALLY, so the override was
#      dead whenever the tracked pins file existed — which is always. A
#      hardcoded-port fix without a working override just relocates the
#      hardcoding (CONST-045 / §11.4.111: resolve, never hardcode).
#   3. The probe distinguishes NOT-LISTENING from REACHABLE-BUT-REFUSED from
#      REACHABLE-BUT-UNABLE. All three used to report the identical
#      "chat probe inconclusive (HTTP 000)", because -w '%{http_code}' prints
#      000 for every transport failure. An operator staring at 000 cannot tell
#      a wrong port from an untrusted certificate, and the fix for those is not
#      remotely the same. Section 3 stands up real local servers — a closed
#      port, a self-signed TLS server, and a 503 — and asserts the reason text
#      names the right cause for each.
#
# Section 3 is hermetic and re-runnable (§11.4.98): it builds its own cert and
# its own servers on ephemeral ports, so it neither needs nor is perturbed by
# whatever HelixAgent/HelixLLM happen to be doing on this host.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
export SCRIPTS_DIR

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

PROVIDERS_SH="$SCRIPTS_DIR/claude-providers.sh"
PROVIDERS_VERIFY="$SCRIPTS_DIR/providers-verify.sh"
PINS_DIR="$SCRIPTS_DIR/providers"

# A sandbox HOME: sourcing claude-providers.sh resolves state paths under $HOME,
# and nothing here may touch the operator's real provider state. The pins files
# still resolve against the REPO (LIB_DIR comes from the script's own
# BASH_SOURCE), which is exactly what sections 1 and 2 need to grade.
make_sandbox

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq is required to read provider records"; exit 0; }

# det FN — source claude-providers.sh (its bottom half is source-guarded, so no
# dispatcher runs) and print the JSON array FN emits. Grading the FUNCTION's
# real output is what makes this test unsatisfiable by a corrected comment.
det() {
  bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; '"$1"'' 2>/dev/null
}

# base_of JSON ID — the base_url of the record whose provider_id is ID.
base_of() { jq -r --arg i "$2" '.[] | select(.provider_id==$i) | .base_url' <<<"$1" 2>/dev/null; }

# ===========================================================================
# 1. The endpoints resolve to a port something actually listens on
# ===========================================================================

it "the tracked pins name no wrong-service port (:18434 / :18435 are other services)"
_dead=0
for f in helixagent.json helixagent-native.json helixllm-gateway.json; do
  if grep -qE ':1843[45]' "$PINS_DIR/$f" 2>/dev/null; then
    _fail "$f still pins a wrong-service port" \
      "$(jq -r '.base_url' "$PINS_DIR/$f") — :18434 is the llama.cpp coder container and :18435 the TEI embeddings container, so this pin names a REAL port belonging to a DIFFERENT service (and both were down when measured); either way the provider can never verify and 'claude-providers list' can never show it"
    _dead=1
  fi
done
(( _dead )) || _pass "none of the three tracked pins names :18434 or :18435"

it "detect_helixagent_record emits the measured HelixAgent endpoint"
DET_HA="$(det detect_helixagent_record)"
assert_eq "http://127.0.0.1:7061/v1" "$(base_of "$DET_HA" helixagent)" \
  "helixagent base_url (HelixAgent's OpenAI-compatible /v1, ss -ltnp 2026-09-03)"

it "detect_helixllm_records emits the measured HelixLLM endpoint for both aliases"
DET_HL="$(det detect_helixllm_records)"
assert_eq "https://127.0.0.1:8443/v1" "$(base_of "$DET_HL" helixllm-gateway)" \
  "helixllm-gateway base_url"
assert_eq "https://127.0.0.1:8443" "$(base_of "$DET_HL" helixagent-native)" \
  "helixagent-native base_url"

it "the HelixLLM aliases use https — plain http on 8443 is refused by the server"
# Measured: `curl http://127.0.0.1:8443/v1/models` answers
# "Client sent an HTTP request to an HTTPS server." A pin that keeps the http
# scheme is as broken as one that keeps the wrong port, and a port-only fix
# would leave it that way.
for _id in helixllm-gateway helixagent-native; do
  _b="$(base_of "$DET_HL" "$_id")"
  case "$_b" in
    https://*) _pass "$_id speaks https ($_b)" ;;
    *)         _fail "$_id is not https" "got '$_b' — HelixLLM serves TLS on this port" ;;
  esac
done

it "the built-in fallback default (pins file present but silent on base_url) is live too"
# The tracked pins are the normal path, but the built-in `:=` defaults are what
# fills any field the pins omit. They were :18435 and localhost:8100 — both
# dead — so the fallback was a second, quieter copy of the same defect, and a
# fix that only edited the JSON would leave it armed.
#
# The pins files must EXIST for the detector to emit anything at all: with both
# absent AND no `helixllm` on PATH the whole feature is correctly opt-out
# (`printf '[]'`). So these sandbox pins carry the ids and deliberately OMIT
# base_url, which is exactly the "a field is missing" case the defaults serve.
printf '{"id":"helixllm-gateway"}\n'  > "$HOME/pins-gw-nourl.json"
printf '{"id":"helixagent-native"}\n' > "$HOME/pins-nat-nourl.json"
DET_NOURL="$(env CMA_HELIXLLM_PINS_FILE="$HOME/pins-gw-nourl.json" \
                 CMA_HELIXLLM_NATIVE_PINS_FILE="$HOME/pins-nat-nourl.json" \
                 bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_helixllm_records' 2>/dev/null)"
assert_eq "https://127.0.0.1:8443/v1" "$(base_of "$DET_NOURL" helixllm-gateway)" \
  "helixllm-gateway built-in default"
assert_eq "https://127.0.0.1:8443" "$(base_of "$DET_NOURL" helixagent-native)" \
  "helixagent-native built-in default"

it "detect_helixagent_record's built-in HOST/PORT default is live too"
# Same class: with no pins file and no base_url env, `base` is composed from
# CMA_HELIXAGENT_HOST:CMA_HELIXAGENT_PORT, which defaulted to localhost:8100 —
# a port that holds nothing (8111 on this host is HelixAgent's liveness probe,
# not its API). The pins file must be ABSENT for the composition to be
# reached, and the detector still emits a record because a pins-file path that
# does not exist plus... no binary would gate it out, so point the pins path at
# a file that DOES exist but omits base_url.
printf '{"id":"helixagent","bin":"helixagent"}\n' > "$HOME/pins-ha-nourl.json"
DET_HAPORT="$(env -u CMA_HELIXAGENT_BASE_URL -u CMA_HELIXAGENT_HOST -u CMA_HELIXAGENT_PORT \
                   CMA_HELIXAGENT_PINS_FILE="$HOME/pins-ha-nourl.json" \
                   bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_helixagent_record' 2>/dev/null)"
assert_eq "http://127.0.0.1:7061/v1" "$(base_of "$DET_HAPORT" helixagent)" \
  "helixagent built-in HOST:PORT default"

# ===========================================================================
# 2. The documented process-env override is implemented, not just promised
# ===========================================================================
# Pre-fix this whole section failed: the pins-file loader overwrote the env
# unconditionally, so every assertion below returned the pins value.

it "CMA_HELIXLLM_GW_BASE_URL overrides the tracked pins file"
DET_ENV="$(env CMA_HELIXLLM_GW_BASE_URL="http://127.0.0.1:19999/v1" \
                bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_helixllm_records' 2>/dev/null)"
assert_eq "http://127.0.0.1:19999/v1" "$(base_of "$DET_ENV" helixllm-gateway)" \
  "process-env wins over the pins file (gateway)"

it "CMA_HELIXLLM_NATIVE_BASE_URL overrides the tracked pins file"
DET_ENVN="$(env CMA_HELIXLLM_NATIVE_BASE_URL="http://127.0.0.1:19998" \
                 bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_helixllm_records' 2>/dev/null)"
assert_eq "http://127.0.0.1:19998" "$(base_of "$DET_ENVN" helixagent-native)" \
  "process-env wins over the pins file (native)"

it "an override of one alias does not disturb the other"
# The two records share a function; a naive fix could leak the gateway's env
# value into the native record (or vice versa).
assert_eq "https://127.0.0.1:8443" "$(base_of "$DET_ENV" helixagent-native)" \
  "native keeps its pin while the gateway is overridden"
assert_eq "https://127.0.0.1:8443/v1" "$(base_of "$DET_ENVN" helixllm-gateway)" \
  "gateway keeps its pin while native is overridden"

it "CMA_HELIXAGENT_BASE_URL still overrides its pins file (unchanged contract)"
DET_HAENV="$(env CMA_HELIXAGENT_BASE_URL="http://127.0.0.1:19997/v1" \
                  bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_helixagent_record' 2>/dev/null)"
assert_eq "http://127.0.0.1:19997/v1" "$(base_of "$DET_HAENV" helixagent)" \
  "helixagent process-env precedence is not regressed"

# ===========================================================================
# 3. The probe says WHY — three failures that used to read identically
# ===========================================================================
# Every case below runs providers-verify.sh with NO key var set against a
# LOOPBACK base_url, which also exercises the keyless-loopback probe gate: a
# local backend that authenticates nothing is now probed instead of being
# skipped into a verdict that cannot distinguish a perfect endpoint from a dead
# one.

HAVE_PY=0; command -v python3 >/dev/null 2>&1 && HAVE_PY=1

# free_port — an ephemeral port nothing holds. Bound and released by the kernel,
# so it is not a guess about what happens to be free.
free_port() {
  python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
}

# pv REASON_FILE ARGS... — run providers-verify.sh with the key var deliberately
# unset; stdout (the verdict) is returned, stderr (the reason) goes to the file.
pv() {
  local errf="$1"; shift
  # CMA_VERIFIER_BIN=/nonexistent makes strategy 1 (the LLMsVerifier binary)
  # deterministically unavailable. Without it this whole section would depend
  # on whether THIS host happens to have built submodules/LLMsVerifier — and
  # on a host that had, every case below would probe the network through a
  # different code path and fail for an unrelated reason.
  env -u CMA_PROVIDER_CA_CERT CMA_VERIFIER_BIN=/nonexistent bash "$PROVIDERS_VERIFY" \
    --provider helix-under-test --model m --key-var CMA_HELIX_TEST_UNSET_KEY "$@" 2>"$errf"
}

if (( ! HAVE_PY )); then
  echo "SECTION-SKIP: python3 is required to stand up the local probe servers"
else

# --- 3a. nothing listening -> CONNECTION REFUSED, named as such -------------
it "a closed loopback port is reported as CONNECTION REFUSED, not bare 'HTTP 000'"
DEAD_PORT="$(free_port)"
out="$(pv "$HOME/refused.err" --base-url "http://127.0.0.1:$DEAD_PORT/v1")"; rc=$?
assert_eq "unverified" "$out" "verdict is unverified"
assert_eq 2 "$rc" "exit 2 (inconclusive, not a hard failure)"
assert_file_contains "$HOME/refused.err" "CONNECTION REFUSED" \
  "reason names the actual transport cause"
assert_file_contains "$HOME/refused.err" "the endpoint is wrong, or the backend is not running" \
  "reason tells the operator which two things to check"

# --- 3b. a real self-signed TLS server --------------------------------------
# This is the helixllm-gateway shape: reachable, listening, answering — and
# rejected by curl at the TLS layer (exit 60) with the SAME HTTP 000 a closed
# port produces. Distinguishing the two is the whole point.
CERT_DIR="$HOME/tlscert"; mkdir -p "$CERT_DIR"
HAVE_TLS=0
if command -v openssl >/dev/null 2>&1; then
  if openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
      -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
      -subj "/CN=127.0.0.1" \
      -addext "subjectAltName=IP:127.0.0.1" >/dev/null 2>&1; then
    HAVE_TLS=1
  fi
fi

if (( ! HAVE_TLS )); then
  echo "SECTION-SKIP: openssl could not generate a self-signed cert — the TLS-trust cases need one"
else
  TLS_PORT="$(free_port)"
  # A TLS server that answers every request with a valid OpenAI-shaped reply
  # carrying the sentinel and a tool call, so the ONLY thing that can stop the
  # probe reaching 'verified' is certificate trust.
  cat > "$HOME/tlssrv.py" <<'PY'
import http.server, json, ssl, sys
port, cert, key = int(sys.argv[1]), sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(n).decode('utf-8', 'replace')
        if '"tools"' in body:
            msg = {"tool_calls": [{"id": "c1", "type": "function",
                                   "function": {"name": "get_weather", "arguments": "{}"}}]}
        else:
            msg = {"content": "VERIFY_OK"}
        out = json.dumps({"choices": [{"message": msg}]}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(out)))
        self.end_headers()
        self.wfile.write(out)
    def log_message(self, *a): pass
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
srv = http.server.HTTPServer(('127.0.0.1', port), H)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
PY
  python3 "$HOME/tlssrv.py" "$TLS_PORT" "$CERT_DIR/cert.pem" "$CERT_DIR/key.pem" \
    >/dev/null 2>&1 &
  TLS_PID=$!
  # Wait for the listener rather than sleeping a guessed interval.
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    curl -sk --max-time 1 -o /dev/null "https://127.0.0.1:$TLS_PORT/" 2>/dev/null && break
    sleep 0.2
  done
  trap 'kill "$TLS_PID" 2>/dev/null; cleanup_sandbox' EXIT

  it "an untrusted certificate is reported as a TLS problem, NOT as 'not listening'"
  out="$(pv "$HOME/tls.err" --base-url "https://127.0.0.1:$TLS_PORT/v1")"; rc=$?
  assert_eq "unverified" "$out" "verdict is unverified"
  assert_file_contains "$HOME/tls.err" "TLS" "reason names the TLS layer"
  assert_file_contains "$HOME/tls.err" "IS reachable" \
    "reason states the endpoint IS reachable (the opposite of the refused case)"
  assert_file_contains "$HOME/tls.err" "CMA_PROVIDER_CA_CERT" \
    "reason names the knob that fixes it"
  assert_file_not_contains "$HOME/tls.err" "CONNECTION REFUSED" \
    "a reachable-but-untrusted endpoint is never reported as refused"

  it "CMA_PROVIDER_CA_CERT is actually wired into the probe (verified through TLS)"
  # The payoff: with the CA trusted, the very same endpoint completes both
  # probes. A CA knob that is documented but not passed to curl would leave
  # this identical to the case above.
  out="$(CMA_PROVIDER_CA_CERT="$CERT_DIR/cert.pem" CMA_VERIFIER_BIN=/nonexistent bash "$PROVIDERS_VERIFY" \
          --provider helix-under-test --model m --key-var CMA_HELIX_TEST_UNSET_KEY \
          --base-url "https://127.0.0.1:$TLS_PORT/v1" 2>"$HOME/tlsok.err")"; rc=$?
  assert_eq "verified" "$out" "the self-signed endpoint verifies once its CA is trusted"
  assert_eq 0 "$rc" "exit 0"

  it "an unreadable CMA_PROVIDER_CA_CERT is reported, not silently ignored"
  out="$(CMA_PROVIDER_CA_CERT="$HOME/no-such-cert.pem" CMA_VERIFIER_BIN=/nonexistent bash "$PROVIDERS_VERIFY" \
          --provider helix-under-test --model m --key-var CMA_HELIX_TEST_UNSET_KEY \
          --base-url "https://127.0.0.1:$TLS_PORT/v1" 2>"$HOME/tlsbad.err")"
  assert_file_contains "$HOME/tlsbad.err" "is not readable" \
    "a typo'd cert path is surfaced instead of presenting as a bare TLS failure"
fi

# --- 3c. reachable but unable (the live HelixAgent 503) ---------------------
it "a 5xx is reported as REACHABLE BUT UNABLE and quotes the backend"
# HelixAgent, at the correct endpoint, currently answers
#   503 {"error":{"message":"All providers failed: no provider in the chain
#        was able to handle the request", ...}}
# because it has discovered zero upstream providers. That is a BACKEND
# condition at a CORRECT endpoint, and it must never read like a wrong port.
UNABLE_PORT="$(free_port)"
cat > "$HOME/srv503.py" <<'PY'
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        out = json.dumps({"error": {"code": 503,
              "message": "All providers failed: no provider in the chain was able to handle the request",
              "type": "no_provider_available"}}).encode()
        self.send_response(503)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(out)))
        self.end_headers()
        self.wfile.write(out)
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PY
python3 "$HOME/srv503.py" "$UNABLE_PORT" >/dev/null 2>&1 &
UNABLE_PID=$!
# Into the trap as well: a signal between here and the explicit kill below
# would otherwise leak this server for the life of the machine. The trap is
# re-registered (not replaced) so the TLS server and the sandbox still go.
trap 'kill "${TLS_PID:-}" "${UNABLE_PID:-}" 2>/dev/null; cleanup_sandbox' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  curl -s --max-time 1 -o /dev/null "http://127.0.0.1:$UNABLE_PORT/" 2>/dev/null && break
  sleep 0.2
done

out="$(pv "$HOME/unable.err" --base-url "http://127.0.0.1:$UNABLE_PORT/v1")"; rc=$?
kill "$UNABLE_PID" 2>/dev/null
assert_eq "unverified" "$out" "verdict is unverified (honestly unproven)"
assert_eq 2 "$rc" "exit 2"
assert_file_contains "$HOME/unable.err" "REACHABLE BUT UNABLE" \
  "reason distinguishes a live-but-failing backend from an unreachable one"
assert_file_contains "$HOME/unable.err" "no provider in the chain" \
  "reason quotes the backend's own explanation"
assert_file_not_contains "$HOME/unable.err" "CONNECTION REFUSED" \
  "a 503 is never reported as refused"

fi  # HAVE_PY

# --- 3b-bis. a 200 from the WRONG SERVICE must not pass silently ------------
# The dead-port defect has a nastier successor. A raw llama.cpp server is now
# live on :18434 — the port helixagent used to be pinned at — and it ACCEPTS
# `model: "HelixAgent/HelixLLM"`, returns 200 WITH the VERIFY_OK sentinel, and
# echoes `"model": "qwen2.5-coder-3b-instruct-q4_k_m"`. Measured 2026-09-03.
# Every existing check passes, so the alias would earn `verified` for a model
# the endpoint does not serve. A dead port fails loudly; a wrong service
# answers plausibly, and nothing looks broken. This section pins the detector.
if (( HAVE_PY )); then
_mk_echo_srv() {  # $1=port  $2=model-name-to-echo-back
  cat > "$HOME/echo_$1.py" <<PYSRV
import http.server, json, sys
PORT, ECHO = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(n).decode('utf-8','replace')
        if '"tools"' in body:
            msg = {"tool_calls":[{"id":"c1","type":"function",
                   "function":{"name":"get_weather","arguments":"{}"}}]}
        else:
            msg = {"content":"VERIFY_OK"}
        out = json.dumps({"model":ECHO,"choices":[{"message":msg}]}).encode()
        self.send_response(200); self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(out))); self.end_headers()
        self.wfile.write(out)
    def log_message(self,*a): pass
http.server.HTTPServer(('127.0.0.1',PORT),H).serve_forever()
PYSRV
  python3 "$HOME/echo_$1.py" "$1" "$2" >/dev/null 2>&1 &
  echo $!
}

it "a 200 whose echoed model is a DIFFERENT service is flagged WRONG-SERVICE"
_WRONG_PORT="$(free_port)"
_WRONG_PID="$(_mk_echo_srv "$_WRONG_PORT" "qwen2.5-coder-3b-instruct-q4_k_m")"
trap 'kill "${TLS_PID:-}" "${UNABLE_PID:-}" "${_WRONG_PID:-}" "${_RIGHT_PID:-}" 2>/dev/null; cleanup_sandbox' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  curl -s --max-time 1 -o /dev/null -X POST -d '{}' "http://127.0.0.1:$_WRONG_PORT/" 2>/dev/null && break; sleep 0.2
done
out="$(env -u CMA_PROVIDER_CA_CERT CMA_VERIFIER_BIN=/nonexistent bash "$PROVIDERS_VERIFY" \
        --provider helix-under-test --model 'HelixAgent/HelixLLM' \
        --key-var CMA_HELIX_TEST_UNSET_KEY \
        --base-url "http://127.0.0.1:$_WRONG_PORT/v1" 2>"$HOME/misserve.err")"
assert_file_contains "$HOME/misserve.err" "WRONG-SERVICE WARNING" \
  "the mis-serve is named even though the probe itself returns 200 + sentinel"
assert_file_contains "$HOME/misserve.err" "qwen2.5-coder-3b-instruct-q4_k_m" \
  "the warning quotes what the endpoint actually answered as"
# The verdict is deliberately NOT changed: legitimate providers echo
# version-qualified names, and failing those would be a fleet-wide false
# positive. The warning is the deliverable; the verdict stays earned on its
# own merits.
assert_eq "verified" "$out" "verdict is unchanged (warning-only, by design)"

it "an echoed model that merely version-qualifies the request is NOT flagged"
# ask gpt-4o, get gpt-4o-2024-08-06 — the common, legitimate case. A detector
# that cried wolf here would be turned off within a day.
_RIGHT_PORT="$(free_port)"
_RIGHT_PID="$(_mk_echo_srv "$_RIGHT_PORT" "acme-big-2026-08-06")"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  curl -s --max-time 1 -o /dev/null -X POST -d '{}' "http://127.0.0.1:$_RIGHT_PORT/" 2>/dev/null && break; sleep 0.2
done
out="$(env -u CMA_PROVIDER_CA_CERT CMA_VERIFIER_BIN=/nonexistent bash "$PROVIDERS_VERIFY" \
        --provider helix-under-test --model 'acme-big' \
        --key-var CMA_HELIX_TEST_UNSET_KEY \
        --base-url "http://127.0.0.1:$_RIGHT_PORT/v1" 2>"$HOME/okserve.err")"
assert_eq "verified" "$out" "verdict verified"
assert_file_not_contains "$HOME/okserve.err" "WRONG-SERVICE" \
  "a version-qualified echo is not a mis-serve"
kill "$_WRONG_PID" "$_RIGHT_PID" 2>/dev/null
fi

# --- 3c-bis. the reason must reach the OPERATOR, not just the probe ---------
# A better diagnostic that the product throws away is not an improvement.
# `cmd_verify` used to run the verifier with `2>/dev/null`, so
# `claude-providers verify <id>` printed one word — "unverified" — and every
# distinction above died at the call site. This asserts the reason survives
# through the REAL entry point, which is the only place an operator sees it.
if (( HAVE_PY )); then
it "claude-providers verify surfaces the verifier's reason, not just the verdict"
_VSB="$HOME/verify-entrypoint"; mkdir -p "$_VSB/.local/share/claude-multi-account/providers"
_VPD="$_VSB/.local/share/claude-multi-account/providers"
_VDEAD="$(free_port)"
{ printf "CMA_PROVIDER_ID='helixprobe'\n"
  printf "CMA_PROVIDER_KEYVAR='CMA_HELIX_TEST_UNSET_KEY'\n"
  printf "CMA_PROVIDER_TRANSPORT='router'\n"
  printf "CMA_PROVIDER_BASE_URL='http://127.0.0.1:%s/v1'\n" "$_VDEAD"
  printf "CMA_PROVIDER_MODEL='m'\n"; } > "$_VPD/helixprobe.env"
_vout="$(HOME="$_VSB" CMA_VERIFIER_BIN=/nonexistent \
          bash "$SCRIPTS_DIR/claude-providers.sh" verify helixprobe 2>"$HOME/entry.err")"
assert_eq "unverified" "$(printf '%s' "$_vout" | tr -d '[:space:]')" \
  "stdout is still the bare verdict word (callers that capture it are unaffected)"
assert_file_contains "$HOME/entry.err" "CONNECTION REFUSED" \
  "the transport cause reaches the operator through 'claude-providers verify'"
assert_file_not_contains "$HOME/entry.err" "CMA_HELIX_TEST_UNSET_KEY is not set and" \
  "a loopback endpoint is probed rather than skipped for want of a key"
fi

# --- 3d. the loopback gate itself, as a truth table -------------------------
# The keyless probe is loopback-only, so _cma_pv_is_loopback is a SECURITY
# boundary: a false TRUE would send a probe to a remote endpoint with no
# credential. It is graded here by EXTRACTING the live definition out of
# providers-verify.sh and EXECUTING it, so a future widening genuinely fails
# these cases and cannot be satisfied by a source comment (the same discipline
# test_provider_validation.sh applies to the provider-id charset guard).
it "the keyless-probe loopback gate admits every loopback spelling and nothing else"
_LB_TT="$(mktemp "${TMPDIR:-/tmp}/cma-lbtt.XXXXXX")"
cat > "$_LB_TT" <<'LBEOF'
set -uo pipefail
. "$SCRIPTS_DIR/lib.sh" >/dev/null 2>&1
set +e
eval "$(sed -n '/^_cma_pv_is_loopback() {/,/^}/p' "$SCRIPTS_DIR/providers-verify.sh")"
# The gate is TWO functions: the URL/host splitter and the strict IPv6 check it
# delegates to. Extracting only the first leaves the second undefined, which
# exits 127 — so every bracketed-IPv6 URL would be reported "not loopback" and
# the six near-miss cases would pass for entirely the wrong reason while the
# genuine ::1 cases failed. Extract both.
eval "$(sed -n '/^_cma_pv_ipv6_is_loopback() {/,/^}/p' "$SCRIPTS_DIR/providers-verify.sh")"
# Guard the guard: if either extraction produced nothing, cases below would
# "pass" against a missing function's 127 exit. Prove both are defined first.
declare -F _cma_pv_is_loopback      >/dev/null || { echo "EXTRACT_FAILED_is_loopback"; exit 9; }
declare -F _cma_pv_ipv6_is_loopback >/dev/null || { echo "EXTRACT_FAILED_ipv6_helper"; exit 9; }
for u in "http://127.0.0.1:7061/v1" "https://127.0.0.1:8443/v1" "http://localhost:7061/v1" \
         "http://LOCALHOST:9/v1" "http://127.0.1.1:7061" "http://127.255.255.254:8080/x?a=b" \
         "http://0.0.0.0:8443/v1" "http://[::1]:8443/v1" "http://[0:0:0:0:0:0:0:1]:8443/v1" \
         "http://[::ffff:127.0.0.1]:8443/v1" "http://user:pw@127.0.0.1:7061/v1" \
         "http://127.0.0.1:7061/v1#frag"; do
  _cma_pv_is_loopback "$u" || echo "SHOULD_BE_LOOPBACK: $u"
done
# Adversarial: a hostname that merely CONTAINS a loopback literal, a
# userinfo-after-path trick, and a public IPv6 address must all be refused.
for u in "https://api.openai.com/v1" "https://api.openai.com:443/v1" "http://192.168.0.241:8443/v1" \
         "http://10.0.0.5:7061" "http://127.example.com:7061/v1" "http://evil.example/@127.0.0.1:7061" \
         "http://notlocalhost:7061/v1" "http://localhost/v1" "http://127.0.0.1/v1" \
         "https://127.0.0.1.attacker.example:8443/v1" "" "http://[2001:db8::1]:8443/v1" \
         "http://[1::]:8443/v1" "http://[10::]:8443/v1" "http://[100::]:8443/v1" \
         "http://[1000::]:8443/v1" "http://[::1:0]:8443/v1" "http://[0:0:0:0:0:0:1:0]:8443/v1"; do
  _cma_pv_is_loopback "$u" && echo "SHOULD_NOT_BE_LOOPBACK: $u"
done
echo TRUTH_TABLE_CLEAN
LBEOF
_lb_out="$(SCRIPTS_DIR="$SCRIPTS_DIR" bash "$_LB_TT" 2>&1)"
rm -f "$_LB_TT"
if [[ "$_lb_out" == "TRUTH_TABLE_CLEAN" ]]; then
  _pass "30 loopback / non-loopback cases all classified correctly (incl. the six IPv6 near-misses [1::] [10::] [100::] [1000::] [::1:0] [0:0:0:0:0:0:1:0] that the shared host test alone accepts)"
else
  _fail "the loopback gate mis-classified at least one URL" "$_lb_out"
fi

# --- 3e. the credential gate stays tight for anything non-loopback ----------
it "a REMOTE base_url with no key is still not probed, and the reason says so"
# The keyless probe is loopback-only. Probing a remote endpoint without a
# credential buys a guaranteed 401 that proves nothing, so the gate must not
# have been widened for everyone — and strategy 3 must now name the missing
# precondition instead of sending the operator to build a submodule.
out="$(pv "$HOME/remote.err" --base-url "https://api.example.invalid/v1")"; rc=$?
assert_eq "unverified" "$out" "verdict is unverified"
assert_eq 2 "$rc" "exit 2"
assert_file_contains "$HOME/remote.err" "CMA_HELIX_TEST_UNSET_KEY" \
  "the reason names the key var that is missing"
assert_file_not_contains "$HOME/remote.err" "CONNECTION REFUSED" \
  "no probe was attempted, so no transport cause is claimed"

it "strategy 3 still points at LLMsVerifier for the full check"
assert_file_contains "$HOME/remote.err" "LLMsVerifier" \
  "the layer-1 escalation path is still documented in the reason"

summary
