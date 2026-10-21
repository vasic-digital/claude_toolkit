#!/usr/bin/env bash
# test_resolve_deps.sh — coverage for scripts/resolve_deps.sh (single-source
# dependency resolver). Hermetic: builds fixture trees in a temp dir, never
# touches the real hub. Proves (1) nested-in-hub resolution, (2) env override
# precedence and its loud failure, (3) loud non-zero failure when nothing
# resolves, (4) that .gitmodules no longer declares the hub-owned duplicates.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"

RESOLVER="$SCRIPTS_DIR/resolve_deps.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/cma-resolve.XXXXXX")"
trap 'rm -rf "$W"' EXIT
set +e

mkhub() {  # mkhub <dir>: a hub with constitution + flat submodules
  mkdir -p "$1/constitution" "$1/submodules/containers" "$1/submodules/challenges" \
           "$1/submodules/superspec" "$1/submodules/claude_toolkit"
  : > "$1/constitution/Constitution.md"
  for n in containers challenges superspec; do : > "$1/submodules/$n/marker"; done
}
# run resolver for <name> against toolkit root <root>, hermetic env
res() { local root="$1" name="$2"; shift 2
  env -u CT_CONSTITUTION_DIR -u CT_CONTAINERS_DIR -u CT_CHALLENGES_DIR -u CT_SUPERSPEC_DIR \
      CT_HOST_CONSTITUTION_FALLBACK="$W/no-such-host-fallback" "$@" \
      bash "$RESOLVER" "$name" "$root"; }

it "resolver script exists and is executable"
assert_file "$RESOLVER" "resolve_deps.sh present"
[[ -x "$RESOLVER" ]] && _pass "executable" || _fail "not executable" "$RESOLVER"

it "nested at <hub>/submodules/claude_toolkit: all four deps resolve from the hub"
mkhub "$W/hub"
for n in constitution containers challenges superspec; do
  out="$(res "$W/hub/submodules/claude_toolkit" "$n" 2>&1)"; rc=$?
  want="$W/hub/submodules/$n"; [[ $n == constitution ]] && want="$W/hub/constitution"
  assert_eq 0 "$rc" "$n: exit 0"
  assert_eq "$want" "$out" "$n: resolved path"
done

it "nested at <hub>/constitution/submodules/claude_toolkit: constitution is the hub itself, flat deps come from the project root"
mkdir -p "$W/proj/constitution/submodules/claude_toolkit" "$W/proj/submodules/containers"
: > "$W/proj/constitution/Constitution.md"; : > "$W/proj/submodules/containers/marker"
out="$(res "$W/proj/constitution/submodules/claude_toolkit" constitution 2>&1)"; rc=$?
assert_eq 0 "$rc" "constitution: exit 0"; assert_eq "$W/proj/constitution" "$out" "constitution path"
out="$(res "$W/proj/constitution/submodules/claude_toolkit" containers 2>&1)"; rc=$?
assert_eq 0 "$rc" "containers: exit 0"; assert_eq "$W/proj/submodules/containers" "$out" "containers path"

it "env override wins over the hub"
mkdir -p "$W/over"; : > "$W/over/Constitution.md"
out="$(res "$W/hub/submodules/claude_toolkit" constitution CT_CONSTITUTION_DIR="$W/over" 2>&1)"; rc=$?
assert_eq 0 "$rc" "exit 0"; assert_eq "$W/over" "$out" "override path used"

it "an env override that does not resolve fails loudly (no silent fall-through to the hub)"
out="$(res "$W/hub/submodules/claude_toolkit" constitution CT_CONSTITUTION_DIR="$W/bogus" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && _pass "non-zero exit ($rc)" || _fail "expected non-zero" "got 0: $out"
[[ "$out" == *CT_CONSTITUTION_DIR* ]] && _pass "message names the variable" || _fail "message lacks variable" "$out"

it "nothing resolvable => non-zero exit with an actionable message"
mkdir -p "$W/lonely/tool"
for n in constitution containers challenges superspec; do
  out="$(res "$W/lonely/tool" "$n" 2>&1)"; rc=$?
  [[ $rc -ne 0 ]] && _pass "$n: non-zero ($rc)" || _fail "$n: silent pass" "$out"
  [[ "$out" == *"CT_${n^^}_DIR"* ]] && _pass "$n: message names CT_${n^^}_DIR" || _fail "$n: message not actionable" "$out"
done

it "unknown dependency name is rejected"
out="$(res "$W/hub/submodules/claude_toolkit" bogusdep 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && _pass "non-zero ($rc)" || _fail "expected non-zero" "$out"

it "sibling and host-fallback tiers resolve constitution"
mkdir -p "$W/sib/tool" "$W/sib/constitution"; : > "$W/sib/constitution/Constitution.md"
out="$(res "$W/sib/tool" constitution 2>&1)"; rc=$?
assert_eq 0 "$rc" "sibling: exit 0"; assert_eq "$W/sib/constitution" "$out" "sibling path"
mkdir -p "$W/hostfb"; : > "$W/hostfb/Constitution.md"
out="$(res "$W/lonely/tool" constitution CT_HOST_CONSTITUTION_FALLBACK="$W/hostfb" 2>&1)"; rc=$?
assert_eq 0 "$rc" "host fallback: exit 0"; assert_eq "$W/hostfb" "$out" "host fallback path"

it ".gitmodules no longer declares the hub-owned duplicates"
for p in constitution submodules/containers submodules/challenges submodules/superspec; do
  if grep -qE "path = $p\$" "$REPO_ROOT/.gitmodules"; then _fail "still declared: $p"; else _pass "not declared: $p"; fi
  if git -C "$REPO_ROOT" ls-files -s -- "$p" 2>/dev/null | grep -q '^160000'; then _fail "gitlink still present: $p"; else _pass "no gitlink: $p"; fi
done
for p in submodules/LLMsVerifier submodules/claude-code-router submodules/go; do
  grep -qE "path = $p\$" "$REPO_ROOT/.gitmodules" && _pass "own dep kept: $p" || _fail "own dep lost: $p"
done

it "in-repo consumers use the resolver instead of hardcoded constitution/ paths"
grep -q 'resolve_deps.sh' "$TESTS_DIR/test_mechanical_tools_acceptance.sh" \
  && _pass "mechanical acceptance test sources the resolver" || _fail "mechanical acceptance test still hand-rolls resolution"
if grep -qE 'REPO_ROOT/constitution/scripts/mechanical' "$TESTS_DIR/test_mechanical_tools_acceptance.sh"; then
  _fail "hardcoded in-tree constitution path remains"; else _pass "no hardcoded in-tree constitution path"; fi

summary
