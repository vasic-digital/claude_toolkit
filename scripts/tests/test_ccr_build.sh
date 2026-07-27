#!/usr/bin/env bash
# test_ccr_build.sh — claude-ccr-build.sh builds the BUNDLED Go
# claude-code-router (submodule) and installs it as `ccr`, so provider aliases
# route through OUR vendored router rather than a separately-installed Node one.
#
# This test verifies the script's contract and its wiring into install.sh and
# lib.sh (structural + bash syntax). The go-PRESENT end-to-end build (git
# submodule + go build + symlink + `ccr --help`) needs the Go toolchain and a
# checked-out submodule, so it is exercised by the live proof / run-proof.sh,
# not this hermetic unit test.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
set +e

BUILD="$SCRIPTS_DIR/claude-ccr-build.sh"

it "claude-ccr-build.sh exists and is executable"
assert_file "$BUILD"
if [[ -x "$BUILD" ]]; then _pass "executable"; else _fail "not executable" "$BUILD"; fi

it "has valid bash syntax"
assert_exit 0 bash -n "$BUILD"

it "builds ./cmd/ccr into the submodule bin and self-checks the router grammar"
assert_file_contains "$BUILD" 'go build -o bin/ccr ./cmd/ccr'
assert_file_contains "$BUILD" 'ccr start' # self-check mirrors lib.sh's identity guard
assert_file_contains "$BUILD" 'ccr serve'

it "initialises the submodule when it is not checked out"
assert_file_contains "$BUILD" 'submodule update --init'

it "guards on a missing Go toolchain (best-effort, non-fatal to install)"
assert_file_contains "$BUILD" 'command -v go'
assert_file_contains "$BUILD" 'Go toolchain not found'

it "installs ccr onto PATH as a symlink, backing up a pre-existing different ccr"
assert_file_contains "$BUILD" 'ln -sf "$BIN" "$LINK"'
assert_file_contains "$BUILD" 'preccr'

it "install.sh builds the bundled router (best-effort) during install"
assert_file_contains "$SCRIPTS_DIR/install.sh" 'claude-ccr-build.sh'

it "lib.sh's provider-router guidance points at the bundled build"
assert_file_contains "$SCRIPTS_DIR/lib.sh" 'claude-ccr-build'

it ".gitmodules registers the claude-code-router submodule"
assert_file_contains "$REPO_ROOT/.gitmodules" 'submodules/claude-code-router'

it "go.mod carries no patch-level toolchain pin (field failure 2026-07-25)"
# A patch-pinned `go 1.26.4` directive plus a host toolchain one patch behind
# (go1.26.2) plus GOTOOLCHAIN=local = the build REFUSES
# ("go.mod requires go >= 1.26.4") and every router-transport provider alias
# dies at install. Patch releases never add language features, so the
# directive must stay at major.minor granularity: any toolchain within the
# same minor line can always build the vendored router.
gomod="$REPO_ROOT/submodules/claude-code-router/go.mod"
if [[ -f "$gomod" ]]; then
  directive="$(awk '/^go[ \t]+[0-9]/ {print $2; exit}' "$gomod")"
  if [[ "$directive" =~ ^[0-9]+\.[0-9]+$ ]]; then
    _pass "go directive is major.minor only ($directive)"
  else
    _fail "go directive carries a patch pin" "go.mod has 'go $directive' — must be major.minor (e.g. 1.26), else older same-minor toolchains with GOTOOLCHAIN=local cannot build"
  fi
else
  _fail "go.mod not found" "$gomod (submodule not checked out?)"
fi

it "both build entrypoints advise on toolchain version skew"
# The failure text must name BOTH remedies (GOTOOLCHAIN=auto, or upgrade Go) —
# a bare "install Go" is a false diagnosis when Go is present but too old.
assert_file_contains "$SCRIPTS_DIR/claude-ccr-build.sh" 'GOTOOLCHAIN=auto'
assert_file_contains "$SCRIPTS_DIR/ccr-install.sh" 'GOTOOLCHAIN=auto'

summary
