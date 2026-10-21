#!/usr/bin/env bash
# test_gitmodules_no_ownorg.sh — gate: claude_toolkit tracks NO own-org nested
# submodule (operator decision 2026-10-21; constitution §11.4.28(C)).
#
# Own-org repositories (vasic-digital/*, HelixDevelopment/*) live FLAT in the
# parent project (<root>/submodules or <hub>/constitution/submodules) and are
# found by scripts/resolve_deps.sh. A nested copy here would be a second,
# drifting pin of the same repository. Third-party submodules (submodules/go,
# go.googlesource.com) are allowed.
#
# FAILs when:
#   - any url in .gitmodules points at an own-org repository (ssh, https, or
#     scp-style, github or gitlab, org matched case-insensitively);
#   - a gitlink (mode 160000) is tracked at a path whose name is a known
#     own-org dependency (LLMsVerifier, claude-code-router, constitution, ...).
#
# Mutation proof: CT_TEST_GITMODULES=<file> points the url check at a copy.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
set +e

GM="${CT_TEST_GITMODULES:-$REPO_ROOT/.gitmodules}"
OWNORG_RE='(github\.com|gitlab\.com)[:/]+(vasic-digital|helixdevelopment)/'

# own_org_urls <file> — print every url line naming an own-org repository
own_org_urls() {
  [[ -f "$1" ]] || return 0
  grep -iE '^[[:space:]]*url[[:space:]]*=' "$1" | grep -iE "$OWNORG_RE" || true
}

it "the detector sees an own-org url (control needle) and ignores a third-party one"
_needle="$(mktemp "${TMPDIR:-/tmp}/cma-gm.XXXXXX")"
printf '[submodule "x"]\n\tpath = submodules/x\n\turl = git@github.com:vasic-digital/x.git\n' > "$_needle"
[[ -n "$(own_org_urls "$_needle")" ]] && _pass "control needle (vasic-digital ssh) detected" \
  || _fail "detector is blind: control needle not detected" "$_needle"
printf '[submodule "y"]\n\tpath = submodules/y\n\turl = https://GitHub.com/HelixDevelopment/Y.git\n' > "$_needle"
[[ -n "$(own_org_urls "$_needle")" ]] && _pass "control needle (HelixDevelopment https, mixed case) detected" \
  || _fail "detector is blind: HelixDevelopment https needle not detected" "$_needle"
printf '[submodule "go"]\n\tpath = submodules/go\n\turl = https://go.googlesource.com/go\n' > "$_needle"
[[ -z "$(own_org_urls "$_needle")" ]] && _pass "negative control (third-party go) not flagged" \
  || _fail "false positive on a third-party url" "$(own_org_urls "$_needle")"
rm -f "$_needle"

it ".gitmodules declares no own-org repository"
[[ -f "$GM" ]] && _pass ".gitmodules readable: $GM" || _pass "no .gitmodules at all ($GM)"
hits="$(own_org_urls "$GM")"
if [[ -z "$hits" ]]; then _pass "no own-org url in $GM"
else _fail "own-org url(s) still declared in $GM — resolve them flat via scripts/resolve_deps.sh instead" "$hits"; fi

it "no own-org gitlink is tracked in the index"
links="$(git -C "$REPO_ROOT" ls-files -s 2>/dev/null | awk '$1=="160000"{print $4}')"
bad=""
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  case "$(basename "$p" | tr '[:upper:]' '[:lower:]')" in
    llmsverifier|llms_verifier|claude-code-router|claude_code_router|constitution|containers|challenges|helixconstitution)
      bad="$bad $p" ;;
  esac
done <<<"$links"
if [[ -z "$bad" ]]; then _pass "gitlinks tracked: ${links//$'\n'/ } (none own-org)"
else _fail "own-org gitlink(s) tracked:$bad" "git rm them; the parent project vends them flat"; fi

it "no executable script hardcodes the old nested paths (they must use the resolver)"
# Code, not prose: lines that are comments are carriers and are skipped.
# The resolver's own fixtures and this gate are excluded.
# Both the legacy repo names and the canonical snake_case names are covered:
# a hardcoded submodules/llms_verifier bypasses the resolver just as badly.
code_hits="$(grep -rniE 'submodules/(LLMsVerifier|llms_verifier|claude-code-router|claude_code_router)' "$SCRIPTS_DIR" \
    --include='*.sh' --include='*.go' --include='*.py' 2>/dev/null \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(#|//)' \
  | grep -vE '/tests/(test_resolve_deps|test_gitmodules_no_ownorg)\.sh:' || true)"
if [[ -z "$code_hits" ]]; then _pass "no hardcoded nested own-org path in scripts/"
else _fail "hardcoded nested own-org path(s) — use scripts/resolve_deps.sh" "$code_hits"; fi

summary
