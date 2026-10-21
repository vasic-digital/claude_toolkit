#!/usr/bin/env bash
# test_mutation_residue.sh — refuse to ship a mutation left behind by testing.
#
# Why this exists (a real incident, not a hypothetical):
#
# Proving a test has teeth means temporarily breaking the code it guards and
# confirming the test fails — mutation testing. The danger is the restore step:
# it is manual, and a mutation that survives it is a silent, shipped defect that
# every test still passes over, because the mutation's whole purpose was to be
# invisible to everything except the one test being probed.
#
# During the v1.23.1 launch-path work an independent reviewer mutated
#   claude-code-router:cmd/ccr/launch.go
#     -  if surface == "app" {
#     +  if surface == "app" && false {
# to prove TestLaunchRejectsAppSurface had teeth. `&& false` makes the branch
# unreachable — the guard is dead, `ccr <profile> app` would silently launch the
# terminal agent instead of refusing. It was caught by a manual scan. This test
# replaces that luck with a gate.
#
# Scope: production sources only. Test files are excluded deliberately — a test
# may legitimately contain the literal string "MUTATED" as fixture data (e.g.
# internal/gateway/wiring_test.go asserts a config value is NOT overwritten by
# using "MUTATED" as the sentinel).
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
set +e

# Patterns that are mutation residue in ANY production source. Each is chosen to
# have no legitimate use in this codebase:
#   && false / || true   inside a Go conditional — short-circuits a guard
#   always pass / always return — the classic "make this gate green" mutation
#   MUTATED for paired   — the constitutional paired-mutation marker
#   _mutated_            — mutated-file naming convention
RESIDUE_RE='&& false|\|\| true \{|// *always (pass|return)|MUTATED for paired|_mutated_'

it "no mutation residue in the bundled Go router's production sources"
# ANTI-VACUOUS: the grep below suppresses stderr and treats NO OUTPUT as the
# pass. An unchecked-out submodule, a renamed cmd//internal layout or a typo in
# either path produces exactly that same silence. Count the corpus first — a
# clean bill of health is only meaningful over a non-empty set of files.
# The router is a FLAT checkout located by the single resolver (not a submodule
# of this repo any more). Unresolvable => ROUTER_DIR is a non-existent marker
# path and the anti-vacuous corpus count below FAILs loudly.
ROUTER_DIR="$(bash "$SCRIPTS_DIR/resolve_deps.sh" claude_code_router "$REPO_ROOT")" \
  || ROUTER_DIR="<claude_code_router not resolvable>"
_go_files="$(find "$ROUTER_DIR/cmd" \
  "$ROUTER_DIR/internal" \
  -type f -name '*.go' 2>/dev/null | grep -c . || true)"
cond=1; [[ "${_go_files:-0}" -ge 5 ]] && cond=0
assert_eq 0 "$cond" "the Go residue sweep had sources to read ($_go_files *.go files)"
go_hits="$(grep -rnE "$RESIDUE_RE" \
  "$ROUTER_DIR/cmd" \
  "$ROUTER_DIR/internal" \
  --include='*.go' 2>/dev/null | grep -v '_test\.go:' || true)"
if [[ -z "$go_hits" ]]; then
  _pass "no mutation residue in cmd/ + internal/ (*.go, excluding _test.go)"
else
  _fail "mutation residue found in Go production source" \
    "a mutation-test edit was not restored — the guarded branch is DEAD in shipped code: $go_hits"
fi

it "no mutation residue in toolkit shell scripts"
# `|| true` is a legitimate and pervasive idiom in these scripts (guarding
# pipelines under `set -e`), so it is NOT part of the shell pattern set. Only
# the unambiguous always-pass markers are.
_sh_files="$(find "$SCRIPTS_DIR" -maxdepth 1 -type f -name '*.sh' 2>/dev/null | grep -c . || true)"
cond=1; [[ "${_sh_files:-0}" -ge 5 ]] && cond=0
assert_eq 0 "$cond" "the shell residue sweep had sources to read ($_sh_files *.sh files)"
sh_hits="$(grep -rnE '// *always (pass|return)|# *always (pass|return)|MUTATED for paired|_mutated_' \
  "$SCRIPTS_DIR"/*.sh 2>/dev/null || true)"
if [[ -z "$sh_hits" ]]; then
  _pass "no always-pass / paired-mutation markers in scripts/*.sh"
else
  _fail "mutation residue found in a toolkit script" "$sh_hits"
fi

# Anti-vacuous-pass guard: prove the detector actually detects. A scanner that
# silently matches nothing would report a clean tree forever.
it "the residue detector actually fires (anti-vacuous-pass guard)"
_fx="$(mktemp -d "${TMPDIR:-/tmp}/cma-test.XXXXXX")"
trap '[[ "$(basename "$_fx")" == cma-test.* ]] && rm -rf -- "$_fx"' EXIT
cat > "$_fx/planted.go" <<'EOF'
package main

func guard(surface string) bool {
	if surface == "app" && false {
		return false
	}
	return true
}
EOF
planted="$(grep -rnE "$RESIDUE_RE" "$_fx" --include='*.go' 2>/dev/null | grep -v '_test\.go:' || true)"
if [[ -n "$planted" ]]; then
  _pass "detector flags a planted '&& false' mutation"
else
  _fail "detector is blind" "a planted '&& false' mutation was NOT detected — this gate proves nothing"
fi

summary
