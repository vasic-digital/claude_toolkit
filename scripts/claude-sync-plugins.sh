#!/usr/bin/env bash
# claude-sync-plugins.sh -- propagate the operator's curated plugin / MCP set
# (the plugins, MCP servers and skills they DISABLED to save tokens) to EVERY
# Claude Code alias: claude1..N, every provider alias (~/.claude-prov-*), the
# default ~/.claude and the shared settings template -- deterministically and
# idempotently. Added in v1.34.0.
#
# Source of truth: one alias (default ~/.claude-claude1), edited by the operator
# with /plugin and /mcp. Where each kind of disablement physically lives:
#   plugins (and the skills / MCP servers / agents they bundle)
#                     <alias>/settings.json  .enabledPlugins  {"name@mkt": bool}
#   MCP servers       <alias>/.claude.json   .projects[<path>].disabledMcpServers
#                     (["plugin:<plugin>:<server>", ...], per project)
# A disabled plugin contributes no skills, MCP tools or agents, so the plugin
# map is what actually removes tokens from a session.
#
# Commands:
#   capture [--from DIR]  write $SHARED_DIR/plugin-policy.json from DIR
#                         (default ~/.claude-claude1)
#   --dry-run             report what --apply would change; writes nothing
#   --apply               enforce the policy everywhere (backs up every file it
#                         changes + writes a manifest first); the source alias
#                         is never written
#   --verify              read-only check; exit 0 conformant, 1 drift, 2 no policy
#   --status              one line per alias: enabled/total plugin counts
# Options: --backup-dir DIR  (default $SHARED_DIR/policy-backups/<timestamp>)
#
# Semantics:
#   * enabledPlugins: policy keys are applied verbatim; a plugin key the target
#     has that the policy does not list is set FALSE (unknown => disabled).
#     Every other key of settings.json (hooks, env, model, permissions, ...)
#     is preserved untouched.
#   * disabledMcpServers: union of the source's per-project lists is ADDED to
#     every project entry of every other alias's .claude.json (never removed).
#     Projects the alias has not opened yet get the list on the next launch,
#     because claude-sync-state (run by every alias wrapper) re-enforces it.
#   * The policy follows the source: when the source alias's settings.json or
#     .claude.json is newer than the policy, the launch-time hook re-captures
#     it, so /plugin changes in claude1 reach every alias on its next launch.
#   * New aliases inherit it: cma_own_settings_seed (add-account, providers
#     sync, bootstrap, unify) and cma_enable_plugins enforce the policy.
#   * Opt out: CMA_PLUGIN_POLICY=off. No captured policy => everything no-ops.
#
# Exit: 0 ok, 1 drift (verify) / failure, 2 usage / no policy / cannot determine.
set -euo pipefail

_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _tgt="$(readlink "$_src")"
  case "$_tgt" in /*) _src="$_tgt" ;; *) _src="$(dirname "$_src")/$_tgt" ;; esac
done
LIB_DIR="$(cd "$(dirname "$_src")" && pwd)"
unset _src _tgt
# shellcheck source=lib.sh
source "$LIB_DIR/lib.sh"
cma_require jq

SHARED_DIR="${SHARED_DIR:-$HOME/.claude-shared}"
DEFAULT_DIR="${DEFAULT_DIR:-$HOME/.claude}"

usage() { sed -n '2,46p' "$0"; }

cmd="" from="$HOME/.claude-claude1" backup_dir=""
while (( $# )); do
  case "$1" in
    capture) cmd=capture ;;
    --dry-run) cmd=dry-run ;;
    --apply) cmd=apply ;;
    --verify) cmd=verify ;;
    --status) cmd=status ;;
    --from) from="${2:?--from needs a dir}"; shift ;;
    --backup-dir) backup_dir="${2:?--backup-dir needs a dir}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$cmd" ]] || { usage >&2; exit 2; }

_count() { jq -r '[(.enabledPlugins // {}) | to_entries[] | select(.value == true)] | length' "$1" 2>/dev/null || echo "?"; }
_total() { jq -r '(.enabledPlugins // {}) | length' "$1" 2>/dev/null || echo "?"; }

if [[ "$cmd" == capture ]]; then
  [[ -d "$from" ]] || { echo "capture: source dir not found: $from" >&2; exit 2; }
  from="$(cd "$from" && pwd)"
  cma_policy_capture "$from" || { echo "capture FAILED" >&2; exit 2; }
  pf="$(cma_policy_file)"
  echo "policy: $pf"
  echo "source: $from"
  jq -r '"enabled plugins: \([.enabledPlugins[] | select(. == true)] | length) true / \(.enabledPlugins | length) listed; disabledMcpServers: \(.disabledMcpServers | length)"' "$pf"
  exit 0
fi

if ! cma_policy_active; then
  echo "no captured policy at $(cma_policy_file) (or CMA_PLUGIN_POLICY=off) - run: claude-sync-plugins capture" >&2
  exit 2
fi
pf="$(cma_policy_file)"
src="$(cma_policy_source_dir)"

# Targets: shared template (settings only) + every managed dir + default.
targets=("$SHARED_DIR")
while IFS= read -r d; do [[ -n "$d" ]] && targets+=("$d"); done < <(cma_policy_targets)

if [[ "$cmd" == status ]]; then
  printf '%-34s %s\n' "policy ($src)" "$(jq -r '[.enabledPlugins[] | select(. == true)] | length' "$pf")/$(jq -r '.enabledPlugins | length' "$pf") enabled"
  for d in "${targets[@]}"; do
    [[ -f "$d/settings.json" ]] || continue
    printf '%-34s %s/%s enabled\n' "$d" "$(_count "$d/settings.json")" "$(_total "$d/settings.json")"
  done
  exit 0
fi

# ---- apply / dry-run / verify share one pass over the targets ---------------
mode_arg=check; [[ "$cmd" == apply ]] && mode_arg=apply
drift=0 changed=0 errors=0 n=0
ts="$(date +%Y%m%d-%H%M%S)"
[[ -n "$backup_dir" ]] || backup_dir="$SHARED_DIR/policy-backups/$ts"
manifest="$backup_dir/manifest.tsv"
if [[ "$cmd" == apply ]]; then
  mkdir -p "$backup_dir"; chmod 700 "$backup_dir" 2>/dev/null || true
  printf 'path\tsha256_before\tbackup\n' > "$manifest"
fi
_sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

_backup() {  # _backup FILE  -- copy next to the manifest, record hash
  local f="$1" key; key="$(printf '%s' "$f" | tr '/' '_')"
  cp -p "$f" "$backup_dir/$key"
  printf '%s\t%s\t%s\n' "$f" "$(_sha "$f")" "$backup_dir/$key" >> "$manifest"
}

# Source drift: the policy is stale when the source has moved on.
if [[ -n "$src" ]] && [[ -f "$src/settings.json" ]]; then
  if ! jq -e --slurpfile p "$pf" '(.enabledPlugins // {} | to_entries | sort_by(.key)) == ($p[0].enabledPlugins | to_entries | sort_by(.key))' "$src/settings.json" >/dev/null 2>&1; then
    echo "NOTE: source $src enabledPlugins differs from the captured policy (policy is stale; run: claude-sync-plugins capture)"
    [[ "$cmd" == verify ]] && drift=$((drift+1))
  fi
fi

for d in "${targets[@]}"; do
  [[ -d "$d" ]] || continue
  n=$((n+1))
  for kind in settings claude_json; do
    if [[ "$kind" == settings ]]; then f="$d/settings.json"; fn=cma_policy_enforce_settings
    else
      [[ "$d" == "$SHARED_DIR" ]] && continue
      f="$d/.claude.json"; fn=cma_policy_enforce_claude_json
      [[ ! -e "$f" && "$d" == "$DEFAULT_DIR" ]] && f="$HOME/.claude.json"
    fi
    [[ -e "$f" ]] || continue
    if [[ "$cmd" == apply ]]; then
      st="$($fn "$d" check 2>/dev/null)" || true
      if [[ "$st" == would-change ]]; then
        real="$f"; [[ -L "$f" ]] && real="$(cma_realpath "$f")"
        _backup "$real"
        st="$($fn "$d" apply 2>/dev/null)" || true
      fi
    else
      st="$($fn "$d" check 2>/dev/null)" || true
    fi
    case "$st" in
      ok|source|absent) ;;
      changed) changed=$((changed+1)) ;;
      would-change) drift=$((drift+1)) ;;
      *) errors=$((errors+1)) ;;
    esac
    [[ "$cmd" == verify && "$st" == ok ]] && continue
    printf '%-9s %-12s %s\n' "$st" "$kind" "$d"
  done
done

echo "---"
echo "policy: $pf (source: ${src:-?})"
echo "targets scanned: $n   changed: $changed   would-change/drift: $drift   errors: $errors"
[[ "$cmd" == apply && "$changed" -gt 0 ]] && echo "backups + manifest: $backup_dir"
if [[ "$cmd" == apply ]]; then
  # re-check: apply must leave zero drift
  post=0
  for d in "${targets[@]}"; do
    [[ -d "$d" ]] || continue
    s="$(cma_policy_enforce_settings "$d" check 2>/dev/null || true)"
    [[ "$s" == would-change ]] && post=$((post+1))
    if [[ "$d" != "$SHARED_DIR" ]]; then
      s="$(cma_policy_enforce_claude_json "$d" check 2>/dev/null || true)"
      [[ "$s" == would-change ]] && post=$((post+1))
    fi
  done
  echo "post-apply drift: $post"
  (( post == 0 && errors == 0 )) || exit 1
  exit 0
fi
if [[ "$cmd" == verify ]]; then
  (( drift == 0 && errors == 0 )) && { echo "VERIFY: conformant"; exit 0; }
  echo "VERIFY: DRIFT" >&2; exit 1
fi
exit 0
