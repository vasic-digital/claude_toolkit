#!/usr/bin/env bash
# run-proof.sh — one command that produces rock-solid, physical evidence the
# whole toolkit works: it runs the hermetic sandbox suite AND the live
# OpenCode verification (plus live provider/alias/e2e legs, v1.27.0+ the
# live Kimi leg, and the live quota/limits leg), then writes a dated
# PROOF.md tying them together.
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

# D1 (B-proof-writers): two destinations.
#   PROOF_ROOT  curated, tracked: PROOF.md (and 00-summary.txt, written by the
#               OpenCode leg). Default scripts/tests/proof.
#   PROOF_DIR   volatile run output (every log and per-leg evidence file):
#               default scripts/tests/proof/volatile, which is git-ignored.
# A caller that sets only PROOF_DIR keeps everything in that one directory, as
# before, so a redirected run never writes into the tracked tree.
# shellcheck source=lib/proof.sh
source "$TESTS_DIR/lib/proof.sh"
if [[ -z "${PROOF_ROOT:-}" ]]; then
  if [[ -n "${PROOF_DIR:-}" ]]; then PROOF_ROOT="$PROOF_DIR"; else PROOF_ROOT="$TESTS_DIR/proof"; fi
fi
PROOF_DIR="${PROOF_DIR:-$(cma_proof_volatile_dir)}"
mkdir -p "$PROOF_DIR" "$PROOF_ROOT"
# Link prefix from PROOF.md (in PROOF_ROOT) to the volatile artifacts.
if [[ "$PROOF_DIR" == "$PROOF_ROOT" ]]; then VREL=""
elif [[ "$PROOF_DIR" == "$PROOF_ROOT"/* ]]; then VREL="${PROOF_DIR#"$PROOF_ROOT"/}/"
else VREL="$PROOF_DIR/"; fi
STAMP="$(date '+%Y-%m-%dT%H:%M:%S%z')"

# Every log below streams into a temp file beside its final path and is renamed
# into place when its leg finishes, so a reader never sees a half-written log.
_LEGTMP=""
leg_open()   { _LEGTMP="$(cma_proof_open "$1")"; }
leg_commit() { cma_proof_commit "$_LEGTMP" "$1"; _LEGTMP=""; }

SAND_LOG="$PROOF_DIR/40-sandbox-suite.log"
LIVE_LOG="$PROOF_DIR/41-live-verify.log"

echo "==> sandbox test suite"
leg_open "$SAND_LOG"
bash "$TESTS_DIR/run-all.sh" 2>&1 | tee "$_LEGTMP"
sand_rc=${PIPESTATUS[0]}
leg_commit "$SAND_LOG"

echo
echo "==> live OpenCode verification"
leg_open "$LIVE_LOG"
PROOF_DIR="$PROOF_DIR" PROOF_ROOT="$PROOF_ROOT" bash "$TESTS_DIR/verify_opencode_live.sh" 2>&1 | tee "$_LEGTMP"
live_rc=${PIPESTATUS[0]}
leg_commit "$LIVE_LOG"

echo
echo "==> live provider-alias verification"
PROV_LOG="$PROOF_DIR/42-live-providers.log"
leg_open "$PROV_LOG"
PROOF_DIR="$PROOF_DIR" bash "$TESTS_DIR/verify_providers_live.sh" 2>&1 | tee "$_LEGTMP"
prov_rc=${PIPESTATUS[0]}
leg_commit "$PROV_LOG"

echo
echo "==> live alias verification (provider + Claude aliases)"
ALIAS_LOG="$PROOF_DIR/43-live-aliases.log"
leg_open "$ALIAS_LOG"
PROOF_DIR="$PROOF_DIR" bash "$TESTS_DIR/verify_aliases_live.sh" 2>&1 | tee "$_LEGTMP"
alias_rc=${PIPESTATUS[0]}
leg_commit "$ALIAS_LOG"

echo
echo "==> live alias end-to-end verification (provider endpoints)"
E2E_LOG="$PROOF_DIR/44-alias-e2e.log"
leg_open "$E2E_LOG"
e2e_rc=0
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
PDIR_LIVE="${CMA_PROVIDERS_DIR:-$HOME/.local/share/claude-multi-account/providers}"
if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not available — alias e2e leg skipped" | tee "$_LEGTMP"
elif [[ ! -d "$PDIR_LIVE" ]] || ! compgen -G "$PDIR_LIVE/*.env" >/dev/null 2>&1; then
  echo "SKIP: no provider aliases installed — alias e2e leg skipped" | tee "$_LEGTMP"
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
    echo "SKIP: could not parse a provider endpoint host — alias e2e leg skipped" | tee "$_LEGTMP"
  elif ! python3 -c 'import socket,sys; socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=5).close()' "$host" "$port" >/dev/null 2>&1; then
    echo "SKIP: no network route to $host:$port — alias e2e leg skipped" | tee "$_LEGTMP"
  else
    python3 "$SCRIPTS_DIR/alias_e2e_test.py" --all 2>&1 | tee "$_LEGTMP"
    e2e_rc=${PIPESTATUS[0]}
    if (( e2e_rc == 3 )); then
      echo "SKIP: alias_e2e_test.py reports nothing to test (exit 3)" | tee -a "$_LEGTMP"
      e2e_rc=0
    fi
  fi
fi
leg_commit "$E2E_LOG"

echo
echo "==> live Kimi verification (real kimi CLI + materialized kimi-<id> aliases)"
KIMI_LOG="$PROOF_DIR/46-kimi-live.log"
leg_open "$KIMI_LOG"
PROOF_DIR="$PROOF_DIR" bash "$TESTS_DIR/verify_kimi_live.sh" 2>&1 | tee "$_LEGTMP"
kimi_rc=${PIPESTATUS[0]}
leg_commit "$KIMI_LOG"

echo
echo "==> live quota/limits verification (claude-providers quota --json)"
QUOTA_LOG="$PROOF_DIR/47-quota-live.log"
# Self-contained on purpose (test_release_gate.sh executes this block alone), so
# the atomic temp-then-rename is spelled out here rather than via lib/proof.sh.
mkdir -p "$PROOF_DIR"
QUOTA_TMP="$(mktemp "$PROOF_DIR/.47-quota-live.log.tmp.XXXXXX")"
if [[ ! -d "$PDIR_LIVE" ]] || ! compgen -G "$PDIR_LIVE/*.env" >/dev/null 2>&1; then
  echo "SKIP: no provider aliases installed — quota live leg skipped (native accounts alone still exercise the code path, but this leg needs at least one configured alias to be meaningful)" | tee "$QUOTA_TMP"
  quota_rc=0
else
  # stdout (the JSON) and stderr (diagnostics) are kept APART: merging them
  # made any stderr line part of the document under validation. The content
  # check is the release gate's own (claude-release-gate.sh
  # --check-quota-json), so a fleet where every provider probe failed is a
  # FAIL here too, not a pass on rc + "valid JSON" alone (F5-gate-shallow).
  qjson="$(mktemp "${TMPDIR:-/tmp}/cma-proof-quota-json.XXXXXX")"
  qerr="$(mktemp "${TMPDIR:-/tmp}/cma-proof-quota-err.XXXXXX")"
  bash "$SCRIPTS_DIR/claude-providers.sh" quota --json >"$qjson" 2>"$qerr"
  quota_rc=$?
  { cat "$qjson"; [[ -s "$qerr" ]] && { echo "--- stderr ---"; cat "$qerr"; }; } >> "$QUOTA_TMP"
  if (( quota_rc != 0 )); then
    echo "FAIL: claude-providers quota --json exited $quota_rc" | tee -a "$QUOTA_TMP"
  elif qmsg="$(bash "$SCRIPTS_DIR/claude-release-gate.sh" --check-quota-json "$qjson")"; then
    echo "PASS: claude-providers quota --json: $qmsg" | tee -a "$QUOTA_TMP"
  else
    echo "FAIL: $qmsg" | tee -a "$QUOTA_TMP"
    quota_rc=1
  fi
  rm -f "$qjson" "$qerr"
fi
chmod 0644 "$QUOTA_TMP" 2>/dev/null; mv -f "$QUOTA_TMP" "$QUOTA_LOG"

echo
echo "==> constitution / conformance static checks (Tier C)"
CONST_LOG="$PROOF_DIR/45-constitution.log"
leg_open "$CONST_LOG"
PROOF_DIR="$PROOF_DIR" bash "$TESTS_DIR/verify_constitution.sh" 2>&1 | tee "$_LEGTMP"
const_rc=${PIPESTATUS[0]}
leg_commit "$CONST_LOG"

# Distil the tallies for the report.
# Strip ANSI colour so the distilled report is clean plain text.
strip_ansi() { sed -E "s/$(printf '\033')\[[0-9;]*m//g"; }  # \xNN is GNU-sed-only; build ESC literally for BSD/macOS
sand_line="$(grep -E 'Test files:|ALL GREEN' "$SAND_LOG" | tail -2 | strip_ansi | tr '\n' ' ')"
live_line="$(grep -E '[0-9]+ passed|SKIP:' "$LIVE_LOG" | tail -1 | strip_ansi)"
prov_line="$(grep -E '[0-9]+ passed|SKIP:' "$PROV_LOG" | tail -1 | strip_ansi)"
alias_line="$(grep -E '[0-9]+ passed|PASS: [0-9]+|SKIP:' "$ALIAS_LOG" | tail -1 | strip_ansi)"
e2e_line="$(grep -E '"(total|passed|failed)":|SKIP:' "$E2E_LOG" | strip_ansi | tr '\n' ' ')"
kimi_line="$(grep -E '[0-9]+ passed|KIMI:|SKIP:' "$KIMI_LOG" | tail -1 | strip_ansi)"
quota_line="$(grep -E 'PASS:|FAIL:|SKIP:' "$QUOTA_LOG" | tail -1 | strip_ansi)"
const_line="$(grep -E '[0-9]+ passed|[0-9]+ failed|SKIP:' "$CONST_LOG" | tail -1 | strip_ansi)"

PROOF_MD="$PROOF_ROOT/PROOF.md"
PROOF_MD_TMP="$(cma_proof_open "$PROOF_MD")"
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
  echo "exit code: \`$sand_rc\`  ·  full log: [40-sandbox-suite.log](${VREL}40-sandbox-suite.log)"
  echo
  echo "## Live OpenCode verification (real binary + real config)"
  echo '```'
  sed -n '1,200p' "$PROOF_ROOT/00-summary.txt" 2>/dev/null
  echo '```'
  echo "result: \`$live_line\`  ·  exit code: \`$live_rc\`"
  echo
  echo "## Live provider-alias verification (real installed state)"
  echo '```'
  echo "$prov_line"
  echo '```'
  echo "exit code: \`$prov_rc\`  ·  evidence: [50-providers-live.txt](${VREL}50-providers-live.txt)"
  echo
  echo "## Live alias verification (real provider + Claude aliases)"
  echo '```'
  echo "$alias_line"
  echo '```'
  echo "exit code: \`$alias_rc\`  ·  full log: [43-live-aliases.log](${VREL}43-live-aliases.log)  ·  evidence: [alias-verify-evidence.txt](${VREL}alias-verify-evidence.txt)"
  echo
  echo "## Live alias end-to-end verification (provider endpoints)"
  echo '```'
  echo "$e2e_line"
  echo '```'
  echo "exit code: \`$e2e_rc\`  ·  full log: [44-alias-e2e.log](${VREL}44-alias-e2e.log)"
  echo
  echo "## Live Kimi verification (real CLI + materialized kimi-<id> aliases, v1.27.0)"
  echo '```'
  echo "$kimi_line"
  echo '```'
  echo "exit code: \`$kimi_rc\`  ·  full log: [46-kimi-live.log](${VREL}46-kimi-live.log)  ·  evidence: [kimi-live-evidence.txt](${VREL}kimi-live-evidence.txt)"
  echo
  echo "## Live quota/limits verification (claude-providers quota --json)"
  echo '```'
  echo "$quota_line"
  echo '```'
  echo "exit code: \`$quota_rc\`  ·  full log: [47-quota-live.log](${VREL}47-quota-live.log)"
  echo
  echo "## Constitution / conformance static checks (Tier C)"
  echo '```'
  echo "$const_line"
  echo '```'
  echo "exit code: \`$const_rc\`  ·  full log: [45-constitution.log](${VREL}45-constitution.log)  ·  evidence: [45-constitution.txt](${VREL}45-constitution.txt)"
  echo
  echo "Artifacts (in \`${VREL:-./}\`, regenerated per run, not tracked): \`10-debug-config.json\`, \`21-skill-names.txt\`," \
       "\`31-mcp-list.clean.txt\`, \`50-providers-live.txt\`, \`43-live-aliases.log\`," \
       "\`44-alias-e2e.log\`, \`46-kimi-live.log\`, \`kimi-live-evidence.txt\`," \
       "\`47-quota-live.log\`," \
       "\`45-constitution.log\`, \`45-constitution.txt\`."
} >> "$PROOF_MD_TMP"
cma_proof_commit "$PROOF_MD_TMP" "$PROOF_MD"

echo
echo "============================================"
echo "PROOF written to $PROOF_MD"
echo "sandbox rc=$sand_rc   live rc=$live_rc   providers rc=$prov_rc   aliases rc=$alias_rc   alias-e2e rc=$e2e_rc   kimi rc=$kimi_rc   quota rc=$quota_rc   constitution rc=$const_rc"
if (( sand_rc == 0 && live_rc == 0 && prov_rc == 0 && alias_rc == 0 && e2e_rc == 0 && kimi_rc == 0 && quota_rc == 0 && const_rc == 0 )); then
  echo "ALL GREEN — evidence is in $PROOF_DIR"
  exit 0
fi
echo "FAILURES PRESENT — inspect logs in $PROOF_DIR"
exit 1
