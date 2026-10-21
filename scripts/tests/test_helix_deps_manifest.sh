#!/usr/bin/env bash
# test_helix_deps_manifest.sh — offline validation of helix-deps.yaml
# (§11.4.31 Submodule-Dependency-Manifest). No network: the ssh_url values were
# checked with `git ls-remote` when the manifest was written; this test pins
# the SHAPE and the coverage.
#
# Asserts: schema_version 1; every dep has name/ssh_url/ref/why/layout; names
# unique; ssh_url is an own-org SSH url (vasic-digital or HelixDevelopment);
# layout is flat; transitive_handling carries recursive + conflict_resolution;
# every own-org name scripts/resolve_deps.sh resolves has a dep row.
# Negative control: a broken copy MUST be rejected by the same validator.
# CT_TEST_HELIX_DEPS=<file> points the validator at another file (mutation proof).
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
set +e

MANIFEST="${CT_TEST_HELIX_DEPS:-$REPO_ROOT/helix-deps.yaml}"

# validate <file> — prints one problem per line; exit 0 only when clean.
validate() {
  python3 - "$1" <<'PY'
import re, sys
try:
    import yaml
except ImportError:
    print("SKIP-NO-PYYAML"); sys.exit(3)
path = sys.argv[1]
try:
    doc = yaml.safe_load(open(path))
except Exception as e:
    print(f"unparseable: {e}"); sys.exit(1)
errs = []
if not isinstance(doc, dict):
    print("top level is not a mapping"); sys.exit(1)
if doc.get("schema_version") != 1:
    errs.append(f"schema_version must be 1, got {doc.get('schema_version')!r}")
deps = doc.get("deps")
if not isinstance(deps, list) or not deps:
    errs.append("deps must be a non-empty list"); deps = []
url_re = re.compile(r"^git@github\.com:(vasic-digital|HelixDevelopment)/[A-Za-z0-9._-]+\.git$")
seen = set()
for i, d in enumerate(deps):
    if not isinstance(d, dict):
        errs.append(f"deps[{i}] is not a mapping"); continue
    for k in ("name", "ssh_url", "ref", "why", "layout"):
        if not d.get(k):
            errs.append(f"deps[{i}] missing {k}")
    n = str(d.get("name", "")).lower()
    if n in seen: errs.append(f"duplicate dep name {d.get('name')}")
    seen.add(n)
    if d.get("ssh_url") and not url_re.match(str(d["ssh_url"])):
        errs.append(f"deps[{i}] ssh_url not an own-org SSH url: {d['ssh_url']}")
    if d.get("layout") and d["layout"] != "flat":
        errs.append(f"deps[{i}] layout must be flat (no nested own-org), got {d['layout']}")
th = doc.get("transitive_handling")
if not isinstance(th, dict) or "recursive" not in th or "conflict_resolution" not in th:
    errs.append("transitive_handling must carry recursive + conflict_resolution")
# coverage: own-org names the resolver knows -> manifest rows (by repo name)
need = {"constitution": "helixconstitution", "containers": "containers", "challenges": "challenges",
        "llms_verifier": "llmsverifier", "claude_code_router": "claude-code-router"}
for rname, dep in need.items():
    if dep not in seen:
        errs.append(f"resolver dep '{rname}' has no manifest row (expected name {dep})")
for e in errs: print(e)
sys.exit(1 if errs else 0)
PY
}

it "helix-deps.yaml exists at the repo root"
assert_file "$MANIFEST" "manifest present"

it "negative control: the validator rejects a broken manifest"
bad="$(mktemp "${TMPDIR:-/tmp}/cma-hd.XXXXXX")"
sed -e 's#git@github.com:vasic-digital/claude-code-router.git#https://github.com/vasic-digital/claude-code-router.git#' \
    -e '/^transitive_handling:/,$d' "$MANIFEST" > "$bad"
out="$(validate "$bad")"; rc=$?
if [[ $rc -eq 3 ]]; then echo "SKIP: python3 yaml module absent — manifest not validated"; _pass "skipped: no PyYAML"
else
  [[ $rc -ne 0 ]] && _pass "broken copy rejected (rc=$rc)" || _fail "validator accepted a broken manifest" "$bad"
  grep -q 'ssh_url not an own-org SSH url' <<<"$out" && _pass "flags the https url" || _fail "https url not flagged" "$out"
  grep -q 'transitive_handling' <<<"$out" && _pass "flags missing transitive_handling" || _fail "missing transitive_handling not flagged" "$out"
fi
rm -f "$bad"

it "the real manifest validates clean"
out="$(validate "$MANIFEST")"; rc=$?
if [[ $rc -eq 3 ]]; then echo "SKIP: python3 yaml module absent"; _pass "skipped: no PyYAML"
elif [[ $rc -eq 0 ]]; then _pass "helix-deps.yaml valid"
else _fail "helix-deps.yaml invalid" "$out"; fi

summary
