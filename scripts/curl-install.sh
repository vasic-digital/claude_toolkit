#!/usr/bin/env bash
# curl-install.sh — one-line installer for the Claude multi-account toolkit.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/vasic-digital/claude-toolkit/main/scripts/curl-install.sh | bash
#
# What it does:
#   1. Detects platform, shell, and architecture.
#   2. Installs missing hard dependencies (jq, rsync, awk) via the system
#      package manager when possible.
#   3. Clones (or pulls) the toolkit repo with all submodules, then provisions
#      the flat own-org router checkout as a sibling when it is not resolvable.
#   4. Runs scripts/install.sh to symlink onto PATH, create the managed alias
#      file, and wire up rc-file sourcing.
#
# Idempotent: safe to re-run.  If ~/claude-toolkit already exists, pulls and
# re-installs instead of re-cloning.
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
REPO_URL="https://github.com/vasic-digital/claude_toolkit.git"
INSTALL_DIR="${CLAUDE_TOOLKIT_DIR:-$HOME/claude-toolkit}"

# ── Helpers ────────────────────────────────────────────────────────────────────
info()  { printf '\033[1;34m[info]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[1;33m[warn]\033[0m  %s\n' "$*" >&2; }
error() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }
die()   { error "$@"; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not found. Install it and retry."
}

# provision_flat_router — step 3b. claude_toolkit tracks NO own-org submodule
# (operator decision 2026-10-21): the Go router it builds
# (vasic-digital/claude-code-router) lives FLAT and is found by
# scripts/resolve_deps.sh. A standalone curl install has no parent hub, so when
# the router is not resolvable it is cloned over https as a SIBLING
# ($(dirname INSTALL_DIR)/claude_code_router, the resolver's tier 4), or an
# existing sibling repo is fast-forwarded. LLMsVerifier is optional (full model
# verification only) and is not cloned here. Covered behaviourally by
# scripts/tests/test_curl_install_router.sh.
provision_flat_router() {
  local ccr_url="${CLAUDE_TOOLKIT_CCR_URL:-https://github.com/vasic-digital/claude-code-router.git}"
  local ccr_sibling
  ccr_sibling="$(dirname "$INSTALL_DIR")/claude_code_router"
  if bash "$INSTALL_DIR/scripts/resolve_deps.sh" claude_code_router "$INSTALL_DIR" >/dev/null 2>&1; then
    return 0
  fi
  if [[ -d "$ccr_sibling/.git" ]]; then
    info "pulling claude-code-router -> $ccr_sibling"
    git -C "$ccr_sibling" pull --ff-only --quiet || die "git pull of $ccr_sibling failed"
  else
    info "cloning $ccr_url -> $ccr_sibling (flat sibling; resolved by scripts/resolve_deps.sh)"
    git clone --quiet "$ccr_url" "$ccr_sibling" || die "git clone of claude-code-router failed (set CT_CLAUDE_CODE_ROUTER_DIR to an existing checkout and re-run)"
  fi
}

# Library mode for the test suite: define the helpers above and stop before
# any install side effect. Never set on a real install.
if [[ -n "${CT_CURL_INSTALL_LIB_ONLY:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# ── 1. Platform detection ──────────────────────────────────────────────────────
OS="$(uname -s)"
ARCH="$(uname -m)"
SHELL_RC=""
case "$SHELL" in
  */zsh)  SHELL_RC="$HOME/.zshrc" ;;
  */bash) SHELL_RC="$HOME/.bashrc" ;;
  *)      SHELL_RC="$HOME/.bashrc" ;;  # fallback
esac

info "platform: $OS ($ARCH)  shell: $(basename "${SHELL:-bash}")"

# ── 2. Check hard dependencies (jq, rsync, awk) ───────────────────────────────
MISSING=()
for cmd in jq rsync awk; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done

if (( ${#MISSING[@]} > 0 )); then
  info "missing dependencies: ${MISSING[*]}"
  # Attempt auto-install via the system package manager.
  install_pkg() {
    case "$OS" in
      Linux)
        if command -v apt-get >/dev/null 2>&1; then
          sudo apt-get update -qq && sudo apt-get install -y -qq "$@"
        elif command -v dnf >/dev/null 2>&1; then
          sudo dnf install -y -q "$@"
        elif command -v yum >/dev/null 2>&1; then
          sudo yum install -y -q "$@"
        elif command -v apk >/dev/null 2>&1; then
          sudo apk add --no-cache "$@"
        elif command -v pacman >/dev/null 2>&1; then
          sudo pacman -S --noconfirm "$@"
        else
          return 1
        fi
        ;;
      Darwin)
        if command -v brew >/dev/null 2>&1; then
          brew install "$@"
        else
          die "Homebrew not found. Install it: https://brew.sh"
        fi
        ;;
      *) return 1 ;;
    esac
  }
  if install_pkg "${MISSING[@]}"; then
    info "installed: ${MISSING[*]}"
  else
    die "could not auto-install: ${MISSING[*]}. Install manually and retry."
  fi
fi

# Verify all hard deps are now present.
for cmd in jq rsync awk git; do
  need_cmd "$cmd"
done
info "all dependencies satisfied"

# ── 3. Clone or pull ──────────────────────────────────────────────────────────
if [[ -d "$INSTALL_DIR/.git" ]]; then
  info "existing repo at $INSTALL_DIR — pulling latest"
  git -C "$INSTALL_DIR" pull --ff-only --recurse-submodules --quiet || \
    die "git pull failed. Check your network or run: cd $INSTALL_DIR && git status"
  git -C "$INSTALL_DIR" submodule update --init --recursive --quiet
else
  info "cloning $REPO_URL -> $INSTALL_DIR"
  git clone --recursive "$REPO_URL" "$INSTALL_DIR" || die "git clone failed"
fi

# ── 3b. Flat own-org dependencies ─────────────────────────────────────────────
provision_flat_router

# ── 4. Run the internal installer ─────────────────────────────────────────────
info "running install.sh ..."
bash "$INSTALL_DIR/scripts/install.sh"

# ── 5. Done ───────────────────────────────────────────────────────────────────
printf '\n'

info "installation complete!"

cat <<EOF

  Repository:   $INSTALL_DIR
  Scripts:      $HOME/.local/bin/claude-*
  Alias file:   $HOME/.local/share/claude-multi-account/aliases.sh
  Shared store: $HOME/.claude-shared/

Next steps:
  source $SHELL_RC                  # reload shell (or open a new terminal)
  claude-list-accounts              # see what's wired up
  claude-add-account                # add an account interactively
  claude-providers sync             # detect provider API keys and create aliases

EOF
