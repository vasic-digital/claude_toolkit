> **STATUS (2026-10-22): historical spec, ported verbatim below the rule.** Superseded in places by
> llmctl `specs/009-jev-decision-models` (the decision-model serving side) and Constitution
> §11.4.279 (the decision-models layer: A detection, B wiring, C typed decisions, D validation via
> §11.4.277, E token proof, F calibration, G bootstrap, H gates). Where this text and current code
> or those documents disagree, the code and the newer documents win. Known later changes: the local
> decide gateway is HTTPS + bearer key (v1.32.0; this text predates it and says http / `127.0.0.1:8095`
> without TLS), launches export `JEV_KEY_VAR`/`JEV_CA_FILE` rather than a key value, and plain http is
> opt-in. The design file `design/toolkit-jev-design.md` that this spec cites exists in no checkout
> searched (this repo, the constitution tree, the filesystem); UNCONFIRMED whether it was ever written.
>
> Per-task verification (2026-10-22): T001-T016 and T018-T025 are present in the tree (files/functions grep-confirmed);
> **T017 is NOT FOUND** (see spec.md). The [x] marks below are the original ones, kept verbatim.

---

# Tasks: Jev Decision-Layer Integration

**Input**: Design documents from `specs/003-jev-decision-layer/` + `design/toolkit-jev-design.md`
**Status**: All implementation tasks shipped. QA: 9 Jev suites / 280 assertions / 0 failures (4 deterministic executions); full run-all 91 pass / 10 pre-existing environmental failures, zero new failures (`qa-results/jev_decision_layer_20261006/`).

**Organization**: staged by dependency (mirrors design §8). Every task names its exact file(s).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (different files, no same-batch dependency).
- **[Story]**: `US1` detection/launch wiring, `US2` gate/MCP/agents, `US3` stats, `US4` spec CI, `SETUP`/`FOUND`/`POLISH`.

---

## Phase 1: Setup

- [x] **T001 [P] [SETUP]** Create `scripts/providers/jev.json` pins file: `hosted.typesafe` (key `TYPESAFE_API_KEY`, models `["jev-1.13.0","jev-latest"]`, ctx 64000), `hosted.openrouter` (key `OPENROUTER_API_KEY`, models `["typesafe/jev-1.13","jev-latest"]`, ctx 32000), `local_gateway` 127.0.0.1:8095 (`/healthz`, `/v1/models`, `/v1/systemone`, key `LLMCTL_API_KEY`), `"lan": []`.
- [x] **T002 [P] [SETUP]** Create canonical fixture `scripts/tests/fixtures/jev_server.py`: stdlib http.server speaking the verified systemone wire format (`GET /healthz`, `GET /v1/models`, `POST /v1/systemone` with name→question map; choice/noul/score response shapes; scripted answers; artificial-latency seam; port file).
- [x] **T003 [P] [SETUP]** Create `specs/003-jev-decision-layer/` skeleton (spec/plan/tasks).

## Phase 2: Foundational — detection core (blocks US1)

- [x] **T004 [FOUND] [US1]** `detect_jev_records()` in `scripts/claude-providers.sh` with four sub-sources: (a) TypeSafe hosted on `TYPESAFE_API_KEY` presence (priority 40, model `jev-latest`); (b) OpenRouter on `OPENROUTER_API_KEY` (priority 30, model `typesafe/jev-1.13`); (c) local gateway probe `/healthz` + `/v1/models` (priority 10, `jev-local`, auto appear/disappear); (d) enabled LAN pins, bounded-parallel probe, id validation, `lan_exposed` (priority 20, `jev-<id>`). All records: `classification:"decision"`, `"alias":null`, `transport:"systemone"`, `max_output:0`.
- [x] **T005 [FOUND] [US1]** `_cma_jev_write_endpoint_cache()`: filter `classification=="decision" && status=="resolved"`, rank (`CMA_JEV_PREFER` first, then priority asc, provider_id tiebreak), write version-1 cache atomically to `providers/jev-endpoints.json` (key var NAME only).
- [x] **T006 [US1]** Subcommand `claude-providers sync-jev [--quiet]`: light path (detect + cache write); honors `CMA_JEV_DISABLE`; full `sync` also invokes it.
- [x] **T007 [US1]** Exclude decision records from alias emission, kimi/pi renderer input, and chat catalogs (guard comments at emission sites; renderers themselves unchanged); include them in `status.json`; render `## Decision endpoints (Jev) — not launchable; decision layer` in `claude-providers list`.
- [x] **T008 [P] [US1]** Tests: `test_jev_detect.sh` (25 assertions), `test_jev_pins.sh` (27), `test_jev_no_alias_leak.sh` (26), `test_jev_endpoints_cache.sh` (16) — record shape, appear/disappear, priority order + `CMA_JEV_PREFER`, malformed-pins tolerance, zero `jev-*`/`kimi-jev-*` aliases, cache format/ranking.

## Phase 3: Launch wiring (US1, depends on Phase 2)

- [x] **T009 [US1]** `cma_jev_env()` + `_cma_emit_cma_jev_env()` in `scripts/lib.sh`: cache-only read (TTL `CMA_JEV_CACHE_TTL` 300; stale → detached `sync-jev --quiet` + `CMA_JEV_REFRESH_KICKED=1`); exports `JEV_BASE_URL/JEV_API_KEY/JEV_MODEL/JEV_MODE(shadow)`, `TYPESAFE_BASE_URL/TYPESAFE_API_KEY`, `CMA_JEV_ACTIVE`, `CMA_JEV_ENDPOINT_ID`, `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50`, `MAX_THINKING_TOKENS=10000`; `CMA_JEV_DISABLE`/`CMA_JEV_QUIET`; ACTIVE/INACTIVE MOTD on stderr.
- [x] **T010 [US1]** Call `cma_jev_env` at the top of all six wrappers (`cma_run`, `cma_run_provider`, `cma_run_kimi`, `cma_run_kimi_provider`, `cma_run_pi`, `cma_run_pi_provider`) including their emitted copies; reserve the `jev-*` namespace in the namespace-contract comment.
- [x] **T011 [P] [US1]** Test `test_jev_wrappers.sh` (95 assertions): env exports incl. token knobs, MOTD signature, cache-absent no-op launch, background-refresh kick, disable/quiet paths.

## Phase 4: Gate + MCP + plugin (US2, parallel with Phase 3 given T002)

- [x] **T012 [P] [US2]** `scripts/jev-gate.sh`: stdin hook JSON (Claude camelCase / Kimi snake_case), 12000-char head+tail truncation, sha256 state hash, deterministic risk floor, one-request choice(`gate`)+noul(`risky`) systemone call, mapping (deny on choice=deny or risky≥0.8 with choice≠allow; ask on choice=ask or risky≥0.7; risky>0.7 escalates allow→ask; floor only escalates), shadow/enforce, fail-open (`JEV_GATE_TIMEOUT=2`, `fallback:"timeout"|"endpoint_error"`), `JEV_GATE=off` kill switch, `JEV_GATE_FAIL=closed` option, Claude-shaped decision JSON + exit codes (0/2), decisions.jsonl schema (no raw state).
- [x] **T013 [P] [US2]** `scripts/jev_mcp.py`: stdlib-only MCP over stdio (Content-Length framing, newline-delimited accepted); tools `jev_ask` (choice/noul), `jev_models`, `jev_stats_summary`; `JEV_MCP_TIMEOUT=4`; structured `isError` on unreachable.
- [x] **T014 [P] [US2]** `scripts/opencode-jev-plugin.js`: `tool.execute.before` gate reading env or `jev-endpoints.json` + keys file directly (OpenCode has no cma wrapper); same thresholds/fail-open/risk-floor inline; decisions.jsonl `agent:"opencode"`; header documents #2319/#5894 caveats.
- [x] **T015 [P] [US2]** Tests: `test_jev_gate.sh` (27 assertions: shadow/enforce/fail-open/risk-floor/kill-switch/hash-only logging), `test_jev_mcp.sh` (11: initialize/tools-list/jev_ask round-trip, isError path); `node --check` on the plugin.

## Phase 5: Installer + renderers (US2, depends on Phases 2–4)

- [x] **T016 [US2]** `scripts/jev-setup.sh`: `--agents claude,kimi,pi,opencode` (default all), `--mode shadow|enforce`, `--check`, `--uninstall`, `--if-stale`, `--quiet`; backup-first atomic jq-merges; common (gate copies, `~/.config/jev/env` 0600, state dir); claude (PreToolUse `Bash|Agent|Task` hook merge + `claudeMdExcludes` union + `.mcp.json` `mcpServers.jev` + CLAUDE.md guarded block); kimi (marker-guarded `[[hooks]]` in native homes, renderer-owned block in kimi-prov homes, `mcp.json` both, key materialization documented); pi (`@riposta/pi-jev`, 3 s npm probe, honest offline SKIP, no homes → no probe); opencode (plugin copy content-addressed, `mcp.jev` + `plugin` entry, caveat printed).
- [x] **T017 [US2]** `_cma_kimi_render_config` additive `# cma-jev:hooks BEGIN/END` block when the endpoint cache is non-empty (renderer reads cache only; whole-file rewrite keeps it idempotent; `default_model` ordering regression guard intact).
- [x] **T018 [US2]** Test `test_jev_setup_idempotent.sh` (32 assertions: double-run single blocks, `--check` MISSING reporting, `--uninstall` restores, mcp merges preserve existing entries).
- [x] **T019 [US2]** `scripts/install.sh`: symlink `jev-*.sh` onto PATH (`jev-setup`, `jev-gate`, `jev-stats`, `jev-spec-setup`).

## Phase 6: Stats + spec CI (US3/US4, parallel with Phase 5)

- [x] **T020 [P] [US3]** `scripts/jev-stats.sh`: `--days N` / `--json`; counts by answer/mode/agent/endpoint, fallback count, avg latency, shadow would-be split + would-deny rate, ESTIMATE formula `total*1500 + enforced_ask_or_deny*200` (constants `JEV_EST_INPUT_TOKENS`/`JEV_EST_OUTPUT_TOKENS`), zero-state message exit 0.
- [x] **T021 [P] [US3]** Test `test_jev_stats.sh` (21 assertions: exact counts/formula on seeded log, empty-log path).
- [x] **T022 [P] [US4]** `scripts/jev-spec-setup.sh`: writes `jev-spec.config.ts` + `.github/workflows/jev-verify.yml` (fork PRs `--dry-run`; `TYPESAFE_AI_API_KEY` key-name note), refuses overwrite without `--force`, never runs npm.

## Phase 7: Docs + QA (POLISH)

- [x] **T023 [P] [POLISH]** `docs/jev/{Jev_Quickstart,Jev_User_Guide,Jev_FAQ}.md`; `docs/Provider_Aliases_User_Guide.md` decision-endpoints chapter; `docs/Provider_FAQ.md` Jev entries; README Features/commands/Documentation rows; CLAUDE.md Jev section byte-copied to AGENTS/GEMINI/QWEN.
- [x] **T024 [P] [POLISH]** `docs/research/` copies (+ index README), `docs/diagrams/jev-architecture.mmd` (+svg), CHANGELOG entry, CONTINUATION entry, `qa-results/jev_decision_layer_20261006/` evidence copy.
- [x] **T025 [POLISH]** Integration QA: fixture convergence on the verified wire format (single canonical `jev_server.py`; `jev_gate_server.py` deleted), full `run-all.sh` twice with identical results (91/10, zero new failures, failure-list diff vs. baseline = only a fixed pre-existing failure), spot-check evidence (`sync-jev` vs fixture, wrapper MOTD capture, gate shadow+enforce round-trips, `jev-setup --check`, fixture dialect proof).

## Dependencies & Execution Order

- Phase 1 → Phase 2 → {Phase 3, Phase 4} → Phase 5 → Phase 6 (∥ 5) → Phase 7.
- T002 (fixture) is the shared root of all gate/MCP/integration tests.
