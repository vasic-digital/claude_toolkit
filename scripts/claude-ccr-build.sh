#!/usr/bin/env bash
# claude-ccr-build.sh — build the BUNDLED claude-code-router (Go) from the
# submodule and install it as the toolkit's `ccr`.
#
# The toolkit's provider aliases route through `ccr` (the OpenAI<->Anthropic
# gateway). Historically that meant a separately-installed Node
# `@musistudio/claude-code-router` on PATH. This repository now VENDORS a
# from-scratch Go reimplementation as the `submodules/claude-code-router`
# submodule; this script builds it and symlinks the result onto PATH so the
# toolkit is self-contained and uses OUR router.
#
# It is idempotent: re-running rebuilds the binary in place and re-points the
# symlink. With no `go` toolchain: if a USABLE bundled router is already
# installed at $BIN_DIR/ccr it warns that the router cannot be rebuilt (and
# will go stale on submodule updates) and exits 0 — the artifact, not the
# build prerequisite, is what the gate asserts; otherwise it explains how to
# install Go and exits non-zero, which install.sh records as a REAL failure.
#
# Env knobs:
#   BIN_DIR   where `ccr` is symlinked (default ~/.local/bin, same as install.sh)
set -euo pipefail

# Resolve this script's real dir through any symlinks (install.sh links it into
# ~/.local/bin), the same idiom install.sh uses.
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
SUBMODULE="$REPO_ROOT/submodules/claude-code-router"
# Hoisted above the Go gate: the no-Go path probes the artifact already
# installed at $BIN_DIR/ccr before deciding whether missing Go is fatal.
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"

# 1. Ensure the submodule is checked out.
if [ ! -f "$SUBMODULE/go.mod" ] || [ ! -d "$SUBMODULE/cmd/ccr" ]; then
  cma_log "claude-code-router submodule not checked out — initialising ..."
  if ! git -C "$REPO_ROOT" submodule update --init --recursive submodules/claude-code-router 2>/dev/null; then
    printf 'claude-ccr-build: submodule submodules/claude-code-router is missing and could not be initialised.\n  Run: git -C %s submodule update --init --recursive\n' "$REPO_ROOT" >&2
    exit 1
  fi
fi
if [ ! -d "$SUBMODULE/cmd/ccr" ]; then
  printf 'claude-ccr-build: %s does not contain cmd/ccr (unexpected submodule layout).\n' "$SUBMODULE" >&2
  exit 1
fi

# 2. Require the Go toolchain.
#
# DECISION (2026-07-22): a missing Go toolchain is a HARD FAILURE with exact
# instructions — deliberately NOT an auto-bootstrap that downloads Go. Reasons,
# in order of weight:
#   1. An auto-bootstrap must pin a verified checksum per (version x os x arch).
#      The required version tracks this submodule's go.mod (see below) and would
#      go stale on every bump; shipping an unverified — or silently stale —
#      toolchain download is precisely the unverified-dependency risk we refuse
#      (§11.4.6/§11.4.10).
#   2. Installing a ~80MB compiler into someone's machine from an ALIAS
#      installer is high blast radius and surprising; the reversible, operator-
#      visible choice is the safe default (§11.4.101).
#   3. Go already solves the harder half itself: GOTOOLCHAIN=auto lets a host
#      that HAS any go fetch the exact toolchain go.mod asks for. Only the
#      no-Go-at-all case is left, and that is one OS package command.
#   4. The reported defect was never "I had to install Go" — it was "install
#      printed [done] while the product was broken". Failing loudly fixes that;
#      auto-bootstrap would not.
# What is NOT acceptable is the old behaviour: exiting non-zero into a caller
# that only warned. install.sh now treats this exit as a real failure.
#
# REFINEMENT (review B1, 2026-07-22, live-proven): missing Go is fatal ONLY
# when it leaves the product unusable. A readiness gate must assert the
# ARTIFACT is usable — probe it — not that a build PREREQUISITE is present:
# a host with a working bundled ccr whose Go was later removed got
# "[ok] ccr: bundled Go router verified" AND "[FAILED] ... did NOT
# build/install" from one install run — a factually-false refusal
# (§11.4.201(1)) that broke the routine `git pull && install.sh` upgrade.
# So: no Go + USABLE resident router (passes the same `ccr restart`
# discriminator as step 4/verify) -> honest staleness warning, exit 0.
#     no Go + absent/broken/doppelganger router -> hard failure, as before.
if ! command -v go >/dev/null 2>&1; then
  _resident="$BIN_DIR/ccr"
  if [ -x "$_resident" ]; then
    # Bounded probe (a wedged resident binary must not hang the installer,
    # and must NOT count as usable — cma_probe_help returns 124 on a hang).
    _rrc=0; _rhelp="$(cma_probe_help "$_resident")" || _rrc=$?
    if [ "$_rrc" -ne 124 ]; then
      case "$_rhelp" in
        *"ccr restart"*)
          cma_warn "Go toolchain not found — cannot REBUILD the bundled claude-code-router.
  The existing bundled router verified usable ($_resident — 'ccr restart' grammar present),
  so this install keeps working. It WILL GO STALE on submodule updates until Go
  is installed:
    Debian/Ubuntu:  sudo apt install golang-go
    Fedora/RHEL:    sudo dnf install golang
    Arch:           sudo pacman -S go
    macOS:          brew install go
    Any platform:   https://go.dev/dl/
  then re-run: claude-ccr-build"
          exit 0
          ;;
      esac
    fi
  fi
  # If the resident binary IS a non-bundled (npm) doppelganger, back it up NOW
  # so the user is never in the broken state "install says [done] but ccr is
  # wrong". The npm binary is identifiably NOT ours: it lacks `ccr restart`.
  # Removing it makes the failure clean and points at the ONE fix: install Go.
  if [ -x "$_resident" ]; then
    _dup="$BIN_DIR/ccr.npm-$(date +%Y%m%d%H%M%S)"
    mv "$_resident" "$_dup" 2>/dev/null || true
    cma_warn "removed non-bundled (npm) ccr at $BIN_DIR/ccr (backed up as $_dup)."
  fi
  cma_warn "Go toolchain not found — cannot build the bundled claude-code-router (Go)."
  printf '  Install Go, then re-run: claude-ccr-build\n    Debian/Ubuntu:  sudo apt install golang-go\n    Fedora/RHEL:    sudo dnf install golang\n    Arch:           sudo pacman -S go\n    macOS:          brew install go\n    Any platform:   https://go.dev/dl/\n' >&2
  exit 1
fi

# 2b. Version skew: this module pins a `go` directive, and with the default
# GOTOOLCHAIN=local an OLDER toolchain does not download the newer one — it
# fails with a "go.mod requires go >= X" error that does not say what to do.
# Report it up front with both remedies. Purely advisory: we do NOT refuse the
# build on this signal (the compare is a best-effort text compare, and refusing
# on it when the build would in fact succeed is a false-positive refusal —
# §11.4.201(1)). The build below is still the authority.
_need="$(awk '/^go[ \t]+[0-9]/ {print $2; exit}' "$SUBMODULE/go.mod" 2>/dev/null || true)"
_have="$(go env GOVERSION 2>/dev/null | sed 's/^go//; s/-.*$//' || true)"
if [ -n "$_need" ] && [ -n "$_have" ] \
   && [ "$_need" != "$_have" ] \
   && [ "$(printf '%s\n%s\n' "$_need" "$_have" | sort -V | head -1)" = "$_have" ]; then
  cma_warn "Go $_have is older than the $_need this router requires (GOTOOLCHAIN=$(go env GOTOOLCHAIN 2>/dev/null))."
  printf '  If the build below fails on the toolchain version, either:\n    export GOTOOLCHAIN=auto     # let Go fetch %s itself (needs network)\n  or upgrade your Go to %s+ (https://go.dev/dl/).\n' "$_need" "$_need" >&2
fi

# 3. Build ./cmd/ccr into the submodule's bin/ccr (matches the submodule
#    Makefile's output path).
BIN="$SUBMODULE/bin/ccr"
cma_log "building bundled claude-code-router (Go): $(cd "$SUBMODULE" && go version 2>/dev/null | awk '{print $3}') ..."
if ! ( cd "$SUBMODULE" && mkdir -p bin && go build -o bin/ccr ./cmd/ccr ); then
  printf 'claude-ccr-build: go build failed in %s\n' "$SUBMODULE" >&2
  exit 1
fi

# 4. Self-check: the built binary must present the BUNDLED router's grammar.
#
#    The discriminator is `ccr restart` — NOT `ccr start`/`ccr serve`, which
#    this check used to accept. Those tokens are a CARRIER match: the npm
#    @musistudio router prints them too, so the old check (and lib.sh's
#    identity gate) could not tell the two apart (§11.4.201(7)(a) — match
#    STRUCTURE, not a substring something else also carries).
#
#    Captured on this host 2026-07-22 (control needle — the same probe run
#    against both binaries through the SAME path):
#      npm     ccr --help | grep -c 'ccr start'   -> 2   (matches: blind)
#      bundled ccr --help | grep -c 'ccr start'   -> 1   (matches: blind)
#      npm     ccr --help | grep -c 'ccr restart' -> 0   (discriminates)
#      bundled ccr --help | grep -c 'ccr restart' -> 1   (discriminates)
#    The missing `restart` is not cosmetic: it is exactly why every
#    route-apply failed in the field against the npm doppelganger.
#
#    head -20 (was -12): `restart` sits on the 9th usage line, and a `head`
#    that truncates above it would turn this gate into a false-negative.
_help="$("$BIN" --help 2>&1 | head -20 || true)"
case "$_help" in
  *"ccr restart"*) : ;;
  *)
    printf 'claude-ccr-build: built binary failed its self-check — `%s --help` did not show the bundled router grammar (no `ccr restart`).\n' "$BIN" >&2
    exit 1
    ;;
esac

# 5. Symlink it onto PATH as `ccr`, backing up any pre-existing DIFFERENT ccr so
#    nothing is silently clobbered. ($BIN_DIR resolved once, above the Go gate.)
mkdir -p "$BIN_DIR"
LINK="$BIN_DIR/ccr"
if [ -L "$LINK" ] && [ "$(cma_realpath "$LINK" 2>/dev/null)" = "$(cma_realpath "$BIN" 2>/dev/null)" ]; then
  : # already ours — nothing to do
elif [ -e "$LINK" ] || [ -L "$LINK" ]; then
  _bak="${LINK}.preccr.$(date +%Y%m%d%H%M%S)"
  mv "$LINK" "$_bak"
  cma_warn "backed up existing $LINK -> $_bak"
fi
ln -sf "$BIN" "$LINK"
cma_log "installed bundled Go ccr: $LINK -> $BIN"

# 6. Informational: confirm PATH resolution points at our link.
#
# Deliberately a WARNING, never a failure (§11.4.201(1) — a false-positive
# refusal is a FAIL-bluff exactly as a false pass is). Since the §11.4.111
# fix, cma_run_provider resolves $CMA_CCR_BIN / $HOME/.local/bin/ccr FIRST and
# only falls back to PATH, so a shadowing ccr in an earlier PATH entry does
# NOT break the toolkit — failing the install on it would refuse a working
# product. It still matters for anything the operator types by hand, so it is
# reported by name with the exact removal command.
_resolved="$(command -v ccr 2>/dev/null || true)"
if [ -n "$_resolved" ] && [ "$(cma_realpath "$_resolved" 2>/dev/null)" = "$(cma_realpath "$BIN" 2>/dev/null)" ]; then
  cma_log "ccr on PATH now resolves to the bundled Go router ($_resolved)"
else
  cma_warn "an EARLIER 'ccr' shadows $LINK on PATH ($_resolved).
  The toolkit is UNAFFECTED — provider aliases resolve $LINK directly, not by PATH order.
  A bare 'ccr' you type yourself still hits the other one. To remove it:
    npm rm -g @musistudio/claude-code-router     # if that is where it came from
  or ensure $BIN_DIR precedes it on PATH."
fi
