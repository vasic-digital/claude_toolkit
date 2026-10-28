#!/usr/bin/env bash
# test_jev_setup_base_homes.sh - the default single-account agent homes
# (~/.claude, ~/.kimi-code, ~/.pi) are wired by jev-setup ONLY on explicit
# opt-in (--base-homes or JEV_WIRE_AGENT_HOMES=1); a base home that already
# carries our marker stays maintained; --uninstall always reaches it; --check
# never writes; backups are taken first; hosted endpoints stay shadow.
# Everything runs inside a HOME sandbox: no real agent home is ever touched.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
set +e
export CMA_JEV_ALLOW_HTTP=1
SETUP="$SCRIPTS_DIR/jev-setup.sh"

mkdir -p "$HOME/.claude" "$HOME/.kimi-code" "$HOME/.pi" "$HOME/.config/opencode" "$SHARED_DIR"
echo '{"model":"opus","keep":1}' > "$HOME/.claude/settings.json"
printf 'default_model = "base"\n' > "$HOME/.kimi-code/config.toml"
echo '{"mcp":{}}' > "$HOME/.config/opencode/opencode.json"
# Stub `pi` and `npm` so the pi leg is deterministic and offline-safe.
BIN="$HOME/stubbin"; mkdir -p "$BIN"
printf '#!/bin/sh\nexit 0\n' > "$BIN/npm"
cat > "$BIN/pi" <<'S'
#!/bin/sh
printf '%s\n' "${PI_CODING_AGENT_DIR:-unset}" >> "$HOME/pi-calls.log"
exit 0
S
chmod +x "$BIN/npm" "$BIN/pi"
export PATH="$BIN:$PATH"

_snap() { find "$HOME/.claude" "$HOME/.kimi-code" "$HOME/.pi" -type f 2>/dev/null | sort | xargs -r sha256sum; }
_calls() { [ -s "$HOME/pi-calls.log" ] && wc -l < "$HOME/pi-calls.log" || echo 0; }

it "default run does NOT touch the base homes"
before="$(_snap)"
bash "$SETUP" --quiet --yes; rc=$?
assert_eq 0 "$rc" "jev-setup exits 0 without opt-in"
assert_eq "$before" "$(_snap)" "~/.claude ~/.kimi-code ~/.pi byte-identical without opt-in"
assert_jq "$HOME/.claude/settings.json" '.hooks // "none"' none "no hook added to ~/.claude"
assert_eq 0 "$(_calls)" "pi install not run for ~/.pi without opt-in"
assert_file "$HOME/.config/opencode/plugins/jev-gate.js" "opencode is always in scope"

it "--check with opt-in is a dry audit: nothing written"
before="$(_snap)"
bash "$SETUP" --check --base-homes >/dev/null 2>&1
assert_eq "$before" "$(_snap)" "--check --base-homes writes nothing"
assert_eq 0 "$(_calls)" "--check never runs pi install"

it "--base-homes wires claude, kimi, pi base homes (backup first)"
bash "$SETUP" --quiet --yes --base-homes; rc=$?
assert_eq 0 "$rc" "opt-in run exits 0"
assert_jq "$HOME/.claude/settings.json" \
  '[.hooks.PreToolUse[] | select(.matcher=="Bash|Agent|Task")] | length' 1 "claude base hook present"
assert_jq "$HOME/.claude/settings.json" '.keep' 1 "pre-existing claude key preserved"
assert_jq "$HOME/.claude/.mcp.json" '.mcpServers.jev.command' python3 "claude base .mcp.json registration"
assert_file_contains "$HOME/.kimi-code/config.toml" "cma-jev:hooks BEGIN" "kimi base hooks block"
assert_file_contains "$HOME/.kimi-code/config.toml" 'default_model = "base"' "kimi content preserved"
assert_jq "$HOME/.kimi-code/mcp.json" '.mcpServers.jev.command' python3 "kimi base mcp.json"
assert_file_contains "$HOME/pi-calls.log" "$HOME/.pi" "pi install targeted ~/.pi"
n="$(find "$HOME/.claude" "$HOME/.kimi-code" -name '*.prejev.*' 2>/dev/null | wc -l)"
[ "$n" -ge 2 ] && _ok=0 || _ok=1
assert_eq 0 "$_ok" "backup files (*.prejev.*) created for base homes (found $n)"

it "an already-marked base home stays maintained without the opt-in, idempotently"
a="$(sha256sum "$HOME/.claude/settings.json" | cut -d' ' -f1)"
bash "$SETUP" --quiet --yes >/dev/null 2>&1
b="$(sha256sum "$HOME/.claude/settings.json" | cut -d' ' -f1)"
assert_eq "$a" "$b" "re-run leaves marked base home byte-identical"

it "a marked base home is maintained without the opt-in (missing registration is restored)"
rm -f "$HOME/.claude/.mcp.json"
bash "$SETUP" --quiet --yes >/dev/null 2>&1
assert_jq "$HOME/.claude/.mcp.json" '.mcpServers.jev.command' python3 "marker alone keeps ~/.claude in scope"

it "--uninstall removes our wiring from the base homes even without opt-in"
bash "$SETUP" --uninstall --quiet --yes; rc=$?
assert_eq 0 "$rc" "uninstall exits 0"
assert_jq "$HOME/.claude/settings.json" \
  '[(.hooks.PreToolUse // [])[] | select(.matcher=="Bash|Agent|Task")] | length' 0 "claude base hook removed"
assert_jq "$HOME/.claude/settings.json" '.model' opus "claude pre-existing key survives"
if grep -qF 'cma-jev:hooks BEGIN' "$HOME/.kimi-code/config.toml"; then _ok=1; else _ok=0; fi
assert_eq 0 "$_ok" "kimi base hooks block removed"
assert_file_contains "$HOME/.kimi-code/config.toml" 'default_model = "base"' "kimi content survives uninstall"

it "--uninstall reaches a base home that has only a registration (no hook marker)"
mkdir -p "$HOME/.kimi-code"
echo '{"mcpServers":{"jev":{"command":"python3","args":["x"]},"other":{"command":"y"}}}' > "$HOME/.kimi-code/mcp.json"
bash "$SETUP" --uninstall --quiet --yes >/dev/null 2>&1
assert_jq "$HOME/.kimi-code/mcp.json" '[.mcpServers.jev // empty] | length' 0 "kimi base mcp registration removed"
assert_jq "$HOME/.kimi-code/mcp.json" '.mcpServers.other.command' y "other mcp server kept"

it "env JEV_WIRE_AGENT_HOMES: only the literal 1 enables"
JEV_WIRE_AGENT_HOMES=yes bash "$SETUP" --quiet --yes >/dev/null 2>&1
assert_jq "$HOME/.claude/settings.json" '[(.hooks.PreToolUse // [])[]] | length' 0 "JEV_WIRE_AGENT_HOMES=yes does not enable"
JEV_WIRE_AGENT_HOMES=1 bash "$SETUP" --quiet --yes >/dev/null 2>&1
assert_jq "$HOME/.claude/settings.json" \
  '[.hooks.PreToolUse[] | select(.matcher=="Bash|Agent|Task")] | length' 1 "JEV_WIRE_AGENT_HOMES=1 wires ~/.claude"

it "a home reachable under two names is processed once (dedupe by physical path)"
ln -s "$HOME/.pi" "$HOME/.pi-linked"
: > "$HOME/pi-calls.log"
bash "$SETUP" --quiet --yes --agents pi --base-homes >/dev/null 2>&1
assert_eq 1 "$(_calls)" "pi install ran once for ~/.pi + its symlink alias"

it "JEV_GATE=off is respected by the gate"
out="$(printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | JEV_GATE=off JEV_MODE=enforce JEV_BASE_URL=http://127.0.0.1:9 bash "$SCRIPTS_DIR/jev-gate.sh" >/dev/null 2>&1; echo $?)"
assert_eq 0 "$out" "JEV_GATE=off allows (rc 0)"
summary
