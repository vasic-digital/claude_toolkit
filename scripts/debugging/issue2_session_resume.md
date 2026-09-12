# Issue 2 — session resume "No conversation found" (WS-C forensics record)

**Feature**: spec 006, WS-C Issue 2
**Date**: 2026-09-12
**Status**: investigated; **no fix authored** — the failure mode is ALREADY GUARDED by design

## Reported symptom

Resume failure for session `ebee2470-ab31-43e9-a4ad-ad876b7dfb2e` — described in
the originating report as a session-ID-not-found / resume error.

## Real surface (measured)

- `scripts/claude-session.sh` — `cma_existing_session_id()` (:171) and
  `cma_latest_session_id()` (:153), plus `main()` dispatch `existing-id`
  (:189) / `latest-id` (:194).
- `scripts/lib.sh` — `_cma_session_flags` (referenced :1579) and the resume
  injection it feeds.
- `scripts/claude-sync-state.sh` — state sync.

## What the code ALREADY does (this is the important part)

`claude-session.sh:166-173` documents the exact failure named in the report:

> injecting `--resume` with the deterministic-but-never-created fallback UUID
> makes Claude Code fail hard ("No conversation found with session ID").

`cma_existing_session_id()` therefore returns the most-recent RESUMABLE UUID
**only when one exists, and empty otherwise**, so the wrapper starts a fresh
session instead of forcing a doomed `--resume`. `_cma_pick_session` additionally
skips "dead" session files below `CMA_SESSION_DEAD_BYTES` (default 65536).

**So the hard-failure path the report describes is guarded.** What remains is a
DIFFERENT, quieter behaviour: when no resumable session is found, the wrapper
starts fresh. A user who expected session `ebee2470-…` back experiences that as
"my session was not resumed", even though Claude Code never errored.

## Candidate causes for the specific ID (NOT confirmed)

Each is a hypothesis, listed so the next run can discriminate — none is asserted:

1. **Project-slug mismatch.** `cma_existing_session_id` builds the lookup path
   from the project ROOT (`sed -E 's/[^A-Za-z0-9]/-/g'`). Resume the same
   conversation from a different working directory (or after a move/rename) and
   the session directory differs, so the ID is not found → fresh session.
2. **Dead-byte threshold.** A session file below `CMA_SESSION_DEAD_BYTES` is
   skipped as dead; a short-but-real session would then never resume.
3. **`CLAUDE_CONFIG_DIR` selection.** The lookup is scoped to the config dir of
   the ACTIVE alias; the session may live under a different account's config dir.
4. **File rotated/pruned.** The JSONL no longer exists under `projects/<slug>/`.

## What was MEASURED

Baseline of the session suites on UNCHANGED product code:

```
scripts/tests/test_session_flags.sh  → 18 passed, 0 failed
scripts/tests/test_session.sh        → 62 passed, 0 failed
scripts/tests/test_sessions.sh       → 30 passed, 0 failed
```

110 tests green. The guarded path is covered.

## Honest boundary (§11.4.6)

- The reported failure was **not reproduced**. No live `claude --resume
  ebee2470-…` run was performed, and no session state for that ID was inspected.
- No defect is proven here. The code already contains the guard for the hard
  failure; the reported experience may be correct-but-surprising behaviour
  (fresh session) rather than a bug.
- **No fix is authored**, because inventing one for a green, deliberately-guarded
  path would be a change without a reproduced defect (§11.4.102 Iron Law).

## Ordered next steps for Issue 2

1. Reproduce against the real state: `claude-session.sh existing-id` from the
   project root the user actually resumed in, and from a different root, to test
   hypothesis 1 first (cheapest, most likely).
2. Inspect whether `projects/<slug>/ebee2470-*.jsonl` exists and its size vs
   `CMA_SESSION_DEAD_BYTES` (hypothesis 2).
3. Compare `CLAUDE_CONFIG_DIR` at launch time vs where the session file lives
   (hypothesis 3).
4. Only once a cause reproduces: author the RED, fix, and paired mutation — the
   same cycle used for Issue 1.
