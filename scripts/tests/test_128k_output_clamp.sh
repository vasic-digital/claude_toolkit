#!/usr/bin/env bash
# test_128k_output_clamp.sh — permanent regression guard (§11.4.135) for the
# 128000 output-token clamp + native token-guard isolation.
#
# Background (§11.4.102/§11.4.108 remediation). Claude Code fatally aborts any
# length-truncated response with "…exceeded the 128000 output token maximum…
# set CLAUDE_CODE_MAX_OUTPUT_TOKENS". The literal 128000 originates in this
# toolkit: cma_run_provider used to re-export the model's THEORETICAL
# limit.output (deepseek 384000, xiaomi 131072) as CLAUDE_CODE_MAX_OUTPUT_TOKENS
# on the native transport ONLY; the CLI hard-caps unknown/custom models to
# 128000, requests 128000, and echoes it in the fatal.
#
# Two-part fix, both proven here (merged with main's v1.16.0 _cma_out_guard —
# the union keeps BOTH sides' live-proven behaviors):
#   (A) CAP for BOTH transports (router AND native), exported ONCE before the
#       transport branch, with the MERGED decision table:
#         - real budget (output < context, or context unknown): export
#           min(CMA_PROVIDER_MAX_OUTPUT, 128000) — the clamp (this file's
#           original live-proven fix for the deepseek-384000/xiaomi-131072
#           ">128000" fatal);
#         - catalog mislabel (output >= context — main's live-proven nvidia5
#           400-overshoot case): NO export (the CLI's adaptive default is the
#           only safe choice);
#         - missing / non-numeric / zero budget: NO export (the CLI's own
#           unknown-model default, 128000, applies — effect-equivalent to the
#           pre-merge always-export-128000 default, but also safe for
#           small-context catalog-gap models).
#   (B) ISOLATION: cma_run (the native claudeN launcher) MUST unset
#       CLAUDE_CODE_MAX_OUTPUT_TOKENS + CLAUDE_CODE_AUTO_COMPACT_WINDOW, which
#       cma_run_provider exports for provider aliases and which PERSIST into
#       a subsequent native launch (wrongly capping native output / early
#       compacting native context).
#
# §11.4.108 DELIVERY seam: both wrappers are TEMPLATES written into the user's
# installed aliases.sh; a change reaches the deployed artifact ONLY when each
# per-function migration guard's marker set forces a re-emit. This test proves,
# on the artifact cma_ensure_alias_file actually emits, that:
#   (a) configured > 128000 (real budget) -> exported 128000 (clamp) [arithmetic]
#   (b) configured < 128000 (real budget) -> exported unchanged      [arithmetic]
#   (c) missing/non-numeric  -> NO export (UNSET)                   [arithmetic]
#   (c') huge all-digit (>2^63-1), no ctx -> 128000, never leaked
#        unclamped; with a known ctx it is the mislabel shape -> UNSET [arithmetic]
#   (c'') floor: 0/00 -> UNSET; leading zeros decimal, not octal    [arithmetic]
#   (c''') mislabel (output >= context) -> NO export (nvidia5)      [arithmetic]
#   (d) the clamp export is present for BOTH transports; the RAW unclamped
#       export is GONE                                              [static]
#   (e) cma_run's isolation unset clears BOTH token guards          [static+sink]
#   (f) the migration seam RE-DEPLOYS the clamp + isolation when a pre-fix
#       (marker-less) body lacks them — RED-polarity per §11.4.115.
#
# §1.1 load-bearing: reverting fix (A) (clamp block / provider guard marker)
# breaks (a)-(d)+(f); reverting fix (B) (cma_run unset / cma_run guard marker)
# breaks (e)+(f).
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
# lib.sh enables `set -e`; the harness asserts on non-zero exits, so relax it.
set +e

# Extract a single wrapper body from the emitted alias file, using the same
# literal-parens anchors the migration guards use (cma_run_provider( never
# collides with cma_run().
prov_body() { awk '/^cma_run_provider\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE"; }
run_body()  { awk '/^cma_run\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE"; }

# Extract the DEPLOYED clamp block (literal-substring anchors — no regex
# escaping) into a probe function, then evaluate the ACTUAL emitted clamp code
# with a given CMA_PROVIDER_MAX_OUTPUT. This is a real §11.4.108 runtime
# signature on the artifact, not a re-implemented copy.
clamp_eval() {
  # $1: 'unset' (missing input) or 'val'; $2: the CMA_PROVIDER_MAX_OUTPUT value;
  # $3 (optional): CMA_PROVIDER_CONTEXT_LIMIT (unset when omitted — the merged
  # guard skips the export when output >= context, so ctx-aware cases need it).
  # Prints the exported cap, or the literal UNSET when the guard did not export.
  local input_present="$1" input_val="${2:-}" ctx_val="${3:-}" probe out
  probe="$(mktemp "${TMPDIR:-/tmp}/clamp-probe.XXXXXX.sh")"
  {
    echo 'clamp_probe() {'
    # The merged block ends with the conditional export:
    #   if [ -n "$_cma_out" ]; then export ...="$_cma_out"; fi
    # so extraction must run THROUGH the closing fi (exiting on the export
    # line would emit an unterminated 'if').
    prov_body | awk '
      index($0,"local _cma_out=\"${CMA_PROVIDER_MAX_OUTPUT"){f=1}
      f{print}
      f && seen && $0 ~ /^[[:space:]]*fi$/ {exit}
      f && index($0,"export CLAUDE_CODE_MAX_OUTPUT_TOKENS=\"$_cma_out\""){seen=1}
    '
    echo '  printf "%s" "${CLAUDE_CODE_MAX_OUTPUT_TOKENS-UNSET}"'
    echo '}'
  } > "$probe"
  local -a envp=()
  [[ -n "$ctx_val" ]] && envp+=("CMA_PROVIDER_CONTEXT_LIMIT=$ctx_val")
  if [[ "$input_present" == "unset" ]]; then
    # Truly-unset CMA_PROVIDER_MAX_OUTPUT (env -u), the "missing" case.
    # Also unset CLAUDE_CODE_MAX_OUTPUT_TOKENS: the Claude Code harness exports
    # this as 128000, which leaks into child processes and makes the probe's
    # ${CLAUDE_CODE_MAX_OUTPUT_TOKENS-UNSET} read 128000 instead of UNSET even
    # when the clamp correctly decides not to export.
    out="$(env -u CMA_PROVIDER_MAX_OUTPUT -u CMA_PROVIDER_CONTEXT_LIMIT -u CLAUDE_CODE_MAX_OUTPUT_TOKENS ${envp[@]+"${envp[@]}"} bash -c 'source "$1"; clamp_probe' _ "$probe")"
  else
    out="$(env -u CMA_PROVIDER_CONTEXT_LIMIT -u CLAUDE_CODE_MAX_OUTPUT_TOKENS ${envp[@]+"${envp[@]}"} "CMA_PROVIDER_MAX_OUTPUT=$input_val" bash -c 'source "$1"; clamp_probe' _ "$probe")"
  fi
  rm -f "$probe"
  printf '%s' "$out"
}

# --- fresh install -----------------------------------------------------------
it "cma_ensure_alias_file emits an alias file with both wrappers"
cma_ensure_alias_file
assert_file "$ALIAS_FILE" "alias file created"
# Control needle (§11.4.201): the extractor CAN see a known-present string in
# each body, so a later ZERO count is a real absence, not a blind probe.
assert_eq 1 "$(prov_body | grep -cF 'unset ANTHROPIC_BASE_URL')" "control needle: prov_body extractor is not blind"
assert_eq 1 "$(run_body  | grep -cF 'unset ANTHROPIC_BASE_URL')" "control needle: run_body extractor is not blind"

# --- (a)/(b)/(c) clamp arithmetic on the DEPLOYED clamp block ----------------
it "clamp: configured > 128000 -> 128000 (deepseek 384000, xiaomi 131072)"
assert_eq 128000 "$(clamp_eval val 384000)" "384000 clamps to 128000"
assert_eq 128000 "$(clamp_eval val 131072)" "131072 clamps to 128000"

it "clamp: configured <= 128000 -> unchanged"
assert_eq 8192   "$(clamp_eval val 8192)"   "8192 unchanged (github-models/upstage)"
assert_eq 127999 "$(clamp_eval val 127999)" "127999 unchanged (off-by-one below cap)"
assert_eq 128000 "$(clamp_eval val 128000)" "128000 unchanged (exactly the cap)"

it "no-budget: missing/non-numeric -> NO export (CLI's own unknown-model default applies)"
# Merged semantics (v1.16.0 _cma_out_guard union): an unknown budget is NOT
# exported — effect-equivalent to the pre-merge 128000 default for unknown
# models, and additionally safe for small-context catalog-gap models (the
# nvidia5-class overshoot an unconditional 128000 export could resurrect).
assert_eq UNSET "$(clamp_eval val '')"    "empty -> no export"
assert_eq UNSET "$(clamp_eval unset)"     "unset  -> no export"
assert_eq UNSET "$(clamp_eval val abc)"   "non-numeric -> no export"
assert_eq UNSET "$(clamp_eval val 12x8)"  "partly-numeric -> no export"

# --- (c') huge all-digit value -> never leaked unclamped ---------------------
# A user-settable CMA_HELIXAGENT_MAX_OUTPUT flows verbatim through 'jq --argjson'
# into CMA_PROVIDER_MAX_OUTPUT. A value past the shell integer max (2^63-1, 19
# digits) would make '[ N -gt 128000 ]' error and, via the failed '&&', leak the
# raw value UNCLAMPED — resurrecting the ">128000" fatal. The length-guard must
# collapse any >18-digit value WITHOUT arithmetic: with no usable context ->
# the 128000 cap; with a known context (every real context is <=18 digits, so
# the huge value >= it) -> the mislabel shape -> no export.
it "clamp: huge all-digit value (>2^63-1) -> 128000 (no ctx) / UNSET (ctx known), never unclamped (F2)"
assert_eq 128000 "$(clamp_eval val 99999999999999999999999)" "23-digit, no ctx -> 128000 (no overflow leak)"
assert_eq 128000 "$(clamp_eval val 9223372036854775808)"     "2^63 (19-digit), no ctx -> 128000"
# v1.24.0: with a known context the huge value is still discarded without
# arithmetic, but the guard no longer leaves the cap UNSET — see the mislabel
# block below for why "no export" was never the safe outcome. 262144 - the
# 160000 input floor = 102144.
assert_eq 102144 "$(clamp_eval val 99999999999999999999999 262144)" "23-digit with known ctx -> discarded, cap carved from the context"
assert_eq 128000 "$(clamp_eval val 1000000)"                 "7-digit 1,000,000, no ctx -> 128000"
assert_eq 128000 "$(clamp_eval val 999999)"                  "6-digit 999,999 (> cap), no ctx -> 128000"

# --- (c'') floor at 1; leading zeros are decimal, not octal ------------------
# 0 must NEVER export CLAUDE_CODE_MAX_OUTPUT_TOKENS=0 (a zero cap): a zero
# budget is a degenerate catalog value = no real info -> merged semantics
# treat it like the missing case (NO export). Leading-zero forms are decimal:
# a small one (007) tests as decimal 7 and exports "007", which Claude Code
# parses as decimal 7 (min-semantics decision); 0128001 tests as 128001 ->
# clamped (never re-read as octal).
it "clamp: floor 0/00 -> no export; leading zeros not octal (F3)"
assert_eq UNSET  "$(clamp_eval val 0)"       "0 -> no export (never a zero cap)"
assert_eq UNSET  "$(clamp_eval val 00)"      "00 -> no export"
assert_eq 128000 "$(clamp_eval val 0128001)" "leading-zero 0128001 tests as 128001 -> clamped 128000 (not octal)"
assert_eq 007    "$(clamp_eval val 007)"     "leading-zero small stays decimal-7 (exports 007 -> parsed as 7)"

# --- (c''') catalog mislabel: output >= context -> DISCARD, then carve -------
# Main's v1.16.0 live-proven case: when limit.output >= limit.context the
# "output" number is really the context size; exporting it (or any clamp of it)
# makes Claude Code request that many completion tokens and input+request
# overshoots the shared window (400). Discarding it is still correct.
#
# v1.24.0 changes what happens NEXT. "Discard and export nothing" looked
# honest but was not safe: Claude Code's own default for a model it does not
# know is 128000, so declining to export IS a request for 128000 output
# tokens. kilo's catalog row is exactly this shape (ctx == out == 262144) —
# the mislabel branch blanked the value, the CLI reserved its 128000 default
# against a 262144 window that must also carry Claude Code's ~137K
# system-prompt + tool-schema floor, and 137483 + 128000 = 265483 overflows.
# So once the bogus value is discarded the cap is CARVED OUT of the context
# instead: clamp(context - 160000 input floor, 8192, 128000).
it "mislabel: output >= context -> discarded, cap carved from the context (nvidia5/kilo)"
assert_eq 8192   "$(clamp_eval val 131072 131072)"  "output == context -> bogus value discarded, floored cap (nvidia5 400 case)"
# SCOPE NOTE (a5e396d): clamp_eval evaluates the CLAMP STAGE only — its awk
# extractor stops at the FIRST `export CLAUDE_CODE_MAX_OUTPUT_TOKENS`, so these
# numbers are the carve's output, NOT necessarily the value the launch finally
# exports. Since the compression-loop guard, a large context is rebalanced
# downward afterwards (262144 -> 62144) to keep a viable auto-compact window.
# That end-to-end value is asserted in test_output_tokens.sh; what is pinned
# here is the carve arithmetic feeding it.
assert_eq 8192   "$(clamp_eval val 262144 131072)"  "output > context -> bogus value discarded, floored cap"
assert_eq 102144 "$(clamp_eval val 262144 262144)"  "kilo's ctx==out==262144 -> carve stage 102144, never the 128000 that overflowed"
assert_eq 8192   "$(clamp_eval val 8192 32768)"     "real small budget < context -> verbatim"
assert_eq 128000 "$(clamp_eval val 384000 1048576)" "deepseek 384000 < ctx 1M -> clamped 128000 (not raw)"

# --- (d) clamp export present for BOTH transports; RAW export GONE ------------
# TWO export sites since a5e396d (2026-07-27), not one. The first is the carve
# (context - input floor, clamped to the CLI's 128000); the second is the
# compression-loop guard re-exporting a LOWERED cap when the co-derived window
# would fall under CMA_MIN_COMPACT_WINDOW. Both write the same literal
# `export CLAUDE_CODE_MAX_OUTPUT_TOKENS="$_cma_out"`, so the structural count is
# 2. Asserting an exact count (rather than >=1) is deliberate: it is what would
# catch a THIRD, unreviewed export site appearing in the guard block.
it "cma_run_provider exports the CLAMPED cap (BOTH transports), never the raw value"
assert_eq 2 "$(prov_body | grep -cF 'export CLAUDE_CODE_MAX_OUTPUT_TOKENS="$_cma_out"')" "clamped export present at both the carve and rebalance sites"
# Two comparisons since v1.24.0: the CLI ceiling bounds the carve-out when the
# context is known ($_cma_cap), and still clamps the raw value when it is not.
assert_eq 2 "$(prov_body | grep -cF -- '-gt 128000')" "clamp comparison present on both the carve-out and no-context paths"
assert_eq 0 "$(prov_body | grep -cF 'export CLAUDE_CODE_MAX_OUTPUT_TOKENS="$CMA_PROVIDER_MAX_OUTPUT"')" "raw unclamped export removed"

# --- (e) cma_run isolation unset present -------------------------------------
it "cma_run (native) unset list clears BOTH token guards"
assert_eq 1 "$(run_body | grep -cF 'unset CLAUDE_CODE_MAX_OUTPUT_TOKENS CLAUDE_CODE_AUTO_COMPACT_WINDOW')" "native token-guard unset line"

# --- (f) migration guard RE-DEPLOYS clamp + isolation (RED-polarity §11.4.115) -
# Simulate an OLDER installed body predating the clamp/isolation: strip every
# line carrying the CLAUDE_CODE_MAX_OUTPUT_TOKENS marker from BOTH bodies
# (removes each guard's re-emit marker).
it "RED: a pre-fix body (marker stripped) lacks the clamp export AND the isolation unset"
_tmp="$(mktemp "${TMPDIR:-/tmp}/cma-red.XXXXXX")"
grep -v 'CLAUDE_CODE_MAX_OUTPUT_TOKENS' "$ALIAS_FILE" > "$_tmp" && mv "$_tmp" "$ALIAS_FILE"
assert_eq 0 "$(prov_body | grep -cF 'export CLAUDE_CODE_MAX_OUTPUT_TOKENS="$_cma_out"')" "defect reproduced: clamp export absent"
assert_eq 0 "$(run_body  | grep -cF 'unset CLAUDE_CODE_MAX_OUTPUT_TOKENS CLAUDE_CODE_AUTO_COMPACT_WINDOW')" "defect reproduced: isolation unset absent"

it "GREEN: the migration seam re-emits the clamp + isolation on the next ensure"
cma_ensure_alias_file
assert_eq 2 "$(prov_body | grep -cF 'export CLAUDE_CODE_MAX_OUTPUT_TOKENS="$_cma_out"')" "clamp export restored (both sites)"
assert_eq 1 "$(run_body  | grep -cF 'unset CLAUDE_CODE_MAX_OUTPUT_TOKENS CLAUDE_CODE_AUTO_COMPACT_WINDOW')" "isolation unset restored"
assert_eq 128000 "$(clamp_eval val 384000)" "clamp arithmetic still 384000->128000 after re-emit"
assert_eq 8192   "$(clamp_eval val 8192)"   "clamp arithmetic still 8192->unchanged after re-emit"

# --- (e-sink) native cma_run clears the leaked token guards from the child ----
# Strongest §11.4.69 signature: what the launched `claude` child actually
# inherits. A stub records the two guard vars; cma_run must have cleared both
# (they were exported as a "leak" before the call, exactly as a prior
# cma_run_provider would leave them).
it "native cma_run clears leaked token guards from the launched child (sink-side)"
_stub="$SANDBOX_HOME/claude_stub"
_child="$SANDBOX_HOME/child_token_env.txt"
{
  printf '#!/usr/bin/env bash\n'
  printf 'for v in CLAUDE_CODE_MAX_OUTPUT_TOKENS CLAUDE_CODE_AUTO_COMPACT_WINDOW; do\n'
  printf '  if [ -n "${!v+x}" ]; then echo "$v=SET"; else echo "$v=UNSET"; fi\n'
  printf 'done > "$TOK_OUT"\nexit 0\n'
} > "$_stub"
chmod +x "$_stub"
: > "$_child"
# PROVENANCE GATE — see lib/assert.sh:assert_fn_from. The launch below sources
# $ALIAS_FILE INSIDE the subshell, so the check uses the --source form: it
# re-does the source in its own subshell but asserts here, where the counters
# survive. Without it a failed source would leave the subshell running the
# HOST's cma_run (already defined via BASH_ENV) and the isolation assertions
# would pass on host code.
assert_fn_from --source "$ALIAS_FILE" cma_run "cma_run under test comes from the sandbox alias file"
(
  # shellcheck disable=SC1090
  source "$ALIAS_FILE"
  export CLAUDE_BIN="$_stub" TOK_OUT="$_child"
  # Leak both guards as a prior cma_run_provider launch would leave them.
  export CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000 CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000
  cma_run --iso-probe >/dev/null 2>&1
)
assert_lines "$_child" 2 "stub recorded both token guards"
assert_eq 0 "$(grep -c '=SET$'   "$_child")" "no token guard leaked into the native claude child"
assert_eq 2 "$(grep -c '=UNSET$' "$_child")" "both token guards UNSET for the native claude child"

summary
