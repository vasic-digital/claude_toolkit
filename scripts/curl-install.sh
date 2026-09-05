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
#   3. Clones (or pulls) the toolkit repo with all submodules.
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
