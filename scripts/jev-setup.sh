#!/usr/bin/env bash
# jev-setup.sh — idempotent installer for the Jev decision layer
# (design: toolkit-jev-design §2.4).
#
# Usage:
#   jev-setup [--agents claude,kimi,pi,opencode]   (default: all)
#             [--mode shadow|enforce]              (writes ~/.config/jev/env; read by
#                                                   the gate, the launch wrappers and the
#                                                   opencode plugin: process env JEV_MODE
#                                                   > this file > shadow; a NEW launch
#                                                   picks up a change, a running session
#                                                   keeps the mode it started with)
#             [--key-file PATH]                    (record WHERE the bearer key lives: appends PATH to
#                                                   ~/.config/jev/key-files, idempotent; the file must define the
#                                                   endpoint's key variable (LLMCTL_API_KEY by default); the gate, the
#                                                   MCP server, the detector and the opencode plugin then PARSE that
#                                                   one variable out of it at call time - nothing is copied, nothing is
#                                                   sourced, the value is never printed. Standalone: no agent home is
#                                                   touched and no consent is needed)
#             [--check]                            (dry audit — no writes)
#             [--uninstall]
#             [--if-stale <seconds>] [--quiet]
#
# Every write is backup-first, idempotent (marker blocks or jq-merge), and
# atomic (temp file + mv). Offline behavior is honest: anything needing the
# network prints a SKIP note with the exact manual command.
set -uo pipefail

# Resolve the real script dir through symlinks (install.sh links into PATH).
_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _dir="$(cd "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  case "$_src" in /*) : ;; *) _src="$_dir/$_src" ;; esac
done
SCRIPTS_DIR="$(cd "$(dirname "$_src")" && pwd)"
unset _src _dir

SHARED_DIR="${SHARED_DIR:-$HOME/.claude-shared}"
JEV_DIR="$HOME/.local/share/claude-multi-account/jev"
# Same resolution order as claude-providers.sh _cma_jev_state_dir: explicit
# JEV_STATE_DIR, else the isolated providers dir, else the real home.
if [ -z "${JEV_STATE_DIR:-}" ]; then
  if [ -n "${CMA_PROVIDERS_DIR:-}" ]; then JEV_STATE_DIR="$CMA_PROVIDERS_DIR/jev-state"
  else JEV_STATE_DIR="$HOME/.local/state/jev"; fi
fi
JEV_CONFIG_DIR="${JEV_CONFIG_DIR:-$HOME/.config/jev}"   # the same override the gate, the wrappers and the opencode plugin read
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
GATE_INSTALLED="$JEV_DIR/jev-gate.sh"
# Shared Kimi helpers (ONE validator + ONE constant file for BOTH TOML writers:
# this script and claude-providers.sh).
# shellcheck source=jev-kimi-lib.sh
if ! . "$SCRIPTS_DIR/jev-kimi-lib.sh"; then
  printf 'jev-setup: cannot load %s/jev-kimi-lib.sh\n' "$SCRIPTS_DIR" >&2
  exit 1
fi
# shellcheck source=jev-keyfile-lib.sh
if ! . "$SCRIPTS_DIR/jev-keyfile-lib.sh"; then
  printf 'jev-setup: cannot load %s/jev-keyfile-lib.sh\n' "$SCRIPTS_DIR" >&2
  exit 1
fi
KIMI_MATCHER=""        # resolved lazily by _kimi_matcher_init (no built-in fallback copy)
_KIMI_MATCHER_TRIED=0
MCP_SERVER="$SCRIPTS_DIR/jev_mcp.py"
CACHE="${CMA_PROVIDERS_DIR:-$HOME/.local/share/claude-multi-account/providers}/jev-endpoints.json"
OPENCODE_CONFIG="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"

AGENTS="claude,kimi,pi,opencode"
AGENTS_EXPLICIT=0
ALL_AGENTS="claude,kimi,pi,opencode"
MODE="" KEYFILE="" CHECK=0 UNINSTALL=0 QUIET=0 IF_STALE=0 IF_STALE_ON=0 CONSENT="${JEV_SETUP_CONSENT:-0}"
_usage_err() { printf 'jev-setup: %s\n' "$*" >&2; exit 2; }
_need_val() { [ "$1" -ge 2 ] || _usage_err "$2 needs a value"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --agents|--agent) _need_val $# "$1"; AGENTS="$2"; AGENTS_EXPLICIT=1; shift 2 ;;
    --agents=*|--agent=*) AGENTS="${1#*=}"; AGENTS_EXPLICIT=1; shift ;;
    --mode) _need_val $# "$1"; MODE="$2"; shift 2 ;;
    --key-file) _need_val $# "$1"; KEYFILE="$2"; shift 2 ;;
    --key-file=*) KEYFILE="${1#*=}"; shift ;;
    --check) CHECK=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --if-stale) _need_val $# "$1"; IF_STALE="$2"; IF_STALE_ON=1; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    --yes|-y) CONSENT=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'jev-setup: unknown flag %s\n' "$1" >&2; exit 2 ;;
  esac
done

# ---- argument validation (usage errors, rc 2, before ANY write) -------------
# --check is an audit and --uninstall is a write: the combination is ambiguous
# (it used to really uninstall), so it is refused rather than half-honoured.
if [ "$CHECK" = 1 ] && [ "$UNINSTALL" = 1 ]; then
  _usage_err "--check and --uninstall cannot be combined (--check never writes; run them separately)"
fi
case "$IF_STALE" in ''|*[!0-9]*) _usage_err "--if-stale needs a number of seconds, got '$IF_STALE'" ;; esac
# --mode is a closed set: an unknown value used to be written to ~/.config/jev/env verbatim (and then read by nothing).
case "$MODE" in ''|shadow|enforce) : ;; *) _usage_err "--mode '$MODE' is not valid (shadow or enforce)" ;; esac
# --key-file: record WHERE the bearer key lives (a pointer, never the value). Standalone and consent-free: it appends one path
# to the jev key-files pointer and touches no agent home.
if [ -n "$KEYFILE" ]; then
  _ksay() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }   # (_say is defined further down, after the consent gate)
  if [ "$CHECK" = 1 ] || [ "$UNINSTALL" = 1 ] || [ -n "$MODE" ]; then
    _usage_err "--key-file is a standalone action (not combinable with --check, --uninstall or --mode)"
  fi
  _kf="$KEYFILE"
  case "$_kf" in '~/'*) _kf="$HOME/${_kf#\~/}" ;; esac
  case "$_kf" in /*) : ;; *) _kf="$PWD/$_kf" ;; esac
  case "$_kf" in *:* | *$'\n'* | *$'\r'*) _usage_err "--key-file: a path with ':' or a line break cannot be listed" ;; esac
  _kd="$(cd "$(dirname "$_kf")" 2>/dev/null && pwd)" || _usage_err "--key-file: directory of '$KEYFILE' does not exist"
  _kf="$_kd/$(basename "$_kf")"
  [ -f "$_kf" ] || _usage_err "--key-file: '$_kf' is not a regular file"
  [ -r "$_kf" ] || _usage_err "--key-file: '$_kf' is not readable"
  [ -O "$_kf" ] || _usage_err "--key-file: '$_kf' is not owned by the current user (a key file must be yours)"
  _kv=""
  if [ -s "${CACHE:-}" ] && command -v jq >/dev/null 2>&1; then _kv="$(jq -r '.endpoints[0].key_var // ""' "$CACHE" 2>/dev/null)"; fi
  [ -n "$_kv" ] || _kv="LLMCTL_API_KEY"
  # The file must DEFINE the variable (checked by the same parser the consumers use; only the NAME is ever reported).
  if ! CMA_JEV_KEY_FILES="$_kf" JEV_CONFIG_DIR=/nonexistent/jev cma_jev_keyfile_lookup "$_kv" >/dev/null 2>&1; then
    _usage_err "--key-file: '$_kf' does not define $_kv (a NAME=value or export NAME=value line); nothing was recorded"
  fi
  mkdir -p "$JEV_CONFIG_DIR" 2>/dev/null || _usage_err "--key-file: cannot create $JEV_CONFIG_DIR"
  _pf="$JEV_CONFIG_DIR/key-files"
  if [ -f "$_pf" ] && tr -d '\r' < "$_pf" | grep -qxF -- "$_kf"; then
    _ksay "jev-setup: $_kf is already listed in $_pf ($_kv is defined there; the value was not read into any output)"
  else
    _tmp="$(mktemp "$_pf.XXXXXX")" || _usage_err "--key-file: cannot write $_pf"
    { [ -f "$_pf" ] && sed -e '$a\' "$_pf"; printf '%s\n' "$_kf"; } > "$_tmp"
    chmod 600 "$_tmp" 2>/dev/null || true
    mv -f "$_tmp" "$_pf" || _usage_err "--key-file: cannot update $_pf"
    _ksay "jev-setup: recorded $_kf in $_pf ($_kv is defined there; the value was not read into any output)"
  fi
  exit 0
fi
# Agent names are an exact, case-sensitive closed set. An unknown or miscased
# value used to be dropped silently and produced an empty `agents=` stamp.
_validate_agents() { # _validate_agents <csv>
  local csv="$1" a
  local -a _arr
  [ -n "$csv" ] || _usage_err "--agents needs a non-empty list (claude,kimi,pi,opencode or all)"
  # A comma list only: whitespace would be word-split (and glob-expanded) and an
  # empty entry (',' ',,' 'claude,') names nobody - both used to pass silently.
  case "$csv" in *[[:space:]]*) _usage_err "--agents '$csv' contains whitespace: use a comma separated list (claude,kimi,pi,opencode or all)" ;; esac
  case ",$csv," in *,,*) _usage_err "--agents '$csv' has an empty entry: needs a non-empty list (claude,kimi,pi,opencode or all)" ;; esac
  IFS=, read -r -a _arr <<<"$csv"
  for a in "${_arr[@]}"; do
    case "$a" in
      claude|kimi|pi|opencode|all) : ;;
      *) _usage_err "unknown agent '$a' in --agents '$csv' (known, case-sensitive: claude, kimi, pi, opencode, all)" ;;
    esac
  done
}
_validate_agents "$AGENTS"

# CONSENT GATE. This script edits files in agent homes (~/.claude, ~/.kimi-code,
# ~/.pi, ~/.config/opencode ...). It does so only with explicit consent:
# --yes, JEV_SETUP_CONSENT=1, an interactive "y", or - for the launch-time lazy
# --if-stale refresh only - a consent stamp left by an earlier consented run.
# --check never writes and --uninstall only restores, so neither needs it.
if [ "$CHECK" = 0 ] && [ "$UNINSTALL" = 0 ] && [ "$CONSENT" != 1 ]; then
  if [ "$IF_STALE_ON" = 1 ] && [ -f "$JEV_STATE_DIR/consent" ]; then
    CONSENT=1
  elif [ -t 0 ] && [ -t 1 ] && [ "$QUIET" = 0 ]; then
    printf 'jev-setup will edit agent configuration under your home (a backup is made first). Continue? [y/N] ' >&2
    read -r _ans </dev/tty 2>/dev/null || _ans=""
    case "$_ans" in y|Y|yes|YES) CONSENT=1 ;; esac
  fi
  if [ "$CONSENT" != 1 ]; then
    if [ "$IF_STALE_ON" = 0 ] && [ "$QUIET" = 0 ]; then
      printf 'jev-setup: not editing any agent home without consent.\n  Preview: jev-setup --check\n  Apply:   jev-setup --yes   (or JEV_SETUP_CONSENT=1); every edited file is backed up first (*.prejev.<timestamp>)\n' >&2
    fi
    exit 3
  fi
fi
if [ "$CONSENT" = 1 ] && [ "$CHECK" = 0 ] && [ "$UNINSTALL" = 0 ]; then
  mkdir -p "$JEV_STATE_DIR" 2>/dev/null && : > "$JEV_STATE_DIR/consent" 2>/dev/null || true
fi

_say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
_warn() { printf '%s\n' "$*" >&2; }      # never silenced by --quiet
_want() { case ",$AGENTS," in *,"$1",*|*,all,*) return 0 ;; *) return 1 ;; esac }

# ---- the install stamp records WHICH agents were consented to ---------------
# File format: one line `agents=<comma list>`. Its mtime is the --if-stale clock.
# A legacy/empty stamp names nobody (the twin renderer then fails closed).
STAMP_FILE="$JEV_STATE_DIR/installed.stamp"
_canon_agents() { # <csv or all> -> canonical ordered csv of known agents
  local want=",$1," a out=""
  for a in ${ALL_AGENTS//,/ }; do
    case "$want" in *,"$a",*|*,all,*) out="${out:+$out,}$a" ;; esac
  done
  printf '%s' "$out"
}
# Canonicalised: a hand-edited stamp naming only unknown agents reads as EMPTY
# (never widens the scope, never round-trips into an empty `agents=` stamp).
_stamp_agents() { _canon_agents "$(jev_kimi_stamp_agents "$STAMP_FILE")"; }
_stamp_write() { # _stamp_write <csv> — atomic, owner-only
  local csv="$1" tmp
  mkdir -p "$JEV_STATE_DIR" 2>/dev/null || return 0
  tmp="$(umask 077; mktemp "$STAMP_FILE.tmp.XXXXXX")" || return 0
  printf 'agents=%s\n' "$csv" > "$tmp" && mv -f "$tmp" "$STAMP_FILE" || rm -f "$tmp"
}
_csv_union() { _canon_agents "$1,$2"; }
_csv_minus() { # _csv_minus <csv> <remove-csv>
  local a out="" rm_=",$2,"
  for a in ${1//,/ }; do
    case "$rm_" in *,"$a",*|*,all,*) : ;; *) out="${out:+$out,}$a" ;; esac
  done
  printf '%s' "$out"
}

# FAIL-CLOSED: returns 1 (and warns) when the backup cannot be made, and every
# caller then leaves the file untouched - "a backup is made first" must hold.
_backup() { # _backup <file> — copy once per run, only when we will write
  [ -f "$1" ] || return 0
  local dst="$1.prejev.$(date +%Y%m%d%H%M%S)"
  [ -e "$dst" ] && return 0
  if ! cp -p "$1" "$dst" 2>/dev/null; then
    rm -f "$dst" 2>/dev/null
    printf 'jev-setup: backup of %s failed - left untouched (nothing written)\n' "$1" >&2
    return 1
  fi
}

# _jq_merge <file> <jq-program> [args...] — atomic, backup-first, no-op-safe.
# Owner-only permissions throughout: these files can carry provider API keys
# (security review finding: Insecure File Permissions on Credential Writes).
_jq_merge() {
  local file="$1" prog="$2"; shift 2
  [ -f "$file" ] || (umask 077; printf '{}\n' > "$file")
  local tmp; tmp=$(umask 077; mktemp "$file.jevtmp.XXXXXX")
  local _jqerr _jqrc=0
  _jqerr="$(jq "$@" "$prog" "$file" 2>&1 >"$tmp")" || _jqrc=$?
  if [ "$_jqrc" -eq 0 ] && [ -z "$_jqerr" ] && [ -s "$tmp" ]; then
    if cmp -s "$tmp" "$file"; then rm -f "$tmp"; return 0; fi
    _backup "$file" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$file"
    chmod 600 "$file" 2>/dev/null || true
  else
    rm -f "$tmp"
    printf 'jev-setup: jq merge failed for %s - left untouched (jq rc=%s): %s\n' "$file" "$_jqrc" "${_jqerr:-empty result}" >&2
    return 1
  fi
}

# Endpoint material for MCP registrations. The cache is NOT trusted: the key
# variable must be a plain name and the real key is materialised only when the
# base origin is allowed to receive it (loopback, a shipped pin for that same
# key variable, or CMA_JEV_TRUSTED_ORIGINS) - the same rule the gate, the MCP
# server and the plugin apply at send time. Otherwise the placeholder "local"
# is written, never the secret.
_jev_endpoint_env() { # echoes TAB-separated base_url, api_key
  local base="" key="" kv=""
  if [ -s "$CACHE" ] && command -v jq >/dev/null 2>&1; then
    base=$(jq -r '.endpoints[0].base_url // ""' "$CACHE" 2>/dev/null)
    kv=$(jq -r '.endpoints[0].key_var // ""' "$CACHE" 2>/dev/null)
  fi
  case "$kv" in ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*) kv="" ;; esac
  if [ -n "$kv" ] && [ -n "$base" ] && [ -f "${CMA_KEYS_FILE:-$HOME/api_keys.sh}" ] \
     && [ "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import jev_mcp; print(1 if jev_mcp._origin_allows_key(sys.argv[2], sys.argv[3]) else 0)' "$SCRIPTS_DIR" "$base" "$kv" 2>/dev/null)" = 1 ]; then
    key=$(KV="$kv" bash -c 'source "${CMA_KEYS_FILE:-$HOME/api_keys.sh}" >/dev/null 2>&1; printf %s "${!KV:-}"' 7>&-)
  fi
  # NOT resolved here from the jev key files: the MCP server resolves the variable itself at call time, so the secret is never
  # copied into an agent config (an unresolved key is the placeholder "local", which jev_mcp.py treats as "no direct key").
  printf '%s\t%s' "$base" "${key:-local}"
}

# ---------------------------------------------------------------------------
# common
install_common() {
  [ "$CHECK" = 1 ] && { _say "common: would install gate copy, env file, bin links"; return 0; }
  mkdir -p "$JEV_DIR" "$JEV_STATE_DIR" "$JEV_CONFIG_DIR" "$BIN_DIR" "$SHARED_DIR/jev" 2>/dev/null || true
  # Canonical shared gate copy (content-addressed).
  if ! cmp -s "$SCRIPTS_DIR/jev-gate.sh" "$GATE_INSTALLED" 2>/dev/null; then
    cp "$SCRIPTS_DIR/jev-gate.sh" "$GATE_INSTALLED" && chmod +x "$GATE_INSTALLED"
  fi
  cp "$SCRIPTS_DIR/jev-gate.sh" "$SHARED_DIR/jev/jev-gate.sh" 2>/dev/null || true
  chmod +x "$SHARED_DIR/jev/jev-gate.sh" 2>/dev/null || true
  # The gate reads the SHIPPED pins from providers/jev.json next to itself (never
  # from env or cache), so the pins must travel with every installed gate copy;
  # without them the installed gate refuses every hosted endpoint (key_unpinned).
  local _d
  for _d in "$JEV_DIR" "$SHARED_DIR/jev"; do
    mkdir -p "$_d/providers" 2>/dev/null || true
    cp "$SCRIPTS_DIR/providers/jev.json" "$_d/providers/jev.json" 2>/dev/null || true
  done
  # Mode env (non-secret, umask-safe).
  local mode="${MODE:-shadow}"
  if [ ! -f "$JEV_CONFIG_DIR/env" ] || [ -n "$MODE" ]; then
    printf 'JEV_MODE=%s\n' "$mode" > "$JEV_CONFIG_DIR/env"
    chmod 600 "$JEV_CONFIG_DIR/env" 2>/dev/null || true
  fi
  # Convenience bin links (real install.sh links the .sh names; the MCP
  # server is registered by absolute repo path, the link is a convenience).
  [ -e "$BIN_DIR/jev_mcp.py" ] || ln -s "$MCP_SERVER" "$BIN_DIR/jev_mcp.py" 2>/dev/null || true
  # Consent record: WHICH agents were selected (union with earlier runs).
  _stamp_write "$(_csv_union "$(_stamp_agents)" "$AGENTS")"
}

# Inventory of the wiring that is ACTUALLY present for each agent, read from the
# agent homes themselves (never from the stamp alone). Prints a canonical csv.
_inventory_wiring() {
  local found="" home sf
  while IFS= read -r home; do
    sf="$home/settings.json"
    [ -f "$sf" ] && jq -e '[ .hooks.PreToolUse[]? | [ .hooks[]?.command? // "" | contains("jev-gate.sh") ] | any ] | any' "$sf" >/dev/null 2>&1 \
      && { found="$found,claude"; break; }
  done < <(_claude_homes)
  while IFS= read -r home; do
    [ -f "$home/config.toml" ] && grep -qF "$KIMI_HOOK_BEGIN" "$home/config.toml" 2>/dev/null \
      && { found="$found,kimi"; break; }
  done < <(_kimi_homes)
  if [ -e "$HOME/.config/opencode/plugins/jev-gate.js" ] \
     || jq -e '.mcp.jev' "$OPENCODE_CONFIG" >/dev/null 2>&1; then
    found="$found,opencode"
  fi
  _canon_agents "$found"
}

# Shared artifacts are removed ONLY when no agent wiring remains: the canonical
# gate is the target of the Claude hook, the Kimi hook blocks and the twin
# renderer, so deleting it for one agent would dangle the others (review round 2).
uninstall_common() {
  local remaining inv keep
  remaining="$(_csv_minus "$(_stamp_agents)" "$AGENTS")"
  inv="$(_inventory_wiring)"
  keep="$(_csv_union "$remaining" "$inv")"
  if [ -n "$keep" ]; then
    _stamp_write "$keep"
    _say "jev-setup: kept shared artifacts (gate, env, stamp): still wired for: $keep"
    return 0
  fi
  rm -f "$BIN_DIR/jev_mcp.py" "$BIN_DIR/jev-gate.sh" "$BIN_DIR/jev-stats.sh" 2>/dev/null || true
  rm -f "$JEV_CONFIG_DIR/env" "$STAMP_FILE" 2>/dev/null || true
  # The canonical gate copy too: the Kimi twin renderer keys on it (plus the
  # stamp above), so leaving it behind would let the next `claude-providers
  # sync` re-add the hooks block this uninstall just stripped.
  rm -f "$GATE_INSTALLED" 2>/dev/null || true
  rm -f "$JEV_DIR/providers/jev.json" 2>/dev/null || true
  _say "jev-setup: removed common artifacts (state dir $JEV_STATE_DIR kept)"
}

# ---------------------------------------------------------------------------
# Claude Code
_claude_hook_merge='
  .hooks //= {} | .hooks.PreToolUse //= [] |
  ( [ .hooks.PreToolUse[] | [ .hooks[]?.command? // "" | contains("jev-gate.sh") ] | any ] | any ) as $present |
  if $present then .
  else .hooks.PreToolUse += [ { matcher: "Bash|Agent|Task",
        hooks: [ { type: "command", command: $cmd, timeout: 5 } ] } ]
  end |
  .claudeMdExcludes = ( ( (.claudeMdExcludes // []) +
      ["**/vendor/**/CLAUDE.md", "**/node_modules/**/CLAUDE.md"] ) | unique )'

_claude_hook_unmerge='
  .hooks //= {} | .hooks.PreToolUse //= [] |
  .hooks.PreToolUse = [ .hooks.PreToolUse[] |
    select( ( [ .hooks[]?.command? // "" | contains("jev-gate.sh") ] | any ) | not ) ]'

_claude_homes() { # one dir per line: shared seed + all account/provider homes
  [ -d "$SHARED_DIR" ] && printf '%s\n' "$SHARED_DIR"
  local d
  for d in "$HOME"/.claude-* "$HOME"/.claude-prov-*; do
    case "$d" in *[[:cntrl:]]*) continue ;; esac   # line-oriented list: skip unsafe names
    [ -d "$d" ] && printf '%s\n' "$d"
  done
}

CLAUDE_MD_BEGIN='<!-- cma-jev:decision-architecture BEGIN -->'
CLAUDE_MD_END='<!-- cma-jev:decision-architecture END -->'

install_claude() {
  local home sf mcpf changed=0
  local ep_base ep_key IFS_SAVE="$IFS"
  IFS="$(printf '\t')"; read -r ep_base ep_key <<EOF
$(exec 7>&-; _jev_endpoint_env)
EOF
  IFS="$IFS_SAVE"
  while IFS= read -r home; do
    sf="$home/settings.json"
    if [ "$UNINSTALL" = 1 ]; then
      [ -f "$sf" ] && _jq_merge "$sf" "$_claude_hook_unmerge"
      mcpf="$home/.mcp.json"
      [ -f "$mcpf" ] && _jq_merge "$mcpf" 'del(.mcpServers.jev) | if .mcpServers == {} then del(.mcpServers) else . end'
      continue
    fi
    # Seed an empty settings.json only for the shared dir (account homes keep
    # their own-settings convention: never invent one where none exists).
    if [ ! -f "$sf" ]; then
      [ "$home" = "$SHARED_DIR" ] || continue
      [ "$CHECK" = 1 ] || printf '{}\n' > "$sf"
    fi
    if [ "$CHECK" = 1 ]; then
      if jq -e '[ .hooks.PreToolUse[]? | [ .hooks[]?.command? // "" | contains("jev-gate.sh") ] | any ] | any' "$sf" >/dev/null 2>&1; then
        # The string being present is not enough: every registered gate command
        # must resolve to an executable file, or the hook fails open silently.
        local _c _bad=0
        while IFS= read -r _c; do
          [ -n "$_c" ] || continue
          # The hook "command" is a command line, not necessarily a bare path
          # (`bash /x/jev-gate.sh`): the whole string if it is a file, else the
          # token naming the gate.
          if [ ! -e "$_c" ]; then
            # Drop leading words (the interpreter) until the rest names a file, so
            # a gate path that contains spaces still resolves; quotes are stripped.
            local _w="${_c%%jev-gate.sh*}jev-gate.sh"
            while [ ! -e "$_w" ] && [[ "$_w" == *" "* ]]; do _w="${_w#* }"; done
            _w="${_w#[\"\']}"; _w="${_w%[\"\']}"
            case "$_w" in *jev-gate.sh) _c="$_w" ;; esac
          fi
          if [ ! -e "$_c" ]; then _say "claude: $sf hook target $_c MISSING"; _bad=1
          elif [ ! -x "$_c" ]; then _say "claude: $sf hook target $_c not executable"; _bad=1; fi
        done < <(jq -r '.hooks.PreToolUse[]? | .hooks[]?.command? // empty | select(contains("jev-gate.sh"))' "$sf" 2>/dev/null)
        if [ "$_bad" = 0 ]; then _say "claude: $sf hooks OK"; else changed=1; fi
      else
        _say "claude: $sf MISSING jev hook"; changed=1
      fi
    else
      _jq_merge "$sf" "$_claude_hook_merge" --arg cmd "$GATE_INSTALLED"
    fi
    # MCP registration (.mcp.json next to settings.json — the deterministic,
    # offline-safe equivalent of `claude mcp add`).
    mcpf="$home/.mcp.json"
    if [ "$CHECK" = 1 ]; then
      jq -e '.mcpServers.jev' "$mcpf" >/dev/null 2>&1 \
        && _say "claude: $mcpf mcp OK" || { _say "claude: $mcpf MISSING jev mcp"; changed=1; }
    else
      _jq_merge "$mcpf" '.mcpServers //= {} | .mcpServers.jev =
        { command: "python3", args: [$srv],
          env: { TYPESAFE_BASE_URL: $base, TYPESAFE_API_KEY: $key,
                 JEV_BASE_URL: $base, JEV_API_KEY: $key } }' \
        --arg srv "$MCP_SERVER" --arg base "${ep_base:-}" --arg key "${ep_key:-local}"
    fi
  done < <(_claude_homes)

  # CLAUDE.md guarded block (all accounts symlink the shared CLAUDE.md).
  local cmd_file="$SHARED_DIR/CLAUDE.md"
  if [ "$UNINSTALL" = 1 ]; then
    if [ -f "$cmd_file" ] && grep -qF "$CLAUDE_MD_BEGIN" "$cmd_file"; then
      local tmp="$cmd_file.jevtmp.$$"
      if _backup "$cmd_file"; then
        awk -v b="$CLAUDE_MD_BEGIN" -v e="$CLAUDE_MD_END" '
          $0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip { print }
        ' "$cmd_file" > "$tmp" && mv "$tmp" "$cmd_file"
        rm -f "$tmp"
        _say "jev-setup: removed CLAUDE.md decision-architecture block"
      fi
    fi
  elif [ "$CHECK" = 1 ]; then
    if [ -f "$cmd_file" ] && grep -qF "$CLAUDE_MD_BEGIN" "$cmd_file"; then
      _say "claude: CLAUDE.md block OK"
    else
      _say "claude: CLAUDE.md block MISSING"; changed=1
    fi
  else
    mkdir -p "$SHARED_DIR" 2>/dev/null || true
    [ -f "$cmd_file" ] || printf '# Shared Claude Instructions\n' > "$cmd_file"
    if ! grep -qF "$CLAUDE_MD_BEGIN" "$cmd_file" && _backup "$cmd_file"; then
      cat >> "$cmd_file" <<'CLAUDE_MD_EOF'

<!-- cma-jev:decision-architecture BEGIN -->
## Decision architecture (Jev)
- Prefer the `jev_ask` MCP tool for any allow/ask/deny, routing, or truncation judgment instead of reasoning it out in prose; a Jev decision call costs ~$0.000056 and ~70-500 ms.
- When the Jev layer is inactive (JEV inactive notice at launch), fall back to normal judgment.
- Never disable jev-gate.sh hooks without telling the user.
<!-- cma-jev:decision-architecture END -->
CLAUDE_MD_EOF
    fi
  fi
  if [ "$CHECK" = 0 ] && [ "$UNINSTALL" = 0 ]; then
    _say "jev-setup: claude hooks+mcp installed (matcher: Bash|Agent|Task, gate: $GATE_INSTALLED)"
    _say "  user-scope alternative: claude mcp add jev -- python3 $MCP_SERVER"
  fi
  return $changed
}

# ---------------------------------------------------------------------------
# Kimi Code
KIMI_HOOK_BEGIN='# cma-jev:hooks BEGIN'
KIMI_HOOK_END='# cma-jev:hooks END'

_kimi_homes() {
  local d _tr="${CMA_PROVIDERS_DIR:+$CMA_PROVIDERS_DIR/kimi-twins}"
  for d in "$HOME"/.kimi-code-* "${_tr:-$HOME}"/.kimi-prov-*; do
    case "$d" in *[[:cntrl:]]*) continue ;; esac   # line-oriented list: skip unsafe names
    [ -d "$d" ] && printf '%s\n' "$d"
  done
}

# Resolve the matcher from the ONE constant file (warns, once, when it is
# missing or invalid: there is deliberately no private fallback copy).
_kimi_matcher_init() {
  [ "$_KIMI_MATCHER_TRIED" = 1 ] && { [ -n "$KIMI_MATCHER" ]; return; }
  _KIMI_MATCHER_TRIED=1
  local err
  if KIMI_MATCHER="$(jev_kimi_matcher "$SCRIPTS_DIR" 2>/dev/null)" && [ -n "$KIMI_MATCHER" ]; then
    return 0
  fi
  KIMI_MATCHER=""
  err="$(jev_kimi_matcher "$SCRIPTS_DIR" 2>&1 >/dev/null)"
  _warn "jev-setup: kimi - ${err:-jev-kimi-tools.txt unusable}; no hook block is written or verified (fix jev-kimi-tools.txt)"
  return 1
}

# The exact [[hooks]] block this version wants (BEGIN..END, no leading blank).
_kimi_block_desired() {
  printf '%s\n[[hooks]]\nevent = "PreToolUse"\nmatcher = "%s"\ncommand = "%s"\ntimeout = 5\n%s\n' \
    "$KIMI_HOOK_BEGIN" "$KIMI_MATCHER" "$GATE_INSTALLED" "$KIMI_HOOK_END"
}
_kimi_block_current() { # BEGIN..END lines of the existing block
  awk -v b="$KIMI_HOOK_BEGIN" -v e="$KIMI_HOOK_END" '
    $0 == b { on = 1 } on { print } $0 == e { on = 0 }' "$1"
}
# _kimi_block_write <file> strip|set — atomic, backup-first rewrite of the
# marker block. The WHOLE new file is built in a temp (block removed together
# with the blank lines directly in front of it, so repeated rewrites never grow
# the file; then, for `set`, one separator blank line when anything precedes it,
# and the desired block) and moved into place only when every step succeeded.
# An empty remainder is legitimate (a block-only config): only a failed awk/
# write/mv refuses, leaving the original untouched.
_kimi_block_write() {
  local f="$1" mode="$2" tmp
  # A symlinked config.toml is rewritten THROUGH the link (mv over the link
  # would replace the link itself with a regular file and orphan its target).
  [ -L "$f" ] && f="$(jev_realpath "$f" 2>/dev/null || printf '%s' "$f")"
  tmp="$(umask 077; mktemp "$f.jevtmp.XXXXXX")" || { _warn "jev-setup: cannot create a temp file next to $f - left untouched"; return 1; }
  if awk -v b="$KIMI_HOOK_BEGIN" -v e="$KIMI_HOOK_END" '
       skip { if ($0 == e) skip = 0; next }
       $0 == b { skip = 1; pend = 0; next }
       $0 == "" { pend++; next }
       { while (pend > 0) { print ""; pend-- } print }
       END { while (pend > 0) { print ""; pend-- } }' "$f" > "$tmp" \
     && { [ "$mode" != set ] || {
            { [ ! -s "$tmp" ] || printf '\n' >> "$tmp"; } && _kimi_block_desired >> "$tmp"
          }; }; then
    if cmp -s "$tmp" "$f"; then rm -f "$tmp"; return 0; fi
    if _backup "$f" && mv -f "$tmp" "$f"; then chmod 600 "$f" 2>/dev/null || true; return 0; fi
  fi
  rm -f "$tmp"
  _warn "jev-setup: could not rewrite the hooks block of $f - left untouched"
  return 1
}

install_kimi() {
  local home conf mcpf changed=0 ep_base ep_key IFS_SAVE="$IFS" hooks_ok=0
  IFS="$(printf '\t')"; read -r ep_base ep_key <<EOF
$(exec 7>&-; _jev_endpoint_env)
EOF
  IFS="$IFS_SAVE"
  if [ "$UNINSTALL" = 0 ]; then
    # Same validator as the twin renderer: the gate path is emitted inside a TOML
    # basic string, so a backslash, quote or control character would corrupt the
    # config (or inject keys). Refuse loudly instead of writing.
    if ! jev_kimi_gate_path_safe "$GATE_INSTALLED"; then
      _warn "jev-setup: kimi - refusing to write a hook block: the gate path contains a backslash, quote or control character (unsafe in a TOML string): $(printf '%q' "$GATE_INSTALLED")"
    elif _kimi_matcher_init; then
      hooks_ok=1
    fi
  fi
  while IFS= read -r home; do
    conf="$home/config.toml"
    if [ "$UNINSTALL" = 1 ]; then
      if [ -f "$conf" ] && grep -qF "$KIMI_HOOK_BEGIN" "$conf"; then
        _kimi_block_write "$conf" strip
      fi
      mcpf="$home/mcp.json"
      [ -f "$mcpf" ] && _jq_merge "$mcpf" 'del(.mcpServers.jev) | if .mcpServers == {} then del(.mcpServers) else . end'
      continue
    fi
    # Additive [[hooks]] block, comment-marker guarded (TOML ignores comments).
    # Native kimi homes only - kimi-prov homes get this block from the renderer
    # (_cma_kimi_jev_hooks_block) at the next `claude-providers sync`, only while
    # the endpoint cache is non-empty, the stamp lists kimi and the installed gate
    # is executable. --uninstall strips it from both kinds. An existing block that
    # differs from the desired one (an older matcher/command, e.g. the v1.31.0
    # `Bash|WriteFile|StrReplaceFile`) is REWRITTEN, not skipped.
    case "$home" in
      */.kimi-code-*)
        if [ -f "$conf" ]; then
          if [ "$CHECK" = 1 ]; then
            if ! grep -qF "$KIMI_HOOK_BEGIN" "$conf"; then
              _say "kimi: $conf MISSING hooks"; changed=1
            elif ! _kimi_matcher_init; then
              changed=1
            elif [ "$(_kimi_block_current "$conf")" != "$(_kimi_block_desired)" ]; then
              _say "kimi: $conf hooks STALE (matcher/command differ from this version: re-run jev-setup --agents kimi)"; changed=1
            elif [ ! -e "$GATE_INSTALLED" ]; then
              _say "kimi: $conf hook target $GATE_INSTALLED MISSING"; changed=1
            elif [ ! -x "$GATE_INSTALLED" ]; then
              _say "kimi: $conf hook target $GATE_INSTALLED not executable"; changed=1
            else
              _say "kimi: $conf hooks OK"
            fi
          elif [ "$hooks_ok" = 1 ]; then
            if grep -qF "$KIMI_HOOK_BEGIN" "$conf"; then
              if [ "$(_kimi_block_current "$conf")" != "$(_kimi_block_desired)" ]; then
                _kimi_block_write "$conf" set || changed=1
              fi
            else
              _kimi_block_write "$conf" set || changed=1
            fi
          fi
        fi
        ;;
    esac
    # mcp.json for BOTH native and provider homes (create if absent). NOTE:
    # TYPESAFE_API_KEY is materialized here - kimi mcp.json lives in a 0700
    # home, the same secrecy class as kimi's own resolved api_key in
    # config.toml, which the toolkit already writes.
    mcpf="$home/mcp.json"
    if [ "$CHECK" = 1 ]; then
      jq -e '.mcpServers.jev' "$mcpf" >/dev/null 2>&1 \
        && _say "kimi: $mcpf mcp OK" || { _say "kimi: $mcpf MISSING jev mcp"; changed=1; }
    else
      _jq_merge "$mcpf" '.mcpServers //= {} | .mcpServers.jev =
        { command: "python3", args: [$srv],
          env: { TYPESAFE_BASE_URL: $base, TYPESAFE_API_KEY: $key,
                 JEV_BASE_URL: $base, JEV_API_KEY: $key } }' \
        --arg srv "$MCP_SERVER" --arg base "${ep_base:-}" --arg key "${ep_key:-local}"
    fi
  done < <(_kimi_homes)
  [ "$CHECK" = 0 ] && [ "$UNINSTALL" = 0 ] && \
    _say "jev-setup: kimi hooks+mcp installed (run 'claude-providers sync' to render hooks into kimi-prov homes)"
  return $changed
}

# ---------------------------------------------------------------------------
# Pi CLI
install_pi() {
  if [ "$UNINSTALL" = 1 ]; then
    _say "jev-setup: pi — nothing to uninstall (env is delivered by cma_jev_env at launch)"
    return 0
  fi
  # No pi homes => nothing to install into; skip even the npm probe (keeps
  # installs hermetic on hosts without the pi family).
  local _pi_found=0 d
  for d in "$HOME"/.pi-* "$HOME"/.pi-prov-*; do
    [ -d "$d" ] && { _pi_found=1; break; }
  done
  [ "$_pi_found" = 0 ] && { _say "jev-setup: pi — SKIP (no ~/.pi-*/ ~/.pi-prov-* homes)"; return 0; }
  # Verified package name is @riposta/pi-jev (older jev-pi / jev-pi-orchestrator
  # names are wrong/renamed). Network-guarded: honest SKIP when offline.
  if ! command -v npm >/dev/null 2>&1; then
    _say "jev-setup: pi — SKIP (npm not found). Manual: PI_CODING_AGENT_DIR=<home> pi install npm:@riposta/pi-jev"
    return 0
  fi
  if timeout 3 npm view @riposta/pi-jev version >/dev/null 2>&1 7>&-; then
    if [ "$CHECK" = 1 ]; then
      _say "jev-setup: pi — would run: pi install npm:@riposta/pi-jev for each ~/.pi-*/ ~/.pi-prov-*/"
      return 0
    fi
    for d in "$HOME"/.pi-* "$HOME"/.pi-prov-*; do
      [ -d "$d" ] || continue
      PI_CODING_AGENT_DIR="$d" pi install npm:@riposta/pi-jev >/dev/null 2>&1 7>&- \
        && _say "jev-setup: pi — installed @riposta/pi-jev into $d" \
        || _say "jev-setup: pi — install FAILED for $d; manual: PI_CODING_AGENT_DIR=$d pi install npm:@riposta/pi-jev"
    done
  else
    _say "jev-setup: pi — SKIP (offline or npm registry unreachable). Manual: PI_CODING_AGENT_DIR=<home> pi install npm:@riposta/pi-jev"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# OpenCode
install_opencode() {
  local plugin_src="$SCRIPTS_DIR/opencode-jev-plugin.js"
  local plugin_dst="$HOME/.config/opencode/plugins/jev-gate.js"
  local changed=0 ep_base ep_key IFS_SAVE="$IFS"
  IFS="$(printf '\t')"; read -r ep_base ep_key <<EOF
$(exec 7>&-; _jev_endpoint_env)
EOF
  IFS="$IFS_SAVE"
  if [ "$UNINSTALL" = 1 ]; then
    rm -f "$plugin_dst"
    if [ -f "$OPENCODE_CONFIG" ]; then
      _jq_merge "$OPENCODE_CONFIG" '
        del(.mcp.jev) |
        .plugin = ( [ (.plugin // [])[] | select(contains("jev-gate") | not) ] ) |
        if .plugin == [] then del(.plugin) else . end'
    fi
    _say "jev-setup: opencode plugin + mcp entry removed"
    return 0
  fi
  if [ "$CHECK" = 1 ]; then
    cmp -s "$plugin_src" "$plugin_dst" 2>/dev/null \
      && _say "opencode: plugin file OK" || { _say "opencode: plugin file MISSING/stale"; changed=1; }
    jq -e '.mcp.jev' "$OPENCODE_CONFIG" >/dev/null 2>&1 \
      && _say "opencode: mcp entry OK" || { _say "opencode: mcp entry MISSING in $OPENCODE_CONFIG"; changed=1; }
    return $changed
  fi
  mkdir -p "$(dirname "$plugin_dst")" 2>/dev/null || true
  cmp -s "$plugin_src" "$plugin_dst" 2>/dev/null || cp "$plugin_src" "$plugin_dst"
  mkdir -p "$(dirname "$OPENCODE_CONFIG")" 2>/dev/null || true
  _jq_merge "$OPENCODE_CONFIG" '
    .mcp //= {} | .mcp.jev =
      { type: "local", command: ["python3", $srv],
        environment: { TYPESAFE_BASE_URL: $base, TYPESAFE_API_KEY: $key,
                       JEV_BASE_URL: $base, JEV_API_KEY: $key } } |
    .plugin = ( ( (.plugin // []) + ["file://" + $plug] ) | unique )' \
    --arg srv "$MCP_SERVER" --arg plug "$plugin_dst" \
    --arg base "${ep_base:-}" --arg key "${ep_key:-local}"
  _say "jev-setup: opencode plugin + mcp installed ($plugin_dst)"
  _say "  CAVEAT: tool.execute.before does NOT intercept MCP tool calls (upstream #2319)"
  _say "          or subagent tool calls (#5894) — the gate covers built-in tools only."
  return 0
}

# ---- serialise the config writes (R4-1, narrowed in R5-6) ---------------------
# The stamp/consent state and every Kimi config rewrite are read-modify-write units:
# a concurrent `claude-providers sync-jev` (twin refresh) or a second jev-setup must
# not interleave with them. The twin writers take the same lock (jev_kimi_lock) and
# recompute the hook block under it, so whichever runs second sees the first one's
# result. The lock is held ONLY around those sections (_lk .. _ulk): never across the
# pi/npm installers, and `7>&-` keeps lock fd 7 away from every child that could
# outlive us (the pi/npm calls and the keys-file sourcing). --check never writes and takes none.
_lk() {
  [ "$CHECK" = 1 ] && return 0
  if ! jev_kimi_lock "$JEV_STATE_DIR"; then
    printf 'jev-setup: could not take the config lock %s/kimi-config.lock (another run holds it?) - remaining steps skipped\n' "$JEV_STATE_DIR" >&2
    exit 1
  fi
}
_ulk() { [ "$CHECK" = 1 ] || jev_kimi_unlock; }
if [ "$CHECK" = 0 ]; then
  trap jev_kimi_unlock_force EXIT
  # Pre-flight: fail BEFORE anything is written when the lock cannot be taken.
  if ! jev_kimi_lock "$JEV_STATE_DIR"; then
    printf 'jev-setup: could not take the config lock %s/kimi-config.lock (another run holds it?) - nothing written\n' "$JEV_STATE_DIR" >&2
    exit 1
  fi
  jev_kimi_unlock
fi

# ---- scope resolution (needs _inventory_wiring, defined above) --------------
# --if-stale: launch-time lazy refresh. Nothing in the toolkit calls it today
# (cma_jev_env only spawns `claude-providers sync-jev --quiet` in the
# background); it exists for an explicit/cron-style refresh. It NEVER widens the
# consented scope: without --agents it refreshes exactly the agents the stamp
# records, and for a legacy/empty/absent stamp exactly the agents whose wiring is
# really present (the inventory) - and nothing at all when nothing is wired.
if [ "$IF_STALE_ON" = 1 ] && [ "$UNINSTALL" = 0 ] && [ "$CHECK" = 0 ]; then
  if [ -f "$STAMP_FILE" ]; then
    _now=$(date +%s); _mt=$(stat -c %Y "$STAMP_FILE" 2>/dev/null || stat -f %m "$STAMP_FILE" 2>/dev/null || echo 0)
    [ $(( _now - _mt )) -lt "$IF_STALE" ] && exit 0
  fi
  if [ "$AGENTS_EXPLICIT" = 0 ]; then
    _sa="$(_stamp_agents)"
    [ -n "$_sa" ] || _sa="$(_inventory_wiring)"
    [ -n "$_sa" ] || exit 0
    AGENTS="$_sa"
  fi
fi
# --check without --agents audits the recorded scope (stamp), else what is
# really wired, and only when neither exists every agent.
if [ "$CHECK" = 1 ] && [ "$AGENTS_EXPLICIT" = 0 ]; then
  _sa="$(_stamp_agents)"
  [ -n "$_sa" ] || _sa="$(_inventory_wiring)"
  [ -n "$_sa" ] && AGENTS="$_sa"
fi

# ---------------------------------------------------------------------------
if [ "$UNINSTALL" = 1 ]; then
  # Per-agent uninstalls FIRST; shared artifacts only afterwards, and only when
  # no wiring (stamp or inventory) remains.
  _want claude   && install_claude
  _want kimi     && { _lk; install_kimi; _ulk; }
  _want pi       && install_pi
  _want opencode && install_opencode
  [ "$CHECK" = 1 ] || { _lk; uninstall_common; _ulk; }
  exit 0
fi
_lk; install_common; _ulk
_rc=0
_want claude   && { install_claude   || _rc=1; }
_want kimi     && { _lk; install_kimi || _rc=1; _ulk; }
_want pi       && { install_pi       || _rc=1; }
_want opencode && { install_opencode || _rc=1; }
# --check is an audit: a finding is a non-zero exit (install modes always return 0
# from the agent installers, so this changes nothing for them).
[ "$CHECK" = 1 ] && exit "$_rc"
exit 0
