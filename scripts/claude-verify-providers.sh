#!/usr/bin/env bash
# claude-verify-providers.sh — verify provider models via the LLMsVerifier checkout.
#
# Drives LLMsVerifier's `code-verification` command (checkout resolved flat by
# scripts/resolve_deps.sh llms_verifier): it builds the Go
# binary (cached), feeds it the toolkit's provider API keys from the environment,
# and runs the mandatory "Do you see my code?" verification, emitting per-model
# verdicts (score / code_visibility / status). This is the toolkit's single,
# reliable path for models+providers testing — replacing ad-hoc `-p` sweeps whose
# output is polluted by Claude's own startup noise.
#
# Keys: read from the environment. `source ~/api_keys.sh` first, or point LV_KEYS
# at a file to source (its values are never printed by this script).
#
# Env knobs: CT_LLMS_VERIFIER_DIR / legacy LLMSVERIFIER_DIR (LLMsVerifier checkout, resolved by scripts/resolve_deps.sh), LV_CONFIG (verification config),
# LV_BIN (cached binary path), LV_KEYS (a shell file of API-key exports to source).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# LLMsVerifier checkout: single resolver (env CT_LLMS_VERIFIER_DIR / legacy
# LLMSVERIFIER_DIR -> parent hub -> <root>/submodules -> sibling). Not a nested
# submodule of claude_toolkit any more. Empty on failure; checked below.
LV_DIR="$(bash "$SCRIPT_DIR/resolve_deps.sh" llms_verifier "$REPO_ROOT" 2>"${TMPDIR:-/tmp}/.cma-lv-resolve.$$")" || LV_DIR=""
LV_RESOLVE_ERR="$(cat "${TMPDIR:-/tmp}/.cma-lv-resolve.$$" 2>/dev/null)"; rm -f "${TMPDIR:-/tmp}/.cma-lv-resolve.$$"
LV_MOD="$LV_DIR/llm-verifier"
CONFIG="${LV_CONFIG:-$LV_DIR/code_verification_config.json}"
BIN="${LV_BIN:-$REPO_ROOT/.local-cache/code-verification}"

usage() {
  cat <<'EOF'
Usage: claude-verify-providers [--providers p1,p2,...] [--models m1,...]
                               [--concurrency N] [--timeout N] [--format json]
Verify provider models via the LLMsVerifier checkout (resolved by scripts/resolve_deps.sh).

Provider API keys are read from the ENVIRONMENT. Source them first, e.g.:
    set -a; . ~/api_keys.sh; set +a
or point LV_KEYS at a file to source.

Env: CT_LLMS_VERIFIER_DIR (legacy LLMSVERIFIER_DIR)  LV_CONFIG  LV_BIN  LV_KEYS
EOF
}

case "${1:-}" in -h|--help) usage; exit 0 ;; esac

# --- preconditions -----------------------------------------------------------
if [ -z "$LV_DIR" ] || [ ! -d "$LV_MOD" ]; then
  echo "error: LLMsVerifier checkout not resolvable." >&2
  [ -n "$LV_RESOLVE_ERR" ] && printf '%s\n' "$LV_RESOLVE_ERR" >&2
  echo "  fix: set CT_LLMS_VERIFIER_DIR=/path/to/LLMsVerifier (or vendor it flat in the parent hub)" >&2
  exit 3
fi
if ! command -v go >/dev/null 2>&1; then
  echo "error: the Go toolchain (go 1.21+) is required to build the verifier." >&2
  exit 4
fi

# Optionally source a keys file (values are used as env, never echoed).
if [ -n "${LV_KEYS:-}" ] && [ -f "$LV_KEYS" ]; then
  set -a; . "$LV_KEYS"; set +a
fi

# --- build the verifier binary (cached; rebuild if source is newer) ----------
if [ ! -x "$BIN" ] || [ "$LV_MOD/cmd/code-verification/main.go" -nt "$BIN" ]; then
  mkdir -p "$(dirname "$BIN")"
  echo "building code-verification (go build)…" >&2
  ( cd "$LV_MOD" && go build -o "$BIN" ./cmd/code-verification/ ) \
    || { echo "error: verifier build failed" >&2; exit 5; }
fi

# --- run: pass the operator's flags through, injecting --config --------------
exec "$BIN" --config "$CONFIG" "$@"
