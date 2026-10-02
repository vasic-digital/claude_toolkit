# llmctl upstream findings (tracked, not fixed here)

- Date: 2026-10-02
- Author: feature `001-llmctl-integration-hardening` (claude_toolkit), task T029
- Scope: five genuine defects/gaps found while exhaustively analyzing the
  separate `/home/milosvasic/Projects/llmctl` project during this feature's
  research phase. Per the feature's clarified scope (spec.md FR-010a), these
  are **documented and tracked only** — claude_toolkit does not own that
  repository and **zero code in `/home/milosvasic/Projects/llmctl` was
  touched** by this feature or by writing this document.
- Each finding's original citation (from `specs/001-llmctl-integration-hardening/research.md`
  §3 and §7) was re-verified fresh, by actually reading the cited file:line
  ranges in the real repository, immediately before this document was
  written (not assumed from the earlier audit). All five are confirmed
  **still accurate and still open** — none has been fixed upstream since the
  original audit.

## LLMCTL-F1 — no machine-readable status/running-state command

**Confidence**: confirmed by reading code (re-verified).

`bin/llmctl`'s `status` subcommand (dispatch line 189: `status) sched_status
;;`) maps to `sched_status()` (`lib/scheduler.sh:753-780`), which emits a
fixed-width **human text table** via `printf '%-16s ...'` — there is no
`--json` flag on `status` anywhere in `bin/llmctl`'s dispatch table, and
`llmctl plan --json` (the one JSON-emitting command) carries no `running`
field (confirmed separately in `research.md §3.A`). The only ground truth for
"what is actually running right now" is `sched_running()`
(`lib/scheduler.sh:75-90`), which enumerates `${LLMCTL_RUNTIME_DIR}/*.run`
marker files — a plain `key=value` text format exported as an env var
(`lib/common.sh:39` region — `LLMCTL_RUNTIME_DIR` export) but with zero
mentions in `docs/architecture.md`, i.e. not documented as a stable external
contract.

**Why it matters**: any external integration depending on either the human
table's column layout or the undocumented `.run` file format is exposed to
silent breakage on a future internal refactor, with no deprecation signal.
claude_toolkit itself is NOT exposed to this (it independently HTTP-probes
each profile's own `/v1/models` endpoint rather than parsing either of
these), but any OTHER integration against llmctl would be.

**Suggested remediation direction** (not prescribed — llmctl's own
maintainer decides): a `--json` flag on `status` emitting the same
information `sched_running()`/`sched_status()` already compute, and a
documented stability contract for `LLMCTL_RUNTIME_DIR`'s `.run` file shape
if it is meant to be consumed externally at all.

## LLMCTL-F2 — switch rollback is best-effort; no distinct machine-readable "rollback also failed" signal

**Confidence**: confirmed by reading code (re-verified).

`_sched_switch_impl` (`lib/scheduler.sh`, rollback branch now at
lines ~657-667, shifted slightly from the original audit's 661-665 citation
but identical in substance) snapshots the running set before stopping
anything and attempts to restore it if starting the target fails. If the
restore ALSO fails, it logs the literal string `ROLLBACK ALSO FAILED - the
host may have fewer services running than before this switch attempt. Check:
llmctl status` — but both the "rollback succeeded" and "rollback also
failed" branches fall through to the same `return "${start_rc}"`, so a
caller has no way to distinguish the two outcomes except by grepping
freeform stderr text.

**Why it matters**: a caller (claude_toolkit included, before this feature's
own T016/T020 fix) cannot reliably tell "switch failed but the previous
profile is still safely running" apart from "switch failed AND the previous
profile is now ALSO gone" without parsing prose. claude_toolkit's own
`_cma_llmctl_ensure_active` (`scripts/lib.sh`) now works around this by
independently re-probing `llmctl status` after any switch failure and by
detecting the `ROLLBACK ALSO FAILED` substring to surface a distinctly
higher-severity warning — but that is a workaround on the CONSUMER side, not
a fix to the missing signal upstream.

**Suggested remediation direction**: a distinct exit code (or a `--json`
error payload) for the "rollback also failed" case specifically, so a
caller never has to pattern-match prose to tell the two failure classes
apart.

## LLMCTL-F3 — colibri engine profiles crash-loop under the LAN-exposed bind default

**Confidence**: confirmed by reading code (re-verified).

`lib/common.sh:74`: `LLMCTL_BIND_HOST="${LLMCTL_BIND_HOST:-0.0.0.0}"` — LAN-exposed
by explicit, documented default (no built-in auth on `llama-server`'s
OpenAI-compatible API). Per `lib/scheduler.sh` (colibri-specific guard,
~lines 295-313, same region as the original citation): colibri engine
profiles (`colibri-glm`, `colibri-qwen36`) carry their OWN independent
fail-closed guard and refuse to bind non-loopback at all unless
`COLI_ALLOW_INSECURE_BIND=1` is explicitly set — and llmctl deliberately
does **not** auto-set that on the operator's behalf. Override is available
globally (`LLMCTL_BIND_HOST=127.0.0.1`) or per-profile
(`LLMCTL_BIND_HOST_<PROFILE>=127.0.0.1`).

**Why it matters**: under the project's own LAN-exposed default, a colibri
profile will crash-loop unless the operator has separately discovered and
set `COLI_ALLOW_INSECURE_BIND=1` — a non-obvious cross-component interaction
between llmctl's own default and the colibri engine's independent safety
guard. claude_toolkit's detection already handles the resulting crash-loop
gracefully (a crash-looping profile simply never answers its `/v1/models`
probe, so it's correctly reported as "not running" rather than a false
positive) — this finding is about operator-facing clarity upstream, not a
claude_toolkit defect.

**Suggested remediation direction**: a startup-time warning (or a doctor
check) when a colibri profile is about to be started under the LAN-exposed
default without `COLI_ALLOW_INSECURE_BIND=1` set, naming the exact
interaction before the crash-loop happens rather than after.

## LLMCTL-F4 — `vision` profile fails tool-calling outright (genuine model-capability limit); CPU-timeout fix for `small`/`moe-fast` never re-verified live

**Confidence**: confirmed by reading dated project history (re-verified);
the live re-verification itself remains open, not resolvable by reading code.

`docs/CONTINUATION.md` (llmctl's own, not claude_toolkit's) §10m
(dated 2026-09-17, now at line ~1048 in the current 1559-line file, shifted
from the original ~983-1065 citation range but the exact table row is
unchanged): `vision (Gemma-3-4b) | FAIL | not reached | model made no tool
call at all — genuine model-capability limitation, not infra`. A later
entry, §10p (line 1304, exact match to the original citation), records GPU
enablement resolving a SEPARATE CPU-speed root cause for `small`/`moe-fast`
with a measured 56.6× throughput improvement, but **explicitly discloses
or exhibits the same wording as the original audit**: "a real Claude Code +
Superpowers TUI session was NOT re-run this round (a ... honest limitation
disclosed)" (line 1309 region).

**Why it matters, directly for claude_toolkit**: this feature's own live
Superpowers-command test suite (US3, this feature's T025-T028) should
expect `llmctl-vision` to plausibly FAIL the tool-calling-dependent checks
for a genuine, pre-existing, non-infrastructure reason — that is a correct
FAIL to record with evidence, never a claude_toolkit integration defect to
chase. `llmctl-small`/`llmctl-moe-fast` deserve a FRESH live re-verification
rather than trusting the GPU fix's claimed resolution, since upstream itself
has not re-confirmed it against a real Superpowers-TUI session as of this
writing.

**Suggested remediation direction**: upstream re-running the real
Superpowers-TUI-shaped session against `small`/`moe-fast` post-GPU-fix, and
either documenting `vision`'s tool-calling incapability as a known model
limitation in its own catalog metadata, or trying a tool-calling-capable
alternative model for that profile slot.

## LLMCTL-F5 — llmctl's own memory/overcommit accounting only covers scheduler-launched processes

**Confidence**: confirmed by reading documented incident (re-verified).

`docs/CONTINUATION.md` lines ~1021-1028 (exact match to the original
1018-1029 citation): a manually-launched raw test process, run alongside two
llmctl-managed persistent services OUTSIDE llmctl's own scheduler, drove
swap to 100% and free RAM to ~278 MiB — "the exact overcommit class §10k
item 4's `enable`-budget-check fix exists to prevent for the
PERSISTENT-service path, but this was a manually-launched raw test process
outside `llmctl`'s own scheduler/reservation bookkeeping, so that check does
not (and structurally cannot) cover it."

**Why it matters, directly for claude_toolkit**: this feature's own test
design (research.md §3.E) already commits to launching/stopping every
llmctl-backed model strictly through llmctl's own commands in every test
(`start`/`switch`/`stop`, via claude_toolkit's existing wrappers), specifically
to stay inside llmctl's safety accounting — this finding is the evidence
that decision was correct, not merely cautious.

**Suggested remediation direction**: llmctl's own budget/overcommit
accounting could optionally sample host-wide free memory/swap rather than
only its own scheduler's reservation ledger, to catch exactly this class of
externally-induced overcommit — upstream's call whether that tradeoff (extra
complexity, possible false positives from unrelated host load) is worth it.

## Status summary

| ID | Status | Re-verified |
|---|---|---|
| LLMCTL-F1 | Still open | Yes — citation accurate, no `--json` status flag added |
| LLMCTL-F2 | Still open | Yes — citation accurate (line numbers shifted ~657-667 vs. 661-665, same content) |
| LLMCTL-F3 | Still open | Yes — citation accurate |
| LLMCTL-F4 | Still open (live re-verification itself is the open item) | Yes — citation accurate, line shifted to ~1048 for the table row, §10p at line 1304 matches exactly |
| LLMCTL-F5 | Still open | Yes — citation accurate |

No finding has been fixed upstream since the original research-phase audit.
No code in `/home/milosvasic/Projects/llmctl` was modified while writing
this document.
