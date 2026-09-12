# Defect — `failing_layer` attribution (WS-C, found by the full-suite sweep)

**Feature**: spec 006, WS-C (new defect, not in the original 5-issue list)
**Date**: 2026-09-12
**Status**: root cause established from the AUTHORITATIVE contract; **fix designed, not
yet applied** (multi-site change, deliberately not rushed)

## Symptom

`scripts/tests/test_failing_layer_attribution.sh` fails **5** assertions on
unchanged code. Exact want/got captured:

| Case | want | got |
|---|---|---|
| L3 `cmd_sync` persists the real layer | `tool_call` | `tool_calling` |
| L6b `cmd_sync` records existence where THAT is the truth | `existence` | `chat_http` |
| L4 `cmd_verify` records tool_call, NOT existence | `tool_call` | `existence` |
| L4 `cmd_verify` records unknown when nothing determined a layer | `unknown` | `existence` |
| L8 an unverified verdict also carries its real layer | `tool_call` | `existence` |

## The authoritative contract (this settles "who is right")

`scripts/providers-verify.sh` **already publishes the layer as a first-class
token**, not as prose, via a file the caller names (`providers-verify.sh:70-84`):

```
# The token travels as a token in a file the CALLER names via CMA_VERIFY_LAYER_FILE.
# The token vocabulary is closed:
#   existence | tool_call | context | attribution | llmsverifier | preconditions | ""
# "" = nothing failed (a verified verdict)
```

`emit()` (`:509` etc.) writes that token: `emit failed "…" tool_call`.

So **`tool_call` is the correct literal and `tool_calling` is off-vocabulary** —
the test is right and the mapping is wrong.

## Two defects

### D1 — `cmd_verify` never consults the layer at all (the dominant one)

`claude-providers.sh:2976-2977`:

```bash
if [[ "$vst" == "failed" ]];     then … cma_status_write "$id" failed     "$model" existence; …
if [[ "$vst" != "verified" ]];   then … cma_status_write "$id" unverified "$model" existence; …
```

It writes the **literal `existence`** for every non-verified verdict and never
sets `CMA_VERIFY_LAYER_FILE`, so the verifier's own token is discarded. This is
the same defect the doc-comment on `cma_verify_failing_layer` describes as "the
two sites that then wrote the LITERAL existence" — **only one of those two sites
(`cmd_sync`, `claude-providers.sh:2628`) was ever wired.** `cmd_verify` was not.
That single fact explains L4 and L8 (`got=existence`).

### D2 — the prose-re-deriving helper is off-vocabulary and unnecessary

`lib.sh:3205 cma_verify_failing_layer` re-derives a layer by pattern-matching
the verifier's **stderr reason** and emits `tool_calling` (and `chat_http`),
neither of which is in the closed vocabulary. Two problems:

- the vocabulary mismatch (L3: `tool_calling` vs `tool_call`);
- L6b: the `verify-existence` stub declares layer `existence` with reason
  "chat probe HTTP 404 (model missing)", which the mapping re-files as
  `chat_http` — i.e. **re-derivation disagrees with the verifier's own
  declaration**, which is precisely the risk the "closed vocabulary" exists to
  remove.

The helper is now **obsolete**: the verifier states the layer directly.

## Fix design (in order)

1. Set `CMA_VERIFY_LAYER_FILE` to a temp file at every call site that runs
   `providers-verify.sh` (`cmd_sync` ~:2628, `cmd_verify` ~:2976, and any other),
   then read the token from it.
2. Use the token as `failing_layer`; when the file is absent/empty use
   **`unknown`** — never `existence` (absence means "not measured", §11.4.6).
3. Delete `cma_verify_failing_layer` and its call, rather than leaving two
   mechanisms that can disagree (the §11.4.124 investigate-before-remove step is
   satisfied: it is unreferenced once step 1 lands, and its rationale is
   superseded by the file protocol).
4. Keep the vocabulary closed: assert membership and map anything else to
   `unknown`.

## RED / evidence

The suite is already the RED: **5 failed** on unchanged code, with the want/got
above. Fix acceptance = `test_failing_layer_attribution.sh` reaches **0 failed**
plus a paired §1.1 mutation (write the literal `existence` again → the L4/L8
cases must fail).

## Honest boundary (§11.4.6)

- Root cause is established by reading `providers-verify.sh`'s own contract, and
  the failures are MEASURED (want/got captured). This is stronger than the
  code-analysis-only records for Issues 2–4.
- The fix is **not applied**: it touches several call sites and a shared helper,
  and it must be done as one reviewed change with the suite as the oracle.
