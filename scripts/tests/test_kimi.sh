#!/usr/bin/env bash
# test_kimi.sh — hermetic Tier-A coverage for the full Kimi provider support
# (v1.15.0): multi-model OAuth records, OAuth-first precedence, launch-time
# token freshness, kimi_proxy schema normalization, family proxy discovery,
# and API-key resolution for kimi.com coding keys. No network, no real keys.
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
CACHE="$PDIR/models.dev.cache.json"

# --- shared fixtures ---------------------------------------------------------
# models.dev catalog seed: the kimi-for-coding provider (env KIMI_API_KEY)
# with the three served models and their limits.
cat > "$CACHE" <<'JSON'
{
  "kimi-for-coding": {
    "env": ["KIMI_API_KEY"],
    "api": "https://api.kimi.com/coding/v1",
    "models": {
      "k3":                        {"limit": {"context": 1048576, "output": 131072}, "reasoning": true},
      "k2p7":                      {"limit": {"context": 262144,  "output": 32768},  "reasoning": true},
      "kimi-for-coding-highspeed": {"limit": {"context": 262144,  "output": 32768},  "reasoning": true}
    }
  }
}
JSON

FAKEBIN="$HOME/fakebin"; mkdir -p "$FAKEBIN"
# Fake kimi CLI: rewrites the cred file with a FRESH token (simulates OAuth
# refresh on `kimi -p ...`), then exits 0.
cat > "$FAKEBIN/kimi" <<'EOF'
#!/usr/bin/env bash
cred="$HOME/.kimi-code/credentials/kimi-code.json"
[[ -f "$cred" ]] || exit 1
now=$(date +%s)
cat > "$cred" <<JSON
{"access_token":"REFRESHED-TOKEN","expires_at":$((now+3600)),"refresh_token":"r","scope":"kimi-code","token_type":"Bearer"}
JSON
exit 0
EOF
# Stub curl: answers the /models discovery with three served models.
cat > "$FAKEBIN/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do :; done
echo '{"data":[{"id":"kimi-for-coding"},{"id":"kimi-for-coding-highspeed"},{"id":"k3"}]}'
exit 0
EOF
chmod +x "$FAKEBIN/kimi" "$FAKEBIN/curl"

write_cred() {  # $1 = access_token, $2 = expires_at
  mkdir -p "$HOME/.kimi-code/credentials"
  cat > "$HOME/.kimi-code/credentials/kimi-code.json" <<JSON
{"access_token":"$1","expires_at":$2,"refresh_token":"r","scope":"kimi-code","token_type":"Bearer"}
JSON
}

# shellcheck source=../claude-providers.sh
source "$SCRIPTS_DIR/claude-providers.sh"
# claude-providers.sh re-enables `set -euo pipefail` on source; the harness
# convention is failing-by-design assertions, so relax again immediately.
set +e

# ===========================================================================
# Section 1 — detect_kimicode_record: multi-model OAuth records
# ===========================================================================
it "kimicode detector: no kimi binary on PATH -> []"
out="$(PATH="/usr/bin:/bin" detect_kimicode_record)"
assert_eq "[]" "$out" "no kimi CLI yields empty record set"

it "kimicode detector: kimi CLI but no credentials file -> []"
out="$(PATH="$FAKEBIN:/usr/bin:/bin" detect_kimicode_record)"
assert_eq "[]" "$out" "missing cred file yields empty record set"

it "kimicode detector: one record per subscription-served model (live /models discovery unioned with catalog)"
write_cred "LIVE-TOKEN" "$(( $(date +%s) + 3600 ))"
out="$(PATH="$FAKEBIN:/usr/bin:/bin" detect_kimicode_record)"
assert_eq 4 "$(jq 'length' <<<"$out")" "four records: 3 listed by /models + catalog's k2p7 (union, sync probes gate)"
assert_eq "kc-for-coding kc-for-coding-highspeed kc-k2p7 kc-k3" \
  "$(jq -r '[.[].provider_id] | sort | join(" ")' <<<"$out")" "provider ids cover default + highspeed + Kimi 2.7 + Kimi 3 (kc-* namespace)"
assert_eq "k3" "$(jq -r '.[] | select(.provider_id=="kc-k3") | .strong_model' <<<"$out")" "kc-k3 runs model k3"
assert_eq "kimi-for-coding-highspeed" "$(jq -r '.[] | select(.provider_id=="kc-for-coding-highspeed") | .strong_model' <<<"$out")" "highspeed runs its own model id"
assert_eq "1048576" "$(jq -r '.[] | select(.provider_id=="kc-k3") | .context_limit' <<<"$out")" "k3 context from catalog (1M)"
assert_eq "131072" "$(jq -r '.[] | select(.provider_id=="kc-k3") | .max_output' <<<"$out")" "k3 output from catalog"
assert_eq "_CMA_KIMICODE_OAUTH_" "$(jq -r '.[0].key_var' <<<"$out")" "all records use the OAuth sentinel keyvar"
assert_eq "https://api.kimi.com/coding/v1" "$(jq -r '.[0].base_url' <<<"$out")" "coding endpoint base"
tok="$(cat "$PDIR/kc-k3.token" 2>/dev/null)"
assert_eq "LIVE-TOKEN" "$tok" "per-alias token snapshot written (kc-k3.token)"
assert_eq "LIVE-TOKEN" "$(cat "$PDIR/kc-for-coding-highspeed.token" 2>/dev/null)" "token snapshot for highspeed too"
assert_eq "600" "$(stat -c %a "$PDIR/kc-k3.token")" "token snapshot is chmod 600"

it "kimicode detector: expired token triggers CLI refresh before emitting"
write_cred "STALE-TOKEN" "$(( $(date +%s) - 100 ))"
out="$(PATH="$FAKEBIN:/usr/bin:/bin" detect_kimicode_record)"
assert_eq "REFRESHED-TOKEN" "$(cat "$PDIR/kc-k3.token" 2>/dev/null)" "stale OAuth token refreshed via kimi CLI"

it "kimicode detector: offline falls back to the models.dev catalog (+ account default)"
write_cred "LIVE-TOKEN" "$(( $(date +%s) + 3600 ))"
out="$(OFFLINE=1 PATH="$FAKEBIN:/usr/bin:/bin" detect_kimicode_record)"
ids="$(jq -r '[.[].provider_id] | sort | join(" ")' <<<"$out")"
ok=1; [[ "$ids" == *"kc-k3"* && "$ids" == *"kc-k2p7"* && "$ids" == *"kc-for-coding"* ]] && ok=0
assert_eq 0 "$ok" "offline records come from catalog keys + account default ($ids)"

# ===========================================================================
# Section 2 — resolve_records: OAuth detector records WIN over key-var records
# ===========================================================================
it "resolve_records: OAuth kc-for-coding record takes precedence over KIMI_API_KEY record"
write_cred "LIVE-TOKEN" "$(( $(date +%s) + 3600 ))"
kf="$HOME/keys.sh"; printf 'export KIMI_API_KEY=sk-test\n' > "$kf"
merged="$(CMA_KEYS_FILE="$kf" PATH="$FAKEBIN:/usr/bin:/bin" resolve_records)"
kv="$(jq -r '.[] | select(.provider_id=="kc-for-coding") | .key_var' <<<"$merged")"
assert_eq "_CMA_KIMICODE_OAUTH_" "$kv" "OAuth subscription record wins over the API-key record"
ok=1; jq -e '.[] | select(.provider_id=="kc-k3")' <<<"$merged" >/dev/null && ok=0
assert_eq 0 "$ok" "OAuth-only models (kc-k3) are present in the merged set"
n="$(jq '[.[] | select(.provider_id=="kc-for-coding")] | length' <<<"$merged")"
assert_eq 1 "$n" "no duplicate kc-for-coding record"

it "resolve_records: API key remains the fallback when no OAuth session exists"
rm -rf "$HOME/.kimi-code"
merged2="$(CMA_KEYS_FILE="$kf" PATH="/usr/bin:/bin" resolve_records)"
kv2="$(jq -r '.[] | select(.provider_id=="kc-for-coding") | .key_var' <<<"$merged2")"
assert_eq "KIMI_API_KEY" "$kv2" "KIMI_API_KEY record used when no OAuth session"

it "resolver: ApiKey_Kimi maps to kc-for-coding via key-aliases (+ legacy rename)"
kf2="$HOME/keys2.sh"; printf 'export ApiKey_Kimi=sk-test\n' > "$kf2"
r3="$(CMA_KEYS_FILE="$kf2" PATH="/usr/bin:/bin" resolve_records)"
kv3="$(jq -r '.[] | select(.provider_id=="kc-for-coding") | .key_var' <<<"$r3")"
assert_eq "ApiKey_Kimi" "$kv3" "ApiKey_Kimi resolves to kc-for-coding (upstream catalog id kimi-for-coding renamed)"
n3="$(jq '[.[] | select(.provider_id=="kimi-for-coding")] | length' <<<"$r3")"
assert_eq 0 "$n3" "no record leaks the legacy kimi-for-coding id"

# ===========================================================================
# Section 3 — launch-time OAuth token freshness (emitted cma_run_provider)
# ===========================================================================
# Launch plumbing: alias file + env file + verified status + recorder claude.
cma_ensure_alias_file
cma_provider_write_env kimi-k3 _CMA_KIMICODE_OAUTH_ native \
  https://api.kimi.com/coding/anthropic k3 k3 "$HOME/.claude-prov-kimi-k3" 1048576 131072 kimi-k3
cma_provider_write_alias kimi-k3 kimi-k3
cma_status_write kimi-k3 verified k3 ""

rec_env="$HOME/rec.env"
recorder="$HOME/recorder.sh"
cat > "$recorder" <<'EOF'
#!/usr/bin/env bash
env | grep -E '^ANTHROPIC_(AUTH_TOKEN|BASE_URL|MODEL)=' > "$REC_ENV_OUT"
exit 0
EOF
chmod +x "$recorder"
mkdir -p "$HOME/.local/bin"
for stub in claude-sync-state claude-session; do
  # sandbox_stub, not a bare redirect: in a real $HOME these names are symlinks
  # into the repo and `>` would write THROUGH the link into the production script.
  sandbox_stub "$HOME/.local/bin/$stub" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
done

# shellcheck source=/dev/null
source "$ALIAS_FILE"
# PROVENANCE GATE — see lib/assert.sh:assert_fn_from. Both launch legs below
# (run_launch and the expired-token leg) depend on this source having taken;
# the host's cma_run_provider is already defined here via BASH_ENV.
it "HYGIENE: the cma_run_provider under test comes from the sandbox alias file"
assert_fn_from cma_run_provider "$ALIAS_FILE" "wrapper loaded from the sandbox, not the host"
CLAUDE_BIN="$recorder"

run_launch() {  # -> prints captured ANTHROPIC_AUTH_TOKEN
  : > "$rec_env"
  ( set +eu; REC_ENV_OUT="$rec_env" CLAUDE_BIN="$recorder" cma_run_provider kimi-k3 </dev/null >/dev/null 2>&1 )
  grep '^ANTHROPIC_AUTH_TOKEN=' "$rec_env" 2>/dev/null | cut -d= -f2-
}

it "launch: unexpired LIVE credentials file beats the sync-time snapshot"
write_cred "LIVE-TOKEN" "$(( $(date +%s) + 3600 ))"
( umask 077; printf '%s' "SNAPSHOT-TOKEN" > "$PDIR/kimi-k3.token" )
assert_eq "LIVE-TOKEN" "$(run_launch)" "fresh OAuth token read from the live cred file"

it "launch: expired cred file triggers CLI refresh and uses the refreshed token"
write_cred "STALE-TOKEN" "$(( $(date +%s) - 100 ))"
: > "$rec_env"
( set +eu; PATH="$FAKEBIN:/usr/bin:/bin" REC_ENV_OUT="$rec_env" CLAUDE_BIN="$recorder" cma_run_provider kimi-k3 </dev/null >/dev/null 2>&1 )
assert_eq "REFRESHED-TOKEN" "$(grep '^ANTHROPIC_AUTH_TOKEN=' "$rec_env" | cut -d= -f2-)" "expired token refreshed at launch"

it "launch: no credentials file falls back to the token-file snapshot"
rm -rf "$HOME/.kimi-code"
( umask 077; printf '%s' "SNAPSHOT-TOKEN" > "$PDIR/kimi-k3.token" )
assert_eq "SNAPSHOT-TOKEN" "$(run_launch)" "token-file snapshot is the last-resort fallback"

it "emitted wrapper carries the freshness-order markers (live cred -> CLI refresh -> snapshot)"
body="$(awk '/^cma_run_provider\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE")"
# herestrings (<<<), NOT `printf … | grep -q`: under pipefail, grep -q exits at
# the first match and printf's remaining write to the (post-merge larger) body
# takes SIGPIPE (rc 141) -> false FAIL though the match IS present.
grep -q 'kimi-code/credentials/kimi-code.json' <<<"$body"; assert_eq 0 $? "live cred file consulted"
grep -q 'kimi -p "hi"' <<<"$body"; assert_eq 0 $? "CLI refresh path present"
# Proxy discovery migrated to the Go cma-proxy (2026-07-22): the wrapper asks
# `cma-proxy --has-transform <id>` and cma-proxy resolves the kimi-* family key
# itself, so the old `_family_id` shell var is gone — assert the new mechanism.
grep -q 'has-transform' <<<"$body"; assert_eq 0 $? "cma-proxy discovery present"

# ===========================================================================
# Section 3b — cmd_verify injects the OAuth token (no detector in that path)
# ===========================================================================
it "cmd_verify: OAuth sentinel token injected for verify-by-id (token-file fallback)"
# cmd_verify sources the env file and must inject _CMA_KIMICODE_OAUTH_ itself —
# otherwise ${!KEYVAR} is empty and verification degrades to a false unverified.
( umask 077; printf '%s' "SNAPSHOT-TOKEN" > "$PDIR/kimi-k3.token" )
cat > "$FAKEBIN/verify-records-key" <<'EOF'
#!/usr/bin/env bash
# Stub providers-verify: PASS only when the OAuth token is actually visible.
if [[ -n "${_CMA_KIMICODE_OAUTH_:-}" ]]; then echo verified; else echo unverified; exit 2; fi
EOF
cat > "$FAKEBIN/semantic-ok" <<'EOF'
#!/usr/bin/env bash
echo verified
EOF
chmod +x "$FAKEBIN/verify-records-key" "$FAKEBIN/semantic-ok"
printf '# empty keys file\n' > "$HOME/keys-empty.sh"
vout="$(CMA_KEYS_FILE="$HOME/keys-empty.sh" \
        VERIFY="$FAKEBIN/verify-records-key" \
        SEMANTIC="$FAKEBIN/semantic-ok" \
        cmd_verify kimi-k3 2>/dev/null)"
assert_eq "verified" "$vout" "cmd_verify kimi-k3 reaches verified with the injected token"
assert_eq "verified" "$(cma_status_read kimi-k3)" "status persisted as verified"

# ===========================================================================
# Section 4 — kimi request transform (moonshot-flavored schema normalization)
# ===========================================================================
# Migrated to Go (2026-07-22): the kimi request transform now lives in
# scripts/proxy/kimi.go and is covered by scripts/proxy/kimi_test.go
# ($defs/definitions hoist, foreign-$ref rewrite, type/properties guarantee,
# cache_control strip). Run via `go test ./...` in scripts/proxy, exercised by
# scripts/tests/test_cma_proxy.sh in the suite. This section (which imported the
# retired kimi_proxy.py) is intentionally removed.

summary
