#!/usr/bin/env bash
# test_jev_keyfile.sh - the NON-SECRET key-file indirection: how the Jev consumers find LLMCTL_API_KEY when it is neither in the
# process environment nor in ~/api_keys.sh.
#
# Root cause (2026-10-26, captured): the llmctl decide gateway is HTTPS + mandatory bearer key. On the operator host the key lives in
# llmctl's own .env (mode 600); the toolkit sync UNIT receives it through a systemd EnvironmentFile drop-in, so `claude-providers
# sync-jev` works from systemd. A gate hook started from an interactive Claude/Kimi/opencode session has no such environment, and
# the key is not in ~/api_keys.sh, so jev-gate.sh sent the placeholder "local" and the gateway answered 401 (the call failed open and
# the decision layer silently did nothing). Copying the secret into ~/api_keys.sh would duplicate it; sourcing a foreign .env would
# execute it. Now: a pointer (`jev-setup --key-file PATH` -> ~/.config/jev/key-files, or $CMA_JEV_KEY_FILES) names the file that owns
# the key, and every consumer PARSES just that one variable out of it at call time (jev-keyfile-lib.sh, the inline copy in
# jev-gate.sh, jev_mcp.py, opencode-jev-plugin.js). Precedence: JEV_API_KEY/TYPESAFE_API_KEY > env var named by JEV_KEY_VAR > keys
# file > key files > "local".
#
# Sections: V = shared vectors over the three bash/python implementations; P = pointer-file mechanics; G = the REAL gate against a
# TLS+bearer fixture (the proof: sink-side Authorization header); D = the detector; M = the MCP server; O = the opencode plugin;
# S = jev-setup --key-file; X = secret hygiene; mutations M* run against a COPY of scripts/ and every one must go RED.
# The fixture key is a random per-run test value; the operator's real key is never read by this suite.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required"; exit 0; }
command -v openssl >/dev/null 2>&1 || { echo "SKIP: openssl required"; exit 0; }
set +e
unset JEV_MODE JEV_CONFIG_DIR JEV_STATE_DIR JEV_BASE_URL JEV_API_KEY JEV_CA_FILE JEV_GATE JEV_KEY_VAR JEV_SETUP_CONSENT CMA_JEV_KEY_FILES \
      TYPESAFE_API_KEY TYPESAFE_BASE_URL CMA_JEV_DISABLE LLMCTL_API_KEY CMA_JEV_CA_FILE SSL_CERT_FILE LLMCTL_HOME
export JEV_STATE_DIR="$HOME/.local/state/jev"
KEYS="$HOME/api_keys.sh"; : > "$KEYS"; export CMA_KEYS_FILE="$KEYS"
CFG="$HOME/.config/jev"; export JEV_CONFIG_DIR="$CFG"
LIBSH="$SCRIPTS_DIR/jev-keyfile-lib.sh"
SECRET="fixture-llmctl-key-$$-$RANDOM$RANDOM-0123456789abcdef"   # random per run, a TEST value (not the operator's key)
WRONG="wrong-key-$$-$RANDOM"

# --------------------------------------------------------------------------------------------------------------- TLS fixture
CERT="$HOME/gw.crt"; KEY="$HOME/gw.key"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$KEY" -out "$CERT" -days 2 -subj "/CN=127.0.0.1" \
  -addext "subjectAltName=IP:127.0.0.1" >/dev/null 2>&1
FIXLOG="$HOME/sink.log"; : > "$FIXLOG"
PF="$HOME/port.txt"; : > "$PF"
JEV_FIXTURE_LOG="$FIXLOG" python3 "$SCRIPTS_DIR/tests/fixtures/jev_https_server.py" 0 "$PF" tls "$CERT" "$KEY" "$SECRET" 127.0.0.1 >/dev/null 2>&1 &
for _ in $(seq 1 60); do [ -s "$PF" ] && [ -s "$PF.pid" ] && break; sleep 0.1; done
PORT="$(cat "$PF")"
trap 'kill "$(cat "$PF.pid" 2>/dev/null)" 2>/dev/null; cleanup_sandbox' EXIT
it "precondition: the TLS+bearer fixture is up"
assert_eq yes "$([ -n "$PORT" ] && echo yes || echo no)" "fixture listens on a port"
BASEURL="https://127.0.0.1:$PORT"

# a stand-in for llmctl's own .env: owned by us, mode 600, holds the key among other variables
LLENV="$HOME/llmctl/.env"; mkdir -p "$HOME/llmctl"
printf '# llmctl env\nLLMCTL_HOME=%s\nLLMCTL_API_KEY=%s\nOTHER_SECRET=do-not-leak\n' "$HOME/llmctl" "$SECRET" > "$LLENV"; chmod 600 "$LLENV"

HOOK='{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
GATE="$SCRIPTS_DIR/jev-gate.sh"
SHIM="$HOME/shim"; mkdir -p "$SHIM"; ARGV="$HOME/curl_argv.log"; : > "$ARGV"
REALCURL="$(command -v curl)"
cat > "$SHIM/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$ARGV"
exec "$REALCURL" "\$@"
SH
chmod +x "$SHIM/curl"

# -------------------------------------------------------------------------------------------------------------------- helpers
GATE_FN="$HOME/gate_fn.sh"
extract_gate_fn() { sed -n '/^_jev_keyfile_lookup() {/,/^}/p' "$1" > "$GATE_FN"; }
extract_gate_fn "$GATE"
impl_lib() { env -i HOME="$HOME" PATH="$PATH" CMA_JEV_KEY_FILES="${2:-}" JEV_CONFIG_DIR="${3:-/nonexistent/jev}" bash -c '. "$1"; cma_jev_keyfile_lookup "$2"' _ "${LIBSH_UNDER_TEST:-$LIBSH}" "$1" 2>/dev/null; }
impl_gate() { env -i HOME="$HOME" PATH="$PATH" CMA_JEV_KEY_FILES="${2:-}" JEV_CONFIG_DIR="${3:-/nonexistent/jev}" bash -c '. "$1"; _jev_keyfile_lookup "$2"' _ "${GATE_FN_UNDER_TEST:-$GATE_FN}" "$1" 2>/dev/null; }
impl_py() { env -i HOME="$HOME" PATH="$PATH" CMA_JEV_KEY_FILES="${2:-}" JEV_CONFIG_DIR="${3:-/nonexistent/jev}" python3 -I -c '
import sys
sys.path.insert(0, sys.argv[1])
import jev_mcp
sys.stdout.write(jev_mcp._keyfile_lookup(sys.argv[2]))' "${SCRIPTS_UNDER_TEST:-$SCRIPTS_DIR}" "$1" 2>/dev/null; }

# ================================================================================================ V: shared vectors (3 impls)
VDIR="$HOME/vec"; mkdir -p "$VDIR"; PWNDIR="$HOME/pwn"; mkdir -p "$PWNDIR"
vec() { # vec <label> <file content> <NAME> <expected>
  local f="$VDIR/f.env"; printf '%s' "$2" > "$f"; chmod 600 "$f"
  local a b c
  a="$(cd "$PWNDIR" && impl_lib "$3" "$f")"; b="$(cd "$PWNDIR" && impl_gate "$3" "$f")"; c="$(cd "$PWNDIR" && impl_py "$3" "$f")"
  assert_eq "$4|$4|$4" "$a|$b|$c" "$1 (lib|gate|python)"
}
it "V: one vector table, three implementations (bash lib, the gate's inline copy, python) must agree on every line"
vec "plain NAME=value"                $'LLMCTL_API_KEY=abc123\n'                                   LLMCTL_API_KEY abc123
vec "export NAME=value"               $'export LLMCTL_API_KEY=abc123\n'                            LLMCTL_API_KEY abc123
vec "double quotes stripped"          $'LLMCTL_API_KEY="abc 123"\n'                                LLMCTL_API_KEY "abc 123"
vec "single quotes stripped"          $'LLMCTL_API_KEY=\'abc123\'\n'                               LLMCTL_API_KEY abc123
vec "last assignment wins"            $'LLMCTL_API_KEY=old\nLLMCTL_API_KEY=new\n'                  LLMCTL_API_KEY new
vec "CRLF line"                       $'LLMCTL_API_KEY=abc123\r\n'                                 LLMCTL_API_KEY abc123
vec "leading and trailing blanks"     $'  \tLLMCTL_API_KEY=abc123  \t\n'                            LLMCTL_API_KEY abc123
vec "no trailing newline"             'LLMCTL_API_KEY=abc123'                                      LLMCTL_API_KEY abc123
vec "longer name is not a match"      $'LLMCTL_API_KEY_OTHER=zzz\n'                                LLMCTL_API_KEY ""
vec "prefixed name is not a match"    $'XLLMCTL_API_KEY=zzz\n'                                     LLMCTL_API_KEY ""
vec "commented line ignored"          $'# LLMCTL_API_KEY=commented\n'                              LLMCTL_API_KEY ""
vec "command substitution is literal" $'LLMCTL_API_KEY=$(touch PWNED_MARKER)\n'                    LLMCTL_API_KEY '$(touch PWNED_MARKER)'
vec "backticks are literal"           $'LLMCTL_API_KEY=`touch PWNED_MARKER`\n'                     LLMCTL_API_KEY '`touch PWNED_MARKER`'
vec "variable reference is literal"   $'LLMCTL_API_KEY=${HOME}x\n'                                 LLMCTL_API_KEY '${HOME}x'
vec "inline comment is literal"       $'LLMCTL_API_KEY=abc # not a comment\n'                      LLMCTL_API_KEY 'abc # not a comment'
vec "value containing ="              $'LLMCTL_API_KEY=ab=cd==\n'                                  LLMCTL_API_KEY 'ab=cd=='
vec "backslash is literal"            $'LLMCTL_API_KEY=ab\\cd\n'                                   LLMCTL_API_KEY 'ab\cd'
vec "unterminated quote is literal"   $'LLMCTL_API_KEY="unterminated\n'                            LLMCTL_API_KEY '"unterminated'
vec "inner quote kept, outer pair stripped" $'LLMCTL_API_KEY="a\\"b"\n'                            LLMCTL_API_KEY 'a\"b'
vec "empty value -> nothing"          $'LLMCTL_API_KEY=\n'                                         LLMCTL_API_KEY ""
vec "empty quotes -> nothing"         $'LLMCTL_API_KEY=""\n'                                       LLMCTL_API_KEY ""
vec "last line empty wins -> nothing" $'LLMCTL_API_KEY=real\nLLMCTL_API_KEY=\n'                    LLMCTL_API_KEY ""
vec "other variables around it"       $'A=1\nLLMCTL_API_KEY=k\nB=2\n'                              LLMCTL_API_KEY k
vec "another variable name"           $'A=1\nB=two\n'                                              B two
vec "invalid name: leading digit"     $'1BAD=x\n'                                                  1BAD ""
vec "invalid name: dash"              $'A-B=x\n'                                                   A-B ""
vec "invalid name: empty"             $'=x\n'                                                      "" ""
assert_eq 0 "$(find "$PWNDIR" -type f | wc -l)" "nothing was executed while parsing (no PWNED_MARKER created, three implementations)"
rm -f -- "${VDIR:?}/f.env"

# ================================================================================================ P: pointer-file mechanics
it "P: candidates = CMA_JEV_KEY_FILES then key-files lines; owner/regular/readable enforced; first non-empty wins"
mkdir -p "$CFG"
A="$HOME/ka.env"; B="$HOME/kb.env"; C="$HOME/kc.env"
printf 'LLMCTL_API_KEY=from-a\n' > "$A"; printf 'LLMCTL_API_KEY=from-b\n' > "$B"; printf 'OTHER=1\n' > "$C"
printf '# comment\n\n  %s  \n%s\n' "$B" "$A" > "$CFG/key-files"
assert_eq "from-b" "$(impl_lib LLMCTL_API_KEY "" "$CFG")" "lib: pointer file order, comments and blanks skipped"
assert_eq "from-b" "$(impl_gate LLMCTL_API_KEY "" "$CFG")" "gate: same"
assert_eq "from-b" "$(impl_py LLMCTL_API_KEY "" "$CFG")" "python: same"
assert_eq "from-a|from-a|from-a" "$(impl_lib LLMCTL_API_KEY "$A" "$CFG")|$(impl_gate LLMCTL_API_KEY "$A" "$CFG")|$(impl_py LLMCTL_API_KEY "$A" "$CFG")" "CMA_JEV_KEY_FILES comes before the pointer file"
assert_eq "from-b|from-b|from-b" "$(impl_lib LLMCTL_API_KEY "$C:$B" "$CFG")|$(impl_gate LLMCTL_API_KEY "$C:$B" "$CFG")|$(impl_py LLMCTL_API_KEY "$C:$B" "$CFG")" "a file without the variable is skipped, the next one answers"
assert_eq "from-b|from-b|from-b" "$(impl_lib LLMCTL_API_KEY "$HOME/missing.env:$HOME:$B" "$CFG")|$(impl_gate LLMCTL_API_KEY "$HOME/missing.env:$HOME:$B" "$CFG")|$(impl_py LLMCTL_API_KEY "$HOME/missing.env:$HOME:$B" "$CFG")" "a missing file and a directory are skipped"
printf '%s\n' '~/kb.env' > "$CFG/key-files"
assert_eq "from-b|from-b|from-b" "$(impl_lib LLMCTL_API_KEY "" "$CFG")|$(impl_gate LLMCTL_API_KEY "" "$CFG")|$(impl_py LLMCTL_API_KEY "" "$CFG")" "~/ is expanded"
printf '%s\r\n' "$B" > "$CFG/key-files"
assert_eq "from-b|from-b|from-b" "$(impl_lib LLMCTL_API_KEY "" "$CFG")|$(impl_gate LLMCTL_API_KEY "" "$CFG")|$(impl_py LLMCTL_API_KEY "" "$CFG")" "a CRLF pointer line works"
if [ -f /etc/os-release ] && [ "$(stat -c %u /etc/os-release 2>/dev/null)" != "$(id -u)" ] && grep -q '^NAME=' /etc/os-release; then
  assert_eq "||" "$(impl_lib NAME /etc/os-release "$CFG")|$(impl_gate NAME /etc/os-release "$CFG")|$(impl_py NAME /etc/os-release "$CFG")" "a readable file NOT owned by the current user (/etc/os-release defines NAME) is never used"
else
  _skip "no root-owned /etc/os-release with NAME= on this host"
fi
rm -f -- "${CFG:?}/key-files"
assert_eq "||" "$(impl_lib LLMCTL_API_KEY "" "$CFG")|$(impl_gate LLMCTL_API_KEY "" "$CFG")|$(impl_py LLMCTL_API_KEY "" "$CFG")" "no pointer, no env -> nothing"

# ================================================================================================ G: the real gate, sink-side proof
sink_auth_last() { tail -n1 "$FIXLOG" 2>/dev/null | sed 's/.*auth=//'; }
decision_field() { tail -n1 "$JEV_STATE_DIR/decisions.jsonl" 2>/dev/null | jq -r "$1" 2>/dev/null; }
run_gate() { # run_gate <gate.sh> [VAR=val ...] -> "<rc>"; stdout/stderr of the gate go to $GOUT
  local g="$1"; shift
  rm -f -- "${JEV_STATE_DIR:?}/decisions.jsonl"; : > "$FIXLOG"
  printf '%s' "$HOOK" | env PATH="$SHIM:$PATH" JEV_BASE_URL="$BASEURL" JEV_CA_FILE="$CERT" JEV_KEY_VAR=LLMCTL_API_KEY JEV_MODE=enforce "$@" bash "$g" > "$HOME/gate.out" 2> "$HOME/gate.err"
  printf '%s' "$?"
}
: > "$HOME/all_outputs.log"
note_outputs() { cat "$HOME/gate.out" "$HOME/gate.err" >> "$HOME/all_outputs.log" 2>/dev/null; }

it "G0 RED shape: key only in llmctl's .env, NO pointer -> the gate sends the placeholder, the gateway says 401, the call fails open (the reported defect)"
rm -f -- "${CFG:?}/key-files"
rc="$(run_gate "$GATE")"; note_outputs
assert_eq 0 "$rc" "no usable key -> fail-open exit 0 (nothing was denied)"
assert_eq "endpoint_error" "$(decision_field '.fallback')" "decision log: fallback endpoint_error"
assert_eq "Bearer local" "$(sink_auth_last)" "the gateway received the placeholder bearer (and rejected it)"

it "G1 GREEN: the same call with the pointer -> the gate reads LLMCTL_API_KEY out of the .env, the gateway accepts, deny is enforced"
printf '%s\n' "$LLENV" > "$CFG/key-files"
rc="$(run_gate "$GATE")"; note_outputs
assert_eq 2 "$rc" "decision enforced (exit 2 = deny)"
assert_eq "deny" "$(decision_field '.answer')" "decision log: answer deny (the fixture decided)"
assert_eq "null" "$(decision_field '.fallback')" "no fallback: the key was found"
assert_eq "Bearer $SECRET" "$(sink_auth_last)" "SINK-SIDE: the gateway received exactly the .env value as the bearer"

it "G2 the same through CMA_JEV_KEY_FILES (no pointer file) and through JEV_CONFIG_DIR"
rm -f -- "${CFG:?}/key-files"
assert_eq 2 "$(run_gate "$GATE" CMA_JEV_KEY_FILES="$LLENV")" "CMA_JEV_KEY_FILES"
mkdir -p "$HOME/altcfg"; printf '%s\n' "$LLENV" > "$HOME/altcfg/key-files"
assert_eq 2 "$(run_gate "$GATE" JEV_CONFIG_DIR="$HOME/altcfg")" "JEV_CONFIG_DIR relocates the pointer"
assert_eq 0 "$(run_gate "$GATE" JEV_CONFIG_DIR="$HOME/no-such")" "a pointer that does not exist -> nothing found, fail-open"

it "G3 precedence: env var named by JEV_KEY_VAR > keys file > key files"
printf '%s\n' "$LLENV" > "$CFG/key-files"                              # key files hold the RIGHT key
assert_eq 0 "$(run_gate "$GATE" LLMCTL_API_KEY="$WRONG")" "a WRONG key in the environment beats the right key in the key files (-> 401 -> fail-open)"
assert_eq "Bearer $WRONG" "$(sink_auth_last)" "sink saw the environment value"
assert_eq 2 "$(run_gate "$GATE" LLMCTL_API_KEY="$SECRET")" "the right key in the environment works"
printf '%s\n' "LLMCTL_API_KEY=$WRONG" > "$HOME/wrong.env"; chmod 600 "$HOME/wrong.env"; printf '%s\n' "$HOME/wrong.env" > "$CFG/key-files"
printf 'export LLMCTL_API_KEY=%s\n' "$SECRET" > "$KEYS"
assert_eq 2 "$(run_gate "$GATE")" "the keys file (~/api_keys.sh) beats a WRONG key in the key files"
: > "$KEYS"
assert_eq 2 "$(run_gate "$GATE" JEV_API_KEY="$SECRET")" "JEV_API_KEY (direct) beats a WRONG key in the key files"
printf '%s\n' "$HOME/wrong.env" > "$CFG/key-files"; printf '%s\n' "$LLENV" >> "$CFG/key-files"
assert_eq 0 "$(run_gate "$GATE")" "the FIRST listed key file wins even if it is wrong (order is part of the contract)"
printf '%s\n' "$LLENV" > "$CFG/key-files"

it "G4 the key is never on a command line, in the gate's output, or in the decision log; other variables of the .env are never read out"
run_gate "$GATE" >/dev/null; note_outputs
assert_eq 0 "$(grep -cF -- "$SECRET" "$ARGV")" "no curl argv contains the key"
assert_eq yes "$([ "$(grep -c . "$ARGV")" -ge 1 ] && echo yes || echo no)" "positive control: the curl shim saw the gate's call"
assert_eq 0 "$(grep -cF -- "$SECRET" "$HOME/gate.out" "$HOME/gate.err" "$JEV_STATE_DIR/decisions.jsonl" | awk -F: '{s+=$NF} END{print s+0}')" "key not in gate stdout/stderr/decision log"
assert_eq 0 "$(grep -c "do-not-leak" "$FIXLOG" "$HOME/gate.out" "$HOME/gate.err" "$JEV_STATE_DIR/decisions.jsonl" | awk -F: '{s+=$NF} END{print s+0}')" "OTHER_SECRET of the same .env is never touched"

# ================================================================================================ D: the detector
PROVIDERS_SH="$SCRIPTS_DIR/claude-providers.sh"
PINS="$HOME/pins.json"
jq -n --argjson p "$PORT" '{hosted:{}, local_gateway:{host:"127.0.0.1",port:$p,scheme:"https",health_path:"/healthz",models_path:"/v1/models",
  systemone_path:"/v1/systemone",key_var:"LLMCTL_API_KEY",context_limit:64000,enabled:true}, lan:[]}' > "$PINS"
export CMA_JEV_PINS_FILE="$PINS"
ERRF="$HOME/detect.err"
detect() { local p="$1"; shift; env "$@" CMA_JEV_CA_FILE="$CERT" bash -c 'source "$1" >/dev/null 2>&1; detect_jev_records' _ "$p" 2>"$ERRF"; }
local_rec() { jq -c '[.[] | select(.provider_id=="jev-local")] | .[0] // "absent"'; }
it "D1 detector: key only in the .env named by the pointer -> the gateway is registered (no key in env, none in api_keys.sh)"
printf '%s\n' "$LLENV" > "$CFG/key-files"
R="$(detect "$PROVIDERS_SH" | local_rec)"
assert_eq "$BASEURL" "$(jq -r '.base_url // "?"' <<<"$R")" "jev-local registered over https"
assert_eq "LLMCTL_API_KEY" "$(jq -r '.key_var // "?"' <<<"$R")" "record names the key variable (never the value)"
cat "$ERRF" >> "$HOME/all_outputs.log"
rm -f -- "${CFG:?}/key-files"
R="$(detect "$PROVIDERS_SH" | local_rec)"
assert_eq '"absent"' "$R" "without the pointer: not registered (positive/negative control)"
grep -q "no bearer key is available" "$ERRF" && _pass "warning: no bearer key is available" || _fail "no-key warning" "$(cat "$ERRF")"
grep -q "jev key files" "$ERRF" && _pass "warning now names the key-file route too" || _fail "warning names key files" "$(cat "$ERRF")"
cat "$ERRF" >> "$HOME/all_outputs.log"

# ================================================================================================ M: the MCP server
mcp_key() { # mcp_key <scripts-dir> [VAR=val ...] -> the bearer jev_mcp would send
  local sd="$1"; shift
  env -i HOME="$HOME" PATH="$PATH" CMA_KEYS_FILE="$KEYS" JEV_CONFIG_DIR="$CFG" "$@" python3 -I -c '
import sys
sys.path.insert(0, sys.argv[1])
import jev_mcp
sys.stdout.write(jev_mcp._api_key())' "$sd" 2>/dev/null
}
it "M1 MCP server: key files are consulted (registration with the placeholder key, JEV_KEY_VAR present or learned from the cache)"
printf '%s\n' "$LLENV" > "$CFG/key-files"
assert_eq "$SECRET" "$(mcp_key "$SCRIPTS_DIR" JEV_API_KEY=local JEV_KEY_VAR=LLMCTL_API_KEY)" "placeholder JEV_API_KEY + JEV_KEY_VAR -> key file value"
CACHEDIR="$HOME/.local/share/claude-multi-account/providers"; mkdir -p "$CACHEDIR"
printf '%s' '{"endpoints":[{"provider_id":"jev-local","base_url":"https://127.0.0.1:1","key_var":"LLMCTL_API_KEY","model":"m","priority":10,"probed_at":1}]}' > "$CACHEDIR/jev-endpoints.json"
assert_eq "$SECRET" "$(mcp_key "$SCRIPTS_DIR" JEV_API_KEY=local)" "no JEV_KEY_VAR: the variable NAME is learned from the endpoint cache"
assert_eq "direct-real-key" "$(mcp_key "$SCRIPTS_DIR" JEV_API_KEY=direct-real-key)" "a real direct key still wins"
assert_eq "env-wins" "$(mcp_key "$SCRIPTS_DIR" JEV_API_KEY=local LLMCTL_API_KEY=env-wins)" "the env var named by the key var beats the key files"
rm -f -- "${CFG:?}/key-files"
assert_eq "local" "$(mcp_key "$SCRIPTS_DIR" JEV_API_KEY=local)" "nothing anywhere -> the keyless placeholder"
rm -f -- "${CACHEDIR:?}/jev-endpoints.json"

# ================================================================================================ O: the opencode plugin
PLUGIN="$SCRIPTS_DIR/opencode-jev-plugin.js"
plugin_denies() { # plugin_denies <plugin.js> [VAR=val ...] -> throws (key accepted -> deny enforced) | passes (401 -> fail-open)
  local p="$1"; shift
  rm -f -- "${JEV_STATE_DIR:?}/decisions.jsonl"
  env NODE_EXTRA_CA_CERTS="$CERT" JEV_BASE_URL="$BASEURL" JEV_KEY_VAR=LLMCTL_API_KEY JEV_MODE=enforce "$@" node --input-type=module -e '
    const m = await import(process.argv[1]);
    const h = await m.JevGate({ client: {} });
    try { await h["tool.execute.before"]({ tool: "bash" }, { args: { command: "ls -la" } }); console.log("passes"); }
    catch (e) { console.log("throws"); }' "$p" 2>/dev/null
}
if command -v node >/dev/null 2>&1; then
  it "O1 opencode plugin: key from the key files (and precedence env > key files)"
  printf '%s\n' "$LLENV" > "$CFG/key-files"
  : > "$FIXLOG"
  assert_eq throws "$(plugin_denies "$PLUGIN")" "pointer -> the gateway accepted the .env key -> deny enforced"
  assert_eq "Bearer $SECRET" "$(sink_auth_last)" "SINK-SIDE: the plugin sent the .env value"
  assert_eq passes "$(plugin_denies "$PLUGIN" LLMCTL_API_KEY="$WRONG")" "a wrong key in the environment beats the key files (401 -> fail-open)"
  rm -f -- "${CFG:?}/key-files"
  assert_eq passes "$(plugin_denies "$PLUGIN")" "no pointer -> placeholder -> 401 -> fail-open"
  printf '%s\n' "# c" "$LLENV" > "$CFG/key-files"
  assert_eq throws "$(plugin_denies "$PLUGIN" CMA_JEV_KEY_FILES="$HOME/nonexistent.env")" "a missing CMA_JEV_KEY_FILES entry falls through to the pointer file"
else
  it "O1 opencode plugin (SKIPPED: node not installed)"; _skip "node missing"
fi

# ================================================================================================ S: jev-setup --key-file
SETUP="$SCRIPTS_DIR/jev-setup.sh"
it "S1 jev-setup --key-file: validated, idempotent, standalone, value never printed"
rm -rf -- "${CFG:?}"; mkdir -p "$HOME/.claude-acct1"
OUT="$(bash "$SETUP" --key-file "$LLENV" 2>&1)"; rc=$?
echo "$OUT" >> "$HOME/all_outputs.log"
assert_eq 0 "$rc" "rc 0 (no --yes needed: no agent home is touched)"
assert_eq "$LLENV" "$(cat "$CFG/key-files" 2>/dev/null)" "the pointer holds exactly the path"
assert_eq 600 "$(stat -c %a "$CFG/key-files" 2>/dev/null)" "pointer mode 600"
case "$OUT" in *"$SECRET"*|*do-not-leak*) _fail "output is value-free" "a secret leaked" ;; *) _pass "output names the file and the variable, never the value" ;; esac
case "$OUT" in *LLMCTL_API_KEY*) _pass "output names the variable" ;; *) _fail "output names the variable" "$OUT" ;; esac
bash "$SETUP" --key-file "$LLENV" >/dev/null 2>&1
assert_eq 1 "$(grep -c . "$CFG/key-files")" "idempotent: still exactly one line"
assert_eq no "$([ -e "$JEV_STATE_DIR/consent" ] || [ -e "$CFG/env" ] && echo yes || echo no)" "no consent record, no env file, no install happened"
assert_eq 0 "$(find "$HOME/.claude-acct1" -type f | wc -l)" "no agent home was touched"
cd "$HOME" && bash "$SETUP" --key-file "llmctl/.env" >/dev/null 2>&1
assert_eq 1 "$(grep -c . "$CFG/key-files")" "a relative path is normalised to the same absolute line (no duplicate)"
printf 'NOT_THE_VAR=1\n' > "$HOME/novar.env"; chmod 600 "$HOME/novar.env"
bash "$SETUP" --key-file "$HOME/novar.env" >/dev/null 2>&1; rc=$?
assert_eq 2 "$rc" "a file that does not define the key variable is refused (rc 2)"
assert_eq 1 "$(grep -c . "$CFG/key-files")" "...and nothing was recorded"
bash "$SETUP" --key-file "$HOME/does-not-exist.env" >/dev/null 2>&1; assert_eq 2 "$?" "missing file -> rc 2"
bash "$SETUP" --key-file "$HOME" >/dev/null 2>&1; assert_eq 2 "$?" "a directory -> rc 2"
bash "$SETUP" --key-file "$LLENV" --mode enforce >/dev/null 2>&1; assert_eq 2 "$?" "--key-file with --mode -> rc 2 (standalone)"
bash "$SETUP" --key-file "$LLENV" --check >/dev/null 2>&1; assert_eq 2 "$?" "--key-file with --check -> rc 2"
bash "$SETUP" --key-file "$HOME/a:b.env" >/dev/null 2>&1; assert_eq 2 "$?" "a path containing ':' -> rc 2"
bash "$SETUP" --key-file "/etc/os-release" >/dev/null 2>&1; assert_eq 2 "$?" "a file not owned by the user -> rc 2 (and it does not define the variable anyway)"
printf 'no newline at end' > "$CFG/key-files"; bash "$SETUP" --key-file "$LLENV" >/dev/null 2>&1
assert_eq 2 "$(grep -c . "$CFG/key-files")" "an existing pointer without a trailing newline is extended on a NEW line"

it "S2 the whole chain: jev-setup --key-file -> the real gate decides with NO env var and NO api_keys entry"
printf '%s\n' "$LLENV" > "$CFG/key-files"
assert_eq 2 "$(run_gate "$GATE")" "enforce deny reached the gate through the pointer written by jev-setup"
note_outputs

# ================================================================================================ X: secret hygiene over the whole run
it "X: the fixture key appears in no captured output of any consumer, and the sink saw only the fixture key or a placeholder/wrong key"
assert_eq 0 "$(grep -cF -- "$SECRET" "$HOME/all_outputs.log")" "no consumer output contains the key"
assert_eq 0 "$(grep -cF -- "$SECRET" "$ARGV")" "no curl argv of the whole run contains the key"

# ================================================================================================ PAIRED MUTATIONS
MUT="$SANDBOX_HOME/mut"
mutant() { # mutant <name> <file> <old> <new> -> path of <file> in a COPY of scripts/ with ONE exact replacement
  local d="${MUT:?}/${1:?}"
  rm -rf -- "$d"; mkdir -p "$d"; cp -a "$SCRIPTS_DIR" "$d/scripts"
  python3 -I - "$d/scripts/$2" "$3" "$4" <<'PY' || return 1
import sys
f, old, new = sys.argv[1:4]
s = open(f).read()
if s.count(old) != 1:
    sys.exit("mutation anchor found %d times in %s: %r" % (s.count(old), f, old))
open(f, "w").write(s.replace(old, new))
PY
  printf '%s\n' "$d/scripts/$2"
}
killed() { # killed <label> <expected-good> <actual>
  if [[ "$3" != "$2" ]]; then _pass "MUTANT $1 -> '$3' instead of '$2': the suite goes RED"; else _fail "MUTANT $1 survived" "still produced '$2'"; fi
}
mdir() { dirname "$1"; }

it "MK1 mutant: the gate never consults the key files (the original defect)"
MP="$(mutant gate_nolookup jev-gate.sh '  [ -n "$_key" ] || _key="$(_jev_keyfile_lookup "$JEV_KEY_VAR")"' '  :')"
printf '%s\n' "$LLENV" > "$CFG/key-files"
killed gate_nolookup 2 "$(run_gate "$MP")"

it "MK2 mutant: the gate prefers the key files over the process environment"
MP="$(mutant gate_order jev-gate.sh '  _key="${!JEV_KEY_VAR:-}"
  if [ -z "$_key" ] && [ -f' '  _key="$(_jev_keyfile_lookup "$JEV_KEY_VAR")"; [ -n "$_key" ] || _key="${!JEV_KEY_VAR:-}"
  if [ -z "$_key" ] && [ -f')"
killed gate_order 0 "$(run_gate "$MP" LLMCTL_API_KEY="$WRONG")"

it "MK3 mutant: first assignment wins (lib copy)"
MP="$(mutant lib_first jev-keyfile-lib.sh 'if (index(line, n "=") == 1) { v = substr' 'if (!found && index(line, n "=") == 1) { v = substr')"
printf '%s' $'LLMCTL_API_KEY=old\nLLMCTL_API_KEY=new\n' > "$VDIR/f.env"; chmod 600 "$VDIR/f.env"
killed lib_first new "$(LIBSH_UNDER_TEST="$MP" impl_lib LLMCTL_API_KEY "$VDIR/f.env")"

it "MK4 mutant: the owner check is dropped (a foreign file would be trusted)"
if [ -f /etc/os-release ] && [ "$(stat -c %u /etc/os-release 2>/dev/null)" != "$(id -u)" ] && grep -q '^NAME=' /etc/os-release; then
  MP="$(mutant lib_noowner jev-keyfile-lib.sh '[ -f "$p" ] && [ -r "$p" ] && [ -O "$p" ] || continue' '[ -f "$p" ] && [ -r "$p" ] || continue')"
  killed lib_noowner "" "$(LIBSH_UNDER_TEST="$MP" impl_lib NAME /etc/os-release)"
else
  _skip "no root-owned /etc/os-release with NAME="
fi

it "MK5 mutant: quotes are not stripped (gate copy)"
MP="$(mutant gate_noquote jev-gate.sh 'v = substr(v, 2, length(v) - 2)' 'v = v')"
extract_gate_fn "$MP"; GATE_FN_MUT="$HOME/gate_fn_mut.sh"; cp "$GATE_FN" "$GATE_FN_MUT"; extract_gate_fn "$GATE"
printf '%s' $'LLMCTL_API_KEY="abc 123"\n' > "$VDIR/f.env"
killed gate_noquote "abc 123" "$(GATE_FN_UNDER_TEST="$GATE_FN_MUT" impl_gate LLMCTL_API_KEY "$VDIR/f.env")"

it "MK6 mutant: the MCP server ignores the key files"
MP="$(mutant mcp_nofile jev_mcp.py 'return val or _keyfile_lookup(key_var) or "local"' 'return val or "local"')"
printf '%s\n' "$LLENV" > "$CFG/key-files"
killed mcp_nofile "$SECRET" "$(mcp_key "$(mdir "$MP")" JEV_API_KEY=local JEV_KEY_VAR=LLMCTL_API_KEY)"

it "MK7 mutant: the MCP server lets the baked placeholder shadow call-time resolution"
MP="$(mutant mcp_placeholder jev_mcp.py 'if direct and direct != "local":' 'if direct:')"
killed mcp_placeholder "$SECRET" "$(mcp_key "$(mdir "$MP")" JEV_API_KEY=local JEV_KEY_VAR=LLMCTL_API_KEY)"

if command -v node >/dev/null 2>&1; then
  it "MK8 mutant: the opencode plugin ignores the key files"
  MP="$(mutant plugin_nofile opencode-jev-plugin.js 'return v || keyfileLookup(name) || "local";' 'return v || "local";')"
  killed plugin_nofile throws "$(plugin_denies "$MP")"
fi

it "MK9 mutant: the detector ignores the key files"
MP="$(mutant detect_nofile claude-providers.sh '[[ -n "$_key" ]] || _key="$(cma_jev_keyfile_lookup "$_tkeyvar" 2>/dev/null)" || _key=""' ':')"
R="$(detect "$MP" | local_rec)"
killed detect_nofile "$BASEURL" "$(jq -r 'if type == "object" then .base_url else "absent" end' <<<"$R")"

it "MK10 mutant: jev-setup --key-file records a file that does not define the variable"
MP="$(mutant setup_noval jev-setup.sh 'if ! CMA_JEV_KEY_FILES="$_kf" JEV_CONFIG_DIR=/nonexistent/jev cma_jev_keyfile_lookup "$_kv" >/dev/null 2>&1; then' 'if false; then')"
rm -rf -- "${CFG:?}"
bash "$MP" --key-file "$HOME/novar.env" >/dev/null 2>&1; rc=$?
killed setup_noval 2 "$rc"
rm -rf -- "${MUT:?}"

summary
