#!/usr/bin/env bash
# test_provider_validation.sh — the provider-id charset check is a SECURITY
# CONTROL, and this test exists so that loosening it fails loudly.
#
# Why this exists (a real design pressure, not a hypothetical):
#
# The HelixLLM adaptive-model-serving feature was originally specified so that
# every offered model option would be NAMED `helixllm/<host>/<model>[:<variant>]`
# and that this string would be the identifier consumers use. Two independent
# validators in lib.sh reject that string:
#
#   1. cma_validate_alias              ^[a-zA-Z][a-zA-Z0-9_-]*$
#   2. the provider-id guard           [A-Za-z0-9._-] only, non-empty
#
# Both reject `/` and `:`. Implementing the naming requirement literally
# therefore meant either widening a validator or failing to build — and guard 2
# is not a style preference. Its own comment in lib.sh says the provider id
# "is interpolated into the alias body and re-parsed when the alias is invoked",
# and the charset exists "so a hostile catalog/--id value can't inject shell
# commands". Widening it to admit `/` would trade a naming convenience for a
# shell-injection hole.
#
# The resolution (HelixLLM FR-014 / FR-014a): the scheme is a human-readable
# IDENTITY carried as a VALUE, and any consumer needing an identifier gets a
# SEPARATELY DERIVED, charset-safe one. The naming requirement may NEVER be
# satisfied by relaxing validation here.
#
# ANTI-BLUFF DESIGN: this test does not merely grep for a string. It EXTRACTS
# the live guard out of lib.sh at runtime and EXECUTES it against a truth table.
# A future edit that widens the charset to admit `/` makes the extracted guard
# genuinely accept `/`, and the behavioural cases below fail — the check cannot
# be satisfied by a source comment that says the right thing.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
LIB="$SCRIPTS_DIR/lib.sh"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
set +e

# ---------------------------------------------------------------------------
# 0. The file under test must exist. A missing lib.sh would make every grep
#    below silently find nothing, which several checks would read as "clean".
# ---------------------------------------------------------------------------
it "lib.sh is present and readable"
assert_file "$LIB" "provider validation source"

# ---------------------------------------------------------------------------
# 1. Structural: both validators are still spelled as they were.
#    These catch a rewrite; the behavioural section below catches a widening.
# ---------------------------------------------------------------------------
it "cma_validate_alias still restricts alias names to ^[a-zA-Z][a-zA-Z0-9_-]*$"
alias_re_hits="$(grep -c 'a-zA-Z\]\[a-zA-Z0-9_-\]\*\$' "$LIB" 2>/dev/null)"
if [[ "${alias_re_hits:-0}" -ge 1 ]]; then
  _pass "the alias-name regex literal is unchanged in lib.sh"
else
  _fail "the alias-name regex in cma_validate_alias changed" \
    "expected the literal ^[a-zA-Z][a-zA-Z0-9_-]*\$ in $LIB — if this was widened to admit '/' or ':', revert it: identifiers are derived to fit the rule, the rule is not relaxed to fit a name"
fi

it "the provider-id guard still restricts ids to [A-Za-z0-9._-]"
id_charset_hits="$(grep -cF '*[!A-Za-z0-9._-]*' "$LIB" 2>/dev/null)"
if [[ "${id_charset_hits:-0}" -ge 1 ]]; then
  _pass "the provider-id charset literal is unchanged in lib.sh"
else
  _fail "the provider-id charset guard changed" \
    "expected the literal *[!A-Za-z0-9._-]* in $LIB — this is a SHELL-INJECTION guard (the id is interpolated into an alias body and re-parsed on invocation). Do not widen it to admit '/' for a naming scheme; derive a charset-safe identifier instead (HelixLLM FR-014a)"
fi

it "the injection rationale is still documented next to the guard"
if grep -q "inject shell commands" "$LIB" 2>/dev/null; then
  _pass "the guard still explains why the charset is restricted"
else
  _fail "the injection-guard rationale comment was removed" \
    "the comment naming shell-command injection is what tells the next reader this charset is a security control, not a style choice"
fi

it "the guard is still wired into cma_provider_write_alias"
if awk '/^cma_provider_write_alias\(\)/{f=1} f&&/\*\[!A-Za-z0-9\._-\]\*/{print;exit}' "$LIB" | grep -q .; then
  _pass "cma_provider_write_alias still applies the charset guard"
else
  _fail "the charset guard is no longer inside cma_provider_write_alias" \
    "the literal may still exist elsewhere in lib.sh while the alias writer no longer calls it — that is an unguarded interpolation path"
fi

# ---------------------------------------------------------------------------
# 2. Behavioural: run the LIVE guard, extracted from lib.sh, against inputs.
#    This is what makes the test un-bluffable — it exercises the real source.
# ---------------------------------------------------------------------------
it "the live provider-id guard can be extracted from lib.sh"
guard_block="$(awk '
  /^cma_provider_write_alias\(\)/ { infn = 1 }
  infn && /case "\$id" in/        { incase = 1 }
  incase                          { print }
  incase && /esac/                { exit }
' "$LIB")"
# ANTI-VACUOUS: an empty extraction would make every behavioural case below
# "pass" by executing nothing. Require a real, runnable block first. This checks
# STRUCTURE only (a complete case…esac over $id) — deliberately NOT the charset,
# which is check 2's job; conflating the two would report a widened charset as
# an extraction failure and hide what actually changed.
if [[ -n "$guard_block" ]] &&
   grep -q 'case "\$id" in' <<<"$guard_block" &&
   grep -q 'esac' <<<"$guard_block"; then
  _pass "extracted the live case-guard ($(wc -l <<<"$guard_block" | tr -d ' ') lines)"
else
  _fail "could not extract the provider-id guard from cma_provider_write_alias" \
    "the function or its case block was renamed/restructured; this test must be updated deliberately, never deleted — got: ${guard_block:-<empty>}"
fi

# Build a standalone function around the extracted block and run it. cma_warn is
# stubbed to keep the guard's own failure path silent and side-effect free.
cma_warn() { :; }
eval "live_guard() {
  local id=\"\$1\"
  local alias_name='probe'
  $guard_block
  return 0
}"

# Inputs the guard MUST reject. Each is either empty or carries a character
# outside [A-Za-z0-9._-]; the shell metacharacter cases are the injection ones.
it "the live guard REJECTS every id outside [A-Za-z0-9._-]"
reject_cases=(
  ''                                   # empty
  'helixllm/gpu-01/llama3'             # the raw HelixLLM identity — '/'
  'helixllm/gpu-01/llama3:8b'          # '/' and ':'
  'llama3:8b'                          # ':'
  'a b'                                # space
  'a;id'                               # command separator
  'a$(whoami)'                         # command substitution
  'a`id`'                              # legacy command substitution
  'a|b'                                # pipe
  'a&b'                                # background
  'a>b'                                # redirection
  'a"b'                                # quote break-out
  "a'b"                                # quote break-out
  'a\b'                                # backslash
  'a
b'                                     # newline
)
reject_failures=0
for bad in "${reject_cases[@]}"; do
  if live_guard "$bad"; then
    reject_failures=$((reject_failures + 1))
    _fail "the guard ACCEPTED an unsafe provider id" \
      "id=$(printf '%q' "$bad") was admitted — the charset was widened, re-opening the shell-injection path this guard exists to close"
  fi
done
if (( reject_failures == 0 )); then
  _pass "all ${#reject_cases[@]} unsafe ids rejected (including the raw helixllm/<host>/<model> identity)"
fi

# Inputs the guard MUST still accept — proving the test detects an over-tightening
# too, not only a widening. These are the shapes a derived identifier takes.
it "the live guard ACCEPTS charset-safe derived identifiers"
accept_cases=(
  'helixllm-gpu-01-llama3-8b-9b7d13f59535'
  'helixllm-node-local-org-qwen2-5-q4_k_m-0bcbe7612083'
  'helixllm-10-0-0-7-whoami-ec4d78734116'
  'openrouter'
  'kimi.k2'
  'a_b-c.d'
)
accept_failures=0
for good in "${accept_cases[@]}"; do
  if ! live_guard "$good"; then
    accept_failures=$((accept_failures + 1))
    _fail "the guard REJECTED a charset-safe identifier" \
      "id=$good — the charset was tightened; derived identifiers can no longer be written and provider aliases will break"
  fi
done
if (( accept_failures == 0 )); then
  _pass "all ${#accept_cases[@]} charset-safe ids accepted"
fi

# ---------------------------------------------------------------------------
# 3. Behavioural: the alias-name rule, exercised the same way.
# ---------------------------------------------------------------------------
it "the live alias-name rule REJECTS names with '/' or ':' and ACCEPTS derived ones"
alias_re="$(grep -o '\^\[a-zA-Z\]\[a-zA-Z0-9_-\]\*\$' "$LIB" | head -n1)"
if [[ -z "$alias_re" ]]; then
  _fail "could not extract the alias-name regex from lib.sh" \
    "cma_validate_alias no longer spells ^[a-zA-Z][a-zA-Z0-9_-]*\$"
else
  alias_failures=0
  for bad in 'helixllm/gpu-01/llama3' 'llama3:8b' '9starts-with-digit' '_leading' 'has.dot' ''; do
    [[ "$bad" =~ $alias_re ]] && {
      alias_failures=$((alias_failures + 1))
      _fail "the alias rule ACCEPTED an invalid alias name" "name=$bad"
    }
  done
  for good in 'helixllm-gpu-01-llama3-8b-9b7d13f59535' 'claude1' 'a_b-c'; do
    [[ "$good" =~ $alias_re ]] || {
      alias_failures=$((alias_failures + 1))
      _fail "the alias rule REJECTED a valid derived alias name" "name=$good"
    }
  done
  (( alias_failures == 0 )) && _pass "the alias-name rule behaves as specified ($alias_re)"
fi

summary
