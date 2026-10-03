# CodeGraph §11.4.275 reachability/completeness audit (2026-10-03)

**Scope**: constitution §11.4.275 (Semantic/structural code-index universal
accessibility + completeness-before-ready + measured efficiency), audited
against the two repos active in this session — `claude_toolkit` (this repo)
and the separate `../llmctl` project — following the constitution submodule's
fast-forward to `e44f22f`, which introduced this anchor.

## Method

Two **fresh, non-fork** subagents (no inherited context from this session,
so their answers could only come from actually using the tool) were each
given an unforgeable challenge: use *only* CodeGraph (never Grep/Read/Glob)
to find every real call site of a specific function already independently
verified via `grep` by the orchestrating session —
`_cma_llmctl_ensure_active` (claude_toolkit) and `sched_reserved_field`
(llmctl). Both functions are real, present, and called multiple times in
each repo (ground truth captured via `grep` before dispatch).

## Findings

**1. `codegraph_explore` (the MCP tool) is universally unreachable — not a
main-session-only asymmetry.** Both subagents' `ToolSearch` calls for
`codegraph_explore` returned zero matches. The orchestrating session
independently confirmed the same: `ToolSearch({query:"select:codegraph_explore"})`
also returned nothing for the main session. This is NOT the clause-(A)
violation pattern the anchor specifically warns about ("a per-user toggle
only the main session sees") — it is a uniform absence, affecting every
caller equally. The project's own CLAUDE.md already anticipates exactly this
case and documents the sanctioned fallback: the shell CLI (`codegraph explore
...`), which **is** reachable and was successfully invoked by both
subagents, returning genuine (if ultimately unhelpful — see finding 2) tool
output. Clause (A)'s substantive reachability requirement (a real tool call
from a dispatched subagent returning an index-only fact) is satisfied via
this path; it just isn't the MCP tool specifically.

**2. CodeGraph has no bash/shell parser support — confirmed, not guessed.**
`codegraph status` in claude_toolkit lists "Files by Language": go, python,
typescript, javascript, yaml, c, rust, tsx, dart, kotlin, liquid, cpp, java,
objc, xml, properties — no bash/shell entry at all, despite claude_toolkit's
own primary content being bash scripts. `codegraph callers`/`query` for both
target functions returned "not found"/"No results found"; `codegraph
explore` degraded to irrelevant fuzzy token matches (Go runtime internals,
unrelated JS/TS classes) rather than real call-site data — and both
subagents correctly flagged this degraded output as noise rather than
reporting it as a real answer.

This matches an **already-disclosed limitation in the constitution's own
text**: §11.4.275's forensic record (clause 7 of the anchor's own research
basis) documents that the sibling Lumen tool's chunker
(`internal/chunker/languages.go`'s `supportedExtensions`) has no `.sh`
entry either, confirmed via a direct database query during that anchor's
own research. CodeGraph apparently shares the same class of gap. This is a
third-party tool parser limitation, not something fixable inside either
`claude_toolkit` or `llmctl`'s own source.

**3. `llmctl`'s index was stale** (built 2026-09-14/15, predating weeks of
real `lib/scheduler.sh` work, including this session's own five commits to
that exact file). This compounded finding 2 for the `sched_reserved_field`
query specifically. **Fixed**: both repos' indexes were re-synced
(`codegraph sync`) during this audit — llmctl: 285 files changed (261
added, 22 modified, 2 removed), claude_toolkit: 93 files changed (31 added,
62 modified). Neither `.codegraph/codegraph.db` is tracked in git
(`.codegraph/.gitignore` excludes it in both repos), so no commit was
needed for the refresh itself.

## Disposition (per §11.4.197 + §11.4.275 clause E)

- **Reachability (clause A)**: substantively satisfied via the shell-CLI
  fallback path in both repos. No further action.
- **Completeness/freshness (clause C)**: the staleness component is fixed
  (both indexes re-synced). The bash-parser-coverage component is a
  genuine, confirmed, **tracked gap** — not hidden, not silently routed
  around. Per clause (E), bash-related code-discovery queries in both
  repos correctly fall back to grep+read, which is exactly what both
  challenge subagents did when instructed to use CodeGraph only (they
  reported the tool's genuine inability rather than fabricating an answer
  or silently falling back without saying so).
- **Not pursued**: patching CodeGraph's own parser to add bash/.sh support
  is outside the scope of either consuming repo — it is the indexing
  tool's own upstream development work, analogous to how LLMCTL-F1
  through F8 (`docs/research/2026-10-02-llmctl-upstream-findings.md`)
  distinguish consumer-side workarounds from upstream-owned fixes.

## Evidence

- Ground-truth call sites (via `grep`, captured before each challenge):
  - `claude_toolkit`: `scripts/lib.sh:1886,4113,4416`.
  - `llmctl`: `lib/scheduler.sh:140` (post-VRAM-fix; earlier in this same
    session, before that fix, call sites also existed at the
    since-refactored lines ~480-481/641-642).
- Both subagents' full verbatim tool-invocation transcripts (ToolSearch
  results, `codegraph callers`/`query`/`explore`/`status` raw output) are
  preserved in this session's task-notification history.
