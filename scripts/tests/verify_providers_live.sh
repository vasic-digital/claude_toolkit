#!/usr/bin/env bash
# verify_providers_live.sh — read-only proof that the provider-alias feature is
# coherent against the REAL installed state on this host (not a sandbox).
#
# Like verify_opencode_live.sh: NOT named test_*.sh (run-all.sh won't auto-pick
# it), read-only, and SKIPs (exit 0) when no provider aliases are installed.
# Every check writes raw evidence to $PROOF_DIR.
#
# Knobs:
#   PROOF_DIR  where to write evidence (default scripts/tests/proof)
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/assert.sh"

PROOF_DIR="${PROOF_DIR:-$TESTS_DIR/proof}"
mkdir -p "$PROOF_DIR"
PDIR="$HOME/.local/share/claude-multi-account/providers"
ALIASES="${ALIAS_FILE:-$HOME/.local/share/claude-multi-account/aliases.sh}"

if [[ ! -d "$PDIR" ]] || ! compgen -G "$PDIR/*.env" >/dev/null 2>&1; then
  echo "SKIP: no provider aliases installed on this host — live provider verification skipped."
  exit 0
fi

set +e
EV="$PROOF_DIR/50-providers-live.txt"
: > "$EV"

it "every provider env file has the required non-secret fields"
ok=1
for f in "$PDIR"/*.env; do
  for key in CMA_PROVIDER_ID CMA_PROVIDER_KEYVAR CMA_PROVIDER_TRANSPORT \
             CMA_PROVIDER_MODEL CMA_PROVIDER_CONFIG_DIR; do
    grep -q "^$key=" "$f" || { ok=0; echo "MISSING $key in $f" >>"$EV"; }
  done
done
assert_eq 1 "$ok" "all env files well-formed"

it "NO secret values are present in env files (structural: only CMA_PROVIDER_* lines)"
# Stronger than a length heuristic: every non-comment, non-blank line in each
# env file MUST be a CMA_PROVIDER_*= assignment. Anything else would be a stray
# value and a potential leak.
stray=0
for f in "$PDIR"/*.env; do
  bad="$(grep -vE '^[[:space:]]*#|^[[:space:]]*$|^CMA_PROVIDER_[A-Z_]+=' "$f")"
  [[ -n "$bad" ]] && { stray=1; printf 'STRAY in %s:\n%s\n' "$f" "$bad" >>"$EV"; }
done
assert_eq 0 "$stray" "env files contain only CMA_PROVIDER_* assignments"

it "each provider alias resolves to cma_run_provider in the alias file"
ok=1
for f in "$PDIR"/*.env; do
  # Source (values are shell-quoted) to read the id cleanly — never sed-parse.
  # shellcheck source=/dev/null  # runtime provider env file, path only known at execution
  id="$( set -a; . "$f"; set +a; printf '%s' "$CMA_PROVIDER_ID" )"
  grep -qE "cma_run_provider $id(\"| )" "$ALIASES" || { ok=0; echo "no alias for $id" >>"$EV"; }
done
assert_eq 1 "$ok" "every provider has an alias line"

it "the cma_run_provider wrapper is defined in the alias file"
grep -q '^cma_run_provider()' "$ALIASES"; assert_eq 0 $? "wrapper present"

it "provider config dirs are excluded from account detection"
# Source lib.sh and confirm no ~/.claude-prov-* leaks into detection.
# shellcheck source=/dev/null  # lib.sh loaded dynamically via $SCRIPTS_DIR; path resolved at runtime
( source "$SCRIPTS_DIR/lib.sh" 2>/dev/null; cma_detect_accounts ) > "$PROOF_DIR/51-detected-accounts.txt" 2>/dev/null
grep -q 'prov-' "$PROOF_DIR/51-detected-accounts.txt"; assert_eq 1 $? "no provider dir detected as account"

{
  echo "# provider live verification — $(date)"
  echo "providers installed: $(find "$PDIR" -maxdepth 1 -name '*.env' 2>/dev/null | wc -l | tr -d ' ')"
  echo "ccr installed: $(command -v ccr >/dev/null 2>&1 && echo yes || echo no)"
  echo "LLMsVerifier binary: $([[ -x "$SCRIPTS_DIR/../submodules/LLMsVerifier/bin/model-verification" ]] && echo built || echo not-built)"
} >> "$EV"

# --- layer 3 (semantic) + layer 4 (superpowers-TUI) per installed provider ---
# Read-only against real host state; every sub-check is an honest SKIP when a
# precondition (key/judge/go/network/real-claude) is absent — never a faked
# PASS (§11.4.3). Extends this already-wired file; no proof/ duplicate.
SUMMARY="$PROOF_DIR/providers-summary.json"
printf '{}\n' > "$SUMMARY"
KEYS_FILE="${CMA_KEYS_FILE:-$HOME/api_keys.sh}"

# Strip anything resembling a leaked credential out of captured evidence before
# it lands in $PROOF_DIR. Defense in depth: the drivers are not supposed to
# print keys, but evidence files are read by humans, committed to the repo, and
# must never carry one, even by accident.
#
# The previous version covered exactly two shapes — `sk-` and `Bearer <tok>` —
# which is far narrower than this repo's ~20 provider key families. This widening
# is a defense-in-depth measure against a FUTURE capture, not a response to a
# known leak: the committed proof/ corpus contains no credentials, and the old
# redactor's behaviour on it was correct. Every credential-shaped field in it
# holds either a literal `REDACTED`/`[REDACTED]`/`PLACEHOLDER` marker, a
# `${VAR}` reference, or an empty string. Do not let a redaction firing be read
# as evidence that a secret was present — those are different claims, and
# conflating them raises a false security alarm, which in this repo means
# proposing vendor key rotation and a four-mirror history rewrite over nothing.
#
# Patterns are derived from key shapes that ACTUALLY occur on this host, not
# from imagination — prefixed families (`sk-`/`sk_`, `csk-`, `gsk_`, `cpk_`,
# `hf_`, `fw_`, `nk_`, `up_`, `r8_`, `vck_`, `nvapi-`, `zpka_`, `tvly-`,
# `glpat-`, `github_pat_`, `VENICE_ADMIN_KEY_`, `inference-`, `perm-`, `ak-`,
# `as-`), dot-separated JWTs, and a generic lowercase-prefix net for families
# not yet seen.
#
# Three constraints shape the regexes, and each is load-bearing:
#
#  1. **The gate must survive redaction.** This leg greps `^# (PASS|FAIL:|SKIP)`
#     and the `# ROUTE-INTENDED:`/`# ROUTE-RESOLVED:` markers out of the very
#     files it redacts, and the proof sweep greps `# FAIL:`. A pattern that
#     mangled a verdict or route line would silently disable the gate — a worse
#     defect than the leak. Every rule is therefore anchored on a credential
#     shape, never on a bare token: the tail-length floors (20/24) and the
#     quoted-JSON / `x-api-key:` / `<NAME>KEY=` context requirements exist
#     precisely so ordinary evidence prose cannot trip them. An earlier draft
#     matched unquoted `..._API_KEY:` and ate assertion text out of a suite log.
#  2. **A redacted marker and a variable reference are not secrets.** Every
#     value class below is `[A-Za-z0-9._~+/=-]`, which deliberately excludes
#     `$ { } [ ] < > *`. That single choice makes `${VAR}`, `$VAR`,
#     `[REDACTED]`, `<REDACTED>` and `***REDACTED***` unmatchable, because each
#     begins with an excluded character. It is the fix for a real defect: an
#     earlier draft used `[^"]{8,}` for the quoted-JSON rule, which matches ANY
#     8+ characters — so it fired on `REDACTED` (exactly 8) and on
#     `${PINECONE_API_KEY}` (19), rewrote five evidence files, and was then
#     misreported as having found six live credentials. It had found none. A
#     `${VAR}` reference is load-bearing evidence in its own right: it documents
#     that a config uses env-var indirection instead of an inline secret, which
#     is precisely what a reviewer needs to see. The residue is the bare word
#     case (`REDACTED`, `PLACEHOLDER` — the vocabulary actually present in the
#     corpus, derived not assumed), which is pure alnum and so cannot be
#     excluded by character class; those are protected by a marker before the
#     rules run and restored after. Net effect: `_redact` is IDEMPOTENT, and
#     the committed corpus is a fixed point of it. Both are tested.
#  3. **Bare unprefixed keys are context-gated, not shape-matched.** Several
#     families (32/39/40/41-char bare alnum, and UUID-shaped ones) are
#     indistinguishable from a git SHA, a session id, or a content hash — all of
#     which are legitimate, load-bearing evidence content. Those are redacted
#     only where they appear as a value: `Bearer`, an `Authorization:` /
#     `x-api-key:` header, a quoted `"…api[-_]key": "…"` JSON field, a
#     `<NAME>(KEY|TOKEN|SECRET|PASSWORD)=` assignment, or `ApiKey_<Name>=`.
#     Shape-matching them globally would destroy more evidence than it protects.
#  4. **POSIX/BSD-safe.** BSD `sed -E` is the floor (macOS ships no GNU sed): no
#     `\+`, no `\d`/`\w`/`\b`, no `I` case-insensitivity flag — hence the
#     explicit `[Aa]` classes. Alternations rely on POSIX leftmost-longest so
#     `gsk_`/`csk-` win over the `sk` alternative and keep their own prefix.
#
# Measured two ways over the proof/ corpus:
#   * Over the files _redact is ACTUALLY applied to in production — the 99
#     `*-semantic.txt` / `*-superpowers.txt` evidence files ($sem_ev, $tui_ev,
#     $neg_ev; see the three call sites) — 99 byte-identical, 0 changed. That
#     subset is a fixed point: nothing in it is a credential.
#   * As a worst-case stress test, over ALL 128 files including ones _redact
#     never touches: 127 identical, 1 changed. The one is
#     `62-precommit-hygiene-audit.txt`, a DIFFERENT leg's evidence carrying a
#     deliberately-planted `sk-`-shaped fixture string (`CMA_FAKE_SECRET=`); the
#     old two-pattern redactor scrubbed it too, so this is neither new nor a
#     credential, and production never feeds this file to _redact anyway.
# Zero verdict lines, route markers or `# FAIL:` markers altered either way. The
# synthetic-fixture and mutation tests in scripts/tests/test_redact.sh are what
# prove the rules still fire; a quiet run over the real evidence is the correct
# result, not an absence of coverage.
_redact() {
  [[ -f "$1" ]] || return 0
  # PROTECT: two classes of non-secret token are pure alnum after their prefix
  # and so cannot be excluded by character class. Park them behind a marker
  # containing '@' — a character in no value class below — then restore verbatim
  # at the end. This is what makes re-redacting an already-redacted file a no-op
  # instead of churn, and it is why `_redact` is idempotent.
  #
  #   (a) bare placeholder words: `REDACTED`, `PLACEHOLDER`. Both are the actual
  #       vocabulary in the corpus (derived by scanning it, not assumed); the
  #       bracketed/starred spellings need no protection because they begin with
  #       an excluded character.
  #   (b) tool/message identifiers. Sweeping the corpus for everything the
  #       generic lowercase-prefix net matches returns exactly ONE construct —
  #       `"tool_use_id":"call_<24 alnum>"`, 3 occurrences. An identifier is not
  #       a credential, and redacting it is pure evidence damage. `call` is the
  #       derived one; `toolu`/`msg`/`chatcmpl` are its siblings in the same two
  #       transcript formats (Anthropic `toolu_`/`msg_`, OpenAI `chatcmpl_`/
  #       `call_`) and are excluded for the same reason. This narrows the net to
  #       the unknown KEY families it exists for; it does not weaken it, which
  #       test_redact.sh pins by keeping an unknown-family fixture redacted.
  sed -E \
    -e 's/REDACTED/@@CMA-PH-R@@/g' \
    -e 's/PLACEHOLDER/@@CMA-PH-P@@/g' \
    -e 's/(call|toolu|msg|chatcmpl)_([A-Za-z0-9]{20,})/@@CMA-ID-\1@@\2/g' \
    -e 's/ey[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/ey***REDACTED-JWT***/g' \
    -e 's/(sk|csk|gsk|cpk|nvapi|zpka|tvly|glpat|perm)([-_])[A-Za-z0-9._-]{24,}/\1\2***REDACTED***/g' \
    -e 's/(github_pat|VENICE_ADMIN_KEY|inference)([-_])[A-Za-z0-9]{24,}/\1\2***REDACTED***/g' \
    -e 's/(hf|fw|nk|up|r8|vck|ak|as)([-_])[A-Za-z0-9]{20,}/\1\2***REDACTED***/g' \
    -e 's/([a-z][a-z0-9]{1,9})_[A-Za-z0-9]{24,}/\1_***REDACTED***/g' \
    -e 's/([Bb]earer[[:space:]]+)[A-Za-z0-9._~+\/=-]{8,}/\1***REDACTED***/g' \
    -e 's/("[A-Za-z0-9_.-]*[Aa][Pp][Ii][-_]?[Kk][Ee][Yy]"[[:space:]]*:[[:space:]]*")[A-Za-z0-9._~+\/=-]{8,}"/\1***REDACTED***"/g' \
    -e 's/([Xx]-[Aa][Pp][Ii][-_]?[Kk][Ee][Yy][[:space:]]*:[[:space:]]*)[A-Za-z0-9._~+\/=-]{8,}/\1***REDACTED***/g' \
    -e 's/([Aa]uthorization["'"'"']?[[:space:]]*:[[:space:]]*["'"'"']?)[A-Za-z0-9._~+\/=-]{8,}/\1***REDACTED***/g' \
    -e 's/([A-Za-z_][A-Za-z0-9_]*([Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd])=["'"'"']?)[A-Za-z0-9._~+\/=-]{8,}/\1***REDACTED***/g' \
    -e 's/(ApiKey_[A-Za-z0-9_]*=["'"'"']?)[A-Za-z0-9._~+\/=-]{8,}/\1***REDACTED***/g' \
    -e 's/@@CMA-ID-([a-z]+)@@/\1_/g' \
    -e 's/@@CMA-PH-R@@/REDACTED/g' \
    -e 's/@@CMA-PH-P@@/PLACEHOLDER/g' \
    "$1" > "$1.redacted" 2>/dev/null && mv "$1.redacted" "$1"
}

# gate_for_status echoes 1 when a layers-3/4 failure for a provider in this
# status MUST fail the suite, else 0. Extracted as a function purely so it can
# be unit-tested (scripts/tests/test_providers_gate.sh) — the whole value of
# this scoping rests on `verified` still failing, and an untested gate could
# silently degrade into "never fail", which is the exact bluff class this leg
# was just repaired for.
gate_for_status() {
  if [[ "${1:-}" == "verified" ]]; then
    echo 1
  else
    echo 0
  fi
}

first_id=""
RUN_TUI_EV=()   # layer-4 evidence files written by THIS run — scopes the sweep below
# Every layer-4 evidence file from this run, gated or NOT. Route attribution is
# status-independent (see the FAIL branch below), so its sweep needs the full
# set rather than the account-health-filtered one.
ALL_TUI_EV=()
for f in "$PDIR"/*.env; do
  # shellcheck source=/dev/null  # runtime provider env file, path only known at execution
  IFS=$'\t' read -r id model keyvar baseurl < <(
    set -a; . "$f"; set +a
    printf '%s\t%s\t%s\t%s' "$CMA_PROVIDER_ID" "$CMA_PROVIDER_MODEL" "$CMA_PROVIDER_KEYVAR" "$CMA_PROVIDER_BASE_URL"
  )
  [[ -n "$first_id" ]] || first_id="$id"
  status="$( source "$SCRIPTS_DIR/lib.sh" 2>/dev/null; cma_status_read "$id" )"
  exists=0
  grep -qE "cma_run_provider $id(\"| )" "$ALIASES" 2>/dev/null && exists=1

  # Does a layers-3/4 failure for THIS provider count as a suite failure?
  #
  # Only if the provider independently reached status=verified — i.e. it already
  # passed the existence + tool-calling probes against its real endpoint. Such a
  # provider IS expected to work end to end, so a layer-3/4 failure is genuine
  # breakage and must fail the run.
  #
  # A provider already classified failed / unverified / orphaned is known-broken
  # for ACCOUNT reasons (rejected key, no funds, exhausted quota). It cannot pass
  # a live launch no matter how correct the toolkit is. Counting it as a suite
  # failure restates known account state as new breakage and pins the run
  # permanently red — which destroys the signal entirely, since a genuinely NEW
  # regression becomes indistinguishable from the standing noise.
  #
  # Crucially this is NOT circular and NOT a way to hide failures: `status` is
  # set by INDEPENDENT live HTTP probes (layers 1-2), never by layers 3-4. And
  # these providers are reported EXPLICITLY on their own line below — never
  # silently skipped, never counted as a pass.
  gated="$(gate_for_status "$status")"

  it "semantic (layer 3) for '$id' — PASS/SKIP, never a faked pass"
  sem_ev="$PROOF_DIR/providers-${id}-semantic.txt"
  sem="$( ( [[ -f "$KEYS_FILE" ]] && { set -a +u; . "$KEYS_FILE"; set +a; }
            bash "$SCRIPTS_DIR/providers-semantic.sh" --provider "$id" \
              --model "$model" --key-var "$keyvar" --base-url "$baseurl" ) 2>"$sem_ev" )"
  echo "semantic verdict: ${sem:-skip}" >> "$sem_ev"
  _redact "$sem_ev"
  case "$sem" in
    verified)   _pass "layer-3 semantic PASS for $id" ;;
    # 'unverified' is NOT a transient/inconclusive outcome here: providers-semantic.sh
    # emits it ONLY on driver exit 1. Every genuinely transient condition
    # (transport/infra error, missing key/judge/go/network) is routed to `skip`
    # (exit 2/3) and lands in the SKIP branch below. So this branch is a
    # DEFINITIVE failure and must fail.
    #
    # But definitive does NOT mean "bluffed". Driver exit 1 spans four distinct
    # determinations — sentinel not reflected, prompt-echo bluff, judge below
    # threshold, and a definitive provider rejection of the model-under-test
    # (HTTP 401/402/403/404). All four justify refusing the alias; only two are
    # a bluff. So both arms below report the driver's OWN reason (which
    # providers-semantic.sh writes into $sem_ev) rather than naming a cause.
    unverified)
      if (( gated )); then
        # Strip the source prefix AND the redundant 'layer-3 unverified' label
        # (this line already says both), leaving just the driver's cause.
        _sem_why="$(grep -m1 -E '^providers-semantic\[[^]]*\]: layer-3 ' "$sem_ev" 2>/dev/null \
                    | sed -E -e 's/^providers-semantic\[[^]]*\]: //' \
                             -e 's/^layer-3 unverified — //')"
        _fail "layer-3 semantic" "verdict: unverified for $id — definitive layer-3 failure (${_sem_why:-no driver reason captured}); evidence: $sem_ev"
      else
        # REPORT THE OBSERVED CAUSE, NEVER ASSERT ONE (2026-07-27 audit).
        # `status` being non-'verified' is why this is not COUNTED; it is not
        # evidence of WHY layer-3 failed. status=unverified in particular means
        # INCONCLUSIVE, not rejected — providers-verify.sh emits it for HTTP
        # 429, for any non-4xx code, and even when no verifier binary exists
        # (providers-verify.sh:226,248,252,258). Naming "key rejected /
        # unfunded / quota" there states an account fact nothing measured.
        # providers-semantic.sh already writes the driver's own reason into
        # $sem_ev; surface that instead. Gating is untouched — this branch
        # counts exactly what it counted before.
        # Strip the source prefix AND the redundant 'layer-3 unverified' label
        # (this line already says both), leaving just the driver's cause.
        _sem_why="$(grep -m1 -E '^providers-semantic\[[^]]*\]: layer-3 ' "$sem_ev" 2>/dev/null \
                    | sed -E -e 's/^providers-semantic\[[^]]*\]: //' \
                             -e 's/^layer-3 unverified — //')"
        echo "KNOWN-NON-WORKING: layer-3 unverified for '$id' — ${_sem_why:-no driver reason captured} (provider status=$status, so not counted as a suite failure); evidence: $sem_ev"
      fi ;;
    *)          echo "SKIP: layer-3 preconditions absent for $id" ;;
  esac

  it "superpowers-TUI (layer 4) for '$id' — PASS/SKIP"
  tui_ev="$PROOF_DIR/providers-${id}-superpowers.txt"
  # The sweep below asserts on evidence from providers that are SUPPOSED to
  # work; an account-dead provider's FAIL marker is expected, not a finding.
  (( gated )) && RUN_TUI_EV+=("$tui_ev")
  ALL_TUI_EV+=("$tui_ev")
  tui_out="$(bash "$SCRIPTS_DIR/verify_superpowers_tui.sh" --alias "$id" --out "$tui_ev" --timeout 180 2>&1)"
  _redact "$tui_ev"
  case "$tui_out" in
    PASS:*) tui_label=verified;   _pass "layer-4 superpowers-TUI PASS for $id" ;;
    FAIL:*)
      tui_label=unverified
      # TWO DIFFERENT KINDS OF FAILURE, and only one of them is excusable by
      # provider status.
      #
      # An account-side failure (rejected key, no funds, exhausted quota) says
      # the PROVIDER cannot answer. `status` already records that independently,
      # so re-counting it would pin the run permanently red — the reasoning
      # behind gate_for_status.
      #
      # A route-attribution failure says something categorically different: the
      # turn was served by, or cannot be shown to have been served by, the
      # backend we are testing. That is OUR VERIFICATION MACHINERY EMITTING A
      # FALSE STATEMENT, and an unfunded key does not explain or excuse it — the
      # helixagent bluff was recorded against an alias whose own status was
      # never the problem. Evidence that lies is a failure at every status, so
      # this branch is deliberately NOT gated.
      #
      # 'launch-refused-route-integrity' joins it: that is rc 78 from
      # cma_run_provider — lib.sh REFUSING to launch because the ccr route could
      # not be applied, or because the alias' base_url is the gateway itself.
      # Nothing ran, so it is not a route ATTRIBUTION failure and never wears a
      # 'route-' marker (those are reserved for turns that actually ran), but it
      # is a toolkit/config-side condition rather than an account-side one, so
      # no key/quota/balance state excuses it. Un-gated for that reason.
      #
      # HONEST BOUNDARY on that rc-78 claim, corrected 2026-07-20. It is often
      # stated as "a genuine toolkit/config defect that no account state
      # explains". That is true of the whole set only in the sense that ACCOUNT
      # state never explains it — it is NOT true that every rc-78 is a defect.
      # There are two `return 78` sites in lib.sh, and the second is reachable
      # from five distinct conditions (lib.sh:1131-1192):
      #   * base_url IS the ccr gateway (self-reference)   — config defect;
      #   * the jq rewrite of config.json failed           — config defect;
      #   * jq is not on PATH                              — ENVIRONMENTAL;
      #   * `mv -f` failed: disk full / read-only / immutable — ENVIRONMENTAL;
      #   * `ccr restart` failed, incl. transient port contention — TRANSIENT.
      # So three of the five are environmental or transient rather than defects,
      # and the jq case is a real inconsistency with this script's own
      # conventions, where an absent binary is an honest SKIP
      # (verify_superpowers_tui.sh:123,126). Un-gating is still the right call —
      # every one of the five leaves the operator with an alias that cannot
      # launch, and none is excused by the provider's account — but the verdict
      # should be read as "this alias could not be launched for a
      # non-account reason", NOT as proof of a toolkit bug. Distinguishing the
      # environmental subset would require lib.sh to report WHICH condition
      # fired (it already composes that text in $_route_msg but folds it all
      # into rc 78); that is a lib.sh change and is deliberately not made here.
      #
      # 'launch-impossible-no-wrapper' (rc 96) and 'launch-refused-unclassified'
      # join for the same non-account reason. The first means the alias file
      # exists but defines no cma_run_provider — a broken installation in which
      # NO alias on the host can launch, so gating it behind provider status
      # would let a wholly broken install report green on any host whose
      # providers are not all 'verified'. The second means the driver's own
      # detection and verdict code sets have drifted apart.
      #
      # Deliberately NOT in this set: 'launch-refused-unverified' (rc 3). That
      # refusal IS the provider's account status being enforced, so it belongs
      # to the gated fallback below — counting it here would fail the suite once
      # per non-verified alias, forever.
      if grep -qE '^# FAIL: (route-|launch-refused-route-integrity|launch-refused-unclassified|launch-impossible-no-wrapper)' "$tui_ev" 2>/dev/null; then
        _fail "layer-4 route attribution (verification integrity)" \
          "live launch through '$id' produced NON-ATTRIBUTABLE evidence: $(grep -m1 -E '^# FAIL: (route-|launch-refused-route-integrity|launch-refused-unclassified|launch-impossible-no-wrapper)' "$tui_ev"). This is a verification-integrity failure, not an account-side one, so it counts at provider status=$status; evidence: $tui_ev"
      elif grep -qiE 'request \([0-9]+ tokens\) exceeds the available context size \([0-9]+ tokens\)|maximum context length is [0-9]+ tokens\. however, you requested (about )?[0-9]+ tokens' "$tui_ev" 2>/dev/null; then
        # CONTEXT-INADEQUATE — a THIRD kind of failure, and its own class.
        # Matches TWO known context-overflow phrasings (evidence-backed, both seen
        # live): the llama.cpp shape (local backends, e.g. helixagent's 3072-ctx
        # server) AND the OpenAI/OpenRouter shape (hosted models, e.g. openrouter's
        # nemotron whose 262144 window is under Claude Code's ~292k tool-heavy
        # request). Both are provider-side context overflows on a route-attributable
        # turn; neither is a toolkit routing bug. The number order DIFFERS between
        # the two phrasings — see the per-phrasing extraction below.
        #
        # The turn WAS served by the right backend (the route-attribution gate
        # above already passed, or this is a native alias), the key WAS accepted,
        # and the account is NOT the problem — yet the backend returned a hard 400
        # because its own context window is smaller than Claude Code's
        # tool/skill-heavy request. That is provider-side in the same family as
        # account-dead: for a LOCAL backend the operator relaunches it larger (as
        # an unfunded key must be topped up); for a HOSTED model the operator pins
        # a larger-context model. (One toolkit lever can sometimes help the hosted
        # case — the output-reservation guard over-reserving against a big tool
        # input; tuning that input floor is a tracked follow-up — but as launched
        # the alias does not answer.)
        #
        # Why gate_for_status does NOT already cover it. `status` is set by the
        # layers-1/2 probes, which send a ~512-token sentinel/tool request — far
        # under any real context — so a backend launched too small still reaches
        # status=verified there and is (correctly) gated. The overflow is only
        # observable on the large layer-4 request, so WITHOUT this branch a
        # genuinely-verified alias whose backend is merely under-provisioned is
        # counted as fresh breakage on every run, pinning the suite red for a
        # condition the toolkit cannot fix — the same signal-destroying outcome
        # gate_for_status exists to prevent for account-dead providers.
        #
        # EVIDENCE-BASED, never the pin. The two numbers come from the backend's
        # own 400 (request N tokens vs. available M tokens), read out of the live
        # transcript — NOT from any declared/pinned context (the pin may say 24576
        # while the server is really 3072). So the class fires only when a real
        # request really overflowed a real window, which is why it cannot
        # false-positive a provider that genuinely answers layer-4: a PASS never
        # reaches this FAIL branch, a 401/402/403 carries no such text and stays
        # account-side, and a non-context 400/500/timeout carries no such text and
        # still counts under the gated fallback below.
        #
        # DURABLE by construction. There is no status to persist and so none for a
        # plain re-sync to overwrite: the verdict is re-derived from the live
        # layer-4 error on every proof run, so a re-sync that re-verifies the small
        # layers-1/2 probes cannot silently flip this back to a counted-verified
        # failure. (What it does NOT do on its own: change what `claude-providers
        # list` shows or what the launch gate permits — those read status.json and
        # still see 'verified'. The real fix is the operator relaunching the
        # backend bigger; a pin/context change is a separate, flagged decision.)
        # TWO phrasings with the request/window numbers in REVERSED order —
        # extract per-phrasing so the marker never swaps them:
        #   llama.cpp:  "request (REQ tokens) exceeds the available context size
        #     (WIN tokens)"                             -> REQ first, WIN second.
        #   OpenAI/OpenRouter: "maximum context length is WIN tokens. However, you
        #     requested about REQ tokens"               -> WIN first, REQ second.
        #   The "about" is OPTIONAL (nvidia/mistral-small live 400, 2026-07-26:
        #     "maximum context length is 32768 tokens. However, you requested
        #      113865 tokens (48329 in the messages, 65536 in the completion)")
        #   — and the match must END at the request total, or the tail-number
        #   extraction below would grab the parenthesised completion budget
        #   (65536) instead of the request (113865).
        _ci_msg="$(grep -oiE 'request \([0-9]+ tokens\) exceeds the available context size \([0-9]+ tokens\)' "$tui_ev" | head -n1)"
        if [[ -n "$_ci_msg" ]]; then
          _ci_req="$(printf '%s' "$_ci_msg" | grep -oE '[0-9]+' | head -n1)"
          _ci_win="$(printf '%s' "$_ci_msg" | grep -oE '[0-9]+' | tail -n1)"
        else
          _ci_msg="$(grep -oiE 'maximum context length is [0-9]+ tokens\. however, you requested (about )?[0-9]+ tokens' "$tui_ev" | head -n1)"
          _ci_win="$(printf '%s' "$_ci_msg" | grep -oE '[0-9]+' | head -n1)"
          _ci_req="$(printf '%s' "$_ci_msg" | grep -oE '[0-9]+' | tail -n1)"
        fi
        printf '# FAIL: context-inadequate (backend %s tokens < request %s)\n' "${_ci_win:-unknown}" "${_ci_req:-unknown}" >> "$tui_ev"
        echo "KNOWN-NON-WORKING: layer-4 context-inadequate for '$id' (backend context ${_ci_win:-unknown} tokens < Claude Code request ${_ci_req:-unknown} tokens — provider-side: pin a larger-context model for this provider, or relaunch a local backing server with a larger context window). Not counted as a suite failure; evidence: $tui_ev"
      elif grep -qE '"api_error_status": *40[23][,}]|API Error: 40[23] ' "$tui_ev" 2>/dev/null; then
        # ACCOUNT-SIDE (billing/access) — a FOURTH KNOWN-NON-WORKING class, the
        # billing analogue of context-inadequate. A 402 (Payment Required /
        # "Insufficient balance") or 403 (key rejected / account suspended / no
        # model access) on a route-attributable turn is DEFINITIVELY provider-
        # account-side: the toolkit cannot cause a 402/403 — those come from the
        # provider's billing/authz, never from how a request was formed (a
        # malformed request is a 400, which stays counted below). Without this
        # branch a provider that was funded at layers-1/2 sync time but whose
        # balance depletes before the large layer-4 turn is counted as fresh
        # toolkit breakage on EVERY proof run — the exact signal-destroying
        # outcome gate_for_status and the context-inadequate class exist to
        # prevent. It fires REGARDLESS of the cached 'verified' status, because
        # that status was set by the ~512-token layers-1/2 probe BEFORE the
        # balance ran out (the small probe passes on the last cents). Evidence-
        # based (the live 402/403), durable (re-derived from the live layer-4
        # error every run — no status for a re-sync to overwrite), and it cannot
        # false-positive a paying account: a PASS never reaches this FAIL branch,
        # and a non-billing 400/500/timeout carries no 402/403 and still counts.
        # Observed live (inference/glm-5.2): "402 Insufficient balance for
        # request" on a correctly-routed turn.
        _as_code="$(grep -oE '"api_error_status": *40[23]|API Error: 40[23]' "$tui_ev" | grep -oE '40[23]' | head -n1)"
        printf '# FAIL: account-side (HTTP %s — provider billing/access, not toolkit)\n' "${_as_code:-402/403}" >> "$tui_ev"
        echo "KNOWN-NON-WORKING: layer-4 account-side for '$id' (HTTP ${_as_code:-402/403} — the provider account cannot be billed/served: insufficient balance, rejected key, or suspended access. Top up or re-key the account. Not counted as a suite failure; evidence: $tui_ev)"
      elif grep -qiE 'Function name was .+ but must be' "$tui_ev" 2>/dev/null; then
        # ENVIRONMENT-INCOMPATIBLE — a FIFTH KNOWN-NON-WORKING class. The
        # provider's own 400 rejects a tool/function NAME from the operator's
        # MCP environment (e.g. live on nvidia4/mistral-small: "Function name
        # was mcp__plugin_aws-startup-advisor_awsknowledge__aws___get_regional_
        # availability but must be a-z, A-Z, 0-9, or contain underscores and
        # dashes, with a maximum length of 64"). The name is generated by the
        # MCP server/plugin ecosystem and advertised verbatim by Claude Code;
        # the toolkit neither mints nor (today) rewrites it, so this is NOT a
        # routing/attribution defect — the strict provider simply cannot serve
        # THIS host's MCP-loaded sessions, while the same alias passes the
        # small layers-1/2 probes (hence status=verified). Without this branch
        # every strict provider pins the suite red on every run for a condition
        # no toolkit change in scope can fix — the signal-destroying outcome
        # the other classes exist to prevent. Evidence-based (the provider's
        # own grammar-rejection text), durable (re-derived every run), and it
        # cannot false-positive: a PASS never reaches this FAIL branch, and
        # other 400s (context → context-inadequate above; anything else) stay
        # counted. The real fix, when wanted, is a ccr/cma-proxy transform
        # that sanitizes advertised tool names for strict backends — tracked
        # as follow-up, not silent behavior.
        _ei_fn="$(grep -oiE 'Function name was [^ ]+ but must be' "$tui_ev" | head -n1 | sed 's/Function name was //; s/ but must be//')"
        printf '# FAIL: environment-incompatible (provider rejects MCP tool name %s — strict function-name grammar)\n' "${_ei_fn:-unknown}" >> "$tui_ev"
        echo "KNOWN-NON-WORKING: layer-4 environment-incompatible for '$id' (the provider's function-name grammar rejects an MCP tool name from this host's plugin environment — not a routing defect; a name-sanitizing transform is the tracked fix). Not counted as a suite failure; evidence: $tui_ev)"
      elif (( gated )); then
        _fail "layer-4 superpowers-TUI" "live launch through '$id' FAILED (${tui_out}); evidence: $tui_ev"
      else
        # REPORT THE OBSERVED CLASSIFICATION, NEVER ASSERT A CAUSE (2026-07-27
        # audit). This is the catch-all reached only after the FOUR
        # evidence-based classifiers above (route attribution, backend context
        # inadequacy, billing 402/403, strict function-name grammar) each
        # declined — so by construction the failure here is NOT one they
        # recognised. It fires for
        # '# FAIL: timeout', 'stream-aborted', 'no-engagement', 'empty-result',
        # 'api-error' and 'launch-refused-unverified', none of which implies an
        # account state; the genuinely account-shaped case (402/403) was already
        # taken by its own branch above. Worse, status=unverified means
        # INCONCLUSIVE rather than rejected (providers-verify.sh emits it for
        # HTTP 429, non-4xx codes, and a missing verifier binary), so the old
        # text asserted a billing fact about accounts nothing had measured.
        # Live: 42-live-providers.log claimed account-side for 'chutes5' while
        # providers-chutes5-superpowers.txt records
        # '# FAIL: launch-refused-unverified (rc=3 … NO turn ran)' — the launch
        # was refused locally and nothing was ever sent to that account.
        #
        # `status` still decides whether this COUNTS (that is gate_for_status,
        # unchanged and still the reason this is not a suite failure); it just
        # no longer masquerades as the diagnosis. $tui_out is the driver's own
        # verdict line and $tui_ev holds its durable '# FAIL: <class>' marker.
        echo "KNOWN-NON-WORKING: layer-4 for '$id' — ${tui_out} (provider status=$status, so not counted as a suite failure); evidence: $tui_ev"
      fi ;;
    *)      tui_label=skip;       echo "SKIP: ${tui_out:-layer-4 preconditions absent for $id}" ;;
  esac

  # aggregate (real semantic shape: no fixture_hash)
  tmp="$(mktemp "${TMPDIR:-/tmp}/cma-sum.XXXXXX")"
  jq --arg id "$id" --arg st "$status" --argjson ex "$([[ $exists == 1 ]] && echo true || echo false)" \
     --arg sem "${sem:-skip}" --arg tui "$tui_label" \
     --arg semev "$sem_ev" --arg tuiev "$tui_ev" \
     '.[$id] = {status:$st,
                 layers:{existence:$ex, semantic:$sem, superpowers_tui:$tui},
                 evidence:{semantic:$semev, superpowers_tui:$tuiev}}' \
     "$SUMMARY" > "$tmp" && mv "$tmp" "$SUMMARY"
done
echo "aggregate: $SUMMARY" >> "$EV"

it "proof sweep: no layer-4 evidence file from THIS run carries a '# FAIL:' marker"
# Defense in depth, independent of the stdout classification above: re-read the
# markers the driver itself wrote to disk. Scoped to $RUN_TUI_EV — $PROOF_DIR
# also holds artifacts from earlier runs and from aliases no longer installed,
# and those are not this run's verdict to report.
# Only the LAST marker line counts: verify_superpowers_tui.sh truncates the
# evidence file on a real launch, but on a precondition SKIP it merely APPENDS
# '# SKIP' — so an older '# FAIL:' can still sit above a current '# SKIP'.
marked=()
for ev in ${RUN_TUI_EV+"${RUN_TUI_EV[@]}"}; do
  [[ -f "$ev" ]] || continue
  last="$(grep -E '^# (PASS|FAIL:|SKIP)' "$ev" 2>/dev/null | tail -n 1)"
  case "$last" in
    # context-inadequate is a provider-side backend-size limit (the backend's
    # own context window is smaller than Claude Code's minimum request), reported
    # KNOWN-NON-WORKING on its own line by the per-provider classifier above —
    # exactly like an account-dead FAIL. It is not a suite failure and is not
    # swept here, even though the alias reached status=verified on the small
    # layers-1/2 probes (the overflow is only observable on the large layer-4
    # request). The marker is retained in the evidence, on its face, so the
    # operator can see WHY: the backing server must be relaunched larger.
    '# FAIL: context-inadequate'*) : ;;
    # account-side is the billing analogue: a 402/403 (insufficient balance /
    # rejected key / suspended access) on a route-attributable turn is provider-
    # account-side, never toolkit — reported KNOWN-NON-WORKING by the per-provider
    # classifier above and retained on its face so the operator sees WHY (top up
    # or re-key the account). Not this run's suite failure.
    '# FAIL: account-side'*) : ;;
    # environment-incompatible is the tool-grammar analogue: the provider's own
    # 400 rejects an MCP tool NAME from the host's plugin environment (strict
    # function-name grammar), which the toolkit neither mints nor rewrites —
    # reported KNOWN-NON-WORKING by the per-provider classifier above and
    # retained on its face so the operator sees WHY. Not this run's suite
    # failure.
    '# FAIL: environment-incompatible'*) : ;;
    '# FAIL:'*) marked+=("$(basename "$ev") -> $last") ;;
  esac
done
if (( ${#marked[@]} == 0 )); then
  _pass "no '# FAIL:' marker in ${#RUN_TUI_EV[@]} layer-4 evidence file(s) from this run"
else
  _fail "layer-4 evidence carries '# FAIL:' markers" "${#marked[@]} of ${#RUN_TUI_EV[@]}: $(printf '%s; ' "${marked[@]}")"
fi

it "route-attribution sweep: NO layer-4 evidence file from this run is non-attributable (status-independent)"
# Deliberately swept over ALL_TUI_EV, not RUN_TUI_EV: the gate above is scoped
# to providers whose account is known-good, because an account-dead provider's
# FAIL is expected noise. A route-* marker is never that kind of noise — it
# means the evidence names, or cannot name, the backend that served the turn.
# Scoping THAT to `verified` providers would reproduce the original bluff on
# every non-verified alias, which is where it was found in the first place.
#
# The set swept here MUST match the un-gated set of the per-provider classifier
# above, and for the same reason: route-* (a turn that ran but is not
# attributable) plus the three non-account launch failures —
# launch-refused-route-integrity (rc 78 — lib.sh refused because the route could
# not be applied; see the honest boundary on that claim at the classifier),
# launch-impossible-no-wrapper (rc 96 — the alias file defines no
# cma_run_provider, so NO alias on this host can launch) and
# launch-refused-unclassified (the driver's detection and verdict code sets have
# drifted). It must NOT include launch-refused-unverified (rc 3): that refusal is
# the provider's own account status being enforced, nothing ran, no false
# statement was made, and sweeping it here status-independently would pin the run
# red on every non-verified alias — which is precisely the regression this sweep
# was almost the vehicle for.
route_marked=()
for ev in ${ALL_TUI_EV+"${ALL_TUI_EV[@]}"}; do
  [[ -f "$ev" ]] || continue
  last="$(grep -E '^# (PASS|FAIL:|SKIP)' "$ev" 2>/dev/null | tail -n 1)"
  case "$last" in
    '# FAIL: route-'*|'# FAIL: launch-refused-route-integrity'*|\
    '# FAIL: launch-refused-unclassified'*|'# FAIL: launch-impossible-no-wrapper'*)
      route_marked+=("$(basename "$ev") -> $last") ;;
  esac
done
if (( ${#route_marked[@]} == 0 )); then
  _pass "all ${#ALL_TUI_EV[@]} layer-4 evidence file(s) from this run are route-attributable"
else
  _fail "layer-4 evidence is NON-ATTRIBUTABLE (verification integrity)" \
    "${#route_marked[@]} of ${#ALL_TUI_EV[@]}: $(printf '%s; ' "${route_marked[@]}")"
fi

it "layer-4 classifier honesty: a neutral, non-superpowers response must NOT verify (negative-case, Task-3 review)"
CB="${CLAUDE_BIN:-$(command -v claude || true)}"
if [[ -n "$first_id" && -n "$CB" && "$CB" != "/usr/bin/true" && "$(basename "$CB")" == claude* && -f "$ALIASES" ]]; then
  # Mirrors verify_superpowers_tui.sh's SCRUB + throwaway-cwd launch, but uses
  # --force (the documented operator override, lib.sh) to bypass the
  # not-yet-verified activation gate: the point here is validating the
  # ENGAGEMENT-MARKER REGEX itself never false-matches on ordinary model
  # output, independent of any one alias's current verified/pending status.
  # -u BASH_ENV is LOAD-BEARING here for the same reason as in
  # verify_superpowers_tui.sh, and its absence was a real hole (found
  # 2026-07-20): this launch has the identical shape — a non-interactive
  # `bash -c` that sources "$ALIASES" explicitly — and a non-interactive bash
  # sources $BASH_ENV FIRST. On this host BASH_ENV points at the operator's
  # ~/.bashrc, which transitively sources the managed alias file, so with a
  # broken/empty/stale "$ALIASES" this check received a WORKING cma_run_provider
  # from somewhere else entirely and _pass'ed "classifier honesty" having
  # measured the host's real installation rather than the file it names.
  NEG_SCRUB=(env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_ENTRYPOINT \
             -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_EXECPATH -u CLAUDE_EFFORT \
             -u CLAUDE_CONFIG_DIR -u ANTHROPIC_MODEL -u ANTHROPIC_BASE_URL \
             -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u BASH_ENV)
  neg_ev="$PROOF_DIR/providers-negative-case-superpowers.txt"
  neg_tmpd="$(mktemp -d "${TMPDIR:-/tmp}/cma-neg.XXXXXX")"
  neg_out="$( timeout 60 "${NEG_SCRUB[@]}" bash -c '
      cd "'"$neg_tmpd"'" || exit 97
      [[ -f "'"$KEYS_FILE"'" ]] && { set -a +u; . "'"$KEYS_FILE"'"; set +a; }
      source "'"$ALIASES"'" >/dev/null 2>&1
      cma_run_provider --force "'"$first_id"'" \
        -p "Reply with exactly the single word DONE and nothing else. Do not use any tool, plugin, or skill." \
        --output-format json 2>&1
    ' )"
  neg_rc=$?
  rmdir "$neg_tmpd" 2>/dev/null || true
  printf '%s\n' "$neg_out" > "$neg_ev"
  _redact "$neg_ev"
  if (( neg_rc == 124 )); then
    echo "SKIP: negative-case launch via '$first_id' timed out (network/precondition absent) — not a classifier finding" >> "$EV"
  elif printf '%s' "$neg_out" | grep -qiE 'superpowers:[a-z0-9_-]+'; then
    _fail "layer-4 classifier honesty" "engagement marker matched on a NEUTRAL prompt via '$first_id' — false-PASS risk (evidence: $neg_ev)"
  else
    _pass "layer-4 classifier honesty: neutral prompt via '$first_id' correctly did NOT match the engagement marker"
  fi
else
  echo "SKIP: negative-case honesty check — no real claude binary / alias file available"
fi

echo "evidence: $EV"
summary
