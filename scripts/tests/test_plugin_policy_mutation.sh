#!/usr/bin/env bash
# test_plugin_policy_mutation.sh -- paired mutation proof for test_plugin_policy.sh
# (Constitution 1.1). A copy of scripts/ is mutated one line at a time; the
# plugin-policy test MUST fail against every mutant and MUST pass on the
# unmutated copy (control), otherwise the test proves nothing.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/assert.sh"
command -v python3 >/dev/null || { _skip "python3 missing"; summary; exit $?; }

W="$(mktemp -d "${TMPDIR:-/tmp}/cma-mut.XXXXXX")"; trap 'rm -rf "$W"' EXIT

run_copy() { # name file old new  -> echoes rc of the policy test on the mutated copy
  local name="$1" file="$2" old="$3" new="$4" d="$W/$1"
  mkdir -p "$d"; cp -R "$SCRIPTS_DIR" "$d/scripts"
  if [[ -n "$file" ]]; then
    python3 - "$d/scripts/$file" "$old" "$new" <<'PY' || return 99
import sys
p,old,new=sys.argv[1:4]
s=open(p).read()
if old not in s: sys.exit(1)
open(p,'w').write(s.replace(old,new,1))
PY
  fi
  ( cd "$d/scripts/tests" && bash test_plugin_policy.sh >/dev/null 2>&1 ); echo $?
}

it "control: the unmutated copy passes"
assert_eq 0 "$(run_copy control '' '' '')" "control rc"

mut() { local rc; rc="$(run_copy "$1" "$2" "$3" "$4")"; if [[ "$rc" != 0 && "$rc" != 99 ]]; then _pass "mutant $1 killed (rc=$rc)"; else _fail "mutant $1 SURVIVED or did not apply (rc=$rc)"; fi; }

it "mutants are killed"
mut M1-unknown-stays-enabled   lib.sh '((.enabledPlugins // {}) | map_values(false))' '((.enabledPlugins // {}))'
mut M2-source-not-protected    lib.sh '  [[ "$d" == "$src" ]]' '  false'
mut M3-seed-ignores-policy     lib.sh '    cma_policy_enforce_settings "$cdir" >/dev/null || true
    return 0' '    return 0'
mut M4-unify-reenables         claude-unify.sh '    cma_policy_enforce_settings "$SHARED_DIR" >/dev/null || true' '    :'
mut M5a-sync-all-hook-removed  claude-sync-state.sh '  all)
    cma_merge_claude_json "${ALL_ACCOUNTS[@]}"
    cma_policy_enforce_all' '  all)
    cma_merge_claude_json "${ALL_ACCOUNTS[@]}"'
mut M5b-sync-pull-hook-removed claude-sync-state.sh '    cma_merge_claude_json "${ALL_ACCOUNTS[@]}"
    cma_policy_enforce_all   # v1.34.0' '    cma_merge_claude_json "${ALL_ACCOUNTS[@]}"
    : # v1.34.0'
mut M6-mcp-replace-not-union   lib.sh '((.disabledMcpServers // []) + $p[0].disabledMcpServers)' '$p[0].disabledMcpServers'
mut M7-no-refresh-from-source  lib.sh '  if [[ "$src/settings.json" -nt "$pf" || "$src/.claude.json" -nt "$pf" ]]; then' '  if false; then'
mut M8-apply-without-write     lib.sh '  if cma_jq_edit "$f" --slurpfile p "$pf" "$flt"; then echo changed; return 0; fi' '  echo changed; return 0'
mut M9-off-switch-ignored      lib.sh '  [[ "${CMA_PLUGIN_POLICY:-on}" != off ]] || return 1' '  :'

summary
