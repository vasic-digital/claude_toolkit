#!/usr/bin/env bash
# test_llmctl_doc_links.sh — T037 (FR-016, SC-005): the llmctl doc set
# (README.md -> docs/llmctl/{quickstart,user-guide,FAQ}.md -> diagrams) has
# ZERO dead links and ZERO orphaned pages. A reader starting at the repo
# README must be able to reach every one of these pages by following links,
# and every link they click must resolve to a real file on disk.
#
# This is a lint over committed doc sources, not a behavioural test of the
# toolkit -- mirrors test_sandbox_hygiene.sh's shape (make_sandbox called for
# suite-wide consistency even though the scan itself reads real repo files,
# never sandboxed copies).
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

# extract_links FILE -> one "target" per line, markdown [text](target) links,
# http(s)/mailto targets excluded (external, not this test's concern), any
# #anchor suffix stripped (anchors are checked against links, not files).
extract_links() {
  local f="$1"
  grep -o '\]([^)]*)' "$f" 2>/dev/null \
    | sed -e 's/^](//' -e 's/)$//' \
    | grep -Ev '^(https?:|mailto:)' \
    | sed 's/#.*$//'
}

# resolve TARGET SOURCE_FILE -> absolute, CANONICAL path TARGET resolves to,
# relative to SOURCE_FILE's own directory (how every renderer -- GitHub, a
# browser, pandoc -- resolves a relative markdown link). Canonicalizing
# (rather than leaving a literal `..` in the string) is load-bearing: two
# different relative links to the SAME real file (e.g. README's
# "docs/diagrams/x.svg" vs. user-guide.md's "../diagrams/x.svg") must compare
# equal, or the "is this file linked anywhere" check below gets a false
# negative purely from string form, not from the file actually being unlinked.
resolve() {
  local target="$1" source_file="$2" dir raw_dir base
  dir="$(cd "$(dirname "$source_file")" && pwd)"
  case "$target" in
    /*) raw_dir="$(dirname "$REPO_ROOT$target")"; base="$(basename "$target")" ;;
    *)  raw_dir="$(dirname "$dir/$target")";      base="$(basename "$target")" ;;
  esac
  if cd "$raw_dir" 2>/dev/null; then
    printf '%s/%s\n' "$(pwd)" "$base"
  else
    printf '%s/%s\n' "$raw_dir" "$base"
  fi
}

# --- 1. collect every doc in the llmctl set + its declared links ----------
DOC_SET=(
  "$REPO_ROOT/README.md"
  "$REPO_ROOT/docs/llmctl/quickstart.md"
  "$REPO_ROOT/docs/llmctl/user-guide.md"
  "$REPO_ROOT/docs/llmctl/FAQ.md"
)

it "every markdown link target inside the llmctl doc set resolves to a real file"
dead_links=""
link_count=0
for src in "${DOC_SET[@]}"; do
  [[ -f "$src" ]] || continue
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    link_count=$(( link_count + 1 ))
    resolved="$(resolve "$target" "$src")"
    if [[ ! -e "$resolved" ]]; then
      dead_links="${dead_links}${src#$REPO_ROOT/} -> ${target} (resolved: ${resolved})"$'\n'
    fi
  done < <(extract_links "$src")
done
assert_eq "" "$dead_links" "zero dead links in the llmctl doc set"
# Positive-quantity guard (test_sandbox_hygiene.sh scanner (d) rationale): an
# empty dead_links string must mean "N links checked, all good", never
# "extract_links silently found nothing" -- assert a real link count too.
if (( link_count > 5 )); then _pass "a real, non-trivial number of links were actually checked ($link_count)"
else _fail "a real, non-trivial number of links were actually checked" "got only $link_count"; fi

# --- 2. zero orphaned pages: every page in the set is reachable from README,
# following only links BETWEEN files in this doc set (external targets and
# files outside the set, like the upstream-findings research doc, don't
# gate reachability of the set itself). ------------------------------------
it "every llmctl doc-set page is reachable from README.md by following links"
README="$REPO_ROOT/README.md"
# BFS over DOC_SET using plain arrays (bash 3.2 has no associative arrays --
# this toolkit targets macOS's stock bash as a real platform).
visited=("$README")
queue=("$README")
while (( ${#queue[@]} > 0 )); do
  cur="${queue[0]}"
  queue=("${queue[@]:1}")
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    resolved="$(resolve "$target" "$cur")"
    [[ -f "$resolved" ]] || continue
    # only traverse into / record members of DOC_SET
    in_set=0
    for member in "${DOC_SET[@]}"; do [[ "$resolved" == "$member" ]] && in_set=1 && break; done
    (( in_set )) || continue
    already=0
    for v in "${visited[@]}"; do [[ "$v" == "$resolved" ]] && already=1 && break; done
    if (( ! already )); then
      visited+=("$resolved")
      queue+=("$resolved")
    fi
  done < <(extract_links "$cur")
done

orphans=""
for member in "${DOC_SET[@]}"; do
  found=0
  for v in "${visited[@]}"; do [[ "$v" == "$member" ]] && found=1 && break; done
  (( found )) || orphans="${orphans}${member#$REPO_ROOT/}"$'\n'
done
assert_eq "" "$orphans" "zero orphaned pages -- every doc-set page reachable from README.md"
assert_eq "${#DOC_SET[@]}" "${#visited[@]}" "reachable-page count matches the full doc set"

# --- 3. the diagram pair is reachable too (declared by FR-015/T034, linked
# from user-guide.md and/or README.md directly). ----------------------------
it "both llmctl diagram SVGs are linked from somewhere in the doc set and exist on disk"
for diagram in llmctl-detection-flow.svg llmctl-switch-flow.svg; do
  diagram_path="$REPO_ROOT/docs/diagrams/$diagram"
  assert_file "$diagram_path" "$diagram exists on disk"
  linked=0
  for src in "${DOC_SET[@]}"; do
    while IFS= read -r target; do
      [[ "$(resolve "$target" "$src")" == "$diagram_path" ]] && linked=1
    done < <(extract_links "$src")
  done
  assert_eq "1" "$linked" "$diagram is linked from somewhere in the doc set"
done

summary
