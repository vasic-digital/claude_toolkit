#!/usr/bin/env bash
# test_quota_cli.sh — collision-regression guard for the quota/limits CLI
# command feature (specs/002-provider-usage-command). This is "the one
# guarantee the entire naming clarification rests on" (plan.md): the
# feature was deliberately named `quota`/`limits` instead of `usage`
# BECAUSE `usage` already collides with a real function name in both
# claude-providers.sh and kimi-providers.sh. This file proves, mechanically
# and against the files as they exist on disk TODAY:
#
#   1. The collision risk cited as the reason for the rename is real, not
#      a straw man — `usage()` already exists as a function in both files.
#   2. `quota` and `limits` are NOT already dispatch case-labels in either
#      of claude-providers.sh's two subcommand-gating case blocks, NOR in
#      kimi-providers.sh's own (structurally different) case block.
#   3. `quota` and `limits` are NOT already function names anywhere in
#      claude-providers.sh, kimi-providers.sh, or lib.sh.
#
# T012 (not yet started as of this writing) will add real `quota)` /
# `limits)` dispatch arms to claude-providers.sh and kimi-providers.sh.
# This file is the PRE-T012 baseline: everything here is expected to pass
# right now, and T012's own follow-up test additions are responsible for
# proving the feature stays collision-free once it exists.
#
# Structural note on claude-providers.sh: it gates subcommand names in TWO
# separate case blocks, not one — `case "${1:-}" in ...` (does $1 even get
# recognized as a subcommand at all?) and `case "$SUBCMD" in ...` (the real
# per-command dispatch). Both must be checked; a name absent from one but
# present in the other is still a collision.
#
# Structural note on kimi-providers.sh: investigated directly for this
# task. It is genuinely a thin wrapper (143 lines total) with its own
# SINGLE `case "$SUBCMD" in ... esac` block (lines ~65-71; same anchor text
# as claude-providers.sh's block 2), but its shape is NOT an enumerated
# allowlist of every valid subcommand name the way claude-providers.sh's
# two blocks are. Its only arms are `""|-h|--help`, `list|list-all|list-faulty`,
# and a catch-all `*) exec "$ENGINE" "$@" ;;` that forwards every other
# subcommand name — including, today, `quota`/`limits` once T012 adds
# them — verbatim to the claude-providers.sh engine. It IS still a real
# case block that a T012 edit could add a `quota)`/`limits)` arm to
# directly (rather than relying on the catch-all forward), so it is
# checked below (assertion 6) via `_extract_kimi_block_names`, once the
# shared extraction logic handles `|`-alternation arms (review round 1,
# Issue 3) rather than assuming one bare `name)` per line. What ALSO
# matters for kimi-providers.sh is covered at the FUNCTION-name level
# (assertions 1, 2, and 5), which is exactly where kimi-providers.sh's
# real `usage()` function lives and where a future `quota`/`limits`
# FUNCTION (as opposed to case arm) would collide.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
set +e   # lib assertion helpers; no lib.sh function call in this file.

# --- extraction helpers -----------------------------------------------------
#
# All three case-block extractors share the same robustness requirements
# (review round 1 findings, fixed here):
#   - Read EVERY label line in the block's range, not just the first — a
#     name added as a brand-new line (rather than edited into an existing
#     compound line) must still be visible.
#   - Allow `|` in the captured character class, so a multi-name alternation
#     arm (e.g. `quota|limits) cmd_quota ;;`) is captured whole, THEN split
#     on `|` into one name per output line — never require the whole block
#     to be a single compound line.
#   - Strip leading whitespace AND the trailing `)` via one `sed`, not
#     `tr -d ')'` alone — `tr -d` only removes the `)` byte and leaves
#     leading spaces in place, which silently defeats `grep -qx` equality
#     checks against the first captured label (reproduced against the real
#     file pre-fix: the block 1 extractor emitted "  sync" instead of
#     "sync", so `grep -qx sync` against its own output failed even though
#     `sync` genuinely is the first name in the block).
#   - A case-arm BODY line (e.g. a continuation line inside a multi-line
#     `sync)` arm, or a `#`-comment line) must NOT match: the character
#     class excludes `#`/quotes/`$`/`{`/`"`/space, and the match requires
#     the captured run to be followed IMMEDIATELY by `)` — a body line like
#     `cmd_add "${POSITIONAL[@]:-}" ;;` has no `)` immediately after a
#     leading identifier run, so it correctly produces no match.

# Block 1: case "${1:-}" in ... esac — the early arg-sniffing block that
# decides whether $1 is even recognized as a subcommand name at all. On the
# real claude-providers.sh, this is a single compound alternation line
# listing every valid subcommand name — but the extractor does not assume
# that shape; it reads every label line in the block.
_extract_block1_names() {
  sed -n '/^case "\${1:-}" in$/,/^esac$/p' "$1" \
    | grep -oE '^[[:space:]]*[a-zA-Z0-9_|-]+\)' \
    | sed -E 's/^[[:space:]]+//; s/\)$//' \
    | tr '|' '\n'
}

# Block 2: case "$SUBCMD" in ... esac — claude-providers.sh's main
# per-command dispatch.
_extract_block2_names() {
  sed -n '/^case "\$SUBCMD" in$/,/^esac$/p' "$1" \
    | grep -oE '^[[:space:]]*[a-zA-Z0-9_|-]+\)' \
    | sed -E 's/^[[:space:]]+//; s/\)$//' \
    | tr '|' '\n'
}

# kimi-providers.sh's OWN case "$SUBCMD" in ... esac block (lines ~65-71).
# Same anchor text as claude-providers.sh's block 2, but a structurally
# different (thin-forwarder) body — see the file header note. Same
# extraction logic applies verbatim once `|`-alternation is handled, so this
# is a distinct function only because it targets a different file/anchor
# instance, not different logic.
_extract_kimi_block_names() {
  sed -n '/^case "\$SUBCMD" in$/,/^esac$/p' "$1" \
    | grep -oE '^[[:space:]]*[a-zA-Z0-9_|-]+\)' \
    | sed -E 's/^[[:space:]]+//; s/\)$//' \
    | tr '|' '\n'
}

# Every bash function name defined at column 0 (top-level, not nested) in a
# given file. `[[:space:]]` (not `\s`, a GNU extension) for BSD/GNU
# portability per this project's own CLAUDE.md.
_extract_func_names() {
  grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(\)[[:space:]]*\{' "$1" \
    | sed -E 's/[[:space:]]*\(\)[[:space:]]*\{//'
}

# --- assertions, in the exact required order --------------------------------

it "usage already exists as a real function in claude-providers.sh (proves this is a real collision risk, not a straw man)"
funcs_claude="$(_extract_func_names "$SCRIPTS_DIR/claude-providers.sh")"
if echo "$funcs_claude" | grep -qx "usage"; then
  assert_eq "1" "1" "usage() exists in claude-providers.sh today"
else
  assert_eq "1" "0" "usage() NOT found in claude-providers.sh -- the collision risk this test guards against may not be real; investigate before trusting this test"
fi

it "usage already exists as a real function in kimi-providers.sh (same proof, second file)"
funcs_kimi="$(_extract_func_names "$SCRIPTS_DIR/kimi-providers.sh")"
if echo "$funcs_kimi" | grep -qx "usage"; then
  assert_eq "1" "1" "usage() exists in kimi-providers.sh today"
else
  assert_eq "1" "0" "usage() NOT found in kimi-providers.sh -- investigate before trusting this test"
fi

# NOTE (T012): these two assertions originally (T011) asserted quota/limits
# were ABSENT from both dispatch blocks -- the pre-T012 RED baseline. T012
# (per tasks.md's own description of this task: "re-run the same enumeration,
# assert quota and limits now EACH appear ... in the case-label list") wires
# the real dispatch arms, so they are updated in place to assert PRESENCE
# instead -- a permanently-failing "must stay absent" assertion would make
# this very file red forever once the feature it exists to gate is actually
# built, which contradicts the TDD RED-then-GREEN contract T011/T012 together
# form. The dedicated per-block/per-name assertions below (and the `usage`
# recheck) give this the same "both blocks, not just one" rigor T011 had.
it "quota is present as a case-label in at least one claude-providers.sh dispatch block (and non-colliding)"
b1="$(_extract_block1_names "$SCRIPTS_DIR/claude-providers.sh")"
b2="$(_extract_block2_names "$SCRIPTS_DIR/claude-providers.sh")"
if echo "$b1" | grep -qx "quota" || echo "$b2" | grep -qx "quota"; then
  assert_eq "present" "present" "quota is now wired into claude-providers.sh's dispatch (post-T012 state)"
else
  assert_eq "present" "absent" "quota must now be a dispatch case label -- T012 was supposed to add it"
fi

it "limits is present as a case-label in at least one claude-providers.sh dispatch block (and non-colliding)"
if echo "$b1" | grep -qx "limits" || echo "$b2" | grep -qx "limits"; then
  assert_eq "present" "present" "limits is now wired into claude-providers.sh's dispatch (post-T012 state)"
else
  assert_eq "present" "absent" "limits must now be a dispatch case label -- T012 was supposed to add it"
fi

it "neither quota nor limits is already a function name in claude-providers.sh, kimi-providers.sh, or lib.sh"
funcs_lib="$(_extract_func_names "$SCRIPTS_DIR/lib.sh")"
all_funcs="$funcs_claude
$funcs_kimi
$funcs_lib"
collision=0
echo "$all_funcs" | grep -qx "quota" && collision=1
echo "$all_funcs" | grep -qx "limits" && collision=1
assert_eq "0" "$collision" "quota/limits must not already exist as function names anywhere in the three files"

# Review round 1, Issue 3: once the shared extractor logic above correctly
# handles `|`-alternation (not just one bare name per line), it generalizes
# cheaply to kimi-providers.sh's own case "$SUBCMD" in block too (its arms
# are `""|-h|--help)`, `list|list-all|list-faulty)`, and a catch-all `*)` —
# see the file header note on why this is NOT the same shape as
# claude-providers.sh's two blocks, but it IS a real case block that a
# future T012 edit could add a `quota)`/`limits)` arm to, so it must be
# checked too.
it "quota/limits is not yet a case-label in kimi-providers.sh's own dispatch block"
bk="$(_extract_kimi_block_names "$SCRIPTS_DIR/kimi-providers.sh")"
collision=0
echo "$bk" | grep -qx "quota" && collision=1
echo "$bk" | grep -qx "limits" && collision=1
assert_eq "0" "$collision" "quota/limits must not already be a case label in kimi-providers.sh's own dispatch block"

# --- T012: per-block granularity on top of the combined check above ---------
#
# The combined assertions just above prove quota/limits landed in AT LEAST
# ONE of the two dispatch blocks. That alone is not enough: a name present in
# only one of the two would still misroute `claude-providers quota` (block 1
# decides whether $1 is even recognized as a subcommand at all; block 2 is
# the real per-command dispatch). These assertions check EACH block
# separately so a half-wired edit (only block 1, or only block 2) is caught.
# usage() is also re-checked to prove this task left the pre-existing
# collision risk untouched.

it "quota is present as a case-label in block 1 (the early arg-sniff alternation)"
b1="$(_extract_block1_names "$SCRIPTS_DIR/claude-providers.sh")"
echo "$b1" | grep -qx "quota" && found=1 || found=0
assert_eq "1" "$found" "quota must now be recognized in block 1 so \$1 is shifted into SUBCMD"

it "quota is present as a case-label in block 2 (the real dispatch)"
b2="$(_extract_block2_names "$SCRIPTS_DIR/claude-providers.sh")"
echo "$b2" | grep -qx "quota" && found=1 || found=0
assert_eq "1" "$found" "quota must now have its own dispatch arm"

it "limits is present as a case-label in block 1"
echo "$b1" | grep -qx "limits" && found=1 || found=0
assert_eq "1" "$found" "limits must now be recognized in block 1"

it "limits is present as a case-label in block 2"
echo "$b2" | grep -qx "limits" && found=1 || found=0
assert_eq "1" "$found" "limits must now have its own dispatch arm"

it "usage is UNCHANGED -- still a real function, still present"
funcs="$(_extract_func_names "$SCRIPTS_DIR/claude-providers.sh")"
echo "$funcs" | grep -qx "usage" && found=1 || found=0
assert_eq "1" "$found" "usage() must be untouched by this task"

# --- T012: cmd_quota() argument-parsing tests --------------------------------
#
# cmd_quota does its own flag parsing. Source claude-providers.sh the same way
# test_render_config_base_null.sh does: directly (it sources lib.sh itself),
# then set +e since both files set -e. The top-level arg-parsing block runs
# with this test script's own (empty) "$@" on source, and the final dispatch
# is skipped by the BASH_SOURCE==$0 source-guard, so sourcing is safe here.

# shellcheck source=../claude-providers.sh
source "$SCRIPTS_DIR/claude-providers.sh"
set +e   # claude-providers.sh (and the lib.sh it sources) set -e; this
         # harness asserts on failures rather than aborting on the first one.

# NOTE (T022): these assertions originally (T012) proved flag-parsing by
# grepping the stub body's single `cma_log "quota: alias=... json=... ..."`
# line -- the only output that stub ever produced. T022 replaces that stub
# body with the real probe-then-render pipeline (_cma_quota_probe_all ->
# _cma_quota_render_json|_cma_quota_render_text), which does not log the
# parsed values at all, so that introspection point is gone. The flag-parsing
# loop itself is UNCHANGED (T022 only touches the body after it), so these
# assertions now prove the same parsing continues to work correctly by
# observing it through the real downstream effect each flag controls: a
# clean exit code (no flag crashes or hangs the pipeline) and, for --json,
# an actually well-formed JSON document. No provider/account fixtures are
# configured in the sandbox yet at this point in the file, so the probe
# step legitimately finds zero rows -- that is fine here; it is exactly the
# "produces well-formed output even with nothing to report" shape the two
# new end-to-end wiring tests at the bottom of this file test more fully,
# once this file's own T013/T014 fixtures are in place.

it "cmd_quota with no args: exit 0"
out="$(cmd_quota 2>&1)"; rc=$?
assert_eq "0" "$rc" "cmd_quota with no args returns 0"

it "cmd_quota <unconfigured-alias>: returns 2 (unknown alias, correctly scoped per T025)"
out="$(cmd_quota myalias 2>&1)"; rc=$?
assert_eq "2" "$rc" "cmd_quota with an unconfigured positional alias must return 2 (T025 wires alias scoping)"

it "cmd_quota --json: produces valid, well-formed JSON"
out="$(cmd_quota --json 2>&1)"
echo "$out" | jq -e . >/dev/null 2>&1
assert_eq "0" "$?" "--json output parses as valid JSON"

it "cmd_quota --fresh: flag accepted, pipeline still completes cleanly"
out="$(cmd_quota --fresh 2>&1)"; rc=$?
assert_eq "0" "$rc" "--fresh parsed and forwarded to _cma_quota_probe_all without error"

it "cmd_quota --timeout 30: flag + value accepted, pipeline still completes cleanly"
out="$(cmd_quota --timeout 30 2>&1)"; rc=$?
assert_eq "0" "$rc" "--timeout value captured and forwarded to _cma_quota_probe_all without error"

it "cmd_quota --no-color: text renderer invoked with --no-color, no error, no ANSI escapes in output"
out="$(cmd_quota --no-color 2>&1)"; rc=$?
assert_eq "0" "$rc" "--no-color parsed and forwarded to _cma_quota_render_text without error"
case "$out" in *$'\033'*) found=1 ;; *) found=0 ;; esac
assert_eq "0" "$found" "--no-color output contains no raw ANSI escape bytes"

it "cmd_quota --json myalias --fresh: positional + multiple flags together, any order, still returns rc=2 + valid JSON for an unknown alias"
out="$(cmd_quota --json myalias --fresh 2>&1)"; rc=$?
ok=0
[[ "$rc" == "2" ]] && echo "$out" | jq -e . >/dev/null 2>&1 && ok=1
assert_eq "1" "$ok" "positional and flags combine correctly regardless of order, unknown alias still returns 2 with valid JSON"

it "cmd_quota --bogus-flag: unrecognized flag returns 1, not exit"
out="$(cmd_quota --bogus-flag 2>&1)"; rc=$?
assert_eq "1" "$rc" "unknown flag returns 1 (not an exit that would kill the test runner -- proven by the fact this line runs at all)"

# --- T013: failing test for _cma_quota_group_accounts (not yet implemented) ----
#
# Task 13 introduces the NOT-YET-EXISTING bash function _cma_quota_group_accounts.
# This test demonstrates the function's required behavior by setting up a fixture
# with one provider (.env file) and multiple alias lines referencing it (simulating
# cross-family sharing), then invoking the function and checking its output shape.
#
# The fixture models the real cross-family sharing mechanism discovered at
# claude-providers.sh:2732 and :2747 — ONE .env file per account, PLUS MULTIPLE
# alias lines in $ALIAS_FILE, each naming the SAME provider id as its argument,
# but calling different family wrapper functions. The function's job is to group
# these aliases by provider_id and produce one JSON record per account.

it "_cma_quota_group_accounts groups deepseek + kimi-deepseek into ONE provider-account record"
pdir="$(cma_providers_dir)"; mkdir -p "$pdir"
cma_provider_write_env deepseek DEEPSEEK_API_KEY router \
  "https://api.deepseek.com/v1" deepseek-chat deepseek-chat \
  "$HOME/.claude-prov-deepseek" 128000 8192 deepseek

cat > "$ALIAS_FILE" <<'EOF'
alias deepseek="cma_run_provider deepseek"
alias kimi-deepseek="cma_run_kimi_provider deepseek"
EOF

out="$(_cma_quota_group_accounts)"
# Exactly one JSON line for provider_id=deepseek (not two, not zero).
count="$(echo "$out" | jq -r 'select(.provider_id=="deepseek")' | jq -s 'length')"
assert_eq "1" "$count" "exactly one record for the deepseek provider account"
# That one record's alias_names lists BOTH alias names.
names="$(echo "$out" | jq -r 'select(.provider_id=="deepseek") | .alias_names[]' | sort | tr '\n' ',')"
assert_eq "deepseek,kimi-deepseek," "$names" "alias_names covers both the bare and the kimi-twin alias"

# --- T014: failing test for _cma_quota_list_native_accounts (not yet implemented) ----
#
# Task 14 introduces the NOT-YET-EXISTING bash function _cma_quota_list_native_accounts.
# This test demonstrates the function's required behavior: listing EVERY configured
# native account separately, never merging/de-duplicating them. The fixture creates
# two account-dir skeletons using make_account, then overwrites each .claude.json
# with a specific organizationRateLimitTier value to simulate the cached tier data.

it "_cma_quota_list_native_accounts returns TWO separate entries for claude1 and claude2 -- never merged"
dir1="$(make_account claude1)"
cat > "$dir1/.claude.json" <<'EOF'
{"oauthAccount": {"organizationRateLimitTier": "default_claude_pro"}}
EOF

dir2="$(make_account claude2)"
cat > "$dir2/.claude.json" <<'EOF'
{"oauthAccount": {"organizationRateLimitTier": "default_claude_max_20x"}}
EOF

out="$(_cma_quota_list_native_accounts)"
count="$(echo "$out" | jq -s 'length')"
assert_eq "2" "$count" "two native accounts must produce two separate rows, never de-duplicated"

it "_cma_quota_list_native_accounts: claude1's plan_tier comes from claude1's own .claude.json"
tier1="$(echo "$out" | jq -r 'select(.account_id | endswith("claude1")) | .plan_tier')"
assert_eq "default_claude_pro" "$tier1" "claude1's own cached tier is read correctly"

it "_cma_quota_list_native_accounts: claude2's plan_tier comes from claude2's own .claude.json (different value, proving no cross-contamination)"
tier2="$(echo "$out" | jq -r 'select(.account_id | endswith("claude2")) | .plan_tier')"
assert_eq "default_claude_max_20x" "$tier2" "claude2's own cached tier is read correctly, and differs from claude1's -- proving neither account's value leaked into the other"

# --- T022: end-to-end cmd_quota() wiring tests -------------------------------
#
# T022 wires cmd_quota() to actually call _cma_quota_probe_all (T017) and
# render with _cma_quota_render_json (T021) / _cma_quota_render_text (T019)
# instead of just logging what it parsed. These two tests prove the wiring
# genuinely produces output end to end, reusing the fixtures the T013/T014
# tests above already set up in this same sandbox: the `deepseek` provider
# (a real .env, but with NO entry in providers/quota-endpoints.json, so it
# resolves honestly to `not_reported_by_provider` with no network call) and
# the `claude1`/`claude2` native accounts. No mock HTTP server needed.

it "cmd_quota (text mode) produces non-empty output for a minimal fixture"
out="$(cmd_quota 2>&1)"
[[ -n "$out" ]] && ok=1 || ok=0
assert_eq "1" "$ok" "cmd_quota with no args produces some output, not silence"

it "cmd_quota --json produces valid JSON for the same fixture"
out_json="$(cmd_quota --json 2>&1)"
echo "$out_json" | jq -e . >/dev/null 2>&1
assert_eq "0" "$?" "cmd_quota --json's output is valid JSON"

# --- T023: failing tests for alias-scoped cmd_quota <alias> (not yet implemented) ----
#
# cmd_quota already PARSES a positional alias_arg (see the comment right above
# the `local result` line in cmd_quota, and the T012 "scoping deferred to
# Phase 4" assertion earlier in this file) but currently ignores it entirely:
# it always probes and renders every configured account/provider regardless
# of what alias_arg holds, and always returns 0 -- even for an alias that was
# never configured anywhere. T025 (Phase 4 / User Story 2) is the task that
# will make cmd_quota actually honor alias_arg: scope the probe/render to
# just that one account, exit 2 for an unknown alias, and report
# unknown_alias:true/"does not exist" instead of silently succeeding.
#
# Fixture: reuses "deepseek", the real provider-account alias T013 already
# configured earlier in this same sandbox/file (one .env under
# cma_providers_dir, plus `alias deepseek="cma_run_provider deepseek"` and
# `alias kimi-deepseek="cma_run_kimi_provider deepseek"` written into
# $ALIAS_FILE) -- the cleanest already-real, currently-configured alias name
# in this file, per the task brief's instruction to substitute whatever
# fixture actually exists rather than inventing one.

it "cmd_quota deepseek --json: scoped_to is set, rows has at most one entry"
out="$(cmd_quota deepseek --json 2>&1)"
scoped="$(echo "$out" | jq -r '.scoped_to' 2>/dev/null)"
assert_eq "deepseek" "$scoped" "scoped_to must name the requested alias (currently stays null -- alias_arg is parsed but not yet wired to scope anything)"
n="$(echo "$out" | jq '.rows | length' 2>/dev/null)"
le1=0; (( n <= 1 )) && le1=1
assert_eq "1" "$le1" "a scoped request must return at most one row (currently returns every configured account/provider row, unscoped)"

it "cmd_quota this-alias-does-not-exist-xyz123: exit code 2"
cmd_quota this-alias-does-not-exist-xyz123 >/dev/null 2>&1
rc=$?
assert_eq "2" "$rc" "an unknown alias must exit 2, never 0 and never a crash (currently always returns 0 regardless of alias_arg)"

it "cmd_quota this-alias-does-not-exist-xyz123 --json: unknown_alias true, rows empty"
out2="$(cmd_quota this-alias-does-not-exist-xyz123 --json 2>&1)"
unk="$(echo "$out2" | jq -r '.unknown_alias' 2>/dev/null)"
assert_eq "true" "$unk" "unknown_alias must be true for an alias nothing configured (currently always stays false)"
n2="$(echo "$out2" | jq '.rows | length' 2>/dev/null)"
assert_eq "0" "$n2" "rows must be empty for an unknown alias (currently returns every row, unscoped, regardless of alias_arg)"

it "cmd_quota this-alias-does-not-exist-xyz123 (text mode): states plainly the alias does not exist"
out3="$(cmd_quota this-alias-does-not-exist-xyz123 2>&1)"
echo "$out3" | grep -qi "does not exist" || assert_eq "contains 'does not exist'" "missing" "FR-003: never silent, never a bare crash (currently prints the full unscoped fleet report instead)"

# --- T028: no-probe-attempt test for a no-endpoint-spec provider ------------
#
# Regression-confirming test (T017 already built the endpoint_spec_present
# short-circuit in _cma_quota_probe_all) -- NOT a RED-then-GREEN pair. It
# proves, mechanically, that a provider ABSENT from quota-endpoints.json
# never causes a live-probe subprocess to be launched at all.
#
# tasks.md's literal text says "stub curl" -- that does not match the real
# implementation. quota_probe.py's http_get_json (reused from
# model_verify.py) uses Python's urllib.request.urlopen, never curl, so
# stubbing curl would prove nothing (it is genuinely never invoked). The
# real subprocess _cma_quota_probe_all launches for a live probe is
# `python3 "$lib_dir/quota_probe.py" --provider-id ...` (and, before that, a
# `python3 -c "..."` cache-check call for any spec-present provider) -- this
# stub intercepts python3 instead.
#
# Critical gotcha avoided: the stub does NOT `exec python3 "$@"` (which
# would re-enter PATH resolution and could hit the SAME stub again). The
# REAL python3's absolute path is resolved via `command -v python3` BEFORE
# the stub is installed, and that absolute path is baked directly into the
# stub script body, so the stub delegates to the genuine interpreter after
# logging -- every OTHER test in this file, before and after this block,
# keeps running against the real python3, completely unaffected.
#
# Fixtures:
#   - "deepseek": already configured earlier in this file (T013) with a
#     real .env + alias line, and genuinely ABSENT from
#     quota-endpoints.json -- reused here, per the task brief, as the
#     no-endpoint-spec provider rather than inventing a duplicate fixture.
#   - "openrouter": newly added here, WITH a real quota-endpoints.json
#     entry (the only entry the file documents today) -- set up so the
#     stub's log can be checked for genuine traffic, proving the "zero
#     calls for deepseek" assertion isn't trivially true because the stub
#     was never wired into the call path at all.
#
# REVIEW ROUND 1 FIX: openrouter's quota-endpoints.json entry points at
# the real https://openrouter.ai, and the first version of this test let
# _cma_quota_probe_all's LIVE-probe branch run for it unmocked -- a real
# outbound HTTPS request, which this project's own convention forbids in a
# unit test (research.md Section 8: "never a real network call in a unit
# test", and this very file already documents the same rule for its T022
# fixtures a few dozen lines above: "no network call" / "no mock HTTP
# server needed"). The fix pre-seeds quota-cache.json with a valid,
# non-expired cache record for openrouter BEFORE calling
# _cma_quota_probe_all, so the CACHED branch
# (scripts/claude-providers.sh's `if [[ -n "$cached" ]]` arm) is taken
# instead of the live-probe one -- pure jq, zero subprocesses, zero
# network. The SYNCHRONOUS cache-check call (the `python3 -c "..."`
# one-liner that reads this very cache file) still genuinely runs and
# still logs a line naming "openrouter" through the stub, so the
# non-vacuous "stub observed real traffic" proof survives unchanged; only
# the network-touching live-probe subprocess is removed from the picture.

it "T028 setup: openrouter provider fixture (HAS a quota-endpoints.json entry)"
pdir="$(cma_providers_dir)"; mkdir -p "$pdir"
cma_provider_write_env openrouter OPENROUTER_API_KEY router \
  "https://openrouter.ai/api/v1" "openrouter/test-model" "openrouter/test-model" \
  "$HOME/.claude-prov-openrouter" 128000 8192 openrouter
cat >> "$ALIAS_FILE" <<'EOF'
alias openrouter="cma_run_provider openrouter"
EOF
assert_file "$pdir/openrouter.env" "openrouter.env fixture written"

it "T028 setup: openrouter's quota cache is pre-seeded with a fresh, non-expired record (so the probe takes the CACHED branch, never the network-touching live one)"
cache_file="$HOME/.local/share/claude-multi-account/quota-cache.json"
mkdir -p "$(dirname "$cache_file")"
now_ts="$(date +%s)"
jq -n --argjson now "$now_ts" '{
  _cache_version: 1,
  _cached_at: $now,
  providers: {
    openrouter: {
      provider_id: "openrouter",
      windows: [
        {window:"subscription", amount_used:10, amount_remaining:90, limit_total:100,
         unit:"credits", percent_remaining:90.0, resets:false, reset_at:null}
      ],
      account_blocked: false,
      absence_reason: null,
      http_status: 200,
      _cached_at: $now
    }
  }
}' > "$cache_file"
assert_file "$cache_file" "quota-cache.json pre-seeded"

it "T028: the real python3 absolute path resolves before any stub is installed"
real_python3="$(command -v python3)"
[[ -n "$real_python3" && -x "$real_python3" ]] && found=1 || found=0
assert_eq "1" "$found" "a real python3 binary must be found on PATH before the stub can delegate to it"

# Install the scoped stub: a fresh directory (not $HOME/.local/bin, so there
# is no production symlink to clobber) prepended to PATH for THIS TEST ONLY.
# It logs every invocation's argv, then execs the baked-in absolute path --
# never the bare name "python3" -- so it cannot recursively re-enter itself.
stub_dir="$HOME/.quota-stub-bin"
stub_log="$HOME/.quota-stub-python3.log"
: > "$stub_log"
sandbox_stub "$stub_dir/python3" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$stub_log"
exec "$real_python3" "\$@"
STUBEOF

old_path="$PATH"
export PATH="$stub_dir:$PATH"

probe_out="$(_cma_quota_probe_all 0 "" 2>&1)"
probe_rc=$?

# Restore PATH immediately -- scoped to just this test, per the brief, so
# every later test in this file runs against the genuine python3 again.
export PATH="$old_path"
rm -rf "$stub_dir"

it "T028: _cma_quota_probe_all still completes cleanly with the stub installed"
assert_eq "0" "$probe_rc" "probe orchestration must not error out merely because python3 was intercepted"

it "T028: deepseek's row reports absence_reason=not_reported_by_provider"
ds_absence="$(echo "$probe_out" | jq -r 'select(.provider_id=="deepseek") | .absence_reason')"
assert_eq "not_reported_by_provider" "$ds_absence" "deepseek (no quota-endpoints.json entry) must report the honest absence reason"

it "T028: deepseek's row reports windows=[]"
ds_windows="$(echo "$probe_out" | jq -c 'select(.provider_id=="deepseek") | .windows')"
assert_eq "[]" "$ds_windows" "deepseek's windows must stay empty -- never estimated/inferred"

it "T028: zero python3 subprocess calls name deepseek as a --provider-id argument"
ds_calls="$(grep -c -- '--provider-id deepseek' "$stub_log" 2>/dev/null)"
[[ -z "$ds_calls" ]] && ds_calls=0
assert_eq "0" "$ds_calls" "the no-endpoint-spec provider must short-circuit entirely -- no live-probe subprocess, ever"

it "T028: the stub observed REAL traffic -- openrouter's id appears at least once in the log (proves the stub is live, not vacuously silent)"
or_calls="$(grep -c -- 'openrouter' "$stub_log" 2>/dev/null)"
[[ -z "$or_calls" ]] && or_calls=0
at_least_one=0; (( or_calls >= 1 )) && at_least_one=1
assert_eq "1" "$at_least_one" "openrouter (a real quota-endpoints.json entry) must trigger at least one logged python3 invocation"

it "T028: openrouter's row came from the CACHE, not a live probe (data_source=cached, absence_reason=null)"
or_src="$(echo "$probe_out" | jq -r 'select(.provider_id=="openrouter") | .data_source')"
assert_eq "cached" "$or_src" "openrouter must resolve via the pre-seeded cache record, not a fresh network probe"
or_absence="$(echo "$probe_out" | jq -r 'select(.provider_id=="openrouter") | .absence_reason')"
assert_eq "null" "$or_absence" "the cached record's success (absence_reason=null) must round-trip, proving the real cache record was read"

it "T028: no python3 subprocess call ever named openrouter as a --provider-id argument (the live-probe/network path never ran)"
or_live_calls="$(grep -c -- '--provider-id openrouter' "$stub_log" 2>/dev/null)"
[[ -z "$or_live_calls" ]] && or_live_calls=0
assert_eq "0" "$or_live_calls" "the live-probe subprocess (the only one that would touch the real network) must never be launched when a fresh cache record exists"

# --- T029: a real absence_detail for probe_failed results -------------------
#
# A real gap: `absence_detail` is required (by this task's spec) to be a
# NON-EMPTY string naming the real failure for a probe_failed result, but
# nothing in the pipeline populates it today -- quota_probe.py's
# probe_provider() failure branch returns only absence_reason/http_status,
# _cma_quota_probe_all never extracts/forwards a detail string, and
# _cma_quota_render_json hardcodes absence_detail:null unconditionally. This
# block proves the gap, then (once the fix lands in production code) proves
# it closed.
#
# Fixture: a NEW provider id ("quota-fixture-unreachable") whose
# quota-endpoints.json entry points at an intentionally-unreachable LOCAL
# address, http://127.0.0.1:1/ -- port 1 on loopback refuses the connection
# almost instantly on virtually every host, so this is a REAL connection
# attempt that fails fast and hermetically, no mocking needed (matching Task
# 28's hermetic-testing correction: never a real network call in a unit
# test). The real, TRACKED scripts/providers/quota-endpoints.json documents
# only "openrouter" (a genuine external host that must never be dialed from
# a test), so this fixture lives in an ISOLATED temp copy pointed at via
# CMA_QUOTA_ENDPOINTS_FILE, the override this task adds to
# _cma_quota_group_accounts (lib.sh) and _cma_quota_probe_all
# (claude-providers.sh) for exactly this purpose: the same documented
# rationale as this file's own existing CMA_PROVIDERS_KEY_ALIASES /
# CMA_PROVIDERS_OVERRIDES overrides a few lines up ("so the hermetic test
# suite can point them at sandbox copies -- otherwise a sync inside a test
# would rewrite the TRACKED repo files"). The override is exported only for
# the single probe call below and unset immediately after.
#
# REVIEW ROUND 1 FIX: the first version of this fixture slurped ALL of the
# real file's entries (including openrouter's genuine
# https://openrouter.ai/... URL) into the isolated copy, and called
# _cma_quota_probe_all with fresh=1 and NO alias_filter -- which forced
# EVERY row in the batch (including the still-live "openrouter" fixture
# from the T028 block above, sharing this same sandboxed $HOME) past the
# cache check and into the live-probe branch. strace -f -e trace=network
# caught a REAL completed TCP handshake to openrouter.ai's Cloudflare IPs --
# exactly the class of regression a prior review round had just fixed in
# the sibling Task 28 test, reintroduced here through a different
# mechanism. Fixed with BOTH of the following (belt and suspenders):
#   1. The isolated quota-endpoints.json fixture now contains ONLY the new
#      unreachable entry -- zero real entries copied in, ever (same safe
#      pattern test_quota_concurrency.sh:11-25 already establishes: an
#      isolated spec file holding fixture entries only, never real ones).
#   2. The fresh=1 probe call below now passes a 3rd alias_filter argument
#      scoping it to ONLY this fixture's alias, so even a real entry
#      present elsewhere in the batch could never be reached by this call.
# The not_reported_by_provider comparison below now reuses the EARLIER,
# already-captured T028 "$probe_out" (the fresh=0, unscoped call, whose
# cached/not-reported rows were already proven network-free by T028's own
# assertions) instead of a second unscoped batch call here.

it "T029 setup: isolated quota-endpoints.json fixture -- ONLY the new unreachable entry, zero real entries"
quota_fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/cma-quota-fixture.XXXXXX")"
quota_fixture_file="$quota_fixture_dir/quota-endpoints.json"
jq -n '{
  "quota-fixture-unreachable": {
    url: "http://127.0.0.1:1/",
    auth: "bearer",
    windows: [
      { window: "subscription", signals: [ { path: [], type: "unit_literal", value: "credits" } ] }
    ]
  }
}' > "$quota_fixture_file"
assert_file "$quota_fixture_file" "isolated quota-endpoints.json fixture written"
real_entry_leaked="$(jq 'has("openrouter")' "$quota_fixture_file")"
assert_eq "false" "$real_entry_leaked" "the isolated fixture must NEVER contain the real openrouter entry"

it "T029 setup: quota-fixture-unreachable provider env + alias"
pdir="$(cma_providers_dir)"; mkdir -p "$pdir"
cma_provider_write_env quota-fixture-unreachable QUOTAFIXTURE_API_KEY router \
  "http://127.0.0.1:1" quota-fixture-unreachable/test-model quota-fixture-unreachable/test-model \
  "$HOME/.claude-prov-quota-fixture-unreachable" 128000 8192 quota-fixture-unreachable
cat >> "$ALIAS_FILE" <<'EOF'
alias quota-fixture-unreachable="cma_run_provider quota-fixture-unreachable"
EOF
assert_file "$pdir/quota-fixture-unreachable.env" "quota-fixture-unreachable.env fixture written"

it "a probe_failed result has a non-empty absence_detail distinct from not_reported_by_provider"
export CMA_QUOTA_ENDPOINTS_FILE="$quota_fixture_file"
t029_out="$(_cma_quota_probe_all 1 "1" "quota-fixture-unreachable")"
unset CMA_QUOTA_ENDPOINTS_FILE
t029_result="$(echo "$t029_out" | jq -c 'select(.provider_id=="quota-fixture-unreachable")')"
t029_reason="$(echo "$t029_result" | jq -r '.absence_reason')"
t029_detail="$(echo "$t029_result" | jq -r '.absence_detail // empty')"
assert_eq "probe_failed" "$t029_reason" "a genuinely-attempted-but-failed probe must report probe_failed"
t029_ok=0; [[ -n "$t029_detail" ]] && t029_ok=1
assert_eq "1" "$t029_ok" "absence_detail must be a non-empty string naming the real failure"

# Reuse T028's earlier, already-captured unscoped probe_out for the
# not_reported_by_provider comparison, rather than a second unscoped batch
# call here (review round 1 fix -- see block comment above).
t029_not_reported_reason="$(echo "$probe_out" | jq -r 'select(.provider_id=="deepseek") | .absence_reason')"
t029_neq=1; [[ "$t029_reason" == "$t029_not_reported_reason" ]] && t029_neq=0
assert_eq "1" "$t029_neq" "probe_failed and not_reported_by_provider must be textually DIFFERENT strings, never confused"

it "T029: every row carries the absence_detail KEY, even when its value is null (key never omitted)"
t029_fixture_has="$(echo "$t029_out" | jq -s 'map(has("absence_detail")) | all')"
assert_eq "true" "$t029_fixture_has" "absence_detail key must be present on the scoped probe_failed row"
t029_batch_has="$(echo "$probe_out" | jq -s 'map(has("absence_detail")) | all')"
assert_eq "true" "$t029_batch_has" "absence_detail key must be present on every row across the full batch too (not_reported_by_provider, cached, and native-account rows alike)"

summary
