#!/usr/bin/env bash
# test_provider_trim_layer4_skip.sh — CMA_PROVIDER_TRIM='bare' providers
# intentionally skip the layer-4 superpowers engagement check.
#
# The superpowers TUI challenge requires the skill/plugin surface to load,
# which --bare deliberately disables for narrow-context local models. The
# verifier must SKIP such providers honestly (exit 0) rather than FAIL them.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e

pdir="$(cma_providers_dir)"; mkdir -p "$pdir"

# A router provider with CMA_PROVIDER_TRIM=bare
cma_provider_write_env trimrtr TESTKEY router "http://127.0.0.1:9/v1" testmodel testmodel \
  "$SANDBOX_HOME/.claude-prov-trimrtr" 200000 8192 trimrtr
cma_status_write trimrtr verified testmodel ""
printf "CMA_PROVIDER_TRIM='bare'\n" >> "$pdir/trimrtr.env"

# An untrimmed provider for contrast
cma_provider_write_env plainrtr TESTKEY router "http://127.0.0.1:9/v1" testmodel testmodel \
  "$SANDBOX_HOME/.claude-prov-plainrtr" 200000 8192 plainrtr
cma_status_write plainrtr verified testmodel ""

# claude binary: the verifier requires a real-ish name
sandbox_stub "$SANDBOX_HOME/.local/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo '{"type":"result","result":"Skills evolve. Read current version.","is_error":false}'
STUB

# Provide a fake superpowers skill so the verifier can pose its challenge
skill_dir="$SANDBOX_HOME/.claude-shared/plugins/cache/claude-plugins-official/superpowers/skills/using-superpowers"
mkdir -p "$skill_dir"
cat > "$skill_dir/SKILL.md" <<'EOF'
# Using Superpowers

## Red Flags

| Thought | Reality |
|---------|---------|
| I remember this skill | Skills evolve. Read current version. |
EOF

export PATH="$SANDBOX_HOME/.local/bin:$PATH"
export CLAUDE_BIN="$SANDBOX_HOME/.local/bin/claude"

# Provide the key the verifier checks for
cat > "$SANDBOX_HOME/api_keys.sh" <<'EOF'
export TESTKEY="dummy-key-present"
EOF

ALIAS_FILE="$SANDBOX_HOME/.local/share/claude-multi-account/aliases.sh"
mkdir -p "$(dirname "$ALIAS_FILE")"
: > "$ALIAS_FILE"

stui_out="$SANDBOX_HOME/trim-stui.txt"

bash "$SCRIPTS_DIR/verify_superpowers_tui.sh" --alias trimrtr --out "$stui_out" >/dev/null 2>&1
rc=$?

it "bare provider skips layer-4 verification (exit 0)"
assert_eq 0 "$rc" "trimrtr verifier rc"

it "bare provider evidence ends with a SKIP marker"
last="$(tail -n 1 "$stui_out" 2>/dev/null || true)"
case "$last" in
  *"SKIP"*"CMA_PROVIDER_TRIM=bare"*) ok=0 ;;
  *) ok=1 ;;
esac
assert_eq 0 "$ok" "last line is SKIP for bare provider: $last"

plain_out="$SANDBOX_HOME/plain-stui.txt"
# The untrimmed provider will fail because our stub claude returns the correct
# answer, so the challenge passes? Actually the stub returns the exact answer,
# so it should PASS. Let's verify it does not SKIP.
bash "$SCRIPTS_DIR/verify_superpowers_tui.sh" --alias plainrtr --out "$plain_out" >/dev/null 2>&1
rc=$?

it "untrimmed provider does NOT skip layer-4 (runs the challenge)"
last="$(tail -n 1 "$plain_out" 2>/dev/null || true)"
case "$last" in
  *"SKIP"*) ok=1 ;;
  *) ok=0 ;;
esac
assert_eq 0 "$ok" "plainrtr should not SKIP: $last"

summary
