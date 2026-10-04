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

it "quota is not yet a case-label in either claude-providers.sh dispatch block"
b1="$(_extract_block1_names "$SCRIPTS_DIR/claude-providers.sh")"
b2="$(_extract_block2_names "$SCRIPTS_DIR/claude-providers.sh")"
if echo "$b1" | grep -qx "quota" || echo "$b2" | grep -qx "quota"; then
  assert_eq "absent" "present" "quota must not already be a dispatch case label before T012 adds it"
else
  assert_eq "absent" "absent" "quota correctly absent from both dispatch blocks (pre-T012 state)"
fi

it "limits is not yet a case-label in either claude-providers.sh dispatch block"
if echo "$b1" | grep -qx "limits" || echo "$b2" | grep -qx "limits"; then
  assert_eq "absent" "present" "limits must not already be a dispatch case label before T012 adds it"
else
  assert_eq "absent" "absent" "limits correctly absent from both dispatch blocks (pre-T012 state)"
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

summary
