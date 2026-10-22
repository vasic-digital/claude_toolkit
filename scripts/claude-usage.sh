#!/usr/bin/env bash
# claude-usage.sh — usage/cost reporting on top of the real `ccusage` binary
# (built by claude-ccusage-build.sh from the vendored submodules/ccusage),
# run against this toolkit's merged SHARED_DIR projects pool.
#
# CONFIRMED-REAL CLI CONTRACT (live run against this host's actual data):
#   CLAUDE_CONFIG_DIR=<dir> ccusage claude daily --json
#     -> {"daily": [...], "totals": {...}}; each daily[] row carries
#        modelBreakdowns[] (present regardless of --breakdown).
#   CLAUDE_CONFIG_DIR=<dir> ccusage claude session --json
#     -> {"sessions": [...], "totals": {...}}; each session row adds
#        firstActivity/lastActivity (ISO-8601) and projectPath.
#
# WHY THIS SCRIPT CANNOT GIVE A TRUE PER-ACCOUNT / PER-ALIAS BREAKDOWN
# (read before "fixing" the honesty language below — it is load-bearing,
# not a hedge): every account dir and every provider-alias config dir on
# this host symlinks `projects/` to the exact SAME $SHARED_DIR/projects —
# confirmed directly with `readlink -f ~/.claude-claude5/projects`,
# `readlink -f ~/.claude-prov-chutes/projects`, etc., all resolving to the
# identical path. Nothing in the stored JSONL transcripts records which
# CLAUDE_CONFIG_DIR produced a given message. So day/model/session/project
# groupings are REAL (ccusage computes them straight from the merged
# transcripts); "provider" is a best-effort cross-reference against
# scripts/providers/status.json that can legitimately be many-to-one
# (several aliases sharing one catalog model id) and is reported as such —
# see claude_usage_report.py's own header for the full contract. Native
# claude1..N accounts cannot be told apart AT ALL (their model field is the
# generic Anthropic id, identical across every native account) and are
# pooled into one explicitly-labeled bucket, never implied to be one
# subscription's share.
#
# A genuinely per-alias GOING-FORWARD ledger (snapshot/delta usage captured
# at each cma_run/cma_run_provider launch) was deliberately NOT built here —
# see the "forward ledger" note in this repo's task history / commit message
# for this change. This script only ever reports the pooled historical data
# ccusage can see, and labels it as such everywhere it appears.
#
# Reports are written under $SHARED_DIR/usage-reports/ (NOT inside the repo
# tree — this is generated, host-specific, financially-flavored output, the
# same "outside git" treatment this toolkit gives every other per-host
# artifact resolved through SHARED_DIR; see this repo's CLAUDE.md "Shared
# dependency layout" / unification-model sections for the existing precedent
# of SHARED_DIR as the canonical location for cross-account generated state).
#
# Usage:
#   claude-usage report [--since YYYY-MM-DD] [--until YYYY-MM-DD]
#                        [--group-by day|model|session|project|provider|all]
#                        [--format json|md|csv] [--out PATH] [--build]
#   claude-usage --help
#
# Default (no --format, no --out): last 4 weeks, --group-by all, writes BOTH
#   $SHARED_DIR/usage-reports/<since>_<until>.json and .md, and prints the
#   Markdown to stdout.
# --format alone (no --out): prints ONLY that format to stdout, writes
#   nothing to disk (the "pipe it somewhere" mode).
# --out PATH: writes to PATH in --format (default md if --format omitted),
#   prints nothing but a one-line confirmation to stderr.
# --build: if `ccusage` is not on PATH, run claude-ccusage-build.sh (which
#   needs a Rust toolchain and may take a while) instead of just failing with
#   instructions. Without --build, a missing `ccusage` is a clear, actionable,
#   non-zero-exit error — this command never silently triggers a heavy build.

set -euo pipefail

# Resolve LIB_DIR through any symlinks (install.sh symlinks into ~/.local/bin),
# same idiom every other script in this toolkit uses.
_cma_src="${BASH_SOURCE[0]}"
while [ -L "$_cma_src" ]; do
  _cma_tgt="$(readlink "$_cma_src")"
  case "$_cma_tgt" in /*) _cma_src="$_cma_tgt" ;; *) _cma_src="$(dirname "$_cma_src")/$_cma_tgt" ;; esac
done
LIB_DIR="$(cd "$(dirname "$_cma_src")" && pwd)"
unset _cma_src _cma_tgt
# shellcheck source=lib.sh
source "$LIB_DIR/lib.sh"

REPORT_HELPER="$LIB_DIR/claude_usage_report.py"
STATUS_JSON="$HOME/.local/share/claude-multi-account/providers/status.json"
BUILD_SCRIPT="$LIB_DIR/claude-ccusage-build.sh"

usage() {
  cat <<'EOF'
Usage:
  claude-usage report [--since YYYY-MM-DD] [--until YYYY-MM-DD]
                       [--group-by day|model|session|project|provider|all]
                       [--format json|md|csv] [--out PATH] [--build]
  claude-usage --help

Default period (no --since/--until): the last 4 weeks (28 days) ending today.
Default --group-by: all (day + model + session + project + provider, combined).

Output modes:
  (neither --format nor --out given)
      Writes BOTH JSON and Markdown reports under
      $SHARED_DIR/usage-reports/<since>_<until>.{json,md}, and also prints
      the Markdown to stdout.
  --format json|md|csv (no --out)
      Prints ONLY that one format to stdout. Writes no file. Useful for
      piping into jq/column/etc.
  --out PATH
      Writes the report to PATH (format: --format if given, else inferred
      from PATH's extension, else md) and prints nothing but a one-line
      confirmation on stderr.
  --build
      If `ccusage` is not found on PATH, run claude-ccusage-build.sh (needs
      a Rust toolchain; may take a while) instead of just erroring out with
      instructions. Without --build, a missing ccusage is a clear,
      actionable, non-zero-exit failure — this command never silently
      kicks off a heavy build on its own.

Honest-labeling note: day/model/session/project groupings come straight
from ccusage's own real output. "provider" is a best-effort cross-reference
against this toolkit's own provider catalog (scripts/providers/status.json)
and can legitimately be many-to-one (ambiguous) or unmapped — see the report
itself for exactly which. Native claude1..N accounts cannot be distinguished
from each other at all and are pooled into one explicitly-labeled bucket.
EOF
}

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------

[[ $# -ge 1 ]] || { usage; exit 2; }

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

cmd="$1"; shift
if [[ "$cmd" != "report" ]]; then
  printf 'claude-usage: unknown subcommand %q\n\n' "$cmd" >&2
  usage >&2
  exit 2
fi

since=""
until_=""
group_by="all"
format=""
out=""
do_build=0

while (( $# )); do
  case "$1" in
    --since) since="$2"; shift 2 ;;
    --until) until_="$2"; shift 2 ;;
    --group-by) group_by="$2"; shift 2 ;;
    --format) format="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --build) do_build=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'claude-usage report: unknown argument %q\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$group_by" in
  day|model|session|project|provider|all) : ;;
  *) printf 'claude-usage report: --group-by must be one of day|model|session|project|provider|all, got %q\n' "$group_by" >&2; exit 2 ;;
esac

if [[ -n "$format" ]]; then
  case "$format" in
    json|md|csv) : ;;
    *) printf 'claude-usage report: --format must be one of json|md|csv, got %q\n' "$format" >&2; exit 2 ;;
  esac
fi

_valid_date() {
  # YYYY-MM-DD, validated by actually parsing it (catches 2026-13-40 etc.),
  # portable across GNU and BSD date.
  date -d "$1" >/dev/null 2>&1 || date -j -f '%Y-%m-%d' "$1" >/dev/null 2>&1
}

if [[ -n "$since" ]] && ! _valid_date "$since"; then
  printf 'claude-usage report: --since %q is not a valid YYYY-MM-DD date\n' "$since" >&2
  exit 2
fi
if [[ -n "$until_" ]] && ! _valid_date "$until_"; then
  printf 'claude-usage report: --until %q is not a valid YYYY-MM-DD date\n' "$until_" >&2
  exit 2
fi

# Default period: the last 4 weeks (28 days) ending today.
if [[ -z "$until_" ]]; then
  until_="$(date +%Y-%m-%d)"
fi
if [[ -z "$since" ]]; then
  if date -d "$until_ -28 days" +%Y-%m-%d >/dev/null 2>&1; then
    since="$(date -d "$until_ -28 days" +%Y-%m-%d)"          # GNU date
  else
    since="$(date -j -v-28d -f '%Y-%m-%d' "$until_" +%Y-%m-%d)"  # BSD date
  fi
fi

if [[ "$since" > "$until_" ]]; then
  printf 'claude-usage report: --since %s is after --until %s\n' "$since" "$until_" >&2
  exit 2
fi

# ccusage wants YYYYMMDD (no dashes).
since8="${since//-/}"
until8="${until_//-/}"

# ---------------------------------------------------------------------------
# ccusage availability
# ---------------------------------------------------------------------------

if ! command -v ccusage >/dev/null 2>&1; then
  if (( do_build )); then
    cma_log "ccusage not found on PATH; --build given, running claude-ccusage-build.sh..."
    if [[ ! -x "$BUILD_SCRIPT" ]]; then
      printf 'claude-usage: --build was given but %s is missing or not executable.\n' "$BUILD_SCRIPT" >&2
      exit 1
    fi
    "$BUILD_SCRIPT"
    if ! command -v ccusage >/dev/null 2>&1; then
      printf 'claude-usage: claude-ccusage-build.sh ran but ccusage is still not on PATH. See its output above.\n' >&2
      exit 1
    fi
  else
    cat >&2 <<EOF
claude-usage: 'ccusage' is not on PATH.

This command reports on REAL ccusage output and refuses to silently kick off
a heavy build as a side effect of a reporting command. Build it explicitly:

    bash $LIB_DIR/claude-ccusage-build.sh

...or re-run this command with --build to have it do that for you:

    claude-usage report --build
EOF
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Shell out to the real ccusage against the toolkit's merged SHARED_DIR pool.
# SHARED_DIR resolution mirrors lib.sh's own default EXACTLY (lib.sh itself
# is out of scope for this change — see this script's header/commit message
# for why): `: "${SHARED_DIR:=$HOME/.claude-shared}"`. Sourcing lib.sh above
# already performed that same resolution, so $SHARED_DIR here IS that value.
# ---------------------------------------------------------------------------

_tmpd="$(mktemp -d "${TMPDIR:-/tmp}/claude-usage.XXXXXX")"
trap 'rm -rf -- "$_tmpd"' EXIT

daily_json="$_tmpd/daily.json"
session_json="$_tmpd/session.json"

cma_log "querying ccusage (CLAUDE_CONFIG_DIR=$SHARED_DIR, $since..$until_)..."

if ! CLAUDE_CONFIG_DIR="$SHARED_DIR" ccusage claude daily --json --breakdown \
     --since "$since8" --until "$until8" >"$daily_json" 2>"$_tmpd/daily.err"; then
  cat "$_tmpd/daily.err" >&2
  printf 'claude-usage: `ccusage claude daily --json` failed (see above).\n' >&2
  exit 1
fi
if ! CLAUDE_CONFIG_DIR="$SHARED_DIR" ccusage claude session --json --breakdown \
     --since "$since8" --until "$until8" >"$session_json" 2>"$_tmpd/session.err"; then
  cat "$_tmpd/session.err" >&2
  printf 'claude-usage: `ccusage claude session --json` failed (see above).\n' >&2
  exit 1
fi

status_arg=()
if [[ -r "$STATUS_JSON" ]]; then
  status_arg=(--status "$STATUS_JSON")
else
  cma_warn "provider status catalog not found/readable at $STATUS_JSON — 'provider' grouping will report everything as unmapped"
fi

_render() {
  # _render FORMAT
  python3 "$REPORT_HELPER" \
    --daily "$daily_json" --session "$session_json" \
    "${status_arg[@]}" \
    --since "$since" --until "$until_" \
    --group-by "$group_by" --format "$1"
}

range_tag="${since}_${until_}"

if [[ -n "$out" ]]; then
  _fmt="$format"
  if [[ -z "$_fmt" ]]; then
    case "$out" in
      *.json) _fmt="json" ;;
      *.csv)  _fmt="csv" ;;
      *)      _fmt="md" ;;
    esac
  fi
  mkdir -p "$(dirname "$out")"
  _render "$_fmt" > "$out"
  cma_log "wrote $_fmt report to $out"
  exit 0
fi

if [[ -n "$format" ]]; then
  _render "$format"
  exit 0
fi

# Default: write both JSON and MD under $SHARED_DIR/usage-reports/, print MD.
outdir="$SHARED_DIR/usage-reports"
mkdir -p "$outdir"
json_path="$outdir/$range_tag.json"
md_path="$outdir/$range_tag.md"

_render json > "$json_path"
_render md > "$md_path"
cma_log "wrote $json_path"
cma_log "wrote $md_path"

cat "$md_path"
