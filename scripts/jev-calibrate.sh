#!/usr/bin/env bash
# jev-calibrate.sh — Jev decision-threshold calibration loop
# (design: toolkit-jev-design §2.6 follow-up; implements the POC's
# shadow -> label -> sweep -> enforce -> drift-check workflow, documented in
# Jev.md, against this toolkit's OWN stdlib-only tooling rather than the
# unverified third-party jevcal/jevkit-calibrate packages the doc names).
#
# Usage:
#   jev-calibrate label  --data DECISIONS --labels LABELS --out LABELED
#   jev-calibrate sweep  --data LABELED [--target-accuracy 0.95] [--lock LOCK] [--json]
#   jev-calibrate check  --data LABELED --lock LOCK [--max-ece 0.05] [--max-mce 0.15] [--json]
#
# Honest gap vs. the POC: there is no built-in "ask an LLM to label this"
# call. `label` merges OPERATOR-SUPPLIED ground truth (a JSON array of
# {"index":N,"ground_truth_ask":bool,"ground_truth_deny":bool}, N = 0-based
# line number in the DECISIONS snapshot) into the decisions. Wiring a live
# LLM-teacher call (e.g. asking Claude to label each shadow decision) is a
# documented follow-up integration point, not something this script fakes.
#
# DECISIONS is normally a snapshot of $JEV_STATE_DIR/decisions.jsonl (copy it
# before labeling so the line numbers you hand-label stay stable):
#   cp "${JEV_STATE_DIR:-$HOME/.local/state/jev}/decisions.jsonl" shadow_batch.jsonl
set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_py="${JEV_CALIBRATE_PY:-$_here/jev_calibrate.py}"

if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  grep '^#' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

_cmd="$1"; shift
case "$_cmd" in
  label|sweep|check) ;;
  *) printf 'jev-calibrate: unknown subcommand %s (expected label|sweep|check)\n' "$_cmd" >&2; exit 2 ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
  printf 'jev-calibrate: python3 not found\n' >&2
  exit 2
fi

exec python3 "$_py" "$_cmd" "$@"
