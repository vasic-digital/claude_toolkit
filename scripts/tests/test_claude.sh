#!/usr/bin/env bash
# test_claude.sh — prove claudeN ACCOUNT aliases are untouched by provider code.
#
# The invariant: an account alias must route through `cma_run`, a provider alias
# through `cma_run_provider`, and the two wrapper bodies must not bleed into each
# other — no proxy/transformer machinery inside `cma_run`.
#
# WHY THIS IS SANDBOXED (operator decision, 2026-09-03).
#
# This file used to read the OPERATOR'S LIVE alias file:
#
#     ALIAS_FILE="$HOME/.local/share/claude-multi-account/aliases.sh"
#     [[ -f "$ALIAS_FILE" ]] || { echo "SKIP: no alias file"; exit 0; }
#
# and it asserted on three hardcoded provider names (`poe`, `deepseek`,
# `xiaomi`) that happened to be aliased on one machine. That made a unit-level
# invariant depend on live, mutable, machine-specific state, and it failed for
# reasons that have nothing to do with the invariant:
#
#   * `xiaomi` resolves a key var, but sync reported "provider 'xiaomi' FAILED
#     verification — alias NOT activated", so no alias line was ever written and
#     the assertion failed — on a TRANSIENT UPSTREAM OUTAGE, not a code defect.
#   * `poe` also fails verification, yet its alias line PERSISTS from an earlier
#     sync. So the file is a mixture of current and HISTORICAL state, and the
#     test could equally pass on a stale alias — green for the wrong reason.
#
# Both failure modes are the same root cause: reading live state to check a
# property of GENERATED code. So the alias file is now generated inside a
# sandbox from a KNOWN set of accounts and providers, using the very emitters
# the product uses (`cma_write_alias` / `cma_provider_write_alias`). The
# invariant is unchanged; what changed is that it is now decided by this repo's
# code instead of by whatever the host last synced.
#
# The provider names are deliberately synthetic. Naming real providers was
# never part of the invariant — any provider alias must use the provider
# wrapper — and hardcoding three real ones is what tied the test to a
# particular machine's rotation in the first place.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
export SCRIPTS_DIR

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox            # exports HOME + ALIAS_FILE into the sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e

ACCOUNTS=(claude1 claude2 claude3)
PROVIDERS=(provalpha prov-beta prov_gamma)

# Generate the alias file through the product's own writers.
cma_ensure_alias_file >/dev/null 2>&1
for i in 1 2 3; do
  make_account "acct$i" >/dev/null 2>&1
  cma_write_alias "claude$i" "$HOME/${ACCOUNT_PREFIX}acct$i" >/dev/null 2>&1
done
for p in "${PROVIDERS[@]}"; do
  cma_provider_write_alias "$p" "$p" >/dev/null 2>&1
done

# Extract a full wrapper body. A fixed `grep -A<N>` window silently missed
# markers near the end once the cma_run body grew (apply-color, v1.10.0) — the
# push call slipped past -A30. Anchor on the function header and stop at its
# closing brace (column-0 `}`), like the other suites do.
#
# Each body is extracted ONCE to a file, and every check greps that FILE rather
# than piping the extractor into `grep -q`. That is not a style preference: with
# `pipefail` on, `grep -q` exits the moment it matches, awk then dies of SIGPIPE,
# and the pipeline reports 141 — so a check whose pattern IS present fails, and
# whether it fails at all depends on which process wins the race. Measured: this
# turned "cma_run_provider has proxy detection" red with got=141 while the
# identical shape two checks earlier passed. No pipe, no race.
_BODY_RUN="$HOME/body.cma_run"
_BODY_PROV="$HOME/body.cma_run_provider"
awk '/^cma_run\(\) ?\{/{f=1} f{print} f&&/^}/{exit}'          "$ALIAS_FILE" > "$_BODY_RUN"
awk '/^cma_run_provider\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE" > "$_BODY_PROV"
_cma_run_body()  { cat "$_BODY_RUN"; }
_cma_prov_body() { cat "$_BODY_PROV"; }

# ---------------------------------------------------------------------------
# 0. GUARD THE NEGATIVE ASSERTIONS.
#
# Two checks below are of the form `grep -q …; assert_eq 1 $?` — "this pattern
# must be ABSENT". Those PASS on an EMPTY body. So if the alias file failed to
# generate, or the awk extraction stopped matching after a rename, they would
# report green while proving nothing at all. Prove the inputs are real first.
# ---------------------------------------------------------------------------
it "the sandbox alias file generated, with both wrappers and a non-empty body"
assert_file "$ALIAS_FILE" "generated alias file"
assert_eq 1 "$(grep -cF 'cma_run_provider()' "$ALIAS_FILE")" "cma_run_provider defined exactly once"
_run_n="$(_cma_run_body | wc -l)"; _run_n="${_run_n// /}"
if (( _run_n > 5 )); then _pass "cma_run body extracted ($_run_n lines)"
else _fail "cma_run body did not extract" "got $_run_n lines — every 'must be absent' check below would pass vacuously"; fi
_prov_n="$(_cma_prov_body | wc -l)"; _prov_n="${_prov_n// /}"
if (( _prov_n > 5 )); then _pass "cma_run_provider body extracted ($_prov_n lines)"
else _fail "cma_run_provider body did not extract" "got $_prov_n lines"; fi

# ---------------------------------------------------------------------------
# 1. The two wrapper bodies keep their own concerns.
# ---------------------------------------------------------------------------
it "cma_run has sync-state pull"
grep -q 'claude-sync-state.*pull' "$_BODY_RUN"
assert_eq 0 $? "cma_run has pull"

it "cma_run has sync-state push"
grep -q 'claude-sync-state.*push' "$_BODY_RUN"
assert_eq 0 $? "cma_run has push"

it "cma_run has NO proxy code"
grep -q '_proxy_script\|_proxy_pid\|cleancache\|streamoptions' "$_BODY_RUN"
assert_eq 1 $? "cma_run clean: no proxy code"

it "cma_run has NO transformer code"
grep -q 'transformer' "$_BODY_RUN"
assert_eq 1 $? "cma_run clean: no transformer"

it "cma_run_provider has proxy detection"
grep -q '_proxy_script\|_proxy_pid' "$_BODY_PROV"
assert_eq 0 $? "cma_run_provider has proxy detection"

# ---------------------------------------------------------------------------
# 2. Each alias routes through the wrapper for its OWN kind.
# ---------------------------------------------------------------------------
for a in "${ACCOUNTS[@]}"; do
  it "$a uses cma_run (not cma_run_provider)"
  _line="$(grep "^alias $a=" "$ALIAS_FILE")"
  grep -q 'cma_run"' <<<"$_line"
  assert_eq 0 $? "$a uses cma_run"
  # And explicitly NOT the provider wrapper — the bug this file exists to catch
  # is an account alias silently acquiring provider routing.
  grep -q 'cma_run_provider' <<<"$_line"
  assert_eq 1 $? "$a does NOT use cma_run_provider"
done

for a in "${PROVIDERS[@]}"; do
  it "$a uses cma_run_provider"
  grep -q 'cma_run_provider' <<<"$(grep "^alias $a=" "$ALIAS_FILE")"
  assert_eq 0 $? "$a uses cma_run_provider"
done

summary
