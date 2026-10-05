#!/usr/bin/env bash
# test_redact.sh — the evidence redactor in verify_providers_live.sh actually
# fires on the key shapes this repo talks to, and does NOT mangle the markers
# the suite's own gates are built on.
#
# Why this test exists. `_redact` is the last thing standing between a captured
# provider transcript and a credential committed into scripts/tests/proof/. It
# used to cover exactly two shapes — `sk-` and `Bearer <tok>` — against ~20
# provider key families, and run over the then-current proof/ corpus it altered
# ONE file, a fixture, while walking straight past live keys sitting in
# proof/10-debug-config.json and proof/ccr-go-live.txt. A redactor that reports
# clean on a corpus that carries real keys is worse than none, because it is
# trusted.
#
# The widening it got is only half the deliverable; the other half is this file.
# An untested redactor is a bluff in both directions:
#
#   * Under-firing is the leak it was written to stop. Every shape claimed in
#     the `_redact` comment gets a SYNTHETIC token here and must come out
#     redacted — and the mutation section below proves the assertions are
#     actually load-bearing by reverting one pattern and watching the matching
#     fixture line survive. Without that, a rule that silently stopped matching
#     would still show green.
#   * Over-firing is the subtler and more damaging failure. verify_providers_live.sh
#     greps `^# (PASS|FAIL:|SKIP)` and `# ROUTE-INTENDED:`/`# ROUTE-RESOLVED:`
#     out of the very files it redacts, and the proof sweep greps `# FAIL:`. A
#     pattern that ate a verdict or a route marker would not fail loudly — it
#     would quietly convert a gated failure into "no marker found", i.e. a pass.
#     That is a strictly worse defect than the leak, so the negative controls
#     here are not decoration.
#
# Every token below is INVENTED. Nothing in this file is or was a real
# credential; the shapes (prefix, character class, length) are what is being
# pinned, and shapes are not secrets.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"
set +e

make_sandbox

LEG="$TESTS_DIR/verify_providers_live.sh"

it "the leg is present and exposes an extractable _redact"
if [[ ! -f "$LEG" ]]; then
  _fail "verify_providers_live.sh missing" "$LEG"
  summary
fi
# Extract the real function rather than re-declaring one here. A copy would
# drift from the implementation and this whole file would grade itself.
# Sourcing the leg is not an option: it runs a live provider sweep.
redact_src="$(sed -n '/^_redact()/,/^}/p' "$LEG")"
if [[ -n "$redact_src" ]] && printf '%s' "$redact_src" | grep -q 'sed -E'; then
  _pass "extracted _redact from the leg ($(printf '%s\n' "$redact_src" | wc -l | tr -d ' ') lines)"
else
  _fail "_redact not extractable" "the leg no longer exposes a testable redactor — this test cannot protect it"
  summary
fi
eval "$redact_src"

# --- fixture -----------------------------------------------------------------
# One line per shape. The MARKER column is what we assert on: after redaction
# the line must still contain its marker (so we know which line we are looking
# at) but must NOT contain the synthetic token.
FIX="$HOME/redact-fixture.txt"

# Synthetic tokens, grouped by the shape they stand in for.
declare -a NAMES=() TOKENS=()
add() { NAMES+=("$1"); TOKENS+=("$2"); }

#   prefix + separator + token body
add "sk-dash"        "sk-FAKE0000000000000000000000000000"
add "sk-underscore"  "sk_FAKE0000000000000000000000000000"
add "csk-cerebras"   "csk-FAKE000000000000000000000000000000000000"
add "gsk-groq"       "gsk_FAKE0000000000000000000000000000000000"
add "cpk-chutes"     "cpk_FAKE00000000000000000000000000000000000000000000000"
add "hf-huggingface" "hf_FAKE000000000000000000000000000000"
add "fw-fireworks"   "fw_FAKE00000000000000000"
add "nk-nia"         "nk_FAKE00000000000000000000000000000"
add "up-upstage"     "up_FAKE000000000000000000000000000"
add "r8-replicate"   "r8_FAKE00000000000000000000000000000000"
add "vck-vercel"     "vck_FAKE000000000000000000000000000000000000000000000000"
add "ak-modal-id"    "ak-FAKE00000000000000000"
add "as-modal-secret" "as-FAKE000000000000000000"
add "nvapi-nvidia"   "nvapi-FAKE00000000000000000000000000000000000000000000000000000000"
add "zpka-publicai"  "zpka_FAKE00000000000000000000000000000000000"
add "tvly-tavily"    "tvly-FAKE000000000000000000000000000000000000000"
add "glpat-gitlab"   "glpat-FAKE00000000000000000000000000000000000000000000000"
add "github-pat"     "github_pat_FAKE00000000000000000000000000000000000000000000000000000000000000000000000000000"
add "venice-admin"   "VENICE_ADMIN_KEY_FAKE00000000000000000000000000000000"
add "inference-"     "inference-FAKE000000000000000000000000000000"
add "perm-junie"     "perm-FAKE00000000000000000000000000000000000000000000000000000000000000000000000000000000"
add "jwt"            "eyFAKE000000000000000000000000000000.eyFAKE000000000000000000000000000000.FAKE000000000000000000000"
#   unknown-family net (a lowercase prefix this repo has never seen)
add "unknown-family" "zzq_FAKE0000000000000000000000000000000000"

: > "$FIX"
for i in "${!NAMES[@]}"; do
  printf 'SHAPE %s value=%s\n' "${NAMES[$i]}" "${TOKENS[$i]}" >> "$FIX"
done

# Context-gated shapes: bare unprefixed keys that are only safe to redact when
# they appear as a VALUE. These stand in for the 32/39/40/41-char bare-alnum and
# UUID-shaped families, which are shape-indistinguishable from a git SHA or a
# session id and so are deliberately NOT matched on shape alone.
BARE="FAKE0000000000000000000000000000"
{
  printf 'CTX bearer Authorization: Bearer %s\n' "$BARE"
  printf 'CTX json    "apiKey": "%s"\n' "$BARE"
  printf 'CTX jsonvar "TAVILY_API_KEY": "%s"\n' "$BARE"
  printf 'CTX header  x-api-key: %s\n' "$BARE"
  printf 'CTX authz   Authorization: %s\n' "$BARE"
  printf 'CTX assign  SOME_PROVIDER_API_KEY=%s\n' "$BARE"
  printf 'CTX token   GITLAB_TOKEN=%s\n' "$BARE"
  printf 'CTX secret  CMA_FAKE_SECRET=%s\n' "$BARE"
  printf 'CTX apikeyv ApiKey_SomeProvider=%s\n' "$BARE"
} >> "$FIX"

# Negative controls: MUST survive redaction byte-for-byte. The first four are
# the suite's own gate inputs; the rest are ordinary evidence content whose
# shape is close enough to a credential to be worth pinning.
declare -a NEG=(
  '# PASS: live launch through openrouter answered with a tool call'
  '# FAIL: route-mismatch intended=helixagent resolved=openrouter'
  '# SKIP: no network'
  '# ROUTE-INTENDED: openrouter'
  '# ROUTE-RESOLVED: openrouter'
  'commit 9f3c1ab77e5d0428bbca61f9d3e70a5c8412de6b'
  'session_id":"6e5c5be1-bce9-4c3f-904a-48e545e34ab8"'
  'CLAUDE_CODE_MAX_OUTPUT_TOKENS=128000'
  'CLAUDE_CODE_AUTO_COMPACT_WINDOW=72000'
  'CMA_PROVIDER_KEYVAR=ApiKey_Kimi_Platform'
  'evidence: scripts/tests/proof/providers-inference-semantic.txt'
  'model=claude-sonnet-4-5-20250929 context=200000'
  '[PASS] HONEST_API_KEY: output_limit (128000) < context_limit (1048576)'
)
for n in "${NEG[@]}"; do printf 'NEG %s\n' "$n" >> "$FIX"; done

# PRESERVE controls: these are the class that a prior widening got WRONG. An
# earlier draft used `[^"]{8,}` for the quoted-JSON rule, which matches any 8+
# characters — so it fired on the literal marker `REDACTED` (exactly 8) and on
# `${PINECONE_API_KEY}` (19), rewrote five evidence files, and the firing was
# then misreported as six live-credential finds. There were none. A redaction
# firing is NOT evidence a secret was present; these lines pin that a redacted
# marker and a variable reference — both legitimate, load-bearing evidence —
# survive untouched. Every value class in _redact excludes `$ { } [ ] < > *`
# precisely so these are unmatchable; the bare-word markers are protected by an
# explicit park-and-restore.
declare -a PRES=(
  'json placeholder    "apiKey": "REDACTED"'
  'json placeholder2   "api_key": "[REDACTED]"'
  'json placeholder3   "TAVILY_API_KEY": "PLACEHOLDER"'
  'json varref         "APPWRITE_API_KEY": "${APPWRITE_API_KEY}"'
  'json varref-dotted  "APPWRITE_API_KEY": "${sk_module.name_x_y}"'
  'json varref2        "DOMINO_API_KEY": "${DOMINO_API_KEY}"'
  'shell varref        export SOME_API_KEY=${SOME_API_KEY}'
  'shell varref-plain  export SOME_TOKEN=$SOME_TOKEN'
  'bare marker         api_key = REDACTED'
  'bracket marker      password: [REDACTED]'
  'star marker         Authorization: ***REDACTED***'
  'angle marker        secret=<REDACTED>'
  'empty value         "NOTION_API_KEY": ""'
  'toolid              "tool_use_id":"call_0619ef8843ed4e4fbf7ac5da"'
  'toolid-anthropic    "id":"toolu_01A2b3C4d5E6f7G8h9I0jKlM"'
)
for p in "${PRES[@]}"; do printf 'PRES %s\n' "$p" >> "$FIX"; done

cp "$FIX" "$HOME/redact-fixture.orig.txt"

# --- direction 1: the patterns fire ------------------------------------------
_redact "$FIX"

it "_redact preserves the file in place (atomic temp+mv, no leftover .redacted)"
if [[ -f "$FIX" && ! -e "$FIX.redacted" ]]; then
  _pass "fixture rewritten in place, no .redacted residue"
else
  _fail "atomicity broken" "expected $FIX to exist and $FIX.redacted to be gone"
fi

it "_redact is a no-op on a missing file (the -f guard survives)"
_redact "$HOME/definitely-not-here.txt"; rc=$?
assert_eq 0 "$rc" "_redact on a nonexistent path must return 0 without touching anything"

it "_redact does not change the line count (nothing swallowed)"
assert_eq "$(wc -l < "$HOME/redact-fixture.orig.txt")" "$(wc -l < "$FIX")" \
  "redaction must rewrite values, never drop lines"

for i in "${!NAMES[@]}"; do
  name="${NAMES[$i]}"; tok="${TOKENS[$i]}"
  it "shape '$name' is redacted"
  line="$(grep "^SHAPE $name " "$FIX")"
  if [[ -z "$line" ]]; then
    _fail "fixture line vanished" "no 'SHAPE $name' line survived redaction"
  elif printf '%s' "$line" | grep -qF "$tok"; then
    _fail "shape '$name' NOT redacted" "the synthetic token survived intact: $line"
  elif printf '%s' "$line" | grep -q 'REDACTED'; then
    _pass "shape '$name' -> $line"
  else
    _fail "shape '$name' changed but carries no REDACTED marker" "$line"
  fi
done

it "every context-gated bare token is redacted (Bearer / headers / JSON / assignments)"
ctx_leaks=0
while IFS= read -r line; do
  if printf '%s' "$line" | grep -qF "$BARE"; then
    ctx_leaks=$((ctx_leaks + 1)); echo "  LEAKED: $line"
  fi
done < <(grep '^CTX ' "$FIX")
assert_eq 0 "$ctx_leaks" "no context-gated bare token may survive"

it "the bare token appears nowhere in the redacted fixture"
if grep -qF "$BARE" "$FIX"; then
  _fail "bare synthetic token survived somewhere" "$(grep -nF "$BARE" "$FIX" | head -3)"
else
  _pass "bare synthetic token fully removed"
fi

# --- the over-firing guard (the one that protects the gates) -----------------
it "NO negative control is altered by redaction"
neg_broken=0
for n in "${NEG[@]}"; do
  if ! grep -qxF "NEG $n" "$FIX"; then
    neg_broken=$((neg_broken + 1))
    echo "  MANGLED: $n"
    echo "       ->: $(grep -F "${n:0:24}" "$FIX" | head -1)"
  fi
done
assert_eq 0 "$neg_broken" "redaction must not touch verdict lines, route markers, SHAs, UUIDs or env names"

it "the gate-critical marker lines are byte-identical before and after"
pat='^NEG (# (PASS|FAIL:|SKIP)|# ROUTE-(INTENDED|RESOLVED):)'
before_markers="$(grep -E "$pat" "$HOME/redact-fixture.orig.txt")"
after_markers="$(grep -E "$pat" "$FIX")"
if [[ "$before_markers" == "$after_markers" && -n "$before_markers" ]]; then
  _pass "all $(printf '%s\n' "$after_markers" | wc -l | tr -d ' ') verdict/route marker lines survived unchanged"
else
  _fail "a gate marker was altered by redaction" \
    "this silently disables the proof sweep — diff: $(diff <(printf '%s' "$before_markers") <(printf '%s' "$after_markers") | head -5)"
fi

# --- the false-positive guard (placeholders and variable references) ---------
# This is the regression that a prior widening actually shipped: it redacted
# already-redacted markers and ${VAR} references, damaged evidence, and the
# firing was misread as a live-credential find. Each PRES line must survive
# byte-for-byte.
it "NO placeholder or variable reference is altered by redaction"
pres_broken=0
for p in "${PRES[@]}"; do
  if ! grep -qxF "PRES $p" "$FIX"; then
    pres_broken=$((pres_broken + 1))
    echo "  MANGLED: $p"
    echo "       ->: $(grep -F "PRES ${p%% *}" "$FIX" | head -1)"
  fi
done
assert_eq 0 "$pres_broken" "a redacted marker or \${VAR} reference is legitimate evidence and must never be rewritten"

it "specifically: an exactly-8-char literal marker 'REDACTED' is not re-redacted"
# 'REDACTED' is 8 chars — the exact length that made the buggy [^\"]{8,} rule
# fire. Pin it directly so a regression to a length-only value match is caught.
if grep -qxF 'PRES json placeholder    "apiKey": "REDACTED"' "$FIX"; then
  _pass "quoted 8-char REDACTED marker preserved"
else
  _fail "8-char marker was re-redacted" "$(grep -F '"apiKey"' "$FIX")"
fi

it "specifically: a \${VAR} reference in a quoted api-key field is preserved"
if grep -qxF 'PRES json varref         "APPWRITE_API_KEY": "${APPWRITE_API_KEY}"' "$FIX"; then
  _pass "\${VAR} reference in an api-key field preserved (env-var indirection signal intact)"
else
  _fail "\${VAR} reference was destroyed" "$(grep -F 'APPWRITE_API_KEY' "$FIX" | head -1)"
fi

# --- idempotence -------------------------------------------------------------
# _redact applied twice must equal _redact applied once. This property is what
# would have caught the placeholder/varref regression on its own: re-redacting a
# `REDACTED` marker into `***REDACTED***` (or a second time) is a fixed-point
# violation, and the proof corpus is regenerated every run, so any churn is a
# real cost. Tested on BOTH the synthetic fixture and every real corpus copy.
it "IDEMPOTENCE: _redact(_redact(x)) == _redact(x) on the synthetic fixture"
cp "$FIX" "$HOME/redact-fixture.twice.txt"
_redact "$HOME/redact-fixture.twice.txt"
if cmp -s "$FIX" "$HOME/redact-fixture.twice.txt"; then
  _pass "second redaction pass is a no-op on the fixture"
else
  _fail "redaction is not idempotent" \
    "a second pass changed the file — churn on every proof regen: $(diff "$FIX" "$HOME/redact-fixture.twice.txt" | head -4)"
fi

# Idempotence over the REAL corpus copies. Guarded by presence: the tracked
# proof/ dir must never be mutated, so operate strictly on copies made here in
# the sandbox. If the corpus is not reachable (CI without it), SKIP honestly.
it "IDEMPOTENCE: _redact is a fixed point after one pass over real corpus copies"
# D1: regenerated evidence now lives in the git-ignored proof/volatile/ folder.
CORPUS="$SCRIPTS_DIR/tests/proof/volatile"
if [[ -d "$CORPUS" ]] && compgen -G "$CORPUS/providers-*-semantic.txt" >/dev/null 2>&1; then
  work="$HOME/corpus-idem"; mkdir -p "$work"
  # Only the files _redact is applied to in production: *-semantic / *-superpowers.
  n=0; unstable=0; changed_once=0
  for src in "$CORPUS"/providers-*-semantic.txt "$CORPUS"/providers-*-superpowers.txt; do
    [[ -e "$src" ]] || continue
    n=$((n + 1))
    base="$(basename "$src")"
    cp "$src" "$work/$base"                       # copy — never touch the tracked file
    _redact "$work/$base"                          # pass 1
    cp "$work/$base" "$work/$base.p1"
    _redact "$work/$base"                          # pass 2
    cmp -s "$src" "$work/$base.p1" || changed_once=$((changed_once + 1))
    cmp -s "$work/$base.p1" "$work/$base" || { unstable=$((unstable + 1)); echo "  UNSTABLE: $base"; }
  done
  if (( n > 0 && unstable == 0 )); then
    _pass "all $n production-target corpus files are a fixed point ($changed_once changed on pass 1, 0 on pass 2)"
  elif (( n == 0 )); then
    _pass "SKIP: no production-target corpus files present"
  else
    _fail "redaction is not idempotent over the corpus" "$unstable of $n files changed on a second pass"
  fi
else
  _pass "SKIP: proof corpus not reachable from the sandbox — idempotence pinned on the synthetic fixture above"
fi

# --- direction 2: mutation test ----------------------------------------------
# An assertion that would pass even with the rule removed proves nothing. Revert
# a pattern, show the fixture lines it uniquely covers leak, then restore and
# show the restoration is byte-identical to what was extracted from the leg, so
# the test can never leave a mutant behind.
#
# `mutant_leaks` reverts ONE rule (matched by a literal substring) and echoes the
# names of the SHAPE fixtures that survive un-redacted as a result.
mutant_leaks() {
  local pattern="$1" src fix name
  src="$(printf '%s\n' "$redact_src" | grep -vF "$pattern")"
  eval "${src/_redact()/_redact_mutant()}"
  fix="$HOME/redact-fixture.mutant.txt"
  cp "$HOME/redact-fixture.orig.txt" "$fix"
  _redact_mutant "$fix"
  for i in "${!NAMES[@]}"; do
    name="${NAMES[$i]}"
    grep -F "${TOKENS[$i]}" "$fix" | grep -q "^SHAPE $name " && printf '%s\n' "$name"
  done
  # context-gated fixtures leak as a group; report the marker once
  grep -qF "$BARE" "$fix" && printf 'CTX-BARE\n'
  return 0
}

# --- mutation 1: the short-prefix family rule --------------------------------
# Expected survivors are NOT all eight shapes this rule lists, and that is the
# interesting part. hf_/nk_/up_/r8_/vck_ are ALSO caught by the generic
# lowercase-prefix net (lowercase prefix + >=24 contiguous alnum), so removing
# this rule leaves them covered — real defense in depth, discovered by this
# mutation rather than assumed. The three that leak are exactly the three no
# other rule reaches: fw_ (22-char tail, below the net's 24 floor) and ak-/as-
# (dash separator, where the net requires an underscore). Pinning the exact set
# rather than a count documents that topology, so a future edit that removes the
# overlap shows up here instead of silently narrowing coverage.
MUT_PATTERN="(hf|fw|nk|up|r8|vck|ak|as)"

it "the mutation target exists in the extracted redactor"
if printf '%s' "$redact_src" | grep -qF "$MUT_PATTERN"; then
  _pass "found the short-prefix rule to mutate"
else
  _fail "mutation target missing" "cannot mutation-test: '$MUT_PATTERN' is not in _redact"
fi

leaked="$(mutant_leaks "$MUT_PATTERN" | sort | tr '\n' ' ')"
leaked="${leaked% }"
it "MUTATION 1: reverting the short-prefix rule leaks exactly the shapes only it covers"
assert_eq "ak-modal-id as-modal-secret fw-fireworks" "$leaked" \
  "with the short-prefix rule removed these must leak (the other five are double-covered by the generic net)"

it "MUTATION 1: the revert is scoped — unrelated shapes stay redacted"
if [[ "$leaked" != *"sk-dash"* && "$leaked" != *"CTX-BARE"* && "$leaked" != *"jwt"* ]]; then
  _pass "sk-, JWT and the context-gated shapes are still redacted by the mutant"
else
  _fail "mutation was not scoped" "removing one rule also disabled unrelated ones: $leaked"
fi

# --- mutation 2: the quoted-JSON api-key rule --------------------------------
# This is the rule that caught the live credentials in proof/10-debug-config.json
# and proof/ccr-go-live.txt. It is the ONLY rule covering a bare, unprefixed key
# sitting in a quoted JSON field, so reverting it must leak the CTX group.
MUT_PATTERN2='[Aa][Pp][Ii][-_]?[Kk][Ee][Yy]"'

it "MUTATION 2: reverting the quoted-JSON api-key rule leaks the bare key it protects"
leaked2="$(mutant_leaks "$MUT_PATTERN2" | sort | tr '\n' ' ')"
if [[ "$leaked2" == *"CTX-BARE"* ]]; then
  _pass "the quoted-JSON rule is load-bearing — without it a bare key in \"apiKey\": \"…\" survives"
else
  _fail "mutation 2 did not change behaviour" \
    "removing the quoted-JSON api-key rule left nothing leaking ($leaked2) — the CTX assertions are not testing it"
fi

it "MUTATION 2: the revert is scoped — prefixed shapes stay redacted"
if [[ "$leaked2" != *"sk-dash"* && "$leaked2" != *"jwt"* ]]; then
  _pass "prefixed and JWT shapes unaffected by the quoted-JSON revert"
else
  _fail "mutation 2 was not scoped" "leaked: $leaked2"
fi

it "MUTATION: restoring the rule reproduces the redactor byte-identically"
restored="$(sed -n '/^_redact()/,/^}/p' "$LEG")"
if [[ "$restored" == "$redact_src" ]]; then
  _pass "re-extracted _redact is byte-identical to the original (no mutant left on disk)"
else
  _fail "the leg was modified by this test" "test_redact.sh must never write to $LEG"
fi

it "MUTATION: the restored redactor redacts the shapes the mutant leaked"
RFIX="$HOME/redact-fixture.restored.txt"
cp "$HOME/redact-fixture.orig.txt" "$RFIX"
eval "${restored/_redact()/_redact_restored()}"
_redact_restored "$RFIX"
restored_leaks=0
for probe in hf-huggingface fw-fireworks nk-nia up-upstage r8-replicate vck-vercel ak-modal-id as-modal-secret; do
  for i in "${!NAMES[@]}"; do
    [[ "${NAMES[$i]}" == "$probe" ]] || continue
    grep -F "${TOKENS[$i]}" "$RFIX" >/dev/null && restored_leaks=$((restored_leaks + 1))
  done
done
assert_eq 0 "$restored_leaks" "the restored rule must redact all 8 shapes the mutant leaked"

# --- portability -------------------------------------------------------------
# The toolkit targets macOS, where sed is BSD. These constructs are GNU-only and
# would either error or silently mean something else under BSD sed.
it "the redactor uses no GNU-only sed constructs (macOS ships BSD sed)"
gnuisms=""
printf '%s' "$redact_src" | grep -q '\\+' && gnuisms="$gnuisms \\+"
printf '%s' "$redact_src" | grep -q '\\[dwsWDS]' && gnuisms="$gnuisms \\d/\\w/\\s"
printf '%s' "$redact_src" | grep -q '\\b' && gnuisms="$gnuisms \\b"
printf '%s' "$redact_src" | grep -qE "/[gp]*I[gp]*'" && gnuisms="$gnuisms I-flag"
printf '%s' "$redact_src" | grep -q 'sed --' && gnuisms="$gnuisms long-opt"
if [[ -z "$gnuisms" ]]; then
  _pass "no GNU-only sed constructs found"
else
  _fail "GNU-only sed construct in _redact" "found:$gnuisms — this breaks on macOS"
fi

it "the redactor still routes through a temp file and mv (atomic publish)"
if printf '%s' "$redact_src" | grep -q '\.redacted' && printf '%s' "$redact_src" | grep -q 'mv "'; then
  _pass "temp-file + mv publish preserved"
else
  _fail "atomic publish lost" "_redact no longer writes a temp and mv's it into place"
fi

it "the redactor still guards on -f (no-op for a missing file)"
if printf '%s' "$redact_src" | grep -q '\[\[ -f "\$1" \]\] || return 0'; then
  _pass "-f guard preserved"
else
  _fail "-f guard lost" "_redact would now create or error on a missing evidence file"
fi

summary
