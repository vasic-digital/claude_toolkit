# Issue 3 — 32MB request limit + compaction (WS-C forensics record)

**Feature**: spec 006, WS-C Issue 3
**Date**: 2026-09-12
**Status**: Go half already implemented AND tested; no fix authored (no reproduced defect).

## Reported symptom

"request too large (max 32MB) error" on large conversations.

## Real surfaces (measured)

| Half | Surface | State |
|---|---|---|
| Go (router) | `submodules/claude-code-router/internal/gateway/messages.go` — `const maxRequestBodyBytes = 32 << 20` (:30), applied via `http.MaxBytesReader` (:210) | **implemented + tested** |
| Bash (wrapper) | `scripts/lib.sh` ~1140–1569 — `CLAUDE_CODE_MAX_CONTEXT_TOKENS`, `CMA_AUTO_COMPACT_CAP` | present, but it is **CONTEXT-WINDOW** compaction, not request-byte compaction |

Router module: `github.com/vasic-digital/claude-code-router`.

## What is already covered (measured, trunk router)

```
go test ./internal/gateway/ -run 'BodyLimit|Body' -v
→ TestOversizedRequestBodyIsRejectedNotOOM          PASS
→ TestNormalSizedRequestBodyStillAccepted           PASS
→ TestOpenAIFacadeLargeRequestForwardsBodyUnchanged PASS
ok  github.com/vasic-digital/claude-code-router/internal/gateway
```

So the limit is deliberately enforced: an oversized body is **rejected (not OOM)**, a
normal body is accepted, and a large-but-valid OpenAI-facade body is forwarded
**unchanged**. The 32MB ceiling is a protection, and its test name says why.

## The important conclusion

**Raising `maxRequestBodyBytes` is the WRONG fix.** The ceiling exists so a huge
inbound POST cannot exhaust memory. A request that exceeds it *should* be refused.

The user-visible problem is therefore upstream of the router: nothing compacts the
conversation **before** its serialized form crosses 32MB, so the user meets a 413.
The wrapper's existing compaction knobs govern the model's CONTEXT WINDOW
(`CLAUDE_CODE_MAX_CONTEXT_TOKENS`, `CMA_AUTO_COMPACT_CAP`, with detailed notes at
lib.sh:1351–1371 about endless-compaction loops), not the serialized request size —
the two are related but not the same quantity.

## Honest boundary (§11.4.6)

- The reported 413 was **not reproduced**: no >32MB request was driven through a
  live router. The three passing tests establish the router's *designed* behaviour,
  not that the user's specific conversation hit it for the assumed reason.
- The claim "nothing compacts before 32MB" is a **hypothesis from reading the
  config surface**, not a measurement of a live session's serialized body size.
- **No fix authored.** A fix here is a threshold/compaction-strategy change whose
  correctness depends on real conversation sizes, and §11.4.102 forbids changing it
  without a reproduced defect.

## Work-stream access blocker (recorded)

`submodules/claude-code-router` is **uninitialized in the feature work-stream**
(0 entries) while the trunk checkout has it (18 entries). Any router-side change
therefore requires initializing that nested submodule in the work-stream first —
a deliberate step, not something to do silently mid-task.

## Ordered next steps for Issue 3

1. Measure the real quantity: capture the SERIALIZED request size of a long live
   session (or the router's 413 log line) before proposing any threshold change.
2. Decide the strategy on evidence: (a) lower the effective context window so
   auto-compaction fires earlier, (b) add pre-send byte-size estimation to the
   wrapper, or (c) accept the 413 as correct and surface a clearer remediation
   message. **Do not raise the router ceiling** without addressing OOM.
3. If a code change is chosen, initialize the nested router submodule in the
   work-stream, then author the RED (a >32MB request that must be compacted/
   reported rather than killed) before the fix.
