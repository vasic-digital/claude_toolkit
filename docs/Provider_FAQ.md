# Provider Aliases — FAQ

## General

### What is a provider alias?

A provider alias is a named configuration that lets you run Claude Code through a non-Anthropic LLM provider. Each alias has its own config directory, API key, and model selection.

### How many providers can I have?

There's no hard limit. Each provider gets its own config directory (`~/.claude-prov-<name>/`) and alias in the shell.

### What's the difference between `native` and `router` transport?

- **Native:** The provider speaks the Anthropic Messages API directly (a base URL ending in `/anthropic`, served as `/anthropic/v1/messages`). Claude Code talks to it without a router. Exactly one shipped provider is pinned to native today — the *local* `helixagent-native` (`scripts/providers/helixagent-native.json`); every hosted provider is pinned to `router`. See the next question.
- **Router:** The provider speaks the OpenAI chat/completions API. Requests go through `ccr` (claude-code-router), which translates between Claude Code's Anthropic format and the provider's OpenAI format.

### Why are the hosted providers all on router transport?

Every `transport` pin in `scripts/providers/overrides.json` is `router` — deepseek, xiaomi, opencode, opencode-go, chutes, kimi-for-coding, hyper. All of them have OpenAI-compatible endpoints that work through ccr, and a single uniform path is much easier to debug than a mix. Xiaomi in particular has moved *off* its Anthropic-native `/anthropic` endpoint onto `https://api.xiaomimimo.com/v1` (see §12 of the Provider Aliases User Guide).

## Model selection

### Which model does an alias run?

The strongest one your account can actually pay for. If the provider account has credit or purchased tokens, the alias runs the strongest **paid** model that passes verification. If it has no credit, the alias runs the strongest **free** model. This applies to both the main model and the fast/background model, and to every alias `sync --multi` creates.

### What if the toolkit can't tell whether I have credit?

Unknown is treated as *no credit*, so you get the free model. That is deliberate: a paid model on an unfunded key fails at launch with a 402/403 and leaves you with a dead alias, while a free model on a funded key only costs some capability. Re-run `claude-providers sync` once the credit signal is readable and the paid model is picked up.

### I bought credit — how do I get the paid model?

Run `claude-providers sync`. Model tier is decided at sync time, not at launch, so an alias created while the account was empty keeps its free model until the next sync re-evaluates it.

### Can I force a specific model regardless of credit?

Yes. Pin `strong_model` / `fast_model` for that provider in `scripts/providers/overrides.json` and re-sync. A pin always wins over the automatic tier choice — including a paid pin on an account with no readable credit, in which case the resulting launch failure is expected.

### Are free models verified less strictly?

No. A free model goes through exactly the same sentinel and tool-calling probes as a paid one, and its alias is not activated unless both pass. The credit rule decides *which* model is tested, never *how strictly*.

## Verification

### Why is my provider showing as "failed"?

Run `claude-providers list-faulty` to see the failure layer. Common causes:
- **failed/existence:** API key invalid, account suspended, or endpoint unreachable
- **failed/tool-call:** Model doesn't support tool calling

### Why is my provider showing as "unverified"?

The provider passed existence but failed a later layer. Run `claude-providers list-all` to see which layer failed.

### What does `# FAIL: route-mismatch` in an evidence file mean?

The live-TUI (layer 4) turn was served by a *different* backend than the alias under test, so it proves nothing about that alias. Router-transport providers share one ccr `Router.default`, and an alias whose `base_url` is the gateway itself skips its own rewrite and inherits the previous provider's route. Each evidence file records `# ROUTE-INTENDED:` and `# ROUTE-RESOLVED:`; when they differ the leg fails rather than passing unattributably. `# FAIL: route-unknown` is the same refusal when the resolved route cannot be read at all (including when `jq` is missing — for a router-transport alias that is a hard precondition, not a skip).

Two sibling failures exist for the same reason. `# FAIL: route-mismatch-background` means `.Router.default` matched but `.Router.background` did not, so background sub-requests of that same turn were served by another backend — partly-foreign evidence is no more attributable than wholly-foreign evidence. `# FAIL: route-unproven` means the config file named the right route but nothing proves the running gateway ever loaded it: the launch wrapper's `ccr restart` runs under `|| true` and can be refused (an authenticated gateway will not bounce without `CCR_API_KEYS` visible), which would leave the previous provider serving while the file reads back correct. Since the router offers no live-route query, the leg demands a restart receipt bracketing the launch — a fresh `gateway listening on` line in `~/.claude-code-router/<alias-id>/service.log`, or a changed `service.json` in that same per-alias directory — and fails closed without one.

Note the **per-alias** paths. Each alias has its own ccr directory — `~/.claude-code-router/<alias-id>/{config.json,service.json,service.log}` — not one shared global set. When you go looking for a route, a pidfile or a gateway log, look under the alias id.

### What does `# FAIL: stream-aborted` in an evidence file mean?

The launch hit the leg's time bound (rc 124) **and** the CLI still wrote a result record saying `terminal_reason":"aborted_streaming"`. The marker carries the observed fields and nothing else:

```
# FAIL: stream-aborted (output_tokens=0 duration_ms=… bound=180s)
```

It is deliberately *not* labelled a trust/overwrite dialog. That used to be the printed guess for every rc-124, and on the run that motivated the change none of the failing aliases had a dialog — the message sent readers hunting for a prompt instead of at the route. The marker now also declines to say *where* the request died, because the leg cannot see that. To find out, read `~/.claude-code-router/<alias-id>/service.log`: a burst of 503s answered in **1-4 ms each** means the *local* gateway rejected the route and the request never reached the provider, which no larger `--timeout` can fix (see "Why does an alias that is `verified` still die on every launch?" below).

### Why does the semantic layer sometimes say something other than "cannot see code"?

Because it now quotes the driver's own `reason` instead of asserting a cause. The `semantic-code-visibility` driver exits 1 for four distinct determinations — sentinel not reflected, prompt-echo bluff, judge below threshold, **and a definitive provider rejection of the model under test (HTTP 401/402/403/404)**. Only the first two are bluffs. Printing "cannot see code / bluffed" for a depleted balance wrote a false cause into the evidence trail: measured over that corpus, 24 evidence files carried the old message, 22 of them next to a driver reason of `non-200 status 401/402/403/404`, and **0** were actual bluffs.

The verdict word (`unverified`) and the exit code are unchanged — a 401 on the model under test really does mean the alias cannot be trusted. Only the human-facing cause moved, so a line now reads e.g. `reason: non-200 status 402: "Insufficient balance for request."` and you triage the account instead of the model.

### How do I re-verify a provider?

```bash
# Re-verify a single provider
claude-providers verify <id> --deep

# Re-verify all providers
claude-providers sync
```

### Can I force-launch a provider that's not verified?

Yes, but it's not recommended:
```bash
claude-providers verify <id> --force
```

## ccr (claude-code-router)

### What is ccr?

ccr is the claude-code-router — a local gateway that translates between Claude Code's Anthropic format and the OpenAI chat/completions format used by most providers. The toolkit **vendors its own Go implementation** as `submodules/claude-code-router`; it is not the Node package of the same name.

### How do I install ccr?

```bash
claude-ccr-build          # builds the bundled Go router, symlinks it to ~/.local/bin/ccr
```

**Do not `npm install -g @musistudio/claude-code-router`.** That is a *different* router, and the toolkit treats it as a doppelgänger: `claude-ccr-build` backs up any pre-existing `ccr` before installing its own, and `claude-install-verify` reports one that shadows it. The discriminator is the `restart` subcommand — `ccr --help` on the bundled router lists `ccr restart`, the npm one does not. That missing subcommand is exactly why every route-apply failed in the field against the npm build.

If you already have the npm one:

```bash
npm rm -g @musistudio/claude-code-router
```

A missing router is reported by name at launch: `provider <id> needs claude-code-router (the 'ccr' gateway).  Build the bundled Go router: claude-ccr-build`.

### ccr says "Profile not found" — what's wrong?

Your bundled `ccr` is **stale**: it does not recognise the `restart` subcommand and read `restart` as a profile name. Rebuild it:

```bash
claude-ccr-build          # needs the Go toolchain
```

The launch wrapper attempts this rebuild once automatically; the message means the automatic attempt was unavailable or did not resolve it. The same symptom appears when a *different* `ccr` shadows the bundled one on PATH — check with `command -v ccr` and remove the other binary (or put `~/.local/bin` earlier on PATH). Note the toolkit itself resolves `~/.local/bin/ccr` directly rather than by PATH order, so a shadowing binary only affects a bare `ccr` you type yourself.

### How does ccr know about my providers?

The toolkit writes provider configurations to `~/.claude-code-router/<alias-id>/config.json` during `claude-providers sync` — one config directory per alias, not one shared file. Each provider's API key is injected at launch time (never stored in the config).

### Why does an alias that is `verified` still die on every launch?

If the launch looks like a hang or a timeout while `claude-providers list` shows the alias `verified` and its config reads back correct, check for the **vendor-prefix routing** class fixed in v1.26.7.

**How to recognise it.** Read the alias's own gateway log:

```bash
tail -50 ~/.claude-code-router/<alias-id>/service.log
```

A burst of **503s answered in 1-4 ms each**, repeated with backoff until the launch gives up, is the signature. Those milliseconds are the tell: no network call takes 1 ms. The *local* gateway rejected the route before dialling the provider, so the provider was never involved, and **no `--timeout` value helps** — the retries were still 503ing past 180 s.

**What was happening.** The router accepts a client-supplied selector in the request's `model` field and recognises two separators, comma and slash (`submodules/claude-code-router/internal/router/selector.go`). Once `lib.sh` began exporting `ANTHROPIC_MODEL` for the router transport too, Claude Code put the *raw catalog id* in the request body — `deepseek-ai/DeepSeek-V3.2-TEE`, `nvidia/nemotron-…`, `Qwen/…` — and the router read the **vendor** as a provider name, found none configured, and returned an unknown-provider error instead of falling through to `Router.default`. **16 of 24 verified aliases** were unroutable this way, while every layer of verification stayed green: layers 1-3 curl the provider's own `base_url` directly and never touch the ccr route path.

**The fix.** The slash form is now decided from evidence rather than from the separator. If some configured provider actually serves the whole string, it is a catalog id and routes normally; if a vendor prefix collides with a real provider name (provider `nvidia` serving `nvidia/nemotron-…`), the whole id wins because the split half is absent from that provider's model list while the full string is present. If nobody serves it, the unknown-provider error still stands, so `Ghost/whatever` cannot silently reach `Router.default`. Comma selectors are unchanged and still fail loudly — a comma is this project's own route syntax, appears in no model id, and silently redirecting one would bill an upstream you never chose.

If you are still on an older build, `claude-ccr-build` rebuilds the vendored router.

## Token limits and your plugin surface

### What is `CMA_TOOL_TOKEN_BUDGET`?

The reservation the launch wrapper makes for **tool schemas** when it derives the two token guards. The endpoint counts your tool payload against the same context window as your text and your output, so the compaction trigger has to reserve for it:

```
window = context - output - CMA_TOOL_TOKEN_BUDGET     # default 80000
```

and when that window would fall below `CMA_MIN_COMPACT_WINDOW` (default 120000) the wrapper buys the window back by lowering the output cap instead:

```
CLAUDE_CODE_MAX_OUTPUT_TOKENS = context - CMA_MIN_COMPACT_WINDOW - CMA_TOOL_TOKEN_BUDGET
```

Override it per host in the provider's `.env` or in the shell.

### Which direction is dangerous if the budget is wrong?

**Under**estimating. Because the output cap is derived as `context − min-window − budget`, too small a budget **inflates** the output cap, and the request then overflows and the launch dies with a 400 naming the real numbers. Measured live on a host with 227 enabled plugins: real tool input **158112** against the 80000 default gave

```
46536 text + 158112 tools + 62144 output = 266792     on a 262144 window
```

### My provider has a 262144 window — is that enough?

Not necessarily, and on a heavily-plugged host **no output cap can rescue it**: `158112 + 120000 > 262144`, so the tool payload plus the minimum compaction window already exceed the whole context before a single output token is reserved. On such a host you must either reduce the enabled-plugin surface or pick a wider-context provider.

### How do I find my own tool input, and my alias's real context?

The 400 error reports the tool number itself — the provider's own message names it, e.g. `you requested about 371727 tokens (199347 of text input, 70236 of tool input, 102144 in the output)`.

For the context, read the alias's resolved env file rather than trusting any table:

```bash
grep CMA_PROVIDER_CONTEXT_LIMIT ~/.local/share/claude-multi-account/providers/<alias>.env
```

Check that before you call any alias "wide enough" — the value is derived per selected model at sync time and changes when the model does.

## Keys and Security

### Where are my API keys stored?

Keys are stored in `~/api_keys.sh` as environment variables. They are sourced at launch time inside a subshell and never written to the toolkit's config files, alias files, or status cache.

### Can I use the same key for multiple providers?

Yes, if the provider allows it. Each provider references a key by variable name (e.g., `DEEPSEEK_API_KEY`), and multiple providers can reference the same variable.

### My key expired — how do I update it?

1. Update the key in `~/api_keys.sh`
2. Run `claude-providers sync` to re-verify
3. The provider should pass verification with the new key

## Sessions and Continuity

### Can I resume a session from one provider in another?

Yes. Sessions are shared across all providers via the unified `~/.claude-shared/` store. A session created under `deepseek` is visible from `xiaomi` and vice versa.

### What happens to my session if a provider goes down?

Your session history is preserved in `~/.claude-shared/projects/`. You can resume it through any other verified provider.

## Local models (helixagent)

### What is the `helixagent` alias?

`helixagent` points Claude Code at a **local** HelixLLM backend — a podman container serving Qwen3-Coder-30B on one GPU, reached at `http://127.0.0.1:7061/v1` (measured 2026-09-03; the earlier `:18434` pin named the llama.cpp coder container — a real port, but a different service, and one that was down when measured — so the alias could never verify) — instead of a hosted API. It uses router transport through `ccr` plus the bundled Go `cma-proxy` (which recovers the model's tool calls so Claude Code's tools engage), and is pinned to a 229,376-token context window. See §12 of the Provider Aliases User Guide for the full note.

### Why does `helixagent` show as `unverified` and refuse to launch?

Its HelixLLM backend is almost certainly in **coder mode** (`-c 24576 --parallel 8` — eight 3,072-token slots), which HelixCode uses. llama.cpp splits `-c` across the slots, so each request gets only ~3,072 tokens and a Claude Code session returns HTTP 400. `helixagent` needs **claude mode** — one 229,376-token slot. Because coder mode is the default operational state, the toolkit honestly marks `helixagent` `unverified` and the launch gate refuses it until you switch:

```bash
helix_code/scripts/helixllm-mode.sh claude     # companion repo, NOT this toolkit
claude-providers verify helixagent --deep      # now passes
helixagent
```

The two modes share one GPU and cannot run at once — switch back with `helixllm-mode.sh coder` when you need HelixCode.

### Will launching `helixagent` start HelixLLM for me?

**No — auto-start is off by default.** Set `CMA_HELIX_AUTOSTART` to `1`, `true`, `yes` or `on` (case-insensitive) to opt in; anything else, including unset, means off.

```bash
CMA_HELIX_AUTOSTART=1 helixagent      # opt in, just for this launch
```

The default is off because booting HelixLLM is a machine-wide side effect, not a private one: it claims the single GPU, and starting it in **claude mode evicts whatever HelixCode had running in coder mode**. A provider alias must not do that to your host merely because you launched it.

You lose no information by leaving it off. When HelixLLM is not answering, the alias still tells you so and prints the exact command:

```
helixagent: HelixLLM is not answering on http://127.0.0.1:7061 and auto-start is OFF by default.
  Start it yourself (it claims the GPU and evicts HelixCode's coder mode):
    helix_code/scripts/helixllm-mode.sh claude
  Or opt in for this launch:
    CMA_HELIX_AUTOSTART=1 <alias>
```

With the opt-in set, the wrapper looks for `helixllm-mode.sh` in the usual Helix Code locations (or under `$HELIX_CODE_DIR`), runs it in claude mode, and polls `/health` for up to 120 s before giving up with a diagnostic. A backend that *is* running but sits in coder mode (`context_limit=24576`) is reported separately — auto-start does not switch modes on a healthy service.

### What is minimal-launch (`CMA_PROVIDER_TRIM='bare'`) mode?

A per-provider setting (a line in the provider's resolved `.env` file) that makes every conversation launch **minimal and fresh** so it fits a small local context window. It prepends `--bare` (dropping the hook/plugin/MCP/CLAUDE.md surface) and skips **both** automatic history seams — the conversation-args auto-`--resume` and the interactive zero-args stored session-flags — so no synced session history rides along. Your **explicit** `--resume` / `--session-id` / `--continue` selectors are still honored verbatim, non-conversation subcommands (`doctor`, `mcp`, …) are untouched, and providers without the setting behave exactly as before. It is wired today for `helixagent`, whose 229,376-token window would otherwise be overflowed by ~330k tokens of resumed history plus ~110k of tool schemas.

## Releasing

### How do I run the pre-release gate?

```bash
claude-release-gate                     # sandbox suite + LIVE real-alias smoke
claude-release-gate --provider poe      # gate through a specific provider
claude-release-gate --skip-suite        # reuse a suite run you just ran green
claude-release-gate --verify-providers  # also run the full LLMsVerifier scan
```

It is **mandatory**: a release commit must not be made unless the gate exits 0. The default gate provider is `helixagent` (override with `--provider` or `$CMA_GATE_PROVIDER`); the chosen provider must exist and be verified, or the gate fails rather than skipping.

### Why isn't the sandbox test suite enough on its own?

The sandbox proves wrapper **logic** but is structurally blind to real-host state. v1.25.1 shipped with the whole sandbox suite green while every router alias on the real host was bricked (a PATH-shadowing `ccr`, a mis-configured local backend, resumed history overflowing a small window — none reachable from a sandbox). So the gate adds a **live** layer: it regenerates the aliases from the current `lib.sh` and drives the real alias through the real PATH → ccr → route-apply → proxy → backend, asserting the served `GATE-OK` reply and — for router providers — that the gateway's sink-side route actually names the provider under test.
