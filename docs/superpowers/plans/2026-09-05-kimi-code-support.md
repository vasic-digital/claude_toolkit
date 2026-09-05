# Plan — Kimi Code CLI support for the claude_toolkit (v1.27.0)

- Status: in progress (plan executed via subagent-driven development)
- Planned date: 2026-09-05
- Spec: `docs/superpowers/specs/2026-09-05-kimi-code-support-design.md` (commit `430822b`) — this plan is the executable form; any conflict resolves to the spec.

## Why

The toolkit runs multiple Claude Code accounts + provider aliases. This plan adds **full, symmetric Kimi Code CLI support** (same trust mechanisms, same verification standards, same docs/tests/release ceremony), per the approved spec. The 9 unreleased commits since `v1.26.8` ride along into the `v1.27.0` changelog/release.

## What

### Deployable contract (enforced by tests)

| Alias | Agent | Backend |
|---|---|---|
| `claudeN` | Claude Code | native account (`CLAUDE_CONFIG_DIR=~/.claude-<n>`) |
| `kimiN` | Kimi Code CLI | native account (`KIMI_CODE_HOME=~/.kimi-code-<n>`) |
| `<provider-id>` (no prefix) | Claude Code | that provider (`cma_run_provider`) |
| `kimi-<provider-id>` | Kimi Code CLI | **same** provider backend (`cma_run_kimi_provider`) |
| `kc-<provider-id>` | Claude Code | a **Kimi-native backend** (legacy renamed) |

- No-prefix behavior is **unchanged**: `deepseek`, `opencode`, `kimi-for-coding`(→`kc-for-coding`), etc. always launch Claude Code.
- `kc-*` ids must **never** get a `kimi-kc-*` alias (Kimi agent over those = the `kimiN` accounts).
- `kimiN` account aliases must not collide with the reserved `kimi-*` / `kc-*` provider namespaces.

### Legacy rename (one-time, idempotent, breaking-change accepted by user)

`kimi-for-coding`→`kc-for-coding`, `kimi-for-coding2`→`kc-for-coding2`, `kimi-for-coding-highspeed`→`kc-for-coding-highspeed`, `kimi-k3`→`kc-k3`, `kimi-k2p7`→`kc-k2p7`.

Canonical source: new `scripts/providers/legacy-renames.json`. Renamed automatically on sync + via a `migrate-names` subcommand, on: `status.json` keys, `*.env`, `*.token` (`kimi-for-coding.token`→`kc-for-coding.token`), `~/.claude-prov-<old>`→`~/.claude-prov-<new>` (via `backup_and_remove`), alias-file lines, `scripts/providers/key-aliases.json` (`"ApiKey_Kimi": "kc-for-coding"`), `scripts/providers/overrides.json` references, and the emission/token-naming inside `detect_kimicode_record` (`scripts/claude-providers.sh:905-975` — drop/add `alias_for` lines 966-968 and token-name mapping 950-951).

### Non-goals (do not do)

Headless `kimi login` automation; any change to the Claude family, `cma-proxy`, or the no-prefix aliases; a `kimi-sync-state` runtime-state merger; fast-model pairing on kimi aliases (one strong model per kimi alias).

## Key facts (verified on this host, 2026-09-05)

- `kimi` v0.41.0 at `~/.kimi-code/bin/kimi`; live root `~/.kimi-code/` with `config.toml` (`[providers.managed:kimi-code] type="kimi"`, base `https://api.kimi.ai/coding/v1`), `credentials/` (OAuth slots), `sessions/` (workdir-keyed, home-independent ⇒ cross-account share works via symlink+rsync).
- Isolation knob is **`KIMI_CODE_HOME`** (per-home `config.toml` + local session root). Config `[providers.<name>]` supports `type=kimi|anthropic|openai|openai_responses|google-genai|vertexai`, `baseUrl`, `apiKey`; `[models."<name>/<model>"]` carries `max_context_size`.
- Provider ids live on this host: `deepseek` (verified), `opencode`; `gh` 2.98.0 and `glab` 1.116.0 present; remotes github/gitlab/gitflic/gitverse (`upstreams/*.sh`); latest tag `v1.26.8`; main is 9 commits ahead of `origin/main` + spec commit `430822b`.
- Alias-file machinery: `_cma_emit_managed` (`scripts/lib.sh:2639`) renders the managed block (CLAUDE_BIN export + `_cma_emit_ccr_gateway_guard` 930 + `_cma_emit_cma_run` 1103 + `_cma_emit_cma_run_provider` 1210 + `_cma_emit_account_dispatch` 1005); `_cma_alias_render` 2787; `_cma_alias_gate` 2889 (structural floor = CLAUDE_BIN header + `cma_run()` + `cma_run_provider()`); commit path `cma_alias_commit` 2951, `cma_ensure_alias_file` 3028, `cma_write_alias` 3057, `cma_remove_alias` 3086; `CMA_SHARED_ITEMS` 3098; `cma_providers_dir` 3119; `cma_status_cache/write/read/all` 3127-3158.
- `cma_run` (`lib.sh:1109`) shows the wrapper pattern to mirror: self-heal bin, unset leaked provider/token-guard env, optional hooks, `"$CLAUDE_BIN" "$@"`, return rc. `cma_run_provider` (`1212`) shows: `--force` double-scan, `$pdir/$id.env` source, transport branches, token refresh, restart receipt, activation gate.
- `detect_kimicode_record` (`claude-providers.sh:905-975`) is the OAuth-subscription detector (sentinel `_CMA_KIMICODE_OAUTH_`). `cmd_sync` 1700, key-file read ~1730, env write 1914 + ownership checks 1951/2001, `cmd_remove` 2176, `cmd_prune` 2231, `cmd_add` 2292, `cmd_sync_multi` 2314.
- `install.sh` symlinks every `$LIB_DIR/claude-*.sh` into `$BIN_DIR` (loop at line 67), runs `claude-providers sync` softly (180), runs unify on detected accounts (184), self-verifies via `claude-install-verify.sh` (211).
- `claude-add-account.sh` (140 lines) is the template for `kimi-add-account.sh` (interactive + `--alias/--dir/--yes`, `cma_suggest_alias`, `cma_validate_alias`, `cma_link_shared_items`, checked `cma_write_alias`, tmux notice).
- Tests: hermetic under `scripts/tests/` using `tests/lib/assert.sh`+`sandbox.sh` (`make_sandbox`, `sandbox_stub`); live proofs under `scripts/tests/verify_*.sh` writing to `scripts/tests/proof/`; `run-proof.sh` orchestrates; suite lock `tests/lib/suite-lock.sh`. `test_sandbox_hygiene.sh` lints the suite for bare redirects/hardcoded `/tmp`.
- Docs lockstep: `AGENTS.md`/`CLAUDE.md`/`QWEN.md`/`GEMINI.md` edited together; `Claude_Multi_Account_Fine_Tuning.md` + `.html`/`.pdf` via `claude-export-docs.sh`.

## Task breakdown

Work units are ordered so later units can rely on earlier ones. Each unit is TDD: write/extend the test first, watch it fail for the right reason, implement, watch it pass. Run the **full** `scripts/tests/run-all.sh` before moving on; unit local tests suffice within a unit.

### Unit 1 (lib.sh family layer) — foundation, no dependencies

`scripts/lib.sh` only (plus its tests). Scripts in the family defer to these functions.

1. Family constants + helpers:
   - `CMA_KIMI_SHARED_ITEMS=(AGENTS.md plugins skills sessions session_index.jsonl)` (spec §5.2). `AGENTS.md` analog of the `CLAUDE.md` promotion; `sessions/` + `session_index.jsonl` are the kimi equivalents of `history.jsonl`.
   - `cma_kimi_home()` → `~/.kimi-code`; `cma_kimi_account_home(alias)` → `~/.kimi-code-<alias>`; `cma_kimi_provider_home(id)` → `~/.kimi-prov-<id>`.
   - `cma_resolve_kimi_bin()` → prefer `~/.kimi-code/bin/kimi`, then `~/.local/bin/kimi`, then PATH; mirrors the claude resolver (`cma_run:1115-1128`).
   - `cma_detect_kimi_accounts()` — mirror `cma_detect_accounts` (lib.sh:272): match `~/.kimi-code-*`, exclude `*-shared`, exclude non-empty dirs lacking a kimi marker (`config.toml` OR `credentials/` OR `sessions/`).
   - `cma_suggest_kimi_alias()` — find next free `kimiN`.
   - `cma_validate_kimi_alias()` — same name rules as `cma_validate_alias`, PLUS reject `kimi-*` and `kc-*` (reserved provider namespaces).
   - `cma_link_kimi_shared_items(home)` — mirror `cma_link_shared_items` (lib.sh:3248) over `CMA_KIMI_SHARED_ITEMS` into `$SHARED_DIR/kimi/`.
2. Alias-family functions:
   - `cma_write_kimi_alias(name, home)` → `cma_alias_commit add` line `alias <name>="KIMI_CODE_HOME=<home> cma_run_kimi"` (validate via `cma_validate_kimi_alias`, chained-metachar/whitespace guard copied from `cma_write_alias:3057-3075`). Idempotent.
   - `cma_remove_kimi_alias(name)` → `cma_alias_commit` drop.
3. Managed-block emitters (added to `_cma_emit_managed` `lib.sh:2639-2652`, after `_cma_emit_cma_run_provider`):
   - `_cma_emit_cma_run_kimi` emitting `cma_run_kimi()`:
     - self-heal/resolve `KIMI_BIN` (same §11.4.185 pattern as `cma_run:1115-1128`; local copy, not a lib dependency);
     - unset leaked provider/token-guard vars: `ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL` + the four `ANTHROPIC_DEFAULT_*_MODEL` tier vars + `CLAUDE_CODE_MAX_OUTPUT_TOKENS CLAUDE_CODE_AUTO_COMPACT_WINDOW CLAUDE_CODE_MAX_CONTEXT_TOKENS` (a previous provider alias in the same shell must not leak into a kimiN launch);
     - **no** `claude-session`/`claude-sync-state` hooks (kimi owns its session index; runtime merge is a non-goal);
     - launch `"$KIMI_BIN" "$@"`, return rc.
   - `_cma_emit_cma_run_kimi_provider` emitting `cma_run_kimi_provider()`:
     - resolve `KIMI_BIN`; `--force` double-scan identical to `cma_run_provider:1234-1237`;
     - `id="${1:-}"`; config dir `$HOME/.kimi-prov-$id`, config `…/config.toml`, env `$(cma_providers_dir)/$id.env`;
     - activation gate: read `status.json` (via the same rules as `cma_run_provider`); non-`verified` ⇒ refuse with the exact "run claude-providers verify <id>" hint **unless** `--force`;
     - if `config.toml` is missing → refuse with "run claude-providers sync" (never launch on a stale/absent config);
     - CA: if `CMA_PROVIDER_CA_CERT` set+readable+`https://` base ⇒ export `NODE_EXTRA_CA_CERTS` (kimi is a Node CLI; Node *appends*) + `SSL_CERT_FILE` for any Go-adjacent calls before launch; http/CA-less untouched (spec §6.2, mirror of the Claude-side trust wiring);
     - launch per spec §6.3: `"$KIMI_BIN" -m "<host>/<strong-model>" "$@"` under `KIMI_CODE_HOME="$HOME/.kimi-prov-$id"`, where `<host>/<strong-model>` is read from the rendered `config.toml` `default_model` line (never hardcoded, never a placeholder); return rc.
   - `_cma_emit_managed` evals both new emitters (like the existing `eval "$(_cma_emit_...)"` at lib.sh:978).
4. Structural floor: `_cma_alias_gate` (`lib.sh:2893-2895`) additionally requires `^cma_run_kimi() {` and `^cma_run_kimi_provider() {`.

Tests:
- `scripts/tests/test_alias_file.sh` (or new `test_kimi_alias_file.sh`): rendered file always contains `cma_run`, `cma_run_provider`, `cma_run_kimi`, `cma_run_kimi_provider`; `cma_write_kimi_alias` + `cma_remove_kimi_alias` commit/revert atomically; idempotent re-write is a byte-no-op; `cma_validate_kimi_alias` rejects `kimi-x`, `kc-x`; `cma_detect_kimi_accounts` honors markers/exclusion.
- Wrapper launch tests (stub `kimi` via `sandbox_stub` in the sandbox): `cma_run_kimi` resolves bin, unsets leaked provider env, passes args; `cma_run_kimi_provider` refuses when status non-verified (rc≠0, message), honors `--force`, refuses on missing config.toml, exports `NODE_EXTRA_CA_CERTS` only for https+CA providers, and executes the stub with `KIMI_CODE_HOME=` the per-id home.

Run: `bash scripts/tests/run-all.sh kimi_alias_file` (adjust to actual file) + `bash scripts/tests/run-all.sh lib`.

### Unit 2 (kimi account commands) — depends on Unit 1

New scripts cloning the Claude family, s/st/reserving per the invariant:
- `scripts/kimi-add-account.sh` — clone `claude-add-account.sh`: `--alias/--dir/--yes`, `cma_suggest_kimi_alias`, `cma_validate_kimi_alias`, default dir `~/.kimi-code-<alias>`, `cma_link_kimi_shared_items`, checked `cma_write_kimi_alias`, tmux notice, prints `kimiX` + "authenticate with `kimiX`'s interactive login" instead of `/login`.
- `scripts/kimi-remove-account.sh` — clone `claude-remove-account.sh`.
- `scripts/kimi-list-accounts.sh` — clone `claude-list-accounts.sh` over `cma_detect_kimi_accounts`.
- `scripts/kimi-unify.sh` — mirror `claude-unify.sh` structure (SAME governance: backup_and_remove on destructive replaces, `.preunify.<ts>` backsps never deleted by the script):
  - merge target `$SHARED_DIR/kimi/`; two-pass rsync for `sessions/`,`plugins/`,`skills/` (first pass `--ignore-existing` union, second pass last-account overlay — the workdir-keyed session id makes this safe);
  - `AGENTS.md` promoted to `$SHARED_DIR/kimi/AGENTS.md` + symlinked from every kimi home (the `~/.claude/CLAUDE.md` analog);
  - `session_index.jsonl` rebuilt/union-merges identical lines (`awk` dedupe, mirror `history.jsonl`);
  - **never** merge `config.toml`, `credentials/`, `oauth/`, `device_id`, `bin/`, `logs/`, `tui.toml` (per-account private, cp. `PRIVATE_ITEMS`).
- `scripts/kimi-rollback.sh` — mirror `claude-rollback.sh` (prefix-aware: walk `~/.kimi-*` `.preunify.*` backups + `$SHARED_DIR/kimi/`).

Tests: `scripts/tests/test_kimi_accounts.sh` — sandboxed: add (`--yes` non-interactive), alias line present with correct `KIMI_CODE_HOME=`, shared items linked under `$SHARED_DIR/kimi/`, remove archives + drops alias, list shows only marker dirs, suggest returns next `kimiN`, account name `kimi-deepseek` rejected, unify merges two homes' `sessions/` + `AGENTS.md` promotion + `.preunify` backups createable by rollback, private files untouched.

Run: `bash scripts/tests/run-all.sh kimi_accounts` + full `run-all.sh`.

### Unit 3 (provider engine: migration + kimi-<id> emission + config renderer) — depends on Unit 1, independent of Unit 2

`scripts/claude-providers.sh`, `scripts/providers_resolve.py`, new `scripts/providers/legacy-renames.json`, new `scripts/kimi-providers.sh`.

1. `scripts/providers/legacy-renames.json` — the one map: `{"kimi-for-coding":"kc-for-coding", "kimi-for-coding2":"kc-for-coding2", "kimi-for-coding-highspeed":"kc-for-coding-highspeed", "kimi-k3":"kc-k3", "kimi-k2p7":"kc-k2p7"}`.
2. `migrate-names` subcommand (`cmd_migrate_names`): read the map; for each old→new:
   - `status.json` key rename (jq, atomic); `$pdir/<old>.env`→`<new>.env`; `$pdir/<old>.token`→`<new>.token`;
   - `~/.claude-prov-<old>`→`~/.claude-prov-<new>` when old exists and new does not (via `backup_and_remove`);
   - alias-file: drop `<old>` and add `<new>="cma_run_provider <new>"`;
   - rewrite `scripts/providers/key-aliases.json` values through the map (`ApiKey_Kimi`→`kc-for-coding`);
   - rewrite `scripts/providers/overrides.json` keys through the map;
   - audit-log each action; no-op when nothing to do; idempotent (second run = zero lines).
   `cmd_sync` invokes it first.
3. `detect_kimicode_record` (`claude-providers.sh:905-975`): apply the map to emitted ids/aliases (`alias_for` 966-968 → `kc-for-coding`, `kc-for-coding-highspeed`, `kc-k3`, `kc-k2p7`; bare `k3`→`kc-k3` etc.) and to token-file naming (950-951); keep the `_CMA_KIMICODE_OAUTH_` sentinel; context/output limits unchanged.
4. kimi-alias emission (the `--multi`/sync kernel): flag `--kimi-aliases` / `--no-kimi-aliases` (default **on**); for every final provider record `x` emitted to the alias file, when enabled and `x` does not start with `kc-`, also write `alias kimi-<x>="cma_run_kimi_provider <x>"` via `cma_alias_commit`; pruning (`cmd_remove`, `cmd_prune`) drops the `kimi-<x>` twin too. `status.json` stays the single gate (shared backend); the kimi alias is gated by the same record.
5. Per-alias kimi config renderer `_cma_kimi_render_config(id, record)` writing `~/.kimi-prov-<id>/config.toml` (dir `mkdir -p`, `umask 077` build + atomic rename, key material only here, never argv) per spec §6.2, exact shape:
   - `[providers."<id>"]` `type = "openai"` for OpenAI-shaped bases, `"anthropic"` when the base URL carries `/anthropic`, `base_url = <provider base>` (endpoint overrides `CMA_*_BASE_URL` honored — the record already reflects them), `api_key = <same key variable the env file already carries>`;
   - `[models."<id>/<strong-model>"]` with `provider`, `model`, `max_context_size = <context_limit>` (same derived limits as the Claude side), `capabilities = ["tool_use","thinking"]`;
   - `default_model = "<id>/<strong-model>"`;
   - single model per alias (strong only; fast is a non-goal);
   - invoked at sync for every emitted kimi alias; converged away again by a later no-op sync ⇒ also rewrite when the record changed (config content is part of the provider record's convergence).
6. `scripts/kimi-providers.sh` — thin **dispatch wrapper** (spec §7, `_family_id`-style) exposing `kimi-providers sync|list|list-all|list-faulty|show|verify|migrate-names` against the same engine with kimi framing; `list` family surfaces **both** alias kinds with an agent column (claude/kimi) and marks `kimi-<x>` twins.

Tests:
- `scripts/tests/test_kimi_migration.sh` — fixture old-form artifacts (status key, `.env`, `.token`, provider dir, alias line, key-aliases.json with `ApiKey_Kimi→kimi-for-coding`, overrides refs); run `migrate-names`; assert full rename + `.preunify` backups; re-run ⇒ byte-no-op; key-aliases.json now `→kc-for-coding`.
- `scripts/tests/test_kimi_aliases.sh` — sync with a fake verified provider (openai shape and anthropic shape): config.toml rendered with correct type/base/key/max_context_size (++0600), alias file gains `kimi-<x>` and keeps `<x>`; `--no-kimi-aliases` yields no twin; `kc-for-coding` yields **no** `kimi-kc-for-coding`; remove/prune drops the twin; unknown/overridden context uses the same carve the launch wrapper uses.
- Update `scripts/tests/test_providers.sh`, `scripts/tests/test_kimi.sh`, `scripts/tests/test_redact.sh` (add config.toml to redaction checks), `scripts/tests/test_output_tokens.sh`, `scripts/tests/test_session_flags.sh`, `scripts/tests/test_provider_validation.sh` (reject `kimi-`/`kc-` as account id charset, allow `kimi-`/`kc-` as provider id charset), `scripts/tests/test_cma_proxy.sh` expectations where they name legacy ids → kc-*.
- `scripts/tests/verify_superpowers_tui.sh` untouched (it references provider ids only through env).

Run: `bash scripts/tests/run-all.sh kimi_migration kimi_aliases providers kimi` + full `run-all.sh`.

### Unit 4 (install + hygiene + self-verify) — depends on Units 2 & 3 scripts existing

1. `scripts/install.sh`: after the `claude-*.sh` symlink loop (line 67) add the identical loop over `"$LIB_DIR"/kimi-*.sh`; install-time unify step for kimi (if `cma_detect_kimi_accounts | wc -l > 0` ⇒ run `kimi-unify.sh`) mirroring step 184; banner lists kimi-commands; keep the existing soft `claude-providers sync` (now also emits kimi provider aliases + kc renames).
2. `scripts/claude-install-verify.sh`: probe real artifacts — kimi-* links resolvable when the checkout ships them; alias file contains `cma_run_kimi()`/`cma_run_kimi_provider()`; per-id `~/.kimi-prov-*/config.toml` (when status.json has kimi-eligible records) parses.
3. `scripts/tests/test_sandbox_hygiene.sh`: add `kimi-*.sh` to the mechanical lint loop.
4. `scripts/tests/test_install.sh`: sandboxed install over a fake checkout asserts kimi links + banner.

Run: `bash scripts/tests/run-all.sh install sandbox_hygiene` + full `run-all.sh`.

### Unit 5 (Tier B live proof + run-proof + release gate) — after Units 1-4

1. `scripts/tests/verify_kimi_live.sh` (SKIPs when `kimi` absent or not signed in; writes evidence to `scripts/tests/proof/`):
   - native smoke: `kimi -p "Reply exactly: KIMI-OK" --output-format text` contains `KIMI-OK`;
   - provider alias smoke: `kimi-deepseek -p "Reply exactly: KIMI-OK"` contains `KIMI-OK` (through the real rendered `~/.kimi-prov-deepseek/config.toml`);
   - invariant: `deepseek` alias line still must be `cma_run_provider deepseek` (Claude), and `kimi-deepseek` must be `cma_run_kimi_provider deepseek` (Kimi) — grep the alias file, not our source;
   - CA-cert providers: honest SKIP when no `CMA_PROVIDER_CA_CERT`;
   - legacy: assert `kc-for-coding` exists as `cma_run_provider kc-for-coding` and no `kimi-kc-for-coding` echo.
2. `scripts/tests/run-proof.sh`: add a kimi leg invoking the above; emit proven lines in `proof/PROOF.md`; include in the tally.
3. `scripts/claude-release-gate.sh`: add a Kimi smoke layer `--kimi-gate-provider` (default `kimi-deepseek`) running `"Reply exactly: GATE-OK"` through the alias, honest SKIP if not signed in / unavailable, name the gate layer in `--help` and the report.

Run on host: `bash scripts/tests/run-proof.sh` (full) and the gate with the kimi flag.

### Unit 6 (docs + changelog + lockstep) — mostly parallel, finalize after Unit 5

1. `Kimi_Accounts_User_Guide.md` (new, root): quickstart (add/list/remove/unify), kimi-<id> alias model, kc rename note, mini-primer on `config.toml` `providers`/`models`, CA flag, status/verification reuse, non-goals.
2. `Claude_Multi_Account_Fine_Tuning.md`: new Kimi chapter (accounts + provider aliases + shared/private items + migration) with diagrams for the family model (add a kimi box to the architecture diagram `docs/diagrams/`); a `docs/diagrams/kimi-family.svg/mermaid` showing `claudeN / kimiN / <id> / kimi-<id> / kc-<id>` dispatch.
3. `README.md`: feature bullets, command table (kimi-* set), quickstart link to the guide.
4. `Provider_Aliases_User_Guide.md` + `Provider_Verification_Guide.md`: kimi alias naming (`kimi-` prefix), shared-verification note, `--kimi-aliases` flag, rename section.
5. `CHANGELOG.md`: prepend `v1.27.0` — enumerate the 9 unreleased commits (`git log v1.26.8..HEAD --oneline`) + the Kimi feature set + breaking rename note.
6. Lockstep: update `AGENTS.md`, `CLAUDE.md`, `QWEN.md`, `GEMINI.md` together (constitution §11.4.157) — Kimi support section, commands, invariants.
7. Render: `bash scripts/claude-export-docs.sh` regenerates `.html`/`.pdf` (and any `.docx` the pipeline emits).

Verify: docs mention every command/flag this plan ships; `grep -i kimi` hits in all four lockstep files; export succeeds.

### Unit 7 (release) — after Units 1-6 green

1. On `main`, tree clean; run `scripts/tests/run-proof.sh`; run `claude-release-gate.sh` incl. kimi smoke.
2. Commit all work (concise, repo style — e.g. `kimi: v1.27.0 — Kimi Code CLI accounts + kimi-<id> provider aliases (+ renames, docs, tests)` split into logical commits if the caller prefers).
3. Tag `v1.27.0` (annotated); `git push` upstream with `--tags` to all four remotes (`upstreams/*.sh` paths).
4. `gh release create v1.27.0 --generate-notes` (GitHub) and `glab release create v1.27.0 --title v1.27.0` (GitLab); verify: `git ls-remote --tags` on all four remotes; `gh release view v1.27.0` / `glab release view v1.27.0`.
5. Report: evidence paths (`proof/`, release URLs, hash ranges), what was intentionally left out (non-goals), and any honest SKIPs.

## Skill application

- `using-superpowers` / `brainstorming` already applied during design; `writing-plans` is this file.
- Implementation executes via `subagent-driven-development` (parse this plan into `todowrite` + dispatch), `test-driven-development` per unit, `verification-before-completion` before every success claim, `requesting-code-review` before the release gate, `systematic-debugging` on any unexpected failure.

## Universal instructions (for every agent on this plan)

- Do not touch real `~/.claude*`, `~/.kimi-*`, or `~/api_keys.sh` state from hermetic tests — always `make_sandbox` + stub via `sandbox_stub`.
- Never break a symlink when writing under `~/.local/bin` (use `sandbox_stub`, not bare redirects).
- `set -eo pipefail`; portable awk (2-arg `match`), no GNU-only constructs, no hardcoded `/tmp` (use `mktemp "${TMPDIR:-/tmp}/x.XXXXXX"`).
- Every launch-path claim must be tracable to evidence (env var export, wrapper body, config file bytes) — no source-grep as proof.
- `install.sh`-symlinked scripts: never `cat > ~/.local/bin/<name>`; the alias commit path is the only writer of `$ALIAS_FILE` edge cases.
- Preserve the constitution section numbers (§11.4.*) referenced by existing comments; edit lockstep docs as noted, never GLDA.md alone.
- Run the suite with the lock-aware runner (`run-all.sh`), not raw `bash` on a live tree while other tests run.

## Final instructions

- The whole job is done only when: `run-proof.sh` passes, `claude-release-gate.sh` (with kimi smoke) passes, `git tag v1.27.0` pushed to all 4 remotes, GitHub+GitLab releases created, docs rendered, and the summary reports evidence file paths and any SKIPs. Then notify the user.