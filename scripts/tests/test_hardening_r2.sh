#!/usr/bin/env bash
# test_hardening_r2.sh — v1.32.0 hardening round 2 (written RED first):
#  A  JEV_GATE=off is RECORDED (timestamped line in the JEV state dir) and jev-stats reports it
#  B  jev-setup edits agent homes only with explicit consent (--yes / JEV_SETUP_CONSENT=1 /
#     a previous consent stamp for --if-stale); a pre-existing file is backed up first
#  C  ONE shared credential-safe opener (http_noredirect.py): cross-origin redirects refused,
#     same-origin allowed; model_verify / alias_e2e_test / jev_mcp / quota_probe use it
#  D  test fixtures record server PIDs in the parent shell (no `$(start_server ...)` pid loss)
#  E  assert.sh summary FAILS when a test file asserted nothing (vacuous pass)
#  F  cma_jq_edit: one atomic, loud JSON-edit helper; no silent jq failures
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e
PIDS=()
trap 'for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null; done; cleanup_sandbox' EXIT

# ------------------------------------------------------------------ A
it "A: JEV_GATE=off is recorded, and jev-stats reports the kill-switch uses"
export JEV_STATE_DIR="$HOME/jst"; mkdir -p "$JEV_STATE_DIR"
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | JEV_GATE=off JEV_AGENT=claude bash "$SCRIPTS_DIR/jev-gate.sh" >/dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "kill switch still passes through (exit 0)"
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | JEV_GATE=off bash "$SCRIPTS_DIR/jev-gate.sh" >/dev/null 2>&1
assert_file "$JEV_STATE_DIR/gate-off.log" "gate-off.log written"
assert_eq 2 "$(grep -c . "$JEV_STATE_DIR/gate-off.log" 2>/dev/null || echo 0)" "one line per use"
grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z ' "$JEV_STATE_DIR/gate-off.log" && _pass "lines are UTC-timestamped" || _fail "lines are UTC-timestamped" "$(cat "$JEV_STATE_DIR/gate-off.log" 2>/dev/null)"
out="$(bash "$SCRIPTS_DIR/jev-stats.sh" 2>&1)"
case "$out" in *"kill-switch"*"2"*) _pass "jev-stats (no decisions yet) still reports 2 kill-switch uses" ;; *) _fail "jev-stats reports kill-switch uses" "$out" ;; esac
assert_eq 2 "$(bash "$SCRIPTS_DIR/jev-stats.sh" --json 2>/dev/null | jq -r '.gate_off.count // "?"')" "jev-stats --json gate_off.count"
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | JEV_STATE_DIR="$HOME/jst2" JEV_BASE_URL=http://127.0.0.1:1 bash "$SCRIPTS_DIR/jev-gate.sh" >/dev/null 2>&1
[[ ! -e "$HOME/jst2/gate-off.log" ]] && _pass "control: a normal (gate on) call writes no kill-switch line" || _fail "control" "log created"

# ------------------------------------------------------------------ B
it "B: jev-setup refuses unattended edits of agent homes without consent; backs up first"
export JEV_STATE_DIR="$HOME/jstB"; mkdir -p "$HOME/.claude-acct1" "$HOME/.claude-shared" "$HOME/.config/jev"
echo '{"model":"x"}' > "$HOME/.claude-acct1/settings.json"
before="$(cksum < "$HOME/.claude-acct1/settings.json")"
bash "$SCRIPTS_DIR/jev-setup.sh" --agents claude </dev/null >"$HOME/b1.out" 2>&1; rc=$?
assert_eq 3 "$rc" "no consent + non-interactive -> exit 3"
assert_eq "$before" "$(cksum < "$HOME/.claude-acct1/settings.json")" "agent home untouched without consent"
grep -q -- "--yes" "$HOME/b1.out" && _pass "message names the --yes consent flag" || _fail "message names --yes" "$(cat "$HOME/b1.out")"
bash "$SCRIPTS_DIR/jev-setup.sh" --agents claude --if-stale 60 --quiet </dev/null >/dev/null 2>&1
assert_eq "$before" "$(cksum < "$HOME/.claude-acct1/settings.json")" "lazy --if-stale refresh does not edit without a prior consent stamp"
bash "$SCRIPTS_DIR/jev-setup.sh" --agents claude --check --quiet </dev/null >/dev/null 2>&1; rc=$?
assert_eq "$before" "$(cksum < "$HOME/.claude-acct1/settings.json")" "--check never writes"
bash "$SCRIPTS_DIR/jev-setup.sh" --agents claude --yes --quiet </dev/null >/dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "--yes proceeds"
[[ "$(cksum < "$HOME/.claude-acct1/settings.json")" != "$before" ]] && _pass "settings.json edited with consent" || _fail "settings.json edited with consent" "unchanged"
ls "$HOME"/.claude-acct1/settings.json.prejev.* >/dev/null 2>&1 && _pass "pre-existing settings.json backed up first" || _fail "backup first" "no .prejev backup"
assert_file "$JEV_STATE_DIR/consent" "consent stamp recorded"
JEV_SETUP_CONSENT=1 bash "$SCRIPTS_DIR/jev-setup.sh" --agents claude --quiet </dev/null >/dev/null 2>&1
assert_eq 0 "$?" "JEV_SETUP_CONSENT=1 is an explicit consent too"

# ------------------------------------------------------------------ C
it "C: shared opener - cross-origin redirect refused, same-origin followed, strict mode refuses all"
cat > "$HOME/rs.py" <<'PY'
import http.server, sys, threading
log=[]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        open(sys.argv[2],"a").write("%s auth=%s\n"%(self.path,self.headers.get("Authorization","-")))
        if self.path=="/same": self.send_response(302); self.send_header("Location","/ok"); self.end_headers()
        elif self.path=="/cross": self.send_response(302); self.send_header("Location",sys.argv[3]); self.end_headers()
        else: b=b"{}"; self.send_response(200); self.send_header("Content-Length","2"); self.end_headers(); self.wfile.write(b)
    def log_message(self,*a): pass
s=http.server.HTTPServer(("127.0.0.1",0),H)
open(sys.argv[1],"w").write(str(s.server_address[1])); s.serve_forever()
PY
: > "$HOME/a.log"; : > "$HOME/b.log"
python3 "$HOME/rs.py" "$HOME/pb" "$HOME/b.log" "/" & PIDS+=("$!")
for _ in $(seq 1 50); do [[ -s "$HOME/pb" ]] && break; sleep 0.1; done; PB="$(cat "$HOME/pb")"
python3 "$HOME/rs.py" "$HOME/pa" "$HOME/a.log" "http://127.0.0.1:$PB/stolen" & PIDS+=("$!")
for _ in $(seq 1 50); do [[ -s "$HOME/pa" ]] && break; sleep 0.1; done; PA="$(cat "$HOME/pa")"
res="$(python3 - "$SCRIPTS_DIR" "$PA" <<'PY' 2>&1
import sys, urllib.request, urllib.error
sys.path.insert(0, sys.argv[1])
import http_noredirect as h
pa=sys.argv[2]
def get(path, **kw):
    req=urllib.request.Request("http://127.0.0.1:%s%s"%(pa,path), headers={"Authorization":"Bearer SECRET"})
    try: return h.open_url(req, timeout=3, **kw).status
    except urllib.error.HTTPError as e: return e.code
print("same_origin_follows=%s cross_refused=%s strict_same_refused=%s" % (get("/same",same_origin=True), get("/cross",same_origin=True), get("/same")))
PY
)"
case "$res" in "same_origin_follows=200 cross_refused=302 strict_same_refused=302") _pass "policy: $res" ;; *) _fail "policy" "$res" ;; esac
[[ ! -s "$HOME/b.log" ]] && _pass "sink-side: the cross-origin target received no request at all" || _fail "cross-origin target untouched" "$(cat "$HOME/b.log")"
for f in model_verify.py alias_e2e_test.py jev_mcp.py quota_probe.py; do
  grep -q "http_noredirect" "$SCRIPTS_DIR/$f" && _pass "$f uses the shared opener" || _fail "$f uses the shared opener" "no import"
  grep -nE "^from urllib\.request import .*\burlopen\b|urllib\.request\.urlopen\(" "$SCRIPTS_DIR/$f" >/dev/null && _fail "$f has no bare urllib urlopen" "$(grep -nE 'urllib\.request\.urlopen\(|import .*urlopen' "$SCRIPTS_DIR/$f" | head -2)" || _pass "$f has no bare urllib urlopen"
done
assert_eq 1 "$(grep -c 'class .*Redirect' "$SCRIPTS_DIR/http_noredirect.py" | awk '{print ($1>=2)?1:0}')" "positive control: the shared module defines the handlers"
assert_eq 0 "$(grep -l 'class _NoRedirect' "$SCRIPTS_DIR"/*.py | wc -l | tr -d ' ')" "no duplicate _NoRedirect class left in scripts/*.py"

# ------------------------------------------------------------------ D
it "D: fixtures do not lose server PIDs in a command-substitution subshell"
for f in test_model_verify_tls.sh test_failing_layer_attribution.sh test_jev_detect_https.sh; do
  if grep -nE '="\$\(start_(server|srv)[ )]' "$TESTS_DIR/$f" >/dev/null; then _fail "$f: no \$(start_server ...)" "$(grep -nE '="\$\(start_(server|srv)' "$TESTS_DIR/$f" | head -1)"; else _pass "$f: servers started in the parent shell"; fi
done

# ------------------------------------------------------------------ E
it "E: a test file that asserted nothing FAILS in summary() (no vacuous pass)"
cat > "$HOME/vac.sh" <<SH
source "$TESTS_DIR/lib/assert.sh"
summary
SH
bash "$HOME/vac.sh" >/dev/null 2>&1; assert_eq 1 "$?" "summary with zero assertions exits 1"
cat > "$HOME/ok.sh" <<SH
source "$TESTS_DIR/lib/assert.sh"
_pass x
summary
SH
bash "$HOME/ok.sh" >/dev/null 2>&1; assert_eq 0 "$?" "control: one passing assertion exits 0"

# ------------------------------------------------------------------ F
it "F: cma_jq_edit is atomic and loud"
echo '{"a":1}' > "$HOME/j.json"; chmod 644 "$HOME/j.json"
cma_jq_edit "$HOME/j.json" '.b = 2'; rc=$?
assert_eq 0 "$rc" "good edit succeeds"
assert_eq 2 "$(jq -r .b "$HOME/j.json")" "edit applied"
assert_eq 644 "$(stat -c %a "$HOME/j.json")" "file mode preserved"
echo 'not json' > "$HOME/bad.json"
err="$(cma_jq_edit "$HOME/bad.json" '.b = 2' 2>&1)"; rc=$?
assert_eq 1 "$rc" "unparsable input -> return 1"
assert_eq "not json" "$(cat "$HOME/bad.json")" "file untouched on failure"
case "$err" in *bad.json*FAILED*) _pass "failure is loud and names the file" ;; *) _fail "loud failure" "$err" ;; esac
assert_eq 0 "$(ls "$HOME"/bad.json.* 2>/dev/null | wc -l | tr -d ' ')" "no temp file left behind"
for f in claude-providers.sh claude-unify.sh jev-setup.sh; do
  grep -q "cma_jq_edit\|jq merge failed.*\$_jqerr\|_jqerr" "$SCRIPTS_DIR/$f" && _pass "$f routes JSON edits through the loud helper" || _fail "$f routes JSON edits through the loud helper" "not found"
done
mkdir -p "$HOME/.local/share/claude-multi-account/providers"
echo 'garbage' > "$HOME/ka.json"
out="$(CMA_KEY_ALIASES="$HOME/ka.json" bash -c 'source "'"$SCRIPTS_DIR"'/claude-providers.sh" >/dev/null 2>&1; KEY_ALIASES="$HOME/ka.json"; cmd_add --from-key FOO --id bar' 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && _pass "claude-providers add on a corrupt aliases file fails (rc=$rc)" || _fail "add fails loudly on a corrupt file" "rc=0: $out"

summary
