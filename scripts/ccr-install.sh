#!/usr/bin/env bash
# ccr-install.sh — standalone build-and-install for the bundled
# claude-code-router (Go).  Can be invoked independently or from
# install.sh (which calls it via claude-ccr-build.sh).
#
# Idempotent: rebuilds the binary and re-points the symlink.
# Exit 0 → ccr is installed and usable.
# Exit 1 → build failed and no usable ccr exists.
#
# Usage:
#   bash scripts/ccr-install.sh
#   bash scripts/ccr-install.sh --bin-dir /usr/local/bin
#
# Env:
#   BIN_DIR   target directory for the `ccr` symlink (default ~/.local/bin)

set -euo pipefail

_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _tgt="$(readlink "$_src")"
  case "$_tgt" in /*) _src="$_tgt" ;; *) _src="$(dirname "$_src")/$_tgt" ;; esac
done
LIB_DIR="$(cd "$(dirname "$_src")" && pwd)"
unset _src _tgt

REPO_ROOT="$(cd "$LIB_DIR/.." && pwd)"
SUBMODULE="$REPO_ROOT/submodules/claude-code-router"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"

log()  { printf '\033[0;32m[ccr]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[ccr]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[ccr]\033[0m %s\n' "$*" >&2; exit 1; }

# --- preflight ----------------------------------------------------------

if [ ! -d "$SUBMODULE" ]; then
  die "submodule not found at $SUBMODULE — run: git submodule update --init"
fi

if ! command -v go >/dev/null 2>&1; then
  if [ -x "$BIN_DIR/ccr" ]; then
    warn "Go not found; existing ccr is USABLE but STALE (cannot rebuild)."
    warn "Install Go (https://go.dev/dl/) to enable rebuilding on submodule updates."
    exit 0
  fi
  die "Go toolchain not found and no existing ccr at $BIN_DIR/ccr — install Go first."
fi

# --- build ---------------------------------------------------------------

log "building bundled claude-code-router (Go) ..."
mkdir -p "$REPO_ROOT/bin"
(
  cd "$SUBMODULE"
  go build -ldflags="-s -w" -o "$REPO_ROOT/bin/ccr" .
) || die "Go build failed — check $SUBMODULE for compile errors"

log "ccr binary built: $REPO_ROOT/bin/ccr"

# --- install -------------------------------------------------------------

mkdir -p "$BIN_DIR"
ln -sf "$REPO_ROOT/bin/ccr" "$BIN_DIR/ccr"
log "ccr symlinked: $BIN_DIR/ccr -> $REPO_ROOT/bin/ccr"

# --- verify ---------------------------------------------------------------

if [ -x "$BIN_DIR/ccr" ]; then
  log "ccr is ready."
  "$BIN_DIR/ccr" version 2>/dev/null || true
else
  die "ccr install failed — $BIN_DIR/ccr is not executable"
fi
