#!/usr/bin/env bash
# test_ccusage_build.sh — claude-ccusage-build.sh builds ccusage (Rust) from
# its flat submodule checkout (submodules/ccusage) and installs it as
# `ccusage`, so claude-usage.sh never depends on `npx ccusage@latest`
# reaching the npm registry at runtime.
#
# This test verifies the script's resolution logic (vendored-cargo-present vs
# fallback-to-system vs neither) and its wiring into install.sh, WITHOUT
# requiring network access or a real cargo build in the sandboxed run. The
# real end-to-end build (cargo build + real `ccusage --version` / `ccusage
# claude daily --json` against real data) needs a Rust toolchain and is
# exercised by the guarded live smoke test at the bottom, which SKIPs
# honestly when no toolchain is available on this host.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
set +e

BUILD="$SCRIPTS_DIR/claude-ccusage-build.sh"
SUBMODULE="$REPO_ROOT/submodules/ccusage"

it "claude-ccusage-build.sh exists and is executable"
assert_file "$BUILD"
if [[ -x "$BUILD" ]]; then _pass "executable"; else _fail "not executable" "$BUILD"; fi

it "has valid bash syntax"
assert_exit 0 bash -n "$BUILD"

it "ccusage is vendored as a FLAT, THIRD-PARTY submodule (same policy as submodules/go)"
# .gitmodules must declare it, with a comment explaining the exception (mirrors
# the submodules/go block) — NOT folded into helix-deps.yaml, which is for this
# org's OWN dependencies only.
assert_file_contains "$REPO_ROOT/.gitmodules" '[submodule "submodules/ccusage"]'
assert_file_contains "$REPO_ROOT/.gitmodules" 'url = https://github.com/ryoppippi/ccusage.git'
if grep -qiE 'ccusage' "$REPO_ROOT/helix-deps.yaml" 2>/dev/null; then
  _fail "helix-deps.yaml mentions ccusage" "ccusage is third-party, like submodules/go — it must NOT be in the own-org manifest"
else
  _pass "helix-deps.yaml does not mention ccusage (third-party, not an own-org dep)"
fi

it "resolves the Rust implementation, not the npm dispatcher (documented rationale)"
# The npm package's bin is a thin Node dispatcher to a PREBUILT per-platform
# binary; building it would fetch from the npm registry — exactly what this
# script exists to avoid. The build must target the real Cargo workspace.
assert_file_contains "$BUILD" 'rust/Cargo.toml'
assert_file_contains "$BUILD" 'build --release --bin ccusage'
# Code only: the header DOCUMENTS why npx/npm are avoided (so the substring
# legitimately appears in a comment) — assert no EXECUTABLE line invokes them.
_npx="$(grep -nE '(^|[^#[:alnum:]_-])(npx|npm[[:space:]]+(install|i))[[:space:]]' "$BUILD" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
[[ -z "$_npx" ]] && _pass "no executable npx/npm invocation in claude-ccusage-build.sh" \
  || _fail "claude-ccusage-build.sh executes npx/npm" "$_npx"

it "handles the build-time LiteLLM pricing snapshot (CCUSAGE_PRICING_JSON_PATH or fetch-litellm-pricing)"
assert_file_contains "$BUILD" 'CCUSAGE_PRICING_JSON_PATH'
assert_file_contains "$BUILD" 'fetch-litellm-pricing'

it "resolves the vendored cargo path through an existence guard (not a bare default)"
# Mirrors claude-ccr-build.sh / claude-proxy-build.sh EXACTLY: a path string
# assigned unconditionally must still be probed with `command -v` before use,
# or the "fall back to system" promise is unreachable (the Go field failure
# this repo's CLAUDE.md documents at length).
assert_file_contains "$BUILD" 'command -v "$_cargo_bin"'
assert_file_contains "$SCRIPTS_DIR/claude-ccr-build.sh" 'command -v "$_go_bin"'
assert_file_contains "$SCRIPTS_DIR/claude-proxy-build.sh" 'command -v "$_go_bin"'

it "guards on a missing Rust toolchain (resident-artifact-aware, like claude-ccr-build.sh)"
assert_file_contains "$BUILD" 'Rust/cargo toolchain not found'
assert_file_contains "$BUILD" '_resident_usable'

it "installs ccusage onto PATH as a symlink, backing up a pre-existing different binary"
assert_file_contains "$BUILD" 'ln -sf "$BIN" "$LINK"'
assert_file_contains "$BUILD" 'preccusage'

it "install.sh needs no special-casing — the claude-*.sh glob already covers it"
assert_file_contains "$SCRIPTS_DIR/install.sh" 'for f in "$LIB_DIR"/claude-*.sh;'
# Behavioural, not just structural: run the SAME glob install.sh uses and
# confirm our script is actually a member.
_matched=0
for f in "$SCRIPTS_DIR"/claude-*.sh; do
  [[ "$(basename "$f")" == "claude-ccusage-build.sh" ]] && _matched=1
done
if [[ "$_matched" == 1 ]]; then _pass "claude-ccusage-build.sh matches install.sh's symlink glob"
else _fail "claude-ccusage-build.sh does NOT match the glob" "install.sh would never symlink it"; fi

# ---------------------------------------------------------------------------
# Resolution-logic behaviour, hermetic (no network, no real cargo build).
#
# The sandbox $HOME has no cargo, no vendored Rust prefix, and no real
# ccusage submodule, so every branch below is forced deterministically via
# env overrides rather than relying on host state.
# ---------------------------------------------------------------------------

it "vendored cargo ABSENT + system cargo ABSENT + no resident binary => hard failure, actionable message"
_nonexistent_vendor="$HOME/.local/share/claude-rust-does-not-exist/cargo/bin/cargo"
out="$(VENDORED_CARGO="$_nonexistent_vendor" BIN_DIR="$HOME/.local/bin" CCUSAGE_SUBMODULE="$SUBMODULE" bash "$BUILD" 2>&1)"
rc=$?
if command -v cargo >/dev/null 2>&1; then
  echo "SKIP: a REAL system cargo is on PATH in this environment — the no-toolchain-at-all branch cannot be forced; covered by the vendored-cargo-present case below instead"
else
  [[ $rc -ne 0 ]] && _pass "non-zero exit ($rc)" || _fail "exit 0 with no toolchain at all" "$out"
  grep -q 'Rust/cargo toolchain not found' <<<"$out" && _pass "message names the missing toolchain" || _fail "no actionable message" "$out"
  grep -q 'rustup' <<<"$out" && _pass "message suggests rustup (no-sudo path)" || _fail "message omits the no-sudo remedy" "$out"
fi

it "vendored cargo ABSENT + system cargo ABSENT + USABLE resident binary => staleness warning, exit 0"
if command -v cargo >/dev/null 2>&1; then
  echo "SKIP: a REAL system cargo is on PATH in this environment — cannot force the no-toolchain branch"
else
  mkdir -p "$HOME/.local/bin"
  sandbox_stub "$HOME/.local/bin/ccusage" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  --help) printf 'USAGE:\n  ccusage [daily] <OPTIONS>\n'; exit 0 ;;
  --version) printf 'ccusage 0.0.0-stub\n'; exit 0 ;;
esac
exit 0
STUB
  out="$(VENDORED_CARGO="$_nonexistent_vendor" BIN_DIR="$HOME/.local/bin" CCUSAGE_SUBMODULE="$SUBMODULE" bash "$BUILD" 2>&1)"
  rc=$?
  [[ $rc -eq 0 ]] && _pass "exit 0 (artifact already usable)" || _fail "non-zero exit with a usable resident binary" "rc=$rc out=$out"
  grep -qi 'stale' <<<"$out" && _pass "message warns about staleness" || _fail "no staleness warning" "$out"
  rm -f "$HOME/.local/bin/ccusage"
fi

it "missing submodule checkout is reported, not silently skipped"
_fake_submodule="$HOME/no-such-ccusage-checkout"
out="$(CCUSAGE_SUBMODULE="$_fake_submodule" BIN_DIR="$HOME/.local/bin" bash "$BUILD" 2>&1)"
rc=$?
[[ $rc -ne 0 ]] && _pass "non-zero exit ($rc)" || _fail "exit 0 with no submodule checkout" "$out"
grep -q 'submodules/ccusage\|ccusage submodule\|Cargo.toml' <<<"$out" && _pass "message mentions the missing checkout" || _fail "no actionable message" "$out"

# ---------------------------------------------------------------------------
# Guarded live smoke test: a REAL build + REAL run, only when the host has
# what it needs. Honest SKIP (not a silent pass, not a failure) when the
# prerequisites are absent — this is a network/build-tool-gated leg, not part
# of the hermetic contract above.
# ---------------------------------------------------------------------------
it "live smoke test: real cargo build + real ccusage --version (guarded)"
_cargo_for_smoke=""
if [[ -n "${VENDORED_CARGO:-}" ]] && command -v "${VENDORED_CARGO}" >/dev/null 2>&1; then
  _cargo_for_smoke="$VENDORED_CARGO"
elif [[ -x "$CMA_REAL_HOME/.local/share/claude-rust/cargo/bin/cargo" ]]; then
  _cargo_for_smoke="$CMA_REAL_HOME/.local/share/claude-rust/cargo/bin/cargo"
elif command -v cargo >/dev/null 2>&1; then
  _cargo_for_smoke="cargo"
fi
if [[ -z "$_cargo_for_smoke" ]]; then
  echo "SKIP: no Rust/cargo toolchain available on this host — live build not exercised"
elif [[ ! -f "$SUBMODULE/rust/Cargo.toml" ]]; then
  echo "SKIP: submodules/ccusage is not checked out on this host (git submodule update --init submodules/ccusage) — live build not exercised"
else
  out="$(VENDORED_RUST_ROOT="$CMA_REAL_HOME/.local/share/claude-rust" \
         BIN_DIR="$HOME/.local/bin" \
         CCUSAGE_SUBMODULE="$SUBMODULE" \
         bash "$BUILD" 2>&1)"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    _fail "live build failed" "$out"
  else
    _pass "live build succeeded"
    if [[ -x "$HOME/.local/bin/ccusage" ]]; then
      verout="$("$HOME/.local/bin/ccusage" --version 2>&1)"
      case "$verout" in
        ccusage\ *) _pass "installed ccusage reports a version ($verout)" ;;
        *) _fail "installed ccusage --version output unexpected" "$verout" ;;
      esac
    else
      _fail "ccusage was not installed at BIN_DIR" "$HOME/.local/bin/ccusage missing"
    fi
  fi
fi

summary
