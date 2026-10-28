#!/usr/bin/env bash
# test_carrier_inherited_heading.sh — every governance carrier (CLAUDE, AGENTS,
# GEMINI, QWEN .md) carries a standard, NON-FENCED, line-anchored
# '## INHERITED FROM <target>' pointer heading (§11.4.35), the predicate the constitution
# hub propagation gates (11.4.279/287/288/289) use to classify a pointer carrier.
#
# The predicate is STRICT (v1.33.2): a heading alone is not enough. It must
#   (1) be line-anchored and outside any fenced block (``` or ~~~),
#   (2) name the constitution carrier as its target (constitution/CLAUDE.md or
#       constitution/Constitution.md - a heading pointing anywhere else is not the pointer), and
#   (3) be followed by a non-empty body (at least one non-blank line before the next
#       heading or the end of the file), so a bare/empty heading cannot satisfy it.
#
# Real path: scans the real repo files. CARRIER_ROOT overrides the scanned root
# (used by the paired mutants below, which run the same predicate on mutated copies).
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
set +e

REPO_ROOT="${CARRIER_ROOT:-$(cd "$TESTS_DIR/../.." && pwd)}"

# Prints 1 if FILE has a valid pointer section (see above), else 0. Fence state is
# tracked per opening marker; the section ends at the next heading (any level).
has_pointer() {
  awk '
    /^[ ]{0,3}(```|~~~)/ { m = substr($0, match($0,/(```|~~~)/), 3)
                           if (!f) { f = m } else if (m == f) { f = "" }
                           if (insec) body = 1   # a fenced block inside the section is body text
                           next }
    f { if (insec && $0 ~ /[^[:space:]]/) body = 1; next }
    /^#+ / {
      if (insec && body) ok = 1
      insec = 0; body = 0
      if ($0 ~ /^## INHERITED FROM constitution\/(CLAUDE|Constitution)\.md[[:space:]]*$/) { insec = 1 }
      next
    }
    insec && /[^[:space:]]/ { body = 1 }
    END { if (insec && body) ok = 1; print ok ? 1 : 0 }' "$1"
}

for f in CLAUDE.md AGENTS.md GEMINI.md QWEN.md; do
  it "$f carries a valid '## INHERITED FROM constitution/...' pointer section"
  assert_eq 1 "$(has_pointer "$REPO_ROOT/$f")" "$f pointer heading present outside fences, correct target, non-empty body"
done

# --- predicate self-validation (golden-good control + mutants) -----------------
M="$SANDBOX_HOME/mut"; mkdir -p "$M"
printf '# t\n\n## INHERITED FROM constitution/CLAUDE.md\n\nbody text\n\n## Next\n\nx\n' > "$M/good.md"
printf '# t\n\n## INHERITED FROM constitution/Constitution.md\n\nbody\n' > "$M/good_constitution.md"
printf '# t\n\n## INHERITED FROM constitution/CLAUDE.md\nbody directly below\n' > "$M/good_nogap.md"
printf '# t\n\n```\n## INHERITED FROM constitution/CLAUDE.md\n\nbody\n```\n' > "$M/fenced.md"
printf '# t\n\n~~~\n## INHERITED FROM constitution/CLAUDE.md\n\nbody\n~~~\n' > "$M/tilde.md"
printf '# t\n\n## Inherited from constitution/CLAUDE.md\n\nbody\n' > "$M/case.md"
printf '# t\n\n### INHERITED FROM constitution/CLAUDE.md\n\nbody\n' > "$M/demoted.md"
printf '# t\n\n ## INHERITED FROM constitution/CLAUDE.md\n\nbody\n' > "$M/indent.md"
printf '# t\n\nsee `## INHERITED FROM constitution/CLAUDE.md` inline\n' > "$M/inline.md"
printf '# t\n\n## INHERITED FROM constitution/CLAUDE.md\n\n## Next\n\nx\n' > "$M/empty_before_heading.md"
printf '# t\n\n## INHERITED FROM constitution/CLAUDE.md\n\n\n   \n' > "$M/empty_at_eof.md"
printf '# t\n\n## INHERITED FROM\n\nbody\n' > "$M/no_target.md"
printf '# t\n\n## INHERITED FROM somewhere/else.md\n\nbody\n' > "$M/wrong_target.md"
printf '# t\n\n## INHERITED FROM constitution/CLAUDE.mdx\n\nbody\n' > "$M/target_suffix.md"
printf '# t\n\n## INHERITED FROM constitution/CLAUDE.md\n\n```\nfenced only\n```\n' > "$M/good_fenced_body.md"
it "predicate accepts the golden-good carriers (positive controls)"
for g in good good_constitution good_nogap good_fenced_body; do
  assert_eq 1 "$(has_pointer "$M/$g.md")" "golden-good $g detected"
done
for m in fenced tilde case demoted indent inline empty_before_heading empty_at_eof no_target wrong_target target_suffix; do
  it "predicate rejects mutant: $m"
  assert_eq 0 "$(has_pointer "$M/$m.md")" "mutant $m not accepted"
done

# --- the real files, mutated in place on a copy: each break must flip the verdict ----
R="$SANDBOX_HOME/real"; mkdir -p "$R"
it "mutating the REAL CLAUDE.md is detected (target, body, heading)"
sed 's|^## INHERITED FROM constitution/CLAUDE.md|## INHERITED FROM constitution/OTHER.md|' "$REPO_ROOT/CLAUDE.md" > "$R/target.md"
assert_eq 0 "$(has_pointer "$R/target.md")" "real file with wrong target rejected"
awk '/^## INHERITED FROM /{print; getline; while ((getline line) > 0) { if (line ~ /^#/) { print line; break } } next} {print}' "$REPO_ROOT/CLAUDE.md" > "$R/nobody.md"
assert_eq 0 "$(has_pointer "$R/nobody.md")" "real file with the body removed rejected"
sed 's|^## INHERITED FROM|INHERITED FROM|' "$REPO_ROOT/CLAUDE.md" > "$R/noheading.md"
assert_eq 0 "$(has_pointer "$R/noheading.md")" "real file with the heading marker removed rejected"
assert_eq 1 "$(has_pointer "$REPO_ROOT/CLAUDE.md")" "unmutated real CLAUDE.md still accepted (control)"

summary
