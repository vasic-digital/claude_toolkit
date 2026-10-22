# Design: LM Studio / LMS provider source for Claude Toolkit

**Date:** 2026-10-16  
**Version:** targets Claude Toolkit v1.31.0  
**Author:** Kimi Code (design doc)  
**Status:** pending human approval

## Intent and why

LM Studio is already installed on this host and serves an OpenAI-compatible chat endpoint at `http://127.0.0.1:1234/v1`. The Claude Toolkit provider system already auto-detects cloud providers from API keys, HelixAgent/HelixLLM from PATH/pins, Kimi Code from OAuth, and llmctl profiles. We want LM Studio to become a first-class **local-network provider source** that is refreshed whenever `claude-providers sync` (or the session-refresh hook) runs, so every supported CLI agent can use every loaded model without manual alias wiring.

The aliases must follow the requested pattern:

- `claude-lms-<model>` for Claude Code
- `kimi-lms-<model>` for Kimi Code CLI
- `pi-lms-<model>` for Pi CLI
- (future) `opencode-lms-<model>` for OpenCode CLI

## Goals

1. Detect the LMS server and enumerate loaded LLMs via `lms ps --json` (with the local `/v1/models` endpoint as a fallback).
2. Emit one provider record per loaded LLM, with deterministic, shell-legal ids and aliases.
3. Integrate into `resolve_records()` so the records flow through the existing env/alias/verify/status pipeline.
4. Generate Kimi and Pi per-provider config files so `kimi-lms-*` and `pi-lms-*` twins launch correctly.
5. Generate a `claude-lms-*` alias alongside the existing bare-provider-id alias.
6. Support verification for tool-capable models and honest `unverified` status for models that do not pass the tool-call probe.
7. Add hermetic tests and update all user-facing docs, guides, changelogs, and diagrams.
8. Pass the full release gate (`scripts/claude-release-gate.sh`) and publish v1.31.0 via GitHub and GitLab CLIs.

## Non-goals

- We will not support embedding-only models from LMS as chat aliases (filter on `type == "llm"`).
- We will not auto-start LM Studio; detection is honest about a missing or down server.
- We will not add LMS model-pairing logic for "strong" vs "fast": each loaded model becomes its own alias with `strong_model == fast_model == modelKey`.
- We will not change the existing cloud-provider detection path.

## Anti-goals

- No AI slop, no false verification claims, no aliases for models that cannot actually be reached.
- No hardcoded host paths; everything must be env-overridable.
- No breaking change to existing provider aliases or the namespace contract.

## Constraints

- Provider ids must match `[A-Za-z0-9._-]`; shell aliases must match `[a-zA-Z][a-zA-Z0-9_-]*`.
- `lms ps --json` returns `modelKey` values like `qwen/qwen3.8-27b`, which contain `/` and `.`. Sanitization is mandatory.
- LM Studio's local endpoint requires no API key, but `cma_run_provider()` currently aborts when the key var expands to empty. We must handle this.
- The design must reuse the existing `detect_*_record()` / `resolve_records()` / `cmd_sync()` / verification pipeline; it must not invent a parallel alias system.
- The design must be testable in the existing sandbox model (`scripts/tests/lib/sandbox.sh`).

## Design

### 1. Static pins file

Add `scripts/providers/lmstudio.json` (git-tracked, env-overridable), following the HelixAgent pattern:

```json
{
  "bin": "lms",
  "id": "lmstudio",
  "base_url": "http://127.0.0.1:1234/v1",
  "transport": "router",
  "key_var": "LMSTUDIO_API_KEY",
  "context_limit": 0,
  "max_output": 8192
}
```

Override env vars:

- `CMA_LMS_BASE_URL` — default `http://127.0.0.1:1234/v1`
- `CMA_LMS_BIN` — default `lms`
- `CMA_LMS_ENABLED` — set to `1` to force detection even when the `lms` binary is not on PATH
- `CMA_LMS_PINS_FILE` — path to a custom pins file for hermetic tests

### 2. Detector: `detect_lms_records()`

Add to `scripts/claude-providers.sh` near the other detectors.

Gating:

1. If `CMA_LMS_PINS_FILE` is set and exists, load it; otherwise load `scripts/providers/lmstudio.json`.
2. Detection runs if **any** of:
   - `CMA_LMS_ENABLED=1`
   - the configured `bin` (`lms` by default) is on PATH
   - the pins file exists
3. If gated in, try to enumerate models:
   - **Primary:** `lms ps --json` (if the binary is available). It returns a top-level array of objects with fields `type`, `modelKey`, `contextLength`, `maxContextLength`, `trainedForToolUse`, etc. Filter to `type == "llm"`.
   - **Fallback:** if the CLI is unavailable, `GET ${base_url%/}/models` and read `.data[].id`. The endpoint does **not** distinguish chat models from embedding models, so fallback-derived records are emitted as-is and left to verification to gate honestly.
4. For each loaded LLM, sanitize `modelKey` into a shell-legal provider id:
   - Replace `/` with `-`
   - Replace `.` with `-`
   - Collapse repeated hyphens
   - Strip leading/trailing non-alphanumerics
   - If the result does not start with a letter, prefix `m-`
   - On collision after sanitization, append a numeric suffix (`-2`, `-3`, ...).
   - Example: `qwen/qwen3.8-27b` → `qwen-qwen38-27b`
5. Emit one record per model:

```json
{
  "key_var": "LMSTUDIO_API_KEY",
  "classification": "llm",
  "provider_id": "lms-qwen-qwen38-27b",
  "alias": "lms-qwen-qwen38-27b",
  "base_url": "http://127.0.0.1:1234/v1",
  "transport": "router",
  "strong_model": "qwen/qwen3.8-27b",
  "fast_model": "qwen/qwen3.8-27b",
  "context_limit": 131072,
  "max_output": 8192,
  "status": "resolved",
  "reason": "LM Studio loaded model qwen/qwen3.8-27b",
  "extra_aliases": ["claude-lms-qwen-qwen38-27b"]
}
```

Context/output derivation:

- `context_limit` comes from `.contextLength` in `lms ps --json`; if absent, fall back to `.maxContextLength`; if both absent, default to `128000`.
- `max_output` is pinned to `8192` unless overridden by env/pins.

Offline behavior:

- When `OFFLINE` is set (`--offline`), `detect_lms_records()` returns `[]`. LMS discovery involves a local-network probe to the LMS server; this matches the existing `detect_llmctl_records()` contract and avoids silent failures in air-gapped shells.

### 3. Merge into `resolve_records()`

Call `detect_lms_records()` in `resolve_records()` alongside the other local detectors and merge with `unique_by(.provider_id)`.

### 4. Keyless local launch

LM Studio local endpoint does not require a key. To satisfy `cma_run_provider()`'s token check without changing the shared launch path, the generated `.env` file will set `CMA_PROVIDER_KEYVAR="LMSTUDIO_API_KEY"` and the operator will be instructed to add to `~/api_keys.sh`:

```bash
export LMSTUDIO_API_KEY="local"
```

This is the **minimal-change option**. A future iteration can add a dedicated keyless-local sentinel, but that is out of scope for the initial implementation.

### 5. Alias naming

- Primary provider id / alias: `lms-<sanitized_model>` (Claude Code, because bare id = Claude family).
- Extra Claude-prefixed alias: `claude-lms-<sanitized_model>`.
- Kimi twin: `kimi-lms-<sanitized_model>` (existing `_cma_kimi_twin_alias()`).
- Pi twin: `pi-lms-<sanitized_model>` (existing `_cma_pi_twin_alias()`).

Implementation:

- In `cmd_sync()`, after writing the primary alias, if the record has `"claude_prefixed_alias": true`, also call `cma_provider_write_alias` for `claude-lms-<model>`.
- The `cma_provider_write_env()` call already accepts an optional alias name (10th positional arg). Use it to store the extra alias name in the env file so the session hook can refresh it.

### 6. Kimi / Pi config rendering

The existing `_cma_kimi_render_config()` and `_cma_pi_render_config()` functions will be invoked by `cmd_sync()` for each LMS record because the record has `status == "resolved"` and a valid id. No changes are needed to those renderers unless the keyless-local case requires a dummy key:

- `_cma_kimi_render_config()` already has a loopback-dummy-key branch for `LLMCTL_API_KEY`. We will extend that branch to also apply when `keyvar == "LMSTUDIO_API_KEY"` and the base URL is loopback.
- `_cma_pi_render_config()` already reads the resolved key value from the keys file; with `LMSTUDIO_API_KEY="local"` it will write `"local"` into `models.json`, which LM Studio accepts.

### 7. Verification

Records flow through the standard verification layers:

1. `scripts/providers-verify.sh` probes the exact model with a tool-call.
2. `scripts/providers-semantic.sh` checks code visibility.
3. `scripts/verify_superpowers_tui.sh` (only with `--deep`) runs a live TUI.

Expected outcomes:

- Models with `trainedForToolUse: true` should reach `verified` when the server is up.
- Models without tool support will likely fail at layer 1 and remain `unverified`.
- A server that is down will leave all LMS aliases `unverified`.

The detector will **not** pre-filter on `trainedForToolUse` unless verification proves unreliable; honest status is preferred to silent omission.

### 8. Pi LMS integration note

Pi has its own LMS/LM Studio custom-provider configuration under `~/.pi/agent/` (outside this toolkit). The new `pi-lms-*` aliases are **separate**: they use per-provider `~/.pi-prov-lms-*/models.json` files and the `PI_CODING_AGENT_DIR` override. Pi's native account and any pre-existing Pi LMS provider remain untouched.

### 9. OpenCode scope

OpenCode is currently **not an agent family** in the toolkit; it only receives synced Claude plugin state. Adding `opencode-lms-*` aliases requires introducing a full OpenCode agent family (launcher, config renderer, twin logic). This is documented as **Phase 2** and is not part of the initial implementation.

## Testing

### Hermetic unit tests

1. `scripts/tests/test_lms_detect_loaded_models.sh`
   - Stub `lms` to return a fixture with two LLMs and one embedding model.
   - Assert only LLMs are emitted.
   - Assert provider ids are sanitized correctly.
   - Assert `context_limit` and `max_output` are populated.

2. `scripts/tests/test_lms_alias_family.sh`
   - Stub `lms` and run `claude-providers sync --no-verify`.
   - Assert alias file contains `lms-*`, `claude-lms-*`, `kimi-lms-*`, and `pi-lms-*`.
   - Assert Kimi `config.toml` and Pi `models.json` are rendered.

3. `scripts/tests/test_lms_keyless_dummy.sh`
   - Set `LMSTUDIO_API_KEY=local` in the sandbox keys file.
   - Run the alias launch wrapper up to the token check and assert it proceeds.

4. `scripts/tests/test_lms_modelkey_sanitize.sh`
   - Exercise the sanitize function with edge cases (`/`, `.`, multiple hyphens, leading digits, special chars).

### Live validation

- Run `bash scripts/claude-release-gate.sh`.
- Manually verify each alias launches against the real LMS server:
  - `claude-lms-qwen-qwen38-27b -p "hi" --output-format text`
  - `kimi-lms-qwen-qwen38-27b -p "hi" --output-format text`
  - `pi-lms-qwen-qwen38-27b --model lms-qwen-qwen38-27b/qwen/qwen3.8-27b -p "hi"`

## Documentation updates

- `docs/Provider_Aliases_User_Guide.md`: add an LM Studio section, alias table, env overrides, dummy-key setup.
- `docs/Provider_Verification_Guide.md`: note local LMS verification depends on tool support.
- `Claude_Multi_Account_Fine_Tuning.md`: mention LMS provider source and alias pattern.
- `CHANGELOG.md`: add v1.31.0 entry.
- Rendered `Claude_Multi_Account_Fine_Tuning.{html,pdf}`: regenerate via `scripts/claude-export-docs.sh`.
- Any diagrams under `docs/diagrams/` that show provider sources: add LM Studio box.

## Release

1. Bump version to `1.31.0` in `package.json` (or wherever the canonical version lives).
2. Update `CHANGELOG.md` with the v1.31.0 entry.
3. Run `bash scripts/claude-release-gate.sh`.
4. Create git tag `v1.31.0`.
5. Push to GitHub and GitLab via `gh` and `glab` CLIs, creating a release with the changelog excerpt.

## Calls made by the designer

- Use the minimal-change keyless-local option (`LMSTUDIO_API_KEY=local`) rather than modifying `cma_run_provider()`.
- Add `claude-lms-*` as an extra alias rather than changing the primary id convention; keeps `cmd_remove()` and status lookups simple.
- Use `lms ps --json` as the primary enumeration source; fallback to `/v1/models` only when the CLI is unavailable.
- Keep OpenCode support as Phase 2 because the toolkit has no OpenCode agent family today.

## Open questions for the human

None at design time if the above is approved. The builder-check reviewer may surface additional questions.