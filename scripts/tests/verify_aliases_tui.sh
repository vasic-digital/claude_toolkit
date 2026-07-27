#!/usr/bin/env bash
# verify_aliases_tui.sh — drive EVERY verified provider alias in a REAL Claude
# Code TUI (tmux), send a real prompt, and require a real answer.
#
# Why this exists (operator demand 2026-07-26): the aggregate proof verifies
# routing, attribution and gates, but it does not sit in an interactive TUI
# with the full prefix (plugin MCP tools, hooks, CLAUDE.md) — which is exactly
# where two live defects hid: the 2.1.220 compact loop (fast/compact tier
# resolving to an unavailable "Fable 5") and the endpoint 400 when the
# auto-compact window ignored the tool-schema budget (openrouter3:
# "requested about 371727 tokens … 70236 of tool input, 102144 in the
# output"). This leg launches the REAL alias in a REAL TUI, types a REAL
# prompt with send-keys, and requires the answer to appear.
#
# Failure signatures detected (each is a distinct, named verdict):
#   tui-400          "API Error: 400" in the pane (endpoint rejection)
#   prompt-too-long  "Prompt is too long" (client-side context mis-accounting)
#   compact-loop     >=3 compaction starts without an answer (the 2.1.220 loop)
#   no-answer        nothing came back within the budget (upstream stall/hang)
#   tui-not-ready    the TUI never reached its prompt (launch failure)
#
# Per-alias gateways are port-isolated, so aliases run N-way concurrent
# (default 4; CMA_TUI_CONCURRENCY overrides). Exit 0 only when every verified
# alias answered.
set -uo pipefail

PROVIDERS_DIR="${CMA_PROVIDERS_DIR:-$HOME/.local/share/claude-multi-account/providers}"
STATUS="$PROVIDERS_DIR/status.json"
CONCURRENCY="${CMA_TUI_CONCURRENCY:-4}"
READY_BUDGET="${CMA_TUI_READY_BUDGET:-300}"     # s to reach the TUI prompt
ANSWER_BUDGET="${CMA_TUI_ANSWER_BUDGET:-480}"   # s to answer the prompt
WORKDIR_PREFIX="${TMPDIR:-/tmp}/cma-tui"

command -v tmux >/dev/null 2>&1 || { echo "verify-aliases-tui: tmux not found" >&2; exit 2; }
command -v jq  >/dev/null 2>&1 || { echo "verify-aliases-tui: jq not found" >&2; exit 2; }
[[ -s "$STATUS" ]] || { echo "verify-aliases-tui: no status.json at $STATUS" >&2; exit 2; }

ALIASES="${CMA_TUI_ALIASES:-}"
if [[ -z "$ALIASES" ]]; then
  ALIASES="$(jq -r 'to_entries[] | select(.value.status=="verified") | .key' "$STATUS" | sort)"
fi
[[ -n "$ALIASES" ]] || { echo "verify-aliases-tui: no verified aliases to test"; exit 0; }

pass=0; fail=0; failed_names=()

pane() { tmux capture-pane -p -t "$1" -S -200 2>/dev/null; }

run_alias() { # $1=alias -> verdict file in $RESULTS_DIR
  local alias="$1" sess="cma-tui-$alias-$$" work="$WORKDIR_PREFIX-$alias-$$"
  mkdir -p "$work"
  tmux new-session -d -s "$sess" -x 220 -y 50 -c "$work" "bash --noprofile --norc" 2>/dev/null
  # Sourcing the production alias file defines cma_run_provider; call the
  # function directly (shell aliases don't expand in non-interactive bash).
  tmux send-keys -t "$sess" 'source ~/.local/share/claude-multi-account/aliases.sh; cma_run_provider '"$alias" Enter
  local t=0 ready=0 trust_sent=0
  while (( t < READY_BUDGET )); do
    local p; p="$(pane "$sess")"
    # Fresh scratch dirs trip Claude Code's folder-trust dialog; accept it
    # once (option 1 = trust) so the TUI can reach its prompt.
    if (( ! trust_sent )) && grep -qi "trust the files in this folder" <<<"$p"; then
      tmux send-keys -t "$sess" "1"; trust_sent=1
    fi
    if grep -q '❯' <<<"$p"; then ready=1; break; fi
    sleep 3; t=$((t+3))
  done
  if (( ! ready )); then
    tmux kill-session -t "$sess" 2>/dev/null; rm -rf "$work"
    echo "$alias|tui-not-ready" > "$RESULTS_DIR/$alias"; return
  fi
  tmux send-keys -t "$sess" 'Reply with exactly: TUI-OK-'"$alias" Enter
  t=0
  local answer=0 compact_starts=0
  while (( t < ANSWER_BUDGET )); do
    local p; p="$(pane "$sess")"
    if grep -q "API Error: 40[0-9][0-9]" <<<"$p"; then
      tmux kill-session -t "$sess" 2>/dev/null; rm -rf "$work"
      echo "$alias|tui-400|$(grep -o 'API Error: 40[0-9][0-9][^"]\{0,120\}' <<<"$p" | head -1)" > "$RESULTS_DIR/$alias"; return
    fi
    if grep -q "Prompt is too long" <<<"$p"; then
      tmux kill-session -t "$sess" 2>/dev/null; rm -rf "$work"
      echo "$alias|prompt-too-long" > "$RESULTS_DIR/$alias"; return
    fi
    if grep -q "TUI-OK-$alias" <<<"$p"; then
      # The marker must appear as an ANSWER (● or ⎿), not just as the typed prompt.
      if grep -q "● .*TUI-OK-$alias" <<<"$p"; then
        answer=1; break
      fi
      # Fallback: the string appears at least twice (once typed, once answered).
      local n; n="$(grep -o "TUI-OK-$alias" <<<"$p" | wc -l)"
      if [[ "$n" -ge 2 ]]; then answer=1; break; fi
    fi
    compact_starts="$(grep -oiE "compacting conversation|auto-?compact" <<<"$p" | wc -l)"
    if (( compact_starts >= 3 )); then
      tmux kill-session -t "$sess" 2>/dev/null; rm -rf "$work"
      echo "$alias|compact-loop|$compact_starts compaction starts without an answer" > "$RESULTS_DIR/$alias"; return
    fi
    sleep 5; t=$((t+5))
  done
  tmux kill-session -t "$sess" 2>/dev/null; rm -rf "$work"
  if (( answer )); then echo "$alias|PASS" > "$RESULTS_DIR/$alias"; else echo "$alias|no-answer|nothing within ${ANSWER_BUDGET}s" > "$RESULTS_DIR/$alias"; fi
}

RESULTS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cma-tui-results.XXXXXX")"
echo "== verify-aliases-tui: $(wc -l <<<"$ALIASES" | tr -d ' ') verified alias(es), concurrency $CONCURRENCY"
active=0
while IFS= read -r alias; do
  [[ -n "$alias" ]] || continue
  run_alias "$alias" &
  active=$((active+1))
  if (( active >= CONCURRENCY )); then wait -n; active=$((active-1)); fi
done <<<"$ALIASES"
wait

pass=0; fail=0; failed_names=()
for f in "$RESULTS_DIR"/*; do
  [[ -f "$f" ]] || continue
  IFS='|' read -r alias verdict detail < "$f"
  if [[ "$verdict" == "PASS" ]]; then
    printf '✓ %s: PASS (real TUI turn answered)\n' "$alias"; pass=$((pass+1))
  else
    printf '✗ %s: FAIL — %s%s\n' "$alias" "$verdict" "${detail:+ ($detail)}"; fail=$((fail+1)); failed_names+=("$alias")
  fi
done
echo
echo "TUI: PASS=$pass FAIL=$fail TOTAL=$((pass+fail))"
rm -rf "$RESULTS_DIR"
(( fail == 0 ))
