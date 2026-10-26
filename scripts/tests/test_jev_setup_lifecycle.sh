#!/usr/bin/env bash
# test_jev_setup_lifecycle.sh — the (agent selection x install/uninstall/render/
# check x fresh/upgrade) cell matrix of the Jev installer, driven ONLY through the
# real scripts/jev-setup.sh invocation and the real Kimi twin renderer
# (review round 2, classes A + B). Every cell runs in its own HOME.
#
# Cells (CELL-n ids are quoted in the CHANGELOG):
#   L1  install claude only        -> stamp lists claude; kimi-prov render adds NO hook (consent)
#   L2  install kimi only          -> stamp lists kimi; render adds the hook; claude untouched
#   L3  install all, uninstall kimi   -> gate survives (claude hook still points at it);
#                                        claude --check OK; kimi twins stripped and stay stripped
#   L4  install all, uninstall claude -> gate survives (kimi native block points at it);
#                                        kimi twin hook still rendered
#   L5  install all, uninstall claude,kimi -> opencode still installed: common artifacts kept
#   L6  install all, uninstall all    -> everything gone, nothing re-rendered
#   L7  --check: hook target deleted / not executable -> reported, not "hooks OK"
#   L8  upgrade: native home with the v1.31.0 matcher -> --check flags STALE; install rewrites it
#   L9  install claude, then install kimi -> stamp is the UNION (nothing forgotten)
#   L10 --if-stale refresh does not widen the recorded agent scope
#   L11 TOML safety of the NATIVE writer: backslash / quote / newline / tab in the gate path
#   L12 the shared validator itself (jev-kimi-lib.sh): safe path accepted, unsafe refused
#   L13 jev-kimi-tools.txt missing / invalid -> the same single file is validated by BOTH
#       writers, and the failure is WARNED about (never a silent second hard-coded copy)
#   L14 legacy/empty stamp + exactly ONE agent really wired (claude | kimi | opencode):
#       uninstalling a DIFFERENT agent keeps the shared gate (the inventory, not the stamp,
#       protects the wiring) - one cell per _inventory_wiring branch
#   L15 --yes --if-stale on a legacy/empty or absent stamp never widens the scope:
#       refreshes only what is actually wired, nothing when nothing is
#   L16 unknown / miscased --agents values are a usage error (rc 2), never an empty stamp
#   L17 --check --uninstall is refused (rc 2) and --check never writes (tree hash identical)
#   L18 native Kimi block rewrite: atomic, idempotent (no blank-line growth), block-only config
#   L19 claude --check parses the hook command (`bash /path/jev-gate.sh` is not "MISSING")
#   L20 --check without --agents audits the stamp scope, not all four agents
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${CMA_TEST_SCRIPTS_DIR:-$(cd "$TESTS_DIR/.." && pwd)}"
export SCRIPTS_DIR
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required"; exit 0; }
python3 -c 'import tomllib' >/dev/null 2>&1 || { echo "SKIP: tomllib (3.11+) required"; exit 0; }
set +e
unset JEV_MODE JEV_STATE_DIR JEV_BASE_URL JEV_API_KEY JEV_CA_FILE JEV_GATE JEV_SETUP_CONSENT TYPESAFE_API_KEY TYPESAFE_BASE_URL
export CMA_JEV_ALLOW_HTTP=1

BASE="$SANDBOX_HOME"
SETUP="$SCRIPTS_DIR/jev-setup.sh"
PROVS="$SCRIPTS_DIR/claude-providers.sh"
N=0

_cell() { # fresh HOME with one claude account, one native + one provider kimi home, opencode
  N=$((N + 1))
  export HOME="$BASE/cell$N"
  export SHARED_DIR="$HOME/.claude-shared"
  mkdir -p "$HOME/.claude-acct1" "$HOME/.kimi-code-1" "$HOME/.kimi-prov-bar" "$SHARED_DIR" \
           "$HOME/.config/opencode" "$HOME/.local/bin" "$HOME/.local/share/claude-multi-account/providers"
  echo '{"model":"opus"}' > "$HOME/.claude-acct1/settings.json"
  printf 'default_model = "k1"\n' > "$HOME/.kimi-code-1/config.toml"
  printf 'default_model = "b1"\n' > "$HOME/.kimi-prov-bar/config.toml"
  echo '{}' > "$HOME/.config/opencode/opencode.json"
  printf '{"version":1,"generated_at":1,"ttl":300,"endpoints":[{"provider_id":"p","base_url":"https://127.0.0.1:1","model":"m","priority":1}]}\n' \
    > "$HOME/.local/share/claude-multi-account/providers/jev-endpoints.json"
  GATE="$HOME/.local/share/claude-multi-account/jev/jev-gate.sh"
  STAMP="$HOME/.local/state/jev/installed.stamp"
  KNAT="$HOME/.kimi-code-1/config.toml"
  KPROV="$HOME/.kimi-prov-bar/config.toml"
  CSET="$HOME/.claude-acct1/settings.json"
}
_setup() { bash "$SETUP" --quiet "$@" >"$HOME/.out" 2>&1; echo $? > "$HOME/.rc"; cat "$HOME/.out" >/dev/null; }
_check() { bash "$SETUP" --check "$@" >"$HOME/.out" 2>&1; echo $? > "$HOME/.rc"; }   # no --quiet: findings are the output
_render() { bash -c 'source "$1" >/dev/null 2>&1; set +e; _cma_kimi_render_config bar BAR_KEY native https://api.example.invalid m-1 8192' _ "$PROVS" 2>"$HOME/.render.err"; }
_nhook() { grep -c 'cma-jev:hooks BEGIN' "$1" 2>/dev/null; }
_claude_hook() { jq -r '[.hooks.PreToolUse[]?.hooks[]?.command? // empty | select(contains("jev-gate.sh"))] | length' "$CSET" 2>/dev/null; }
_gate_ok() { [ -x "$GATE" ] && echo yes || echo no; }
_hook_cmd_exec() { # the command string the claude hook runs must be an executable file
  local c; c="$(jq -r '[.hooks.PreToolUse[]?.hooks[]?.command? // empty | select(contains("jev-gate.sh"))][0] // ""' "$CSET")"
  [ -n "$c" ] && [ -x "$c" ] && echo yes || echo no; }
_toml_ok() { python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$1" 2>/dev/null && echo yes || echo no; }

it "L1: install --agents claude only -> stamp lists claude, kimi-prov render adds NO hook"
_cell
_setup --yes --agents claude
assert_eq 1 "$(_claude_hook)" "claude hook wired"
assert_eq 0 "$(_nhook "$KNAT")" "native kimi home untouched by --agents claude"
assert_file_contains "$STAMP" "agents=claude" "stamp records exactly the selected agent"
_render
assert_eq 0 "$(_nhook "$KPROV")" "kimi NOT selected -> the twin renderer emits no hook block"
bash -c 'source "$1" >/dev/null 2>&1; set +e; _cma_kimi_jev_hooks_refresh' _ "$PROVS"
assert_eq 0 "$(_nhook "$KPROV")" "sync-time refresh also adds no hook block"

it "L2: install --agents kimi only -> stamp lists kimi, render adds the hook, claude untouched"
_cell
_setup --yes --agents kimi
assert_file_contains "$STAMP" "agents=kimi" "stamp records kimi"
assert_eq 0 "$(_claude_hook)" "claude settings untouched"
assert_eq 1 "$(_nhook "$KNAT")" "native kimi hook block written"
_render
assert_eq 1 "$(_nhook "$KPROV")" "kimi selected -> twin hook block rendered"

it "L3: install all, uninstall --agents kimi -> gate survives, claude hook still resolves, twins stay stripped"
_cell
_setup --yes
assert_eq 1 "$(_nhook "$KNAT")" "precondition: native block present"
_render; assert_eq 1 "$(_nhook "$KPROV")" "precondition: twin block present"
_setup --uninstall --agents kimi
assert_eq 0 "$(cat "$HOME/.rc")" "uninstall --agents kimi exits 0"
assert_eq yes "$(_gate_ok)" "canonical gate STILL exists (claude hook points at it)"
assert_eq 1 "$(_claude_hook)" "claude hook still registered"
assert_eq yes "$(_hook_cmd_exec)" "claude hook command resolves to an executable file"
assert_eq 0 "$(_nhook "$KNAT")" "native kimi block stripped"
assert_eq 0 "$(_nhook "$KPROV")" "kimi-prov twin block stripped"
_check --agents claude
if grep -q 'MISSING\|not executable' "$HOME/.out"; then _fail "claude --check after kimi uninstall" "$(cat "$HOME/.out")"; else _pass "claude --check clean after kimi uninstall"; fi
_render; assert_eq 0 "$(_nhook "$KPROV")" "render after kimi uninstall: no hook re-added (kimi no longer selected)"
assert_file_not_contains "$STAMP" "kimi" "stamp no longer lists kimi"
assert_file_contains "$STAMP" "claude" "stamp still lists claude"

it "L4: install all, uninstall --agents claude -> gate survives for kimi, twin hook still rendered"
_cell
_setup --yes
_setup --uninstall --agents claude
assert_eq yes "$(_gate_ok)" "canonical gate STILL exists (kimi native block points at it)"
assert_eq 0 "$(_claude_hook)" "claude hook removed"
assert_eq 1 "$(_nhook "$KNAT")" "native kimi block kept"
_render; assert_eq 1 "$(_nhook "$KPROV")" "kimi still selected -> twin hook still rendered"
assert_file_contains "$STAMP" "kimi" "stamp still lists kimi"

it "L5: uninstall claude,kimi while opencode stays installed -> shared artifacts kept"
_cell
_setup --yes
_setup --uninstall --agents claude,kimi
assert_eq 0 "$(_claude_hook)" "claude hook removed"
assert_eq 0 "$(_nhook "$KNAT")" "kimi block removed"
assert_jq "$HOME/.config/opencode/opencode.json" '.mcp.jev.type' local "opencode still installed"
assert_file "$HOME/.config/opencode/plugins/jev-gate.js" "opencode plugin kept"
assert_file "$HOME/.config/jev/env" "env file kept while any agent wiring remains"

it "L6: install all, uninstall all -> everything removed and nothing re-rendered"
_cell
_setup --yes
_setup --uninstall
assert_eq no "$(_gate_ok)" "gate removed when no wiring remains"
assert_eq no "$([ -e "$STAMP" ] && echo yes || echo no)" "stamp removed"
assert_eq no "$([ -e "$HOME/.config/jev/env" ] && echo yes || echo no)" "env file removed"
_render; assert_eq 0 "$(_nhook "$KPROV")" "render after full uninstall adds nothing"

it "L7: --check verifies the hook TARGET exists and is executable, not just the string"
_cell
_setup --yes
rm -f "$GATE"
_check --agents claude
assert_eq 1 "$(cat "$HOME/.rc")" "--check exits non-zero on a dangling target"
grep -q 'claude:.*\(MISSING\|not executable\)' "$HOME/.out" && _pass "claude --check reports a dangling hook target" || _fail "claude --check reported a deleted gate as OK" "$(cat "$HOME/.out")"
_check --agents kimi
grep -q 'kimi:.*\(MISSING\|not executable\)' "$HOME/.out" && _pass "kimi --check reports a dangling hook target" || _fail "kimi --check reported a deleted gate as OK" "$(cat "$HOME/.out")"
_setup --yes --agents claude        # reinstall heals
assert_eq yes "$(_hook_cmd_exec)" "reinstall restores the gate"
chmod -x "$GATE"
_check --agents claude
grep -q 'claude:.*\(MISSING\|not executable\)' "$HOME/.out" && _pass "claude --check reports a non-executable hook target" || _fail "non-executable gate reported OK" "$(cat "$HOME/.out")"

it "L8: upgrade — native home carrying the v1.31.0 matcher is flagged STALE by --check and rewritten by install"
_cell
_setup --yes --agents claude
cat >> "$KNAT" <<'EOF'

# cma-jev:hooks BEGIN
[[hooks]]
event = "PreToolUse"
matcher = "Bash|WriteFile|StrReplaceFile"
command = "/old/gate.sh"
timeout = 5
# cma-jev:hooks END
EOF
_check --agents kimi
grep -q 'kimi:.*STALE' "$HOME/.out" && _pass "--check flags the stale matcher" || _fail "stale matcher reported OK" "$(cat "$HOME/.out")"
_setup --yes --agents kimi
assert_eq 1 "$(_nhook "$KNAT")" "still exactly one block after upgrade"
M="$(python3 -c 'import sys,tomllib; print(tomllib.load(open(sys.argv[1],"rb"))["hooks"][0]["matcher"])' "$KNAT")"
assert_eq "Bash|Write|Edit" "$M" "matcher upgraded to the real tool names"
C="$(python3 -c 'import sys,tomllib; print(tomllib.load(open(sys.argv[1],"rb"))["hooks"][0]["command"])' "$KNAT")"
assert_eq "$GATE" "$C" "command upgraded to the installed gate"
assert_file_contains "$KNAT" 'default_model = "k1"' "unrelated config preserved by the upgrade"
h1="$(sha256sum "$KNAT" | cut -d' ' -f1)"; _setup --yes --agents kimi; h2="$(sha256sum "$KNAT" | cut -d' ' -f1)"
assert_eq "$h1" "$h2" "upgrade is idempotent (byte-identical on the next run)"
_check --agents kimi
if grep -q 'STALE\|MISSING' "$HOME/.out"; then _fail "--check after upgrade" "$(cat "$HOME/.out")"; else _pass "--check clean after upgrade"; fi

it "L9: install claude, then install kimi -> the stamp is the UNION"
_cell
_setup --yes --agents claude
_setup --yes --agents kimi
assert_file_contains "$STAMP" "claude" "union keeps claude"
assert_file_contains "$STAMP" "kimi" "union adds kimi"
_render; assert_eq 1 "$(_nhook "$KPROV")" "twin hook rendered once kimi is selected"

it "L10: --if-stale refresh does not widen the recorded agent scope"
_cell
_setup --yes --agents claude
touch -d '2 days ago' "$STAMP"
_setup --if-stale 60
assert_eq 0 "$(cat "$HOME/.rc")" "--if-stale exits 0"
assert_eq 0 "$(_nhook "$KNAT")" "a launch-time refresh must not wire kimi when only claude was consented to"
assert_file_not_contains "$STAMP" "kimi" "stamp scope unchanged"

it "L11: native writer TOML safety — unsafe gate paths are refused, config stays valid"
for kind in backslash quote newline tab; do
  _cell
  case "$kind" in
    backslash) H="$BASE/cell$N/we\\ird" ;;
    quote)     H="$BASE/cell$N/we\"ird" ;;
    newline)   H="$BASE/cell$N/we"$'\n'"ird" ;;
    tab)       H="$BASE/cell$N/we"$'\t'"ird" ;;
  esac
  mkdir -p "$H/.kimi-code-1" "$H/.local/share/claude-multi-account/providers"
  printf 'default_model = "k1"\n' > "$H/.kimi-code-1/config.toml"
  ( export HOME="$H"; export SHARED_DIR="$H/.claude-shared"; bash "$SETUP" --quiet --yes --agents kimi >"$H/.out" 2>&1 )
  assert_eq 0 "$(_nhook "$H/.kimi-code-1/config.toml")" "$kind gate path -> native writer emits no hook block"
  assert_eq yes "$(_toml_ok "$H/.kimi-code-1/config.toml")" "$kind gate path -> native config still valid TOML"
  grep -qi 'refus\|unsafe' "$H/.out" && _pass "$kind: refusal is reported" || _fail "$kind: silent refusal" "$(cat "$H/.out")"
done

it "L12: the ONE shared validator (scripts/jev-kimi-lib.sh)"
LIB="$SCRIPTS_DIR/jev-kimi-lib.sh"
assert_file "$LIB" "shared validator file exists"
v() { bash -c 'source "$1"; jev_kimi_gate_path_safe "$2"; echo $?' _ "$LIB" "$1" 2>/dev/null | tail -1; }
assert_eq 0 "$(v "/home/u/.local/share/jev/jev-gate.sh")" "plain path accepted"
assert_eq 1 "$(v 'a\b')" "backslash refused"
assert_eq 1 "$(v 'a"b')" "double quote refused"
assert_eq 1 "$(v $'a\nb')" "newline (control char) refused"
assert_eq 1 "$(v $'a\tb')" "tab (control char) refused"
assert_eq 1 "$(v $'a\x7fb')" "DEL (control char) refused"
m() { bash -c 'source "$1"; jev_kimi_matcher_valid "$2"; echo $?' _ "$LIB" "$1" 2>/dev/null | tail -1; }
assert_eq 0 "$(m 'Bash|Write|Edit')" "matcher of tool names accepted"
assert_eq 1 "$(m 'Bash|')" "empty alternative refused"
assert_eq 1 "$(m 'Bash.*')" "regex metacharacter refused"
assert_eq 1 "$(m '')" "empty matcher refused"

it "L13: missing/invalid jev-kimi-tools.txt -> both writers warn and neither falls back to a private copy"
T="$BASE/tools-tree"; mkdir -p "$T"
find "$SCRIPTS_DIR" -maxdepth 1 -type f -exec cp -p {} "$T/" \;
ln -s "$SCRIPTS_DIR/providers" "$T/providers"
rm -f "$T/jev-kimi-tools.txt"
_cell
( bash "$T/jev-setup.sh" --quiet --yes --agents kimi >"$HOME/.out" 2>&1 )
assert_eq 0 "$(_nhook "$KNAT")" "setup: missing constant file -> no hook block (no private fallback)"
grep -q 'jev-kimi-tools.txt' "$HOME/.out" && _pass "setup: warns naming jev-kimi-tools.txt" || _fail "setup: silent about the missing constant file" "$(cat "$HOME/.out")"
printf 'Bash|Wr!te\n' > "$T/jev-kimi-tools.txt"
rm -rf "$HOME/.local/state/jev"
( bash "$T/jev-setup.sh" --quiet --yes --agents kimi >"$HOME/.out" 2>&1 )
assert_eq 0 "$(_nhook "$KNAT")" "setup: invalid constant file -> no hook block"
grep -q 'jev-kimi-tools.txt' "$HOME/.out" && _pass "setup: warns about the invalid constant file" || _fail "setup: silent about an invalid constant file" "$(cat "$HOME/.out")"
_cell
( bash "$T/jev-setup.sh" --quiet --yes --agents kimi >/dev/null 2>&1 ) # valid stamp/gate, then break the file
rm -f "$T/jev-kimi-tools.txt"
TREE_PROVS="$T/claude-providers.sh" bash -c 'source "$TREE_PROVS" >/dev/null 2>&1; set +e; _cma_kimi_render_config bar BAR_KEY native https://api.example.invalid m-1 8192' 2>"$HOME/.render.err"
assert_eq 0 "$(_nhook "$KPROV")" "renderer: missing constant file -> no hook block"
grep -q 'jev-kimi-tools.txt' "$HOME/.render.err" && _pass "renderer: warns naming jev-kimi-tools.txt" || _fail "renderer: silent about the missing constant file" "$(cat "$HOME/.render.err")"

_treehash() { find "$HOME" -type f ! -name .out ! -name .rc ! -name .render.err -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1; }

it "L14: legacy/empty stamp + one agent really wired -> uninstalling ANOTHER agent keeps the shared gate (inventory protects it)"
for who in claude kimi opencode; do
  _cell
  _setup --yes --agents "$who"
  : > "$STAMP"                                   # legacy stamp: names nobody
  _setup --uninstall --agents pi
  assert_eq 0 "$(cat "$HOME/.rc")" "$who: uninstall --agents pi exits 0"
  assert_eq yes "$(_gate_ok)" "$who: wired agent still present -> canonical gate kept (empty stamp must not authorise its removal)"
  assert_file "$HOME/.config/jev/env" "$who: env file kept"
  assert_file_contains "$STAMP" "agents=$who" "$who: stamp rebuilt from the inventory"
  case "$who" in
    claude)   assert_eq 1 "$(_claude_hook)" "claude hook still registered" ;;
    kimi)     assert_eq 1 "$(_nhook "$KNAT")" "native kimi block still present" ;;
    opencode) assert_file "$HOME/.config/opencode/plugins/jev-gate.js" "opencode plugin still present" ;;
  esac
  # control: with the wiring really removed the same uninstall DOES remove the gate
  _setup --uninstall --agents "$who"
  assert_eq no "$(_gate_ok)" "$who: control - after uninstalling the wired agent the gate is gone"
done

it "L15: --yes --if-stale on a legacy/empty/absent stamp never widens the consented scope"
_cell
_setup --yes --agents claude
: > "$STAMP"; touch -d '2 days ago' "$STAMP"
_setup --yes --if-stale 60
assert_eq 0 "$(cat "$HOME/.rc")" "claude-only install, empty stamp: --yes --if-stale exits 0"
assert_eq 0 "$(_nhook "$KNAT")" "empty stamp: kimi NOT wired on a Claude-only install"
assert_eq no "$([ -e "$HOME/.config/opencode/plugins/jev-gate.js" ] && echo yes || echo no)" "empty stamp: opencode plugin NOT installed"
assert_eq 1 "$(_claude_hook)" "empty stamp: the really-wired claude hook is kept"
assert_file_not_contains "$STAMP" "kimi" "empty stamp: scope not widened to kimi"
assert_file_not_contains "$STAMP" "opencode" "empty stamp: scope not widened to opencode"
_cell
_setup --yes --agents kimi
: > "$STAMP"; touch -d '2 days ago' "$STAMP"; rm -f "$CSET.x"
before_claude="$(cat "$CSET")"
_setup --yes --if-stale 60
assert_eq "$before_claude" "$(cat "$CSET")" "kimi-only install, empty stamp: claude settings untouched by the refresh"
assert_eq 1 "$(_nhook "$KNAT")" "kimi-only install, empty stamp: the wired kimi block is refreshed/kept"
_cell
mkdir -p "$HOME/.local/state/jev"; : > "$HOME/.local/state/jev/consent"      # consent but nothing wired, no stamp
_setup --yes --if-stale 60
assert_eq 0 "$(cat "$HOME/.rc")" "nothing wired, no stamp: --if-stale exits 0"
assert_eq 0 "$(_claude_hook)" "nothing wired, no stamp: claude not wired"
assert_eq 0 "$(_nhook "$KNAT")" "nothing wired, no stamp: kimi not wired"
assert_eq no "$([ -e "$HOME/.config/opencode/plugins/jev-gate.js" ] && echo yes || echo no)" "nothing wired, no stamp: opencode not wired"

it "L16: unknown / miscased --agents values are a usage error (rc 2), never an empty stamp"
for bad in Kimi bogus claude,Pi claude,bogus "" , " " ,, "claude kimi" "claude," ",claude" "claude,,kimi" "claude, kimi"; do
  _cell
  h0="$(_treehash)"
  _setup --yes --agents "$bad"
  assert_eq 2 "$(cat "$HOME/.rc")" "--agents '$bad' -> usage error rc 2"
  grep -qi 'unknown agent\|non-empty list\|empty entry\|whitespace' "$HOME/.out" && _pass "'$bad': clear error message" || _fail "'$bad': silent" "$(cat "$HOME/.out")"
  assert_eq no "$([ -e "$STAMP" ] && echo yes || echo no)" "'$bad': no stamp written (in particular no empty agents= stamp)"
  assert_eq "$h0" "$(_treehash)" "'$bad': nothing under HOME was written"
done
_cell; _setup --uninstall --agents Kimi
assert_eq 2 "$(cat "$HOME/.rc")" "--uninstall --agents Kimi -> rc 2"
_cell; _check --agents Kimi
assert_eq 2 "$(cat "$HOME/.rc")" "--check --agents Kimi -> rc 2"
_cell; _setup --yes --agents all
assert_eq 0 "$(cat "$HOME/.rc")" "control: --agents all is accepted"
assert_file_contains "$STAMP" "agents=claude,kimi,pi,opencode" "control: all -> canonical full stamp"

it "L17: --check --uninstall is refused and --check never writes (tree hash identical)"
_cell
_setup --yes
h0="$(_treehash)"
_check --uninstall
assert_eq 2 "$(cat "$HOME/.rc")" "--check --uninstall -> usage error rc 2"
assert_eq "$h0" "$(_treehash)" "--check --uninstall wrote nothing (every file byte-identical)"
_check --uninstall --agents kimi
assert_eq 2 "$(cat "$HOME/.rc")" "--check --uninstall --agents kimi -> rc 2"
assert_eq "$h0" "$(_treehash)" "--check --uninstall --agents kimi wrote nothing"
assert_eq 1 "$(_nhook "$KNAT")" "native kimi block still there"
assert_eq 1 "$(_claude_hook)" "claude hook still there"
_check
assert_eq "$h0" "$(_treehash)" "plain --check wrote nothing either"

it "L18: native Kimi stale-block rewrite is atomic, idempotent (no blank-line growth) and handles a block-only config"
_cell
_setup --yes --agents claude
cat >> "$KNAT" <<'EOF'

# cma-jev:hooks BEGIN
[[hooks]]
event = "PreToolUse"
matcher = "Old"
command = "/old/gate.sh"
timeout = 5
# cma-jev:hooks END
EOF
_setup --yes --agents kimi
R1="$(cat "$KNAT")"; assert_eq 1 "$(_nhook "$KNAT")" "one block after the first rewrite"
for i in 1 2 3; do
  sed -i 's/^matcher = .*/matcher = "Old"/' "$KNAT"
  _setup --yes --agents kimi
  assert_eq "$R1" "$(cat "$KNAT")" "rewrite #$i is byte-identical to the first (no accumulating blank lines)"
done
assert_eq yes "$(_toml_ok "$KNAT")" "config still valid TOML"
assert_eq 0 "$(ls "$HOME/.kimi-code-1"/config.toml.jevtmp.* 2>/dev/null | wc -l)" "no temp file left behind"
# failing rewrite: awk broken -> original untouched, reported, no temp
mkdir -p "$HOME/shim"; printf '#!/bin/sh\nexit 1\n' > "$HOME/shim/awk"; chmod +x "$HOME/shim/awk"
sed -i 's/^matcher = .*/matcher = "Old"/' "$KNAT"
hs="$(sha256sum "$KNAT" | cut -d' ' -f1)"
PATH="$HOME/shim:$PATH" bash "$SETUP" --yes --agents kimi >"$HOME/.out" 2>&1
assert_eq "$hs" "$(sha256sum "$KNAT" | cut -d' ' -f1)" "failing rewrite keeps the original byte-identical"
grep -qi 'untouched\|could not' "$HOME/.out" && _pass "failing rewrite is reported" || _fail "silent rewrite failure" "$(cat "$HOME/.out")"
assert_eq 0 "$(ls "$HOME/.kimi-code-1"/config.toml.jevtmp.* 2>/dev/null | wc -l)" "no temp left after the failed rewrite"
# block-only config
_cell
_setup --yes --agents claude
cat > "$KNAT" <<'EOF'
# cma-jev:hooks BEGIN
[[hooks]]
event = "PreToolUse"
matcher = "Old"
command = "/old/gate.sh"
timeout = 5
# cma-jev:hooks END
EOF
_setup --yes --agents kimi
assert_eq 1 "$(_nhook "$KNAT")" "block-only config: rewritten, exactly one block"
M="$(python3 -c 'import sys,tomllib; print(tomllib.load(open(sys.argv[1],"rb"))["hooks"][0]["matcher"])' "$KNAT" 2>/dev/null)"
assert_eq "Bash|Write|Edit" "$M" "block-only config: matcher upgraded"
_setup --uninstall --agents kimi
assert_eq 0 "$(_nhook "$KNAT")" "block-only config: --uninstall strips the block (empty result is legitimate)"
assert_eq yes "$(_toml_ok "$KNAT")" "block-only config after uninstall is valid TOML"

it "L19: claude --check parses the hook command (bash /path/jev-gate.sh is not reported MISSING)"
_cell
_setup --yes --agents claude
jq --arg c "bash $GATE" '(.hooks.PreToolUse[] | .hooks[] | select(.command | contains("jev-gate.sh")) | .command) = $c' "$CSET" > "$CSET.n" && mv "$CSET.n" "$CSET"
_check --agents claude
if grep -q 'MISSING\|not executable' "$HOME/.out"; then _fail "interpreter-prefixed command reported broken" "$(cat "$HOME/.out")"; else _pass "claude --check: 'bash <gate>' resolves"; fi
assert_eq 0 "$(cat "$HOME/.rc")" "claude --check rc 0 for 'bash <gate>'"
jq '(.hooks.PreToolUse[] | .hooks[] | select(.command | contains("jev-gate.sh")) | .command) = "bash /nonexistent/dir/jev-gate.sh"' "$CSET" > "$CSET.n" && mv "$CSET.n" "$CSET"
_check --agents claude
grep -q 'claude:.*MISSING' "$HOME/.out" && _pass "control: a nonexistent gate behind 'bash' is still reported MISSING" || _fail "dangling 'bash <gate>' reported OK" "$(cat "$HOME/.out")"
assert_eq 1 "$(cat "$HOME/.rc")" "control: rc 1"

it "L20: --check without --agents audits the stamp scope, not all four agents"
_cell
_setup --yes
_setup --uninstall --agents claude
_check
assert_eq 0 "$(cat "$HOME/.rc")" "check after uninstalling claude (stamp = remaining agents) exits 0"
grep -q 'claude:' "$HOME/.out" && _fail "claude audited although not in the stamp scope" "$(cat "$HOME/.out")" || _pass "claude not audited"
grep -q 'kimi:' "$HOME/.out" && _pass "control: kimi (in scope) audited" || _fail "control: kimi not audited" "$(cat "$HOME/.out")"
_cell                                            # no stamp, nothing wired -> falls back to all four (findings expected)
_check
assert_eq 1 "$(cat "$HOME/.rc")" "no stamp and nothing wired: falls back to auditing all (findings -> rc 1)"
grep -q 'claude:' "$HOME/.out" && _pass "fallback audits claude" || _fail "fallback did not audit claude" "$(cat "$HOME/.out")"

it "L21: opencode inventory - the plugin file and the .mcp.jev entry each protect the gate on their own (R4-9)"
for half in plugin-only mcp-only; do
  _cell
  _setup --yes --agents opencode
  case "$half" in
    plugin-only) jq 'del(.mcp.jev)' "$HOME/.config/opencode/opencode.json" > "$HOME/oc.n" && mv "$HOME/oc.n" "$HOME/.config/opencode/opencode.json"
                 assert_file "$HOME/.config/opencode/plugins/jev-gate.js" "$half: precondition - plugin file present" ;;
    mcp-only)    rm -f "$HOME/.config/opencode/plugins/jev-gate.js"
                 assert_eq yes "$(jq -e '.mcp.jev' "$HOME/.config/opencode/opencode.json" >/dev/null 2>&1 && echo yes || echo no)" "$half: precondition - .mcp.jev present" ;;
  esac
  : > "$STAMP"                                    # legacy stamp: only the inventory can protect the gate
  _setup --uninstall --agents pi
  assert_eq 0 "$(cat "$HOME/.rc")" "$half: uninstall --agents pi exits 0"
  assert_eq yes "$(_gate_ok)" "$half: the single opencode wiring half keeps the shared gate"
done
_cell; _setup --yes --agents opencode; : > "$STAMP"; _setup --uninstall --agents pi; _setup --uninstall --agents opencode
assert_eq no "$(_gate_ok)" "control: with both opencode halves removed the gate IS removed"

it "L22: uninstall keeps the shared gate for the agents still listed in the stamp, pi and kimi included (R4-5)"
_cell
_setup --yes --agents claude,pi
assert_file_contains "$STAMP" "agents=claude,pi" "precondition: stamp lists claude and pi"
_setup --uninstall --agents claude
assert_eq 0 "$(cat "$HOME/.rc")" "uninstall --agents claude exits 0"
assert_eq yes "$(_gate_ok)" "pi is still consented (no inventory branch can see it): the gate is KEPT"
assert_file_contains "$STAMP" "agents=pi" "stamp keeps exactly the remaining agent"
_setup --uninstall --agents pi
assert_eq no "$(_gate_ok)" "control: uninstalling the last agent removes the gate"
_cell
_setup --yes --agents claude,kimi
rm -rf "$HOME/.kimi-code-1"                       # kimi consented but its home is gone: the inventory cannot see it
_setup --uninstall --agents claude
assert_eq yes "$(_gate_ok)" "kimi consented (home gone, so no inventory): the gate is KEPT"
assert_file_contains "$STAMP" "agents=kimi" "stamp keeps kimi"

it "L23: --if-stale 0 never widens the scope; a non-numeric --if-stale is a usage error (R4-7)"
_cell
_setup --yes --agents claude
_setup --yes --if-stale 0
assert_eq 0 "$(cat "$HOME/.rc")" "--yes --if-stale 0 exits 0"
assert_file_contains "$STAMP" "agents=claude" "stamp still exactly claude"
assert_file_not_contains "$STAMP" "kimi" "--if-stale 0: kimi not added"
assert_eq 0 "$(_nhook "$KNAT")" "--if-stale 0: no kimi block"
assert_eq no "$([ -e "$HOME/.config/opencode/plugins/jev-gate.js" ] && echo yes || echo no)" "--if-stale 0: no opencode plugin"
for bad in abc -1 1.5; do
  _cell; _setup --yes --agents claude; h1="$(_treehash)"
  _setup --yes --if-stale "$bad"
  assert_eq 2 "$(cat "$HOME/.rc")" "--if-stale '$bad' -> usage error rc 2"
  assert_eq "$h1" "$(_treehash)" "--if-stale '$bad': nothing written"
done

it "L24: kimi --check reports a gate that is not executable (R4-8)"
_cell
_setup --yes --agents kimi
chmod -x "$GATE"
_check --agents kimi
grep -q 'kimi:.*not executable' "$HOME/.out" && _pass "kimi --check: 'not executable' reported" || _fail "kimi --check silent on a non-executable gate" "$(cat "$HOME/.out")"
assert_eq 1 "$(cat "$HOME/.rc")" "kimi --check rc 1"
chmod +x "$GATE"; _check --agents kimi
assert_eq 0 "$(cat "$HOME/.rc")" "control: executable gate -> kimi --check rc 0"

_stale_block() { cat >> "$1" <<'STALE'

# cma-jev:hooks BEGIN
[[hooks]]
event = "PreToolUse"
matcher = "Old"
command = "/old/gate.sh"
timeout = 5
# cma-jev:hooks END
STALE
}

it "L25: the config rewrites are backup-first AND fail-closed (R4-6)"
_cell
_setup --yes --agents claude
_stale_block "$KNAT"
_setup --yes --agents kimi
bk="$(grep -l 'matcher = "Old"' "$HOME/.kimi-code-1"/config.toml.prejev.* 2>/dev/null | head -n 1)"
[ -n "$bk" ] && _pass "a .prejev backup holding the OLD config exists" || _fail "no backup of the pre-rewrite config" "$(ls -la "$HOME/.kimi-code-1")"
_cell
_setup --yes --agents claude
_stale_block "$KNAT"
mkdir -p "$HOME/shim"; RCP="$(command -v cp)"
printf '#!/bin/sh\ncase "$*" in *.prejev.*) exit 1 ;; esac\nexec "%s" "$@"\n' "$RCP" > "$HOME/shim/cp"; chmod +x "$HOME/shim/cp"
hs="$(sha256sum "$KNAT" | cut -d' ' -f1)"
PATH="$HOME/shim:$PATH" bash "$SETUP" --yes --agents kimi >"$HOME/.out" 2>&1
assert_eq "$hs" "$(sha256sum "$KNAT" | cut -d' ' -f1)" "backup could not be made -> the config is NOT rewritten (byte-identical)"
grep -qi 'backup' "$HOME/.out" && _pass "the failed backup is reported" || _fail "backup failure silent" "$(cat "$HOME/.out")"
assert_eq 0 "$(ls "$HOME/.kimi-code-1"/config.toml.jevtmp.* 2>/dev/null | wc -l)" "no temp left behind"

it "L26: a hand-edited stamp naming only unknown agents never widens the scope or writes an empty stamp (R4-11d)"
_cell
mkdir -p "$HOME/.local/state/jev"; printf 'agents=bogus,foo\n' > "$STAMP"
_setup --yes --if-stale 0
assert_eq 0 "$(cat "$HOME/.rc")" "unknown-only stamp, nothing wired: exits 0"
assert_eq 0 "$(_claude_hook)" "claude not wired"
assert_eq 0 "$(_nhook "$KNAT")" "kimi not wired"
_cell
_setup --yes --agents claude
printf 'agents=bogus,foo\n' > "$STAMP"
_setup --yes --if-stale 0
assert_file_contains "$STAMP" "agents=claude" "unknown-only stamp + really wired claude: the inventory scopes the refresh"
assert_eq 0 "$(_nhook "$KNAT")" "kimi still not wired"

it "L27: a symlinked native Kimi config.toml keeps its symlink; the target is rewritten (R4-11)"
_cell
_setup --yes --agents claude
mv "$KNAT" "$HOME/real-k1.toml"; ln -s "$HOME/real-k1.toml" "$KNAT"
_stale_block "$HOME/real-k1.toml"
_setup --yes --agents kimi
assert_eq yes "$([ -L "$KNAT" ] && echo yes || echo no)" "config.toml is still a symlink"
assert_eq "$HOME/real-k1.toml" "$(readlink "$KNAT")" "and still points at the same target"
assert_eq 1 "$(_nhook "$HOME/real-k1.toml")" "the symlink TARGET carries the (single) rewritten block"
assert_eq 0 "$(grep -c 'matcher = "Old"' "$HOME/real-k1.toml")" "and the stale matcher is gone"

# --- races: a background twin refresh (the detached `claude-providers sync-jev`) versus a foreground writer.
# The awk shim runs the REAL awk first and then sleeps: it only widens the read -> replace window.
_render_model() { bash -c 'source "$1" >/dev/null 2>&1; set +e; _cma_kimi_render_config bar BAR_KEY native https://api.example.invalid "$RM" 8192' _ "$PROVS" 2>"$HOME/.render.err"; }
_race_setup() {
  _cell
  _setup --yes --agents kimi
  RM=m-OLD _render_model
  mkdir -p "$HOME/shim"; RA="$(command -v awk)"
  printf '#!/bin/sh\n"%s" "$@"; rc=$?; sleep 2; exit $rc\n' "$RA" > "$HOME/shim/awk"; chmod +x "$HOME/shim/awk"
}
_bg_refresh() { ( PATH="$HOME/shim:$PATH" bash -c 'source "$1" >/dev/null 2>&1; set +e; _cma_kimi_jev_hooks_refresh' _ "$PROVS" ) & RACE_BG=$!; sleep 0.7; }

it "L28: race 1 - a foreground render landing inside a background refresh is never reverted (R4-1)"
_race_setup
assert_eq 1 "$(_nhook "$KPROV")" "precondition: twin has the hook block"
_bg_refresh
RM=m-NEW _render_model
wait "$RACE_BG"
assert_eq 'model = "m-NEW"' "$(grep '^model = ' "$KPROV")" "the foreground render's model survives the background refresh (no lost update)"
assert_eq 1 "$(_nhook "$KPROV")" "exactly one hook block"
assert_eq yes "$(_toml_ok "$KPROV")" "twin config is valid TOML"
_race_setup
export JEV_KIMI_LOCK_NO_FLOCK=1
_bg_refresh
RM=m-NEW _render_model
wait "$RACE_BG"
unset JEV_KIMI_LOCK_NO_FLOCK
assert_eq 'model = "m-NEW"' "$(grep '^model = ' "$KPROV")" "mkdir-lock backend (no flock): the same race is closed"

it "L29: race 2 - a background refresh never resurrects the hook block after a foreground --uninstall (R4-1)"
_race_setup
_bg_refresh
bash "$SETUP" --quiet --uninstall >/dev/null 2>&1
wait "$RACE_BG"
assert_eq 0 "$(_nhook "$KPROV")" "no hook block in the twin after uninstall + refresh"
assert_eq 0 "$(_nhook "$KNAT")" "no hook block in the native home"
assert_eq no "$(_gate_ok)" "gate removed"
assert_eq 0 "$(grep -c '^command = ' "$KPROV")" "no dangling hook command left in the twin"


it "L30: the hook block is recomputed UNDER the lock (stale consent read before the lock must not be written) (R4-1)"
if command -v flock >/dev/null 2>&1; then
  _race_setup
  SD="$HOME/.local/state/jev"
  ( exec 7>>"$SD/kimi-config.lock"; flock 7; sleep 2.5 ) &
  HOLD=$!
  sleep 0.4
  ( bash -c 'source "$1" >/dev/null 2>&1; set +e; _cma_kimi_jev_hooks_refresh' _ "$PROVS" ) & RACE_BG=$!
  sleep 0.7                                         # the refresh is now waiting for the lock
  rm -f "$STAMP" "$GATE"                            # what a concurrent --uninstall does while it holds the lock
  wait "$HOLD"; wait "$RACE_BG"
  assert_eq 0 "$(_nhook "$KPROV")" "refresh that waited for the lock saw the post-uninstall state: no block resurrected"
  assert_eq 'model = "m-OLD"' "$(grep '^model = ' "$KPROV")" "model untouched"
else
  _pass "SKIP: flock(1) absent on this host - the held-lock scenario needs it"
fi

it "L31: a symlinked twin config.toml survives a refresh with its symlink intact (R4-11)"
_cell
_setup --yes --agents kimi
RM=m-OLD _render_model
mv "$KPROV" "$HOME/real-twin.toml"; ln -s "$HOME/real-twin.toml" "$KPROV"
rm -f "$STAMP"                                      # refresh must now strip the block
bash -c 'source "$1" >/dev/null 2>&1; set +e; _cma_kimi_jev_hooks_refresh' _ "$PROVS" 2>/dev/null
assert_eq yes "$([ -L "$KPROV" ] && echo yes || echo no)" "twin config.toml is still a symlink"
assert_eq 0 "$(_nhook "$HOME/real-twin.toml")" "and its target carries the refreshed (block-free) content"

it "L32: claude --check resolves 'bash <gate>' when the gate path contains spaces (R4-11)"
_cell
_setup --yes --agents claude
SP="$HOME/dir with space"; mkdir -p "$SP"; cp -p "$GATE" "$SP/jev-gate.sh"
jq --arg c "bash $SP/jev-gate.sh" '(.hooks.PreToolUse[] | .hooks[] | select(.command | contains("jev-gate.sh")) | .command) = $c' "$CSET" > "$CSET.n" && mv "$CSET.n" "$CSET"
_check --agents claude
if grep -q 'MISSING\|not executable' "$HOME/.out"; then _fail "spaced gate path reported broken" "$(cat "$HOME/.out")"; else _pass "claude --check: 'bash <spaced gate>' resolves"; fi
assert_eq 0 "$(cat "$HOME/.rc")" "rc 0 for a spaced gate path"
rm -f "$SP/jev-gate.sh"; _check --agents claude
grep -q 'claude:.*MISSING' "$HOME/.out" && _pass "control: the spaced gate removed is still reported MISSING" || _fail "dangling spaced gate reported OK" "$(cat "$HOME/.out")"

it "L33: a hostile endpoint cache cannot make jev-setup write a real key for an unpinned origin (R3 I-1)"
_cell
DUMMYK="dummy-secret-key-L33"
printf 'export TYPESAFE_API_KEY=%s\nexport OPENROUTER_API_KEY=%s\n' "$DUMMYK" "$DUMMYK" > "$HOME/keys.sh"
export CMA_KEYS_FILE="$HOME/keys.sh"
EPC="$HOME/.local/share/claude-multi-account/providers/jev-endpoints.json"
printf '{"version":1,"generated_at":1,"ttl":300,"endpoints":[{"provider_id":"p","base_url":"https://evil.example.invalid","key_var":"TYPESAFE_API_KEY","model":"m","priority":1}]}\n' > "$EPC"
_setup --yes --agents claude,kimi,opencode
leaked=0
for f in "$HOME/.claude-acct1/.mcp.json" "$HOME/.kimi-code-1/mcp.json" "$HOME/.config/opencode/opencode.json"; do
  grep -q "$DUMMYK" "$f" 2>/dev/null && leaked=$((leaked + 1))
done
assert_eq 0 "$leaked" "no MCP config carries the real key for an unpinned https origin"
assert_eq yes "$([ -s "$HOME/.claude-acct1/.mcp.json" ] && grep -q evil.example.invalid "$HOME/.claude-acct1/.mcp.json" && echo yes || echo no)" "control: the claude MCP entry was still written (base recorded)"
# injection through key_var in the cache must not execute
printf '{"version":1,"generated_at":1,"ttl":300,"endpoints":[{"provider_id":"p","base_url":"https://api.typesafe.ai","key_var":"X}; touch %s/pwned; echo ${Y","model":"m","priority":1}]}\n' "$HOME" > "$EPC"
_setup --yes --agents claude
assert_eq no "$([ -e "$HOME/pwned" ] && echo yes || echo no)" "a hostile key_var in the cache is never executed"
# positive control: the shipped pin with its own key variable still gets its key
printf '{"version":1,"generated_at":1,"ttl":300,"endpoints":[{"provider_id":"p","base_url":"https://api.typesafe.ai","key_var":"TYPESAFE_API_KEY","model":"m","priority":1}]}\n' > "$EPC"
_setup --yes --agents claude
assert_eq yes "$(grep -q "$DUMMYK" "$HOME/.claude-acct1/.mcp.json" && echo yes || echo no)" "control: a shipped-pin origin with its own key variable keeps its key"
# the shipped pin with ANOTHER key variable must not
printf '{"version":1,"generated_at":1,"ttl":300,"endpoints":[{"provider_id":"p","base_url":"https://api.typesafe.ai","key_var":"OPENROUTER_API_KEY","model":"m","priority":1}]}\n' > "$EPC"
_setup --yes --agents claude
assert_eq no "$(grep -q "$DUMMYK" "$HOME/.claude-acct1/.mcp.json" && echo yes || echo no)" "a shipped origin with a different key variable gets no key"
unset CMA_KEYS_FILE

it "L34: jev-setup and claude-providers resolve the SAME state dir under CMA_PROVIDERS_DIR (R3 minor b)"
_cell
export CMA_PROVIDERS_DIR="$HOME/isolated-providers"
mkdir -p "$CMA_PROVIDERS_DIR"
_setup --yes --agents claude
assert_file "$CMA_PROVIDERS_DIR/jev-state/installed.stamp" "stamp written under CMA_PROVIDERS_DIR/jev-state"
assert_eq no "$([ -e "$HOME/.local/state/jev/installed.stamp" ] && echo yes || echo no)" "and not in the real home state dir"
SD="$(bash -c 'source "$1" >/dev/null 2>&1; _cma_jev_state_dir' _ "$PROVS")"
assert_eq "$CMA_PROVIDERS_DIR/jev-state" "$SD" "claude-providers resolves the same directory"
JEV_STATE_DIR="$HOME/explicit-state" ; export JEV_STATE_DIR
_setup --yes --agents claude
assert_file "$HOME/explicit-state/installed.stamp" "explicit JEV_STATE_DIR still wins"
unset JEV_STATE_DIR CMA_PROVIDERS_DIR

summary
