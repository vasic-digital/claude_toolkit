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

- [ ] T001 [P] Confirm `jq`, `curl`, `ss` are available in the toolkit's
  documented dev/test prerequisites (extend `scripts/tests/README.md` or
  equivalent if a prerequisite list exists); `ss` is new for this feature
  (FR-009's bind-address read).
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
- [ ] T003 [P] Create `docs/llmctl/` directory and placeholder
  `docs/diagrams/llmctl-detection-flow.mmd` / `docs/diagrams/llmctl-switch-flow.mmd`
  files (empty scaffolds; content lands in Phase 6).

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
- [ ] T013 [US1] Parallelize the per-profile `/v1/models` liveness probe
  (concurrent rather than sequential) inside `detect_llmctl_records()` to
  bound total detection latency (research.md §5), capped at an explicit
  maximum concurrency (e.g., a `CMA_LLMCTL_MAX_PARALLEL_PROBES` constant,
  default matching this project's existing parallel-fan-out ceilings —
  resolves analysis finding L2; never an unbounded one-`curl`-per-catalog-entry
  fan-out). *(depends on T011, T012 landing first so the carve/LAN logic is
  present in the parallelized path; satisfies **FR-001**, **FR-011**)*
- [ ] T014 [US1] New performance test asserting total detection time stays
  bounded (≈ the single slowest profile's timeout, never the sum, and never
  exceeding T013's concurrency cap's worst case) regardless of catalog size
  — `scripts/tests/test_llmctl_detect.sh` (new case, exercises T013;
  satisfies **FR-011**).
- [ ] T015 [REVIEW] [US1] Review the context-carve + LAN-exposure +
  parallelization changes together against
  `contracts/alias-behavior-contract.md` before proceeding to Phase 4.

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

- [ ] T016 [P] [TDD] [US2] RED test: a fixture `llmctl` stub simulating
  "switch failed, rollback also failed" (research.md §3.B / LLMCTL-F2) must
  produce a distinctly worded, higher-severity warning from
  `_cma_llmctl_ensure_active`, never conflated with an ordinary refusal —
  `scripts/tests/test_llmctl_ondemand_switch.sh` (new case; satisfies
  **FR-007**).
- [ ] T017 [P] [TDD] [US2] RED test: after any switch failure (ordinary or
  rollback-also-failed), the previously-active profile's liveness is
  independently re-probed, never assumed live purely from the switch
  command's exit code — `scripts/tests/test_llmctl_ondemand_switch.sh` (new
  case; satisfies **FR-007**).
- [ ] T018 [P] [TDD] [US2] Regression-confirm existing switch cases:
  already-active no-op (**FR-005**), different-profile triggers switch
  (**FR-005**), **switch-FAILS-aborts-launch for all three account families
  (provider/kimi/pi)** (**FR-007**'s "refused with a clear reason" half —
  named explicitly here per analysis finding U1, previously omitted from
  this task's description even though the underlying test already exists),
  non-llmctl provider never touches llmctl (**FR-008**), unresolvable
  binary refuses cleanly (**FR-004**) — all still pass unmodified —
  `scripts/tests/test_llmctl_ondemand_switch.sh` (existing; satisfies
  **SC-002**).
- [ ] T019 [P] [TDD] [US2] **(new — resolves analysis finding E2)** RED/
  regression test locking FR-006's structural guarantee against future
  drift: `_cma_llmctl_ensure_active` (and therefore any llmctl profile
  start) is reachable **only** from the three launch wrappers
  (`cma_run_provider`/`cma_run_kimi_provider`/`cma_run_pi_provider`) — assert
  that a plain sync/detect call (`detect_llmctl_records`, `claude-providers
  sync`, or equivalent) never starts, pre-warms, or otherwise brings up an
  llmctl profile as a side effect — `scripts/tests/test_llmctl_ondemand_switch.sh`
  (new case; satisfies **FR-006**).

### Implementation for User Story 2

- [ ] T020 [US2] Implement the post-switch-failure liveness re-probe and the
  distinct rollback-also-failed warning in `_cma_llmctl_ensure_active()`
  (`scripts/lib.sh`). *(depends on T016, T017; satisfies **FR-007**)*
- [ ] T021 [US1] [US2] **(new — resolves analysis finding E1)** Stress/chaos
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
  (new file; satisfies **FR-011**).
- [ ] T022 [REVIEW] [US2] Review the switch-hardening change (T020), the
  FR-006 structural lock (T019), and the stress/chaos suite (T021) together
  against `contracts/alias-behavior-contract.md`'s FR-007 refinement before
  proceeding to Phase 5.

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
- [ ] T025 [US3] Extend `scripts/verify_superpowers_tui.sh` (or add
  `scripts/tests/verify_llmctl_superpowers_live.sh` per quickstart.md) to
  issue all three commands against a given alias + CLI agent family, reusing
  the existing route-attribution, bare-provider honest-skip, and
  precondition-SKIP machinery unchanged — including an honest, explicit SKIP
  (never an error, never a silent omission) when llmctl itself is absent
  from the host running this check. *(depends on T023, T024; satisfies
  **FR-012**, **FR-014**)*
- [ ] T026 [TDD] [US3] RED case: an alias/model that does not genuinely load
  a given skill must FAIL that skill's challenge — proves the oracle before
  any PASS from T025 is trusted (satisfies **FR-012**, **FR-014**).
- [ ] T027 [US3] Wire the live check to run across every llmctl-backed alias
  × every supported CLI agent family (claude, kimi), producing one Check
  Result record per combination (data-model.md) — new orchestrator script
  under `scripts/tests/` (satisfies **FR-012**, **SC-004**).
- [ ] T028 [US3] Implement the double-run determinism assertion (**FR-013**):
  run the full matrix twice against an unchanged system, assert byte-identical
  verdicts — `scripts/tests/` (new).
- [ ] T029 [P] [US3] File the five llmctl-Side Findings (research.md §7,
  LLMCTL-F1..F5) as separately tracked follow-up items — a
  documentation/tracking action, never a claude_toolkit code task (satisfies
  **FR-010a**).
- [ ] T030 [REVIEW] [US3] Review the live-test extension to
  `verify_superpowers_tui.sh` before merging — this is shared,
  anti-bluff-sensitive infrastructure used by every other provider's
  layer-4 verification, not llmctl-specific code.

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

- [ ] T031 [P] [US4] Write `docs/llmctl/quickstart.md` (install llmctl, get
  recognized, launch a model) — mirrors the existing
  `docs/Provider_Aliases_User_Guide.md` pattern (satisfies **FR-015**).
- [ ] T032 [P] [US4] Write `docs/llmctl/user-guide.md` (detection, naming,
  switching, LAN-exposure and context-fit warnings, troubleshooting;
  satisfies **FR-015**).
- [ ] T033 [P] [US4] Write `docs/llmctl/FAQ.md` (common how-to/troubleshooting
  questions, explicitly including the honest "a profile's model may not
  support tool-calling or may be too slow" note from research.md §3.D;
  satisfies **FR-015**).
- [ ] T034 [P] [US4] Author `docs/diagrams/llmctl-detection-flow.mmd` and
  `docs/diagrams/llmctl-switch-flow.mmd` (scaffolded in T003), render to
  `.svg` via the existing `mmdc` pipeline documented in
  `docs/diagrams/README.md` (satisfies **FR-015**).
- [ ] T035 [US4] Export `quickstart.md`/`user-guide.md`/`FAQ.md` to every
  project-supported format (`.html`/`.pdf`), mirroring
  `claude-export-docs.sh` / the `docs/Provider_Aliases_User_Guide.*` pattern.
  *(depends on T031, T032, T033; satisfies **FR-015**)*
- [ ] T036 [US4] Add a linked section in the repository root `README.md`
  pointing to `docs/llmctl/quickstart.md`, and link quickstart → user-guide →
  FAQ → diagrams so every new page is README-reachable. *(depends on
  T031–T035; satisfies **FR-016**)*
- [ ] T037 [P] [TDD] [US4] Link-check test asserting zero dead links and
  zero orphaned pages in the new llmctl doc set — `scripts/tests/` (new,
  extends any existing doc-link-check tooling; satisfies **FR-016**,
  **SC-005**).
- [ ] T038 [REVIEW] [US4] Review the full llmctl doc set for accuracy
  against the actual shipped behavior (US1–US3) before proceeding to
  release.

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

- [ ] T039 [US5] Confirm every prior checkpoint (Phases 3–6) is green — gate,
  not a file change (satisfies **FR-017**).
- [ ] T040 [US5] Run `scripts/claude-release-gate.sh` and confirm exit 0.
  *(depends on T039; satisfies **FR-017**)*
- [ ] T041 [US5] Write the `CHANGELOG.md` `## v1.29.0` entry (Added/Changed/
  Testing & Validation sections, matching the existing convention), listing
  only real, verified changes from Phases 3–6. *(depends on T040; satisfies
  **FR-017**)*
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
- [ ] T046 [P] Re-check the plan.md Constitution Check table against the
  final, as-built state — confirm every PASS still holds, including
  Principle V's revised justification now that T021 (stress/chaos) closes
  the gap `/speckit-analyze` found (resolves analysis finding I1).
- [ ] T047 Append this feature's entry to the project's operator-request-history
  ledger (constitution `§11.4.208`), if one is maintained — honest `UNKNOWN`
  for any field not recoverable.

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
