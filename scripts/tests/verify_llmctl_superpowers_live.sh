#!/usr/bin/env bash
# verify_llmctl_superpowers_live.sh — US3 orchestrator (spec
# 001-llmctl-integration-hardening, T027): runs the full
# {llmctl-backed alias} x {CLI agent family} x {Superpowers command} matrix
# through verify_superpowers_tui.sh and emits ONE aggregated, durable,
# machine-readable Check Result record (data-model.md) — never a silently
# missing combination.
#
# Discovery is delegated to detect_llmctl_records() (claude-providers.sh) --
# this script never re-implements llmctl liveness detection. On a host where
# llmctl is absent or has nothing running, this is an HONEST, non-error
# outcome (FR-004/FR-014): exit 0, a result file recording zero combinations,
# never a crash and never a fabricated pass.
#
# Usage: verify_llmctl_superpowers_live.sh [--run-index N] [--out FILE]
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
PROOF_DIR="${PROOF_DIR:-$TESTS_DIR/proof}"
mkdir -p "$PROOF_DIR"

RUN_INDEX=1
OUT=""
while (( $# )); do
  case "$1" in
    --run-index) RUN_INDEX="$2"; shift 2 ;;
    --out)       OUT="$2"; shift 2 ;;
    -h|--help)   sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
: "${OUT:=$PROOF_DIR/llmctl-superpowers-live-matrix.json}"

COMMANDS=(using-superpowers systematic-debugging subagent-driven-development)
AGENTS=(claude kimi)

# --- discover every currently-live llmctl-backed alias ----------------------
# Reuses detect_llmctl_records() verbatim -- never a second detection path.
RECORDS="[]"
if command -v jq >/dev/null 2>&1; then
  RECORDS="$(cd "$SCRIPTS_DIR" && bash -c 'source claude-providers.sh >/dev/null 2>&1; detect_llmctl_records' 2>/dev/null)" || RECORDS="[]"
  printf '%s' "$RECORDS" | jq -e 'type=="array"' >/dev/null 2>&1 || RECORDS="[]"
fi
ALIASES="$(printf '%s' "$RECORDS" | jq -r '.[].alias' 2>/dev/null)"

RESULTS_TMP="$(mktemp -d "${TMPDIR:-/tmp}/llmctl-live-matrix.XXXXXX")"
trap 'rm -rf "$RESULTS_TMP"' EXIT
_n=0

run_one() {
  local alias="$1" agent="$2" command="$3"
  local combo_id="${alias}__${agent}__${command}"
  local evidence="$PROOF_DIR/providers-${alias}-${agent}-${command}-superpowers.txt"
  local verdict="skip" reason="" route_resolved="" rc=0

  # verify_superpowers_tui.sh's own convention: PASS and SKIP both exit 0 --
  # they are distinguished ONLY by the stdout text prefix ("PASS: "/"SKIP: "),
  # never by exit code alone. Classifying purely on exit code (as an earlier
  # draft of this function did) silently records every genuine SKIP as a
  # PASS -- a real, confirmed bug caught during the T030 review, fixed here:
  # the text prefix is checked FIRST and always, independent of exit code.
  VERBOSE_OUT="$(bash "$TESTS_DIR/../verify_superpowers_tui.sh" \
        --alias "$alias" --command "$command" --agent "$agent" \
        --out "$evidence" 2>&1)"; rc=$?
  case "$VERBOSE_OUT" in
    PASS:*) verdict="pass" ;;
    SKIP:*) verdict="skip"; reason="${VERBOSE_OUT#SKIP: }" ;;
    FAIL:*) verdict="fail"; reason="${VERBOSE_OUT#FAIL: }" ;;
    *)
      # Neither prefix matched (unexpected output shape) -- never silently
      # call this a pass; record it as a fail naming the real exit code and
      # a truncated excerpt of what was actually printed, per this feature's
      # own anti-bluff discipline (an unrecognized result is not a success).
      verdict="fail"; reason="unrecognized output shape (exit $rc): ${VERBOSE_OUT:0:120}" ;;
  esac
  route_resolved="$(grep -m1 '^# ROUTE-RESOLVED:' "$evidence" 2>/dev/null | sed 's/^# ROUTE-RESOLVED: //')"

  jq -cn --arg id "$combo_id" --arg alias "$alias" --arg agent "$agent" --arg command "$command" \
         --arg verdict "$verdict" --arg reason "$reason" --arg evidence "$evidence" \
         --arg route "$route_resolved" --argjson run_index "$RUN_INDEX" \
    '{combination_id:$id, alias:$alias, agent:$agent, command:$command,
      verdict:$verdict, reason:$reason, evidence:$evidence,
      route_resolved:$route, run_index:$run_index}' \
    > "$RESULTS_TMP/$(printf '%04d' "$_n").json"
  _n=$((_n + 1))
}

if [[ -z "$ALIASES" ]]; then
  jq -cn --argjson run_index "$RUN_INDEX" \
    '{combination_id:"(none)", alias:null, agent:null, command:null,
      verdict:"skip", reason:"no llmctl-backed aliases discovered on this host",
      evidence:null, route_resolved:null, run_index:$run_index}' \
    > "$RESULTS_TMP/0000.json"
else
  while IFS= read -r alias; do
    [[ -n "$alias" ]] || continue
    for agent in "${AGENTS[@]}"; do
      for command in "${COMMANDS[@]}"; do
        run_one "$alias" "$agent" "$command"
      done
    done
  done <<<"$ALIASES"
fi

jq -s 'sort_by(.combination_id)' "$RESULTS_TMP"/*.json > "$OUT"
echo "Check Result matrix written: $OUT"
jq -r '.[] | "\(.verdict|ascii_upcase): \(.combination_id)\(if .reason != "" then " -- " + .reason else "" end)"' "$OUT"
echo "total=$(jq 'length' "$OUT")"
exit 0
