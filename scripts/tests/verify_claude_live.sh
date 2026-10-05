#!/usr/bin/env bash
# verify_claude_live.sh — end-to-end live verification of EVERY provider alias
# through REAL Claude Code, in BOTH modes:
#   CLI: cma_run_provider <id> -p "<prompt>" --output-format json   (authoritative)
#   TUI: the interactive Ink app driven under a PTY (scripts/tests/lib/pty_drive.py)
#
# Each launch runs in a SCRUBBED env (mimics a fresh user shell) and, for TUI,
# from a throwaway temp cwd so it can never resume a real conversation (the
# toolkit's cross-alias .claude.json sync would otherwise auto-resume one).
#
# Outcomes are classified so ACCOUNT problems are not counted as toolkit bugs:
#   PASS      Claude Code returned a successful result / a live response
#   FUNDS     insufficient balance / credits / suspended account (user must top up)
#   BADKEY    key rejected (401 / invalid api key / paid-model-auth-required)
#   NOKEY     key var empty in the keys file
#   GATED     the activation gate refused the launch (alias not verified) —
#             the verification gate already filtered it, not a launch defect
#   FAIL      a genuine error (this is what must be zero)
#   TIMEOUT   no result within the window
#
# Exit code: number of genuine FAILs (0 = all good). SKIP buckets never fail.
#
# Usage:
#   verify_claude_live.sh [--mode cli|tui|both] [--alias ID] [--prompt STR]
#                         [--use-superpowers] [--timeout N] [--out FILE]
set +e
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PDIR="$HOME/.local/share/claude-multi-account/providers"
ALIASES_FILE="$HOME/.local/share/claude-multi-account/aliases.sh"
# Volatile run output (D1): built in a temp file beside the final path and
# renamed into the git-ignored proof/volatile/ folder only on completion.
# shellcheck source=lib/proof.sh
source "$TESTS_DIR/lib/proof.sh"
PROOF_DIR="${PROOF_DIR:-$(cma_proof_volatile_dir)}"

MODE=both TARGET="" PROMPT="Reply with exactly the two characters: OK"
TIMEOUT=160 OUT=""
while (( $# )); do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --alias) TARGET="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --use-superpowers) PROMPT="/using-superpowers"; shift ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
mkdir -p "$PROOF_DIR"
: "${OUT:=$PROOF_DIR/claude-live-verify.txt}"
OUT_FINAL="$OUT"
OUT="$(cma_proof_open "$OUT_FINAL")"

[[ -f "$ALIASES_FILE" ]] || { echo "no aliases file ($ALIASES_FILE) — run install.sh"; rm -f "$OUT"; exit 2; }

# BASH_ENV is scrubbed for the same reason as in verify_superpowers_tui.sh (see
# the long note there), and this file's launch has the identical shape: a
# non-interactive `bash -c` that sources "$ALIASES_FILE" explicitly. A
# non-interactive bash ALSO sources $BASH_ENV first, and where that points at
# the operator's ~/.bashrc it transitively loads the managed alias file — so
# cma_run_provider can come from somewhere other than the alias file this script
# names, and a broken/empty/stale $ALIASES_FILE is undetectable. Verified on
# this host: `bash -c 'declare -F cma_run_provider'` succeeds with BASH_ENV set,
# fails with it unset.
#
# The two SCRUB lists are asserted IDENTICAL by test_providers.sh:1716-1719
# ("SCRUB list mirrors verify_claude_live.sh exactly"), so they must be changed
# together — that assertion is what caught this one.
SCRUB=(env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_ENTRYPOINT
       -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_EXECPATH -u CLAUDE_EFFORT
       -u CLAUDE_CONFIG_DIR -u ANTHROPIC_MODEL -u ANTHROPIC_BASE_URL
       -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u BASH_ENV)

# Shared classifier lives in lib/classify_live.py so stdin carries the transcript
# (a heredoc here would occupy stdin and swallow the piped output).
classify() { python3 "$TESTS_DIR/lib/classify_live.py" "$1"; }

# When a launch FAILs (often a hang/"no result" because ccr retries an upstream
# 401/402/403/429), probe the provider's API directly to recover the TRUE cause
# so an ACCOUNT problem is not miscounted as a toolkit bug. Prints a refined
# verdict (BADKEY/FUNDS/FAIL) + detail, or empty if the probe is inconclusive.
reclassify_fail() {
  local id="$1"
  ( set +e
    set -a
    # shellcheck disable=SC1090  # user's runtime keys file, path not known statically
    . "${CMA_KEYS_FILE:-$HOME/api_keys.sh}" >/dev/null 2>&1
    set +a
    # shellcheck disable=SC1090
    . "$PDIR/$id.env" >/dev/null 2>&1
    eval "tok=\"\${$CMA_PROVIDER_KEYVAR:-}\""
    [ -z "${tok:-}" ] && { echo "NOKEY|key var empty"; exit; }
    local base="$CMA_PROVIDER_BASE_URL" url auth model="$CMA_PROVIDER_MODEL"
    if [ "${CMA_PROVIDER_TRANSPORT:-native}" = native ]; then
      url="${base%/}/v1/messages"; auth=(-H "x-api-key: $tok" -H "anthropic-version: 2023-06-01")
    else
      url="${base%/}/chat/completions"; auth=(-H "Authorization: Bearer $tok")
    fi
    local body code
    body="$(curl -sS -m 30 -w '\n__H__%{http_code}' "${auth[@]}" -H 'content-type: application/json' \
      -d "{\"model\":\"$model\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Say OK\"}]}" "$url" 2>&1)"
    code="${body##*__H__}"; body="${body%__H__*}"
    local low; low="$(printf '%s' "$body" | tr '[:upper:]' '[:lower:]')"
    case "$code" in
      401) echo "BADKEY|direct probe HTTP 401 (key rejected/insufficient scope)" ;;
      402) echo "FUNDS|direct probe HTTP 402 ${body:0:50}" ;;
      403|429)
        # English + provider-specific balance markers (e.g. Zhipu code 1113 /
        # Chinese 余额不足…请充值) all mean "out of funds", not a bad key.
        if printf '%s' "$low" | grep -qE 'balance|credit|quota|insufficient|not_enough|arrears|recharge|payment|1113|余额|充值'; then
          echo "FUNDS|direct probe HTTP $code ${body:0:50}"
        else echo "BADKEY|direct probe HTTP $code ${body:0:50}"; fi ;;
      400)
        # A 400 that says the configured model is unknown/invalid means the
        # account cannot invoke it (e.g. a key that can LIST models via /models
        # but has no chat entitlement — every catalog model returns this). That
        # is an account/provisioning problem, not a toolkit bug, so bucket it as
        # BADKEY. A 400 WITHOUT a model-rejection marker (e.g. Poe's misleading
        # "Invalid 'tools': Field required") is a real launch-layer defect —
        # leave it as FAIL so it is fixed, never masked.
        if printf '%s' "$low" | grep -qE 'invalid model|model not found|no such model|unknown model|model_not_found|does not exist|not a valid model|unsupported model'; then
          echo "BADKEY|direct probe HTTP 400 model rejected — account lacks access to '$model': ${body:0:50}"
        else echo ""; fi ;;
      200) echo "" ;;  # API works directly -> the failure is in the launch layer; keep FAIL
      *) echo "" ;;
    esac )
}

run_cli() {
  local id="$1"
  timeout "$TIMEOUT" "${SCRUB[@]}" bash -c '
    set +e
    source "'"$ALIASES_FILE"'" >/dev/null 2>&1
    cma_run_provider "'"$id"'" -p "'"$PROMPT"'" --output-format json 2>&1
  '
}

# The SCRUB is applied to the launch SHELL, not to python3: pty_drive.py is the
# harness and needs its own environment, while the thing under test is the bash
# that sources the alias file — exactly the process run_cli scrubs. Until
# 2026-07-20 this function applied NO scrub at all (the array was referenced only
# by run_cli), which made this file's own header claim "Each launch runs in a
# SCRUBBED env" FALSE for TUI mode: the interactive launch inherited CLAUDECODE /
# CLAUDE_CODE_* / ANTHROPIC_* from the invoking session, and — via BASH_ENV — a
# cma_run_provider from an alias file other than the one named above.
run_tui() {
  local id="$1" tmpd
  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/cma-tui.XXXXXX")"
  timeout "$TIMEOUT" python3 "$TESTS_DIR/lib/pty_drive.py" --prompt "$PROMPT" --boot 24 --run "$(( TIMEOUT>90 ? 70 : 45 ))" -- \
    "${SCRUB[@]}" bash -c 'cd "'"$tmpd"'" && source "'"$ALIASES_FILE"'" >/dev/null 2>&1; cma_run_provider "'"$id"'"' 2>/dev/null
  rmdir "$tmpd" 2>/dev/null || true
}

if [[ -n "$TARGET" ]]; then
  IDS=("$TARGET")
else
  IDS=(); for f in "$PDIR"/*.env; do IDS+=("$(basename "$f" .env)"); done
fi

echo "# verify_claude_live  mode=$MODE prompt=$(printf %q "$PROMPT")  $(date)" | tee -a "$OUT"
fails=0
for id in "${IDS[@]}"; do
  line="$id"
  for m in cli tui; do
    [[ "$MODE" != both && "$MODE" != "$m" ]] && continue
    if [[ "$m" == cli ]]; then out="$(run_cli "$id")"; else out="$(run_tui "$id")"; fi
    verdict="$(printf '%s' "$out" | classify "$m")"
    st="${verdict%%|*}"
    # A CLI FAIL is often a hang on an upstream 401/402/403/429 (account issue).
    # Probe the provider directly to recover the true cause before counting it.
    if [[ "$m" == cli && ( "$st" == FAIL || "$st" == TIMEOUT ) ]]; then
      refined="$(reclassify_fail "$id")"
      if [[ -n "$refined" ]]; then verdict="$refined (was $st)"; st="${refined%%|*}"; fi
    fi
    line+="  ${m}:${verdict}"
    [[ "$st" == FAIL || "$st" == TIMEOUT ]] && fails=$((fails+1))
  done
  printf '%s\n' "$line" | tee -a "$OUT"
done
echo "# DONE fails=$fails" | tee -a "$OUT"
cma_proof_commit "$OUT" "$OUT_FINAL"
exit "$fails"
