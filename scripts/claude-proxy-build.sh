#!/usr/bin/env bash
# claude-proxy-build.sh — build the toolkit's provider-compatibility proxy
# (Go) and install it where the launch wrapper finds it.
#
# `cma-proxy` (scripts/proxy/, module cmaproxy) replaces the former per-provider
# python proxies (poe/kimi/sarvam request-schema fixes + helixagent Hermes
# tool-call recovery). cma_run_provider starts one instance per proxied provider
# as `cma-proxy --provider <id> --port <port>` and points ccr at it; discovery
# uses `cma-proxy --has-transform <id>`.
#
# Idempotent: rebuilds in place and re-copies. Gated on the Go toolchain — with
# no `go` it explains and exits non-zero (install.sh treats it as best-effort so
# install still completes; without the proxy, helixagent/poe/kimi/sarvam aliases
# fall back to their direct endpoint, i.e. their compat shims are INACTIVE).
#
# Env knobs:
#   BIN_DIR   where `cma-proxy` is symlinked (default ~/.local/bin)
set -euo pipefail

# Resolve this script's real dir through any symlinks (install.sh links it into
# ~/.local/bin), the same idiom the other build scripts use.
_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _tgt="$(readlink "$_src")"
  case "$_tgt" in /*) _src="$_tgt" ;; *) _src="$(dirname "$_src")/$_tgt" ;; esac
done
LIB_DIR="$(cd "$(dirname "$_src")" && pwd)"
unset _src _tgt
# shellcheck source=lib.sh
source "$LIB_DIR/lib.sh"

PROXY_SRC="$LIB_DIR/proxy"
if [ ! -f "$PROXY_SRC/go.mod" ]; then
  printf 'claude-proxy-build: %s has no go.mod (unexpected layout).\n' "$PROXY_SRC" >&2
  exit 1
fi

# Vendored Go toolchain (built by claude-go-build.sh), same as claude-ccr-build.
VENDORED_GO="${VENDORED_GO:-$HOME/.local/share/claude-go/bin/go}"
_go_bin="${VENDORED_GO:-go}"
if ! command -v "$_go_bin" >/dev/null 2>&1; then
  _go_bin="go"  # fall back to system Go
fi
if ! command -v "$_go_bin" >/dev/null 2>&1; then
  cma_warn "Go toolchain not found — cannot build the compatibility proxy (cma-proxy)."
  printf '  Install Go (https://go.dev/dl/) then re-run: claude-proxy-build\n  Without it, helixagent/poe/kimi/sarvam aliases run against their direct\n  endpoint and their request/response compat shims are INACTIVE.\n' >&2
  exit 1
fi

# 1. Build scripts/proxy -> bin/cma-proxy.
BIN="$PROXY_SRC/bin/cma-proxy"
cma_log "building compatibility proxy (Go): $(cd "$PROXY_SRC" && "$_go_bin" version 2>/dev/null | awk '{print $3}') ..."
if ! ( cd "$PROXY_SRC" && mkdir -p bin && "$_go_bin" build -o bin/cma-proxy . ); then
  if ( cd "$PROXY_SRC" && GOTOOLCHAIN=auto "$_go_bin" build -o bin/cma-proxy . ); then
    cma_log "GOTOOLCHAIN=auto build succeeded"
  else
    cma_warn "cma-proxy build failed."
    exit 1
  fi
fi

# 2. Install into the shared proxy dir (where the launch wrapper looks) and
#    symlink onto PATH for CLI/`--has-transform` use.
DST_DIR="${SHARED_DIR:-$HOME/.claude-shared}/proxy"
mkdir -p "$DST_DIR"
cp -f "$BIN" "$DST_DIR/cma-proxy"
chmod +x "$DST_DIR/cma-proxy"

BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN_DIR"
ln -sf "$DST_DIR/cma-proxy" "$BIN_DIR/cma-proxy"

cma_log "cma-proxy installed: $DST_DIR/cma-proxy (symlinked $BIN_DIR/cma-proxy)"
# Quick self-check: the discovery gate must answer for a known provider.
if "$DST_DIR/cma-proxy" --has-transform helixagent >/dev/null 2>&1; then
  cma_log "cma-proxy self-check OK (transforms: helixagent + request shims)"
else
  cma_warn "cma-proxy built but --has-transform helixagent did not return 0 (unexpected)"
fi
