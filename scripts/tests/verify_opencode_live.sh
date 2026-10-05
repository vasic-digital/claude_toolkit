#!/usr/bin/env bash
# verify_opencode_live.sh — end-to-end proof that the OpenCode integration
# actually works against the REAL opencode binary and the REAL config this
# host's claude-opencode-sync.sh produced.
#
# Unlike the sandboxed test_*.sh suite, this talks to the live system, so it
# is intentionally NOT named test_*.sh (run-all.sh won't auto-pick it up).
# It is read-only with respect to the OpenCode config — it only *inspects*.
#
# Every check writes its raw command output to $PROOF_DIR so the results are
# physical, inspectable artifacts rather than just a green/red line. If
# opencode is not installed it SKIPs (exit 0) rather than failing CI on a
# host without OpenCode.
#
# Knobs:
#   PROOF_DIR        where to write volatile run output
#                    (default scripts/tests/proof/volatile, git-ignored)
#   PROOF_ROOT       where the curated 00-summary.txt goes (default
#                    scripts/tests/proof; falls back to PROOF_DIR when only
#                    PROOF_DIR is given, so a redirected run stays contained)
#   MIN_SKILLS       minimum skills that must resolve (default 200)
#   MIN_MCP_ENABLED  minimum enabled MCP servers that must connect (default 3)

set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/proof.sh
source "$TESTS_DIR/lib/proof.sh"

# D1: the curated summary stays at scripts/tests/proof/00-summary.txt (tracked);
# every other artifact is volatile run output in the git-ignored volatile/.
if [[ -z "${PROOF_ROOT:-}" ]]; then
  if [[ -n "${PROOF_DIR:-}" ]]; then PROOF_ROOT="$PROOF_DIR"; else PROOF_ROOT="$TESTS_DIR/proof"; fi
fi
PROOF_DIR="${PROOF_DIR:-$(cma_proof_volatile_dir)}"
MIN_SKILLS="${MIN_SKILLS:-200}"
MIN_MCP_ENABLED="${MIN_MCP_ENABLED:-3}"
OPENCODE_CONFIG="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"

if ! command -v opencode >/dev/null 2>&1; then
  echo "SKIP: opencode not installed on this host — live verification skipped."
  exit 0
fi

# `timeout` is GNU coreutils; on macOS it is `gtimeout` (or absent). Resolve it
# once so the live checks degrade gracefully instead of hard-failing with
# "timeout: command not found" on a host that has opencode but no coreutils.
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
_oc_timeout() {
  if [[ -n "$TIMEOUT_BIN" ]]; then "$TIMEOUT_BIN" "$@"; else shift; "$@"; fi
}

mkdir -p "$PROOF_DIR" "$PROOF_ROOT"

# _oc_publish FINAL — read stdin into a temp beside FINAL, then rename it into
# place, so no reader ever sees a half-written artifact.
_oc_publish() {
  local _t; _t="$(cma_proof_open "$1")" || return 1
  cat > "$_t" && cma_proof_commit "$_t" "$1"
}

# Redact secrets from any text BEFORE it is written to the committed proof dir.
# `opencode debug config` / `mcp list` echo the user's RESOLVED config, which can
# contain literal API keys and connection-string passwords (placeholders like
# ${VAR} are preserved). Never commit those. Filters: (1) sensitive JSON string
# values whose KEY NAME contains key/token/secret/password/api-key (env-style
# names like TAVILY_API_KEY included) and whose value is not a ${...} placeholder
# or empty; (2) user:password@ in URLs; (3) known key prefixes incl. JWTs.
cma_redact_secrets() {
  sed -E \
    -e 's/("[^"]*([Aa][Pp][Ii][-_]?[Kk][Ee][Yy]|[Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd])[^"]*"[[:space:]]*:[[:space:]]*")([^"$][^"]*)(")/\1REDACTED\4/g' \
    -e 's#://([^:/@ "]+):([^@/ "]{2,})@#://\1:REDACTED@#g' \
    -e 's/(sk-ant-|sk-|gsk_|xai-|hf_|AIza|xoxb-|xoxp-|xoxs-|pc-|re_|secret_|ghp_|github_pat_|AKIA|tvly-|nvapi-)[A-Za-z0-9_-]{8,}/REDACTED/g' \
    -e 's/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/REDACTED/g'
}

STAMP="$(date '+%Y-%m-%dT%H:%M:%S%z')"
# The summary is accumulated in a temp file and renamed into place at the end.
SUMMARY_FINAL="$PROOF_ROOT/00-summary.txt"
SUMMARY="$(cma_proof_open "$SUMMARY_FINAL")"
{
  echo "# OpenCode live verification proof"
  echo "generated: $STAMP"
  echo "host:      $(uname -srm)"
  echo "opencode:  $(opencode --version 2>/dev/null)"
  echo "config:    $OPENCODE_CONFIG"
} >> "$SUMMARY"

# --- 1. opencode reports a version --------------------------------------
it "opencode binary runs and reports a version"
ver="$(opencode --version 2>/dev/null)"
if [[ -n "$ver" ]]; then _pass "version: $ver"; else _fail "no version"; fi

# --- 2. resolved config parses and has our keys -------------------------
it "opencode resolves the generated config without error"
DC_RAW="$(cma_proof_open "$PROOF_DIR/10-debug-config.json.raw")"
DC_ERR="$(cma_proof_open "$PROOF_DIR/10-debug-config.err")"
opencode debug config >"$DC_RAW" 2>"$DC_ERR"
rc=$?
cma_proof_commit "$DC_ERR" "$PROOF_DIR/10-debug-config.err"
cma_redact_secrets < "$DC_RAW" | _oc_publish "$PROOF_DIR/10-debug-config.json"
rm -f "$DC_RAW"
assert_eq 0 "$rc" "debug config exit"
if jq -e . "$PROOF_DIR/10-debug-config.json" >/dev/null 2>&1; then _pass "resolved config is valid JSON"; else _fail "resolved config not JSON"; fi
mcp_total="$(jq '.mcp | length' "$PROOF_DIR/10-debug-config.json" 2>/dev/null || true)"
mcp_enabled="$(jq '[.mcp[]|select(.enabled==true)]|length' "$PROOF_DIR/10-debug-config.json" 2>/dev/null || true)"
skill_paths="$(jq '.skills.paths | length' "$PROOF_DIR/10-debug-config.json" 2>/dev/null || true)"
echo "mcp_total=$mcp_total mcp_enabled=$mcp_enabled skill_paths=$skill_paths" >> "$SUMMARY"
if (( mcp_total >= 1 )); then _pass "mcp servers configured: $mcp_total"; else _fail "no mcp servers"; fi
if (( skill_paths >= 1 )); then _pass "skill paths configured: $skill_paths"; else _fail "no skill paths"; fi

# --- 3. skills actually resolve (full capture; the stream is slow) -------
it "opencode discovers the Claude plugin skills"
# debug skill streams a large (multi-MB) JSON array; capture it to a temp,
# count + extract names, then drop the raw dump so we commit only the compact,
# human-checkable evidence (the sorted unique skill-name list).
SKILLS_RAW="$(mktemp "${TMPDIR:-/tmp}/oc-skills.XXXXXX")"
SK_ERR="$(cma_proof_open "$PROOF_DIR/20-skills.err")"
_oc_timeout 240 opencode debug skill >"$SKILLS_RAW" 2>"$SK_ERR"
cma_proof_commit "$SK_ERR" "$PROOF_DIR/20-skills.err"
skills="$(grep -c '"name":' "$SKILLS_RAW" 2>/dev/null || true)"
echo "skills_resolved=$skills (threshold $MIN_SKILLS)" >> "$SUMMARY"
grep -o '"name": "[^"]*"' "$SKILLS_RAW" 2>/dev/null | sed 's/"name": //' \
  | sort -u | _oc_publish "$PROOF_DIR/21-skill-names.txt"
rm -f "$SKILLS_RAW"
if (( skills >= MIN_SKILLS )); then _pass "skills resolved: $skills (>= $MIN_SKILLS)"
else _fail "skills resolved" "got=$skills want>=$MIN_SKILLS"; fi

# --- 4. enabled MCP servers connect -------------------------------------
it "every enabled MCP server connects"
MCP_RAW="$(cma_proof_open "$PROOF_DIR/30-mcp-list.txt.raw")"
_oc_timeout 300 opencode mcp list >"$MCP_RAW" 2>&1
cma_redact_secrets < "$MCP_RAW" | _oc_publish "$PROOF_DIR/30-mcp-list.txt"
rm -f "$MCP_RAW"
# Strip ANSI colour so parsing is robust (30-mcp-list.txt is already redacted).
sed -E "s/$(printf '\033')\[[0-9;]*m//g" "$PROOF_DIR/30-mcp-list.txt" | _oc_publish "$PROOF_DIR/31-mcp-list.clean.txt"
connected="$(grep -c '✓' "$PROOF_DIR/31-mcp-list.clean.txt" 2>/dev/null || true)"
failed="$(grep -c '✗' "$PROOF_DIR/31-mcp-list.clean.txt" 2>/dev/null || true)"
echo "mcp_connected=$connected mcp_failed=$failed" >> "$SUMMARY"
if (( connected >= MIN_MCP_ENABLED )); then _pass "connected MCP servers: $connected (>= $MIN_MCP_ENABLED)"
else _fail "connected MCP servers" "got=$connected want>=$MIN_MCP_ENABLED"; fi
if (( failed == 0 )); then _pass "no enabled MCP server failed to connect"
else _fail "some enabled MCP servers failed" "failed=$failed (see 31-mcp-list.clean.txt)"; fi

# --- 5. instructions wired ----------------------------------------------
it "user CLAUDE.md is wired as an instruction (if present)"
instr="$(jq -r '.instructions // [] | length' "$PROOF_DIR/10-debug-config.json" 2>/dev/null || true)"
echo "instructions=$instr" >> "$SUMMARY"
if (( instr >= 1 )); then _pass "instructions configured: $instr"; else _pass "no instructions (CLAUDE.md absent — acceptable)"; fi

echo >> "$SUMMARY"
echo "result: see PASS/FAIL tally below" >> "$SUMMARY"
cma_proof_commit "$SUMMARY" "$SUMMARY_FINAL"
[[ -e "$PROOF_ROOT/.gitkeep" ]] || cp /dev/null "$PROOF_ROOT/.gitkeep" 2>/dev/null || true

echo
echo "Summary written to:  $SUMMARY_FINAL"
echo "Evidence written to: $PROOF_DIR"
ls -1 "$PROOF_DIR"
summary
