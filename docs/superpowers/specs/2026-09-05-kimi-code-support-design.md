# Kimi Code Support (Accounts + Provider Aliases) — Design Spec

**Date:** 2026-09-05
**Status:** Approved design (pending written-spec review)
**Author:** OpenCode agent (brainstormed with Milos Vasic)

## 1. Problem & Goal

The toolkit currently runs multiple **Claude Code** accounts (`claude1..N`) and a set of
provider aliases that open **Claude Code** against ~25 LLM backends (deepseek, poe, kilo,
hyper, openrouter, …). Kimi Code exists in the toolkit only as a *backend for Claude Code*
(the `kimi-for-coding`, `kimi-k3`, `kimi-k2p7`, `kimi-for-coding-highspeed` aliases route
the **Claude CLI** to `api.kimi.com/coding/v1` via the `cma-proxy` `kimi` transform).

We now want **first-class Kimi Code CLI** support, symmetric with Claude Code:

1. **Multiple Kimi accounts** — `kimi1`, `kimi2`, `kimi3`, … aliases, each with its own
   `KIMI_CODE_HOME` and its own Kimi OAuth subscription, unified like the Claude accounts.
2. **`kimi-` provider aliases** — `kimi-deepseek`, `kimi-opencode`, … that run the
   **Kimi Code CLI** (`kimi` binary) against the *same* provider backends the no-prefix
   aliases open via Claude Code.
3. **No-prefix invariant** — any provider alias *without* a `kimi-` prefix keeps opening
   Claude Code, exactly as today. No regressions on the existing 25 aliases.

### User decisions (recorded in brainstorm, 2026-09-05)

- `kimi-<provider>` = **Kimi Code CLI agent on the same backend** as the no-prefix alias.
- **Rename** the legacy `kimi-*` backend aliases to `kc-*` (breaking change, accepted).
- Generate `kimi-<id>` for **every provider that verifies**, on every sync.
- Kimi accounts **mirror Claude accounts + shared unification** under
  `$SHARED_DIR/kimi/`.

### Non-negotiable safety constraints

- Existing `claude1..N` **and** the no-prefix provider aliases keep working unchanged.
- `claude-add-account`, `claude-unify`, `claude-providers`, … remain byte-identical in
  behavior for everything they already do.
- Secrets never land in the repo or the alias file; keys are read from the provider env
  records (never argv).
- The `kimi-` prefix means *only* "Kimi Code CLI agent" after the migration — zero
  exceptions.
- Every claim is backed by machine evidence (hermetic suite + live proof legs); no hand
  wave, no bluff.

## 2. Ground Truth (measured on the live host, 2026-09-05)

| Fact | Value | Source |
|------|-------|--------|
| `kimi` CLI installed | `~/.kimi-code/bin/kimi`, v0.41.0 (`command -v kimi`) | live host |
| `kimi` data root | `~/.kimi-code/` (`config.toml`, `credentials/<slot>.json`, `oauth/`, `sessions/`, `session_index.jsonl`, `plugins/`, `skills/`, `region`) | live host |
| Bare-root isolation knob | `KIMI_CODE_HOME` env var (whole data root moves) | `kimi-code` source: `packages/oauth/src/toolkit.ts` `defaultKimiHome`; `apps/kimi-code/src/constant/app.ts` `KIMI_CODE_HOME_ENV` |
| OAuth slot naming | `credentials/<oauth|baseUrl>-hashed.json`; scoped slots for env-overridden endpoints | `packages/oauth/src/managed-kimi-code.ts` `resolveKimiCodeOAuthKey`; live host has `kimi-code-env-0e4f99c69cc27850.json` |
| Custom providers | `[providers.<name>]` `type=kimi\|anthropic\|openai\|openai_responses\|google-genai\|vertexai`, `baseUrl`, `apiKey`; models as `[models."<prov>/<id>"]` with `max_context_size` | live host `config.toml`; `apps/kimi-code/src/cli/sub/provider.ts` |
| Native provider id | `managed:kimi-code`, `type=kimi`, `api_key=""`, `oauth:{storage:file, key:oauth/<slot>}`, base `https://api.kimi.ai/coding/v1` (global) / `https://api.kimi.com/coding/v1` (mainland) | live host `config.toml`; region marker `~/.kimi-code/region` = `global` |
| Headless mode | `kimi -p "<prompt>" [--output-format text\|stream-json]`; auto-approves; exit-code driven; hard-conflicts with `--yolo/--auto/--plan` | `apps/kimi-code/src/cli/commands.ts`, `run-prompt.ts` |
| Token lifetime | server-authoritative `expires_in` (~900 s observed); CLI refreshes lazily at ≤`max(300, 50%)` remaining, cross-process coordinated | `packages/oauth/src/oauth.ts`, `oauth-manager.ts` |
| Login | interactive device flow only (`kimi login` prints URL+code, polls) — no headless login flag | `apps/kimi-code/src/cli/sub/provider.ts` / oauth toolkit |
| Sessions | `KIMI_CODE_HOME/sessions/<workDirKey>/<sessionId>`, workdir-keyed (path hash, home-independent) | `packages/agent-core/src/session/store/workdir-key.ts` |
| Provider id `deepseek` | exists on host, status `verified`, model `deepseek-v4-flash` | `status.json` |
| Provider id `opencode` | exists on host (`ZEN_API_KEY`/`ApiKey_Opencode_Zen` → `opencode`) | `key-aliases.json`, `status.json` |
| Legacy kimi backend ids | `kimi-for-coding` (API key, `ApiKey_Kimi`), `kimi-for-coding2` (2nd key); OAuth-emitted `kimi-k3`, `kimi-k2p7`, `kimi-for-coding`, `kimi-for-coding-highspeed` | `key-aliases.json`, `status.json`, env files, `detect_kimicode_record` |
| Release tooling | `gh` 2.98.0, `glab` 1.116.0 present; remotes github/gitlab/gitflic/gitverse | live host |

## 3. Architecture: the Family Model

An **agent family** is an orthogonal axis from the provider backend. The provider engine
stays shared; each family supplies the agent binary, the home env var, the account
prefix, the user-scope root, and the launcher functions.

| | Claude family (existing) | Kimi family (new) |
|---|---|---|
| agent binary | `claude` | `kimi` |
| home env var | `CLAUDE_CONFIG_DIR` | `KIMI_CODE_HOME` |
| account prefix | `.claude-` | `.kimi-code-` |
| user-scope root | `~/.claude` (`DEFAULT_DIR`, excluded from detection) | `~/.kimi-code` (`KIMI_DEFAULT_DIR`, excluded from detection) |
| account aliases | `claude1…N` | `kimi1…N` |
| account launcher | `cma_run` | `cma_run_kimi` |
| provider launcher | `cma_run_provider` | `cma_run_kimi_provider` |
| per-account shared-items list | `SHARED_ITEMS` | `KIMI_SHARED_ITEMS` |
| shared store area | `$SHARED_DIR/**` (root) | `$SHARED_DIR/kimi/**` |

### 3.1 Namespace rules (the invariant)

```
claudeN        → Claude agent, native Claude account N
kimiN          →  Kimi agent, native   Kimi account N
<id>           → Claude agent, backend <id>          (NO prefix — always Claude)
kimi-<id>      →  Kimi agent, backend <id>            (kimi- prefix — always Kimi CLI)
kc-<id>        → Claude agent, backend = Kimi native  (renamed legacy kimi-* ids)
```

- `kimi-<id>` is generated for every provider id that passes verification, **except** ids
  that already start with `kc-` (Kimi-native backend: the Kimi agent on that backend *is*
  the `kimiN` account, so a `kimi-kc-*` alias would be redundant).
- The no-prefix provider alias (`deepseek`, `opencode`, …) is **unchanged** and still
  launches Claude Code. This is asserted by tests, not assumed.

## 4. Legacy Rename (kimi-* → kc-*)

The `kimi-` namespace must be vacated so the prefix means only "Kimi CLI agent".

### 4.1 Rename map

| Old id / alias | New id / alias | Kind |
|---|---|---|
| `kimi-for-coding` | `kc-for-coding` | provider record (`ApiKey_Kimi` → `kc-for-coding` in `key-aliases.json`) |
| `kimi-for-coding2` | `kc-for-coding2` | mirror API-key record on host |
| `kimi-for-coding-highspeed` | `kc-for-coding-highspeed` | OAuth-emitted model alias (Claude agent) |
| `kimi-k3` | `kc-k3` | OAuth-emitted model alias (Claude agent) |
| `kimi-k2p7` | `kc-k2p7` | OAuth-emitted model alias (Claude agent) |

### 4.2 What a rename touches

- `providers/key-aliases.json` value rewrite (`ApiKey_Kimi` → `kc-for-coding`).
- `detect_kimicode_record` emitted alias/id names (`kc-*`).
- `~/.claude-prov-kimi-for-coding` → `~/.claude-prov-kc-for-coding` via
  `backup_and_remove` (rename, never delete), `*.env` file rename (record kept, not the
  content deleted), `providers/status.json` key rename, alias-file lines.
- The Kimi OAuth token cache file name `$CMA_PROVIDERS_DIR/kimi-for-coding.token` →
  `kc-for-coding.token`.
- Test fixtures referencing the old names.

### 4.3 Migration mechanics

- The provider engine applies the rename **automatically, once** at sync (a
  `migrate-names` pass), with `--dry-run` preview and `--yes` confirm, or as the explicit
  `claude-providers migrate-names` subcommand.
- Idempotent and convergent: running it twice is a no-op.
- Rollback is available via the standard `backup_and_remove` backups
  (`claude-rollback`-style path), documented in the changelog.

## 5. Kimi Accounts (kimi1…kimiN)

### 5.1 New commands (symlinked into `~/.local/bin` by the extended `install.sh`)

- `kimi-add-account <name> [--login]` — create `~/.kimi-code-<name>` (marker + skeleton),
  wire `KIMI_SHARED_ITEMS` symlinks into `$SHARED_DIR/kimi/`, then either drive
  `kimi login` (device flow: prints URL+code, waits for user approval) when `--login`, or
  print the login instructions. All under `KIMI_CODE_HOME=~/.kimi-code-<name>` so the
  login provisions *that* account.
- `kimi-remove-account <name>` — unlink aliases, `backup_and_remove` the home.
- `kimi-list-accounts` — detect via `cma_kimi_detect_accounts` (mirror of
  `cma_detect_accounts`, Kimi marker files: `config.toml`, `credentials/`,
  `session_index.jsonl`); `*_shared` and marker-less dirs skipped.
- `kimi-unify [--dry-run]` — the Kimi analog of `claude-unify`: merge `KIMI_SHARED_ITEMS`
  across detected Kimi accounts into `$SHARED_DIR/kimi/`, symlink back, `backup_and_remove`
  on every destructive replacement.
- `kimi-rollback` — walk `.preunify.<ts>` backups for the kimi family.

### 5.2 KIMI_SHARED_ITEMS (unified; symlinked to `$SHARED_DIR/kimi/`)

| Item | Merge strategy |
|---|---|
| `AGENTS.md` | promoted from the newest/most-active account; symlinked everywhere (memory) |
| `plugins/` | dir union (two-pass rsync + symlink) — mirror `merge_dir_into_shared` |
| `skills/` | dir union (same) |
| `sessions/` | dir union — workdir-keyed, home-independent, so cross-account resume works |
| `session_index.jsonl` | concat + line-dedupe (mirror `history.jsonl` strategy) |

**Private (never symlinked):** `config.toml` (holds `[providers.*]` + OAuth refs),
`credentials/`, `oauth/`, `device_id`, `bin/`, `logs/`, `migrations-effort.json`,
`region`, `telemetry/`, `updates/`, `user-history/`, `workspace-trust/`, `cache/`,
`tui.toml`.

### 5.3 Alias + launcher

`cma_alias_commit` renders, in addition to the current blocks:

```
alias kimi1="KIMI_CODE_HOME=/home/…/.kimi-code-kimi1 cma_run_kimi"
```

`cma_run_kimi`:
1. Resolves the `kimi` binary: `$KIMI_CODE_HOME/bin/kimi` if present, else `command -v kimi`.
2. Prepends the bundled `bin` dir to PATH for the child (the native install lives in the
   data root).
3. Execs `kimi "$@"` under the env vars set on the alias line.

No per-launch state merge is needed (kimi has no `.claude.json`-style file); session
continuity across accounts is delivered by the shared `sessions/` + `session_index.jsonl`
symlinks (workdir-keyed ⇒ home-independent).

## 6. kimi-<id> Provider Aliases

### 6.1 Emission rule

In both `sync` and `--multi`, for every provider record that passes the verification set
(identical to the set that gets a no-prefix alias), additionally emit:

```
alias kimi-<id>="cma_run_kimi_provider <id>"
```

Excluded: ids starting with `kc-` (see §3.1). Controlled by `--kimi-aliases`/`--no-kimi-aliases`
(default on); never emitted for `unverified`/`failed` unless `--force` at launch.

### 6.2 The per-provider Kimi config home: `~/.kimi-prov-<id>`

Mirrors `~/.claude-prov-<id>`. `cma_run_kimi_provider <id>` builds/refreshes a
`config.toml` there:

```toml
[providers."<host>"]
type = "openai"                    # or "anthropic" when the base URL carries /anthropic
base_url = "<provider base_url>"
api_key  = "<key from the provider env record>"

[models."<host>/<strong-model>"]
provider = "<host>"
model    = "<strong-model>"
max_context_size = <context_limit>      # from the same derived limits as Claude side
capabilities = [ "tool_use", "thinking" ]

default_model   = "<host>/<strong-model>"
```

- Key is read from the provider env record under `cma_providers_dir` (`<id>.env`),
  the same record the Claude wrapper uses — never from argv.
- `type` chosen by base-URL shape (the existing native/`/anthropic` knowledge in the
  verifier is reused); `CMA_PROVIDER_CA_CERT` → `NODE_EXTRA_CA_CERTS` (Node appends) +
  `SSL_CERT_FILE` for any Go-adjacent calls, gated on https + cert set (mirror of the
  Claude-side trust wiring).
- Endpoint overrides (`CMA_*` per-provider `_BASE_URL`) honored — same knobs as the
  Claude side.

### 6.3 Launch

```
KIMI_CODE_HOME="$HOME/.kimi-prov-<id>" exec kimi -m "<host>/<strong-model>" "$@"
```

- No `cma-proxy` on this path. The Kimi CLI speaks the OpenAI/Anthropic wire protocol
  natively; the proxy's `kimi` transform exists only to fix **Claude Code** tool schema
  against the moonshot `#/$defs/` flavor and must not be involved.
- Posterity: the kimi config resolves models itself from `config.toml`; no
  `CLAUDE_CODE_*` token guards apply (those are Claude-Code-only env vars).
- The launch gate mirrors the Claude side: refuse non-`verified` ids unless `--force`.

## 7. Provider Engine Changes (`claude-providers.sh` + wrapper `kimi-providers.sh`)

- `sync` / `--multi`: emit `kimi-<id>` aliases per §6.1 after verification.
- `migrate-names` subcommand + automatic one-time rename pass (§4.3).
- `list`/`list-all`/`list-faulty`: surface both alias kinds and mark their agent
  (claude/kimi) column.
- `--no-kimi-aliases` switch.
- `kimi-providers.sh`: thin wrapper script (dispatch-by-name, the existing
  `_family_id`-style pattern) exposing `kimi-providers sync|list|show|verify|migrate-names`
  for the same engine.
- No-prefix emission code paths are untouched; the host's 25 existing aliases render
  byte-identically (regression-proved).

## 8. Machine-Evidence Testing & Proof Strategy

### 8.1 Tier A — hermetic sandbox (no network, fake `kimi`)

New:
- `test_kimi_accounts.sh` — add/remove/list/detect/unify/rollback on the kimi family,
  marker-based detection, `KIMI_SHARED_ITEMS` symlink convergence, account aliases.
- `test_kimi_aliases.sh` — **namespace invariant** (no-prefix → `cma_run_provider`;
  `kimi-<id>` → `cma_run_kimi_provider`; `kimiN` → `cma_run_kimi`; `kc-*` get no kimi
  flavor), config.toml rendering (fake `kimi`, key wiring, `max_context_size` from
  derived limits), CA/endpoint override handling, launch gate.
- `test_kimi_migration.sh` — the kimi→kc rename: key-aliases rewrite, env/status/config
  dir renames, token cache rename, alias-file rewrite, dry-run, idempotence, rollback.

Updated: `test_kimi.sh`, `test_providers.sh`, `test_alias_file*.sh`, `test_install.sh`,
`test_output_tokens.sh`, `test_session_flags.sh`, `test_redact.sh`,
`test_provider_validation.sh` (id charset), `test_sandbox_hygiene.sh` (lint both
`claude-*.sh` and `kimi-*.sh`), `test_coverage.sh` mappings.

### 8.2 Tier B — live proof on this host (evidence files, fail-closed)

- New `verify_kimi_live.sh`:
  1. Native: `KIMI_CODE_HOME=$HOME/.kimi-code kimi -p "Reply exactly: KIMI-OK"`, assert
     rc=0 + reply + evidence file (`# PASS`/`# FAIL` markers, log/header caps).
  2. Provider alias: `kimi-deepseek -p "Reply exactly: KIMI-OK"` through the real
     generated alias, real PATH, real config.toml; assert reply + evidence.
  3. Invariant: assert the no-prefix `deepseek` alias still resolves to
     `cma_run_provider` (Claude) in `aliases.sh`.
  The `-p` update-preflight latency is tolerated (bounded sees ~seconds; no production
  timeout leniency).
- `verify_aliases_live.sh` and `verify_aliases_multi_prompt.sh` gain the kimi alias class.
- `run-proof.sh` gains the kimi leg; `proof/PROOF.md` updated.

### 8.3 Release gate

`claude-release-gate.sh` extended with a Kimi smoke (gate alias from
`--kimi-gate-provider`, default `kimi-deepseek`, or native `kimi -p` fallback) running
"Reply exactly: GATE-OK" and asserting rc + reply + attribution evidence. Any kimi smoke
failure = do-not-release.

## 9. Documentation & Deliverables (kept in lockstep)

Governance: `AGENTS.md`/`CLAUDE.md`/`QWEN.md`/`GEMINI.md` edited together (constitution
§11.4.157); `claude-export-docs.sh` re-renders html/pdf/docx.

- `Claude_Multi_Account_Fine_Tuning.md` — new Kimi Code Architecture chapter (family
  model diagram, namespace rules, account flow, provider alias flow, OAuth/refresh
  explanation).
- `README.md` — kimi commands + alias summary; feature/quickstart sections.
- `Provider_Aliases_User_Guide.md` — kc renames, `kimi-<id>` alias usage, agent column.
- New `Kimi_Accounts_User_Guide.md` — kimiN lifecycle, login device flow, unify/rollback.
- `Provider_Verification_Guide.md` — verification unchanged-but-renamed notes.
- `docs/diagrams/` — family-model graph, kimi-* data flow, account lifecycle diagram.
- `CHANGELOG.md` — **v1.27.0**: the 9 unreleased commits since v1.26.8 + this feature.
- Constitution checks pass (`verify_constitution`, anchors doc).

## 10. Install + Release Plan (final phase, on this host)

1. `install.sh` extension: auto-link `kimi-*.sh` in addition to `claude-*.sh`.
2. Install the working tree to this host; verify symlinks and rc sourcing.
3. Full `scripts/tests/run-proof.sh` — hermetic suite + every live leg (claude + kimi),
   evidence into `proof/`.
4. `claude-release-gate.sh` with kimi smoke — all layers green.
5. Bump **v1.27.0**; write `CHANGELOG.md` section; render all docs (md/html/pdf/docx).
6. Commit + `gh release` (GitHub) + `glab release` (GitLab, env `GITLAB_TOKEN` supplied)
   + `git push` all four remotes (github/gitlab/gitflic/gitverse); verify tags on each.
7. Report completion with the evidence summary.

## 11. Non-Goals & Explicit Deferrals

- No headless/non-interactive Kimi login (device flow is interactive by product design;
  `--login` drives it and pauses for user approval).
- No changes to the Claude family behavior, wrapper, or `cma-proxy` backend paths.
- No `kimi-sync-state` (kimi has no `.claude.json` analog; session continuity comes from
  shared `sessions/`).
- No per-account `kimi` runtime state merge beyond the kimi shared items in §5.2.