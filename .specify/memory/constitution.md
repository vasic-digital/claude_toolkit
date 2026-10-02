<!--
Sync Impact Report (scratch — remove before the amended file is treated as final)
Version change: UNVERSIONED (all-placeholder scaffold, never ratified) → 1.0.0
Rationale for 1.0.0 (MAJOR, per semver policy in Governance): this is the FIRST
filled ratification of this document — no prior principle set existed to
preserve or break, so the baseline itself is the major version.
Modified principles: none renamed — all 15 are newly authored from the
resolved template's [PRINCIPLE_N_NAME]/[PRINCIPLE_N_DESCRIPTION] slots.
Added sections: Technology Stack, Development Workflow, Quality Gates
(all present in the newly-resolved constitution-template; absent from the
previously-committed older-variant scaffold).
Removed sections: the old scaffold's generic [SECTION_2_NAME]/[SECTION_3_NAME]
placeholders — superseded by the template's named Technology Stack /
Development Workflow / Quality Gates sections.
Follow-up TODOs: none deferred — every placeholder below is filled. The one
deliberate non-literal: anchor numbers 62, 175, 203, 204 are cited in canon's
own index as gaps (never defined, or re-numbered away) and are reproduced
here as gaps, not invented.
-->

# Claude Multi-Account Toolkit Constitution

## Canonical-root notice (read first)

This document is a **spec-kit-facing index**, not canon. Authoritative governance
for this repository is, in order:

1. `constitution/Constitution.md` (the submodule pinned at `constitution/`) —
   the full Helix Universal Constitution, §§1–12 plus Appendices A–C, anchors
   `§11.4.1`–`§11.4.275` (gaps: `§11.4.62`, `§11.4.175`, `§11.4.203`,
   `§11.4.204` — never defined or re-numbered away in canon itself).
2. `constitution/CLAUDE.md` — the agent manual mirroring the same anchors in
   lockstep (`§11.4.157`).
3. This repository's own root `CLAUDE.md` — a **consumer extension** per
   `§11.4.35`: it may extend or tighten canon, it may never weaken it.

Where this file and canon disagree, **canon wins**, always — this file can lag
canon (it will not restate ~113K tokens of full anchor text per `§11.4.141`
token-efficiency), canon never lags itself. Every principle below cites its
governing anchor(s) by literal token (`§11.4.N`) so a reader can jump to full
text in one hop. This file binds **spec-kit-driven feature work** in this
repository (`/speckit.specify` → `/speckit.plan` → `/speckit.tasks` →
`/speckit.implement`) to the same non-negotiables that already bind every
other change here.

## Core Principles

### I. Anti-Bluff — Every PASS Is a Claim That Carries Captured Evidence

A PASS is a claim the feature works for the **end user**, never a claim that a
checker ran. Every PASS/FAIL/VERIFIED/WORKING/COMPLETE claim MUST cite
captured, machine-derived evidence produced at the layer the claim is about —
metadata-only, config-only, absence-of-error, or grep-without-runtime PASS is
a critical defect regardless of how green the summary line looks
(`§11.4.1`, `§11.4.2`, `§11.4.5`, `§11.4.69`, `§11.4.98`, `§11.4.107`,
`§11.4.123`, `§11.4.226` evidence-class-at-closure, `§11.4.262` machine-created
evidence at every gate, `§11.4.266` claim-vs-reality ledger). Words like
*verified, tested, working, complete, fixed, passing* are forbidden in any
report without pasted output from the current session. An ungoverned
second-opinion/confidence/consensus signal may inform but never substitutes
for a receipt at the evidence-acceptance seam (`§11.4.269`) — it never
weakens the constitution's own mandatory independent-review family (II below).

### II. No-Guessing + Investigate-Before-Acting

"Probably", "seems", "should be" are not findings — state
`UNCONFIRMED:`/`UNKNOWN:`/`PENDING_FORENSICS:` instead of asserting
(`§11.4.6`). No fix ships without root-cause investigation first — reproduce
on the broken artifact using its **exact** working reproduction sequence
before writing a fix; a deviating repro that never reaches the precondition
proves nothing (`§11.4.102` systematic debugging Iron Law, `§11.4.199`
exact-reproduction-sequence, `§11.4.242` bisection-not-blame). Seemingly-dead
code is never removed on sight — investigate git history for how it was wired
and how it died before any deletion (`§11.4.124`). Legacy code with no
behavior-asserting tests gets characterization/golden-master tests **first**,
before any behavior-changing edit (`§11.4.243`). Regression localization uses
bisection (O(log N)) over blame-walking, bounded to a proven monotone
observable (`§11.4.242`).

### III. Git, Multi-Remote & Data Safety — Never Force, Never Lose Work

`--force`/`--force-with-lease`/history rewrite is **never** allowed on any
repo or submodule, with or without approval; integrate by fetching, merging
onto the latest `main`, and pushing fast-forward to **every** configured
upstream (`§11.4.113`, `§9.2`, `§2.1` multi-upstream push). Before any
destructive git command, check status and back up (`§9`/`§9.1`–`§9.4`). A
submodule's own changes are committed and pushed to its own upstream(s)
*before* the superproject's pointer bump; every tag on main mirrors onto every
owned submodule (`constitution/Constitution.md` §§2–4). Branch taxonomy is
closed — `feat/*` merges to `main` only after full validation **and** live
manual QA (`§11.4.185`); `product/*`/`flavor/*` lines do not merge to `main`
the same way (`§11.4.195`). Commits are never made while a build is actively
writing tracked artifacts (`§11.4.121`); the working tree stays quiescent
for subagent commits (`§11.4.84`). A standing anti-mess control plane
reconciles the whole persistent repo/governance/tracking/runtime state against
a declared invariant catalogue before every gated transition — commit-batch
pile-ups, stale locks, orphaned worktrees, and divergent mirrors are
detected, never silently assumed clean (`§11.4.233`).

### IV. Host & Resource Safety

Never suspend, hibernate, reboot, power off, or halt the host
(`CONST-033`, `§12`). Host-safety guards fail closed on an unresolvable signal
and MUST assert the **real** condition from its authoritative source, never a
proxy a carrier process can satisfy (`§11.4.201`, `§11.4.196(D)`, `§12.12`).
Memory stays under a 60%-of-total ceiling for `user.slice`-resident work
(`§12.6`); the containerized build path may use the maximal dynamically-safe
fraction of host capacity, scoped separately (`§12.11`). Process-group
signals are never sent to `pgid ≤ 1` and never issued against a bare
substring match of a process's command line — validate `pid > 1` as a real
integer and resolve identity from `/proc/<pid>/cmdline` before any
`killpg`/`kill -<pgid>`/`pkill -f` call; test mocks must set an explicit
integer `pid`, never rely on a mock library's default (`§11.4.263`,
`§11.4.174`, `§12.12`). Every long-running operation is registered, has a
single owner per purpose, proves liveness via heartbeat/progress delta (never
inferred from "process alive"), hands off cleanly on stop, is reaped only on
proven staleness, and degrades to an evidence-backed decision rather than
blocking indefinitely (`§11.4.232`).

### V. Test-First, Real-System Testing, and a Measured (Never Gamed) Coverage Floor

Every work product with an executable surface — including bash/shell
scripts, gates, and their paired mutations — is test-**first**: the test is
written and observed to fail for the right reason *before* the implementation
exists (`§11.4.224`, `§11.4.43` for fixes specifically, `§11.4.115` RED-on-the-
broken-artifact). Mocks/stubs/placeholders are permitted **only** in unit
tests; every other test type (integration, E2E, full-automation, security,
DDoS, scaling, chaos, stress, performance, UI/UX, Challenges) exercises the
real, fully-implemented system (`§11.4.27`). A ≥85% code-coverage floor
(~100% target) applies, is **necessary but never sufficient** — a line
"covered" by an assertion-free test proves nothing, so coverage is always
paired with a mutation proving the test catches its own negation
(`§11.4.224(C)`, `§1.1`). Every test identifies its oracle explicitly from a
closed strategy set (specified/derived/metamorphic/golden-master/invariant/
statistical/human) and the oracle is structurally independent of the code
under test (`§11.4.245`). Flaky tests are quarantined with a tracked
stabilization deadline, never silently re-run-until-green; permanent
regression guards for known-fixed defects may carry a
`[PROTECTED-SPEC: ATM-NNN]` tag requiring elevated review to modify
(`§11.4.248`). Cross-component boundaries get consumer-driven contract tests
plus a `can-i-deploy`-class compatibility gate (`§11.4.244`). Automated QA is
the **discoverer**; a manual QA pass that finds something new is itself a
tracked coverage-escape requiring a strengthened automated check
(`§11.4.238`).

### VI. Independent Code Review — Opus at `xhigh`, Always, No Fallback

Every change — source, fix, test, gate, doc-tooling, build/CI, config,
governance, one-liner — passes an independent review before acceptance;
self-review precedes but never substitutes for it (`§11.4.92`, `§11.4.142`
universal mandate, `§11.4.125` pre-build gate, `§11.4.194` exhaustive
all-scenario depth, `§11.4.134` iterate-to-clean-GO). That mandatory review —
and any main→feature/product/flavor merge-conflict resolution — runs on the
**Opus model at `xhigh` effort**, always; no Fable, no lower tier, no
fallback model; genuine Opus-unavailability **blocks and defers** the review
rather than substituting a lighter model (`§11.4.209`, `§11.4.211`). Outside
review/merge-conflict scopes, dispatched work defaults to the lightest model
tier genuinely capable of the task (Sonnet by default, escalating on proven
mid-task complexity), per `§11.4.231` — an under-powered dispatch that bluffs
or requires rework is a false economy of equal severity to any other
PASS-bluff. The producer of a change structurally cannot also be its
oracle, gate, or verifier (`§11.4.240`, `§11.4.249`).

### VII. Documentation, Diagrams, and Always-In-Sync Doc Chains

The main README is the canonical entry point — every project document (manual
tests catalog, Status docs, trackers, guides) must be reachable from it,
directly or transitively; no orphan docs (`§11.4.212`, `§11.4.57`). Every
component/service/feature ships a user manual, task-oriented guides, and a
real-question-derived FAQ (`§11.4.257`); architecture, data-flow, state-machine,
and sequence diagrams are embedded at point of use, open-format, non-degenerate,
and synced to the code they describe (`§11.4.258`). Docs stay in sync with the
code/DB they derive from at the commit, build, and constitution-pull write
seams (`§11.4.106`, `§11.4.12`, `§11.4.44` revision headers, `§11.4.65`
multi-format export). The live in-session task/todo tracker is always
up to date and never shows completed work as pending or vice versa
(`§11.4.229`).

### VIII. Workable-Item Integrity & Tracked-Request Lifecycle

Every tracked item carries a valid status (`§11.4.15`), a type from the
closed set (`§11.4.16`), a stable id (`§11.4.54`), and a comprehensive
structured description (`§11.4.148`). A returning defect reopens its existing
item — it is never re-minted as a fresh id, which would silently blind the
reopen-count signal that targets extra scrutiny at the most-fragile work
(`§11.4.214`, `§11.4.55`, `§11.4.189`). A done/ready status write is refused
without its full evidence chain: registry row → executable guard → RED+GREEN
verdict pair → class-matched evidence (`§11.4.146(D3)`). Research and
kicked-off work is driven to full completion-and-wired or explicit
evidence-backed closure — never left sitting un-wired in a backlog
(`§11.4.197`). Every operator request/prompt is mechanically captured,
tracked, and processed — never silently skipped (`§11.4.210`, `§11.4.208`
request-history ledger).

### IX. Submodule & Dependency Discipline

Submodules are equal codebase, decoupled, inherited **by reference** — never
copied/forked byte-identically (`§11.4.28`, `§11.4.177`, `§11.4.251`
byte-identical-fork prohibition). Before adding or reimplementing
functionality, the own-org submodule catalogue is checked first; a missing
capability extends the upstream submodule rather than hand-rolling a
duplicate (`§11.4.74`). Every proposed dependency — internal or external —
carries a closed-set existence verdict (`VERIFIED`/`AMBIGUOUS`/`UNVERIFIED`)
with citable evidence before adoption; existence is necessary, never
sufficient, for fitness (`§11.4.270`). `submodules/go` is the one documented
exception to "always pull latest": it is pinned to a Go point release
required by `claude-code-router`'s `go.mod`, and `origin/master` is the
unreleased next-major dev tree — never bump it there (project-level override,
this repo's own `CLAUDE.md`).

### X. Autonomous, Multi-Track & Subagent-Driven Execution

Subagent-driven execution is the default (`§11.4.20`, `§11.4.70`); the
endless autonomous loop is the default working mode from the first prompt,
stopping only on explicit operator STOP, an empty scope, or a `§12`
host-safety bound (`§11.4.126`). A free track is immediately re-assigned its
next-highest-priority actionable work — never left idle while its domain has
remaining items (`§11.4.192`). Build-and-deploy proceeds the moment source
fixes are proven-correct by independent review; test-instrumentation
hardening runs in parallel, never as a build gate (`§11.4.235`). Pipeline
stages overlap wherever a validation stage does not depend on the
in-flight build's own not-yet-produced artifact, and on non-huge-blocker
discovery only the affected stages re-run — never a from-scratch restart
(`§11.4.230`). A non-converging retry loop is a detected signal: a shared
attempt record is consulted before any re-attempt, and a stalled loop
escalates rather than burning cycles silently (`§11.4.267`).

### XI. Release, Deployment & Supply-Chain Integrity

A release artifact deploys only after the mandated validation produced a
machine-written PASS verdict whose artifact fingerprint matches the
candidate; absence of that verdict blocks exactly as a FAIL does
(`§11.4.135`, `§11.4.236`). Exactly one artifact is built per release
candidate and promoted by content-addressed digest through every
environment — never rebuilt per stage, never promoted by mutable tag
(`§11.4.264`). Rollout to users is traffic-shifted (canary/blue-green) with
an **automated** promote/abort decision gated on both infrastructure **and**
business metrics across multiple analysis windows, never a single sample or
a rubber-stamp manual click (`§11.4.265`). Builds are reproducible and
hermetic, meeting SLSA Build Level 2 as the fleet-wide minimum
(`§11.4.246`). Every release/version name is prefixed per project
(`§11.4.151`); every deploy increments the version, and a manual-QA deploy
closes the outgoing development cycle and opens the next one on the next
version id (`§11.4.235(B)`). A huge-blocker defect triggers full STOP →
fix-all → full-restart, never a partial resume (`§11.4.129`).

### XII. Secrets & Credentials

Never commit, print, log, or echo a credential (`CONST-042`, `§11.4.10`).
`.env` files stay gitignored, mode `0600`. Credential-safe handling extends
to OCR/vision-driven UI interaction evidence (redact before capture,
`§11.4.193`) and to translation review artifacts. Any plaintext credential
value that has ever appeared in documentation, a spec, or commit history is
compromised from the moment of commit, regardless of later removal
(`§11.4.209(D)`).

### XIII. UI/UX, Accessibility & Design-System Discipline

Any UI-shipping surface uses OpenDesign as the mandatory token-and-theme
system, never ad-hoc CSS (`§11.4.162`); design tokens have one canonical
machine-readable source consumed via generated bindings, never hand-copied
(`§11.4.216`). Every UI change is proven with device-independent host-rendered
pixels (golden-diff + OCR/vision oracle) per screen×state×theme — value/
property-only UI tests never substitute for the rendered-pixel proof
(`§11.4.170`). All interaction with a UI — including login — is see-before-
you-type and verify-after-you-type via OCR/vision/accessibility-tree; blind
typing is strictly forbidden (`§11.4.193`). A shipped website must be fully
responsive, SEO-optimized, uniquely OpenDesign-authored, and bleeding-edge
enterprise quality, each proven with captured evidence (`§11.4.190`).

### XIV. Code Intelligence (CodeGraph / Lumen) & Mechanical-Work Extraction

Where a repository ships a structural (CodeGraph) or semantic (Lumen) code
index, every agent and dispatched subagent must be able to reach it through a
resolvable server definition, proven by a real tool call returning an
index-only fact — never assumed reachable from configuration alone
(`§11.4.78`, `§11.4.275`). A census or measurement that informs a decision is
control-needle-proven before its result is believed; an empty result from a
silenced or errored instrument is never read as "absent" (`§11.4.273`).
Deterministic mechanical work (copy/mutate/run/restore/diff loops) is
extracted into a tested, documented script rather than repeatedly executed
one tool call at a time inside an agent's context (`§11.4.274`). The active
skill/extension surface stays the minimum needed for the task at hand;
everything else stays discoverable, not preloaded (`§11.4.272`).

### XV. Governance-Corpus Self-Custody & Anchor Integrity

A rule is bound by the same custody it imposes on the codebase: every named
gate is either implemented or carries a registered, tracked deferral, with
the unimplemented count monotone-decreasing (`§11.4.227`). Propagation gates
count anchor **block-starts**, never bare literal citations — duplicate or
divergent mirror copies and anchor-number collisions are detected, not
assumed absent (`§11.4.227(B)`). A new rule is classified universal (goes to
the constitution submodule) or project-specific (stays in this repo's own
`CLAUDE.md`) at the moment it is minted (`§11.4.17`). Every accepted evidence
record is tamper-evident against deletion, reordering, and tail-truncation,
not only content mutation — a periodic anchor record catches what chain-walk
verification alone cannot (`§11.4.268`). An occasional, bounded exception to
an otherwise-blocking gate is expressed only through the formal waiver schema
— a rostered non-producer authorizer, a mandatory unelapsed expiry, and a
named tracked item — never a silent or informal bypass (`§11.4.271`).

## Technology Stack

| Layer | Technology | Purpose |
|-------|-----------|---------|
| Shell runtime | POSIX-leaning Bash (`scripts/*.sh`) | Primary implementation language for every account/alias/provider/doc-pipeline script; portable across Linux + macOS (BSD vs GNU awk/mktemp discipline) |
| JSON tooling | `jq` | Settings/plugin-manifest merges, provider record resolution, `.claude.json` partial sync |
| Sync/merge | `rsync` (two-pass `--ignore-existing` then overlay) | Cross-account shared-item unification (`claude-unify.sh`) |
| Locking | `flock(1)` with atomic-`mkdir` fallback | Alias-file commit serialization, suite-run serialization — never bare file writes under contention |
| Go toolchain | Vendored Go (pinned point release) + system Go fallback via `command -v` probe | Building `claude-code-router` (CCR) and `cma-proxy`; `submodules/go` pinned to the exact version `go.mod` requires, never `origin/master` |
| Node / router | `claude-code-router` (submodule) | Multi-provider request routing; comma vs slash selector semantics distinguish route syntax from vendor/model catalog ids |
| Go proxy | `cma-proxy` | Per-provider request/response transforms (Kimi tool-schema normalization, HelixAgent tool-call recovery) |
| Kimi agent | Kimi Code CLI (`kimi`) | Sibling agent family to Claude Code; own account prefix, home dir, shared-store subtree |
| Python | `providers_resolve.py`, `model_verify.py`, `opencode_sync.py` | Provider catalog resolution (models.dev), multi-model scoring/verification, OpenCode config translation |
| Doc pipeline | `pandoc` + (`weasyprint` \| `wkhtmltopdf` \| headless Chromium) | `.md` → self-contained `.html`/`.pdf` export (`claude-export-docs.sh`) |
| VCS topology | Git with 4 configured upstream mirrors per repo (GitHub, GitLab, GitFlic, GitVerse) + submodules | Multi-remote push discipline (`§2.1`), recursive submodule governance (`§11.4.28`) |
| Spec-kit | `.specify/` (this directory) | Specification-driven feature development pipeline layered on top of the constitution |

## Development Workflow

This project follows **specification-driven development** via the superspec
pipeline, bound by the constitution's testing and review disciplines at every
step:

1. **Constitution** (`/speckit.constitution`) — establish and maintain these
   governance principles (this document).
2. **Specification** (`/speckit.specify`) — define feature requirements
   before any code is written.
3. **Brainstorming** (`/speckit.superspec.brainstorm`) — challenge assumptions,
   discover edge cases.
4. **Planning** (`/speckit.plan`) — design the technical approach with an
   explicit constitution-compliance check against the principles above.
5. **Task Decomposition** (`/speckit.superspec.tasks`) — break down into
   executable, test-first, dependency-ordered tasks.
6. **Execution** (`/speckit.superspec.execute`) — implement with TDD
   discipline (Principle V) and subagent-driven dispatch (Principle X) where
   it genuinely parallelizes.
7. **Review** (`/speckit.superspec.review`) — independent review at Opus
   `xhigh` per Principle VI, iterated to a clean GO.

### Workflow Rules

- No code is written before a spec is approved.
- Every spec goes through at least one brainstorm session.
- Implementation plans pass a constitution-compliance check before execution.
- Phase checkpoints require explicit human approval.
- Real test-harness discipline (this repo's own, not spec-kit's): every test
  file sources `tests/lib/assert.sh` + `tests/lib/sandbox.sh`, calls
  `make_sandbox` (never touches real `~/.claude*` state), and the full suite
  (`scripts/tests/run-all.sh`) is serialized by `cma_suite_lock_acquire` so two
  concurrent runs never corrupt each other's results.
- `claude-release-gate.sh` is mandatory before any release commit — it is the
  only leg that exercises the real router-transport launch chain end to end
  (Principle XI).

## Quality Gates

### Testing Requirements

- [x] **Unit tests**: REQUIRED — mocks/stubs/fakes permitted only here
      (Principle V, `§11.4.27`).
- [x] **Integration/E2E/full-automation tests**: REQUIRED for any change
      touching the router selector, provider verification, or multi-account
      sync paths — against the real system, never mocked (`§11.4.27`).
- [x] **Contract tests**: REQUIRED at every cross-component boundary this
      toolkit owns (account↔shared-store, alias↔provider config, CCR
      route↔gateway) (`§11.4.244`).
- [x] **TDD discipline**: REQUIRED — every task marked `[TDD]` follows
      RED→GREEN→REFACTOR; every fix follows the 5-step TDD-fix workflow
      (`§11.4.43`, `§11.4.224`).

### Review Requirements

- [x] **Code review**: REQUIRED on every change, no exception — independent,
      Opus at `xhigh` effort, iterated to a clean GO (`§11.4.142`,
      `§11.4.209`, `§11.4.134`).
- [x] **Spec compliance**: REQUIRED — every acceptance scenario in the
      feature spec passes before the feature is reported done.
- [x] **Security review**: REQUIRED for anything touching credentials,
      `.env` handling, or provider API keys (`§11.4.10`).
- [x] **Performance review**: REQUIRED where a change affects context-window
      budgeting, token-limit guards, or the autocompact-window derivation
      (this repo's own documented host-budget forensics in `CLAUDE.md`).

### Deployment Gates

- [x] All tests pass (captured evidence, not a green summary line alone).
- [x] All review items resolved (or formally waived per `§11.4.271`).
- [x] Constitution compliance verified against the 15 principles above.
- [x] `claude-release-gate.sh` green — the live multi-leg proof suite
      (hermetic suite + live OpenCode/providers/aliases + alias e2e +
      constitution) with evidence under `scripts/tests/proof/`.

## Governance

This constitution is the spec-kit-facing governance document for this
repository. It does not supersede the canonical Helix Universal Constitution
(`constitution/Constitution.md`) or this repository's own root `CLAUDE.md` —
it is their distillation into spec-kit's principle/workflow/gate shape, and it
is itself bound by `§11.4.35` (canonical-root inheritance) and `§11.4.17`
(universal-vs-project classification).

**Amendment procedure.** Any amendment requires: (1) a documented change
rationale; (2) an update to every dependent spec/plan/task document that
cited the changed principle; (3) a verification pass confirming no principle
was silently weakened relative to canon (`§11.4.227` self-custody applied to
this file). A principle here may *tighten* canon (extend, per `§11.4.35`); it
may never relax a `§11.4.N` anchor's operative rule.

**Versioning policy** (semantic versioning): MAJOR for a backward-incompatible
principle removal/redefinition or a weakening relative to canon; MINOR for a
new principle or materially expanded guidance; PATCH for wording/clarification
fixes with no semantic change.

**Compliance review.** Every `/speckit.plan` output includes an explicit
constitution-compliance check against the 15 principles above before
`/speckit.tasks` proceeds; every `/speckit.superspec.review` re-checks it
against the finished implementation.

**Version**: 1.0.0 | **Ratified**: 2026-10-02 | **Last Amended**: 2026-10-02
