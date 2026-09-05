#!/usr/bin/env bash
# test_kimi_migration.sh — hermetic coverage for the legacy kimi-* -> kc-*
# provider-id rename (v1.27.0). Exercise cmd_migrate_names end to end on a
# sandboxed old-form fixture: status keys, env files, token files, provider
# config dirs, alias-file lines, key-aliases.json values and overrides.json
# keys. No network, no real keys, no real ~/.claude state.
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

PDIR="$(cma_providers_dir)"
mkdir -p "$PDIR"

# --- sandbox copies of the tracked inputs, so the migration never touches the
# --- real repo's providers/*.json. Point the engine at them via the (now
# --- env-overridable) KEY_ALIASES/OVERRIDES/LEGACY_RENAMES knobs BEFORE sourcing.
SB="$HOME/provider-fixtures"
mkdir -p "$SB"
cp "$SCRIPTS_DIR/providers/legacy-renames.json" "$SB/legacy-renames.json"

# Fixture key-aliases.json: ApiKey_Kimi maps to the OLD id (the pre-rename shape).
cat > "$SB/key-aliases.json" <<'JSON'
{
  "ApiKey_Kimi": "kimi-for-coding",
  "MOONSHOT_API_KEY": "moonshotai"
}
JSON
# Fixture overrides.json: carries an entry under the OLD key plus an unrelated one.
cat > "$SB/overrides.json" <<'JSON'
{
  "kimi-for-coding": {
    "transport": "router",
    "base_url": "https://api.kimi.com/coding/v1",
    "strong_model": "kimi-for-coding",
    "fast_model": "kimi-for-coding",
    "context_limit": 262144,
    "max_output": 65536
  },
  "moonshotai": {"transport": "router"}
}
JSON

export KEY_ALIASES="$SB/key-aliases.json"
export OVERRIDES="$SB/overrides.json"
export LEGACY_RENAMES="$SB/legacy-renames.json"

# shellcheck source=../claude-providers.sh
source "$SCRIPTS_DIR/claude-providers.sh"
set +e

# --- shared old-form fixture -------------------------------------------------
# A verified status record, env file and token file for the old id (plus an
# unrelated provider that must be left untouched).
cat > "$PDIR/status.json" <<'JSON'
{"kimi-for-coding":{"status":"verified","model":"kimi-for-coding","failing_layer":""},"moonshotai":{"status":"verified","model":"m1","failing_layer":""}}
JSON
cat > "$PDIR/kimi-for-coding.env" <<'ENV'
CMA_PROVIDER_ID='kimi-for-coding'
CMA_PROVIDER_KEYVAR='_CMA_KIMICODE_OAUTH_'
CMA_PROVIDER_TRANSPORT='router'
CMA_PROVIDER_BASE_URL='https://api.kimi.com/coding/v1'
CMA_PROVIDER_MODEL='kimi-for-coding'
CMA_PROVIDER_FAST_MODEL='kimi-for-coding'
CMA_PROVIDER_CONFIG_DIR='$HOME/.claude-prov-kimi-for-coding'
CMA_PROVIDER_CONTEXT_LIMIT='262144'
CMA_PROVIDER_MAX_OUTPUT='65536'
CMA_PROVIDER_ALIAS='kimi-for-coding'
ENV
( umask 077; printf 'TOKEN-SECRET' > "$PDIR/kimi-for-coding.token" )
mkdir -p "$HOME/.claude-prov-kimi-for-coding"

# Alias-file fixture: the old name present via the real alias writer.
cma_ensure_alias_file
cma_provider_write_alias kimi-for-coding kimi-for-coding
grep -q '^alias kimi-for-coding="cma_run_provider kimi-for-coding"' "$ALIAS_FILE"
assert_eq 0 $? "pre-migration: alias file carries the old-form alias"

# ===========================================================================
# Section 1 — run migrate-names, assert the full rename
# ===========================================================================
it "migrate-names renames status key, env, token, config dir, alias, key-aliases and overrides"
cmd_migrate_names >/dev/null 2>&1
assert_eq "absent" "$(jq -r '."kimi-for-coding" // "absent"' "$PDIR/status.json")" "old status key migrated away"
assert_eq "verified" "$(jq -r '."kc-for-coding".status' "$PDIR/status.json")" "status key renamed to kc-for-coding"
assert_file "$PDIR/kc-for-coding.env" "env file renamed to kc-for-coding.env"
assert_eq "0" "$([[ -e "$PDIR/kimi-for-coding.env" ]] && echo 1 || echo 0)" "old env file gone"
assert_file "$PDIR/kc-for-coding.token" "token file renamed to kc-for-coding.token"
assert_eq "TOKEN-SECRET" "$(cat "$PDIR/kc-for-coding.token")" "token content preserved"
assert_dir "$HOME/.claude-prov-kc-for-coding" "provider config dir renamed to kc-"
assert_eq "0" "$([[ -d "$HOME/.claude-prov-kimi-for-coding" ]] && echo 1 || echo 0)" "old provider dir gone"
grep -q '^alias kc-for-coding="cma_run_provider kc-for-coding"' "$ALIAS_FILE"
assert_eq 0 $? "alias renamed to kc-for-coding"
grep -q '^alias kimi-for-coding=' "$ALIAS_FILE"
assert_eq 1 $? "old-form alias dropped from the alias file"
assert_jq "$KEY_ALIASES" '."ApiKey_Kimi"' "kc-for-coding" "key-aliases ApiKey_Kimi now -> kc-for-coding"
assert_jq "$OVERRIDES" '."kc-for-coding".transport' "router" "overrides key renamed to kc-for-coding (block preserved)"
assert_jq "$OVERRIDES" '."kimi-for-coding" // "absent"' "absent" "old overrides key gone"
assert_eq "verified" "$(jq -r '."moonshotai".status' "$PDIR/status.json")" "unrelated provider unmigrated"

# ===========================================================================
# Section 1b — migrate-names --dry-run previews exactly what would change
# and writes NOTHING (usage text line 109 promises a preview; the command must
# keep it — a dry-run that also writes would be indistinguishable from a real
# migration except by luck).
# ===========================================================================
it "migrate-names --dry-run previews each action and writes nothing"
jq '. + {"kimi-for-coding2":{"status":"verified"}}' "$PDIR/status.json" \
  > "$PDIR/status.json.tmp" && mv "$PDIR/status.json.tmp" "$PDIR/status.json"
printf "CMA_PROVIDER_ID='kimi-for-coding2'\n" > "$PDIR/kimi-for-coding2.env"
( umask 077; printf 'TOKEN-2' > "$PDIR/kimi-for-coding2.token" )
mkdir -p "$HOME/.claude-prov-kimi-for-coding2"
cma_provider_write_alias kimi-for-coding2 kimi-for-coding2
jq '. + {"ApiKey_SecondKimi":"kimi-for-coding2"}' "$KEY_ALIASES" \
  > "$KEY_ALIASES.tmp" && mv "$KEY_ALIASES.tmp" "$KEY_ALIASES"
jq '. + {"kimi-for-coding2":{"transport":"router"}}' "$OVERRIDES" \
  > "$OVERRIDES.tmp" && mv "$OVERRIDES.tmp" "$OVERRIDES"

out_dry="$(DRY_RUN=1 cmd_migrate_names 2>&1)"
assert_eq "1" "$(grep -c 'would rename status record: kimi-for-coding2 -> kc-for-coding2' <<<"$out_dry")" "dry-run prints the status-record preview"
assert_eq "1" "$(grep -c 'would rename env: kimi-for-coding2.env -> kc-for-coding2.env' <<<"$out_dry")" "dry-run prints the env preview"
assert_eq "1" "$(grep -c 'would rename token: kimi-for-coding2.token -> kc-for-coding2.token' <<<"$out_dry")" "dry-run prints the token preview"
assert_eq "1" "$(grep -c 'would rename config dir: .*kimi-for-coding2 -> .*kc-for-coding2' <<<"$out_dry")" "dry-run prints the config-dir preview"
assert_eq "1" "$(grep -c 'would rename alias: kimi-for-coding2 -> kc-for-coding2' <<<"$out_dry")" "dry-run prints the alias preview"
assert_eq "1" "$(grep -c 'would rewrite .*value kimi-for-coding2 -> kc-for-coding2' <<<"$out_dry")" "dry-run prints the key-aliases preview"
assert_eq "1" "$(grep -c 'would rewrite .*key kimi-for-coding2 -> kc-for-coding2' <<<"$out_dry")" "dry-run prints the overrides preview"
assert_eq "0" "$(grep -c '^  renamed ' <<<"$out_dry")" "dry-run prints no past-tense 'renamed' lines"
assert_eq "verified" "$(jq -r '."kimi-for-coding2".status // "absent"' "$PDIR/status.json")" "dry-run leaves status key unmigrated"
assert_eq "absent" "$(jq -r '."kc-for-coding2" // "absent"' "$PDIR/status.json")" "dry-run creates no kc status key"
assert_file "$PDIR/kimi-for-coding2.env" "dry-run leaves old env file in place"
assert_eq "0" "$([[ -e "$PDIR/kc-for-coding2.env" ]] && echo 1 || echo 0)" "dry-run creates no kc env file"
assert_file "$PDIR/kimi-for-coding2.token" "dry-run leaves old token file in place"
assert_dir "$HOME/.claude-prov-kimi-for-coding2" "dry-run leaves old config dir in place"
assert_eq "0" "$([[ -d "$HOME/.claude-prov-kc-for-coding2" ]] && echo 1 || echo 0)" "dry-run creates no kc config dir"
grep -q '^alias kimi-for-coding2=' "$ALIAS_FILE"; assert_eq 0 $? "dry-run leaves old alias in place"
grep -q '^alias kc-for-coding2=' "$ALIAS_FILE"; assert_eq 1 $? "dry-run adds no kc alias"
assert_jq "$KEY_ALIASES" '."ApiKey_SecondKimi"' "kimi-for-coding2" "dry-run leaves key-aliases value unmigrated"
assert_jq "$OVERRIDES" '."kimi-for-coding2".transport' "router" "dry-run leaves overrides key unmigrated"

# Settle the tree (real migration of the seeded id) so the idempotency section
# below snapshots a fully-renamed state and asserts true no-ops.
cmd_migrate_names >/dev/null 2>&1
assert_file "$PDIR/kc-for-coding2.env" "settled: kimi-for-coding2.env migrated to kc-"
assert_eq "0" "$([[ -e "$PDIR/kimi-for-coding2.env" ]] && echo 1 || echo 0)" "settled: old env gone"
assert_dir "$HOME/.claude-prov-kc-for-coding2" "settled: config dir renamed"
assert_eq "0" "$([[ -d "$HOME/.claude-prov-kimi-for-coding2" ]] && echo 1 || echo 0)" "settled: old config dir gone"

# ===========================================================================
# Section 2 — idempotency: a second run on the settled tree is a byte-level no-op
# ===========================================================================
it "migrate-names is idempotent (second run = byte-level no-op, zero audit lines)"
snap() { cp "$PDIR/status.json"       "$SB/status-snap"; \
         cp "$PDIR/kc-for-coding.env" "$SB/env-snap"; \
         cp "$PDIR/kc-for-coding.token" "$SB/token-snap"; \
         cp "$KEY_ALIASES" "$SB/kal-snap"; \
         cp "$OVERRIDES" "$SB/ovr-snap"; \
         cp "$ALIAS_FILE" "$SB/alias-snap"; }
snap
out2="$(cmd_migrate_names 2>&1)"
cmp -s "$PDIR/status.json" "$SB/status-snap"; assert_eq 0 $? "run2 status.json byte-identical"
cmp -s "$PDIR/kc-for-coding.env" "$SB/env-snap"; assert_eq 0 $? "run2 env byte-identical"
cmp -s "$PDIR/kc-for-coding.token" "$SB/token-snap"; assert_eq 0 $? "run2 token byte-identical"
cmp -s "$KEY_ALIASES" "$SB/kal-snap"; assert_eq 0 $? "run2 key-aliases byte-identical"
cmp -s "$OVERRIDES" "$SB/ovr-snap"; assert_eq 0 $? "run2 overrides byte-identical"
cmp -s "$ALIAS_FILE" "$SB/alias-snap"; assert_eq 0 $? "run2 alias file byte-identical"
assert_eq "" "$out2" "run2 prints no audit lines (nothing to do)"

# ===========================================================================
# Section 3 — all five mapped ids migrate; none of the old names remain
# ===========================================================================
it "migrate-names handles every mapped id and leaves no old-form residue"
# Pre-seed every old id as an env file (status/token/dir are covered by run 1);
# run a fresh migration and assert each becomes its kc- twin.
for old in kimi-for-coding2 kimi-for-coding-highspeed kimi-k3 kimi-k2p7; do
  printf "CMA_PROVIDER_ID='%s'\n" "$old" > "$PDIR/$old.env"
done
cmd_migrate_names >/dev/null 2>&1
for pair in "kimi-for-coding2 kc-for-coding2" "kimi-for-coding-highspeed kc-for-coding-highspeed" "kimi-k3 kc-k3" "kimi-k2p7 kc-k2p7"; do
  set -- $pair; old="$1"; new="$2"
  assert_file "$PDIR/$new.env" "env for $old renamed to $new"
  assert_eq "0" "$([[ -e "$PDIR/$old.env" ]] && echo 1 || echo 0)" "old env $old gone"
done

summary
