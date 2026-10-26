#!/usr/bin/env bash
# test_jev_key_origin_class.sh - the CLASS "a key can reach a host that was never
# validated" (round-2 review of 1.33.0). Every path that can send a bearer/key is
# in docs/jev/Jev_Key_Send_Paths.md; this file proves the jev paths of that table
# sink-side with PATH-shim curl, a mocked fetch and a patched urlopen. No real
# endpoint, no real key: dummy keys are built from fragments.
#
#  C1  live probe: a pins-supplied systemone_path can never move the request to
#      another host (userinfo / backslash / percent / query / empty / relative).
#  C2  end to end: a pins OVERRIDE origin written into the endpoint cache by
#      sync-jev (or hand-written there) does NOT attest a key in the gate.
#  C3  positive controls: shipped pin, loopback https, operator-trusted origin.
#  C4  jev_mcp.py applies the same origin rule.
#  C5  opencode-jev-plugin.js applies the same rule, honours CMA_PROVIDERS_DIR,
#      sends no "Bearer local", and never shell-interpolates key_var.
#  C6  drift guards: the table lists every file that builds a bearer, and the
#      plugin's embedded shipped-origin list equals providers/jev.json.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
trap cleanup_sandbox EXIT
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e

PROVIDERS_SH="$SCRIPTS_DIR/claude-providers.sh"
GATE="$SCRIPTS_DIR/jev-gate.sh"
SHIPPED_PINS="$SCRIPTS_DIR/providers/jev.json"
DUMMY="dum""my-k""ey-$$-0123456789"
KEYS="$HOME/api_keys.sh"
printf "export TYPESAFE_API_KEY='%s'\nexport LLMCTL_API_KEY='%s'\nexport OPENROUTER_API_KEY='%s'\n" "$DUMMY" "$DUMMY" "$DUMMY" > "$KEYS"

# --- PATH shim curl: records every URL and every header FILE it is handed ------
SHIM="$HOME/shim"; mkdir -p "$SHIM"
printf '%s\n' '#!/usr/bin/env bash' \
  'log="${SHIM_LOG:?}"; prev=""' \
  'for a in "$@"; do' \
  '  if [[ "$prev" == "-H" && "$a" == @* ]]; then cat "${a#@}" >> "$log.hdr" 2>/dev/null; fi' \
  '  case "$a" in http://*|https://*) printf "%s\n" "$a" >> "$log.url" ;; esac' \
  '  prev="$a"' \
  'done' 'exit 7' > "$SHIM/curl"
chmod +x "$SHIM/curl"
shim_reset() { rm -f "$HOME/shim.log.hdr" "$HOME/shim.log.url"; }
shim_urls() { cat "$HOME/shim.log.url" 2>/dev/null | wc -l | tr -d ' '; }
shim_keyseen() { grep -q "$DUMMY" "$HOME/shim.log.hdr" 2>/dev/null && echo yes || echo no; }

export JEV_STATE_DIR="$HOME/.local/state/jev-cl"
HOOK='{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
gate() { # gate <env...>  (hermetic against the caller's ambient JEV/key env)
  printf '%s' "$HOOK" | env -u JEV_API_KEY -u TYPESAFE_API_KEY -u JEV_KEY_VAR -u JEV_CA_FILE -u CMA_JEV_TRUSTED_ORIGINS \
    -u CMA_JEV_ENDPOINT_ID -u JEV_GATE_FAIL -u JEV_GATE -u LLMCTL_API_KEY -u CMA_PROVIDERS_DIR -u CMA_JEV_PINS_FILE \
    CMA_KEYS_FILE="$HOME/no-such-keys.sh" PATH="$SHIM:$PATH" SHIM_LOG="$HOME/shim.log" JEV_MODE=shadow "$@" bash "$GATE" >/dev/null 2>&1
}
lastfb() { tail -n1 "$JEV_STATE_DIR/decisions.jsonl" | jq -r '.fallback // "none"'; }

# ===========================================================================
it "C1: live probe - a hostile systemone_path never moves the request off the pinned host"
c1() { # c1 <base> <path> <expect: send|nosend> [slot] [key_var]
  local base="$1" path="$2" want="$3" slot="${4:-typesafe}" kv="${5:-TYPESAFE_API_KEY}" pins="$HOME/pinsc1.json" log="$HOME/curlc1.log"
  rm -f "$log"
  jq -n --arg b "$base" --arg p "$path" --arg s "$slot" --arg k "$kv" '{hosted:{($s):{key_var:$k,base_url:$b,systemone_path:$p,
    models:["jev-latest"],context_limit:64000,enabled:true}}, local_gateway:{enabled:false}, lan:[]}' > "$pins"
  env -u LLMCTL_API_KEY CMA_JEV_PINS_FILE="$pins" CMA_KEYS_FILE="$KEYS" CMA_JEV_LIVE=1 CMA_JEV_HTTP_TIMEOUT=1 \
    bash -c 'curl() { printf "%s\n" "$*" >>"'"$log"'"; return 7; }; export -f curl; source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_jev_records' >/dev/null 2>&1
  if [[ "$want" == nosend ]]; then
    [[ ! -e "$log" ]] && _pass "no curl for base [$base] path [$path]" || _fail "no curl for base [$base] path [$path]" "$(cat "$log")"
  else
    [[ -e "$log" ]] && _pass "curl invoked for base [$base] path [$path]" || _fail "curl invoked for base [$base] path [$path]" "probe skipped"
  fi
}
for p in '@evil.example/x' '\@evil.example/x' '%40evil.example/x' '/v1/x?y=1' '/v1/x#f' '' 'v1/systemone' '/a b' '/v1/../x' '/%2e%2e/x' ; do
  c1 "https://api.typesafe.ai" "$p" nosend
  c1 "http://127.0.0.1:8095" "$p" nosend
done
for hb in 'http://127.0.0.1:9@evil.example.invalid' 'https://127.0.0.1:9@evil.example.invalid' 'http://127.0.0.1:9%40evil.example.invalid'; do
  c1 "$hb" "/api/v1/systemone" nosend
done
c1 "https://api.typesafe.ai" "/v1/systemone" send
c1 "https://openrouter.ai/api" "/v1/systemone" nosend   # slot is typesafe: origin+key_var must equal the typesafe pin
c1 "http://127.0.0.1:8095" "/api/v1/systemone" send
# I-2: the shipped OpenRouter pin carries a path (/api); the probe must accept it exactly like the gate
c1 "https://openrouter.ai/api" "/v1/systemone" send openrouter OPENROUTER_API_KEY
c1 "https://openrouter.ai/api" "/v1/systemone" nosend openrouter TYPESAFE_API_KEY
c1 "https://evil.example.invalid/api" "/v1/systemone" nosend openrouter OPENROUTER_API_KEY

# ===========================================================================
it "C2: pins override origin -> sync-jev (cache) -> gate : the real key never reaches the override origin"
EVIL="https://evil.example.invalid"
PO="$HOME/pins-evil.json"
jq -n --arg b "$EVIL" '{hosted:{typesafe:{key_var:"TYPESAFE_API_KEY",base_url:$b,systemone_path:"/v1/systemone",
  models:["jev-latest"],context_limit:64000,enabled:true}}, local_gateway:{enabled:false}, lan:[]}' > "$PO"
PROV="$HOME/prov-c2"; mkdir -p "$PROV"
env -u LLMCTL_API_KEY CMA_PROVIDERS_DIR="$PROV" CMA_JEV_PINS_FILE="$PO" CMA_KEYS_FILE="$KEYS" \
  bash "$PROVIDERS_SH" sync-jev --quiet >/dev/null 2>&1
jq -e --arg e "$EVIL" '[.endpoints[]? | select(.base_url==$e)] | length >= 0' "$PROV/jev-endpoints.json" >/dev/null 2>&1 \
  && _pass "sync-jev ran against the override (premise: the cache may name the override origin)" \
  || _fail "sync-jev produced a readable cache" "$(cat "$PROV/jev-endpoints.json" 2>&1 | head -c 300)"
shim_reset
gate JEV_BASE_URL="$EVIL" JEV_KEY_VAR=TYPESAFE_API_KEY TYPESAFE_API_KEY="$DUMMY" CMA_PROVIDERS_DIR="$PROV" CMA_JEV_PINS_FILE="$PO"
assert_eq "key_unpinned" "$(lastfb)" "gate refuses (fallback key_unpinned)"
assert_eq "0" "$(shim_urls)" "sink-side: zero requests reached the override origin"
assert_eq "no" "$(shim_keyseen)" "sink-side: the key was not handed to curl"
# hand-written cache entry: still no attestation
jq -n --arg b "$EVIL" '{endpoints:[{base_url:$b,key_var:"TYPESAFE_API_KEY",provider_id:"jev-typesafe",status:"resolved"}]}' > "$PROV/jev-endpoints.json"
shim_reset
gate JEV_BASE_URL="$EVIL" JEV_KEY_VAR=TYPESAFE_API_KEY TYPESAFE_API_KEY="$DUMMY" CMA_PROVIDERS_DIR="$PROV"
assert_eq "key_unpinned" "$(lastfb)" "a cache entry never attests a key"
assert_eq "0" "$(shim_urls)" "sink-side: zero requests (cache attestation removed)"
# the key found in the keys file (not exported) is held back the same way
shim_reset
gate JEV_BASE_URL="$EVIL" JEV_KEY_VAR=TYPESAFE_API_KEY CMA_KEYS_FILE="$KEYS" CMA_PROVIDERS_DIR="$PROV"
assert_eq "0" "$(shim_urls)" "keys-file key: zero requests to the override origin"
assert_eq "no" "$(shim_keyseen)" "keys-file key: not handed to curl"

# ===========================================================================
it "C3: positive controls - shipped pin, loopback https and an operator-trusted origin DO receive the key"
shim_reset
gate JEV_BASE_URL="https://api.typesafe.ai" JEV_KEY_VAR=TYPESAFE_API_KEY TYPESAFE_API_KEY="$DUMMY"
assert_eq "1" "$(shim_urls)" "shipped TypeSafe pin: one request"
assert_eq "yes" "$(shim_keyseen)" "shipped TypeSafe pin: key sent"
shim_reset
gate JEV_BASE_URL="https://openrouter.ai/api" JEV_KEY_VAR=OPENROUTER_API_KEY OPENROUTER_API_KEY="$DUMMY"
assert_eq "1" "$(shim_urls)" "I-2 shipped OpenRouter pin (base carries /api): one request"
assert_eq "yes" "$(shim_keyseen)" "I-2 shipped OpenRouter pin: key sent"
shim_reset
gate JEV_BASE_URL="https://openrouter.ai/api/" JEV_KEY_VAR=OPENROUTER_API_KEY OPENROUTER_API_KEY="$DUMMY"
assert_eq "yes" "$(shim_keyseen)" "I-2 shipped OpenRouter pin with a trailing slash: key sent"
shim_reset
gate JEV_BASE_URL="https://openrouter.ai/api" JEV_KEY_VAR=TYPESAFE_API_KEY TYPESAFE_API_KEY="$DUMMY"
assert_eq "no" "$(shim_keyseen)" "OpenRouter origin with the TypeSafe key variable: refused"
shim_reset
gate JEV_BASE_URL="https://openrouter.ai.evil.example.invalid/api" JEV_KEY_VAR=OPENROUTER_API_KEY OPENROUTER_API_KEY="$DUMMY"
assert_eq "no" "$(shim_keyseen)" "look-alike OpenRouter host: refused"
shim_reset
gate JEV_BASE_URL="https://api.typesafe.ai" JEV_KEY_VAR=OPENROUTER_API_KEY OPENROUTER_API_KEY="$DUMMY"
assert_eq "0" "$(shim_urls)" "shipped origin with the OTHER slot's key variable: refused"
shim_reset
gate JEV_BASE_URL="https://127.0.0.1:9" JEV_KEY_VAR=TYPESAFE_API_KEY TYPESAFE_API_KEY="$DUMMY"
assert_eq "1" "$(shim_urls)" "loopback https: one request"
assert_eq "yes" "$(shim_keyseen)" "loopback https: key sent"
shim_reset
gate JEV_BASE_URL="https://llm.lan.example:8443" JEV_KEY_VAR=LLMCTL_API_KEY LLMCTL_API_KEY="$DUMMY" \
  CMA_JEV_TRUSTED_ORIGINS="https://llm.lan.example:8443=LLMCTL_API_KEY"
assert_eq "yes" "$(shim_keyseen)" "operator-trusted origin (env, origin=KEYVAR): key sent"
shim_reset
gate JEV_BASE_URL="https://llm.lan.example:8443" JEV_KEY_VAR=TYPESAFE_API_KEY TYPESAFE_API_KEY="$DUMMY" \
  CMA_JEV_TRUSTED_ORIGINS="https://llm.lan.example:8443=LLMCTL_API_KEY"
assert_eq "no" "$(shim_keyseen)" "trusted origin is bound to ITS key variable only"
shim_reset
gate JEV_BASE_URL="http://llm.lan.example:8443" JEV_KEY_VAR=LLMCTL_API_KEY LLMCTL_API_KEY="$DUMMY" \
  CMA_JEV_TRUSTED_ORIGINS="http://llm.lan.example:8443=LLMCTL_API_KEY"
assert_eq "no" "$(shim_keyseen)" "plain http never carries a key, trusted or not"

# hostile authorities: the text looks loopback, the connection would not be (or the octets are not an address)
HOSTILE_BASES=('https://127.999.0.1' 'https://127.0.0.1:9@evil.example.invalid' 'https://127.0.0.1:9%40evil.example.invalid'
  'https://127.0.0.1:9\@evil.example.invalid' 'https://localhost.evil.example.invalid' 'https://127.0.0.1.evil.example.invalid')
for hb in "${HOSTILE_BASES[@]}"; do
  shim_reset
  gate JEV_BASE_URL="$hb" JEV_KEY_VAR=TYPESAFE_API_KEY TYPESAFE_API_KEY="$DUMMY"
  assert_eq "0" "$(shim_urls)" "gate: hostile authority [$hb]: no request"
  assert_eq "no" "$(shim_keyseen)" "gate: hostile authority [$hb]: key not handed to curl"
done

# minor (d): the trusted-origin list is split WITHOUT glob expansion. A '*' in the value must not
# expand against the working directory (dir "https:" holding a file named like a trusted pair).
GLOBDIR="$HOME/globdir"; mkdir -p "$GLOBDIR/https:"
: > "$GLOBDIR/https:/evil.example.invalid=TYPESAFE_API_KEY"
shim_reset
( cd "$GLOBDIR" && gate JEV_BASE_URL="https://evil.example.invalid" JEV_KEY_VAR=TYPESAFE_API_KEY TYPESAFE_API_KEY="$DUMMY" \
    CMA_JEV_TRUSTED_ORIGINS='https://*' )
assert_eq "no" "$(shim_keyseen)" "glob: a '*' in CMA_JEV_TRUSTED_ORIGINS never expands into a trusted pair"
assert_eq "0" "$(shim_urls)" "glob: zero requests to the origin a glob would have produced"
shim_reset
( cd "$GLOBDIR" && gate JEV_BASE_URL="https://llm.lan.example:8443" JEV_KEY_VAR=LLMCTL_API_KEY LLMCTL_API_KEY="$DUMMY" \
    CMA_JEV_TRUSTED_ORIGINS='https://*  https://llm.lan.example:8443=LLMCTL_API_KEY' )
assert_eq "yes" "$(shim_keyseen)" "glob: a real entry next to a '*' entry is still honoured (no false refusal)"

# minor (a): a DISABLED shipped pin attests nothing - gate, mcp and probe. The shipped file is not
# overridable, so run copies of the scripts next to a providers/jev.json with the pins disabled.
DIS="$HOME/scripts-dis"; mkdir -p "$DIS"
cp -r "$SCRIPTS_DIR"/. "$DIS"/ 2>/dev/null; rm -rf "$DIS/tests"
jq '.hosted |= with_entries(.value.enabled=false)' "$SHIPPED_PINS" > "$DIS/providers/jev.json"
GATE_SAVE="$GATE"; GATE="$DIS/jev-gate.sh"
shim_reset
gate JEV_BASE_URL="https://api.typesafe.ai" JEV_KEY_VAR=TYPESAFE_API_KEY TYPESAFE_API_KEY="$DUMMY"
assert_eq "key_unpinned" "$(lastfb)" "disabled shipped pin: gate refuses (key_unpinned)"
assert_eq "0" "$(shim_urls)" "disabled shipped pin: zero requests"
shim_reset
gate JEV_BASE_URL="https://openrouter.ai/api" JEV_KEY_VAR=OPENROUTER_API_KEY OPENROUTER_API_KEY="$DUMMY"
assert_eq "0" "$(shim_urls)" "disabled OpenRouter pin: zero requests"
GATE="$GATE_SAVE"
PROVIDERS_SAVE="$PROVIDERS_SH"; PROVIDERS_SH="$DIS/claude-providers.sh"
c1 "https://api.typesafe.ai" "/v1/systemone" nosend
c1 "https://openrouter.ai/api" "/v1/systemone" nosend openrouter OPENROUTER_API_KEY
PROVIDERS_SH="$PROVIDERS_SAVE"
c1 "https://api.typesafe.ai" "/v1/systemone" send   # control: the enabled copy still sends

# ===========================================================================
it "C4: jev_mcp.py applies the same origin rule (patched urlopen records the Authorization header)"
mcp() { # mcp <base> <keyvar|-> [env...] -> prints "auth=<yes|no|none> err=<0|1>"
  local base="$1" kv="$2"; shift 2
  [ "$kv" = "-" ] && kv=""
  env -u JEV_API_KEY -u TYPESAFE_API_KEY -u JEV_KEY_VAR -u CMA_JEV_TRUSTED_ORIGINS CMA_KEYS_FILE="$HOME/no-such-keys.sh" \
    JEV_BASE_URL="$base" TYPESAFE_API_KEY="$DUMMY" ${kv:+JEV_KEY_VAR="$kv"} "$@" \
    python3 -c '
import sys, os
sys.path.insert(0, sys.argv[1])
import jev_mcp
seen = []
class R:
    def __enter__(s): return s
    def __exit__(s, *a): return False
    def read(s): return b"{\"data\":[]}"
def fake_open(req, timeout, ca_file=None):
    seen.append(req.headers.get("Authorization", ""))
    return R()
jev_mcp._open = fake_open
err = 0
try:
    jev_mcp._tool_jev_models({})
except Exception:
    err = 1
d = os.environ["TYPESAFE_API_KEY"]
a = "none" if not seen else ("yes" if d in seen[0] else "no")
print("auth=%s err=%d" % (a, err))' "$SCRIPTS_DIR" 2>/dev/null
}
assert_eq "auth=none err=1" "$(mcp https://evil.example.invalid -)" "unpinned https origin: no request, error"
assert_eq "auth=yes err=0" "$(mcp https://api.typesafe.ai -)" "shipped pin: key sent"
assert_eq "auth=none err=1" "$(mcp https://api.typesafe.ai OPENROUTER_API_KEY)" "shipped origin, wrong key variable: refused"
assert_eq "auth=yes err=0" "$(mcp https://openrouter.ai/api OPENROUTER_API_KEY CMA_KEYS_FILE="$KEYS")" "I-2 shipped OpenRouter pin (base carries /api): key sent"
assert_eq "auth=none err=1" "$(mcp https://openrouter.ai/api TYPESAFE_API_KEY CMA_KEYS_FILE="$KEYS")" "OpenRouter origin, TypeSafe key variable: refused"
assert_eq "auth=yes err=0" "$(mcp https://127.0.0.1:9 -)" "loopback https: key sent"
assert_eq "auth=yes err=0" "$(mcp https://llm.lan.example:8443 LLMCTL_API_KEY CMA_JEV_TRUSTED_ORIGINS=https://llm.lan.example:8443=LLMCTL_API_KEY LLMCTL_API_KEY="$DUMMY")" "operator-trusted origin: key sent"
assert_eq "auth=none err=1" "$(mcp https://llm.lan.example:8443 TYPESAFE_API_KEY CMA_JEV_TRUSTED_ORIGINS=https://llm.lan.example:8443=LLMCTL_API_KEY)" "I1 mcp: a trusted origin is bound to ITS key variable only"
assert_eq "auth=none err=1" "$(mcp 'https://127.0.0.1@evil.example.invalid' -)" "userinfo base: refused"
for hb in "${HOSTILE_BASES[@]}"; do
  assert_eq "auth=none err=1" "$(mcp "$hb" -)" "mcp: hostile authority [$hb]: refused"
done
SCRIPTS_SAVE="$SCRIPTS_DIR"; SCRIPTS_DIR="$DIS"
assert_eq "auth=none err=1" "$(mcp https://api.typesafe.ai -)" "disabled shipped pin: mcp refuses"
assert_eq "auth=none err=1" "$(mcp https://openrouter.ai/api OPENROUTER_API_KEY CMA_KEYS_FILE="$KEYS")" "disabled OpenRouter pin: mcp refuses"
SCRIPTS_DIR="$SCRIPTS_SAVE"
assert_eq "auth=yes err=0" "$(mcp https://api.typesafe.ai -)" "control: the enabled shipped pin still sends"
# minor (c): a routes.json candidate names a key_var that _candidate_answer resolves to the secret;
# the same origin rule applies per candidate (https only to loopback / shipped pin / trusted origin).
cand() { # cand <base> <key_var> [env...] -> "auth=<yes|no|none>"
  local base="$1" kv="$2"; shift 2
  env -u JEV_API_KEY -u JEV_KEY_VAR -u CMA_JEV_TRUSTED_ORIGINS CMA_KEYS_FILE="$KEYS" DUM="$DUMMY" CB="$base" CK="$kv" "$@" \
    python3 -c '
import sys, os
sys.path.insert(0, sys.argv[1])
import jev_mcp
seen = []
class R:
    def __enter__(s): return s
    def __exit__(s, *a): return False
    def read(s): return b"{\"answers\":{\"ask\":{\"choice\":\"allow\"}}}"
def fake_open(req, timeout, ca_file=None):
    seen.append(req.headers.get("Authorization", ""))
    return R()
jev_mcp._open = fake_open
jev_mcp._candidate_answer({"base_url": os.environ["CB"], "key_var": os.environ["CK"], "model": "m"}, {}, {})
print("auth=" + ("none" if not seen else ("yes" if os.environ["DUM"] in seen[0] else "no")))' "$SCRIPTS_DIR" 2>/dev/null
}
assert_eq "auth=none" "$(cand https://evil.example.invalid TYPESAFE_API_KEY)" "route candidate, unpinned https origin: no request, key not sent"
assert_eq "auth=none" "$(cand 'https://127.0.0.1:9@evil.example.invalid' TYPESAFE_API_KEY)" "route candidate, userinfo authority: refused"
assert_eq "auth=yes" "$(cand https://api.typesafe.ai TYPESAFE_API_KEY)" "route candidate, shipped pin + its key variable: key sent"
assert_eq "auth=none" "$(cand https://api.typesafe.ai LLMCTL_API_KEY)" "route candidate, shipped origin with another key variable: refused"
assert_eq "auth=yes" "$(cand https://llm.lan.example:8443 LLMCTL_API_KEY CMA_JEV_TRUSTED_ORIGINS=https://llm.lan.example:8443=LLMCTL_API_KEY)" "route candidate, operator-trusted origin: key sent"
assert_eq "auth=none" "$(cand https://llm.lan.example:8443 TYPESAFE_API_KEY CMA_JEV_TRUSTED_ORIGINS=https://llm.lan.example:8443=LLMCTL_API_KEY)" "I1 route candidate: a trusted origin is bound to ITS key variable only"
assert_eq "auth=no" "$(cand http://127.0.0.1:9 '')" "route candidate, loopback http with no key: request still made, no bearer (no false refusal)"
PINS_EVIL="$HOME/pins-mcp-evil.json"
jq -n '{hosted:{typesafe:{key_var:"TYPESAFE_API_KEY",base_url:"https://evil.example.invalid",systemone_path:"/v1/systemone",models:["jev-latest"],context_limit:64000,enabled:true}},local_gateway:{enabled:false},lan:[]}' > "$PINS_EVIL"
assert_eq "auth=none err=1" "$(mcp https://evil.example.invalid - CMA_JEV_PINS_FILE="$PINS_EVIL")" "mcp: a pins-file override never attests a key"

# ===========================================================================
it "C5: opencode-jev-plugin.js - same rule, CMA_PROVIDERS_DIR, no 'Bearer local', no shell interpolation of key_var"
if ! command -v node >/dev/null 2>&1; then
  _pass "node not installed - JS plugin scenarios SKIPPED (honest skip, documented in the table)"
else
  PLUG() { # PLUG [env...] -> JSON line
    env -u JEV_BASE_URL -u JEV_API_KEY -u TYPESAFE_API_KEY -u JEV_KEY_VAR -u CMA_PROVIDERS_DIR -u CMA_JEV_TRUSTED_ORIGINS \
      -u JEV_GATE -u JEV_MODE HOME="$HOME/plughome" JEV_TEST_SCRATCH_HOME="$HOME/plughome" JEV_TEST_DUMMY="$DUMMY" JEV_STATE_DIR="$HOME/plugstate" CMA_KEYS_FILE="$HOME/no-such-keys.sh" "$@" \
      node "$TESTS_DIR/jev_plugin_origin_test.mjs" 2>&1 | tail -n1
  }
  mkdir -p "$HOME/plughome"
  R="$(PLUG JEV_BASE_URL=https://evil.example.invalid TYPESAFE_API_KEY="$DUMMY")"
  assert_eq "0" "$(jq '.calls|length' <<<"$R" 2>/dev/null || echo ERR)" "unpinned https origin: fetch never called"
  case "$R" in *"$DUMMY"*) _fail "key not in output" "key echoed" ;; *) _pass "key not in test output" ;; esac
  R="$(PLUG JEV_BASE_URL=http://127.0.0.1:9)"
  assert_eq "1" "$(jq '.calls|length' <<<"$R" 2>/dev/null || echo ERR)" "plain http loopback, no key: request made"
  assert_eq "null" "$(jq -c '.calls[0].auth' <<<"$R" 2>/dev/null || echo ERR)" "no Authorization header at all (was 'Bearer local')"
  R="$(PLUG JEV_BASE_URL=http://127.0.0.1:9 TYPESAFE_API_KEY="$DUMMY")"
  assert_eq "null" "$(jq -c '.calls[0].auth' <<<"$R" 2>/dev/null || echo ERR)" "plain http with an exported key: still no Authorization header"
  R="$(PLUG JEV_BASE_URL=https://api.typesafe.ai TYPESAFE_API_KEY="$DUMMY")"
  assert_eq "true" "$(jq -r '.calls[0].auth_is_dummy' <<<"$R" 2>/dev/null || echo ERR)" "shipped pin: key sent"
  R="$(PLUG JEV_BASE_URL=https://api.typesafe.ai JEV_KEY_VAR=OPENROUTER_API_KEY OPENROUTER_API_KEY="$DUMMY")"
  assert_eq "0" "$(jq '.calls|length' <<<"$R" 2>/dev/null || echo ERR)" "shipped origin with the other slot's key variable: refused"
  R="$(PLUG JEV_BASE_URL=https://openrouter.ai/api JEV_KEY_VAR=OPENROUTER_API_KEY OPENROUTER_API_KEY="$DUMMY")"
  assert_eq "true" "$(jq -r '.calls[0].auth_is_dummy' <<<"$R" 2>/dev/null || echo ERR)" "I-2 shipped OpenRouter pin (base carries /api): key sent"
  assert_eq "error" "$(jq -r '.calls[0].redirect' <<<"$R" 2>/dev/null || echo ERR)" "NIT: the plugin's fetch refuses redirects (redirect:error)"
  R="$(PLUG JEV_BASE_URL=https://openrouter.ai/api JEV_KEY_VAR=TYPESAFE_API_KEY TYPESAFE_API_KEY="$DUMMY")"
  assert_eq "0" "$(jq '.calls|length' <<<"$R" 2>/dev/null || echo ERR)" "OpenRouter origin with the TypeSafe key variable: refused"
  R="$(PLUG JEV_BASE_URL=https://llm.lan.example:8443 JEV_KEY_VAR=TYPESAFE_API_KEY TYPESAFE_API_KEY="$DUMMY" CMA_JEV_TRUSTED_ORIGINS=https://llm.lan.example:8443=LLMCTL_API_KEY)"
  assert_eq "0" "$(jq '.calls|length' <<<"$R" 2>/dev/null || echo ERR)" "I1 plugin: a trusted origin is bound to ITS key variable only"
  # M2: the harness refuses to run without a scratch HOME and never prints an Authorization value
  RG="$(env -u JEV_TEST_SCRATCH_HOME HOME="$HOME/plughome" JEV_BASE_URL=https://api.typesafe.ai TYPESAFE_API_KEY="$DUMMY" node "$TESTS_DIR/jev_plugin_origin_test.mjs" 2>&1; echo "rc=$?")"
  case "$RG" in *"rc=2") _pass "M2: harness refuses without JEV_TEST_SCRATCH_HOME" ;; *) _fail "M2: harness refuses without JEV_TEST_SCRATCH_HOME" "$RG" ;; esac
  case "$RG" in *"$DUMMY"*|*Bearer*) _fail "M2: refusal output carries no credential" "leak" ;; *) _pass "M2: refusal output carries no credential" ;; esac
  R="$(PLUG JEV_BASE_URL=https://api.typesafe.ai TYPESAFE_API_KEY="$DUMMY")"
  case "$R" in *Bearer*|*"$DUMMY"*) _fail "M2: harness output has no Authorization value" "leak" ;; *) _pass "M2: harness output has no Authorization value" ;; esac
  R="$(PLUG JEV_BASE_URL=https://127.0.0.1:9 TYPESAFE_API_KEY="$DUMMY")"
  assert_eq "true" "$(jq -r '.calls[0].auth_is_dummy' <<<"$R" 2>/dev/null || echo ERR)" "loopback https: key sent"
  R="$(PLUG JEV_BASE_URL=https://llm.lan.example:8443 JEV_KEY_VAR=LLMCTL_API_KEY LLMCTL_API_KEY="$DUMMY" CMA_JEV_TRUSTED_ORIGINS=https://llm.lan.example:8443=LLMCTL_API_KEY)"
  assert_eq "true" "$(jq -r '.calls[0].auth_is_dummy' <<<"$R" 2>/dev/null || echo ERR)" "operator-trusted origin: key sent"
  # cache read from CMA_PROVIDERS_DIR (HOME is empty), key_var shell-injection attempt
  PD="$HOME/plugprov"; mkdir -p "$PD"; EXP="$HOME/pwned.flag"; rm -f "$EXP"
  jq -n --arg k "TYPESAFE_API_KEY}\"; touch $EXP; echo \"" '{endpoints:[{base_url:"http://127.0.0.1:9",key_var:$k,provider_id:"jev-x"}]}' > "$PD/jev-endpoints.json"
  R="$(PLUG CMA_PROVIDERS_DIR="$PD" JEV_TEST_EXPLOIT_FILE="$EXP")"
  assert_eq "1" "$(jq '.calls|length' <<<"$R" 2>/dev/null || echo ERR)" "cache under CMA_PROVIDERS_DIR is honoured (HOME has none)"
  assert_eq "false" "$(jq -r '.exploit' <<<"$R" 2>/dev/null || echo ERR)" "a hostile key_var is never interpreted by a shell"
  [[ ! -e "$EXP" ]] && _pass "sink-side: the injected command did not run" || _fail "injected command did not run" "flag file exists"
  # bash indirect expansion evaluates an array subscript: KV='NAME[$(cmd)]' would run cmd
  EXP2="$HOME/pwned2.flag"; rm -f "$EXP2"
  jq -n --arg k "TYPESAFE_API_KEY[\$(touch $EXP2)]" '{endpoints:[{base_url:"https://127.0.0.1:9",key_var:$k,provider_id:"jev-x"}]}' > "$PD/jev-endpoints.json"
  R="$(PLUG CMA_PROVIDERS_DIR="$PD" JEV_TEST_EXPLOIT_FILE="$EXP2")"
  assert_eq "false" "$(jq -r '.exploit' <<<"$R" 2>/dev/null || echo ERR)" "a subscript/command-substitution key_var is rejected before bash sees it"
  [[ ! -e "$EXP2" ]] && _pass "sink-side: the subscript command did not run" || _fail "subscript command did not run" "flag file exists"
  EXP3="$HOME/pwned3.flag"; rm -f "$EXP3"
  jq -n --arg k "TYPESAFE_API_KEY}\"; touch $EXP3; echo \"" '{endpoints:[{base_url:"https://127.0.0.1:9",key_var:$k,provider_id:"jev-x"}]}' > "$PD/jev-endpoints.json"
  R="$(PLUG CMA_PROVIDERS_DIR="$PD" JEV_TEST_EXPLOIT_FILE="$EXP3")"
  assert_eq "false" "$(jq -r '.exploit' <<<"$R" 2>/dev/null || echo ERR)" "brace-injection key_var on a reached https loopback origin is never interpreted"
  [[ ! -e "$EXP3" ]] && _pass "sink-side: the brace-injected command did not run" || _fail "brace-injected command did not run" "flag file exists"
  for hb in 'https://127.999.0.1' 'https://127.0.0.1:9@evil.example.invalid' 'https://127.0.0.1:9%40evil.example.invalid' 'https://localhost.evil.example.invalid'; do
    R="$(PLUG JEV_BASE_URL="$hb" TYPESAFE_API_KEY="$DUMMY")"
    assert_eq "0" "$(jq '.calls|length' <<<"$R" 2>/dev/null || echo ERR)" "hostile authority [$hb]: fetch never called"
  done
  jq -n '{endpoints:[{base_url:"https://evil.example.invalid",key_var:"TYPESAFE_API_KEY",provider_id:"jev-x"}]}' > "$PD/jev-endpoints.json"
  R="$(PLUG CMA_PROVIDERS_DIR="$PD" TYPESAFE_API_KEY="$DUMMY")"
  assert_eq "0" "$(jq '.calls|length' <<<"$R" 2>/dev/null || echo ERR)" "a cache entry for an unpinned https origin never attests a key"
fi

# ===========================================================================
it "C6: drift guards - the send-path table lists every file that builds a bearer; plugin origin list == shipped pins"
TABLE="$REPO_DIR/docs/jev/Jev_Key_Send_Paths.md"
assert_file "$TABLE" "send-path table exists"
missing=""
while IFS= read -r f; do
  b="$(basename "$f")"
  grep -q "$b" "$TABLE" 2>/dev/null || missing="$missing $b"
done < <(grep -lE "Bearer |x-api-key|X-Api-Key|JEV_API_KEY: \\\$key" "$SCRIPTS_DIR"/*.sh "$SCRIPTS_DIR"/*.py "$SCRIPTS_DIR"/*.js 2>/dev/null)
[[ -z "$missing" ]] && _pass "every file with a bearer/api-key header is in the table" || _fail "every file with a bearer/api-key header is in the table" "missing:$missing"
shipped="$(jq -r '[.hosted[] | select(.enabled // true) | ((.base_url|capture("^(?<o>https://[^/?#]+)").o)+"="+.key_var)] | sort | join(" ")' "$SHIPPED_PINS")"
plug="$(grep -E '^// SHIPPED_ORIGINS:' "$SCRIPTS_DIR/opencode-jev-plugin.js" | sed -E 's#^// SHIPPED_ORIGINS: ##' | tr ' ' '\n' | sort | paste -sd' ' -)"
assert_eq "$shipped" "$plug" "plugin SHIPPED_ORIGINS marker equals providers/jev.json hosted (origin=key_var)"

summary
