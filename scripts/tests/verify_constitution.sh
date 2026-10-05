#!/usr/bin/env bash
# verify_constitution.sh — Tier C: constitution/conformance static checks.
#
# Read-only, no network. Follows the verify_*.sh conventions: NOT named
# test_*.sh (run-all.sh won't auto-pick it), honest SKIP (counted as pass)
# when a precondition is absent, PASS/FAIL tallies via lib/assert.sh, evidence
# written to $PROOF_DIR/45-constitution.txt, nonzero exit if any check FAILs.
#
# Checks (docs/superpowers/specs/2026-07-04-provider-verification-design.md §7.4):
#   CONST-051   submodules/LLMsVerifier carries zero toolkit coupling
#   §11.4.157   AGENTS.md / CLAUDE.md / QWEN.md / GEMINI.md exist and their
#               byte sizes stay within 5% of each other (doc lockstep)
#   §11.4.113   no force-push in any repo script (scripts/, upstreams/)
#   §11.4.156   CI/CD disabled: .github/workflows/ absent-or-empty AND no
#               .gitlab-ci.yml
#   §11.4.151   release-tag prefix consistency (honest SKIP when no
#               .env / env.properties carries a prefix key)
#   fixture independence: scripts/providers/{fixture,rubric} exist, are
#               referenced by scripts/providers-semantic.sh, and do not leak
#               into the submodule (toolkit-owned, project-not-aware submodule)
#
# Path note: §7.4 names this scripts/tests/proof/verify_constitution.sh, but
# proof/ is the evidence OUTPUT dir and every other verifier lives in
# scripts/tests/ — so it lives here (pre-approved deviation).
#
# Knobs:
#   PROOF_DIR      where to write evidence (default scripts/tests/proof)
#   CMA_REPO_ROOT  repo root to check (default: the repo containing this
#                  script) — overridable so hermetic tests can point the
#                  verifier at a fixture repo.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"

CMA_REPO_ROOT="${CMA_REPO_ROOT:-$(cd "$TESTS_DIR/../.." && pwd)}"
# Volatile run output (D1): built in a temp file beside the final path and
# renamed into the git-ignored proof/volatile/ folder only on completion.
# shellcheck source=lib/proof.sh
source "$TESTS_DIR/lib/proof.sh"
PROOF_DIR="${PROOF_DIR:-$(cma_proof_volatile_dir)}"
EV_FINAL="$PROOF_DIR/45-constitution.txt"
EV="$(cma_proof_open "$EV_FINAL")"

set +e  # failing-by-design greps must not abort the run

# --- CONST-051: submodule/toolkit decoupling --------------------------------
it "CONST-051: LLMsVerifier submodule carries zero toolkit coupling"
SUB="$CMA_REPO_ROOT/submodules/LLMsVerifier"
if [[ ! -d "$SUB" ]]; then
  echo "SKIP: submodule not checked out at $SUB"
  echo "CONST-051 SKIP: submodule absent" >> "$EV"
else
  # Whole subtree (minus .git): as of writing, zero hits across all files,
  # so no *_test.go carve-out is needed.
  #
  # ANTI-VACUOUS: "$SUB is a directory" is NOT the same as "$SUB has content".
  # An uninitialised submodule is an empty-but-present dir, and grep over it
  # returns nothing — which is exactly this check's success condition, so the
  # assertion would pass having read zero bytes. Count the files first and
  # require a positive number; only then does an empty hit list mean anything.
  sub_files="$(find "$SUB" -name .git -prune -o -type f -print 2>/dev/null | grep -c . || true)"
  cond=1; [[ "${sub_files:-0}" -ge 20 ]] && cond=0
  assert_eq 0 "$cond" "CONST-051 swept a populated submodule ($sub_files files under $SUB)"
  echo "CONST-051 files swept: $sub_files" >> "$EV"
  # --exclude=.git as well as --exclude-dir=.git: in a WORKTREE checkout a
  # populated submodule's .git is a FILE (a gitdir pointer whose content names
  # the parent repo's path, e.g. .../claude_toolkit/.git/worktrees/...), not a
  # directory — sweeping it is a §11.4.201(7)(a) CARRIER match (git plumbing
  # that MENTIONS the parent path), not a coupling reference in the
  # submodule's own content. The find on line 59 already prunes .git in both
  # shapes; the grep must exclude both shapes too or the two disagree.
  hits="$(grep -rn --exclude-dir=.git --exclude=.git -E 'claude_toolkit|cma_|claude-providers' "$SUB")"
  if [[ -n "$hits" ]]; then printf 'CONST-051 coupling hits:\n%s\n' "$hits" >> "$EV"; fi
  assert_eq "" "$hits" "no claude_toolkit / cma_ / claude-providers references in the submodule"
fi

# --- §11.4.157: governance docs in size lockstep -----------------------------
it "§11.4.157: AGENTS.md / CLAUDE.md / QWEN.md / GEMINI.md exist in size lockstep (±5%)"
docs_ok=1
sizes=()
for d in AGENTS.md CLAUDE.md QWEN.md GEMINI.md; do
  if [[ -f "$CMA_REPO_ROOT/$d" ]]; then
    sizes+=("$(wc -c < "$CMA_REPO_ROOT/$d" | tr -d '[:space:]')")
  else
    docs_ok=0
    echo "§11.4.157 MISSING doc: $d" >> "$EV"
  fi
done
if (( docs_ok == 1 )); then
  min=0 max=0
  for s in "${sizes[@]}"; do
    if (( min == 0 || s < min )); then min=$s; fi
    if (( s > max )); then max=$s; fi
  done
  echo "§11.4.157 doc sizes: ${sizes[*]} (min=$min max=$max)" >> "$EV"
  # All within 5% of each other  <=>  max*100 <= min*105  (integer math).
  if (( max * 100 > min * 105 )); then
    docs_ok=0
    echo "§11.4.157 size drift >5%: min=$min max=$max" >> "$EV"
  fi
fi
assert_eq 1 "$docs_ok" "four governance docs exist and stay within 5% size drift"

# --- §11.4.113: no force-push in repo scripts --------------------------------
it "§11.4.113: no force-push in any repo script"
# ANTI-VACUOUS: a mistyped root, a moved upstreams/ dir or a missing checkout
# all make this grep print nothing — the same output as a clean tree. Prove the
# sweep had a corpus before reading "no hits" as "no force-push".
fp_files="$(find "$CMA_REPO_ROOT/scripts" "$CMA_REPO_ROOT/upstreams" \
  -type f \( -name '*.sh' -o -name '*.py' \) -print 2>/dev/null | grep -c . || true)"
cond=1; [[ "${fp_files:-0}" -ge 20 ]] && cond=0
assert_eq 0 "$cond" "§11.4.113 swept a populated tree ($fp_files .sh/.py files)"
echo "§11.4.113 files swept: $fp_files" >> "$EV"
fp_hits="$(grep -rnE --include='*.sh' --include='*.py' --exclude-dir=proof --exclude-dir=__pycache__ \
  'push[[:space:]]+--force([^A-Za-z]|$)|push[[:space:]]+-[A-Za-z]*f([^A-Za-z]|$)' \
  "$CMA_REPO_ROOT/scripts" "$CMA_REPO_ROOT/upstreams")"
if [[ -n "$fp_hits" ]]; then printf '§11.4.113 force-push hits:\n%s\n' "$fp_hits" >> "$EV"; fi
assert_eq "" "$fp_hits" "no force-push flags under scripts/ or upstreams/"

# --- §11.4.156: CI/CD disabled ------------------------------------------------
it "§11.4.156: CI/CD disabled (.github/workflows absent-or-empty, no .gitlab-ci.yml)"
ci_ok=1
if [[ -d "$CMA_REPO_ROOT/.github/workflows" ]] && compgen -G "$CMA_REPO_ROOT/.github/workflows/*" >/dev/null 2>&1; then
  ci_ok=0
  echo "§11.4.156 .github/workflows/ is populated" >> "$EV"
fi
if [[ -f "$CMA_REPO_ROOT/.gitlab-ci.yml" ]]; then
  ci_ok=0
  echo "§11.4.156 .gitlab-ci.yml present" >> "$EV"
fi
assert_eq 1 "$ci_ok" "CI/CD stays disabled"

# --- §11.4.151: release-tag prefix consistency --------------------------------
it "§11.4.151: release-tag prefix consistency (.env / env.properties)"
envf=""
for cand in "$CMA_REPO_ROOT/.env" "$CMA_REPO_ROOT/env.properties"; do
  if [[ -f "$cand" ]]; then envf="$cand"; break; fi
done
if [[ -z "$envf" ]]; then
  echo "SKIP: no .env / env.properties at repo root — release-tag prefix check not applicable"
  echo "§11.4.151 SKIP: no env file at repo root" >> "$EV"
else
  pline="$(grep -E '^[[:space:]]*[A-Za-z_]*RELEASE[A-Za-z_]*PREFIX[[:space:]]*=' "$envf" 2>/dev/null | head -1)"
  if [[ -z "$pline" ]]; then
    echo "SKIP: $envf carries no release-prefix key"
    echo "§11.4.151 SKIP: no prefix key in $envf" >> "$EV"
  else
    prefix="$(printf '%s' "$pline" | cut -d= -f2- | tr -d "\"'[:space:]")"
    expected="${HELIX_RELEASE_PREFIX:-$(basename "$CMA_REPO_ROOT" | tr '[:upper:]' '[:lower:]')}"
    echo "§11.4.151 prefix=$prefix expected=$expected (file=$envf)" >> "$EV"
    assert_eq "$expected" "$prefix" "release-tag prefix matches HELIX_RELEASE_PREFIX / lowercased root dir"
  fi
fi

# --- semantic-visibility fixture independence --------------------------------
it "semantic-visibility fixture/rubric are toolkit-owned, referenced, and absent from the submodule"
fx_ok=1
if [[ ! -d "$CMA_REPO_ROOT/scripts/providers/fixture" ]]; then
  fx_ok=0; echo "MISSING scripts/providers/fixture/" >> "$EV"
fi
if [[ ! -d "$CMA_REPO_ROOT/scripts/providers/rubric" ]]; then
  fx_ok=0; echo "MISSING scripts/providers/rubric/" >> "$EV"
fi
SEM="$CMA_REPO_ROOT/scripts/providers-semantic.sh"
if [[ -f "$SEM" ]]; then
  if ! grep -q 'providers/fixture' "$SEM"; then
    fx_ok=0; echo "providers-semantic.sh lacks a providers/fixture reference" >> "$EV"
  fi
  if ! grep -q 'providers/rubric' "$SEM"; then
    fx_ok=0; echo "providers-semantic.sh lacks a providers/rubric reference" >> "$EV"
  fi
else
  fx_ok=0; echo "MISSING scripts/providers-semantic.sh" >> "$EV"
fi
if [[ -d "$SUB" ]]; then
  leaked="$(find "$SUB" -name .git -prune -o -type f -name 'code-visibility*' -print 2>/dev/null)"
  if [[ -n "$leaked" ]]; then
    fx_ok=0; printf 'fixture leaked into submodule:\n%s\n' "$leaked" >> "$EV"
  fi
fi
assert_eq 1 "$fx_ok" "fixture/rubric live in scripts/providers/ and are referenced by providers-semantic.sh"

{
  echo "# constitution verification — $(date)"
  echo "repo root: $CMA_REPO_ROOT"
} >> "$EV"

cma_proof_commit "$EV" "$EV_FINAL"
echo "evidence: $EV_FINAL"
summary
