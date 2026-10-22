# Jev Decision Layer — Quickstart

Jev is a **decision model**, not a chat model: you POST a `state` plus typed
`questions` to `/v1/systemone` and get back typed decisions (choice / noul /
score) with probabilities. claude_toolkit wires Jev endpoints into every
agent launch as a **decision layer**: a permission gate on tool calls, an MCP
tool agents can consult explicitly, and a launch-time environment that makes
the nearest endpoint reachable. Jev endpoints never become launchable
aliases — they have no chat completions to launch.

This page gets you from zero to an active decision layer in under five
minutes. See [Jev_User_Guide.md](./Jev_User_Guide.md) for the full reference
and [Jev_FAQ.md](./Jev_FAQ.md) for common questions.

---

## 1. Get one endpoint reachable

Any **one** of these is enough (the toolkit ranks them automatically; the
local gateway wins when present):

| Source | What to do |
|--------|-----------|
| **Local llmctl decision gateway** | Run a llmctl profile that serves a `/v1/systemone`-compatible decision endpoint (default `127.0.0.1:8095`; if you changed `llmctl decide serve --port`, update `local_gateway.port` in the pins; free, lowest latency). llmctl's gateway is **HTTPS + bearer key**: export `LLMCTL_API_KEY` (or keep it in `~/api_keys.sh`) and, if the gateway uses llmctl's local CA, `CMA_JEV_CA_FILE=$LLMCTL_HOME/cert/ca/ca.crt`. See the [User Guide](./Jev_User_Guide.md) §2.1 (§11.4.279 clause A). |
| **TypeSafe hosted key** | Add `TYPESAFE_API_KEY=<key>` to your keys file (`~/api_keys.sh`). Note: TypeSafe hosted has a signup waitlist. |
| **OpenRouter key** | Add `OPENROUTER_API_KEY=<key>` to `~/api_keys.sh` — the hosted path with no waitlist. Serves `typesafe/jev-1.13` at `https://openrouter.ai/api/v1/systemone`. |

(LAN pins for a remote host — including a cloud box you control — go in
`scripts/providers/jev.json` under `"lan"`; see the User Guide §2.)

## 2. Sync

```bash
claude-providers sync        # or the Jev-only fast path: claude-providers sync-jev
claude-providers list        # endpoints appear under "## Decision endpoints (Jev)"
```

The sync writes the ranked endpoint cache
`~/.local/share/claude-multi-account/providers/jev-endpoints.json`. That
cache is the **only** thing a launch reads — launching never probes the
network.

## 3. Install the per-agent artifacts

```bash
jev-setup                  # all agents (claude, kimi, pi, opencode); idempotent
jev-setup --check          # dry audit afterwards: what is installed, what is missing
```

This installs the shared gate (`jev-gate.sh`), hooks for Claude Code and
Kimi, the `jev` MCP server registration, the OpenCode plugin, and writes
`JEV_MODE=shadow` to `~/.config/jev/env`. Pi gets `@riposta/pi-jev` via npm
when the network is reachable, otherwise the exact manual command is printed.

## 4. Launch any alias and look for the MOTD

```bash
claude1        # or deepseek, kimi1, pi1, kimi-deepseek — every alias is wired
```

On stderr, before the agent starts:

```
Jev decision layer: ACTIVE (endpoint: jev-local, mode: shadow)
```

If you instead see `Jev decision layer: INACTIVE (...)`, the endpoint cache
is missing or empty — re-run step 2. The launch itself is unaffected either
way: with no endpoint the toolkit behaves exactly as before Jev.

## 5. Watch it work

```bash
jev-stats            # human report: decisions by answer/mode/agent/endpoint,
                     # latency, shadow would-be verdicts, ESTIMATED tokens saved
jev-stats --json     # same data, machine-readable
```

In the default **shadow** mode the gate never blocks anything — it logs what
it *would* have decided to `~/.local/state/jev/decisions.jsonl`. Review
shadow verdicts for a calibration week, then switch to enforcement:

```bash
jev-setup --mode enforce     # writes JEV_MODE=enforce to ~/.config/jev/env
```

The token-savings number in `jev-stats` is a **documented estimate**, not a
metered value — the formula and its constants are printed in the report
header and in the User Guide §8.
