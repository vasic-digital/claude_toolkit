#!/usr/bin/env bash
# test_failure_cause_attribution.sh — a failure message may report only the
# cause the EVIDENCE shows. It may never assert one the evidence contradicts.
#
# THE DEFECT CLASS. Two sites wrote a confident, specific, WRONG cause into
# scripts/tests/proof/ — the audit trail this project reasons from — while the
# true cause sat in a variable or a file already in scope.
#
#   (1) providers-semantic.sh mapped driver exit 1 to
#       "layer-3 FAIL (cannot see code / bluffed)". Per the driver's own
#       contract (submodules/LLMsVerifier/llm-verifier/cmd/
#       semantic-code-visibility/main.go:44-50) exit 1 ALSO covers definitive
#       provider rejections of the model-under-test — HTTP 401/402/403/404.
#       Measured over the committed corpus: 24 evidence files carried that
#       message, 22 of them beside a driver reason of `non-200 status
#       401/402/403/404`, and 0 were bluffs. providers-inference-semantic.txt
#       holds both claims TWELVE LINES APART — `non-200 status 402:
#       "Insufficient balance for request."` and then "cannot see code /
#       bluffed". The honest string was already local: the evidence block ten
#       lines above the verdict mirrors the driver JSON, whose per-round
#       `reason` field the verdict never read.
#
#   (2) verify_providers_live.sh's layer-3 and layer-4 catch-alls said
#       "account-side: key rejected / unfunded / quota". The layer-4 one is the
#       `else` after FOUR evidence-based classifiers declined, so it fires for
#       '# FAIL: timeout', 'stream-aborted', 'no-engagement', 'empty-result',
#       'api-error' and 'launch-refused-unverified' — none of which implies an
#       account state, and the genuinely account-shaped case (402/403) is
#       already taken by its own branch. And status=unverified means
#       INCONCLUSIVE, not rejected: providers-verify.sh emits it for HTTP 429,
#       for any non-4xx code, and even when no verifier binary exists
#       (providers-verify.sh:226,248,252,258). Live proof:
#       42-live-providers.log claimed account-side for 'chutes5' while
#       providers-chutes5-superpowers.txt records '# FAIL:
#       launch-refused-unverified (rc=3 … NO turn ran)' — the launch was refused
#       locally and NOTHING was ever sent to that account.
#
# WHAT THIS FILE PINS, and what it deliberately does not. It pins that each
# message reports the OBSERVED reason and stops asserting an unsupported cause.
# It does NOT change, and actively guards, which outcomes are COUNTED: every
# case below asserts the gated/un-gated tally alongside the wording, because a
# "fix" that quietly stopped failing the suite would be a far worse regression
# than the wrong noun it set out to correct. The control cases (B6, B7) hold the
# line from the other side: where an account state IS measured (a live 402/403)
# the message must STILL say account-side, and a route-attribution failure must
# still fail un-gated.
#
# HERMETIC: no network, no live provider, no real claude. providers-semantic.sh
# honours CMA_SEMANTIC_DRIVER, so a stub driver supplies a deterministic rc +
# JSON; the verify_providers_live.sh branches are EXTRACTED FROM THE REAL FILE
# and eval'd, so an assertion cannot be satisfied by a literal that has been
# commented out.
#
# TEETH. CMA_SEMANTIC_BIN / CMA_LIVE_BIN point the two subjects at alternative
# copies, which is how this file is demonstrated RED against the pre-fix bodies
# (`git show HEAD:<file>` into a temp copy) without editing the checkout.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
set +e

SEM="${CMA_SEMANTIC_BIN:-$SCRIPTS_DIR/providers-semantic.sh}"
LIVE="${CMA_LIVE_BIN:-$TESTS_DIR/verify_providers_live.sh}"

# ---------------------------------------------------------------------------
# Stub driver + preconditions so providers-semantic.sh reaches its verdict case.
# ---------------------------------------------------------------------------
# The real driver writes its JSON report to STDOUT and providers-semantic.sh
# redirects that into .local-cache/semantic-last.json (and stderr into
# .../semantic-last.err). The stub mirrors exactly that contract, so the script
# under test exercises its own real capture path rather than a test-only one.
STUB="$SANDBOX_HOME/stub-driver.sh"
sandbox_stub "$STUB" <<'EOF'
#!/usr/bin/env bash
[[ -n "${STUB_JSON:-}" ]] && printf '%s\n' "$STUB_JSON"
[[ -n "${STUB_ERR:-}" ]]  && printf '%s\n' "$STUB_ERR" >&2
exit "${STUB_RC:-1}"
EOF

# Point the seam files at the real toolkit-owned fixtures so an alternative copy
# of providers-semantic.sh (the RED run) resolves them from any location.
FIXTURE="$SCRIPTS_DIR/providers/fixture/code-visibility.md"
PROMPT_T="$SCRIPTS_DIR/providers/fixture/prompt-template.txt"
RUBRIC="$SCRIPTS_DIR/providers/rubric/code-visibility-rubric.json"

JUDGE_ENV="$SANDBOX_HOME/judge.env"
{
  echo "CMA_JUDGE_BASE_URL=https://judge.invalid/v1"
  echo "CMA_JUDGE_MODEL=judge-model"
  echo "CMA_JUDGE_KEYVAR=TEST_JUDGE_KEY"
  echo "CMA_JUDGE_THRESHOLD=2"
} > "$JUDGE_ENV"
export TEST_JUDGE_KEY="judge-key-not-a-real-secret"
export TEST_PROBE_KEY="probe-key-not-a-real-secret"

SEM_OUT="" SEM_RC=0
run_semantic() {  # run_semantic EVIDENCE_FILE   (STUB_JSON/STUB_ERR/STUB_RC in env)
  local ev="$1"
  SEM_OUT="$( ( export CMA_SEMANTIC_DRIVER="$STUB" CMA_JUDGE_ENV="$JUDGE_ENV" \
                       CMA_SEMANTIC_FIXTURE="$FIXTURE" CMA_SEMANTIC_PROMPT="$PROMPT_T" \
                       CMA_SEMANTIC_RUBRIC="$RUBRIC"
                bash "$SEM" --provider probeprov --model probe-model \
                  --key-var TEST_PROBE_KEY --base-url https://prov.invalid/v1 ) 2>"$ev" )"
  SEM_RC=$?
}

# assert_absent / assert_present operate on a captured STRING (the extracted
# branches print to stdout, not to a file). Rule (d) of test_sandbox_hygiene.sh:
# every "must not contain" is paired with a "must contain" in the same case, so
# an empty capture — a crashed harness — can never read as success.
assert_present() {  # assert_present HAYSTACK NEEDLE MSG
  if grep -qF -- "$2" <<<"$1"; then _pass "$3"
  else _fail "$3" "expected to find '$2' in: $1"; fi
}
assert_absent() {   # assert_absent HAYSTACK NEEDLE MSG
  if grep -qF -- "$2" <<<"$1"; then _fail "$3" "found the unsupported claim '$2' in: $1"
  else _pass "$3"; fi
}

# ===========================================================================
# PART A — providers-semantic.sh reports the DRIVER's reason, not a guess
# ===========================================================================

# --- A1: a definitive PROVIDER REJECTION (402), the live inference case ------
it "A1 driver exit 1 with a 402 rejection: the message reports the rejection, never a bluff"
export STUB_RC=1 STUB_ERR=""
export STUB_JSON='{"round1_sentinel":{"pass":false,"observed":"","reason":"provider definitively rejected the request: non-200 status 402: {\"error\":{\"message\":\"Insufficient balance for request.\",\"type\":\"PaymentRequiredError\"}}"},"round2_judge":{"pass":null,"score":null,"skipped":true,"reason":"round 1 did not pass; round 2 not attempted"},"overall_pass":false}'
EV_402="$SANDBOX_HOME/sem-402.txt"
run_semantic "$EV_402"
# CONTRACT UNCHANGED — the verdict word and exit code are what claude-providers.sh
# and the live leg key on; only the human-facing cause was allowed to move.
assert_eq "unverified" "$SEM_OUT" "A1 verdict word is still 'unverified'"
assert_eq 1 "$SEM_RC" "A1 exit code is still 1"
sem402="$(cat "$EV_402")"
assert_present "$sem402" "Insufficient balance for request." "A1 the driver's own reason reaches the evidence verdict line"
assert_present "$sem402" "non-200 status 402" "A1 the HTTP status the driver observed is named"
assert_absent "$sem402" "cannot see code" "A1 no unsupported 'cannot see code' claim"
assert_absent "$sem402" "bluffed" "A1 no unsupported 'bluffed' claim"

# --- A2: a GENUINE bluff still reads as a bluff ------------------------------
# Without this, A1 would be satisfied by deleting the cause entirely. The
# message must TRACK the evidence, not be a new fixed string.
it "A2 driver exit 1 on a real prompt-echo bluff: that reason is reported verbatim"
export STUB_JSON='{"round1_sentinel":{"pass":false,"observed":"ZETA-9-ORANGE-7f3a","reason":"reply contained the sentinel but regurgitated a 74-character verbatim slice of the fixture (prompt echo / bluff)"},"round2_judge":{"pass":null,"score":null,"skipped":true,"reason":"round 1 did not pass; round 2 not attempted"},"overall_pass":false}'
EV_BLUFF="$SANDBOX_HOME/sem-bluff.txt"
run_semantic "$EV_BLUFF"
assert_eq "unverified" "$SEM_OUT" "A2 verdict word is still 'unverified'"
sembluff="$(cat "$EV_BLUFF")"
assert_present "$sembluff" "prompt echo / bluff" "A2 a real bluff IS reported as a bluff (the message tracks evidence)"
assert_absent "$sembluff" "402" "A2 it does not carry the other case's reason"

# --- A3: round-2 judge failure is attributed to ROUND 2, not round 1 ---------
it "A3 driver exit 1 from the judge: the round that actually failed owns the reason"
export STUB_JSON='{"round1_sentinel":{"pass":true,"observed":"ZETA-9-ORANGE-7f3a"},"round2_judge":{"pass":false,"score":1,"skipped":false,"reason":"judge scored 1, below threshold 2"},"overall_pass":false}'
EV_JUDGE="$SANDBOX_HOME/sem-judge.txt"
run_semantic "$EV_JUDGE"
assert_eq "unverified" "$SEM_OUT" "A3 verdict word is still 'unverified'"
semjudge="$(cat "$EV_JUDGE")"
assert_present "$semjudge" "judge scored 1, below threshold 2" "A3 round-2's reason is selected (round1 pass=true is skipped)"
assert_absent "$semjudge" "cannot see code" "A3 no unsupported cause"

# --- A4: NO driver JSON at all -> degrade to the driver's stderr -------------
it "A4 an unparseable driver report degrades to stderr, never to an invented cause"
export STUB_JSON="" STUB_ERR="semantic-code-visibility: fixture unreadable, aborting"
EV_NOJSON="$SANDBOX_HOME/sem-nojson.txt"
run_semantic "$EV_NOJSON"
assert_eq "unverified" "$SEM_OUT" "A4 verdict word is still 'unverified' (no fail-open)"
assert_eq 1 "$SEM_RC" "A4 exit code is still 1"
semnojson="$(cat "$EV_NOJSON")"
assert_present "$semnojson" "fixture unreadable, aborting" "A4 the driver's stderr is surfaced as the fallback reason"
assert_absent "$semnojson" "cannot see code" "A4 no invented cause when the report is unreadable"

# --- A5: report present but carrying NO reason -> say so explicitly ----------
it "A5 a report with no reason field says so, rather than naming a cause"
export STUB_JSON='{"round1_sentinel":{"pass":false,"observed":""},"round2_judge":{"pass":null,"skipped":true},"overall_pass":false}'
export STUB_ERR=""
EV_NOREASON="$SANDBOX_HOME/sem-noreason.txt"
run_semantic "$EV_NOREASON"
assert_eq "unverified" "$SEM_OUT" "A5 verdict word is still 'unverified'"
semnoreason="$(cat "$EV_NOREASON")"
assert_present "$semnoreason" "not reported by the driver" "A5 the absence of a reason is stated as such"
assert_absent "$semnoreason" "bluffed" "A5 no unsupported cause is substituted for the missing reason"

# --- A6: control — a PASS is untouched ---------------------------------------
it "A6 control: driver exit 0 still yields 'verified' (the pass path is untouched)"
export STUB_RC=0
export STUB_JSON='{"round1_sentinel":{"pass":true,"observed":"ZETA-9-ORANGE-7f3a"},"round2_judge":{"pass":true,"score":3,"skipped":false},"overall_pass":true}'
EV_PASS="$SANDBOX_HOME/sem-pass.txt"
run_semantic "$EV_PASS"
assert_eq "verified" "$SEM_OUT" "A6 verdict word is 'verified'"
assert_eq 0 "$SEM_RC" "A6 exit code is 0"
assert_file_contains "$EV_PASS" "sentinel+judge PASS" "A6 the pass message is unchanged"
unset STUB_RC STUB_JSON STUB_ERR

# ===========================================================================
# PART B — verify_providers_live.sh reports the OBSERVED classification
# ===========================================================================
# Both branches are EXTRACTED FROM THE REAL FILE and eval'd, so nothing here can
# be satisfied by a literal that has been commented out. The anchors mirror
# test_layer4_route_attribution.sh's (indentation-tolerant; the trailing `;;`
# belongs to the enclosing case and is a syntax error on its own, so it is
# rewritten to a bare `fi`).

# The layer-3 arm is a `case` ARM, so its `unverified)` label — like the trailing
# `;;` — belongs to the enclosing `case` and is a syntax error standing alone.
# Keep the raw capture for the non-vacuity assertion, then strip the label for
# the eval.
L3_RAW="$(awk '/^[[:space:]]*unverified\)$/ {inb=1} inb {print} inb && /^[[:space:]]*fi ;;$/ {exit}' "$LIVE")"
L3_SRC="$(printf '%s\n' "$L3_RAW" | sed -e '1d' -e 's/^\([[:space:]]*\)fi ;;$/\1fi/')"
L4_SRC="$(awk '/^[[:space:]]*if grep -qE? .\^# FAIL: / {inb=1} inb {print} inb && /^[[:space:]]*fi ;;$/ {exit}' "$LIVE" \
          | sed 's/^\([[:space:]]*\)fi ;;$/\1fi/')"

it "B0 both classifier branches were extracted from the real file — non-vacuous"
# Positive quantities, per hygiene rule (d): a brittle anchor yields an EMPTY
# extraction, and every "does not assert a cause" check below would then pass
# for the wrong reason.
assert_eq 1 "$(grep -c 'unverified)' <<<"$L3_RAW")" "B0 layer-3 case arm located (1 label)"
assert_eq 0 "$( grep -q 'if (( gated ))'   <<<"$L3_SRC" && echo 0 || echo 1 )" "B0 layer-3 arm extracted with its gate intact"
assert_eq 0 "$( grep -q 'elif (( gated ))' <<<"$L4_SRC" && echo 0 || echo 1 )" "B0 layer-4 classifier extracted with its gated fallback intact"
assert_eq 0 "$( (( $(wc -l <<<"$L3_SRC") >= 4 )) && echo 0 || echo 1 )" "B0 layer-3 extraction has a body ($(wc -l <<<"$L3_SRC") lines)"
assert_eq 0 "$( (( $(wc -l <<<"$L4_SRC") >= 20 )) && echo 0 || echo 1 )" "B0 layer-4 extraction has a body ($(wc -l <<<"$L4_SRC") lines)"

run_l3() {  # run_l3 SEM_EVIDENCE GATED STATUS
  # shellcheck disable=SC2034  # every name is read by the branch eval'd below
  ( sem_ev="$1"; gated="$2"; status="$3"; id="probeprov"
    _fail() { printf 'SUITE-FAILURE: %s :: %s\n' "$1" "${2:-}"; }
    eval "$L3_SRC" ) 2>&1
}
run_l4() {  # run_l4 TUI_EVIDENCE GATED STATUS TUI_OUT
  # shellcheck disable=SC2034  # every name is read by the branch eval'd below
  ( tui_ev="$1"; gated="$2"; status="$3"; tui_out="$4"; id="probeprov"
    _fail() { printf 'SUITE-FAILURE: %s :: %s\n' "$1" "${2:-}"; }
    eval "$L4_SRC" ) 2>&1
}

# --- B1/B2: layer-3, driven by the REAL evidence A1 produced ----------------
# End-to-end chain: stub driver -> providers-semantic.sh -> $sem_ev -> the live
# leg's own branch. Nothing is hand-written into the evidence.
it "B1 layer-3, un-gated: reports the observed reason, asserts no account state, still not counted"
out="$(run_l3 "$EV_402" 0 unverified)"
assert_present "$out" "KNOWN-NON-WORKING" "B1 the provider is still reported explicitly, never silently dropped"
assert_present "$out" "Insufficient balance for request." "B1 the driver's reason reaches the live leg's line"
assert_absent  "$out" "account-side: key rejected" "B1 no unsupported account claim"
assert_absent  "$out" "SUITE-FAILURE" "B1 TALLY UNCHANGED: an un-gated layer-3 failure is still not counted"

it "B2 layer-3, gated: still COUNTS as a suite failure, and now names the real reason"
out="$(run_l3 "$EV_402" 1 verified)"
assert_present "$out" "SUITE-FAILURE" "B2 TALLY UNCHANGED: a gated layer-3 failure still fails the suite"
assert_present "$out" "Insufficient balance for request." "B2 the counted failure also carries the driver's reason"
assert_absent  "$out" "cannot see code" "B2 the counted failure asserts no unsupported cause"

# --- B3/B4/B5: layer-4 -------------------------------------------------------
# The live chutes5 shape: the launch was REFUSED locally at rc=3, so nothing was
# ever sent to the provider's account — the exact case the old text mis-described.
EV_REFUSED="$SANDBOX_HOME/tui-refused.txt"
{
  echo "# ROUTE-INTENDED: probeprov/some-model (transport=router)"
  echo "# LAUNCH-REFUSED: rc=3 — activation gate — alias not 'verified'; refused before any ccr route write"
  echo "# FAIL: launch-refused-unverified (rc=3 intended=probeprov/some-model; NO turn ran — route attribution is not applicable)"
} > "$EV_REFUSED"
TUI_REFUSED="FAIL: launch-refused-unverified — cma_run_provider refused to launch 'probeprov' (activation gate — alias not 'verified'); no turn ran, so no route can be attributed"

it "B3 layer-4, un-gated launch-refusal: reports the refusal, asserts no account state, still not counted"
out="$(run_l4 "$EV_REFUSED" 0 unverified "$TUI_REFUSED")"
assert_present "$out" "KNOWN-NON-WORKING" "B3 the provider is still reported explicitly"
assert_present "$out" "launch-refused-unverified" "B3 the observed classification is surfaced"
assert_present "$out" "no turn ran" "B3 the evidence's own words survive into the report"
assert_absent  "$out" "account-side: key rejected" "B3 no account claim for a launch that never reached the account"
assert_absent  "$out" "SUITE-FAILURE" "B3 TALLY UNCHANGED: an rc-3 refusal on a non-verified provider is still not counted"

it "B4 layer-4, gated: an rc-3 refusal on a status=verified provider STILL counts"
out="$(run_l4 "$EV_REFUSED" 1 verified "$TUI_REFUSED")"
assert_present "$out" "SUITE-FAILURE" "B4 TALLY UNCHANGED: the gated arm still fails the suite"
assert_absent  "$out" "KNOWN-NON-WORKING" "B4 it is not simultaneously written off"

it "B5 layer-4, un-gated timeout: a timeout is reported as a timeout, not as a billing state"
EV_TIMEOUT="$SANDBOX_HOME/tui-timeout.txt"
printf '# FAIL: timeout\n' > "$EV_TIMEOUT"
out="$(run_l4 "$EV_TIMEOUT" 0 unverified "FAIL: launch hung within 180s (trust/overwrite prompt?)")"
assert_present "$out" "KNOWN-NON-WORKING" "B5 still reported explicitly"
assert_present "$out" "launch hung within 180s" "B5 the observed timeout is surfaced"
assert_absent  "$out" "account-side: key rejected" "B5 a timeout is not restated as a rejected/unfunded key"
assert_absent  "$out" "SUITE-FAILURE" "B5 TALLY UNCHANGED: still not counted"

# --- B6/B7: CONTROLS — the other direction ----------------------------------
# The fix must not make the leg incapable of ever saying "account-side", nor
# soften a route-attribution failure. Both classifiers precede the catch-all and
# must be untouched.
it "B6 control: a MEASURED 402 still reports account-side (the word is right where it is earned)"
EV_402TUI="$SANDBOX_HOME/tui-402.txt"
printf '{"api_error_status": 402, "error": "Insufficient balance"}\n' > "$EV_402TUI"
out="$(run_l4 "$EV_402TUI" 0 verified "FAIL: Claude Code reported an API error through the alias")"
assert_present "$out" "KNOWN-NON-WORKING: layer-4 account-side" "B6 the evidence-based account-side classifier still fires"
assert_present "$out" "HTTP 402" "B6 it names the status it actually observed"
assert_absent  "$out" "SUITE-FAILURE" "B6 TALLY UNCHANGED: a measured 402 is still not counted"

it "B7 control: a route-attribution failure still fails UN-GATED (integrity outranks status)"
EV_ROUTE="$SANDBOX_HOME/tui-route.txt"
printf '# FAIL: route-mismatch (intended probeprov/x resolved other/y)\n' > "$EV_ROUTE"
out="$(run_l4 "$EV_ROUTE" 0 unverified "FAIL: route-mismatch")"
assert_present "$out" "SUITE-FAILURE: layer-4 route attribution" "B7 TALLY UNCHANGED: route failures still count at every status"
assert_absent  "$out" "KNOWN-NON-WORKING" "B7 it is not written off as known-non-working"

summary
