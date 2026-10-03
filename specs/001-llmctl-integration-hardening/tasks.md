# Tasks: llmctl Integration Hardening & Verified Release

**Input**: Design documents from `specs/001-llmctl-integration-hardening/`
**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/)

**Superpowers detection**: the `writing-plans` skill was checked at both
superspec-bridge detection paths (`$PROJECT_DIR/.agents/skills/writing-plans/SKILL.md`,
`~/.agents/skills/writing-plans/SKILL.md`) and was **not found** at either —
this breakdown uses the built-in fallback: direct decomposition from
plan.md/spec.md/research.md/data-model.md/contracts/, per this command's own
documented fallback behavior.

**Tests**: Explicitly requested by the spec (FR-011 through FR-014 mandate a
full constitution-test-type-breadth suite plus live, evidence-producing
checks) — every user story below includes test tasks, written first.

**Organization**: Tasks are grouped by user story (P1–P5, matching spec.md)
so each is independently implementable, testable, and demoable. Two of the
five stories' *detection/switch mechanisms* are already implemented and
already tested per research.md §1 — their tasks below are the **confirmed
new work** (fixes, hardening, regression confirmation), not a rebuild.
Every task below cites the specific `FR-###`/`SC-###` it satisfies for
direct, non-inferential traceability (added during `/speckit-analyze`
remediation — see Revision Note).

## Format: `[ID] [P?] [Story] [Markers] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[TDD]**: Must follow RED→GREEN→REFACTOR — write the test, confirm it
  fails for the right reason, then implement
- **[REVIEW]**: Human/independent-review checkpoint before proceeding
- **[SUBAGENT]**: Independently dispatchable to a parallel subagent
- **[Story]**: US1–US5, matching spec.md's priority-ordered user stories

## Revision Note (2026-10-02, post `/speckit-analyze`)

`/speckit-analyze` found 0 CRITICAL issues but 2 HIGH coverage gaps, 2 MEDIUM
underspecification findings, and 2 LOW findings. All are remediated in this
revision:

- **E1 (HIGH, FR-011 stress/chaos coverage gap)** → new **T021**.
- **E2 (HIGH, FR-006 zero task coverage)** → new **T019**.
- **I1 (MEDIUM, plan.md Principle V claim incomplete)** → resolved as a
  consequence of E1; no plan.md text changed beyond what E1's fix already
  covers.
- **U1 (MEDIUM, T018's regression list omitted an already-existing case)**
  → T018 reworded to name the omitted case explicitly.
- **U2 (MEDIUM, FR/SC IDs not cited in most task descriptions)** → every task
  below now cites its governing `FR-###`/`SC-###`.
- **L1 (LOW, hedged pins-file language in plan.md)** → resolved definitively
  in T011's description (no new pins-file field; the existing
  `CMA_LLMCTL_CONTEXT_LIMIT` override mechanism already covers the
  operator-override case) and mirrored in `plan.md`'s Project Structure.
- **L2 (LOW, unbounded probe concurrency)** → T013 now states an explicit
  concurrency bound.

Task IDs T019 and T021 are newly inserted (US2's prior T019 and everything
after it shifted by +2, to T047 total). No task before T016 changed
numbering.

---

## Phase 1: Setup

**Purpose**: Shared scaffolding every later phase needs — no behavior change.

- [x] T001 [P] Confirm `jq`, `curl`, `ss` are available in the toolkit's
  documented dev/test prerequisites (extend `scripts/tests/README.md` or
  equivalent if a prerequisite list exists); `ss` is new for this feature
  (FR-009's bind-address read). **Done**: no prerequisite list existed
  anywhere in the repo (checked `scripts/tests/`, root `README.md`); created
  `scripts/tests/README.md` naming all three tools and what each is used for.
- [x] T002 [P] ~~Create `scripts/tests/fixtures/llmctl/`~~ **Course-corrected
  during execution (2026-10-02) after reading `test_llmctl_detect.sh` in
  full**: this suite's real, established convention is a *self-contained
  inline stub per test file* (`write_llmctl_stub()` + `sandbox_stub` heredocs,
  with dynamic values like ports interpolated per-test) — every existing
  llmctl test file defines its own, there is no shared fixtures directory
  anywhere in this suite, and introducing one here would be a mismatched
  abstraction (constitution §11.4.74 extend-don't-reinvent). No shared
  fixtures directory is created; each new test file (T007, T008, T016–T019,
  T021) follows the same inline-stub pattern `test_llmctl_detect.sh` already
  uses, parameterizing `ctx`, bind address, or switch-failure shape directly
  in its own heredoc.
- [x] T003 [P] Create `docs/llmctl/` directory and placeholder
  `docs/diagrams/llmctl-detection-flow.mmd` / `docs/diagrams/llmctl-switch-flow.mmd`
  files (empty scaffolds; content lands in Phase 6). **Superseded in
  practice**: `docs/llmctl/` and both `.mmd` files were created directly
  with their real, final content in T031-T034 rather than as empty
  scaffolds first — same end state, no separate placeholder commit needed.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Contract-level protections that every user story's fixes depend
on being true before they can be trusted.

**⚠️ CRITICAL**: No User Story 1–3 fix lands until this phase's contract
tests exist and pass against current behavior.

- [x] T004 [TDD] Contract test: `detect_llmctl_records` fails closed (an
  honest error, never a silent `[]`) when `llmctl plan --json` returns a
  profile object missing `port` or `ctx` — `scripts/tests/test_llmctl_detect.sh`
  (new case; per `contracts/llmctl-external-contract.md` obligation #1;
  underwrites **FR-001**'s "always reflects what llmctl is actually
  running" guarantee against a malformed upstream response). **Done
  2026-10-02**: added Cases F3 (missing `port` — confirmed silently skipped
  by construction) and F4/F4b (missing `ctx`). **Genuine finding surfaced**
  (Case F4b): when BOTH the catalog's `ctx` and the live probe's own
  `meta.n_ctx` are absent, `context_limit` resolves to the string `"0"` —
  not the documented `8192` fallback — because the jq extraction's
  `.value.ctx // 0` turns an absent catalog field into the valid digit-string
  `"0"`, which wins the `^[0-9]+$` gate before the `CMA_LLMCTL_CONTEXT_LIMIT`
  default is ever consulted. This is not a crash/fabrication risk (no record
  is wrongly fabricated), but it feeds directly into **T011**'s
  context-floor-warning scope — a `context_limit` of `0` is even further
  below any usable floor than the already-known 8192 case, and T011's floor
  check must treat it accordingly. All 38 assertions in the file pass, exit 0.
- [x] T005 [P] [TDD] Confirm (regression) the existing wrong-service
  port-squatting case still holds — liveness is never derived from a merely
  open port — `scripts/tests/test_llmctl_detect.sh` (existing Case, add an
  explicit regression-lock comment citing research.md §1; underwrites
  **FR-001**/**FR-003**). **Done 2026-10-02**: added an explicit
  regression-lock comment after Case E citing research.md §1 (no new
  assertions needed — Cases C2/E already prove this).
- [x] T006 [REVIEW] Review `contracts/llmctl-external-contract.md` and
  `contracts/alias-behavior-contract.md` against the actual current code
  (sanity pass) before any Phase 3+ fix work begins. **Done**: reviewed
  against T004's real findings and amended both contracts — the "fails
  closed" wording was imprecise (missing `port` is already safely
  per-profile-skipped, not a detector-wide failure; missing `ctx` surfaced
  the genuine `"0"`-string bug, not a crash) and `alias-behavior-contract.md`'s
  context-fit section was corrected from "carved the same way every other
  provider's limits already are" (inaccurate — that refers to an unrelated
  catalog-correction mechanism) to the actual implemented shape: an honest
  `context_warning` field alongside the real value.

**Checkpoint**: Contract tests exist, assert the real upstream schema shape,
and pass against current code. Fix work can now safely begin.

---

## Phase 3: User Story 1 - Every Running llmctl Model Becomes a Ready-to-Use Alias (Priority: P1) 🎯 MVP

**Goal**: Every llmctl profile the operator is running becomes a correctly
named, correctly sized, honestly exposure-warned, genuinely usable alias —
closing the two confirmed real gaps (context-limit, LAN-exposure) without
touching the already-correct naming/detection/absence-handling logic.

**Independent Test**: Start one or more llmctl profiles directly via
llmctl, re-sync claude_toolkit, and confirm each appears as a distinct,
correctly labeled, correctly context-sized alias, with an exposure warning
if LAN-bound — independent of switching (US2), live-command proof (US3), or
documentation (US4).

### Tests for User Story 1 (write first, confirm RED)

- [x] T007 [P] [TDD] [US1] RED test reproducing the captured context-limit
  failure shape: a fixture profile whose `ctx` is below the CLI-agent-overhead
  floor must not be exported with an unusable `context_limit`/`max_output` —
  `scripts/tests/test_llmctl_context_carve.sh` (new file; satisfies **FR-010**
  — the claude_toolkit-side gap fix — and **SC-003**). **RED-confirmed
  2026-10-02**: 1 failed / 3 passed, exit 1 — the TINY-profile
  `context_warning` assertion fails exactly as expected (field currently
  ABSENT), the LARGE-profile negative control passes. GREEN is a separate
  task (T011).
- [x] T008 [P] [TDD] [US1] RED test: a fixture profile bound to `0.0.0.0`
  must set the new `lan_exposed` field true and surface a warning; one bound
  to `127.0.0.1` must not — `scripts/tests/test_llmctl_lan_exposure.sh` (new
  file; satisfies **FR-009**). **RED-confirmed (2026-10-02)**: exposed case
  FAILs (`want=true got=false`), local negative-control PASSes — implementation
  is T012. Real `ss -ltn "sport = :<port>"` empirically verified on this host:
  the `Local Address:Port` column reads `0.0.0.0:<port>` for a wildcard bind,
  `127.0.0.1:<port>` for loopback-only — T012 should parse exactly that field.
- [x] T009 [P] [TDD] [US1] Regression-confirm the existing alias-naming
  assertion (`llmctl-<profile>`, never bare) is unchanged —
  `scripts/tests/test_llmctl_detect.sh` (existing; research.md §1
  regression-lock; satisfies **FR-002**).
- [x] T010 [P] [TDD] [US1] Regression-confirm existing Cases A–H4 (zero/one/
  many running profiles, llmctl absent, garbage JSON, env-var precedence)
  still pass unmodified — `scripts/tests/test_llmctl_detect.sh` (existing;
  satisfies **FR-001**, **FR-003**, **FR-004**, **SC-001**).

### Implementation for User Story 1

- [x] T011 [US1] Implement the context-limit carve in `detect_llmctl_records()`
  (`scripts/claude-providers.sh`): derive `context_limit`/`max_output` from
  the real `n_ctx` (`/v1/models` `meta.n_ctx`, else `plan --json`'s own `ctx`
  field), apply the same carve `providers_resolve.py:derive_limits()`
  already applies to every other provider, and emit an honest warning when
  the carved result cannot clear the minimum usable floor. No new
  `providers/llmctl.json` pins-file field is introduced — the carve derives
  limits purely from already-available real `n_ctx` sources, and an operator
  who still needs a manual override already has the existing
  `CMA_LLMCTL_CONTEXT_LIMIT` env var for it (resolves analysis finding L1;
  plan.md's Project Structure note is updated to match). *(depends on T007,
  T004; satisfies **FR-010**, **SC-003**)*
- [x] T012 [P] [US1] Implement LAN-exposure detection in
  `detect_llmctl_records()` (`scripts/claude-providers.sh`): read the real
  listening-socket bind address for the profile's resolved port (`ss -ltnp`
  or equivalent — never an llmctl JSON field, none exists per research.md
  §3.C), set the new `lan_exposed` field, and surface a plainly worded
  warning at alias-creation time. *(depends on T008; satisfies **FR-009**)*
- [x] T013 [US1] Parallelize the per-profile `/v1/models` liveness probe
  (concurrent rather than sequential) inside `detect_llmctl_records()` to
  bound total detection latency (research.md §5), capped at an explicit
  maximum concurrency (e.g., a `CMA_LLMCTL_MAX_PARALLEL_PROBES` constant,
  default matching this project's existing parallel-fan-out ceilings —
  resolves analysis finding L2; never an unbounded one-`curl`-per-catalog-entry
  fan-out). *(depends on T011, T012 landing first so the carve/LAN logic is
  present in the parallelized path; satisfies **FR-001**, **FR-011**)*
  **Done**: `CMA_LLMCTL_MAX_PARALLEL_PROBES` (default 8). Each profile's
  probe runs as a backgrounded subshell writing its own JSON fragment to a
  zero-padded-index-named file in a per-run `mktemp -d` dir; batches of up
  to the cap are launched via plain `wait` (no args — deliberately NOT
  `wait -n`, which needs bash >=4.3 and this project targets macOS's stock
  bash 3.2); fragments are reassembled via one `jq -cs` over the glob,
  which sorts lexicographically by the zero-padded index, so result order
  always matches catalog order regardless of completion order. Measured:
  baseline sequential ~10.5s for 5 profiles x 2s-slow-but-live; parallel
  ~2.25s (one batch, bounded by the single slowest profile). Investigated
  a real-looking hang during manual verification and confirmed by full A/B
  (stash/pop) that it was NOT caused by this change — it reproduced
  identically on the pre-T013 baseline and traced to real API key env vars
  leaked into the debugging shell from earlier in the session, triggering
  slow real network calls in an unrelated code path; a clean-env (`env -i`)
  run resolved it (5.5s, exit 0). Also added a defensive
  `</dev/null >/dev/null 2>&1` on each background subshell's own stdio
  (the subshell would otherwise inherit `resolve_records`'s
  `$(detect_llmctl_records)` pipe fd — a real, independent concern for
  production usage even though it was not the cause of the observed hang).
- [x] T014 [US1] New performance test asserting total detection time stays
  bounded (≈ the single slowest profile's timeout, never the sum, and never
  exceeding T013's concurrency cap's worst case) regardless of catalog size
  — `scripts/tests/test_llmctl_detect.sh` (new case, exercises T013;
  satisfies **FR-011**). **Done**: new Case I, five genuinely-2s-slow mock
  profiles (a dead/refused port would be rejected instantly and prove
  nothing about timeout cost); asserts all 5 still detected AND elapsed
  time is under a 6s bound (sequential sum would be ~10s). 3 consecutive
  clean-env runs: 41/41 passing, elapsed 2.24-2.25s each time — no
  flakiness.
- [x] T015 [REVIEW] [US1] Review the context-carve + LAN-exposure +
  parallelization changes together against
  `contracts/alias-behavior-contract.md` before proceeding to Phase 4.
  **Done**: verified directly against `scripts/claude-providers.sh`'s
  `detect_llmctl_records()` — `context_warning` derives from the real
  per-profile context vs. `CMA_INPUT_FLOOR + 8192`, omitted (not
  empty-stringed) when not applicable, matching the contract's "alongside
  the real value, never a silent substitution" wording; `lan_exposed`
  defaults conservatively `false` when `ss` is unavailable, matching FR-009.

**Checkpoint**: User Story 1 fully functional and independently
demonstrable — every running llmctl profile is a correctly labeled,
correctly sized, honestly LAN-exposure-warned alias, detected within a
bounded time and bounded concurrency.

---

## Phase 4: User Story 2 - Switch Which llmctl Model Is Active Without Breaking Anything Else (Priority: P2)

**Goal**: Harden the already-correct exclusive-switch mechanism against
llmctl's own disclosed "rollback also failed" degraded case, lock in the
FR-006 on-demand-only structural guarantee against regression, and prove
the detection+switch stack holds up under concurrent/adverse conditions —
without touching the parts already proven correct.

**Independent Test**: With one llmctl profile active, request a switch to a
second, and confirm the first stops, the second becomes reachable, and — new
for this story — a simulated rollback-also-failed condition is surfaced
distinctly rather than silently misreported as an ordinary refusal.

### Tests for User Story 2 (write first, confirm RED)

- [x] T016 [P] [TDD] [US2] RED test: a fixture `llmctl` stub simulating
  "switch failed, rollback also failed" (research.md §3.B / LLMCTL-F2) must
  produce a distinctly worded, higher-severity warning from
  `_cma_llmctl_ensure_active`, never conflated with an ordinary refusal —
  `scripts/tests/test_llmctl_ondemand_switch.sh` (new case; satisfies
  **FR-007**).
- [x] T017 [P] [TDD] [US2] RED test: after any switch failure (ordinary or
  rollback-also-failed), the previously-active profile's liveness is
  independently re-probed, never assumed live purely from the switch
  command's exit code — `scripts/tests/test_llmctl_ondemand_switch.sh` (new
  case; satisfies **FR-007**).
- [x] T018 [P] [TDD] [US2] Regression-confirm existing switch cases:
  already-active no-op (**FR-005**), different-profile triggers switch
  (**FR-005**), **switch-FAILS-aborts-launch for all three account families
  (provider/kimi/pi)** (**FR-007**'s "refused with a clear reason" half —
  named explicitly here per analysis finding U1, previously omitted from
  this task's description even though the underlying test already exists),
  non-llmctl provider never touches llmctl (**FR-008**), unresolvable
  binary refuses cleanly (**FR-004**) — all still pass unmodified —
  `scripts/tests/test_llmctl_ondemand_switch.sh` (existing; satisfies
  **SC-002**).
- [x] T019 [P] [TDD] [US2] **(new — resolves analysis finding E2)** RED/
  regression test locking FR-006's structural guarantee against future
  drift: `_cma_llmctl_ensure_active` (and therefore any llmctl profile
  start) is reachable **only** from the three launch wrappers
  (`cma_run_provider`/`cma_run_kimi_provider`/`cma_run_pi_provider`) — assert
  that a plain sync/detect call (`detect_llmctl_records`, `claude-providers
  sync`, or equivalent) never starts, pre-warms, or otherwise brings up an
  llmctl profile as a side effect — `scripts/tests/test_llmctl_ondemand_switch.sh`
  (new case; satisfies **FR-006**).

### Implementation for User Story 2

- [x] T020 [US2] Implement the post-switch-failure liveness re-probe and the
  distinct rollback-also-failed warning in `_cma_llmctl_ensure_active()`
  (`scripts/lib.sh`). *(depends on T016, T017; satisfies **FR-007**)*
  **Done**: landed together with T016/T017's RED→GREEN work (same fork,
  same commit `0a3bc0c`) — `_cma_llmctl_active_profile()` shared parse
  helper + the second `llmctl status` call in the failure branch + the
  `CRITICAL: llmctl rollback also failed` marker. Not a separate action,
  recorded here for accurate task-by-task traceability.
- [x] T021 [US1] [US2] **(new — resolves analysis finding E1)** Stress/chaos
  test of the combined detection+switching stack (the FR-011 minimum test
  type this feature was missing entirely): (a) fire concurrent
  `detect_llmctl_records` syncs against the fixture `llmctl` stub while a
  switch is in flight and assert no corrupted/partial alias state results;
  (b) simulate the fixture `llmctl` process being killed/restarted mid-probe
  and assert the next sync recovers cleanly (no stuck "probing" state, no
  stale alias); (c) simulate a switch request arriving while a previous
  switch is still settling and assert llmctl's own lock-serialization
  (research.md §3.B) is respected, never bypassed by claude_toolkit's own
  wrapper issuing a second concurrent switch — `scripts/tests/test_llmctl_stress_chaos.sh`
  (new file; satisfies **FR-011**). **Done**: 3 scenarios implemented
  exactly as specified, each preceded by an "investigate" case proving the
  race/kill/lock window is genuinely reachable before asserting on it (not
  assumed); 14 assertions, 5 consecutive full-file runs, 14/14 passing
  every run — zero flakiness.
- [x] T022 [REVIEW] [US2] Review the switch-hardening change (T020), the
  FR-006 structural lock (T019), and the stress/chaos suite (T021) together
  against `contracts/alias-behavior-contract.md`'s FR-007 refinement before
  proceeding to Phase 5. **Done**: verified `_cma_llmctl_ensure_active()` in
  `scripts/lib.sh` — on switch failure it never trusts the exit code alone,
  re-probing via the shared `_cma_llmctl_active_profile()` parse helper, and
  raises the distinct `CRITICAL: llmctl rollback also failed` marker only
  when llmctl's own stderr names that exact condition, matching FR-007
  exactly.

**Checkpoint**: User Stories 1 AND 2 both independently functional —
switching stays exclusive, is now honest about llmctl's own disclosed
degraded case, never starts a profile speculatively, and has been proven to
hold up under concurrent syncs and a mid-probe restart — while continuing to
leave every non-llmctl alias untouched.

---

## Phase 5: User Story 3 - Deterministic, Evidence-Backed Proof the Integration Actually Works (Priority: P3)

**Goal**: Extend — never reinvent — `verify_superpowers_tui.sh`'s existing
unforgeable-knowledge-challenge anti-bluff design to prove all three
required Superpowers commands genuinely engage through every llmctl-backed
alias and every supported CLI agent family.

**Independent Test**: With US1/US2 already landed, run the full check suite
against a real running llmctl profile and confirm a captured, reproducible
pass/fail/skip record exists for every alias × agent × command combination.

### Tests/implementation for User Story 3 (interleaved — this story builds the test layer itself)

- [x] T023 [P] [SUBAGENT] [US3] Extract the unforgeable-challenge fact from
  `systematic-debugging/SKILL.md` at runtime (mirrors the existing
  Red-Flags-table extraction for "Use Superpowers") — new helper in
  `scripts/verify_superpowers_tui.sh` (or a shared lib it sources; satisfies
  **FR-012**). **Done**: `sp_skill_file()` generalized to take an optional
  skill-name arg (default `using-superpowers`, zero-arg call site
  unchanged); new `sp_expected_answer_systematic_debugging()` extracts the
  "Reference too long" row's Reality cell from that skill's own "Common
  Rationalizations" table. Verified live against the real installed
  `claude-plugins-official/superpowers/6.4.1` skill file.
- [x] T024 [P] [SUBAGENT] [US3] Extract the unforgeable-challenge fact from
  `subagent-driven-development/SKILL.md` at runtime — same pattern as T023,
  independent target file (satisfies **FR-012**). **Done**: new
  `sp_expected_answer_subagent_driven()` extracts the "spawned its own
  reviewer" row's Reality cell from that skill's own "Common
  Rationalizations" table. Verified live, same host.
- [x] T025 [US3] Extend `scripts/verify_superpowers_tui.sh` (or add
  `scripts/tests/verify_llmctl_superpowers_live.sh` per quickstart.md) to
  issue all three commands against a given alias + CLI agent family, reusing
  the existing route-attribution, bare-provider honest-skip, and
  precondition-SKIP machinery unchanged — including an honest, explicit SKIP
  (never an error, never a silent omission) when llmctl itself is absent
  from the host running this check. *(depends on T023, T024; satisfies
  **FR-012**, **FR-014**)* **Done**: added `--command {using-superpowers|
  systematic-debugging|subagent-driven-development}` (dispatches prompt +
  challenge-extractor; existing claude-path route-attribution/bare-skip/
  precondition-SKIP machinery entirely untouched) and `--agent {claude|kimi}`
  — the Kimi path is new capability (confirmed via a real observed
  `plugin.session_start plugin="superpowers"` session log on this host that
  Kimi Code genuinely supports Superpowers) but is honestly scoped narrower
  than claude's: native-only launch means no router/ccr layer exists to
  misattribute (so `ROUTE-RESOLVED: n/a` is a true statement, not an
  un-investigated gap), while trust-dialog detection and structured
  API-error/empty-result classification are explicit, stated-not-papered-over
  gaps for a follow-up (no captured real Kimi JSON shapes to build them from
  in this pass). `$OUT` now disambiguates by alias×agent×command, with the
  original default filename preserved byte-for-byte for the untouched
  claude+using-superpowers combination. Verified: `bash -n` clean; all 6
  command×agent combinations' arg-validation and precondition-SKIP paths
  exercised with real `bash` runs (invalid `--command`/`--agent` rejected;
  no-alias and alias-not-installed SKIP correctly for every combination).
  Full live-launch wiring (a real model call) was NOT exercised in this pass
  — `cma_ensure_alias_file` hung for an unrelated, pre-existing reason
  unconnected to this change (see T026 note), flagged not hidden.
  **PROCESS NOTE**: partway through this task the file was briefly observed
  reverted to the exact prior-commit (`73b8fb5`) baseline — a transient
  working-tree race with a concurrent git operation elsewhere in this
  session (another fork or the parent, not this task's own doing) — then
  observed restored with these edits intact and re-verified working after
  the fact. Flagging because it's a real coordination hazard (editing files
  in a working tree a concurrent process can briefly `checkout`/`stash`),
  not because anything is actually wrong with the landed result.
- [x] T026 [TDD] [US3] RED case: an alias/model that does not genuinely load
  a given skill must FAIL that skill's challenge — proves the oracle before
  any PASS from T025 is trusted (satisfies **FR-012**, **FR-014**). **Done**
  via a hermetic fixture (no live model, no API cost): for all three
  commands, a plausible-but-wrong model response ("skills evolve over time
  and must be checked regularly for updates") does NOT satisfy
  `grep -qF` against any of the three real extracted challenge answers
  (proven — zero false-positive matches), while each real answer embedded
  verbosely in a longer reply DOES match (proven — zero false-negative
  misses). A full end-to-end RED/GREEN run through the actual script's
  launch path was attempted but abandoned after `cma_ensure_alias_file`
  hung for >120s for a reason unrelated to T025/T026's own code (not
  investigated further — outside this task's scope; flagged as a real,
  separate finding for whoever owns that function, not silently worked
  around). The oracle itself — the part T026 exists to prove — is verified
  directly against the real `sp_skill_file`/`sp_expected_answer*` functions
  and the real installed SKILL.md files, which is the load-bearing claim.
- [x] T027 [US3] Wire the live check to run across every llmctl-backed alias
  × every supported CLI agent family (claude, kimi), producing one Check
  Result record per combination (data-model.md) — new orchestrator script
  under `scripts/tests/` (satisfies **FR-012**, **SC-004**). **Done**:
  `scripts/tests/verify_llmctl_superpowers_live.sh`, discovers every live
  alias via `detect_llmctl_records` (never a second detection path), runs
  all 3 commands × 2 agents per alias, emits one aggregated JSON Check
  Result record (never a silently-missing combination). Proven against a
  REAL running `llmctl-small` profile on this host (6/6 combinations ran,
  each with real captured evidence — genuine, correctly-attributed FAILs
  from the known 8192-token context-capacity limit, e.g. kimi:
  "request (79112 tokens) exceeds the available context size (8192
  tokens)" — exactly research.md §3.D's anticipated failure mode, not a
  toolkit defect). **Correction (independent review, 2026-10-03)**: a
  LATER re-run of one cell (kimi/subagent-driven-development) failed
  instead with a Node.js `ENOSPC` from inotify-watcher exhaustion
  (`/proc/sys/fs/inotify/max_user_instances` = 128 on this host) — unrelated
  host resource contention, most likely from this session's own heavy
  concurrent subagent fan-out, not the context limit and not a repo defect
  either. The verdict-level claim (6/6 genuinely FAIL, none bluffed as
  PASS) holds across both runs; the SPECIFIC per-cell root cause is NOT
  uniform across runs and must not be stated as if it were.
  `kimi-unclassified-nonzero` is deliberately honest about this — it does
  not claim a single cause for every non-zero Kimi exit, because there
  isn't one. **Clean re-confirmation (2026-10-03, post review-fixes)**: a
  final re-run, after the inotify-contention episode cleared and findings
  2/6's fixes landed (commits `e836cfc`/`6e22dc8`/`1d919a1`), shows all 6
  cells uniformly attributing the genuine 8192-token context-capacity
  cause again (kimi transcripts: 79111/79118/79121 tokens vs 8192), and
  every Kimi evidence file now correctly carries `# ROUTE-RESOLVED: n/a`
  (finding 6's fix verified live, not just by its own unit test).
- [x] T028 [US3] Implement the double-run determinism assertion (**FR-013**):
  run the full matrix twice against an unchanged system, assert byte-identical
  verdicts — `scripts/tests/` (new). **Done**:
  `scripts/tests/test_llmctl_superpowers_determinism.sh`. A hermetic oracle
  proof (mandatory, always runs) proves the comparison LOGIC itself: zero
  mismatches on identical runs, exactly one on a changed verdict, one on a
  dropped combination — never silently passing a real mismatch. A cheap
  real-environment double-run (one live combination, invoked twice,
  unsandboxed) proved genuinely deterministic (fail==fail) against the real
  host. **Found and fixed a real bug in this task's own first draft**:
  invoking the live orchestrator from inside `make_sandbox` silently turned
  genuine FAILs into honest SKIPs (the sandbox stubs `CLAUDE_BIN=/usr/bin/true`
  for hermetic safety elsewhere in this suite) — test-environment
  contamination, not real non-determinism; fixed by keeping the real
  double-run strictly outside any sandboxed scope.
- [x] T029 [P] [US3] File the five llmctl-Side Findings (research.md §7,
  LLMCTL-F1..F5) as separately tracked follow-up items — a
  documentation/tracking action, never a claude_toolkit code task (satisfies
  **FR-010a**). **Done**: all five re-verified fresh against the real
  `../llmctl` repository (citations confirmed still accurate, none fixed
  upstream since the original audit) and documented in
  `docs/research/2026-10-02-llmctl-upstream-findings.md`, linked from
  research.md §7. Zero edits made inside `/home/milosvasic/Projects/llmctl`.
- [x] T030 [REVIEW] [US3] Review the live-test extension to
  `verify_superpowers_tui.sh` before merging — this is shared,
  anti-bluff-sensitive infrastructure used by every other provider's
  layer-4 verification, not llmctl-specific code. **Done**: confirmed the
  `--command`/`--agent` extension itself leaves the existing route-
  attribution/bare-skip/precondition-SKIP machinery untouched (the
  anti-bluff-sensitive part this review exists to protect). **Found a real
  bug in `verify_llmctl_superpowers_live.sh` (T027), the new orchestrator,
  NOT in `verify_superpowers_tui.sh` itself**: `verify_superpowers_tui.sh`'s
  own PASS and SKIP paths both exit 0, distinguished only by a stdout text
  prefix (`PASS:`/`SKIP:`) — the orchestrator's first draft classified
  purely on exit code, so every genuine SKIP would have been silently
  recorded as a PASS (did not manifest in the T027 live run only because
  nothing happened to hit a SKIP path that time — a latent defect, not a
  coincidence). Fixed: classification now checks the text prefix first and
  always, independent of exit code, with an explicit `fail (unrecognized
  output shape)` fallback rather than ever defaulting to pass. Verified
  synthetically (all 4 shapes: PASS/SKIP/FAIL/garbage) and against a fresh
  real re-run on the live host (unchanged, correct FAIL results).

**Checkpoint**: Every llmctl-backed alias × CLI-agent × command combination
produces a durable, reproducible, honest Check Result. A genuine
model-capability limit (e.g., `llmctl-vision` per research.md §3.D) is
expected and correctly recorded as a real FAIL — never hidden, never
force-passed.

---

## Phase 6: User Story 4 - Find, Understand, and Troubleshoot the Integration from the README (Priority: P4)

**Goal**: A reader with zero prior knowledge reaches install → recognition →
switching → troubleshooting entirely by following links from the README, in
every project-supported export format.

**Independent Test**: Starting only from `README.md`, follow links to reach
the llmctl quick-start, user guide, FAQ, and diagrams without prior
repository knowledge; confirm every link resolves.

- [x] T031 [P] [US4] Write `docs/llmctl/quickstart.md` (install llmctl, get
  recognized, launch a model) — mirrors the existing
  `docs/Provider_Aliases_User_Guide.md` pattern (satisfies **FR-015**).
  **Done**: 6 sections (prerequisites, quick start, appearance/disappearance,
  switching, the two honest warnings, pointers to user-guide/FAQ), matching
  the existing doc's numbered-`##`/table/code-block house style.
- [x] T032 [P] [US4] Write `docs/llmctl/user-guide.md` (detection, naming,
  switching, LAN-exposure and context-fit warnings, troubleshooting;
  satisfies **FR-015**).
- [x] T033 [P] [US4] Write `docs/llmctl/FAQ.md` (common how-to/troubleshooting
  questions, explicitly including the honest "a profile's model may not
  support tool-calling or may be too slow" note from research.md §3.D;
  satisfies **FR-015**). **Done**: 14 Q&A entries across General/Detection
  and naming/The two warnings/Troubleshooting, mirroring `docs/Provider_FAQ.md`'s
  house style. The context-size answer quotes the real captured evidence
  from `scripts/tests/proof/kimi-llmctl-integration-evidence.txt` verbatim
  (92629 vs 8192 tokens) rather than an invented number.
- [x] T034 [P] [US4] Author `docs/diagrams/llmctl-detection-flow.mmd` and
  `docs/diagrams/llmctl-switch-flow.mmd` (scaffolded in T003), render to
  `.svg` via the existing `mmdc` pipeline documented in
  `docs/diagrams/README.md` (satisfies **FR-015**). **Done**: both authored
  matching the existing diagram style (decision-diamond branching,
  `<br/>`-wrapped labels), rendered via the documented `mmdc` command,
  verified non-blank (exact diagram label text — `context_warning`,
  `lan_exposed`, `CRITICAL`, `rollback` — found inside the rendered SVG
  XML, 35KB/29KB file sizes), and both rows added to
  `docs/diagrams/README.md`'s index + regeneration command.
- [x] T035 [US4] Export `quickstart.md`/`user-guide.md`/`FAQ.md` to every
  project-supported format (`.html`/`.pdf`), mirroring
  `claude-export-docs.sh` / the `docs/Provider_Aliases_User_Guide.*` pattern.
  *(depends on T031, T032, T033; satisfies **FR-015**)* **Done**: ran
  `MD_FILE=docs/llmctl/<doc>.md bash scripts/claude-export-docs.sh` per file
  (the script's `MD_FILE` override is already generic, proven by
  `test_export.sh`'s own fixture-md pattern — no script change needed);
  produced `.html`/`.pdf`/`.docx` for all three docs, every PDF verified
  `%PDF-` at byte 0.
- [x] T036 [US4] Add a linked section in the repository root `README.md`
  pointing to `docs/llmctl/quickstart.md`, and link quickstart → user-guide →
  FAQ → diagrams so every new page is README-reachable. *(depends on
  T031–T035; satisfies **FR-016**)* **Done**: README's Documentation table
  gained a quickstart → user-guide → FAQ row (+ a direct diagram link);
  `user-guide.md` gained a new §7 "Diagrams" pointing at both rendered SVGs
  and their `.mmd` sources, closing the only previously-unlinked hop.
- [x] T037 [P] [TDD] [US4] Link-check test asserting zero dead links and
  zero orphaned pages in the new llmctl doc set — `scripts/tests/` (new,
  extends any existing doc-link-check tooling; satisfies **FR-016**,
  **SC-005**). **Done**: `scripts/tests/test_llmctl_doc_links.sh` (8 cases) —
  extracts every markdown link from README.md + the 3 llmctl docs, resolves
  each canonically (collapsing `..`, which an earlier draft got wrong and a
  real planted-fixture run proved: see test header), asserts zero dead links,
  BFS-reachability from README.md for zero orphans, and that both diagram
  SVGs are linked from somewhere in the set. Proven non-vacuous both ways: a
  manually planted dead link was caught live (then reverted, zero diff) before
  this was marked done, and the real "switch-flow.svg not reachable" bug this
  test itself found (a `..`-relative-path string-compare bug in the test, not
  in the docs) was fixed and re-verified green.
- [x] T038 [REVIEW] [US4] Review the full llmctl doc set for accuracy
  against the actual shipped behavior (US1–US3) before proceeding to
  release. **Done**: cross-checked every concrete claim in quickstart/
  user-guide/FAQ against the real source and evidence: the `kimi-llmctl-<profile>`
  naming matches `data-model.md`'s documented family-pairing; the captured
  "92629 tokens ... 8192" context-exceeded quote matches
  `scripts/tests/proof/kimi-llmctl-integration-evidence.txt` verbatim; the
  `LLMCTL_BIND_HOST` / `LLMCTL_BIND_HOST_<PROFILE>` env vars and the
  `0.0.0.0` default bind claim match the upstream `llmctl` repo's own
  README/CHANGELOG and this feature's own
  `docs/research/2026-10-02-llmctl-upstream-findings.md` (LLMCTL-F3). No
  inaccuracies found; no edits needed.

**Checkpoint**: A new reader can go from the README to a working
understanding of install/recognition/switching/troubleshooting with zero
dead links.

---

## Phase 7: User Story 5 - A Verified Release Is Published With an Accurate Changelog (Priority: P5)

**Goal**: Publish a correctly versioned, accurately changelogged release to
both GitHub and GitLab, gated behind every prior user story's acceptance
scenarios.

**Independent Test**: With US1–US4 complete, produce a release whose
changelog entries each match a real, verified change, and confirm it is
visible and correctly tagged on both services.

- [x] T039 [US5] Confirm every prior checkpoint (Phases 3–6) is green — gate,
  not a file change (satisfies **FR-017**). **Done**: independently
  re-verified (not trusted from a subagent self-report) T027/T028's
  orchestrator + determinism oracle, T030's classification fix (RED-before/
  GREEN-after confirmed by temporarily reverting it), T035-T038's doc
  export/linking/link-check (re-ran `test_llmctl_doc_links.sh`: 8/8), and
  closed out T001/T003/T015/T022 which had been left unchecked. Full
  sandbox suite: `scripts/tests/run-all.sh` — **84 test files, 84 passed, 0
  failed, ALL GREEN**.
  **Addendum (2026-10-03) — four independent-review rounds (§11.4.209 Opus-`xhigh`, iterated to GO per §11.4.134), run AFTER the above and before T042**:
  Round 1 — NO-GO, 6 findings (FR-009 warnings never surfaced; Kimi
  launch-refused false-FAIL on successful switch; `lan_exposed` missed
  LAN-IP/dual-socket binds; post-switch re-probe made false multi-profile
  claims; a doc over-generalization; Kimi path lost its own
  `ROUTE-RESOLVED` line) — all fixed (`e836cfc`, `6e22dc8`, `1d919a1`).
  Round 2 — NO-GO, the zsh-word-splitting fix for finding 4 only worked
  under bash, plus a new TSV null-field-corruption bug in the sync loops —
  both fixed (`be979c0`, `c65d8ec`). Round 3 — NO-GO, the same TSV bug
  recurring through `.base_url` (cascading every subsequent field), plus a
  sibling instance in the provider-rename path and in
  `verify_providers_live.sh` — fixed (`fa979ca`, `b4991bb`, `f8e38d2`).
  Round 4 — covered the Pi-wrapper silent-failure fix (`eadf6f6`) and
  documentation commits (`4e078cf`, `ca4f39e`) — clean **GO**, no
  blockers. Full suite re-ran green after each round (final confirmed
  count: 87 test files, 87 passed).
- [x] T040 [US5] Run `scripts/claude-release-gate.sh` and confirm exit 0.
  *(depends on T039; satisfies **FR-017**)* **Done**: `--provider nvidia
  --skip-suite` (suite had just run green under T039) — layer 2 live smoke
  GREEN (GATE-OK served end-to-end, sink-side route confirmed), layer 2.5
  kimi smoke honest-SKIP (`kimi-deepseek` alias exists but its provider
  status is `failed` — the verification gate refuses to force-launch an
  unverified alias, so the gate SKIPs rather than FAILs; corrected here
  from an earlier, less precise "alias does not exist" wording — never a
  gate FAIL per the script's own design), **ALL LAYERS
  GREEN — release may proceed.** Note: the gate's *default* provider
  (`helixagent`) is `unverified` on this host (HelixLLM is in coder mode,
  the documented common case) and `helixagent-native` (32768 ctx) genuinely
  FAILed with "Prompt is too long" — investigated and confirmed as the
  project's own already-documented host-state condition (this host's
  enabled-plugin tool-prefix exceeds a 32K-context provider's window,
  `CLAUDE.md`'s "Router selector semantics" section), not a regression from
  this feature's work. `nvidia` (1,000,000 ctx) was picked per that same
  doc's explicit guidance and is unaffected.
- [x] T041 [US5] Write the `CHANGELOG.md` `## v1.29.0` entry (Added/Changed/
  Testing & Validation sections, matching the existing convention), listing
  only real, verified changes from Phases 3–6. *(depends on T040; satisfies
  **FR-017**)* **Done**: an earlier draft of this entry (written before T040
  actually ran) claimed the release gate was already green — struck as a
  bluff per the anti-bluff mandate once caught during T039's review; the
  Testing & Validation section now cites only the real T039/T040 results
  (84/84 suite, nvidia-gated release-gate ALL GREEN) captured in this
  session.
**llmctl scope-expansion status (2026-10-03, recorded here per T039's
checkpoint-gate role — see `spec.md`'s Clarifications and `CHANGELOG.md`
for the authorization itself and the full fix-by-fix breakdown)**: the
operator explicitly directed real fixes in the separate `../llmctl`
project, overriding this feature's original investigate-only boundary.
**COMPLETE as of this entry** — 11 commits (`b2fbfec`..`6fae6de`), through
five independent Opus-`xhigh` review rounds (each round finding a real
issue in the prior round's fix, until round 5 returned a clean,
unconditional GO with zero blocking/Important findings), independently
re-verified by this session at every step (`tests/run_tests.sh`: 37/37
PASS confirmed fresh after each of the 11 commits), and pushed
fast-forward to all five of llmctl's own remotes (github/gitlab/codeberg/
gitflic/gitverse), verified by `git ls-remote` matching local `HEAD`
(`6fae6de`) on every one. The admission-control/eviction-loop chain
(`451d983`→`f6febd8`→`39a1f0e`→`aa38ebb`) that round 2-4 surfaced is fully
closed; see `CHANGELOG.md`'s `## v1.29.0` entry for the complete
commit-by-commit narrative.
- [ ] T042 [US5] Tag `v1.29.0` (and the constitution `§11.4.151`
  project-prefixed `claude_toolkit-1.29.0` tag) and push fast-forward-only to
  every configured upstream remote. *(depends on T041; satisfies **FR-017**)*
- [ ] T043 [US5] Publish the release via `gh release create v1.29.0` and
  `glab release create v1.29.0`, each with the changelog section as release
  notes. *(depends on T042; satisfies **FR-017**)*
- [ ] T044 [REVIEW] [US5] Confirm the release is visible and correctly
  tagged on both GitHub and GitLab. *(depends on T043; satisfies **FR-017**,
  **SC-006**)*

**Checkpoint**: All five user stories independently functional; release
published.

---

## Phase 8: Polish & Cross-Cutting Concerns

- [ ] T045 [P] Full sandbox suite run (`scripts/tests/run-all.sh`) — zero
  regressions across the whole toolkit, not only the llmctl-related tests.
- [x] T046 [P] Re-check the plan.md Constitution Check table against the
  final, as-built state — confirm every PASS still holds, including
  Principle V's revised justification now that T021 (stress/chaos) closes
  the gap `/speckit-analyze` found (resolves analysis finding I1). **Done**:
  cross-checked all 15 principles against final implementation. 13 of 15
  unchanged and still accurate. Two corrections made in plan.md: (1)
  Principle V's note upgraded from "is covered by tasks.md T021" to cite
  the real, independently re-verified evidence (14/14 assertions, 5
  consecutive clean runs, zero flakiness; 84/84 full-suite as-built). (2)
  Principle VI's note now honestly states this branch has **not yet**
  undergone its required independent code review (no `/code-review`
  Fable/xhigh pass found in commit history or spec artifacts as of this
  check) — that gate stays OPEN and must run before T042 (tag), not
  satisfied by the T039/T040 test-suite/release-gate checks alone.
- [x] T047 Append this feature's entry to the project's operator-request-history
  ledger (constitution `§11.4.208`), if one is maintained — honest `UNKNOWN`
  for any field not recoverable. **N/A, honestly**: checked this project for
  an existing ledger at any conventional path (`docs/requests/`, repo root,
  `.specify/`) — none exists. `§11.4.208` mandates a full append-only,
  newest-first, 4-format-exported document with its own keep-applying
  capture hook; standing one up from scratch is a separate, project-wide
  governance initiative out of scope for this llmctl-integration feature,
  not a one-line addition this task could honestly claim to satisfy. Task
  was itself written conditionally ("if one is maintained") — condition is
  false, so there is nothing to append to.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — starts immediately.
- **Foundational (Phase 2)**: Depends on Setup — BLOCKS Phase 3's fix work
  (not Phases 4–5's test-writing, which can start once T006 is reviewed).
- **User Story 1 (Phase 3)**: Depends on Foundational. No dependency on US2–US5.
- **User Story 2 (Phase 4)**: Depends on Foundational. Independent of US1's
  fixes (different file region of `lib.sh` vs. `claude-providers.sh`), but
  logically sequenced after US1 so the T021 stress/chaos suite exercises a
  fully hardened detect+switch stack at once, and so live-testing (US3)
  exercises it too.
- **User Story 3 (Phase 5)**: Depends on US1 (an alias with a correct
  context/LAN posture) and US2 (a hardened, stress-tested switch) being in
  place — a live Superpowers check against an alias still carrying the
  8192-token defect would produce misleading FAILs unrelated to what US3 is
  actually proving.
- **User Story 4 (Phase 6)**: Depends on US1–US3's real, final behavior
  (documentation describes what actually ships, never what was planned).
- **User Story 5 (Phase 7)**: Depends on US1–US4 all being complete and green.
- **Polish (Phase 8)**: Depends on every prior phase.

### Parallel Opportunities

- All `[P]` Setup tasks (T001–T003) run in parallel.
- T004/T005 (Foundational contract tests) run in parallel.
- Within US1: T007–T010 (tests) run in parallel; T011 and T012
  (implementation) touch non-overlapping logic inside the same function and
  can be developed as parallel `[SUBAGENT]` streams, landing as separate
  commits, before T013 integrates both into the parallelized probe loop.
- Within US2: T016–T019 run in parallel (four independent test-writing
  streams); T021's stress/chaos suite can be developed in parallel with
  T020's implementation once both T016/T017's RED state is confirmed, since
  T021 targets the fixture harness + lock-serialization behavior rather than
  the specific re-probe logic T020 implements.
- Within US3: T023 and T024 (the two new challenge extractions) are fully
  independent `[SUBAGENT]` streams; T029 (findings filing) is independent of
  all code work in this phase.
- Within US4: T031–T034 (quickstart, user-guide, FAQ, diagrams) are four
  fully independent `[SUBAGENT]` streams with zero code dependency — they
  can start as soon as US1–US3's *final* behavior is known, i.e., after
  Phase 5's checkpoint, not necessarily waiting for Phase 6 itself to begin.

---

## Parallel Example: User Story 1

```bash
# Launch all four US1 test-writing tasks together:
Task: "RED test for context-carve in scripts/tests/test_llmctl_context_carve.sh"
Task: "RED test for LAN-exposure in scripts/tests/test_llmctl_lan_exposure.sh"
Task: "Regression-confirm alias naming in scripts/tests/test_llmctl_detect.sh"
Task: "Regression-confirm Cases A-H4 in scripts/tests/test_llmctl_detect.sh"

# Then, once RED is confirmed, launch the two independent fixes together:
Task: "Implement context-limit carve in scripts/claude-providers.sh"
Task: "Implement LAN-exposure detection in scripts/claude-providers.sh"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1 (Setup) + Phase 2 (Foundational).
2. Complete Phase 3 (User Story 1) — this alone closes the highest-value,
   already-captured-in-production defect (context-limit mismatch) and the
   confirmed LAN-exposure gap.
3. **STOP and VALIDATE**: run T014's performance test and manually confirm
   against a real llmctl profile before continuing.

### Incremental Delivery

1. Setup + Foundational → foundation ready.
2. US1 → validate independently → the MVP defect fix ships.
3. US2 → validate independently → switching is fully hardened and
   stress/chaos-proven.
4. US3 → validate independently → the live, evidence-backed proof layer
   exists and has actually run.
5. US4 → validate independently → documentation matches reality.
6. US5 → release.

### Parallel Team / Subagent Strategy

1. Team/subagents complete Setup + Foundational together.
2. Once Foundational is done, dispatch **within** US1: one subagent on the
   context-carve fix (T011), one on LAN-exposure (T012) — both are `[P]`
   against different concerns in the same file region.
3. Once US1 lands, dispatch **within** US3: one subagent per challenge
   extraction (T023, T024) — fully independent files.
4. Once US1–US3 are final, dispatch **all four** US4 doc tasks
   (T031–T034) as parallel subagent streams.

---

## Notes

- `[P]` tasks touch different files or non-overlapping logic — no shared-file
  conflicts.
- `[Story]` labels trace every task back to its spec.md user story; every
  task also cites its governing `FR-###`/`SC-###` directly.
- Two of this feature's five user stories' *core mechanisms* were confirmed
  already correct and already tested during planning (research.md §1) — this
  breakdown's US1/US2 tasks are deliberately scoped to the **confirmed new
  work** only, never a from-scratch rebuild of what already works.
- Verify every `[TDD]` test fails for the right reason before implementing.
- Commit after each task or logical group.
- Stop at any checkpoint to validate a story independently before continuing.
