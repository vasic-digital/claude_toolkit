#!/usr/bin/env bash
# test_jev_hosted_live_fixes.sh - regression tests for the five defects the live
# hosted-Jev validation (2026-10-24, TypeSafe /v1/systemone) found in the toolkit.
# No real endpoint and no real key are used: every server is a loopback stub
# (fixtures/jev_hosted_stub.py for the plain-http wire contract,
# fixtures/jev_https_server.py for TLS/auth) and every key is a dummy built from
# fragments.
#
#  T1  CMA_JEV_LIVE=1 probe sends `questions` as a MAP (name -> {type,
#      instructions,...}); the stub answers 422 to the old ARRAY form, so
#      sync-jev with CMA_JEV_LIVE=1 must RESOLVE the hosted endpoint.
#  T2  sync-jev honours CMA_PROVIDERS_DIR for the endpoint cache, the status
#      bookkeeping, the jev state dir and the kimi twin hook refresh; a
#      read-only hostile HOME stand-in stays byte-identical.
#  T3  the shipped pins list jev-1.13.0 AND jev-1.14.0 (jev-latest last).
#  T4  jev-gate latency_ms has millisecond resolution; decisions.jsonl carries
#      the `class` field the canon token-reduction gate (clause 4) requires.
#  T5  jev-gate logs distinct fallbacks (auth_rejected / tls_untrusted /
#      unreachable / timeout) and never sends a bearer when no key is found
#      over https (no_key, sink-side proof: zero requests reached the server).
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
# Hermeticity (test defect, fixed 2026-10-27): T7a asserts "no request at all (OPENROUTER_API_KEY is unset)" for a
# gate run with JEV_KEY_VAR=OPENROUTER_API_KEY, but nothing unset it. A runner that EXPORTS OPENROUTER_API_KEY - this host
# does - makes the gate read that variable, find it set and legitimately send the request, so the sink logs 1 line and
# the case fails for a reason unrelated to the code under test (reproduced on the unmodified v1.33.0 tree: fails with the
# variable exported, passes under `env -u OPENROUTER_API_KEY`). Cases that need the variable set pass it inline.
unset OPENROUTER_API_KEY

PROVIDERS_SH="$SCRIPTS_DIR/claude-providers.sh"
GATE="$SCRIPTS_DIR/jev-gate.sh"
STUB="$SCRIPTS_DIR/tests/fixtures/jev_hosted_stub.py"
TLSFIX="$SCRIPTS_DIR/tests/fixtures/jev_https_server.py"
SHIPPED_PINS="$SCRIPTS_DIR/providers/jev.json"
# dummy key built from fragments: never a real value, never one literal token
DUMMY="dum""my-k""ey-$$-0123456789"
WRONG="wr""ong-k""ey-$$-9876543210"

PIDFILES=()
reap() {
  local pf pid
  for pf in "${PIDFILES[@]+"${PIDFILES[@]}"}"; do
    [[ -s "$pf" ]] && { pid="$(cat "$pf")"; kill "$pid" 2>/dev/null; }
  done
}
RO_DIRS=()
cleanup_all() {
  local d
  reap
  for d in "${RO_DIRS[@]+"${RO_DIRS[@]}"}"; do chmod -R u+w -- "$d" 2>/dev/null; done
  cleanup_sandbox
}
trap cleanup_all EXIT

# start_stub [delay] [logfile]  -> STUB_PORT   (parent shell, no subshell)
start_stub() {
  local pf; pf="$(mktemp "$HOME/stubport.XXXXXX")"; : > "$pf"
  JEV_STUB_DELAY="${1:-0}" JEV_STUB_LOG="${2:-}" python3 "$STUB" 0 "$pf" >/dev/null 2>&1 &
  PIDFILES+=("$pf.pid")
  local _
  for _ in $(seq 1 60); do [[ -s "$pf" && -s "$pf.pid" ]] && break; sleep 0.1; done
  STUB_PORT="$(cat "$pf" 2>/dev/null)"
}
# start_tls <logfile> [mode]  -> TLS_PORT
CERT="$HOME/gw.crt"; TKEY="$HOME/gw.key"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TKEY" -out "$CERT" -days 2 \
  -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" >/dev/null 2>&1
start_tls() {
  local pf; pf="$(mktemp "$HOME/tlsport.XXXXXX")"; : > "$pf"
  JEV_FIXTURE_LOG="${1:-}" python3 "$TLSFIX" 0 "$pf" "${2:-tls}" "$CERT" "$TKEY" "$DUMMY" 127.0.0.1 >/dev/null 2>&1 &
  PIDFILES+=("$pf.pid")
  local _
  for _ in $(seq 1 60); do [[ -s "$pf" && -s "$pf.pid" ]] && break; sleep 0.1; done
  TLS_PORT="$(cat "$pf" 2>/dev/null)"
}
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }

it "precondition: stub servers start and the TLS fixture cert exists"
start_stub 0 "$HOME/stub0.log"
assert_file "$CERT" "self-signed cert minted"
[[ "$STUB_PORT" =~ ^[0-9]+$ ]] && _pass "plain stub listening on $STUB_PORT" || _fail "plain stub listening" "port='$STUB_PORT'"

# ===========================================================================
# T1 - live probe wire format
# ===========================================================================
it "T1a: the stub REJECTS the array form with 422 (negative control for the wire contract)"
code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 -X POST "http://127.0.0.1:$STUB_PORT/v1/systemone" \
  -H 'Content-Type: application/json' \
  -d '{"model":"jev-latest","state":"s","questions":[{"name":"probe","type":"noul","instructions":"x"}]}')"
assert_eq 422 "$code" "array-form questions -> HTTP 422"
code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 -X POST "http://127.0.0.1:$STUB_PORT/v1/systemone" \
  -H 'Content-Type: application/json' \
  -d '{"model":"jev-latest","state":"s","questions":{"probe":{"type":"noul","instructions":"x","criteria":{"true":"a","false":"b"}}}}')"
assert_eq 200 "$code" "map-form questions -> HTTP 200"

KEYS="$HOME/api_keys.sh"
printf "export TYPESAFE_API_KEY='%s'\n" "$DUMMY" > "$KEYS"
PINS="$HOME/pins.json"
jq -n --argjson p "$STUB_PORT" '{hosted:{typesafe:{key_var:"TYPESAFE_API_KEY",base_url:("http://127.0.0.1:"+($p|tostring)),
  systemone_path:"/v1/systemone",models:["jev-1.13.0","jev-latest"],context_limit:64000,enabled:true}},
  local_gateway:{enabled:false}, lan:[]}' > "$PINS"

it "T1b: detect_jev_records with CMA_JEV_LIVE=1 RESOLVES the hosted endpoint (not 'unverified')"
: > "$HOME/stub0.log"
OUT="$(env -u LLMCTL_API_KEY CMA_JEV_PINS_FILE="$PINS" CMA_KEYS_FILE="$KEYS" CMA_JEV_LIVE=1 \
  bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_jev_records' 2>/dev/null)"
REC="$(jq -c '[.[] | select(.provider_id=="jev-typesafe")] | .[0] // "absent"' <<<"$OUT")"
assert_eq "resolved" "$(jq -r '.status // "?"' <<<"$REC")" "jev-typesafe status (reason: $(jq -r '.reason // "?"' <<<"$REC"))"
grep -q '^POST /v1/systemone ' "$HOME/stub0.log" && _pass "sink-side: the stub received the live probe POST" || _fail "stub received the probe POST" "$(cat "$HOME/stub0.log")"
case "$OUT" in *"$DUMMY"*) _fail "key never printed" "key in detector output" ;; *) _pass "key value never in detector output" ;; esac

it "T1c: sync-jev with CMA_JEV_LIVE=1 writes the endpoint into the cache (end to end)"
PROV="$HOME/.local/share/claude-multi-account/providers"
rm -f "$PROV/jev-endpoints.json"
env -u LLMCTL_API_KEY CMA_JEV_PINS_FILE="$PINS" CMA_KEYS_FILE="$KEYS" CMA_JEV_LIVE=1 \
  bash "$PROVIDERS_SH" sync-jev --quiet >/dev/null 2>&1
assert_eq "1" "$(jq '.endpoints | length' "$PROV/jev-endpoints.json" 2>/dev/null || echo ERR)" "cache holds 1 endpoint"
assert_eq "jev-typesafe" "$(jq -r '.endpoints[0].provider_id // "?"' "$PROV/jev-endpoints.json" 2>/dev/null)" "the hosted endpoint was kept"

# ===========================================================================
# T2 - CMA_PROVIDERS_DIR honoured by sync-jev
# ===========================================================================
it "T2: sync-jev under CMA_PROVIDERS_DIR touches nothing in a WRITABLE hostile HOME (a swallowed write would show in the snapshot)"
POISON="$(mktemp -d "$HOME/poison.XXXXXX")"
mkdir -p "$POISON/.kimi-prov-x" "$POISON/.local/state/jev" "$POISON/.local/share/claude-multi-account/providers"
printf 'default_model = "m"\n# cma-jev:hooks BEGIN\nstale-home\n# cma-jev:hooks END\n' > "$POISON/.kimi-prov-x/config.toml"
printf 'sentinel\n' > "$POISON/.local/share/claude-multi-account/providers/jev-endpoints.json"
printf 'sentinel\n' > "$POISON/api_keys.sh"
ISO="$(mktemp -d "$HOME/iso.XXXXXX")"
mkdir -p "$ISO/prov/kimi-twins/.kimi-prov-x"
printf 'default_model = "m"\n# cma-jev:hooks BEGIN\nstale-iso\n# cma-jev:hooks END\n' > "$ISO/prov/kimi-twins/.kimi-prov-x/config.toml"
printf "export TYPESAFE_API_KEY='%s'\n" "$DUMMY" > "$ISO/keys.sh"
snap() { (cd "$1" && find . -print0 | sort -z | xargs -0 stat -c '%n %a %s %Y' 2>/dev/null; find . -type f -print0 | sort -z | xargs -0 sha256sum 2>/dev/null) | sha256sum | cut -c1-64; }
BEFORE="$(snap "$POISON")"
env -u JEV_STATE_DIR -u LLMCTL_API_KEY HOME="$POISON" CMA_PROVIDERS_DIR="$ISO/prov" CMA_KEYS_FILE="$ISO/keys.sh" \
  CMA_JEV_PINS_FILE="$PINS" bash "$PROVIDERS_SH" sync-jev --quiet >"$ISO/out.txt" 2>&1
rc=$?
AFTER="$(snap "$POISON")"
assert_eq 0 "$rc" "sync-jev exits 0 with the hostile HOME ($(head -c 200 "$ISO/out.txt" | tr '\n' ' '))"
assert_eq "$BEFORE" "$AFTER" "HOME stand-in is byte-identical (names, modes, sizes, mtimes, sha256)"
assert_eq "1" "$(jq '.endpoints | length' "$ISO/prov/jev-endpoints.json" 2>/dev/null || echo ERR)" "endpoint cache written under CMA_PROVIDERS_DIR"
assert_file "$ISO/prov/status.json" "status bookkeeping written under CMA_PROVIDERS_DIR"
grep -q 'stale-iso' "$ISO/prov/kimi-twins/.kimi-prov-x/config.toml" && _fail "kimi twin under CMA_PROVIDERS_DIR refreshed" "stale hook block still present" || _pass "kimi twin under CMA_PROVIDERS_DIR was refreshed (stale hook block stripped)"
grep -q 'stale-home' "$POISON/.kimi-prov-x/config.toml" && _pass "kimi twin under the real HOME left untouched" || _fail "HOME kimi twin untouched" "stale block gone"

# ===========================================================================
# T3 - pins
# ===========================================================================
it "T3: shipped pins list jev-1.13.0 and jev-1.14.0, jev-latest stays the default (last)"
assert_jq "$SHIPPED_PINS" '.hosted.typesafe.models | index("jev-1.13.0") != null' "true" "jev-1.13.0 still listed (server still serves it)"
assert_jq "$SHIPPED_PINS" '.hosted.typesafe.models | index("jev-1.14.0") != null' "true" "jev-1.14.0 listed (what jev-latest resolves to now)"
assert_jq "$SHIPPED_PINS" '.hosted.typesafe.models[-1]' "jev-latest" "jev-latest is last = detector default model"
tr '\n' ' ' < "$SCRIPTS_DIR/../docs/jev/Jev_User_Guide.md" | grep -q 'jev-latest. resolved server-side to .jev-1\.14\.0.*UNCONFIRMED' && _pass "user guide states jev-latest -> jev-1.14.0 as an UNCONFIRMED observation" || _fail "user guide states jev-latest -> jev-1.14.0 as an UNCONFIRMED observation" "not found"

# ===========================================================================
# T4 - latency + class
# ===========================================================================
export JEV_STATE_DIR="$HOME/.local/state/jev-t4"
gate() { # gate <json> [env...]  - hermetic against the caller's ambient JEV/key env
  local hook="$1"; shift
  printf '%s' "$hook" | env -u JEV_API_KEY -u TYPESAFE_API_KEY -u JEV_KEY_VAR -u JEV_CA_FILE \
    -u CMA_JEV_ENDPOINT_ID -u JEV_GATE_FAIL -u JEV_GATE -u LLMCTL_API_KEY \
    CMA_KEYS_FILE="$HOME/no-such-keys.sh" "$@" bash "$GATE"
}
HOOK='{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
lastlog() { tail -n1 "$JEV_STATE_DIR/decisions.jsonl"; }

it "T4a: a ~300 ms endpoint is logged with millisecond latency (250..2000, not a 1000-multiple)"
start_stub 0.3 ""; SLOW_PORT="$STUB_PORT"
rm -rf "$JEV_STATE_DIR"
gate "$HOOK" JEV_BASE_URL="http://127.0.0.1:$SLOW_PORT" JEV_MODE=shadow JEV_GATE_TIMEOUT=5 >/dev/null 2>&1
L="$(lastlog)"; LAT="$(jq -r '.latency_ms' <<<"$L")"
[[ "$LAT" =~ ^[0-9]+$ && "$LAT" -ge 250 && "$LAT" -le 2000 ]] && _pass "latency_ms=$LAT within 250..2000" || _fail "latency_ms within 250..2000" "latency_ms=$LAT"
[[ "$LAT" =~ ^[0-9]+$ ]] && (( LAT % 1000 != 0 )) && _pass "latency_ms=$LAT is not a whole-second value" || _fail "latency_ms not a whole-second value" "latency_ms=$LAT"

it "T4b: latency over several runs is not quantised to whole seconds"
quant=0
for _i in 1 2 3; do
  gate "$HOOK" JEV_BASE_URL="http://127.0.0.1:$SLOW_PORT" JEV_MODE=shadow JEV_GATE_TIMEOUT=5 >/dev/null 2>&1
  v="$(jq -r '.latency_ms' <<<"$(lastlog)")"
  (( v % 1000 == 0 )) && quant=$((quant+1))
done
assert_eq 0 "$quant" "no run logged a multiple-of-1000 latency"

it "T4c: decisions.jsonl carries class=gate (canon cm_jev_token_reduction clause 4 field) next to question/answer"
assert_eq "gate" "$(jq -r '.class // "ABSENT"' <<<"$L")" "class field"
assert_eq "gate" "$(jq -r '.question // "ABSENT"' <<<"$L")" "question field kept"
assert_eq "true" "$(jq -r 'has("answer")' <<<"$L")" "answer field kept"
gate "$HOOK" JEV_BASE_URL="http://127.0.0.1:$(free_port)" JEV_MODE=shadow JEV_GATE_TIMEOUT=2 >/dev/null 2>&1
assert_eq "gate" "$(jq -r '.class // "ABSENT"' <<<"$(lastlog)")" "class also present on fallback lines"
CANON_GATE="${CMA_CANON_TOKEN_REDUCTION_GATE:-}"
if [[ -n "$CANON_GATE" && -x "$CANON_GATE" ]]; then
  : > "$HOME/before.jsonl"; : > "$HOME/after.jsonl"
  out="$(JEV_BEFORE="$HOME/before.jsonl" JEV_AFTER="$HOME/after.jsonl" JEV_DECISIONS="$JEV_STATE_DIR/decisions.jsonl" JEV_GATED_CLASSES=gate bash "$CANON_GATE" 2>&1)"
  grep -q 'clause4' <<<"$out" && _fail "canon clause 4 accepts the log" "$out" || _pass "canon gate clause 4 raises no clause4 error against the gate log"
else
  _skip "canon cm_jev_token_reduction.sh not provided (set CMA_CANON_TOKEN_REDUCTION_GATE to cross-check)"
fi

# ===========================================================================
# T5 - distinct fallbacks, no bearer without a key
# ===========================================================================
export JEV_STATE_DIR="$HOME/.local/state/jev-t5"
fb() { jq -r '.fallback // "none"' <<<"$(lastlog)"; }

it "T5a: wrong key over https -> fallback auth_rejected (401), fail-open exit 0"
TLSLOG="$HOME/tls.log"; : > "$TLSLOG"; start_tls "$TLSLOG"
rm -rf "$JEV_STATE_DIR"
gate "$HOOK" JEV_BASE_URL="https://127.0.0.1:$TLS_PORT" JEV_CA_FILE="$CERT" JEV_API_KEY="$WRONG" JEV_MODE=shadow >/dev/null 2>&1
assert_eq 0 "$?" "fail-open exit"
assert_eq "auth_rejected" "$(fb)" "401 is logged as auth_rejected"
grep -q "POST /v1/systemone auth=Bearer $WRONG" "$TLSLOG" && _pass "sink-side: the server did see the (wrong) bearer and refused it" || _fail "server saw the request" "$(cat "$TLSLOG")"

it "T5b: https without the CA -> fallback tls_untrusted"
gate "$HOOK" JEV_BASE_URL="https://127.0.0.1:$TLS_PORT" JEV_API_KEY="$DUMMY" JEV_MODE=shadow >/dev/null 2>&1
assert_eq "tls_untrusted" "$(fb)" "untrusted certificate is logged as tls_untrusted"

it "T5c: nothing listening -> fallback unreachable"
gate "$HOOK" JEV_BASE_URL="http://127.0.0.1:$(free_port)" JEV_MODE=shadow JEV_GATE_TIMEOUT=2 >/dev/null 2>&1
assert_eq "unreachable" "$(fb)" "connection refused is logged as unreachable"

it "T5d: slow endpoint beyond JEV_GATE_TIMEOUT -> fallback timeout"
start_stub 3 ""; TO_PORT="$STUB_PORT"
gate "$HOOK" JEV_BASE_URL="http://127.0.0.1:$TO_PORT" JEV_MODE=shadow JEV_GATE_TIMEOUT=1 >/dev/null 2>&1
assert_eq "timeout" "$(fb)" "curl rc 28 is logged as timeout"

it "T5e: https and NO key anywhere -> no request is sent at all; fallback no_key"
: > "$TLSLOG"
gate "$HOOK" JEV_BASE_URL="https://127.0.0.1:$TLS_PORT" JEV_CA_FILE="$CERT" JEV_MODE=shadow >/dev/null 2>&1
assert_eq 0 "$?" "fail-open exit"
assert_eq "no_key" "$(fb)" "missing key is logged as no_key"
assert_eq "0" "$(grep -c . "$TLSLOG")" "sink-side: zero requests reached the server (no literal bearer 'local' sent)"
grep -q 'Bearer local' "$TLSLOG" && _fail "no literal 'local' bearer" "sent" || _pass "no literal 'local' bearer on the wire"

it "T5f: JEV_GATE_FAIL=closed + enforce + no key -> deny (still no request)"
gate "$HOOK" JEV_BASE_URL="https://127.0.0.1:$TLS_PORT" JEV_CA_FILE="$CERT" JEV_MODE=enforce JEV_GATE_FAIL=closed >/dev/null 2>&1
assert_eq 2 "$?" "fail-closed denies when no key"
assert_eq "0" "$(grep -c . "$TLSLOG")" "sink-side: still zero requests"

it "T5g: positive control - right key + CA -> real decision, no fallback"
gate "$HOOK" JEV_BASE_URL="https://127.0.0.1:$TLS_PORT" JEV_CA_FILE="$CERT" JEV_API_KEY="$DUMMY" JEV_MODE=shadow >/dev/null 2>&1
assert_eq "none" "$(fb)" "no fallback on success"
assert_eq "deny" "$(jq -r '.answer' <<<"$(lastlog)")" "the fixture's real deny answer was logged"
assert_eq "gate" "$(jq -r '.class' <<<"$(lastlog)")" "class on a success line"

it "T5h: plain http with no key still works (no bearer is ever sent over http)"
gate "$HOOK" JEV_BASE_URL="http://127.0.0.1:$SLOW_PORT" JEV_MODE=shadow JEV_GATE_TIMEOUT=5 >/dev/null 2>&1
assert_eq "none" "$(fb)" "http without key -> normal decision"

# ===========================================================================
# T5i - 403 maps to auth_rejected (mutant M3: 403 no longer mapped survived)
# ===========================================================================
it "T5i: HTTP 403 over https -> fallback auth_rejected (not endpoint_error)"
FLOG="$HOME/forbid.log"; : > "$FLOG"; _MAIN_TLS="$TLS_PORT"; start_tls "$FLOG" forbid; FB_PORT="$TLS_PORT"; TLS_PORT="$_MAIN_TLS"
gate "$HOOK" JEV_BASE_URL="https://127.0.0.1:$FB_PORT" JEV_CA_FILE="$CERT" JEV_API_KEY="$DUMMY" JEV_MODE=shadow >/dev/null 2>&1
assert_eq 0 "$?" "fail-open exit"
assert_eq "auth_rejected" "$(fb)" "403 is logged as auth_rejected"
grep -q '^POST /v1/systemone' "$FLOG" && _pass "sink-side: the 403 server received the request" || _fail "403 server received the request" "$(cat "$FLOG")"

# ===========================================================================
# T6 - CMA_PROVIDERS_DIR: writers AND readers agree
# ===========================================================================
it "T6a: after sync-jev under CMA_PROVIDERS_DIR a LAUNCH-SIDE read finds the cache (cma_jev_env ACTIVE, no re-kick)"
T6H="$(mktemp -d "$HOME/t6home.XXXXXX")"; T6P="$T6H/prov"
env -u JEV_STATE_DIR -u LLMCTL_API_KEY HOME="$T6H" CMA_PROVIDERS_DIR="$T6P" CMA_KEYS_FILE="$KEYS" \
  CMA_JEV_PINS_FILE="$PINS" bash "$PROVIDERS_SH" sync-jev --quiet >/dev/null 2>&1
assert_file "$T6P/jev-endpoints.json" "writer put the cache under CMA_PROVIDERS_DIR"
R="$(env -u JEV_STATE_DIR HOME="$T6H" CMA_PROVIDERS_DIR="$T6P" CMA_JEV_QUIET=1 CMA_JEV_CACHE_TTL=99999 \
  bash -c 'source "'"$SCRIPTS_DIR"'/lib.sh"; unset CMA_JEV_REFRESH_KICKED; cma_jev_env; echo "active=${CMA_JEV_ACTIVE:-?} kicked=${CMA_JEV_REFRESH_KICKED:-0} base=${JEV_BASE_URL:-}"' 2>/dev/null)"
assert_eq "active=1 kicked=0 base=$(jq -r '.endpoints[0].base_url' "$T6P/jev-endpoints.json")" "$R" "reader resolves the endpoint the writer stored"

it "T6b: launch-side readers use the same directory (run: unknown-provider message, kimi twin home)"
OUTR="$(env HOME="$T6H" CMA_PROVIDERS_DIR="$T6P" bash -c 'source "'"$SCRIPTS_DIR"'/lib.sh"; source <(_cma_emit_cma_run_provider); cma_run_provider no-such-id' 2>&1 | head -3)"
case "$OUTR" in *"$T6P/no-such-id.env"*) _pass "run reads <CMA_PROVIDERS_DIR>/<id>.env" ;; *) _fail "run reads <CMA_PROVIDERS_DIR>/<id>.env" "$OUTR" ;; esac
KH="$(env HOME="$T6H" CMA_PROVIDERS_DIR="$T6P" bash -c 'source "'"$SCRIPTS_DIR"'/lib.sh"; cma_kimi_provider_home abc')"
assert_eq "$T6P/kimi-twins/.kimi-prov-abc" "$KH" "kimi twin home follows CMA_PROVIDERS_DIR (matches the hook-refresh scan root)"
KH0="$(env -u CMA_PROVIDERS_DIR HOME="$T6H" bash -c 'source "'"$SCRIPTS_DIR"'/lib.sh"; cma_kimi_provider_home abc')"
assert_eq "$T6H/.kimi-prov-abc" "$KH0" "unset CMA_PROVIDERS_DIR keeps the historical \$HOME location"

it "T6c: no non-comment code in any shipped script (sh/js/py) hardcodes the default providers dir or a kimi twin home, except override-aware expansions and the reasoned allow-list"
# A line is accepted when it is the override-aware default-expansion form
#   ${CMA_PROVIDERS_DIR:-$HOME/.local/share/claude-multi-account/providers}
#   ${<root>:-$HOME}/.kimi-prov-*     (root computed from CMA_PROVIDERS_DIR)
# or it routes through the helper functions. Merely mentioning CMA_PROVIDERS_DIR is NOT enough.
# Allow-list (file|fixed substring|reason) - every entry states why the line is exempt:
T6C_ALLOW=(
  'opencode-jev-plugin.js|join(homedir(), ".local/share/claude-multi-account/providers")|documented fallback of the CMA_PROVIDERS_DIR override on the previous line'
  'opencode-jev-plugin.js|join(homedir(), ".local/state/jev")|JEV_STATE_DIR default; a state dir, not the providers dir'
  'opencode-jev-plugin.js|join(process.env.JEV_CONFIG_DIR || join(homedir(), ".config/jev")|JEV_CONFIG_DIR default; the jev config dir (env, key-files), overridable, not the providers dir'
  'opencode-jev-plugin.js|join(homedir(), p.slice(2))|expands a user-written ~/ path from the key-files list'
  'jev_mcp.py|os.environ.get("CMA_PROVIDERS_DIR") or os.path.join(|override-aware: CMA_PROVIDERS_DIR first, the literal is only its documented default'
  'alias_e2e_test.py|os.path.expanduser("~/.local/share/claude-multi-account/providers")|deliberate real-host end-to-end test of the operator own aliases'
  'kimi-providers.sh|twin aliases, and each twin|usage text, not a path used by code'
  'claude-install-verify.sh|_ok "kimi: ~/.kimi-prov-|message text'
  'claude-install-verify.sh|_fail "kimi: ~/.kimi-prov-|message text'
  'claude-install-verify.sh|sed |strips the prefix from a basename'
  'lib.sh|KIMI_PROVIDER_PREFIX=".kimi-prov-"|the prefix constant itself'
)
BAD=""
shopt -s nullglob
for fp in "$SCRIPTS_DIR"/*.sh "$SCRIPTS_DIR"/*.js "$SCRIPTS_DIR"/*.py; do
  f="$(basename "$fp")"
  hits="$(grep -nE '\.local/share/claude-multi-account/providers|\.kimi-prov-|homedir\(\)|\$KIMI_PROVIDER_PREFIX' "$fp" \
    | grep -vE '^[0-9]+:[[:space:]]*(#|//)')"
  [[ -z "$hits" ]] && continue
  while IFS= read -r line; do
    body="${line#*:}"
    case "$body" in
      *'${CMA_PROVIDERS_DIR:-$HOME/.local/share/claude-multi-account/providers}'*) continue ;;
      *'${'*':-$HOME}'*'/.kimi-prov-'*|*'cma_providers_dir'*|*'kimi_twin_root'*|*'cma_kimi_twin_root'*) continue ;;
    esac
    ok=0
    for e in "${T6C_ALLOW[@]}"; do
      ef="${e%%|*}"; rest="${e#*|}"; es="${rest%%|*}"
      [[ "$ef" == "$f" && "$body" == *"$es"* ]] && { ok=1; break; }
    done
    [[ $ok -eq 1 ]] || BAD+="$f:${line%%:*}: ${body:0:90} | "
  done <<<"$hits"
done
shopt -u nullglob
[[ -z "$BAD" ]] && _pass "every reader/writer is override-aware or allow-listed with a reason" || _fail "every reader/writer is override-aware or allow-listed with a reason" "$BAD"

# ===========================================================================
# T7 - a key is only ever sent to the origin it is pinned to
# ===========================================================================
it "T7a: exported TYPESAFE_API_KEY is NOT sent to another https origin whose JEV_KEY_VAR is a different variable"
: > "$TLSLOG"
gate "$HOOK" JEV_BASE_URL="https://127.0.0.1:$TLS_PORT" JEV_CA_FILE="$CERT" JEV_KEY_VAR=OPENROUTER_API_KEY \
  TYPESAFE_API_KEY="$DUMMY" JEV_MODE=shadow >/dev/null 2>&1
assert_eq 0 "$?" "fail-open exit"
grep -q "$DUMMY" "$TLSLOG" && _fail "TypeSafe key never reaches the other origin" "bearer seen: $(cat "$TLSLOG")" || _pass "sink-side: the TypeSafe key was not sent to the OpenRouter-bound origin"
assert_eq "0" "$(grep -c . "$TLSLOG")" "sink-side: no request at all (OPENROUTER_API_KEY is unset)"

it "T7b: JEV_KEY_VAR=TYPESAFE_API_KEY against an https origin nothing attests -> refused, no request made"
T7P="$(mktemp -d "$HOME/t7prov.XXXXXX")"
# A cache entry for that very origin must NOT attest it (the cache is writable from a pins override).
jq -n '{endpoints:[{base_url:"https://evil.example.invalid",key_var:"TYPESAFE_API_KEY",provider_id:"jev-x"}]}' > "$T7P/jev-endpoints.json"
gate "$HOOK" JEV_BASE_URL="https://evil.example.invalid" JEV_KEY_VAR=TYPESAFE_API_KEY \
  TYPESAFE_API_KEY="$DUMMY" CMA_PROVIDERS_DIR="$T7P" CMA_JEV_PINS_FILE="$T7P/pins.json" JEV_MODE=shadow >/dev/null 2>&1
assert_eq "key_unpinned" "$(fb)" "unpinned origin is logged as key_unpinned (cache/pins override do not attest)"

it "T7c: positive control - a loopback https origin is attested and receives the key"
: > "$TLSLOG"
gate "$HOOK" JEV_BASE_URL="https://127.0.0.1:$TLS_PORT" JEV_CA_FILE="$CERT" JEV_KEY_VAR=TYPESAFE_API_KEY \
  TYPESAFE_API_KEY="$DUMMY" CMA_PROVIDERS_DIR="$T7P" JEV_MODE=shadow >/dev/null 2>&1
assert_eq "none" "$(fb)" "no fallback for loopback"
grep -q "auth=Bearer $DUMMY" "$TLSLOG" && _pass "sink-side: the loopback origin received the key" || _fail "loopback origin received the key" "$(cat "$TLSLOG")"

it "T7d: the shipped origin with a DIFFERENT key variable than the shipped pin's own -> refused"
gate "$HOOK" JEV_BASE_URL="https://api.typesafe.ai" JEV_KEY_VAR=OPENROUTER_API_KEY \
  OPENROUTER_API_KEY="$WRONG" CMA_PROVIDERS_DIR="$T7P" JEV_MODE=shadow >/dev/null 2>&1
assert_eq "key_unpinned" "$(fb)" "variable is not the shipped pin's own"

it "T7e: an https base with userinfo is never key-pinned, even if a cache lists that literal string"
for ub in "https://127.0.0.1@127.0.0.1:$TLS_PORT" "https://127.0.0.1:$TLS_PORT\\@evil"; do
  jq -n --arg b "$ub" '{endpoints:[{base_url:$b,key_var:"TYPESAFE_API_KEY"}]}' > "$T7P/jev-endpoints.json"
  : > "$TLSLOG"
  gate "$HOOK" JEV_BASE_URL="$ub" JEV_CA_FILE="$CERT" JEV_KEY_VAR=TYPESAFE_API_KEY \
    TYPESAFE_API_KEY="$DUMMY" CMA_PROVIDERS_DIR="$T7P" JEV_MODE=shadow >/dev/null 2>&1
  assert_eq "key_unpinned" "$(fb)" "userinfo/backslash base refused [$ub]"
  assert_eq "0" "$(grep -c . "$TLSLOG")" "sink-side: zero requests"
done

# ===========================================================================
# T8 - the live probe never sends a bearer off a non-https non-loopback or unpinned URL
# ===========================================================================
it "T8a: CMA_JEV_LIVE probe with a pins override pointing at plain http on a NON-loopback host sends nothing"
PINS8="$HOME/pins8.json"
jq -n '{hosted:{typesafe:{key_var:"TYPESAFE_API_KEY",base_url:"http://192.0.2.1:9",systemone_path:"/v1/systemone",
  models:["jev-latest"],context_limit:64000,enabled:true}}, local_gateway:{enabled:false}, lan:[]}' > "$PINS8"
OUT8="$(env -u LLMCTL_API_KEY CMA_JEV_PINS_FILE="$PINS8" CMA_KEYS_FILE="$KEYS" CMA_JEV_LIVE=1 CMA_JEV_HTTP_TIMEOUT=1 \
  bash -c 'curl() { echo "CURL-CALLED $*" >>"'"$HOME"'/curl8.log"; return 7; }; export -f curl; source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_jev_records' 2>/dev/null)"
assert_eq "unverified" "$(jq -r '[.[] | select(.provider_id=="jev-typesafe")][0].status // "absent"' <<<"$OUT8")" "record is unverified"
case "$(jq -r '[.[] | select(.provider_id=="jev-typesafe")][0].reason // ""' <<<"$OUT8")" in *refus*) _pass "reason says the bearer was refused" ;; *) _fail "reason says the bearer was refused" "$(jq -c . <<<"$OUT8")" ;; esac
[[ ! -e "$HOME/curl8.log" ]] && _pass "curl was never invoked (no bearer could leave)" || _fail "curl was never invoked" "$(cat "$HOME/curl8.log")"

it "T8b: https pins override to a host other than the shipped pin's origin is refused too (not pinned)"
PINS8B="$HOME/pins8b.json"
jq -n '{hosted:{typesafe:{key_var:"TYPESAFE_API_KEY",base_url:"https://evil.example.invalid",systemone_path:"/v1/systemone",
  models:["jev-latest"],context_limit:64000,enabled:true}}, local_gateway:{enabled:false}, lan:[]}' > "$PINS8B"
rm -f "$HOME/curl8.log"
OUT8B="$(env -u LLMCTL_API_KEY CMA_JEV_PINS_FILE="$PINS8B" CMA_KEYS_FILE="$KEYS" CMA_JEV_LIVE=1 CMA_JEV_HTTP_TIMEOUT=1 \
  bash -c 'curl() { echo "CURL-CALLED $*" >>"'"$HOME"'/curl8.log"; return 7; }; export -f curl; source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_jev_records' 2>/dev/null)"
assert_eq "unverified" "$(jq -r '[.[] | select(.provider_id=="jev-typesafe")][0].status // "absent"' <<<"$OUT8B")" "record is unverified"
[[ ! -e "$HOME/curl8.log" ]] && _pass "curl was never invoked" || _fail "curl was never invoked" "$(cat "$HOME/curl8.log")"

it "T9: live-probe host parsing - userinfo/look-alike/odd hosts never receive a bearer; real loopback still does"
t9() { # t9 <base> <expect: send|nosend>
  local base="$1" want="$2" pins="$HOME/pins9.json" log="$HOME/curl9.log"
  rm -f "$log"
  jq -n --arg b "$base" '{hosted:{typesafe:{key_var:"TYPESAFE_API_KEY",base_url:$b,systemone_path:"/v1/systemone",
    models:["jev-latest"],context_limit:64000,enabled:true}}, local_gateway:{enabled:false}, lan:[]}' > "$pins"
  env -u LLMCTL_API_KEY CMA_JEV_PINS_FILE="$pins" CMA_KEYS_FILE="$KEYS" CMA_JEV_LIVE=1 CMA_JEV_HTTP_TIMEOUT=1 \
    bash -c 'curl() { echo "CURL-CALLED" >>"'"$log"'"; return 7; }; export -f curl; source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_jev_records' >/dev/null 2>&1
  if [[ "$want" == nosend ]]; then
    [[ ! -e "$log" ]] && _pass "no curl for [$base]" || _fail "no curl for [$base]" "curl was invoked"
  else
    [[ -e "$log" ]] && _pass "curl invoked for [$base]" || _fail "curl invoked for [$base]" "probe was skipped"
  fi
}
for b in 'http://127.0.0.1@evil.example/' 'http://localhost:80@evil/' 'http://user:pw@127.0.0.1.evil/' \
         'http://127.0.0.1.evil/' 'http://localhost./' 'http://127.0.0.1\@evil/' 'http://127.0.0.1 evil/' \
         'http://%31%32%37.0.0.1/' 'http://127.0.0.1%2eevil/' 'http:///' 'http://:8095/' 'http://127.0.0.1:80a/' \
         'http://[::1]x/' 'http://127.0.0.1:8095:9/'; do t9 "$b" nosend; done
for b in 'http://127.0.0.1:8095' 'http://localhost:8095/' 'http://[::1]:8095' 'http://127.0.0.1'; do t9 "$b" send; done

summary
