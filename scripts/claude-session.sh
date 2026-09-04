#!/usr/bin/env bash
# claude-session.sh — derive per-project session launch flags for the alias
# wrappers (cma_run / cma_run_provider).
#
# Each project (identified by its root directory) gets ONE long-lived Claude
# session so launching any alias inside it resumes the same ongoing work, or
# creates it the first time. The session is named after the root dir in
# lowercase kebab-case.
#
# Subcommands:
#   flags <config_dir>          Print launch flags for `claude` on stdout:
#                               either `--resume <sid>` (session exists) or
#                               `--session-id <sid> --name <kebab>` (first run).
#                               Picks the MOST RECENTLY ACTIVE *resumable*
#                               session (degenerate assistant-free reload
#                               debris is skipped — see _cma_pick_session).
#                               Side effect: trust the project in <config_dir>.
#   name  [path]                Print the kebab-case session name for a path.
#   id    [path]                Print the stable session UUID for a path.
#   latest-id [config_dir]      Print most-recently-active session UUID.
#   context-size <dir> [sid]    Print the session's estimated current context
#                               tokens (last assistant usage input+cache sum).
#   color <label>              Print the mapped color for an alias label.
#   hint  <label> [path]        Print a human color/session hint on stderr.
#
# All subcommands default <path> to $PWD's project root (git toplevel if any,
# else $PWD). Designed to be sourced-free: a normal PATH script with a shebang,
# so it runs under a known bash regardless of the user's interactive shell.
set -euo pipefail

# Claude Code's /color palette (verified from the native binary: the `Ky`
# array). Order is load-bearing for the deterministic label->color mapping.
CMA_COLORS=(red blue green yellow purple orange pink cyan)

# Resolve the project root: prefer the git working-tree root so every dir in a
# repo shares one session; fall back to the given path (or $PWD).
cma_project_root() {
  local p="${1:-$PWD}"
  local root
  if root="$(cd "$p" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)"; then
    printf '%s\n' "$root"
  else
    ( cd "$p" 2>/dev/null && pwd -P ) || printf '%s\n' "$p"
  fi
}

# Sanitize a user-facing session name: lowercase, collapse non-alnum to single
# dash, trim leading/trailing dashes.
cma_session_name() {
  local root base
  root="$(cma_project_root "${1:-$PWD}")"
  base="$(basename "$root")"
  printf '%s\n' "$base" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[^a-z0-9]+/-/g; s/-+/-/g; s/^-//; s/-$//'
}

# Stable RFC-4122-shaped UUID derived from the project root path.
cma_session_id() {
  local root hash
  root="$(cma_project_root "${1:-$PWD}")"
  if command -v md5sum >/dev/null 2>&1; then
    hash="$(printf '%s' "cma-session:$root" | md5sum | cut -d' ' -f1)"
  else
    hash="$(printf '%s' "cma-session:$root" | md5 -q)"
  fi
  printf '%s-%s-%s-%s-%s\n' \
    "${hash:0:8}" "${hash:8:4}" "${hash:12:4}" "${hash:16:4}" "${hash:20:12}"
}

# Deterministic alias-label -> color.
cma_label_color() {
  local label="${1:-}" hash num
  if command -v md5sum >/dev/null 2>&1; then
    hash="$(printf '%s' "$label" | md5sum | cut -d' ' -f1)"
  elif command -v md5 >/dev/null 2>&1; then
    hash="$(printf '%s' "$label" | md5 -q)"
  else
    hash="$(printf '%s' "$label" | cksum | cut -d' ' -f1)"
  fi
  num=$(( 0x${hash:0:6} % ${#CMA_COLORS[@]} ))
  printf '%s\n' "${CMA_COLORS[$num]}"
}

# Mark the project as trusted in <config_dir>/.claude.json
cma_trust_project() {
  local config_dir="$1" root="$2" f tmp
  # An empty config dir (e.g. a no-arg call with CLAUDE_CONFIG_DIR unset) has
  # nothing to trust into — return quietly rather than writing /.claude.json.
  [[ -n "$config_dir" ]] || return 0
  f="$config_dir/.claude.json"
  command -v jq >/dev/null 2>&1 || return 0
  [[ -f "$f" ]] || printf '{}\n' > "$f" 2>/dev/null || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX" 2>/dev/null)" || return 0
  if jq --arg p "$root" '
        .projects = (.projects // {})
        | .projects[$p] = ((.projects[$p] // {}) + {hasTrustDialogAccepted: true})
      ' "$f" > "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
    mv "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

# Find the MOST RECENTLY active session UUID for a project directory.
# Scans *.jsonl (excluding subagents/), sorts by mtime descending.
# Falls back to the deterministic UUID on first launch.

# Degenerate-session guard (2026-09-03 compaction-loop cascade): the store is
# SHARED across every alias, and resolution used to be purely mtime-based, so a
# launch that loaded a large resumed context under a smaller provider window
# and died with ZERO assistant events left a fresh-mtime transcript that the
# NEXT alias launch then resumed — the cascade that made the compaction loop
# endless (35 near-identical ~319KB corpses measured on the live store). A
# transcript is resumable when it carries an assistant event, OR is small: a
# small assistant-free file is a one-prompt session the user simply walked
# away from (continuity must survive); a LARGE assistant-free file is reload
# debris that can only die the same way again. The threshold is bytes, not
# tokens, because a died-on-load transcript has no usage line to measure.
# 0 / negative / non-numeric values mean "use default" — 0 would classify
# every non-empty assistant-free transcript as dead debris and silently break
# one-prompt continuity.
CMA_SESSION_DEAD_BYTES="${CMA_SESSION_DEAD_BYTES:-65536}"
case "$CMA_SESSION_DEAD_BYTES" in
  ''|0|*[!0-9]*) CMA_SESSION_DEAD_BYTES=65536 ;;
esac

_cma_session_resumable() {
  local f="$1" sz
  [[ -f "$f" ]] || return 1
  sz="$(wc -c < "$f" 2>/dev/null || printf '0')"
  if [ "$sz" -le "$CMA_SESSION_DEAD_BYTES" ]; then return 0; fi
  # Anchored to the JSONL object start: a pasted/debris line that merely
  # CONTAINS the substring mid-line must not count as an assistant event.
  grep -q '^{"type":"assistant"' "$f" 2>/dev/null
}

# Print the newest RESUMABLE session id for a session dir, nothing when every
# transcript is degenerate. Callers decide the no-session behaviour.
_cma_pick_session() {
  local sess_dir="$1" f latest=""
  [[ -d "$sess_dir" ]] || return 1
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if _cma_session_resumable "$f"; then latest="$f"; break; fi
  done <<CMA_PICK_EOF
$(ls -t "$sess_dir"/*.jsonl 2>/dev/null | grep -v '/subagents/' || true)
CMA_PICK_EOF
  [[ -n "$latest" ]] || return 1
  basename "$latest" .jsonl
}

cma_latest_session_id() {
  local config_dir="${1:-${CLAUDE_CONFIG_DIR:-}}" root="${2:-}"
  root="${root:-$PWD}"
  local proj_slug sess_dir latest
  proj_slug="$(printf '%s' "$root" | sed -E 's/[^A-Za-z0-9]/-/g')"
  sess_dir="$config_dir/projects/$proj_slug"
  latest="$(_cma_pick_session "$sess_dir" 2>/dev/null || true)"
  if [[ -n "${latest:-}" ]]; then
    printf '%s\n' "$latest"
  else
    cma_session_id "$root"
  fi
}

# Print the most-recent RESUMABLE session UUID ONLY when one exists for this
# project (empty otherwise). Used by the wrapper's args resume-injection:
# injecting --resume with the deterministic-but-never-created fallback UUID
# makes Claude Code fail hard ("No conversation found with session ID").
cma_existing_session_id() {
  local config_dir="${1:-${CLAUDE_CONFIG_DIR:-}}" root="${2:-}"
  root="${root:-$PWD}"
  local proj_slug sess_dir latest
  proj_slug="$(printf '%s' "$root" | sed -E 's/[^A-Za-z0-9]/-/g')"
  sess_dir="$config_dir/projects/$proj_slug"
  latest="$(_cma_pick_session "$sess_dir" 2>/dev/null || true)"
  [[ -n "${latest:-}" ]] && printf '%s\n' "$latest"
  return 0
}

main() {
  local cmd="${1:-flags}"; shift 2>/dev/null || true
  case "$cmd" in
    name)  cma_session_name "${1:-$PWD}" ;;
    id)    cma_session_id "${1:-$PWD}" ;;
    color) cma_label_color "${1:-}" ;;
    existing-id)
      local config_dir="${1:-${CLAUDE_CONFIG_DIR:-}}" root
      root="$(cma_project_root "$PWD")"
      cma_existing_session_id "$config_dir" "$root"
      ;;
    latest-id)
      local config_dir="${1:-${CLAUDE_CONFIG_DIR:-}}" root
      root="$(cma_project_root "$PWD")"
      cma_latest_session_id "$config_dir" "$root"
      ;;
    context-size)
      # Estimated CURRENT context tokens of a session: the last assistant
      # usage's input+cache_creation+cache_read sum (that triple IS the prompt
      # size of the last completed turn; output is the reply, not the context).
      # Empty output when unknown — callers treat empty as "no data", never 0.
      local config_dir="${1:-${CLAUDE_CONFIG_DIR:-}}" sid="${2:-}" root
      root="$(cma_project_root "$PWD")"
      if [[ -z "$sid" ]]; then
        sid="$(cma_existing_session_id "$config_dir" "$root")"
      fi
      [[ -n "$sid" ]] || exit 0
      local proj_slug sess_file
      proj_slug="$(printf '%s' "$root" | sed -E 's/[^A-Za-z0-9]/-/g')"
      sess_file="$config_dir/projects/$proj_slug/$sid.jsonl"
      [[ -f "$sess_file" ]] || exit 0
      command -v jq >/dev/null 2>&1 || exit 0
      # grep|tail|jq under pipefail: a no-assistant transcript makes grep exit
      # 1 — the || true keeps that an empty print, never an abort. Anchored to
      # the JSONL object start, matching _cma_session_resumable, so a mid-line
      # substring (pasted debris) is not mistaken for an assistant event.
      grep '^{"type":"assistant"' "$sess_file" 2>/dev/null | tail -1 | \
        jq -r '(.message.usage // {}) | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)) | select(. > 0)' 2>/dev/null || true
      ;;
    flags)
      local config_dir="${1:-${CLAUDE_CONFIG_DIR:-}}" root sid name proj_slug sess_file
      root="$(cma_project_root "$PWD")"
      sid="$(cma_latest_session_id "$config_dir" "$root")"
      name="$(cma_session_name "$root")"
      cma_trust_project "$config_dir" "$root" || true
      proj_slug="$(printf '%s' "$root" | sed -E 's/[^A-Za-z0-9]/-/g')"
      sess_file="$config_dir/projects/$proj_slug/$sid.jsonl"
      if [[ -f "$sess_file" ]]; then
        printf -- '--resume %s --name %s\n' "$sid" "$name"
      else
        printf -- '--session-id %s --name %s\n' "$sid" "$name"
      fi
      ;;
    apply-color)
      local config_dir="${1:-${CLAUDE_CONFIG_DIR:-}}" label="${2:-}" root sid color proj_slug sess_file latest
      root="$(cma_project_root "$PWD")"
      sid="$(cma_latest_session_id "$config_dir" "$root")"
      color="$(cma_label_color "$label")"
      proj_slug="$(printf '%s' "$root" | sed -E 's/[^A-Za-z0-9]/-/g')"
      sess_file="$config_dir/projects/$proj_slug/$sid.jsonl"
      [[ -f "$sess_file" ]] || return 0
      latest="$(grep '"type":"agent-color"' "$sess_file" 2>/dev/null | tail -1 \
                | sed -E 's/.*"agentColor":"([^"]*)".*/\1/')" || latest=""
      [[ "$latest" == "$color" ]] && return 0
      printf '{"type":"agent-color","agentColor":"%s","sessionId":"%s"}\n' "$color" "$sid" >> "$sess_file"
      ;;
    hint)
      local label="${1:-}" color name
      color="$(cma_label_color "$label")"
      name="$(cma_session_name "$PWD")"
      printf 'claude-session: project "%s" — alias color: %s (auto-applied).\n' \
        "$name" "$color" >&2
      ;;
    *) printf 'usage: claude-session {flags|name|id|color|apply-color|hint|latest-id|existing-id|context-size} [args]\n' >&2; return 2 ;;
  esac
}

main "$@"
