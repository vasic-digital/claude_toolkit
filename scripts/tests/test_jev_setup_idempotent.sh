#!/usr/bin/env bash
# test_jev_setup_idempotent.sh — jev-setup.sh runs twice → byte-identical
# toolkit-owned config; hooks/mcp/blocks present in sandboxed claude/kimi/
# opencode configs; --check agrees when installed; --uninstall removes every
# block while leaving pre-existing keys intact.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
set +e
# These suites drive plain-http loopback fixtures; since v1.32.0 plain http is an
# explicit opt-in (TLS is the default). test_jev_detect_https.sh covers the default.
export CMA_JEV_ALLOW_HTTP=1

SETUP="$SCRIPTS_DIR/jev-setup.sh"

# Sandboxed agent homes with pre-existing content that must survive.
make_account acct1
mkdir -p "$HOME/.claude-prov-foo" "$HOME/.kimi-code-1" "$HOME/.kimi-prov-bar" \
         "$SHARED_DIR" "$HOME/.config/opencode"
echo '{"model":"opus","permissions":{"allow":["Bash(ls)"]}}' > "$HOME/.claude-acct1/settings.json"
echo '{"existing":true}' > "$HOME/.claude-prov-foo/settings.json"
printf 'default_model = "k1"\n' > "$HOME/.kimi-code-1/config.toml"
printf 'default_model = "b1"\n' > "$HOME/.kimi-prov-bar/config.toml"
echo '{"mcp":{"other":{"type":"local","command":["x"]}}}' > "$HOME/.config/opencode/opencode.json"

# Toolkit-owned files whose bytes must be identical across a re-run.
_owned_files() {
  find "$HOME" -type f \
    \( -name settings.json -o -name .mcp.json -o -name mcp.json \
       -o -name config.toml -o -name CLAUDE.md -o -name opencode.json \
       -o -name jev-gate.js -o -name env \) \
    ! -path '*/.npm/*' | sort
}

it "first install writes hooks, mcp, CLAUDE.md block, opencode plugin"
bash "$SETUP" --quiet --yes
rc=$?
assert_eq 0 "$rc" "jev-setup exits 0"
assert_jq "$HOME/.claude-acct1/settings.json" \
  '[.hooks.PreToolUse[] | select(.matcher=="Bash|Agent|Task")] | length' 1 "claude hook matcher group present"
assert_jq "$HOME/.claude-acct1/settings.json" '.model' 'opus' "pre-existing settings key preserved"
assert_jq "$HOME/.claude-acct1/settings.json" '.permissions.allow[0]' 'Bash(ls)' "nested pre-existing key preserved"
assert_jq "$HOME/.claude-acct1/.mcp.json" '.mcpServers.jev.command' 'python3' "claude .mcp.json registration"
assert_jq "$HOME/.claude-prov-foo/settings.json" '.existing' 'true' "provider home key preserved"
assert_jq "$SHARED_DIR/settings.json" \
  '[.hooks.PreToolUse[] | select(.matcher=="Bash|Agent|Task")] | length' 1 "shared seed settings got hooks"
assert_file_contains "$SHARED_DIR/CLAUDE.md" "cma-jev:decision-architecture BEGIN" "CLAUDE.md block present"
assert_file_contains "$HOME/.kimi-code-1/config.toml" "cma-jev:hooks BEGIN" "kimi native hooks block"
assert_jq "$HOME/.kimi-code-1/mcp.json" '.mcpServers.jev.command' 'python3' "kimi native mcp.json"
assert_jq "$HOME/.kimi-prov-bar/mcp.json" '.mcpServers.jev.command' 'python3' "kimi provider mcp.json"
assert_file_contains "$HOME/.kimi-code-1/config.toml" 'default_model = "k1"' "kimi config content preserved"
assert_file "$HOME/.config/opencode/plugins/jev-gate.js" "opencode plugin installed"
assert_jq "$HOME/.config/opencode/opencode.json" '.mcp.jev.type' 'local' "opencode mcp entry"
assert_jq "$HOME/.config/opencode/opencode.json" '.mcp.other.type' 'local' "pre-existing opencode mcp preserved"
assert_jq "$HOME/.config/opencode/opencode.json" '[.plugin[] | select(contains("jev-gate"))] | length' 1 "opencode plugin entry"

it "second run is byte-identical (idempotent)"
_owned_files | xargs md5sum > "$HOME/.snap1"
bash "$SETUP" --quiet --yes
_owned_files | xargs md5sum > "$HOME/.snap2"
if cmp -s "$HOME/.snap1" "$HOME/.snap2"; then _pass "byte-identical re-run"; else
  _fail "re-run changed files" "$(diff "$HOME/.snap1" "$HOME/.snap2")"
fi
assert_eq 1 "$(grep -c 'cma-jev:decision-architecture BEGIN' "$SHARED_DIR/CLAUDE.md")" "CLAUDE.md block exactly once"
assert_eq 1 "$(grep -c 'cma-jev:hooks BEGIN' "$HOME/.kimi-code-1/config.toml")" "kimi block exactly once"
assert_jq "$HOME/.claude-acct1/settings.json" \
  '[.hooks.PreToolUse[] | select(.matcher=="Bash|Agent|Task")] | length' 1 "hook group still exactly one"

it "--check audits clean after install"
bash "$SETUP" --quiet --check > "$HOME/.check-out" 2>&1
rc=$?
assert_eq 0 "$rc" "--check exits 0 when installed"
if grep -q MISSING "$HOME/.check-out"; then _fail "--check reports MISSING" "$(cat "$HOME/.check-out")"; else _pass "--check reports nothing missing"; fi

it "kimi-prov twin: render after install adds the hooks block exactly once with the shared matcher"
PROVS="$SCRIPTS_DIR/claude-providers.sh"
mkdir -p "$HOME/.local/share/claude-multi-account/providers"
printf '{"version":1,"generated_at":1,"ttl":300,"endpoints":[{"provider_id":"p","base_url":"https://127.0.0.1:1","model":"m","priority":1}]}\n' \
  > "$HOME/.local/share/claude-multi-account/providers/jev-endpoints.json"
_render_bar() { bash -c 'source "$1" >/dev/null 2>&1; set +e; _cma_kimi_render_config bar BAR_KEY native https://api.example.invalid m-1 8192' _ "$PROVS"; }
_render_bar; _render_bar
BARC="$HOME/.kimi-prov-bar/config.toml"
assert_eq 1 "$(grep -c 'cma-jev:hooks BEGIN' "$BARC")" "twin: hooks block exactly once after two renders"
assert_eq "$(tr -d '[:space:]' < "$SCRIPTS_DIR/jev-kimi-tools.txt")" \
  "$(python3 -c 'import sys,tomllib; print(tomllib.load(open(sys.argv[1],"rb"))["hooks"][0]["matcher"])' "$BARC")" "twin: matcher == shared constant"
assert_eq "$(tr -d '[:space:]' < "$SCRIPTS_DIR/jev-kimi-tools.txt")" \
  "$(python3 -c 'import sys,tomllib; print(tomllib.load(open(sys.argv[1],"rb"))["hooks"][0]["matcher"])' "$HOME/.kimi-code-1/config.toml")" "native: matcher == shared constant"

it "--uninstall removes all blocks, preserves other keys"
bash "$SETUP" --quiet --uninstall
rc=$?
assert_eq 0 "$rc" "--uninstall exits 0"
assert_jq "$HOME/.claude-acct1/settings.json" '.hooks.PreToolUse | length' 0 "claude hooks removed"
assert_jq "$HOME/.claude-acct1/settings.json" '.model' 'opus' "settings key survives uninstall"
if jq -e '.mcpServers.jev' "$HOME/.claude-acct1/.mcp.json" >/dev/null 2>&1; then
  _fail "claude mcp entry still present"; else _pass "claude mcp entry removed"; fi
assert_file_not_contains "$SHARED_DIR/CLAUDE.md" "cma-jev:decision-architecture" "CLAUDE.md block removed"
assert_file_not_contains "$HOME/.kimi-code-1/config.toml" "cma-jev:hooks" "kimi block removed"
assert_file_contains "$HOME/.kimi-code-1/config.toml" 'default_model = "k1"' "kimi config survives uninstall"
if jq -e '.mcp.jev' "$HOME/.config/opencode/opencode.json" >/dev/null 2>&1; then
  _fail "opencode mcp entry still present"; else _pass "opencode mcp entry removed"; fi
assert_jq "$HOME/.config/opencode/opencode.json" '.mcp.other.type' 'local' "opencode other mcp survives"
if [ -e "$HOME/.config/opencode/plugins/jev-gate.js" ]; then
  _fail "opencode plugin file still present"; else _pass "opencode plugin file removed"; fi

assert_file_not_contains "$HOME/.kimi-prov-bar/config.toml" "cma-jev:hooks" "kimi-prov twin: block removed by --uninstall"

it "uninstall sticks: the next render does NOT re-add the hook (install -> render -> uninstall -> render)"
assert_eq "no" "$([ -e "$HOME/.local/share/claude-multi-account/jev/jev-gate.sh" ] && echo yes || echo no)" "canonical gate copy removed by --uninstall"
_render_bar
assert_file_not_contains "$HOME/.kimi-prov-bar/config.toml" "cma-jev:hooks" "post-uninstall render leaves no hook block"
python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$HOME/.kimi-prov-bar/config.toml"; assert_eq 0 "$?" "twin config still valid TOML"
bash "$SETUP" --quiet --yes
_render_bar
assert_eq 1 "$(grep -c 'cma-jev:hooks BEGIN' "$HOME/.kimi-prov-bar/config.toml")" "re-install then render -> hook is back, once"

summary
