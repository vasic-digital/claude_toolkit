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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$SCRIPT_DIR/claude-providers.sh"

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
output="$(KIMI_ALIASES=0 bash "$ENGINE" "$SUBCMD" "$@" 2>/dev/null || true)"
if ! printf '%s' "$output" | grep -qE '^\s*ALIAS\s'; then
  printf '%s\n' "${output:-No provider aliases installed. Run: kimi-providers sync}"
  exit 0
fi

printf '%-6s %-14s %-16s %-10s %-12s %-24s\n' AGENT ALIAS PROVIDER STATUS LAYER STRONG_MODEL
printf '%s\n' "$output" | awk -F' ' '
  $1 == "ALIAS" { next }
  NF < 5 { next }
  {
    alias=$1; pid=$2; status=$3; layer=$4; model=$5
    printf "%-6s %-14s %-16s %-10s %-12s %-24s\n", "claude", alias, pid, status, layer, model
    if (pid !~ /^kc-/ && pid !~ /^kimi-/) {
      printf "%-6s %-14s %-16s %-10s %-12s %-24s\n", "kimi", "kimi-" pid, pid, status, layer, model
    }
  }'