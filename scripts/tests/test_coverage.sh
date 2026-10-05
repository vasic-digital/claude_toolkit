#!/usr/bin/env bash
# test_coverage.sh — coverage tests for lib.sh behaviors not covered in test_lib.sh.
#
# Areas covered:
#   1. cma_ensure_alias_file: fresh creation, idempotency, old-format migration
#   2. cma_can_prompt: CMA_NONINTERACTIVE=1 and no-tty conditions
#   3. cma_enable_plugins: JSON shape, additive behaviour, //= semantics
#   4. cma_link_shared_items: all CMA_SHARED_ITEMS become symlinks into SHARED_DIR
#   5. stats-cache.json newest-by-mtime selection (via run_unify)
#   6. Security regressions: alias-injection rejection (M-1/M-2), .env quoting
#      (M-3), broadened secret redaction (H-1)
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
# lib.sh sets `set -e`. Tests assert on non-zero exits so we disable it.
set +e

# ── 1. cma_ensure_alias_file ─────────────────────────────────────────────────

it "cma_ensure_alias_file: fresh creation writes header and both wrappers"
rm -f "$ALIAS_FILE"
cma_ensure_alias_file
assert_file "$ALIAS_FILE" "alias file created from scratch"
assert_file_contains "$ALIAS_FILE" "export CLAUDE_BIN=" "CLAUDE_BIN export present"
assert_file_contains "$ALIAS_FILE" "cma_run()" "cma_run wrapper written"
assert_file_contains "$ALIAS_FILE" "cma_run_provider()" "cma_run_provider wrapper written"

it "cma_ensure_alias_file: idempotent — second call does not duplicate wrappers"
cma_ensure_alias_file   # second call on the same current file
run_count="$(grep -c '^cma_run()' "$ALIAS_FILE")"
assert_eq "1" "$run_count" "cma_run() appears exactly once"
prov_count="$(grep -c '^cma_run_provider()' "$ALIAS_FILE")"
assert_eq "1" "$prov_count" "cma_run_provider() appears exactly once"

it "cma_ensure_alias_file: old-format alias (direct \$CLAUDE_BIN) migrated to cma_run; unrelated lines survive"
# Build an alias file with the OLD pre-wrapper format. The old write code used
# printf with a single-quoted format so the alias contained the LITERAL string
# $CLAUDE_BIN (not expanded), e.g.:
#   alias claude1="CLAUDE_CONFIG_DIR=/path $CLAUDE_BIN"
# We reproduce that here via printf's single-quoted format string.
rm -f "$ALIAS_FILE"
mkdir -p "$(dirname "$ALIAS_FILE")"
{
  printf '# Managed by claude-multi-account. Do not edit by hand.\n'
  printf 'export CLAUDE_BIN="/usr/bin/true"\n'
  # shellcheck disable=SC2016  # $CLAUDE_BIN is a literal in the alias text, not a shell expansion
  printf 'alias claude1="CLAUDE_CONFIG_DIR=%s/.claude-acct1 $CLAUDE_BIN"\n' "$HOME"
  printf '# some user-added comment\n'
  printf 'MY_CUSTOM_VAR=preserved\n'
} > "$ALIAS_FILE"
cma_ensure_alias_file
# The alias must now reference cma_run instead of bare $CLAUDE_BIN
assert_file_contains "$ALIAS_FILE" "cma_run" "migrated alias now uses cma_run"
# shellcheck disable=SC2016  # $CLAUDE_BIN is a literal string to search for in the alias file
assert_file_not_contains "$ALIAS_FILE" ' $CLAUDE_BIN"' "old bare \$CLAUDE_BIN reference gone"
# Unrelated content must survive the in-place migration
assert_file_contains "$ALIAS_FILE" "MY_CUSTOM_VAR=preserved" "unrelated user line preserved after migration"

it "cma_ensure_alias_file (B9): migrates old cma_run_provider body; claude-sync-state added, alias lines after function preserved"
# Build an alias file with an OLD cma_run_provider() body that lacks both
# 'claude-sync-state' and 'set -a +u' — the two markers of the current
# version — followed by a real claudeN alias.  The old grep searched for
# 'claude-sync-state pull' (with a space after the command name) but the
# actual text has '"claude-sync-state" pull' (quote-then-space), so the
# match always failed and migration fired on EVERY write, chopping all
# alias lines that followed the function.  This test locks in the fix.
rm -f "$ALIAS_FILE"
mkdir -p "$(dirname "$ALIAS_FILE")"
cat > "$ALIAS_FILE" <<'B9_OLD_BODY'
# Managed by claude-multi-account. Do not edit by hand.
export CLAUDE_BIN="/usr/bin/true"

cma_run_provider() {
  local id="$1"; shift 2>/dev/null || true
  local pdir="$HOME/.local/share/claude-multi-account/providers"
  local envf="$pdir/$id.env"
  if [[ ! -f "$envf" ]]; then
    printf 'claude-providers: unknown provider %s\n' "$id" >&2
    return 1
  fi
  source "$envf"
  local keysf="${CMA_KEYS_FILE:-$HOME/api_keys.sh}"
  if [[ -f "$keysf" ]]; then source "$keysf"; fi
  local token=""
  eval "token=\"\${$CMA_PROVIDER_KEYVAR:-}\""
  if [[ -z "$token" ]]; then
    printf 'claude-providers: $%s is empty\n' "$CMA_PROVIDER_KEYVAR" >&2
    return 1
  fi
  export CLAUDE_CONFIG_DIR="$CMA_PROVIDER_CONFIG_DIR"
  export ANTHROPIC_BASE_URL="$CMA_PROVIDER_BASE_URL"
  export ANTHROPIC_AUTH_TOKEN="$token"
  "$CLAUDE_BIN" "$@"
}
B9_OLD_BODY
# Append a real alias AFTER the function — this is what the old bug silently
# dropped on every subsequent install.sh re-run.
printf 'alias claude1="CLAUDE_CONFIG_DIR=%s/.claude-acct1 cma_run"\n' "$HOME" >> "$ALIAS_FILE"
cma_ensure_alias_file
# (a) The new cma_run_provider() body must contain claude-sync-state.
_b9_body="$(awk '/^cma_run_provider\(\)/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE")"
b9_has_sync=1; grep -q 'claude-sync-state' <<<"$_b9_body" && b9_has_sync=0
assert_eq 0 "$b9_has_sync" "migrated cma_run_provider body contains claude-sync-state"
# (b) alias claude1= must survive — this is the line the old bug chopped.
assert_file_contains "$ALIAS_FILE" "alias claude1=" "alias claude1 line preserved after cma_run_provider migration"
# (c) exactly one cma_run_provider() definition (no duplication).
b9_prov_count="$(grep -c '^cma_run_provider()' "$ALIAS_FILE" || true)"
assert_eq "1" "$b9_prov_count" "cma_run_provider() appears exactly once after migration"

# ── 2. cma_can_prompt ────────────────────────────────────────────────────────

it "cma_can_prompt: returns 1 when CMA_NONINTERACTIVE=1"
( CMA_NONINTERACTIVE=1 cma_can_prompt ); rc=$?
assert_eq 1 "$rc" "CMA_NONINTERACTIVE=1 → cma_can_prompt returns 1"

it "cma_can_prompt: returns non-zero when no controlling tty (via setsid or direct)"
# setsid creates a new session with no controlling terminal; /dev/tty open fails.
# Falls back to a direct call if setsid is not available (still informative
# in CI environments which themselves have no PTY).
unset CMA_NONINTERACTIVE 2>/dev/null || true
if command -v setsid >/dev/null 2>&1; then
  setsid bash -c "
    source '$SCRIPTS_DIR/lib.sh' 2>/dev/null
    set +e
    unset CMA_NONINTERACTIVE
    cma_can_prompt
  " 2>/dev/null; rc=$?
  if [[ "$rc" -ne 0 ]]; then
    _pass "setsid (detached session) → cma_can_prompt returns false (rc=$rc)"
  else
    _fail "setsid (detached session)" "expected non-zero rc from cma_can_prompt, got 0"
  fi
else
  # No setsid: run directly; in CI (no PTY) this is still non-zero.
  cma_can_prompt; rc=$?
  if [[ "$rc" -ne 0 ]]; then
    _pass "no tty in this run environment → cma_can_prompt returns false (rc=$rc)"
  else
    _pass "tty is available in this run environment — CMA_NONINTERACTIVE=1 covers the critical path"
  fi
fi

# ── 3. cma_enable_plugins ────────────────────────────────────────────────────

it "cma_enable_plugins: creates settings.json and sets plugin key to true"
mkdir -p "$SHARED_DIR"
rm -f "$SHARED_DIR/settings.json"
cma_enable_plugins "superpowers@anthropics"
assert_file "$SHARED_DIR/settings.json" "settings.json created by cma_enable_plugins"
assert_jq  "$SHARED_DIR/settings.json" '.enabledPlugins["superpowers@anthropics"]' "true" "plugin key is true"

it "cma_enable_plugins: additive — second call adds new key without removing existing"
cma_enable_plugins "other-plugin@example"
assert_jq "$SHARED_DIR/settings.json" '.enabledPlugins["superpowers@anthropics"]' "true" "first plugin preserved"
assert_jq "$SHARED_DIR/settings.json" '.enabledPlugins["other-plugin@example"]'   "true" "new plugin added"

it "cma_enable_plugins: //= upgrades false to true (jq // is falsy, not null-only)"
# jq's alternative operator (//) returns the right side when the left is
# EITHER null OR false (unlike null-coalescing in other languages).  So
# .enabledPlugins[$k] //= true will flip a stored `false` to `true`.
# This is the REAL behaviour: a plugin explicitly set false gets re-enabled.
jq '.enabledPlugins["falsy@test"] = false' "$SHARED_DIR/settings.json" \
  > "$SHARED_DIR/settings.json.tmp" \
  && mv "$SHARED_DIR/settings.json.tmp" "$SHARED_DIR/settings.json"
cma_enable_plugins "falsy@test"
assert_jq "$SHARED_DIR/settings.json" '.enabledPlugins["falsy@test"]' "true" \
  "//= on false yields true (jq treats false as alternative-triggering)"

# ── 4. cma_link_shared_items ─────────────────────────────────────────────────

it "cma_link_shared_items: every CMA_SHARED_ITEMS entry becomes a symlink into SHARED_DIR"
linkdir="$HOME/.claude-linktest"
mkdir -p "$linkdir"
cma_link_shared_items "$linkdir"
all_ok=1
for item in "${CMA_SHARED_ITEMS[@]}"; do
  tgt="$linkdir/$item"
  if [[ ! -L "$tgt" ]]; then
    _fail "symlink for $item" "expected a symlink at $tgt but found none"
    all_ok=0
  else
    real_link="$(cma_realpath "$tgt")"
    real_src="$(cma_realpath "$SHARED_DIR/$item")"
    if [[ "$real_link" != "$real_src" ]]; then
      _fail "symlink target for $item" "want=$real_src got=$real_link"
      all_ok=0
    fi
  fi
done
(( all_ok )) && _pass "all ${#CMA_SHARED_ITEMS[@]} CMA_SHARED_ITEMS are correct symlinks"

it "cma_link_shared_items: idempotent — second call keeps same symlink count"
cma_link_shared_items "$linkdir"
link_count="$(find "$linkdir" -maxdepth 1 -type l | wc -l | tr -d ' ')"
expected="${#CMA_SHARED_ITEMS[@]}"
assert_eq "$expected" "$link_count" "same symlink count after second call (no duplicates)"

# ── 5. stats-cache.json newest-by-mtime (via run_unify) ──────────────────────

it "unify: stats-cache.json from the account with newer mtime wins"
d_old="$(make_account stats_old)"
d_new="$(make_account stats_new)"
# Write distinct content to each real (non-symlink) stats-cache.json file.
printf '{"source":"old"}\n' > "$d_old/stats-cache.json"
printf '{"source":"new"}\n' > "$d_new/stats-cache.json"
# Stamp mtimes deterministically so the test is never clock-sensitive.
# 2020 = older;  2023 = newer.
touch -t 202001010000.00 "$d_old/stats-cache.json"
touch -t 202301010000.00 "$d_new/stats-cache.json"
# Run unify (suppress log chatter; non-zero exit is still informative from $?).
# shellcheck disable=SC2119  # test intentionally calls run_unify with no args
run_unify 2>/dev/null
actual="$(jq -r '.source' "$SHARED_DIR/stats-cache.json" 2>/dev/null)"
assert_eq "new" "$actual" "newer stats-cache.json (2023-01-01) wins over older (2020-01-01)"

# ── 6. Security regressions (v1.7.8 / v1.7.9 hardening) ───────────────────────
# These lock in the injection / redaction fixes so they can never silently
# regress. The alias body is re-parsed by the shell when the alias is invoked,
# so a metacharacter in the provider id / config dir must be rejected at write.

cma_ensure_alias_file   # make sure $ALIAS_FILE exists for the not-contains checks

it "cma_provider_write_alias rejects a provider id with shell metacharacters (M-1)"
( cma_provider_write_alias "evilp" 'poe"; touch PWN_m1; echo "' >/dev/null 2>&1 ); assert_eq 1 $? "hostile provider id rejected"
assert_file_not_contains "$ALIAS_FILE" "PWN_m1" "hostile id never reaches the alias file"

it "cma_provider_write_alias still accepts a normal provider id (no over-rejection)"
( cma_provider_write_alias "poe2" "poe" >/dev/null 2>&1 ); assert_eq 0 $? "safe provider id accepted"
assert_file_contains "$ALIAS_FILE" "cma_run_provider poe" "safe provider alias written"

it "cma_write_alias rejects a config dir with shell metacharacters (M-2)"
( cma_write_alias "evild" '/a"; touch PWN_m2; echo "' >/dev/null 2>&1 ); assert_eq 1 $? "hostile config dir rejected"
assert_file_not_contains "$ALIAS_FILE" "PWN_m2" "hostile config dir never reaches the alias file"

it "cma_write_alias still accepts a normal config dir (no over-rejection)"
( cma_write_alias "wdok" "$HOME/.claude-wdok" >/dev/null 2>&1 ); assert_eq 0 $? "safe config dir accepted"
assert_file_contains "$ALIAS_FILE" "alias wdok=" "safe config alias written"

it "cma_enable_plugins enables ALL plugins when given 3+ (regression: jq --arg index)"
# The default always-on set has 4 plugins; a prior /2-vs-/3 index bug produced
# --arg names p0,p1,p3,p4 so $p2 was undefined and jq silently enabled NONE.
_ep="$SHARED_DIR/settings.json"; rm -f "$_ep"
cma_enable_plugins one two three four 2>/dev/null
assert_eq "4" "$(jq '.enabledPlugins|length' "$_ep" 2>/dev/null)" "all 4 plugins enabled (not 0)"
assert_eq "true" "$(jq -r '.enabledPlugins.three // "MISSING"' "$_ep" 2>/dev/null)" "the 3rd plugin (the broken index) is enabled"

if command -v python3 >/dev/null 2>&1; then
  it "providers_generate.py q() makes .env values injection-safe on source (M-3)"
  rm -f "$HOME/PWN_m3"
  line="$(python3 -c "
import importlib.util
s=importlib.util.spec_from_file_location('pg','$SCRIPTS_DIR/providers_generate.py')
m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
ev=chr(39)+'; touch PWN_m3; echo '+chr(39)
print([l for l in m.generate_env_content('p','','K','t','u',ev,'f','/c').splitlines() if l.startswith('CMA_PROVIDER_MODEL=')][0])
" 2>/dev/null)"
  ( cd "$HOME" && eval "$line" )    # sourcing the assignment must NOT run touch
  inj=1; [[ ! -f "$HOME/PWN_m3" ]] && inj=0; assert_eq 0 "$inj" "quoted .env value does not execute on source"
  rm -f "$HOME/PWN_m3"
fi

it "cma_redact_secrets redacts broadened secret shapes (H-1)"
# Source just the function out of the live verifier and feed it fakes.
eval "$(sed -n '/^cma_redact_secrets() {/,/^}/p' "$SCRIPTS_DIR/tests/verify_opencode_live.sh")"
# shellcheck disable=SC2016  # ${...} is intentionally a literal placeholder (test input), not expanded
red="$(printf '%s\n' \
  '"GOOGLE": "AIzaSyFAKE0000000000000000000000000000aa"' \
  '"HF": "hf_FAKE00000000000000000000000000000000"' \
  '"JWT": "eyJhFAKEAAAAAAAAAA.eyJzFAKEBBBBBBBBBB.sigFAKECCCCCCCCCC"' \
  '"keep": "${COCKROACHDB_PASSWORD}"' | cma_redact_secrets)"
ok=1; [[ "$red" != *AIzaSy* && "$red" != *hf_FAKE* && "$red" != *eyJhFAKE* ]] && ok=0
assert_eq 0 "$ok" "AIza / hf_ / JWT shapes all redacted"
ph="\${COCKROACHDB_PASSWORD}"   # literal placeholder, built without a single-quoted $
ok=1; [[ "$red" == *"$ph"* ]] && ok=0
assert_eq 0 "$ok" "\${...} placeholder preserved (not redacted)"

it "cma_redact_secrets redacts env-style JSON keys + tvly/nvapi prefixes (v1.14.0 leak fix)"
# Live-caught: opencode debug config embeds MCP env like
# {"environment": {"TAVILY_API_KEY": "tvly-dev-..."}} — the key NAME based
# filter missed it and the prefix list had no tvly-/nvapi-.
red2="$(printf '%s\n' \
  '"environment": {"TAVILY_API_KEY": "tvly-devFAKE00000000000000000000000000"}' \
  '"NVIDIA_API_KEY": "nvapi-FAKE0000000000000000000000000000000000"' \
  '"GITHUB_TOKEN": "ghp_FAKE000000000000000000000000000000"' \
  '"keep2": "${TAVILY_API_KEY}"' | cma_redact_secrets)"
ok=1; [[ "$red2" != *tvly-dev* && "$red2" != *nvapi-* && "$red2" != *ghp_FAKE* ]] && ok=0
assert_eq 0 "$ok" "env-style JSON key names + tvly-/nvapi-/ghp_ redacted"
ph2="\${TAVILY_API_KEY}"
ok=1; [[ "$red2" == *"$ph2"* ]] && ok=0
assert_eq 0 "$ok" "env-style \${...} placeholder preserved"

# ── B3. cma_provider_write_env _cma_q quoting ────────────────────────────────
# _cma_q wraps each value in single quotes and escapes embedded single quotes
# via the '\'' idiom.  Test both that a literal ' in a model name survives a
# source round-trip and that an injection payload does NOT execute on source.

it "cma_provider_write_env (B3): model name with literal single quote round-trips through source"
# Args: id keyvar transport base_url model fast_model config_dir
# cma_providers_dir() is hardcoded to $HOME/.local/share/... (not $SHARED_DIR),
# so we temporarily override it to write into a sandbox temp dir.
_b3_tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/cma.XXXXXX")"
_b3_orig_fn="$(declare -f cma_providers_dir 2>/dev/null)"
cma_providers_dir() { echo "$_b3_tmpdir"; }
_b3_env="$_b3_tmpdir/b3quote.env"
cma_provider_write_env "b3quote" "TESTKEY" "native" "https://api.test/v1" "model-with-'quote'" "" "$HOME/.claude-b3"
b3_actual="$(bash -c '. "$1"; printf "%s" "$CMA_PROVIDER_MODEL"' _ "$_b3_env" 2>/dev/null)"
assert_eq "model-with-'quote'" "$b3_actual" "_cma_q: single-quote in model name survives source round-trip"
eval "$_b3_orig_fn"

it "cma_provider_write_env (B3): injection payload in model name does not execute on source"
_b3_pwn="$HOME/PWN_b3"
rm -f "$_b3_pwn"
# Build the injection string without a heredoc so single/double quotes stay readable.
# The payload would close the single-quoted value and inject a shell command.
_b3_inject="x'; touch ${_b3_pwn}; echo '"
_b3_tmpdir2="$(mktemp -d "${TMPDIR:-/tmp}/cma.XXXXXX")"
cma_providers_dir() { echo "$_b3_tmpdir2"; }
cma_provider_write_env "b3inject" "TESTKEY" "native" "https://api.test/v1" "$_b3_inject" "" "$HOME/.claude-b3i"
_b3_env2="$_b3_tmpdir2/b3inject.env"
( bash -c '. "$1"' _ "$_b3_env2" ) 2>/dev/null
b3_inj=1; [[ ! -f "$_b3_pwn" ]] && b3_inj=0
assert_eq 0 "$b3_inj" "_cma_q injection payload does not execute on source"
rm -f "$_b3_pwn" "$_b3_tmpdir" "$_b3_tmpdir2"

# ── B5. cma_provider_write_env token-limit fields (v1.8.0 guard) ──────────────
# v1.8.0 added context_limit/max_output (args 8 & 9) so cma_run_provider can
# export CLAUDE_CODE_MAX_OUTPUT_TOKENS and never overshoot a provider's real
# context window. That data path shipped without a test; these assertions cover
# write_env's emission (value round-trip, "null"->empty, 7-arg back-compat) and
# confirm the consumer wiring is present in the emitted wrapper.
_b5_tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/cma.XXXXXX")"
cma_providers_dir() { echo "$_b5_tmpdir"; }

# b5_probe — read ONE variable out of an emitted .env by sourcing it, without
# the vacuous-pass shape these assertions used to have.
#
# The old form was `v="$(bash -c '. "$1"; printf "%s" "$VAR"' _ "$f" 2>/dev/null)"`
# followed by `assert_eq "" "$v"`. Every failure mode of the probe — env file
# never written, unreadable, syntactically broken, bash missing — produces
# EMPTY stdout, which is precisely the success condition, so the assertion
# passes having tested nothing. Two changes fix it:
#   * the source's failure becomes exit status 3 instead of silence, and
#   * the value is prefixed with a fixed "VAL:" sentinel, so "the variable is
#     empty" (VAL:) and "the probe never ran" ("") stop looking identical.
# Callers therefore assert a POSITIVE string and a zero exit status; there is
# no longer any assertion whose passing condition is "nothing came back".
# stderr is left ALONE (not redirected to /dev/null): a broken probe should be
# loud in the run log.
b5_probe() {   # <env-file> <var-name>  ->  "VAL:<value>" on stdout; rc 3 if unsourceable
  bash -c '. "$1" || exit 3; eval "printf \"VAL:%s\" \"\${$2-}\""' _ "$1" "$2"
}

it "cma_provider_write_env (B5): context_limit/max_output round-trip through source"
cma_provider_write_env "b5lim" "TESTKEY" "native" "https://api.test/v1" "model-x" "" "$HOME/.claude-b5" "262144" "32768"
b5_ctx="$(b5_probe "$_b5_tmpdir/b5lim.env" CMA_PROVIDER_CONTEXT_LIMIT)"; b5_ctx_rc=$?
b5_max="$(b5_probe "$_b5_tmpdir/b5lim.env" CMA_PROVIDER_MAX_OUTPUT)"; b5_max_rc=$?
assert_eq 0 "$b5_ctx_rc" "b5lim.env sources cleanly (the probe really ran)"
assert_eq 0 "$b5_max_rc" "b5lim.env sources cleanly for max_output too"
assert_eq "VAL:262144" "$b5_ctx" "CMA_PROVIDER_CONTEXT_LIMIT round-trips through source"
assert_eq "VAL:32768"  "$b5_max" "CMA_PROVIDER_MAX_OUTPUT round-trips through source"

it "cma_provider_write_env (B5): literal \"null\" normalizes to empty"
cma_provider_write_env "b5null" "TESTKEY" "native" "https://api.test/v1" "model-x" "" "$HOME/.claude-b5" "null" "null"
b5_ctxn="$(b5_probe "$_b5_tmpdir/b5null.env" CMA_PROVIDER_CONTEXT_LIMIT)"; b5_ctxn_rc=$?
b5_maxn="$(b5_probe "$_b5_tmpdir/b5null.env" CMA_PROVIDER_MAX_OUTPUT)"; b5_maxn_rc=$?
assert_eq 0 "$b5_ctxn_rc" "b5null.env sources cleanly (the probe really ran)"
assert_eq 0 "$b5_maxn_rc" "b5null.env sources cleanly for max_output too"
assert_eq "VAL:" "$b5_ctxn" "context_limit 'null' -> empty (no bogus value leaks into wrapper)"
assert_eq "VAL:" "$b5_maxn" "max_output 'null' -> empty (no bogus value leaks into wrapper)"

it "cma_provider_write_env (B5): omitted limits stay empty (7-arg back-compat)"
cma_provider_write_env "b5omit" "TESTKEY" "native" "https://api.test/v1" "model-x" "" "$HOME/.claude-b5"
b5_maxo="$(b5_probe "$_b5_tmpdir/b5omit.env" CMA_PROVIDER_MAX_OUTPUT)"; b5_maxo_rc=$?
assert_eq 0 "$b5_maxo_rc" "b5omit.env sources cleanly (the probe really ran)"
assert_eq "VAL:" "$b5_maxo" "omitted max_output stays empty"

it "cma_run_provider (B5): emitted wrapper exports CLAUDE_CODE_MAX_OUTPUT_TOKENS"
ALIAS_FILE="$_b5_tmpdir/aliases5.sh"
cma_ensure_alias_file 2>/dev/null || true
b5_wire=1; grep -q 'CLAUDE_CODE_MAX_OUTPUT_TOKENS' "$ALIAS_FILE" 2>/dev/null && b5_wire=0
assert_eq 0 "$b5_wire" "consumer wiring present: CMA_PROVIDER_MAX_OUTPUT -> CLAUDE_CODE_MAX_OUTPUT_TOKENS"
rm -rf "$_b5_tmpdir"

# ── B6. auto-session integration in the emitted wrappers + self-heal ──────────
# The per-project auto-session (claude-session flags/hint) lives INSIDE the
# cma_run / cma_run_provider bodies. A dropped integration would ship unnamed
# sessions undetected (the session-script's own unit tests can't see the
# wrapper), so assert the emitted bodies carry it — and that a stale cma_run
# missing the 'claude-session' marker self-heals on the next ensure (the trigger
# previously fired only on a missing 'unset ANTHROPIC_', so older wrappers never
# regained auto-session).
ALIAS_FILE="$SANDBOX_HOME/aliases_b6.sh"; mkdir -p "$(dirname "$ALIAS_FILE")"
rm -f "$ALIAS_FILE"; cma_ensure_alias_file
_b6_run="$(awk '/^cma_run\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE")"
_b6_prov="$(awk '/^cma_run_provider\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE")"

it "cma_run body wires per-project auto-session (claude-session flags + bare-launch guard + apply + hint)"
b6=1; grep -q 'claude-session' <<<"$_b6_run" && b6=0
assert_eq 0 "$b6" "cma_run calls claude-session"
b6=1; grep -q ' flags ' <<<"$_b6_run" && b6=0
assert_eq 0 "$b6" "cma_run uses 'claude-session flags'"
b6=1; grep -qF '$# -eq 0' <<<"$_b6_run" && b6=0
assert_eq 0 "$b6" "cma_run gates auto-session on a bare launch"
b6=1; grep -qF 'eval "set -- ' <<<"$_b6_run" && b6=0
assert_eq 0 "$b6" "cma_run applies the session flags (eval set --)"
b6=1; grep -qF ' hint ' <<<"$_b6_run" && b6=0
assert_eq 0 "$b6" "cma_run emits the per-alias color hint"

it "cma_run_provider body also wires per-project auto-session"
b6=1; grep -q 'claude-session' <<<"$_b6_prov" && b6=0
assert_eq 0 "$b6" "cma_run_provider calls claude-session"

it "self-heal: a cma_run missing the claude-session marker is regenerated"
# Outdated wrapper: cma_run HAS 'unset ANTHROPIC_' but LACKS 'claude-session'.
# The old trigger checked only the first marker, so it never regenerated.
rm -f "$ALIAS_FILE"; mkdir -p "$(dirname "$ALIAS_FILE")"
{
  printf '# Managed by claude-multi-account. Do not edit by hand.\n'
  printf 'export CLAUDE_BIN="/usr/bin/true"\n'
  printf 'cma_run() {\n'
  printf '  unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN\n'
  # shellcheck disable=SC2016  # literal alias-body text; $CLAUDE_BIN/$@ must NOT expand here
  printf '  "$CLAUDE_BIN" "$@"\n'
  printf '}\n'
  printf 'alias claude1="CLAUDE_CONFIG_DIR=%s/.claude-acct1 cma_run"\n' "$HOME"
} > "$ALIAS_FILE"
cma_ensure_alias_file
_b6_run2="$(awk '/^cma_run\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE")"
b6=1; grep -q 'claude-session' <<<"$_b6_run2" && b6=0
assert_eq 0 "$b6" "stale cma_run (no claude-session) was regenerated with auto-session"
b6=1; grep -q 'unset ANTHROPIC_' <<<"$_b6_run2" && b6=0
assert_eq 0 "$b6" "regenerated cma_run still has provider-env isolation"
b6_cnt="$(grep -c '^cma_run()' "$ALIAS_FILE")"
assert_eq 1 "$b6_cnt" "exactly one cma_run() after self-heal (no duplication)"
assert_file_contains "$ALIAS_FILE" "alias claude1=" "claude1 alias preserved through self-heal"

# ── B7. cma_resolve_claude_bin: find claude across per-host install locations ──
# npm's global prefix varies (~/.npm-global vs ~/.local vs Homebrew). A fixed
# ~/.local/bin default mis-points where `npm i -g` landed elsewhere, breaking
# every alias launch. The resolver must prefer explicit CLAUDE_BIN, then $PATH,
# then the known locations. (Regression for the amber.local rollout finding.)
it "cma_resolve_claude_bin: explicit CLAUDE_BIN wins verbatim"
b7="$(CLAUDE_BIN=/custom/path/claude cma_resolve_claude_bin)"
assert_eq "/custom/path/claude" "$b7" "explicit CLAUDE_BIN returned as-is"

it "cma_resolve_claude_bin: finds ~/.npm-global/bin/claude when not on PATH / not in ~/.local/bin"
# This is the amber.local scenario. ~/.npm-global/bin is checked before the
# system paths (/opt/homebrew, /usr/local), so a sandboxed HOME makes this
# deterministic regardless of whether the host has a system-path claude.
_b7h="$(mktemp -d "${TMPDIR:-/tmp}/cma.XXXXXX")"
mkdir -p "$_b7h/.npm-global/bin" "$_b7h/emptybin"
printf '#!/bin/sh\n' > "$_b7h/.npm-global/bin/claude"; chmod +x "$_b7h/.npm-global/bin/claude"
b7="$(unset CLAUDE_BIN; HOME="$_b7h" PATH="$_b7h/emptybin" cma_resolve_claude_bin)"
assert_eq "$_b7h/.npm-global/bin/claude" "$b7" "resolves the npm-global claude location"
# NOTE: the "nothing found anywhere -> ~/.local/bin fallback" branch is NOT
# hermetically testable — the resolver also checks the absolute system paths
# /opt/homebrew/bin and /usr/local/bin, which a sandboxed HOME/PATH can't mask
# (a host with a real /usr/local/bin/claude would correctly return that). The
# fallback is the trivial final printf; the load-bearing discovery logic is
# covered above.
rm -rf "$_b7h"

# ── B8. CLAUDE_BIN migration: rewrite a stale (non-executable) CLAUDE_BIN ──────
# Existing installs whose alias file points CLAUDE_BIN at a path that doesn't
# exist on THIS host (e.g. ~/.local/bin/claude where npm installed to
# ~/.npm-global/bin — the amber.local case) must self-heal so aliases launch.
it "cma_ensure_alias_file: stale non-executable CLAUDE_BIN is rewritten to a resolved claude"
_b8h="$(mktemp -d "${TMPDIR:-/tmp}/cma.XXXXXX")"
mkdir -p "$_b8h/.npm-global/bin" "$_b8h/emptybin" "$_b8h/.local/share/claude-multi-account"
printf '#!/bin/sh\n' > "$_b8h/.npm-global/bin/claude"; chmod +x "$_b8h/.npm-global/bin/claude"
_b8af="$_b8h/.local/share/claude-multi-account/aliases.sh"
# shellcheck disable=SC2016  # $HOME is a literal in the alias file, expanded at source time
{ printf '# Managed by claude-multi-account.\n'; printf 'export CLAUDE_BIN="$HOME/.local/bin/claude"\n'; } > "$_b8af"
(
  unset CLAUDE_BIN
  # Constrain PATH to system coreutils only (NOT the user dirs where claude
  # lives), so `command -v claude` misses and the resolver falls to the
  # ~/.npm-global location — while mktemp/sed/mv stay available for the rewrite.
  # shellcheck disable=SC2123  # deliberate, scoped to this subshell
  HOME="$_b8h"; PATH="/usr/bin:/bin"; ALIAS_FILE="$_b8af"; CMA_RC_FILES=()
  cma_ensure_alias_file
) >/dev/null 2>&1
_b8cb="$(grep -m1 '^export CLAUDE_BIN=' "$_b8af" | sed -E 's/^export CLAUDE_BIN="?//; s/"?$//')"
assert_eq "$_b8h/.npm-global/bin/claude" "$_b8cb" "stale CLAUDE_BIN rewritten to the resolved (npm-global) claude"
rm -rf "$_b8h"

# ── B8b. migration probe must not abort on an alias file with NO CLAUDE_BIN line ─
# lib.sh runs `set -euo pipefail`. The migration probe
# `_cur_cb="$(grep -m1 '^export CLAUDE_BIN=' "$ALIAS_FILE")"` returns 1 (no match)
# on an older/hand-edited alias file lacking that line, which aborted
# cma_ensure_alias_file mid-run (fixed with `|| _cur_cb=""`). EXECUTE the function.
it "cma_ensure_alias_file: no abort when the existing alias file lacks export CLAUDE_BIN"
_b8b="$(mktemp -d "${TMPDIR:-/tmp}/cma.XXXXXX")"
mkdir -p "$_b8b/.local/share/claude-multi-account"
_b8baf="$_b8b/.local/share/claude-multi-account/aliases.sh"
printf '# old alias file, no export CLAUDE_BIN line\nalias claude1=x\n' > "$_b8baf"
( unset CLAUDE_BIN; HOME="$_b8b"; ALIAS_FILE="$_b8baf"; CMA_RC_FILES=(); cma_ensure_alias_file ) >/dev/null 2>&1
assert_eq 0 $? "cma_ensure_alias_file completed (did not abort under set -e)"
rm -rf "$_b8b"

# ── B9. apply-color wired into both emitted wrappers (auto-color integration) ──
it "cma_run + cma_run_provider bodies call claude-session apply-color"
ALIAS_FILE="$SANDBOX_HOME/aliases_b9.sh"; mkdir -p "$(dirname "$ALIAS_FILE")"; rm -f "$ALIAS_FILE"
cma_ensure_alias_file
_b9_run="$(awk '/^cma_run\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE")"
_b9_prov="$(awk '/^cma_run_provider\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE")"
b9=1; grep -q 'apply-color' <<<"$_b9_run" && b9=0
assert_eq 0 "$b9" "cma_run calls apply-color"
b9=1; grep -q 'apply-color' <<<"$_b9_prov" && b9=0
assert_eq 0 "$b9" "cma_run_provider calls apply-color"

# --- harness integrity: every test file MUST end by calling `summary` --------
# run-all.sh decides pass/fail purely from each file's EXIT CODE (run-all.sh:30
# `if bash "$f"; then`). `summary` is what turns a non-zero TESTS_FAILED into a
# non-zero exit. A file missing it exits with its last command's status —
# usually 0 — so its failures are silently counted as a PASS.
# This really happened: test_providers.sh lacked `summary` and hid 5 real
# failures behind a green "27/27 ALL GREEN" run.
it "every test file ends by calling summary (else run-all.sh cannot see its failures)"
# Count what was swept as well as what was wrong. "No file is missing summary"
# is also the answer you get when the glob matched NOTHING (wrong TESTS_DIR, a
# renamed convention), so the emptiness of _missing_summary only means anything
# next to a positive _summary_seen.
_missing_summary=""; _summary_seen=0
for _tf in "$TESTS_DIR"/test_*.sh; do
  [[ -f "$_tf" ]] || continue
  _summary_seen=$((_summary_seen + 1))
  # `summary` must appear as a standalone command, not only in a comment.
  if ! grep -qE '^[[:space:]]*summary[[:space:]]*$' "$_tf"; then
    _missing_summary="$_missing_summary $(basename "$_tf")"
  fi
done
cond=1; (( _summary_seen >= 10 )) && cond=0
assert_eq 0 "$cond" "the summary sweep actually examined files ($_summary_seen test_*.sh)"
assert_eq "" "$_missing_summary" "no test file is missing its summary call"

# --- harness integrity: no SIGPIPE-prone `printf | grep -q` before an assert -
# `printf '%s\n' "$body" | grep -q PAT; assert_eq 0 $?` is a race: grep -q exits
# on first match and closes the pipe, so printf dies with SIGPIPE and the
# PIPELINE status is 141 (128+13), not grep's 0 — the assertion fails even
# though the pattern IS present. Whether it trips depends on how early the
# match lands, so it is a latent coin-flip that changes as bodies grow.
# Use a here-string (`grep -q PAT <<<"$body"`) instead: no pipe, no SIGPIPE.
#
# Two shapes carry the hazard, and the guard must recognise both:
#   S1  printf … | grep -q PAT; assert_eq 0 $? …     (status read on the next
#                                                    command)
#   S2  echo "$out" | grep -q PAT || assert_eq …     (status read by `||`)
# S2 is the same race through a different operator: under `set -o pipefail`
# (which these files set) the `||` sees the pipeline status, so a SIGPIPE'd
# echo yields 141 and the assert fires on a body that DOES contain PAT.
# Reproduced: a NEEDLE-first body of 500k lines gave 20/20 false failures for
# both shapes and 0/20 for the here-string form.
_SIGPIPE_RE='(printf|echo)[^|]*\|[[:space:]]*grep[^;]*(;|\|\|)[[:space:]]*assert'
# _sigpipe_scan FILE — 0 when FILE (comment lines ignored) has a hazard line.
# grep -v '^[[:space:]]*#' first: this file documents the bad pattern in a
# comment above, and the guard must not match its own explanation.
# Captured, then matched from a here-string — NOT `grep -v … | grep -q`: under
# pipefail that pipe is itself the race this guard exists to catch (grep -q
# exits on an early match, the upstream grep is SIGPIPE'd, the 141 reads as
# "no hit"), so a piped scan silently skips exactly the large files.
_sigpipe_scan() {
  local _body
  _body="$(grep -vE '^[[:space:]]*#' "$1")"
  grep -qE "$_SIGPIPE_RE" <<<"$_body"
}

# Fixtures are ASSEMBLED at runtime ($_G stands for the grep word) so the
# offending lines never appear literally in this file — the sweep below scans
# this file too, and a literal fixture would make it flag itself.
_G='grep'
_sp_dir="$SANDBOX_HOME/sigpipe_fixtures"; mkdir -p "$_sp_dir"
printf '%s\n' "printf '%s\\n' \"\$body\" | $_G -q PAT; assert_eq 0 \$? \"m\"" > "$_sp_dir/s1_printf_semicolon.sh"
printf '%s\n' "echo \"\$out\" | $_G -qi PAT || assert_eq \"has PAT\" \"missing\" \"m\"" > "$_sp_dir/s2_echo_oror.sh"
{
  printf '%s\n' "$_G -q PAT <<<\"\$out\" || assert_eq \"has PAT\" \"missing\" \"m\""
  printf '%s\n' "n=\"\$(echo \"\$out\" | jq -r .x)\"; assert_eq 1 \"\$n\" \"m\""
  printf '%s\n' "# echo \"\$out\" | $_G -q PAT || assert_eq a b c   (prose in a comment)"
} > "$_sp_dir/good_herestring.sh"

it "GUARD: the SIGPIPE guard flags shape S1 (printf piped to grep, then a separate assert)"
cond=1; _sigpipe_scan "$_sp_dir/s1_printf_semicolon.sh" && cond=0
assert_eq 0 "$cond" "S1 fixture: $(cat "$_sp_dir/s1_printf_semicolon.sh")"

it "GUARD: the SIGPIPE guard flags shape S2 (echo piped to grep, assert behind an or-list)"
cond=1; _sigpipe_scan "$_sp_dir/s2_echo_oror.sh" && cond=0
assert_eq 0 "$cond" "S2 fixture: $(cat "$_sp_dir/s2_echo_oror.sh")"

# The guard's OWN plumbing is exposed to the same race: a `grep -v | grep -q`
# under pipefail returns 141 once the match lands early in a file larger than
# the pipe buffer, and a 141 reads as "no hit". Observed: test_quota_cli.sh's
# S2 line was silently skipped that way. Plant one hazard line at the top of a
# >64 KiB body so a piped implementation would miss it.
{
  printf '%s\n' "echo \"\$out\" | $_G -q PAT || assert_eq \"has PAT\" \"missing\" \"m\""
  _i=0; while (( _i < 4000 )); do
    printf 'filler_line_%05d="padding the body past the pipe buffer"\n' "$_i"; _i=$((_i + 1))
  done
} > "$_sp_dir/s2_large_early.sh"

it "GUARD: the SIGPIPE guard flags an early hazard line in a file larger than the pipe buffer"
_sp_size="$(wc -c < "$_sp_dir/s2_large_early.sh" | tr -d ' ')"
cond=1; (( _sp_size > 65536 )) && cond=0
assert_eq 0 "$cond" "fixture really exceeds the 64 KiB pipe buffer ($_sp_size bytes)"
cond=1; _sigpipe_scan "$_sp_dir/s2_large_early.sh" && cond=0
assert_eq 0 "$cond" "large-file hazard is detected (the guard must not SIGPIPE itself)"

it "GUARD: the SIGPIPE guard does NOT flag the here-string form, a non-grep pipe, or a comment"
cond=0; _sigpipe_scan "$_sp_dir/good_herestring.sh" && cond=1
assert_eq 0 "$cond" "compliant fixture is clean (not a match-everything regex)"

it "no assertion reads \$? from a printf|grep pipeline (SIGPIPE gives 141, not 0)"
_sigpipe_hits=""; _sigpipe_seen=0
for _tf in "$TESTS_DIR"/test_*.sh; do
  [[ -f "$_tf" ]] || continue
  _sigpipe_seen=$((_sigpipe_seen + 1))
  if _sigpipe_scan "$_tf"; then
    _sigpipe_hits="$_sigpipe_hits $(basename "$_tf")"
  fi
done
# Same reasoning as the summary sweep: prove the sweep had input before
# treating "no hits" as good news.
cond=1; (( _sigpipe_seen >= 10 )) && cond=0
assert_eq 0 "$cond" "the SIGPIPE sweep actually examined files ($_sigpipe_seen test_*.sh)"
assert_eq "" "$_sigpipe_hits" "no SIGPIPE-prone assert pipelines remain"

summary
