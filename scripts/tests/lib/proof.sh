#!/usr/bin/env bash
# proof.sh — writer API for proof/evidence output (operator decisions D1, D3).
#
# Contract:
#   * Regenerated run output is VOLATILE and lives in scripts/tests/proof/volatile/,
#     which is git-ignored. Only the curated files (.gitkeep, PROOF.md,
#     00-summary.txt) live in scripts/tests/proof/ itself and stay tracked.
#   * Writers never truncate their evidence file in place. They build a temp
#     file in the SAME directory (so the final rename stays on one filesystem
#     and is atomic) and rename it over the final path on completion. A
#     concurrent reader therefore sees either the previous complete file or the
#     new complete file, never a partial one.
#
# Usage:
#   source "$TESTS_DIR/lib/proof.sh"
#   PROOF_DIR="${PROOF_DIR:-$(cma_proof_volatile_dir)}"
#   PROOF_FINAL="$PROOF_DIR/xx-name.txt"
#   PROOF="$(cma_proof_open "$PROOF_FINAL")"   # write/append to $PROOF
#   ...
#   cma_proof_commit "$PROOF" "$PROOF_FINAL"   # once, when complete
#
# A run that aborts before commit leaves only a dot-prefixed temp inside the
# ignored folder; the last complete evidence file is untouched.

_CMA_PROOF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# cma_proof_volatile_dir — the git-ignored folder for regenerated run output.
cma_proof_volatile_dir() {
  printf '%s\n' "$(cd "$_CMA_PROOF_LIB_DIR/.." && pwd)/proof/volatile"
}

# cma_proof_open FINAL — create the directory of FINAL if needed, then create
# and print an empty temp file next to it. Portable mktemp template (no
# --suffix), so it works with BSD and GNU mktemp.
cma_proof_open() {
  local final="$1" dir base
  dir="$(dirname "$final")"; base="$(basename "$final")"
  mkdir -p "$dir" || return 1
  mktemp "$dir/.${base}.tmp.XXXXXX"
}

# cma_proof_commit TMP FINAL — publish TMP as FINAL with one rename. mktemp
# creates files 0600; widen to the usual 0644 so the published evidence keeps
# the permissions the old in-place writers produced.
cma_proof_commit() {
  local tmp="$1" final="$2"
  [[ -f "$tmp" ]] || return 1
  chmod 0644 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$final"
}

# cma_proof_redact_ip ADDR — filter stdin to stdout, replacing every literal
# occurrence of the IPv4 address ADDR with the fixed placeholder 192.168.x.x
# (D3). Dots in ADDR are matched literally. An empty ADDR is a pass-through.
cma_proof_redact_ip() {
  local addr="${1:-}"
  if [[ -z "$addr" ]]; then cat; return 0; fi
  local re="${addr//./\\.}"
  # Bounded on both sides by a non-digit, so 192.168.1.1 never rewrites the
  # prefix of 192.168.1.115. The expression runs twice because adjacent
  # matches share a boundary character that the first pass consumes.
  local e="s/(^|[^0-9])${re}([^0-9]|\$)/\\1192.168.x.x\\2/g"
  sed -E -e "$e" -e "$e"
}
