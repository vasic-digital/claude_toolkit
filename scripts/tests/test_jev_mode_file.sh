#!/usr/bin/env bash
# test_jev_mode_file.sh - `jev-setup --mode enforce` must actually change what the gate does.
#
# Root cause (2026-10-26, captured in the decision-models evidence: "18_jev_env_file_not_read"):
#   `jev-setup --mode enforce` writes JEV_MODE=enforce to ~/.config/jev/env, but NOTHING read that file:
#   jev-gate.sh took `JEV_MODE="${JEV_MODE:-shadow}"`, the launch wrappers (cma_jev_env) exported
#   `JEV_MODE="${JEV_MODE:-shadow}"` and the opencode plugin read process.env.JEV_MODE only. So the documented switch was a
#   no-op and the only working route was a hand-exported env var in a shell rc.
# Contract now (identical in the gate, the wrapper env and the opencode plugin):
#   process env JEV_MODE  >  $JEV_CONFIG_DIR/env (default ~/.config/jev/env)  >  shadow
#   - the file is PARSED, never sourced: only an exact `JEV_MODE=shadow` / `JEV_MODE=enforce` line counts, the last one wins,
#     everything else (other keys, garbage, a command, `export JEV_MODE=...`, trailing comments) is ignored and never executed;
#   - `jev-setup --mode <x>` accepts only shadow|enforce (rc 2 and no write otherwise).
# Drives the REAL gate, the REAL installed copy, the REAL wrapper function and the REAL plugin against the loopback
# systemone fixture. Paired mutations run against a COPY of scripts/ (never the real tree).
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
set +e
unset JEV_MODE JEV_CONFIG_DIR JEV_STATE_DIR JEV_BASE_URL JEV_API_KEY JEV_CA_FILE JEV_GATE JEV_KEY_VAR JEV_SETUP_CONSENT \
      TYPESAFE_API_KEY TYPESAFE_BASE_URL CMA_JEV_DISABLE
export CMA_JEV_ALLOW_HTTP=1
export JEV_STATE_DIR="$HOME/.local/state/jev"

FIXTURE="$SCRIPTS_DIR/tests/fixtures/jev_server.py"
CFG="$HOME/.config/jev"
HOOK='{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'

_pick_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
start_fixture() { # a gateway whose gate question answers DENY (so enforce vs shadow is visible in the exit code)
  local port; port=$(_pick_port)
  printf '%s' '{"gate":"deny"}' > "$HOME/fixture-responses.json"
  CMA_JEV_FIXTURE_RESPONSES="$HOME/fixture-responses.json" python3 "$FIXTURE" "$port" >/dev/null 2>&1 &
  FIX_PID=$!
  local i; for i in $(seq 1 50); do curl -sf -m 1 "http://127.0.0.1:$port/healthz" >/dev/null 2>&1 && break; sleep 0.1; done
  FIX_PORT="$port"
}
start_fixture
trap 'kill "$FIX_PID" 2>/dev/null; cleanup_sandbox' EXIT

write_env() { mkdir -p "$CFG"; printf '%b' "$1" > "$CFG/env"; }
clear_env() { rm -rf -- "${CFG:?}"; }
gate_rc() { # gate_rc <gate.sh> [VAR=val ...] -> prints "<exit code> <mode in the decision log>"
  local g="$1"; shift
  rm -f -- "${JEV_STATE_DIR:?}/decisions.jsonl"
  printf '%s' "$HOOK" | env JEV_BASE_URL="http://127.0.0.1:$FIX_PORT" "$@" bash "$g" >/dev/null 2>&1
  local rc=$?
  printf '%s %s' "$rc" "$(tail -n1 "$JEV_STATE_DIR/decisions.jsonl" 2>/dev/null | jq -r '.mode // "none"' 2>/dev/null)"
}
GATE="$SCRIPTS_DIR/jev-gate.sh"

# ---------------------------------------------------------------------------------------------------------------------------
it "C1 gate: no env, no file -> shadow (deny is logged, never enforced)"
clear_env
assert_eq "0 shadow" "$(gate_rc "$GATE")" "default is shadow"

it "C2 gate: the file says enforce, the env is unset -> ENFORCED (this was the bug: the file was never read)"
write_env 'JEV_MODE=enforce\n'
assert_eq "2 enforce" "$(gate_rc "$GATE")" "file enforce reaches the gate"

it "C3 gate: process env beats the file in both directions"
write_env 'JEV_MODE=enforce\n'
assert_eq "0 shadow" "$(gate_rc "$GATE" JEV_MODE=shadow)" "env shadow beats file enforce"
write_env 'JEV_MODE=shadow\n'
assert_eq "2 enforce" "$(gate_rc "$GATE" JEV_MODE=enforce)" "env enforce beats file shadow"

it "C4 gate: the last exact line wins; garbage is ignored, never sourced or executed"
write_env 'JEV_MODE=enforce\nJEV_MODE=shadow\n'
assert_eq "0 shadow" "$(gate_rc "$GATE")" "last line wins (shadow)"
write_env 'JEV_MODE=shadow\nJEV_MODE=enforce\n'
assert_eq "2 enforce" "$(gate_rc "$GATE")" "last line wins (enforce)"
write_env 'JEV_MODE=bogus\n'
assert_eq "0 shadow" "$(gate_rc "$GATE")" "an invalid value is ignored (shadow)"
write_env 'export JEV_MODE=enforce\nJEV_MODE=enforce # on\n JEV_MODE=enforce\nJEV_MODE=ENFORCE\n'
assert_eq "0 shadow" "$(gate_rc "$GATE")" "export / trailing comment / leading space / wrong case are not exact lines"
write_env 'JEV_MODE=enforce; touch "$HOME/pwned1"\ntouch "$HOME/pwned2"\n$(touch "$HOME/pwned3")\nJEV_MODE=$(touch "$HOME/pwned4")\n'
assert_eq "0 shadow" "$(gate_rc "$GATE")" "command text is not an exact line"
assert_eq 0 "$(find "$HOME" -maxdepth 1 -name 'pwned*' | wc -l)" "nothing in the file was executed"
write_env 'OTHER=1\nJEV_MODE=enforce\nJEV_MODEL=x\n'
assert_eq "2 enforce" "$(gate_rc "$GATE")" "other keys around the line are ignored"
mkdir -p "$HOME/alt"; printf 'JEV_MODE=enforce\n' > "$HOME/alt/env"; clear_env
assert_eq "2 enforce" "$(gate_rc "$GATE" JEV_CONFIG_DIR="$HOME/alt")" "JEV_CONFIG_DIR relocates the file"

# ---------------------------------------------------------------------------------------------------------------------------
# the wrapper environment (cma_jev_env): from lib.sh AND from the rendered managed alias file (the code real shells run)
PDIR="$HOME/.local/share/claude-multi-account/providers"; mkdir -p "$PDIR"
cat > "$PDIR/jev-endpoints.json" <<EOF
{"endpoints":[{"provider_id":"jev-local","base_url":"http://127.0.0.1:$FIX_PORT","key_var":"","model":"jev-fixture-1","priority":10,"probed_at":1}]}
EOF
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"; set +e
_cma_emit_managed "$HOME/.local/bin/claude" > "$ALIAS_FILE"
wrapper_mode() { # wrapper_mode <file-to-source> [VAR=val ...] -> JEV_MODE as exported by cma_jev_env
  local src="$1"; shift
  env -u JEV_MODE "$@" bash -c 'source "$1" >/dev/null 2>&1; CMA_JEV_QUIET=1 cma_jev_env; printf %s "$JEV_MODE"' _ "$src" 2>/dev/null
}
wrapper_notice() { env -u JEV_MODE bash -c 'source "$1" >/dev/null 2>&1; cma_jev_env' _ "$ALIAS_FILE" 2>&1 >/dev/null | grep -o 'mode: [a-z]*'; }

it "C5 wrapper: file enforce -> exports enforce (lib.sh function AND the rendered alias file)"
write_env 'JEV_MODE=enforce\n'
assert_eq enforce "$(wrapper_mode "$SCRIPTS_DIR/lib.sh")" "lib.sh cma_jev_env reads the file"
assert_eq enforce "$(wrapper_mode "$ALIAS_FILE")" "alias-file cma_jev_env reads the file"
assert_eq "mode: enforce" "$(wrapper_notice)" "the launch notice names the effective mode"

it "C6 wrapper: env beats the file; no file -> shadow; garbage ignored and never executed"
assert_eq shadow "$(wrapper_mode "$ALIAS_FILE" JEV_MODE=shadow)" "env shadow beats file enforce"
clear_env
assert_eq shadow "$(wrapper_mode "$ALIAS_FILE")" "no file -> shadow"
write_env 'JEV_MODE=bogus\nJEV_MODE=enforce; touch "$HOME/pwned5"\n'
assert_eq shadow "$(wrapper_mode "$ALIAS_FILE")" "garbage -> shadow"
assert_eq no "$([ -e "$HOME/pwned5" ] && echo yes || echo no)" "the wrapper never executed the file"
write_env 'JEV_MODE=enforce\n'
assert_eq shadow "$(wrapper_mode "$ALIAS_FILE" JEV_CONFIG_DIR="$HOME/no-such-dir")" "JEV_CONFIG_DIR points at a dir without the file -> shadow"
assert_eq enforce "$(wrapper_mode "$ALIAS_FILE" JEV_CONFIG_DIR="$HOME/alt")" "JEV_CONFIG_DIR relocates the file for the wrapper too"

it "C7 wrapper -> gate contract: the mode the wrapper exports is the mode the gate enforces (no disagreement inside one launch)"
write_env 'JEV_MODE=enforce\n'
W="$(wrapper_mode "$ALIAS_FILE")"
assert_eq "2 enforce" "$(gate_rc "$GATE" JEV_MODE="$W")" "wrapper-exported mode drives the gate"

# ---------------------------------------------------------------------------------------------------------------------------
# end to end through the REAL installer and the INSTALLED standalone gate copy (which cannot source any repo lib)
it "C8 jev-setup --mode: validated before any write; enforce reaches the installed gate; shadow reverts it"
export HOME="$SANDBOX_HOME/e2e"; export SHARED_DIR="$HOME/.claude-shared"; export JEV_STATE_DIR="$HOME/.local/state/jev"
CFG="$HOME/.config/jev"
mkdir -p "$HOME/.claude-acct1" "$SHARED_DIR" "$HOME/.local/bin" "$HOME/.local/share/claude-multi-account/providers"
cp "$PDIR/jev-endpoints.json" "$HOME/.local/share/claude-multi-account/providers/jev-endpoints.json"
SETUP="$SCRIPTS_DIR/jev-setup.sh"
bash "$SETUP" --yes --quiet --agents claude --mode bogus >/dev/null 2>&1; rc=$?
assert_eq 2 "$rc" "--mode bogus is a usage error (rc 2)"
assert_eq no "$([ -e "$CFG/env" ] && echo yes || echo no)" "--mode bogus wrote nothing"
bash "$SETUP" --yes --quiet --agents claude --mode enforce >/dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "--mode enforce installs (rc 0)"
assert_eq "JEV_MODE=enforce" "$(cat "$CFG/env" 2>/dev/null)" "the env file holds exactly the mode line"
INSTALLED="$HOME/.local/share/claude-multi-account/jev/jev-gate.sh"
assert_file "$INSTALLED" "the standalone gate copy is installed"
assert_eq "2 enforce" "$(gate_rc "$INSTALLED")" "INSTALLED gate enforces after jev-setup --mode enforce, with NO env var set"
bash "$SETUP" --yes --quiet --agents claude --mode shadow >/dev/null 2>&1
assert_eq "0 shadow" "$(gate_rc "$INSTALLED")" "jev-setup --mode shadow reverts it"
bash "$SETUP" --yes --quiet --agents claude >/dev/null 2>&1
assert_eq "JEV_MODE=shadow" "$(cat "$CFG/env" 2>/dev/null)" "a re-run without --mode keeps the file (idempotent)"
bash "$SETUP" --yes --quiet --agents claude --mode enforce >/dev/null 2>&1
bash "$SETUP" --yes --quiet --agents claude >/dev/null 2>&1
assert_eq "2 enforce" "$(gate_rc "$INSTALLED")" "a re-run without --mode does NOT silently drop enforce"

# ---------------------------------------------------------------------------------------------------------------------------
# the opencode plugin (a separate implementation: it shares nothing with the bash gate)
PLUGIN="$SCRIPTS_DIR/opencode-jev-plugin.js"
plugin_denies() { # plugin_denies <plugin.js> [VAR=val ...] -> "throws" when the tool.execute.before hook blocks, else "passes"
  local p="$1"; shift
  rm -f -- "${JEV_STATE_DIR:?}/decisions.jsonl"
  env JEV_BASE_URL="http://127.0.0.1:$FIX_PORT" "$@" node --input-type=module -e '
    const m = await import(process.argv[1]);
    const h = await m.JevGate({ client: {} });
    try { await h["tool.execute.before"]({ tool: "bash" }, { args: { command: "ls -la" } }); console.log("passes"); }
    catch (e) { console.log("throws"); }' "$p" 2>/dev/null
}
if command -v node >/dev/null 2>&1; then
  it "C9 opencode plugin: file enforce -> blocks a deny; env shadow beats it; no file -> passes"
  write_env 'JEV_MODE=enforce\n'
  assert_eq throws "$(plugin_denies "$PLUGIN")" "file enforce blocks (env unset)"
  assert_eq passes "$(plugin_denies "$PLUGIN" JEV_MODE=shadow)" "env shadow beats file enforce"
  write_env 'JEV_MODE=enforce; touch x\nJEV_MODE=bogus\n'
  assert_eq passes "$(plugin_denies "$PLUGIN")" "garbage in the file is ignored"
  clear_env
  assert_eq passes "$(plugin_denies "$PLUGIN")" "no file -> shadow (passes)"
else
  it "C9 opencode plugin (SKIPPED: node not installed)"; _skip "node missing"
fi

# ---------------------------------------------------------------------------------------------------------------------------
# PAIRED MUTATIONS: each re-introduces ONE defect into a COPY of scripts/ and the matching case above MUST go RED.
# ---------------------------------------------------------------------------------------------------------------------------
MUT="$SANDBOX_HOME/mut"
mutant() { # mutant <name> <file> <old> <new> -> prints the path of <file> in a copy of scripts/ with ONE exact replacement
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
killed() { # killed <label> <expected-good-value> <actual>
  if [[ "$3" != "$2" ]]; then _pass "MUTANT $1 -> '$3' instead of '$2': the suite goes RED"; else _fail "MUTANT $1 survived" "still produced '$2'"; fi
}
export HOME="$SANDBOX_HOME/mutate"; CFG="$HOME/.config/jev"; export JEV_STATE_DIR="$HOME/.local/state/jev"
mkdir -p "$HOME/.local/share/claude-multi-account/providers"
cp "$PDIR/jev-endpoints.json" "$HOME/.local/share/claude-multi-account/providers/jev-endpoints.json"   # the wrapper needs the endpoint cache

it "M1 mutant: the gate ignores the file (the original defect)"
MP="$(mutant gate_nofile jev-gate.sh '_jev_cfg_env="${JEV_CONFIG_DIR:-$HOME/.config/jev}/env"' '_jev_cfg_env=/nonexistent/jev/env')"
write_env 'JEV_MODE=enforce\n'
killed gate_nofile "2 enforce" "$(gate_rc "$MP")"

it "M2 mutant: precedence inverted (the file overrides an explicit process env)"
MP="$(mutant gate_inverted jev-gate.sh 'if [ -z "${JEV_MODE:-}" ]; then
  _jev_cfg_env=' 'if true; then
  _jev_cfg_env=')"
write_env 'JEV_MODE=enforce\n'
killed gate_inverted "0 shadow" "$(gate_rc "$MP" JEV_MODE=shadow)"

it "M3 mutant: the file is sourced instead of parsed (command injection)"
MP="$(mutant gate_source jev-gate.sh '    JEV_MODE=$(grep -E '"'"'^JEV_MODE=(shadow|enforce)$'"'"' "$_jev_cfg_env" 2>/dev/null | tail -n1 | cut -d= -f2)' '    . "$_jev_cfg_env"')"
write_env 'JEV_MODE=shadow; touch "$HOME/pwned-mutant"\n'
gate_rc "$MP" >/dev/null
killed gate_source no "$([ -e "$HOME/pwned-mutant" ] && echo yes || echo no)"
rm -f -- "${HOME:?}/pwned-mutant"

it "M4 mutant: the wrapper ignores the file (cma_jev_env exports shadow while the gate would enforce)"
MP="$(mutant wrapper_nofile lib.sh 'if [ -z "${JEV_MODE:-}" ] && [ -r "${JEV_CONFIG_DIR:-$HOME/.config/jev}/env" ]; then' 'if false; then')"
write_env 'JEV_MODE=enforce\n'
killed wrapper_nofile enforce "$(wrapper_mode "$MP")"

it "M5 mutant: jev-setup accepts any --mode value (the validation is gone)"
MP="$(mutant setup_noval jev-setup.sh "case \"\$MODE\" in ''|shadow|enforce) : ;; *) _usage_err" "case \"\$MODE\" in *) : ;; *) _usage_err")"
export SHARED_DIR="$HOME/.claude-shared"; mkdir -p "$HOME/.claude-acct1" "$SHARED_DIR" "$HOME/.local/bin"
rm -rf -- "${CFG:?}"
bash "$MP" --yes --quiet --agents claude --mode bogus >/dev/null 2>&1; rc=$?
killed setup_noval 2 "$rc"

if command -v node >/dev/null 2>&1; then
  it "M6 mutant: the opencode plugin ignores the file"
  MP="$(mutant plugin_nofile opencode-jev-plugin.js 'join(process.env.JEV_CONFIG_DIR || join(homedir(), ".config/jev"), "env")' '"/nonexistent/jev/env"')"
  write_env 'JEV_MODE=enforce\n'
  killed plugin_nofile throws "$(plugin_denies "$MP")"
fi
rm -rf -- "${MUT:?}"

summary
