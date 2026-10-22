# Jev Decision Layer — FAQ

See also: [Quickstart](./Jev_Quickstart.md) · [User Guide](./Jev_User_Guide.md)

## General

### Is a Jev endpoint as accurate as the hosted Jev service?

It depends on which endpoint you run. The hosted TypeSafe Jev is the
reference System-One model (Jev 1.13, Decision Index 57.91). Local
replications differ per model: StartLux-Decision-27B scores 63.88 on the
same index (31/38 head-to-head wins), and its 4B Q8_0 quant shows 100%
decision parity with its bf16 weights on JevBench 231 — but those are the
replication authors' reported numbers, not this toolkit's measurements. The
toolkit is endpoint-agnostic: it ranks endpoints, gates on their answers,
and logs what they decided. Calibrate against your own workload in shadow
mode before trusting any endpoint in enforce mode.

### Why must I run a shadow week before enforce mode?

Because the gate thresholds (`JEV_GATE_THRESHOLD=0.8`,
`JEV_RISKY_THRESHOLD=0.7`) are heuristics, and every endpoint has its own
calibration. In shadow mode the gate never blocks — it logs the would-be
decision to `decisions.jsonl`. `jev-stats` shows the shadow would-be split
(deny / ask / allow and the would-deny rate). Review a week of that against
your real usage; if the would-deny rate is dominated by false positives,
tune the thresholds before `jev-setup --mode enforce`.

### Is the `confidence` field an error probability?

No. Confidence is a calibration score produced by the decision model — a
higher number correlates with better-calibrated answers, but "confidence
0.9" does **not** mean "10% chance of being wrong". The gate therefore uses
the `risky` noul probability for its thresholds, not confidence.

### Why does the gate fail open?

Availability over enforcement, deliberately. If the endpoint times out
(`JEV_GATE_TIMEOUT=2`s) or errors, the gate allows the call and logs
`fallback: "timeout"` / `"endpoint_error"` — an endpoint outage must never
freeze every tool call in every agent session. The trade-off: enforcement
has holes during outages. `JEV_GATE_FAIL=closed` flips this (deny on
endpoint error) and is documented as risky. The deterministic risk floor
(`rm -rf /`, `mkfs`, `git push --force`, `| sh`, …) applies even when the
endpoint is down, so the most destructive patterns still get at least `ask`.

## Endpoints and detection

### Why did my `jev-local` endpoint disappear?

The same reason llmctl aliases disappear: detection re-probes on every sync,
and `jev-local` only exists while `127.0.0.1:8095` answers both `/healthz`
and `/v1/models`. Stop the gateway and the next `claude-providers sync` (or
the background `sync-jev` a launch kicks when the cache is stale) drops it.
No endpoint is ever kept on the strength of a merely-open port.

### How do I point the toolkit at a decision server on another machine — including a cloud host?

Add it to the `"lan"` array in `scripts/providers/jev.json` with
`"enabled": true` (shipped default: empty array). A pin is a trust
declaration — `host` may be a LAN address or a remote cloud host you
control; either way it is probed (`/healthz` + `/v1/models`) on sync and
recorded with `lan_exposed: true`. LAN pins rank at priority 20, ahead of
both hosted sources.

### How do I force a specific endpoint when several are up?

`CMA_JEV_PREFER="jev-openrouter,jev-lan-1"` — a comma list of provider_ids,
ranked first in the order given; everything else keeps the default order
(local 10 > LAN 20 > OpenRouter 30 > TypeSafe 40). See
`claude-providers list` under `## Decision endpoints (Jev)` for the resolved
order.

### Why does TypeSafe hosted rank last?

Priority order is local-first, then user-declared pins, then the hosted
paths — and of the hosted paths, TypeSafe 1P has a signup waitlist while
OpenRouter works with any OpenRouter key, so OpenRouter ranks above it. All
four sources are always detected; ranking only decides which one
`endpoints[0]` (the one launches use) points at.

### Why don't Jev endpoints get aliases like `jev-local` I can launch?

Because there is nothing to launch: Jev has no chat-completions API. Records
carry `classification: "decision"` and `"alias": null`, and the emission
paths that would create `<id>` / `kimi-<id>` / `pi-<id>` aliases skip them
by construction (covered by `test_jev_no_alias_leak.sh`, 26 assertions).
They show up in `claude-providers list` and `status.json` for health
visibility only. The `jev-*` namespace is reserved for the decision layer;
no account or provider alias may use it.

## Agents

### The OpenCode gate missed an MCP tool call — why?

Upstream limitation, not a toolkit defect: opencode's `tool.execute.before`
plugin hook does not intercept MCP tool calls (issue #2319) or subagent tool
calls (issue #5894). The OpenCode gate therefore covers built-in tools only.
This is printed by `jev-setup`, stated in the plugin header, and listed in
the User Guide's limitations. Claude Code and Kimi hooks do not have this
gap.

### What happens with pi on an offline host?

`jev-setup` probes the npm registry for 3 seconds; unreachable → it prints
the exact manual command (`PI_CODING_AGENT_DIR=<home> pi install
npm:@riposta/pi-jev`) and continues. Nothing is half-installed. Even without
the package, pi launches still receive the full `JEV_*` environment from the
wrapper. Note the verified package name is `@riposta/pi-jev`; `jev-pi` /
`jev-pi-orchestrator` in older material are wrong/renamed. Its env-var names
beyond the SDK convention (`TYPESAFE_BASE_URL` / `TYPESAFE_API_KEY`) are
unverified.

### Does `jev-architect` use this layer?

No. `jev-architect` (BenjaminPolge) does heuristic architecture checks and
never calls a Jev endpoint; it is excluded from this integration by design.

## Reporting and licensing

### How real are the token-savings numbers in `jev-stats`?

They are documented estimates, not metered values. The formula is printed in
every report header: `total_decisions * 1500 + enforced_ask_or_deny * 200`,
with both constants overridable (`JEV_EST_INPUT_TOKENS`,
`JEV_EST_OUTPUT_TOKENS`). No token counter is read anywhere in the pipeline;
treat the number as an order-of-magnitude indicator, and the decision counts
/ latencies / would-be splits as the hard data.

### Can I use a local StartLux-Decision server commercially?

No. StartLux-Decision **weights are CC BY-NC-4.0** (non-commercial); only
the server code is Apache-2.0. The toolkit integrates with any
`/v1/systemone`-compatible server, but the license obligations of the model
you point it at are yours. See
[docs/research/jev-ecosystem.md](../research/jev-ecosystem.md) for the
licensing table.

### How do I turn the whole layer off?

`CMA_JEV_DISABLE=1` in your environment (no exports, no notice, no
background refresh — identical to pre-Jev behavior), `JEV_GATE=off` to
disable only the gate, or `jev-setup --uninstall` to remove the installed
artifacts (state dir and evidence log are kept).
