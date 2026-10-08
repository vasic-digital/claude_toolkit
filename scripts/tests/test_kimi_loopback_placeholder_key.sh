#!/usr/bin/env bash
# test_kimi_loopback_placeholder_key.sh — _cma_kimi_render_config must write the
# placeholder `api_key = "local"` for a LOOPBACK base with an explicit port when
# no real key resolves (kimi 0.42.0 treats an empty api_key as missing:
# "provider llmctl-small has no credential configured"; llmctl docs say use the
# dummy key "local"). A REMOTE base with no key must NOT get the placeholder,
# and a REAL key must never be replaced by it. Hermetic: temp HOME, no network.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${CMA_TEST_SCRIPTS_DIR:-$(cd "$TESTS_DIR/.." && pwd)}"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
# shellcheck source=../claude-providers.sh
source "$SCRIPTS_DIR/claude-providers.sh"
set +e
export CMA_KEYS_FILE="$HOME/no_such_keys.sh"
unset LLMCTL_API_KEY REMOTE_TEST_KEY REALKEY_TEST_KEY

_apikey() { grep -E '^api_key = ' "$HOME/.kimi-prov-$1/config.toml" | head -n1 | sed -E 's/^api_key = "(.*)"$/\1/'; }

it "loopback base + port, no key -> api_key = \"local\""
_cma_kimi_render_config "llmctl-small" "LLMCTL_API_KEY" "router" "http://127.0.0.1:8085/v1" "m.gguf" "8192" 2>/dev/null
assert_eq "local" "$(_apikey llmctl-small)" "loopback keyless gets placeholder"

it "localhost base + port, no key -> placeholder"
_cma_kimi_render_config "lh-test" "LLMCTL_API_KEY" "router" "http://localhost:8085/v1" "m.gguf" "8192" 2>/dev/null
assert_eq "local" "$(_apikey lh-test)" "localhost keyless gets placeholder"

it "REMOTE base, no key -> NO placeholder (stays empty, warns)"
_cma_kimi_render_config "remote-test" "REMOTE_TEST_KEY" "router" "https://api.example.invalid/v1" "m" "8192" 2>/dev/null
assert_eq "" "$(_apikey remote-test)" "remote keyless must not get placeholder"

it "loopback base WITHOUT explicit port, no key -> NO placeholder"
_cma_kimi_render_config "noport-test" "LLMCTL_API_KEY" "router" "http://127.0.0.1/v1" "m" "8192" 2>/dev/null
assert_eq "" "$(_apikey noport-test)" "portless loopback must not get placeholder"

it "loopback base + REAL key -> real key kept, not replaced by placeholder"
printf 'export LLMCTL_API_KEY=%s\n' "sk-not-a-real-secret" > "$CMA_KEYS_FILE"
_cma_kimi_render_config "real-test" "LLMCTL_API_KEY" "router" "http://127.0.0.1:8085/v1" "m" "8192" 2>/dev/null
assert_eq "sk-not-a-real-secret" "$(_apikey real-test)" "real key preserved"
rm -f "$CMA_KEYS_FILE"; unset LLMCTL_API_KEY

it "non-llmctl loopback provider (helixcoder-style) with declared-but-empty key -> NO placeholder, still warns"
_w="$(_cma_kimi_render_config "helixcoder" "HELIXCODER_API_KEY" "router" "http://127.0.0.1:18434/v1" "m" "8192" 2>&1 >/dev/null)"
assert_eq "" "$(_apikey helixcoder)" "non-llmctl keyvar must not get placeholder"
_hasw=0; case "$_w" in *"key empty"*) _hasw=1 ;; esac
assert_eq "1" "$_hasw" "warning preserved for non-llmctl loopback"

it "IPv6 non-loopback literal [1::]:8085 -> NO placeholder"
_cma_kimi_render_config "v6-test" "LLMCTL_API_KEY" "router" "http://[1::]:8085/v1" "m" "8192" 2>/dev/null
assert_eq "" "$(_apikey v6-test)" "[1::] is remote"

it "substring host localhost.evil.com:8085 -> NO placeholder"
_cma_kimi_render_config "evil-test" "LLMCTL_API_KEY" "router" "http://localhost.evil.com:8085/v1" "m" "8192" 2>/dev/null
assert_eq "" "$(_apikey evil-test)" "lookalike host is remote"

summary
