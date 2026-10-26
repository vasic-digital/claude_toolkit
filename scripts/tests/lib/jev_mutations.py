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
KORIG = "test_jev_key_origin_class.sh"
HLIVE = "test_jev_hosted_live_fixes.sh"
PLUGIN = "scripts/opencode-jev-plugin.js"
KHOOK = "test_kimi_render_config_jev_hooks.sh"
SETUP = "test_jev_setup_idempotent.sh"
SETUPSH = "scripts/jev-setup.sh"
KLIB = "scripts/jev-kimi-lib.sh"
LDIR = "scripts/jev-lockdir-lib.sh"
KLOCK = "test_jev_kimi_lock.sh"
LIFE = "test_jev_setup_lifecycle.sh"

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
  """elif [[ "$JEV_BASE_URL" == https://* ]]; then""", "elif true; then", 1),
 ("gate: ignores JEV_KEY_VAR in the environment", GATE, HTTPS,
  '  _key="${!_kvar:-}"', '  _key=""', 1),
 # --- jev_mcp
 ("mcp: TLS verification off (R5)", MCP, HTTPS,
  "ctx = ssl.create_default_context()", "ctx = ssl._create_unverified_context()", 1),
 ("mcp: JEV_CA_FILE never loaded (R5b)", MCP, HTTPS,
  "    if ca and os.path.isfile(ca):\n        ctx.load_verify_locations(cafile=ca)", "    if ca and os.path.isfile(ca):\n        pass", 1),
 ("mcp: redirects followed with the key", "scripts/http_noredirect.py", HTTPS,
  "handlers = [SameOriginRedirect() if same_origin else NoRedirect()]", "handlers = [urllib.request.HTTPRedirectHandler()]", 1),
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
# --- review round (NO-GO fix): classes A-C, E
 ("mcp: Authorization no longer stripped for non-https", MCP, HARD,
  'req.headers.pop("Authorization", None)', "pass", 1),
 ("redirect policy: _origin drops the host", "scripts/http_noredirect.py", HARD,
  'return (u.scheme, (u.hostname or "").lower(), port)', "return (u.scheme, port)", 1),
 ("redirect policy: _origin drops the scheme", "scripts/http_noredirect.py", HARD,
  'return (u.scheme, (u.hostname or "").lower(), port)', 'return ((u.hostname or "").lower(), port)', 1),
 ("kimi hooks: stale non-tool matcher restored", "scripts/jev-kimi-tools.txt", KHOOK,
  "Bash|Write|Edit", "Bash|WriteFile|StrReplaceFile", 1),
 ("kimi hooks: backslash in the gate path accepted", KLIB, KHOOK,
  r"""'' | *\\* | *\"* | *[[:cntrl:]]*) return 1 ;;""", r"""'' | *\"* | *[[:cntrl:]]*) return 1 ;;""", 1),
 ("kimi hooks: renderer ignores the consent stamp (agents list)", CP, KHOOK,
  'jev_kimi_stamp_has "$stamp" kimi || return 0', ': # stamp ignored', 1),
 ("kimi hooks: after_sync no longer refreshes the twins", CP, KHOOK,
  '  _cma_jev_write_endpoint_cache "$records"\n  _cma_kimi_jev_hooks_refresh || true\n}', '  _cma_jev_write_endpoint_cache "$records"\n}', 1),
 ("jev-setup: --uninstall leaves the canonical gate copy", SETUPSH, LIFE,
  'rm -f "$GATE_INSTALLED" 2>/dev/null || true', ': # gate copy kept', 1),
 ("jev-setup: _jq_merge ignores jq's exit status", SETUPSH, HARD,
  'if [ "$_jqrc" -eq 0 ] && [ -z "$_jqerr" ] && [ -s "$tmp" ]; then', 'if [ -z "$_jqerr" ] && [ -s "$tmp" ]; then', 1),
 ("mcp: candidate ca_file ignored (per-candidate trust root)", MCP, HARD,
  "    if ca_file:\n        if not os.path.isfile(ca_file)", "    if False:\n        if not os.path.isfile(ca_file)", 1),
 ("mcp: route candidate's ca_file not passed through", MCP, HARD,
  'ca_file=_route_ca_file(candidate.get("ca_file")),', "ca_file=None,", 1),
 ("detector: IPv6 host not bracketed in URLs", CP, HTTPS,
  "    *:*) printf '[%s]' \"$h\" ;;", "    *:*) printf '%s' \"$h\" ;;", 1),
 ("detector: silent on a non-loopback https /healthz failure (warning branch removed)", CP, HTTPS,
  "                  printf 'gateway at https://%s:%s did not answer %s (curl rc %s) - not registered\\n' \\\n                    \"$_uh\" \"$_tport\" \"$_thpath\" \"$_tlsrc\" > \"$_note\"", "                  :", 1),
# --- review round 2 (NO-GO fix): classes A-D, reviewer mutants M2-M4
 ("kimi hooks: control chars accepted in the gate path (reviewer M4)", KLIB, KHOOK,
  r"""'' | *\\* | *\"* | *[[:cntrl:]]*) return 1 ;;""", r"""'' | *\\* | *\"*) return 1 ;;""", 1),
 ("kimi hooks: control chars accepted in the gate path (lifecycle, real jev-setup)", KLIB, LIFE,
  r"""'' | *\\* | *\"* | *[[:cntrl:]]*) return 1 ;;""", r"""'' | *\\* | *\"*) return 1 ;;""", 1),
 ("kimi hooks: over-matching matcher Bash|Write|Edit|ea (reviewer M2)", "scripts/jev-kimi-tools.txt", KHOOK,
  "Bash|Write|Edit", "Bash|Write|Edit|ea", 1),
 ("mcp: candidate ca_file falls through to JEV_CA_FILE (reviewer M3, trust roots mixed)", MCP, HARD,
  "        ctx.load_verify_locations(cafile=ca)\n        return ctx\n    ca = os.environ.get", "        ctx.load_verify_locations(cafile=ca)\n    ca = os.environ.get", 1),
 ("kimi hooks: stamp match is a substring (kimix counts as kimi)", KLIB, KHOOK,
  '*,"${2-}",* | *,all,*) return 0 ;;', '*"${2-}"* | *,all,*) return 0 ;;', 1),
 ("kimi hooks: legacy empty stamp grants consent", KLIB, KHOOK,
  '[ -e "${1-}" ] || return 1', '[ -e "${1-}" ] || return 1; [ -s "$1" ] || return 0', 1),
 ("jev-setup: uninstall of one agent deletes shared artifacts despite other wiring", SETUPSH, LIFE,
  'if [ -n "$keep" ]; then', 'if false; then', 1),
 ("jev-setup: claude --check does not verify the hook target is executable", SETUPSH, LIFE,
  '\n          elif [ ! -x "$_c" ]; then _say "claude: $sf hook target $_c not executable"; _bad=1; fi', '; fi', 1),
 ("jev-setup: kimi --check does not flag a stale matcher", SETUPSH, LIFE,
  'elif [ "$(_kimi_block_current "$conf")" != "$(_kimi_block_desired)" ]; then\n              _say "kimi: $conf hooks STALE', 'elif false; then\n              _say "kimi: $conf hooks STALE', 1),
 ("jev-setup: kimi install does not upgrade a stale marker block", SETUPSH, LIFE,
  'if [ "$(_kimi_block_current "$conf")" != "$(_kimi_block_desired)" ]; then\n                _kimi_block_write', 'if false; then\n                _kimi_block_write', 1),
 ("jev-setup: stamp does not record which agents were selected", SETUPSH, LIFE,
  'agents=%s', 'agents=%.0s', 1),
 ("jev-setup inventory: claude wiring not counted (R8)", SETUPSH, LIFE,
  '&& { found="$found,claude"; break; }', '&& { :; break; }', 1),
 ("jev-setup inventory: kimi wiring not counted (R3)", SETUPSH, LIFE,
  '&& { found="$found,kimi"; break; }', '&& { :; break; }', 1),
 ("jev-setup inventory: opencode wiring not counted (R7)", SETUPSH, LIFE,
  'found="$found,opencode"', ':', 1),
 ("jev-setup uninstall: inventory ignored when deciding to keep the shared gate (R9)", SETUPSH, LIFE,
  'inv="$(_inventory_wiring)"', 'inv=""', 1),
 ("renderer refresh: rewritten config lacking default_model replaces the original (guard removed)", CP, KHOOK,
  " || ! grep -q '^default_model = ' \"$tmp\" 2>/dev/null; then", "; then", 1),
 ("mcp: relative candidate ca_file resolved against the cwd", MCP, HARD,
  'ca_file=_route_ca_file(candidate.get("ca_file")),', 'ca_file=candidate.get("ca_file") or None,', 1),
 ("renderer refresh: write failure replaces the config (fail-closed check removed)", CP, KHOOK,
  '    if ! { awk -v b=\'# cma-jev:hooks BEGIN\' -v e=\'# cma-jev:hooks END\' \'\n        (index($0, b) == 1 && $0 != b) || (index($0, e) == 1 && $0 != e) { bad = 1 }\n        skip { if ($0 == e) skip = 0; next }\n        $0 == b { skip = 1; pend = 0; next }\n        $0 == "" { pend++; next }\n        { while (pend > 0) { print ""; pend-- } print }\n        END { if (skip || bad) exit 7; while (pend > 0) { print ""; pend-- } }\' "$f" \\\n        && { [[ -z "$blk" ]] || printf \'%s\\n\' "$blk"; }; } > "$tmp" 2>/dev/null \\\n       || [[ ! -s "$tmp" ]] || ! grep -q \'^default_model = \' "$tmp" 2>/dev/null; then\n', '    if false; then\n', 1),
# --- R4 reviewer mutations (round 4 review of v1.32.0): each MUST be killed by the named suite
 ("opencode inventory: plugin-file half dropped (o1)", SETUPSH, LIFE,
  """  if [ -e "$HOME/.config/opencode/plugins/jev-gate.js" ] \\
     || jq -e '.mcp.jev' "$OPENCODE_CONFIG" >/dev/null 2>&1; then""",
  """  if jq -e '.mcp.jev' "$OPENCODE_CONFIG" >/dev/null 2>&1; then""", 1),
 ("opencode inventory: .mcp.jev half dropped (o2)", SETUPSH, LIFE,
  """  if [ -e "$HOME/.config/opencode/plugins/jev-gate.js" ] \\
     || jq -e '.mcp.jev' "$OPENCODE_CONFIG" >/dev/null 2>&1; then""",
  """  if [ -e "$HOME/.config/opencode/plugins/jev-gate.js" ]; then""", 1),
 ("agents: empty --agents list accepted (o3)", SETUPSH, LIFE,
  """  [ -n "$csv" ] || _usage_err "--agents needs a non-empty list (claude,kimi,pi,opencode or all)""", "  :", 1),
 ("agents: empty list entry accepted (o3c)", SETUPSH, LIFE,
  """  case ",$csv," in *,,*) _usage_err""", """  case ",$csv," in __NEVER__) _usage_err""", 1),
 ("if-stale: digit check removed (o4)", SETUPSH, LIFE,
  """case "$IF_STALE" in ''|*[!0-9]*) _usage_err "--if-stale needs a number of seconds, got '$IF_STALE'" ;; esac""", ":", 1),
 ("kimi write: backup not fail-closed (o6)", SETUPSH, LIFE,
  """    if _backup "$f" && mv -f "$tmp" "$f"; then""", """    if { _backup "$f" || true; } && mv -f "$tmp" "$f"; then""", 1),
 ("_backup: failed copy reported as success (o6b)", SETUPSH, LIFE,
  """    printf 'jev-setup: backup of %s failed - left untouched (nothing written)\\n' "$1" >&2
    return 1""", """    printf 'jev-setup: backup of %s failed - left untouched (nothing written)\\n' "$1" >&2
    return 0""", 1),
 ("uninstall keep: stamp agents ignored (o8)", SETUPSH, LIFE,
  """  keep="$(_csv_union "$remaining" "$inv")""", """  keep="$(_csv_union "" "$inv")""", 1),
 ("mcp: unreadable explicit ca_file falls back to the default trust (o12)", MCP, HARD,
  """            raise RuntimeError("candidate ca_file is not a readable file")""", "            return ctx", 1),
 ("kimi --check: not-executable gate not reported (o15)", SETUPSH, LIFE,
  """            elif [ ! -x "$GATE_INSTALLED" ]; then
              _say "kimi: $conf hook target $GATE_INSTALLED not executable"; changed=1""",
  """            elif false; then
              :""", 1),
 ("lock: jev-setup pre-flight lock probe removed (R4-1/R5-6)", SETUPSH, KLOCK,
  """  # Pre-flight: fail BEFORE anything is written when the lock cannot be taken.
  if ! jev_kimi_lock "$JEV_STATE_DIR"; then""", """  # Pre-flight: fail BEFORE anything is written when the lock cannot be taken.
  if ! true; then""", 1),
 ("lock: jev-setup section lock _lk never takes the lock (R5-6)", SETUPSH, KLOCK,
  """  if ! jev_kimi_lock "$JEV_STATE_DIR"; then
    printf 'jev-setup: could not take the config lock %s/kimi-config.lock (another run holds it?) - remaining steps skipped""", """  if ! true; then
    printf 'jev-setup: could not take the config lock %s/kimi-config.lock (another run holds it?) - remaining steps skipped""", 1),
 ("lock: refresh takes no lock (R4-1)", CP, LIFE,
  """  jev_kimi_lock "$(_cma_jev_state_dir)"
}""", """  return 0
}""", 1),
 ("lock: refresh block computed BEFORE the lock, stale under it (R4-1)", CP, LIFE,
  """  local f tmp blk real rrc=0
  if ! _cma_kimi_cfg_lock; then
    printf 'claude-providers: could not take the config lock - Kimi twin hooks not refreshed\\n' >&2
    return 0
  fi
  # Computed once per run but UNDER the lock; its warnings (unusable
  # jev-kimi-tools.txt ...) reach stderr.
  blk="$(_cma_kimi_jev_hooks_block)\"""",
  """  local f tmp blk real rrc=0
  blk="$(_cma_kimi_jev_hooks_block)"
  if ! _cma_kimi_cfg_lock; then
    printf 'claude-providers: could not take the config lock - Kimi twin hooks not refreshed\\n' >&2
    return 0
  fi""", 1),
 ("claude --check: interpreter-prefixed command split on spaces (R4-11)", SETUPSH, LIFE,
  """            while [ ! -e "$_w" ] && [[ "$_w" == *" "* ]]; do _w="${_w#* }"; done""",
  """            _w="${_w##* }""" + '"', 1),
 ("lock R5-1: mkdir backend never breaks a stale lockdir (M4)", LDIR, KLOCK,
  """        if ! _cma_lockdir_alive "$holder"; then _cma_lockdir_break_stale "$dir" "$holder"; fi""",
  """        if false; then _cma_lockdir_break_stale "$dir" "$holder"; fi""", 1),
 ("lock R5-1/R6: the pid claim is a plain write, not O_EXCL (mkdir alone is the mutex; M10)", LDIR, KLOCK,
  """_cma_lockdir_claim() { ( set -C; printf""",
  """_cma_lockdir_claim() { ( printf""", 1),
 ("lock R6: breaker role not claimed O_EXCL (any mkdir 'winner' breaks)", LDIR, KLOCK,
  """  if ! _cma_lockdir_claim "$br"; then return 0; fi""",
  """  true""", 1),
 ("lock R5-1: breaker removes without re-reading the observed pid", LDIR, KLOCK,
  """    if { [ -n "$observed" ] && [ "$cur" = "$observed" ] && ! _cma_lockdir_alive "$cur"; } \\""",
  """    if { [ -n "$observed" ] && true; } \\""", 1),
 ("lock R5-1: release is blind (removes a lock owned by another)", LDIR, KLOCK,
  """  if [ "$(_cma_lockdir_pid "$dir")" = "$$" ]; then
    rm -f "$dir/pid" 2>/dev/null; rmdir "$dir" 2>/dev/null""", """  if true; then
    rm -f "$dir/pid" 2>/dev/null; rmdir "$dir" 2>/dev/null""", 1),
 ("lock R5-1: pid-less lockdir never broken (no grace break)", LDIR, KLOCK,
  """        if [ $((now - empty_since)) -ge "$grace" ]; then""", """        if false; then""", 1),
 ("lock R5-1: wait deadline never enforced", LDIR, KLOCK,
  """    [ $((now - start)) -ge "$wait" ] && return 1""", """    :""", 1),
 ("lock R5-2: re-entrant acquire does not count depth (M9)", KLIB, KLOCK,
  """    _JEV_LOCK_DEPTH=$((_JEV_LOCK_DEPTH + 1))
    return 0
  fi
  mkdir -p""", """    return 0
  fi
  mkdir -p""", 1),
 ("lock R5-2: flock -w timeout fails open (M5)", KLIB, KLOCK,
  """    else flock -w "$wait" 7 || { { exec 7>&-; } 2>/dev/null; return 1; }""",
  """    else flock -w "$wait" 7 || { { exec 7>&-; } 2>/dev/null; return 0; }""", 1),
 ("lock R5-2: render decides the hooks block BEFORE the lock (M2)", CP, KLOCK,
  """  if ! _cma_kimi_cfg_lock; then
    rm -f "$tmp"
    cma_warn "kimi config: could not take the config lock — $kdir/config.toml not rewritten"
    return 1
  fi
  _cma_kimi_jev_hooks_block >> "$tmp"
""", """  _cma_kimi_jev_hooks_block >> "$tmp"
  if ! _cma_kimi_cfg_lock; then
    rm -f "$tmp"
    cma_warn "kimi config: could not take the config lock — $kdir/config.toml not rewritten"
    return 1
  fi
""", 1),
 ("refresh R5-5: variant BEGIN/END lines not detected (prefix-only match)", CP, KLOCK,
  """        (index($0, b) == 1 && $0 != b) || (index($0, e) == 1 && $0 != e) { bad = 1 }
""", "", 1),
 ("refresh R5-5: unterminated BEGIN no longer fails closed", CP, KLOCK,
  """END { if (skip || bad) exit 7;""", """END { if (0) exit 7;""", 1),
 ("refresh R5-5: blank lines outside the block dropped", CP, KLOCK,
  """        $0 == "" { pend++; next }""", """        $0 == "" { next }""", 1),
 ("refresh R5-5: malformed block does not make refresh return nonzero", CP, KLOCK,
  """  return "$rrc\"""", """  return 0""", 1),
 ("jev-setup R5-6: config lock held across the whole run", SETUPSH, KLOCK,
  """_ulk() { [ "$CHECK" = 1 ] || jev_kimi_unlock; }""", """_ulk() { :; }""", 1),
 ("jev-setup R5-6: lock fd 7 leaks into the endpoint-env subshell and its keys-file process", SETUPSH, KLOCK,
  "$(exec 7>&-; _jev_endpoint_env)", "$(_jev_endpoint_env)", 3),
# --- docs
 ("docs: README anchor broken (reviewer mutation A)", "README.md", DOCS,
  "(#-constitution-hub-engine)", "(#-constitution-hub-engines-BROKEN)", 1),
 ("docs: mermaid statement broken by a semicolon", "docs/diagrams/decide-gateway-flow.mmd", DOCS,
  "Note over GW: HTTPS only, bearer key mandatory", "Note over GW: HTTPS only; bearer key mandatory", 1),
 ("docs: README names only one third-party submodule", "README.md", DOCS,
  "and\n  `submodules/ccusage`.", ".", 1),

# --- round-3 class: "a key can reach a host that was never validated" (review r2 I-1..I-3)
 ("gate: every https origin counts as pinned (key released anywhere)", GATE, KORIG,
  "    _key_pinned=0\n    # Userinfo", "    _key_pinned=1\n    # Userinfo", 1),
 ("gate: shipped-pin check dropped (api.typesafe.ai no longer released its own key)", GATE, KORIG,
  """if [ "$_key_pinned" = 0 ] && [ -f "$_pinsf" ] && jq -e""", """if false && jq -e""", 1),
 ("gate: pin matches the origin but not the key variable", GATE, KORIG,
  """and (.key_var // "") == $v and (.enabled // true))]""", """and (.enabled // true))]""", 1),
 ("gate: operator trusted-origin list ignores the key variable", GATE, KORIG,
  """[ "${_t#*=}" = "$_kvar" ] && """, """true && """, 1),
 ("gate: loopback octets above 255 accepted (127.999.0.1)", GATE, KORIG,
  r""" \
         && ! printf '%s' "$_h" | grep -qE '(^|\.)(25[6-9]|2[6-9][0-9]|[3-9][0-9][0-9])(\.|$)'; then""", """; then""", 1),
 ("gate: userinfo/backslash/percent authority not refused", GATE, KORIG,
  r"""case "$_origin" in *[@\\%[:space:]]*) _origin="" ;; esac""", ":", 1),
 ("gate: unpinned origin still makes the request (key_unpinned ignored)", GATE, KORIG,
  """  elif [ "$_key_pinned" != 1 ]; then _no_key=2; fi""", "  fi", 1),
 ("gate: endpoint cache attests a key (cache used as a pin)", GATE, HLIVE,
  "    _key_pinned=0\n    # Userinfo", "    _key_pinned=$( [ -s \"${CMA_PROVIDERS_DIR:-/nonexistent}/jev-endpoints.json\" ] && echo 1 || echo 0 )\n    # Userinfo", 1),
 ("mcp: key released to any https base (origin rule removed)", MCP, KORIG,
  "        if not _origin_allows_key(base, kv):", "        if False:", 1),
 ("mcp: shipped pins read from an environment override", MCP, KORIG,
  """path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "providers", "jev.json")""",
  """path = os.environ.get("CMA_JEV_PINS_FILE") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "providers", "jev.json")""", 1),
 ("mcp: pin matches the origin but not the key variable", MCP, KORIG,
  "    if (origin, key_var) in _shipped_pins():", "    if any(o == origin for o, _k in _shipped_pins()):", 1),
 ("mcp: userinfo/backslash/percent authority accepted", MCP, KORIG,
  r"""    if re.search(r"[@\\%\s]", hostport):
        return False""", "    pass", 1),
 ("plugin: key released to any https base (origin rule removed)", PLUGIN, KORIG,
  "    if (!originAllowsKey(base, keyVar)) { out.key_unpinned = true; return out; }", "    if (false) { out.key_unpinned = true; return out; }", 1),
 ("plugin: pin matches the origin but not the key variable", PLUGIN, KORIG,
  "  const pair = `${origin}=${keyVar}`;", "  const pair = SHIPPED_ORIGINS.find((s) => s.startsWith(origin + \"=\")) || \"\";", 1),
 ("plugin: key_var unvalidated and interpolated into the shell script text", PLUGIN, KORIG,
  r"""  if (!KEYVAR_RE.test(keyVar)) return "";
  if (process.env[keyVar]) return process.env[keyVar];
  try {
    // key_var travels as DATA in the environment, never inside the script text.
    return execFileSync("bash", ["-c",
      'source "${CMA_KEYS_FILE:-$HOME/api_keys.sh}" >/dev/null 2>&1; printf %s "${!KV:-}"'],""",
  r"""  if (process.env[keyVar]) return process.env[keyVar];
  try {
    // key_var travels as DATA in the environment, never inside the script text.
    return execFileSync("bash", ["-c",
      'source "${CMA_KEYS_FILE:-$HOME/api_keys.sh}" >/dev/null 2>&1; printf %s "${' + keyVar + ':-}"'],""", 1),
 ("plugin: key_var not validated before use", PLUGIN, KORIG,
  "  if (!KEYVAR_RE.test(keyVar)) return \"\";", "", 1),
 ("plugin: providers dir hardcoded (CMA_PROVIDERS_DIR ignored)", PLUGIN, KORIG,
  "process.env.CMA_PROVIDERS_DIR", "process.env.CMA_PROVIDERS_DIR_IGNORED", 1),
 ("probe: systemone_path not validated (userinfo path reaches curl)", CP, KORIG,
  """if [[ "$_h_spath" =~ ^/[A-Za-z0-9._~/-]*$ && "$_h_spath" != *..* ]]; then _h_pathok=1; fi""", "_h_pathok=1", 1),
 ("probe: path validation and final-URL host re-classification both removed", CP, KORIG,
  r"""      if [[ "$_h_spath" =~ ^/[A-Za-z0-9._~/-]*$ && "$_h_spath" != *..* ]]; then _h_pathok=1; fi
      if (( ! _h_pathok )); then _h_send=0
      elif [[ "$(_cma_jev_base_host_class "${_h_base%/}")" == "loopback" && "$(_cma_jev_base_host_class "${_h_base%/}$_h_spath")" == "loopback" ]]; then _h_send=1""",
  r"""      _h_pathok=1
      if false; then _h_send=0
      elif [[ "$(_cma_jev_base_host_class "${_h_base%/}")" == "loopback" ]]; then _h_send=1""", 1),
 ("probe: shipped-pin check dropped (any https base receives the key)", CP, KORIG,
  """elif [[ "${_h_base%/}" == https://* ]] && jq -e --arg h "$_hs\"""", """elif [[ "${_h_base%/}" == https://* ]] && true || jq -e --arg h "$_hs\"""", 1),
 ("host classifier: userinfo guard removed and port grammar loosened", CP, KORIG,
  r"""  case "$auth" in
    ""|*[@\\%[:space:]]*) printf 'invalid'; return 0 ;;
  esac
  if [[ "$auth" =~ ^(\[[^]]+\]|[^:]+)(:[0-9]+)?$ ]]; then host=""",
  r"""  case "$auth" in
    "") printf 'invalid'; return 0 ;;
  esac
  if [[ "$auth" =~ ^(\[[^]]+\]|[^:]+)(:.*)?$ ]]; then host=""", 1),
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
