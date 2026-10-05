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
# Exit code only: that --fresh is what changes behaviour is pinned by the
# T22-flag-specificity tests near the end of this file (cache vs live probe).

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

# --- C2 fix: same-credential multi-instance dedup axis (T038-independent-review) ----
#
# The deepseek test above proves the CROSS-FAMILY axis (one .env file, multiple
# alias lines). This test proves the OTHER axis: multiple SEPARATE .env files
# (different CMA_PROVIDER_ID, since cma_provider_write_env always makes the
# filename equal the id) sharing the IDENTICAL CMA_PROVIDER_KEYVAR +
# CMA_PROVIDER_BASE_URL -- the real openrouter/openrouter2/openrouter3/.../
# openrouter5 shape confirmed live on this host (5 real .env files, 1 real
# key, used to render as 5 rows with 4 false "not reported by provider"
# statuses before this fix).

it "_cma_quota_group_accounts dedupes multiple .env files sharing the same keyvar+base_url (same-credential multi-instance axis)"
# Operator decision "merge by key value": grouping is on a digest of the
# secret VALUE, so the shared keyvar must actually resolve to a (clearly
# fake) value -- an empty/unreadable key never merges. The keys file is a
# sandbox file, pinned explicitly so an operator-exported CMA_KEYS_FILE can
# never point this test at the real keys file.
export CMA_KEYS_FILE="$HOME/.quota-test-keys.sh"
cat > "$CMA_KEYS_FILE" <<'EOF'
export SHARED_TEST_KEY='fake-qtest-sharedkey-value-0000'
EOF
chmod 600 "$CMA_KEYS_FILE"
cma_provider_write_env sharedkey1 SHARED_TEST_KEY router \
  "https://api.sharedtest.example/v1" model1 model1 \
  "$HOME/.claude-prov-sharedkey1" 128000 8192 sharedkey1
cma_provider_write_env sharedkey2 SHARED_TEST_KEY router \
  "https://api.sharedtest.example/v1" model2 model2 \
  "$HOME/.claude-prov-sharedkey2" 128000 8192 sharedkey2
cat >> "$ALIAS_FILE" <<'EOF'
alias sharedkey1="cma_run_provider sharedkey1"
alias sharedkey2="cma_run_provider sharedkey2"
EOF
out="$(_cma_quota_group_accounts)"
count="$(echo "$out" | jq -r 'select(.base_url=="https://api.sharedtest.example/v1")' | jq -s 'length')"
assert_eq "1" "$count" "two .env files sharing the same keyvar+base_url must collapse into ONE row"
names="$(echo "$out" | jq -r 'select(.base_url=="https://api.sharedtest.example/v1") | .alias_names | sort | join(",")')"
assert_eq "sharedkey1,sharedkey2" "$names" "the merged row's alias_names must list BOTH distinct .env-backed ids"

# --- Operator decision: merge same-secret accounts by key VALUE -------------
#
# Two differently NAMED key variables holding the SAME secret are ONE real
# account, so they must render as ONE row; the dedup key is a sha256 digest
# of the value (plus base_url), never the variable name. Security contract
# asserted below: neither the value nor its digest ever appears in any
# output. Every fixture value is clearly fake. Assertion messages never
# interpolate a value or a digest -- only counts are compared.
qv_same='fake-qtest-secret-SAME-0001'
qv_diff='fake-qtest-secret-DIFF-0002'
cat >> "$CMA_KEYS_FILE" <<EOF
export QTEST_KEY_ALPHA='$qv_same'
export QTEST_KEY_BETA='$qv_same'
export QTEST_KEY_GAMMA='$qv_diff'
export QTEST_KEY_EMPTY=''
EOF
qv_base='https://api.samesecret.example/v1'
qe_base='https://api.emptysecret.example/v1'
for _qv in alpha:QTEST_KEY_ALPHA beta:QTEST_KEY_BETA gamma:QTEST_KEY_GAMMA; do
  cma_provider_write_env "qv${_qv%%:*}" "${_qv#*:}" router "$qv_base" m m \
    "$HOME/.claude-prov-qv${_qv%%:*}" 128000 8192 "qv${_qv%%:*}"
  printf 'alias qv%s="cma_run_provider qv%s"\n' "${_qv%%:*}" "${_qv%%:*}" >> "$ALIAS_FILE"
done
# Empty value (same keyvar name in both) and an unreadable (defined nowhere) key.
for _qe in qempty1:QTEST_KEY_EMPTY qempty2:QTEST_KEY_EMPTY qmiss1:QTEST_KEY_UNDEFINED_X qmiss2:QTEST_KEY_UNDEFINED_X; do
  cma_provider_write_env "${_qe%%:*}" "${_qe#*:}" router "$qe_base" m m \
    "$HOME/.claude-prov-${_qe%%:*}" 128000 8192 "${_qe%%:*}"
done
qv_out="$(_cma_quota_group_accounts 2>&1)"

it "merge-by-value: two DIFFERENT keyvar names holding the SAME value + same base_url collapse to ONE row"
qv_n="$(echo "$qv_out" | jq -c 'select(.base_url=="'"$qv_base"'") | select(.alias_names | index("qvalpha"))' 2>/dev/null | jq -s 'length')"
assert_eq "1" "$qv_n" "same secret under two names must be one row"
qv_names="$(echo "$qv_out" | jq -r 'select(.base_url=="'"$qv_base"'") | select(.alias_names | index("qvalpha")) | .alias_names | sort | join(",")' 2>/dev/null)"
assert_eq "qvalpha,qvbeta" "$qv_names" "the merged row lists both same-secret aliases and nothing else"

it "merge-by-value: a DIFFERENT value on the same base_url stays a separate row"
qv_total="$(echo "$qv_out" | jq -c 'select(.base_url=="'"$qv_base"'")' 2>/dev/null | jq -s 'length')"
assert_eq "2" "$qv_total" "same-secret pair (1 row) + different-secret account (1 row)"

it "merge-by-value: an EMPTY or UNREADABLE key never merges with anything (per-pid fallback)"
qe_total="$(echo "$qv_out" | jq -c 'select(.base_url=="'"$qe_base"'")' 2>/dev/null | jq -s 'length')"
assert_eq "4" "$qe_total" "two empty-valued + two undefined-key accounts must stay four rows"

it "merge-by-value: no key VALUE and no key DIGEST appears in the grouping output or the --json render"
printf '{}\n' > "$HOME/.quota-empty-endpoints.json"
qv_json="$(CMA_QUOTA_ENDPOINTS_FILE="$HOME/.quota-empty-endpoints.json" cmd_quota --json 2>&1)"
leaks=0
for _v in "$qv_same" "$qv_diff" 'fake-qtest-sharedkey-value-0000'; do
  _d="$(printf '%s' "$_v" | { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print $1}')"
  for _o in "$qv_out" "$qv_json"; do
    case "$_o" in *"$_v"*) leaks=$((leaks + 1)) ;; esac
    [[ -n "$_d" ]] && case "$_o" in *"$_d"*) leaks=$((leaks + 1)) ;; esac
  done
done
unset _v _d _o
assert_eq "0" "$leaks" "secret values and their digests must never be emitted"

it "merge-by-value: under set -x, the xtrace stream carries NO key value and NO key digest"
# Security review of e22e001: the digest was traced once xtrace came back on.
# Run the grouping with xtrace ON, capture ONLY the trace (stderr), and count
# hits for every fake value and its sha256 digest. Counts only -- nothing
# secret is ever interpolated into a message.
qx_trace="$HOME/.quota-xtrace.log"
( set -x; _cma_quota_group_accounts >/dev/null ) 2>"$qx_trace"
qx_lines="$(wc -l < "$qx_trace" | tr -d ' ')"
qx_nonvacuous=0; (( qx_lines > 0 )) && qx_nonvacuous=1
assert_eq "1" "$qx_nonvacuous" "the trace must be non-empty (xtrace really was on)"
qx_vhits=0; qx_dhits=0
for _v in "$qv_same" "$qv_diff" 'fake-qtest-sharedkey-value-0000'; do
  _d="$(printf '%s' "$_v" | { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print $1}')"
  _n="$(grep -c -F -e "$_v" "$qx_trace" 2>/dev/null)"; qx_vhits=$((qx_vhits + ${_n:-0}))
  _n="$(grep -c -F -e "$_d" "$qx_trace" 2>/dev/null)"; qx_dhits=$((qx_dhits + ${_n:-0}))
done
unset _v _d _n
assert_eq "0" "$qx_vhits" "xtrace hits for fake key VALUES must be zero"
assert_eq "0" "$qx_dhits" "xtrace hits for fake key DIGESTS must be zero"
rm -f "$qx_trace"

it "Kimi OAuth sentinel: kc-style aliases on ONE subscription (same base_url) collapse to one row; another base_url stays separate"
# _CMA_KIMICODE_OAUTH_ has no keys-file value by design (the token is the
# OAuth subscription), so value-grouping would split N models into N rows.
# Sentinel rule: group by (keyvar name, base_url), as before C2's value change.
qk_base='https://api.kimi-oauth.example/coding/v1'
qk_other='https://api.kimi-oauth-other.example/coding/v1'
for _qk in qkc1:"$qk_base" qkc2:"$qk_base" qkc3:"$qk_other"; do
  cma_provider_write_env "${_qk%%:*}" _CMA_KIMICODE_OAUTH_ router "${_qk#*:}" m m \
    "$HOME/.claude-prov-${_qk%%:*}" 128000 8192 "${_qk%%:*}"
  printf 'alias %s="cma_run_provider %s"\n' "${_qk%%:*}" "${_qk%%:*}" >> "$ALIAS_FILE"
done
qk_out="$(_cma_quota_group_accounts 2>/dev/null)"
qk_same="$(echo "$qk_out" | jq -c 'select(.base_url=="'"$qk_base"'")' 2>/dev/null | jq -s 'length')"
assert_eq "1" "$qk_same" "two sentinel aliases on the same base_url are one account"
qk_names="$(echo "$qk_out" | jq -r 'select(.base_url=="'"$qk_base"'") | .alias_names | sort | join(",")' 2>/dev/null)"
assert_eq "qkc1,qkc2" "$qk_names" "the merged sentinel row lists both aliases"
qk_sep="$(echo "$qk_out" | jq -c 'select(.base_url=="'"$qk_other"'")' 2>/dev/null | jq -s 'length')"
assert_eq "1" "$qk_sep" "a sentinel alias on a different base_url stays its own row"
for _q in qkc1 qkc2 qkc3; do rm -f "$(cma_providers_dir)/$_q.env"; done
grep -v -E '^alias qkc[123]=' "$ALIAS_FILE" > "$ALIAS_FILE.tmp" && mv "$ALIAS_FILE.tmp" "$ALIAS_FILE"
unset _qk

# Remove these fixtures so later fleet-wide assertions see the same set as before.
for _q in qvalpha qvbeta qvgamma qempty1 qempty2 qmiss1 qmiss2; do
  rm -f "$(cma_providers_dir)/$_q.env"
done
grep -v -E '^alias qv(alpha|beta|gamma)=' "$ALIAS_FILE" > "$ALIAS_FILE.tmp" && mv "$ALIAS_FILE.tmp" "$ALIAS_FILE"
unset _q _qv _qe

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

# --- C1 fix: auth_state (ok / session_expired / not_signed_in) ---------------
#
# T038-independent-review finding C1: a native account's genuine
# auth-session-expiry must be reported as a distinct state from
# quota-exhaustion, never conflated into the identical "not reported by
# provider" status every native account rendered regardless of real auth
# health. Three fixtures cover all three auth_state values. The signal is
# refreshTokenExpiresAt ONLY (never expiresAt, the routinely-refreshed
# access token) for Claude, and presence/absence of a credentials file for
# Kimi (no refresh-expiry field exists in that shape).

it "_cma_quota_list_native_accounts: auth_state=ok when refreshTokenExpiresAt is in the future"
dir_ok="$(make_account claudeauthok)"
future_ms=$(( ($(date +%s) + 86400) * 1000 ))
cat > "$dir_ok/.credentials.json" <<EOF
{"claudeAiOauth": {"refreshTokenExpiresAt": $future_ms}}
EOF
out_auth="$(_cma_quota_list_native_accounts)"
auth_ok="$(echo "$out_auth" | jq -r 'select(.account_id | endswith("claudeauthok")) | .auth_state')"
assert_eq "ok" "$auth_ok" "a future refreshTokenExpiresAt yields auth_state=ok"

it "_cma_quota_list_native_accounts: auth_state=session_expired when refreshTokenExpiresAt is in the past"
dir_expired="$(make_account claudeauthexpired)"
past_ms=$(( ($(date +%s) - 86400) * 1000 ))
cat > "$dir_expired/.credentials.json" <<EOF
{"claudeAiOauth": {"refreshTokenExpiresAt": $past_ms}}
EOF
out_auth="$(_cma_quota_list_native_accounts)"
auth_expired="$(echo "$out_auth" | jq -r 'select(.account_id | endswith("claudeauthexpired")) | .auth_state')"
assert_eq "session_expired" "$auth_expired" "a past refreshTokenExpiresAt yields auth_state=session_expired"

# Register item C1-expiresAt-untested: the decision to IGNORE expiresAt (the
# access token, refreshed routinely) was documented above but never pinned.
# Both fixtures carry BOTH fields, set to OPPOSITE sides of now, so a reader
# that consulted expiresAt -- alone or in addition -- gets the wrong answer.
it "_cma_quota_list_native_accounts: an EXPIRED expiresAt with a FUTURE refreshTokenExpiresAt is auth_state=ok (access token ignored)"
dir_acc_exp="$(make_account claudeaccexp)"
cat > "$dir_acc_exp/.credentials.json" <<EOF
{"claudeAiOauth": {"expiresAt": $past_ms, "refreshTokenExpiresAt": $future_ms}}
EOF
out_auth="$(_cma_quota_list_native_accounts)"
auth_acc_exp="$(echo "$out_auth" | jq -r 'select(.account_id | endswith("claudeaccexp")) | .auth_state')"
assert_eq "ok" "$auth_acc_exp" "an expired access token (expiresAt) is a routine refresh, never a session failure"

it "_cma_quota_list_native_accounts: a FUTURE expiresAt does not mask a PAST refreshTokenExpiresAt (session_expired)"
dir_ref_exp="$(make_account claudereffexp)"
cat > "$dir_ref_exp/.credentials.json" <<EOF
{"claudeAiOauth": {"expiresAt": $future_ms, "refreshTokenExpiresAt": $past_ms}}
EOF
out_auth="$(_cma_quota_list_native_accounts)"
auth_ref_exp="$(echo "$out_auth" | jq -r 'select(.account_id | endswith("claudereffexp")) | .auth_state')"
assert_eq "session_expired" "$auth_ref_exp" "a live access token must not hide an expired refresh token"

it "_cma_quota_list_native_accounts: auth_state=not_signed_in when .credentials.json is absent entirely"
dir_nosignin="$(make_account claudeauthnosignin)"
rm -f "$dir_nosignin/.credentials.json"
out_auth="$(_cma_quota_list_native_accounts)"
auth_nosignin="$(echo "$out_auth" | jq -r 'select(.account_id | endswith("claudeauthnosignin")) | .auth_state')"
assert_eq "not_signed_in" "$auth_nosignin" "a missing .credentials.json file yields auth_state=not_signed_in"

# --- B1 release gate: C1 octal noise + C2 loop-variable leak -----------------
#
# C1: a numeric-looking refreshTokenExpiresAt STRING with a leading zero
# ("0999") passed the ^[0-9]+$ guard and was then read by (( )) as an
# octal literal, printing `((: 0999: value too great for base` to the
# user's stderr. The compare must force decimal (10#). Each fixture runs
# in a subshell with its OWN mktemp HOME so the extra account dirs never
# reach the shared sandbox the end-to-end cmd_quota tests below reuse.
# stderr is captured separately from stdout and must be EMPTY.

_b1_native_probe() {   # $1 = refreshTokenExpiresAt JSON value; prints "<auth_state>\n<stderr bytes>"
  local b1_home; b1_home="$(mktemp -d "${TMPDIR:-/tmp}/cma-test.b1.XXXXXX")"
  mkdir -p "$b1_home/.claude-b1octal"
  printf '{}\n' > "$b1_home/.claude-b1octal/.claude.json"
  printf '{"claudeAiOauth": {"refreshTokenExpiresAt": %s}}\n' "$1" > "$b1_home/.claude-b1octal/.credentials.json"
  (
    export HOME="$b1_home"
    out="$(_cma_quota_list_native_accounts 2>"$b1_home/stderr")"
    echo "$out" | jq -r 'select(.account_id=="b1octal") | .auth_state'
    wc -c < "$b1_home/stderr" | tr -d ' '
    cat "$b1_home/stderr" >&2
  )
  rm -rf "$b1_home"
}

# B1 ruling: a leading-zero string is NOT a canonical number, so it is an
# unparseable field -- and an unparseable field never yields a guessed
# failure. It must degrade to auth_state=ok, never session_expired.
it "_cma_quota_list_native_accounts: leading-zero refreshTokenExpiresAt (\"0999\") is unparseable -> auth_state=ok, NOTHING on stderr (C1)"
b1_res="$(_b1_native_probe '"0999"')"
assert_eq "ok" "$(echo "$b1_res" | sed -n 1p)" "a non-canonical (leading-zero) expiry is unparseable and must degrade to auth_state=ok"
assert_eq "0" "$(echo "$b1_res" | sed -n 2p)" "a leading-zero numeric string must not leak an arithmetic-base error to stderr"

it "_cma_quota_list_native_accounts: a long leading-zero refreshTokenExpiresAt (\"09999999999999\") leaves stderr empty"
b1_res="$(_b1_native_probe '"09999999999999"')"
assert_eq "0" "$(echo "$b1_res" | sed -n 2p)" "a leading-zero value must never reach arithmetic, so nothing is printed to stderr"

it "_cma_quota_list_native_accounts: canonical FUTURE refreshTokenExpiresAt (9999999999999) -> auth_state=ok"
b1_res="$(_b1_native_probe '9999999999999')"
assert_eq "ok" "$(echo "$b1_res" | sed -n 1p)" "a canonical future expiry yields auth_state=ok"
assert_eq "0" "$(echo "$b1_res" | sed -n 2p)" "and nothing is printed to stderr"

it "_cma_quota_list_native_accounts: canonical PAST refreshTokenExpiresAt (\"1000\") still -> session_expired (gate keeps the real expiry path)"
b1_res="$(_b1_native_probe '"1000"')"
assert_eq "session_expired" "$(echo "$b1_res" | sed -n 1p)" "a canonical past expiry must still yield auth_state=session_expired"
assert_eq "0" "$(echo "$b1_res" | sed -n 2p)" "and nothing is printed to stderr"

# --- Operator decision D2: Kimi session ends ONLY on refresh-token expiry ----
#
# A Kimi credentials/*.json carries access_token, expires_at, expires_in,
# refresh_token, scope, token_type. The access token expires routinely and
# is refreshed; its expiry is NEVER a session failure. The session ends only
# when the refresh_token JWT's own `exp` claim has passed. An undecodable
# refresh token or a non-canonical/non-numeric exp stays "ok" (never guess
# a failure from an unparseable field). Each fixture runs in a subshell with
# its OWN mktemp HOME (never the real ~/.kimi-code-*); stderr must be empty.
# Tokens are unsigned JWTs built here; their contents are fixture data only.

_d2_b64url() { base64 | tr -d '\n=' | tr '+/' '-_'; }
_d2_jwt() {   # $1 = raw payload text (may be invalid JSON on purpose)
  printf '%s.%s.%s' \
    "$(printf '%s' '{"alg":"none","typ":"JWT"}' | _d2_b64url)" \
    "$(printf '%s' "$1" | _d2_b64url)" \
    "sig"
}
_d2_kimi_probe() {   # $1 = refresh_token string ("" = no credentials file), $2 = access expires_at; prints "<auth_state>\n<stderr bytes>"
  local d2_home; d2_home="$(mktemp -d "${TMPDIR:-/tmp}/cma-test.d2.XXXXXX")"
  mkdir -p "$d2_home/.kimi-code-d2kimi/credentials"
  printf 'x = 1\n' > "$d2_home/.kimi-code-d2kimi/config.toml"
  if [[ -n "$1" ]]; then
    jq -nc --arg rt "$1" --argjson ea "$2" \
      '{access_token:"fixture-access", expires_at:$ea, expires_in:900, refresh_token:$rt, scope:"kimi-code", token_type:"Bearer"}' \
      > "$d2_home/.kimi-code-d2kimi/credentials/kimi-code.json"
  fi
  (
    export HOME="$d2_home"
    out="$(_cma_quota_list_native_accounts 2>"$d2_home/stderr")"
    echo "$out" | jq -r 'select(.family=="kimi" and .account_id=="d2kimi") | .auth_state'
    wc -c < "$d2_home/stderr" | tr -d ' '
  )
  rm -rf "$d2_home"
}
d2_now="$(date +%s)"
d2_future=$(( d2_now + 198 * 3600 ))
d2_past=$(( d2_now - 86400 ))

it "D2 Kimi: refresh exp in the FUTURE -> auth_state=ok"
d2_res="$(_d2_kimi_probe "$(_d2_jwt "{\"exp\":$d2_future}")" "$d2_future")"
assert_eq "ok" "$(echo "$d2_res" | sed -n 1p)" "a future refresh-token exp yields auth_state=ok"
assert_eq "0" "$(echo "$d2_res" | sed -n 2p)" "and nothing is printed to stderr"

it "D2 Kimi: refresh exp in the PAST (access token also expired) -> session_expired"
d2_res="$(_d2_kimi_probe "$(_d2_jwt "{\"exp\":$d2_past}")" "$d2_past")"
assert_eq "session_expired" "$(echo "$d2_res" | sed -n 1p)" "a past refresh-token exp yields auth_state=session_expired"
assert_eq "0" "$(echo "$d2_res" | sed -n 2p)" "and nothing is printed to stderr"

it "D2 Kimi: refresh exp in the PAST but access token FUTURE -> session_expired (refresh-only decision)"
d2_res="$(_d2_kimi_probe "$(_d2_jwt "{\"exp\":$d2_past}")" "$d2_future")"
assert_eq "session_expired" "$(echo "$d2_res" | sed -n 1p)" "a future access token must not mask a past refresh-token exp"

it "D2 Kimi: access token EXPIRED, refresh exp FUTURE -> ok (false-negative guard)"
d2_res="$(_d2_kimi_probe "$(_d2_jwt "{\"exp\":$d2_future}")" "$d2_past")"
assert_eq "ok" "$(echo "$d2_res" | sed -n 1p)" "an expired access token is a normal refresh, never a session failure"
assert_eq "0" "$(echo "$d2_res" | sed -n 2p)" "and nothing is printed to stderr"

it "D2 Kimi: no credentials file -> not_signed_in"
d2_res="$(_d2_kimi_probe "" 0)"
assert_eq "not_signed_in" "$(echo "$d2_res" | sed -n 1p)" "a missing credentials file yields auth_state=not_signed_in"

it "D2 Kimi: malformed JWT / non-numeric exp / leading-zero exp -> ok, empty stderr"
for d2_tok in "not-a-jwt" "a.%%%.b" "$(_d2_jwt '{"exp":"abc"}')" "$(_d2_jwt '{"exp":"0999"}')" \
              "$(_d2_jwt '{"exp":0999}')" "$(_d2_jwt '{"exp":-5}')" "$(_d2_jwt '{"sub":"x"}')" "$(_d2_jwt '[1,2]')"; do
  d2_res="$(_d2_kimi_probe "$d2_tok" "$d2_past")"
  assert_eq "ok" "$(echo "$d2_res" | sed -n 1p)" "an unparseable refresh token / exp degrades to auth_state=ok"
  assert_eq "0" "$(echo "$d2_res" | sed -n 2p)" "an unparseable refresh token / exp leaves stderr empty"
done

# C2: `while IFS= read -r _name` in _cma_quota_group_accounts did not
# declare _name local, so it leaked into the CALLER's scope. Run in a
# subshell so the probe cannot pollute this file's own scope either; the
# deepseek fixture above guarantees the read loop actually executes.
it "_cma_quota_group_accounts does NOT leak its loop variable _name into the caller (C2)"
b1_leak="$( unset _name; _cma_quota_group_accounts >/dev/null 2>&1; if declare -p _name >/dev/null 2>&1; then echo leaked; else echo clean; fi )"
assert_eq "clean" "$b1_leak" "_name must be function-local, unset in the caller after the call"

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
grep -qi "does not exist" <<<"$out3" && dne=1 || dne=0
assert_eq "1" "$dne" "FR-003: the unknown alias is stated plainly ('does not exist'), never silent, never a bare crash"

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

# --- T028 isolation (register item: hermetic T028) -------------------------
# FIRST thing in the block: point every quota spec lookup at an ISOLATED
# sandbox copy. It keeps openrouter's entry (T028 needs a spec-present
# provider) but rewrites its url to a loopback stub (port 1 refuses
# instantly), so even a cache miss cannot reach the real openrouter.ai. Later
# blocks that swap in their own fixture file restore THIS one afterwards
# (never `unset`, which would silently fall back to the tracked file).
t028_spec="$HOME/.quota-t028-endpoints.json"
jq '{openrouter: (.openrouter | .url = "http://127.0.0.1:1/api/v1/key" | .doc = "stub (T028 isolated copy)")}' \
  "$SCRIPTS_DIR/providers/quota-endpoints.json" > "$t028_spec"
export CMA_QUOTA_ENDPOINTS_FILE="$t028_spec"

# --- T028 network guard (register item: hermetic T028) ---------------------
#
# Forensics found a real-network fallthrough: this block used the TRACKED
# quota-endpoints.json (openrouter -> https://openrouter.ai), and the cache
# check that keeps the probe on the CACHED branch swallows its own errors
# (2>/dev/null). Any cache miss -- including a failed `import quota_probe`
# -- fell through to a LIVE probe of the real host. The guard below makes
# that impossible to miss: the python3 stub refuses to run quota_probe.py
# against a spec file naming any non-loopback host and records a violation
# instead, and the effective endpoints file is checked directly.
t028_guard_log="$HOME/.quota-t028-network-guard.log"
: > "$t028_guard_log"
t028_guard_check="$HOME/.quota-t028-guard-check.sh"
cat > "$t028_guard_check" <<'GUARDEOF'
#!/usr/bin/env bash
# usage: guard-check SPEC_FILE -- prints the count of url fields whose host is
# NOT a loopback stub; prints nothing (=> treated as a violation) if unreadable.
jq -r '[.. | objects | .url? | select(type == "string")
        | select(test("^https?://(127\\.0\\.0\\.1|localhost)(:[0-9]+)?(/|$)") | not)]
       | length' "$1" 2>/dev/null
GUARDEOF
chmod +x "$t028_guard_check"
t028_effective_spec() { printf '%s' "${CMA_QUOTA_ENDPOINTS_FILE:-${LIB_DIR:-${SCRIPTS_DIR:-}}/providers/quota-endpoints.json}"; }

it "T028 hermetic: the effective quota-endpoints file names ONLY loopback stub hosts (no real host reachable on a cache miss)"
t028_nonstub="$("$t028_guard_check" "$(t028_effective_spec)")"
assert_eq "0" "${t028_nonstub:-unreadable}" "every endpoint url T028 can probe must be a loopback stub, never a real host"

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
# Seed the CURRENT cache version (2). A stale version is rejected wholesale
# by load_quota_cache, which would turn this cached-branch test into a live
# probe; the cache-check assertion below fails loudly if the two ever drift.
jq -n --argjson now "$now_ts" '{
  _cache_version: 2,
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
# NETWORK GUARD: any quota_probe.py invocation (the ONLY subprocess that
# opens a socket) whose --spec-file names a non-loopback host is refused
# here -- logged to $t028_guard_log and exited 97 BEFORE the real
# interpreter runs, so a regression can never actually dial the real host.
t028_install_stub() {
  sandbox_stub "$stub_dir/python3" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$stub_log"
case "\$*" in
  *quota_probe.py*)
    _spec=""; _prev=""
    for _a in "\$@"; do [[ "\$_prev" == "--spec-file" ]] && _spec="\$_a"; _prev="\$_a"; done
    _bad="\$("$t028_guard_check" "\$_spec")"
    if [[ "\$_bad" != "0" ]]; then
      printf 'NETWORK-GUARD: live probe refused, spec %s names %s non-stub host(s)\n' "\$_spec" "\${_bad:-unreadable}" >> "$t028_guard_log"
      exit 97
    fi
    ;;
esac
exec "$real_python3" "\$@"
STUBEOF
}
t028_install_stub

it "T028: the cache-check import works and returns openrouter's seeded record (fails LOUDLY -- a silent failure here is exactly what fell through to a live probe)"
t028_cc_err="$HOME/.quota-t028-cachecheck.err"
t028_cc_out="$(python3 -c "
import sys, json
sys.path.insert(0, sys.argv[1])
import quota_probe as qp
data = qp.load_quota_cache(sys.argv[2])
rec = data.get('providers', {}).get(sys.argv[3])
print(json.dumps(rec) if rec else '')
" "${LIB_DIR:-${SCRIPTS_DIR:-}}" "$cache_file" openrouter 2>"$t028_cc_err")"
t028_cc_rc=$?
if (( t028_cc_rc != 0 )) || [[ -z "$t028_cc_out" ]]; then
  printf 'T028 FATAL: cache-check python failed (rc=%s); the probe below would fall through to a live probe. stderr:\n' "$t028_cc_rc" >&2
  cat "$t028_cc_err" >&2
fi
assert_eq "0" "$t028_cc_rc" "the cache-check python one-liner must exit 0 (import quota_probe + load_quota_cache)"
assert_eq "openrouter" "$(jq -r '.provider_id // empty' <<<"$t028_cc_out" 2>/dev/null)" "the cache check must return the seeded openrouter record"

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

it "T028 network guard: a FORCED cache miss (fresh=1) for openrouter launches the live probe, and it never targets a non-stub host"
# The fallthrough path, exercised on purpose: fresh=1 skips the cache, so
# _cma_quota_probe_all launches quota_probe.py for openrouter exactly as a
# failed cache check would. The guard stub refuses (exit 97 + log line) if
# the spec it is handed names any real host; with isolation in place the
# probe runs against the loopback stub and fails fast, hermetically.
: > "$stub_log"
t028_install_stub
export PATH="$stub_dir:$PATH"
t028_forced_out="$(_cma_quota_probe_all 1 "1" openrouter 2>&1)"
export PATH="$old_path"
rm -rf "$stub_dir"
t028_live_calls="$(grep -c -- '--provider-id openrouter' "$stub_log" 2>/dev/null)"
[[ -z "$t028_live_calls" ]] && t028_live_calls=0
t028_live_ok=0; (( t028_live_calls >= 1 )) && t028_live_ok=1
assert_eq "1" "$t028_live_ok" "the forced miss must really reach the live-probe subprocess (guard is non-vacuous)"
t028_violations="$(grep -c 'NETWORK-GUARD' "$t028_guard_log" 2>/dev/null)"
[[ -z "$t028_violations" ]] && t028_violations=0
assert_eq "0" "$t028_violations" "no quota_probe.py call in T028 may target a non-stub (real) host"
assert_eq "probe_failed" "$(echo "$t028_forced_out" | jq -r 'select(.provider_id=="openrouter") | .absence_reason' 2>/dev/null)" "the loopback stub refuses, so the forced live probe reports probe_failed"

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
# would rewrite the TRACKED repo files"). The override is swapped in only for
# the single probe call below, then restored to T028's isolated copy.
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
export CMA_QUOTA_ENDPOINTS_FILE="$t028_spec"   # restore T028 isolation, never the tracked file
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

# --- T038-independent-review I3: batching still produces every row past
# max_parallel ----------------------------------------------------------
#
# The brief's ruling: _cma_quota_probe_all's bounded-concurrency batching
# (a blocking `wait` after every CMA_QUOTA_MAX_PARALLEL_PROBES probes) is
# a deliberate resource-safety design, NOT a bug -- the I3 fix is a
# spec-text correction (FR-017/SC-008 now honestly describe the batched
# ceil(N/max_parallel) bound instead of claiming independence from N) plus
# a defensive outer `timeout` wrapper around the live-probe python3
# subprocess. This is a regression guard proving the batching BEHAVIOR is
# unchanged by that fix: 5 fake provider accounts, all absent from
# quota-endpoints.json (same no-endpoint-spec shape "deepseek" already
# establishes above -- no live-probe subprocess, no network), with
# CMA_QUOTA_MAX_PARALLEL_PROBES forced to 2 so 5 accounts span 3 rounds
# (2+2+1) and the blocking `wait` barrier fires twice before the loop ends.

it "I3 setup: 5 fake provider accounts, all absent from quota-endpoints.json"
pdir="$(cma_providers_dir)"; mkdir -p "$pdir"
for n in 1 2 3 4 5; do
  cma_provider_write_env "quota-batch-fixture-$n" "QUOTABATCH${n}_API_KEY" router \
    "https://example.invalid/quota-batch-fixture-$n" "quota-batch-fixture-$n/test-model" \
    "quota-batch-fixture-$n/test-model" "$HOME/.claude-prov-quota-batch-fixture-$n" \
    128000 8192 "quota-batch-fixture-$n"
  cat >> "$ALIAS_FILE" <<EOF
alias quota-batch-fixture-$n="cma_run_provider quota-batch-fixture-$n"
EOF
done
assert_file "$pdir/quota-batch-fixture-5.env" "5th fake provider account fixture written"

it "I3: CMA_QUOTA_MAX_PARALLEL_PROBES=2 across 5 accounts still produces all 5 rows (batching behavior unchanged by the I3 fix)"
batch_out="$(CMA_QUOTA_MAX_PARALLEL_PROBES=2 _cma_quota_probe_all 0 "" "" 2>&1)"
batch_rc=$?
assert_eq "0" "$batch_rc" "a forced max_parallel=2 batch run (3 rounds for 5 accounts) must still complete cleanly"
batch_count=0
for n in 1 2 3 4 5; do
  found="$(echo "$batch_out" | jq -r --arg pid "quota-batch-fixture-$n" 'select(.provider_id==$pid) | .provider_id' 2>/dev/null)"
  [[ "$found" == "quota-batch-fixture-$n" ]] && batch_count=$(( batch_count + 1 ))
done
assert_eq "5" "$batch_count" "all 5 accounts must appear in the output even though max_parallel(2) < account count(5) -- more rounds, same completeness, nothing dropped by the batching"

# --- T038-independent-review I4: --json with a quote-containing alias ----
#
# cmd_quota used to build the --json scoped_to argument via naive string
# interpolation ("\"$alias_arg\"") instead of proper jq encoding --
# _cma_quota_render_json's --argjson scoped "$scoped_to" requires a VALID
# JSON literal, so an alias name containing a literal `"` broke jq parsing
# and produced no output + a non-zero exit instead of a clean,
# correctly-scoped result. This proves the fix (scoped_to_json built once
# via `jq -cn --arg a "$alias_arg" '$a'`) round-trips the exact alias
# string, including its embedded quote, instead of breaking.

it "I4: --json with an alias name containing a literal double-quote character produces valid JSON (not broken by naive string interpolation)"
out_quote="$(cmd_quota 'foo"bar' --json 2>&1)"
rc_quote=$?
assert_eq "2" "$rc_quote" "an unknown alias (even one containing a literal quote) must still return 2, never crash"
echo "$out_quote" | jq -e . >/dev/null 2>&1
assert_eq "0" "$?" "I4 fix: --json output must be valid, parseable JSON even when alias_arg contains a literal \" character"
scoped_quote="$(echo "$out_quote" | jq -r '.scoped_to' 2>/dev/null)"
assert_eq 'foo"bar' "$scoped_quote" "scoped_to must carry the exact alias string, including its embedded quote, via proper jq encoding"

# --- T038-independent-review S1: --timeout value/numeric validation ------
#
# --timeout had no guard for a missing value (crashed under nounset if
# --timeout were the last argument) or a non-numeric value (silently
# passed through to a confusing downstream failure). Both are now
# rejected up front with a clear error and exit 1.

it "S1: --timeout with no following argument returns 1 with a clear error, never a nounset crash"
out_missing="$(cmd_quota --timeout 2>&1)"
rc_missing=$?
assert_eq "1" "$rc_missing" "--timeout with no value must return 1, not crash or hang"
echo "$out_missing" | grep -qi "timeout.*requires a value"
assert_eq "0" "$?" "the error message must clearly name --timeout as requiring a value"

it "S1: --timeout notanumber returns 1 with a clear error"
out_nan="$(cmd_quota --timeout notanumber 2>&1)"
rc_nan=$?
assert_eq "1" "$rc_nan" "--timeout with a non-numeric value must return 1, not be silently accepted"
echo "$out_nan" | grep -qi "timeout.*positive integer"
assert_eq "0" "$?" "the error message must clearly name --timeout as requiring a positive integer"

# Fix round 1 (independent review): the regex is now ^[1-9][0-9]*$ so that
# "positive integer" is literally true -- 0 is rejected (not positive), and
# a leading-zero value like 08 is rejected (it would be read as octal by
# $(( timeout + 1 ))  and fail with "value too great for base").

it "S1 (fix round 1): --timeout 0 returns 1 with the positive-integer error"
out_zero="$(cmd_quota --timeout 0 2>&1)"
rc_zero=$?
assert_eq "1" "$rc_zero" "--timeout 0 must return 1 -- zero is not a positive integer"
echo "$out_zero" | grep -qi "timeout.*positive integer"
assert_eq "0" "$?" "--timeout 0 must produce the same positive-integer error message"

it "S1 (fix round 1): --timeout 08 returns 1 with the positive-integer error (leading zero, would be octal)"
out_08="$(cmd_quota --timeout 08 2>&1)"
rc_08=$?
assert_eq "1" "$rc_08" "--timeout 08 must return 1 -- leading zero is rejected, never read as octal"
echo "$out_08" | grep -qi "timeout.*positive integer"
assert_eq "0" "$?" "--timeout 08 must produce the same positive-integer error message"

# --- Fix round 1 (blocker): live probe must work WITHOUT a `timeout` binary --
#
# Stock macOS ships no coreutils `timeout`. The live-probe branch used to
# call `timeout ...` unconditionally, so there every live probe exited 127
# and degraded to probe_failed. The fix falls back to the bare python3 call
# when `command -v timeout` fails. This test proves that path: PATH is
# narrowed to a dir holding symlinks to python3/jq/date/mktemp only (no
# timeout), and a stub quota_probe.py (via LIB_DIR) returns a successful
# window. The result must be a real live success, not probe_failed.

it "blocker (fix round 1): live probe with NO timeout binary on PATH still yields a real result, not probe_failed"
nt_bin="$HOME/.quota-notimeout-bin"
nt_lib="$HOME/.quota-notimeout-lib"
mkdir -p "$nt_bin" "$nt_lib"
# Symlink EVERY executable from the standard system dirs EXCEPT `timeout`,
# so the narrowed PATH is identical to the normal one minus exactly one tool
# (guessing a minimal allowlist missed tools the orchestration needs).
for d in /usr/bin /bin; do
  [[ -d "$d" ]] || continue
  for f in "$d"/*; do
    b="$(basename "$f")"
    [[ "$b" == "timeout" || -e "$nt_bin/$b" ]] && continue
    [[ -x "$f" && -f "$f" ]] && ln -s "$f" "$nt_bin/$b"
  done
done
nt_timeout_visible=0; PATH="$nt_bin" command -v timeout >/dev/null 2>&1 && nt_timeout_visible=1
assert_eq "0" "$nt_timeout_visible" "precondition: the timeout binary must be genuinely unresolvable on the narrowed PATH (otherwise this test proves nothing)"

cat > "$nt_lib/quota_probe.py" <<'PYEOF'
import json, os, sys
def load_quota_cache(path):
    return {}
def save_quota_cache(path, data):
    return None
if __name__ == "__main__":
    # Invocation log (register item I3-data_source-assert): proof that the
    # live probe subprocess genuinely RAN, independent of the row it yields.
    log = os.environ.get("NT_PROBE_LOG")
    if log:
        with open(log, "a") as f:
            f.write(sys.argv[sys.argv.index("--provider-id") + 1] + "\n")
    print(json.dumps({"windows": [{"window": "subscription", "amount_used": 20,
        "amount_remaining": 80, "limit_total": 100, "unit": "credits",
        "percent_remaining": 80.0, "resets": False, "reset_at": None}],
        "account_blocked": False, "absence_reason": None, "http_status": 200}))
PYEOF

nt_pdir="$(cma_providers_dir)"; mkdir -p "$nt_pdir"
cma_provider_write_env quota-notimeout-fixture NOTIMEOUT_API_KEY router \
  "http://127.0.0.1:1" quota-notimeout-fixture/test-model quota-notimeout-fixture/test-model \
  "$HOME/.claude-prov-quota-notimeout-fixture" 128000 8192 quota-notimeout-fixture
cat >> "$ALIAS_FILE" <<EOF
alias quota-notimeout-fixture="cma_run_provider quota-notimeout-fixture"
EOF
nt_spec="$HOME/.quota-notimeout-spec.json"
jq -n '{"quota-notimeout-fixture": {url: "http://127.0.0.1:1/", auth: "bearer",
  windows: [ { window: "subscription", signals: [ { path: [], type: "unit_literal", value: "credits" } ] } ]}}' > "$nt_spec"

old_path_nt="$PATH"
export PATH="$nt_bin"
export LIB_DIR="$nt_lib"
export CMA_QUOTA_ENDPOINTS_FILE="$nt_spec"
export NT_PROBE_LOG="$HOME/.quota-notimeout-probe.log"
rm -f "$NT_PROBE_LOG"
nt_out="$(_cma_quota_probe_all 1 "" "quota-notimeout-fixture" 2>&1)"
nt_rc=$?
unset LIB_DIR NT_PROBE_LOG; export CMA_QUOTA_ENDPOINTS_FILE="$t028_spec"   # restore T028 isolation
export PATH="$old_path_nt"

nt_row="$(echo "$nt_out" | jq -c 'select(.provider_id=="quota-notimeout-fixture")' 2>/dev/null)"
nt_reason="$(echo "$nt_row" | jq -r '.absence_reason' 2>/dev/null)"
nt_amt="$(echo "$nt_row" | jq -r '.windows[0].amount_remaining' 2>/dev/null)"
assert_eq "0" "$nt_rc" "the probe orchestration must complete cleanly with no timeout binary"
assert_eq "null" "$nt_reason" "with no timeout binary the live probe must NOT degrade to probe_failed (absence_reason must be null)"
# data_source=live alone does NOT discriminate (register item
# I3-data_source-assert): the orchestrator stamps "live" on EVERY row of the
# live branch, including the probe_failed row it synthesizes when the probe
# subprocess never ran or printed nothing. The probe's own invocation log is
# the discriminating signal: exactly one run, for exactly this provider.
nt_runs="$(grep -cx 'quota-notimeout-fixture' "$HOME/.quota-notimeout-probe.log" 2>/dev/null)"
assert_eq "1" "${nt_runs:-0}" "the live probe subprocess must actually have RUN exactly once for this provider with no timeout binary (invocation log), not merely produced a data_source=live row"
assert_eq "80" "$nt_amt" "the stubbed probe's real window value must round-trip through the no-timeout fallback"

# --- B-orchestrator: lost-update race in the cache merge pass ----------------
#
# _cma_quota_probe_all's merge pass is a read-modify-write of the SHARED
# quota cache (load -> merge this run's records -> save). Two concurrent
# `quota` runs that both load before either saves resolve last-writer-wins
# and one run's records vanish. save_quota_cache's temp+rename (B-probe)
# makes each WRITE atomic; it does not serialize the CYCLE.
#
# Deterministic, not statistical: a stub quota_probe.py (via LIB_DIR) sleeps
# INSIDE load_quota_cache, so without a lock both runs are guaranteed to load
# the same empty snapshot before either saves. With the lock, the second
# run's load happens after the first run's save. Two DIFFERENT providers, one
# per run, so a lost record cannot be re-derived by the other run.
bo_lib="$HOME/.quota-bo-lib"
mkdir -p "$bo_lib"
cat > "$bo_lib/quota_probe.py" <<'PYEOF'
import json, os, sys, time
def load_quota_cache(path):
    try:
        with open(path) as f:
            d = json.load(f)
    except (OSError, ValueError):
        d = {"_cache_version": 2, "providers": {}}
    if not isinstance(d, dict):
        d = {"_cache_version": 2, "providers": {}}
    s = os.environ.get("BO_LOAD_SLEEP")
    if s:
        time.sleep(float(s))
    return d
def save_quota_cache(path, data):
    data["_cache_version"] = 2
    data["_cached_at"] = time.time()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".bo.tmp." + str(os.getpid())
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)
if __name__ == "__main__":
    pid = sys.argv[sys.argv.index("--provider-id") + 1]
    log = os.environ.get("BO_PROBE_LOG")
    if log:
        with open(log, "a") as f:
            f.write(pid + "\n")
    print(json.dumps({"provider_id": pid, "windows": [{"window": "subscription",
        "amount_used": 1, "amount_remaining": 9, "limit_total": 10, "unit": "credits",
        "percent_remaining": 90.0, "resets": False, "reset_at": None}],
        "account_blocked": False, "absence_reason": None, "http_status": 200}))
PYEOF
bo_spec="$HOME/.quota-bo-spec.json"
echo '{}' > "$bo_spec"
bo_pdir="$(cma_providers_dir)"; mkdir -p "$bo_pdir"
for bo_p in quota-race-a quota-race-b quota-f2-fixture; do
  cma_provider_write_env "$bo_p" "BO_KEY_${bo_p//-/_}" router "http://127.0.0.1:1" \
    "$bo_p/test-model" "$bo_p/test-model" "$HOME/.claude-prov-$bo_p" 128000 8192 "$bo_p"
  printf 'alias %s="cma_run_provider %s"\n' "$bo_p" "$bo_p" >> "$ALIAS_FILE"
  jq --arg p "$bo_p" '. + {($p): {url: "http://127.0.0.1:1/", auth: "bearer",
    windows: [ { window: "subscription", signals: [ { path: [], type: "unit_literal", value: "credits" } ] } ]}}' \
    "$bo_spec" > "$bo_spec.tmp" && mv "$bo_spec.tmp" "$bo_spec"
done
bo_cache="$HOME/.local/share/claude-multi-account/quota-cache.json"
bo_lockdir="$(dirname "$bo_cache")/quota-cache.lock.d"

# _bo_race BACKEND_LABEL: two concurrent --fresh runs, one provider each.
_bo_race() {
  rm -f "$bo_cache"
  ( _cma_quota_probe_all 1 "" quota-race-a >/dev/null 2>&1 ) &
  local ra=$!
  ( _cma_quota_probe_all 1 "" quota-race-b >/dev/null 2>&1 ) &
  local rb=$!
  wait "$ra"; wait "$rb"
  jq -c '.providers | keys' "$bo_cache" 2>/dev/null
}

export LIB_DIR="$bo_lib" CMA_QUOTA_ENDPOINTS_FILE="$bo_spec" BO_LOAD_SLEEP=1

it "B-orchestrator race: two concurrent quota runs each keep their own cache record (default lock backend)"
bo_keys="$(_bo_race)"
assert_eq '["quota-race-a","quota-race-b"]' "$bo_keys" \
  "both concurrent runs' records must survive the merge (got $bo_keys) -- last-writer-wins lost one"

it "B-orchestrator race: same guarantee on the portable mkdir backend (macOS has no flock)"
export CMA_ALIAS_LOCK_NO_FLOCK=1
bo_keys="$(_bo_race)"
unset CMA_ALIAS_LOCK_NO_FLOCK
assert_eq '["quota-race-a","quota-race-b"]' "$bo_keys" \
  "both records must survive under the mkdir lock backend too (got $bo_keys)"

it "B-orchestrator race: a held cache lock is waited on for a BOUNDED time, then the save is skipped with a warning (never hangs)"
unset BO_LOAD_SLEEP
rm -f "$bo_cache"
# Hold the quota-cache lock with a LIVE foreign pid on the mkdir backend --
# deterministic, no timing race: the lock is held before the run starts and
# its holder is alive for the whole run, so it can never be broken as stale.
# The holder is started DETACHED (inside a reaped subshell), never as a job
# of this shell: _cma_quota_probe_all's bare `wait` runs inside the caller's
# $(...) subshell, which inherits this shell's job table, and a live job
# there makes that `wait` spin indefinitely -- an unbounded hang, not a
# wait-for-the-job delay (observed: 99% CPU, never returned).
bo_holder="$( (sleep 30 </dev/null >/dev/null 2>&1 & printf '%s' "$!") )"
mkdir -p "$bo_lockdir/.aliases.lockdir"
printf '%s\n' "$bo_holder" > "$bo_lockdir/.aliases.lockdir/pid"
export CMA_ALIAS_LOCK_NO_FLOCK=1 CMA_QUOTA_CACHE_LOCK_WAIT=1
# The effective wait is clamped to more than the stale grace (D8), so the
# grace is lowered here to keep this bounded-wait check fast. The holder is
# LIVE, so the grace never breaks it -- only the clamp arithmetic sees it.
bo_old_grace="$CMA_ALIAS_LOCK_STALE_GRACE"; CMA_ALIAS_LOCK_STALE_GRACE=1
bo_t0="$(date +%s)"
bo_out="$(_cma_quota_probe_all 1 "" quota-race-a 2>"$HOME/.quota-bo-stderr")"
bo_rc=$?
bo_elapsed=$(( $(date +%s) - bo_t0 ))
CMA_ALIAS_LOCK_STALE_GRACE="$bo_old_grace"
unset CMA_ALIAS_LOCK_NO_FLOCK CMA_QUOTA_CACHE_LOCK_WAIT
kill "$bo_holder" 2>/dev/null
rm -rf "$bo_lockdir/.aliases.lockdir"
assert_eq "0" "$bo_rc" "a busy cache lock must not fail the command"
bo_fast=0; (( bo_elapsed <= 8 )) && bo_fast=1
assert_eq "1" "$bo_fast" "the lock wait must be bounded by CMA_QUOTA_CACHE_LOCK_WAIT (elapsed ${bo_elapsed}s)"
bo_saved=0; [[ -f "$bo_cache" ]] && bo_saved=1
assert_eq "0" "$bo_saved" "on lock timeout the save must be SKIPPED, never written unlocked"
bo_warned=0; grep -q 'quota cache lock' "$HOME/.quota-bo-stderr" 2>/dev/null && bo_warned=1
assert_eq "1" "$bo_warned" "a skipped save must be announced on stderr, not silent"
bo_src="$(echo "$bo_out" | jq -r 'select(.provider_id=="quota-race-a") | .data_source' 2>/dev/null)"
assert_eq "live" "$bo_src" "the row itself must still be reported from the live probe"

# --- D8: the quota-cache lock wait is clamped above the stale grace ---------
# The mkdir backend breaks a pid-less lock dir only after
# CMA_ALIAS_LOCK_STALE_GRACE seconds of continuous emptiness. A configured
# CMA_QUOTA_CACHE_LOCK_WAIT shorter than that gives up first, so a stale
# pid-less lock (a holder that died between mkdir and its pid write) would
# make EVERY later run skip its save, forever.
it "D8: _cma_quota_cache_lock_wait clamps a short wait above CMA_ALIAS_LOCK_STALE_GRACE, leaves a long one alone"
bo_old_grace="$CMA_ALIAS_LOCK_STALE_GRACE"; CMA_ALIAS_LOCK_STALE_GRACE=10
assert_eq "11" "$(CMA_QUOTA_CACHE_LOCK_WAIT=3 _cma_quota_cache_lock_wait)" "wait 3 < grace 10 is clamped to grace+1"
assert_eq "11" "$(CMA_QUOTA_CACHE_LOCK_WAIT=0 _cma_quota_cache_lock_wait)" "wait 0 is clamped too (a fail-fast wait could never break a stale lock)"
assert_eq "11" "$(CMA_QUOTA_CACHE_LOCK_WAIT=junk _cma_quota_cache_lock_wait)" "an invalid wait falls back to the default, then is clamped"
assert_eq "30" "$(CMA_QUOTA_CACHE_LOCK_WAIT=30 _cma_quota_cache_lock_wait)" "a wait already longer than the grace is unchanged"
CMA_ALIAS_LOCK_STALE_GRACE="$bo_old_grace"

it "D8: a stale pid-less quota-cache lock is broken and the save proceeds, even with a configured wait shorter than the grace"
rm -f "$bo_cache"
rm -rf "$bo_lockdir/.aliases.lockdir"
mkdir -p "$bo_lockdir/.aliases.lockdir"   # pid-less: its creator died before writing a pid
export CMA_ALIAS_LOCK_NO_FLOCK=1 CMA_QUOTA_CACHE_LOCK_WAIT=1
bo_old_grace="$CMA_ALIAS_LOCK_STALE_GRACE"; CMA_ALIAS_LOCK_STALE_GRACE=2
_cma_quota_probe_all 1 "" quota-race-a >/dev/null 2>"$HOME/.quota-d8-stderr"
CMA_ALIAS_LOCK_STALE_GRACE="$bo_old_grace"
unset CMA_ALIAS_LOCK_NO_FLOCK CMA_QUOTA_CACHE_LOCK_WAIT
d8_keys="$(jq -c '.providers | keys' "$bo_cache" 2>/dev/null)"
rm -rf "$bo_lockdir/.aliases.lockdir"
assert_eq '["quota-race-a"]' "$d8_keys" "the stale lock must be broken and this run's record saved (got '$d8_keys'; stderr: $(cat "$HOME/.quota-d8-stderr" 2>/dev/null))"
d8_warned=0; grep -q 'quota cache lock' "$HOME/.quota-d8-stderr" 2>/dev/null && d8_warned=1
assert_eq "0" "$d8_warned" "no 'save skipped' warning once the stale lock is recovered"

# --- N2: the busy warning reports the OBSERVED wait, not the configured one --
# A caller already holding the alias lock is refused AT ONCE (the helper is
# single-slot). The old warning still claimed "busy for <configured>s",
# describing a wait that never happened.
it "N2: an immediately refused cache lock warns with the real elapsed wait, not the configured limit"
rm -f "$bo_cache"
( _cma_alias_lock_depth=1; _cma_quota_probe_all 1 "" quota-race-a >/dev/null 2>"$HOME/.quota-n2-stderr" )
n2_msg="$(grep 'quota cache lock' "$HOME/.quota-n2-stderr" 2>/dev/null)"
n2_ok=0; grep -Eq 'quota cache lock not acquired after [01]s \(limit [0-9]+s\)' <<<"$n2_msg" && n2_ok=1
assert_eq "1" "$n2_ok" "warning must state the observed elapsed time and the limit separately (got: $n2_msg)"
n2_bad=0; grep -q 'busy for' <<<"$n2_msg" && n2_bad=1
assert_eq "0" "$n2_bad" "warning must not claim a configured-length wait that never happened (got: $n2_msg)"
n2_saved=0; [[ -f "$bo_cache" ]] && n2_saved=1
assert_eq "0" "$n2_saved" "a refused lock still skips the save (got cache file present=$n2_saved)"

# --- B-orchestrator: F2 cached-branch windows guard -------------------------
#
# The cached branch replayed whatever record the loader handed it, so a
# windowless record (the pre-F2 v1.30.0 shape: windows:[] + absence_reason
# null) became data_source:"cached" with NO windows and NO absence reason --
# a row violating the windows-XOR-absence_reason invariant that renders blank.
# quota_probe.py's load filter now drops such records, but the orchestrator
# must not depend on every loader it may be paired with (LIB_DIR override,
# version skew): it re-checks the invariant itself before replaying. The stub
# loader above deliberately does NOT filter, which is exactly that pairing.
it "B-orchestrator F2: a cached record with no windows is NOT replayed; the orchestrator re-probes live"
bo_now="$(date +%s)"
jq -n --argjson now "$bo_now" '{_cache_version: 2, _cached_at: $now, providers: {
  "quota-f2-fixture": {provider_id: "quota-f2-fixture", windows: [], account_blocked: false,
                       absence_reason: null, http_status: 200, _cached_at: $now}}}' > "$bo_cache"
bo_row="$(_cma_quota_probe_all 0 "" quota-f2-fixture 2>/dev/null | jq -c 'select(.provider_id=="quota-f2-fixture")')"
bo_f2_src="$(echo "$bo_row" | jq -r '.data_source')"
bo_f2_nwin="$(echo "$bo_row" | jq -r '.windows | length')"
assert_eq "live" "$bo_f2_src" "a windowless cached record must force a live re-probe, never be replayed as cached (row: $bo_row)"
f7_f2_row="$bo_row"   # kept for the F7 all-rows invariant check below
assert_eq "1" "$bo_f2_nwin" "the re-probed row carries the live probe's real window"

it "B-orchestrator F2: a cached record WITH windows is still replayed (guard is not over-broad)"
jq -n --argjson now "$bo_now" '{_cache_version: 2, _cached_at: $now, providers: {
  "quota-f2-fixture": {provider_id: "quota-f2-fixture", account_blocked: false, absence_reason: null,
    windows: [{window:"subscription", amount_used:3, amount_remaining:7, limit_total:10, unit:"credits",
               percent_remaining:70.0, resets:false, reset_at:null}], http_status: 200, _cached_at: $now}}}' > "$bo_cache"
bo_row="$(_cma_quota_probe_all 0 "" quota-f2-fixture 2>/dev/null | jq -c 'select(.provider_id=="quota-f2-fixture")')"
assert_eq "cached" "$(echo "$bo_row" | jq -r '.data_source')" "a valid cached record must still be served from cache"
assert_eq "7" "$(echo "$bo_row" | jq -r '.windows[0].amount_remaining')" "the cached window value round-trips"

# --- F7-orchestrator-invariant: windows XOR absence_reason on EVERY real row --
# The cached-replay guard above checks the invariant for one hand-built
# record. This checks it across every row _cma_quota_probe_all actually
# produced in this file -- not-reported, probe_failed, live, cached, native,
# batched, no-timeout, and the F2 re-probe -- so a regression in ANY branch
# (cached replay, live, synthesized failure, native) that emits a row with
# both or neither is caught. The row count is asserted too, so an empty
# capture cannot pass vacuously.
it "F7: every row _cma_quota_probe_all produced in this file has windows XOR absence_reason"
f7_rows="$(printf '%s\n' "$probe_out" "$t029_out" "$batch_out" "$nt_out" "$bo_out" "$f7_f2_row" \
  | jq -c 'select(type=="object")' 2>/dev/null)"
f7_total="$(printf '%s\n' "$f7_rows" | grep -c .)"
f7_bad="$(printf '%s\n' "$f7_rows" | jq -c 'select((((.windows // []) | length) > 0) == (.absence_reason != null))' 2>/dev/null)"
f7_ok=0; (( f7_total >= 10 )) && f7_ok=1
assert_eq "1" "$f7_ok" "the invariant sweep must cover a real population of rows (got $f7_total), never pass on an empty capture"
assert_eq "" "$f7_bad" "no row may carry both windows and an absence_reason, or neither"

# --- T22-flag-specificity: --fresh is the thing that changes behaviour ------
# The T012 test near the top of this file only shows `cmd_quota --fresh`
# exits 0, which a parser that silently DROPS the flag also does. Here the
# SAME fixture is queried twice through the real cmd_quota entry point, and
# the flag is the only difference between the two calls: a fresh, windowed
# cache record (amount_remaining 7) is on disk, and the stub live probe
# reports amount_remaining 9 and logs every invocation. Without --fresh the
# cached value must be served and the probe must NOT run; with --fresh the
# probe must run exactly once and its live value must be served.
it "T22: cmd_quota WITHOUT --fresh serves the cached record and never launches the probe"
jq -n --argjson now "$(date +%s)" '{_cache_version: 2, _cached_at: $now, providers: {
  "quota-f2-fixture": {provider_id: "quota-f2-fixture", account_blocked: false, absence_reason: null,
    windows: [{window:"subscription", amount_used:3, amount_remaining:7, limit_total:10, unit:"credits",
               percent_remaining:70.0, resets:false, reset_at:null}], http_status: 200, _cached_at: $now}}}' > "$bo_cache"
export BO_PROBE_LOG="$HOME/.quota-t22-probe.log"
rm -f "$BO_PROBE_LOG"
t22_plain="$(cmd_quota quota-f2-fixture --json 2>/dev/null)"
t22_plain_runs="$(grep -cx 'quota-f2-fixture' "$BO_PROBE_LOG" 2>/dev/null)"
assert_eq "cached" "$(echo "$t22_plain" | jq -r '.rows[0].data_source' 2>/dev/null)" "no --fresh: the row is served from the cache"
assert_eq "7" "$(echo "$t22_plain" | jq -r '.rows[0].windows[0].amount_remaining' 2>/dev/null)" "no --fresh: the CACHED value (7) is shown"
assert_eq "0" "${t22_plain_runs:-0}" "no --fresh: the live probe subprocess never ran"

it "T22: cmd_quota WITH --fresh bypasses the same cached record and launches the probe exactly once"
rm -f "$BO_PROBE_LOG"
t22_fresh="$(cmd_quota quota-f2-fixture --json --fresh 2>/dev/null)"
t22_fresh_runs="$(grep -cx 'quota-f2-fixture' "$BO_PROBE_LOG" 2>/dev/null)"
assert_eq "live" "$(echo "$t22_fresh" | jq -r '.rows[0].data_source' 2>/dev/null)" "--fresh: the row comes from a live probe, not the cache"
assert_eq "9" "$(echo "$t22_fresh" | jq -r '.rows[0].windows[0].amount_remaining' 2>/dev/null)" "--fresh: the LIVE value (9) is shown, not the cached 7"
assert_eq "1" "${t22_fresh_runs:-0}" "--fresh: the live probe subprocess ran exactly once for this provider"
unset BO_PROBE_LOG

unset LIB_DIR BO_LOAD_SLEEP; export CMA_QUOTA_ENDPOINTS_FILE="$t028_spec"   # restore T028 isolation

# --- Kimi native usage windows (the /coding/v1/usages endpoint) -------------
#
# A signed-in Kimi native account reports two rolling windows, read from the
# usages endpoint's `usages.limit_5h` / `usages.limit_7d` objects (integer
# used_ratio + string reset_time). Hermetic: its OWN mktemp HOME with a FAKE
# credential file (never the real ~/.kimi-code-*), and a loopback stub that
# CMA_KIMI_USAGE_BASE_URL points at. The stub records each request's method,
# path, and whether the bearer equalled the fake ACCESS token -- never the
# token itself. No refresh flow exists: a 401 is reported as auth_expired and
# the stub must see exactly ONE request.
kn_home="$(mktemp -d "${TMPDIR:-/tmp}/cma-test.kn.XXXXXX")"
kn_acct="$kn_home/.kimi-code-kn1"
mkdir -p "$kn_acct/credentials"
printf 'x = 1\n' > "$kn_acct/config.toml"
kn_access="fixture-kimi-access-DO-NOT-PRINT-7f3a"
kn_refresh="$(_d2_jwt "{\"exp\":$(( $(date +%s) + 198 * 3600 ))}")"
jq -nc --arg at "$kn_access" --arg rt "$kn_refresh" \
  '{access_token:$at, expires_at:1, expires_in:900, refresh_token:$rt, scope:"kimi-code", token_type:"Bearer"}' \
  > "$kn_acct/credentials/kimi-code.json"

cat > "$kn_home/stub.py" <<'PYEOF'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
home = sys.argv[1]
expect = "Bearer " + os.environ["KN_EXPECT_ACCESS"]
OK_BODY = {
    "usages": {
        "limit_5h": {"used_ratio": 0.25, "reset_time": "2026-10-05T17:00:00Z"},
        "limit_7d": {"used_ratio": 1, "reset_time": "2026-10-10T00:00:00Z"},
    },
    "usage": {"limit": "100", "used": "25", "remaining": "75", "resetTime": "2026-10-05T17:00:00Z"},
    "limits": [{"window": {"duration": "300"}, "detail": {"limit": "100", "remaining": "75"}}],
}
class H(BaseHTTPRequestHandler):
    def _handle(self):
        auth = self.headers.get("Authorization")
        tag = "access" if auth == expect else ("none" if auth is None else "other")
        with open(os.path.join(home, "stub.log"), "a") as f:
            f.write("%s %s auth=%s\n" % (self.command, self.path, tag))
        with open(os.path.join(home, "stub.mode")) as f:
            mode = f.read().strip()
        if mode == "401":
            body, code = {"error": "unauthorized"}, 401
        else:
            body, code = OK_BODY, 200
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
    do_GET = _handle
    do_POST = _handle
    def log_message(self, *a):
        pass
srv = HTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(home, "stub.port.tmp"), "w") as f:
    f.write(str(srv.server_address[1]))
os.replace(os.path.join(home, "stub.port.tmp"), os.path.join(home, "stub.port"))
srv.serve_forever()
PYEOF
printf 'ok\n' > "$kn_home/stub.mode"
KN_EXPECT_ACCESS="$kn_access" python3 "$kn_home/stub.py" "$kn_home" </dev/null >/dev/null 2>&1 &
kn_stub_pid=$!
for _kn_i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [[ -s "$kn_home/stub.port" ]] && break
  sleep 0.25
done
kn_port="$(cat "$kn_home/stub.port" 2>/dev/null)"
assert_eq "1" "$([[ "$kn_port" =~ ^[0-9]+$ ]] && echo 1 || echo 0)" "precondition: the loopback usages stub is listening"

_kn_probe() {   # runs the native-row probe for kn1 under the fixture HOME; prints stdout+stderr
  (
    export HOME="$kn_home"
    export CMA_KIMI_USAGE_BASE_URL="http://127.0.0.1:$kn_port/coding/v1"
    _cma_quota_probe_all 1 "" "kn1" 2>&1
  )
}

it "Kimi native: a signed-in account with the documented usages shape yields TWO windows (subscription_5h, subscription_7d)"
rm -f "$kn_home/stub.log"; printf 'ok\n' > "$kn_home/stub.mode"
kn_out="$(_kn_probe)"
kn_row="$(echo "$kn_out" | jq -c 'select(.family=="kimi" and .account_id=="kn1")' 2>/dev/null)"
assert_eq "2" "$(echo "$kn_row" | jq -r '.windows | length' 2>/dev/null)" "two windows reported"
assert_eq "subscription_5h,subscription_7d" "$(echo "$kn_row" | jq -r '[.windows[].window] | join(",")' 2>/dev/null)" "window names"
assert_eq "null" "$(echo "$kn_row" | jq -r '.absence_reason' 2>/dev/null)" "no absence_reason on a successful probe"
assert_eq "75" "$(echo "$kn_row" | jq -r '.windows[0].percent_remaining' 2>/dev/null)" "5h: percent_remaining = 100 - 0.25*100"
assert_eq "0" "$(echo "$kn_row" | jq -r '.windows[1].percent_remaining' 2>/dev/null)" "7d: integer used_ratio 1 -> percent_remaining 0"
assert_eq "2026-10-05T17:00:00Z" "$(echo "$kn_row" | jq -r '.windows[0].reset_at' 2>/dev/null)" "5h: reset_at from reset_time"
assert_eq "2026-10-10T00:00:00Z" "$(echo "$kn_row" | jq -r '.windows[1].reset_at' 2>/dev/null)" "7d: reset_at from reset_time"
assert_eq "true" "$(echo "$kn_row" | jq -r '.windows[0].resets' 2>/dev/null)" "5h: resets=true"
assert_eq "access" "$(sed -n 1p "$kn_home/stub.log" 2>/dev/null | sed 's/.*auth=//')" "the request carried the CURRENT access token as bearer"
assert_eq "GET /coding/v1/usages" "$(sed -n 1p "$kn_home/stub.log" 2>/dev/null | sed 's/ auth=.*//')" "exactly the usages endpoint was requested"
echo "$kn_out" | grep -qF "$kn_access" && kn_leak=1 || kn_leak=0
assert_eq "0" "$kn_leak" "the access token never appears in output"

it "Kimi native windows render through the existing severity path (text + json)"
kn_txt="$(printf '%s\n' "$kn_row" | _cma_quota_render_text --no-color)"
echo "$kn_txt" | grep -E '^  subscription_5h ' | grep -q '\[GREEN\]' && kn_ok=1 || kn_ok=0
assert_eq "1" "$kn_ok" "5h at 75% left renders [GREEN], got: $kn_txt"
echo "$kn_txt" | grep -E '^  subscription_7d ' | grep -q '\[LIMIT_EXCEEDED\]' && kn_ok=1 || kn_ok=0
assert_eq "1" "$kn_ok" "7d at 0% left renders [LIMIT_EXCEEDED], got: $kn_txt"
assert_eq "green,limit_exceeded" "$(printf '%s\n' "$kn_row" | _cma_quota_render_json | jq -r '[.rows[0].windows[].severity] | join(",")' 2>/dev/null)" "json severity per window"

it "Kimi native: a 401 yields auth_expired with the exact detail and makes NO refresh call (one request only)"
rm -f "$kn_home/stub.log"; printf '401\n' > "$kn_home/stub.mode"
kn_out="$(_kn_probe)"
kn_row="$(echo "$kn_out" | jq -c 'select(.family=="kimi" and .account_id=="kn1")' 2>/dev/null)"
assert_eq "auth_expired" "$(echo "$kn_row" | jq -r '.absence_reason' 2>/dev/null)" "401 -> absence_reason auth_expired"
assert_eq 'Kimi access token expired: run `kimi login` to refresh' "$(echo "$kn_row" | jq -r '.absence_detail' 2>/dev/null)" "exact detail"
assert_eq "0" "$(echo "$kn_row" | jq -r '.windows | length' 2>/dev/null)" "no windows on 401"
assert_eq "1" "$(wc -l < "$kn_home/stub.log" 2>/dev/null | tr -d ' ')" "exactly ONE request reached the stub (no retry, no refresh)"
grep -qiE 'refresh|oauth|token' "$kn_home/stub.log" 2>/dev/null && kn_ref=1 || kn_ref=0
assert_eq "0" "$kn_ref" "no refresh/oauth/token endpoint was hit"
assert_eq "GET /coding/v1/usages auth=access" "$(cat "$kn_home/stub.log" 2>/dev/null)" "the single request was the usages GET with the access token"
echo "$kn_out" | grep -qF "$kn_access" && kn_leak=1 || kn_leak=0
assert_eq "0" "$kn_leak" "the access token never appears in output"

kill "$kn_stub_pid" 2>/dev/null; wait "$kn_stub_pid" 2>/dev/null
rm -rf "$kn_home"

it "claude-providers --help includes the quota subcommand documentation (I5)"
help_output="$(bash "$SCRIPTS_DIR/claude-providers.sh" --help 2>&1)"
echo "$help_output" | grep -q "quota" && found=1 || found=0
assert_eq "1" "$found" "claude-providers --help must mention quota"

summary
