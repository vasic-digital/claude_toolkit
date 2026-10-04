# Feature Specification: Universal Alias Quota/Limits Reporting

**Feature Branch**: `002-provider-usage-command`
**Created**: 2026-10-04
**Status**: Draft
**Input**: User description: "Extend the solution with another command: \"usage\" which MUST BE applicable to all providers and native aliases. For example claude-providers usage, or pi-providers usage, or any similar variant which MUST give us exact usage information for every claude code alias, every provider alias so we are aware how much tokens / days of use we have left - exact percentage! We MUST know from it if we had hit some kind of limit, when it expires, if it expires, the limit or the whole subscription. Make sure that limiting is nicely colored and easy to see understand, and depending on the percentage left for the current session, or weekly (or daily if provider supports it) limit. For example 100 - 30 % green, 30 - 10 % yellow, below 10 % red coloring. Make sure that there are no gaps, shortcomings, weak spots or danger zones left. Everything MUST BE fully covered with all supported test types and fully documented - all documentation updated, extended and new one written, user guides, manuals and tutorials, FAQs and all other materials! When everything is fully completed we MUST run setup and perform full LIVE testing, confirmation, validation and verification on LIVE installed latest Claude Toolkit codebase with fully deterministic checks against machine produced rock-solid evidence! After all this is completed with no false or faulty results, with no gaps or bluff of any kind we MUST release new version of everything using GitHub and GitLab CLI agents with properly written change and version logs!"

## Clarifications

### Session 2026-10-04

- Q: Should the new reporting subcommand keep the exact name `usage` as originally requested, even though both `claude-providers.sh` and `kimi-providers.sh` already have a `usage()` function that prints `--help`-style invocation text — or should it use a different name that avoids that collision? → A: Neither alone — support **both** `quota` and `limits` as fully equivalent subcommand names (not `usage`), with zero conflicts against any existing subcommand, function, or flag. Confirmed clash-free by inspecting both scripts' dispatch tables and the codebase's own existing informal use of "quota" for this exact concept (`claude-release-gate.sh`'s "account quota (usage limit)" log line).
- Q: Should the `quota`/`limits` command also support a structured, machine-readable output mode (e.g. JSON) in addition to the colored human-readable default, or is colored terminal text the only required output form for this feature? → A: Yes — add a `--json` flag mirroring this toolkit's existing convention (`llmctl plan --json`), emitting the same data as structured JSON so automated tests and scripts never need to parse colored or human-formatted text.
- Q: When probing multiple aliases' providers for live usage data in one fleet-wide run, should the command probe them in parallel with a bounded per-provider timeout, or sequentially, and is there a cap on total run time regardless of alias count? → A: Probe all aliases concurrently, each with a short bounded per-provider timeout; a slow/unresponsive provider only affects its own alias's status (FR-010), never the rest of the report, and total wall-clock time stays bounded by the per-provider timeout rather than growing with the number of aliases.

No other blocking clarifications were required. The feature request fully
specifies scope (every native alias and every provider alias), the required
granularity (session / daily / weekly / subscription windows), the coloring
rule (green ≥30%, yellow 30–10%, red <10%), and the delivery bar (tests,
docs, live verification, dual-forge release). Judgment calls with no single
obvious answer — what to show for a provider that exposes no usage API at
all, and whether the command should prefer live or cached data — are
resolved below under Assumptions, following this project's existing
anti-bluff convention (report what is actually known; never fabricate or
estimate a number in place of real provider data).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Fleet-Wide Quota/Limits At A Glance (Priority: P1)

An operator who runs several Claude Code and Kimi Code sessions across many
native accounts and provider aliases wants, before starting a work session,
to see at a glance which of those aliases are healthy, which are running low,
and which have already run out — across every budget window each one tracks
(current session, daily, weekly, or whole subscription) — without having to
query each alias one at a time or guess from a failed launch later.

**Why this priority**: This is the entire point of the feature. An operator
who only discovers a limit was hit when a launch fails mid-task has already
lost the work session the feature exists to protect. A single, truthful,
color-coded overview across every alias is the minimum viable version of
this feature.

**Independent Test**: With at least one native account and one provider
alias configured, run the `quota`/`limits` command with no arguments and
confirm every currently known alias appears exactly once, each with its own
usage figures and color, independent of whether per-alias drill-down (User
Story 2) or the honest "not reported" path (User Story 3) has landed yet.

**Acceptance Scenarios**:

1. **Given** multiple native accounts and provider aliases are configured,
   **When** the operator runs the `quota`/`limits` command with no further
   argument, **Then** the output lists every one of them, each annotated
   with its own usage figures and color, with none silently missing.
2. **Given** an alias is at 45% of its weekly limit remaining and 8% of its
   daily limit remaining, **When** the `quota`/`limits` command runs,
   **Then** the weekly figure is shown and colored green and the daily
   figure is shown and colored red, as two independent figures for the same
   alias, not one blended figure or color.
3. **Given** an alias has already exceeded one of its windows, **When** the
   `quota`/`limits` command runs, **Then** that window is visually and
   textually distinguishable from a window that is merely under 10%
   remaining.

---

### User Story 2 - Per-Alias Quota/Limits Detail (Priority: P2)

An operator who just had a launch refused or degraded, or who simply wants
the full picture for one specific alias, asks the `quota`/`limits` command
about that one alias by name and gets the complete detail for every window
it tracks: the exact amount used, the exact amount and percentage
remaining, the raw limit, whether that window's limit has already been
reached, and — for any window that resets — exactly when the next reset
happens (or, for a window that never resets, an explicit statement that it
doesn't).

**Why this priority**: The fleet-wide view (User Story 1) tells the operator
*which* alias needs attention; this view tells them *why*, so they can
decide whether to wait for a reset, switch to a different alias, or escalate
a genuinely exhausted subscription. It depends on the same data User Story 1
collects, so it is naturally second.

**Independent Test**: Pick one configured alias, run the `quota`/`limits`
command scoped to just that alias, and confirm the response contains every
window that alias's account/provider actually tracks, each with used
amount, limit, percentage remaining, hit/not-hit status, and reset time or
"does not reset" — independently of whether the fleet-wide view or
honest-gap handling is exercised in the same test run.

**Acceptance Scenarios**:

1. **Given** a specific alias with a known weekly limit and a known reset
   day, **When** the operator asks for that alias's quota/limits by name,
   **Then** the output states the exact amount used, the exact amount and
   percentage remaining, the raw limit, and the exact time of the next
   reset.
2. **Given** a specific alias whose account-level subscription itself has
   been suspended (not just one window exhausted), **When** the operator
   asks for that alias's quota/limits, **Then** the output clearly states
   that the whole account/subscription is blocked, distinct from a single
   exhausted window.
3. **Given** a specific alias with a fixed, non-resetting lifetime quota,
   **When** the operator asks for that alias's quota/limits, **Then** the
   output explicitly states that this window does not reset, rather than
   omitting reset information or inventing a reset date.

---

### User Story 3 - Honest Reporting When A Provider Exposes Nothing (Priority: P3)

An operator has an alias backed by a provider that simply does not publish
any usage or quota endpoint. Rather than that alias being silently absent
from the report, or shown with a fabricated percentage and a falsely
reassuring green color, the `quota`/`limits` command states plainly that
this provider does not report usage — and does so distinctly from a
transient probe failure (network/auth error), which is also never reported
as if it were a real 0%-remaining or 100%-remaining reading.

**Why this priority**: Without this, the feature's own headline promise —
"no gaps, shortcomings, weak spots" — would be violated by the feature
itself: a confident-looking green bar for an alias nobody actually measured
is a worse outcome than no feature at all, because it actively misleads the
operator at the exact moment they're relying on it. This depends on the
reporting machinery from User Stories 1 and 2 already existing, so it is
third.

**Independent Test**: Configure one alias backed by a provider with no
known usage endpoint and (separately) simulate one alias whose usage probe
fails transiently; run the `quota`/`limits` command and confirm the two are
reported with distinct, honest statuses, and that neither is colored or
worded as if a genuine measurement had succeeded.

**Acceptance Scenarios**:

1. **Given** an alias backed by a provider with no documented usage
   endpoint, **When** the `quota`/`limits` command runs, **Then** that
   alias is shown with an explicit "not reported by provider" status, not a
   numeric percentage or a color implying a real measurement.
2. **Given** an alias whose usage probe fails due to a transient error
   (timeout, network failure, expired credential), **When** the
   `quota`/`limits` command runs, **Then** that alias is shown with an
   explicit probe-failure status, distinct from both "not reported by
   provider" and from any real percentage reading.
3. **Given** the same command invocation reports some aliases with real
   percentages, some as "not reported", and some as "probe failed", **When**
   the operator reviews the output, **Then** all three categories are
   unambiguous from each other in both colored and color-stripped output.

---

### Edge Cases

- What happens when an alias's provider exposes a session window but not a
  daily or weekly one (or any other partial combination)? Only the windows
  that genuinely exist for that alias are shown; no placeholder windows.
- What happens when color output is stripped (piped to a file, redirected,
  or a terminal without color support)? Every severity level communicated
  by color must also be unambiguous from the plain text alone.
- What happens when cached usage data is shown instead of a fresh probe
  (e.g., to avoid hammering a provider's API on repeated invocations)? The
  output must disclose that the data is cached and how old it is.
- What happens when two different windows for the same alias disagree in
  severity (e.g., weekly green, daily red)? Both are shown and colored
  independently; the alias as a whole is never reduced to one blended
  status.
- What happens for a native account (OAuth-based, not a bare API key) whose
  authentication session itself has expired, as opposed to the account's
  usage quota being exhausted? These are different failure states and must
  be reported as such, not conflated.
- What happens when the operator asks for quota/limits info on an alias
  name that does not exist / is not currently configured? The command
  reports that plainly rather than returning an empty or misleading
  success.
- What happens when one alias's provider is slow to respond in a
  fleet-wide run? That alias alone is held to its bounded per-provider
  timeout and, if it does not answer in time, reported as a probe failure
  (FR-010); every other alias finishes and is reported on its own time,
  and the command as a whole never waits on the slow provider past that
  bound (FR-017).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The System MUST provide a quota/limits-reporting subcommand on
  every CLI entrypoint this toolkit already exposes for alias/account
  management (at minimum the entrypoints that today support
  `list`/`verify`-style subcommands for native accounts and for provider
  aliases), invoked the same way as this toolkit's other existing
  subcommands. This subcommand MUST be reachable under **both** the name
  `quota` and the name `limits`, as fully equivalent synonyms with
  identical behavior — **not** under the name `usage`, which collides with
  this codebase's existing `usage()` help-text convention. Neither `quota`
  nor `limits` may collide with any existing subcommand, function, flag, or
  environment-variable prefix in any entrypoint this feature touches.
- **FR-002**: Running `quota` (or, equivalently, `limits`) with no further
  argument MUST report usage for every currently known alias in one pass —
  every native account and every provider alias this toolkit currently
  recognizes, regardless of family — with none silently omitted.
- **FR-003**: Running `quota <alias>` (or, equivalently, `limits <alias>`)
  MUST report the same information scoped to just that one named alias, and
  MUST state plainly (not fail silently or ambiguously) when the named
  alias does not exist.
- **FR-004**: For each alias, the System MUST report, independently, every
  usage window that alias's underlying account/provider actually exposes —
  current-session, daily, weekly, and/or the account's overall
  subscription/lifetime limit — and MUST NOT collapse multiple distinct
  windows into one blended figure.
- **FR-005**: For each reported window, the System MUST state: the exact
  amount used, the exact amount remaining, the percentage remaining (at the
  provider's own reporting precision — never rounded in a way that would
  hide a sub-10% state as a higher figure), and the raw limit value itself
  (e.g. a token count, a request count, a currency amount, or whatever unit
  the provider itself reports in).
- **FR-006**: For each reported window that has an expiration/reset, the
  System MUST state exactly when it resets; for a window that has no reset
  (a fixed/lifetime quota), the System MUST say so explicitly rather than
  omitting reset information or inventing a date.
- **FR-007**: The System MUST clearly flag when a window's limit has
  already been reached or exceeded, and this state MUST be distinguishable
  from "merely under 10% remaining."
- **FR-008**: The System MUST color each reported percentage-remaining
  figure using this exact scale: 30%–100% remaining is colored green,
  under 30% down to 10% remaining is colored yellow, and under 10%
  remaining is colored red; a window whose limit is already reached or
  exceeded MUST use a visibly more severe treatment than the 0–10% red
  bucket, never blended with it.
- **FR-009**: When an alias's underlying provider/account exposes no
  usage-reporting capability at all, the System MUST report that fact
  honestly and distinctly (an explicit "not reported by provider" status)
  and MUST NEVER substitute an estimate, a guess, or a default
  percentage/color in place of real provider data.
- **FR-010**: When a usage probe fails (network error, authentication
  failure, timeout, or any other transient condition) rather than
  succeeding with a genuine value, the System MUST report that failure as a
  failure — distinct from both "0% remaining" and "not reported by
  provider" — and MUST NOT color or present that alias as though real data
  were obtained.
- **FR-011**: The System MUST distinguish a hard, whole-account/subscription
  -level stop (the account itself is blocked, not merely one window
  exhausted) from a single exhausted window, and state explicitly which
  case applies.
- **FR-012**: The coloring shown and the numbers shown MUST always be based
  on the same underlying data within one invocation. If cached (rather than
  freshly probed) data is ever used, the output MUST disclose that it is
  cached and how stale it is.
- **FR-013**: The command's output MUST remain fully legible with color
  stripped (e.g., redirected or piped output, or a terminal without color
  support) — every severity communicated by color MUST also be communicated
  unambiguously in the plain text itself.
- **FR-014**: The feature MUST be covered by every test type this project's
  existing test suite already applies to comparable alias/provider-reporting
  commands, including hermetic sandboxed behavioral tests and a live
  end-to-end verification run against the real, installed toolkit, and
  these tests MUST read their assertions from the `--json` output (FR-016)
  rather than parsing colored or human-formatted text. Test coverage MUST
  explicitly assert that neither `quota` nor `limits` collides with any
  pre-existing subcommand, function, or flag (regression guard for the
  naming decision in FR-001).
- **FR-015**: Every existing documentation surface that already documents
  alias/provider subcommands (README, user guides, manuals, FAQs, and any
  other existing material covering this toolkit's provider/account
  commands) MUST be updated to document `quota`/`limits`, and any genuinely
  new explanatory material this feature requires MUST be written rather
  than left missing.
- **FR-016**: The System MUST support a `--json` flag on `quota`/`limits`
  (in both its fleet-wide and single-alias forms) that emits the exact same
  underlying data as structured, machine-parseable JSON — one record per
  alias, each listing every window it reports (or its honest "not reported
  by provider" / probe-failure status) — mirroring this toolkit's existing
  `--json` convention (e.g. `llmctl plan --json`). The colored/plain-text
  rendering and the `--json` rendering MUST always agree, because both are
  derived from the same underlying data within one invocation (FR-012);
  `--json` output carries the severity classification (green/yellow/red/
  limit-exceeded) as plain data fields, not ANSI color codes, so automated
  tests and scripts never need to parse colored or human-formatted text.
- **FR-017**: In a fleet-wide run, the System MUST probe every alias's
  provider concurrently rather than one at a time, with a short, bounded
  per-provider timeout. A single slow or unresponsive provider MUST
  degrade only that alias to the probe-failure status (FR-010) and MUST
  NOT delay or block the reporting of any other alias. The command's total
  wall-clock time MUST stay bounded by the per-provider timeout, not by
  the number of aliases being reported on.

### Key Entities

- **Alias**: An already-existing launchable identity this toolkit manages —
  either a native account (its own OAuth/session-based family) or a
  provider alias (API-key-backed). This feature reports on aliases; it does
  not create or change them.
- **Usage Window**: One countable budget period an underlying account or
  provider tracks for an alias (current session, daily, weekly, or the
  overall subscription/lifetime). Each window has an amount used, a limit,
  a percentage remaining, a hit/not-hit state, and either a reset time or
  an explicit "does not reset" statement.
- **Usage Report**: The complete set of Usage Windows known for one alias
  at the moment the `quota`/`limits` command runs, or — when no window
  could be determined — an explicit, honest status explaining why (not
  reported by the provider, or a probe failure).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A single invocation of the `quota`/`limits` command with no
  arguments reports on 100% of the operator's currently configured aliases,
  with zero aliases silently missing from the output.
- **SC-002**: For every alias whose provider exposes real usage data, the
  percentage-remaining figure shown matches the precision the provider
  itself reports, with zero cases of a sub-10% state being displayed at a
  higher, falsely reassuring percentage or color.
- **SC-003**: 100% of aliases whose provider exposes no usage data are shown
  with an explicit "not reported" status; zero are shown with a fabricated
  or estimated percentage.
- **SC-004**: Every usage window that has reached or exceeded its limit is
  distinguishable from a window merely under 10% remaining, verified in
  both colored and color-stripped output.
- **SC-005**: Every claim made in this feature's documentation, tests, or
  release notes that usage is "now visible" is backed by a captured run of
  the command against a live, installed copy of the toolkit — never a
  code-reading inference alone.
- **SC-006**: Zero regressions are introduced in any existing subcommand,
  function, or flag on any CLI entrypoint this feature touches, verified by
  the existing test suite continuing to pass unmodified for behavior this
  feature did not intend to change.
- **SC-007**: Every field this feature's own automated tests assert on is
  read from the `--json` output, with zero tests parsing colored or
  human-formatted text to derive a pass/fail verdict.
- **SC-008**: With one alias's provider simulated as slow/unresponsive, the
  command's total run time is independent of how many OTHER aliases are
  configured, and every other alias's real status is still reported
  — demonstrating that one slow provider never blocks the rest of the
  report.

## Assumptions

- Which specific usage data any given native account or provider actually
  exposes is decided entirely by that account's/provider's own API, not by
  this toolkit. Where a provider or native account genuinely offers no
  usage/quota endpoint at all, this feature reports that absence honestly
  (FR-009) rather than estimating from local token counts, conversation
  logs, or any other proxy signal — consistent with this project's existing
  anti-bluff convention of reporting `verified` / `unverified` / honest
  `skip` states rather than guessing.
- "Native aliases" means this toolkit's own account families (for example
  its Claude-family and Kimi-family native accounts), each authenticated
  through its own OAuth/session mechanism rather than a bare API key.
  "Providers" means the API-key-backed aliases this toolkit already
  resolves and launches today, across every family it currently supports.
  Any future alias family this toolkit adds is expected to be covered by
  the same `quota`/`limits` contract, not a special case.
- The `quota`/`limits` command is read-only: it never mutates an alias's
  configuration, verification status, or stored credentials — it only
  reports on state that already exists.
- A short-lived cache for usage data (mirroring the caching this toolkit
  already applies to other per-provider state) is an acceptable default to
  avoid hammering a provider's API on every invocation, provided the
  command always discloses when it is serving cached data and how stale it
  is (FR-012). An operator-facing way to force a fresh probe is expected but
  left to the planning phase to name.
- The live-testing, documentation, and dual-forge (GitHub + GitLab CLI)
  release steps described in the originating request are delivery/process
  requirements for shipping this feature, not functional capabilities of
  the `quota`/`limits` command itself. They are captured here through this
  spec's Success Criteria (SC-005 in particular) and are expected to be
  carried out through this project's existing plan/tasks/implementation/
  release workflow, the same way this project's prior features have been
  released.
