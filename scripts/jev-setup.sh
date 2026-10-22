#!/usr/bin/env bash
# jev-setup.sh — idempotent installer for the Jev decision layer
# (design: toolkit-jev-design §2.4).
#
# Usage:
#   jev-setup [--agents claude,kimi,pi,opencode]   (default: all)
#             [--mode shadow|enforce]              (writes ~/.config/jev/env)
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
JEV_STATE_DIR="${JEV_STATE_DIR:-$HOME/.local/state/jev}"
JEV_CONFIG_DIR="$HOME/.config/jev"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
GATE_INSTALLED="$JEV_DIR/jev-gate.sh"
MCP_SERVER="$SCRIPTS_DIR/jev_mcp.py"
CACHE="$HOME/.local/share/claude-multi-account/providers/jev-endpoints.json"
OPENCODE_CONFIG="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"

AGENTS="claude,kimi,pi,opencode"
MODE="" CHECK=0 UNINSTALL=0 QUIET=0 IF_STALE=0 CONSENT="${JEV_SETUP_CONSENT:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --agents|--agent) AGENTS="$2"; shift 2 ;;
    --agents=*|--agent=*) AGENTS="${1#*=}"; shift ;;
    --mode) MODE="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --if-stale) IF_STALE="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    --yes|-y) CONSENT=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'jev-setup: unknown flag %s\n' "$1" >&2; exit 2 ;;
  esac
done

# CONSENT GATE. This script edits files in agent homes (~/.claude, ~/.kimi-code,
# ~/.pi, ~/.config/opencode ...). It does so only with explicit consent:
# --yes, JEV_SETUP_CONSENT=1, an interactive "y", or - for the launch-time lazy
# --if-stale refresh only - a consent stamp left by an earlier consented run.
# --check never writes and --uninstall only restores, so neither needs it.
if [ "$CHECK" = 0 ] && [ "$UNINSTALL" = 0 ] && [ "$CONSENT" != 1 ]; then
  if [ "$IF_STALE" -gt 0 ] && [ -f "$JEV_STATE_DIR/consent" ]; then
    CONSENT=1
  elif [ -t 0 ] && [ -t 1 ] && [ "$QUIET" = 0 ]; then
    printf 'jev-setup will edit agent configuration under your home (a backup is made first). Continue? [y/N] ' >&2
    read -r _ans </dev/tty 2>/dev/null || _ans=""
    case "$_ans" in y|Y|yes|YES) CONSENT=1 ;; esac
  fi
  if [ "$CONSENT" != 1 ]; then
    if [ "$IF_STALE" -le 0 ] && [ "$QUIET" = 0 ]; then
      printf 'jev-setup: not editing any agent home without consent.\n  Preview: jev-setup --check\n  Apply:   jev-setup --yes   (or JEV_SETUP_CONSENT=1); every edited file is backed up first (*.prejev.<timestamp>)\n' >&2
    fi
    exit 3
  fi
fi
if [ "$CONSENT" = 1 ] && [ "$CHECK" = 0 ] && [ "$UNINSTALL" = 0 ]; then
  mkdir -p "$JEV_STATE_DIR" 2>/dev/null && : > "$JEV_STATE_DIR/consent" 2>/dev/null || true
fi

_say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
_want() { case ",$AGENTS," in *,"$1",*|*,all,*) return 0 ;; *) return 1 ;; esac }

# --if-stale: launch-time lazy refresh hook (cma_jev_env calls this).
if [ "$IF_STALE" -gt 0 ] && [ "$UNINSTALL" = 0 ] && [ "$CHECK" = 0 ]; then
  _stamp="$JEV_STATE_DIR/installed.stamp"
  if [ -f "$_stamp" ]; then
    _now=$(date +%s); _mt=$(stat -c %Y "$_stamp" 2>/dev/null || stat -f %m "$_stamp" 2>/dev/null || echo 0)
    [ $(( _now - _mt )) -lt "$IF_STALE" ] && exit 0
  fi
fi

_backup() { # _backup <file> — copy once per run, only when we will write
  [ -f "$1" ] || return 0
  local dst="$1.prejev.$(date +%Y%m%d%H%M%S)"
  [ -e "$dst" ] || cp -p "$1" "$dst" 2>/dev/null || true
}

# _jq_merge <file> <jq-program> [args...] — atomic, backup-first, no-op-safe.
# Owner-only permissions throughout: these files can carry provider API keys
# (security review finding: Insecure File Permissions on Credential Writes).
_jq_merge() {
  local file="$1" prog="$2"; shift 2
  [ -f "$file" ] || (umask 077; printf '{}\n' > "$file")
  local tmp; tmp=$(umask 077; mktemp "$file.jevtmp.XXXXXX")
  local _jqerr; _jqerr="$(jq "$@" "$prog" "$file" 2>&1 >"$tmp")"
  if [ -z "$_jqerr" ] && [ -s "$tmp" ]; then
    if cmp -s "$tmp" "$file"; then rm -f "$tmp"; return 0; fi
    _backup "$file"
    mv "$tmp" "$file"
    chmod 600 "$file" 2>/dev/null || true
  else
    rm -f "$tmp"
    printf 'jev-setup: jq merge failed for %s - left untouched: %s\n' "$file" "${_jqerr:-empty result}" >&2
    return 1
  fi
}

# Endpoint material for MCP registrations (cache + keys file; key var NAME
# resolved at install time into agent-local config only).
_jev_endpoint_env() { # echoes TAB-separated base_url, api_key
  local base="" key="" kv=""
  if [ -s "$CACHE" ] && command -v jq >/dev/null 2>&1; then
    base=$(jq -r '.endpoints[0].base_url // ""' "$CACHE" 2>/dev/null)
    kv=$(jq -r '.endpoints[0].key_var // ""' "$CACHE" 2>/dev/null)
  fi
  if [ -n "$kv" ] && [ -f "${CMA_KEYS_FILE:-$HOME/api_keys.sh}" ]; then
    key=$(bash -c 'source "${CMA_KEYS_FILE:-$HOME/api_keys.sh}" >/dev/null 2>&1; printf %s "${'"$kv"':-}"')
  fi
  printf '%s\t%s' "$base" "${key:-local}"
}

# ---------------------------------------------------------------------------
# common
install_common() {
  if [ "$UNINSTALL" = 1 ]; then
    rm -f "$BIN_DIR/jev_mcp.py" "$BIN_DIR/jev-gate.sh" "$BIN_DIR/jev-stats.sh" 2>/dev/null || true
    rm -f "$JEV_CONFIG_DIR/env" "$JEV_STATE_DIR/installed.stamp" 2>/dev/null || true
    _say "jev-setup: removed common artifacts (state dir $JEV_STATE_DIR kept)"
    return 0
  fi
  [ "$CHECK" = 1 ] && { _say "common: would install gate copy, env file, bin links"; return 0; }
  mkdir -p "$JEV_DIR" "$JEV_STATE_DIR" "$JEV_CONFIG_DIR" "$BIN_DIR" "$SHARED_DIR/jev" 2>/dev/null || true
  # Canonical shared gate copy (content-addressed).
  if ! cmp -s "$SCRIPTS_DIR/jev-gate.sh" "$GATE_INSTALLED" 2>/dev/null; then
    cp "$SCRIPTS_DIR/jev-gate.sh" "$GATE_INSTALLED" && chmod +x "$GATE_INSTALLED"
  fi
  cp "$SCRIPTS_DIR/jev-gate.sh" "$SHARED_DIR/jev/jev-gate.sh" 2>/dev/null || true
  chmod +x "$SHARED_DIR/jev/jev-gate.sh" 2>/dev/null || true
  # Mode env (non-secret, umask-safe).
  local mode="${MODE:-shadow}"
  if [ ! -f "$JEV_CONFIG_DIR/env" ] || [ -n "$MODE" ]; then
    printf 'JEV_MODE=%s\n' "$mode" > "$JEV_CONFIG_DIR/env"
    chmod 600 "$JEV_CONFIG_DIR/env" 2>/dev/null || true
  fi
  # Convenience bin links (real install.sh links the .sh names; the MCP
  # server is registered by absolute repo path, the link is a convenience).
  [ -e "$BIN_DIR/jev_mcp.py" ] || ln -s "$MCP_SERVER" "$BIN_DIR/jev_mcp.py" 2>/dev/null || true
  touch "$JEV_STATE_DIR/installed.stamp"
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
    [ -d "$d" ] && printf '%s\n' "$d"
  done
}

CLAUDE_MD_BEGIN='<!-- cma-jev:decision-architecture BEGIN -->'
CLAUDE_MD_END='<!-- cma-jev:decision-architecture END -->'

install_claude() {
  local home sf mcpf changed=0
  local ep_base ep_key IFS_SAVE="$IFS"
  IFS="$(printf '\t')"; read -r ep_base ep_key <<EOF
$(_jev_endpoint_env)
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
        _say "claude: $sf hooks OK"
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
      _backup "$cmd_file"
      local tmp="$cmd_file.jevtmp.$$"
      awk -v b="$CLAUDE_MD_BEGIN" -v e="$CLAUDE_MD_END" '
        $0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip { print }
      ' "$cmd_file" > "$tmp" && mv "$tmp" "$cmd_file"
      _say "jev-setup: removed CLAUDE.md decision-architecture block"
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
    if ! grep -qF "$CLAUDE_MD_BEGIN" "$cmd_file"; then
      _backup "$cmd_file"
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
  local d
  for d in "$HOME"/.kimi-code-* "$HOME"/.kimi-prov-*; do
    [ -d "$d" ] && printf '%s\n' "$d"
  done
}

install_kimi() {
  local home conf mcpf changed=0 ep_base ep_key IFS_SAVE="$IFS"
  IFS="$(printf '\t')"; read -r ep_base ep_key <<EOF
$(_jev_endpoint_env)
EOF
  IFS="$IFS_SAVE"
  while IFS= read -r home; do
    conf="$home/config.toml"
    if [ "$UNINSTALL" = 1 ]; then
      if [ -f "$conf" ] && grep -qF "$KIMI_HOOK_BEGIN" "$conf"; then
        _backup "$conf"
        local tmp="$conf.jevtmp.$$"
        awk -v b="$KIMI_HOOK_BEGIN" -v e="$KIMI_HOOK_END" '
          $0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip { print }
        ' "$conf" > "$tmp" && mv "$tmp" "$conf"
      fi
      mcpf="$home/mcp.json"
      [ -f "$mcpf" ] && _jq_merge "$mcpf" 'del(.mcpServers.jev) | if .mcpServers == {} then del(.mcpServers) else . end'
      continue
    fi
    # Additive [[hooks]] block, comment-marker guarded (TOML ignores comments;
    # skip when present). Native kimi homes only — kimi-prov homes get this
    # block from the renderer (_cma_kimi_jev_hooks_block) at the next
    # `claude-providers sync`, only while the endpoint cache is non-empty and
    # the installed gate is executable. --uninstall strips it from both kinds.
    case "$home" in
      */.kimi-code-*)
        if [ -f "$conf" ]; then
          if [ "$CHECK" = 1 ]; then
            grep -qF "$KIMI_HOOK_BEGIN" "$conf" \
              && _say "kimi: $conf hooks OK" || { _say "kimi: $conf MISSING hooks"; changed=1; }
          elif ! grep -qF "$KIMI_HOOK_BEGIN" "$conf"; then
            _backup "$conf"
            cat >> "$conf" <<KIMI_HOOK_EOF

$KIMI_HOOK_BEGIN
[[hooks]]
event = "PreToolUse"
matcher = "Bash|WriteFile|StrReplaceFile"
command = "$GATE_INSTALLED"
timeout = 5
$KIMI_HOOK_END
KIMI_HOOK_EOF
          fi
        fi
        ;;
    esac
    # mcp.json for BOTH native and provider homes (create if absent). NOTE:
    # TYPESAFE_API_KEY is materialized here — kimi mcp.json lives in a 0700
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
  if timeout 3 npm view @riposta/pi-jev version >/dev/null 2>&1; then
    if [ "$CHECK" = 1 ]; then
      _say "jev-setup: pi — would run: pi install npm:@riposta/pi-jev for each ~/.pi-*/ ~/.pi-prov-*/"
      return 0
    fi
    for d in "$HOME"/.pi-* "$HOME"/.pi-prov-*; do
      [ -d "$d" ] || continue
      PI_CODING_AGENT_DIR="$d" pi install npm:@riposta/pi-jev >/dev/null 2>&1 \
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
$(_jev_endpoint_env)
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

# ---------------------------------------------------------------------------
install_common
_want claude   && install_claude
_want kimi     && install_kimi
_want pi       && install_pi
_want opencode && install_opencode
exit 0
