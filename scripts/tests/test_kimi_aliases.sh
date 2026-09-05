#!/usr/bin/env bash
# test_kimi_aliases.sh — hermetic Tier-A coverage for the kimi-<id> twin aliases
# (v1.27.0, Unit 3): per-provider `kimi-<id>` twin emission + ~/.kimi-prov-<id>/
# config.toml on a plain sync, the --no-kimi-aliases opt-out, the kc-* exclusion
# (no kimi twin for Claude-over-Kimi ids), and the twin's lifecycle under
# `claude-providers remove <id>`. No network, no real keys, no real ~/.claude.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e

# --- hermeticity: the sandbox does NOT scrub the inherited environment, so the
# HOST's exported provider keys (CHUTES_API_KEY, ApiKey_Opencode_Zen, …) would
# reach the subprocess detectors and make every pinned multi-alias detector fire
# with REAL credentials — live network + real keys in test artifacts. The pinned
# detectors each gate on a -f probes pins-file (CMA_*_PINS_FILE, env-overridable
# exactly so hermetic tests can point them at an absent path); pointing all of
# them at a nonexistent sandbox path yields `[]` from every local detector.
for _pin in HELIXAGENT HELIXLLM HELIXLLM_NATIVE OPENCODE_ZEN OPENCODE_GO CHUTES HYPER; do
  export "CMA_${_pin}_PINS_FILE=$HOME/.none-${_pin}-pins.json"
done
unset _pin
# Single-alias path only: the multi-sync leg runs live model_verify.py per
# model against real endpoints, which is neither hermetic nor fast.
export CMA_SYNC_MULTI=0
# Stub the two binaries that could reach a REAL backend/cli: kimi (the OAuth
# detector gate is `command -v kimi`; a failing stub keeps it at []) and curl
# (blocks any stray probe/refresh). Real python3/jq/rsync stay on PATH.
FAKEBIN="$HOME/fakebin"; mkdir -p "$FAKEBIN"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/kimi"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/curl"
chmod +x "$FAKEBIN/kimi" "$FAKEBIN/curl"
PATH="$FAKEBIN:$PATH"

PROVIDERS_SH="$SCRIPTS_DIR/claude-providers.sh"
PDIR="$(cma_providers_dir)"
mkdir -p "$PDIR"
CACHE="$PDIR/models.dev.cache.json"

# Offline-sync requirement (ensure_catalog): a valid models.dev cache must exist.
# acme has an Anthropic-native base (/anthropic), beta an OpenAI base (/v1), and
# kimi-for-coding is the models.dev UPSTREAM id (env KIMI_API_KEY) that the
# legacy-renames map turns into the kc-for-coding EMITTED id — which must NEVER
# receive a kimi-kc-for-coding twin.
cat > "$CACHE" <<'JSON'
{
  "acme":   {"env":["ACME_API_KEY"],"api":"https://api.acme.com/anthropic","npm":"@ai-sdk/anthropic",
             "models":{"b":{"id":"acme-big","reasoning":true,"release_date":"2025-05-01","limit":{"context":200000},"cost":{"input":3,"output":15},"tool_call":true},
                       "s":{"id":"acme-small","reasoning":false,"release_date":"2024-01-01","limit":{"context":32000},"cost":{"input":0.1,"output":0.4},"tool_call":true}}},
  "beta":   {"env":["BETA_API_KEY"],"api":"https://api.beta.ai/v1","npm":"@ai-sdk/openai-compatible",
             "models":{"f":{"id":"beta-x","reasoning":false,"release_date":"2025-06-01","limit":{"context":128000},"cost":{"input":1,"output":5},"tool_call":true}}},
  "kimi-for-coding":{"env":["KIMI_API_KEY"],"api":"https://api.kimi.com/coding/v1","npm":"@ai-sdk/openai-compatible",
             "models":{"k":{"id":"kimi-for-coding","reasoning":true,"release_date":"2025-08-01","limit":{"context":262144},"cost":{"input":0,"output":0},"tool_call":true}}}
}
JSON

# Keys file. Values are dummies; only the NAMES matter. The toolkit's install
# static data must never be rewritten inside a test HOME, and cmd_migrate_names
# + resolve_records read it through the env-overridable knobs — export sandbox
# copies of key-aliases/overrides/legacy-renames so the subprocess uses them.
KEYS="$HOME/api_keys.sh"
cat > "$KEYS" <<'SH'
export ACME_API_KEY="dummy-acme"
export BETA_API_KEY="dummy-beta"
export KIMI_API_KEY="dummy-kimi"
SH
keyaliases="$HOME/key-aliases.json"
overrides="$HOME/overrides.json"
legacy="$HOME/legacy-renames.json"
echo '{}' > "$keyaliases"
echo '{}' > "$overrides"
cat > "$legacy" <<'JSON'
{"kimi-for-coding":"kc-for-coding"}
JSON
export CMA_PROVIDERS_KEY_ALIASES="$keyaliases"
export CMA_PROVIDERS_OVERRIDES="$overrides"
export CMA_PROVIDERS_LEGACY_RENAMES="$legacy"

# The wrapper is invoked as a SUBPROCESS exactly like test_providers.sh, so the
# twin/config emission is tested through the real dispatch path rather than by
# calling functions ad hoc. --no-verify + --offline keep everything offline.

# ===========================================================================
# Section 1 — --no-kimi-aliases: base aliases emitted, NO twins, NO config
# ===========================================================================
it "sync --no-kimi-aliases emits base aliases but no kimi twins or config"
bash "$PROVIDERS_SH" sync --offline --no-verify --keys-file "$KEYS" --no-kimi-aliases >/dev/null 2>&1
alias_rc=$?
assert_eq 0 "$alias_rc" "sync --no-kimi-aliases exits cleanly"
grep -q '^alias acme=' "$ALIAS_FILE"; assert_eq 0 $? "base acme alias present"
grep -q '^alias beta=' "$ALIAS_FILE"; assert_eq 0 $? "base beta alias present"
grep -q '^alias kc-for-coding=' "$ALIAS_FILE"; assert_eq 0 $? "kc-for-coding alias present"
grep -q '^alias kimi-acme=' "$ALIAS_FILE" && _t=1 || _t=0
assert_eq 0 "$_t" "no kimi-acme twin with --no-kimi-aliases"
[[ ! -d "$HOME/.kimi-prov-acme" ]]; assert_eq 0 $? "no kimi config dir for acme"
[[ ! -d "$HOME/.kimi-prov-beta" ]]; assert_eq 0 $? "no kimi config dir for beta"

# ===========================================================================
# Section 2 — plain sync: twins + config.toml for every non-kc-*/kimi-* id
# ===========================================================================
it "sync emits kimi-<id> twins and config.toml for every real provider"
bash "$PROVIDERS_SH" sync --offline --no-verify --keys-file "$KEYS" >/dev/null 2>&1
sync_rc=$?
assert_eq 0 "$sync_rc" "plain sync exits cleanly"
grep -q '^alias kimi-acme="cma_run_kimi_provider acme"$' "$ALIAS_FILE"; assert_eq 0 $? "kimi-acme twin -> cma_run_kimi_provider acme"
grep -q '^alias kimi-beta="cma_run_kimi_provider beta"$' "$ALIAS_FILE"; assert_eq 0 $? "kimi-beta twin -> cma_run_kimi_provider beta"
grep -q '^alias kimi-kc-for-coding=' "$ALIAS_FILE" && _t=1 || _t=0
assert_eq 0 "$_t" "kc-for-coding gets NO kimi twin (Claude-over-Kimi namespace)"
grep -q 'kimi-for-coding' "$ALIAS_FILE" && _t=1 || _t=0
assert_eq 0 "$_t" "legacy kimi-for-coding id leaves no alias residue"

it "config.toml for an Anthropic-native base (acme) is correct and private"
ac="$HOME/.kimi-prov-acme/config.toml"
assert_file "$ac" "acme config.toml rendered"
grep -q '^\[providers."acme"\]$' "$ac"; assert_eq 0 $? "provider block acme"
grep -q '^type = "anthropic"$' "$ac"; assert_eq 0 $? "anthropic type (base carries /anthropic)"
grep -q '^base_url = "https://api.acme.com/anthropic"$' "$ac"; assert_eq 0 $? "base_url preserved"
grep -q '^api_key = "dummy-acme"$' "$ac"; assert_eq 0 $? "api_key is the RESOLVED VALUE, not a keyvar name"
grep -q '^max_context_size = 200000$' "$ac"; assert_eq 0 $? "context carved from catalog (200000)"
grep -q '^capabilities = \[ "tool_use", "thinking" \]$' "$ac"; assert_eq 0 $? "tool_use + thinking capabilities"
grep -q '^default_model = "acme/acme-big"$' "$ac"; assert_eq 0 $? "default_model names provider/model"
assert_eq "600" "$(stat -c %a "$ac")" "config.toml is chmod 600"

it "config.toml for an OpenAI base (beta) carries type=openai"
bt="$HOME/.kimi-prov-beta/config.toml"
assert_file "$bt" "beta config.toml rendered"
grep -q '^type = "openai"$' "$bt"; assert_eq 0 $? "openai type (base is /v1)"
grep -q '^api_key = "dummy-beta"$' "$bt"; assert_eq 0 $? "beta api_key resolved value"

it "no kimi config dir for the kc-* id"
[[ ! -d "$HOME/.kimi-prov-kc-for-coding" ]]; assert_eq 0 $? "kc-for-coding renders no config (no kimi twin)"

# ===========================================================================
# Section 3 — remove <id> tears down the twin alias + both config dirs
# ===========================================================================
it "claude-providers remove acme backs up the twin + kimi config dir"
grep -q '^alias kimi-acme=' "$ALIAS_FILE"; assert_eq 0 $? "precondition: twin alias exists"
bash "$PROVIDERS_SH" remove acme >/dev/null 2>&1
grep -q '^alias kimi-acme=' "$ALIAS_FILE" && _t=1 || _t=0
assert_eq 0 "$_t" "kimi-acme twin removed with the provider"
ls -d "$HOME"/.claude-prov-acme.preunify.* >/dev/null 2>&1; assert_eq 0 $? "claude config dir backed up (preunify)"
ls -d "$HOME"/.kimi-prov-acme.preunify.* >/dev/null 2>&1; assert_eq 0 $? "kimi config dir backed up (preunify)"
[[ ! -d "$HOME/.kimi-prov-acme" ]]; assert_eq 0 $? "kimi config dir no longer live"

summary