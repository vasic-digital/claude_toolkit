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

summary
