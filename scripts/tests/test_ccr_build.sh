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
assert_file_contains "$BUILD" 'build -o bin/ccr ./cmd/ccr'
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
#
# EXCEPTION: when a vendored Go toolchain (built from the Go submodule at
# submodules/go by claude-go-build.sh) is available, the patch-level pin
# is harmless because the vendored toolchain matches the required version
# exactly. The GOTOOLCHAIN=auto retry also handles this case.
gomod="$REPO_ROOT/submodules/claude-code-router/go.mod"
if [[ -f "$gomod" ]]; then
  directive="$(awk '/^go[ \t]+[0-9]/ {print $2; exit}' "$gomod")"
  if [[ "$directive" =~ ^[0-9]+\.[0-9]+$ ]]; then
    _pass "go directive is major.minor only ($directive)"
  elif [[ -x "${REAL_HOME:-$HOME}/.local/share/claude-go/bin/go" ]] || [[ -f "$REPO_ROOT/scripts/claude-go-build.sh" ]]; then
    _pass "go directive has patch pin ($directive) but vendored Go toolchain is available"
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

# ---------------------------------------------------------------------------
# Vendored-Go fallback (field failure 2026-07-27, v1.26.6)
#
# `VENDORED_GO="${VENDORED_GO:-$HOME/.local/share/claude-go/bin/go}"` assigns a
# PATH STRING, not a found binary — it is non-empty whether or not that file
# exists. So the very next `_go_bin="${VENDORED_GO:-go}"` can NEVER take its
# `:-go` branch, and the "fall back to system Go" the comment promises is
# unreachable. install.sh only SYMLINKS claude-go-build (building Go from
# source is deliberately opt-in, see the DECISION block in claude-ccr-build.sh),
# so ~/.local/share/claude-go does not exist on a normal install and the build
# exec'd a missing file: exit 127, "No such file or directory" x2, then a
# FACTUALLY FALSE "(Go version mismatch?)" on a host whose Go was already the
# exact required 1.26.4. claude-proxy-build.sh survived the same two lines only
# because it adds a `command -v` existence guard — the one-line difference.
# ---------------------------------------------------------------------------

it "resolves the vendored Go path through an existence guard (not a bare default)"
# Mirrors claude-proxy-build.sh: a path string must be probed before it is exec'd.
assert_file_contains "$BUILD" 'command -v "$_go_bin"'

it "keeps the proxy build's guard too (the reference implementation)"
assert_file_contains "$SCRIPTS_DIR/claude-proxy-build.sh" 'command -v "$_go_bin"'

it "builds with system Go when the vendored toolchain is absent"
# Behavioural: the structural assert above proves the guard is WRITTEN; this
# proves it WORKS. Runs the real script against a deliberately nonexistent
# VENDORED_GO. BIN_DIR follows the sandbox $HOME, so nothing outside is touched.
if ! command -v go >/dev/null 2>&1; then
  _pass "skipped: no system Go on this host"
elif [[ ! -f "$REPO_ROOT/submodules/claude-code-router/go.mod" ]]; then
  _pass "skipped: claude-code-router submodule not checked out"
else
  out="$(VENDORED_GO="$HOME/definitely-not-here/bin/go" bash "$BUILD" 2>&1)"; rc=$?
  case "$out" in
    *"No such file or directory"*)
      _fail "exec'd the absent vendored toolchain" "$(printf '%s' "$out" | grep -m2 'No such file')" ;;
    *) _pass "no exec-not-found against the vendored path" ;;
  esac
  if [[ $rc -eq 0 ]]; then _pass "exit 0"; else _fail "build exited $rc" "$out"; fi
  if [[ -x "$HOME/.local/bin/ccr" ]]; then _pass "installed ccr into the sandbox"
  else _fail "no ccr installed" "$HOME/.local/bin/ccr missing"; fi
fi

# ---------------------------------------------------------------------------
# Go-toolchain RESOLUTION MATRIX
#
# The block above proves ONE cell: an explicitly-passed bogus VENDORED_GO falls
# back. That is not the cell the field failure lived in — the bug was in the
# script's OWN DEFAULT (`$HOME/.local/share/claude-go/bin/go`, injected when
# VENDORED_GO is unset), which is exactly what a normal install hits. Every row
# below therefore runs with VENDORED_GO UNSET (`env -u`) and manipulates the
# default path itself, so the resolution logic is exercised through the same
# door the user comes in.
#
# Each row asserts WHICH toolchain actually ran, not merely that the script
# exited 0: the vendored stub appends its argv to a log and then delegates to
# the real system go, so "vendored was chosen" and "system was chosen" are
# distinguishable facts rather than an inference from a green exit code.
# ---------------------------------------------------------------------------

SYS_GO="$(command -v go 2>/dev/null || true)"
PROXY_BUILD="$SCRIPTS_DIR/claude-proxy-build.sh"
# The script's own default, spelled out here so the test breaks loudly if the
# default path is ever moved without the matrix following it.
VGO_DIR="$HOME/.local/share/claude-go/bin"
VGO="$VGO_DIR/go"
VGO_LOG="$HOME/vendored-go-invocations.log"

MATRIX_READY=1
[[ -n "$SYS_GO" ]] || MATRIX_READY=0
[[ -f "$REPO_ROOT/submodules/claude-code-router/go.mod" ]] || MATRIX_READY=0

# _install_vendored_stub — write an executable fake `go` at the script's default
# vendored path. It records every invocation, then execs the REAL system go, so
# a run that picks it up still produces a genuine build artifact.
_install_vendored_stub() {
  sandbox_stub "$VGO" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$VGO_LOG"
exec "$SYS_GO" "\$@"
EOF
}

# _matrix_skip MSG — one honest, clearly-labelled skip line (never a silent
# green): the row did not run, and says so.
_matrix_skip() {
  _pass "SKIPPED (prereq unmet): $1"
}

# _assert_no_exec_failure OUT — the failure signature of the original bug.
# exit 127 / ENOENT / EACCES / EISDIR all mean the resolved path was exec'd
# without being probed first.
_assert_no_exec_failure() {
  local out="$1"
  case "$out" in
    *"No such file or directory"*) _fail "exec'd a nonexistent toolchain" "$(printf '%s' "$out" | grep -m1 'No such file')" ;;
    *"Permission denied"*)         _fail "exec'd a non-executable toolchain" "$(printf '%s' "$out" | grep -m1 'Permission denied')" ;;
    *"Is a directory"*)            _fail "exec'd a directory as a toolchain" "$(printf '%s' "$out" | grep -m1 'Is a directory')" ;;
    *"command not found"*)         _fail "resolved toolchain not found" "$(printf '%s' "$out" | grep -m1 'command not found')" ;;
    *) _pass "no exec-resolution failure in output" ;;
  esac
}

# ---- structural: the guard must sit BETWEEN the assignment and the first use --
#
# `assert_file_contains 'command -v "$_go_bin"'` (above) proves the guard EXISTS
# somewhere in the file. It does not prove it runs before the binary is exec'd —
# a guard added after the first use would satisfy that assert and still ship the
# bug. Compare line numbers instead.
_assert_guard_placement() {
  local f="$1" name assign guard use
  name="$(basename "$f")"
  assign="$(grep -nF '_go_bin="${VENDORED_GO' "$f" | head -1 | cut -d: -f1)"
  guard="$(grep -nF 'command -v "$_go_bin"' "$f" | head -1 | cut -d: -f1)"
  use="$(grep -nF '"$_go_bin"' "$f" | grep -vF 'command -v' | grep -v '^[0-9]*:[[:space:]]*#' | head -1 | cut -d: -f1)"
  if [[ -z "$assign" ]]; then
    _fail "$name: no _go_bin assignment from VENDORED_GO" "grep found no '_go_bin=\${VENDORED_GO'"
  elif [[ -z "$guard" ]]; then
    _fail "$name: no existence guard on \$_go_bin" "the dead-default bug is back"
  elif [[ -z "$use" ]]; then
    _fail "$name: \$_go_bin is never used" "matrix cannot be verified against this file"
  elif (( guard > assign && guard < use )); then
    _pass "$name: guard at L$guard sits between assign L$assign and first use L$use"
  else
    _fail "$name: guard is misplaced" "assign=L$assign guard=L$guard first-use=L$use (need assign < guard < use)"
  fi
}

it "the existence guard runs BEFORE the resolved toolchain is exec'd"
_assert_guard_placement "$BUILD"
_assert_guard_placement "$PROXY_BUILD"

it "every script defaulting VENDORED_GO carries the guard (repo-wide lint)"
# Catches a future THIRD build script copying the two dead lines without the
# third. Also counts the matches, so an accidental zero-match glob cannot make
# this lint pass vacuously.
_lint_seen=0 _lint_missing=""
for _f in "$SCRIPTS_DIR"/*.sh; do
  grep -qF '_go_bin="${VENDORED_GO' "$_f" 2>/dev/null || continue
  _lint_seen=$((_lint_seen + 1))
  grep -qF 'command -v "$_go_bin"' "$_f" 2>/dev/null \
    || _lint_missing="$_lint_missing $(basename "$_f")"
done
if (( _lint_seen < 2 )); then
  _fail "lint scanned too few files" "expected >=2 VENDORED_GO consumers, saw $_lint_seen (glob broken? scripts renamed?)"
elif [[ -z "$_lint_missing" ]]; then
  _pass "all $_lint_seen VENDORED_GO consumers guard the resolved path"
else
  _fail "unguarded VENDORED_GO consumer(s)" "$_lint_missing"
fi

# ---- behavioural rows ------------------------------------------------------

it "row 1/6: default vendored path ABSENT -> system Go, build succeeds"
if (( ! MATRIX_READY )); then
  _matrix_skip "needs system Go + a checked-out claude-code-router submodule"
else
  rm -rf "$HOME/.local/share/claude-go" "$VGO_LOG"
  rm -f "$HOME/.local/bin/ccr"
  if [[ -e "$VGO" ]]; then _fail "precondition" "$VGO should not exist"; else _pass "precondition: default vendored path absent"; fi
  out="$(env -u VENDORED_GO bash "$BUILD" 2>&1)"; rc=$?
  _assert_no_exec_failure "$out"
  if [[ $rc -eq 0 ]]; then _pass "exit 0"; else _fail "build exited $rc" "$out"; fi
  if [[ -x "$HOME/.local/bin/ccr" ]]; then _pass "system Go produced and installed ccr"
  else _fail "no ccr installed" "$HOME/.local/bin/ccr missing"; fi
  if [[ -f "$VGO_LOG" ]]; then _fail "vendored stub ran" "no stub was installed for this row"
  else _pass "no vendored toolchain was invoked"; fi
fi

it "row 2/6: default vendored path EXISTS + executable -> PREFERRED over system Go"
if (( ! MATRIX_READY )); then
  _matrix_skip "needs system Go + a checked-out claude-code-router submodule"
else
  _install_vendored_stub
  rm -f "$VGO_LOG" "$HOME/.local/bin/ccr"
  out="$(env -u VENDORED_GO bash "$BUILD" 2>&1)"; rc=$?
  _assert_no_exec_failure "$out"
  if [[ $rc -eq 0 ]]; then _pass "exit 0"; else _fail "build exited $rc" "$out"; fi
  if [[ -f "$VGO_LOG" ]]; then _pass "vendored toolchain was invoked"
  else _fail "vendored toolchain NOT chosen" "system Go won despite an executable $VGO"; fi
  # Not just "invoked" — invoked for the BUILD, i.e. it is the toolchain that
  # produced the artifact, not merely the one asked for `go version`.
  if grep -qF 'build -o bin/ccr ./cmd/ccr' "$VGO_LOG" 2>/dev/null; then
    _pass "vendored toolchain ran the ccr build itself"
  else
    _fail "vendored toolchain did not run the build" "log: $(cat "$VGO_LOG" 2>/dev/null | tr '\n' ';')"
  fi
  if [[ -x "$HOME/.local/bin/ccr" ]]; then _pass "installed ccr into the sandbox"
  else _fail "no ccr installed" "$HOME/.local/bin/ccr missing"; fi
fi

it "row 3/6: explicit VENDORED_GO pointing at a real binary still wins (env knob)"
if (( ! MATRIX_READY )); then
  _matrix_skip "needs system Go + a checked-out claude-code-router submodule"
else
  _install_vendored_stub
  rm -f "$VGO_LOG" "$HOME/.local/bin/ccr"
  out="$(VENDORED_GO="$VGO" bash "$BUILD" 2>&1)"; rc=$?
  _assert_no_exec_failure "$out"
  if [[ $rc -eq 0 ]]; then _pass "exit 0"; else _fail "build exited $rc" "$out"; fi
  if grep -qF 'build -o bin/ccr ./cmd/ccr' "$VGO_LOG" 2>/dev/null; then
    _pass "explicitly-set toolchain ran the build"
  else
    _fail "explicit VENDORED_GO ignored" "log: $(cat "$VGO_LOG" 2>/dev/null | tr '\n' ';')"
  fi
fi

it "row 4/6: vendored path exists but is NOT executable -> system Go, no EACCES"
if (( ! MATRIX_READY )); then
  _matrix_skip "needs system Go + a checked-out claude-code-router submodule"
else
  _install_vendored_stub
  chmod -x "$VGO"
  rm -f "$VGO_LOG" "$HOME/.local/bin/ccr"
  if [[ -e "$VGO" && ! -x "$VGO" ]]; then _pass "precondition: $VGO exists, mode -x"
  else _fail "precondition" "could not make $VGO non-executable"; fi
  out="$(env -u VENDORED_GO bash "$BUILD" 2>&1)"; rc=$?
  _assert_no_exec_failure "$out"
  if [[ $rc -eq 0 ]]; then _pass "exit 0"; else _fail "build exited $rc" "$out"; fi
  if [[ -f "$VGO_LOG" ]]; then _fail "ran the non-executable stub" "impossible unless the guard was bypassed"
  else _pass "fell back: the non-executable path was never invoked"; fi
  if [[ -x "$HOME/.local/bin/ccr" ]]; then _pass "system Go produced and installed ccr"
  else _fail "no ccr installed" "$HOME/.local/bin/ccr missing"; fi
fi

it "row 5/6: vendored path exists but is a DIRECTORY -> system Go, no EISDIR"
if (( ! MATRIX_READY )); then
  _matrix_skip "needs system Go + a checked-out claude-code-router submodule"
else
  rm -rf "$VGO" "$VGO_LOG" "$HOME/.local/bin/ccr"
  mkdir -p "$VGO"
  if [[ -d "$VGO" ]]; then _pass "precondition: $VGO is a directory"
  else _fail "precondition" "could not make $VGO a directory"; fi
  out="$(env -u VENDORED_GO bash "$BUILD" 2>&1)"; rc=$?
  _assert_no_exec_failure "$out"
  if [[ $rc -eq 0 ]]; then _pass "exit 0"; else _fail "build exited $rc" "$out"; fi
  if [[ -x "$HOME/.local/bin/ccr" ]]; then _pass "system Go produced and installed ccr"
  else _fail "no ccr installed" "$HOME/.local/bin/ccr missing"; fi
  rm -rf "$VGO"
fi

it "row 6/6: claude-proxy-build.sh resolves identically (reference implementation)"
# Parity is asserted BEHAVIOURALLY, not only by the shared grep above: the two
# scripts are the only consumers of this idiom, and a divergence in either
# direction is the regression. Both halves of the matrix are checked here.
if [[ -z "$SYS_GO" ]]; then
  _matrix_skip "no system Go on this host"
elif [[ ! -f "$SCRIPTS_DIR/proxy/go.mod" ]]; then
  _matrix_skip "scripts/proxy has no go.mod"
else
  # (a) default vendored path absent -> falls back to system Go
  rm -rf "$HOME/.local/share/claude-go" "$VGO_LOG"
  rm -f "$SHARED_DIR/proxy/cma-proxy"
  out="$(env -u VENDORED_GO bash "$PROXY_BUILD" 2>&1)"; rc=$?
  _assert_no_exec_failure "$out"
  if [[ $rc -eq 0 ]]; then _pass "proxy: exit 0 with vendored path absent"; else _fail "proxy build exited $rc" "$out"; fi
  if [[ -x "$SHARED_DIR/proxy/cma-proxy" ]]; then _pass "proxy: system Go produced cma-proxy"
  else _fail "proxy: no cma-proxy" "$SHARED_DIR/proxy/cma-proxy missing"; fi
  # (b) default vendored path present + executable -> preferred
  _install_vendored_stub
  rm -f "$VGO_LOG" "$SHARED_DIR/proxy/cma-proxy"
  out="$(env -u VENDORED_GO bash "$PROXY_BUILD" 2>&1)"; rc=$?
  _assert_no_exec_failure "$out"
  if [[ $rc -eq 0 ]]; then _pass "proxy: exit 0 with vendored path present"; else _fail "proxy build exited $rc" "$out"; fi
  if grep -qF 'build -o bin/cma-proxy' "$VGO_LOG" 2>/dev/null; then
    _pass "proxy: vendored toolchain ran the cma-proxy build"
  else
    _fail "proxy: vendored toolchain not preferred" "log: $(cat "$VGO_LOG" 2>/dev/null | tr '\n' ';')"
  fi
fi

summary
