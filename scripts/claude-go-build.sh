#!/usr/bin/env bash
# claude-go-build.sh — build the VENDORED Go toolchain from the submodule
# and install it as the project's local Go toolchain.
#
# This script builds Go from source using the submodule at submodules/go.
# It uses the system Go as the bootstrap compiler, then installs the
# resulting toolchain locally for use by claude-ccr-build and claude-proxy-build.
#
# Env knobs:
#   GO_SUBMODULE   path to Go submodule (default: REPO_ROOT/submodules/go)
#   GO_INSTALL_DIR where to install the built toolchain (default: ~/.local/share/claude-go)
#   BOOTSTRAP_GO   bootstrap Go binary (default: system 'go' on PATH)

set -euo pipefail

# Resolve this script's real dir through any symlinks (install.sh links it into ~/.local/bin).
_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _tgt="$(readlink "$_src")"
  case "$_tgt" in /*) _src="$_tgt" ;; *) _src="$(dirname "$_src")/$_tgt" ;; esac
done
LIB_DIR="$(cd "$(dirname "$_src")" && pwd)"
unset _src _tgt
# shellcheck source=lib.sh
source "$LIB_DIR/lib.sh"

REPO_ROOT="$(cd "$LIB_DIR/.." && pwd)"
GO_SUBMODULE="${GO_SUBMODULE:-$REPO_ROOT/submodules/go}"
GO_INSTALL_DIR="${GO_INSTALL_DIR:-$HOME/.local/share/claude-go}"
BOOTSTRAP_GO="${BOOTSTRAP_GO:-$(command -v go)}"

cma_log "building vendored Go toolchain from $GO_SUBMODULE"

# 1. Ensure the submodule is checked out at the right version.
if [ ! -f "$GO_SUBMODULE/src/Makefile" ] || [ ! -f "$GO_SUBMODULE/VERSION" ]; then
  cma_log "Go submodule not fully checked out — initialising..."
  if ! git -C "$REPO_ROOT" submodule update --init --recursive submodules/go 2>/dev/null; then
    printf 'claude-go-build: submodule submodules/go is missing and could not be initialised.\n  Run: git -C %s submodule update --init --recursive\n' "$REPO_ROOT" >&2
    exit 1
  fi
fi

# 2. Determine the target version from the submodule's VERSION file.
# The VERSION file contains "go1.26.4time 2026-05-29T15:26:39Z" but the binary reports "1.26.4".
_target_raw="$(cat "$GO_SUBMODULE/VERSION" 2>/dev/null | tr -d '\n')"
_target_version="${_target_raw#go}"  # strip leading 'go'
_target_version="${_target_version%%time*}"  # strip "time 2026..."
_target_version="${_target_version%% *}"  # strip any trailing space
if [ -z "$_target_version" ]; then
  printf 'claude-go-build: could not parse VERSION from %s\n' "$GO_SUBMODULE" >&2
  exit 1
fi
cma_log "target Go version: $_target_version"

# 3. Check if already built and installed.
_go_bin="$GO_INSTALL_DIR/bin/go"
if [ -x "$_go_bin" ]; then
  _installed_version="$("$_go_bin" version 2>/dev/null | awk '{print $3}' | sed 's/^go//')"
  if [ "$_installed_version" = "$_target_version" ]; then
    cma_log "vendored Go $_target_version already installed at $GO_INSTALL_DIR"
    printf '%s\n' "$_go_bin"
    exit 0
  fi
  cma_log "installed version ($_installed_version) differs from target ($_target_version) — rebuilding"
fi

# 4. Require a bootstrap Go toolchain.
if [ -z "$BOOTSTRAP_GO" ] || ! command -v "$BOOTSTRAP_GO" >/dev/null 2>&1; then
  printf 'claude-go-build: no bootstrap Go toolchain found.\n  Install Go (>= 1.20) or set BOOTSTRAP_GO to a suitable binary.\n' >&2
  exit 1
fi
_bootstrap_version="$("$BOOTSTRAP_GO" version 2>/dev/null | awk '{print $3}' | sed 's/^go//')"
cma_log "bootstrap Go: $_bootstrap_version (from $BOOTSTRAP_GO)"

# 5. Build Go from source.
# The Go source build process: cd src && ./make.bash (or ./all.bash for tests).
# We only need the toolchain, so make.bash is sufficient.
cd "$GO_SUBMODULE/src"
cma_log "building Go $_target_version (this may take several minutes)..."
if ! ./make.bash; then
  printf 'claude-go-build: Go build failed in %s/src\n' "$GO_SUBMODULE" >&2
  exit 1
fi

# 6. Install the built toolchain.
# The built binaries are in ../bin/ and ../pkg/.
# We'll copy the entire GOROOT structure to the install dir.
mkdir -p "$GO_INSTALL_DIR"
# Remove any existing installation.
rm -rf "$GO_INSTALL_DIR"/bin "$GO_INSTALL_DIR"/pkg "$GO_INSTALL_DIR"/src "$GO_INSTALL_DIR"/VERSION "$GO_INSTALL_DIR"/api "$GO_INSTALL_DIR"/doc "$GO_INSTALL_DIR"/test "$GO_INSTALL_DIR"/lib "$GO_INSTALL_DIR"/misc "$GO_INSTALL_DIR"/go.env
# Copy the built toolchain (from the submodule root, not src/).
cd "$GO_SUBMODULE"
cp -r bin pkg src VERSION api doc test lib misc go.env "$GO_INSTALL_DIR/" 2>/dev/null || true

# 7. Verify the installation.
if [ ! -x "$_go_bin" ]; then
  printf 'claude-go-build: installed Go binary not found at %s\n' "$_go_bin" >&2
  exit 1
fi
_installed_raw="$("$_go_bin" version 2>/dev/null | awk '{print $3}' | sed 's/^go//')"
if [ "$_installed_raw" != "$_target_version" ]; then
  printf 'claude-go-build: version mismatch — expected %s, got %s\n' "$_target_version" "$_installed_raw" >&2
  exit 1
fi

cma_log "vendored Go $_target_version installed successfully at $GO_INSTALL_DIR"
printf '%s\n' "$_go_bin"