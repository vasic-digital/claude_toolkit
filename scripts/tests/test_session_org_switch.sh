#!/usr/bin/env bash
# test_session_org_switch.sh - alias switch across Anthropic organizations.
# Thinking-block signatures are org-bound; claude-unify shares projects/ so a
# session is resumed under another org and Claude Code re-reads it uncached.
# Unavoidable for the unmodified session; the toolkit warns before launch,
# names a same-org alias, and (opt-in) resumes a sanitized COPY.
# Covers: unit, integration, e2e, security, stress, chaos, performance,
# and mutation (script copies with one defect each MUST fail the probes).
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
set +e
SES="$SCRIPTS_DIR/claude-session.sh"
ORG_A=aaaaaaaa-1111-4111-8111-111111111111
ORG_B=bbbbbbbb-2222-4222-8222-222222222222
SID=11111111-2222-4333-8444-555555555555
mkdir -p "$HOME/.claude-shared/projects" "$HOME/proj"
for a in 1 2 3; do
  d="$HOME/.claude-claude$a"; mkdir -p "$d"
  o=$ORG_A; [ "$a" = 2 ] && o=$ORG_B
  printf '{"oauthAccount":{"organizationUuid":"%s"}}' "$o" > "$d/.claude.json"
  ln -s "$HOME/.claude-shared/projects" "$d/projects"
done
cd "$HOME/proj" || exit 1
SLUG="$(printf '%s' "$HOME/proj" | sed -E 's/[^A-Za-z0-9]/-/g')"
PD="$HOME/.claude-shared/projects/$SLUG"; mkdir -p "$PD"
mk_session() { # <file> <n pairs>
  python3 - "$1" "$2" "$SID" <<'PY'
import json,sys
f,n,sid=sys.argv[1],int(sys.argv[2]),sys.argv[3]
p=None
with open(f,'w') as o:
  for i in range(n):
    u='u%d'%i
    o.write(json.dumps({"type":"user","uuid":u+'a',"parentUuid":p,"sessionId":sid,"message":{"role":"user","content":"q%d"%i}},separators=(',',':'))+'\n')
    o.write(json.dumps({"type":"assistant","uuid":u+'t',"parentUuid":u+'a',"sessionId":sid,"message":{"role":"assistant","content":[{"type":"thinking","thinking":"x","signature":"SIG"}]}},separators=(',',':'))+'\n')
    o.write(json.dumps({"type":"assistant","uuid":u+'b',"parentUuid":u+'t',"sessionId":sid,"message":{"role":"assistant","content":[{"type":"text","text":"a%d"%i}],"usage":{"input_tokens":10,"cache_read_input_tokens":4990}}},separators=(',',':'))+'\n')
    p=u+'b'
PY
}
mk_session "$PD/$SID.jsonl" 3
A1="$HOME/.claude-claude1"; A2="$HOME/.claude-claude2"; A3="$HOME/.claude-claude3"
FL="--resume $SID --name proj"

it "unit: org-id reads organizationUuid, empty when unknown"
assert_eq "$ORG_A" "$(bash "$SES" org-id "$A1")" "claude1 org"
assert_eq "$ORG_B" "$(bash "$SES" org-id "$A2")" "claude2 org"
assert_eq "" "$(bash "$SES" org-id "$HOME/nonexistent")" "unknown -> empty"

it "integration: first launch records, same org is silent"
err="$(bash "$SES" org-guard "$A1" "$FL" 2>&1 >/dev/null)"; assert_eq "" "$err" "no warning on first launch"
out="$(bash "$SES" org-guard "$A3" "$FL" 2>"$HOME/oe.err")"; assert_eq "$FL" "$out" "flags unchanged same-org"
assert_eq "" "$(cat "$HOME/oe.err")" "same-org alias silent"; rm -f "$HOME/oe.err"

it "integration: org change warns with size, same-org hint, opt-in hint; flags unchanged"
out="$(bash "$SES" org-guard "$A2" "$FL" 2>"$HOME/oe.err")"
assert_eq "$FL" "$out" "flags unchanged without opt-in"
assert_file_contains "$HOME/oe.err" "WARNING" "warns"
assert_file_contains "$HOME/oe.err" "5000 tokens" "reports context size"
assert_file_contains "$HOME/oe.err" "cannot be avoided" "honest about API limit"
assert_file_contains "$HOME/oe.err" "CMA_SESSION_SANITIZE_ON_ORG_CHANGE" "opt-in named"
assert_file_not_contains "$HOME/oe.err" "$ORG_A" "full org uuid never printed"
bash "$SES" org-guard "$A2" "$FL" 2>"$HOME/oe.err" >/dev/null; assert_eq "" "$(cat "$HOME/oe.err")" "recorded: no repeat warning"
bash "$SES" org-guard "$A1" "$FL" 2>"$HOME/oe.err" >/dev/null; assert_file_contains "$HOME/oe.err" "Same-org alias" "switching back names nothing wrong"
rm -f "$HOME/oe.err"
bash "$SES" org-guard "$A2" "$FL" >/dev/null 2>&1   # record B again
bash "$SES" org-guard "$A3" "$FL" 2>"$HOME/oe.err" >/dev/null
bash "$SES" org-guard "$A2" "$FL" >/dev/null 2>&1
hint="$(bash "$SES" org-guard "$A1" "$FL" 2>&1 >/dev/null)"
case "$hint" in *'Same-org alias (no penalty): claude'*) rc=0 ;; *) rc=1 ;; esac
assert_eq 0 "$rc" "same-org alias suggested"

it "unit: sanitize-fork drops thinking, keeps text, rewires parents, original untouched"
before="$(sha256sum "$PD/$SID.jsonl" | cut -d' ' -f1)"
nsid="$(bash "$SES" sanitize-fork "$A2" "$SID")"
assert_file "$PD/$nsid.jsonl" "fork exists"
assert_eq "$before" "$(sha256sum "$PD/$SID.jsonl" | cut -d' ' -f1)" "original byte-identical"
assert_eq 0 "$(grep -c '"thinking"' "$PD/$nsid.jsonl")" "no thinking blocks"
assert_eq 3 "$(grep -c '"type":"text"' "$PD/$nsid.jsonl")" "text kept"
assert_eq 0 "$(grep -c "$SID" "$PD/$nsid.jsonl")" "sessionId rewritten"
python3 - "$PD/$nsid.jsonl" <<'PY'; assert_eq 0 $? "parent chain intact (no dangling parentUuid)"
import json,sys
us=set();ps=[]
for l in open(sys.argv[1]):
    o=json.loads(l); us.add(o['uuid']); ps.append(o.get('parentUuid'))
sys.exit(0 if all(p is None or p in us for p in ps) else 1)
PY
python3 - "$PD/$nsid.jsonl" <<'PY'; assert_eq 0 $? "thinking-only lines dropped, children rewired to the dropped line's parent"
import json,sys
ls=[json.loads(l) for l in open(sys.argv[1])]
us={o['uuid']:o for o in ls}
ok=len(ls)==6                                   # 3 user + 3 text-assistant, 3 thinking-only gone
ok&=not any(u.endswith('t') for u in us)        # dropped uuids absent
ok&=not any(o.get('message',{}).get('content')==[] for o in ls)   # no empty-content line
for i in range(3):
    ok&=us['u%db'%i]['parentUuid']=='u%da'%i    # parent of dropped u?t
sys.exit(0 if ok else 1)
PY

it "e2e: opt-in switch resumes a sanitized copy; original kept"
bash "$SES" org-guard "$A1" "$FL" >/dev/null 2>&1
out="$(CMA_SESSION_SANITIZE_ON_ORG_CHANGE=1 bash "$SES" org-guard "$A2" "$FL" 2>/dev/null)"
nid="$(printf '%s' "$out" | sed -E 's/.*--resume ([0-9a-f-]{36}).*/\1/')"
[ "$nid" != "$SID" ] && assert_file "$PD/$nid.jsonl" "flags point at new fork"
assert_file "$PD/$SID.jsonl" "original still present"
assert_eq 0 "$(grep -c '"thinking"' "$PD/$nid.jsonl")" "fork has no thinking"

it "security: bad sid / traversal / odd org uuid are rejected"
out="$(bash "$SES" org-guard "$A2" "--resume ../../etc/passwd --name x" 2>/dev/null)"; assert_eq "--resume ../../etc/passwd --name x" "$out" "traversal sid passed through untouched"
assert_eq 2 "$(bash "$SES" sanitize-fork "$A2" '../x' >/dev/null 2>&1; echo $?)" "sanitize-fork rejects non-uuid"
mkdir -p "$HOME/.claude-bad"; printf '{"oauthAccount":{"organizationUuid":"a/../b;rm"}}' > "$HOME/.claude-bad/.claude.json"
assert_eq "" "$(bash "$SES" org-id "$HOME/.claude-bad")" "metachar org uuid ignored"
assert_eq "600" "$(stat -c %a "$(ls "$HOME/.claude-shared/session-orgs/"* | head -1)")" "record mode 0600"

it "chaos: corrupt JSON, truncated tail, no .claude.json, unwritable record dir, existing target"
cp "$PD/$SID.jsonl" "$PD/cc.jsonl"; printf 'not json\n{"type":"assistant","message":{"content":[{"type":"thin' >> "$PD/cc.jsonl"
CSID=99999999-2222-4333-8444-555555555555
bash -c "source <(sed -n '/^_cma_valid_sid/,/^main()/p' '$SES' | sed '\$d'); cma_project_root(){ echo \$PWD; }; cma_sanitize_fork '$PD/cc.jsonl' $CSID" >/dev/null 2>&1; assert_eq 0 $? "corrupt lines tolerated"
assert_file_contains "$PD/$CSID.jsonl" "not json" "garbage line preserved"
assert_eq "$FL" "$(bash "$SES" org-guard "$HOME/nohome" "$FL" 2>/dev/null)" "no .claude.json -> flags unchanged"
chmod 500 "$HOME/.claude-shared/session-orgs"
assert_eq "$FL" "$(bash "$SES" org-guard "$A1" "$FL" 2>/dev/null)" "unwritable record dir non-fatal"; chmod 700 "$HOME/.claude-shared/session-orgs"
assert_eq 3 "$(bash -c "source <(sed -n '/^_cma_valid_sid/,/^main()/p' '$SES' | sed '\$d'); cma_sanitize_fork '$PD/$SID.jsonl' $CSID >/dev/null 2>&1; echo \$?")" "existing fork never overwritten"

it "stress+performance: 30000-line session sanitize under budget; 200 guards"
mk_session "$PD/big.jsonl" 10000
BSID=88888888-2222-4333-8444-555555555555
t0=$(date +%s)
bash -c "source <(sed -n '/^_cma_valid_sid/,/^main()/p' '$SES' | sed '\$d'); cma_sanitize_fork '$PD/big.jsonl' $BSID" >/dev/null 2>&1; assert_eq 0 $? "big sanitize ok"
assert_eq 10000 "$(grep -c '"type":"text"' "$PD/$BSID.jsonl")" "all text kept"
dt=$(( $(date +%s) - t0 )); [ "$dt" -le 30 ]; assert_eq 0 $? "30k lines in ${dt}s (<=30s)"
for i in $(seq 1 200); do bash "$SES" org-guard "$A1" "$FL" >/dev/null 2>&1 || { fail=1; break; }; done
assert_eq "" "${fail:-}" "200 guards all rc 0"

it "mutation: each defect is detected by the probes"
probe() { # <script>
  local s="$1" r=0 o
  rm -rf "$HOME/.claude-shared/session-orgs"
  bash "$s" org-guard "$A1" "$FL" >/dev/null 2>&1
  o="$(bash "$s" org-guard "$A2" "$FL" 2>&1 >/dev/null)"; grep -q WARNING <<<"$o" || r=1
  o="$(bash "$s" org-guard "$A3" "$FL" 2>&1 >/dev/null)"; [ "$r" = 0 ] && bash "$s" org-guard "$A2" "$FL" >/dev/null 2>&1
  o="$(bash "$s" org-guard "$A3" "$FL" 2>&1 >/dev/null)"
  bash "$s" org-guard "$A1" "$FL" >/dev/null 2>&1; o="$(bash "$s" org-guard "$A3" "$FL" 2>&1 >/dev/null)"; grep -q WARNING <<<"$o" && r=1
  n="$(bash "$s" sanitize-fork "$A2" "$SID" 2>/dev/null)"; [ -n "$n" ] && grep -q '"thinking"' "$PD/$n.jsonl" && r=1
  [ -n "$n" ] && grep -q '"uuid":"u[0-9]t"' "$PD/$n.jsonl" && r=1
  [ -n "$n" ] && rm -f "$PD/$n.jsonl"
  return $r
}
probe "$SES"; assert_eq 0 $? "unmutated passes probes"
mut() { # <label> <sed>
  cp "$SES" "$HOME/mut.sh"; sed -i "$2" "$HOME/mut.sh"
  cmp -s "$SES" "$HOME/mut.sh" && { _fail "mutation $1 did not apply"; return; }
  probe "$HOME/mut.sh"; [ $? -ne 0 ]; assert_eq 0 $? "mutation $1 killed"
}
mut no-warn 's/printf .claude-session: WARNING/: printf "x" /'
mut compare-inverted 's/"\$prev" != "\$cur"/"$prev" == "$cur"/'
mut keep-thinking "s/'thinking','redacted_thinking'/'zzz'/"
mut keep-thinking-only-lines "s/if not k and o.get('uuid'):/if False:/"
mut no-record 's/mv -f "\$rec.tmp.\$\$" "\$rec"/true/'
summary
