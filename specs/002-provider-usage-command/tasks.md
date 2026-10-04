# Tasks: Universal Alias Quota/Limits Reporting

**Input**: Design documents from `specs/002-provider-usage-command/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md — all present and read before this breakdown was written.

**Tests**: Explicitly REQUIRED for this feature — spec.md's FR-014 and plan.md's Execution Strategy mandate TDD for specific components; this is not the template's optional default.

**Organization**: Tasks are grouped by user story (US1/US2/US3, matching spec.md's priorities) after a Setup and Foundational phase, then Polish. Every task names its exact file(s); no task references a type, function, or field not already defined in data-model.md, contracts/, or an earlier task.

## Format: `[ID] [P?] [TDD?] [REVIEW?] [SUBAGENT?] [Story] Description`

- **[P]**: Different file(s), no dependency on a sibling task in the same batch — safe to run concurrently.
- **[TDD]**: Write the failing test first, confirm it fails for the right reason, then implement, then confirm it passes.
- **[REVIEW]**: Pause for independent review (Opus `xhigh`, per constitution Principle VI) before the next task that depends on this one starts.
- **[SUBAGENT]**: Self-contained enough to dispatch to a fresh subagent with no prior context beyond this task's own description.
- **[Story]**: `US1`/`US2`/`US3`/`SETUP`/`FOUND`/`POLISH`.

## Review Focus (five scenarios most likely to bite, each owned by a named task below)

1. **Exact threshold boundaries** (30%, 10%, 0%/negative remaining) — owned by `T007`/`T008`.
2. **A real collision slipping past a hand-picked "list of what we thought of"** — owned by `T011` (enumerates the dispatch tables programmatically, not from memory).
3. **One slow provider stalling the entire fleet report** — owned by `T017`.
4. **A provider with no endpoint entry at all being silently dropped from the report, or a provider whose probe genuinely fails being shown as if it succeeded with zero** — owned by `T028`/`T029`.
5. **The colored and `--json` renderings disagreeing on the same data within one invocation** (FR-012) — owned by `T020`.

---

## Phase 1: Setup

- [x] **T001 [SETUP]** Create `scripts/providers/quota-endpoints.json` with the `_comment` documentation array (mirroring `scripts/providers/credit-endpoints.json`'s own `_comment` style) and exactly one real entry — `openrouter` — using the full worked example from `contracts/quota-endpoint-spec-contract.md`'s "Worked example" section verbatim (url `https://openrouter.ai/api/v1/key`, `auth: bearer`, one `subscription` window with `amount_remaining`/`limit_total`/`amount_used`/`unit_literal` signals). This is the one real fixture every later probing test and the live quickstart validation (Scenario 1/5) depends on existing.
  - **Files**: Create `scripts/providers/quota-endpoints.json`.

---

## Phase 2: Foundational (blocks all user stories)

**⚠️ CRITICAL**: No user story task may start until every task in this phase is done.

- [x] **T002 [TDD] [FOUND]** Write `scripts/tests/test_quota_probe.sh` with the FIRST failing test: given a fixture `quota-endpoints.json` entry (literally the `openrouter` entry from T001) and a monkeypatched `model_verify.http_get_json` returning `(200, {"data": {"limit_remaining": 52.68, "limit": 100.0, "usage": 47.32}})`, calling the new `quota_probe.resolve_window(entry["windows"][0], body)` (a function that does not exist yet) returns a dict with `amount_remaining=52.68`, `limit_total=100.0`, `amount_used=47.32`, `unit="credits"`, `percent_remaining=52.68` (derived: `100*52.68/100.0`, since OpenRouter's example has no direct `percent_remaining` signal), `resets=False`, `reset_at=None`. Use the exact monkeypatch pattern from `scripts/tests/test_provider_credit.sh:609-610` (`mv.http_get_json = lambda *a, **k: (status, body)`, but against the new module).
  - Run it, confirm it fails with `ImportError`/`AttributeError: module 'quota_probe' has no attribute 'resolve_window'` (the RIGHT failure reason — proves the test is wired to a real, not-yet-existing target, not silently vacuous).
  - **Files**: Create `scripts/tests/test_quota_probe.sh`.

- [x] **T003 [TDD] [FOUND]** Implement `scripts/quota_probe.py`'s `resolve_window(window_spec, body)` to make T002 pass: import `_dig`, `_walk`, `_dig_bool` directly from `model_verify` (`from model_verify import _dig, _walk, _dig_bool` — research.md §3's explicit "import, don't copy" decision); walk `window_spec["signals"]` once per `type` needed, applying resolution rules 1–6 from `contracts/quota-endpoint-spec-contract.md` exactly: derive the missing one of `amount_used`/`amount_remaining`/`limit_total` when two of three resolve (rule 2); use a provider-direct `percent_remaining` signal verbatim when present, else derive `100 * amount_remaining / limit_total` (rule 4); convert `reset_in_seconds` to an absolute `reset_at` at call time (rule 5); drop the window (return `None`) when neither `amount_remaining` nor `limit_total` resolves, or when no unit resolves (rules 3 and 6). Run T002 again, confirm it passes.
  - **Files**: Create `scripts/quota_probe.py`.
  - **Interfaces — Produces**: `resolve_window(window_spec: dict, body: dict) -> dict | None`, returning the exact field set from data-model.md §4 (`window`, `amount_used`, `amount_remaining`, `limit_total`, `unit`, `percent_remaining`, `resets`, `reset_at` — NOT yet `severity`, assigned later by T010).

- [x] **T004 [TDD] [FOUND]** Extend `scripts/tests/test_quota_probe.sh` with a second test: a `window_spec` whose ONLY present signal is `amount_used` (no `amount_remaining`/`limit_total` in the fake response body) — assert `resolve_window(...)` returns `None` (rule 3's "drop the window, never a placeholder" guarantee). A third test: a `window_spec` with a present `reset_in_seconds: 3600` signal — assert the returned `reset_at` is an ISO-8601 string `3600` seconds after a frozen/injected "now" (inject the clock via a monkeypatched `time.time` or `datetime.now`, never a real sleep). Confirm both fail for the right reason before T003 covers them (they were written against the already-passing T003 code, so immediately write them as failing-then-fix in the same commit as T003 if sequencing makes that cleaner — either order is acceptable as long as each is independently observed red before green).
  - **Files**: Modify `scripts/tests/test_quota_probe.sh`.

- [x] **T005 [TDD] [FOUND]** Write a failing test in `scripts/tests/test_quota_probe.sh` for the cache: `quota_probe.load_quota_cache(path)` on a non-existent path returns `{"_cache_version": QUOTA_CACHE_VERSION, "providers": {}}`; on a path whose `_cached_at` is older than `QUOTA_CACHE_TTL_SECONDS` also returns the empty shape (never partially trusted) — mirror `model_verify.py:908-925`'s `load_credit_cache` test shape exactly, against the new quota-specific functions and constants. Confirm it fails (`AttributeError`).
  - **Files**: Modify `scripts/tests/test_quota_probe.sh`.

- [x] **T006 [FOUND]** Implement `quota_probe.load_quota_cache(path)` / `quota_probe.save_quota_cache(path, data)` in `scripts/quota_probe.py`, copying the exact shape of `model_verify.py:908-934`'s `load_credit_cache`/`save_credit_cache`: own `QUOTA_CACHE_VERSION` constant; own `QUOTA_CACHE_TTL_SECONDS` constant, set to `CREDIT_CACHE_TTL_SECONDS / 4` (read `model_verify.CREDIT_CACHE_TTL_SECONDS`'s actual current value at implementation time and divide by 4 — a concrete, mechanical rule, not an open judgment call — per research.md §4's "quota data should default to a shorter TTL" decision), recorded in this file's own module docstring with that exact arithmetic as the rationale. Run T005, confirm it passes.
  - **Files**: Modify `scripts/quota_probe.py`.
  - **Interfaces — Produces**: `load_quota_cache(path: str) -> dict`, `save_quota_cache(path: str, data: dict) -> None`, module constants `QUOTA_CACHE_VERSION: int`, `QUOTA_CACHE_TTL_SECONDS: int`.

- [x] **T007 [P] [TDD] [FOUND]** Write `scripts/tests/test_quota_rendering.sh` (hermetic, `make_sandbox` + `source lib.sh`, matching this project's standard test-file header) with a boundary-value table as the FIRST failing tests against a not-yet-existing `_cma_quota_severity` bash function: `percent_remaining=100 → green`, `=30 → green` (inclusive), `=29.99 → yellow`, `=10 → yellow` (inclusive), `=9.99 → red`, `=0.01 → red`, `=0 → limit_exceeded`, `=-5 → limit_exceeded` (negative remaining still classifies, never undefined — data-model.md §4's severity rule). Confirm every case fails (`command not found: _cma_quota_severity`).
  - **Files**: Create `scripts/tests/test_quota_rendering.sh`.
  - Can run in parallel with T002–T006 — different files, no shared dependency (plan.md's Execution Strategy: color renderer and probe have no dependency on each other).

- [x] **T008 [FOUND]** Implement `_cma_quota_severity(percent_remaining)` in `scripts/lib.sh` (alongside the existing `cma_log`/`cma_warn`/`cma_err` block, `scripts/lib.sh:47-50`): echoes one of `green`/`yellow`/`red`/`limit_exceeded` per the exact FR-008 boundary table (the `<= 0` check for `limit_exceeded` MUST be evaluated before the percentage thresholds, so a negative value never falls through to a percentage comparison). Run T007, confirm all 8 cases pass.
  - **Files**: Modify `scripts/lib.sh`.
  - **Interfaces — Produces**: `_cma_quota_severity "<percent_remaining>"` → stdout one of `green|yellow|red|limit_exceeded`.

- [x] **T009 [P] [TDD] [FOUND]** Extend `scripts/tests/test_quota_rendering.sh` with failing tests for a not-yet-existing `_cma_quota_color_enabled` function: returns `0` (true, color on) only when `[[ -t 1 ]]` is true AND `NO_COLOR` is unset/empty AND no `--json`/`--no-color` flag was passed; returns `1` (false) in every other combination — test all four input combinations explicitly (tty+no-NO_COLOR+no-flag → on; tty+NO_COLOR=1 → off; non-tty → off regardless of NO_COLOR; tty+no-NO_COLOR+`--no-color` → off). Simulate "is a tty" in the hermetic sandbox by redirecting through a pty helper this project's test harness already has access to, or by making the tty-check itself an overridable test seam (e.g. `_cma_quota_color_enabled` accepts an optional `--force-tty`/`--force-no-tty` test-only override, documented as test-only in its own comment) — confirm all four fail first.
  - **Files**: Modify `scripts/tests/test_quota_rendering.sh`.

- [x] **T010 [FOUND]** Implement `_cma_quota_color_enabled` in `scripts/lib.sh` per T009's contract (research.md §6's NO_COLOR/isatty/`--json` gate). Run T009, confirm all four pass.
  - **Files**: Modify `scripts/lib.sh`.
  - **Interfaces — Produces**: `_cma_quota_color_enabled` (exit-code boolean, no stdout).

- [x] **T011 [TDD] [REVIEW] [FOUND]** Write `scripts/tests/test_quota_cli.sh` (new file) with the collision-regression guard as its FIRST test, structured as a genuine RED/GREEN pair per plan.md's Human Checkpoint #2:
  1. Capture, into two bash arrays inside the test, the CURRENT (pre-this-feature) top-level case labels of `claude-providers.sh`'s dispatch (`sync helixllm-export list list-all list-faulty show verify sync-all-llmctl remove prune add migrate-names` — the exact list confirmed in research.md §1) and every bash function name matching `^[a-zA-Z_][a-zA-Z0-9_]*\s*\(\)\s*{` in `claude-providers.sh` + `kimi-providers.sh` + `lib.sh` (via `grep -oE`).
  2. Assert `usage` IS present in the function-name list for both `claude-providers.sh` and `kimi-providers.sh` (proving the test is checking against the REAL pre-existing collision risk, not a straw man).
  3. Assert neither `quota` nor `limits` is present in EITHER the case-label list or the function-name list captured in step 1 — this is the RED state: run it now, before T012, and confirm it PASSES (because nothing has been added yet) — then temporarily and locally (never committed) rename the dispatch case this task is about to add to `usage)` instead of `quota)`/`limits)` in a scratch copy, re-run, and confirm THIS test starts correctly reporting the real tool now has a function/subcommand named `usage` colliding how the spec's clarification predicted — this confirms the test has teeth before trusting it.
  4. Restore the scratch copy; the committed test asserts step 3's "absent before" state only (the "present and non-colliding after" assertion is T012's own test, since it needs the real implementation to exist first).
  - **Files**: Create `scripts/tests/test_quota_cli.sh`.
  - **[REVIEW]**: this test is "the one guarantee the entire naming clarification rests on" (plan.md) — get it reviewed before T012 adds the real dispatch case.

- [x] **T012 [TDD] [FOUND]** Add the `quota`/`limits` case labels to `claude-providers.sh`'s dispatch (`scripts/claude-providers.sh`, immediately after the existing `migrate-names)` line, `scripts/claude-providers.sh:4194` per research.md §1), both calling a new `cmd_quota()` function with `"${POSITIONAL[@]:-}"` (matching the existing calling convention for `show`/`verify`). Implement `cmd_quota()`'s ARGUMENT PARSING ONLY in this task (no probing/rendering yet): accept an optional positional `<alias>`, and flags `--json`, `--fresh`, `--timeout <seconds>`, `--no-color`, in any order (matching how the existing `MULTI`/`DRY_RUN`-style flags are parsed elsewhere in this file); on an unrecognized flag, print an error and return 1 (matching this file's existing unknown-flag convention). For now, `cmd_quota()` ends by printing the parsed values and returning 0 — real orchestration is wired in US1. Extend `scripts/tests/test_quota_cli.sh` with: (a) the "present and non-colliding after" half of T011's assertion (re-run the same enumeration, assert `quota` and `limits` now EACH appear exactly once in the case-label list, and `usage` is UNCHANGED — still present as a function, still printing help text when invoked); (b) argument-parsing tests for each flag and the bare/aliased positional form. Confirm all pass.
  - **Files**: Modify `scripts/claude-providers.sh`, `scripts/tests/test_quota_cli.sh`.
  - **Interfaces — Produces**: `cmd_quota()` (reads `$POSITIONAL`/flags the same way sibling `cmd_*` functions in this file do); not yet wired to real data.

**Checkpoint**: Foundational phase complete — `quota_probe.py`'s extraction+cache, `lib.sh`'s severity+color-gate helpers, and `claude-providers.sh`'s collision-safe dispatch skeleton all exist and are independently tested. User story work can begin.

---

## Phase 3: User Story 1 - Fleet-Wide Quota/Limits At A Glance (Priority: P1) 🎯 MVP

**Goal**: `claude-providers quota` (or `limits`) with no argument reports every currently configured native account and provider alias, each with every usage window it genuinely has, correctly colored, in bounded time.

**Independent Test**: quickstart.md Scenario 1 and Scenario 6 — run `claude-providers quota` against a sandbox with at least one native account and one provider alias (OpenRouter, using T001's fixture), confirm every alias appears exactly once with correct figures/color, and confirm total run time does not scale linearly with alias count.

### Tests for User Story 1

- [x] **T013 [P] [TDD] [US1]** Write a failing test in a new `scripts/tests/test_quota_cli.sh` section: given a sandbox with `.env` files for `deepseek.env` and `kimi-deepseek`-style twin-sharing (both carrying `CMA_PROVIDER_ID=deepseek`, matching the real on-disk convention confirmed in research.md §2), calling a not-yet-existing `_cma_quota_group_accounts` bash function returns exactly ONE provider-account group for `deepseek` whose `alias_names` lists both alias names — proving the de-duplication data-model.md §2 requires, before any probing logic exists.
  - **Files**: Modify `scripts/tests/test_quota_cli.sh`.

- [x] **T014 [P] [TDD] [US1]** Write a failing test in `scripts/tests/test_quota_cli.sh`: given a sandbox with two native-account dirs (`claude1`, `claude2`) each with a distinct fake `.claude.json` carrying a different `oauthAccount.organizationRateLimitTier`, calling a not-yet-existing `_cma_quota_list_native_accounts` function returns TWO separate entries (never de-duplicated — data-model.md §3's "each slot is independently distinct" rule), each carrying its own `plan_tier` string read from its own fake `.claude.json`.
  - **Files**: Modify `scripts/tests/test_quota_cli.sh`.

### Implementation for User Story 1

- [x] **T015 [US1]** Implement `_cma_quota_group_accounts` in `scripts/lib.sh`: enumerate every `$pdir/*.env` (`pdir="$(cma_providers_dir)"`), source each to read `CMA_PROVIDER_ID`, and group alias filenames (the `.env` basename minus `.env`) by that id, producing one record per distinct `CMA_PROVIDER_ID` with its full `alias_names` list — satisfy T013.
  - **Files**: Modify `scripts/lib.sh`.
  - **Interfaces — Produces**: `_cma_quota_group_accounts` → stdout, one JSON object per line (`{"provider_id":..., "alias_names":[...], "base_url":..., "endpoint_spec_present":...}`), `endpoint_spec_present` computed by checking whether `scripts/providers/quota-endpoints.json` has a top-level key matching `provider_id`.

- [x] **T016 [US1]** Implement `_cma_quota_list_native_accounts` in `scripts/lib.sh`: enumerate every native account dir this toolkit already detects (reuse `cma_detect_accounts`'s existing detection, never re-derive it), and for each, attempt to read `oauthAccount.organizationRateLimitTier` from that account's own `.claude.json` (or the Kimi-family equivalent field — confirm during this task whether an analogous field exists in a real Kimi account's config by inspecting one; if none is found, `plan_tier` is `null` for Kimi accounts, honestly, not guessed) — satisfy T014.
  - **Files**: Modify `scripts/lib.sh`.
  - **Interfaces — Produces**: `_cma_quota_list_native_accounts` → stdout, one JSON object per line (`{"account_id":..., "family":"claude"|"kimi", "plan_tier": <string|null>}`).

- [x] **T017 [TDD] [SUBAGENT] [US1]** Write a failing test, then implement, the bounded-concurrency orchestration function `_cma_quota_probe_all` in `scripts/claude-providers.sh`, reusing the EXACT batch pattern from `scripts/claude-providers.sh:2140-2270` (research.md §5): for each provider-account group from T015 with `endpoint_spec_present=true`, FIRST check T006's `load_quota_cache` for a non-expired entry — if present, use it with `data_source="cached"` and `data_age_seconds = now - _cached_at` (FR-012) and skip the network probe entirely; otherwise (or when `--fresh` was passed, which forces this branch unconditionally) background a live probe (`( ... ) </dev/null >/dev/null 2>&1 &`, writing its JSON result to a zero-padded-index temp file, `curl`/python3-invoked `quota_probe.py` call bounded by `--timeout`, which defaults to `CMA_QUOTA_HTTP_TIMEOUT:-3` — 3 seconds, the EXACT same default as the existing `CMA_LLMCTL_HTTP_TIMEOUT:-3` precedent this pattern is copied from, `scripts/claude-providers.sh:2128`, not a new number invented for this feature), batched with plain `wait` every `CMA_QUOTA_MAX_PARALLEL_PROBES` (default 8) jobs, tag the result `data_source="live"`/`data_age_seconds=null`, and write it back via T006's `save_quota_cache` for the NEXT invocation to find; for every group with `endpoint_spec_present=false`, skip straight to an `absence_reason=not_reported_by_provider` result with NO background job and NO cache lookup at all (data-model.md's state-transition diagram's first branch — test this explicitly: assert zero `curl`/probe invocations happened for a fixture provider with no `quota-endpoints.json` entry). The test must include: (a) a SIMULATED slow provider (a fixture entry whose stubbed probe sleeps past the timeout) — assert that alias alone ends up `probe_failed`, every OTHER alias in the same run still reports its real result, and total wall-clock time for the whole batch is bounded by the per-provider timeout, not by alias count (SC-008, Review Focus #3) — measure this with `time`/`$SECONDS` inside the test, asserting an upper bound well under `N_aliases × timeout`; (b) a fixture with a valid non-expired cache entry already on disk — assert NO `curl` invocation happened for that alias and its result carries `data_source="cached"` with a correct, non-null `data_age_seconds` (FR-012); (c) given N configured aliases (mix of provider-accounts and native accounts), assert the result set contains EXACTLY N rows — none missing, none duplicated (SC-001's explicit "zero missing" claim, tested directly here rather than only implied by the live quickstart scenario).
  - **Files**: Modify `scripts/claude-providers.sh`; create `scripts/tests/test_quota_concurrency.sh` for this task's own test (a dedicated file, matching plan.md's Project Structure and Parallel Execution Opportunities sections, which both commit to it existing as an independent, parallelizable file — not folded into `test_quota_cli.sh`).
  - **Interfaces — Consumes**: `_cma_quota_group_accounts` (T015), `scripts/providers/quota-endpoints.json` (T001), `quota_probe.resolve_window` (T003), `load_quota_cache`/`save_quota_cache` (T006), invoked via a small `quota_probe.py` CLI entrypoint this task also adds (`python3 quota_probe.py --provider-id <id> --spec-file <path> --api-key-env <var> --timeout <n>`, printing one JSON result to stdout — the bash↔Python boundary this project already uses for `providers-semantic.sh`↔its driver).
  - **Interfaces — Produces**: `_cma_quota_probe_all` → stdout, one JSON Reportable-Entity-shaped object per line (data-model.md §1, including `data_source`/`data_age_seconds`), covering every provider-account group AND every native account from T016 (native accounts always resolve `absence_reason=not_reported_by_provider` for v1, per research.md §7 — no probe attempted for them at all).
  - **[SUBAGENT]**: self-contained — depends only on already-merged T001/T003/T006/T015/T016 interfaces, needs no further context to implement.

- [x] **T018 [P] [TDD] [US1]** Write a failing test in `scripts/tests/test_quota_rendering.sh` for a not-yet-existing `_cma_quota_render_text` function: given a fixed, hand-built array of Reportable Entity JSON lines (matching T017's output shape) covering one green provider row, one native "not reported" row, one row with two windows of DIFFERENT severities, and one row with `data_source="cached"`/`data_age_seconds=42`, assert the rendered output (a) groups by alias header exactly once per provider-account (never once per alias_name — Scenario 1's de-dup check), (b) shows each window on its own line, (c) contains the literal words "not reported by provider" for the native row, (d) contains both severity words for the two-window row on two separate lines, (e), when run with `_cma_quota_color_enabled` forced false, contains ZERO ANSI escape bytes (`\033`) anywhere in the output while STILL containing every severity word from (d) (FR-013, Review Focus #5's plain-text half), and (f) the cached row's line states its data is cached and states `42` (or "42 seconds", any wording containing the number) — FR-012's disclosure requirement rendered, not only carried as a silent field.
  - **Files**: Modify `scripts/tests/test_quota_rendering.sh`.

- [x] **T019 [US1]** Implement `_cma_quota_render_text` in `scripts/lib.sh` per T018's contract, using `_cma_quota_severity` (T008) and `_cma_quota_color_enabled` (T010), matching the example layout in `contracts/quota-limits-cli-contract.md`'s "Human-readable output shape" section. Confirm T018 passes.
  - **Files**: Modify `scripts/lib.sh`.
  - **Interfaces — Produces**: `_cma_quota_render_text` (reads Reportable Entity JSON lines from stdin or an argument file, writes formatted text to stdout).

- [x] **T020 [P] [TDD] [US1]** Write a failing test in `scripts/tests/test_quota_rendering.sh` for a not-yet-existing `_cma_quota_render_json` function: given the SAME fixture array T018 used, assert the output is a single valid JSON object (`jq .` exits 0), its top-level shape matches data-model.md §5 exactly (`generated_at`, `scoped_to`, `unknown_alias`, `rows`), and — this is the Review Focus #5 assertion in its strict form — run BOTH `_cma_quota_render_text` and `_cma_quota_render_json` against the EXACT SAME fixture input and assert the severity word appearing in the text output for a given alias matches (via `jq`) the `severity` field for that SAME alias/window in the JSON output, for every row in the fixture (never just spot-checking one).
  - **Files**: Modify `scripts/tests/test_quota_rendering.sh`.

- [x] **T021 [US1]** Implement `_cma_quota_render_json` in `scripts/lib.sh` using `jq -n`/`jq -s` to assemble the exact shape from `contracts/quota-limits-cli-contract.md`'s `--json` example, reading the SAME Reportable Entity stream `_cma_quota_render_text` reads (both renderers MUST consume byte-identical input in the same invocation — satisfy this by having `cmd_quota()`, wired in T022, capture `_cma_quota_probe_all`'s output ONCE into a variable/tempfile and pass that SAME captured data to whichever renderer the `--json` flag selects, never re-probing for the second renderer). Confirm T020 passes.
  - **Files**: Modify `scripts/lib.sh`.
  - **Interfaces — Produces**: `_cma_quota_render_json` (same input contract as `_cma_quota_render_text`).

- [x] **T022 [US1]** Wire `cmd_quota()` (from T012) to call, in order: T015 + T016 (gather accounts) → T017 (probe, respecting `--fresh` by skipping T006's cache read and `--timeout` by overriding the `CMA_QUOTA_HTTP_TIMEOUT:-3` default) → capture the combined result once → T019 or T021 depending on `--json` → print to stdout → return 0. This completes User Story 1 end-to-end.
  - **Files**: Modify `scripts/claude-providers.sh`.

**Checkpoint**: `claude-providers quota` (and `limits`, and `kimi-providers quota`/`limits` via its existing passthrough — confirmed needing no change, research.md §1) now fully works for the fleet-wide, no-argument case. Run quickstart.md Scenarios 1, 5, and 6 against a real sandbox/live install before proceeding.

---

## Phase 4: User Story 2 - Per-Alias Quota/Limits Detail (Priority: P2)

**Goal**: `claude-providers quota <alias>` reports the same depth of detail scoped to one alias, states plainly when the alias does not exist, and distinguishes a whole-account block from a single exhausted window.

**Independent Test**: quickstart.md Scenario 2 — run `claude-providers quota openrouter`, then `claude-providers quota this-alias-does-not-exist` and confirm exit code 2 with a plain statement, not silence or a crash.

### Tests for User Story 2

- [x] **T023 [TDD] [US2]** Write a failing test in `scripts/tests/test_quota_cli.sh`: `cmd_quota openrouter` (an existing alias) produces output with `scoped_to="openrouter"` (via `--json`) and `rows` containing AT MOST one entry; `cmd_quota this-alias-does-not-exist` returns exit code `2`, produces `unknown_alias: true` with an EMPTY `rows` array, and prints a plain-text statement containing the words "does not exist" (or equivalent) to stderr/stdout — never a silent `exit 0` with empty output (FR-003).
  - **Files**: Modify `scripts/tests/test_quota_cli.sh`.

- [x] **T024 [TDD] [US2]** Write a failing test in `scripts/tests/test_quota_probe.sh`: given a `quota-endpoints.json` entry with an `account_signals` list containing an `account_blocked` signal, and a stubbed HTTP body where that signal resolves `true`, calling a not-yet-existing `quota_probe.resolve_account_blocked(provider_spec, body)` returns `True`; given a body where it resolves `false`, returns `False`; given an entry with NO `account_signals` at all, returns `False` (the documented default, never "unknown" — `contracts/quota-endpoint-spec-contract.md`'s "account_blocked" section).
  - **Files**: Modify `scripts/tests/test_quota_probe.sh`.

### Implementation for User Story 2

- [x] **T025 [US2]** Modify `cmd_quota()` (`scripts/claude-providers.sh`) to accept the positional `<alias>` parsed back in T012: when present, after gathering accounts (T015/T016), filter to the ONE matching provider-account-group-or-native-account before probing (never probe every OTHER alias just to discard the result — this is also a latency win, not only a correctness one); when no match exists, set `unknown_alias=true`, skip probing entirely, print the plain-text statement, and `return 2`. Confirm T023 passes.
  - **Files**: Modify `scripts/claude-providers.sh`.

- [ ] **T026 [US2]** Implement `quota_probe.resolve_account_blocked(provider_spec, body)` in `scripts/quota_probe.py`, importing `_dig_bool` from `model_verify` (same reuse discipline as T003) and reading the OPTIONAL `account_signals` list per the new contract section. Wire its result into T017's per-account probe output as the `account_blocked` field (data-model.md §1). Confirm T024 passes.
  - **Files**: Modify `scripts/quota_probe.py`, `scripts/claude-providers.sh` (the T017 orchestration call site now also calls this and merges its result).
  - **Interfaces — Produces**: `resolve_account_blocked(provider_spec: dict, body: dict) -> bool`.

- [ ] **T027 [TDD] [US2]** Write a failing test, then extend `_cma_quota_render_text` (T019) and `_cma_quota_render_json` (T021), so that a row with `account_blocked=true` renders a DISTINCT, unmistakable statement (e.g. "ACCOUNT BLOCKED — the whole subscription is suspended") separately from, and in addition to, any real windows that row still carries (FR-011's "distinct from a single exhausted window" — a blocked account's PRIOR windows are not hidden, just annotated as moot) — confirm the color-stripped output ALSO carries this distinction in words (same Review Focus #5 discipline as T018).
  - **Files**: Modify `scripts/lib.sh`, `scripts/tests/test_quota_rendering.sh`.

**Checkpoint**: Both User Story 1 and User Story 2 fully work, independently and together. Run quickstart.md Scenario 2 against a real sandbox/live install.

---

## Phase 5: User Story 3 - Honest Reporting When A Provider Exposes Nothing (Priority: P3)

**Goal**: A provider with no endpoint spec is reported as `not_reported_by_provider`; a provider whose live probe genuinely fails is reported as `probe_failed`; the two are never confused with each other or with a real reading, in either rendering.

**Independent Test**: quickstart.md Scenario 3 — one alias with no `quota-endpoints.json` entry, one alias pointed at an unreachable host, confirm distinct, honest, unambiguous statuses for both.

### Tests for User Story 3

- [ ] **T028 [TDD] [US3]** Write a failing test in `scripts/tests/test_quota_cli.sh`: given a fixture alias whose `CMA_PROVIDER_ID` has NO entry in `quota-endpoints.json`, run `_cma_quota_probe_all` (T017) and assert its result for that alias has `absence_reason="not_reported_by_provider"`, `windows=[]`, AND — the Review Focus #4 assertion — that no `curl`/probe subprocess was ever invoked for it at all (stub `curl` itself via `sandbox_stub` to log every invocation to a file; assert the log contains zero lines naming this alias's `base_url`).
  - **Files**: Modify `scripts/tests/test_quota_cli.sh`.

- [ ] **T029 [TDD] [US3]** Write a failing test in `scripts/tests/test_quota_cli.sh`: given a fixture alias WITH a real `quota-endpoints.json` entry whose stubbed probe (via `sandbox_stub`'d `curl`) returns a connection-refused/timeout condition, assert the result has `absence_reason="probe_failed"`, `absence_detail` is a NON-EMPTY string naming the real failure, `windows=[]`, and — critically — `absence_reason` here is TEXTUALLY DIFFERENT from T028's `"not_reported_by_provider"` string (a literal string-inequality assertion, not just "both are falsy/absent" — Review Focus #4's "never confused with each other" half).
  - **Files**: Modify `scripts/tests/test_quota_cli.sh`.

### Implementation for User Story 3

T028 and T029 are expected to pass against the EXISTING `_cma_quota_probe_all` implementation (T017 already built the `endpoint_spec_present=false` short-circuit and the probe-failure path as part of its own bounded-concurrency work) — this phase has no distinct new code path of its own to add here. If either fails when run, the fix belongs in `scripts/claude-providers.sh` / `scripts/quota_probe.py` at the specific branch T028/T029 exercises; record that fix against this phase's Checkpoint below rather than as a separate numbered task.

- [ ] **T030 [TDD] [US3]** Write a failing test, then extend `_cma_quota_render_text`/`_cma_quota_render_json` (if not already satisfied by T019/T021's existing handling of `absence_reason`) so that `not_reported_by_provider` renders literally as "not reported by provider" (no percentage, no color word) and `probe_failed` renders literally including the `absence_detail` text (e.g. "probe failed: <detail>") — and assert, for a FULL fleet report mixing all three categories (real reading, not-reported, probe-failed) in one invocation, that a plain substring search for each category's expected phrase finds EXACTLY the rows that belong to it, never a false match against a different row's text (Review Focus #4/#5 combined, matching spec.md's own User Story 3 Acceptance Scenario 3).
  - **Files**: Modify `scripts/lib.sh` (if needed), `scripts/tests/test_quota_rendering.sh`.

**Checkpoint**: All three user stories are independently functional and demonstrated together. Confirm T028/T029 pass with no gap (see note above); run quickstart.md Scenario 3 (and re-run 1/2) against a real sandbox/live install.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [ ] **T031 [P] [POLISH]** Update `docs/Provider_Aliases_User_Guide.md` with a new section documenting `quota`/`limits` (both names, all flags, example output for both a funded and an exhausted provider, the native-account honest-absence behavior) in the same style as its existing subcommand sections; regenerate `.html`/`.docx`/`.pdf` via `bash scripts/claude-export-docs.sh`. No new `quickstart/`-style tutorial directory is created for this feature — this user guide section plus this spec's own `quickstart.md` (already linked from the spec directory) are the complete documentation surface for how to validate/use the command; state this explicitly in the new section so the question never resurfaces.
  - **Files**: Modify `docs/Provider_Aliases_User_Guide.md` (+ re-exported siblings).

- [ ] **T032 [P] [POLISH]** Update `docs/Provider_FAQ.md` with at least these real questions this feature's own design surfaced: "Why does `quota` show the same number for `deepseek` and `kimi-deepseek`?" (answer: shared account, data-model.md §2), "Why does my native Claude/Kimi account show 'not reported by provider'?" (answer: research.md §7's honest finding, plan-tier context if cached), "Why would `quota` for one alias take longer than the others?" (answer: FR-017's bounded per-provider timeout, not the whole command hanging).
  - **Files**: Modify `docs/Provider_FAQ.md`.

- [ ] **T033 [P] [POLISH]** Cross-reference `quota`/`limits` from `docs/Provider_Verification_Guide.md` (one short paragraph: "quota/limits is a separate, read-only reporting concern from verification — see Provider_Aliases_User_Guide.md") and from `docs/diagrams/provider-aliases.md` (one line pointing at the new diagram, T034).
  - **Files**: Modify `docs/Provider_Verification_Guide.md`, `docs/diagrams/provider-aliases.md`.

- [ ] **T034 [P] [POLISH]** Create `docs/diagrams/quota-limits-flow.mmd` (a flowchart matching data-model.md's State Transitions diagram: endpoint-spec-present check → bounded probe → success/timeout/error branches → render) and render it to `docs/diagrams/quota-limits-flow.svg`, matching this project's existing `.mmd`/`.svg` diagram convention (e.g. `docs/diagrams/llmctl-detection-flow.mmd`/`.svg`).
  - **Files**: Create `docs/diagrams/quota-limits-flow.mmd`, `docs/diagrams/quota-limits-flow.svg`.

- [ ] **T035 [P] [POLISH]** Update `README.md`'s "📋 Daily commands" section (`README.md:122`) with `claude-providers quota` / `limits` and `kimi-providers quota` / `limits` one-liners, linking to the user guide section from T031.
  - **Files**: Modify `README.md`.

- [ ] **T036 [POLISH]** Add a live end-to-end leg to `scripts/claude-release-gate.sh` (and, if it runs separately, `scripts/tests/run-proof.sh`) that runs `claude-providers quota --json` against whatever REAL, currently-configured provider aliases and native accounts exist on the host running the gate, asserting the output is valid JSON with the expected top-level shape — this is the live leg SC-005 requires ("every claim... backed by a captured run... against a live, installed copy of the toolkit"). Capture its output under `scripts/tests/proof/` per this project's existing evidence convention.
  - **Files**: Modify `scripts/claude-release-gate.sh` (and/or `scripts/tests/run-proof.sh`).

- [ ] **T037 [POLISH]** Run the full regression suite (`bash scripts/tests/run-all.sh`) and confirm EVERY pre-existing test still passes unmodified — this is SC-006's explicit, separate claim from "the new tests pass," and must be demonstrated, not assumed, with pasted output.
  - **Files**: None (verification task).

- [ ] **T038 [REVIEW] [POLISH]** Independent review (Opus `xhigh`, constitution Principle VI) of the whole feature branch against every one of spec.md's 8 Success Criteria, each with its own pasted command output as evidence (quickstart.md's 7 scenarios map directly to this) — plan.md's Human Checkpoint #4, the gate before release. Explicitly include SC-007 in this review's scope: grep every `test_quota_*.sh` file for any ANSI-stripping workaround or colored-text substring parsing used to derive a pass/fail verdict, and confirm zero such cases exist (every assertion reads structured `--json`/direct-function-return data, per T013/T014/T023/T024/T028/T029's existing convention) — SC-007 is otherwise only satisfied incidentally, never explicitly audited, and this review is where that gap closes.
  - **Files**: None (review task); findings, if any, become new tasks or direct fixes before T039.

- [ ] **T039 [POLISH]** Dual-forge release: bump this project's version, write the CHANGELOG entry (Added: `quota`/`limits` subcommand on `claude-providers`/`kimi-providers`, new `providers/quota-endpoints.json`, Testing & Validation summary citing T037/T038's evidence), tag, fetch→verify-fast-forward→push to every configured upstream for both the main repo (per this project's own standing multi-remote discipline), then `gh release create` and `glab release create` with the changelog as release notes — matching the originating request's explicit final step and this project's own established release workflow from prior features.
  - **Files**: Modify `CHANGELOG.md`; git tag; no other file changes.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately.
- **Foundational (Phase 2)**: Depends on Setup (T001's fixture file is read by T002's first test). BLOCKS all user stories.
- **User Story 1 (Phase 3)**: Depends on Foundational completion. No dependency on US2/US3.
- **User Story 2 (Phase 4)**: Depends on Foundational AND on User Story 1's `cmd_quota()`/renderer existing (T025 modifies `cmd_quota()`, T027 extends the renderers) — not independently implementable before US1, unlike the template's generic assumption; this is a real, spec-shaped dependency (per-alias detail is inherently a refinement of the fleet view's same data, per spec.md's own "Why this priority" for User Story 2).
- **User Story 3 (Phase 5)**: Depends on Foundational AND User Story 1 (same reason — T028/T029 test `_cma_quota_probe_all` from T017). Independent of User Story 2 — can be done in parallel with Phase 4 by a different track.
- **Polish (Phase 6)**: Depends on all three user stories being complete.

### Parallel Opportunities

- T001 (Setup) blocks T002 but nothing else in Setup — it is the only Setup task.
- Within Foundational: T002→T006 (quota_probe.py's probe+cache) and T007→T010 (lib.sh's severity+color) are two independent chains — `[P]` against each other, never within a chain (same-file sequential dependency). T011→T012 (the collision test + dispatch skeleton) depends on NOTHING in the other two chains structurally, but should land last in this phase since T012's `cmd_quota()` stub is what US1 immediately extends.
- Within User Story 1: T013/T014 (two independent test-writing tasks, different functions) are `[P]`. T015/T016 depend on their respective tests (not on each other) and could be done by two different people/tracks, though both land in `scripts/lib.sh` — treat as sequential within one file in practice even though conceptually independent (writing-plans' "avoid same-file conflicts" rule). T017 depends on T015+T016 existing. T018/T020 (two renderer tests, same file, different functions) — written in parallel is fine (test-writing rarely conflicts), but T019/T021's IMPLEMENTATIONS should land sequentially in the same `lib.sh` region to avoid merge noise.
- User Story 2 and User Story 3 (Phases 4 and 5) can proceed IN PARALLEL on two different tracks once User Story 1's checkpoint is reached — they touch an overlapping but not identical set of functions (`cmd_quota()`, the two renderers) and SHOULD be sequenced relative to EACH OTHER if both tracks would otherwise edit the same function bodies in the same commit window; coordinate via whichever lands first rebasing cleanly onto the other, not via a hard phase-dependency.
- Polish tasks T031–T035 (docs/diagram) are fully `[P]` against each other and against T036/T037 (they touch no shared file). T038 (review) depends on T036+T037 having run. T039 (release) depends on T038's clean outcome.

---

## Implementation Strategy

### MVP First

1. Setup (T001) → Foundational (T002–T012) → User Story 1 (T013–T022).
2. **STOP and VALIDATE**: run quickstart.md Scenarios 1, 5, 6 against a real sandbox AND a live install.
3. This is already a complete, demoable MVP — `quota`/`limits` works for the fleet-wide case, which spec.md calls "the entire point of the feature."

### Incremental Delivery

1. MVP (above) → demo.
2. Add User Story 2 (T023–T027) → validate Scenario 2 → demo.
3. Add User Story 3 (T028–T030) → validate Scenario 3 → demo.
4. Polish (T031–T039) → full release.

### Parallel Track Strategy

With two tracks available after the Foundational checkpoint:

- Track A: User Story 1 end-to-end (T013–T022), solo — it is the critical path everything else depends on.
- Once US1's checkpoint lands: Track A takes User Story 2 (T023–T027), Track B takes User Story 3 (T028–T030), in parallel, coordinating only on `cmd_quota()`/the renderer functions per the note under Parallel Opportunities above.
- Both tracks converge on Polish (T031–T039), splitting the fully-parallel doc/diagram tasks (T031–T035) across themselves.

---

## Notes

- Every `[TDD]` task's test MUST be run and observed to fail for the stated reason before its implementation step is written — this is not optional scaffolding, it is how T011 in particular earns the trust plan.md's Human Checkpoint #2 requires.
- `[P]` here always means "different file, or non-overlapping function in a shared file written by test-only tasks" — never "same function, different person" (writing-plans' same-file-conflict rule).
- Commit after each task, or after each RED+GREEN pair for `[TDD]` tasks (two commits: test, then implementation — never squashed into one, so the RED state is itself in history as evidence the test was real).
- No task above references a type, function, or field not already defined in data-model.md, contracts/, research.md, or an earlier task in this file — if implementation reveals one is needed, add it to data-model.md/the relevant contract FIRST, then continue (never invent a shape silently mid-task).
- **Execution method (confirmed)**: subagent-driven — a fresh subagent implements each task and a fresh reviewer checks it before the next one starts, then a whole-branch review at the end (`/speckit.superspec.execute`, per the user's explicit standing instruction: "Everything MUST BE done fully sub-agent driven!").
