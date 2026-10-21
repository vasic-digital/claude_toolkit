#!/usr/bin/env bash
# claude-semantic-visibility.sh — build + run the LLMsVerifier semantic-code-visibility
# command (layer 3: "does this model actually SEE my code through the alias path?").
#
# Mirrors claude-verify-providers.sh: builds the Go binary (cached; rebuild if the
# command source is newer), then execs it, passing the caller's flags through. The
# command is stdlib-only (no cgo/database) so it builds without a C toolchain.
#
# Secrets: the command reads the model + judge keys from the env var NAMES given via
# --api-key-env / --judge-api-key-env (os.Getenv), never from argv.
#
# Env knobs: CT_LLMS_VERIFIER_DIR / legacy LLMSVERIFIER_DIR (LLMsVerifier checkout, resolved by scripts/resolve_deps.sh), LV_SEMANTIC_BIN (cached binary path).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# LLMsVerifier checkout: single resolver (env CT_LLMS_VERIFIER_DIR / legacy
# LLMSVERIFIER_DIR -> parent hub -> <root>/submodules -> sibling). Not a nested
# submodule of claude_toolkit any more. Empty on failure; checked below.
LV_DIR="$(bash "$SCRIPT_DIR/resolve_deps.sh" llms_verifier "$REPO_ROOT" 2>"${TMPDIR:-/tmp}/.cma-lv-resolve.$$")" || LV_DIR=""
LV_RESOLVE_ERR="$(cat "${TMPDIR:-/tmp}/.cma-lv-resolve.$$" 2>/dev/null)"; rm -f "${TMPDIR:-/tmp}/.cma-lv-resolve.$$"
LV_MOD="$LV_DIR/llm-verifier"
BIN="${LV_SEMANTIC_BIN:-$REPO_ROOT/.local-cache/semantic-code-visibility}"
SRC="$LV_MOD/cmd/semantic-code-visibility/main.go"

case "${1:-}" in
  -h|--help)
    if [ -x "$BIN" ]; then
      exec "$BIN" -h
    fi
    echo "usage: claude-semantic-visibility.sh [flags]"
    echo "  semantic-code-visibility driver: builds (cached) + runs the LLMsVerifier"
    echo "  layer-3 semantic-code-visibility command, forwarding all flags through."
    echo "  Env: CT_LLMS_VERIFIER_DIR / LLMSVERIFIER_DIR (LLMsVerifier checkout), LV_SEMANTIC_BIN (cached binary path)."
    exit 0
    ;;
esac

if [ -z "$LV_DIR" ] || [ ! -d "$LV_MOD" ]; then
  echo "error: LLMsVerifier checkout not resolvable." >&2
  [ -n "$LV_RESOLVE_ERR" ] && printf '%s\n' "$LV_RESOLVE_ERR" >&2
  echo "  fix: set CT_LLMS_VERIFIER_DIR=/path/to/LLMsVerifier (or vendor it flat in the parent hub)" >&2
  exit 3
fi
if ! command -v go >/dev/null 2>&1; then
  echo "error: the Go toolchain is required to build the semantic verifier." >&2
  exit 4
fi

if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
  mkdir -p "$(dirname "$BIN")"
  echo "building semantic-code-visibility (go build)…" >&2
  ( cd "$LV_MOD" && go build -o "$BIN" ./cmd/semantic-code-visibility/ ) \
    || { echo "error: semantic verifier build failed" >&2; exit 5; }
fi

exec "$BIN" "$@"
