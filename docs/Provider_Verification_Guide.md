# Provider Verification Guide

## Overview

Every provider alias goes through a 4-layer verification pipeline before it can launch Claude Code. A provider that passes all available layers is marked `verified` and is launchable. A provider that fails any layer is marked `failed` or `unverified` and is refused by the activation gate.

## The Four Layers

### Layer 1: Existence

The existence probe sends a minimal chat request to the provider's API endpoint. It checks:
- The endpoint is reachable (HTTP response received)
- The API key is valid (not 401/403)
- The account is active (not 412/suspended)

**Runner:** `providers-verify.sh`
**On fail:** status → `failed` with layer `existence`
**On inconclusive (no network, timeout):** status → `unverified` with layer `existence`

### Layer 2: Tool-Call

The tool-call probe sends a request with a tool definition and checks that the model:
- Recognizes the tool schema
- Returns a valid tool call in the response

This is critical because Claude Code is tool-driven — a chat-only model is useless.

**Runner:** `providers-verify.sh` (same script, second probe)
**On fail:** status → `failed`
**On pass:** status → `verified` (so far)

### Layer 3: Semantic Code-Visibility

The semantic layer tests whether the model can actually "see" and describe code content. It uses a two-round test:

1. **Round 1 (sentinel):** A code fixture is embedded in the prompt. The model must return a specific sentinel string (`ZETA-9-ORANGE-7f3a`) verbatim.
2. **Round 2 (judge):** An independent judge model evaluates whether the model's description of the code is accurate.

**Runner:** `providers-semantic.sh` → Go binary (`semantic-code-visibility`)
**On fail:** status → `unverified` with layer `semantic`
**On skip (no Go, no key, no network):** keeps prior verdict (no downgrade)
**On pass:** keeps `verified`

**The reported cause is the driver's, not ours.** Driver exit 1 covers *four* determinations, not one: sentinel not reflected, prompt-echo bluff, judge below threshold, and a definitive provider rejection of the model under test (HTTP 401/402/403/404 — auth failure, depleted credit and model-not-found are deterministic states, not transient infra). All four justify refusing the alias; only two are a bluff. So the failure line now quotes the per-round `reason` out of the driver's own JSON:

```
providers-semantic[<id>]: layer-3 unverified — driver exit 1; reason: non-200 status 402: "Insufficient balance for request."
```

The previous message asserted "cannot see code / bluffed" for all four. Measured over the evidence corpus: 24 files carried it, 22 alongside a driver reason of `non-200 status 401/402/403/404`, and **0** were actual bluffs — one file held both claims twelve lines apart. The verdict word (`unverified`) and the exit code are deliberately unchanged; only the human-facing cause moved. When no reason can be read the line says so explicitly rather than guessing one.

### Layer 4: Superpowers-TUI

The superpowers-TUI layer launches a real Claude Code session through the provider alias and checks whether it can engage with the superpowers plugin. This is the final, definitive test.

**Route attribution.** A PASS here is only meaningful if the turn was actually served by the alias under test. Every router-transport provider rewrites ccr's shared `Router.default` to itself before launching, but an alias whose `base_url` *is* the gateway trips a self-reference guard, skips that rewrite, and inherits the previous provider's route — `helixagent` was once badged `verified` on a turn served by a different provider. Every evidence file now records both routes:

```
# ROUTE-INTENDED: <provider>/<model> (transport=router)
# ROUTE-INTENDED-BACKGROUND: <provider>/<model>
# ROUTE-RESOLVED: <provider>/<model>
# ROUTE-RESOLVED-BACKGROUND: <provider>/<model>
# ROUTE-APPLIED: <restart receipt, or <unproven>>
```

`ROUTE-RESOLVED` is read *after* the launch, so it reflects the rewrite rather than the stale pre-launch value. If the two differ the leg fails with `# FAIL: route-mismatch`; if the resolved route cannot be read at all the leg fails with `# FAIL: route-unknown` — an unattributable turn is never a silent pass.

Both router entries are checked, not just `.Router.default`. Claude Code dispatches background sub-requests of the *same* turn through `.Router.background`, so a turn served only partly by another backend fails with `# FAIL: route-mismatch-background`.

**A config file is not a live gateway.** Reading `config.json` back proves what it *says*, not what the daemon serves: the launch wrapper runs `ccr restart` under `|| true`, and `cmdRestart` genuinely refuses to bounce an authenticated gateway when `CCR_API_KEYS` is not visible to the call (`cmd/ccr/service.go:525-530`, returns 1) — a swallowed failure leaves the *previous* provider serving while the file reads back correct. The router exposes no live-route query (its `/health` reports a provider *count*, not a route), so the leg requires a **restart receipt** bracketing the launch: either a new `gateway listening on` line appended to `~/.claude-code-router/<alias-id>/service.log` past the pre-launch byte offset, or a changed `~/.claude-code-router/<alias-id>/service.json` pidfile. With neither, the leg **fails closed** with `# FAIL: route-unproven`.

Every one of these paths is **per alias**. Each alias owns `~/.claude-code-router/<alias-id>/` with its own `config.json`, `service.json` and `service.log`; there is no single global set to inspect.

Two honest limits on that guarantee: the receipt brackets the whole launch rather than the individual request (a concurrent rewrite is excluded by the suite lock, not by this gate), and it proves that *a* config load happened, not that the loaded bytes were the ones read back.

`jq` is a hard precondition for router-transport aliases, not a silent skip — without it the resolved route is unreadable and the leg takes `route-unknown`. The whole attribution check runs *before* any transcript-derived verdict, so a route failure is never explained away by the provider's status: a rejected key explains a provider that cannot answer, but nothing about an account explains evidence attributed to the wrong backend. Native-transport aliases talk to their endpoint directly, so they record an explicit `n/a` and are not route-checked.

**A timeout is classified, not guessed.** Exit code 124 says only that the bound expired — never why. The leg used to print `launch hung within Ns (trust/overwrite prompt?)` for every one of them; on the run that motivated the change, *every* failing alias on the host was reported that way and **none** had a dialog. Their own result JSON, captured into the same evidence file, said `"terminal_reason":"aborted_streaming"` with `output_tokens` 0. So the leg now consults the transcript first and emits a distinct marker when it finds that record:

```
# FAIL: stream-aborted (output_tokens=0 duration_ms=… bound=180s)
```

The marker states the observed fields, says explicitly that this is **not** a trust/overwrite dialog, and — importantly — declines to name *where* the request died, because the leg cannot see that. It points instead at `~/.claude-code-router/<alias-id>/service.log`: a burst of 503s at **1-4 ms each** means the *local* gateway rejected the route and the request never reached the provider. For the same reason it does not advise a longer `--timeout`; on that run the retries were still 503ing past 180 s, and no bound fixes a rejected route. An rc-124 with no such result record still takes the original `# FAIL: timeout` path, where a dialog remains a plausible cause.

**Runner:** `verify_superpowers_tui.sh`
**On fail:** status → `unverified` with layer `superpowers_tui`
**On skip (no real claude, no PTY):** keeps prior verdict (no downgrade)
**On pass:** status → `verified` (final)

## Status Vocabulary

| Status | Meaning |
|--------|---------|
| `verified` | All testable layers passed; none failed |
| `unverified` | Existence passed but a later layer failed or was inconclusive |
| `failed` | Existence or tool-call failed |
| `pending` | Not yet run |

**Key rule:** A layer that cannot run (no key, no network, no Go, no real claude) is an honest **SKIP** and does NOT downgrade a provider. Only a real layer *failure* downgrades.

## What Gets Verified: the Credit-Aware Model Tier

The four layers verify *the model the alias will actually run*, and which model that is depends on the provider account's credit state:

| Credit state | Model put under test |
|--------------|----------------------|
| Credit / purchased tokens available | the strongest **paid** model the provider serves |
| No credit | the strongest **free** model (free tier / `$0` cost) |
| Unknown / undeterminable | treated as *no credit* — the free model |

Two consequences for verification specifically:

1. **The gates are identical in both tiers.** A free model is not verified more leniently. It must pass the same sentinel probe and the same tool-calling probe, or its alias is not activated. The tier decides *which* model is tested, never *how strictly*.
2. **The conservative unknown-branch avoids a whole class of `failed` verdicts.** Probing a paid model on an unfunded key returns 401/402/403, which Layer 1 correctly treats as a definitive rejection — the alias would be marked `failed` and refuse to launch. Defaulting an unreadable credit state to the free tier means an unfunded provider ends up with a working free alias instead of a dead paid one. Re-run `claude-providers sync` once the account is funded and the paid model is picked up and re-verified.

A `strong_model` / `fast_model` pin in `scripts/providers/overrides.json` overrides the tier choice; the pinned model is then the one verified, whatever its cost tier.

> The mechanism behind this (in `providers_resolve.py` and in LLMsVerifier's corresponding detection) landed alongside this section. The rules above are the behavioural contract — read the source for the current flag and field names.

## Commands

```bash
# List verified providers only (default)
claude-providers list

# List all providers including failed/unverified
claude-providers list-all

# List only faulty providers
claude-providers list-faulty

# Re-sync all providers (re-runs verification)
claude-providers sync

# Deep-verify a single provider (all 4 layers)
claude-providers verify <id> --deep

# Refresh aliases without re-verifying
claude-providers list --refresh-aliases
```

## The Activation Gate

When you launch a provider alias (e.g., `deepseek`), the activation gate checks the provider's status in `~/.local/share/claude-multi-account/providers/status.json`. If the status is not `verified`, the launch is refused with an actionable message.

To override the gate (e.g., for testing):
```bash
claude-providers verify <id> --force
```

## Common Issues

### "resolved ccr … is not the bundled claude-code-router"

The `ccr` being used is not the toolkit's own router. The toolkit vendors a Go implementation (`submodules/claude-code-router`) and discriminates it by the `restart` subcommand: `ccr --help` shows `ccr restart` on the bundled router and does **not** on the Node `@musistudio/claude-code-router`. That missing subcommand is why route-apply failed in the field against the npm build. Fix:

```bash
claude-ccr-build                              # build + install the bundled Go router
npm rm -g @musistudio/claude-code-router      # if an npm doppelgänger shadows it
```

`claude-ccr-build` backs up any pre-existing `ccr` rather than clobbering it. A shadowing binary earlier on PATH is a warning, not a breakage — provider aliases resolve `~/.local/bin/ccr` directly, not by PATH order — but a bare `ccr` you type yourself still hits the other one.

### Provider shows "failed/existence"

The API endpoint is unreachable or the API key is invalid. Check:
1. Is the API key set in `~/api_keys.sh`?
2. Is the account active (not suspended)?
3. Can you reach the endpoint? `curl -4 -s <base_url>/chat/completions`

### Provider shows "unverified/semantic"

The semantic code-visibility test returned a definitive failure. **Read the `reason:` on the failure line before assuming anything about the model** — it is the driver's own, and it distinguishes the four cases exit 1 covers:

- `non-200 status 401/402/403/404` — the provider rejected the model under test. This is account-side (rejected key, depleted balance, no access, model not served); top up or re-key and re-sync. It says nothing about the model's ability to read code.
- a sentinel/judge reason — the genuine "can't reliably describe code content" case. Possible causes: the model doesn't support the chat/completions format, its context window is too small for the fixture, or it echoed the prompt instead of answering.
- `not reported by the driver` — no reason could be read; the driver JSON and stderr are mirrored into the evidence file just above the verdict.

Transport/infra errors and an unavailable judge are an honest **SKIP** (exit 3), not this status — they never demote a provider.

### Provider shows "unverified/superpowers_tui"

The superpowers-TUI test failed. This means the model can't engage with the superpowers plugin. Possible causes:
- The model doesn't support tool calling
- The model's output is too short for the engagement check
- Claude Code couldn't launch through the alias
- **`# FAIL: route-mismatch`** in the evidence file — the turn was served by a *different* backend than the alias under test (a gateway-based alias skipping its own `Router.default` rewrite and inheriting the previous provider's route), so it proves nothing either way. Re-run the leg on its own rather than after another router alias.
- **`# FAIL: route-mismatch-background`** — `.Router.default` matched, but `.Router.background` named another backend, so background sub-requests of that same turn were served elsewhere. Partly-foreign evidence is refused for the same reason wholly-foreign evidence is.
- **`# FAIL: route-unknown`** — ccr's resolved route could not be read (no `jq`, or no `Router.default` / `Router.background` in `~/.claude-code-router/<alias-id>/config.json`). The turn is unattributable and is refused rather than passed.
- **`# FAIL: route-unproven`** — the config file names the right route, but no `ccr restart` receipt brackets the launch (no new `gateway listening on` line in `~/.claude-code-router/<alias-id>/service.log`, and `service.json` unchanged), so the running gateway may still be serving the previous provider. Fails closed. Usually means the restart was refused — most often an authenticated gateway restarted without `CCR_API_KEYS` visible.
- **`# FAIL: stream-aborted`** — the bound expired *and* the CLI wrote a result with `terminal_reason=aborted_streaming`. Not a dialog. Read `~/.claude-code-router/<alias-id>/service.log`; 503s at 1-4 ms each mean the local gateway rejected the route (see "An alias is `verified` but every launch dies" below), and a longer `--timeout` will not help.
- **`# FAIL: context-inadequate (backend N tokens < request M)`** — the turn reached the right backend and the key was accepted, but the backend's own window is smaller than Claude Code's tool-heavy request. Both numbers come from the backend's live 400, never from the pin (the pin may say 24576 while the server is really 3072). Provider-side: relaunch a local backend larger, or pin a wider-context model. Not counted as a suite failure.
- **`# FAIL: account-side (HTTP 402|403 …)`** — billing/access. The toolkit cannot cause a 402/403; a malformed request is a 400. Fires even on a cached `verified` status, because that status was set by the ~512-token layers-1/2 probe before the balance ran out. Top up or re-key. Not counted as a suite failure.

### An alias is `verified` but every launch dies

Check the alias's own gateway log for the **vendor-prefix routing** class fixed in v1.26.7:

```bash
tail -50 ~/.claude-code-router/<alias-id>/service.log
```

A burst of 503s answered in **1-4 ms each** is the signature — no network call takes 1 ms, so the local gateway rejected the route before dialling the provider. The router recognises both `,` and `/` as explicit `provider/model` selectors; once `ANTHROPIC_MODEL` began being exported for the router transport, Claude Code sent the raw catalog id (`deepseek-ai/…`, `nvidia/…`, `Qwen/…`), the router read the **vendor** as a provider name, found none configured, and errored instead of falling through to `Router.default`. **16 of 24 verified aliases** were affected.

Note which gate caught it and why the others could not: layers 1-3 curl the provider's own `base_url` directly and never touch the ccr route path, so they were green throughout. **Only the layer-4 live launch exercises the real chain** — that is the entire reason that leg exists. The fix decides the slash form from evidence (a string some configured provider actually serves is a catalog id and routes normally; one nobody serves still fails loudly), leaving comma selectors failing loudly as before.

## File Locations

| File | Purpose |
|------|---------|
| `~/.local/share/claude-multi-account/providers/status.json` | Verification status for all providers |
| `~/.local/share/claude-multi-account/providers/<id>.env` | Provider configuration (non-secret), including `CMA_PROVIDER_CONTEXT_LIMIT` |
| `~/.local/share/claude-multi-account/aliases.sh` | Shell aliases for launching providers |
| `~/.claude-code-router/<alias-id>/config.json` | ccr router configuration — **one per alias** |
| `~/.claude-code-router/<alias-id>/service.log` | That alias's gateway log (route rejections land here) |
| `~/.claude-code-router/<alias-id>/service.json` | That alias's gateway pidfile (the restart receipt) |
| `~/api_keys.sh` | API keys (sourced at launch, never stored by toolkit) |
