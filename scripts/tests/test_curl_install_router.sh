#!/usr/bin/env bash
# test_curl_install_router.sh — BEHAVIOURAL coverage for curl-install.sh step
# 3b (provision the flat claude-code-router checkout). The step is RUN, with a
# stubbed `git` on PATH that records its argv; nothing touches the network.
#
# curl-install.sh is loaded with CT_CURL_INSTALL_LIB_ONLY=1, which makes it
# define its helpers + provision_flat_router and return before any install
# side effect. Cases:
#   1. router already resolvable -> no git call at all
#   2. no router, no sibling     -> git clone <url> <dirname INSTALL_DIR>/claude_code_router
#   3. sibling repo exists       -> git -C <sibling> pull --ff-only
#   4. clone fails               -> dies non-zero with the actionable message
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
set +e

INSTALL_SCRIPT="${CT_TEST_CURL_INSTALL:-$SCRIPTS_DIR/curl-install.sh}"   # override only for mutation proofs
W="$(mktemp -d "${TMPDIR:-/tmp}/cma-curlccr.XXXXXX")"
trap 'rm -rf "$W"' EXIT

mkdir -p "$W/bin"
cat > "$W/bin/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GIT_STUB_LOG"
[[ "${GIT_STUB_FAIL:-0}" == 1 ]] && exit 128
exit 0
EOF
chmod +x "$W/bin/git"

# run_case <name> [VAR=val ...] — fresh fixture: <case>/home/claude-toolkit with the real resolver
run_case() {
  local c="$1"; shift
  local base="$W/$c/home"
  mkdir -p "$base/claude-toolkit/scripts"
  cp "$SCRIPTS_DIR/resolve_deps.sh" "$base/claude-toolkit/scripts/"
  : > "$W/$c.log"
  env -u CT_CLAUDE_CODE_ROUTER_DIR -u CT_LLMS_VERIFIER_DIR -u LLMSVERIFIER_DIR \
      PATH="$W/bin:$PATH" GIT_STUB_LOG="$W/$c.log" HOME="$base" \
      CLAUDE_TOOLKIT_DIR="$base/claude-toolkit" CT_CURL_INSTALL_LIB_ONLY=1 "$@" \
      bash -c 'source "$1" || exit 97; provision_flat_router' _ "$INSTALL_SCRIPT" 2>&1
}

it "curl-install.sh can be loaded as a library (no install side effects)"
out="$(run_case lib 2>&1)"; rc=$?
assert_eq 0 "$rc" "sourced in library mode and provision_flat_router ran (rc)"

it "router already resolvable (sibling with identity marker) -> no git call"
mkdir -p "$W/res/home/claude_code_router/cmd/ccr"
: > "$W/res/home/claude_code_router/go.mod"; : > "$W/res/home/claude_code_router/cmd/ccr/main.go"
out="$(run_case res)"; rc=$?
assert_eq 0 "$rc" "exit 0"
[[ ! -s "$W/res.log" ]] && _pass "git not invoked" || _fail "git invoked although the router resolved" "$(cat "$W/res.log")"

it "no router and no sibling -> clones over https into \$(dirname INSTALL_DIR)/claude_code_router"
out="$(run_case clone)"; rc=$?
assert_eq 0 "$rc" "exit 0"
want="clone --quiet https://github.com/vasic-digital/claude-code-router.git $W/clone/home/claude_code_router"
grep -qxF -- "$want" "$W/clone.log" && _pass "git clone argv: $want" || _fail "expected clone not issued" "log: $(cat "$W/clone.log")"

it "sibling git repo exists but is not a router checkout yet -> git pull --ff-only"
mkdir -p "$W/pull/home/claude_code_router/.git"
out="$(run_case pull)"; rc=$?
assert_eq 0 "$rc" "exit 0"
want="-C $W/pull/home/claude_code_router pull --ff-only --quiet"
grep -qxF -- "$want" "$W/pull.log" && _pass "git pull argv: $want" || _fail "expected pull not issued" "log: $(cat "$W/pull.log")"

it "clone failure -> dies non-zero naming CT_CLAUDE_CODE_ROUTER_DIR"
out="$(run_case die GIT_STUB_FAIL=1)"; rc=$?
[[ $rc -ne 0 && $rc -ne 97 ]] && _pass "non-zero ($rc)" || _fail "expected a die (rc=$rc)" "$out"
grep -q 'git clone of claude-code-router failed' <<<"$out" && _pass "die message present" || _fail "no die message" "$out"
grep -q 'CT_CLAUDE_CODE_ROUTER_DIR' <<<"$out" && _pass "message names CT_CLAUDE_CODE_ROUTER_DIR" || _fail "no actionable var" "$out"

it "CLAUDE_TOOLKIT_CCR_URL overrides the clone url"
out="$(run_case url CLAUDE_TOOLKIT_CCR_URL=https://example.invalid/r.git)"; rc=$?
grep -q '^clone --quiet https://example.invalid/r.git ' "$W/url.log" && _pass "override url used" || _fail "override ignored" "$(cat "$W/url.log")"

it "step 3b actually calls provision_flat_router on a real install (wired, not just defined)"
grep -qx 'provision_flat_router' "$INSTALL_SCRIPT" && _pass "top-level call present" \
  || _fail "provision_flat_router is never called at top level" "$INSTALL_SCRIPT"

summary
