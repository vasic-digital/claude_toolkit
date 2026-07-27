#!/usr/bin/env bash
# providers-semantic.sh — layer-3 (semantic code-visibility) adapter for
# claude-providers. Runs AFTER existence/tool-call passed. Drives the
# LLMsVerifier semantic-code-visibility command with the toolkit-owned fixture,
# prompt, sentinel and rubric (the submodule stays project-not-aware; every
# consumer-specific input is a CLI arg — CONST-051).
#
# Output: one word on stdout — verified | unverified | skip. Exit: 0/1/2.
#   verified  round-1 sentinel + round-2 judge both passed.
#   unverified  a round reached a definitive negative — the sentinel was not
#         reflected, the reply was a prompt-echo bluff, the judge scored below
#         threshold, OR the provider definitively rejected the model-under-test
#         call (HTTP 401/402/403/404). All four are exit 1; the driver's own
#         per-round `reason` says which, and is what the verdict line reports.
#   skip  a precondition was absent (no key/judge/go/network) — HONEST SKIP,
#         the caller MUST NOT downgrade on this (§11.4.3).
#
# Args: --provider ID --model M --key-var VAR [--base-url URL] [--offline]
set -uo pipefail

_cma_src="${BASH_SOURCE[0]}"
while [ -L "$_cma_src" ]; do
  _cma_tgt="$(readlink "$_cma_src")"
  case "$_cma_tgt" in /*) _cma_src="$_cma_tgt" ;; *) _cma_src="$(dirname "$_cma_src")/$_cma_tgt" ;; esac
done
LIB_DIR="$(cd "$(dirname "$_cma_src")" && pwd)"
unset _cma_src _cma_tgt
REPO_ROOT="$(cd "$LIB_DIR/.." && pwd)"

PROVIDER="" MODEL="" KEYVAR="" BASEURL="" OFFLINE=0
while (( $# )); do
  case "$1" in
    --provider) PROVIDER="$2"; shift 2 ;;
    --model)    MODEL="$2"; shift 2 ;;
    --key-var)  KEYVAR="$2"; shift 2 ;;
    --base-url) BASEURL="$2"; shift 2 ;;
    --offline)  OFFLINE=1; shift ;;
    *) echo "providers-semantic: unknown arg $1" >&2; exit 2 ;;
  esac
done

emit_skip() { echo skip; echo "providers-semantic[$PROVIDER]: skip — ${1:-precondition absent}" >&2; exit 2; }

DRIVER="${CMA_SEMANTIC_DRIVER:-$LIB_DIR/claude-semantic-visibility.sh}"
FIX="${CMA_SEMANTIC_FIXTURE:-$LIB_DIR/providers/fixture/code-visibility.md}"
PROMPT="${CMA_SEMANTIC_PROMPT:-$LIB_DIR/providers/fixture/prompt-template.txt}"
RUBRIC="${CMA_SEMANTIC_RUBRIC:-$LIB_DIR/providers/rubric/code-visibility-rubric.json}"
SENTINEL="${CMA_SEMANTIC_SENTINEL:-ZETA-9-ORANGE-7f3a}"

(( OFFLINE )) && emit_skip "offline"
[[ -f "$FIX" && -f "$PROMPT" && -f "$RUBRIC" ]] || emit_skip "toolkit seam files missing"
command -v jq >/dev/null 2>&1 || emit_skip "jq not available"

# --- keys (env only; never argv) -------------------------------------------
# The model-under-test key: the caller (cmd_sync) has already sourced the keys
# file into this process's env, so ${!KEYVAR} resolves. Re-export under the
# fixed name the Go command reads via --api-key-env.
mkey="${!KEYVAR:-}"
[[ -n "$mkey" ]] || emit_skip "no key in \$$KEYVAR for model under test"
export CMA_PROBE_KEY="$mkey"

# --- judge config (providers/judge.env overrides the template default) ------
JUDGE_ENV="${CMA_JUDGE_ENV:-$LIB_DIR/providers/judge.env}"
[[ -f "$JUDGE_ENV" ]] || JUDGE_ENV="$LIB_DIR/providers/judge.env.template"
# shellcheck source=/dev/null  # runtime judge config, non-secret (holds var NAMES + urls)
[[ -f "$JUDGE_ENV" ]] && { set -a +u; . "$JUDGE_ENV"; set +a; }
JUDGE_BASE="${CMA_JUDGE_BASE_URL:-}"
# Normalize the same way as the model-under-test base (below): the Go command
# appends /v1/chat/completions to whatever judge-base-url it is given too, so
# a judge.env base ending in /v1 (a very natural way to write one) would
# otherwise double up to /v1/v1/chat/completions -> 404.
JUDGE_BASE="${JUDGE_BASE%/}"; JUDGE_BASE="${JUDGE_BASE%/chat/completions}"; JUDGE_BASE="${JUDGE_BASE%/anthropic}"; JUDGE_BASE="${JUDGE_BASE%/v1}"
JUDGE_MODEL="${CMA_JUDGE_MODEL:-}"
JUDGE_KEYVAR="${CMA_JUDGE_KEYVAR:-}"
JUDGE_THRESHOLD="${CMA_JUDGE_THRESHOLD:-2}"
# Judge key: the value under $CMA_JUDGE_KEY (already set by tests) OR ${!JUDGE_KEYVAR}.
jkey="${CMA_JUDGE_KEY:-}"
[[ -z "$jkey" && -n "$JUDGE_KEYVAR" ]] && jkey="${!JUDGE_KEYVAR:-}"
[[ -n "$jkey" && -n "$JUDGE_BASE" && -n "$JUDGE_MODEL" ]] || emit_skip "no round-2 judge configured (see providers/judge.env)"
export CMA_JUDGE_KEY="$jkey"

# --- base-url normalization (the Go command appends /v1/chat/completions) ----
base="${BASEURL:-}"
base="${base%/}"; base="${base%/chat/completions}"; base="${base%/anthropic}"; base="${base%/v1}"
[[ -n "$base" ]] || emit_skip "no base url"

# Independence guard (final-review / deep-research §11.4.150): a judge on the SAME
# provider endpoint as the model-under-test is the same model family and exhibits
# measured self-preference bias (arXiv:2508.06709), inflating verdicts. WARN (do not
# fail — the operator may intend it); the real fix is a different-family judge in judge.env.
_su_host="${base#*://}"; _su_host="${_su_host%%/*}"
_ju_host="${JUDGE_BASE#*://}"; _ju_host="${_ju_host%%/*}"
[[ -n "$_su_host" && "$_su_host" == "$_ju_host" ]] && \
  echo "providers-semantic[$PROVIDER]: WARNING judge endpoint '$_ju_host' == model-under-test endpoint — same-family judge is NOT independent (self-grading bias); prefer a different-family judge in providers/judge.env" >&2

# --- split the toolkit prompt template into round-1 + round-2 ----------------
# The template carries a "Round 1 —" block and a "Round 2 —" block; the Go
# command takes them as two separate flags. Split on the first line starting
# with "Round 2" (a generic delimiter; the wording stays toolkit-owned).
tmp1="$(mktemp "${TMPDIR:-/tmp}/cma-r1.XXXXXX")"
tmp2="$(mktemp "${TMPDIR:-/tmp}/cma-r2.XXXXXX")"
awk 'BEGIN{p=1} /^Round 2/{p=2} p==1{print > R1} p==2{print > R2}' \
    R1="$tmp1" R2="$tmp2" "$PROMPT"

# --- render the rubric into a judge-prompt template (toolkit-owned) ----------
tmpj="$(mktemp "${TMPDIR:-/tmp}/cma-judge.XXXXXX")"
{
  echo "You grade whether a DESCRIPTION accurately reflects some REFERENCE code."
  echo
  echo "REFERENCE code:"
  echo "{{FIXTURE_CONTENT}}"
  echo
  echo "DESCRIPTION to grade:"
  echo "{{DESCRIPTION}}"
  echo
  echo "Score 0-3 using this rubric:"
  jq -r '.criteria | to_entries[] | "  \(.key) = \(.value)"' "$RUBRIC"
  echo "Fixture-specific details a good description names:"
  jq -r '.fixture_specific_details[] | "  - \(.)"' "$RUBRIC"
  echo
  echo "Reply with ONLY the single integer 0, 1, 2, or 3."
} > "$tmpj"

[[ -n "${CMA_SEMANTIC_DEBUG:-}" ]] && cat "$tmpj" >&2

cleanup() { rm -f "$tmp1" "$tmp2" "$tmpj"; }
trap cleanup EXIT

# --- run the command (keys via env, never argv) ------------------------------
mkdir -p "$REPO_ROOT/.local-cache"
set +e
"$DRIVER" \
  --base-url "$base" --model "$MODEL" --api-key-env CMA_PROBE_KEY \
  --fixture "$FIX" --prompt "$tmp1" --round2-prompt "$tmp2" --sentinel "$SENTINEL" \
  --judge-base-url "$JUDGE_BASE" --judge-model "$JUDGE_MODEL" --judge-api-key-env CMA_JUDGE_KEY \
  --judge-prompt "$tmpj" --judge-threshold "$JUDGE_THRESHOLD" \
  --format json >"$REPO_ROOT/.local-cache/semantic-last.json" 2>"$REPO_ROOT/.local-cache/semantic-last.err"
rc=$?
set -e

# Evidence capture (§11.4.5 / §11.4.116 — a verdict must carry the evidence that
# backs it). The driver's per-round JSON lands in ONE cache file that the next
# provider overwrites, so a sweep across N providers leaves only the LAST run
# diagnosable: a layer-3 FAIL for provider k is unreconstructable afterwards.
# Callers capture THIS script's stderr per provider, so mirror the driver's JSON
# (and any stderr) there. Verdict logic is untouched — stderr only.
{
  printf 'providers-semantic[%s]: driver rc=%s\n' "$PROVIDER" "$rc"
  if [[ -s "$REPO_ROOT/.local-cache/semantic-last.json" ]]; then
    printf 'driver json: '; cat "$REPO_ROOT/.local-cache/semantic-last.json"
  fi
  if [[ -s "$REPO_ROOT/.local-cache/semantic-last.err" ]]; then
    printf 'driver stderr: '; head -c 2000 "$REPO_ROOT/.local-cache/semantic-last.err"; echo
  fi
} >&2 || true
# `|| true` is load-bearing (independent-review finding F1). `set -e` is active
# here, and this block sits BETWEEN `rc=$?` and the verdict `case`. An I/O fault
# inside it (unreadable cache, full pipe, closed stderr) would abort the script
# before the verdict word is echoed — and claude-providers.sh reads an EMPTY
# verdict as "keep the existence verdict", silently turning a definitive layer-3
# FAIL into `verified`. Evidence capture must never be able to decide the verdict.

# _driver_reason — the cause the DRIVER actually reported, never one we assert.
#
# WHY (2026-07-27 audit). Driver exit 1 does NOT mean "cannot see code /
# bluffed". Per the driver's own contract
# (submodules/LLMsVerifier/llm-verifier/cmd/semantic-code-visibility/main.go:44-50)
# exit 1 ALSO covers definitive provider rejections on the model-under-test —
# HTTP 401, 402, 403, 404 — because auth failure, depleted credit and
# model-not-found are deterministic states, not transient infra. Printing a
# bluff verdict for those writes a FALSE CAUSE into scripts/tests/proof/, which
# is the audit trail this project reasons from. Measured on that corpus: 24
# evidence files carried the old message, 22 of them alongside a driver reason
# of `non-200 status 401/402/403/404`, and 0 were actual bluffs.
# providers-inference-semantic.txt holds both claims twelve lines apart —
# `non-200 status 402: "Insufficient balance for request."` and then "cannot see
# code / bluffed".
#
# The honest string was ALREADY LOCAL and simply never read: the evidence block
# ten lines above mirrors the driver's JSON, which carries a per-round `reason`.
# So this reads the reason instead of naming one of three causes. The verdict
# word (`unverified`) and the exit code (1) are DELIBERATELY unchanged — a 401 on
# the model under test really does mean the alias cannot be trusted, so only the
# human-facing cause moves.
#
# `set -e` is active here (line 135), and this runs inside a command
# substitution in the verdict `case` — so every command is failure-tolerant. An
# unreadable cache must degrade to a vaguer reason, never truncate or abort the
# verdict, which is the same fail-open the `|| true` above exists to prevent.
_driver_reason() {
  local j="$REPO_ROOT/.local-cache/semantic-last.json"
  local e="$REPO_ROOT/.local-cache/semantic-last.err"
  local r=""
  # First round whose `pass` is literally false owns the failure. round2_judge
  # carries pass=null when skipped, and `select(.pass == false)` excludes null,
  # so a round-1 rejection is never mis-attributed to the judge.
  if [[ -s "$j" ]] && command -v jq >/dev/null 2>&1; then
    r="$(jq -r '[.round1_sentinel?, .round2_judge?]
                  | map(select(type == "object" and .pass == false) | .reason // empty)
                  | first // empty' "$j" 2>/dev/null)" || r=""
  fi
  # Fallbacks, in descending order of specificity: the driver's stderr, then an
  # explicit statement that no cause was reported. Never a guessed cause.
  if [[ -z "$r" || "$r" == "null" ]]; then
    r="$(head -c 300 "$e" 2>/dev/null | tr '\n' ' ')" || r=""
  fi
  [[ -n "$r" ]] || r="not reported by the driver (see the driver json/stderr mirrored above)"
  printf '%s' "$r"
}

case "$rc" in
  0) echo verified;   echo "providers-semantic[$PROVIDER]: layer-3 sentinel+judge PASS" >&2; exit 0 ;;
  1) echo unverified; echo "providers-semantic[$PROVIDER]: layer-3 unverified — driver exit 1; reason: $(_driver_reason)" >&2; exit 1 ;;
  3) emit_skip "round-1/round-2 API call could not complete (transport/infra error, exit 3) — honest SKIP, no downgrade (final-review I-1: a transient judge/model error must not demote the model-under-test)" ;;
  *) emit_skip "semantic command config/precondition error (exit $rc)" ;;
esac
