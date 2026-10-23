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

# ------------------------------------------------------------------ G
it "G: jev_mcp._open never sends Authorization over plain http (sink-side), does over verified https"
FIX="$TESTS_DIR/fixtures/jev_https_server.py"
GK="$HOME/g.key"; GC="$HOME/g.crt"; GSECRET="k-fixture-secret-G"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$GK" -out "$GC" -days 2 \
  -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" >/dev/null 2>&1
assert_file "$GC" "G precondition: openssl minted a cert"
GPLOG="$HOME/g-plain.log"; GTLOG="$HOME/g-tls.log"; : > "$GPLOG"; : > "$GTLOG"
_gstart() { # _gstart <mode> <log> : sets G_PORT (parent shell, pid recorded)
  local pf; pf="$(mktemp "$HOME/gport.XXXXXX")"; : > "$pf"
  JEV_FIXTURE_LOG="$2" python3 "$FIX" 0 "$pf" "$1" "$GC" "$GK" "$GSECRET" 127.0.0.1 >/dev/null 2>&1 &
  PIDS+=("$!")
  local _; for _ in $(seq 1 60); do [[ -s "$pf" && -s "$pf.pid" ]] && break; sleep 0.1; done
  G_PORT="$(cat "$pf" 2>/dev/null)"
}
_gstart plain "$GPLOG"; GPP="$G_PORT"
_gstart tls "$GTLOG"; GTP="$G_PORT"
assert_eq 1 "$([[ -n "$GPP" && -n "$GTP" ]] && echo 1 || echo 0)" "G fixtures listening"
_mcp_open() { # _mcp_open <url> : GET with a bearer through jev_mcp._open
  PYTHONPATH="$SCRIPTS_DIR" JEV_CA_FILE="$GC" python3 -c '
import sys, urllib.request, jev_mcp
req = urllib.request.Request(sys.argv[1], headers={"Authorization": "Bearer " + sys.argv[2]})
try:
    print(jev_mcp._open(req, 5).status)
except Exception as e:
    print("ERR", type(e).__name__)
' "$1" "$GSECRET" 2>&1
}
out="$(_mcp_open "http://127.0.0.1:$GPP/v1/models")"
assert_eq 200 "$out" "plain http request reached the fixture"
grep -q 'GET /v1/models auth=-$' "$GPLOG" && _pass "sink-side: plain-http fixture saw NO Authorization header" || _fail "plain http must not carry Authorization" "$(cat "$GPLOG")"
grep -q "Bearer" "$GPLOG" && _fail "bearer leaked over plain http" "$(cat "$GPLOG")" || _pass "no bearer string anywhere in the plain-http log"
out="$(_mcp_open "https://127.0.0.1:$GTP/v1/models")"
assert_eq 200 "$out" "control: https (trusted CA) request authenticated (fixture answers 200 only for the right key)"
grep -q "GET /v1/models auth=Bearer $GSECRET\$" "$GTLOG" && _pass "control: https DOES send Authorization (the strip is scheme-conditional)" || _fail "https must send Authorization" "$(cat "$GTLOG")"

# ------------------------------------------------------------------ H
it "H: SameOriginRedirect refuses a hop that differs ONLY in host, or ONLY in scheme"
cat > "$HOME/rs2.py" <<'PY'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        open(sys.argv[2], "a").write("%s auth=%s\n" % (self.path, self.headers.get("Authorization", "-")))
        port = self.server.server_address[1]
        loc = {"/hostdiff": "http://localhost:%d/stolen" % port,
               "/schemediff": "https://127.0.0.1:%d/stolen" % port,
               "/same": "/ok"}.get(self.path)
        if loc:
            self.send_response(302); self.send_header("Location", loc); self.end_headers()
        else:
            self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"{}")
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_address[1])); s.serve_forever()
PY
: > "$HOME/h.log"
python3 "$HOME/rs2.py" "$HOME/ph" "$HOME/h.log" & PIDS+=("$!")
for _ in $(seq 1 50); do [[ -s "$HOME/ph" ]] && break; sleep 0.1; done; PH="$(cat "$HOME/ph")"
res="$(python3 - "$SCRIPTS_DIR" "$PH" <<'PY' 2>&1
import sys, urllib.request, urllib.error
sys.path.insert(0, sys.argv[1])
import http_noredirect as h
ph = sys.argv[2]
def get(path):
    req = urllib.request.Request("http://127.0.0.1:%s%s" % (ph, path), headers={"Authorization": "Bearer SECRET"})
    try:
        return h.open_url(req, timeout=3, same_origin=True).status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception as e:
        return "ERR-" + type(e).__name__
print("same=%s hostdiff=%s schemediff=%s" % (get("/same"), get("/hostdiff"), get("/schemediff")))
PY
)"
assert_eq "same=200 hostdiff=302 schemediff=302" "$res" "same-origin followed (control); host-only and scheme-only hops refused as 302"
grep -q '^/ok auth=' "$HOME/h.log" && _pass "control: the same-origin hop reached /ok" || _fail "same-origin control" "$(cat "$HOME/h.log")"
grep -q '^/stolen' "$HOME/h.log" && _fail "a host-only hop was followed with the key" "$(cat "$HOME/h.log")" || _pass "sink-side: /stolen never requested after a host-only hop"

# ------------------------------------------------------------------ I
it "I: a routes.json candidate's own ca_file is honoured; an unreadable one fails closed"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$HOME/i-other.key" -out "$HOME/i-other.crt" -days 2 \
  -subj "/CN=unrelated" >/dev/null 2>&1
_cand() { # _cand <JEV_CA_FILE value> <candidate ca_file or ""> : prints answer-or-NONE
  JEV_CA_FILE="$1" GKV="$GSECRET" PYTHONPATH="$SCRIPTS_DIR" python3 -c '
import sys, jev_mcp
c = {"base_url": sys.argv[2], "key_var": "GKV", "model": "m"}
if sys.argv[3]:
    c["ca_file"] = sys.argv[3]
orig, st = jev_mcp._post_systemone, {"ok": False}
def spy(*a, **k):
    r = orig(*a, **k); st["ok"] = True; return r
jev_mcp._post_systemone = spy
jev_mcp._candidate_answer(c, {}, [{"id": "ask", "type": "yesno", "text": "x"}])
print("ANSWER" if st["ok"] else "NONE")
' "x" "https://127.0.0.1:$GTP" "$2" 2>&1
}
: > "$GTLOG"
assert_eq "ANSWER" "$(_cand "$HOME/i-other.crt" "$GC")" "candidate ca_file ($GC) wins over a wrong JEV_CA_FILE"
grep -q "POST /v1/systemone auth=Bearer $GSECRET" "$GTLOG" && _pass "sink-side: the gateway saw the candidate request" || _fail "candidate request reached the gateway" "$(cat "$GTLOG")"
: > "$GTLOG"
assert_eq "NONE" "$(_cand "$GC" "$HOME/i-no-such-ca.crt")" "unreadable candidate ca_file fails closed (even with a good JEV_CA_FILE)"
grep -q 'POST' "$GTLOG" && _fail "request sent despite unreadable candidate CA" "$(cat "$GTLOG")" || _pass "sink-side: no request was sent"
assert_eq "NONE" "$(_cand "$HOME/i-other.crt" "")" "control: no candidate ca_file + wrong JEV_CA_FILE -> TLS verification fails"
# R4-10: the unreadable-explicit-ca_file refusal must be a REFUSAL, not "the system store happened to fail".
# SSL_CERT_FILE points OpenSSL's default trust store at the good gateway CA, so a silent
# fallback to the system store WOULD verify the gateway and answer; only the fail-closed
# raise makes this NONE. The control proves SSL_CERT_FILE really is an effective fallback here.
: > "$GTLOG"
assert_eq "ANSWER" "$(SSL_CERT_FILE="$GC" _cand "$HOME/i-other.crt" "")" "control: SSL_CERT_FILE=<good CA> alone makes the system-store fallback verify the gateway"
: > "$GTLOG"
assert_eq "NONE" "$(SSL_CERT_FILE="$GC" _cand "$GC" "$HOME/i-no-such-ca.crt")" "unreadable explicit ca_file fails closed even when a silent system-store fallback WOULD verify (SSL_CERT_FILE + JEV_CA_FILE both good)"
grep -q 'POST' "$GTLOG" && _fail "request sent despite unreadable explicit ca_file (silent fallback)" "$(cat "$GTLOG")" || _pass "sink-side: no request after an unreadable explicit ca_file, SSL_CERT_FILE notwithstanding"
: > "$GTLOG"
assert_eq "NONE" "$(_cand "$GC" "$HOME/i-other.crt")" "readable-but-WRONG candidate ca_file + GOOD JEV_CA_FILE -> NONE (trust roots are never mixed)"
grep -q 'POST' "$GTLOG" && _fail "request sent although the candidate's own (wrong) CA does not verify the gateway" "$(cat "$GTLOG")" || _pass "sink-side: no request reached the gateway"

# I2: relative candidate ca_file resolves against the routes.json directory, never the cwd;
# a candidate without ca_file deliberately trusts JEV_CA_FILE (documented) as an extra root.
mkdir -p "$HOME/i2-routes" "$HOME/i2-cwd"
cp "$GC" "$HOME/i2-routes/rel-ca.crt"
cp "$HOME/i-other.crt" "$HOME/i2-cwd/rel-ca.crt"      # same NAME in the cwd, but the WRONG CA
_candrel() { # _candrel <relative ca_file> <cwd>
  ( cd "$2" && JEV_ROUTES_FILE="$HOME/i2-routes/routes.json" JEV_CA_FILE="$HOME/i-other.crt" GKV="$GSECRET" PYTHONPATH="$SCRIPTS_DIR" python3 -c '
import sys, jev_mcp
c = {"base_url": sys.argv[1], "key_var": "GKV", "model": "m", "ca_file": sys.argv[2]}
orig, st = jev_mcp._post_systemone, {"ok": False}
def spy(*a, **k):
    r = orig(*a, **k); st["ok"] = True; return r
jev_mcp._post_systemone = spy
jev_mcp._candidate_answer(c, {}, [{"id": "ask", "type": "yesno", "text": "x"}])
print("ANSWER" if st["ok"] else "NONE")
' "https://127.0.0.1:$GTP" "$1" 2>&1 )
}
: > "$GTLOG"
assert_eq "ANSWER" "$(_candrel rel-ca.crt "$HOME/i2-cwd")" "relative candidate ca_file resolves against the routes.json dir (the cwd holds a WRONG CA of the same name)"
grep -q "POST /v1/systemone auth=Bearer $GSECRET" "$GTLOG" && _pass "sink-side: the gateway saw the request" || _fail "relative-CA request reached the gateway" "$(cat "$GTLOG")"
assert_eq "NONE" "$(_candrel only-in-cwd.crt "$HOME/i2-cwd")" "a relative ca_file absent from the routes.json dir fails closed (no cwd lookup)"
cp "$GC" "$HOME/i2-cwd/only-in-cwd.crt"
assert_eq "NONE" "$(_candrel only-in-cwd.crt "$HOME/i2-cwd")" "control: a good CA that exists ONLY in the cwd is still not found"
# documented JEV_CA_FILE fallback: no candidate ca_file + good JEV_CA_FILE -> verifies
: > "$GTLOG"
assert_eq "ANSWER" "$(_cand "$GC" "")" "documented: a candidate WITHOUT ca_file trusts JEV_CA_FILE as an extra root (system store stays on)"

# ------------------------------------------------------------------ J
it "J: the REAL jev-setup.sh never overwrites a settings file whose jq merge fails (and still merges a good one)"
export JEV_STATE_DIR="$HOME/jstJ"
mkdir -p "$HOME/.claude-jbad" "$HOME/.claude-jok" "$HOME/.claude-shared" "$HOME/.config/jev"
printf '{"a":' > "$HOME/.claude-jbad/settings.json"           # malformed JSON: jq exits non-zero with no output
echo '{"model":"x"}' > "$HOME/.claude-jok/settings.json"
badsum="$(cksum < "$HOME/.claude-jbad/settings.json")"
# Control needle: the good home IS edited by the same invocation, so a zero-change on the bad home is not "installer did nothing".
bash "$SCRIPTS_DIR/jev-setup.sh" --agents claude --yes </dev/null >"$HOME/j1.out" 2>&1; rc=$?
assert_eq "$badsum" "$(cksum < "$HOME/.claude-jbad/settings.json")" "malformed settings.json left byte-identical by the real installer"
grep -q 'jq merge failed' "$HOME/j1.out" && _pass "the failure is reported on stderr, not swallowed" || _fail "silent jq failure" "$(cat "$HOME/j1.out")"
jq -e '.hooks.PreToolUse | length > 0' "$HOME/.claude-jok/settings.json" >/dev/null 2>&1 && _pass "control: the good home received the hook in the same run" || _fail "control needle: good home merged" "$(cat "$HOME/j1.out")"
ls "$HOME/.claude-jbad"/settings.json.jevtmp.* >/dev/null 2>&1 && _fail "temp file left behind" "$(ls "$HOME/.claude-jbad")" || _pass "no jevtmp leftovers in the failing home"
# jq that prints a (different, valid) document, exits 1 and says NOTHING on stderr - the `jq -e` false/null shape.
# Only the exit status can tell this apart from success, so the real jev-setup.sh must honour it.
mkdir -p "$HOME/jshim" "$HOME/.claude-jrc"; REALJQ="$(command -v jq)"
cat > "$HOME/jshim/jq" <<SHIM
#!/usr/bin/env bash
"$REALJQ" "\$@" >/dev/null 2>&1
printf '{"clobbered":true}\n'
exit 1
SHIM
chmod +x "$HOME/jshim/jq"
echo '{"keep":1}' > "$HOME/.claude-jrc/settings.json"; rcsum="$(cksum < "$HOME/.claude-jrc/settings.json")"
PATH="$HOME/jshim:$PATH" bash "$SCRIPTS_DIR/jev-setup.sh" --agents claude --yes </dev/null >"$HOME/j2.out" 2>&1
assert_eq "$rcsum" "$(cksum < "$HOME/.claude-jrc/settings.json")" "jq exiting 1 with no stderr and a valid-looking stdout does not overwrite the file"
grep -q 'jq rc=1' "$HOME/j2.out" && _pass "the non-zero jq status is what the installer reported" || _fail "jq rc reported" "$(head -5 "$HOME/j2.out")"

summary
