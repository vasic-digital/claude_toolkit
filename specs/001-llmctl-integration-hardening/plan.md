# Implementation Plan: llmctl Integration Hardening & Verified Release

**Branch**: `001-llmctl-integration-hardening` | **Date**: 2026-10-02 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `specs/001-llmctl-integration-hardening/spec.md`

## Summary

Two exhaustive codebase audits (claude_toolkit-side and the separate
`../llmctl` upstream project — see [research.md](./research.md)) establish
that detection, alias naming, and the on-demand exclusive switch mechanism
are **already correctly implemented and already tested**. The real work this
feature delivers is: (1) a confirmed, already-captured-in-production
context-limit defect fix (an llmctl-backed alias's advertised context was
never carved for a CLI agent's own overhead, causing a real 92,436-vs-8192
token failure); (2) a net-new LAN-exposure warning (FR-009), sourced from the
real kernel socket state rather than from llmctl's JSON (which exposes no
such field); (3) a net-new live, evidence-producing test layer that proves
every llmctl-backed alias genuinely answers the three required Superpowers
extension commands through every supported CLI agent, by extending — never
reinventing — the toolkit's existing unforgeable-knowledge-challenge
anti-bluff mechanism (`verify_superpowers_tui.sh`); (4) a precisely
documented, separately-tracked register of five genuine upstream llmctl
findings (no `../llmctl` code is touched); (5) a full documentation set
(quickstart, user guide, FAQ, diagrams) reachable from the README, built
with the project's existing multi-format export pipeline; and (6) a verified
release published to both GitHub and GitLab with an accurate changelog.

## Technical Context

**Language/Version**: Bash (POSIX-leaning, Bash 5) — matches the whole toolkit; no new language.
**Primary Dependencies**: `jq`, `curl` (both already used by `detect_llmctl_records`), `ss` (new — reads the real listening-socket bind address for FR-009), the existing `cma_run_provider`/`cma_run_kimi_provider`/`cma_run_pi_provider` launch wrappers, the existing `verify_superpowers_tui.sh` anti-bluff mechanism (extended, not replaced).
**Storage**: N/A — no new persistent storage; existing `providers/llmctl.json` pins file and in-memory per-sync records are reused as-is.
**Testing**: The toolkit's existing hermetic sandbox harness (`tests/lib/assert.sh`, `tests/lib/sandbox.sh`, serialized via `cma_suite_lock_acquire`) for unit/integration/contract checks; a new live-test layer (real `claude`/`kimi` binaries, real running llmctl models) following `verify_superpowers_tui.sh`'s existing honest-SKIP/route-attribution pattern for the end-to-end Superpowers-command checks; `claude-release-gate.sh` as the mandatory pre-release gate.
**Target Platform**: Linux + macOS — the same hosts claude_toolkit already targets, matching llmctl's own explicitly Linux/macOS-only scope.
**Project Type**: CLI tool / shell-script library — no new project type introduced.
**Performance Goals**: Per-sync llmctl-detection overhead bounded by the single slowest profile's probe timeout (≤ ~3–10s) rather than the sum across the whole catalog (research.md §5 — probes parallelized, not sequential); no perceptible added delay to interactive shell startup on a host with zero or few llmctl profiles.
**Constraints**: Zero code changes inside `../llmctl` (clarified spec scope — findings are documented and separately tracked, never fixed here); every llmctl-backed model launch/stop in tests goes strictly through llmctl's own commands (research.md §3.E, keeps test execution inside llmctl's own memory/overcommit accounting); live-test execution stays inside this project's `§12.6`/`§12.11` host-memory ceilings; the three live-test checks reuse the existing unforgeable-knowledge-challenge design rather than a new vocabulary/keyword heuristic (research.md §4).

## Constitution Check

*GATE: Must pass before proceeding. Re-check after design phase.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Anti-Bluff — captured evidence for every PASS | PASS | Core design driver: every Check Result is pass/fail/skip with captured evidence (data-model.md); reuses, never weakens, `verify_superpowers_tui.sh`'s existing unforgeable-challenge oracle. |
| II. No-Guessing + investigate-before-acting | PASS | Two exhaustive, cited (file:line) audits performed before any design decision (research.md); the context-limit fix is sourced from already-captured evidence, not a guessed constant. |
| III. Git, Multi-Remote & Data Safety | PASS | No force-push/history-rewrite needed; this is additive feature work on a dedicated feature branch, merged per the toolkit's normal fast-forward discipline. |
| IV. Host & Resource Safety | PASS | Live tests launch/stop llmctl models strictly through llmctl's own commands (research.md §3.E), staying inside its accounting and this project's §12.6/§12.11 ceilings; the parallelized liveness-probe fix (§5) is bounded, not unbounded concurrency. |
| V. Test-First, real-system testing, measured coverage | PASS | New behavior (context-limit carve, LAN warning, live Superpowers checks) is planned test-first in tasks.md; existing hermetic tests already cover the regression-locked behavior (research.md §1) and are preserved, not weakened. FR-011's stress/chaos minimum (initially missing — found by `/speckit-analyze`, finding E1) is covered by tasks.md T021. |
| VI. Independent Code Review — Opus at `xhigh` | PASS (procedural, enforced at /speckit.superspec.review) | No change to this plan's own content; binds the eventual implementation's review step. |
| VII. Documentation, diagrams, always-in-sync | PASS | US4/FR-015/FR-016 explicitly require README-reachable docs + diagrams in every supported export format, using the project's existing `docs/Provider_*`-pattern pipeline (research.md context; plan Project Structure below). |
| VIII. Workable-item integrity & tracked-request lifecycle | PASS | The five llmctl-Side Findings (research.md §7) are explicitly scoped as separately-tracked items (FR-010a), never silently folded into this feature's own closure claim. |
| IX. Submodule & dependency discipline | PASS | `../llmctl` is a sibling project, not a submodule of this repo — the clarified scope (investigate, document, never fix) respects its independent ownership; no new submodule or vendored dependency is introduced. |
| X. Autonomous, multi-track & subagent-driven execution | PASS | The two audit forks dispatched during planning are the template for how implementation tasks (independent per-area fixes) can also fan out; tasks.md marks genuinely independent work streams `[SUBAGENT]`. |
| XI. Release, deployment & supply-chain integrity | PASS | US5/FR-017 requires a correctly-versioned (MINOR bump, new capability — v1.29.0 per CHANGELOG.md's existing `vX.Y.Z` convention), accurately-changelogged release on both GitHub and GitLab, gated behind every prior user story's acceptance scenarios passing and `claude-release-gate.sh`. |
| XII. Secrets & credentials | PASS | Confirmed (research.md §3.F): llmctl requires no real credential by default; `LLMCTL_API_KEY` stays a toolkit-internal registration key, never logged or sent as a real secret. No `.env`/credential handling changes needed. |
| XIII. UI/UX, accessibility & design-system discipline | N/A | This feature has no graphical UI surface (CLI tool); spec Assumptions already note UI-type tests are honestly not-applicable here, not faked. |
| XIV. Code Intelligence (CodeGraph/Lumen) & mechanical-work extraction | PASS | No new mechanical copy/mutate/run/restore loop is introduced that would warrant extraction; the live double-run determinism check (FR-013) is itself a small, documented, testable script, not ad-hoc manual repetition. |
| XV. Governance-corpus self-custody & anchor integrity | PASS | This plan introduces no new constitution anchor; it cites existing anchors (§11.4.6, §11.4.74, §11.4.201, §12.6, §12.11) by reference rather than restating them. |

No violations — Complexity Tracking is empty.

## Project Structure

### Documentation (this feature)

```text
specs/001-llmctl-integration-hardening/
├── spec.md                          # Feature specification (clarified)
├── plan.md                          # This file
├── research.md                      # Phase 0 — audits + decisions
├── data-model.md                    # Phase 1 — entities, schemas, state transitions
├── contracts/
│   ├── llmctl-external-contract.md  # Dependency contract on ../llmctl
│   └── alias-behavior-contract.md   # Behavioral contract claude_toolkit exposes
├── quickstart.md                    # Runnable end-to-end validation scenarios
├── checklists/requirements.md       # Spec quality checklist (already green)
└── tasks.md                         # /speckit.superspec.tasks output (next command)
```

### Source Code (repository root)

```text
scripts/
├── claude-providers.sh              # detect_llmctl_records() — context-limit carve
│                                     # fix + parallelized liveness probe (both:
│                                     # existing function, targeted edits only)
├── lib.sh                           # _cma_llmctl_ensure_active() — post-switch-
│                                     # failure liveness re-probe (targeted edit)
├── verify_superpowers_tui.sh        # EXTENDED (not forked) with two new
│                                     # challenge sources (systematic-debugging,
│                                     # subagent-driven-development)
├── providers/
│   └── llmctl.json                  # pins file — unchanged shape; the carve
│                                     # derives limits from already-available
│                                     # real n_ctx sources, no new field
│                                     # needed (the existing
│                                     # CMA_LLMCTL_CONTEXT_LIMIT env var
│                                     # already covers a manual override)
└── tests/
    ├── test_llmctl_detect.sh                      # existing, extended with
    │                                                 LAN-exposure + context-carve cases
    ├── test_llmctl_ondemand_switch.sh              # existing, extended with the
    │                                                 post-failure re-probe case
    ├── test_llmctl_context_carve.sh                # NEW — unit/contract test for §2's fix
    ├── test_llmctl_lan_exposure.sh                  # NEW — unit test for FR-009
    ├── verify_llmctl_superpowers_live.sh            # NEW — live US3 test, extends
    │                                                 verify_superpowers_tui.sh's design
    └── proof/
        └── (new captured-evidence files per live run)

docs/
├── llmctl/
│   ├── quickstart.md                # NEW (+ .html/.pdf export)
│   ├── user-guide.md                # NEW (+ .html/.pdf export)
│   └── FAQ.md                       # NEW (+ .html/.pdf export)
├── diagrams/
│   ├── llmctl-detection-flow.mmd/.svg  # NEW
│   └── llmctl-switch-flow.mmd/.svg     # NEW
└── README.md (repo root)            # Linked section added, per FR-016
```

**Structure Decision**: every new file is additive within the toolkit's
already-established conventions (`scripts/tests/test_*.sh` naming, the
`docs/Provider_*`-pattern multi-format doc set, the `docs/diagrams/*.mmd`→`.svg`
pipeline) — no new top-level directory, no new build system, no new
language. This follows directly from the Constitution Check's Principle IX
(extend-don't-reimplement) and Principle VII (documentation pattern reuse).

## Execution Strategy

### TDD Requirements

- [x] **Context-limit carve fix** (`claude-providers.sh`): strict RED-GREEN —
  a fixture profile with a real `ctx` below the CLI-agent-overhead floor
  must fail the new test first (reproducing the captured 92,436-vs-8192
  failure shape), then pass once the carve + honest warning land.
- [x] **LAN-exposure detection** (`claude-providers.sh`): RED-GREEN against a
  fixture that binds non-loopback vs. one that binds loopback-only — the
  real-socket-read mechanism must distinguish them without relying on any
  llmctl JSON field (none exists, research.md §3.C).
- [x] **Post-switch-failure liveness re-probe** (`lib.sh`): RED-GREEN against
  a fixture `llmctl` stub that simulates "switch failed, rollback also
  failed" (research.md §3.B) — the wrapper must surface this distinctly, not
  conflate it with an ordinary refusal.
- [x] **Live Superpowers-command checks**: each of the two new challenge
  extractions (systematic-debugging, subagent-driven-development) needs a
  RED case (a model that does not load the skill must fail the challenge)
  before the GREEN case (a model that does load it passes) — mirrors
  `verify_superpowers_tui.sh`'s own existing discipline.

### Parallel Execution Opportunities

- [x] The context-limit carve fix and the LAN-exposure detection are
  independent edits to different responsibilities inside the same function
  (`detect_llmctl_records`) touching non-overlapping field derivations — can
  be developed as two parallel `[SUBAGENT]` streams that land as separate,
  independently-reviewable commits.
- [x] Documentation (quickstart/user-guide/FAQ/diagrams) has zero code
  dependency and can proceed fully in parallel with every code-fixing task,
  starting as soon as `research.md`'s decisions are final (they already
  are).
- [x] The two new live-challenge extractions (systematic-debugging,
  subagent-driven-development) are independent of each other and of the
  existing "Use Superpowers" check — three parallel `[SUBAGENT]` streams.

### Human Checkpoints

1. After the context-limit carve fix and LAN-exposure detection land — verify
   both against a real, locally-running llmctl instance (not just the
   hermetic fixtures) before proceeding to the live Superpowers-command
   layer.
2. After the live Superpowers-command test layer first runs against a real
   GPU-backed profile — verify at least one genuine PASS with inspectable
   evidence before running the full matrix (including the anticipated
   `llmctl-vision` capability-limit case from research.md §3.D).
3. After the full live matrix runs twice with identical verdicts (FR-013) —
   verify no flakiness before documentation is finalized against these
   results.
4. Before the release is cut — confirm every prior user story's acceptance
   scenarios pass and `claude-release-gate.sh` is green.

### Review Gates

- [x] **`contracts/llmctl-external-contract.md`**: review before implementing
  the context-limit carve or LAN-exposure detection, since both depend on
  the exact upstream JSON schema this contract states.
- [x] **The five llmctl-Side Findings register** (research.md §7): review
  before filing the separately-tracked follow-up items, to confirm each
  finding's confidence level and citation are accurate before they leave
  this feature's scope.
- [x] **The live-test extension to `verify_superpowers_tui.sh`**: review
  before merging, since this script is shared, security/anti-bluff-sensitive
  infrastructure used by every other provider's layer-4 verification, not
  llmctl-specific code.

## Complexity Tracking

*No Constitution Check violations — this section is intentionally empty.*
