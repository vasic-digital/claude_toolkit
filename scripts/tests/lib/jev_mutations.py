#!/usr/bin/env python3
"""Mutation table for test_jev_detect_https_mutation.sh.

usage: jev_mutations.py list                -> "<idx>\t<suite>\t<label>" per line
       jev_mutations.py apply <idx> <root>  -> apply mutation <idx> inside <root>
                                               (a COPY of the repo; exit 3 if the
                                               pattern is absent = stale table)
Every mutation re-introduces one defect class named in the independent review of
the v1.32.0 release (R1..R6 and the docs-review set); the named suite MUST fail.
"""
import sys

CP = "scripts/claude-providers.sh"
GATE = "scripts/jev-gate.sh"
MCP = "scripts/jev_mcp.py"
LIB = "scripts/lib.sh"
HTTPS = "test_jev_detect_https.sh"
WIRING = "test_llmctl_vision_gate_wiring.sh"
DOCS = "test_docs_hub_engine_release.sh"
HARD = "test_hardening_r2.sh"

BS = "\\"   # a single backslash (raw strings cannot end with one)
AUTH = r"""-H @<(printf 'Authorization: Bearer %s\n' "$_key") """.rstrip() + " " + BS
AUTH_ARGV = r"""-H "Authorization: Bearer $_key" """.rstrip() + " " + BS

M = [
 # --- KEY LEAK class
 ("detector: key moved into curl argv (R1)", CP, HTTPS,
  AUTH, AUTH_ARGV, None),
 ("detector: http fallback probe sends Authorization (R2)", CP, HTTPS,
  r"""_hz="$(curl -sf --max-time "$_t" "${_b}${_thpath}" 2>/dev/null)" || _hz="" """.rstrip(),
  r"""_hz="$(curl -sf --max-time "$_t" -H "Authorization: Bearer leaked" "${_b}${_thpath}" 2>/dev/null)" || _hz="" """.rstrip(), 1),
 ("detector: ca_file recorded on http records (R3)", CP, HTTPS,
  r"""_cafield=""; [[ "$_auth" == 1 && -n "$_okca" ]] && _cafield="$_okca" """.rstrip(),
  r"""_cafield="${CMA_JEV_CA_FILE:-}" """.rstrip(), 1),
 ("detector: http record keeps key_var", CP, HTTPS,
  r"""_base="$_b"; _tkeyvar="" """.rstrip(), r"""_base="$_b" """.rstrip(), 1),
 ("detector: http fallback on by default", CP, HTTPS,
  r"""[[ "${CMA_JEV_ALLOW_HTTP:-0}" == "1" || "$_tscheme" == "http" ]] || exit 0""", ":", 1),
 ("detector: loopback matched by prefix (R4)", CP, HTTPS,
  r"""if [[ "$h" =~ ^127(\.[0-9]{1,3}){3}$ ]]; then""", r"""if [[ "$h" == 127.* ]]; then""", 1),
 ("detector: non-loopback plain http allowed", CP, HTTPS,
  r"""if (( ! _loop )); then""", "if false; then", 1),
 ("detector: TLS verification disabled (curl -k)", CP, HTTPS,
  r"""_co=(); [[ -n "$_c" ]] && _co=(--cacert "$_c")""", "_co=(-k)", 1),
 ("detector: only the first CA candidate is tried", CP, HTTPS,
  r"""[[ -n "$_c" && -f "$_c" ]] && _cas+=("$_c")""", r"""[[ -n "$_c" && -f "$_c" && ${#_cas[@]} -eq 0 ]] && _cas+=("$_c")""", 1),
 ("detector: HTTP 404 worded as a rejected key", CP, HTTPS,
  "401|403|429)", "401|403|404|429)", 1),
 ("detector: untrusted-CA warning removed", CP, HTTPS,
  "elif (( _certrc != 0 )); then", "elif false; then", 1),
 ("detector: bearer header dropped from the models request", CP, HTTPS,
  r"""                  -H @<(printf 'Authorization: Bearer %s\n' "$_key") \
""", "", 1),
 ("detector: cache drops ca_file", CP, HTTPS,
  """ca_file: (.ca_file // ""),""", "", 1),
 ("live probe: key moved into curl argv", CP, HTTPS,
  r"""-H @<(printf 'Authorization: Bearer %s\n' "$_h_secret")""", r"""-H "Authorization: Bearer $_h_secret" """.rstrip(), 1),
 # --- gate
 ("gate: key moved into curl argv", GATE, HTTPS,
  AUTH, AUTH_ARGV, 1),
 ("gate: drops --cacert", GATE, HTTPS,
  """${JEV_CA_FILE:+--cacert "$JEV_CA_FILE"}""", "", 1),
 ("gate: sends the bearer over http too", GATE, HTTPS,
  """if [[ "$JEV_BASE_URL" == https://* ]]; then""", "if true; then", 1),
 ("gate: ignores JEV_KEY_VAR in the environment", GATE, HTTPS,
  '_key="${!JEV_KEY_VAR:-}"', '_key=""', 1),
 # --- jev_mcp
 ("mcp: TLS verification off (R5)", MCP, HTTPS,
  "ctx = ssl.create_default_context()", "ctx = ssl._create_unverified_context()", 1),
 ("mcp: JEV_CA_FILE never loaded (R5b)", MCP, HTTPS,
  "ctx.load_verify_locations(cafile=ca)", "pass", 1),
 ("mcp: redirects followed with the key", MCP, HTTPS,
  "_NoRedirect, urllib.request.HTTPSHandler", "urllib.request.HTTPRedirectHandler, urllib.request.HTTPSHandler", 1),
 # --- lib.sh
 ("cma_jev_env: exports a CA path that no longer exists (R6)", LIB, HTTPS,
  """if [ -n "$_jev_ca" ] && [ -f "$_jev_ca" ]; then export JEV_CA_FILE""", """if [ -n "$_jev_ca" ]; then export JEV_CA_FILE""", 1),
 ("ensure_active: every exit 75 is a failed rollback", LIB, WIRING,
  """if [[ "$_cma_lc_rows3" != "$_cma_lc_rows" || "$_cma_lc_row3" != "$_cma_lc_row" ]]; then""", "if true; then", 1),
 ("ensure_active: gate exit code replaced by 1", LIB, WIRING,
  'return "$_cma_lc_switch_rc"', "return 1", 1),
 ("ensure_active: STRICT already-active check removed", LIB, WIRING,
  """if [[ "${LLMCTL_VALIDATE_STRICT:-0}" == "1" ]]; then
      local _cma_lc_rv_out""", """if false; then
      local _cma_lc_rv_out""", 1),
 # --- hardening round 2 (HARD suite)
 ("gate: JEV_GATE=off no longer recorded", GATE, HARD,
  "$JEV_STATE_DIR/gate-off.log\" 2>/dev/null || true", "/dev/null 2>/dev/null || true", 1),
 ("jev-setup: consent gate removed", "scripts/jev-setup.sh", HARD,
  'if [ "$CHECK" = 0 ] && [ "$UNINSTALL" = 0 ] && [ "$CONSENT" != 1 ]; then', "if false; then", 1),
 ("assert.sh: zero-assertion file passes", "scripts/tests/lib/assert.sh", HARD,
  "if (( TESTS_PASSED + TESTS_FAILED == 0 )); then", "if false; then", 1),
 ("shared opener follows cross-origin redirects", "scripts/http_noredirect.py", HARD,
  "if self._origin(newurl) != self._origin(req.full_url):", "if False:", 1),
 ("cma_jq_edit swallows a failed edit", "scripts/lib.sh", HARD,
  "    return 1\n  fi\n  mode=", "    return 0\n  fi\n  mode=", 1),
 ("fixture pid lost in a subshell", "scripts/tests/test_failing_layer_attribution.sh", HARD,
  'start_server notools; PORT_NT="$SRV_PORT"', 'PORT_NT="$(start_server notools)"', 1),
# --- docs
 ("docs: README anchor broken (reviewer mutation A)", "README.md", DOCS,
  "(#-constitution-hub-engine)", "(#-constitution-hub-engines-BROKEN)", 1),
 ("docs: mermaid statement broken by a semicolon", "docs/diagrams/decide-gateway-flow.mmd", DOCS,
  "Note over GW: HTTPS only, bearer key mandatory", "Note over GW: HTTPS only; bearer key mandatory", 1),
 ("docs: README names only one third-party submodule", "README.md", DOCS,
  "and\n  `submodules/ccusage`.", ".", 1),
]

def main():
    if sys.argv[1] == "list":
        for i, m in enumerate(M):
            print("%d\t%s\t%s" % (i, m[2], m[0]))
        return 0
    idx, root = int(sys.argv[2]), sys.argv[3]
    label, f, suite, old, new, count = M[idx]
    p = root + "/" + f
    s = open(p, encoding="utf-8").read()
    if old not in s:
        print("pattern absent: " + label, file=sys.stderr)
        return 3
    s = s.replace(old, new) if count is None else s.replace(old, new, count)
    open(p, "w", encoding="utf-8").write(s)
    return 0

if __name__ == "__main__":
    sys.exit(main())
