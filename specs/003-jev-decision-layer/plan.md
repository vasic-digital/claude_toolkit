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

---

# Implementation Plan: Jev Decision-Layer Integration

**Branch**: `003-jev-decision-layer` | **Date**: 2026-10-06 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `specs/003-jev-decision-layer/spec.md`; file-level design `design/toolkit-jev-design.md`.

## Summary

Add a parallel, non-launchable registration path for Jev decision-model
endpoints to the claude-providers engine (detector → resolve → ranked
endpoint cache, **not** aliases/renderers), wire the top-ranked endpoint
into all six launch wrappers via a cache-only env function + MOTD, and ship
the decision-layer tooling: shared POSIX gate (shadow-first, fail-open,
risk floor), stdlib MCP server, idempotent per-agent installer, stats
reporter, opt-in CI template installer, and an OpenCode plugin with
documented upstream interception caveats.

## Technical Context

**Language/Version**: Bash (POSIX-leaning, macOS bash 3.2 compatible) for
detection/wiring/gate/installer; Python 3.8+ stdlib only for the MCP server;
dependency-free JS for the OpenCode plugin. **No new Go.**
**Primary Dependencies**: `jq`, `curl` (already hard deps), `sha256sum`/`shasum`.
**Storage**: `~/.local/share/claude-multi-account/providers/jev-endpoints.json`
(ranked cache, non-secret), `~/.local/state/jev/decisions.jsonl` (evidence),
`~/.config/jev/env` (mode, 0600, non-secret). Secrets remain only in
`CMA_KEYS_FILE`.
**Testing**: existing hermetic bash harness (`tests/lib/assert.sh` +
`lib/sandbox.sh`, `make_sandbox`, `sandbox_stub`, `CMA_LIVE_TESTS=1` gates)
plus a new canonical stdlib fixture `tests/fixtures/jev_server.py` speaking
the verified systemone wire format.
**Target Platform**: Linux + macOS.
**Performance Goals**: zero network I/O on the launch path (one `stat` + one
`jq` on a small file; background refresh only); gate bound by
`JEV_GATE_TIMEOUT=2`s; detection probes bounded-parallel with
`CMA_JEV_HTTP_TIMEOUT=2`s.

## Constitution Check

- Secrets only in the keys file: cache stores key var **names**; evidence
  log stores state hashes only. (Documented exception: kimi `mcp.json`
  materializes the key inside a 0700 home, same secrecy class as kimi's own
  resolved `api_key` in `config.toml`.)
- Graceful degradation: no endpoint ⇒ identical pre-Jev behavior plus at
  most one notice line; gate fail-open by default.
- Atomic writes funnel through existing patterns (temp + `mv`, jq-merge with
  backup-first); no code outside the listed touch points.

## Project Structure

### Documentation (this feature)

```text
specs/003-jev-decision-layer/
├── spec.md
├── plan.md
└── tasks.md
docs/jev/{Jev_Quickstart.md, Jev_User_Guide.md, Jev_FAQ.md}
docs/research/{toolkit-architecture.md, agent-integration-mechanics.md,
  jev-ecosystem.md, decision-model-hashes.md, encoder-model-hashes.md}
docs/diagrams/jev-architecture.mmd (+ .svg)
qa-results/jev_decision_layer_20261006/
```

### Source Code

```text
scripts/
├── providers/jev.json          # pins: hosted (typesafe/openrouter),
│                               # local_gateway :8095, lan: [] (NEW)
├── claude-providers.sh         # detect_jev_records + 4 sub-sources,
│                               # _cma_jev_write_endpoint_cache, sync-jev,
│                               # decision-record filters, list section (MOD)
├── lib.sh                      # cma_jev_env (+ _cma_emit_cma_jev_env),
│                               # 6 wrapper call sites, MOTD (MOD)
├── jev-gate.sh                 # shared POSIX PreToolUse gate (NEW)
├── jev_mcp.py                  # stdlib MCP server (NEW)
├── jev-setup.sh                # idempotent per-agent installer (NEW)
├── jev-stats.sh                # savings/calibration reporter (NEW)
├── jev-spec-setup.sh           # CI template installer (NEW)
├── opencode-jev-plugin.js      # OpenCode plugin + caveat header (NEW)
└── install.sh                  # symlink jev-*.sh onto PATH (MOD)
tests/
├── fixtures/jev_server.py      # canonical systemone fixture (NEW)
└── test_jev_{detect,endpoints_cache,no_alias_leak,pins,gate,mcp,
    setup_idempotent,stats,wrappers}.sh   # 9 suites, 280 assertions (NEW)
```

## Implementation notes (as built — code wins over design where they differ)

- Risky-probability thresholds as shipped: `JEV_GATE_THRESHOLD=0.8` (deny
  floor), `JEV_RISKY_THRESHOLD=0.7` (allow→ask escalation); an additional
  hard rule escalates risky > 0.7 with an allow answer to at least `ask`.
- Claude hook matcher as shipped: `Bash|Agent|Task` (timeout 5).
- MCP tool surface as shipped: `jev_ask`, `jev_models`, `jev_stats_summary`.
- Savings formula as shipped: `total * JEV_EST_INPUT_TOKENS(1500) +
  enforced_ask_or_deny * JEV_EST_OUTPUT_TOKENS(200)`.
- Token knobs exported on active launches: `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50`,
  `MAX_THINKING_TOKENS=10000` (pre-set values preserved).
- The single canonical fixture is `tests/fixtures/jev_server.py`
  (the earlier `jev_gate_server.py` was deleted during integration QA).
