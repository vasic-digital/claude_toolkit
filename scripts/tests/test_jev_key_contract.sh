#!/usr/bin/env bash
# test_jev_key_contract.sh - the LLMCTL_API_KEY FORMAT contract is applied in lock-step by every Jev consumer that resolves the bearer:
# jev-gate.sh (own suite: test_jev_gate_placeholder_key.sh), scripts/jev_mcp.py and scripts/opencode-jev-plugin.js (this suite).
# llmctl's contract: the whole value matches [A-Za-z0-9_-]{32,512} (single line). A shell profile may export a 1-char placeholder;
# sending it as the bearer only earns a 401 (fail-open) and hides the real key further down the chain, so a malformed LLMCTL_API_KEY
# counts as ABSENT at EVERY source (env, keys file, key files) and the next source is consulted. Other key variables are NOT
# format-checked (their contract is not ours). Test key values are fabricated.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
set +e
SC_UNDER_TEST="${SCRIPTS_UNDER_TEST:-$SCRIPTS_DIR}"
GOOD="Zk3_goodkey-0123456789abcdefghijklmnopqrstuv"      # 43 chars
GOOD2="Ke7_keysfile-0123456789abcdefghijklmnopqrstuv"
OTHER="Env_wellformed-0123456789abcdefghijklmnopqrstu"
BIG512="$(head -c 512 /dev/zero | tr '\0' 'a')"
mkdir -p "$HOME/plughome"
printf 'LLMCTL_API_KEY=%s\n' "$GOOD" > "$HOME/llmctl.env"; chmod 600 "$HOME/llmctl.env"
printf 'SHORT_VAR=tiny\n' > "$HOME/other.env"; chmod 600 "$HOME/other.env"

# py <env-assignments...> -> the bearer jev_mcp would use
py() {
  env -i HOME="$HOME" PATH="$PATH" JEV_KEY_VAR=LLMCTL_API_KEY CMA_KEYS_FILE="$HOME/no-such-keys.sh" CMA_JEV_KEY_FILES="$HOME/llmctl.env" JEV_CONFIG_DIR=/nonexistent/jev "$@" \
    python3 -I -c '
import sys
sys.path.insert(0, sys.argv[1])
import jev_mcp
sys.stdout.write(jev_mcp._api_key())' "$SC_UNDER_TEST" 2>/dev/null
}
# plug <dummy-expected> <env-assignments...> -> "yes" when the bearer carried the expected key, "none" when no request, "no" else
plug() {
  local want="$1"; shift
  local R; R="$(env -i HOME="$HOME/plughome" PATH="$PATH" JEV_TEST_SCRATCH_HOME="$HOME/plughome" JEV_TEST_DUMMY="$want" JEV_STATE_DIR="$HOME/plugstate" \
    JEV_BASE_URL=https://127.0.0.1:9 JEV_KEY_VAR=LLMCTL_API_KEY CMA_KEYS_FILE="$HOME/no-such-keys.sh" CMA_JEV_KEY_FILES="$HOME/llmctl.env" JEV_CONFIG_DIR=/nonexistent/jev "$@" \
    node "$TESTS_DIR/jev_plugin_origin_test.mjs" 2>&1 | tail -n1)"
  if [ "$(jq '.calls|length' <<<"$R" 2>/dev/null)" = "0" ]; then echo none; else jq -r 'if .calls[0].auth_is_dummy then "yes" else "no" end' <<<"$R" 2>/dev/null || echo ERR; fi
}
HAVE_NODE=1; command -v node >/dev/null 2>&1 || HAVE_NODE=0
check() { # check <label> <py expected key> <plugin expected (key|none)> <env...>
  local label="$1" pyexp="$2" plexp="$3"; shift 3
  assert_eq "$pyexp" "$(py "$@")" "python: $label"
  if (( HAVE_NODE )); then
    if [ "$plexp" = none ]; then assert_eq none "$(plug "$GOOD" "$@")" "plugin: $label (no request)"
    else assert_eq yes "$(plug "$plexp" "$@")" "plugin: $label"; fi
  fi
}
(( HAVE_NODE )) || _pass "node not installed - JS plugin scenarios SKIPPED (honest skip)"

it "1-char placeholder env value is ignored; the key-file key is the bearer"
check "placeholder env" "$GOOD" "$GOOD" LLMCTL_API_KEY=x
it "short non-placeholder garbage is also ignored"
check "short env" "$GOOD" "$GOOD" LLMCTL_API_KEY=short-1234
it "a well-formed env value still wins over the key file"
check "well-formed env wins" "$OTHER" "$OTHER" LLMCTL_API_KEY="$OTHER"
it "multi-line env value is rejected (no header injection)"
check "multi-line env" "$GOOD" "$GOOD" LLMCTL_API_KEY="$(printf 'x\n%s' "$GOOD")"
it "512 chars accepted, 513 rejected"
check "512 accepted" "$BIG512" "$BIG512" LLMCTL_API_KEY="$BIG512"
check "513 rejected" "$GOOD" "$GOOD" LLMCTL_API_KEY="${BIG512}a"
it "charset: a value with a space or '.' is rejected"
check "space in value" "$GOOD" "$GOOD" LLMCTL_API_KEY="${GOOD:0:20} ${GOOD:21}"
check "dot in value" "$GOOD" "$GOOD" LLMCTL_API_KEY="${GOOD:0:20}.${GOOD:21}"

it "a placeholder in the keys file (~/api_keys.sh) is ignored; the key-file key is the bearer"
printf 'export LLMCTL_API_KEY=x\n' > "$HOME/api_keys.sh"
check "placeholder in keys file" "$GOOD" "$GOOD" CMA_KEYS_FILE="$HOME/api_keys.sh"
it "env placeholder + valid key in the keys file: the keys file is consulted"
printf 'export LLMCTL_API_KEY=%s\n' "$GOOD2" > "$HOME/api_keys.sh"
check "keys file after env placeholder" "$GOOD2" "$GOOD2" LLMCTL_API_KEY=x CMA_KEYS_FILE="$HOME/api_keys.sh" CMA_JEV_KEY_FILES=/nonexistent
it "precedence env > keys file: a valid env value wins over a valid keys-file value"
check "env beats keys file" "$OTHER" "$OTHER" LLMCTL_API_KEY="$OTHER" CMA_KEYS_FILE="$HOME/api_keys.sh"

it "a malformed value at EVERY source and no good key anywhere: no malformed bearer is ever sent"
printf 'LLMCTL_API_KEY=y\n' > "$HOME/bad.env"; chmod 600 "$HOME/bad.env"
printf 'export LLMCTL_API_KEY=x\n' > "$HOME/api_keys.sh"
assert_eq local "$(py LLMCTL_API_KEY=x CMA_KEYS_FILE="$HOME/api_keys.sh" CMA_JEV_KEY_FILES="$HOME/bad.env")" "python: keyless placeholder 'local', not 'x'/'y'"
(( HAVE_NODE )) && assert_eq none "$(plug "$GOOD" LLMCTL_API_KEY=x CMA_KEYS_FILE="$HOME/api_keys.sh" CMA_JEV_KEY_FILES="$HOME/bad.env")" "plugin: no request (no_key), not a placeholder bearer"

it "OTHER key variables are NOT format-checked (short values still used)"
assert_eq tiny "$(py JEV_KEY_VAR=SHORT_VAR SHORT_VAR=tiny)" "python: SHORT_VAR=tiny used"
(( HAVE_NODE )) && assert_eq yes "$(plug tiny JEV_KEY_VAR=SHORT_VAR SHORT_VAR=tiny)" "plugin: SHORT_VAR=tiny used"
summary
