#!/usr/bin/env bash
# resolve_deps.sh — ONE source of truth for locating the shared dependencies
# (constitution, containers, challenges, superspec) that claude_toolkit no
# longer vendors as its own nested submodules.
#
# Why: the constitution hub vendors claude_toolkit at
# <hub>/constitution/submodules/claude_toolkit and already carries flat copies
# of containers/challenges/superspec. Re-declaring them here created nested
# duplicate chains (stale pins). The toolkit now FINDS them instead.
#
# Usage:
#   bash scripts/resolve_deps.sh <constitution|containers|challenges|superspec> [toolkit_root]
#       prints the absolute path on stdout, exit 0; nothing resolvable => exit 1
#       with an actionable message on stderr (never a silent pass).
#   source scripts/resolve_deps.sh; ct_resolve_dep containers   # same, as a function
#
# Resolution order (first VALID hit wins; "valid" = Constitution.md file for
# constitution, a non-empty directory for the others):
#   1. env override  CT_CONSTITUTION_DIR | CT_CONTAINERS_DIR | CT_CHALLENGES_DIR | CT_SUPERSPEC_DIR
#      (set but invalid => hard failure, NO fall-through: a wrong override must
#      never silently resolve to something else)
#   2. parent hub, when the toolkit sits at <hub>/submodules/claude_toolkit
#      (hub = ../..): constitution = <hub> (if it is itself the constitution)
#      or <hub>/constitution; others = <hub>/submodules/<n>, then the hub's own
#      parent <hub>/../submodules/<n> (hub = <project>/constitution case)
#   3. in-tree: <root>/constitution, <root>/submodules/<n>
#   4. siblings: <root>/../constitution, <root>/../<n>
#   5. host fallback (constitution only): $CT_HOST_CONSTITUTION_FALLBACK
#      (default /home/milosvasic/Projects/helix_code/constitution)
#
# Exit codes: 0 resolved | 1 not resolvable / bad override | 2 usage error

CT_RESOLVE_SELF="${BASH_SOURCE[0]}"

_ct_valid() {  # _ct_valid <name> <path>
  case "$1" in
    constitution) [ -f "$2/Constitution.md" ] ;;
    *) [ -d "$2" ] && [ -n "$(ls -A "$2" 2>/dev/null)" ] ;;
  esac
}

ct_resolve_dep() {  # ct_resolve_dep <name> [toolkit_root]
  local name="${1:-}" root="${2:-}" var up cand hub
  case "$name" in
    constitution|containers|challenges|superspec) ;;
    *) echo "resolve_deps: unknown dependency '$name' (want constitution|containers|challenges|superspec)" >&2; return 2 ;;
  esac
  if [ -z "$root" ]; then root="$(cd "$(dirname "$CT_RESOLVE_SELF")/.." && pwd -P)"; fi
  root="$(cd "$root" 2>/dev/null && pwd -P)" || { echo "resolve_deps: toolkit root not found: ${2:-}" >&2; return 2; }
  up="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"
  var="CT_${up}_DIR"

  # 1. env override — authoritative; invalid => loud failure
  if [ -n "${!var:-}" ]; then
    if _ct_valid "$name" "${!var}"; then printf '%s\n' "${!var}"; return 0; fi
    echo "resolve_deps: $var='${!var}' is set but is not a valid $name checkout. Fix or unset $var." >&2
    return 1
  fi

  local cands=()
  # 2. parent hub
  if [ "$(basename "$(dirname "$root")")" = "submodules" ]; then
    hub="$(dirname "$(dirname "$root")")"
    if [ "$name" = constitution ]; then cands+=("$hub" "$hub/constitution")
    else cands+=("$hub/submodules/$name" "$hub/../submodules/$name" "$hub/constitution/submodules/$name"); fi
  fi
  # 3. in-tree   4. siblings
  if [ "$name" = constitution ]; then cands+=("$root/constitution" "$root/../constitution")
  else cands+=("$root/submodules/$name" "$root/../$name"); fi
  # 5. host fallback
  [ "$name" = constitution ] && cands+=("${CT_HOST_CONSTITUTION_FALLBACK:-/home/milosvasic/Projects/helix_code/constitution}")

  for cand in "${cands[@]}"; do
    if [ -d "$cand" ] && _ct_valid "$name" "$(cd "$cand" && pwd -P)"; then
      (cd "$cand" && pwd -P); return 0
    fi
  done
  {
    echo "resolve_deps: cannot resolve '$name' for toolkit root $root."
    echo "  tried: ${cands[*]}"
    echo "  fix : set $var=/path/to/$name, or vendor claude_toolkit under a hub at <hub>/submodules/claude_toolkit"
  } >&2
  return 1
}

# CLI mode (executed, not sourced)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ $# -lt 1 ]; then echo "usage: resolve_deps.sh <constitution|containers|challenges|superspec> [toolkit_root]" >&2; exit 2; fi
  ct_resolve_dep "$@"; exit $?
fi
