#!/usr/bin/env bash
# test_jev_detect_https.sh — hermetic coverage for the HTTPS + bearer-key
# transport of the local llmctl decide gateway (llmctl docs/decide-gateway.md:
# HTTPS only, local CA, mandatory `Authorization: Bearer <key>` on /v1/*,
# /healthz open) across the detector, the cache/env export, jev-gate.sh and
# jev_mcp.py. Fixture: fixtures/jev_https_server.py with a self-signed cert
# minted by openssl into the sandbox. Servers bind 127.0.0.1 (the single
# non-loopback case binds ONLY the host's LAN address), are started in the
# parent shell (pid files, no $(...) subshell), and are reaped by an EXIT trap;
# the suite ends by asserting that no fixture process survives.
#
# Classes covered (each mutation in test_jev_detect_https_mutation.sh must fail it):
#  KEY LEAK   : key never in any curl argv (detector, CMA_JEV_LIVE probe, gate);
#               http records carry no key_var/ca_file and no consumer sends a
#               bearer over http; urllib never follows a redirect with the key
#  HOST / CA  : exact loopback grammar (table), CA candidates tried in turn,
#               distinct messages for 401 / 404 / untrusted CA / no key,
#               gate resolves the key from the environment, empty-array safe
#  TRANSPORT  : jev_mcp TLS trust (untrusted refused, JEV_CA_FILE accepted),
#               cache ca_file, cma_jev_env with a missing CA path
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e

PROVIDERS_SH="$SCRIPTS_DIR/claude-providers.sh"
FIX="$SCRIPTS_DIR/tests/fixtures/jev_https_server.py"
SECRET="s3cr3t-key-$$-0123456789abcdef"
KEYS="$HOME/api_keys.sh"; : > "$KEYS"
PDIR="$HOME/.local/share/claude-multi-account/providers"; mkdir -p "$PDIR"
PIDFILES=()
reap_servers() {
  local pf pid
  for pf in "${PIDFILES[@]+"${PIDFILES[@]}"}"; do
    [[ -s "$pf" ]] && { pid="$(cat "$pf")"; kill "$pid" 2>/dev/null; }
  done
  sleep 0.3
}
trap 'reap_servers; cleanup_sandbox' EXIT

CERT="$HOME/gw.crt"; KEY="$HOME/gw.key"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$KEY" -out "$CERT" -days 2 \
  -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" >/dev/null 2>&1
OTHERCERT="$HOME/other.crt"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$HOME/other.key" -out "$OTHERCERT" -days 2 \
  -subj "/CN=unrelated" >/dev/null 2>&1
it "precondition: openssl minted the self-signed certificates"
assert_file "$CERT" "gateway cert exists"
assert_file "$OTHERCERT" "unrelated CA cert exists"

# start_srv <mode> [bind] [logfile] : sets SRV_PORT (parent shell, no subshell)
start_srv() {
  local pf; pf="$(mktemp "$HOME/port.XXXXXX")"; : > "$pf"
  JEV_FIXTURE_LOG="${3:-}" JEV_FIXTURE_REDIRECT_TO="${4:-}" python3 "$FIX" 0 "$pf" "$1" "$CERT" "$KEY" "$SECRET" "${2:-127.0.0.1}" >/dev/null 2>&1 &
  PIDFILES+=("$pf.pid")
  local _
  for _ in $(seq 1 60); do [[ -s "$pf" && -s "$pf.pid" ]] && break; sleep 0.1; done
  SRV_PORT="$(cat "$pf" 2>/dev/null)"
}
TLSLOG="$HOME/tls.log"; PLAINLOG="$HOME/plain.log"; : > "$TLSLOG"; : > "$PLAINLOG"
start_srv tls 127.0.0.1 "$TLSLOG";  TLS_PORT="$SRV_PORT"
start_srv plain 127.0.0.1 "$PLAINLOG"; PLAIN_PORT="$SRV_PORT"

PINS="$HOME/pins.json"
mkpins() { # mkpins <port> [scheme]
  jq -n --argjson p "$1" --arg sc "${2:-https}" '{hosted:{}, local_gateway:{host:"127.0.0.1",port:$p,scheme:$sc,
    health_path:"/healthz",models_path:"/v1/models",systemone_path:"/v1/systemone",key_var:"LLMCTL_API_KEY",
    context_limit:64000,enabled:true}, lan:[]}' > "$PINS"
}
export CMA_JEV_PINS_FILE="$PINS" CMA_KEYS_FILE="$KEYS"
ERRF="$HOME/err.txt"
detect() { env "$@" bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_jev_records' 2>"$ERRF"; }
jl() { jq -c '[.[] | select(.provider_id=="jev-local")] | .[0] // "absent"'; }
err_has() { grep -qF -- "$1" "$ERRF"; }

# ---------------------------------------------------------------- KEY / TLS
it "H1: TLS gateway + right key in env + CA trusted -> https jev-local record"
mkpins "$TLS_PORT"
OUT="$(detect LLMCTL_API_KEY="$SECRET" CMA_JEV_CA_FILE="$CERT")"; R="$(jl <<<"$OUT")"
assert_eq "https://127.0.0.1:$TLS_PORT" "$(jq -r '.base_url // "?"' <<<"$R")" "base_url is https"
assert_eq "jev-tls-fixture" "$(jq -r '.strong_model // "?"' <<<"$R")" "model id read through the authenticated /v1/models"
assert_eq "$CERT" "$(jq -r '.ca_file // "?"' <<<"$R")" "record carries the CA path (non-secret)"
assert_eq "LLMCTL_API_KEY" "$(jq -r '.key_var // "?"' <<<"$R")" "record carries the key var NAME"
assert_eq "null" "$(jq -c '.alias' <<<"$R")" "alias null (decision layer, never an alias)"
case "$OUT$(cat "$ERRF")" in *"$SECRET"*) _fail "key never printed" "key leaked" ;; *) _pass "key value never printed (stdout/stderr)" ;; esac

it "H2: key only in the keys file (not env) -> still detected"
echo "export LLMCTL_API_KEY='$SECRET'" > "$KEYS"
R="$(jl <<<"$(detect CMA_JEV_CA_FILE="$CERT")")"
assert_eq "https://127.0.0.1:$TLS_PORT" "$(jq -r '.base_url // "?"' <<<"$R")" "detected via keys-file key"
: > "$KEYS"

it "H3: wrong key -> 401 -> no record + warning naming HTTP 401, key not echoed"
OUT="$(detect LLMCTL_API_KEY="wrong-key-xyz" CMA_JEV_CA_FILE="$CERT")"
assert_eq '"absent"' "$(jl <<<"$OUT")" "no jev-local record"
err_has "rejected the bearer key (HTTP 401)" && _pass "warning names HTTP 401" || _fail "warning names HTTP 401" "$(cat "$ERRF")"
case "$OUT$(cat "$ERRF")" in *wrong-key-xyz*) _fail "wrong key not echoed" "echoed" ;; *) _pass "wrong key value not echoed" ;; esac

it "H4: no key anywhere -> no record + 'no bearer key' warning"
OUT="$(detect CMA_JEV_CA_FILE="$CERT")"
assert_eq '"absent"' "$(jl <<<"$OUT")" "no jev-local record"
err_has "no bearer key" && _pass "warning says no bearer key" || _fail "no-key warning" "$(cat "$ERRF")"

it "H5: CA not trusted -> no record AND an honest key-free 'not trusted' warning (rc 60)"
OUT="$(detect LLMCTL_API_KEY="$SECRET")"
assert_eq '"absent"' "$(jl <<<"$OUT")" "no jev-local record (verification is never disabled)"
err_has "is not trusted" && _pass "warning says the certificate is not trusted" || _fail "untrusted-CA warning" "$(cat "$ERRF")"
err_has "$SECRET" && _fail "warning is key-free" "key in warning" || _pass "warning is key-free"

it "H5b: models route answering 404 is NOT reported as a rejected key"
start_srv tls404 127.0.0.1; P404="$SRV_PORT"; mkpins "$P404"
OUT="$(detect LLMCTL_API_KEY="$SECRET" CMA_JEV_CA_FILE="$CERT")"
assert_eq '"absent"' "$(jl <<<"$OUT")" "no record"
err_has "models request failed (HTTP 404)" && _pass "message says models request failed (HTTP 404)" || _fail "404 message" "$(cat "$ERRF")"
err_has "rejected the bearer key" && _fail "404 is not a key rejection" "wrong wording" || _pass "404 not worded as a key rejection"

it "H5c: CA candidates are tried in turn (SSL_CERT_FILE unrelated, LLMCTL_HOME CA valid)"
mkdir -p "$HOME/lh/cert/ca"; cp "$CERT" "$HOME/lh/cert/ca/ca.crt"
mkpins "$TLS_PORT"
R="$(jl <<<"$(detect LLMCTL_API_KEY="$SECRET" SSL_CERT_FILE="$OTHERCERT" LLMCTL_HOME="$HOME/lh")")"
assert_eq "https://127.0.0.1:$TLS_PORT" "$(jq -r '.base_url // "?"' <<<"$R")" "detected despite an unrelated SSL_CERT_FILE"
assert_eq "$HOME/lh/cert/ca/ca.crt" "$(jq -r '.ca_file // "?"' <<<"$R")" "ca_file is the CA that actually verified"

# ---------------------------------------------------------------- HTTP policy
it "H6: plain-http loopback server is NOT registered by default (TLS required)"
mkpins "$PLAIN_PORT"
OUT="$(detect LLMCTL_API_KEY="$SECRET")"
assert_eq '"absent"' "$(jl <<<"$OUT")" "no record without opt-in"

it "H6b: CMA_JEV_ALLOW_HTTP=1 registers it with NO key_var and NO ca_file; no bearer is ever sent"
: > "$PLAINLOG"
OUT="$(detect LLMCTL_API_KEY="$SECRET" CMA_JEV_ALLOW_HTTP=1 CMA_JEV_CA_FILE="$CERT")"; R="$(jl <<<"$OUT")"
assert_eq "http://127.0.0.1:$PLAIN_PORT" "$(jq -r '.base_url // "?"' <<<"$R")" "http loopback fallback"
assert_eq "" "$(jq -r '.key_var // ""' <<<"$R")" "http record carries no key_var"
assert_eq "" "$(jq -r '.ca_file // ""' <<<"$R")" "http record carries no ca_file (even with CMA_JEV_CA_FILE set)"
[[ -s "$PLAINLOG" ]] && _pass "positive control: the plain fixture logged the probe requests" || _fail "positive control" "plain log empty"
grep -q 'auth=-' "$PLAINLOG" && ! grep -q 'auth=Bearer' "$PLAINLOG" \
  && _pass "detector sent no Authorization over http" || _fail "detector sent no Authorization over http" "$(cat "$PLAINLOG")"

it "H6c: the gate over that http record sends no Authorization either, and still decides"
: > "$PLAINLOG"; HOOK='{"tool_name":"Bash","tool_input":{"command":"ls"}}'
export JEV_STATE_DIR="$HOME/jev-state"; mkdir -p "$JEV_STATE_DIR"
out="$(printf '%s' "$HOOK" | JEV_BASE_URL="http://127.0.0.1:$PLAIN_PORT" JEV_KEY_VAR=LLMCTL_API_KEY LLMCTL_API_KEY="$SECRET" JEV_API_KEY="$SECRET" JEV_MODE=enforce bash "$SCRIPTS_DIR/jev-gate.sh" 2>/dev/null)"; rc=$?
assert_eq 2 "$rc" "gate reached the http server (deny, exit 2)"
grep -q 'POST /v1/systemone auth=-' "$PLAINLOG" && ! grep -q 'Bearer' "$PLAINLOG" \
  && _pass "gate sent no bearer over http" || _fail "gate sent no bearer over http" "$(cat "$PLAINLOG")"

it "H6d: scheme \"http\" in the pin is an explicit loopback opt-in"
mkpins "$PLAIN_PORT" http
assert_eq "http://127.0.0.1:$PLAIN_PORT" "$(jl <<<"$(detect)" | jq -r '.base_url // "?"')" "registers without the env opt-in"

it "H7: non-loopback plain http is refused (no listener needed): scheme http on 192.0.2.1"
jq -n '{hosted:{}, local_gateway:{enabled:false}, lan:[{id:"lan-1",host:"192.0.2.1",port:9,scheme:"http",enabled:true}]}' > "$PINS"
OUT="$(detect CMA_JEV_ALLOW_HTTP=1)"
assert_eq "0" "$(jq 'length' <<<"$OUT")" "no record"
err_has "refused" && _pass "warning says refused" || _fail "refusal warning" "$(cat "$ERRF")"

it "H8: a real plain-http server on the host's LAN address is refused, with and without scheme"
LANIP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [[ -n "$LANIP" && "$LANIP" != 127.* ]]; then
  start_srv plain "$LANIP"; NL_PORT="$SRV_PORT"
  jq -n --argjson p "$NL_PORT" --arg h "$LANIP" '{hosted:{}, local_gateway:{enabled:false},
    lan:[{id:"lan-1",host:$h,port:$p,scheme:"http",enabled:true}]}' > "$PINS"
  assert_eq "0" "$(jq 'length' <<<"$(detect CMA_JEV_ALLOW_HTTP=1)")" "scheme http on a LAN address refused"
  jq -n --argjson p "$NL_PORT" --arg h "$LANIP" '{hosted:{}, local_gateway:{enabled:false},
    lan:[{id:"lan-1",host:$h,port:$p,enabled:true}]}' > "$PINS"
  assert_eq "0" "$(jq 'length' <<<"$(detect CMA_JEV_ALLOW_HTTP=1)")" "default-scheme LAN pin never downgrades to http"
  err_has "does not speak TLS" && _pass "warning explains the TLS-only policy" || _fail "TLS-only warning" "$(cat "$ERRF")"
else
  _skip "H8: this host has no non-loopback address (hostname -I empty); covered only by H7"
fi

it "H8b: host grammar table (exact loopback match; userinfo and look-alikes rejected)"
hc() { HH="$1" bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; _cma_jev_host_class "$HH"'; }
while IFS='|' read -r h want; do
  assert_eq "$want" "$(hc "$h")" "host '$h' -> $want"
done <<'TBL'
127.0.0.1|loopback
127.1.2.3|loopback
localhost|loopback
::1|loopback
[::1]|loopback
127.evil.example|other
127.0.0.1.nip.io|other
localhost.|other
192.168.1.115|other
127.0.0.1@192.168.1.115|invalid
127.0.0.1/x|invalid
127.0.0.1?x|invalid
127.0.0.1#x|invalid
127.999.1.1|invalid
a b|invalid
TBL

it "H8c: IPv6 literal hosts are bracketed in URLs (exact table)"
uh() { HH="$1" bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; _cma_jev_url_host "$HH"'; }
while IFS='|' read -r h want; do
  assert_eq "$want" "$(uh "$h")" "url host '$h' -> $want"
done <<'TBL'
127.0.0.1|127.0.0.1
localhost|localhost
::1|[::1]
[::1]|[::1]
fe80::1|[fe80::1]
TBL

it "H8d: non-loopback https gateway that fails /healthz (not cert, not plain-http) warns"
jq -n '{hosted:{}, local_gateway:{enabled:false}, lan:[{id:"lan-1",host:"192.0.2.1",port:9,scheme:"https",enabled:true}]}' > "$PINS"
OUT="$(detect CMA_JEV_HTTP_TIMEOUT=1)"
assert_eq "0" "$(jq 'length' <<<"$OUT")" "no record"
err_has "did not answer" && _pass "warning says the gateway did not answer /healthz" || _fail "unreachable-gateway warning" "$(cat "$ERRF")"

it "H9: unreachable port -> []"
mkpins 1
assert_eq "0" "$(jq 'length' <<<"$(detect LLMCTL_API_KEY="$SECRET")")" "no records, no crash"

# ---------------------------------------------------------------- argv hygiene
it "K1: the bearer key never appears on any curl command line (PATH shim; positive control inside)"
SHIM="$HOME/shim"; mkdir -p "$SHIM"; ARGV="$HOME/curl_argv.log"; : > "$ARGV"
REALCURL="$(command -v curl)"
cat > "$SHIM/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$ARGV"
exec "$REALCURL" "\$@"
SH
chmod +x "$SHIM/curl"
PATH="$SHIM:$PATH" curl -sS --max-time 1 --header "X-Control: CONTROL_MARKER_123" http://127.0.0.1:1/ >/dev/null 2>&1
grep -q CONTROL_MARKER_123 "$ARGV" && _pass "positive control: the shim sees argv" || _fail "positive control" "shim blind"
# detector (TLS path)
mkpins "$TLS_PORT"
PATH="$SHIM:$PATH" detect LLMCTL_API_KEY="$SECRET" CMA_JEV_CA_FILE="$CERT" >/dev/null
# gate (TLS path)
printf '%s' "$HOOK" | PATH="$SHIM:$PATH" JEV_BASE_URL="https://127.0.0.1:$TLS_PORT" JEV_CA_FILE="$CERT" JEV_API_KEY="$SECRET" JEV_MODE=enforce bash "$SCRIPTS_DIR/jev-gate.sh" >/dev/null 2>&1
# CMA_JEV_LIVE hosted probe
jq -n --argjson p "$TLS_PORT" '{hosted:{typesafe:{key_var:"TYPESAFE_API_KEY",base_url:("https://127.0.0.1:"+($p|tostring)),
  systemone_path:"/v1/systemone",models:["jev-latest"],context_limit:64000,enabled:true}}, local_gateway:{enabled:false}, lan:[]}' > "$PINS"
echo "export TYPESAFE_API_KEY='$SECRET'" > "$KEYS"
PATH="$SHIM:$PATH" detect CMA_JEV_LIVE=1 >/dev/null; : > "$KEYS"
[[ "$(grep -c . "$ARGV")" -ge 5 ]] && _pass "shim logged the detector, gate and live-probe curls ($(grep -c . "$ARGV") lines)" || _fail "shim coverage" "only $(grep -c . "$ARGV") lines"
grep -qF -- "$SECRET" "$ARGV" && _fail "key absent from every curl argv" "$(grep -F -- "$SECRET" "$ARGV" | head -2)" || _pass "key absent from every curl argv"

# ---------------------------------------------------------------- gate env key
it "K2: jev-gate resolves JEV_KEY_VAR from the environment when there is no keys file"
mkpins "$TLS_PORT"; : > "$TLSLOG"
rm -f "$KEYS"
# the https origin + key variable must be attested by a pin before the key is released
jq --arg o "https://127.0.0.1:$TLS_PORT" '.hosted.t = {base_url:$o, key_var:"LLMCTL_API_KEY", enabled:true}' "$PINS" > "$PINS.x" && mv "$PINS.x" "$PINS"
out="$(printf '%s' "$HOOK" | JEV_BASE_URL="https://127.0.0.1:$TLS_PORT" JEV_CA_FILE="$CERT" JEV_KEY_VAR=LLMCTL_API_KEY LLMCTL_API_KEY="$SECRET" JEV_API_KEY= TYPESAFE_API_KEY= JEV_MODE=enforce bash "$SCRIPTS_DIR/jev-gate.sh" 2>/dev/null)"; rc=$?
assert_eq 2 "$rc" "TLS + CA + env key (no keys file) -> real deny decision"
grep -q "POST /v1/systemone auth=Bearer $SECRET" "$TLSLOG" && _pass "sink-side: the gateway saw the real bearer" || _fail "gateway saw the real bearer" "$(cat "$TLSLOG")"
: > "$KEYS"

it "K3: jev-gate over TLS without the CA fails open (exit 0, no JSON)"
: > "$JEV_STATE_DIR/decisions.jsonl"
out="$(printf '%s' "$HOOK" | JEV_BASE_URL="https://127.0.0.1:$TLS_PORT" JEV_API_KEY="$SECRET" JEV_MODE=enforce bash "$SCRIPTS_DIR/jev-gate.sh" 2>/dev/null)"; rc=$?
assert_eq 0 "$rc" "untrusted CA -> fail-open exit 0"
assert_eq "" "$out" "fail-open emits no decision JSON"
# Positive evidence the fail-open path above was actually reached because the
# curl call failed (untrusted CA), not because exit 0 + empty stdout happened
# for some unrelated reason (e.g. an early, different return): the gate's own
# decisions.jsonl record for this run must carry the "tls_untrusted"
# fallback it writes only from that curl-failure branch (curl rc 60; before
# 2026-10-24 every curl failure was lumped together as "endpoint_error").
assert_eq "tls_untrusted" "$(tail -n1 "$JEV_STATE_DIR/decisions.jsonl" | jq -r '.fallback // "?"')" "sink-side: decisions.jsonl logs the untrusted-CA curl failure as tls_untrusted"

# ---------------------------------------------------------------- cache / env
it "H10: endpoint cache carries ca_file; cma_jev_env exports JEV_CA_FILE (not SSL_CERT_FILE)"
mkpins "$TLS_PORT"
RECS="$(detect LLMCTL_API_KEY="$SECRET" CMA_JEV_CA_FILE="$CERT")"
RECS="$RECS" bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; _cma_jev_write_endpoint_cache "$RECS"'
assert_eq "$CERT" "$(jq -r '.endpoints[0].ca_file // "?"' "$PDIR/jev-endpoints.json")" "cache endpoints[0].ca_file"
envrun() { env -u SSL_CERT_FILE CMA_JEV_QUIET=1 bash -c 'source "'"$SCRIPTS_DIR/lib.sh"'" >/dev/null 2>&1; set +e; cma_jev_env; printf "%s|%s|%s" "${JEV_CA_FILE:-}" "${JEV_BASE_URL:-}" "${SSL_CERT_FILE:-}"'; }
assert_eq "$CERT|https://127.0.0.1:$TLS_PORT|" "$(envrun)" "JEV_CA_FILE+https base exported, SSL_CERT_FILE untouched"

it "H10b: a cache whose ca_file no longer exists exports NO JEV_CA_FILE"
jq '.endpoints[0].ca_file = "/nonexistent/ca.crt"' "$PDIR/jev-endpoints.json" > "$PDIR/x.json" && mv "$PDIR/x.json" "$PDIR/jev-endpoints.json"
assert_eq "|https://127.0.0.1:$TLS_PORT|" "$(envrun)" "missing CA path -> JEV_CA_FILE unset"

# ---------------------------------------------------------------- jev_mcp TLS
it "M1: jev_mcp over TLS - untrusted CA refused, JEV_CA_FILE accepted"
mcp() { env "$@" python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import jev_mcp; print(jev_mcp._tool_jev_models({}))' "$SCRIPTS_DIR" 2>&1; }
OUT="$(mcp JEV_BASE_URL="https://127.0.0.1:$TLS_PORT" JEV_API_KEY="$SECRET")"; rc=$?
case "$OUT" in *"jev-tls-fixture"*) _fail "untrusted CA is refused" "models returned: $OUT" ;; *) _pass "untrusted CA refused (no models returned)" ;; esac
OUT="$(mcp JEV_BASE_URL="https://127.0.0.1:$TLS_PORT" JEV_API_KEY="$SECRET" JEV_CA_FILE="$CERT")"
case "$OUT" in *"jev-tls-fixture"*) _pass "JEV_CA_FILE accepted: models returned" ;; *) _fail "JEV_CA_FILE accepted" "$OUT" ;; esac

it "M2: jev_mcp never follows a redirect with the key (sink-side: the redirect target saw nothing)"
: > "$PLAINLOG"
start_srv redirect 127.0.0.1 "" "http://127.0.0.1:$PLAIN_PORT/v1/models"; RD_PORT="$SRV_PORT"
curl -s "http://127.0.0.1:$PLAIN_PORT/healthz" >/dev/null
[[ -s "$PLAINLOG" ]] && _pass "positive control: the redirect target logs a direct hit" || _fail "positive control" "target log empty"
: > "$PLAINLOG"
OUT="$(mcp JEV_BASE_URL="https://127.0.0.1:$RD_PORT" JEV_API_KEY="$SECRET" JEV_CA_FILE="$CERT")"
case "$OUT" in *"302"*|*"edirect"*|*"rror"*) _pass "the 302 surfaced as an error, not followed" ;; *) _fail "302 not followed" "$OUT" ;; esac
[[ ! -s "$PLAINLOG" ]] && _pass "redirect target received no request at all (key not replayed)" || _fail "redirect target untouched" "$(cat "$PLAINLOG")"

# ---------------------------------------------------------------- hygiene
it "Z: every fixture server started by this suite is reaped (no leaked process)"
reap_servers
alive=0
for pf in "${PIDFILES[@]}"; do [[ -s "$pf" ]] && kill -0 "$(cat "$pf")" 2>/dev/null && alive=$((alive+1)); done
assert_eq 0 "$alive" "no recorded fixture pid is still alive (${#PIDFILES[@]} started)"
leak="$(pgrep -f "jev_https_server.py .*$HOME" | wc -l)"
assert_eq 0 "$leak" "no process with this sandbox in its cmdline survives"
[[ ${#PIDFILES[@]} -ge 5 ]] && _pass "positive control: the suite did start servers (${#PIDFILES[@]})" || _fail "positive control" "only ${#PIDFILES[@]} servers"

summary
