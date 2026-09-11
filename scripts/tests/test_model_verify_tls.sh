#!/usr/bin/env bash
# test_model_verify_tls.sh — the PYTHON verifier must be able to trust a
# private / self-signed endpoint, on the same knob the SHELL verifier already
# reads, and must never buy that ability with an insecure fallback.
#
# THE HOLE THIS CLOSES. scripts/providers-verify.sh (the shell probe) reads
# CMA_PROVIDER_CA_CERT and hands it to curl, and documents why at
# providers-verify.sh:62-75: a local backend that serves TLS with a self-signed
# certificate makes curl exit 60 while `%{http_code}` still prints 000, so in
# the HTTP code ALONE a LIVE endpoint is indistinguishable from a dead one.
# scripts/model_verify.py — the Python scoring engine that decides which models
# a provider actually serves — had no TLS handling of any kind (zero hits for
# ssl / SSLContext / cafile / CA_CERT), so every model behind such an endpoint
# came back:
#
#   "Connection failed: <urlopen error [SSL: CERTIFICATE_VERIFY_FAILED]
#    certificate verify failed: self-signed certificate (_ssl.c:1081)>"
#
# i.e. scored 0 and reported "failed" — a live, serving backend recorded as
# dead. That is the same conflation the shell path fixed, surviving in the
# other half of the verification pair.
#
# WHAT THIS FILE PINS.
#   T0  the fixture itself is REAL: a live HTTPS endpoint that a plain client
#       genuinely refuses (curl 60) and a CA-trusting one genuinely serves
#       (HTTP 200). Without this control a "fails without the CA" assertion
#       could be satisfied by a dead port (§11.4.273 / §11.4.201).
#   T1  with CMA_PROVIDER_CA_CERT pointed at the cert, the model VERIFIES.
#   T2  with the variable UNSET the probe still FAILS at TLS. This is the
#       anti-bluff control: it is what makes T1 mean "the CA was used", not
#       "verification was switched off". A fix that added verify=False would
#       pass T1 and FAIL here.
#   T3  an unreadable path is reported and DEGRADES TO SYSTEM VERIFICATION —
#       never to no verification (still fails against the self-signed cert).
#   T4  a path containing a quote / backslash / newline is REFUSED, matching
#       the validation claude-providers.sh:1006-1011 applies, so a path that
#       is accepted by one verifier is accepted by both.
#   T5  the CA path is taken from the ENVIRONMENT only. No argv option may
#       exist for it: argv is world-readable via /proc/<pid>/cmdline, which is
#       the same reason CMA_PROBE_KEY is an env var (model_verify.py:19-20).
#   T6  a plain-HTTP endpoint is unaffected when the variable is set.
#   T7  source-level: no insecure escape hatch anywhere in the file
#       (CERT_NONE / check_hostname = False / _create_unverified_context).
#
# Hermetic: the HTTPS server is a throwaway fixture bound to 127.0.0.1 on an
# EPHEMERAL port (bind :0, port read back from the child) inside the sandbox,
# with a certificate generated per run. It never touches, and never needs, any
# endpoint another agent owns (§11.4.119).
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 is required"; exit 0; }
command -v openssl >/dev/null 2>&1 || { echo "SKIP: openssl is required to mint a throwaway cert"; exit 0; }
command -v curl    >/dev/null 2>&1 || { echo "SKIP: curl is required for the T0 control"; exit 0; }

MV="$SCRIPTS_DIR/model_verify.py"
[[ -f "$MV" ]] || { echo "SKIP: model_verify.py not found at $MV"; exit 0; }

make_sandbox
set +e

FIX="$HOME/tlsfix"; mkdir -p "$FIX"

# --- throwaway self-signed cert ---------------------------------------------
openssl req -x509 -newkey rsa:2048 -keyout "$FIX/key.pem" -out "$FIX/cert.pem" \
  -days 2 -nodes -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" \
  >/dev/null 2>&1
if [[ ! -s "$FIX/cert.pem" || ! -s "$FIX/key.pem" ]]; then
  echo "SKIP: openssl could not mint a self-signed cert on this host"; exit 0
fi

# --- fixture server ----------------------------------------------------------
# Answers the OpenAI-shaped chat/completions the probe builds: the sentinel
# VERIFY_OK for a plain probe, a tool_calls message when the request carries
# tools. Binds port 0 and prints the port it got, so two concurrent runs (or
# another agent's suite) can never collide on a fixed number.
cat > "$FIX/server.py" <<'PY'
import json, ssl, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def _send(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            req = {}
        if req.get("tools"):
            msg = {"role": "assistant", "content": None, "tool_calls": [
                {"id": "call_1", "type": "function",
                 "function": {"name": "get_weather",
                              "arguments": "{\"location\":\"Paris\"}"}}]}
        else:
            msg = {"role": "assistant", "content": "VERIFY_OK"}
        self._send({"id": "cmpl-1", "object": "chat.completion",
                    "model": req.get("model", "m"),
                    "choices": [{"index": 0, "message": msg,
                                 "finish_reason": "stop"}],
                    "usage": {"prompt_tokens": 5, "completion_tokens": 3,
                              "total_tokens": 8}})
    def do_GET(self):
        self._send({"object": "list", "data": [{"id": "m1", "object": "model"}]})

mode = sys.argv[1]
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
if mode == "tls":
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(sys.argv[2], sys.argv[3])
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
print("PORT %d" % srv.server_address[1], flush=True)
srv.serve_forever()
PY

SRV_PIDS=()
start_server() {  # start_server tls|plain -> echoes the port
  local mode="$1" log; log="$(mktemp "${TMPDIR:-/tmp}/cma-tlsfix.XXXXXX")"
  if [[ "$mode" == tls ]]; then
    python3 "$FIX/server.py" tls "$FIX/cert.pem" "$FIX/key.pem" > "$log" 2>&1 &
  else
    python3 "$FIX/server.py" plain > "$log" 2>&1 &
  fi
  SRV_PIDS+=("$!")
  local i port=""
  for ((i=0; i<60; i++)); do
    port="$(awk '/^PORT /{print $2; exit}' "$log" 2>/dev/null)"
    [[ -n "$port" ]] && break
    sleep 0.1
  done
  rm -f "$log"
  echo "$port"
}

# Reap only the fixture PIDs THIS file started — never a pattern kill, which
# on a shared host could signal another agent's python3 (§11.4.174/§11.4.263).
stop_servers() {
  local p
  for p in ${SRV_PIDS[@]+"${SRV_PIDS[@]}"}; do
    [[ -n "$p" ]] && [[ "$p" =~ ^[0-9]+$ ]] && (( p > 1 )) && kill "$p" 2>/dev/null
  done
}
trap 'stop_servers; cleanup_sandbox' EXIT

PORT="$(start_server tls)"
if [[ -z "$PORT" ]]; then
  echo "SKIP: the throwaway HTTPS fixture did not come up"; exit 0
fi
EP="https://127.0.0.1:$PORT/v1"

# run_mv [ENV=VAL ...] -> sets MV_OUT (stdout), MV_ERR (stderr), MV_RC
run_mv() {
  local errf; errf="$(mktemp "${TMPDIR:-/tmp}/cma-mverr.XXXXXX")"
  MV_OUT="$(env "$@" CMA_PROBE_KEY=test-key python3 "$MV" \
              --provider tlsfix --endpoint "${MV_EP:-$EP}" --models m1 \
              --no-cache --timeout 10 2>"$errf")"
  MV_RC=$?
  MV_ERR="$(cat "$errf")"; rm -f "$errf"
}

# jq-free field readers (python3 is already a prerequisite).
mv_field() { printf '%s' "$MV_OUT" | python3 -c \
  'import json,sys; d=json.load(sys.stdin); print(d["'"$1"'"])' 2>/dev/null; }
mv_reason() { printf '%s' "$MV_OUT" | python3 -c \
  'import json,sys; d=json.load(sys.stdin); print(d["models"][0].get("failure_reason",""))' 2>/dev/null; }

# ---------------------------------------------------------------------------
it "T0 control: the fixture is a LIVE endpoint that is genuinely self-signed"
# Without this, "it fails without the CA" would also be true of a dead port,
# and every assertion below would be vacuous.
curl -s --max-time 10 --cacert "$FIX/cert.pem" -o /dev/null \
  -w '%{http_code}' -X POST "$EP/chat/completions" \
  -H 'Content-Type: application/json' -d '{"model":"m1","messages":[]}' > "$FIX/c_ok" 2>/dev/null
assert_eq "200" "$(cat "$FIX/c_ok")" "T0 curl WITH the CA gets HTTP 200 (endpoint is live)"
curl -s --max-time 10 -o /dev/null "$EP/chat/completions" 2>/dev/null
assert_eq 60 "$?" "T0 curl WITHOUT the CA exits 60 (certificate genuinely untrusted)"

# ---------------------------------------------------------------------------
it "T1 CMA_PROVIDER_CA_CERT is honoured: the model VERIFIES over self-signed TLS"
run_mv CMA_PROVIDER_CA_CERT="$FIX/cert.pem"
assert_eq 0 "$MV_RC" "T1 model_verify.py exits 0"
assert_eq "1" "$(mv_field verified_count)" "T1 verified_count=1"
assert_eq "0" "$(mv_field failed_count)" "T1 failed_count=0"
assert_eq "" "$(mv_reason)" "T1 no failure_reason"

# ---------------------------------------------------------------------------
it "T2 anti-bluff control: with the variable UNSET the probe still fails at TLS"
# This is the load-bearing negative. It proves T1's pass came from TRUSTING the
# certificate, not from having stopped verifying certificates.
run_mv CMA_PROVIDER_CA_CERT=
assert_eq "0" "$(mv_field verified_count)" "T2 verified_count=0 without the CA"
_r="$(mv_reason)"
case "$_r" in
  *CERTIFICATE_VERIFY_FAILED*|*certificate*) _pass "T2 failure names the certificate: $_r" ;;
  *) _fail "T2 failure must be the TLS one" "got=$_r" ;;
esac

# ---------------------------------------------------------------------------
it "T3 an unreadable CA path is reported and degrades to SYSTEM verification"
run_mv CMA_PROVIDER_CA_CERT="$FIX/does-not-exist.pem"
assert_eq "0" "$(mv_field verified_count)" "T3 still fails (no silent insecure fallback)"
case "$MV_ERR" in
  *CMA_PROVIDER_CA_CERT*) _pass "T3 stderr names the variable" ;;
  *) _fail "T3 the refusal must be reported on stderr" "stderr=$MV_ERR" ;;
esac

# ---------------------------------------------------------------------------
it "T4 a quote / backslash / newline in the path is refused (parity with the shell path)"
_bad1="$FIX/ca\".pem"; _bad2="$FIX/ca\\\\.pem"; _bad3="$FIX/ca"$'\n'"x.pem"
for _b in "$_bad1" "$_bad2" "$_bad3"; do
  # Make the file genuinely readable so the ONLY thing that can reject it is
  # the character check — otherwise T4 would be indistinguishable from T3.
  cp "$FIX/cert.pem" "$_b" 2>/dev/null
  run_mv CMA_PROVIDER_CA_CERT="$_b"
  assert_eq "0" "$(mv_field verified_count)" "T4 refused, so verification still fails"
  case "$MV_ERR" in
    *CMA_PROVIDER_CA_CERT*) _pass "T4 refusal reported for a path with a quote/backslash/newline" ;;
    *) _fail "T4 refusal must be reported" "stderr=$MV_ERR" ;;
  esac
done

# ---------------------------------------------------------------------------
it "T5 the CA path is env-only — no argv option exposes it (/proc/<pid>/cmdline)"
_h="$(python3 "$MV" --help 2>&1)"
# Compare WHOLE option tokens, never substrings: a bare `--ca` substring test
# matches the legitimate `--catalog` and would refuse a correct program — a
# false-positive refusal is a FAIL-bluff exactly as a false pass is a
# PASS-bluff (§11.4.201). The option list is extracted and matched exactly.
_opts="$(printf '%s' "$_h" | python3 -c '
import re, sys
print("\n".join(sorted(set(re.findall(r"--[A-Za-z0-9][A-Za-z0-9-]*", sys.stdin.read())))))')"
for _opt in --ca --ca-cert --cacert --ca-bundle --ca-file; do
  if printf '%s\n' "$_opts" | grep -qx -- "$_opt"; then
    _fail "T5 $_opt must not be an argv option" "argv is world-readable"
  else
    _pass "T5 no $_opt option on argv"
  fi
done
# Positive control for the extraction above (§11.4.273): it really does find
# options that ARE declared, so the five absences mean absent, not "no input".
if printf '%s\n' "$_opts" | grep -qx -- '--endpoint' \
   && printf '%s\n' "$_opts" | grep -qx -- '--catalog'; then
  _pass "T5 control: the option extractor finds --endpoint and --catalog"
else
  _fail "T5 control failed: extractor found no option list" "got=$_opts"
fi

# ---------------------------------------------------------------------------
it "T6 a plain-HTTP endpoint is unaffected when the variable is set"
_pport="$(start_server plain)"
if [[ -n "$_pport" ]]; then
  MV_EP="http://127.0.0.1:$_pport/v1" run_mv CMA_PROVIDER_CA_CERT="$FIX/cert.pem"
  assert_eq "1" "$(mv_field verified_count)" "T6 plain HTTP still verifies with the CA var set"
else
  echo "    (plain fixture did not come up; T6 not asserted)"
fi

# ---------------------------------------------------------------------------
it "T7 source carries no insecure escape hatch"
# Match CODE, not prose. A flat grep over the file also hits the comment that
# EXPLAINS why these must never be used, so it would refuse a correct program
# — the same false-positive-refusal class as T5's `--ca` (§11.4.201). Comment
# tokens are stripped with python's own tokenizer (exact, unlike a `#` split,
# which would mangle a '#' inside a string literal); string literals are KEPT,
# so a hatch smuggled through eval of a literal is still caught.
_code="$FIX/mv_code_only.py"
python3 - "$MV" > "$_code" <<'PY'
import io, sys, tokenize
src = open(sys.argv[1], encoding="utf-8").read()
out = []
for tok in tokenize.generate_tokens(io.StringIO(src).readline):
    if tok.type != tokenize.COMMENT:
        out.append(tok.string)
sys.stdout.write("\n".join(out))
PY
for _needle in 'CERT_NONE' '_create_unverified_context' 'check_hostname = False' 'check_hostname=False'; do
  if grep -qF "$_needle" "$_code"; then
    _fail "T7 '$_needle' must not appear in model_verify.py CODE" "an insecure mode lets a real MITM pass"
  else
    _pass "T7 no '$_needle' in code"
  fi
done
# Positive controls (§11.4.273). Two of them, because this needs to mean more
# than "the file was read": the extraction must (a) produce code and (b) really
# have dropped comments — otherwise the four absences above are unearned.
if grep -qF 'CMA_PROBE_KEY' "$_code"; then _pass "T7 control: code extract retains real identifiers"
else _fail "T7 control failed" "code extract lost CMA_PROBE_KEY — extraction is broken"; fi
if grep -qF 'CERT_NONE' "$MV" && ! grep -qF 'CERT_NONE' "$_code"; then
  _pass "T7 control: the needle IS present in the file and WAS stripped as a comment (extraction discriminates)"
else
  _pass "T7 control: no commented mention of CERT_NONE to discriminate against (vacuously fine)"
fi

summary
