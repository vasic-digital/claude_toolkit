# Feature Specification: llmctl Integration Hardening & Verified Release

**Feature Branch**: `001-llmctl-integration-hardening`
**Created**: 2026-10-02
**Status**: Draft
**Input**: User description: "We MUST CHECK if we are properly and fully incorporating the llmctl solution with the Claude Toolkit and fix any issues, gaps and shortcomings! ... We MUST BE able to recognize all models running by llmctl and enable them and start on the fly if llmctl is present on the System with swapping mechanism to easily switch between the models on same host! ... After everything is fixed and fully covered with exhaustive tests (all supported test types by the constitution) which all produce machine evidence ... intensive LIVE testing of all llmctl exposed models using all supported CLI agents ... covering Superpowers commands (Use Superpowers, Systematic Debugging, Sub-Agents Driven Development) ... Extend and update all existing documentation ... convert to all mandatory formats ... fully incorporate the docs-chain submodule ... user manuals, guides, quick start guides, FAQs ... full diagrams in all major formats, fully linked from the main README ... create a new release using GitHub and GitLab CLIs with properly written changelogs."

## Clarifications

### Session 2026-10-02

- Q: Does "fix any issues... Current llmctl codebase for any fixes (if needed)" mean this feature also makes code changes inside the separate `../llmctl` repository itself, or is this feature's scope strictly the integration code living in `claude_toolkit`? → A: Investigate-first — this feature analyzes llmctl's codebase for defects and documents every finding precisely, but any actual llmctl-side code change is filed as an explicit, separately tracked follow-up item (not performed under this feature's task list).
- Q: Should an llmctl-backed alias use the bare llmctl profile name (e.g. `fast`, `coder`) or a clearly namespaced form (e.g. `llmctl-fast`, `llmctl-coder`)? → A: Always namespaced `llmctl-<profile>` — consistent with this project's existing prefix contract for other backends (`kimi-<id>`, `kc-<id>`), never a bare profile name.

### Session 2026-10-03 — scope override

- The investigate-first "never fix llmctl" boundary set above (2026-10-02 entry) was explicitly overridden by the operator mid-session, in direct instructions to this effect: real fixes to the separate `../llmctl` project, found while live-testing this feature's integration work, "MUST BE done" via "full in depth systematic debugging and properly fixing," covering "all mandatory work on llmctl project." This is a deliberate, operator-directed, one-time exception to this repo's standing "submodules/sibling-projects are independently owned" convention (root `CLAUDE.md`) — scoped only to this specific instruction, not a general precedent for future features to assume the same license. Fixes made under this override land as ordinary commits in `../llmctl`'s own history, reviewed and tested by that project's own conventions, not folded into this repo's task list or commit history.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Every Running llmctl Model Becomes a Ready-to-Use Alias (Priority: P1)

An operator who has llmctl installed and running one or more local model
profiles opens a fresh shell on the same host. Without any manual
provider-file editing, every model profile llmctl currently has running is
already recognized by the toolkit and available as a launchable alias for
every supported CLI agent (Claude Code and Kimi Code).

**Why this priority**: This is the entire point of the integration — if the
toolkit does not reliably see what llmctl is actually serving, nothing else
in this feature (switching, testing, docs) has anything real to act on. It
is also the area most likely to already be partially built and partially
broken, so verifying and fixing it is the highest-value, highest-risk slice.

**Independent Test**: Start one or more llmctl profiles directly via llmctl,
open a new shell, and confirm each running profile appears as a distinct,
launchable alias with the correct model name and capability — independent of
whether switching or documentation work has landed yet.

**Acceptance Scenarios**:

1. **Given** llmctl is installed and is currently serving exactly one model
   profile, **When** the operator opens a new shell or re-syncs the toolkit,
   **Then** exactly one new alias appears, named and labeled after that
   profile's real model, and launching it reaches that model successfully.
2. **Given** llmctl is serving two or more model profiles concurrently,
   **When** the operator re-syncs the toolkit, **Then** one distinct alias
   exists per running profile, each correctly identified by its own model
   name — no profile is missed, merged with another, or mislabeled.
3. **Given** llmctl is installed but is not currently serving any model,
   **When** the operator re-syncs the toolkit, **Then** no llmctl-backed
   alias is created or left active, and the toolkit reports plainly that
   llmctl has nothing running — never a stale alias pointing at a model that
   is no longer there.
4. **Given** llmctl is not installed on the host at all, **When** the
   operator re-syncs the toolkit, **Then** the toolkit behaves exactly as if
   llmctl were simply absent — no error, no broken alias, no dependency on
   llmctl being present.
5. **Given** a profile llmctl is serving binds to all network interfaces
   (LAN-reachable) rather than localhost-only, **When** the toolkit
   recognizes that profile, **Then** it still becomes a usable alias, and the
   operator is shown a clear, explicit warning that the model is reachable
   from the local network, not only from this host.

---

### User Story 2 - Switch Which llmctl Model Is Active Without Breaking Anything Else (Priority: P2)

An operator working with an llmctl-backed alias decides to use a different
local model instead. They ask the toolkit to switch to the new one. The
toolkit hands that request to llmctl's own exclusive switch behavior (stop
everything, start exactly the one requested), and every non-llmctl alias
(native accounts, other providers) keeps working throughout and after the
switch, with no leftover reference to the model that was just replaced.

**Why this priority**: Once models are correctly recognized (User Story 1),
the next most valuable thing an operator does with multiple local models on
one host is move between them — this is the feature's second-most-common
real action, and the one most likely to leave the system in a half-swapped
state if it is not handled atomically.

**Independent Test**: With one llmctl profile active and in use via its
alias, request a switch to a second profile and confirm the first stops, the
second becomes reachable under its own alias, and unrelated provider/account
aliases are unaffected throughout.

**Acceptance Scenarios**:

1. **Given** one llmctl profile is active and its alias is in use, **When**
   the operator requests a switch to a different llmctl profile, **Then**
   the first profile's alias is deactivated, the newly requested profile's
   alias becomes reachable, and at no point are both considered
   simultaneously active by the toolkit.
2. **Given** a requested switch target does not fit the host's available
   resources, **When** the operator requests the switch, **Then** the
   switch is refused with a plain explanation of what would not fit, the
   previously active profile is left exactly as it was (never left with
   nothing running), and no alias is left pointing at a model that failed to
   start.
3. **Given** an llmctl-backed alias is active, **When** the operator
   launches any native account alias or any non-llmctl provider alias,
   **Then** that launch succeeds normally and is wholly unaffected by the
   llmctl switch mechanism.
4. **Given** a switch between two llmctl profiles is requested and
   completes, **When** the operator inspects the previously active alias
   immediately afterward, **Then** it is clearly reported as no longer
   active rather than silently left configured and seemingly launchable.

---

### User Story 3 - Deterministic, Evidence-Backed Proof the Integration Actually Works (Priority: P3)

A reviewer (or the operator themselves) wants proof — not a claim — that
every llmctl-backed alias genuinely works end to end: that it answers real
prompts, and that it correctly handles the toolkit's core extension commands
(enabling the Superpowers extension, turning on systematic debugging, and
turning on sub-agent-driven development) through every CLI agent the toolkit
supports, without any of those commands crashing the model or returning an
API error. Every one of those checks produces a durable, machine-readable
result that can be inspected after the fact — never a narrated "it worked."

**Why this priority**: This is what converts "we wired it up" into "we
proved it works" — it is the direct countermeasure to the exact failure mode
the request calls out by name (tests that pass while the real feature is
broken), and it is what makes every claim in User Stories 1 and 2
trustworthy rather than asserted.

**Independent Test**: With llmctl-backed aliases already recognized and
switchable, run the full evidence-producing check suite against them and
confirm it produces a captured pass/fail record for every alias × command
combination, with no step reporting success purely from the absence of an
error.

**Acceptance Scenarios**:

1. **Given** an llmctl-backed alias is active, **When** the extension-command
   check suite issues the "enable Superpowers", "turn on systematic
   debugging", and "turn on sub-agent-driven development" commands through
   that alias, **Then** each command completes without an API error or model
   crash and returns a response that is recorded as positive evidence, not
   merely "no exception was thrown."
2. **Given** the same check suite is run against every CLI agent family the
   toolkit supports, **When** the suite completes, **Then** a distinct
   recorded result exists for every agent × alias × command combination —
   none silently skipped, none assumed to pass because a sibling
   combination passed.
3. **Given** a check genuinely fails (a command errors, or the model
   response is empty, malformed, or clearly not a real answer), **When** the
   suite runs, **Then** that failure is recorded as a failure with the
   actual captured output — it is never reported as a pass, and it is never
   silently dropped from the result set.
4. **Given** the full check suite has been run once, **When** it is run
   again against an unchanged system, **Then** it produces the same
   pass/fail outcome for every combination — no flakiness, no
   non-deterministic result standing in for a real verdict.
5. **Given** any gap, misalignment, or weak spot in the llmctl integration is
   found during this verification work, **When** it is fixed, **Then** a
   check exists afterward that would have caught the original problem and
   now passes against the fix — the fix is proven, not merely asserted.

---

### User Story 4 - Find, Understand, and Troubleshoot the Integration from the README (Priority: P4)

A new operator who has never used this integration before starts at the
project's main README, and from there can reach every piece of
documentation about the llmctl integration — a quick-start, a full user
guide, an FAQ answering the common "how do I...", "why isn't...", and "what
happens if..." questions, and diagrams explaining how detection, aliasing,
and switching actually work — without hunting through source files or
guessing at undocumented behavior.

**Why this priority**: A correctly-working integration that nobody can
discover or safely operate is only half delivered; this is lower priority
than the working mechanism itself and its proof, but it is what makes the
first three user stories usable by someone other than the people who built
them.

**Independent Test**: Starting only from the main README, follow links to
reach the llmctl quick-start, user guide, FAQ, and diagrams without using
search or prior knowledge of the repository layout, and confirm each
document explains the behavior confirmed in User Stories 1–3.

**Acceptance Scenarios**:

1. **Given** the main README, **When** a reader looks for information about
   local-model / llmctl support, **Then** a clearly labeled link leads them
   to a quick-start covering installing llmctl, having it recognized, and
   launching a model through it.
2. **Given** the llmctl quick-start, **When** the reader wants more detail
   (switching behavior, LAN-exposure warnings, troubleshooting a model that
   does not appear), **Then** a link leads to a full user guide and FAQ
   covering those exact scenarios with concrete answers.
3. **Given** the documentation set, **When** the reader wants to understand
   how detection, aliasing, and switching fit together, **Then** diagrams are
   present, explained in surrounding text, and available in more than one
   file format.
4. **Given** any document in the llmctl documentation set, **When** the
   reader follows its links, **Then** every link resolves to an existing
   page — no dead links, no page that exists but is unreachable from the
   README.

---

### User Story 5 - A Verified Release Is Published With an Accurate Changelog (Priority: P5)

Once the integration has been fixed, proven by the evidence-backed check
suite, and documented, the maintainer cuts a new release capturing exactly
what changed, and that release is published to both of the project's
primary code-hosting services with a changelog a reader can trust describes
what actually shipped.

**Why this priority**: Shipping is the natural conclusion of the work, but
it depends entirely on User Stories 1–4 being genuinely done first — a
release cut before the integration is proven would itself be the kind of
unearned "it works" claim this whole effort exists to prevent.

**Independent Test**: With the prior user stories complete, produce a
release whose changelog entries can each be checked against the actual
change they describe, and confirm the release is visible and correctly
tagged on both code-hosting services.

**Acceptance Scenarios**:

1. **Given** every prior user story's acceptance scenarios pass, **When**
   the maintainer prepares the release, **Then** the version identifier
   advances in a way that reflects the scope of the change (new capability,
   not a patch-only bump).
2. **Given** the release is prepared, **When** the changelog is written,
   **Then** every entry describes a real, verifiable change — no entry
   describes work that was not actually completed.
3. **Given** the changelog is finalized, **When** the release is published,
   **Then** it appears, correctly tagged and versioned, on both
   code-hosting services the project uses, not only one.

### Edge Cases

- What happens when llmctl is present but its hardware/profile plan changes
  between two toolkit syncs (e.g., a profile that used to fit no longer
  fits)? The toolkit must reflect the new reality rather than keep offering
  an alias that can no longer actually be reached.
- What happens when llmctl itself is mid-switch (stopping one profile,
  starting another) at the exact moment the toolkit tries to recognize its
  current state? The toolkit must not report a transient or inconsistent
  state as a stable one.
- What happens when an llmctl profile name itself contains characters that
  are not alias-safe? The resulting `llmctl-<profile>` alias must still be
  individually addressable and must not collide with any other alias once
  sanitized.
- What happens when a command issued through an llmctl-backed alias (one of
  the Superpowers extension commands or an ordinary prompt) times out rather
  than erroring cleanly? That must be recorded as a failure, not silently
  ignored or retried into an apparent pass.
- What happens when the operator asks to switch to an llmctl profile that
  does not exist or is not currently downloaded? The request must be
  refused with a clear reason, never partially applied.
- What happens when the same check suite is run on a host where llmctl is
  not installed? Every llmctl-dependent check must be skipped with an
  honest, explicit reason rather than reported as passed or silently
  omitted from the results.

#### Brainstorm Prompts

- **Boundary conditions**: What is the behavior at zero running profiles,
  exactly one, and the maximum number of profiles the host can co-reside?
- **Error scenarios**: What if llmctl's own command-line interface changes
  its output shape between versions? What if a model crashes mid-response
  during a live check?
- **Scale**: What if an operator has many llmctl profiles downloaded but
  only a few running — does recognition scale cleanly with just the running
  set, not the full catalog?
- **Security**: Does LAN exposure of a recognized model ever get hidden from
  the operator by the toolkit's own summary output?
- **User confusion**: Could an operator mistake an llmctl-backed alias for a
  cloud-hosted provider alias, given how similar their launch commands look?
- **Data integrity**: Can a switch leave two aliases both pointing at ports
  that are no longer backed by any running model?
- **Backwards compatibility**: Does recognizing llmctl change behavior for
  operators who have never installed it?

## Open Questions

| # | Question | Status | Resolution |
|---|----------|--------|------------|
| Q1 | Should the toolkit be allowed to start an llmctl profile that is not already running? | Resolved | On-demand only — may start a profile automatically only when the operator explicitly launches/selects that alias; never starts one speculatively or in the background. |
| Q2 | Should multiple llmctl-backed aliases be usable concurrently, or always swapped exclusively? | Resolved | Exclusive swap — selecting a different llmctl-backed alias always stops the previous one and starts exactly the newly requested one, mirroring llmctl's own `switch`. |
| Q3 | Should the toolkit verify localhost-only binding before auto-enabling a profile? | Resolved | Verify-and-warn — the toolkit checks the bind address and surfaces an explicit warning when LAN-exposed, but still enables the alias; the operator decides. |

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The toolkit MUST detect every model profile llmctl is
  currently serving on the host, with no manual configuration step, and
  re-detect it on every toolkit sync so the recognized set always reflects
  what llmctl is actually running right now.
- **FR-002**: The toolkit MUST expose exactly one distinct, launchable alias
  per currently-running llmctl profile, correctly labeled with that
  profile's real model identity, for every CLI agent family the toolkit
  supports, named with an always-namespaced `llmctl-<profile>` form (never a
  bare profile name) so it is immediately distinguishable from a native
  account alias or any other provider alias.
- **FR-003**: The toolkit MUST remove or deactivate an llmctl-backed alias
  the moment its backing profile is no longer running — an alias MUST never
  be left pointing at a model that has stopped.
- **FR-004**: On a host where llmctl is not installed or not running
  anything, the toolkit MUST behave exactly as if llmctl were absent — no
  error, no broken alias, no dependency introduced on llmctl's presence.
- **FR-005**: The toolkit MUST allow the operator to switch from one
  llmctl-backed alias to another on the same host, and that switch MUST be
  exclusive: the previously active profile is fully stopped and exactly the
  newly requested profile becomes active, mirroring llmctl's own switch
  behavior, never leaving more than one llmctl-backed alias simultaneously
  active.
- **FR-006**: The toolkit MUST start an llmctl profile automatically only in
  direct response to the operator explicitly launching or selecting the
  alias backed by that profile — it MUST NOT start, pre-warm, or otherwise
  bring up an llmctl profile speculatively, in the background, or as a side
  effect of an unrelated toolkit operation.
- **FR-007**: If a requested switch's target profile does not fit the
  host's currently available resources, the toolkit MUST refuse the switch
  with a clear, specific reason, and MUST leave whatever was previously
  active completely unchanged — never partially stopped, never left with
  nothing running.
- **FR-008**: Switching, recognizing, or losing an llmctl-backed alias MUST
  have no effect on any native account alias or any non-llmctl provider
  alias — those MUST continue to function normally throughout.
- **FR-009**: When the toolkit recognizes an llmctl profile that is reachable
  from the local network (not only from the local host), it MUST surface an
  explicit, plainly worded warning of that exposure to the operator at the
  point the alias becomes available, without blocking the alias from being
  used.
- **FR-010**: Every identified gap, misalignment, shortcoming, weak spot,
  performance risk, or danger zone in the existing **claude_toolkit-side**
  llmctl integration MUST be fixed, and each fix MUST be accompanied by a
  check that would have caught the original problem and that now passes
  against the fix.
- **FR-010a**: If the exhaustive analysis of llmctl's own codebase (`../llmctl`)
  surfaces a genuine defect in llmctl itself, that finding MUST be documented
  precisely — root cause, affected location, and evidence — and filed as an
  explicit, separately tracked follow-up item. No llmctl-side code change is
  made as part of this feature's task list.
- **FR-011**: The toolkit MUST provide a check suite covering every
  constitution-mandated test type applicable to this integration (at
  minimum: unit, integration, end-to-end, full-automation, performance, and
  stress/chaos checks of the detection, aliasing, and switching behavior),
  with every check producing a durable, inspectable record of its result —
  never a result that exists only as narrated success.
- **FR-012**: The toolkit MUST provide a live check that, for every
  llmctl-backed alias and for every CLI agent family the toolkit supports,
  issues the "enable Superpowers extension," "turn on systematic debugging,"
  and "turn on sub-agent-driven development" commands, and records for each
  combination whether the command completed without an API error or model
  crash and returned a genuine, non-empty response.
- **FR-013**: Every check and live test result MUST be reproducible — running
  the same check suite again against an unchanged system MUST produce the
  same pass/fail outcome for every combination, with no non-deterministic or
  flaky result accepted as a verdict.
- **FR-014**: A check that cannot run because a precondition is genuinely
  absent (for example, llmctl is not installed on the host running the
  checks) MUST be recorded as an explicit, honestly reasoned skip — never
  recorded as a pass, and never silently omitted from the result set.
- **FR-015**: The toolkit's documentation MUST include, for the llmctl
  integration: a quick-start, a full user guide, an FAQ answering the most
  common how-to and troubleshooting questions, and diagrams explaining
  detection, aliasing, and switching — each available in every document
  format the project's documentation pipeline supports, and all kept
  synchronized with one another.
- **FR-016**: Every llmctl-related documentation page MUST be reachable by
  following links starting from the project's main README, and every link
  within that documentation set MUST resolve to an existing page — no
  orphaned pages, no dead links.
- **FR-017**: Once every other requirement in this specification is
  satisfied and verified, the toolkit's maintainers MUST be able to publish
  a new release, with an accurate changelog, to both of the project's
  primary code-hosting services.

### Key Entities

- **llmctl Profile**: A named, locally-run model configuration llmctl
  manages (its own concept) — has a model identity, a network port, a
  running/stopped state, and a fit/footprint relative to host resources.
  The toolkit observes this entity; it does not own or redefine it.
- **llmctl-Backed Alias**: The toolkit's own representation of a currently-
  running llmctl Profile, exposed to the operator as something launchable
  through a supported CLI agent, always named `llmctl-<profile>` (never a
  bare profile name) so it is immediately distinguishable from a native
  account alias or any other provider alias. Exists only while its backing
  Profile is running; disappears (or is clearly marked inactive) the moment
  that Profile stops.
- **CLI Agent Family**: One of the command-line agent surfaces the toolkit
  supports launching (Claude Code, Kimi Code). Each llmctl-backed alias is
  expected to be reachable through every family the toolkit supports.
- **Extension Command**: One of the three specific commands this feature
  must prove work through every llmctl-backed alias — enabling the
  Superpowers extension, turning on systematic debugging, and turning on
  sub-agent-driven development.
- **Check Result**: A single durable, inspectable record of one check or
  live test's outcome — pass, fail (with captured evidence), or honest skip
  (with a stated reason) — never a fourth, ambiguous state.
- **llmctl-Side Finding**: A documented defect discovered while analyzing
  llmctl's own codebase (`../llmctl`), distinct from a claude_toolkit-side
  gap — carries root cause, affected location, and evidence, and is tracked
  as a follow-up item outside this feature's own task list rather than fixed
  here.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator with llmctl running one or more model profiles sees
  every one of them as a distinct, correctly labeled, launchable alias
  within one toolkit sync, with zero missed, merged, or mislabeled profiles
  across repeated verification runs.
- **SC-002**: An operator can switch from one llmctl-backed model to another
  on the same host in a single request, with the previous model fully
  stopped and the new one reachable, and with zero observed cases of both
  being considered active at once or neither being active after the switch.
- **SC-003**: 100% of the identified gaps, misalignments, and weak spots in
  the existing **claude_toolkit-side** integration are fixed and each has a
  passing, previously-failing-on-the-original-problem check backing the fix;
  100% of any genuine llmctl-side defects found are documented as precise,
  separately tracked findings (zero fixed as part of this feature, zero
  silently dropped).
- **SC-004**: 100% of llmctl-backed alias × CLI-agent-family × extension-
  command combinations produce a recorded pass, fail, or honest skip — zero
  combinations silently missing from the results, and the same result
  reproduces on repeated runs against an unchanged system.
- **SC-005**: A reader who has never seen this integration before can go
  from the main README to a working understanding of how to install llmctl,
  see it recognized, switch models, and troubleshoot a common problem,
  entirely through linked documentation, with zero dead links encountered.
- **SC-006**: A new, correctly versioned release describing this work is
  visible on both of the project's primary code-hosting services, with a
  changelog in which every entry can be matched to a real, verified change.

## Assumptions

- This feature's code-change scope is the claude_toolkit repository only; a
  genuine defect found in llmctl's own codebase during analysis is documented
  as a precise, separately tracked finding, never fixed as part of this
  feature's own task list or release.
- The host running the toolkit and the host running llmctl are the same
  machine (local-only integration, matching llmctl's own same-host design);
  remote llmctl instances are out of scope for this feature.
- "All supported CLI agents by Claude Toolkit" means every agent family the
  toolkit can already launch and manage accounts/providers for at the time
  this feature ships (Claude Code and Kimi Code) — a future agent family
  added later would extend this feature's guarantees, not retroactively
  invalidate them.
- The constitution's full test-type list (unit, integration, e2e,
  full-automation, security, scaling, chaos, stress, performance,
  benchmarking, UI/UX, Challenges) is honored to the extent each type is
  meaningful for a CLI-driven, non-UI, local-process integration; types with
  no applicable surface for this feature (for example, UI tests, since this
  feature has no graphical interface) are honestly noted as not applicable
  rather than faked.
- "All major diagram/document formats" means the project's existing
  documentation pipeline's supported export set (at minimum Markdown, HTML,
  and PDF), with diagrams authored in an open, diffable source format and
  rendered to the same export set.
- "Properly written change and version logs" means the project's existing
  changelog conventions and version-naming scheme are followed, not a new
  scheme invented for this feature.
- Publishing a release is a one-time action for the scope of this feature:
  one coordinated release capturing this work, not a release-per-user-story.
- Recognizing llmctl adds no perceptible delay to interactive shell startup
  or an explicit sync, consistent with the toolkit's existing performance
  budget for its other provider-detection work.
- The integration targets llmctl's currently-documented command-line and
  JSON output shape; a future breaking change to that shape in a newer
  llmctl release is a maintenance concern to be detected and fixed when it
  occurs, not a design constraint solved in advance by this feature.

## Brainstorm Log

<!-- Populated by /speckit.superspec.brainstorm when run. -->
