#!/usr/bin/env bash
# test_constitution.sh — hermetic coverage for verify_constitution.sh (Tier C).
#
# The constitution checks are static/read-only against the real repo, so this
# test:
#   1. runs the verifier against the REAL repo (every check must pass or SKIP
#      here) with PROOF_DIR redirected into the sandbox, asserting exit 0 and
#      a written evidence file;
#   2. points CMA_REPO_ROOT at a controlled fixture repo in the sandbox and
#      asserts a well-formed fixture passes;
#   3. breaks one precondition in the fixture (removes GEMINI.md, violating
#      the §11.4.157 doc lockstep) and asserts the verifier exits nonzero and
#      records the missing doc in its evidence.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
set +e

it "verify_constitution.sh passes on the real repo and writes evidence"
PROOF_DIR="$SANDBOX_HOME/proof-real" bash "$TESTS_DIR/verify_constitution.sh" >/dev/null 2>&1
rc=$?
if bash "$TESTS_DIR/../resolve_deps.sh" llms_verifier >/dev/null 2>&1; then
  assert_eq 0 "$rc" "exit 0 on the real repo (LLMsVerifier resolvable)"
else
  # CONST-051 cannot run: exit 3 = no FAIL but NOT a pass (visible SKIP).
  echo "SKIP: LLMsVerifier not resolvable on this host — CONST-051 not verified (set CT_LLMS_VERIFIER_DIR)"
  assert_eq 3 "$rc" "exit 3 (not-a-pass) on the real repo without a resolvable LLMsVerifier"
fi
assert_file "$SANDBOX_HOME/proof-real/45-constitution.txt" "evidence file written for the real repo"

# --- controlled fixture repo -------------------------------------------------
FIX="$SANDBOX_HOME/fixrepo"
mkdir -p "$FIX/scripts/providers/fixture" "$FIX/scripts/providers/rubric" \
         "$FIX/upstreams" "$FIX/submodules"
# Four governance docs in size lockstep (identical template; name-length
# differences stay well under the 5% tolerance).
for d in AGENTS.md CLAUDE.md QWEN.md GEMINI.md; do
  printf 'fixture governance doc %s — identical body for the lockstep size check\n' "$d" > "$FIX/$d"
done
# providers-semantic.sh references the toolkit-owned fixture/rubric dirs.
cat > "$FIX/scripts/providers-semantic.sh" <<'EOF'
#!/usr/bin/env bash
# fixture stub: references only, never executed
FIX="$LIB_DIR/providers/fixture/code-visibility.md"
RUBRIC="$LIB_DIR/providers/rubric/code-visibility-rubric.json"
EOF
# §11.4.113's anti-vacuous corpus guard requires a populated tree (>=20 .sh/.py
# files under scripts/ + upstreams/) before an empty force-push hit list is read
# as "no force-push" — a mistyped/empty root must not vacuously pass. Model a
# populated repo with harmless helper scripts (deliberately NO force-push
# patterns, so the actual force-push grep keeps its teeth and still returns
# empty here). Without this the well-formed fixture has a single script and
# trips the guard it is meant to satisfy.
for n in $(seq 1 22); do
  printf '#!/usr/bin/env bash\necho "fixture helper %s — plain git push only"\n' "$n" \
    > "$FIX/scripts/helper_$n.sh"
done
# No .env, no .github, no .gitlab-ci.yml, no submodule checkout — those
# checks SKIP or vacuously pass on the fixture.

it "fixture with NO resolvable LLMsVerifier: CONST-051 SKIP is visible and NOT a pass (exit 3)"
out="$(env -u CT_LLMS_VERIFIER_DIR -u LLMSVERIFIER_DIR CMA_REPO_ROOT="$FIX" PROOF_DIR="$SANDBOX_HOME/proof-noverifier" \
  bash "$TESTS_DIR/verify_constitution.sh" 2>&1)"; rc=$?
assert_eq 3 "$rc" "exit 3 when CONST-051 could not run"
grep -q 'CONST-051 NOT VERIFIED' <<<"$out" && _pass "SKIP banner names CONST-051 NOT VERIFIED" || _fail "no visible CONST-051 SKIP banner" "$out"
grep -q 'CT_LLMS_VERIFIER_DIR' <<<"$out" && _pass "banner names CT_LLMS_VERIFIER_DIR" || _fail "banner lacks the fix" "$out"

# A populated, decoupled fake LLMsVerifier checkout (identity marker + >=20 files).
FAKE_LV="$SANDBOX_HOME/fake_llms_verifier"
mkdir -p "$FAKE_LV/llm-verifier"; : > "$FAKE_LV/llm-verifier/go.mod"
for n in $(seq 1 22); do printf 'package x // file %s\n' "$n" > "$FAKE_LV/llm-verifier/f$n.go"; done

it "well-formed fixture repo with a resolvable LLMsVerifier passes (exit 0)"
CT_LLMS_VERIFIER_DIR="$FAKE_LV" CMA_REPO_ROOT="$FIX" PROOF_DIR="$SANDBOX_HOME/proof-fixture" \
  bash "$TESTS_DIR/verify_constitution.sh" >/dev/null 2>&1
assert_eq 0 $? "exit 0 on well-formed fixture"
assert_file "$SANDBOX_HOME/proof-fixture/45-constitution.txt" "evidence file written for the fixture"

it "breaking doc lockstep (missing GEMINI.md) fails the verifier"
rm "$FIX/GEMINI.md"
CMA_REPO_ROOT="$FIX" PROOF_DIR="$SANDBOX_HOME/proof-broken" \
  bash "$TESTS_DIR/verify_constitution.sh" >/dev/null 2>&1
rc=$?
if (( rc != 0 )); then
  _pass "nonzero exit ($rc) when GEMINI.md is missing"
else
  _fail "verifier should fail when GEMINI.md is missing" "got exit 0"
fi
if grep -q 'MISSING doc: GEMINI.md' "$SANDBOX_HOME/proof-broken/45-constitution.txt"; then
  _pass "evidence records the missing GEMINI.md"
else
  _fail "evidence should record the missing doc" "see $SANDBOX_HOME/proof-broken/45-constitution.txt"
fi

summary
