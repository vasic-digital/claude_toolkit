#!/usr/bin/env bash
# test_carrier_inherited_heading.sh — every governance carrier (CLAUDE, AGENTS,
# GEMINI, QWEN .md) carries a standard, NON-FENCED, line-anchored
# '## INHERITED FROM ' pointer heading (§11.4.35), the predicate the constitution
# hub propagation gates (11.4.279/287/288/289) use to classify a pointer carrier.
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

# Prints 1 if FILE has a line-anchored '## INHERITED FROM ' heading outside any
# fenced block (``` or ~~~), else 0. Fence state is tracked per opening marker.
has_pointer() {
  awk '
    /^[ ]{0,3}(```|~~~)/ { m = substr($0, match($0,/(```|~~~)/), 3)
                           if (!f) { f = m } else if (m == f) { f = "" } ; next }
    !f && /^## INHERITED FROM / { found = 1 }
    END { print found ? 1 : 0 }' "$1"
}

for f in CLAUDE.md AGENTS.md GEMINI.md QWEN.md; do
  it "$f carries a non-fenced '## INHERITED FROM ' heading"
  assert_eq 1 "$(has_pointer "$REPO_ROOT/$f")" "$f pointer heading present outside fences"
done

# --- predicate self-validation (control needles / mutants) --------------------
M="$SANDBOX_HOME/mut"; mkdir -p "$M"
printf '# t\n\n## INHERITED FROM constitution/CLAUDE.md\n\nbody\n' > "$M/good.md"
printf '# t\n\n```\n## INHERITED FROM constitution/CLAUDE.md\n```\n' > "$M/fenced.md"
printf '# t\n\n~~~\n## INHERITED FROM constitution/CLAUDE.md\n~~~\n' > "$M/tilde.md"
printf '# t\n\n## Inherited from constitution/CLAUDE.md\n' > "$M/case.md"
printf '# t\n\n### INHERITED FROM constitution/CLAUDE.md\n' > "$M/demoted.md"
printf '# t\n\n ## INHERITED FROM constitution/CLAUDE.md\n' > "$M/indent.md"
printf '# t\n\nsee `## INHERITED FROM x` inline\n' > "$M/inline.md"
it "predicate accepts the golden-good carrier (positive control)"
assert_eq 1 "$(has_pointer "$M/good.md")" "golden-good detected"
for m in fenced tilde case demoted indent inline; do
  it "predicate rejects mutant: $m"
  assert_eq 0 "$(has_pointer "$M/$m.md")" "mutant $m not accepted"
done

summary
