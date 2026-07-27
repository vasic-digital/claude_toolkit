#!/usr/bin/env bash
# test_layer4_route_attribution.sh — hermetic proof that a layer-4 (superpowers
# TUI) verdict is ATTRIBUTABLE to the provider under test.
#
# THE HOLE THIS CLOSES. The `helixagent` alias never actually talked to
# helixagent. Its base_url IS the ccr gateway (http://127.0.0.1:3456/v1), which
# trips the self-reference guard in cma_run_provider (lib.sh): every OTHER
# router-transport provider rewrites .Router.default to itself immediately
# before launching, helixagent skips that rewrite and INHERITS whatever the
# previously-launched provider left in its own per-alias ccr config
# (~/.claude-code-router/<provider-id>/config.json). In the
# v1.23.0 proof run it inherited a ~1M-context provider and 157,419 tokens passed
# through a nominally 24,576-token alias — recorded as a layer-4 PASS. The
# `verified` badge measured whichever router provider ran last and would have
# named a different backend had the run order changed.
#
# Nothing in the layer-4 evidence recorded WHICH BACKEND SERVED THE TURN, which
# is exactly why it survived a release. The evidence file's own `modelUsage`
# cannot supply it either: the router branch never exports ANTHROPIC_MODEL, so
# Claude Code labels every router turn with its own defaults
# (claude-opus-4-8[1m] / contextWindow 1000000) while ccr rewrites the model
# server-side. An INDEPENDENT source of truth is required — ccr's resolved
# .Router.default — and that is what these tests exercise.
#
# Hermetic: no network, no real claude, no provider alias is ever launched
# (that costs real money and contends the shared gateway). `cma_run_provider` is
# a sandboxed fake that returns a transcript which would PASS on content — the
# exact helixagent situation, where only the ROUTE is wrong.
#
# Cases:
#   (a) matching route     -> ROUTE-RESOLVED recorded, leg PASSes
#   (b) MISMATCHED route   -> '# FAIL: route-mismatch', leg FAILs (teeth)
#   (c) proof-sweep gate   -> verify_providers_live.sh's REAL sweep catches (b)
#   (d) native transport   -> no ccr route exists; must not fabricate a mismatch
#   (e) unreadable route   -> '# FAIL: route-unknown', never a silent pass
#   (f) restart FAILED     -> '# FAIL: route-unproven'; a matching config that
#                             was never APPLIED to the live gateway is not proof
#   (g) background foreign -> '# FAIL: route-mismatch-background'; a turn PARTLY
#                             served by another backend is not attributable
#   (h) no jq on PATH      -> '# FAIL: route-unknown' (production degradation)
#   (i) no jq, native      -> still PASSes; the control that makes (h) mean jq
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
set +e

# Script under test. The override exists so the mismatch case can be re-run
# against the PRE-CHANGE script to demonstrate it genuinely has teeth (a test
# that cannot fail against the old code proves nothing). Defaults to the real
# script for every normal suite run.
STUI="${CMA_STUI_BIN:-$SCRIPTS_DIR/verify_superpowers_tui.sh}"
# Same rationale as CMA_STUI_BIN: cases (c) and (j) EXECUTE code extracted from
# verify_providers_live.sh, and an override is the only way to demonstrate that
# extraction has teeth (run it against a mutated copy and the leg must fail)
# without editing the shared checkout. Defaults to the real script.
LIVE="${CMA_LIVE_BIN:-$TESTS_DIR/verify_providers_live.sh}"

PDIR="$HOME/.local/share/claude-multi-account/providers"
# PER-ALIAS CCR_HOME LAYOUT. Since 5f9d82f (2026-07-24, "CCR multi-provider
# concurrent session fix", refined by 8695577) the launcher (lib.sh
# cma_run_provider router branch) isolates every router alias in its OWN
# CCR_HOME: config.json / service.json / service.log live under
# ~/.claude-code-router/<provider-id>/, NOT the global dir. The verifier's
# reads predated that change (last touched 88b4695, 2026-07-21) and kept
# pointing at the global dir — so on a live host every router leg resolved a
# STALE global route (deepseek, Jul 20) and failed attribution
# (route-mismatch). Every fixture below therefore writes the PER-ALIAS dir for
# 'routertest', and a stale GLOBAL config naming a different provider is
# planted once and never touched again: a verifier that reads the global dir
# (the pre-fix behaviour) visibly resolves the WRONG route, while the fixed
# verifier must resolve the per-alias one. That is the regression this file
# pins.
CCR_DIR="$HOME/.claude-code-router"
CCR_ALIAS_DIR="$CCR_DIR/routertest"
CCR_CFG="$CCR_ALIAS_DIR/config.json"
CCR_LOG="$CCR_ALIAS_DIR/service.log"
PROOF="$HOME/proof"
KEYS="$HOME/keys.sh"
export CMA_KEYS_FILE="$KEYS"
mkdir -p "$PDIR" "$PROOF" "$CCR_ALIAS_DIR" "$(dirname "$ALIAS_FILE")"
# The stale GLOBAL config (pre-isolation layout, e.g. left over from Jul 20).
# Never rewritten by any case: it is the decoy the fixed verifier must IGNORE.
printf '{"Providers":[],"Router":{"default":"deepseek,deepseek-v4-pro","background":"deepseek,deepseek-v4-pro"}}\n' \
  > "$CCR_DIR/config.json"
printf 'gateway listening on http://127.0.0.1:3456 (http)\n' > "$CCR_DIR/service.log"

# jq is a HARD precondition of this file, not a reason to skip.
#
# It used to be `HAVE_JQ`, with every router leg wrapped in `if (( HAVE_JQ ))`
# and a bare `echo SKIP` else-branch containing no assertions at all. On a
# jq-less host that left the gate with ZERO coverage while the suite still went
# green — a test that reports success for running nothing. There is also no
# honest "skip" reading available here: cma_run_provider's router upsert is
# itself `command -v jq`-guarded (lib.sh:1009), so a host without jq cannot run
# a router-transport provider AT ALL, and a green report would be describing a
# feature that host cannot execute.
#
# The production no-jq branch is a different matter and IS covered, on every
# host, by cases (h)/(i) below — which manufacture jq's absence with a PATH
# shim rather than waiting for a host that happens to lack it.
if ! command -v jq >/dev/null 2>&1; then
  echo "FATAL: jq is required to exercise the layer-4 route-attribution gate" >&2
  echo "  (the router transport it guards is itself jq-gated in lib.sh, so there" >&2
  echo "   is nothing to verify on a jq-less host — this is a hard error, never" >&2
  echo "   a silent skip)." >&2
  exit 1
fi

# --- fixture: the superpowers skill the challenge is drawn from --------------
# verify_superpowers_tui.sh reads the expected answer FROM the skill at runtime
# (sp_skill_file + sp_expected_answer), so the fixture must carry a real Red
# Flags table row. Path must match '*/skills/using-superpowers/SKILL.md' under a
# plugins/cache root, and 'claude-plugins-official' is preferred by the picker.
SKILL_DIR="$HOME/.claude/plugins/cache/claude-plugins-official/superpowers/skills/using-superpowers"
mkdir -p "$SKILL_DIR"
cat > "$SKILL_DIR/SKILL.md" <<'EOF'
# Using Superpowers

## Red Flags

| Thought | Reality |
|---|---|
| "I remember this skill" | Skills evolve. Read current version. |
EOF
CHALLENGE='Skills evolve. Read current version.'

# --- fixture: a fake claude binary (precondition only) -----------------------
# The launch itself never reaches this; it exists so the "no real claude binary"
# precondition (basename must match claude*) does not SKIP before we classify.
sandbox_stub "$HOME/.local/bin/claude-stub" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
export CLAUDE_BIN="$HOME/.local/bin/claude-stub"

echo 'export ROUTERTEST_API_KEY=sk-test-not-a-real-key' > "$KEYS"

# --- fixture: provider env files ---------------------------------------------
write_env() {  # write_env ID TRANSPORT MODEL FAST_MODEL
  cat > "$PDIR/$1.env" <<EOF
CMA_PROVIDER_ID='$1'
CMA_PROVIDER_KEYVAR='ROUTERTEST_API_KEY'
CMA_PROVIDER_TRANSPORT='$2'
CMA_PROVIDER_MODEL='$3'
CMA_PROVIDER_FAST_MODEL='$4'
CMA_PROVIDER_BASE_URL='http://127.0.0.1:3456/v1'
CMA_PROVIDER_CONFIG_DIR='$HOME/.claude-prov-$1'
EOF
}
write_env routertest router 'router-model-1' 'router-fast-1'
write_env nativetest native 'native-model-1' 'native-fast-1'

# --- fixture: a fake cma_run_provider ----------------------------------------
# Returns a transcript that would PASS on CONTENT (it answers the skill
# challenge, is_error false, non-empty result). Only the ROUTE varies between
# cases — which is precisely the helixagent bluff.
#
# When $FAKE_CCR_REWRITE is set the fake rewrites .Router.default to that value
# just before "serving", mimicking what a normal router provider does. That is
# what proves ROUTE-RESOLVED is read AFTER the launch: case (a) starts from a
# STALE config naming a different provider and still passes, because the rewrite
# landed. A pre-launch read would have reported the stale route and failed.
#
# It also models `ccr restart`. A real successful bounce re-execs the detached
# `serve` child, whose stdout is O_APPENDed to service.log
# (cmd/ccr/service.go:240-247) and which announces itself with "gateway
# listening on" (cmd/ccr/serve.go:104). FAKE_CCR_RESTART=0 models the case the
# gate exists to catch: the config write lands, `ccr restart` FAILS, and
# lib.sh:1026's `|| true` swallows it — so the file reads correct while the
# running gateway still serves the previous provider.
#
# \$FAKE_LAUNCH_RC models a REFUSED launch: cma_run_provider prints its refusal
# to stderr and returns WITHOUT rewriting the route, without bouncing the
# gateway, and without producing any transcript — exactly what the real wrapper
# does for rc 3 (activation gate, lib.sh:668-680, which returns before the
# router branch is even reached), rc 78 (route-integrity refusal) and rc 127
# (missing ccr/claude binary). The stale config.json is left untouched, so a
# gate that reads it post-launch sees the PREVIOUS provider — the N1 trap.
#
# \$FAKE_LAUNCH_EMIT models the OPPOSITE and far more dangerous shape: a turn
# that GENUINELY RAN and then exited with a code that happens to sit in the
# refusal set. `ccr` forwards the agent's own exit code VERBATIM
# (cmd/ccr/launch.go:377 `return ee.ExitCode()`; only signal deaths remap) and
# the native branch is a bare `"\$CLAUDE_BIN" "\$@"; rc=\$?; return \$rc`
# (lib.sh:1219,1229), so ANY code the agent produces reaches the refusal keying
# unchanged. Two sub-shapes, because they stress different halves of the guard:
#   full       — a complete transcript: the ONE terminal {"type":"result",…}
#                object that `--output-format json` emits. This is what the real
#                launch produces on a completed turn (33/33 evidence files in
#                scripts/tests/proof/ have exactly this and nothing else).
#   diagnostic — a turn that ran and died MID-STREAM. Under `--output-format
#                json` Claude Code buffers the whole turn and emits its single
#                result object only at the END, so a mid-stream death emits NO
#                json at all — what remains on the wire is ccr's own startup
#                diagnostic, verbatim from a real evidence file. This is the
#                production-realistic mid-stream shape.
#
# There used to be a third, `partial`, emitting {"type":"assistant",…}. It was
# DELETED 2026-07-20: that is a `--output-format stream-json` chunk, and the
# launch hardcodes `--output-format json` (verify_superpowers_tui.sh:328), so
# production cannot emit it. It was the only thing exercising the
# `assistant|user|system` alternation in _stui_conversation_started, which made
# that alternation look covered while being unreachable in production — the
# fixture and the code were propping each other up. Both are now gone.
#
# \$FAKE_LAUNCH_MSG uses \${VAR-default} (no colon), so a caller can set it EMPTY
# to model output that carries NO wrapper refusal text — which is exactly what a
# mid-stream agent death looks like.
cat > "$ALIAS_FILE" <<EOF
cma_run_provider() {
  # \$FAKE_LAUNCH_HANG models the rc=124 path: the launch outlives the bound.
  # 'aborted' first emits the real result JSON a backend-that-answered-nothing
  # produces (verbatim shape from providers-openrouter2-superpowers.txt: the CLI
  # completed, but served zero tokens and the stream was aborted), THEN hangs —
  # so the evidence file carries a result AND rc is 124, the exact combination
  # the classifier used to report as a trust/overwrite dialog.
  # 'silent' hangs with no output at all: a genuine dialog-style hang, which must
  # still classify as a plain timeout.
  # The sleep redirects its own stdout: otherwise it inherits the capture pipe
  # and keeps the command substitution open past the kill, so the harness would
  # measure the sleep instead of the bound.
  if [[ -n "\${FAKE_LAUNCH_HANG:-}" ]]; then
    if [[ "\$FAKE_LAUNCH_HANG" == "aborted" ]]; then
      printf '%s\n' '{"type":"result","is_error":true,"duration_api_ms":0,"num_turns":2,"usage":{"output_tokens":0},"total_cost_usd":0,"terminal_reason":"aborted_streaming","subtype":"error_during_execution","duration_ms":141075}'
    fi
    sleep 45 >/dev/null 2>&1
    return 0
  fi
  if [[ -n "\${FAKE_LAUNCH_RC:-}" ]]; then
    printf '%s\n' "\${FAKE_LAUNCH_MSG-claude-providers: refused}" >&2
    case "\${FAKE_LAUNCH_EMIT:-}" in
      full)       printf '%s\n' '{"type":"result","is_error":false,"result":"$CHALLENGE"}' ;;
      diagnostic) printf '%s\n' 'Service not running, starting service...' ;;
    esac
    return "\$FAKE_LAUNCH_RC"
  fi
  if [[ -n "\${FAKE_CCR_REWRITE:-}" ]]; then
    printf '{"Providers":[],"Router":{"default":"%s","background":"%s"}}\n' \\
      "\$FAKE_CCR_REWRITE" "\${FAKE_CCR_REWRITE_BG:-\$FAKE_CCR_REWRITE}" > "$CCR_CFG"
  fi
  if [[ "\${FAKE_CCR_RESTART:-1}" == "1" ]]; then
    printf 'gateway listening on http://127.0.0.1:3456 (http)\n' >> "$CCR_LOG"
  fi
  printf '%s\n' '{"type":"result","is_error":false,"result":"$CHALLENGE"}'
}
EOF

set_route() {  # set_route "<prov>,<model>" ["<prov>,<fast>"]  |  set_route --empty
  if [[ "$1" == "--empty" ]]; then printf '{"Providers":[],"Router":{}}\n' > "$CCR_CFG"
  else printf '{"Providers":[],"Router":{"default":"%s","background":"%s"}}\n' \
         "$1" "${2:-$1}" > "$CCR_CFG"; fi
}

# --- fixture: a PATH with NO jq on it, on every host -------------------------
# The production gate degrades through `command -v jq || return 0`
# (verify_superpowers_tui.sh) into route-unknown. Asserting that branch by
# hoping the host lacks jq is not a test — it is a coin flip that lands
# "uncovered" on every developer machine. So manufacture the absence: a bin dir
# holding symlinks to everything the script needs EXCEPT jq, used as the whole
# PATH. A non-executable or failing `jq` shim would NOT work: `command -v`
# skips those and keeps searching PATH, finding the real one.
NOJQ_BIN="$HOME/nojq-bin"
BASH_ABS="$(command -v bash)"
build_nojq_path() {
  mkdir -p "$NOJQ_BIN"
  local t p missing=""
  for t in bash env timeout mktemp date mkdir rmdir dirname basename \
           find grep sort tail awk sed curl wc tr cut cat; do
    p="$(command -v "$t" 2>/dev/null)"
    if [[ -z "$p" ]]; then missing="$missing $t"; continue; fi
    ln -sf "$p" "$NOJQ_BIN/$t"
  done
  printf '%s' "$missing"
}
NOJQ_MISSING="$(build_nojq_path)"

# run_stui ALIAS EVIDENCE_FILE — sets $STUI_OUT and $STUI_RC in the CALLER.
# Deliberately not "out=$(run_stui ...)": that runs the function in a subshell,
# where the rc assignment is lost and every exit-code assertion silently
# degrades into reading a stale/unset variable.
#
# $STUI_PATH overrides the PATH handed to the script under test (cases h/i).
# `bash` is invoked by ABSOLUTE path because a PATH= prefix assignment also
# governs the lookup of the command it prefixes — with a shim PATH that has not
# been built yet, resolving `bash` through it would be the thing under test.
#
# $STUI_ALIAS_FILE overrides the alias file the script sources (case p). The
# script's only alias-file precondition is `[[ -f "$ALIASES_FILE" ]]` and its
# `source` runs under `>/dev/null 2>&1`, so a file that EXISTS but is broken
# satisfies the precondition and fails silently — the state this override lets
# the suite manufacture.
STUI_OUT=""; STUI_RC=0
run_stui() {
  STUI_OUT="$( PROOF_DIR="$PROOF" PATH="${STUI_PATH:-$PATH}" \
               ALIAS_FILE="${STUI_ALIAS_FILE:-$ALIAS_FILE}" \
               "$BASH_ABS" "$STUI" --alias "$1" --out "$2" --timeout 20 2>&1 )"
  STUI_RC=$?
}

# ===========================================================================
# (a) matching route -> ROUTE-RESOLVED recorded, leg PASSes
# ===========================================================================
it "matching route: evidence records ROUTE-INTENDED + ROUTE-RESOLVED and the leg PASSes"
MATCH_EV="$PROOF/providers-routertest-superpowers.txt"
set_route 'someoneelse,stale-model'        # stale, as a real host would be
FAKE_CCR_REWRITE='routertest,router-model-1' ; export FAKE_CCR_REWRITE
FAKE_CCR_REWRITE_BG='routertest,router-fast-1' ; export FAKE_CCR_REWRITE_BG
run_stui routertest "$MATCH_EV"
unset FAKE_CCR_REWRITE FAKE_CCR_REWRITE_BG
assert_eq 0 "$STUI_RC" "matching route exits 0"
grep -q '^PASS:' <<<"$STUI_OUT"; assert_eq 0 $? "stdout reports PASS"
assert_file_contains "$MATCH_EV" '# ROUTE-INTENDED: routertest/router-model-1' "intended route recorded"
assert_file_contains "$MATCH_EV" '# ROUTE-RESOLVED: routertest/router-model-1' "resolved route recorded (read AFTER launch, so the rewrite is seen — not the stale value)"
assert_file_not_contains "$MATCH_EV" 'ROUTE-RESOLVED: someoneelse' "stale pre-launch route is NOT what gets recorded"
assert_file_contains "$MATCH_EV" '# ROUTE-INTENDED-BACKGROUND: routertest/router-fast-1' "background intent recorded (fast model)"
assert_file_contains "$MATCH_EV" '# ROUTE-RESOLVED-BACKGROUND: routertest/router-fast-1' "background resolved route recorded"
assert_file_contains "$MATCH_EV" '# ROUTE-APPLIED: service.log' "restart receipt recorded — the route was proven APPLIED, not merely written"
assert_file_contains "$MATCH_EV" '# PASS' "evidence carries the PASS marker"
# Per-alias-dir teeth: the GLOBAL config still names the stale provider, so a
# verifier reading the global dir (the pre-fix behaviour, seen live as
# 'intended=xiaomi resolved=deepseek') would have FAILED this leg with
# route-mismatch. The PASS proves the read came from the per-alias CCR_HOME.
assert_file_contains "$CCR_DIR/config.json" 'deepseek,deepseek-v4-pro' "the stale GLOBAL config still names another provider — it was NOT what got read"
assert_file_contains "$CCR_ALIAS_DIR/config.json" '"default":"routertest,router-model-1"' "the PER-ALIAS config is what the fake launcher rewrote"
assert_file_not_contains "$MATCH_EV" 'deepseek' "the resolved route never names the stale global provider"

# ===========================================================================
# (b) MISMATCHED route -> '# FAIL: route-mismatch', leg FAILS  [TEETH]
# ===========================================================================
# Exactly the helixagent situation: the alias never rewrites the route (no
# FAKE_CCR_REWRITE, mirroring lib.sh's self-reference guard skipping the
# upsert), so config.json still names the PREVIOUS provider — while the
# transcript itself is a perfectly good content-PASS. Before this change the
# leg reported PASS and the `verified` badge named the wrong backend.
it "MISMATCHED route: a content-passing transcript served by another backend must FAIL, not pass"
MISMATCH_EV="$PROOF/providers-routertest-mismatch.txt"
set_route 'chutes,zai-org/GLM-5.2-TEE'     # inherited from the previous alias
run_stui routertest "$MISMATCH_EV"
assert_eq 1 "$STUI_RC" "route mismatch exits 1 (leg FAILS)"
grep -q '^FAIL: route-mismatch' <<<"$STUI_OUT"; assert_eq 0 $? "stdout names the mismatch explicitly"
grep -q 'routertest/router-model-1' <<<"$STUI_OUT"; assert_eq 0 $? "stdout names the INTENDED side"
grep -q 'chutes/zai-org/GLM-5.2-TEE' <<<"$STUI_OUT"; assert_eq 0 $? "stdout names the RESOLVED side"
assert_file_contains "$MISMATCH_EV" '# FAIL: route-mismatch' "evidence carries the distinct route-mismatch marker"
assert_file_contains "$MISMATCH_EV" 'intended=routertest/router-model-1' "marker names the intended route"
assert_file_contains "$MISMATCH_EV" 'resolved=chutes/zai-org/GLM-5.2-TEE' "marker names the resolved route"
assert_file_not_contains "$MISMATCH_EV" '# PASS' "a non-attributable turn NEVER carries a PASS marker"
# The bluff-shape assertion: the transcript content alone WOULD have passed.
assert_file_contains "$MISMATCH_EV" "$CHALLENGE" "the transcript did answer the skill challenge — only the ROUTE was wrong"

# ===========================================================================
# (c) the proof-sweep gate in verify_providers_live.sh catches the marker
# ===========================================================================
it "proof-sweep gate in verify_providers_live.sh treats '# FAIL: route-mismatch' as a failure"
# This leg used to be vacuous twice over. It grep'd two literals out of $LIVE
# (which would still pass with both lines COMMENTED OUT), then matched a regex
# against a HARDCODED STRING — `grep -qE ... <<<'# ROUTE-RESOLVED: x/y'` —
# exercising zero production code and passing with the whole feature deleted.
#
# Replace both with the real thing: EXTRACT the sweep loop verbatim from
# verify_providers_live.sh and EXECUTE it over the real evidence file case (b)
# just produced. If the sweep is deleted, commented out, or stops classifying
# route markers as failures, the extraction or the assertion below fails.
assert_file "$MISMATCH_EV" "case (b) produced the evidence this sweep runs against"

# Extract from the sweep's `marked=()` initializer to its closing `done`.
# 2-arg awk only (no GNU 3-arg match capture) per the portability rules.
SWEEP_SRC="$(awk '/^marked=\(\)$/ {inb=1} inb {print} inb && /^done$/ {exit}' "$LIVE")"
# ANTI-VACUITY GUARD, and an honest statement of what it does and does not cover.
#
# It used to be a bare `grep -q 'marked+='`, whose comment claimed it detected
# "an empty/commented block". It did not: commenting the classification line out
# leaves the literal `marked+=` inside the comment text, so the guard PASSED on
# a block that classifies nothing, and only the behavioural assertions below
# caught the mutation. Strip full-line comments first, so a commented-out body
# fails the guard rather than sailing through it.
#
# A naive `sed 's/#.*//'` would be WRONG here and is deliberately avoided: the
# real classification line is `'# FAIL:'*) marked+=(...)`, whose `#` lives
# inside a shell pattern, so stripping from the first `#` would delete the very
# token being looked for and the guard would fail on correct code.
#
# What this guard covers: an empty extraction, and a body whose lines are all
# commented out. What it does NOT cover: a trailing-comment mutation on an
# otherwise live line. That residual case is covered behaviourally — the
# extracted body is EXECUTED against real evidence immediately below, and a body
# that classifies nothing fails those assertions.
SWEEP_CODE="$(grep -vE '^[[:space:]]*#' <<<"$SWEEP_SRC")"
grep -q 'marked+=' <<<"$SWEEP_CODE"
assert_eq 0 $? "extracted a live sweep body from $LIVE (survives comment-stripping, so a commented-out block cannot satisfy this)"

# Run the REAL sweep body against the REAL mismatch evidence.
#
# $SWEEP_CODE, not $SWEEP_SRC: the anti-vacuity guard above is applied to the
# comment-stripped text, so evaluating the RAW text would mean the guard and the
# executed body are not the same string. A body that satisfies the guard only
# because of its comments would then still be the thing that runs. (Case (c2)
# already evals its comment-stripped form; this makes the two symmetric.)
# shellcheck disable=SC2034  # RUN_TUI_EV is read by the sweep body eval'd below
marked=(); RUN_TUI_EV=("$MISMATCH_EV")
eval "$SWEEP_CODE"
assert_eq 1 "${#marked[@]}" "the production sweep classifies the route-mismatch evidence as a FAIL"
grep -q 'route-mismatch' <<<"${marked[0]:-}"
assert_eq 0 $? "the sweep's own report names the route-mismatch marker"

# The ROUTE-* lines must not shadow the verdict in the sweep's `tail -n 1`
# selection — asserted against the REAL file, which genuinely contains them.
assert_file_contains "$MISMATCH_EV" '# ROUTE-RESOLVED:' "the real evidence file does contain ROUTE-* lines to shadow with"
marker_count="$(grep -cE '^# (PASS|FAIL:|SKIP)' "$MISMATCH_EV")"
assert_eq 1 "$marker_count" "exactly one line of the real evidence is a marker line — the ROUTE-* lines are not selected"

# And the control: a PASSing file is NOT swept as a failure, so the sweep is
# discriminating rather than uniformly red.
marked=()
# shellcheck disable=SC2034  # RUN_TUI_EV is read by the sweep body eval'd below
RUN_TUI_EV=("$MATCH_EV")
eval "$SWEEP_CODE"
assert_eq 0 "${#marked[@]}" "the production sweep leaves the PASSing evidence alone"

# ===========================================================================
# (c2) the STATUS-INDEPENDENT sweep is a SECOND loop and needs its own execution
# ===========================================================================
# verify_providers_live.sh has TWO sweeps: the gated one extracted above
# (`marked=()`, scoped to RUN_TUI_EV) and a status-independent one
# (`route_marked=()`, scoped to ALL_TUI_EV) that exists so a non-attributable
# turn fails at ANY provider status. The awk anchor `^marked=\(\)$` matches only
# the FIRST, so the second loop had no extracted-execution coverage at all — its
# only coverage was indirect, via the per-provider classifier, and a regression
# confined to that loop (a dropped case pattern, a wrong array name) would have
# gone unnoticed. Extract and execute it too.
it "the STATUS-INDEPENDENT route sweep in verify_providers_live.sh is itself executed against real evidence"
ROUTE_SWEEP_SRC="$(awk '/^route_marked=\(\)$/ {inb=1} inb {print} inb && /^done$/ {exit}' "$LIVE")"
ROUTE_SWEEP_CODE="$(grep -vE '^[[:space:]]*#' <<<"$ROUTE_SWEEP_SRC")"
grep -q 'route_marked+=' <<<"$ROUTE_SWEEP_CODE"
assert_eq 0 $? "extracted the status-independent sweep body (survives comment-stripping)"
# It must be a DIFFERENT loop from the gated one, or the extraction is silently
# re-testing the same code twice and (c2) proves nothing.
grep -q 'ALL_TUI_EV' <<<"$ROUTE_SWEEP_CODE"
assert_eq 0 $? "the extracted body is the ALL_TUI_EV loop, not a second copy of the RUN_TUI_EV one"

# shellcheck disable=SC2034  # ALL_TUI_EV is read by the sweep body eval'd below
route_marked=(); ALL_TUI_EV=("$MISMATCH_EV")
eval "$ROUTE_SWEEP_CODE"
assert_eq 1 "${#route_marked[@]}" "the status-independent sweep classifies route-mismatch evidence as a failure"
grep -q 'route-mismatch' <<<"${route_marked[0]:-}"
assert_eq 0 $? "its report names the route-mismatch marker"

# Control: a PASSing file is left alone, so the sweep discriminates.
# shellcheck disable=SC2034  # ALL_TUI_EV is read by the sweep body eval'd below
route_marked=(); ALL_TUI_EV=("$MATCH_EV")
eval "$ROUTE_SWEEP_CODE"
assert_eq 0 "${#route_marked[@]}" "the status-independent sweep leaves PASSing evidence alone"

# ===========================================================================
# (d) native transport -> no ccr route exists; must not fabricate a mismatch
# ===========================================================================
it "native transport: records 'n/a' for the resolved route and does NOT invent a mismatch"
NATIVE_EV="$PROOF/providers-nativetest-superpowers.txt"
set_route 'chutes,zai-org/GLM-5.2-TEE'   # irrelevant to a native alias
run_stui nativetest "$NATIVE_EV"
assert_eq 0 "$STUI_RC" "native transport is unaffected by the ccr route (exit 0)"
grep -q '^PASS:' <<<"$STUI_OUT"; assert_eq 0 $? "native transport still PASSes"
assert_file_contains "$NATIVE_EV" '# ROUTE-INTENDED: nativetest/native-model-1 (transport=native)' "intended route records the transport"
assert_file_contains "$NATIVE_EV" '# ROUTE-RESOLVED: n/a (native transport' "native resolved route is an explicit n/a, not a bogus comparison"
assert_file_contains "$NATIVE_EV" '# ROUTE-APPLIED: n/a (native transport' "native transport needs no restart receipt and says so explicitly"
assert_file_not_contains "$NATIVE_EV" 'route-mismatch' "native transport never emits a route-mismatch"
assert_file_not_contains "$NATIVE_EV" 'route-unproven' "native transport never demands a ccr restart receipt"

# ===========================================================================
# (e) unreadable route -> '# FAIL: route-unknown', never a silent pass
# ===========================================================================
# .Router.default absent is exactly the state in which cma_run_provider ALSO
# skipped its own jq-guarded upsert, so the turn really was served by something
# this run cannot name. Unattributable must not mean "assume fine".
it "unreadable ccr route: router alias FAILs with route-unknown rather than passing unattributably"
UNKNOWN_EV="$PROOF/providers-routertest-unknown.txt"
set_route --empty
run_stui routertest "$UNKNOWN_EV"
assert_eq 1 "$STUI_RC" "unreadable route exits 1"
grep -q '^FAIL: route-unknown' <<<"$STUI_OUT"; assert_eq 0 $? "stdout names route-unknown"
assert_file_contains "$UNKNOWN_EV" '# FAIL: route-unknown' "evidence carries the route-unknown marker"
assert_file_not_contains "$UNKNOWN_EV" '# PASS' "unattributable turn never carries a PASS marker"

# ===========================================================================
# (f) config written but `ccr restart` FAILED -> route-unproven  [TEETH, C1]
# ===========================================================================
# The gate's original weak point: it INFERRED the live route from config.json.
# cma_run_provider writes that file and then runs `ccr restart` under `|| true`
# (lib.sh:1026), discarding any failure — and cmdRestart genuinely does fail,
# e.g. it refuses to bounce an authenticated gateway when CCR_API_KEYS is not
# visible (cmd/ccr/service.go:556-560). The Go gateway keeps serving the config
# it STARTED with (service.go:357-364), so the previous provider continues to
# serve while the post-launch file read returns the intended value.
#
# Here the rewrite lands and matches perfectly — only the restart is missing.
# Before the fix this was an unqualified PASS for a turn served by whoever ran
# last, which is the exact bluff class the gate claims to make impossible.
it "config written but restart FAILED: a perfectly-matching config must not pass without a restart receipt"
UNPROVEN_EV="$PROOF/providers-routertest-unproven.txt"
set_route 'someoneelse,stale-model'
FAKE_CCR_REWRITE='routertest,router-model-1' ; export FAKE_CCR_REWRITE
FAKE_CCR_REWRITE_BG='routertest,router-fast-1' ; export FAKE_CCR_REWRITE_BG
FAKE_CCR_RESTART=0 ; export FAKE_CCR_RESTART       # the swallowed `|| true` failure
run_stui routertest "$UNPROVEN_EV"
unset FAKE_CCR_REWRITE FAKE_CCR_REWRITE_BG FAKE_CCR_RESTART
assert_eq 1 "$STUI_RC" "an unapplied route exits 1 (fails closed)"
grep -q '^FAIL: route-unproven' <<<"$STUI_OUT"; assert_eq 0 $? "stdout names route-unproven"
assert_file_contains "$UNPROVEN_EV" '# FAIL: route-unproven' "evidence carries the route-unproven marker"
assert_file_contains "$UNPROVEN_EV" '# ROUTE-APPLIED: <unproven>' "evidence states on its face that application was never proven"
assert_file_not_contains "$UNPROVEN_EV" '# PASS' "a route that cannot be shown APPLIED never carries a PASS marker"
# The bluff shape: config and transcript were both flawless. Only the restart missing.
assert_file_contains "$UNPROVEN_EV" '# ROUTE-RESOLVED: routertest/router-model-1' "the on-disk route matched the intent exactly — the file was never the problem"
assert_file_contains "$UNPROVEN_EV" "$CHALLENGE" "the transcript answered the skill challenge — only the APPLICATION of the route was unproven"

# ===========================================================================
# (g) background route mismatch -> route-mismatch-background  [TEETH, I6]
# ===========================================================================
# cma_run_provider writes .Router.default AND .Router.background in one upsert
# (lib.sh:1022-1023). Claude Code dispatches background sub-requests of the SAME
# turn through the background entry, so checking only .default let a turn that
# was PARTLY served by another backend pass the gate.
it "background route mismatch: a turn PARTLY served by another backend must FAIL"
BGMISMATCH_EV="$PROOF/providers-routertest-bgmismatch.txt"
set_route 'someoneelse,stale-model'
FAKE_CCR_REWRITE='routertest,router-model-1' ; export FAKE_CCR_REWRITE
FAKE_CCR_REWRITE_BG='chutes,zai-org/GLM-5.2-TEE' ; export FAKE_CCR_REWRITE_BG
run_stui routertest "$BGMISMATCH_EV"
unset FAKE_CCR_REWRITE FAKE_CCR_REWRITE_BG
assert_eq 1 "$STUI_RC" "background mismatch exits 1 even though .Router.default is correct"
grep -q '^FAIL: route-mismatch-background' <<<"$STUI_OUT"; assert_eq 0 $? "stdout names the background mismatch distinctly"
assert_file_contains "$BGMISMATCH_EV" '# FAIL: route-mismatch-background' "evidence carries the background-specific marker"
assert_file_contains "$BGMISMATCH_EV" 'resolved=chutes/zai-org/GLM-5.2-TEE' "marker names the foreign background backend"
assert_file_contains "$BGMISMATCH_EV" '# ROUTE-RESOLVED: routertest/router-model-1' "the PRIMARY route was correct — only the background entry was foreign"
assert_file_not_contains "$BGMISMATCH_EV" '# PASS' "a partly-foreign turn never carries a PASS marker"

# ===========================================================================
# (h) NO jq on PATH, router transport -> route-unknown  [TEETH, C2]
# ===========================================================================
# The production degradation `command -v jq >/dev/null || return 0` in
# ccr_route_for had no assertion anywhere: every router case was wrapped in
# `if (( HAVE_JQ ))` with a bare `echo` else-branch, so on a jq-less host the
# gate had ZERO coverage and the suite still reported green. jq's absence is
# manufactured here (see build_nojq_path) so this branch is covered on EVERY
# host rather than on whichever host happens to lack jq.
it "no jq on PATH: a router alias FAILs route-unknown instead of silently passing"
assert_eq "" "$NOJQ_MISSING" "the jq-less PATH shim could be built (missing tools would invalidate cases h/i)"
NOJQ_EV="$PROOF/providers-routertest-nojq.txt"
# A PERFECTLY matching route on disk: the only thing wrong is that the gate
# cannot read it. Unattributable must still not mean "assume fine".
set_route 'routertest,router-model-1' 'routertest,router-fast-1'
command -v jq >/dev/null 2>&1; assert_eq 0 $? "jq IS present on this host — so case (h) is testing the shim, not the host"
PATH="$NOJQ_BIN" command -v jq >/dev/null 2>&1
assert_eq 1 $? "the shim PATH genuinely hides jq (the precondition case (h) rests on)"
STUI_PATH="$NOJQ_BIN" run_stui routertest "$NOJQ_EV"
assert_eq 1 "$STUI_RC" "without jq a router alias exits 1"
grep -q '^FAIL: route-unknown' <<<"$STUI_OUT"; assert_eq 0 $? "stdout names route-unknown when jq cannot resolve the route"
assert_file_contains "$NOJQ_EV" '# FAIL: route-unknown' "evidence carries the route-unknown marker"
assert_file_contains "$NOJQ_EV" '# ROUTE-RESOLVED: <unreadable>' "evidence records the route as unreadable rather than inventing one"
assert_file_not_contains "$NOJQ_EV" '# PASS' "a route that cannot be READ never carries a PASS marker"

# ===========================================================================
# (i) NO jq on PATH, NATIVE transport -> still PASSes  [CONTROL for (h)]
# ===========================================================================
# Without this control, case (h) proves nothing: a shim PATH missing some
# unrelated tool would also produce a FAIL, and the test would credit that to
# the jq branch. A native alias needs no ccr route and therefore no jq, so it
# must still PASS on the very same PATH — which isolates (h)'s failure to jq.
it "route failure is NOT excused by provider status: the live classifier fails it even when un-gated"
# The proof sweep used to be reachable only for `verified` providers
# (verify_providers_live.sh gates evidence collection on gate_for_status), so a
# route mismatch on a non-verified provider printed KNOWN-NON-WORKING and never
# failed the suite. But those are two different kinds of failure: a rejected
# key explains a provider that cannot ANSWER; nothing about an account explains
# evidence attributed to the WRONG BACKEND. That is our own machinery emitting
# a false statement, and it must count at every status.
#
# Extract the real classification branch from verify_providers_live.sh and run
# it, rather than asserting on literals that would survive being commented out.
# The trailing `;;` is the enclosing case arm's terminator; it is a syntax
# error on its own, so drop it while keeping the `fi` that closes the branch.
# The anchor tolerates `grep -q` or `grep -qE`: the un-gated branch now matches
# an alternation (route-* plus the rc-78/96/unclassified launch-refusal
# markers), which requires -E.
#
# The anchors are INDENTATION-TOLERANT. They used to hard-code six leading
# spaces plus a literal `      fi ;;` terminator, so a reindent of
# verify_providers_live.sh would silently empty the extraction — and the
# `elif (( gated ))` assertion below would then fail reporting "the gated
# fallback is missing", which is the wrong cause and sends the next reader
# hunting a nonexistent regression. `[[:space:]]*` matches whatever the file
# actually uses, and the sed mirrors it, so a reindent is a no-op here.
CLASSIFY_SRC="$(awk '/^[[:space:]]*if grep -qE? .\^# FAIL: / {inb=1} inb {print} inb && /^[[:space:]]*fi ;;$/ {exit}' "$LIVE" \
                | sed 's/^\([[:space:]]*\)fi ;;$/\1fi/')"
assert_eq 0 "$( [[ -n "$CLASSIFY_SRC" ]] && echo 0 || echo 1 )" "the classifier extraction is non-empty (a brittle anchor would report as a missing gate below)"
grep -q 'elif (( gated ))' <<<"$CLASSIFY_SRC"
assert_eq 0 $? "extracted the live layer-4 FAIL classifier from $LIVE (with its gated fallback intact)"

# Un-gated (status=failed, the account-dead case) + route-marked evidence.
# Every variable the extracted branch reads must be bound: the test file runs
# under `set -u`, so a missing one aborts the subshell before it can classify
# anything — which would look exactly like "the gate did not fire".
run_classifier() {  # run_classifier EVIDENCE GATED STATUS [TUI_OUT]
  # shellcheck disable=SC2034  # all six are read by the branch eval'd below
  ( tui_ev="$1"; gated="$2"; status="$3"
    id="routertest"; tui_out="${4:-FAIL: route-mismatch}"
    _fail() { printf 'SUITE-FAILURE: %s\n' "$1"; }
    eval "$CLASSIFY_SRC" ) 2>&1
}
out="$(run_classifier "$MISMATCH_EV" 0 failed)"
grep -q 'SUITE-FAILURE: layer-4 route attribution' <<<"$out"
assert_eq 0 $? "a route-mismatch on a status=failed provider STILL fails the suite (integrity, not account state)"
grep -q 'KNOWN-NON-WORKING' <<<"$out"
assert_eq 1 $? "it is NOT written off as known-non-working"

# Control: a NON-route layer-4 failure on the same un-gated provider is still
# excused — otherwise this change would just pin the run permanently red, which
# is the very thing gate_for_status exists to prevent.
out="$(run_classifier "$NATIVE_EV" 0 failed)"
grep -q 'SUITE-FAILURE' <<<"$out"
assert_eq 1 $? "a non-route layer-4 failure on an account-dead provider is still NOT a suite failure"
grep -q 'KNOWN-NON-WORKING' <<<"$out"
assert_eq 0 $? "it is reported explicitly as known-non-working, never silently dropped"

# And a route failure on a gated (verified) provider fails too, as before.
out="$(run_classifier "$MISMATCH_EV" 1 verified)"
grep -q 'SUITE-FAILURE' <<<"$out"
assert_eq 0 $? "a route-mismatch on a verified provider fails the suite as well"

it "no jq on PATH, native transport: still PASSes (proves the shim PATH is sound, so (h) is about jq)"
NOJQ_NATIVE_EV="$PROOF/providers-nativetest-nojq.txt"
STUI_PATH="$NOJQ_BIN" run_stui nativetest "$NOJQ_NATIVE_EV"
assert_eq 0 "$STUI_RC" "native transport runs end-to-end on the jq-less PATH"
grep -q '^PASS:' <<<"$STUI_OUT"; assert_eq 0 $? "native transport still PASSes without jq"
assert_file_contains "$NOJQ_NATIVE_EV" '# PASS' "evidence carries the PASS marker"

# ===========================================================================
# (j) REFUSED launch, rc 3 (activation gate) -> NO route-* marker  [TEETH, N1]
# ===========================================================================
# The regression this closes. cma_run_provider's activation gate returns rc 3
# for any non-'verified' alias BEFORE the router branch, so nothing is written
# to config.json and nothing is served. The gate then read the STALE config,
# found the previous provider, and emitted '# FAIL: route-mismatch' for a launch
# that never happened — and because route markers are un-gated by design, that
# became a hard suite failure at every non-verified provider (11 of 21 aliases
# on the reference host). A refusal is not a mis-attribution: no turn ran, so
# there is no backend to attribute and no false statement to punish.
it "REFUSED launch (rc 3, activation gate): no route-* marker is emitted for a turn that never ran"
REFUSED3_EV="$PROOF/providers-routertest-refused3.txt"
set_route 'chutes,zai-org/GLM-5.2-TEE'   # the previous provider's route, as on a real host
FAKE_LAUNCH_RC=3 ; export FAKE_LAUNCH_RC
FAKE_LAUNCH_MSG='claude-providers: alias routertest is failed — not launching.' ; export FAKE_LAUNCH_MSG
run_stui routertest "$REFUSED3_EV"
unset FAKE_LAUNCH_RC FAKE_LAUNCH_MSG
assert_eq 1 "$STUI_RC" "a refused launch is not a pass (exit 1)"
assert_file_not_contains "$REFUSED3_EV" '# FAIL: route-' "NO route-* marker: route markers are reserved for turns that ACTUALLY RAN"
assert_file_not_contains "$REFUSED3_EV" '# ROUTE-RESOLVED:' "no resolved-route line is fabricated from the stale config of a launch that never happened"
assert_file_not_contains "$REFUSED3_EV" 'chutes/zai-org/GLM-5.2-TEE' "the PREVIOUS provider's route is never named as if it had served this turn"
assert_file_contains "$REFUSED3_EV" '# LAUNCH-REFUSED: rc=3' "the refusal itself is recorded, verbatim and on its face"
assert_file_contains "$REFUSED3_EV" '# FAIL: launch-refused-unverified' "a distinctly-named, non-route verdict"
assert_file_contains "$REFUSED3_EV" 'claude-providers: alias routertest is failed' "the wrapper's own refusal text is preserved in the evidence"
assert_file_not_contains "$REFUSED3_EV" '# PASS' "a refused launch never carries a PASS marker"
grep -q '^FAIL: launch-refused-unverified' <<<"$STUI_OUT"; assert_eq 0 $? "stdout names the refusal, not a mismatch"

# ...and it must NOT fail the suite for a non-verified provider (the whole point).
out="$(run_classifier "$REFUSED3_EV" 0 failed "FAIL: launch-refused-unverified")"
grep -q 'SUITE-FAILURE' <<<"$out"
assert_eq 1 $? "an rc-3 refusal on a status=failed provider does NOT fail the suite (it restates known account state)"
grep -q 'KNOWN-NON-WORKING' <<<"$out"
assert_eq 0 $? "it is reported explicitly as known-non-working, never silently dropped"
# ...while on a provider that CLAIMS to be verified it still fails: status.json
# would then disagree with the gate that reads it.
out="$(run_classifier "$REFUSED3_EV" 1 verified "FAIL: launch-refused-unverified")"
grep -q 'SUITE-FAILURE' <<<"$out"
assert_eq 0 $? "an rc-3 refusal on a status=verified provider IS a suite failure (inconsistent status)"
# ...and the status-independent sweep must leave it alone, or the gate above is
# moot: the sweep runs over ALL providers regardless of status.
# shellcheck disable=SC2034  # ALL_TUI_EV is read by the sweep body eval'd below
route_marked=(); ALL_TUI_EV=("$REFUSED3_EV")
eval "$ROUTE_SWEEP_CODE"
assert_eq 0 "${#route_marked[@]}" "the status-independent sweep does NOT flag an rc-3 refusal (no attribution claim was made)"

# ===========================================================================
# (k) REFUSED launch, rc 78 (route integrity) -> un-gated FAILURE  [TEETH, N1]
# ===========================================================================
# rc 78 is lib.sh REFUSING to launch because the ccr route was not applied
# (lib.sh:1097-1107) or because the alias' base_url IS the gateway (the
# helixagent self-reference, lib.sh:964). Also not a route ATTRIBUTION failure —
# nothing ran — so it wears no 'route-' marker. But unlike rc 3 it is NOT
# account-side: no rejected key, no exhausted quota, no unfunded balance
# explains it. It is a real toolkit/config defect that lib.sh caught one step
# earlier than the attribution gate would have, so it counts at EVERY status.
it "REFUSED launch (rc 78, route integrity): no route-* marker, but an UN-GATED failure at any status"
REFUSED78_EV="$PROOF/providers-routertest-refused78.txt"
set_route 'chutes,zai-org/GLM-5.2-TEE'
FAKE_LAUNCH_RC=78 ; export FAKE_LAUNCH_RC
FAKE_LAUNCH_MSG='claude-providers: refusing to launch routertest — its ccr route was NOT applied.' ; export FAKE_LAUNCH_MSG
run_stui routertest "$REFUSED78_EV"
unset FAKE_LAUNCH_RC FAKE_LAUNCH_MSG
assert_eq 1 "$STUI_RC" "an unapplied-route refusal exits 1"
assert_file_not_contains "$REFUSED78_EV" '# FAIL: route-' "NO route-* marker: nothing ran, so nothing was mis-attributed"
assert_file_not_contains "$REFUSED78_EV" '# ROUTE-RESOLVED:' "no resolved route is invented for a launch that was refused"
assert_file_contains "$REFUSED78_EV" '# LAUNCH-REFUSED: rc=78' "the refusal is recorded on its face"
assert_file_contains "$REFUSED78_EV" '# FAIL: launch-refused-route-integrity' "distinct, non-route integrity verdict"
assert_file_not_contains "$REFUSED78_EV" '# PASS' "a refused launch never carries a PASS marker"
grep -q '^FAIL: launch-refused-route-integrity' <<<"$STUI_OUT"; assert_eq 0 $? "stdout names the route-integrity refusal"

# The distinguishing assertion vs. case (j): rc 78 is NOT excused by status.
out="$(run_classifier "$REFUSED78_EV" 0 failed "FAIL: launch-refused-route-integrity")"
grep -q 'SUITE-FAILURE: layer-4 route attribution' <<<"$out"
assert_eq 0 $? "an rc-78 refusal on a status=failed provider STILL fails the suite (integrity, not account state)"
grep -q 'KNOWN-NON-WORKING' <<<"$out"
assert_eq 1 $? "it is NOT written off as known-non-working"
# shellcheck disable=SC2034  # ALL_TUI_EV is read by the sweep body eval'd below
route_marked=(); ALL_TUI_EV=("$REFUSED78_EV")
eval "$ROUTE_SWEEP_CODE"
assert_eq 1 "${#route_marked[@]}" "the status-independent sweep DOES flag an rc-78 refusal"

# ===========================================================================
# (l) REFUSED launch, rc 127 (binary absent) -> honest SKIP
# ===========================================================================
# `ccr` or `claude` missing from this host is environmental, indistinguishable
# from the preconditions this script already SKIPs on. It is not a verdict about
# the provider in either direction.
it "REFUSED launch (rc 127, missing binary): an honest SKIP, never a verdict"
REFUSED127_EV="$PROOF/providers-routertest-refused127.txt"
set_route 'chutes,zai-org/GLM-5.2-TEE'
FAKE_LAUNCH_RC=127 ; export FAKE_LAUNCH_RC
FAKE_LAUNCH_MSG='claude-providers: provider routertest needs claude-code-router (the `ccr` gateway).' ; export FAKE_LAUNCH_MSG
run_stui routertest "$REFUSED127_EV"
unset FAKE_LAUNCH_RC FAKE_LAUNCH_MSG
assert_eq 0 "$STUI_RC" "a missing binary is an honest SKIP (exit 0)"
grep -q '^SKIP:' <<<"$STUI_OUT"; assert_eq 0 $? "stdout reports SKIP"
assert_file_not_contains "$REFUSED127_EV" '# FAIL:' "no failure verdict is recorded for an absent binary"
assert_file_contains "$REFUSED127_EV" '# LAUNCH-REFUSED: rc=127' "the refusal is still recorded"
assert_file_contains "$REFUSED127_EV" '# SKIP' "the evidence's last marker is a SKIP"
# shellcheck disable=SC2034  # ALL_TUI_EV is read by the sweep body eval'd below
route_marked=(); ALL_TUI_EV=("$REFUSED127_EV")
eval "$ROUTE_SWEEP_CODE"
assert_eq 0 "${#route_marked[@]}" "the status-independent sweep does not flag a SKIP"

# ===========================================================================
# (m) the I4 PROPERTY IS PRESERVED: a real mismatch on a turn that DID run
# ===========================================================================
# Every fix above narrows what counts as a route failure. This re-asserts, after
# all of them, that the narrowing did not reach the case the gate exists for: a
# launch that ACTUALLY RAN (rc 0, real transcript) against a foreign route still
# fails, at a status that excuses everything else.
it "I4 preserved: a genuine route mismatch on a turn that DID run still FAILs at a non-verified status"
I4_EV="$PROOF/providers-routertest-i4.txt"
set_route 'chutes,zai-org/GLM-5.2-TEE'
run_stui routertest "$I4_EV"          # no FAKE_LAUNCH_RC: the turn genuinely runs
assert_eq 1 "$STUI_RC" "a mismatched route on a real turn still exits 1"
assert_file_contains "$I4_EV" '# FAIL: route-mismatch' "a turn that RAN still earns a route-* marker"
assert_file_contains "$I4_EV" "$CHALLENGE" "and the transcript really did run (it answered the skill challenge)"
out="$(run_classifier "$I4_EV" 0 failed)"
grep -q 'SUITE-FAILURE: layer-4 route attribution' <<<"$out"
assert_eq 0 $? "it fails the suite even on a status=failed provider — the I4 property, intact"
route_marked=()
# shellcheck disable=SC2034  # ALL_TUI_EV is read by the sweep body eval'd below
ALL_TUI_EV=("$I4_EV")
eval "$ROUTE_SWEEP_CODE"
assert_eq 1 "${#route_marked[@]}" "and the status-independent sweep still flags it"

# ===========================================================================
# (n) the CORROBORATION GUARD itself, in its TRUE arm  [TEETH, C2]
# ===========================================================================
# Cases (j)/(k)/(l) only ever exercised the corroboration in its FALSE arm: the
# fake returned early on $FAKE_LAUNCH_RC and emitted NO transcript, so there was
# nowhere in the suite where a refusal-set exit code met a transcript that had
# actually run. That left the guard untested in the only direction it exists
# for — deleting it outright kept the file at 105/0 green, and so did deleting
# it AND classifying every exit code as a refusal.
#
# The scenario is real, not contrived: `ccr` forwards the agent's exit code
# verbatim, so a turn that RAN and exited 3 is indistinguishable from the
# activation gate's refusal on the exit code alone. Only the transcript
# separates them, and the verdict must follow the transcript.
it "corroboration guard: a turn that ACTUALLY RAN is never re-read as a refusal, whatever its exit code"
CORROB_EV="$PROOF/providers-routertest-corroborated.txt"
set_route 'chutes,zai-org/GLM-5.2-TEE'    # foreign route, as after a real launch
FAKE_LAUNCH_RC=3 ; export FAKE_LAUNCH_RC
FAKE_LAUNCH_EMIT=full ; export FAKE_LAUNCH_EMIT
run_stui routertest "$CORROB_EV"
unset FAKE_LAUNCH_RC FAKE_LAUNCH_EMIT
assert_eq 1 "$STUI_RC" "a turn that ran against a foreign route exits 1"
assert_file_contains "$CORROB_EV" '# FAIL: route-mismatch' "rc 3 + a completed transcript is a ROUTE failure, not a refusal"
assert_file_not_contains "$CORROB_EV" 'launch-refused-unverified' "the refusal verdict is NOT reached for a turn that ran"
assert_file_not_contains "$CORROB_EV" '# LAUNCH-REFUSED' "no LAUNCH-REFUSED line is written for a launch that was not refused"
assert_file_contains "$CORROB_EV" "$CHALLENGE" "the transcript really did run (it answered the skill challenge)"
grep -q '^FAIL: route-mismatch' <<<"$STUI_OUT"; assert_eq 0 $? "stdout names the mismatch, not a refusal"
# ...and it must count at EVERY status, or the guard buys nothing: the whole
# point is that a real turn served by a foreign backend is an integrity failure.
out="$(run_classifier "$CORROB_EV" 0 failed)"
grep -q 'SUITE-FAILURE: layer-4 route attribution' <<<"$out"
assert_eq 0 $? "a corroborated route-mismatch fails the suite even at status=failed"

# ===========================================================================
# (o) a turn killed MID-STREAM must not become a SKIP — and this ISOLATES
#     half (b) of the corroboration  [TEETH, C1+C2]
# ===========================================================================
# The sharpest form of the same hole, and the one that converts a false-RED into
# a false-GREEN: a genuine turn dies before completing, the agent's exit code
# (127 here) reaches the refusal keying unchanged, and the script reports
# "nothing ran". rc 127 is the SKIP arm, so the whole leg goes green having
# tested nothing.
#
# WHAT THIS CASE NOW ISOLATES, and why the fixture changed (2026-07-20). The
# corroboration is a conjunction of two halves — (a) no conversation-shaped
# chunk, (b) empty output or the wrapper's own refusal text — and the refusal
# stands only when BOTH hold. This case used to emit a stream-json
# `{"type":"assistant"}` chunk, which made half (a) false and let the case be
# credited to (a). That was doubly wrong: production hardcodes `--output-format
# json` and can never emit that chunk, and it left half (b) with NO coverage at
# all — forcing _stui_wrapper_refused to return true unconditionally (i.e.
# reducing the guard to the pre-fix transcript-only logic) kept the file green.
#
# The fixture is now the shape production ACTUALLY produces when a turn dies
# mid-stream under `--output-format json`: no json at all (the single result
# object is emitted only at the END), just ccr's own startup diagnostic, copied
# verbatim from a real evidence file. So:
#   half (a) CANNOT match — there is no conversation-shaped chunk to find;
#   half (b) is FALSE     — the output is non-empty and carries no
#                           'claude-providers:'/'cma_run:' refusal prefix.
# The refusal is therefore cleared by `! _stui_wrapper_refused` and NOTHING
# ELSE. Half (b) is the sole load-bearing half of this case, which is exactly
# what was untested before.
#
# FAKE_LAUNCH_MSG is set EMPTY on purpose: a mid-stream agent death produces no
# 'claude-providers:' refusal text.
it "mid-stream death (production --output-format json shape: no json emitted): a run that HAPPENED is never reported as a SKIP"
MIDSTREAM_EV="$PROOF/providers-routertest-midstream.txt"
set_route 'chutes,zai-org/GLM-5.2-TEE'
FAKE_LAUNCH_RC=127 ; export FAKE_LAUNCH_RC
FAKE_LAUNCH_EMIT=diagnostic ; export FAKE_LAUNCH_EMIT
FAKE_LAUNCH_MSG='' ; export FAKE_LAUNCH_MSG
run_stui routertest "$MIDSTREAM_EV"
unset FAKE_LAUNCH_RC FAKE_LAUNCH_EMIT FAKE_LAUNCH_MSG
assert_eq 1 "$STUI_RC" "a turn that ran and died mid-stream is NOT an exit-0 SKIP"
grep -q '^SKIP:' <<<"$STUI_OUT"; assert_eq 1 $? "stdout does NOT report SKIP for a run that happened"
assert_file_not_contains "$MIDSTREAM_EV" '# SKIP' "no SKIP marker is written for a run that happened"
assert_file_not_contains "$MIDSTREAM_EV" '# LAUNCH-REFUSED' "rc 127 alone does not make a launch refused"
assert_file_contains "$MIDSTREAM_EV" '# FAIL: route-' "it lands on a loud, un-gated route verdict instead"
# The half-(a)-cannot-match precondition, asserted rather than assumed: if the
# fixture ever grew a conversation-shaped chunk, this case would silently stop
# isolating half (b) and would be carried by half (a) instead.
grep -qE '"type": *"(result|assistant|user|system)"' "$MIDSTREAM_EV"
assert_eq 1 $? "the evidence carries NO conversation-shaped chunk — so half (a) cannot be what cleared the refusal; only half (b) can"
assert_file_contains "$MIDSTREAM_EV" 'Service not running' "the mid-stream output really is the production diagnostic shape"

# C1's other half: half (a) must stay NARROW. Structural on purpose, and this is
# the honest form of the assertion rather than a hedge.
#
# The reviewed hole was that reverting `result|assistant|user|system` -> `result`
# was invisible: the suite could not tell which half of the conjunction was
# load-bearing. That was resolved by DELETING the alternation as dead code
# (production hardcodes `--output-format json`, which emits one terminal result
# object; 33/33 real evidence files bear this out and none contains an
# assistant/user/system chunk). With the alternation gone, that mutation no
# longer exists to be invisible.
#
# What remains possible is the INVERSE — someone re-widening the regex and
# re-introducing breadth that production cannot reach and no test can exercise,
# which is exactly the pattern being removed. A behavioural assertion cannot
# catch that (unreachable code changes no behaviour by definition), so the
# assertion is deliberately structural, and is scoped to the specific dead
# alternatives rather than pinning the regex verbatim.
_conv_fn="$(awk '/^_stui_conversation_started\(\) \{$/ {inb=1} inb {print} inb && /^\}$/ {exit}' "$STUI")"
assert_eq 0 "$( [[ -n "$_conv_fn" ]] && echo 0 || echo 1 )" "extracted _stui_conversation_started from $STUI"
grep -q 'result' <<<"$_conv_fn"
assert_eq 0 $? "half (a) still matches the result shape production DOES emit (it is narrowed, not deleted)"
grep -qE 'assistant|user|system' <<<"$_conv_fn"
assert_eq 1 $? "half (a) does NOT match stream-json chunk shapes — production hardcodes --output-format json and can never emit them, so matching them would be untestable dead breadth"
# ...and the status-independent sweep must SEE it. This is the invariant the
# whole finding rests on: a broken run fails loudly at any status.
# shellcheck disable=SC2034  # ALL_TUI_EV is read by the sweep body eval'd below
route_marked=(); ALL_TUI_EV=("$MIDSTREAM_EV")
eval "$ROUTE_SWEEP_CODE"
assert_eq 1 "${#route_marked[@]}" "the status-independent sweep flags the mid-stream run (it is not invisible)"

# ===========================================================================
# (p) BROKEN INSTALLATION: alias file present, wrapper UNDEFINED  [TEETH, C1]
# ===========================================================================
# Not hypothetical — this exact corruption happened on the reference host. The
# script's only alias-file precondition is `[[ -f "$ALIASES_FILE" ]]`, and the
# launch sources it under `>/dev/null 2>&1`, so a TRUNCATED or syntactically
# broken alias file passes the precondition and fails silently. Every alias then
# yields rc 127 from bash's own "command not found".
#
# Pre-corroboration that produced a loud (if misattributed) route-unknown /
# route-mismatch. Keying rc 127 to a SKIP turned it into: the entire layer-4 leg
# SKIPs and the suite goes green with ZERO providers actually tested. That is
# strictly worse than the false-RED it replaced, which is why the guard must be
# a positive assertion that the wrapper EXISTS, not an inference from a code.
it "broken installation (alias file present, cma_run_provider undefined): fails LOUDLY, never SKIPs"
BROKEN_ALIASES="$HOME/broken-aliases.sh"
cat > "$BROKEN_ALIASES" <<'EOF'
# A truncated alias file: the function body is never closed, so `source` aborts
# with a syntax error and cma_run_provider is left UNDEFINED.
cma_run_provider() {
  printf 'this file was truncated mid-write
EOF
NOWRAPPER_EV="$PROOF/providers-routertest-nowrapper.txt"
set_route 'routertest,router-model-1' 'routertest,router-fast-1'   # a PERFECT route
# Sanity: the fixture really does leave the wrapper undefined (otherwise this
# case would silently test nothing).
#
# `env -u BASH_ENV` is REQUIRED, not decorative. BASH_ENV is exported on this
# host and points at the operator's ~/.bashrc, which transitively sources the
# PRODUCTION alias file — so a plain subshell (and, before the fix, the script's
# own launch subshell) has a working cma_run_provider supplied from somewhere
# other than the alias file under test. Without this the assertion measures the
# host's real installation instead of the fixture.
env -u BASH_ENV "$BASH_ABS" -c 'source "$1" >/dev/null 2>&1; declare -F cma_run_provider >/dev/null 2>&1' _ "$BROKEN_ALIASES"
assert_eq 1 $? "the broken alias fixture genuinely leaves cma_run_provider undefined"
STUI_ALIAS_FILE="$BROKEN_ALIASES" run_stui routertest "$NOWRAPPER_EV"
assert_eq 1 "$STUI_RC" "a broken installation exits 1 (loud), never 0"
grep -q '^SKIP:' <<<"$STUI_OUT"; assert_eq 1 $? "stdout does NOT report SKIP for a broken installation"
assert_file_not_contains "$NOWRAPPER_EV" '# SKIP' "no SKIP marker: the installation is broken, which is a finding"
assert_file_contains "$NOWRAPPER_EV" '# FAIL: launch-impossible-no-wrapper' "a distinctly-named verdict naming the real cause"
assert_file_not_contains "$NOWRAPPER_EV" '# PASS' "a broken installation never carries a PASS marker"
grep -q '^FAIL: launch-impossible-no-wrapper' <<<"$STUI_OUT"; assert_eq 0 $? "stdout names the missing wrapper explicitly"
# The route on disk was PERFECT — so nothing about the route could have caught
# this, and the verdict must not be attributed to one.
assert_file_not_contains "$NOWRAPPER_EV" '# FAIL: route-' "a perfect route is not blamed for a missing wrapper"
# Un-gated: a broken installation is a toolkit defect that no account state
# explains, so it must fail the suite at EVERY provider status — otherwise a
# host whose providers are all non-verified goes green on a broken install.
out="$(run_classifier "$NOWRAPPER_EV" 0 failed "FAIL: launch-impossible-no-wrapper")"
grep -q 'SUITE-FAILURE' <<<"$out"
assert_eq 0 $? "a broken installation fails the suite even at status=failed (toolkit defect, not account state)"
grep -q 'KNOWN-NON-WORKING' <<<"$out"
assert_eq 1 $? "it is NOT written off as known-non-working"
# shellcheck disable=SC2034  # ALL_TUI_EV is read by the sweep body eval'd below
route_marked=(); ALL_TUI_EV=("$NOWRAPPER_EV")
eval "$ROUTE_SWEEP_CODE"
assert_eq 1 "${#route_marked[@]}" "the status-independent sweep flags a broken installation"

# ===========================================================================
# (p2) rc 96 WITHOUT the sentinel is NOT a broken installation  [TEETH, C3]
# ===========================================================================
# The negative control for case (p), and the assertion that makes the sentinel
# REQUIREMENT load-bearing rather than decorative. The broken-install branch is
#   if (( rc == 96 )) && printf '%s' "$out" | grep -qF "$CMA_STUI_NO_WRAPPER"
# and deleting the second conjunct — leaving a bare `if (( rc == 96 ))` — left
# the whole file green. Nothing anywhere exercised an rc 96 that was NOT the
# guard firing, so the sentinel check could be removed silently.
#
# The scenario is the same one that motivates the sentinel in the first place:
# `ccr` forwards the agent's exit code VERBATIM, so an agent that simply exits 96
# is indistinguishable from the guard on the code alone. Here the wrapper IS
# defined (the normal working fixture), the guard does NOT fire and prints no
# sentinel, and the launch returns 96 with a genuine transcript. That must be
# read as a turn that RAN — and therefore fall through to the route gate — never
# as "this host has no launch wrapper", which would be a false statement about
# the entire installation derived from one provider's exit code.
it "rc 96 WITHOUT the sentinel: a turn that RAN is never read as a broken installation"
RC96_EV="$PROOF/providers-routertest-rc96.txt"
set_route 'chutes,zai-org/GLM-5.2-TEE'   # foreign route, so the fallthrough has a verdict to reach
FAKE_LAUNCH_RC=96 ; export FAKE_LAUNCH_RC
FAKE_LAUNCH_EMIT=full ; export FAKE_LAUNCH_EMIT
FAKE_LAUNCH_MSG='' ; export FAKE_LAUNCH_MSG
run_stui routertest "$RC96_EV"
unset FAKE_LAUNCH_RC FAKE_LAUNCH_EMIT FAKE_LAUNCH_MSG
assert_eq 1 "$STUI_RC" "rc 96 on a turn that ran still exits 1 (it is a route failure, not a pass)"
# The load-bearing assertions: the broken-install verdict must NOT be reached.
assert_file_not_contains "$RC96_EV" 'launch-impossible-no-wrapper' "rc 96 WITHOUT the sentinel is NOT a broken installation — the sentinel is required, not decorative"
grep -q 'launch-impossible-no-wrapper' <<<"$STUI_OUT"
assert_eq 1 $? "stdout does not claim a broken installation either"
# The sanity control: the fixture really did produce an rc-96 turn that ran.
assert_file_contains "$RC96_EV" "$CHALLENGE" "the transcript really did run (it answered the skill challenge)"
# And it lands on the honest verdict for what it actually is: a turn that ran
# against a foreign route.
assert_file_contains "$RC96_EV" '# FAIL: route-mismatch' "it falls through to the route gate and earns a route verdict"
assert_file_not_contains "$RC96_EV" '# PASS' "a turn served by a foreign backend never carries a PASS marker"

# ===========================================================================
# (q) the verdict `case` has a total `*)` arm  [I2]
# ===========================================================================
# The detection `case` and the verdict `case` in verify_superpowers_tui.sh carry
# the same code set today, so nothing falls through. But when a code is
# classified as a refusal and matches no verdict arm, the script writes
# '# LAUNCH-REFUSED: rc=N' and then CONTINUES into route resolution, producing
# evidence that simultaneously claims the launch was refused AND names a
# resolved backend. Any future edit that adds a code to one case and not the
# other lands here silently. Assert the arm exists by SOURCE INSPECTION — the
# state it guards is unreachable by construction today, which is exactly why it
# needs a structural assertion rather than a behavioural one.
# ===========================================================================
# (r) the refusal set is BOUNDED: rc 124 (timeout) is not in it  [TEETH, I2]
# ===========================================================================
# The complement of case (n). (n) proves a code INSIDE the refusal set is
# overridden by evidence that the turn ran; this proves the set itself has an
# edge, i.e. that the detection `case` enumerates codes rather than matching
# everything. Without it, widening the detection case to `*)` is invisible:
# every other case in this file supplies a transcript, so the corroboration
# clears the misclassification and the mutation survives silently.
#
# rc 124 is the sharpest probe. It is `timeout` killing a hung launch — a
# trust/overwrite prompt is the classic cause — and it produces NO transcript
# and NO wrapper refusal text, so BOTH halves of the corroboration are silent
# and the exit code is all that is left. A detection case that matched `*)`
# would classify it as a refusal and report a hang as "nothing ran".
it "bounded refusal set: an rc-124 timeout is a HANG verdict, never a launch refusal"
TIMEOUT_EV="$PROOF/providers-routertest-timeout.txt"
set_route 'routertest,router-model-1' 'routertest,router-fast-1'
FAKE_LAUNCH_RC=124 ; export FAKE_LAUNCH_RC
FAKE_LAUNCH_MSG='' ; export FAKE_LAUNCH_MSG    # a killed process leaves no refusal text
run_stui routertest "$TIMEOUT_EV"
unset FAKE_LAUNCH_RC FAKE_LAUNCH_MSG
assert_eq 1 "$STUI_RC" "a hung launch exits 1"
assert_file_contains "$TIMEOUT_EV" '# FAIL: timeout' "a hang is recorded as a timeout"
assert_file_not_contains "$TIMEOUT_EV" '# LAUNCH-REFUSED' "rc 124 is NOT in the refusal set — a hang is not a refusal"
assert_file_not_contains "$TIMEOUT_EV" 'launch-refused-unclassified' "and it never falls into the verdict case's drift arm"
grep -q '^FAIL: launch hung' <<<"$STUI_OUT"; assert_eq 0 $? "stdout names the hang, not a refusal"

it "the refusal verdict case has a total '*)' arm, so a detection/verdict drift cannot fall through silently"
# Indentation-tolerant anchors on purpose (see the CLASSIFY_SRC note in case
# (i)): pinning an exact leading-space count makes a harmless reindent silently
# empty the extraction, which then reports as "the arm is missing" — the wrong
# cause. The VERDICT case is the SECOND `case "$rc" in` in the file; the first
# is the detection case.
VERDICT_SRC="$(awk '/^[[:space:]]*case "\$rc" in$/ {n++} n==2 {print} n==2 && /^[[:space:]]*esac$/ {exit}' "$STUI")"
assert_eq 0 "$( [[ -n "$VERDICT_SRC" ]] && echo 0 || echo 1 )" "extracted the refusal VERDICT case from $STUI (non-empty)"
# It really is the VERDICT case, not the detection one: only the verdict case
# writes the LAUNCH-REFUSED verdicts.
grep -q 'launch-refused-unverified' <<<"$VERDICT_SRC"
assert_eq 0 $? "the extraction is the verdict case (it writes the refusal verdicts), not the detection case"
grep -qE '^[[:space:]]*\*\)' <<<"$VERDICT_SRC"
assert_eq 0 $? "the verdict case carries an explicit '*)' arm"
# ...and that arm must be a FAILURE, not a silent fallthrough.
grep -q 'exit 1' <<<"$VERDICT_SRC"
assert_eq 0 $? "the '*)' arm exits non-zero rather than continuing into route resolution"

# ===========================================================================
# (q2) the `*)` arm's DOWNSTREAM WIRING, behaviourally  [TEETH, I1]
# ===========================================================================
# Case (q) above asserts only that the arm EXISTS IN THE SOURCE of
# verify_superpowers_tui.sh. That says nothing about whether the marker it emits
# is ACTED ON, and it is consumed in two independent places in
# verify_providers_live.sh: the per-provider classifier's un-gated alternation
# and the status-independent route sweep's `case`. Dropping
# 'launch-refused-unclassified' from EITHER left the whole file green, because
# nothing anywhere fed that marker to either loop.
#
# The failure that buys: a detection/verdict drift fires the `*)` arm, the
# consuming pattern is missing, the failure falls through to `elif (( gated ))`
# and is written off as KNOWN-NON-WORKING on every non-verified alias (14 of 24
# on this host) — the drift signal swallowed by provider status, which is the
# precise thing un-gating exists to prevent.
#
# The marker is UNREACHABLE through a real launch by construction (the detection
# and verdict code sets are identical today, which is the point of the arm), so
# the evidence file is synthesized. The CONSUMERS are the real extracted
# production loops, exactly as in cases (c)/(c2)/(i) — so this is behavioural
# coverage of the wiring, not another source-inspection assertion.
it "the '*)' arm's marker is ACTED ON by both consumers in verify_providers_live.sh (not just present in source)"
UNCLASS_EV="$PROOF/providers-routertest-unclassified.txt"
{
  echo '# ROUTE-INTENDED: routertest/router-model-1 (transport=router)'
  echo '# LAUNCH-REFUSED: rc=42 — a code the detection case classified but the verdict case does not name'
  echo '# FAIL: launch-refused-unclassified (rc=42 intended=routertest/router-model-1; detection/verdict case sets disagree — toolkit defect)'
} > "$UNCLASS_EV"

# CONSUMER 1: the per-provider classifier. Un-gated (status=failed) — a drift in
# our own driver is not excused by a provider's account state.
out="$(run_classifier "$UNCLASS_EV" 0 failed "FAIL: launch-refused-unclassified")"
grep -q 'SUITE-FAILURE: layer-4 route attribution' <<<"$out"
assert_eq 0 $? "the classifier fails the suite on a launch-refused-unclassified marker even at status=failed"
grep -q 'KNOWN-NON-WORKING' <<<"$out"
assert_eq 1 $? "it is NOT written off as known-non-working (that is the swallow this arm exists to prevent)"

# CONSUMER 2: the status-independent route sweep — a SECOND, separate loop.
# shellcheck disable=SC2034  # ALL_TUI_EV is read by the sweep body eval'd below
route_marked=(); ALL_TUI_EV=("$UNCLASS_EV")
eval "$ROUTE_SWEEP_CODE"
assert_eq 1 "${#route_marked[@]}" "the status-independent sweep also flags launch-refused-unclassified"
grep -q 'launch-refused-unclassified' <<<"${route_marked[0]:-}"
assert_eq 0 $? "the sweep's report names the unclassified-refusal marker"

# ...and the discrimination control, so neither assertion above is satisfied by a
# uniformly-red loop: the rc-3 refusal evidence from case (j) must still be left
# alone by both consumers.
out="$(run_classifier "$REFUSED3_EV" 0 failed "FAIL: launch-refused-unverified")"
grep -q 'SUITE-FAILURE' <<<"$out"
assert_eq 1 $? "the classifier still discriminates: an rc-3 refusal is not swept up by the unclassified pattern"
# shellcheck disable=SC2034  # ALL_TUI_EV is read by the sweep body eval'd below
route_marked=(); ALL_TUI_EV=("$REFUSED3_EV")
eval "$ROUTE_SWEEP_CODE"
assert_eq 0 "${#route_marked[@]}" "the sweep still discriminates too"

# ===========================================================================
# (q3) the two un-gated marker lists are the SAME SET  [I1, minor]
# ===========================================================================
# verify_providers_live.sh states the un-gated marker set TWICE — once as a
# `grep -qE` alternation in the classifier, once as a `case` pattern list in the
# status-independent sweep — and its own comment requires them to match ("The set
# swept here MUST match the un-gated set of the per-provider classifier"). They
# are hand-duplicated, so a one-sided edit is invisible: (q2) above would catch a
# marker dropped from BOTH, and each consumer's own assertions catch a drop from
# either, but this states the invariant directly so the NEXT marker added to one
# list and not the other fails immediately rather than waiting for someone to
# write a behavioural case for it.
it "the classifier's un-gated marker alternation and the sweep's case list are the same set"
# ONE shared character class governs BOTH extractions, so they cannot silently
# diverge. Before this, the classifier used '[a-z0-9|-]+' and the sweep used
# '[a-z-]+'; a future marker containing a DIGIT (e.g. a 'route-mismatch-l2')
# extracted whole on the classifier side but truncated at the digit on the sweep
# side, so this (q3) leg would report a spurious mismatch on a correct pair. The
# shared $MARKER_CLASS makes divergence impossible by construction, and it
# includes 0-9 so a numeric marker is not truncated on either side.
MARKER_CLASS='[a-z0-9|-]'
# Marker names from the classifier's `grep -qE '^# FAIL: (...)'` alternation.
CLASSIFIER_MARKERS="$(grep -m1 -oE "\^# FAIL: \(${MARKER_CLASS}+\)" "$LIVE" \
                      | sed 's/^\^# FAIL: (//; s/)$//' | tr '|' '\n' | sort)"
# Marker names from the sweep's `'# FAIL: xxx'*` case patterns.
SWEEP_MARKERS="$(grep -oE "'# FAIL: ${MARKER_CLASS}+'" <<<"$ROUTE_SWEEP_CODE" \
                 | sed "s/'# FAIL: //; s/'$//" | sort -u)"
assert_eq 0 "$( [[ -n "$CLASSIFIER_MARKERS" ]] && echo 0 || echo 1 )" "extracted a non-empty marker set from the classifier alternation"
assert_eq 0 "$( [[ -n "$SWEEP_MARKERS" ]] && echo 0 || echo 1 )" "extracted a non-empty marker set from the sweep case list"
assert_eq "$CLASSIFIER_MARKERS" "$SWEEP_MARKERS" "the two hand-duplicated un-gated marker lists are identical (a one-sided edit is caught here)"
# Digit-consistency: feed BOTH extractors a synthetic, correctly-matching pair
# whose marker set includes a digit-bearing name, using the SAME two pipelines as
# above. They must agree, and the digit-bearing marker must survive WHOLE on the
# sweep side — the side whose old '[a-z-]+' class truncated it at the digit. If
# $MARKER_CLASS ever loses 0-9, or the two pipelines diverge again, one of these
# two assertions fails immediately rather than waiting for production to grow a
# numeric marker.
_syn_alt="if grep -qE '^# FAIL: (route-|route-mismatch-l2)' \"\$tui_ev\""
_syn_case="    '# FAIL: route-'*|'# FAIL: route-mismatch-l2'*)"
_syn_cls="$(grep -m1 -oE "\^# FAIL: \(${MARKER_CLASS}+\)" <<<"$_syn_alt" \
            | sed 's/^\^# FAIL: (//; s/)$//' | tr '|' '\n' | sort)"
_syn_swp="$(grep -oE "'# FAIL: ${MARKER_CLASS}+'" <<<"$_syn_case" \
            | sed "s/'# FAIL: //; s/'$//" | sort -u)"
assert_eq "$_syn_cls" "$_syn_swp" "a digit-bearing marker extracts identically on both sides (shared class, no divergence)"
grep -q 'route-mismatch-l2' <<<"$_syn_swp"
assert_eq 0 $? "the digit-bearing marker survives the SWEEP-side extraction intact (the exact case the old '[a-z-]+' class truncated)"

# ===========================================================================
# (s) EVERY launch shape scrubs its environment  [I3]
# ===========================================================================
# The existing mirror assertion (test_providers.sh, "SCRUB list mirrors
# verify_claude_live.sh exactly") compares the `-u VAR` SETS of two files. That
# is necessary but not sufficient twice over: it says nothing about the third
# file's list, and — the hole that actually bit — nothing about whether a
# declared list is APPLIED to a given launch. Two of the four launch shapes were
# wrong on 2026-07-20 while that assertion was green:
#   * verify_providers_live.sh's NEG_SCRUB omitted `-u BASH_ENV`, so with a
#     broken alias file the "classifier honesty" check received a WORKING
#     cma_run_provider from ~/.bashrc and _pass'ed having measured the host's
#     real installation rather than the file it names;
#   * verify_claude_live.sh's run_tui applied NO scrub at all (the array was
#     referenced only by run_cli), making that file's own header claim "Each
#     launch runs in a SCRUBBED env" FALSE for TUI mode.
#
# So assert both properties over ALL launch shapes, mechanically:
#   1. all three files declare the SAME scrub set (widens the two-file mirror);
#   2. every `bash -c` launch site in them APPLIES a scrub array.
# Continuations are joined first (the STUI launch spreads its scrub and its
# `bash -c` across two physical lines) and BOTH full-line and inline comments
# stripped (several of these files' comments legitimately discuss `bash -c`, and
# a trailing ` # … bash -c …` remark on a code line must not read as a site).
it "every launch shape in every verifier scrubs its environment (all four sites, not just the mirrored pair)"
# Same override rationale as CMA_STUI_BIN / CMA_LIVE_BIN: each file must be
# replaceable by a mutated scratchpad copy so this lint can be shown to have
# teeth without editing the shared checkout. $STUI and $LIVE already carry that
# for two of the three; CMA_CLIVE_BIN adds it for the third.
CLIVE="${CMA_CLIVE_BIN:-$TESTS_DIR/verify_claude_live.sh}"
SCRUB_FILES=("$STUI" "$CLIVE" "$LIVE")
# 1. identical declared sets across all three files.
#
# Full-line comments are STRIPPED before extracting. This is not tidiness, it is
# required for the assertion to have teeth: these files' comments legitimately
# discuss the scrub vars by name (e.g. "-u BASH_ENV is LOAD-BEARING here"), so a
# raw grep happily reads a var out of PROSE that the CODE no longer scrubs.
# Verified: without this strip, deleting `-u BASH_ENV` from NEG_SCRUB left this
# leg green — the neighbouring comment supplied the token.
_scrub_set() { grep -vE '^[[:space:]]*#' "$1" | grep -oE -- '-u [A-Z_]+' | awk '{print $2}' | sort -u; }
_ref_scrub=""
for _f in "${SCRUB_FILES[@]}"; do
  _s="$(_scrub_set "$_f")"
  if [[ -z "$_ref_scrub" ]]; then _ref_scrub="$_s"; continue; fi
  assert_eq "$_ref_scrub" "$_s" "$(basename "$_f") declares the same scrub set as the others"
done
grep -q 'BASH_ENV' <<<"$_ref_scrub"
assert_eq 0 $? "BASH_ENV is in the scrub set (without it a broken alias file is undetectable — the launch gets a wrapper from ~/.bashrc)"

# 2. every launch site applies a scrub array.
#
# ONE definition of "a launch line" (continuations joined, full-line AND inline
# comments stripped, `bash -c` lines kept) is shared by the real count and the
# synthetic pin below, so the two cannot drift. The ` #…` inline strip is what
# stops a future `code # … bash -c …` remark from masquerading as a phantom 5th
# site; it is whitespace-anchored (a shell comment opens only at a word break),
# so a `#` inside code — e.g. `bash -c 'echo #x'` — is left intact.
_launch_lines() {  # emit FILE's launch lines
  awk '{while(sub(/\\$/,"")){if(getline nl<=0) break; $0=$0 nl}; print}' "$1" \
    | grep -vE '^[[:space:]]*#' | sed 's/[[:space:]]#.*$//' | grep 'bash -c'
}
_unscrubbed=""
_launch_sites=0
for _f in "${SCRUB_FILES[@]}"; do
  while IFS= read -r _line; do
    _launch_sites=$(( _launch_sites + 1 ))
    grep -q 'SCRUB\[@\]}' <<<"$_line" || _unscrubbed="$_unscrubbed $(basename "$_f")"
  done < <(_launch_lines "$_f")
done
assert_eq "" "$_unscrubbed" "every 'bash -c' launch site applies a SCRUB array (an unscrubbed one names its file here)"
# The anti-vacuity control: if the extraction found no launch sites at all, the
# assertion above would pass trivially. All four known shapes must be seen.
assert_eq 4 "$_launch_sites" "all four launch shapes were actually inspected (STUI, run_cli, run_tui, NEG_SCRUB)"
# The inline-comment pin, via the SAME _launch_lines helper: a synthetic file
# with one genuine launch line plus one inline `# … bash -c …` remark must yield
# exactly ONE site. If the inline strip is ever dropped from _launch_lines, this
# sees 2 and fails (while the four real files, having no such remark today, would
# not have caught it).
_M4_SYN="$HOME/m4-inline-launch.sh"
{ printf '  real=$( "${SCRUB[@]}" bash -c %s )\n' "'echo hi'"
  printf '  foo=1   # a remark that merely mentions bash -c in prose\n'; } > "$_M4_SYN"
_M4_SITES=0
while IFS= read -r _; do _M4_SITES=$(( _M4_SITES + 1 )); done < <(_launch_lines "$_M4_SYN")
assert_eq 1 "$_M4_SITES" "an inline '# … bash -c …' comment is NOT counted as a launch site (only the genuine one is)"

# ===========================================================================
# (t) the sentinel is UNSET before cma_run_provider runs, so an adversarial
#     wrapper cannot FORGE launch-impossible-no-wrapper  [TEETH, security]
# ===========================================================================
# launch-impossible-no-wrapper is an UN-GATED verdict: it fails the whole suite
# from a single provider's turn, at every status (case (p)). The broken-install
# branch fires on `rc == 96 && out contains $CMA_STUI_NO_WRAPPER`, and BOTH
# halves are suppliable by a hostile turn: `ccr` forwards the agent's exit code
# verbatim (so `exit 96` is trivial) and the sentinel is EXPORTED into the launch
# environment. The one thing that stops the forgery is the `unset
# CMA_STUI_NO_WRAPPER` performed the instant the guard has passed, BEFORE
# cma_run_provider is invoked (verify_superpowers_tui.sh): an adversarial wrapper
# then inherits an EMPTY sentinel and cannot echo the real value back.
#
# The fixture is exactly that adversary — a wrapper that echoes whatever
# CMA_STUI_NO_WRAPPER it inherited and exits 96 — installed via the alias-file
# override so the real launch path runs. With the unset in place the echoed value
# is empty, the broken-install grep misses, and the run falls through to the
# honest route gate (route-unproven here, since the adversary applies no route).
# Delete the unset and the same fixture forges launch-impossible-no-wrapper.
it "sentinel unset: an adversarial wrapper echoing its inherited sentinel + exit 96 cannot forge launch-impossible-no-wrapper"
FORGE_ALIASES="$HOME/forge-aliases.sh"
cat > "$FORGE_ALIASES" <<'EOF'
# Adversarial wrapper: echo the inherited sentinel (empty once :348 unset it) and
# exit 96 — the two halves the broken-install guard keys on, both from material
# the parent handed the launch.
cma_run_provider() {
  printf '%s\n' "${CMA_STUI_NO_WRAPPER:-}"
  exit 96
}
EOF
FORGE_EV="$PROOF/providers-routertest-forge.txt"
# A PERFECT route on disk, so the ONLY thing preventing a pass is the missing
# restart receipt — the adversary applies no route — which makes the honest
# fall-through verdict route-unproven, cleanly distinct from any forged one.
set_route 'routertest,router-model-1' 'routertest,router-fast-1'
STUI_ALIAS_FILE="$FORGE_ALIASES" run_stui routertest "$FORGE_EV"
assert_eq 1 "$STUI_RC" "the adversarial launch still exits 1 (not a pass)"
# THE load-bearing assertion: the un-gated broken-install verdict must NOT be forged.
assert_file_not_contains "$FORGE_EV" 'launch-impossible-no-wrapper' "an adversarial wrapper cannot forge the broken-install verdict — the sentinel was unset before it ran, so its echo is empty and the guard's grep misses"
grep -q 'launch-impossible-no-wrapper' <<<"$STUI_OUT"
assert_eq 1 $? "stdout does not carry the forged broken-install verdict either"
# The non-vacuity control: the wrapper WAS defined and the guard did NOT fire, so
# the run reached the launch and fell through to the honest route gate.
assert_file_contains "$FORGE_EV" '# FAIL: route-unproven' "the forgery blocked, the run falls through to the honest route verdict — proving the launch path actually ran"
assert_file_contains "$FORGE_EV" '# ROUTE-RESOLVED: routertest/router-model-1' "the route on disk was PERFECT — nothing about the route explains the (blocked) forgery"

# ===========================================================================
# (u) the broken-install sentinel is derived PER RUN (not a replayable constant)
# ===========================================================================
# The guard prints $CMA_STUI_NO_WRAPPER to stdout when the wrapper is undefined
# (case (p)), and that value lands in the evidence file. A compile-time-constant
# sentinel would be readable from the world-readable source and replayable across
# runs — a hostile turn on ANY later run could echo the known value to forge the
# broken-install verdict of case (t). The derivation folds in $$ + timestamp +
# 2×$RANDOM precisely so a value learned from one run does not satisfy the next.
# Two broken-install launches must therefore emit DIFFERENT sentinels; make the
# derivation a constant and they collide.
it "per-run sentinel: two broken-install launches emit DIFFERENT sentinels (not a replayable compile-time constant)"
M2_BROKEN="$HOME/m2-broken-aliases.sh"
# A truncated alias file: the unterminated string aborts `source`, leaving
# cma_run_provider undefined so the guard fires and prints the sentinel.
printf 'cma_run_provider() {\n  printf %s\n' "'truncated mid-write" > "$M2_BROKEN"
M2_EV1="$PROOF/providers-routertest-persent1.txt"
M2_EV2="$PROOF/providers-routertest-persent2.txt"
set_route 'routertest,router-model-1' 'routertest,router-fast-1'
STUI_ALIAS_FILE="$M2_BROKEN" run_stui routertest "$M2_EV1"
STUI_ALIAS_FILE="$M2_BROKEN" run_stui routertest "$M2_EV2"
# Both launches must have taken the broken-install path, or there is no sentinel
# to compare (non-vacuity).
assert_file_contains "$M2_EV1" '# FAIL: launch-impossible-no-wrapper' "launch 1 took the broken-install path (the sentinel was emitted)"
assert_file_contains "$M2_EV2" '# FAIL: launch-impossible-no-wrapper' "launch 2 took the broken-install path (the sentinel was emitted)"
M2_S1="$(grep -oE '__CMA_STUI_WRAPPER_UNDEFINED__[^[:space:]]+' "$M2_EV1" | head -1)"
M2_S2="$(grep -oE '__CMA_STUI_WRAPPER_UNDEFINED__[^[:space:]]+' "$M2_EV2" | head -1)"
assert_eq 0 "$( [[ -n "$M2_S1" ]] && echo 0 || echo 1 )" "launch 1's evidence carries the emitted sentinel value"
assert_eq 0 "$( [[ "$M2_S1" != "$M2_S2" ]] && echo 0 || echo 1 )" "the two launches' sentinels DIFFER — the derivation is per-run, not a compile-time constant"
# ...and structurally: the derivation interpolates per-run entropy rather than
# being a bare string literal readable from the world-readable source.
M2_SENT_LINE="$(grep -m1 -E '^[[:space:]]*CMA_STUI_NO_WRAPPER=' "$STUI")"
grep -qE '\$\$|\$\(date|\$\{?RANDOM' <<<"$M2_SENT_LINE"
assert_eq 0 $? "the sentinel derivation interpolates per-run entropy (\$\$ / date / RANDOM), not a constant string"

# ===========================================================================
# (v) CONTEXT-INADEQUATE: a verified provider whose backend context window is
#     smaller than Claude Code's minimum request is KNOWN-NON-WORKING, not a
#     suite failure — a THIRD class beside account-dead and route-integrity
# ===========================================================================
# THE HOLE THIS CLOSES. helixagent passes layers 1-2 (small ~512-token probes)
# and reaches status=verified, so gate_for_status GATES it. But its real backend
# (a local llama.cpp launched with a 3072-token context) returns a hard
#   400 request (67288 tokens) exceeds the available context size (3072 tokens)
# on the large, tool/skill-heavy layer-4 turn. Before the context-inadequate
# branch that landed in the gated `_fail` and pinned the whole live-providers leg
# red — a provider-side backend-size condition (relaunch the server bigger)
# counted as fresh toolkit breakage, exactly the signal-destroying outcome
# gate_for_status prevents for account-dead. It is its own KNOWN-NON-WORKING
# class: honest (a distinct '# FAIL: context-inadequate' marker, never a pass),
# evidence-based (the two token counts are read from the live 400, never a
# declared/pinned context), and NOT counted — while a genuine layer-4 PASS, an
# account-dead 403, and a non-context 400/500 are all left exactly as they were.
it "context-inadequate: a VERIFIED provider's context-overflow 400 is KNOWN-NON-WORKING, not a suite failure"
CI_EV="$PROOF/providers-routertest-ctxinadequate.txt"
# Shaped like the real helixagent evidence: a MATCHING route (so the attribution
# gate PASSES and cannot be what fails here), then Claude Code's own 400.
{
  echo '# ROUTE-INTENDED: routertest/router-model-1 (transport=router)'
  echo '# ROUTE-INTENDED-BACKGROUND: routertest/router-model-1'
  echo '{"type":"result","is_error":true,"api_error_status":400,"result":"API Error: 400 request (67288 tokens) exceeds the available context size (3072 tokens), try increasing it"}'
  echo '# ROUTE-RESOLVED: routertest/router-model-1'
  echo '# ROUTE-RESOLVED-BACKGROUND: routertest/router-model-1'
  echo '# FAIL: api-error'
} > "$CI_EV"
out="$(run_classifier "$CI_EV" 1 verified "FAIL: api-error")"
grep -q 'KNOWN-NON-WORKING: layer-4 context-inadequate' <<<"$out"
assert_eq 0 $? "a context-overflow on a status=verified provider is reported KNOWN-NON-WORKING (context-inadequate)"
grep -q 'SUITE-FAILURE' <<<"$out"
assert_eq 1 $? "and it is NOT counted as a suite failure (backend-size is provider-side, like account-dead)"
# Evidence-based, never the pin: the two numbers come out of the live 400.
grep -q 'backend context 3072 tokens < Claude Code request 67288 tokens' <<<"$out"
assert_eq 0 $? "the operator message names the REAL backend window (3072) and request (67288), read from the 400 — not the pin"
# The distinct, honest marker is appended to the evidence, on its face.
assert_file_contains "$CI_EV" '# FAIL: context-inadequate (backend 3072 tokens < request 67288)' "a distinct context-inadequate marker is written to the evidence (never a faked pass)"

# --- (v-openrouter) the OpenAI/OpenRouter 'maximum context length' phrasing, with
#     the window/request numbers in REVERSED order, is ALSO context-inadequate and
#     its numbers land in the RIGHT roles (not swapped). Exact live openrouter
#     shape: nemotron 262144 window < 292211 request. This is what pinned the
#     live-providers leg red until the classifier regex learned this phrasing.
it "context-inadequate: the OpenAI/OpenRouter 'maximum context length' phrasing (reversed order) is classified + extracted without swapping the numbers"
OR_EV="$PROOF/providers-routertest-ctxinadequate-openrouter.txt"
{
  echo '# ROUTE-INTENDED: routertest/router-model-1 (transport=router)'
  echo '# ROUTE-RESOLVED: routertest/router-model-1'
  echo '{"type":"result","is_error":true,"api_error_status":400,"result":"API Error: 400 maximum context length is 262144 tokens. However, you requested about 292211 tokens (158579 of tool input). Please reduce the length."}'
  echo '# FAIL: api-error'
} > "$OR_EV"
out="$(run_classifier "$OR_EV" 1 verified "FAIL: api-error")"
grep -q 'KNOWN-NON-WORKING: layer-4 context-inadequate' <<<"$out"
assert_eq 0 $? "the OpenRouter 'maximum context length' overflow is KNOWN-NON-WORKING (context-inadequate)"
grep -q 'SUITE-FAILURE' <<<"$out"
assert_eq 1 $? "and it is NOT counted as a suite failure"
# KEY: window (262144, the FIRST number in this phrasing) and request (292211, the
# SECOND) land in the RIGHT roles — the reversed order is handled, NOT swapped.
grep -q 'backend context 262144 tokens < Claude Code request 292211 tokens' <<<"$out"
assert_eq 0 $? "the reversed-order phrasing extracts window=262144 and request=292211 correctly (not swapped)"
assert_file_contains "$OR_EV" '# FAIL: context-inadequate (backend 262144 tokens < request 292211)' "the marker names window<request in the right order for the OpenRouter phrasing"

# --- CONTROL 1: a NON-context 500 on the SAME verified provider STILL counts ---
# The narrowing must not leak: only the context-overflow shape is the new class.
it "control: a NON-context error on a verified provider still fails the suite (no over-broadening)"
NC_EV="$PROOF/providers-routertest-noncontext500.txt"
{ echo '{"is_error":true,"api_error_status":500,"result":"API Error: 500 internal server error"}'
  echo '# FAIL: api-error'; } > "$NC_EV"
out="$(run_classifier "$NC_EV" 1 verified "FAIL: api-error")"
grep -q 'SUITE-FAILURE' <<<"$out"
assert_eq 0 $? "a non-context 500 on a verified provider is STILL a counted failure"
grep -q 'context-inadequate' <<<"$out"
assert_eq 1 $? "and it is NOT misclassified as context-inadequate"

# --- CONTROL 2: an account-dead 403 stays its OWN class (account-side) ---------
it "control: an account-dead 403 stays account-side, never context-inadequate"
AD_EV="$PROOF/providers-routertest-accountdead.txt"
{ echo '{"is_error":true,"api_error_status":403,"result":"Failed to authenticate. API Error: 403 Sorry, your account balance is insufficient"}'
  echo '# FAIL: api-error'; } > "$AD_EV"
out="$(run_classifier "$AD_EV" 0 failed "FAIL: api-error")"
grep -q 'account-side' <<<"$out"
assert_eq 0 $? "a 403 on a status=failed provider is still reported as account-side known-non-working"
grep -q 'context-inadequate' <<<"$out"
assert_eq 1 $? "a 403 carries no context-overflow text, so it is NEVER context-inadequate"

# --- CONTROL 3: route attribution outranks context-inadequate -----------------
# A turn served by the WRONG backend is non-attributable whatever else it says;
# the integrity gate must win even when the (foreign) transcript also overflowed.
it "control: a route-mismatch outranks a co-present context-overflow (integrity first)"
RC_EV="$PROOF/providers-routertest-ctx-vs-route.txt"
{ echo 'API Error: 400 request (67288 tokens) exceeds the available context size (3072 tokens)'
  echo '# FAIL: route-mismatch (intended=routertest/router-model-1 resolved=chutes/zai-org/GLM-5.2-TEE)'; } > "$RC_EV"
out="$(run_classifier "$RC_EV" 1 verified "FAIL: route-mismatch")"
grep -q 'SUITE-FAILURE: layer-4 route attribution' <<<"$out"
assert_eq 0 $? "route attribution is decided FIRST — the mismatch fails the suite"
grep -q 'context-inadequate' <<<"$out"
assert_eq 1 $? "the co-present overflow text does NOT downgrade a route-integrity failure to known-non-working"

# --- (v-nvidia) the no-"about" 'maximum context length' variant ----------------
# Live 2026-07-26 (nvidia3/mistral-small): "maximum context length is 32768
# tokens. However, you requested 113865 tokens (48329 in the messages, 65536 in
# the completion)" — NO "about", and trailing parenthetical numbers. The branch
# regex used to REQUIRE "about", so this overflow fell through to a counted
# api-error; and a careless tail-number extraction would grab 65536 (the
# completion budget) instead of 113865 (the request).
it "context-inadequate: the no-'about' 'maximum context length' variant is classified, and the request number is NOT the trailing parenthesis"
NV_EV="$PROOF/providers-routertest-ctxinadequate-nvidia.txt"
{
  echo '# ROUTE-INTENDED: routertest/router-model-1 (transport=router)'
  echo '# ROUTE-RESOLVED: routertest/router-model-1'
  echo '{"type":"result","is_error":true,"api_error_status":400,"result":"API Error: 400 This model'"'"'s maximum context length is 32768 tokens. However, you requested 113865 tokens (48329 in the messages, 65536 in the completion). Please reduce the length of the messages or completion."}'
  echo '# FAIL: api-error'
} > "$NV_EV"
out="$(run_classifier "$NV_EV" 1 verified "FAIL: api-error")"
grep -q 'KNOWN-NON-WORKING: layer-4 context-inadequate' <<<"$out"
assert_eq 0 $? "the no-'about' overflow phrasing is KNOWN-NON-WORKING (context-inadequate)"
grep -q 'SUITE-FAILURE' <<<"$out"
assert_eq 1 $? "and it is NOT counted as a suite failure"
grep -q 'backend context 32768 tokens < Claude Code request 113865 tokens' <<<"$out"
assert_eq 0 $? "window=32768 and request=113865 — NOT the trailing 65536 completion budget"
assert_file_contains "$NV_EV" '# FAIL: context-inadequate (backend 32768 tokens < request 113865)' "the marker names the real window<request pair"

# --- (w) ENVIRONMENT-INCOMPATIBLE: the provider rejects an MCP tool NAME -------
# Live 2026-07-26 (nvidia4/mistral-small): "Function name was
# mcp__plugin_aws-startup-advisor_awsknowledge__aws___get_regional_availability
# but must be a-z, A-Z, 0-9, or contain underscores and dashes, with a maximum
# length of 64." The name is minted by the MCP plugin ecosystem and advertised
# verbatim by Claude Code — the toolkit neither generates nor rewrites it, so a
# strict provider's grammar rejection is NOT a routing defect: its own
# KNOWN-NON-WORKING class, distinct marker, not counted.
it "environment-incompatible: a provider function-name-grammar 400 is KNOWN-NON-WORKING, not a suite failure"
EI_EV="$PROOF/providers-routertest-envincompatible.txt"
{
  echo '# ROUTE-INTENDED: routertest/router-model-1 (transport=router)'
  echo '# ROUTE-RESOLVED: routertest/router-model-1'
  echo '{"type":"result","is_error":true,"api_error_status":400,"result":"API Error: 400 Function name was mcp__plugin_aws-startup-advisor_awsknowledge__aws___get_regional_availability but must be a-z, A-Z, 0-9, or contain underscores and dashes, with a maximum length of 64."}'
  echo '# FAIL: api-error'
} > "$EI_EV"
out="$(run_classifier "$EI_EV" 1 verified "FAIL: api-error")"
grep -q 'KNOWN-NON-WORKING: layer-4 environment-incompatible' <<<"$out"
assert_eq 0 $? "a function-name-grammar 400 on a status=verified provider is reported KNOWN-NON-WORKING (environment-incompatible)"
grep -q 'SUITE-FAILURE' <<<"$out"
assert_eq 1 $? "and it is NOT counted as a suite failure (the toolkit does not mint MCP tool names)"
grep -q 'environment-incompatible (provider rejects MCP tool name mcp__plugin_aws-startup-advisor' <<<"$(tail -1 "$EI_EV")"
assert_eq 0 $? "the distinct marker names the rejected tool, on the evidence's face"

it "control: a generic 400 with NO grammar text still counts (no over-broadening)"
G4_EV="$PROOF/providers-routertest-generic400.txt"
{ echo '{"is_error":true,"api_error_status":400,"result":"API Error: 400 Bad request: something unrelated"}'
  echo '# FAIL: api-error'; } > "$G4_EV"
out="$(run_classifier "$G4_EV" 1 verified "FAIL: api-error")"
grep -q 'SUITE-FAILURE' <<<"$out"
assert_eq 0 $? "a generic 400 on a verified provider is STILL a counted failure"
grep -q 'environment-incompatible' <<<"$out"
assert_eq 1 $? "and it is NOT misclassified as environment-incompatible"

# --- the gated RUN_TUI_EV disk sweep leaves the appended marker alone ----------
# The per-provider classifier decides counting, but a SECOND, independent disk
# sweep re-reads the last marker of every gated provider's evidence. A verified
# provider IS in that gated set, so the appended '# FAIL: context-inadequate'
# must be excluded there too, or the leg fails from the sweep instead.
it "the gated RUN_TUI_EV sweep does NOT flag a context-inadequate marker (but still flags a real api-error)"
# shellcheck disable=SC2034  # RUN_TUI_EV is read by the sweep body eval'd below
marked=(); RUN_TUI_EV=("$CI_EV"); eval "$SWEEP_CODE"
assert_eq 0 "${#marked[@]}" "the sweep leaves the context-inadequate evidence alone (known-non-working, reported on its own line)"
# discrimination control: the generic api-error evidence IS still swept.
# shellcheck disable=SC2034  # RUN_TUI_EV is read by the sweep body eval'd below
marked=(); RUN_TUI_EV=("$NC_EV"); eval "$SWEEP_CODE"
assert_eq 1 "${#marked[@]}" "the same sweep still flags a generic api-error marker — it discriminates, it is not uniformly quiet"

# --- and the status-independent route sweep never claims it either ------------
it "the status-independent route sweep does not flag context-inadequate (it carries no route-* marker)"
# shellcheck disable=SC2034  # ALL_TUI_EV is read by the sweep body eval'd below
route_marked=(); ALL_TUI_EV=("$CI_EV"); eval "$ROUTE_SWEEP_CODE"
assert_eq 0 "${#route_marked[@]}" "context-inadequate is not a route failure, so the route sweep leaves it alone"

# ===========================================================================
# (v2) PAIRED MUTATION (§1.1): delete the context-inadequate branch and the
#      very same overflow evidence flips to a COUNTED suite failure  [TEETH]
# ===========================================================================
# Everything above passes only as long as the branch is present. Prove it is the
# BRANCH that carries the behaviour: excise it from a COPY of the extracted
# classifier (never the shared checkout) and re-run identical evidence. With the
# branch gone the overflow falls through to `elif (( gated ))` and IS counted —
# so a later refactor that silently drops the branch turns (v) red instead of
# quietly re-bluffing helixagent back to a counted-verified failure.
it "paired mutation: WITHOUT the context-inadequate branch, the overflow is a COUNTED failure (teeth), and WITH it it is not"
MUT_EV="$PROOF/providers-routertest-ctx-mutation.txt"
{ echo '{"is_error":true,"api_error_status":400,"result":"API Error: 400 request (67288 tokens) exceeds the available context size (3072 tokens)"}'
  echo '# FAIL: api-error'; } > "$MUT_EV"
# Excise the branch: drop every line from the context-inadequate `elif` (the
# only `elif grep -qiE 'request \(` in the block — anchored on its distinctive
# llama.cpp-regex OPEN, not the generic `elif grep -qiE`, because the
# environment-incompatible branch below also uses that shape) up to — but not
# including — the `elif (( gated ))` that follows it. That range spans THREE
# classifier branches (context-inadequate, account-side,
# environment-incompatible); the mutation stays honest because neither of the
# other two can match the 400-overflow evidence used below (no 402/403, no
# function-name grammar text), so the overflow provably falls through to the
# gated fallback. Bracket classes, not backslash-escaped parens, per the
# BSD-awk portability rule (no 3-arg match; 2-arg regex only).
# Guard (future-proofing): the excision anchors on the SOLE
# `elif grep -qiE 'request \(` branch. If a later edit adds a second such
# branch the awk range could silently swallow too much — losing the mutation's
# teeth without failing — so assert the anchor is unambiguous, failing LOUDLY
# here to force the awk range to be re-scoped rather than silently
# over-excising.
assert_eq 1 "$(grep -cE "^[[:space:]]*elif grep -qiE 'request \\\\[(]" <<<"$CLASSIFY_SRC")" "exactly one context-inadequate branch exists — the mutation excision anchor is unambiguous"
MUT_CLASSIFY="$(awk '
  /^[[:space:]]*elif grep -qiE .request \\/ {skip=1}
  skip && /^[[:space:]]*elif [(][(] gated [)][)]; then/ {skip=0}
  !skip {print}
' <<<"$CLASSIFY_SRC")"
# Anti-vacuity: the mutation must have actually removed the branch and changed
# the source, or the pair proves nothing.
assert_eq 0 "$( grep -q 'context-inadequate' <<<"$MUT_CLASSIFY" && echo 1 || echo 0 )" "the mutated classifier no longer contains the context-inadequate branch"
assert_eq 0 "$( [[ "$MUT_CLASSIFY" != "$CLASSIFY_SRC" ]] && echo 0 || echo 1 )" "the mutation changed the classifier (not a no-op)"
grep -q 'elif (( gated ))' <<<"$MUT_CLASSIFY"
assert_eq 0 $? "the gated fallback the overflow now falls through to is still present in the mutant"
# MUTANT direction: with the branch removed, the overflow on a verified provider
# IS counted.
mut_out="$( ( tui_ev="$MUT_EV"; gated=1; status=verified; id="routertest"; tui_out="FAIL: api-error"
             _fail() { printf 'SUITE-FAILURE: %s\n' "$1"; }
             eval "$MUT_CLASSIFY" ) 2>&1 )"
grep -q 'SUITE-FAILURE' <<<"$mut_out"
assert_eq 0 $? "MUTANT: with the branch removed, the overflow on a verified provider IS counted (the branch has teeth)"
grep -q 'KNOWN-NON-WORKING' <<<"$mut_out"
assert_eq 1 $? "MUTANT: it is no longer written off as known-non-working"
# RESTORED direction: the REAL, unmutated classifier ($CLASSIFY_SRC, extracted
# from the shared file and never edited) leaves the SAME evidence uncounted.
rm -f "$MUT_EV"
{ echo '{"is_error":true,"api_error_status":400,"result":"API Error: 400 request (67288 tokens) exceeds the available context size (3072 tokens)"}'
  echo '# FAIL: api-error'; } > "$MUT_EV"
real_out="$(run_classifier "$MUT_EV" 1 verified "FAIL: api-error")"
grep -q 'SUITE-FAILURE' <<<"$real_out"
assert_eq 1 $? "RESTORED: the real classifier leaves the overflow uncounted — both directions of the pair proven"
grep -q 'KNOWN-NON-WORKING: layer-4 context-inadequate' <<<"$real_out"
assert_eq 0 $? "RESTORED: and reports it as context-inadequate known-non-working"

# ===========================================================================
# rc=124 is TWO different failures and must not be reported as one
#
# Field evidence (2026-07-27): every timing-out alias on this host — chutes1-4,
# kilo, nvidia, nvidia3, openrouter2/3, poe3, all long-time-to-first-token
# reasoning models, while every fast model PASSed — was reported as
# "launch hung within Ns (trust/overwrite prompt?)". None of them had a dialog.
# Their own result JSON, in the same evidence file, said
# terminal_reason "aborted_streaming" with output_tokens 0 / cost 0 /
# duration_api_ms 0, and openrouter2 completed in 141s INSIDE a 180s bound.
# The bound expiring says the process outlived it; it never says why. Naming a
# cause the captured transcript contradicts is the same defect class as the
# "(Go version mismatch?)" misdiagnosis fixed in the same release.
# ===========================================================================

it "rc=124 WITH an aborted-stream result is reported as stream-aborted, not a dialog hang"
ABORT_EV="$PROOF/providers-routertest-streamaborted.txt"; rm -f "$ABORT_EV"
set_route "routertest,router-model-1" "routertest,router-fast-1"
FAKE_LAUNCH_HANG=aborted run_stui routertest "$ABORT_EV"
assert_eq 1 "$STUI_RC" "stream-aborted still FAILs the leg (never a pass)"
grep -q '^FAIL: stream-aborted' <<<"$STUI_OUT"
assert_eq 0 $? "stdout names stream-aborted explicitly"
# Match the GUESS, not the words. The corrected message deliberately still
# contains the phrase "trust/overwrite" — it says the failure is NOT one — so a
# bare substring test flags the fix it is meant to protect. Pin the dialog-hang
# verdict's own wording instead.
grep -q 'launch hung within' <<<"$STUI_OUT"
assert_eq 1 $? "stdout does NOT return the dialog-hang verdict for an aborted stream"
assert_file_contains "$ABORT_EV" '# FAIL: stream-aborted' "evidence carries the distinct stream-aborted marker"
assert_file_contains "$ABORT_EV" 'output_tokens=0' "marker records that ZERO tokens were served — the actionable fact"
assert_file_not_contains "$ABORT_EV" '# FAIL: timeout' "the misleading generic timeout marker is gone"

it "CONTROL: rc=124 with NO transcript is still a plain timeout (dialog branch kept)"
# Both directions, so the fix is a discrimination and not a blanket rename: a
# launch that produces nothing at all really is the dialog-hang shape, and must
# keep its original classification.
SILENT_EV="$PROOF/providers-routertest-silenthang.txt"; rm -f "$SILENT_EV"
set_route "routertest,router-model-1" "routertest,router-fast-1"
FAKE_LAUNCH_HANG=silent run_stui routertest "$SILENT_EV"
assert_eq 1 "$STUI_RC" "silent hang FAILs the leg"
grep -q 'trust/overwrite prompt' <<<"$STUI_OUT"
assert_eq 0 $? "a silent hang DOES still name the dialog as the likely cause"
assert_file_contains "$SILENT_EV" '# FAIL: timeout' "silent hang keeps the generic timeout marker"
assert_file_not_contains "$SILENT_EV" '# FAIL: stream-aborted' "and is NOT relabelled stream-aborted"

summary
