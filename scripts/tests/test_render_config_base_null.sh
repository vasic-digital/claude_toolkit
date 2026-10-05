#!/usr/bin/env bash
# test_render_config_base_null.sh — _cma_pi_render_config and
# _cma_kimi_render_config (scripts/claude-providers.sh) must never write the
# literal string "null" as a base URL into their rendered config files.
#
# WHY THIS EXISTS (round-3 independent review, same session as the TSV
# null-field-corruption fix in cmd_sync/cmd_sync_multi). That fix defaults
# every nullable field in the TSV feed -- including .base_url -- to the
# literal string "null" instead of a bare empty string, because tab is a
# POSIX IFS-whitespace character and `IFS=$'\t' read` collapses even ONE
# empty field into the delimiter, cascading every subsequent field one slot
# left (reproduced live against the real "anthropic" catalog entry: a
# NATIVE-transport provider with no catalog `api` field stays "resolved"
# with base_url=null, since providers_resolve.py only marks ROUTER providers
# unmapped for a missing base_url).
#
# That TSV-level fix is necessary but NOT sufficient on its own: both
# _cma_pi_render_config and _cma_kimi_render_config write their `base`
# parameter VERBATIM into a config file (models.json / config.toml) with no
# normalization layer in between the TSV read and the write -- unlike
# cma_provider_write_env, which already normalizes "null" -> "" for every
# field it writes (lib.sh ~3695-3701). Without this test's guard, a
# resolved-but-base_url-null record would ship a syntactically-valid but
# semantically-broken `baseUrl: "null"` / `base_url = "null"` into the
# provider's own live config.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# Volatile run output (D1): written to a temp file beside the final path and
# renamed into the git-ignored proof/volatile/ folder only on completion.
# shellcheck source=lib/proof.sh
source "$TESTS_DIR/lib/proof.sh"
PROOF_DIR="$(cma_proof_volatile_dir)"
PROOF_FINAL="$PROOF_DIR/test_render_config_base_null.txt"
PROOF="$(cma_proof_open "$PROOF_FINAL")"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox

# shellcheck source=../claude-providers.sh
source "$SCRIPTS_DIR/claude-providers.sh"
set +e   # claude-providers.sh (and the lib.sh it sources) set -e; this
         # harness asserts on failures rather than aborting on the first one.

it "_cma_pi_render_config: base='null' (literal string, round-3 TSV fix) writes an EMPTY baseUrl, never the string 'null'"
_cma_pi_render_config "pitest" "PITEST_KEY" "native" "null" "claude-sonnet-5-5" "1000000"
CFG_PI="$HOME/.pi-prov-pitest/models.json"
assert_file "$CFG_PI" "models.json rendered for the base='null' fixture"
if [[ -f "$CFG_PI" ]]; then
  _pi_json="$(cat "$CFG_PI")"
  echo "--- pi models.json (base='null' fixture) ---" >> "$PROOF"
  echo "$_pi_json" >> "$PROOF"
  _pi_base="$(jq -r '.providers.pitest.baseUrl' <<<"$_pi_json")"
  assert_eq "" "$_pi_base" "baseUrl is empty, NEVER the literal string 'null'"
fi

it "_cma_kimi_render_config: base='null' (literal string, round-3 TSV fix) writes an EMPTY base_url, never the string 'null'"
_cma_kimi_render_config "kimitest" "KIMITEST_KEY" "native" "null" "claude-sonnet-5-5" "1000000"
CFG_KIMI="$HOME/.kimi-prov-kimitest/config.toml"
assert_file "$CFG_KIMI" "config.toml rendered for the base='null' fixture"
if [[ -f "$CFG_KIMI" ]]; then
  _kimi_toml="$(cat "$CFG_KIMI")"
  echo "--- kimi config.toml (base='null' fixture) ---" >> "$PROOF"
  echo "$_kimi_toml" >> "$PROOF"
  _kimi_base_line="$(grep -E '^[[:space:]]*base_url[[:space:]]*=' "$CFG_KIMI" | head -n1)"
  assert_eq 'base_url = ""' "$_kimi_base_line" "base_url line is an EMPTY string, NEVER the literal \"null\""
fi

it "control: a GENUINE base URL (not the string 'null') still renders correctly through both functions"
_cma_pi_render_config "pireal" "PIREAL_KEY" "native" "https://api.example.invalid" "claude-sonnet-5-5" "1000000"
_pi_real_base="$(jq -r '.providers.pireal.baseUrl' "$HOME/.pi-prov-pireal/models.json" 2>/dev/null)"
assert_eq "https://api.example.invalid" "$_pi_real_base" "a real base URL is NOT accidentally blanked by the new guard"
_cma_kimi_render_config "kimireal" "KIMIREAL_KEY" "native" "https://api.example.invalid" "claude-sonnet-5-5" "1000000"
_kimi_real_base_line="$(grep -E '^[[:space:]]*base_url[[:space:]]*=' "$HOME/.kimi-prov-kimireal/config.toml" 2>/dev/null | head -n1)"
assert_eq 'base_url = "https://api.example.invalid"' "$_kimi_real_base_line" "a real base URL is NOT accidentally blanked by the new guard"

cma_proof_commit "$PROOF" "$PROOF_FINAL"
summary
