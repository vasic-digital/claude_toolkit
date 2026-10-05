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
  "gamma":  {"env":["GAMMA_API_KEY"],"api":"https://api.gamma.ai/v1","npm":"@ai-sdk/openai-compatible",
             "models":{"g":{"id":"gamma-x","reasoning":false,"release_date":"2025-06-01","limit":{"context":128000},"cost":{"input":1,"output":5},"tool_call":true}}},
  "sarv":   {"env":["SARV_API_KEY"],"api":"https://api.sarv.ai/v1","npm":"@ai-sdk/openai-compatible",
             "models":{"s":{"id":"sarv-105b","reasoning":true,"release_date":"2025-06-01","limit":{"context":131072,"output":131072},"cost":{"input":1,"output":5},"tool_call":true}}},
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
export GAMMA_API_KEY="dummy-gamma"
export SARV_API_KEY="dummy-sarv"
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

# Stub verifier (CMA_PROVIDERS_VERIFY is the documented override knob): prints
# the verdict named for --provider in $VERDICTS ("<id> <verdict>" lines),
# default `verified`. --offline (always passed below) skips the semantic layer,
# so this stub's verdict IS the status the sync records. No network, no keys.
VERDICTS="$HOME/verdicts.txt"; : > "$VERDICTS"
VERIFY_STUB="$HOME/verify-stub.sh"
cat > "$VERIFY_STUB" <<'SH'
#!/usr/bin/env bash
p=""
while [ $# -gt 0 ]; do case "$1" in --provider) p="$2"; shift 2 ;; *) shift ;; esac; done
v="$(awk -v p="$p" '$1==p {print $2}' "$VERDICTS" 2>/dev/null)"
echo "${v:-verified}"
SH
chmod +x "$VERIFY_STUB"
export VERDICTS
set_verdicts() { printf '%s\n' "$@" > "$VERDICTS"; }
vsync() { CMA_PROVIDERS_VERIFY="$VERIFY_STUB" bash "$PROVIDERS_SH" sync --offline --keys-file "$KEYS" "$@" >/dev/null 2>&1; }

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
# ===========================================================================
# Section 1b — operator decision "Gate on verification": a kimi-<id> twin is
# emitted ONLY for a provider whose status record is `verified` (the same
# status.json record the Claude alias launch gate reads via cma_status_read).
# ===========================================================================
it "gate: a failed or unverified provider gets NO kimi-<id> twin after sync"
set_verdicts "beta unverified" "gamma failed"
vsync; assert_eq 0 $? "mixed-verdict sync exits cleanly"
assert_eq "unverified" "$(cma_status_read beta)" "precondition: beta recorded unverified"
assert_eq "failed" "$(cma_status_read gamma)" "precondition: gamma recorded failed"
grep -q '^alias kimi-beta=' "$ALIAS_FILE" && _t=1 || _t=0
assert_eq 0 "$_t" "no kimi-beta twin for an UNVERIFIED provider"
grep -q '^alias kimi-gamma=' "$ALIAS_FILE" && _t=1 || _t=0
assert_eq 0 "$_t" "no kimi-gamma twin for a FAILED provider"

it "gate: a verified provider gets its kimi-<id> twin after sync"
assert_eq "verified" "$(cma_status_read acme)" "precondition: acme recorded verified"
grep -q '^alias kimi-acme="cma_run_kimi_provider acme"$' "$ALIAS_FILE"; assert_eq 0 $? "kimi-acme twin emitted for the VERIFIED provider"

it "sync emits kimi-<id> twins and config.toml for every real provider"
set_verdicts
vsync
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
# Section 2b — reconcile: a twin that is no longer emitted (provider demoted
# from verified, or gone entirely) has its stale kimi-<id> line removed by
# sync, through cma_alias_commit; a second sync then changes nothing.
# ===========================================================================
it "reconcile: stale kimi-<id> lines for unverified/failed/removed providers are dropped; 2nd sync is a no-op"
grep -q '^alias kimi-beta=' "$ALIAS_FILE"; assert_eq 0 $? "precondition: kimi-beta twin exists (beta was verified)"
grep -q '^alias kimi-gamma=' "$ALIAS_FILE"; assert_eq 0 $? "precondition: kimi-gamma twin exists (gamma was verified)"
# A twin whose provider no longer exists at all (no key, no catalog entry, no
# status record) — the shape of the stale lines found in a real alias file.
cma_alias_commit "" 'alias kimi-ghost="cma_run_kimi_provider ghost"' keep
grep -q '^alias kimi-ghost=' "$ALIAS_FILE"; assert_eq 0 $? "precondition: stale kimi-ghost line seeded"
set_verdicts "beta unverified" "gamma failed"
vsync; assert_eq 0 $? "demoting sync exits cleanly"
grep -q '^alias kimi-beta=' "$ALIAS_FILE" && _t=1 || _t=0
assert_eq 0 "$_t" "stale kimi-beta line removed (beta now unverified)"
grep -q '^alias kimi-gamma=' "$ALIAS_FILE" && _t=1 || _t=0
assert_eq 0 "$_t" "stale kimi-gamma line removed (gamma now failed)"
grep -q '^alias kimi-ghost=' "$ALIAS_FILE" && _t=1 || _t=0
assert_eq 0 "$_t" "stale kimi-ghost line removed (provider gone)"
grep -q '^alias kimi-acme="cma_run_kimi_provider acme"$' "$ALIAS_FILE"; assert_eq 0 $? "verified kimi-acme twin kept"
grep -q '^alias beta=' "$ALIAS_FILE"; assert_eq 0 $? "base beta alias untouched by twin reconciliation"
ls "$ALIAS_FILE".rejected.* >/dev/null 2>&1 && _t=1 || _t=0
assert_eq 0 "$_t" "no rejected alias render (committer gate accepted every drop)"
_sum1="$(cksum < "$ALIAS_FILE")"
_ino1="$(ls -i "$ALIAS_FILE" | awk '{print $1}')"
vsync; assert_eq 0 $? "second sync exits cleanly"
assert_eq "$_sum1" "$(cksum < "$ALIAS_FILE")" "second sync leaves the alias file byte-identical"
assert_eq "$_ino1" "$(ls -i "$ALIAS_FILE" | awk '{print $1}')" "second sync performed no rename onto the alias file"
set_verdicts

# ===========================================================================
# Section 2c — reconciliation must never delete what it did not write, and
# must drop exactly the named twin (review of 7cc067a).
# ===========================================================================
it "reconcile: a USER-AUTHORED kimi-<id> line for an unverified/failed provider survives byte-identical"
cma_alias_commit "" 'alias kimi-beta="my own beta command"' keep
cma_alias_commit "" 'alias kimi-gamma="my own gamma command"' keep
grep -qxF 'alias kimi-beta="my own beta command"' "$ALIAS_FILE"; assert_eq 0 $? "precondition: user kimi-beta line seeded"
grep -qxF 'alias kimi-gamma="my own gamma command"' "$ALIAS_FILE"; assert_eq 0 $? "precondition: user kimi-gamma line seeded"
set_verdicts "beta unverified" "gamma failed"
vsync; assert_eq 0 $? "sync with user-authored twin-named lines exits cleanly"
grep -qxF 'alias kimi-beta="my own beta command"' "$ALIAS_FILE"; assert_eq 0 $? "user kimi-beta line survives byte-identical (beta unverified)"
grep -qxF 'alias kimi-gamma="my own gamma command"' "$ALIAS_FILE"; assert_eq 0 $? "user kimi-gamma line survives byte-identical (gamma failed)"
# Test-only cleanup so later sections start from the toolkit-managed state.
cma_alias_commit kimi-beta "" keep; cma_alias_commit kimi-gamma "" keep
set_verdicts

it "reconcile: a whitespace-variant USER line (alias<2 spaces>kimi-beta=) beside the canonical twin survives byte-identical"
# Hand-edited state (the operator's own edit, simulated as a test fixture in the
# sandbox): a two-space user definition of kimi-beta PLUS the canonical twin.
# The guard is exercised directly — any sync-path commit first runs the
# committer's last-wins dedupe, which collapses the two same-name lines before
# the twin gate is ever reached.
assert_eq "unverified" "$(cma_status_read beta)" "precondition: beta is unverified"
printf '%s\n' 'alias  kimi-beta="my own"' 'alias kimi-beta="cma_run_kimi_provider beta"' >> "$ALIAS_FILE"
grep -qxF 'alias  kimi-beta="my own"' "$ALIAS_FILE"; assert_eq 0 $? "precondition: two-space user kimi-beta line present"
_sum_ws="$(cksum < "$ALIAS_FILE")"
( source "$PROVIDERS_SH"; set +e; _cma_kimi_twin_alias beta ) >/dev/null 2>&1
grep -qxF 'alias  kimi-beta="my own"' "$ALIAS_FILE"; assert_eq 0 $? "two-space user kimi-beta line survives"
assert_eq "$_sum_ws" "$(cksum < "$ALIAS_FILE")" "alias file left byte-identical (name shared with a user line is untouched)"
cma_alias_commit kimi-beta "" keep

it "reconcile: a dotted id drops ONLY its own literal twin line (no regex over-match, no rejected render)"
cma_alias_commit "" 'alias kimi-a.b="cma_run_kimi_provider a.b"' keep
cma_alias_commit "" 'alias kimi-aXb="victim"' keep
grep -qxF 'alias kimi-a.b="cma_run_kimi_provider a.b"' "$ALIAS_FILE"; assert_eq 0 $? "precondition: stale kimi-a.b line seeded"
grep -qxF 'alias kimi-aXb="victim"' "$ALIAS_FILE"; assert_eq 0 $? "precondition: victim kimi-aXb line seeded"
vsync; assert_eq 0 $? "sync exits cleanly"
grep -qxF 'alias kimi-a.b="cma_run_kimi_provider a.b"' "$ALIAS_FILE" && _t=1 || _t=0
assert_eq 0 "$_t" "stale kimi-a.b twin line removed"
grep -qxF 'alias kimi-aXb="victim"' "$ALIAS_FILE"; assert_eq 0 $? "victim kimi-aXb line survives byte-identical"
ls "$ALIAS_FILE".rejected.* >/dev/null 2>&1 && _t=1 || _t=0
assert_eq 0 "$_t" "no .rejected.* alias render written"
cp "$ALIAS_FILE" "$HOME/alias.before-2nd"
vsync; assert_eq 0 $? "second sync exits cleanly"
cmp -s "$HOME/alias.before-2nd" "$ALIAS_FILE"; assert_eq 0 $? "second sync leaves the alias file identical (cmp)"
ls "$ALIAS_FILE".rejected.* >/dev/null 2>&1 && _t=1 || _t=0
assert_eq 0 "$_t" "still no .rejected.* after the second sync"
cma_alias_commit kimi-aXb "" keep

# ===========================================================================
# Section 2d — known-issue 36 (KIMI-LEG-config-missing): a kimi-<id> twin line
# must never exist without the ~/.kimi-prov-<id>/config.toml it launches
# through. Live finding: 8 twin lines with no config behind them; the live
# verifier failed each with "the twin was emitted but its config.toml was not
# rendered". Two producers: (a) a sync whose config render FAILED silently and
# still emitted the twin; (b) a config deleted later while the session-refresh
# path never removed the stale line.
# ===========================================================================
it "config-missing (36a): a sync whose config.toml render fails refuses the twin with a clear message"
set_verdicts
vsync
grep -q '^alias kimi-beta="cma_run_kimi_provider beta"$' "$ALIAS_FILE"; assert_eq 0 $? "precondition: verified beta has its twin"
# Make the render impossible: the per-alias config dir path is a regular file.
rm -rf "$HOME/.kimi-prov-beta"; : > "$HOME/.kimi-prov-beta"
_out36="$(CMA_PROVIDERS_VERIFY="$VERIFY_STUB" bash "$PROVIDERS_SH" sync --offline --keys-file "$KEYS" 2>&1)"
assert_eq 0 $? "sync with an unrenderable kimi config still exits cleanly"
grep -q '^alias kimi-beta=' "$ALIAS_FILE" && _t=1 || _t=0
assert_eq 0 "$_t" "NO kimi-beta twin when its config.toml could not be rendered"
grep -q '^alias beta=' "$ALIAS_FILE"; assert_eq 0 $? "base beta alias is unaffected"
grep -q "kimi-beta.*config.toml" <<<"$_out36"; assert_eq 0 $? "sync names the refused twin and its missing config.toml"
rm -f "$HOME/.kimi-prov-beta"
vsync
grep -q '^alias kimi-beta="cma_run_kimi_provider beta"$' "$ALIAS_FILE"; assert_eq 0 $? "twin returns once the config renders again"

it "config-missing (36b): --refresh-aliases drops a twin line whose config.toml was deleted"
assert_file "$HOME/.kimi-prov-beta/config.toml" "precondition: beta config exists"
rm -f "$HOME/.kimi-prov-beta/config.toml" "$PDIR/.refresh-aliases-fingerprint"
bash "$PROVIDERS_SH" list --refresh-aliases >/dev/null 2>&1
grep -q '^alias kimi-beta=' "$ALIAS_FILE" && _t=1 || _t=0
assert_eq 0 "$_t" "stale kimi-beta line removed when its config.toml is gone"
grep -q '^alias beta=' "$ALIAS_FILE"; assert_eq 0 $? "base beta alias still restored by refresh"
grep -q '^alias kimi-acme="cma_run_kimi_provider acme"$' "$ALIAS_FILE"; assert_eq 0 $? "kimi-acme twin (config present) untouched"
vsync
grep -q '^alias kimi-beta="cma_run_kimi_provider beta"$' "$ALIAS_FILE"; assert_eq 0 $? "sync re-renders the config and restores the twin"

# ===========================================================================
# Section 2e — known-issue 37 (KIMI-LEG-fireworks-twin): `kimi-fireworks-ai`
# existed while its base provider `fireworks-ai` (status failed, Claude alias
# overridden to a different name) had no Claude alias. Regression guard for the
# 7cc067a gate: the twin of a provider with no launchable base is dropped, and
# the twin of a verified provider exists only alongside its Claude base alias.
# ===========================================================================
it "fireworks-twin (37): a failed provider with an overridden alias name keeps no kimi-<id> twin"
echo '{"gamma":{"alias":"gm"}}' > "$overrides"
cma_alias_commit gamma "" keep 2>/dev/null
cma_alias_commit "" 'alias kimi-gamma="cma_run_kimi_provider gamma"' keep
grep -q '^alias kimi-gamma=' "$ALIAS_FILE"; assert_eq 0 $? "precondition: stale kimi-gamma twin seeded"
set_verdicts "gamma failed"
vsync; assert_eq 0 $? "sync exits cleanly"
grep -q '^alias kimi-gamma=' "$ALIAS_FILE" && _t=1 || _t=0
assert_eq 0 "$_t" "kimi-gamma twin dropped: its base provider is not launchable"
grep -qE '^alias [A-Za-z0-9._-]+="cma_run_provider gamma"$' "$ALIAS_FILE" && _t=1 || _t=0
assert_eq 0 "$_t" "precondition of the defect shape: no Claude alias launches gamma"

it "fireworks-twin (37): a verified provider's twin coexists with its Claude base alias"
set_verdicts
vsync; assert_eq 0 $? "sync exits cleanly"
grep -q '^alias gm="cma_run_provider gamma"$' "$ALIAS_FILE"; assert_eq 0 $? "Claude base alias gm -> gamma present"
grep -q '^alias kimi-gamma="cma_run_kimi_provider gamma"$' "$ALIAS_FILE"; assert_eq 0 $? "kimi-gamma twin present with its base"
echo '{}' > "$overrides"
cma_alias_commit gm "" keep 2>/dev/null
vsync

# ===========================================================================
# Section 2f — known-issue 38 (KIMI-LEG-sarvam): kimi-sarvam sent max_tokens
# 131072 (its whole context) and the backend refused it above its 128000
# output cap. The Kimi CLI uses `max_output_size` from the model alias as its
# hard completion cap and, absent it, falls back to max_context_size. The
# rendered config must carry the SAME derived output cap the Claude side
# exports (CMA_PROVIDER_MAX_OUTPUT), never the whole window.
# ===========================================================================
it "sarvam (38): config.toml carries max_output_size = the derived output cap, below the context"
sc="$HOME/.kimi-prov-sarv/config.toml"
assert_file "$sc" "sarv config.toml rendered"
_ctx38="$(sed -n 's/^max_context_size = \([0-9]*\)$/\1/p' "$sc")"
_out38="$(sed -n 's/^max_output_size = \([0-9]*\)$/\1/p' "$sc")"
_env38="$( ( set -a; . "$PDIR/sarv.env"; set +a; printf '%s' "${CMA_PROVIDER_MAX_OUTPUT:-}" ) )"
assert_eq "131072" "$_ctx38" "precondition: sarv context is the catalog 131072"
[[ -n "$_env38" ]]; assert_eq 0 $? "precondition: sync derived an output cap for sarv"
assert_eq "$_env38" "$_out38" "max_output_size equals the derived CMA_PROVIDER_MAX_OUTPUT"
[[ -n "$_out38" ]] && (( _out38 < _ctx38 && _out38 <= 128000 )); assert_eq 0 $? "max_output_size ($_out38) is below the context and the 128000 cap"

it "sarvam (38): unknown/oversized derived output never reaches the whole context"
( source "$PROVIDERS_SH"; set +e
  _cma_kimi_render_config t38a SARV_API_KEY router "https://x.invalid/v1" m "131072" ""
  _cma_kimi_render_config t38b SARV_API_KEY router "https://x.invalid/v1" m "131072" "131072" ) >/dev/null 2>&1
for _t38 in t38a t38b; do
  _o="$(sed -n 's/^max_output_size = \([0-9]*\)$/\1/p' "$HOME/.kimi-prov-$_t38/config.toml" 2>/dev/null)"
  [[ -n "$_o" ]] && (( _o < 131072 && _o <= 128000 )); assert_eq 0 $? "$_t38: max_output_size ($_o) below context and cap"
done
rm -rf "$HOME/.kimi-prov-t38a" "$HOME/.kimi-prov-t38b"

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

it "kimi-providers --help includes the quota subcommand documentation (I5)"
kimi_help="$("$SCRIPTS_DIR/kimi-providers.sh" --help 2>&1)"
echo "$kimi_help" | grep -q "quota" && found=1 || found=0
assert_eq "1" "$found" "kimi-providers --help must mention quota"

summary