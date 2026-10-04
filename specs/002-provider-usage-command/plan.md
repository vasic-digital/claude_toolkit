# Implementation Plan: Universal Alias Quota/Limits Reporting

**Branch**: `002-provider-usage-command` | **Date**: 2026-10-04 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `specs/002-provider-usage-command/spec.md`

## Summary

Add a `quota`/`limits` subcommand (two fully equivalent names, never `usage`)
to every alias-management CLI entrypoint this toolkit exposes
(`claude-providers`, `kimi-providers`), reporting every usage window
(session/daily/weekly/subscription) each native account (`claudeN`/`kimiN`)
and provider alias actually exposes — exact used/remaining/percentage/limit,
reset time or "does not reset", color-coded green/yellow/red with a
visually distinct limit-exceeded state, a `--json` machine-readable
twin of the same data, and honest "not reported by provider" /
"probe failed" statuses that are never confused with a real reading.

Technical approach: extend this project's own existing declarative
balance-endpoint pattern (`scripts/providers/credit-endpoints.json` +
`model_verify.py`'s `probe_balance_endpoint`/`_dig`/`_walk` JSON-signal
walker) from a binary funded/not-funded verdict to a richer numeric
usage-window extraction, add a new versioned/TTL'd cache mirroring
`load_credit_cache`/`save_credit_cache`, reuse this project's existing
bounded-concurrency batch-probe pattern (`claude-providers.sh`'s
per-profile llmctl probe loop) for fan-out across many aliases, and add a
new bash rendering layer (color/plain/JSON) with no prior art in this
codebase to build from scratch.

## Technical Context

**Language/Version**: Bash (POSIX-leaning, macOS stock bash 3.2 compatible
per this repo's own portability rule) for CLI dispatch, rendering, and
concurrency orchestration; Python 3 for the HTTP-probing/JSON-signal-walking
layer — matching this project's existing split (`claude-providers.sh`
orchestrates, `model_verify.py`/`providers_resolve.py` do structured
HTTP/JSON work).
**Primary Dependencies**: `jq` (JSON construction/parsing in bash), `curl`
(HTTP probes), Python 3 standard library only (`model_verify.py` already
has zero third-party dependencies — this feature introduces none either).
**Storage**: Flat JSON files under `~/.local/share/claude-multi-account/
providers/` (this toolkit's existing per-provider state directory,
`cma_providers_dir()`), consistent with `status.json` and the existing
credit cache; no database.
**Testing**: This project's own hermetic bash test harness
(`tests/lib/assert.sh` + `tests/lib/sandbox.sh` + `make_sandbox` +
`sandbox_stub`), run via `scripts/tests/run-all.sh`; Python-side unit
tests via embedded `python3 -c` blocks inside bash test files that
monkeypatch `model_verify.http_get_json`/`http_post_json` at module level
(the exact pattern `scripts/tests/test_provider_credit.sh` already uses);
a live end-to-end leg added to `scripts/claude-release-gate.sh` /
`scripts/tests/run-proof.sh`.
**Target Platform**: Linux + macOS (this toolkit's two supported
platforms); no Windows support (none exists elsewhere in this toolkit).
**Project Type**: Single bash+Python CLI toolkit (no frontend/backend
split) — this feature is additive subcommands + a probing library inside
the existing `scripts/` tree.
**Performance Goals**: Fleet-wide `quota`/`limits` with no argument
completes in bounded time independent of alias count (FR-017/SC-008) —
total wall-clock time is bounded by the per-provider timeout (a short,
single-digit-second budget, named precisely in research.md), not by
`N_aliases × timeout`, achieved via the same bounded-concurrency batch
pattern this codebase already uses for llmctl profile probing.
**Constraints**: Zero new runtime dependencies beyond what this toolkit
already requires (`jq`, `curl`, Python 3, bash); read-only (never mutates
alias config/credentials); must not collide with any existing subcommand,
function, flag, or env-var prefix (FR-001, mechanically tested); must
degrade honestly rather than guess when a provider exposes no usage data
(FR-009/FR-010) — no heuristic fallback the way `run_credit_probe`'s
paid-model-probe is a fallback for binary credit, because no single
completion call can honestly reveal an exact remaining-percentage.

## Constitution Check

*GATE: Must pass before proceeding. Re-check after design phase.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Anti-Bluff | PASS | FR-009/FR-010/SC-003 make the honest "not reported"/"probe failed" paths first-class, tested states — never a fabricated percentage or color. The feature's own tests must themselves produce captured evidence (live leg output under `scripts/tests/proof/`), not a grep-only pass. |
| II. No-Guessing + Investigate-Before-Acting | PASS | Native-account (claudeN/kimiN) live usage data was investigated directly (checked `claude --help`/`kimi --help` for a usage/billing/status subcommand — none exists; inspected `~/.claude.json` recursively for cached usage/limit/rate fields — only a plan-TIER name and unrelated feature-flag budgets exist, never a live remaining-quota number) rather than guessed; the research task to find a genuine live endpoint is explicitly deferred to an implementation-phase spike, not invented here. |
| III. Git, Multi-Remote & Data Safety | PASS | No force-push; all commits fast-forward-merged and pushed to every configured upstream, as this project has done throughout. |
| IV. Host & Resource Safety | PASS | No process signalling, no host-level mutation; concurrency is bounded (FR-017) using this project's existing batch-wait pattern, not an unbounded fan-out. |
| V. Test-First, Real-System Testing | PASS | Unit tests (Python JSON-signal-walker, bash arg-parsing/rendering) use mocks only at that layer (constitution-compliant); the live end-to-end leg (`claude-release-gate.sh`) exercises real configured provider aliases with no mocking. |
| VI. Independent Code Review | PASS (procedural) | Every change passes independent review at Opus `xhigh` before acceptance, per this project's standing practice — enforced at implementation/review time, not at planning time. |
| VII. Documentation, Diagrams, Always-In-Sync | PASS | FR-015 requires updating `docs/Provider_Aliases_User_Guide.md`(+html/docx/pdf), `docs/Provider_FAQ.md`, `docs/Provider_Verification_Guide.md`, `docs/diagrams/provider-aliases.md` (+ a new quota/limits-flow diagram), and `README.md`'s commands section — all reachable from the README per this project's doc-chain rule. |
| VIII. Workable-Item Integrity | N/A (this feature) | No workable-item tracking system changes needed. |
| IX. Submodule & Dependency Discipline | PASS | Zero new dependencies, no submodule touched. |
| X. Autonomous, Multi-Track & Subagent-Driven Execution | PASS (procedural) | Task decomposition (`/speckit.tasks`) will mark independent work streams `[SUBAGENT]`. |
| XI. Release, Deployment & Supply-Chain | PASS (procedural) | Release follows this project's existing fetch→verify-ff→push→tag→dual-forge-release workflow, per spec Assumptions. |
| XII. Secrets & Credentials | PASS | The probe reads real API keys the SAME way `cma_run_provider`/`providers-semantic.sh` already do (sourced via `CMA_PROVIDER_KEYVAR` indirection, never printed/logged); quota/limit NUMBERS are not secrets and are shown freely, but the key VALUE itself is never echoed, matching this project's existing redaction discipline (`model_verify.py`'s `redact()`). |
| XIII. UI/UX, Accessibility | PASS | This is a CLI, not a UI-shipping surface (OpenDesign does not apply); FR-013's color-stripped legibility requirement is this feature's own accessibility-equivalent discipline. |
| XIV. Code Intelligence | PASS | No CodeGraph/Lumen index changes needed beyond normal re-sync after new files land. |
| XV. Governance-Corpus Self-Custody | N/A (this feature) | No constitution anchors added/changed. |

No violations requiring justification — Complexity Tracking table is empty.

## Project Structure

### Documentation (this feature)

```text
specs/002-provider-usage-command/
├── spec.md                      # Feature specification (done)
├── plan.md                      # This file
├── research.md                  # Phase 0 output
├── data-model.md                # Phase 1 output
├── quickstart.md                # Phase 1 output
├── contracts/
│   ├── quota-limits-cli-contract.md       # CLI surface: flags, exit codes, output shape
│   └── quota-endpoint-spec-contract.md    # providers/quota-endpoints.json schema
├── checklists/
│   └── requirements.md          # Spec quality checklist (done)
└── tasks.md                     # /speckit.tasks output (not yet generated)
```

### Source Code (repository root)

```text
scripts/
├── claude-providers.sh          # MODIFIED: new `quota`/`limits` dispatch case,
│                                 #   cmd_quota() orchestration, rendering calls
├── kimi-providers.sh            # UNCHANGED (thin exec-through wrapper; the new
│                                 #   subcommand reaches it automatically — see
│                                 #   research.md decision on the wrapper's `*)`
│                                 #   passthrough)
├── lib.sh                       # MODIFIED: new shared helpers — color-severity
│                                 #   renderer, NO_COLOR/isatty detection,
│                                 #   native-account tier-name reader
├── quota_probe.py               # NEW: HTTP probing + JSON-signal-walking for
│                                 #   usage windows (used/remaining/limit/reset),
│                                 #   extending model_verify.py's _dig/_walk
│                                 #   primitives; versioned/TTL'd quota cache
├── providers/
│   └── quota-endpoints.json     # NEW: declarative per-provider usage-window
│                                 #   endpoint specs (sibling to
│                                 #   credit-endpoints.json, richer signal types)
└── tests/
    ├── test_quota_cli.sh        # NEW: bash-level dispatch/arg-parsing/
    │                             #   collision-regression tests (hermetic)
    ├── test_quota_rendering.sh  # NEW: color/plain/JSON rendering + threshold
    │                             #   boundary tests (hermetic)
    ├── test_quota_probe.sh      # NEW: Python signal-walker unit tests
    │                             #   (monkeypatched HTTP, matching
    │                             #   test_provider_credit.sh's convention)
    └── test_quota_concurrency.sh # NEW: bounded-concurrency + per-provider
                                  #   timeout isolation tests (hermetic,
                                  #   simulated slow provider)

docs/
├── Provider_Aliases_User_Guide.md   # MODIFIED (+ .html/.docx/.pdf re-export)
├── Provider_FAQ.md                  # MODIFIED
├── Provider_Verification_Guide.md   # MODIFIED (cross-reference only)
├── diagrams/
│   ├── provider-aliases.md          # MODIFIED (cross-reference to new diagram)
│   └── quota-limits-flow.mmd/.svg   # NEW

README.md                            # MODIFIED: "Daily commands" section
```

**Structure Decision**: Single-project bash+Python CLI layout (no
src/models/services split — this is not that kind of project). All new
code lands inside the existing `scripts/` tree, following the established
split: bash owns CLI surface/dispatch/rendering/concurrency orchestration,
Python owns structured HTTP calls and JSON-signal extraction, exactly
mirroring how `providers_resolve.py`/`model_verify.py` already relate to
`claude-providers.sh`. No new top-level directories.

## Execution Strategy

### TDD Requirements

- [x] **Signal-walking extraction logic** (`quota_probe.py`): strict
      RED→GREEN→REFACTOR. Many edge cases (missing field, null vs. zero,
      negative remaining, multiple windows in one response) make this the
      highest-risk, highest-value TDD target, mirroring why
      `probe_balance_endpoint` itself has a dedicated test file.
- [x] **Threshold/coloring logic** (green ≥30%, yellow 30–10%, red <10%,
      limit-exceeded as a distinct fifth state): strict TDD — an
      off-by-one at a boundary (exactly 30%, exactly 10%, exactly 0%) is
      exactly the class of bug a test-first boundary table catches and a
      hand-verified "looks right" pass does not.
- [x] **Collision regression guard** (FR-001: neither `quota` nor `limits`
      may collide with any existing subcommand/function/flag): TDD — write
      the enumerate-and-diff test FIRST, confirm it fails before the new
      dispatch case exists (proving it would have caught a real collision),
      then add the dispatch case.
- [ ] **Rendering/formatting** (column alignment, JSON shape): standard
      test-first, not called out separately — same discipline, lower
      novel-edge-case risk than the three above.

### Parallel Execution Opportunities

- [ ] **`quota_probe.py`'s signal-walker extension** and **the new color/
      plain/JSON renderer in `lib.sh`** have no shared files and no
      dependency on each other — both consume the same abstract "Usage
      Window" data shape (data-model.md), neither needs the other to exist
      first. Dispatchable in parallel.
- [ ] **The 4 new test files** (`test_quota_cli.sh`, `test_quota_rendering.sh`,
      `test_quota_probe.sh`, `test_quota_concurrency.sh`) are independent
      files with non-overlapping scope and can be written in parallel once
      their respective implementation targets exist.
- [ ] **Documentation updates** (user guide, FAQ, diagram, README) can
      proceed in parallel with implementation once the CLI contract
      (`contracts/quota-limits-cli-contract.md`) is frozen, since docs
      describe the CONTRACT, not the internals.
- [ ] The **bounded-concurrency orchestration** in `claude-providers.sh`
      depends on the per-alias probe function already existing (either
      real or a test stub) — not parallelizable with the probe itself, but
      IS parallelizable with rendering/docs work.

### Human Checkpoints

1. After the CLI contract (`contracts/quota-limits-cli-contract.md`) and
   `quota-endpoints.json` schema contract are drafted — verify the exact
   flag names, output shape, and the collision-freedom claim against the
   real dispatch tables before any implementation code is written.
2. After the collision-regression test is written and observed to fail
   for the right reason (RED) — confirm it actually would have caught the
   `usage`-vs-`usage()` collision this spec's own clarification surfaced,
   before trusting it as a permanent regression guard.
3. After each user story's acceptance scenarios pass against the real,
   installed toolkit (not just the hermetic suite) — per the original
   request's explicit "full LIVE testing... on LIVE installed latest
   Claude Toolkit codebase" requirement.
4. Before the dual-forge (GitHub + GitLab CLI) release — final review
   against spec.md's Success Criteria, all eight, with pasted command
   output as evidence for each.

### Review Gates

- [ ] **`providers/quota-endpoints.json` schema + `quota_probe.py`'s
      signal-walker**: review before any provider entries are added past
      the first proof-of-concept one — this is the extensibility contract
      every future provider entry depends on getting right once.
- [ ] **Collision-regression test + the dispatch-table change itself**:
      review before merge — this is the one guarantee the entire naming
      clarification rests on.
- [ ] **Native-account "not reported" + tier-name-context decision**:
      review before implementation — confirm the honest-absence framing
      reads as informative, not as a bug, to someone seeing it cold.

## Complexity Tracking

*No violations — table intentionally empty.*
