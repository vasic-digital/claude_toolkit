#!/usr/bin/env bash
# test_docs_hub_engine_release.sh — presence/link lint for the hub-engine /
# §11.4.277 / §11.4.278 / §11.4.279 documentation set and its diagrams.
#   1. docs/User_Manual.md exists, is linked from README.md, and every
#      relative link in the manual + README resolves to a real file.
#   2. README/guides/FAQs carry the required topics (hub engine, resolver,
#      11.4.277 gate, 11.4.278 Vision QA, 11.4.279 decision models,
#      decide gateway HTTPS + bearer key).
#   3. The two new diagrams exist as .mmd + non-empty .svg and are indexed in
#      docs/diagrams/README.md.
#   4. Doc twins of the changed docs are non-empty.
#   5. package.json version matches the top CHANGELOG release heading.
# Reads committed sources only; control needles guard against a blind scan.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
set +e

has() { grep -qiF -- "$2" "$1" 2>/dev/null; }

MANUAL="$REPO_ROOT/docs/User_Manual.md"
it "docs/User_Manual.md exists and README links it"
assert_file "$MANUAL" "User_Manual.md exists"
assert_file_contains "$REPO_ROOT/README.md" "docs/User_Manual.md" "README links the manual"

it "manual indexes every guide/FAQ"
for t in Provider_Aliases_User_Guide.md Provider_FAQ.md Provider_Verification_Guide.md \
         jev/Jev_Quickstart.md jev/Jev_User_Guide.md jev/Jev_FAQ.md \
         llmctl/quickstart.md llmctl/user-guide.md llmctl/FAQ.md \
         diagrams/README.md; do
  assert_file_contains "$MANUAL" "$t" "manual links $t"
done

it "zero dead relative links in README + manual + changed guides"
dead=""; n=0
for src in README.md docs/User_Manual.md docs/Provider_Aliases_User_Guide.md docs/Provider_FAQ.md \
           docs/jev/Jev_User_Guide.md docs/jev/Jev_FAQ.md docs/jev/Jev_Quickstart.md \
           docs/llmctl/user-guide.md docs/llmctl/quickstart.md docs/llmctl/FAQ.md docs/diagrams/README.md; do
  f="$REPO_ROOT/$src"; [[ -f "$f" ]] || continue
  d="$(dirname "$f")"
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    n=$((n+1))
    [[ -e "$d/$t" ]] || dead="${dead}${src} -> ${t}"$'\n'
  done < <(grep -o '\]([^)]*)' "$f" | sed -e 's/^](//' -e 's/)$//' | grep -Ev '^(https?:|mailto:|#)' | sed 's/#.*$//' | grep -v '^$')
done
assert_eq "" "$dead" "no dead links"
if (( n > 40 )); then _pass "positive-quantity guard: $n links checked"; else _fail "positive-quantity guard" "only $n links"; fi

it "required topics present"
R="$REPO_ROOT/README.md"
for needle in "hub engine" "constitution/submodules/claude_toolkit" "11.4.277" "11.4.278" "11.4.279" "resolve_deps.sh"; do
  has "$R" "$needle" && _pass "README mentions: $needle" || _fail "README mentions: $needle" "missing"
done
for f in docs/Provider_Aliases_User_Guide.md docs/Provider_FAQ.md docs/jev/Jev_User_Guide.md docs/jev/Jev_FAQ.md docs/jev/Jev_Quickstart.md docs/llmctl/user-guide.md docs/llmctl/FAQ.md; do
  has "$REPO_ROOT/$f" "11.4.27" && _pass "$f cites the governing §11.4.27x anchors" || _fail "$f cites §11.4.27x" "missing"
done
for f in docs/jev/Jev_User_Guide.md docs/jev/Jev_FAQ.md; do
  has "$REPO_ROOT/$f" "bearer" && has "$REPO_ROOT/$f" "https" \
    && _pass "$f documents the decide gateway HTTPS + bearer key" || _fail "$f documents decide gateway HTTPS + bearer key" "missing"
done
has "$REPO_ROOT/docs/llmctl/user-guide.md" "LLMCTL_VALIDATE_STRICT" && _pass "llmctl guide names STRICT" || _fail "llmctl guide names STRICT" "missing"
# negative control: a fabricated needle must NOT be found (instrument can see absence)
has "$R" "ZZNEEDLEQQ9-not-a-real-topic" && _fail "negative control" "fabricated needle found" || _pass "negative control: fabricated needle absent"

it "new diagrams: .mmd + non-empty .svg + indexed"
for d in hub-engine-placement decide-gateway-flow; do
  assert_file "$REPO_ROOT/docs/diagrams/$d.mmd" "$d.mmd exists"
  assert_file "$REPO_ROOT/docs/diagrams/$d.svg" "$d.svg exists"
  [[ -s "$REPO_ROOT/docs/diagrams/$d.svg" ]] && head -c 400 "$REPO_ROOT/docs/diagrams/$d.svg" | grep -q '<svg' \
    && _pass "$d.svg is a non-empty SVG" || _fail "$d.svg is a non-empty SVG" "empty or not svg"
  assert_file_contains "$REPO_ROOT/docs/diagrams/README.md" "$d.svg" "diagram index lists $d"
done

it "doc twins of changed docs are non-empty"
for d in README CHANGELOG docs/Provider_Aliases_User_Guide docs/User_Manual docs/llmctl/user-guide docs/llmctl/quickstart docs/llmctl/FAQ; do
  for ext in html pdf docx; do
    [[ -s "$REPO_ROOT/$d.$ext" ]] && _pass "$d.$ext non-empty" || _fail "$d.$ext non-empty" "missing or empty"
  done
done

it "every #anchor link resolves to a real heading (GitHub slug rules)"
bad="$(python3 - "$REPO_ROOT" <<'PY'
import os,re,sys
root=sys.argv[1]
docs=["README.md","docs/User_Manual.md","docs/Provider_Aliases_User_Guide.md","docs/Provider_FAQ.md",
      "docs/jev/Jev_User_Guide.md","docs/jev/Jev_FAQ.md","docs/jev/Jev_Quickstart.md",
      "docs/llmctl/user-guide.md","docs/llmctl/quickstart.md","docs/llmctl/FAQ.md","docs/diagrams/README.md"]
def slugs(path):
    out=set(); fence=False
    for line in open(path,encoding="utf-8"):
        if line.startswith("```"): fence=not fence
        if fence: continue
        m=re.match(r"#{1,6}\s+(.*)",line)
        if m:
            t=re.sub(r"`|\*|\[|\]\([^)]*\)","",m.group(1)).strip().lower()
            t=re.sub(r"[^a-z0-9 _\-]","",t).replace(" ","-")
            out.add(t)
    return out
n=0; bad=[]
for d in docs:
    f=os.path.join(root,d)
    if not os.path.isfile(f): continue
    for t in re.findall(r"\]\(([^)]*#[^)]*)\)",open(f,encoding="utf-8").read()):
        if t.startswith(("http:","https:","mailto:")): continue
        path,_,frag=t.partition("#")
        tgt=f if not path else os.path.normpath(os.path.join(os.path.dirname(f),path))
        if not tgt.endswith(".md") or not os.path.isfile(tgt): continue
        n+=1
        if frag not in slugs(tgt): bad.append("%s -> %s#%s"%(d,path,frag))
print("\n".join(bad)); print("CHECKED=%d"%n,file=sys.stderr)
PY
)"
assert_eq "" "$bad" "no broken #anchor"
# positive control: the checker flags a deliberately broken anchor
printf '# Real Heading\n[x](#no-such-anchor)\n' > "$HOME/anchor.md"
ctl="$(python3 - "$HOME/anchor.md" <<'PY'
import re,sys
t=open(sys.argv[1]).read()
heads={re.sub(r"[^a-z0-9 _\-]","",m.lower()).replace(" ","-") for m in re.findall(r"^#+\s+(.*)$",t,re.M)}
print("flagged" if "no-such-anchor" not in heads else "missed")
PY
)"
assert_eq "flagged" "$ctl" "anchor checker control: broken anchor flagged"

it "every .mmd renders with mmdc (syntax parses) and the key labels are in the committed SVG"
# The sandbox HOME hides puppeteer's browser cache: point it at the account's real one.
REALHOME="$(getent passwd "$(id -u)" | cut -d: -f6)"
[[ -z "${PUPPETEER_CACHE_DIR:-}" && -d "$REALHOME/.cache/puppeteer" ]] && export PUPPETEER_CACHE_DIR="$REALHOME/.cache/puppeteer"
PP="$HOME/pptr.json"; echo '{"args":["--no-sandbox"]}' > "$PP"
render() { timeout 120 nice -n 19 mmdc -i "$1" -o "$2" -p "$PP" >/dev/null 2>&1 && [[ -s "$2" ]]; }
if ! command -v mmdc >/dev/null 2>&1; then
  _skip "mmdc not installed: diagram syntax not verified"
elif ! { printf 'flowchart LR\n  A-->B\n' > "$HOME/ok.mmd"; render "$HOME/ok.mmd" "$HOME/ok.svg"; }; then
  _skip "mmdc cannot render a trivial control diagram in this environment (no browser): diagram syntax not verified"
else
  for m in "$REPO_ROOT"/docs/diagrams/*.mmd; do
    b="$(basename "$m" .mmd)"
    if render "$m" "$HOME/$b.svg"; then _pass "$b.mmd renders"; else _fail "$b.mmd renders" "mmdc failed (syntax error?)"; fi
  done
  grep -q "opt-in" "$REPO_ROOT/docs/diagrams/decide-gateway-flow.svg" && _pass "committed decide-gateway SVG carries the final labels" || _fail "decide-gateway SVG labels" "stale svg"
  grep -q "ccusage" "$REPO_ROOT/docs/diagrams/hub-engine-placement.svg" && _pass "committed hub-engine SVG carries the final labels" || _fail "hub-engine SVG labels" "stale svg"
  printf 'sequenceDiagram\n  Note over A: bad; semicolon\n' > "$HOME/bad.mmd"
  render "$HOME/bad.mmd" "$HOME/bad.svg" && _fail "render check control" "a broken diagram rendered" || _pass "render check control: a broken diagram is rejected"
fi

it "README facts: open routes, both third-party submodules, measured suite count"
has "$R" "/healthz" && has "$R" "/readyz" && _pass "README names /healthz and /readyz" || _fail "README names both open routes" "missing"
# Scoped to the "only submodules it carries" sentence specifically (not a
# document-wide substring search): the README mentions submodules/ccusage a
# second time elsewhere (the hub-engine section), so a bare `has "$R" ...`
# still passed when THIS sentence was mutated to drop one of the two names —
# the second, unrelated mention masked the defect (R95 coverage gap).
submod_ctx="$(grep -A1 -F 'only submodules it carries are the third-party' "$R" 2>/dev/null)"
if printf '%s' "$submod_ctx" | grep -qF 'submodules/go' && printf '%s' "$submod_ctx" | grep -qF 'submodules/ccusage'; then
  _pass "README names both third-party submodules in the same sentence"
else
  _fail "README names both submodules in the same sentence" "${submod_ctx:-sentence not found}"
fi
cnt="$(ls "$SCRIPTS_DIR"/tests/test_*.sh | wc -l | tr -d ' ')"
badge="$(grep -o 'badge/tests-[0-9]*%20suites' "$R" | grep -o '[0-9]*' | head -1)"
assert_eq "$cnt" "$badge" "README tests badge equals the measured suite count"

it "twins carry distinctive sentences of their markdown (not merely non-empty)"
for d in README CHANGELOG docs/Provider_Aliases_User_Guide docs/User_Manual docs/llmctl/user-guide docs/llmctl/quickstart docs/llmctl/FAQ; do
  res="$(python3 - "$REPO_ROOT/$d" <<'PY'
import re,sys,zipfile,subprocess,html
base=sys.argv[1]
md=open(base+".md",encoding="utf-8").read().splitlines()
cands=[l.strip() for l in md if re.fullmatch(r"[A-Za-z][A-Za-z0-9 ,.\-]{60,200}",l.strip())]
if not cands: print("NOCAND"); sys.exit(0)
step=max(1,len(cands)//5); marks=[cands[i][:55] for i in range(0,len(cands),step)][:5]
norm=lambda t: re.sub(r"\s+"," ",t)
h=norm(html.unescape(re.sub(r"<[^>]+>"," ",open(base+".html",encoding="utf-8",errors="ignore").read())))
dx=norm(html.unescape(re.sub(r"<[^>]+>"," ",zipfile.ZipFile(base+".docx").read("word/document.xml").decode("utf-8","ignore"))))
try: pdf=norm(subprocess.run(["pdftotext",base+".pdf","-"],capture_output=True,text=True,check=True).stdout)
except Exception: pdf=None
out=[]
for m in marks:
    mm=norm(m)
    if mm not in h: out.append("html:"+mm)
    if mm not in dx: out.append("docx:"+mm)
    if pdf is not None and mm not in pdf: out.append("pdf:"+mm)
print("OK" if not out else "MISSING "+" | ".join(out)); print("PDF" if pdf is not None else "NOPDF",file=sys.stderr)
PY
)"
  case "$res" in OK) _pass "$d twins contain 5 distinctive markdown sentences" ;; NOCAND) _skip "$d: no distinctive sentence candidates" ;; *) _fail "$d twins match the markdown" "$res" ;; esac
done

it "docs/research/README.md has no dangling link; specs/003 spec/plan/tasks are ported with a status header"
dang=""
while IFS= read -r l; do [[ -e "$REPO_ROOT/docs/research/$l" ]] || dang="${dang}${l}"$'\n'; done \
  < <(grep -o '](\([^)]*\))' "$REPO_ROOT/docs/research/README.md" | sed 's/^](//; s/)$//' | grep -v '^http' | grep -v '^#' | sed 's/#.*$//')
assert_eq "" "$dang" "no dangling link in docs/research/README.md"
has "$REPO_ROOT/docs/research/README.md" "specs/003-jev-decision-layer" && _pass "research README links the 003 spec" || _fail "research README links the 003 spec" "missing"
for f in spec plan tasks; do
  assert_file "$REPO_ROOT/specs/003-jev-decision-layer/$f.md" "specs/003 $f.md exists"
  has "$REPO_ROOT/specs/003-jev-decision-layer/$f.md" "STATUS (2026-10-22): historical spec" && _pass "$f.md carries the status header" || _fail "$f.md carries the status header" "missing"
done
has "$REPO_ROOT/specs/003-jev-decision-layer/spec.md" "toolkit-jev-design.md" && has "$REPO_ROOT/specs/003-jev-decision-layer/spec.md" "UNCONFIRMED" && _pass "header records the missing design file as UNCONFIRMED" || _fail "design-file note" "missing"

it "package.json version equals the top dated CHANGELOG release"
pv="$(grep -m1 '"version"' "$REPO_ROOT/package.json" | sed -E 's/.*"version": *"([^"]+)".*/\1/')"
cv="$(grep -m1 -E '^## v[0-9]' "$REPO_ROOT/CHANGELOG.md" | sed -E 's/^## v([0-9.]+).*/\1/')"
assert_eq "$cv" "$pv" "package.json version == top CHANGELOG release"
[[ -n "$cv" ]] && _pass "changelog release parsed ($cv)" || _fail "changelog release parsed" "empty"

summary
