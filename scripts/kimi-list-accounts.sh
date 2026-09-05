#!/usr/bin/env bash
# kimi-list-accounts.sh — Print a status summary of every detected Kimi Code
# account: which alias maps to it, whether credentials are present, and
# whether its shared-state symlinks are intact. Family mirror of
# claude-list-accounts.sh.

set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  for newer in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$newer" ]] && exec "$newer" "$0" "$@"
  done
  echo "kimi-list-accounts requires bash 4+. Install via: brew install bash" >&2
  exit 1
fi

# Resolve LIB_DIR through any symlinks (install.sh symlinks into ~/.local/bin).
_cma_src="${BASH_SOURCE[0]}"
while [ -L "$_cma_src" ]; do
  _cma_tgt="$(readlink "$_cma_src")"
  case "$_cma_tgt" in /*) _cma_src="$_cma_tgt" ;; *) _cma_src="$(dirname "$_cma_src")/$_cma_tgt" ;; esac
done
LIB_DIR="$(cd "$(dirname "$_cma_src")" && pwd)"
unset _cma_src _cma_tgt
# shellcheck source=lib.sh
source "$LIB_DIR/lib.sh"

KSHARED="$SHARED_DIR/$KIMI_SHARED_SUBDIR"
KIMI_DEFAULT_DIR="${KIMI_DEFAULT_DIR:-$(cma_kimi_home)}"

# Build alias -> dir mapping from the managed alias file.
declare -A ALIAS_OF_DIR
if [[ -f "$ALIAS_FILE" ]]; then
  while IFS= read -r line; do
    [[ "$line" =~ ^alias[[:space:]]+([a-zA-Z0-9_-]+)=.*KIMI_CODE_HOME=([^[:space:]]+) ]] || continue
    ALIAS_OF_DIR["${BASH_REMATCH[2]}"]="${BASH_REMATCH[1]}"
  done < "$ALIAS_FILE"
fi

# Items we expect to be symlinks pointing into $SHARED_DIR/kimi.
CHECK_LINKS=(plugins skills sessions AGENTS.md)

printf '%-12s  %-45s  %-6s  %-5s  %s\n' \
  "ALIAS" "CONFIG DIR" "CREDS" "LINKS" "NOTES"

mapfile -t accounts < <(cma_detect_kimi_accounts)
for dir in "${accounts[@]}"; do
  alias_name="${ALIAS_OF_DIR[$dir]:--}"
  if { [[ -d "$dir/credentials" && -n "$(ls -A "$dir/credentials" 2>/dev/null)" ]] \
       || [[ -d "$dir/oauth" && -n "$(ls -A "$dir/oauth" 2>/dev/null)" ]]; }; then
    creds="yes"; else creds="no"; fi
  ok=0 total=0 missing=()
  for item in "${CHECK_LINKS[@]}"; do
    total=$((total+1))
    if [[ -L "$dir/$item" ]] \
       && [[ "$(cma_realpath "$dir/$item")" == "$(cma_realpath "$KSHARED/$item")" ]]; then
      ok=$((ok+1))
    else
      missing+=("$item")
    fi
  done
  notes=""
  (( ${#missing[@]} )) && notes="not linked: ${missing[*]}"
  printf '%-12s  %-45s  %-6s  %-5s  %s\n' \
    "$alias_name" "$dir" "$creds" "$ok/$total" "$notes"
done

echo
echo "Shared store: $KSHARED"
[[ -d "$KSHARED" ]] || echo "  (does not exist — run kimi-unify.sh)"
echo "Alias file:   $ALIAS_FILE"
[[ -f "$ALIAS_FILE" ]] || echo "  (does not exist — run install.sh)"
echo "Default home: $KIMI_DEFAULT_DIR"
[[ -d "$KIMI_DEFAULT_DIR" ]] || echo "  (does not exist — will be created on first login)"