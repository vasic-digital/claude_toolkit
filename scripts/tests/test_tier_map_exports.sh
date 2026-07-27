#!/usr/bin/env bash
# test_tier_map_exports.sh — BOTH transports must export the model, the tier
# maps, and the real context size (the 2.1.220 compact-loop fix).
#
# Live defect (2026-07-26): the tier maps (ANTHROPIC_DEFAULT_OPUS/SONNET/HAIKU/
# FABLE_MODEL), ANTHROPIC_MODEL and ANTHROPIC_SMALL_FAST_MODEL were exported
# only in the NATIVE branch of cma_run_provider. Router-transport aliases
# (most providers) launched with none of them, so Claude Code 2.1.220 resolved
# the tiers client-side — the fast/compact tier to "Fable 5", which the binary
# itself reports as CURRENTLY UNAVAILABLE. Auto-compaction runs on the fast
# tier, so the compact call failed client-side on every attempt: the context
# was never freed, compaction retried forever, and the alias was unusable
# (zero /v1/messages reaching the gateway — a client-side loop).
# And exporting ANTHROPIC_MODEL alone made it WORSE in a second way: an id
# Claude's table does not know falls back to a tiny default context, so the
# system+tool prefix alone overflows — "Prompt is too long" on a 20-char
# prompt (reproduced live). CLAUDE_CODE_MAX_CONTEXT_TOKENS carries the real
# window and closes that half.
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
cma_provider_write_env testrtr TESTKEY router "http://127.0.0.1:9/v1" testrtr-big testrtr-fast \
  "$SANDBOX_HOME/.claude-prov-testrtr" 262144 8192 testrtr
cma_status_write testrtr verified testrtr-big ""
export TESTKEY="dummy-key"
ALIAS_FILE="$SANDBOX_HOME/.local/share/claude-multi-account/aliases.sh"
mkdir -p "$(dirname "$ALIAS_FILE")" "$SANDBOX_HOME/.local/bin"
CMA_RC_FILES=("$SANDBOX_HOME/.unused-rc")
cma_ensure_alias_file >/dev/null 2>&1

CCRCALLS="$SANDBOX_HOME/ccr.calls"
sandbox_stub "$SANDBOX_HOME/.local/bin/ccr" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
  --help|-h|help)
    printf 'Usage:\n  ccr start [...]\n  ccr restart [--host <host>] [--port <port>] [--gateway|--no-gateway]\n'; exit 0 ;;
  restart) printf 'restart %s\n' "\$*" >> "$CCRCALLS"; exit 0 ;;
  code|default-claude-code)
    # Capture the environment the agent would inherit.
    env | grep -E '^(ANTHROPIC_MODEL|ANTHROPIC_SMALL_FAST_MODEL|ANTHROPIC_DEFAULT_(OPUS|SONNET|HAIKU|FABLE)_MODEL|CLAUDE_CODE_MAX_CONTEXT_TOKENS)=' | sort > "$SANDBOX_HOME/agent.env"
    exit 0 ;;
  *) exit 0 ;;
esac
STUB
# shellcheck disable=SC1090
source "$ALIAS_FILE"
assert_fn_from cma_run_provider "$ALIAS_FILE"

it "router transport: agent env carries model, all four tier maps, and the real context size"
cma_run_provider testrtr >/dev/null 2>&1; rc=$?
assert_eq "0" "$rc" "router launch rc"
assert_file_contains "$SANDBOX_HOME/agent.env" "ANTHROPIC_MODEL=testrtr-big"            "ANTHROPIC_MODEL"
assert_file_contains "$SANDBOX_HOME/agent.env" "ANTHROPIC_SMALL_FAST_MODEL=testrtr-fast" "SMALL_FAST"
assert_file_contains "$SANDBOX_HOME/agent.env" "ANTHROPIC_DEFAULT_OPUS_MODEL=testrtr-big"   "opus map"
assert_file_contains "$SANDBOX_HOME/agent.env" "ANTHROPIC_DEFAULT_SONNET_MODEL=testrtr-big" "sonnet map"
assert_file_contains "$SANDBOX_HOME/agent.env" "ANTHROPIC_DEFAULT_HAIKU_MODEL=testrtr-fast" "haiku map -> fast model"
assert_file_contains "$SANDBOX_HOME/agent.env" "ANTHROPIC_DEFAULT_FABLE_MODEL=testrtr-big"  "fable map (the 2.1.220 compact-tier fix)"
assert_file_contains "$SANDBOX_HOME/agent.env" "CLAUDE_CODE_MAX_CONTEXT_TOKENS=262144"      "real context size exported"

it "cma_run clears CLAUDE_CODE_MAX_CONTEXT_TOKENS for native launches (isolation)"
assert_file_contains "$ALIAS_FILE" "unset CLAUDE_CODE_MAX_OUTPUT_TOKENS CLAUDE_CODE_AUTO_COMPACT_WINDOW CLAUDE_CODE_MAX_CONTEXT_TOKENS" "isolation unset covers the new var"

it "the exports are hoisted BEFORE the transport branch (both transports)"
# The shared export block must appear before the router/native branch point in
# the emitted body, or one transport again goes without the maps.
body="$(awk '/^cma_run_provider\(\) \{/,/^CMA_PROV_BODY_EOF$/' "$ALIAS_FILE")"
exp_line="$(printf '%s\n' "$body" | grep -n 'export ANTHROPIC_DEFAULT_FABLE_MODEL' | head -1 | cut -d: -f1)"
branch_line="$(printf '%s\n' "$body" | grep -n 'if \[\[ "${CMA_PROVIDER_TRANSPORT:-native}" == "router" \]\]' | head -1 | cut -d: -f1)"
[[ -n "$exp_line" && -n "$branch_line" && "$exp_line" -lt "$branch_line" ]] \
  && _pass "tier maps export at line $exp_line, branch at $branch_line" \
  || _fail "tier maps are not hoisted above the transport branch" "exp=$exp_line branch=$branch_line"

summary
