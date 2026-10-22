# Toolkit Architecture — Implementation Reference

Source: https://github.com/vasic-digital/claude_toolkit via GitHub API (tree + raw files).
Repo name on disk / remote: `claude-toolkit` (remote URL in package.json / curl-install).

## 0. Executive summary

- Language split: **overwhelmingly bash** (`scripts/*.sh`, `scripts/lib.sh` 265 KB, `scripts/claude-providers.sh` 253 KB). **Python** for resolver/verifier/probe/sync helpers (`providers_resolve.py` 64 KB, `model_verify.py` 49 KB, `quota_probe.py` 33 KB, `opencode_sync.py`, `providers_generate.py`, `alias_e2e_test.py`). **Go** for two small tools: `scripts/proxy/` (provider request-transform proxy: hermes/kimi/nvidia/poe/sarvam + registry + main) and `scripts/toon/` (TOON encoder). **JS**: `scripts/toon.mjs` only. No Go module at repo root; each Go dir has its own `go.mod`.
- Supported agent families TODAY: **Claude Code**, **Kimi Code CLI** (v1.27.0), **Pi CLI** (`pi-<id>` twins, `PI_CODING_AGENT_DIR` + `models.json`), **OpenCode** (config sync only, via `claude-opencode-sync`). **No aider / continue.dev / Cline / crush anywhere** (grepped scripts + README + CLAUDE.md + CHANGELOG.md: zero hits).
- **No mention of Jev, decision models, systemone, or "system one" anywhere** in scripts, README.md, CLAUDE.md, or CHANGELOG.md (grepped; zero hits). Token-consumption reduction today = the **TOON** encoder utility ("~40% fewer tokens for structured prompt data") + token guards (`CLAUDE_CODE_AUTO_COMPACT_WINDOW`, `CLAUDE_CODE_MAX_OUTPUT_TOKENS`, context carve `CMA_INPUT_FLOOR`).
- The extension point for a new provider family is the **claude-providers engine**: detector functions → `resolve_records()` → per-family renderers (`cma_provider_write_env` for Claude, `_cma_kimi_render_config` for Kimi, `_cma_pi_render_config` for Pi) → alias lines in one managed alias file. llmctl integration is the template to copy for Jev local servers.

## 1. Directory layout & script responsibilities

Root docs: `README.md` (+ `.html/.pdf/.docx` renders), `CHANGELOG.md` (295 KB, Keep-a-Changelog-ish versioned history, plus docx/html/pdf renders), `CLAUDE.md` == `AGENTS.md` == `GEMINI.md` == `QWEN.md` (same ~52 KB agent-guidance file, byte-size identical), `Claude_Multi_Account_Fine_Tuning.md` (long-form guide), `Kimi_Accounts_User_Guide.md`, `OpenCode_Integration.md`, `.claude-cwd-hook` (project-local cwd hook; prints nothing, exit 0), `package.json` (only dep: `@toon-format/toon`), `.gitmodules` (submodules: LLMsVerifier, containers, challenges, claude-code-router, go, superspec, constitution).

```
scripts/
  lib.sh                      # 265 KB shared library: every script sources it. Defines SHARED_DIR,
                              # ALIAS_FILE, wrappers (cma_run, cma_run_provider, cma_run_kimi*,
                              # cma_run_pi*), alias-file committer, settings seeding, quota rendering.
  claude-providers.sh         # 253 KB provider engine: detectors, resolve_records, sync/verify/quota/
                              # limits/add/remove/migrate-names/sync-all-llmctl/helixllm-export;
                              # per-family config renderers. THE file to extend for Jev.
  kimi-providers.sh           # thin Kimi-framed dispatch over claude-providers.sh (sync|list|show|verify|migrate-names)
  providers_resolve.py        # "dynamic brain": keys-file var NAMES + models.dev cache + key-aliases.json
                              # + overrides.json + legacy-renames.json -> provider records JSON. Pure/offline.
  providers_generate.py       # multi-alias generation from model_verify.py's verified_models.json
  model_verify.py             # live model verification against provider endpoints
  quota_probe.py              # usage/quota endpoint probing
  opencode_sync.py            # plugin-cache -> opencode.json translator (skills.paths/mcp/instructions)
  alias_e2e_test.py           # alias end-to-end driver
  toon_encode.py / toon.mjs   # TOON (token-efficient JSON) wrappers; Go impl in scripts/toon/
  install.sh                  # bootstrap: dep check, symlink every claude-*/kimi-* script into ~/.local/bin,
                              # PATH wiring, managed alias file + rc sourcing, unify, doc refresh, npm install
  curl-install.sh             # curl-pipe installer (clone/pull + install.sh)
  claude-bootstrap.sh         # clean-slate provisioning (--count N / --aliases)
  claude-add-account.sh / claude-remove-account.sh / claude-list-accounts.sh
  claude-unify.sh             # merge ~/.claude-* account dirs into $SHARED_DIR (symlink model)
  claude-sync-state.sh        # jq merge of .claude.json session index (pull/push around launches)
  claude-session.sh           # per-project auto-session naming/color helper
  claude-opencode-sync.sh     # bash front-end to opencode_sync.py
  claude-ccr-build.sh / claude-proxy-build.sh / claude-go-build.sh  # Go builds (vendored toolchain)
  ccr-install.sh              # claude-code-router installer (submodule)
  claude-gc.sh, claude-rollback.sh, claude-release-gate.sh, claude-export-docs.sh,
  claude-semantic-visibility.sh, providers-semantic.sh, providers-verify.sh,
  claude-install-verify.sh, claude-verify-providers.sh
  kimi-add-account.sh / kimi-remove-account.sh / kimi-list-accounts.sh / kimi-unify.sh / kimi-rollback.sh
  providers/*.json            # pins: llmctl.json, helixagent.json, helixagent-native.json, helixcoder.json,
                              # helixllm-gateway.json, helixllm/*.json (18 upstream pins), opencode-zen.json,
                              # opencode-go.json, chutes.json, hyper.json, tokenrouter.json, overrides.json,
                              # key-aliases.json, legacy-renames.json, credit-endpoints.json,
                              # quota-endpoints.json, judge.env.template, fixture/, rubric/, evidence/
  proxy/                      # Go: provider request-transform proxy (hermes.go, kimi.go, nvidia.go, poe.go,
                              # sarvam.go, registry.go, main.go + *_test.go). Prefix-matched by family
                              # (poe2->poe, kimi-k2->kimi); invoked `--has-transform`.
  toon/                       # Go TOON encoder (encode.go + tests + testdata)
  systemd/                    # claude-toolkit-sync.service/.timer
  bash-completion/claude-toolkit-completion.bash
  tests/                      # see §5
config/containers/llmsverifier/   # Docker/Prometheus/Grafana packaging of LLMsVerifier + patches
docs/                         # Provider_Aliases_User_Guide.md (83 KB), Provider_FAQ.md,
                              # Provider_Verification_Guide.md, SESSION_COLOR.md, TOON_Integration.md,
                              # CONTINUATION.md, MULTI_HOST_ROLLOUT.md, diagrams/ (mmd+svg),
                              # investigations/, llmctl/ (quickstart/user-guide/FAQ), qa/, research/,
                              # superpowers/{plans,specs}
specs/                        # speckit feature specs: 001-llmctl-integration-hardening,
                              # 002-provider-usage-command (spec/plan/tasks/research/contracts/data-model)
.specify/, .claude/skills/    # speckit/superspec skill bundles (project-level Claude skills)
submodules/, constitution/    # git submodules
upstreams/                    # GitHub.sh / GitLab.sh / GitFlic.sh / GitVerse.sh push helpers
qa-results/                   # committed QA evidence logs
```

## 2. How each agent is configured TODAY

### Shared state paths (lib.sh lines 16–24)
```bash
: "${SHARED_DIR:=$HOME/.claude-shared}"
: "${ALIAS_FILE:=$HOME/.local/share/claude-multi-account/aliases.sh}"
```
Provider state dir: `cma_providers_dir() { echo "$HOME/.local/share/claude-multi-account/providers"; }` — holds `<id>.env`, `status.json` (activation gate), `<id>.token` (Kimi OAuth snapshots), `helixllm-models.json`. Keys file: `CMA_KEYS_FILE` default `$HOME/api_keys.sh` — **secrets live ONLY here**, read at launch.

### Claude Code (family: claude)
- Native accounts: dirs `~/.claude-<name>` (`ACCOUNT_PREFIX=.claude-`), home env `CLAUDE_CONFIG_DIR`; `~/.claude` is the excluded user-scope root. Most entries are symlinks into `~/.claude-shared/` (projects, todos, tasks, plans, history.jsonl, plugins, CLAUDE.md…). PRIVATE: `.credentials.json`, `.claude.json` (partially synced), `mcp-needs-auth-cache.json`.
- **settings.json**: deliberately NOT symlinked ("§11.4 own-settings"): each config dir gets its OWN `<dir>/settings.json`, seeded from `~/.claude-shared/settings.json` by `cma_own_settings_seed`, with `enabledPlugins` union-merged (`cma_enable_plugins` writes `.enabledPlugins["<plugin>@<marketplace>"] //= true`). No `"hooks"` key is written by the toolkit into settings.json (grep: no SessionStart/hooks JSON emission) — all "hooks" are shell-level (see §4).
- Provider aliases: dir `~/.claude-prov-<id>/` (prefix `.claude-prov-`), plus a non-secret env file `~/.local/share/claude-multi-account/providers/<id>.env` written verbatim by `cma_provider_write_env` (lib.sh ~4182):
```bash
# generated by claude-providers — non-secret. Do not edit by hand.
# Secrets are NEVER stored here; the key is read from the keys file at launch.
CMA_PROVIDER_ID='<id>'
CMA_PROVIDER_KEYVAR='<KEY_VAR_NAME>'
CMA_PROVIDER_TRANSPORT='<native|router>'
CMA_PROVIDER_BASE_URL='<base url>'
CMA_PROVIDER_MODEL='<strong model>'
CMA_PROVIDER_FAST_MODEL='<fast model>'
CMA_PROVIDER_CONFIG_DIR='$HOME/.claude-prov-<id>'
CMA_PROVIDER_CONTEXT_LIMIT='<int>'   # -> CLAUDE_CODE_AUTO_COMPACT_WINDOW
CMA_PROVIDER_MAX_OUTPUT='<int>'      # -> CLAUDE_CODE_MAX_OUTPUT_TOKENS
CMA_PROVIDER_ALIAS='<alias name>'
# optional preserved knob: CMA_PROVIDER_TRIM='bare'
```
  At launch `cma_run_provider <id>` sources this, sources `api_keys.sh`, and exports for the `claude` binary: `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` (from the key var), `ANTHROPIC_MODEL`, `ANTHROPIC_SMALL_FAST_MODEL`, plus tier pins `ANTHROPIC_DEFAULT_OPUS_MODEL/SONNET/HAIKU/FABLE` (native branch) and the two token guards. Router-transport providers can be dialed through the Go proxy (`$SHARED_DIR/proxy`) or claude-code-router when the family needs request transforms. Launch is gated on `status.json` `.["<id>"].status == "verified"` unless `--force`.

### Kimi Code CLI (family: kimi, v1.27.0)
- Home env `KIMI_CODE_HOME`; accounts `~/.kimi-code-<name>`; user-scope root `~/.kimi-code` (OAuth creds at `~/.kimi-code/credentials/kimi-code.json`, ~15-min tokens, refreshed via `kimi -p hi`); provider homes `~/.kimi-prov-<id>/`; shared store `$SHARED_DIR/kimi/`; shared items: `AGENTS.md plugins skills sessions session_index.jsonl`.
- **Config written: `~/.kimi-prov-<id>/config.toml`** (only writer: `_cma_kimi_render_config` in claude-providers.sh ~2913; secret-bearing, umask 077, atomic rename). Verbatim template:
```toml
default_model = "<id>/<strong>"

[providers."<id>"]
type = "<openai|anthropic>"        # from transport: native->anthropic, else openai
base_url = "<base>"
api_key = "<resolved key value>"

[models."<id>/<strong>"]
provider = "<id>"
model = "<strong>"
max_context_size = <ctx>           # default 128000
max_output_size = <max_out>        # carved < ctx, ceiling 128000
capabilities = [ "tool_use", "thinking" ]
```
  `default_model` MUST precede any `[table]` (regression guarded by `test_kimi_render_config_default_model_toml.sh`). `kc-*` ids render no kimi config. Wrapper `cma_run_kimi_provider <id>` reads `default_model`/`base_url` from this file and launches `kimi -m <id>/<strong>` (Kimi HAS `-m`; Pi does not).

### Pi CLI (family: pi)
- Account prefix `.pi-` (`~/.pi-<name>`, detection markers `config.toml|credentials|sessions|session_index.jsonl`); provider homes `~/.pi-prov-<id>/`; binary resolution: `$PI_BIN` → `~/.pi/bin/pi` → `~/.local/bin` → PATH. Shared subdir `$SHARED_DIR/pi/`; shared items same as kimi.
- **Config written: `~/.pi-prov-<id>/models.json`** (only writer: `_cma_pi_render_config`, claude-providers.sh ~2846). Root-cause comment documents that Pi has NO TOML reader and NO `PI_HOME`; the real override is env `PI_CODING_AGENT_DIR` (default `~/.pi/agent`) and a JSON file named exactly `models.json`. Verbatim jq build:
```json
{
  "providers": {
    "<id>": {
      "baseUrl": "<base (trailing / stripped)>",
      "api": "openai-completions",        // native -> "anthropic-messages"
      "apiKey": "<resolved key value>",
      "models": [ { "id": "<strong>", "contextWindow": <ctx, default 2000000> } ]
    }
  }
}
```
  Wrapper `cma_run_pi_provider <id>` exports `PI_CODING_AGENT_DIR="$HOME/.pi-prov-<id>"`, reads provider/model id + baseUrl from models.json, same `status.json` verified-gate, passes `--model` (no `-m`). Stale `config.toml` is `rm -f`'d on render.

### OpenCode
- Config file: `~/.config/opencode/opencode.json` (override `OPENCODE_CONFIG`), written by `claude-opencode-sync.sh` + `opencode_sync.py` (idempotent/additive, backs up first). Translates Claude plugin cache (`~/.claude/plugins/cache/claude-plugins-official`) into opencode keys: `skills.paths` (dirs containing `<skill>/SKILL.md`), `mcp` (from each plugin's `.mcp.json`, translated transports; enabled per curated allowlist or `--enable-all[-local-runnable]`), and `instructions` (from shared `CLAUDE.md`). Stats via `--stats`. Providers for opencode itself are NOT written by the toolkit — opencode is also a *backend* (opencode-zen1..5 / opencode-go1..5 detector records pinned in `providers/opencode-zen.json` / `opencode-go.json`, base `https://opencode.ai/zen[/go]/v1`).

### llmctl registration (the model to copy for Jev local servers)
`detect_llmctl_records()` (claude-providers.sh ~2061): pins `providers/llmctl.json`:
```json
{ "bin": "llmctl", "key_var": "LLMCTL_API_KEY", "transport": "router",
  "context_limit": 8192, "max_output": 4096 }
```
Runs `llmctl plan --json` → `.profiles.<name>.port` (fixed catalog-assigned port per profile; e.g. 8080 = "fast"); probes each `http://127.0.0.1:<port>/v1/models` (bounded-parallel batches, timeout `CMA_LLMCTL_HTTP_TIMEOUT=3`); extracts `.data[0].id` + `.meta.n_ctx`; checks LAN exposure via `ss`; warns when ctx < `CMA_INPUT_FLOOR(160000)+8192`. Emits one record per RUNNING profile:
```json
{ "key_var": "LLMCTL_API_KEY", "classification": "llm",
  "provider_id": "llmctl-<name>", "alias": "llmctl-<name>",
  "base_url": "http://127.0.0.1:<port>/v1", "transport": "router",
  "strong_model": "<served model id>", "fast_model": "<same>",
  "context_limit": <n_ctx>, "max_output": 4096, "lan_exposed": <bool>,
  "status": "resolved", "reason": "llmctl profile <name> live at ..." }
```
llama-server has no API key (confirmed in llmctl's scheduler); `LLMCTL_API_KEY` is a placeholder for future auth proxies. Aliases auto-appear/disappear with running servers; on-demand exclusive switch via `_cma_llmctl_ensure_active` (`llmctl status` → `llmctl switch <profile>`) fires inside every `llmctl-*` alias launch. `claude-providers sync-all-llmctl` sweeps the full catalog deterministically.

## 3. Alias system

All aliases live in ONE managed file `~/.local/share/claude-multi-account/aliases.sh`, sourced from `~/.bashrc` + `~/.zshrc` (Linux) / `~/.zshrc` (macOS) inside `# cma-rc:* BEGIN/END` blocks. Every write funnels through `cma_alias_commit` (full-file render → sanity gate `_cma_alias_gate` → exclusive lock → atomic `mv`; byte-identical no-op guard; `CMA_ALIAS_LOCK_WAIT=0` in the session hook). Wrapper function bodies (`cma_run`, `cma_run_provider`, `cma_run_kimi`, `cma_run_kimi_provider`, `cma_run_pi`, `cma_run_pi_provider`, session hook, `command_not_found_handler`) are emitted INTO the file by `_cma_emit_managed` and eval'd from it — self-contained, no lib.sh at runtime.

Alias line forms (verbatim patterns):
```bash
alias claude1="CLAUDE_CONFIG_DIR=$HOME/.claude-1 cma_run"          # native Claude account
alias kimi1="KIMI_CODE_HOME=$HOME/.kimi-code-1 cma_run_kimi"       # native Kimi account
alias pi1="PI_HOME=$HOME/.pi-1 cma_run_pi"                         # native Pi account (marker only; PI_HOME is inert)
alias <id>="cma_run_provider <id>"            # Claude over provider backend (e.g. deepseek, llmctl-fast)
alias kimi-<id>="cma_run_kimi_provider <id>"  # Kimi Code over the SAME backend
alias pi-<id>="cma_run_pi_provider <id>"      # Pi CLI over the SAME backend
```
Namespace contract (lib.sh comment, verbatim): "`claudeN/kimiN` are native accounts; `<id>` (no prefix) is ALWAYS Claude Code over that backend; `kimi-<id>` is ALWAYS Kimi Code over the SAME backend; `kc-<id>` is Claude Code over a Kimi-native backend (legacy rename)." Provider namespaces `pi-*|kimi-*|kc-*` are reserved and rejected for account alias names. There is no `claude-native` alias; native = `claudeN`. llmctl aliases: `llmctl-<profile>` / `kimi-llmctl-<profile>` / `pi-llmctl-<profile>`. `claude-providers list` renders per-agent rows (agent=claude/kimi/pi).

## 4. Hooks / plugins / MCP / skills machinery

- **Claude Code plugins**: enabled via `enabledPlugins` in per-dir `settings.json` (union-seeded from shared). `CMA_ALWAYS_ON_PLUGINS` (claude-providers.sh line 43) is force-enabled on every sync. Plugin manifests (`installed_plugins.json`, `known_marketplaces.json`) are path-rewritten into `$SHARED_DIR/plugins/` by unify.
- **Claude Code `settings.json` "hooks"**: NOT used by the toolkit. Hooks are shell-level: (a) the **provider session-refresh hook** (`cma_install_session_hook` / `_cma_emit_session_hook` → `cma_providers_session_refresh`) installed into the alias file — on every interactive shell start rewrites provider aliases from cache (no network) and kicks a detached full sync when `status.json` is older than `CMA_PROVIDERS_SYNC_TTL` (24 h); (b) the **cwd hook** (`.claude-cwd-hook` in a repo root, else `~/.local/bin/claude-cwd-hook`) consulted by `cma_run`/`cma_run_provider` before launch; (c) `command_not_found_handler` emission for account dispatch.
- **MCP**: Claude-side MCP servers come from installed plugins (`.mcp.json` per plugin; `mcp-needs-auth-cache.json` is private per account). OpenCode-side registration is generated by `opencode_sync.py` (`build_mcp`: dedupe identical transports, allowlist default: context7, microsoft-docs, cloudflare, mintlify, qt-docs, awsknowledge, appwrite, mapbox, awspricing, shopify; disabled-but-present otherwise).
- **Skills**: Anthropic-format `SKILL.md` dirs — synced to OpenCode `skills.paths`; Kimi/Pi shared stores symlink a `skills/` item; the repo itself carries project skills under `.claude/skills/speckit-*` and a superspec extension under `.specify/extensions/superspec`.
- **Pi/Kimi extension machinery**: none beyond shared `plugins/skills` symlinks and their config files.

## 5. Test harness

Plain bash, llmctl-independent (own harness, but same conventions family). `scripts/tests/run-all.sh` discovers `test_*.sh`, runs each in a subshell, tallies via `summary` exit code, and cross-checks that no `[FAIL]` printed with exit 0 (harness-integrity). `run-proof.sh` runs a 6-leg proof (hermetic suite + live OpenCode/providers/aliases + alias e2e + constitution) with evidence in `scripts/tests/proof/`. Suite serialization: `lib/suite-lock.sh` (`flock` or mkdir-lock, exit 75 on timeout, re-entrant via `CMA_SUITE_LOCK_OWNER/PATH`). ~90 test files; Go dirs have `go test` (`proxy/*_test.go`, `toon/encode_test.go`).

Test-file conventions (CLAUDE.md "Test harness conventions"): source `lib/assert.sh` + `lib/sandbox.sh`; `make_sandbox` (mktemp `$HOME` matching `cma-test.*`, rebinds `SHARED_DIR ALIAS_FILE DEFAULT_DIR ACCOUNT_PREFIX CLAUDE_BIN=/usr/bin/true`, EXIT-trap cleanup); `set +e` after sourcing lib.sh; fixtures via `make_account NAME [--plugins] [--settings JSON] ...`; `sandbox_stub` for `$HOME/.local/bin` stubs (breaks symlinks before writing); live tests are opt-in via `CMA_LIVE_TESTS=1` with named SKIP-never-FAIL gates; determinism seams are env overrides (`CMA_KEYS_FILE`, `CMA_LLMCTL_PINS_FILE`, `CMA_PROVIDERS_DIR`, `OPENCODE_CONFIG`, `CLAUDE_PLUGINS_DIR`, mock `llmctl`/`kimi` stubs on sandbox PATH, `CMA_LLMCTL_HTTP_TIMEOUT`).

Representative test (verbatim header of `scripts/tests/test_kimi_llmctl_integration.sh` — the live llmctl round-trip pattern to clone for Jev):
```bash
CFG="$HOME/.kimi-prov-llmctl-small/config.toml"
PROVIDER_ID="llmctl-small"
_skip() { echo "SKIP: $1" | tee -a "$EV"; cma_proof_commit "$EV" "$EV_FINAL"; summary; exit 0; }
[[ "${CMA_LIVE_TESTS:-0}" == 1 ]] || _skip "live host-state test: set CMA_LIVE_TESTS=1 to run against real state"
_status="$(jq -r --arg i "$PROVIDER_ID" '.[$i].status // "absent"' "$STATUS_JSON" 2>/dev/null)"
[[ "$_status" == "verified" ]] || _skip "$PROVIDER_ID is not verified (status=$_status) — run: claude-providers sync $PROVIDER_ID"
_models_body="$(curl -sf --max-time 5 "${_base_url%/}/models" 2>/dev/null)" || _models_body=""
[[ -n "$_models_body" ]] || _skip "llmctl server not reachable at $_base_url (is 'llmctl start small' running?)"
grep -q "^alias kimi-$PROVIDER_ID=" "$ALIAS_FILE" || _skip "kimi-$PROVIDER_ID alias not present in $ALIAS_FILE"
# then: source "$ALIAS_FILE"; run the real alias; assert absence of the named failure signature
```
Hermetic structural mirror: `test_kimi_render_config_default_model_toml.sh`; llmctl detector unit coverage: `test_llmctl_detect.sh` (36 KB), `test_llmctl_ondemand_switch.sh`, `test_llmctl_sync_all.sh`, `test_llmctl_lan_exposure.sh`, `test_pi_alias_file.sh`, `test_kimi_aliases.sh`.

## 6. Docs conventions

- README.md: badge row, Why/Features/Quick-start/Daily-commands table/Documentation table/Requirements/Layout sections; every root guide has rendered `.html/.pdf/.docx` siblings regenerated by `claude-export-docs.sh` (pandoc, `<!-- INCLUDE: -->` inlining; engines weasyprint→wkhtmltopdf→chromium).
- `docs/` hosts topic guides + `diagrams/` (.mmd + rendered .svg pairs), dated `investigations/` (`YYYY-MM-DD-topic.md`), dated `research/`, `qa/` evidence dirs, `superpowers/{plans,specs}`, `llmctl/` three-doc set (quickstart→user-guide→FAQ). Feature work follows speckit: `specs/NNN-name/{spec,plan,tasks,research,data-model,quickstart,contracts/,checklists/}`.
- No explicit "no-orphan docs" rule found (grepped CLAUDE.md for orphan: none); linkage is by README Documentation table + cross-links.
- CHANGELOG.md: versioned entries (current v1.27.0), heavily detailed per-release notes; version also pinned in README badge and package.json.

## 7. Jev / decision-model / token-reduction surface

- Zero existing Jev/systemone/decision-model mentions (verified by grep over scripts/, README, CLAUDE.md, CHANGELOG.md).
- Token-reduction machinery today: TOON encoder (`scripts/toon.mjs`, `toon_encode.py`, Go `scripts/toon/`, doc `docs/TOON_Integration.md`, "~40% fewer tokens"); input/output token guards per provider alias; `CMA_PROVIDER_TRIM=bare` minimal-launch knob; Kimi default-system-prompt overhead measured in test comments (~80k tokens with default skills — a real "prompt too long" driver on 8192-ctx llmctl profiles).
- Natural Jev integration seams: (1) new detector `detect_jev_records()` next to `detect_llmctl_records()` (pins file `providers/jev.json`, probe `POST /v1/systemone`); (2) resolver fields flow unchanged; (3) per-family renderers already keyed off `transport`; a new transport value (e.g. `systemone`) would need handling in `_cma_kimi_render_config` typ selection, `_cma_pi_render_config` api_type enum, the Go proxy registry (`scripts/proxy/registry.go`, prefix-matched families), and `cma_proxy_transform_family` in lib.sh; (4) aliases `jev-<id>`/`kimi-jev-<id>`/`pi-jev-<id>` fall out of the existing twin emission; (5) tests: clone the llmctl suite (`test_llmctl_detect.sh` hermetic + `test_kimi_llmctl_integration.sh` live-gated pattern).
