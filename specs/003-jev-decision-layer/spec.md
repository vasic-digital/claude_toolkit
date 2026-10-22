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
> Task status was verified against the CURRENT code by grep on 2026-10-22 (not guessed).
> Implemented (artifact present): T001-T016, T018-T025. NOT FOUND in current code: T017 (the additive
> `# cma-jev:hooks BEGIN/END` block in `_cma_kimi_render_config`; the marker exists only in `scripts/jev-setup.sh`).

---

# Feature Specification: Jev Decision-Layer Integration

**Feature Branch**: `003-jev-decision-layer`
**Created**: 2026-10-06
**Status**: Implemented (QA: 9 suites, 280 assertions, 0 failures; full run-all 91 pass / 10 pre-existing environmental failures — `qa-results/jev_decision_layer_20261006/`)
**Input**: Design: `design/toolkit-jev-design.md`; research: `docs/research/toolkit-architecture.md`, `docs/research/agent-integration-mechanics.md`, `docs/research/jev-ecosystem.md`, `docs/research/decision-model-hashes.md`.

## Summary

Register Jev-class **decision-model** endpoints (TypeSafe hosted, OpenRouter,
local llmctl `:8095` gateway, user-pinned LAN/remote hosts) as a new
`classification: "decision"` record type that is **never launchable** (no
aliases, no chat configs), and wire the highest-ranked endpoint into every
agent launch as a decision layer: a fail-open, shadow-first PreToolUse
permission gate (`jev-gate.sh`), a stdlib MCP server (`jev_mcp.py`),
per-agent install artifacts (`jev-setup`), a savings/calibration reporter
(`jev-stats`), and an opt-in CI template installer (`jev-spec-setup`).

## Clarifications

### Session 2026-10-06

- Q: Should decision records flow through the existing alias/renderers like
  llmctl records do? → A: No. Decision records carry `"alias": null` and are
  filtered out of alias emission, per-family renderers, and verified-models
  chat catalogs at each emission site. They appear only in `status.json`,
  `claude-providers list` (own section), and the endpoint cache.
- Q: Endpoint selection priority? → A: local llmctl gateway (10) > LAN pins
  (20) > OpenRouter (30) > TypeSafe hosted (40); overridable via
  `CMA_JEV_PREFER`. Rationale: local is free/lowest-latency; LAN pins are
  user-declared trust; OpenRouter has no waitlist while TypeSafe 1P does.
- Q: Gate default posture? → A: shadow mode + fail-open. Enforce mode is an
  explicit operator action (`jev-setup --mode enforce`) after a calibration
  week; fail-closed exists (`JEV_GATE_FAIL=closed`) but is not the default.
- Q: Which pi package? → A: `@riposta/pi-jev` (verified). `jev-pi` /
  `jev-pi-orchestrator` names in older material are wrong/renamed.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Endpoint appears, launch is wired (Priority: P1)

An operator with any one Jev endpoint source (local gateway, LAN pin, or a
hosted key in `~/api_keys.sh`) runs `claude-providers sync` and sees the
endpoint under `## Decision endpoints (Jev)` in `claude-providers list`;
launching any alias prints `Jev decision layer: ACTIVE (endpoint: …, mode:
shadow)` and exports `JEV_*`/`TYPESAFE_*` without any network I/O on the
launch path.

**Acceptance Scenarios**:

1. **Given** a live local gateway on `127.0.0.1:8095`, **When** `claude-providers sync-jev` runs, **Then** `jev-endpoints.json` contains `jev-local` first and no `jev-*` alias exists in the managed alias file.
2. **Given** only `OPENROUTER_API_KEY` in the keys file, **When** sync runs, **Then** `jev-openrouter` resolves with model `typesafe/jev-1.13`.
3. **Given** no endpoint at all, **When** any alias launches, **Then** the launch behaves identically to pre-Jev plus at most one INACTIVE notice (suppressible with `CMA_JEV_QUIET=1`).

### User Story 2 - Tool-call gating with evidence (Priority: P1)

With artifacts installed (`jev-setup`), Claude Code and Kimi tool calls
matching the hook matchers pass through `jev-gate.sh`: one systemone request
(choice `gate` + noul `risky`) maps to allow/ask/deny; a deterministic risk
floor forces at least `ask` for destructive patterns; shadow mode logs the
would-be decision; enforce mode applies it; endpoint failure fails open.

**Acceptance Scenarios**:

1. **Given** shadow mode and a scripted deny answer, **When** a gated tool call runs, **Then** the tool is allowed and `decisions.jsonl` records `"mode":"shadow","answer":"deny","enforced":false`.
2. **Given** enforce mode and a deny answer, **Then** stdout carries `permissionDecision:"deny"` and exit code is 2.
3. **Given** the endpoint is killed mid-call, **Then** the gate allows within `JEV_GATE_TIMEOUT` and logs `fallback:"timeout"`.
4. **Given** input `rm -rf /` with the endpoint answering allow, **Then** the decision is at least `ask` (risk floor).
5. **Given** a secret in the tool input, **Then** the log contains only `state_hash`, never the raw input.

### User Story 3 - Calibration and savings reporting (Priority: P2)

`jev-stats [--days N] [--json]` aggregates `decisions.jsonl`: counts by
answer/mode/agent/endpoint, average latency, fallback count, shadow
would-be split, and an explicitly-labeled ESTIMATE of tokens saved
(`total*1500 + enforced_ask_or_deny*200`, constants env-overridable).

### User Story 4 - CI spec verification (Priority: P3)

`jev-spec-setup [--force] <repo>` installs `jev-spec.config.ts` +
`.github/workflows/jev-verify.yml` templates (fork PRs dry-run; key never
exposed), refusing overwrites without `--force`, never running npm itself.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Detect four Jev endpoint sources (local gateway via live probe of `/healthz` + `/v1/models`; enabled LAN pins via the same probe; OpenRouter and TypeSafe via keys-file var-name presence) and emit `classification: "decision"`, `"alias": null` records.
- **FR-002**: Exclude decision records from alias emission, kimi/pi renderers, and chat model catalogs; include them in `status.json` and a dedicated `claude-providers list` section marked not launchable.
- **FR-003**: Write a ranked, non-secret endpoint cache (`jev-endpoints.json`, version 1, TTL `CMA_JEV_CACHE_TTL` 300 s) on `sync` and on the Jev-only `sync-jev` path.
- **FR-004**: Export the Jev environment in all six launch wrappers with zero launch-path network I/O; stale cache kicks a background refresh; any failure yields `CMA_JEV_ACTIVE=0` and an unchanged launch.
- **FR-005**: Install per-agent artifacts idempotently (backup-first, marker blocks or jq-merge, atomic writes, honest offline SKIP messages): Claude hooks+MCP+CLAUDE.md block; kimi `[[hooks]]`+`mcp.json`; pi `@riposta/pi-jev` (network-guarded); opencode plugin+MCP with the #2319/#5894 caveat printed.
- **FR-006**: Gate protocol: kill switch, risk floor, one-request two-question systemone call, threshold mapping (0.8 deny / 0.7 ask), shadow/enforce modes, fail-open, Claude-shaped decision JSON plus consistent exit codes, hashed-only evidence logging.
- **FR-007**: MCP server exposing `jev_ask`, `jev_models`, `jev_stats_summary`; structured `isError` on unreachable endpoint; never hangs.
- **FR-008**: `jev-stats` report with the documented savings estimate formula and shadow calibration split.
- **FR-009**: Global opt-outs: `CMA_JEV_DISABLE=1` (whole layer), `JEV_GATE=off` (gate only).
- **FR-010**: No secrets outside the keys file: the endpoint cache stores key var names only; the evidence log stores state hashes only. (Exception, documented: kimi `mcp.json` materializes the key inside a 0700 home, the same secrecy class as kimi's own resolved `api_key`.)

## Success Criteria *(mandatory)*

- **SC-001**: All 9 Jev test suites pass deterministically: 280 assertions, 0 failures, identical across repeated runs (achieved: 4 executions recorded in `qa-results/jev_decision_layer_20261006/toolkit-iter3-final.txt`).
- **SC-002**: Zero new failures in the full hermetic suite (101 files: 91 pass / 10 fail, all 10 pre-existing environmental; failure-list diff empty vs. baseline).
- **SC-003**: With no Jev endpoint, every alias launch is behavior-identical to pre-Jev (no new exports, no MOTD beyond the suppressible notice).
- **SC-004**: A gated tool call in shadow mode never blocks; in enforce mode a deny exits 2 with Claude-shaped JSON.
- **SC-005**: Gate wall-clock stays within `JEV_GATE_TIMEOUT` + 1 s on endpoint failure.
- **SC-006**: Docs set ships and is linked: `docs/jev/` three-doc set, research copies, this spec, README/CHANGELOG/CLAUDE-family updates, architecture diagram.

## Assumptions

- Kimi's PreToolUse stdout decision-JSON shape is Claude-like; the gate emits both JSON and exit codes so either consumer works (exit codes are verified).
- `@riposta/pi-jev` honors the SDK-convention env names; unverified names beyond that are documented as such.
- MCP stdio framing is Content-Length LSP-style (implemented; newline-delimited input also accepted).

## Out of Scope

- `jev-architect` (BenjaminPolge): heuristics only, never calls Jev — excluded.
- Any chat-model use of decision endpoints (they have no chat API).
- Automatic `--mode enforce`: always an explicit operator action.
