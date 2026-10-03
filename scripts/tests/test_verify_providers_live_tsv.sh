#!/usr/bin/env bash
# test_verify_providers_live_tsv.sh — the per-.env TSV read in
# verify_providers_live.sh's main sweep loop must not corrupt id/model/keyvar
# when a field is empty.
#
# Round-3 independent-review sweep (2026-10-03) for the IFS-tab-collapse bug
# class already fixed three times this session in claude-providers.sh/lib.sh:
# tab is a POSIX IFS-whitespace character, so `IFS=$'\t' read` COLLAPSES a
# single empty field into its neighbouring delimiter rather than preserving
# it, shifting every LATER field left by one slot. verify_providers_live.sh's
# main loop iterates EVERY *.env on disk unconditionally (not gated by
# current resolved status), including a degenerate env the provider-rename
# path in claude-providers.sh explicitly documents it can produce ("fields
# that were absent come out empty rather than blocking the move").
#
# This extracts the REAL printf line from the source file via sed (pattern-
# anchored, not a hand-copied duplicate), so the test can never silently
# drift from the live code.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
LEG="$SCRIPTS_DIR/tests/verify_providers_live.sh"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"
set +e

make_sandbox

_printf_line="$(sed -n '/^    printf .%s\\t%s\\t%s\\t%s. /p' "$LEG" | head -1 | sed 's/^[[:space:]]*//')"
[[ -n "$_printf_line" ]] && ok=1 || ok=0
assert_eq 1 "$ok" "the real printf line was found in verify_providers_live.sh (test would otherwise silently test nothing)"

_run_tsv_read() {
  # Args: CMA_PROVIDER_ID CMA_PROVIDER_MODEL CMA_PROVIDER_KEYVAR CMA_PROVIDER_BASE_URL
  # (each possibly empty, mirroring an on-disk .env with an unset field)
  local _id _model _keyvar _base
  CMA_PROVIDER_ID="$1" CMA_PROVIDER_MODEL="$2" CMA_PROVIDER_KEYVAR="$3" CMA_PROVIDER_BASE_URL="$4" \
    bash -c "
      $_printf_line
    " 2>/dev/null \
    | { IFS=$'\t' read -r _id _model _keyvar _base; printf '%s\t%s\t%s\t%s\n' "$_id" "$_model" "$_keyvar" "$_base"; }
}

it "normal case: every field populated -> no corruption (negative control)"
out="$(_run_tsv_read p1 strong-model KEY_VAR https://api.example.test)"
assert_eq "p1	strong-model	KEY_VAR	https://api.example.test" "$out" "all four fields land in their own slots"

it "degenerate env (round-3 finding): empty model -> id/model/keyvar must NOT shift (RED before the fix)"
out="$(_run_tsv_read p2 '' KEY_VAR2 https://api2.example.test)"
IFS=$'\t' read -r r_id r_model r_keyvar r_base <<<"$out"
assert_eq "p2" "$r_id" "id is still p2, never shifted"
assert_eq "null" "$r_model" "empty model reads back as the literal string 'null', never corrupted/absorbing keyvar's value"
assert_eq "KEY_VAR2" "$r_keyvar" "keyvar is NOT shifted left into model's slot"
assert_eq "https://api2.example.test" "$r_base" "base_url is NOT lost/shifted"

it "empty id -> model/keyvar/base_url still correct (id is NOT the last field, so this must also be guarded)"
out="$(_run_tsv_read '' real-model KEY_VAR3 https://api3.example.test)"
IFS=$'\t' read -r r_id r_model r_keyvar r_base <<<"$out"
assert_eq "null" "$r_id" "empty id reads back as the literal string 'null'"
assert_eq "real-model" "$r_model" "model is NOT shifted into id's slot"
assert_eq "KEY_VAR3" "$r_keyvar" "keyvar is NOT shifted"
assert_eq "https://api3.example.test" "$r_base" "base_url is NOT shifted"

it "empty base_url (the LAST field) -> everything before it is unaffected either way (sanity control)"
out="$(_run_tsv_read p4 model4 KEY4 '')"
IFS=$'\t' read -r r_id r_model r_keyvar r_base <<<"$out"
assert_eq "p4" "$r_id" "id correct"
assert_eq "model4" "$r_model" "model correct"
assert_eq "KEY4" "$r_keyvar" "keyvar correct"
assert_eq "" "$r_base" "base_url (last field) is empty, as expected -- nothing after it to shift into"

summary
