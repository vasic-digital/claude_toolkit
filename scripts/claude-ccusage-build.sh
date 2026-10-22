#!/usr/bin/env bash
# claude-ccusage-build.sh — build ccusage from its flat submodule checkout
# and install it as the toolkit's `ccusage`, so claude-usage.sh (and anyone
# else) never depends on `npx ccusage@latest` reaching the npm registry.
#
# WHY RUST, NOT bun/node (read before "fixing" this to shell out to npm):
# ccusage's npm package (submodules/ccusage/apps/ccusage, bin: src/cli.js) is
# a thin Node dispatcher — it locates and execs a PREBUILT per-platform
# native binary shipped as an npm optionalDependency
# (@ccusage/ccusage-<platform>-<arch>, resolved via require.resolve() in
# src/cli.js). The real implementation lives entirely in submodules/ccusage/
# rust/ (a Cargo workspace; crates/ccusage is the `[[bin]] name = "ccusage"`
# target). Building/installing the npm package therefore means FETCHING a
# prebuilt binary from the npm registry — exactly the dependency this script
# exists to avoid. apps/ccusage/scripts/ensure-native-binary.nu (the package's
# own build script) falls back to `cargo build --manifest-path rust/Cargo.toml
# --release --bin ccusage` whenever no matching prebuilt package is found —
# this script does that directly, without the Node/nushell wrapper.
#
# Confirmed by a real build in-session (see scripts/tests/proof or the task
# that produced this script for pasted output): `cargo build --release --bin
# ccusage` from submodules/ccusage/rust produces a working
# `target/release/ccusage` that reports `ccusage 20.0.40` and answers
# `ccusage claude daily --json` against real ~/.claude-shared/projects data.
#
# BUILD-TIME PRICING SNAPSHOT: crates/ccusage-pricing-snapshots/build.rs
# embeds a LiteLLM model_prices_and_context_window.json at build time. It
# reads one of:
#   - $CCUSAGE_PRICING_JSON_PATH, a local copy of that file (no network), or
#   - with the `fetch-litellm-pricing` cargo feature enabled, a one-time HTTPS
#     GET of that exact file from the EXACT commit pinned in the submodule's
#     flake.lock (nodes.litellm.locked.{owner,repo,rev}) via
#     raw.githubusercontent.com — a pinned, verifiable revision, not
#     "latest", and the same revision a Nix build would embed. Cargo's
#     `cargo:rerun-if-changed` caches the build-script output, so this fetch
#     only re-runs when flake.lock changes; every other rebuild is offline.
# This script enables fetch-litellm-pricing unless CCUSAGE_PRICING_JSON_PATH
# is already set, so the FIRST build needs network for this one file and
# every later build (until the next ccusage checkout update) does not.
#
# VENDORED-TOOLCHAIN PATTERN (mirrors claude-ccr-build.sh / claude-proxy-
# build.sh for Go — read the "Go toolchain resolution" section of the repo's
# CLAUDE.md before changing this): prefer a vendored Rust/cargo under
# $HOME/.local/share/claude-rust (an operator-provisioned rustup prefix —
# this toolkit does NOT vendor a from-source Rust bootstrap build the way
# claude-go-build.sh does for Go; rustc's own self-hosted bootstrap is an
# order of magnitude heavier, and auto-downloading a compiler from an alias
# installer is exactly the high-blast-radius move claude-ccr-build.sh's
# header already refuses for Go, for the same reasons), falling back to
# system `cargo`/`rustc` via `command -v`. THE command -v PROBE IS LOAD-
# BEARING, same as in claude-ccr-build.sh/claude-proxy-build.sh:
# VENDORED_CARGO is assigned a path STRING unconditionally below, so it is
# NEVER empty and `${VENDORED_CARGO:-cargo}` alone can never reach its
# `:-cargo` branch — omitting the explicit `command -v` check would exec a
# path that may not exist (exit 127) on a host with no vendored prefix.
#
# Idempotent: re-running rebuilds in place (a cargo no-op when nothing
# changed) and re-points the symlink. With NO Rust toolchain at all: a USABLE
# resident `ccusage` already installed at $BIN_DIR/ccusage gets an honest
# staleness warning and exit 0 (the artifact, not the build prerequisite, is
# what a readiness gate asserts); with no usable resident binary, a hard
# failure with exact install instructions.
#
# Env knobs:
#   BIN_DIR                   where `ccusage` is symlinked (default ~/.local/bin)
#   CCUSAGE_SUBMODULE         path to the ccusage submodule (default REPO_ROOT/submodules/ccusage)
#   VENDORED_RUST_ROOT        vendored Rust prefix (default $HOME/.local/share/claude-rust;
#                             e.g. `rustup`/`cargo` homes set up via
#                             `RUSTUP_HOME=$VENDORED_RUST_ROOT/rustup CARGO_HOME=$VENDORED_RUST_ROOT/cargo
#                             sh rustup-init.sh --default-toolchain none`)
#   VENDORED_CARGO            vendored cargo binary (default $VENDORED_RUST_ROOT/cargo/bin/cargo)
#   CCUSAGE_PRICING_JSON_PATH path to a local LiteLLM model_prices_and_context_window.json
#                             (set this to skip the build-time network fetch)

set -euo pipefail

# Resolve this script's real dir through any symlinks (install.sh links it
# into ~/.local/bin), the same idiom the other build scripts use.
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
SUBMODULE="${CCUSAGE_SUBMODULE:-$REPO_ROOT/submodules/ccusage}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
RESIDENT="$BIN_DIR/ccusage"

# Bounded probe: is the resident ccusage (if any) usable? Same discriminator
# shape as claude-ccr-build.sh's "ccr restart" check — probe the FILE, don't
# just trust its presence, and never let a wedged binary hang this script
# (cma_probe_help returns 124 on a timeout).
_resident_usable() {
  [ -x "$RESIDENT" ] || return 1
  local _rrc=0 _rhelp
  _rhelp="$(cma_probe_help "$RESIDENT")" || _rrc=$?
  [ "$_rrc" -eq 124 ] && return 1
  case "$_rhelp" in
    *"ccusage"*|*"USAGE"*) return 0 ;;
    *) return 1 ;;
  esac
}

# 1. Ensure the submodule is checked out. Only auto-init the REAL repo path —
# a CCUSAGE_SUBMODULE override pointing elsewhere (e.g. a test fixture) must
# never be "fixed" by silently initialising the actual submodules/ccusage.
if [ ! -f "$SUBMODULE/rust/Cargo.toml" ] || [ ! -f "$SUBMODULE/apps/ccusage/package.json" ]; then
  if [ "$SUBMODULE" = "$REPO_ROOT/submodules/ccusage" ]; then
    cma_log "ccusage submodule not fully checked out — initialising..."
    git -C "$REPO_ROOT" submodule update --init submodules/ccusage 2>/dev/null || true
  fi
  if [ ! -f "$SUBMODULE/rust/Cargo.toml" ] || [ ! -f "$SUBMODULE/apps/ccusage/package.json" ]; then
    printf 'claude-ccusage-build: %s is missing/incomplete (no rust/Cargo.toml or apps/ccusage/package.json).\n  Run: git -C %s submodule update --init submodules/ccusage\n' "$SUBMODULE" "$REPO_ROOT" >&2
    exit 1
  fi
fi
RUST_DIR="$SUBMODULE/rust"
if [ ! -f "$RUST_DIR/Cargo.toml" ]; then
  printf 'claude-ccusage-build: %s has no Cargo.toml (unexpected ccusage layout).\n' "$RUST_DIR" >&2
  exit 1
fi

# 2. Resolve a Rust toolchain: vendored first, system fallback — see header.
VENDORED_RUST_ROOT="${VENDORED_RUST_ROOT:-$HOME/.local/share/claude-rust}"
VENDORED_CARGO="${VENDORED_CARGO:-$VENDORED_RUST_ROOT/cargo/bin/cargo}"
_cargo_bin="${VENDORED_CARGO:-cargo}"
_using_vendored=0
if command -v "$_cargo_bin" >/dev/null 2>&1; then
  _using_vendored=1
else
  _cargo_bin="cargo"   # fall back to system cargo
fi
if ! command -v "$_cargo_bin" >/dev/null 2>&1; then
  if _resident_usable; then
    cma_warn "no Rust/cargo toolchain found — cannot REBUILD ccusage.
  The existing binary at $RESIDENT verified usable, so this install keeps working.
  It WILL GO STALE on the next ccusage checkout update until Rust is installed:
    rustup (recommended, no sudo):
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
    Debian/Ubuntu:  sudo apt install cargo rustc
    Fedora/RHEL:    sudo dnf install cargo rust
    Arch:           sudo pacman -S rust
    macOS:          brew install rust
  then re-run: claude-ccusage-build"
    exit 0
  fi
  cma_warn "Rust/cargo toolchain not found — cannot build ccusage."
  printf '  Install Rust, then re-run: claude-ccusage-build\n    rustup (recommended, no sudo):\n      curl --proto '"'"'=https'"'"' --tlsv1.2 -sSf https://sh.rustup.rs | sh\n    Debian/Ubuntu:  sudo apt install cargo rustc\n    Fedora/RHEL:    sudo dnf install cargo rust\n    Arch:           sudo pacman -S rust\n    macOS:          brew install rust\n' >&2
  exit 1
fi

# 3. Build. ccusage's rust-toolchain.toml pins an exact channel; a rustup-
# managed cargo (vendored or system) auto-installs it. A non-rustup system
# cargo (e.g. a distro package) will use whatever it has — if that is too
# old for this workspace's edition/MSRV, the compiler error below says so.
_features=()
if [ -z "${CCUSAGE_PRICING_JSON_PATH:-}" ]; then
  _features=(--features fetch-litellm-pricing)
fi
BIN="$RUST_DIR/target/release/ccusage"
# A rustup-proxy cargo/rustc (vendored OR system) needs RUSTUP_HOME/CARGO_HOME
# to find ITS OWN install prefix; without them it falls back to the default
# ~/.rustup + ~/.cargo, which — for a vendored prefix set up at a NON-default
# location — has no toolchain installed and fails opaquely ("could not
# execute process `rustc -vV`"). Only set these for the vendored branch, and
# only if the caller has not already set them (an explicit override wins).
# Set BEFORE the first "$_cargo_bin" invocation (the version probe below),
# not just before the build, or that probe silently prints nothing.
if [ "$_using_vendored" = "1" ]; then
  : "${RUSTUP_HOME:=$VENDORED_RUST_ROOT/rustup}"
  : "${CARGO_HOME:=$VENDORED_RUST_ROOT/cargo}"
  export RUSTUP_HOME CARGO_HOME
fi
# Probe --version from INSIDE $RUST_DIR, not cwd: a rustup-managed cargo
# with no configured default toolchain resolves one only via the directory's
# rust-toolchain.toml override, and errors ("could not choose a version of
# cargo to run") anywhere else.
cma_log "building ccusage (Rust): $(cd "$RUST_DIR" && "$_cargo_bin" --version 2>/dev/null) ..."
if ! ( cd "$RUST_DIR" && "$_cargo_bin" build --release --bin ccusage "${_features[@]}" ); then
  if _resident_usable; then
    cma_warn "ccusage build FAILED (see cargo output above).
  The existing binary at $RESIDENT verified usable, so this install keeps working.
  It WILL GO STALE on the next ccusage checkout update until the build succeeds.
  Re-run to see the failure in full: claude-ccusage-build"
    exit 0
  fi
  printf 'claude-ccusage-build: cargo build failed in %s\n' "$RUST_DIR" >&2
  exit 1
fi

# 4. Self-check: the built binary must actually run and report the expected
# program name (catches e.g. a workspace member mix-up silently naming a
# different [[bin]] "ccusage" wrong binary path).
if [ ! -x "$BIN" ]; then
  printf 'claude-ccusage-build: build reported success but %s is missing.\n' "$BIN" >&2
  exit 1
fi
_ver="$("$BIN" --version 2>&1 || true)"
case "$_ver" in
  ccusage\ *) : ;;
  *)
    printf 'claude-ccusage-build: built binary failed its self-check — `%s --version` printed %q, not "ccusage <version>".\n' "$BIN" "$_ver" >&2
    exit 1
    ;;
esac

# 5. Symlink it onto PATH as `ccusage`, backing up any pre-existing DIFFERENT
# binary so nothing is silently clobbered (same pattern as claude-ccr-build.sh).
mkdir -p "$BIN_DIR"
LINK="$RESIDENT"
if [ -L "$LINK" ] && [ "$(cma_realpath "$LINK" 2>/dev/null)" = "$(cma_realpath "$BIN" 2>/dev/null)" ]; then
  : # already ours — nothing to do
elif [ -e "$LINK" ] || [ -L "$LINK" ]; then
  _bak="${LINK}.preccusage.$(date +%Y%m%d%H%M%S)"
  mv "$LINK" "$_bak"
  cma_warn "backed up existing $LINK -> $_bak"
fi
ln -sf "$BIN" "$LINK"
cma_log "installed ccusage ($_ver): $LINK -> $BIN"
