#!/usr/bin/env bash
# jev-stats.sh — Jev decision-layer savings/calibration reporter
# (design: toolkit-jev-design §2.8).
#
# Usage: jev-stats [--days N] [--json]
#
# ESTIMATED TOKEN SAVINGS FORMULA (documented estimate, not metered):
#   saved_tokens = gated_decisions * JEV_EST_INPUT_TOKENS  (default 1500)
#                + enforced_ask_or_deny * JEV_EST_OUTPUT_TOKENS (default 200)
# Rationale: each gated decision replaces approximately one avoided LLM
# round-trip (~1500 input tokens of guard reasoning + ~200 output tokens at
# the active provider's pricing tier) and every enforced ask/deny deflects
# one wasted tool-result ingestion. Constants are env-overridable and this
# formula is printed in the report header.
set -uo pipefail

JEV_STATE_DIR="${JEV_STATE_DIR:-$HOME/.local/state/jev}"
LOG="$JEV_STATE_DIR/decisions.jsonl"
DAYS=0 JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --days) DAYS="$2"; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'jev-stats: unknown flag %s\n' "$1" >&2; exit 2 ;;
  esac
done

EST_IN="${JEV_EST_INPUT_TOKENS:-1500}"
EST_OUT="${JEV_EST_OUTPUT_TOKENS:-200}"

if [ ! -s "$LOG" ]; then
  if [ "$JSON" = 1 ]; then
    printf '{"total":0,"message":"no Jev decisions yet"}\n'
  else
    printf 'No Jev decisions yet — launch any alias after `claude-providers sync`.\n'
  fi
  exit 0
fi

# Optional time window (epoch ms cutoff).
_cutoff=0
if [ "$DAYS" -gt 0 ]; then
  _cutoff=$(( ( $(date +%s) - DAYS * 86400 ) * 1000 ))
fi

_stats=$(jq -s --argjson cutoff "$_cutoff" --argjson est_in "$EST_IN" --argjson est_out "$EST_OUT" '
  [ .[] | select((.ts // 0) >= $cutoff) ] as $d
  | ($d | length) as $total
  | def countby(f): (group_by(f) | map({(first | f | tostring): length}) | add) // {};
  {
    total: $total,
    by_answer: (countby(.answer // "unknown")),
    by_mode: (countby(.mode // "unknown")),
    by_agent: (countby(.agent // "unknown")),
    by_endpoint: (countby(.endpoint // "unknown")),
    fallbacks: ( [ $d[] | select(.fallback != null) ] | length ),
    avg_latency_ms: ( if $total > 0
                      then (([ $d[] | (.latency_ms // 0) ] | add) / $total * 10 | round / 10)
                      else 0 end ),
    shadow_would: {
      deny: ([ $d[] | select(.mode == "shadow" and .answer == "deny") ] | length),
      ask:  ([ $d[] | select(.mode == "shadow" and .answer == "ask") ] | length),
      allow:([ $d[] | select(.mode == "shadow" and .answer == "allow") ] | length)
    },
    enforced_ask_deny: ([ $d[] | select(.enforced == true and (.answer == "ask" or .answer == "deny")) ] | length),
    est_tokens_saved: ( $total * $est_in
                        + ([ $d[] | select(.enforced == true and (.answer == "ask" or .answer == "deny")) ] | length) * $est_out ),
    formula: "saved = total_decisions * \($est_in) (input) + enforced_ask_or_deny * \($est_out) (output); constants via JEV_EST_INPUT_TOKENS / JEV_EST_OUTPUT_TOKENS"
  }' "$LOG" 2>/dev/null)

if [ -z "$_stats" ]; then
  printf 'jev-stats: could not parse %s\n' "$LOG" >&2
  exit 1
fi

if [ "$JSON" = 1 ]; then
  printf '%s\n' "$_stats"
  exit 0
fi

printf 'Jev decision-layer stats  (%s%s)\n' "$LOG" "$([ "$DAYS" -gt 0 ] && printf ', last %s days' "$DAYS")"
printf 'ESTIMATE formula: %s\n\n' "$(printf '%s' "$_stats" | jq -r '.formula')"
printf 'total decisions: %s   fallbacks (fail-open): %s   avg latency: %sms\n' \
  "$(printf '%s' "$_stats" | jq -r '.total')" \
  "$(printf '%s' "$_stats" | jq -r '.fallbacks')" \
  "$(printf '%s' "$_stats" | jq -r '.avg_latency_ms')"
for dim in answer mode agent endpoint; do
  printf '\nby %s:\n' "$dim"
  printf '%s' "$_stats" | jq -r --arg d "by_$dim" '.[$d] | to_entries[] | "  \(.key): \(.value)"'
done
printf '\nshadow-mode calibration (would-have-been):\n'
printf '%s' "$_stats" | jq -r '.shadow_would | "  deny: \(.deny)  ask: \(.ask)  allow: \(.allow)"'
_total=$(printf '%s' "$_stats" | jq -r '.total')
_shadow_deny=$(printf '%s' "$_stats" | jq -r '.shadow_would.deny')
if [ "$_total" -gt 0 ]; then
  printf '  would-deny rate (shadow): %s%%\n' \
    "$(awk -v d="$_shadow_deny" -v t="$_total" 'BEGIN{printf "%.1f", (t>0)? d*100.0/t : 0}')"
fi
printf '\nESTIMATED tokens saved: %s\n' "$(printf '%s' "$_stats" | jq -r '.est_tokens_saved')"
printf 'Review shadow verdicts for a calibration week before `jev-setup --mode enforce`.\n'
