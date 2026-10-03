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

**Status update (2026-10-03)**: fixed upstream, landed as `../llmctl` commit
`b2fbfec` ("fix: warn before a colibri profile crash-loops on the LAN-bind
security guard"), per the operator's explicit scope-expansion override (see
`specs/001-llmctl-integration-hardening/spec.md`'s 2026-10-03 Clarifications
entry). `sched_build_launch`'s colibri branch now warns up front, naming both
resolution paths, exactly matching the remediation direction above — the
guard itself is unchanged, never auto-bypassed. 9 new assertions in
`tests/test_scheduler_bind_host.sh`; RED (3 failures) confirmed against the
pre-fix code, GREEN after, with no regression across
`test_scheduler.sh`/`test_scheduler_switch_safety.sh`/`test_scheduler_lock.sh`/
`test_port_override.sh` (verified directly from the commit, not from a
self-report).

## LLMCTL-F6 — `vision` profile crash-loops after a successful start (investigated; most likely a symptom of F7, not an independent defect)

**Confidence**: confirmed by live reproduction this session; root cause
investigated and the crash-loop itself could not be reproduced in isolation
post-fix.

Reproduced three separate times on this host (during the SAME live-testing
window as F7's `vision-pro` OOM below): `llmctl switch vision` reports
success, the service genuinely loads the model and begins listening on its
port, then self-terminates within single-digit seconds. `llmctl logs
vision` shows a clean `"cleaning up before exit"` each time — no OOM, no
obvious crash signature. Not linked to LLMCTL-F4's ("vision" profile fails
tool-calling outright) finding — that finding is about a model making no
tool call once a turn actually runs; this one is about the service not
staying up long enough for any turn to be attempted at all.

**Status (2026-10-03) — investigated, not independently fixed**: a fresh,
isolated `llmctl switch vision` (commit `007fc00`'s own investigation, run
AFTER F7's fix landed and with no concurrent GPU activity) ran stably for
26+ seconds with `/v1/models` answering `200` throughout — the crash-loop
did not reproduce. The most likely explanation, stated directly in
`007fc00`'s own commit message: the original crash-loop observations
happened during GPU contention with a CONCURRENT, unrelated `vision-pro`
OOM-retry-loop running in the same time window (F7's root cause, now
fixed) — not a genuine, independent defect in `vision`'s own engine path.
**Honest residual uncertainty**: it was not possible to re-reproduce the
ORIGINAL crash-loop under contention to definitively prove this is the
WHOLE explanation, only that the symptom does not reproduce in isolation
once F7 is fixed. No speculative fix was applied to `vision` itself — if
this profile crash-loops again under conditions where `vision-pro` (or
another profile) is NOT concurrently contending for GPU memory, that would
indicate a genuinely separate defect still open.

## LLMCTL-F7 — VRAM budget check uses static total capacity, not real free VRAM (Fixed)

**Confidence**: confirmed by reading code and live reproduction.

`lib/catalog.sh`'s `footprint()`: `vram_budget = int(vram_total * 0.85)`,
where `vram_total = hw.get("gpu_total_vram_mb", 0)` comes from
`lib/hardware.sh`'s GPU probe, which queries only
`nvidia-smi --query-gpu=name,memory.total,...` — the card's static total
capacity, never how much is actually free at measurement time. Contrast with
`ram_budget = max(0, ram_avail - 4096)`, which correctly uses real available
RAM — the VRAM side of this same budget calculation has no equivalent
real-availability accounting. Reproduced live: `llmctl plan --json` reported
`vision-pro` (ctx=16384) as `fits: true` on this host, but
`llmctl switch vision-pro` genuinely OOM'd —
`cudaMalloc failed: out of memory` in `llmctl logs vision-pro` — because the
GPU had other VRAM usage at the time (12288 MiB total, ~8089 MiB actually
free) that the static-total-based budget check never saw. llmctl's own
scheduler then retried the failing load repeatedly rather than giving up and
reporting a clean failure.

**Status (2026-10-03) — Fixed, commit `3926468`**: `lib/hardware.sh`'s GPU
probe now queries real free VRAM (nvidia-smi `memory.free`, amdgpu sysfs
`mem_info_vram_used`, Apple's unified-memory heuristic applied to real
available RAM; rocm-smi's own free/used column layout was honestly left
`unknown` rather than guessed, since no ROCm host was available to verify
it). New hw-doc field `gpu_free_vram_mb` (`null` when unmeasurable, never a
fabricated value). `lib/catalog.sh`'s `vram_budget` now uses 85% of real
free VRAM when measured, falling back to the original total-based formula
only for old fixtures/unverified GPU paths. Verified directly from the
commit diff and its new `hw-vram-contended.json` fixture test (RED: budget
10444, gpu mode, would OOM; GREEN: budget 2550, correctly falls through to
cpu mode) — not a self-report. No regression: `test_hardware_probe.sh`,
`test_planner.sh`, `test_scheduler_switch_safety.sh` all pass, independently
re-run.

## LLMCTL-F8 — a port already held by an unrelated external process produces a generic timeout, not a clear conflict message (Fixed)

**Confidence**: confirmed by live reproduction.

Reproduced live: `llmctl switch fast` timed out after 60s with no
model-related error at all. Independently confirmed via `ss -ltnp` that
port 8080 (fast's resolved port) was already held by a completely unrelated,
long-running host service (a different project's `helixcode` binary) — not
an llmctl profile, not an llmctl bug in the sense of a defect in the
scheduler's own logic, but a real resilience/error-reporting gap: the
scheduler's readiness-wait path does not appear to distinguish "bind failed
because something else already owns this port" from "still starting,
genuinely slow" — both currently present identically as a plain timeout to
the operator, who must independently run `ss`/`lsof` to discover the real
cause.

**Status (2026-10-03) — Fixed, commit `007fc00`**: new
`_sched_diagnose_bind_failure()` reads the profile's own log after
`_sched_wait_ready` times out, and when it finds llama-server's own
`"couldn't bind HTTP server socket ... port: <N>"` signature, surfaces a
specific message naming the real port, the owning process (via `ss`), and
the `LLMCTL_PORT_<NAME>` override — a deliberate positive-pattern match
(two negative controls: no log at all, and an unrelated failure like OOM)
so a merely-slow-to-free port is never misreported as someone else's
process. Live-reproduced against the real conflict on this host (port 8080
held by an unrelated project's `helixcode` service) — the new message
correctly named the real owning process by name, verified directly, not
from a self-report. No regression: `test_scheduler_wait_ready.sh` (12/12),
`test_services_crashloop.sh`, `test_port_override.sh`, `test_scheduler.sh`
all pass.

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
| LLMCTL-F3 | **Fixed** (commit `b2fbfec`) | Yes — verified directly from the commit diff + its 9 new test assertions, not a self-report |
| LLMCTL-F4 | Still open (live re-verification itself is the open item) | Yes — citation accurate, line shifted to ~1048 for the table row, §10p at line 1304 matches exactly |
| LLMCTL-F5 | Still open | Yes — citation accurate |
| LLMCTL-F6 | Investigated, not independently fixed — most likely a symptom of F7, not a separate defect | New finding, 2026-10-03 — crash-loop did not reproduce in isolation post-F7-fix; honest residual uncertainty noted |
| LLMCTL-F7 | **Fixed** (commit `3926468`) | New finding, 2026-10-03 — verified directly from the commit diff + its new fixture test, not a self-report |
| LLMCTL-F8 | **Fixed** (commit `007fc00`) | New finding, 2026-10-03 — verified directly from the commit diff + live re-reproduction against the real conflict, not a self-report |

**2026-10-03 update**: the operator explicitly overrode this feature's
original "investigate-and-document-only" scope (see
`specs/001-llmctl-integration-hardening/spec.md`'s 2026-10-03 Clarifications
entry) and authorized real fixes in `../llmctl`. Three of the four new/
newly-actionable findings from that work have landed and are independently
verified above: F3 (`b2fbfec`), F7 (`3926468`), F8 (`007fc00`). F6 was
investigated but is most likely a downstream symptom of F7 rather than an
independent defect — no speculative fix was applied to it. F1/F2/F4/F5
remain untouched, separate findings from the original 2026-10-02 audit,
outside this fix wave's scope. The original audit's own finding (no
finding had been fixed upstream, and no code in `/home/milosvasic/Projects/llmctl`
was modified while performing THAT audit) remains true as a historical
statement about the 2026-10-02 research phase — it no longer describes the
project's current state as of 2026-10-03.
