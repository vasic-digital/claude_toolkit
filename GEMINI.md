<!-- GEMINI.md — maintained in lockstep with CLAUDE.md / AGENTS.md / QWEN.md per constitution §11.4.157. Same governance body as CLAUDE.md; edit all four together. -->
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A POSIX-leaning bash toolkit (`scripts/`) for running multiple Claude Code accounts on one host while keeping conversation history, memory, todos, plans, plugins, and settings unified across them. Companion long-form documentation lives at the repo root (`Claude_Multi_Account_Fine_Tuning.md` and its rendered `.html` / `.pdf` siblings).

## Common commands

```bash
# Install / re-run bootstrap (symlinks scripts onto PATH, sets up aliases,
# runs unify, refreshes docs). Idempotent.
bash scripts/install.sh

# Run the full test suite (uses a sandboxed $HOME via mktemp). Takes the
# suite lock — a second concurrent run waits, then exits 75.
bash scripts/tests/run-all.sh

# Run a single test file by suffix (e.g. tests/test_lib.sh).
bash scripts/tests/run-all.sh lib
bash scripts/tests/run-all.sh unify add_remove export list

# Regenerate Claude_Multi_Account_Fine_Tuning.{html,pdf} from the .md.
bash scripts/claude-export-docs.sh

# Sync the host's Claude plugin Skills/MCP/CLAUDE.md into OpenCode.
bash scripts/claude-opencode-sync.sh --dry-run --stats   # preview
bash scripts/claude-opencode-sync.sh                      # apply

# Prove everything works: hermetic suite + live OpenCode/providers/aliases +
# alias e2e + constitution (6 legs; evidence in scripts/tests/proof/).
bash scripts/tests/run-proof.sh
```

The per-account user commands installed by `install.sh` (`claude-unify`, `claude-add-account`, `claude-remove-account`, `claude-list-accounts`, `claude-rollback`, `claude-export-docs`, `claude-opencode-sync`, `claude-providers`, `claude-sync-state`, `claude-bootstrap`) end up as symlinks in `~/.local/bin` (`install.sh` auto-links every `claude-*.sh`).

## Go toolchain resolution (`claude-ccr-build.sh`, `claude-proxy-build.sh`)

Both Go build entrypoints prefer a **vendored** toolchain and fall back to system Go:

```bash
VENDORED_GO="${VENDORED_GO:-$HOME/.local/share/claude-go/bin/go}"
_go_bin="${VENDORED_GO:-go}"
if ! command -v "$_go_bin" >/dev/null 2>&1; then
  _go_bin="go"          # <- load-bearing; not optional
fi
```

The `command -v` probe is the whole fallback. Without it the fallback does not exist, because `VENDORED_GO` is assigned a path **string** unconditionally on the line above — it is never empty, so `${VENDORED_GO:-go}` can never reach its `:-go` branch. `install.sh` only *symlinks* `claude-go-build` (building Go from source is deliberately opt-in — see the DECISION block in `claude-ccr-build.sh`, which refuses to download an ~80MB compiler from an alias installer), so `~/.local/share/claude-go` does **not** exist on a normal install and the unguarded form exec'd a missing file: exit 127, `No such file or directory`, on a host whose Go was already the exact version required. Two follow-on symptoms belong to the same root and must not be diagnosed separately: the `cma_log` version line prints EMPTY (its `"$_go_bin" version` also failed, stderr swallowed by `2>/dev/null`), and the resident-artifact branch then reports `(Go version mismatch?)` — false on such a host. A usable resident `ccr` downgrades this to a warning + exit 0, so the defect is invisible on an established machine and a hard install failure on a fresh one.

`submodules/go` is pinned to the version `submodules/claude-code-router/go.mod` requires. Never bump it to `origin/master`: that is the unreleased next-major dev tree and carries no `VERSION` file, which `claude-go-build.sh` parses and hard-fails without. Point releases on `release-branch.go1.N` are the only valid bump target, and a bump must be followed by `claude-go-build` + `claude-ccr-build` + the live router legs.

## Router selector semantics (`submodules/claude-code-router`)

A route is `provider,model` on disk. But the router also accepts a **client-supplied** selector in the request's `model` field, and it recognises *two* separators — comma and slash, leftmost wins (`internal/router/selector.go`). Those two are not equally trustworthy, and conflating them cost 16 of 24 verified aliases:

- A **comma** is this project's own route syntax and appears in no model id, so an unknown provider really is a caller error and fails loudly. Silently redirecting it to `Router.default` would bill an upstream the caller never chose.
- A **slash** is ambiguous: it is both Node CCR's `Provider/model` wire format *and* the near-universal `vendor/model` catalog convention (`deepseek-ai/…`, `Qwen/…`, `nvidia/…`).

Once `lib.sh` began exporting `ANTHROPIC_MODEL` for the **router** transport too (`a5e396d`), Claude Code put the raw catalog id in the request body, the router read the **vendor** as a provider name, found none configured in the per-alias config, and returned an unknown-provider error instead of falling through to `Router.default`. The gateway answered **503 in 1-4 ms — before any network call** — and retried with backoff until the launch bound expired. The on-disk route was correct the whole time (`"kilo,nvidia/nemotron-…"` parses fine, its comma comes first), which is why the config looked healthy while every launch died.

The slash form is therefore decided from **evidence, not from the separator**: if some configured provider actually serves the whole string it is a catalog id and routes normally; if nobody serves it the unknown-provider error still stands, so `Ghost/whatever` cannot silently reach Default. A vendor prefix that *collides* with a real provider name (provider `nvidia` serving `nvidia/nemotron-…`) resolves to the whole id, because the split half is absent from `Models` while the full string is present.

Note which gate caught this, and why the others could not: `providers-verify.sh` and `providers-semantic.sh` curl the provider's own `base_url` directly and never touch the ccr route path, so layers 1-3 were green throughout. **Only the layer-4 live launch exercises the real chain** — that is the entire reason that leg exists and why `claude-release-gate.sh` is mandatory before a release commit.

## Architecture

All scripts source `scripts/lib.sh`, which defines the toolkit's vocabulary and the three env-var knobs every script honors:

- `SHARED_DIR` (default `~/.claude-shared`) — the single source of truth for cross-account state.
- `ALIAS_FILE` (default `~/.local/share/claude-multi-account/aliases.sh`) — managed alias file sourced from `~/.bashrc` and `~/.zshrc` on Linux, `~/.zshrc` only on macOS.
- `ACCOUNT_PREFIX` (default `.claude-`) — naming convention for per-account dirs under `$HOME` (e.g. `~/.claude-acct1`). `~/.claude` itself is treated as the user-scope plugin root (`DEFAULT_DIR`), **not** an account dir, and is excluded from auto-detection.

The unification model (`claude-unify.sh`) is:

1. For each item in `SHARED_ITEMS` (projects, todos, tasks, plans, history.jsonl, settings.json, plugins, etc.), merge contents from every detected account into `$SHARED_DIR`, then replace the per-account entry with a symlink into `$SHARED_DIR`.
2. Merge strategy varies by type:
   - **Directories**: two-pass rsync — first pass `--ignore-existing` per account (preserves union), second pass overlays the **last** account (assumed most recently active) to bias toward the freshest content for conflicting files.
   - **`history.jsonl`**: concat all sources + `awk` line-dedupe.
   - **`settings.json`**: `jq -s` deep-merge where right-most wins for top-level keys, except `enabledPlugins` which is a union across all accounts.
   - **`stats-cache.json`**: pick the newest by mtime.
3. `PRIVATE_ITEMS` (`.credentials.json`, `.claude.json`, `mcp-needs-auth-cache.json`) stay per-account (no symlinks into shared). But `.claude.json` is **partially synced** at unify time: `cma_merge_claude_json` deep-merges every account's file so the `projects` subtree (session/MCP/memory index), UX state, and caches are unioned across accounts. Auth keys defined in `CMA_CLAUDE_JSON_PRIVATE_KEYS` (`userID`, `oauthAccount`, `firstStartTime`, `claudeCodeFirstTokenDate`) are written back to each account untouched.
4. Plugin manifests (`installed_plugins.json`, `known_marketplaces.json`) get JSON-rewritten so absolute `installPath` / `installLocation` values point into `$SHARED_DIR/plugins/...` after the move.
5. `~/.claude/CLAUDE.md` (user-scope memory) is promoted into `$SHARED_DIR/CLAUDE.md` and symlinked from every account dir + `$DEFAULT_DIR`.

Every destructive replacement uses the `backup_and_remove` helper, which renames the target to `<path>.preunify.<timestamp>`. `claude-rollback.sh` / `claude-unify.sh --rollback` walks those backups to undo.

`claude-add-account.sh` mirrors the same `SHARED_ITEMS` list when wiring up a brand-new account, so a fresh account starts in lockstep without re-running unify. Keep the two lists in sync when adding new shared items.

**Runtime sync (`claude-sync-state.sh`)**: the alias file installs a `cma_run` shell function that wraps every `claudeN` invocation with a pre-launch `claude-sync-state pull` and post-exit `claude-sync-state push`. This is a lightweight `jq` merge of every account's `.claude.json` — no rsync — so sessions created under one account are visible to all others on the next launch, without anyone having to run `claude-unify` manually.

**Alias-file writes are serialized and atomic (`cma_alias_commit`)**: every mutation of `$ALIAS_FILE` in the toolkit funnels through one committer; nothing else may write, append to, or rename onto the file. This matters because the file is written far more often than it looks — the session-refresh block the alias file installs fires `claude-providers list --refresh-aliases` on every shell start, which called the per-provider alias writer ~21 times, racing `cma_ensure_alias_file`'s own sequential temp+rename migrations and direct `cat >>` appends, with no lock anywhere. Each writer was atomic *in isolation*, which is precisely why it broke: the second writer's read predates the first's rename, so it publishes back a whole file that has lost the first's work — a clean run could destroy the user's aliases. `cma_alias_commit` renders the **complete** file (header, both wrappers, every account alias, every provider alias) into a single temp and publishes it with one `mv`, under an `$ALIAS_FILE`-scoped exclusive lock (`flock(1)` where present, otherwise an atomic-`mkdir` lock with rename-verified stale breaking, since macOS ships no `flock`). Three properties carry the fix: a byte-identical **no-op guard** renders and compares *before* the lock is taken, so a settled host performs zero renames per shell start and never enters the race at all; contention policy is caller-set via `CMA_ALIAS_LOCK_WAIT`, pinned to `0` in the session hook so a shell start can never block (a skipped refresh is harmless — the next writer re-renders from the file); and `INT`/`TERM` are masked across the critical section so an interrupt cannot land between render and rename. A sanity gate refuses to publish a candidate that lost aliases nobody asked to drop, parking it as `<alias-file>.rejected.<timestamp>` and leaving the live file untouched.

## Provider aliases and verification (`claude-providers.sh`)

`claude-providers sync` discovers LLM API keys in `~/api_keys.sh`, resolves each to a provider record via `providers_resolve.py` (models.dev catalog + `providers/key-aliases.json` + `providers/overrides.json`), verifies it, and generates: an env file, a shell alias (`cma_run_provider <id>`), and a config dir (`~/.claude-prov-<id>`) linked into the shared store. `sync --multi` scores every catalog model with `model_verify.py` and pairs the top ones into multiple aliases per provider.

Verification is strict (v1.14.0+) — an alias is launchable only when every applicable gate passes:

1. **Existence (`providers-verify.sh`)**: two live probes against the provider's chat endpoint with the exact alias model — a `VERIFY_OK` sentinel that must be echoed back, and a tool-calling probe (Claude Code is tool-driven, so a chat-only model is useless). Definitive rejections (400/401/402/403/404/412, missing sentinel, error-in-200, no tool call) ⇒ `failed` and the alias is not activated; transient conditions (429/5xx/timeout/no-network) ⇒ `unverified` (created, but the launch gate refuses it). Anthropic-native bases keep their `/anthropic` prefix and are probed as `/anthropic/v1/messages`; versioned bases (`…/v4`) get only `/chat/completions` appended.
2. **Semantic code-visibility (`providers-semantic.sh` + LLMsVerifier `semantic-code-visibility`)**: two rounds — exact-sentinel fixture echo (with a prompt-echo bluff guard) and an independent judge. Genuine failures (incl. 401/402/403/404 on the model under test) demote; transient and judge-side infra errors are an honest SKIP that never demotes.
3. **Live TUI (`verify_superpowers_tui.sh`)**: launches real Claude Code through the alias — opt-in via `claude-providers verify <id> --deep` and the live proof suite. **Route attribution is part of the gate.** A PASS used to be non-attributable: every router-transport provider rewrites its per-alias `Router.default` to itself before launching, but an alias whose `base_url` IS the gateway trips a self-reference guard, skips that rewrite, and inherits the PREVIOUS provider's route — that is how `helixagent` was badged `verified` on a turn served by a different provider. Every evidence file now carries `# ROUTE-INTENDED:` and `# ROUTE-RESOLVED:` (the resolved route is read *after* the launch, so the rewrite is observed rather than the stale pre-launch value), and the leg fails with `# FAIL: route-mismatch` when the two differ, or `# FAIL: route-unknown` when the resolved route cannot be read — never a silent pass. The gate compares **both** router entries, not just `.Router.default`: Claude Code dispatches background sub-requests of the same turn through `.Router.background`, and a turn served *partly* by another backend fails with `# FAIL: route-mismatch-background`. And because a config file only proves what it *says*, the gate additionally requires a **restart receipt** bracketing the launch: `cma_run_provider` runs `ccr restart` under `|| true`, and `cmdRestart` genuinely refuses to bounce an authenticated gateway when `CCR_API_KEYS` is not visible to the call (`submodules/claude-code-router/cmd/ccr/service.go:556-560` returns 1); the bounce is no longer what makes the edit visible — post-ATM-870 (`a6a24e0`) the running gateway applies a config hot-reload in place via `gw.SwapConfig` (an atomic pointer swap; `/health`, `/ready` and routing follow it per-request), so `config.json` edits are picked up live for routing and health — but the swap's timing is not observable from outside the process, and the startup-built outbound proxy client and in-flight request snapshots still do not follow it, so `ccr restart` remains the toolkit's deterministic apply-point and a swallowed failure leaves the apply unproven while the file reads back correct. The router exposes no live-route query (`/health` reports a provider *count*, not a route), so the receipt is either a new `gateway listening on` line appended to the per-alias `~/.claude-code-router/<provider-id>/service.log` past the pre-launch byte offset, or a changed `~/.claude-code-router/<provider-id>/service.json` pidfile; with neither, the leg **fails closed** with `# FAIL: route-unproven` rather than trusting the file. `jq` is a hard precondition, not a silent skip — without it the resolved route is unreadable and the leg takes `route-unknown`, which is right, because that is exactly the state in which `cma_run_provider` also skipped its own rewrite. The whole attribution gate runs *before* every transcript-derived verdict, so a route failure is never absorbed into a provider-status explanation: a rejected key explains a provider that cannot answer, but nothing about an account explains evidence attributed to the wrong backend. Two honest limits on the guarantee: the receipt brackets the **whole launch**, not the individual request (a concurrent rewrite is excluded by the suite lock, not by this gate), and it proves that *a* config load happened, not that the loaded bytes were the ones read back. Native-transport aliases talk to their endpoint directly, so they record an explicit `n/a` and are not route-checked.

In the `--multi` path `model_verify.py` applies the same anti-bluff rules: the sentinel must be present, `verified` requires a passed tool-calling probe, and the 24h verification cache carries a schema version so results from older, weaker logic are never replayed.

**Model-tier policy — credit-aware, mandatory for every provider alias.** Which model an alias runs is decided by whether that provider's account can actually be billed:

- **Credit / purchased tokens available ⇒ the strongest *paid* model** the provider serves that passes verification.
- **No credit ⇒ the strongest *free* model** the provider serves — free tier or $0 cost — subject to exactly the same verification gates.
- **Credit state unknown** (billing probe inconclusive, no billing signal exposed, offline catalog) ⇒ treat it as *no credit* and take the free choice.

The conservative unknown-branch is deliberate and asymmetric: choosing a paid model on an unfunded key fails at launch with a 402/403 and leaves the operator with a dead alias, whereas choosing a free model on a funded key only gives up capability, and the next `sync` corrects it once the credit signal is readable. The rule applies to both the strong and the fast slot, and to every alias the `--multi` path generates. It is a floor on cost safety, not a cap on quality: within whichever tier applies, the pick is still the strongest model that verifies.

A human pin in `providers/overrides.json` (`strong_model` / `fast_model`) still wins over the automatic choice. The policy only decides what happens when nothing is pinned; an operator who wants a specific model on a specific provider pins it and the tier logic steps aside.

Note the ranking this layers on top of: `providers_resolve.py:select_models` historically chose the strong model on capability alone (reasoning-capable first, then newest `release_date`, then largest context, tie-broken by highest output cost as a flagship proxy) and the fast model as the cheapest tool-call-capable one — with no notion of whether the key could pay for either. The credit-aware tier split constrains that ranking to the affordable tier rather than replacing it, and LLMsVerifier carries the matching detection so the tier decision rests on verified evidence rather than a guess. **The mechanism landed alongside this section: the behaviour above is the contract; read the source for the current function, flag, and field names.**

**Kimi Code (OAuth subscription)**: when the `kimi` CLI is signed in, `detect_kimicode_record` discovers every model the subscription serves (`GET /coding/v1/models` ∪ catalog) and emits one alias per model (`kimi-k3`, `kimi-k2p7`, `kimi-for-coding-highspeed`, `kimi-for-coding`) with the same `_CMA_KIMICODE_OAUTH_` sentinel keyvar; OAuth records take precedence over `KIMI_API_KEY`/`ApiKey_Kimi` records (`unique_by` merge, detector first). The launch wrapper refreshes the ~15-minute OAuth token at launch (live credentials file → CLI refresh → snapshot), and routes all `kimi-*` aliases through the Go `cma-proxy` (whose `kimi` transform normalizes tool schemas to the moonshot `#/$defs/` flavor k3 requires), discovered via `cma-proxy --has-transform`.

**HelixAgent (local, single-GPU, mode-switched):** the `helixagent` alias routes Claude Code to a local HelixLLM backend (podman container `helixllm-coder` on `:18434` serving Qwen3-Coder-30B on one RTX 5090 / 32607 MiB), pinned in `providers/helixagent.json` to `context_limit` **229376** — sized not for Claude Code's *first* request (system prompt + tool schemas, ~67K tokens, which 180224 already fit) but for the multi-turn **agent loop**: once the `cma-proxy` `helixagent`-transform fix (below) made tools actually execute, each executed tool feeds output back and the loop accumulates context to ~182,128 tokens, overflowing the old 180224 slot with `400 exceeds context size` ~2 of 3 runs. 229376 restores headroom while still clearing the launch carve floor of 168192 (`CMA_INPUT_FLOOR` 160000 + the 8192 min-output floor); the carve cap is min(229376−160000, 128000) = 69376, but the pin's `max_output` **8192** holds the exported output cap at 8192 (so the co-derived auto-compact window sits at its 200000 cap with ~21K slack). The `helixagent` alias routes through the Go `cma-proxy` (its `helixagent` transform recovers Hermes/Qwen `<function=…>` tool calls that llama.cpp leaks as prose — when the model writes a preamble before the call — into structured `tool_calls`, and it forces `parallel_tool_calls: false` because HelixLLM's streaming path otherwise emits an unbounded loop of identical `tool_calls`) so Claude Code's tools engage. That backend is shared — on the same single GPU — with **HelixCode**, and the two cannot run at once: HelixCode drives HelixLLM in **coder mode** (`-c 24576 --parallel 8` — eight 3072-token slots for its concurrent sub-requests), whereas the `helixagent` alias needs **claude mode** (`-c 229376 --parallel 1` — one large single slot). Switch between the two with `helix_code/scripts/helixllm-mode.sh coder|claude` (that companion repo, **not** this toolkit). **Auto-starting HelixLLM is opt-in and OFF by default** (`CMA_HELIX_AUTOSTART=1|true|yes|on`): booting it claims the single GPU and *evicts* whatever HelixCode had running in coder mode, which a provider alias must never do implicitly just because someone launched it. With auto-start off the pre-flight still reports that HelixLLM is not answering and prints the exact command, so the operator keeps the information and the choice. The pre-flight treats a successful `/health` as healthy and falls back to `/v1/models` (`n_ctx`) for mode detection when `context_limit` is absent, so recent HelixLLM builds that return only `{"status":"ok"}` from `/health` no longer trigger a false "not answering" warning. Note also that everything the pre-flight prints must go through the `_hl_log`/`_hl_warn` fallback emitters, **not** bare `cma_log`/`cma_warn`: this body is emitted into the alias file by a heredoc and that file never sources `lib.sh`, so a bare call prints `cma_warn: command not found` and destroys the message — and here the message *is* the feature. Because coder is the default operational state (HelixCode is the common case), the `helixagent` alias is honestly demoted to `unverified` when HelixLLM is in coder mode. Once HelixLLM is flipped to claude mode, `claude-providers verify helixagent` passes layers 1-3; the `--deep` layer-4 superpowers engagement check is an honest `SKIP` for `CMA_PROVIDER_TRIM=bare` providers because `--bare` intentionally disables the skill surface the challenge requires. The alias therefore becomes `verified` and launchable without forcing.

Statuses live in `~/.local/share/claude-multi-account/providers/status.json`; `claude-providers list` shows only `verified`, `list-all` everything, `list-faulty` the filtered-out rest. The launch wrapper refuses non-`verified` aliases unless `--force`.

**Cross-alias continuity:** `daemon/` + `jobs/` (Claude Code's background-agent registry) are shared items with a roster union merge (`cma_union_rosters`, newer `updatedAt` wins per worker); `_cma_session_flags` applies per-project session resolution to BOTH transports and injects `--resume` for conversation args (via `claude-session existing-id` — never a never-created fallback id). A session or background agent left under one alias is visible and resumable from every other alias.

**Token-limit guards (both transports):** the wrapper exports `CLAUDE_CODE_MAX_OUTPUT_TOKENS` (output cap, `_cma_out_guard` — router providers included; without it they ran with Claude Code's 128000 generic default and long responses died) and `CLAUDE_CODE_AUTO_COMPACT_WINDOW`. The two are **co-derived, not independent**: the window is computed from what the output half actually reserved — `window = min(context - output - tool_budget, 200000)` — so the pair can never sum past the context, which the old independent derivation could not guarantee. `200000` is a **cap, not a gate**: the input guard used to be exported *only* when context ≤ 200000 (fail-open, so large-context providers got no guard at all, and a 200K–270K dead zone got none either); a window is now exported for every known context. Note what the window is — a **compaction trigger**, not a hard cap: it cannot bound tool schemas, which are assembled before any conversation exists to compact.

**Autocompact thrashing guard (v1.26.8):** the raw window above consumes the entire model window (`text + tools + output = context`), leaving zero headroom for the compacted summary itself. After Claude Code compacts, a large file read or tool output can refill the context to the limit within a few turns, producing the "Autocompact is thrashing" error. A safety margin (`CMA_AUTO_COMPACT_SAFETY_MARGIN`, default **24000** tokens) is therefore reserved from the window whenever the provider can afford it without dropping below `CMA_MIN_COMPACT_WINDOW`. The margin lowers the compaction trigger so the post-compact context has meaningful breathing room. Tight providers keep their existing window rather than trade thrashing for a compression loop; operators can raise or lower the margin, or set it to `0` to disable it.

Which is exactly why `CMA_TOOL_TOKEN_BUDGET` (default 80000) matters, and why the dangerous direction is the counter-intuitive one. The output cap is derived as `context − CMA_MIN_COMPACT_WINDOW(120000) − CMA_TOOL_TOKEN_BUDGET`, so **under**estimating the budget *inflates* the output cap and the request overflows — it does not merely "compact earlier". Measured live 2026-07-27 on a host with 227 enabled plugins: real tool input **158112** against the 80000 default produced `46536 text + 158112 tools + 62144 output = 266792` on a 262144 window, a `400` naming those exact numbers. Note the harder consequence: `158112 + 120000` already exceeds 262144, so on such a host **no** output cap makes a 262144-context provider fit — `kilo`, `openrouter2/3` and `opencode-go1` are all structurally too narrow there, while `nvidia` (1000000) and `xiaomi` (1048576) fit comfortably. The lever is the enabled-plugin surface or a wider provider, not the cap. This is also why the release gate's default provider must be one whose context can actually hold the host's tool prefix.

`limit.output` from models.dev cannot be trusted verbatim: **1099 of 5696 catalogued models report `limit.output >= limit.context`** (counted over raw published values, including the 104 rows whose `context` is 0 — the resolver later treats those as unknown rather than as a cap of zero, which is why the both-fields-positive count is 995), which is physically impossible (output is carved out of the context). Those rows need no detector of their own — `providers_resolve.py:derive_limits()` **always carves** the cap out of the context instead of trusting the published one (`min(context − Claude Code's input floor, the CLI's own 128000 ceiling)`, which is strictly below the context on every branch), so any `output >= context` collapses to exactly the cap an absent output would have produced. An earlier pass documented a separate `output >= context` detector; a review proved that disabling it changed **0 of those 5696 rows**, and it has been deleted rather than left as untested code the docs credited with work it did not do. A large but credible output budget is still left alone (xiaomi's `mimo-v2.5-pro` genuinely serves `{context:1048576, output:131072}`). A catalog row carrying `"context": 0` or `"output": 0` is treated as **unknown**, not as a binding cap of zero.

What does need adjudicating is the opposite mislabel — a record whose *context* is fiction. A `:free` record claiming a larger output budget than its own paid sibling now raises a **suspicion, not a verdict**. The earlier version read that number as the record's real context, consulting exactly ONE sibling where the catalog holds 6–16 independent records for the same model, and on the live catalog that inference was a coin flip: it collapsed `nemotron-3-ultra-550b-a55b:free` from 1,000,000 to 65,536 (93.4% of the window destroyed) and `gemma-4-26b-a4b-it:free` from 262,144 to 32,768. The suspicion is now adjudicated against the rest of the catalog — ids are folded across providers by dropping `:free` suffixes and vendor prefixes and case-folding (`normalize_model_key`, indexed once per run by `build_context_corroboration`) — and a context is lowered **only** when at least `MIN_CORROBORATING_PROVIDERS` (**3**) *distinct* providers **other than the accused one** publish a smaller context, and only to the lower median of what those independents publish. Both numbers are arithmetic, not taste. Because the value returned is the lower median, a correction at n=3 is a number 2 of 3 independents publish at or below — an actual majority — whereas at n=2 the lower median *is* the minimum, so a single peer decides alone. The previous round also let the accused vote in its own trial, so `{accused, one peer}` cleared a threshold of 2 and that one peer won outright: a genuine 1,000,000-token window was cut to 8,192 (99.2% destroyed) under a note claiming two independent providers had agreed, when nothing had agreed with anything.

Three further gates bound what may be counted. **Adjudication runs only where the record's `output < context`.** Where `output == context` the row is exhibiting the catalog's commonest mislabel — output copied *from* context, the shape 1099 of 5696 live rows are in, which the carve above already fixes — and weighing that copy against a paid sibling's genuine output cap is a category error, not evidence. It cost three real windows in the previous round (`llama-3.2-3b-instruct:free` 131072→80000, `llama-3.3-70b-instruct:free` 131072→128000, `tencent/hy3:free` 262144→256000); restricting adjudication to the anomaly it was built for leaves all three alone. A **vendor-compatibility gate** (`vendor_of`) stops an unrelated `y/foo` voting against `x/foo` — 392 normalized keys span more than one vendor prefix and 257 of them disagree on context — while a bare, unprefixed id states no vendor and still votes for anything. And one vote per provider, so a host publishing both the paid and the `:free` row cannot vote twice for its own number.

Be exact about what this establishes, because the mechanism **fails in both directions** if read as more than it is. It cannot establish "the model's real context" — **there is no such quantity.** The catalog holds one record per (provider, model) *pair* and each deployment genuinely has its own window: `llama-3.2-3b-instruct` is served at 16000, 32768, 80000 and 131072 by different hosts, and none of them is wrong. It equally cannot establish the legitimate case the anomaly is named for — every peer record describes the **paid** tier, so a `:free` row that really *is* throttled gets corroborated at the paid value and left alone. That blind spot is asserted behaviour, not an oversight, and corroboration must never be described as catching free-tier throttling. What it *can* establish is only that a claim is not credible **as data**: a plausibility ceiling drawn from peers, never a measurement. On the live catalog the gates still restore both false positives and preserve both genuine catches — `nemotron-3-super-120b-a12b` (7 independents, median 262144) and `qwen3-coder` (5, median 262144) corrected, so `openrouter` / `kilo` still derive `262144 / 102144`, while `nemotron-3-ultra-550b-a55b` (4, median 1000000) and `gemma-4-26b-a4b-it` (14, median 262144) are left alone. The asymmetry that governs all of this — understating a window costs capability, overstating kills the alias at launch with a 400 — does **not** license the old inference, because it is bounded by a second one learned from that regression: **an 8192-token output cap on a coding model is itself a dead alias**, so a detector that fires wrongly is not made safe by erring small. That is the reason corroboration exists.

**Unknown limits do not fail open either**: a pinned model the catalog has never heard of used to emit no limits at all, so the wrapper exported neither guard and Claude Code ran its own 128000 output default against an unmeasured window — the same fail-open shape, reached from the other end. An unknown context now resolves to a conservative *measured* number — `UNKNOWN_MODEL_CONTEXT` = 128000, the p10 context across the catalog's tool-call-capable models (**93.95% of those 4544 models publish ≥128000**, so it understates the real window for ~94% of them, which costs capability, and overstates it for the remaining ~6%) — narrowed further by the provider's **own** p10 over its tool-call-capable models, capped by that provider's widest published window and floored at `MIN_USABLE_UNKNOWN_CONTEXT` = 65536. The floor is load-bearing, not decoration: an unfloored percentile puts poe's window at 480 tokens, trading a 400 error for an alias too small to hold Claude Code's own system prompt. But the floor is itself **clamped at the provider's own median**, and only on pools of at least `MEDIAN_CLAMP_MIN_POOL` (3) rows — for the same arithmetic reason the corroboration threshold is 3, since on a two-element pool the lower median *is* the minimum and one narrow row would set the estimate single-handedly. Unclamped, the floor *raised* the estimate above most of a provider's own catalog: `inference` — the very provider that motivated the unknown-model fallback — came out at 65536 against a p10 of 4000, and now yields 16000, `atomic-chat` 32768, while poe, pioneer, nebius and evroc keep the full 65536. The provider ceiling on its own was insufficient — measured as how often the fallback is pulled below the 128000 default, the bare ceiling does so for only **3 of 167 providers (1.8%)** (`inference` 125000, `llmtr` 16384, `morph` 32000) while the per-provider percentile does so for **32 of 167 (19.2%)**, both counts unaffected by the median clamp (which moves only two estimates, `inference` 65536→16000 and `atomic-chat` 65536→32768, each already below 128000 either way). (Whether `pool[-1]` is the term that decides the returned value is a different question, answering 1 of 167 under the shipped clamp and 2 before it — the reading the old "2 of 167" was computed under.) Operator overrides in `providers/overrides.json` are **validated, not trusted**: booleans, floats, zero and negatives are rejected with the reason recorded in `selection_reason`, clean digit strings are honoured and coerced, and an override that cannot carve a usable cap is refused outright in favour of the derived pair — previously `true`, `-1`, `0` and `50000.5` each produced a state where the launch wrapper exported NEITHER guard. The final carve runs over whatever survived — catalog value, model pin, or override alike — so a hand-pinned pair is held to the same physics as a derived one. Proxies may clamp further API-side (`cma-proxy`'s `sarvam` transform tier clamp).

**Account-dir detection (`cma_detect_accounts`)**: matches `~/.claude-*` but skips (a) `*-shared` and (b) non-empty dirs that don't contain any Claude marker file (`projects/`, `todos/`, `plugins/`, `.claude.json`, `.credentials.json`, `history.jsonl`). This excludes tool-config dirs that share the prefix by coincidence (e.g. `.claude-server-commander` for an MCP server).

**rsync exit-code tolerance**: macOS `rsync` returns 23/24 (partial transfer warnings) for benign issues like `unlinkat: Directory not empty` when symlinks straddle the tree. `merge_dir_into_shared` and `absorb_default_plugins` explicitly tolerate those codes; anything else is fatal.

## Test harness conventions

Tests under `scripts/tests/` are plain bash. Each `test_*.sh` file:

1. Sources `tests/lib/assert.sh` and `tests/lib/sandbox.sh`.
2. Calls `make_sandbox`, which `mktemp`s a fresh `$HOME` and rebinds every env var the toolkit reads (`SHARED_DIR`, `ALIAS_FILE`, `DEFAULT_DIR`, `ACCOUNT_PREFIX`, `CLAUDE_BIN=/usr/bin/true`). An `EXIT` trap cleans up via a `cma-test.*` prefix check — never delete a sandbox path that wasn't produced by `mktemp`.
3. After sourcing `lib.sh` (which sets `set -e`), explicitly call `set +e` so failing-by-design assertions don't abort the script.
4. Uses `make_account NAME [--plugins] [--settings JSON] [--history ...] [--memory K:V] [--todo X]` to populate the sandbox before invoking `run_unify` / `run_add_account` / etc.
5. Ends with `summary`, whose exit code feeds `run-all.sh`'s tally.

When adding tests, the real `~/.claude*` state must never be touched — always go through `make_sandbox`.

**Suite serialization (`tests/lib/suite-lock.sh`)**: `run-all.sh` and `run-proof.sh` each call `cma_suite_lock_acquire suite` before doing anything else. Two suite runs overlapping in one checkout — a developer plus an agent, or two agents — cannot produce reproducible results, because the repo mutates while its own tests execute; that is what once made a set of deterministic tests look flaky. On contention the lock waits a bounded `CMA_SUITE_LOCK_WAIT` (default 600s) and then exits **75** (`EX_TEMPFAIL`) rather than hanging; `CMA_SUITE_LOCK_WAIT=0` is fail-fast. It is re-entrant for the nested `run-proof.sh` → `run-all.sh` case: the child inherits the parent's lock via `CMA_SUITE_LOCK_OWNER` / `CMA_SUITE_LOCK_PATH` instead of deadlocking on it, and inheritance is verified rather than trusted (the named PID must be alive, must match the lock path, and must be the PID physically recorded inside the lock), so a forged or stale env var cannot silently disable locking. Backend is `flock(1)` where present, otherwise an atomic `mkdir` lock with rename-based stale breaking (macOS ships no `flock`). The lock lives in the git dir (or `$TMPDIR`), never in the tracked tree.

**Sandbox hygiene (`tests/lib/sandbox.sh`)**: two helpers covering two different failure modes.

- `assert_sandboxed` — called by `make_sandbox`, exits 99 unless `$HOME`'s basename matches `cma-test.*`. It catches a test that never sandboxed at all.
- `sandbox_stub PATH` (content on stdin) — the required way to install a stub anywhere under `$HOME/.local/bin`. It asserts the sandbox, refuses a target that escapes `$HOME`, and — the load-bearing guarantee — **removes an existing symlink before writing instead of writing through it**.

Why `sandbox_stub` exists, and why the sandbox assertion alone does not cover it: `install.sh` symlinks every `claude-*.sh` into `~/.local/bin`, and a shell redirect follows symlinks. A test doing `cat > "$HOME/.local/bin/claude-session"` followed that link and truncated the production `scripts/claude-session.sh` from 201 lines to an 8-line stub (and `scripts/claude-sync-state.sh` from 103 lines to 2), which broke every provider alias with `No conversation found with session ID: …`. `$HOME` **was** a valid sandbox at the time — `install.sh` had created the links inside it — so `assert_sandboxed` passed and could never have caught this class. Breaking the symlink is the part that does. `test_sandbox_hygiene.sh` lints the whole suite mechanically for bare redirects into `.local/bin` and for hardcoded `/tmp` write targets, reporting `file:line`.

## OpenCode integration (`claude-opencode-sync.sh` + `opencode_sync.py`)

`claude-opencode-sync.sh` is a thin bash wrapper (knob parsing, runtime
detection, backup, atomic write) around `opencode_sync.py`, which does the
JSON-heavy scan/translate/merge. It is **additive and idempotent**: existing
OpenCode providers and MCP keys are never clobbered; skill paths and
instructions are unioned; re-running is a no-op on unchanged input.

What it maps from the Claude plugin cache (`CLAUDE_PLUGINS_DIR`, default
`~/.claude/plugins/cache/claude-plugins-official`) into `opencode.json`:

- Plugin `skills/` folders → `skills.paths`.
- `.mcp.json` servers → `mcp{}`, translated to OpenCode's `local`/`remote`
  shapes. **Both** on-disk formats are parsed: wrapped (`{"mcpServers":{…}}`)
  and bare (`{name:{…}}`). `${CLAUDE_PLUGIN_ROOT}` is expanded to the install
  path. Identical servers are deduped by transport identity; genuine name
  clashes are renamed `<plugin>-<name>`.
- `$SHARED_DIR/CLAUDE.md` → `instructions[]`.

**Enable policy** (`opencode_sync.py:build_mcp`): OpenCode connects to every
enabled MCP at startup, so the default enables only a curated allowlist
(`DEFAULT_ALLOWLIST` in the `.sh`) — public no-auth docs servers plus local
servers whose runtime is present and which need no secret env. Everything else
is written `enabled:false` (configured, ready to `opencode mcp auth`). Flags
`--enable-all-local-runnable` and `--enable-all` widen this. Override the list
with `OPENCODE_ALLOWLIST` (one `plugin/server` per line) — the test suite uses
this for deterministic, host-independent assertions.

Tests: `scripts/tests/test_opencode.sh` (hermetic — fakes a plugin tree in the
sandbox, no real `~/.claude`, no opencode binary). `verify_opencode_live.sh`
(live, read-only, writes evidence to `scripts/tests/proof/`; SKIPs if opencode
is absent). `run-proof.sh` runs both and emits `proof/PROOF.md`. The live
verifier captures the full `opencode debug skill` stream before counting —
counting it mid-stream undercounts.

## Portability notes (BSD vs GNU)

The toolkit targets Linux and macOS. Avoid GNU-only constructs: use 2-arg
`awk match()` + `substr`/`RSTART`/`RLENGTH` (not the 3-arg `match($0,re,arr)`
capture form), and portable `mktemp "${TMPDIR:-/tmp}/x.XXXXXX"` (not
`mktemp --suffix`). `cma_ensure_alias_file` only manages `~/.zshrc` on Darwin
(`CMA_RC_FILES`), so platform-sensitive tests must select the rc file the same
way lib.sh does.

## Doc pipeline

`claude-export-docs.sh` reads `~/Documents/Claude_Multi_Account_Fine_Tuning.md` (overridable via `MD_FILE` / `DOC_DIR`), preprocesses `<!-- INCLUDE: relative/path -->` markers via awk to inline external files, then renders self-contained HTML (`pandoc --embed-resources`) and PDF. PDF engines are tried in order: pandoc+weasyprint → pandoc+wkhtmltopdf → weasyprint-on-html → headless chromium. Install at least one PDF engine for full output.

## Upstream remotes

`upstreams/*.sh` each `export UPSTREAMABLE_REPOSITORY=...` for the four mirrors (GitHub, GitLab, GitFlic, GitVerse). These are sourced by external multi-remote push tooling, not by anything in this repo — leave them as one-line exports.
