#!/usr/bin/env bash
# kimi-providers.sh — thin dispatch wrapper around the claude-providers engine,
# for the Kimi Code CLI family (v1.27.0).
#
# Every provider id has BOTH a Claude twin (`<id>` alias, exists today) and a
# Kimi twin (`kimi-<id>` alias that runs `cma_run_kimi_provider <id>`), sharing
# ONE status.json record. This wrapper is the operator's Kimi-framed view:
#   * sync / show / verify / remove / prune / add / migrate-names — forwarded
#     verbatim to the engine (which emits/updates the kimi-<id> twins itself).
#   * list / list-all / list-faulty — the engine's table repeated per AGENT:
#     the Claude alias (agent=claude) and its kimi-<id> twin (agent=kimi).
#     kc-* and kimi-* ids never have a twin and appear once.
#
# Namespace contract (see AGENTS.md): claudeN/kimiN are native accounts; a bare
# <id> is always Claude over that backend; kimi-<id> is always Kimi Code over
# the same backend; kc-<id> is Claude over a Kimi-native backend.
set -euo pipefail

# Resolve this script's real dir THROUGH any symlinks, the same readlink idiom
# claude-proxy-build.sh uses. Without it, SCRIPT_DIR resolved to the PATH dir
# (install.sh links this script into ~/.local/bin) and ENGINE pointed at
# ~/.local/bin/claude-providers.sh — a file that does not exist there, because
# the PATH link is named `claude-providers`, with no `.sh`. Every subcommand
# was therefore broken WHEN RUN FROM PATH, which is the only way an operator
# runs it: the `exec` branch died with 127, and the list branch — whose stderr
# is discarded — printed "No provider aliases installed", i.e. it reported an
# empty inventory for a wrapper that could not find its own engine.
_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _tgt="$(readlink "$_src")"
  case "$_tgt" in /*) _src="$_tgt" ;; *) _src="$(dirname "$_src")/$_tgt" ;; esac
done
SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"
unset _src _tgt
ENGINE="$SCRIPT_DIR/claude-providers.sh"
# A missing engine is now a NAMED hard error, never a silently empty table.
[[ -f "$ENGINE" ]] || {
  printf 'kimi-providers: engine not found: %s\n' "$ENGINE" >&2
  printf '  This wrapper must sit beside claude-providers.sh in the toolkit checkout.\n' >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: kimi-providers <subcommand> [args...]

Subcommands:
  sync [<id>]   discover + create/refresh provider aliases, their kimi-<id>
                twin aliases, and each twin's ~/.kimi-prov-<id>/config.toml
  list          list verified providers, one claude row + one kimi row each
  list-all      list every installed provider (any status), both agents
  list-faulty   list aliases with an issue, both agents
  show <id>     show details for one provider
  verify <id>   re-run verification for one provider
  remove <id>   remove a provider (+ its kimi-<id> twin + config dirs, backed up)
  prune [--dry-run] [--unresolved]   report/remove orphaned providers
  migrate-names  one-time, idempotent kimi-* -> kc-* provider id rename

All engine flags are forwarded unchanged (--keys-file, --no-verify, --offline,
--multi, --include-paid, --max-aliases, ...).
EOF
}

SUBCMD="${1:-}"
case "$SUBCMD" in
  ""|-h|--help) usage; exit 0 ;;
  list|list-all|list-faulty) shift ;;
  # Everything else is the engine's business — forward verbatim. KIMI_ALIASES
  # defaults ON in the engine; a caller can still opt out per run.
  *) exec "$ENGINE" "$@" ;;
esac

# Reuse the engine's table (fixed-width printf; no field contains a space), then
# expand each data row into per-agent rows. The engine's own header is dropped.
# `|| true` used to swallow the engine's exit status as well as its stderr, so
# an engine that CRASHED was indistinguishable from one that found nothing —
# and the empty-inventory message was printed over the failure. Keep stderr
# quiet (the engine is chatty on the happy path) but honour the exit status.
set +e
output="$(KIMI_ALIASES=0 bash "$ENGINE" "$SUBCMD" "$@" 2>/dev/null)"
engine_rc=$?
set -e
if (( engine_rc != 0 )); then
  printf 'kimi-providers: engine failed (exit %d) running: claude-providers %s\n' \
    "$engine_rc" "$SUBCMD" >&2
  printf '  Re-run it directly to see the error:  claude-providers %s\n' "$SUBCMD" >&2
  exit "$engine_rc"
fi
if ! printf '%s' "$output" | grep -qE '^[[:space:]]*ALIAS[[:space:]]'; then
  printf '%s\n' "${output:-No provider aliases installed. Run: kimi-providers sync}"
  exit 0
fi

# WHICH TWINS ACTUALLY EXIST. The kimi row used to be SYNTHESIZED for every
# non-kc/non-kimi provider and handed the CLAUDE row's status verbatim, so the
# table asserted a twin it had never checked for. Observed on the operator's
# host: `kimi-helixllm-anton-...` was listed `verified` while the engine had
# emitted neither its alias nor its ~/.kimi-prov-<id>/config.toml — a listed
# alias that could not launch, which is the exact bluff this table must not
# produce. A twin is REAL only when BOTH artifacts the engine writes are on
# disk; anything else is drift and is reported as `no-twin`, never dropped
# silently (a missing row would hide the drift just as effectively as a
# fabricated one).
_alias_file="${ALIAS_FILE:-$HOME/.local/share/claude-multi-account/aliases.sh}"
wired=" "
if [[ -f "$_alias_file" ]]; then
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    [[ -f "$HOME/.kimi-prov-$t/config.toml" ]] && wired+="$t "
  done < <(grep -oE '^alias kimi-[A-Za-z0-9._-]+=' "$_alias_file" 2>/dev/null \
           | sed -e 's/^alias kimi-//' -e 's/=$//')
fi

printf '%-6s %-14s %-16s %-10s %-12s %-24s\n' AGENT ALIAS PROVIDER STATUS LAYER STRONG_MODEL
printf '%s\n' "$output" | awk -F' ' -v wired="$wired" '
  $1 == "ALIAS" { next }
  NF < 5 { next }
  {
    alias=$1; pid=$2; status=$3; layer=$4; model=$5
    printf "%-6s %-14s %-16s %-10s %-12s %-24s\n", "claude", alias, pid, status, layer, model
    if (pid !~ /^kc-/ && pid !~ /^kimi-/) {
      kstatus = (index(wired, " " pid " ") > 0) ? status : "no-twin"
      klayer  = (index(wired, " " pid " ") > 0) ? layer  : "run-sync"
      printf "%-6s %-14s %-16s %-10s %-12s %-24s\n", "kimi", "kimi-" pid, pid, kstatus, klayer, model
    }
  }'