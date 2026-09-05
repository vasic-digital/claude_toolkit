#!/usr/bin/env bash
# run-proof.sh — one command that produces rock-solid, physical evidence the
# whole toolkit works: it runs the hermetic sandbox suite AND the live
# OpenCode verification (plus live provider/alias/e2e legs and, v1.27.0+, the
# live Kimi leg), then writes a dated PROOF.md tying them together.
#
# Exit code is 0 only if ALL legs pass. Live legs SKIP (count as pass) when
# their prerequisite is absent (no opencode binary, no keys, no kimi).

set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# SERIALIZATION: acquired here, at the OUTERMOST entry point, before any leg
# runs. The nested `run-all.sh` below acquires the same lock and inherits it
# from this process instead of deadlocking against it (see lib/suite-lock.sh).
# shellcheck source=lib/suite-lock.sh
source "$TESTS_DIR/lib/suite-lock.sh"
cma_suite_lock_acquire suite

PROOF_DIR="${PROOF_DIR:-$TESTS_DIR/proof}"
mkdir -p "$PROOF_DIR"
STAMP="$(date '+%Y-%m-%dT%H:%M:%S%z')"

SAND_LOG="$PROOF_DIR/40-sandbox-suite.log"
LIVE_LOG="$PROOF_DIR/41-live-verify.log"

echo "==> sandbox test suite"
bash "$TESTS_DIR/run-all.sh" 2>&1 | tee "$SAND_LOG"
sand_rc=${PIPESTATUS[0]}

echo
echo "==> live OpenCode verification"
bash "$TESTS_DIR/verify_opencode_live.sh" 2>&1 | tee "$LIVE_LOG"
live_rc=${PIPESTATUS[0]}

echo
echo "==> live provider-alias verification"
PROV_LOG="$PROOF_DIR/42-live-providers.log"
bash "$TESTS_DIR/verify_providers_live.sh" 2>&1 | tee "$PROV_LOG"
prov_rc=${PIPESTATUS[0]}

echo
echo "==> live alias verification (provider + Claude aliases)"
ALIAS_LOG="$PROOF_DIR/43-live-aliases.log"
bash "$TESTS_DIR/verify_aliases_live.sh" 2>&1 | tee "$ALIAS_LOG"
alias_rc=${PIPESTATUS[0]}

echo
echo "==> live alias end-to-end verification (provider endpoints)"
E2E_LOG="$PROOF_DIR/44-alias-e2e.log"
e2e_rc=0
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
PDIR_LIVE="${CMA_PROVIDERS_DIR:-$HOME/.local/share/claude-multi-account/providers}"
if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not available — alias e2e leg skipped" | tee "$E2E_LOG"
elif [[ ! -d "$PDIR_LIVE" ]] || ! compgen -G "$PDIR_LIVE/*.env" >/dev/null 2>&1; then
  echo "SKIP: no provider aliases installed — alias e2e leg skipped" | tee "$E2E_LOG"
else
  # Network pre-check against the first provider's endpoint host: the e2e leg
  # must reach provider APIs, so without connectivity record an honest SKIP
  # instead of letting every alias fail for environmental reasons.
  first_env="$(find "$PDIR_LIVE" -maxdepth 1 -name '*.env' | sort | head -1)"
  base_url="$(grep -E '^CMA_PROVIDER_BASE_URL=' "$first_env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "\"'")"
  hostport="$(printf '%s' "$base_url" | sed -E 's#^[A-Za-z]+://([^/]+).*#\1#')"
  host="${hostport%%:*}"
  port="${hostport##*:}"
  if [[ "$port" == "$hostport" || -z "$port" ]]; then port=443; fi
  if [[ -z "$host" ]]; then
    echo "SKIP: could not parse a provider endpoint host — alias e2e leg skipped" | tee "$E2E_LOG"
  elif ! python3 -c 'import socket,sys; socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=5).close()' "$host" "$port" >/dev/null 2>&1; then
    echo "SKIP: no network route to $host:$port — alias e2e leg skipped" | tee "$E2E_LOG"
  else
    python3 "$SCRIPTS_DIR/alias_e2e_test.py" --all 2>&1 | tee "$E2E_LOG"
    e2e_rc=${PIPESTATUS[0]}
    if (( e2e_rc == 3 )); then
      echo "SKIP: alias_e2e_test.py reports nothing to test (exit 3)" | tee -a "$E2E_LOG"
      e2e_rc=0
    fi
  fi
fi

echo
echo "==> live Kimi verification (real kimi CLI + materialized kimi-<id> aliases)"
KIMI_LOG="$PROOF_DIR/46-kimi-live.log"
bash "$TESTS_DIR/verify_kimi_live.sh" 2>&1 | tee "$KIMI_LOG"
kimi_rc=${PIPESTATUS[0]}

echo
echo "==> constitution / conformance static checks (Tier C)"
CONST_LOG="$PROOF_DIR/45-constitution.log"
bash "$TESTS_DIR/verify_constitution.sh" 2>&1 | tee "$CONST_LOG"
const_rc=${PIPESTATUS[0]}

# Distil the tallies for the report.
# Strip ANSI colour so the distilled report is clean plain text.
strip_ansi() { sed -E "s/$(printf '\033')\[[0-9;]*m//g"; }  # \xNN is GNU-sed-only; build ESC literally for BSD/macOS
sand_line="$(grep -E 'Test files:|ALL GREEN' "$SAND_LOG" | tail -2 | strip_ansi | tr '\n' ' ')"
live_line="$(grep -E '[0-9]+ passed|SKIP:' "$LIVE_LOG" | tail -1 | strip_ansi)"
prov_line="$(grep -E '[0-9]+ passed|SKIP:' "$PROV_LOG" | tail -1 | strip_ansi)"
alias_line="$(grep -E '[0-9]+ passed|PASS: [0-9]+|SKIP:' "$ALIAS_LOG" | tail -1 | strip_ansi)"
e2e_line="$(grep -E '"(total|passed|failed)":|SKIP:' "$E2E_LOG" | strip_ansi | tr '\n' ' ')"
kimi_line="$(grep -E '[0-9]+ passed|KIMI:|SKIP:' "$KIMI_LOG" | tail -1 | strip_ansi)"
const_line="$(grep -E '[0-9]+ passed|[0-9]+ failed|SKIP:' "$CONST_LOG" | tail -1 | strip_ansi)"

{
  echo "# Toolkit proof of work"
  echo
  echo "- generated: \`$STAMP\`"
  echo "- host: \`$(uname -srm)\`"
  echo
  echo "## Sandbox suite (hermetic, no network)"
  echo '```'
  echo "$sand_line"
  echo '```'
  echo "exit code: \`$sand_rc\`  ·  full log: [40-sandbox-suite.log](40-sandbox-suite.log)"
  echo
  echo "## Live OpenCode verification (real binary + real config)"
  echo '```'
  sed -n '1,200p' "$PROOF_DIR/00-summary.txt" 2>/dev/null
  echo '```'
  echo "result: \`$live_line\`  ·  exit code: \`$live_rc\`"
  echo
  echo "## Live provider-alias verification (real installed state)"
  echo '```'
  echo "$prov_line"
  echo '```'
  echo "exit code: \`$prov_rc\`  ·  evidence: [50-providers-live.txt](50-providers-live.txt)"
  echo
  echo "## Live alias verification (real provider + Claude aliases)"
  echo '```'
  echo "$alias_line"
  echo '```'
  echo "exit code: \`$alias_rc\`  ·  full log: [43-live-aliases.log](43-live-aliases.log)  ·  evidence: [alias-verify-evidence.txt](alias-verify-evidence.txt)"
  echo
  echo "## Live alias end-to-end verification (provider endpoints)"
  echo '```'
  echo "$e2e_line"
  echo '```'
  echo "exit code: \`$e2e_rc\`  ·  full log: [44-alias-e2e.log](44-alias-e2e.log)"
  echo
  echo "## Live Kimi verification (real CLI + materialized kimi-<id> aliases, v1.27.0)"
  echo '```'
  echo "$kimi_line"
  echo '```'
  echo "exit code: \`$kimi_rc\`  ·  full log: [46-kimi-live.log](46-kimi-live.log)  ·  evidence: [kimi-live-evidence.txt](kimi-live-evidence.txt)"
  echo
  echo "## Constitution / conformance static checks (Tier C)"
  echo '```'
  echo "$const_line"
  echo '```'
  echo "exit code: \`$const_rc\`  ·  full log: [45-constitution.log](45-constitution.log)  ·  evidence: [45-constitution.txt](45-constitution.txt)"
  echo
  echo "Artifacts: \`10-debug-config.json\`, \`21-skill-names.txt\`," \
       "\`31-mcp-list.clean.txt\`, \`50-providers-live.txt\`, \`43-live-aliases.log\`," \
       "\`44-alias-e2e.log\`, \`46-kimi-live.log\`, \`kimi-live-evidence.txt\`," \
       "\`45-constitution.log\`, \`45-constitution.txt\`."
} > "$PROOF_DIR/PROOF.md"

echo
echo "============================================"
echo "PROOF written to $PROOF_DIR/PROOF.md"
echo "sandbox rc=$sand_rc   live rc=$live_rc   providers rc=$prov_rc   aliases rc=$alias_rc   alias-e2e rc=$e2e_rc   kimi rc=$kimi_rc   constitution rc=$const_rc"
if (( sand_rc == 0 && live_rc == 0 && prov_rc == 0 && alias_rc == 0 && e2e_rc == 0 && kimi_rc == 0 && const_rc == 0 )); then
  echo "ALL GREEN — evidence is in $PROOF_DIR"
  exit 0
fi
echo "FAILURES PRESENT — inspect logs in $PROOF_DIR"
exit 1
