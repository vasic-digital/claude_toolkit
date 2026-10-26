#!/usr/bin/env bash
# jev-keyfile-lib.sh - SOURCED helper: find a bearer-key VARIABLE in "key files" named by a NON-SECRET pointer.
#
# Why (2026-10-26, captured): the local llmctl decide gateway needs `Authorization: Bearer $LLMCTL_API_KEY`. On the operator host the
# value lives in llmctl's own `.env` (mode 600) and is injected into the toolkit sync unit by a systemd EnvironmentFile. A gate
# hook started from an interactive Claude/Kimi/opencode session has NEITHER that environment NOR the key in ~/api_keys.sh, so
# jev-gate.sh sent no usable key and the gateway answered 401 (the call then failed open). Copying the secret into
# ~/api_keys.sh would duplicate it (two places to rotate, one of them world-readable by mistake); sourcing a foreign .env would
# execute whatever it contains. This helper does neither.
#
# Contract (identical in jev-gate.sh [inline copy], this library, jev_mcp.py and opencode-jev-plugin.js; one shared vector suite
# in scripts/tests/test_jev_keyfile.sh keeps them in lock-step):
#   candidates  = $CMA_JEV_KEY_FILES (colon separated)  THEN  the lines of ${JEV_CONFIG_DIR:-~/.config/jev}/key-files
#                 (one path per line; blank lines and lines starting with # are ignored; ~/ is expanded; paths must not contain ':')
#   a candidate is used only if it is a regular, readable file OWNED BY THE CURRENT USER (anything else is skipped silently)
#   the file is PARSED, never sourced or executed: only a line `NAME=value` or `export NAME=value` counts (leading blanks ok),
#   the LAST such line wins, CR and trailing blanks are stripped, ONE pair of matching surrounding quotes is removed, nothing is
#   expanded ($VAR, $(cmd), backticks and inline # comments are literal text, so they are never executed)
#   the first candidate that yields a non-empty value wins; NAME must match [A-Za-z_][A-Za-z0-9_]*
# Precedence among key sources (every consumer): JEV_API_KEY / TYPESAFE_API_KEY > the env var named by JEV_KEY_VAR > the keys
# file (~/api_keys.sh) > these key files > the literal "local" (a keyless loopback gateway).
# The value is only ever written to stdout of the caller's command substitution; it is never put on a command line.
# `jev-setup --key-file PATH` records PATH in the pointer file (the path, never the value).
#
# No side effects when sourced.

cma_jev_keyfile_list() { # candidate paths, one per line, in lookup order
  local cfg="${JEV_CONFIG_DIR:-$HOME/.config/jev}/key-files"
  if [ -n "${CMA_JEV_KEY_FILES:-}" ]; then printf '%s\n' "$CMA_JEV_KEY_FILES" | tr ':' '\n'; fi
  if [ -r "$cfg" ]; then tr -d '\r' < "$cfg"; fi
  return 0
}

cma_jev_keyfile_lookup() { # cma_jev_keyfile_lookup <VARNAME> -> value on stdout, rc 0 when found (non-empty), else rc 1
  local name="${1:-}" p v
  case "$name" in '' | [0-9]* | *[!A-Za-z0-9_]*) return 1 ;; esac
  while IFS= read -r p; do
    p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
    case "$p" in '' | '#'*) continue ;; '~/'*) p="$HOME/${p#\~/}" ;; esac
    [ -f "$p" ] && [ -r "$p" ] && [ -O "$p" ] || continue
    v="$(awk -v n="$name" '
      { line = $0; sub(/\r$/, "", line); sub(/^[ \t]+/, "", line)
        if (line ~ /^export[ \t]+/) sub(/^export[ \t]+/, "", line)
        if (index(line, n "=") == 1) { v = substr(line, length(n) + 2); found = 1 } }
      END { if (found) { sub(/[ \t]+$/, "", v)
              if (length(v) >= 2 && ((substr(v, 1, 1) == "\"" && substr(v, length(v), 1) == "\"") || (substr(v, 1, 1) == "\047" && substr(v, length(v), 1) == "\047"))) v = substr(v, 2, length(v) - 2)
              print v } }' "$p" 2>/dev/null)" || v=""
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  done < <(cma_jev_keyfile_list)
  return 1
}
