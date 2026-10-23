# Jev Decision Layer — User Guide

Full reference for the Jev decision-layer integration. Short version:
[Jev_Quickstart.md](./Jev_Quickstart.md). Common questions:
[Jev_FAQ.md](./Jev_FAQ.md). Implementation evidence: 9 test suites, 280
assertions, 0 failures (`qa-results/jev_decision_layer_20261006/`).

Jev endpoints are **decision models**, not chat models: `POST
<base>/v1/systemone` with `{model, state, questions}` returns typed answers
(choice / noul / score) with probabilities. Because there is no
chat-completions API to launch, Jev endpoints are registered with
`classification: "decision"` and **never become aliases** — they feed a
parallel decision layer instead: a permission gate, an MCP tool, and a
launch-time environment.

---

## 1. Architecture

```
detect_jev_records()            (scripts/claude-providers.sh)
   │  probes: local llmctl gateway :8095 · LAN pins · OpenRouter · TypeSafe
   ▼
resolve_records()  →  status.json (health bookkeeping) 
   │              →  NO aliases, NO kimi/pi renderer configs, NO models.json
   ▼
_cma_jev_write_endpoint_cache() → providers/jev-endpoints.json (ranked)
   ▼
cma_jev_env()  (lib.sh, emitted into every launch wrapper)
   │  cache-only read; exports JEV_* + TYPESAFE_* + token knobs; MOTD line
   ▼
agents: claude · kimi · pi · opencode
   ├─ jev-gate.sh      PreToolUse permission gate (shadow/enforce, fail-open)
   ├─ jev_mcp.py       MCP tools: jev_ask, jev_models, jev_stats_summary
   └─ decisions.jsonl  evidence log → jev-stats
```

Launch-path budget: `cma_jev_env` does **zero network I/O** — one `stat` and
one `jq` on a small file. On any failure it exports `CMA_JEV_ACTIVE=0` and
the launch proceeds exactly as before Jev.

## 2. Provider sources

Declared in `scripts/providers/jev.json` (override the whole file in tests
via `CMA_JEV_PINS_FILE`; probing timeout `CMA_JEV_HTTP_TIMEOUT`, default 2 s).

### 2.1 Local llmctl decision gateway (priority 10)

`local_gateway` pin: `127.0.0.1:8095` (`scheme: https`), health path `/healthz`, models
path `/v1/models`, key var `LLMCTL_API_KEY` (the name of the env var / keys-file entry holding
the gateway's bearer key; 8095 is llmctl's default decide port - if you changed
it with `llmctl decide serve --port N`, update `local_gateway.port` in the
pins). The detector requires a 200 on `/healthz` **and** a parseable
authenticated `/v1/models` listing with at least one
model id — a merely-open port is never trusted. The record appears and
disappears with the running server on every sync, exactly like llmctl chat
profiles. Emitted as `jev-local` with the served model id from `.data[0].id`.

**Transport: HTTPS + bearer key (v1.32.0).** llmctl's decide gateway
(`llmctl decide`, llmctl `docs/decide-gateway.md`) serves
`https://127.0.0.1:8095`, signs with a local CA
(`$LLMCTL_HOME/cert/ca/ca.crt`) and requires `Authorization: Bearer
$LLMCTL_API_KEY` on every `/v1/*` request (401 otherwise); only `/healthz` and
`/readyz` are open. The detector now speaks exactly that:

- It tries `https://` first. Each CA candidate is tried in turn until the TLS
  `/healthz` answers: `CMA_JEV_CA_FILE`, `SSL_CERT_FILE`, `$LLMCTL_HOME/cert/ca/ca.crt`
  (when set and present), then the system store; the CA that verified is the
  one recorded as `ca_file`. Certificate verification is never disabled: a
  gateway whose certificate no candidate trusts is not registered, and the
  warning says so (`TLS certificate ... is not trusted`).
- The bearer key is read from the env var **named** by the pin's `key_var`
  (`LLMCTL_API_KEY`), else from the keys file (`~/api_keys.sh` /
  `CMA_KEYS_FILE`). It is handed to curl through a header file, never on a
  command line, and is never printed or written to the cache. Healthz answering
  but no key available, an HTTP 401/403/429 on `/v1/models` (key rejected), or
  any other status (`models request failed (HTTP n)`) means the endpoint is
  **not registered**; each case has its own one-line, key-free warning.
- `scheme` in a pin (`local_gateway.scheme`, `lan[].scheme`) defaults to
  `https`. **Plain http is opt-in and loopback-only**: set
  `CMA_JEV_ALLOW_HTTP=1` (or `scheme: "http"` in the pin) for a loopback host
  (`127.0.0.0/8` literal, `localhost`, `::1`, `[::1]` - exact match; userinfo,
  paths, `127.evil.example`, `127.0.0.1.nip.io`, `localhost.` are not loopback).
  Such a record carries no `key_var` and no `ca_file`, and neither
  `jev-gate.sh` nor `jev_mcp.py` ever sends an Authorization header over http.
  A non-loopback host is never probed over plain http; `scheme: "http"` for one
  is refused with a warning, and a default-scheme LAN pin whose server does
  not speak TLS says so. **Breaking vs v1.31.x**: LAN pins without a scheme are
  now TLS-only.
- The endpoint cache records the non-secret `ca_file`; launches export it as
  `JEV_CA_FILE` (deliberately **not** `SSL_CERT_FILE`, which would replace the
  system trust store for the whole agent tree). `jev-gate.sh` passes it to curl
  as `--cacert`; `jev_mcp.py` loads it into its TLS context. The OpenCode
  plugin (Node) does not read it: export `NODE_EXTRA_CA_CERTS` for it.

Governing rule: Constitution §11.4.279 (clause A detection, C decision models
are never aliases, D validation through §11.4.277); diagram:
[decide-gateway-flow](../diagrams/decide-gateway-flow.svg).

### 2.2 LAN pins (priority 20)

User-declared trusted endpoints in the `"lan"` array of
`scripts/providers/jev.json`. The shipped default is `"lan": []`. An entry:

```json
{
  "id": "lan-1",
  "host": "192.168.1.20",
  "port": 8095,
  "key_var": "LAN_JEV_KEY",
  "models": ["jev-latest"],
  "context_limit": 64000,
  "enabled": true
}
```

`host` may also be a remote cloud host you control — a pin is a trust
declaration, not a locality check; `lan_exposed: true` is recorded on the
record. Each enabled entry is probed (`/healthz` + `/v1/models`,
bounded-parallel, `CMA_JEV_HTTP_TIMEOUT`) and emitted as `jev-<id>` (the
example above yields `jev-lan-1`). Entry ids containing characters outside
`[A-Za-z0-9._-]` are rejected with a warning. Disabled entries are never
probed.

### 2.3 OpenRouter (priority 30)

Presence of a non-empty `OPENROUTER_API_KEY` in the keys file
(`CMA_KEYS_FILE`, default `~/api_keys.sh`) emits `jev-openrouter`: base
`https://openrouter.ai/api`, model `typesafe/jev-1.13` (the canonical
upstream id, first in the pins `models` list), context 32000. Detection
reads the keys file for the variable **name** only; no network call is made
for hosted records.

### 2.4 TypeSafe hosted (priority 40)

Presence of `TYPESAFE_API_KEY` in the keys file emits `jev-typesafe`: base
`https://api.typesafe.ai`, model `jev-latest` (last in the pins `models`
list, behind the pinned `jev-1.13.0`), context 64000. TypeSafe hosted has a
signup waitlist, which is why it ranks below OpenRouter.

### 2.5 Ranking and `CMA_JEV_PREFER`

Lower priority number wins: **local (10) > LAN (20) > OpenRouter (30) >
TypeSafe (40)**. `CMA_JEV_PREFER="jev-openrouter,jev-lan-1"` (comma list of
provider_ids) moves the listed ids to the front, in the order given; all
other endpoints keep priority order behind them. Ties break on provider_id
for determinism.

## 3. The endpoint cache

Path: `~/.local/share/claude-multi-account/providers/jev-endpoints.json`
(the directory is `CMA_PROVIDERS_DIR`-overridable in tests). Written
atomically by `claude-providers sync` and by the Jev-only fast path
`claude-providers sync-jev [--quiet]`. Format:

```json
{
  "version": 1,
  "generated_at": 1759700000,
  "ttl": 300,
  "endpoints": [
    { "provider_id": "jev-local", "base_url": "https://127.0.0.1:8095",
      "model": "jev-latest", "key_var": "LLMCTL_API_KEY",
      "ca_file": "/home/me/.local/share/llmctl/cert/ca/ca.crt",
      "priority": 10, "probed_at": 1759700000,
      "reason": "llmctl decide gateway live at https://127.0.0.1:8095" }
  ]
}
```

Non-secret by construction: it stores the key variable **name**, never the
value. TTL: `CMA_JEV_CACHE_TTL` seconds (default 300). At launch, when the
cache is missing or older than the TTL, `cma_jev_env` kicks a detached
`claude-providers sync-jev --quiet` in the background (and sets the
test/observability flag `CMA_JEV_REFRESH_KICKED=1`); the **stale** cache is
still used for that launch — launches never block on a refresh. Only
`endpoints[0]` is consumed at launch.

## 4. Launch wiring and MOTD

`cma_jev_env` (defined in `scripts/lib.sh` and emitted once into the managed
alias file by `_cma_emit_managed`) runs at the top of all six launch
wrappers (`cma_run`, `cma_run_provider`, `cma_run_kimi`,
`cma_run_kimi_provider`, `cma_run_pi`, `cma_run_pi_provider`) and exports,
when an endpoint is resolved:

- `JEV_BASE_URL`, `JEV_KEY_VAR` (the NAME of the key variable - the key
  value is never exported into the agent's environment; `jev-gate.sh` and
  `jev_mcp.py` resolve it themselves), `JEV_CA_FILE` (the non-secret CA path
  for an https gateway, only when the file exists), `JEV_MODEL`, `JEV_MODE`
  (default `shadow`),
- `TYPESAFE_BASE_URL` — the SDK-convention alias (TypeSafe SDKs honor it),
- `CMA_JEV_ACTIVE=1`, `CMA_JEV_ENDPOINT_ID=<provider_id>`,
- `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50` and `MAX_THINKING_TOKENS=10000`
  (token-reduction knobs; pre-set values are preserved).

MOTD (stderr, interactive launches):

```
Jev decision layer: ACTIVE (endpoint: jev-local, mode: shadow)
```

With no cache or no resolved endpoints the launch is unchanged and a single
INACTIVE notice is printed unless `CMA_JEV_QUIET=1`. `CMA_JEV_DISABLE=1`
opts out globally: no exports, no notice, no background refresh.

## 5. Per-agent artifacts (`jev-setup`)

`jev-setup [--agents claude,kimi,pi,opencode] [--mode shadow|enforce]
[--check] [--uninstall] [--if-stale <s>] [--quiet]` — idempotent,
backup-first (`.prejev.<timestamp>` siblings), atomic writes, honest offline
behavior. `--check` is a dry audit (no writes, reports OK/MISSING per item).
`--if-stale <seconds>` backs the launch-time lazy refresh stamp
(`~/.local/state/jev/installed.stamp`).

**Common:** canonical gate copies at
`~/.local/share/claude-multi-account/jev/jev-gate.sh` (content-addressed)
and `$SHARED_DIR/jev/`; `~/.config/jev/env` with `JEV_MODE` (default
shadow, mode 0600, non-secret); state dir `~/.local/state/jev/`.

**Claude Code:** jq-merges a PreToolUse hook group into the shared seed
`~/.claude-shared/settings.json` and every existing
`~/.claude-*/settings.json` + `~/.claude-prov-*/settings.json`:

```json
"hooks": {"PreToolUse": [
  {"matcher": "Bash|Agent|Task",
   "hooks": [{"type": "command",
              "command": "<abs>/jev/jev-gate.sh", "timeout": 5}]}]}
```

plus `claudeMdExcludes` union-merged with `["**/vendor/**/CLAUDE.md",
"**/node_modules/**/CLAUDE.md"]`. If any existing hook command contains
`jev-gate.sh`, the merge is a no-op; all other settings keys are preserved.
MCP: `.mcp.json` next to each settings.json gets
`mcpServers.jev = {command: "python3", args: ["<abs>/jev_mcp.py"], env:
{TYPESAFE_BASE_URL, TYPESAFE_API_KEY, JEV_BASE_URL, JEV_API_KEY}}` — the
deterministic, offline-safe equivalent of `claude mcp add jev -- python3
<abs>/jev_mcp.py` (which the installer also prints). Finally, a guarded
`<!-- cma-jev:decision-architecture BEGIN/END -->` block is appended to the
shared `CLAUDE.md` instructing agents to prefer `jev_ask` for allow/ask/deny,
routing, and truncation judgments and to never disable the gate silently.

**Kimi Code:** native homes `~/.kimi-code-*/config.toml` get an additive
block between `# cma-jev:hooks BEGIN/END` comment markers (TOML ignores
comments; an identical block is left alone, a differing one is rewritten
in place, atomically and after a `*.prejev.<ts>` backup):

```toml
[[hooks]]
event = "PreToolUse"
matcher = "Bash|Write|Edit"
command = "<abs>/jev-gate.sh"
timeout = 5
```

Provider homes `~/.kimi-prov-*` receive the same block from the config
renderer on the next `claude-providers sync`, but only while the Jev endpoint
cache holds at least one endpoint and the installed gate
(`~/.local/share/claude-multi-account/jev/jev-gate.sh`, installed by
`jev-setup`) is executable and `jev-setup` has been run for Kimi (its
`installed.stamp` must exist AND list `kimi` or `all`; a legacy empty stamp or
one listing only other agents does not count; `jev-setup --uninstall` removes
it, so the block is not re-added). The matcher string lives once in `scripts/jev-kimi-tools.txt`
and is read by both the renderer and `jev-setup`; with an empty cache the block is absent (the
renderer rewrites the file atomically each sync, so the block is regenerated,
never duplicated, and removed when no endpoint remains). Kimi's own runtime
acceptance of the hook has not been exercised live. Every
kimi home (native and provider) also gets `mcp.json` with the same
`mcpServers.jev` entry as Claude. Note: the endpoint key is materialized
into kimi `mcp.json` — it lives in a 0700 home, the same secrecy class as
kimi's own resolved `api_key` in `config.toml`.

**Pi CLI:** for each `~/.pi-*` / `~/.pi-prov-*` home, runs `pi install
npm:@riposta/pi-jev` (with `PI_CODING_AGENT_DIR=<home>`) when a 3-second
`npm view` probe succeeds; otherwise prints the exact manual command and
continues. With no pi homes present the npm probe is skipped entirely. The
verified package name is `@riposta/pi-jev` — older `jev-pi` /
`jev-pi-orchestrator` names are wrong/renamed. Pi's `models.json` is never
touched; env reaches the pi process from the launch wrapper.

**OpenCode:** copies `scripts/opencode-jev-plugin.js` to
`~/.config/opencode/plugins/jev-gate.js` (content-addressed) and jq-merges
into `opencode.json` (`OPENCODE_CONFIG`-overridable): `mcp.jev` (local
server, same env) and a `plugin` array entry `file://<plugin path>`.
OpenCode is not launched through cma wrappers, so the plugin itself reads
`jev-endpoints.json` (with the same TTL semantics) and resolves the key from
`~/api_keys.sh`. **Known upstream caveats:** `tool.execute.before` does not
intercept MCP tool calls (opencode issue #2319) or subagent tool calls
(#5894) — the gate covers built-in tools only. This is printed by the
installer and stated in the plugin header.

## 6. The gate protocol (`jev-gate.sh`)

Shared POSIX gate; works for Claude Code PreToolUse hooks and Kimi
`[[hooks]]` (both deliver hook JSON on stdin). Reads
`tool_name|toolName|tool` and `tool_input|toolInput|input` via jq
alternates, builds a `state` string truncated head+tail to 12000 chars, and
always sets stdout JSON and exit code consistently (exit 0 = allow/ask/
shadow, exit 2 = deny with the reason on stderr).

Decision flow:

1. **Kill switch:** `JEV_GATE=off` → instant allow, nothing logged.
2. **Risk floor (deterministic, pre-Jev):** patterns such as `rm -rf /`,
   `mkfs`, `:(){`, `> /dev/sd`, `git push --force`, `| sh` / `| bash` force
   the outcome to at least `ask` regardless of the model's answer. The floor
   can only escalate.
3. **One systemone request, two questions** (verified wire format): a
   `choice` question `gate` over `allow`/`ask`/`deny` and a `noul` question
   `risky` ("Does this action risk data loss, secret exposure, or
   irreversible external side effects?").
4. **Mapping:** choice=`deny`, or (risky ≥ `JEV_GATE_THRESHOLD` 0.8 and
   choice≠allow) → deny; choice=`ask` or risky ≥ `JEV_RISKY_THRESHOLD`
   (0.7) → ask; risky > 0.7 with an allow answer escalates to at least ask;
   else allow.
5. **Mode:** `shadow` (default) always allows and logs the would-be
   decision; `enforce` returns the real decision. Claude-shaped stdout:
   `{"hookSpecificOutput":{"hookEventName":"PreToolUse",
   "permissionDecision":"allow|ask|deny","permissionDecisionReason":"jev: …"}}`.
6. **Fail-open:** any transport/parse error or curl timeout
   (`JEV_GATE_TIMEOUT`, 2 s) → allow, logged with `fallback:
   "timeout"|"endpoint_error"`. Fail-closed is available via
   `JEV_GATE_FAIL=closed` and is documented as risky: an endpoint outage then
   blocks all gated tool calls.

Evidence log — one JSON line per gated call in
`$JEV_STATE_DIR/decisions.jsonl` (`JEV_STATE_DIR` default
`~/.local/state/jev`):

```json
{"ts": 1759700000123, "agent": "claude", "tool": "Bash",
 "state_hash": "0123abcd4567ef89", "question": "gate", "answer": "allow",
 "risky_p": 0.12, "confidence": 0.93, "latency_ms": 141,
 "endpoint": "jev-local", "mode": "shadow", "enforced": false,
 "fallback": null}
```

`fallback` is `null`, `"timeout"`, or `"endpoint_error"`. The raw state is
never logged — only its truncated sha256 prefix — so secrets in tool inputs
cannot land in the log.

## 7. The MCP server (`jev_mcp.py`)

Stdlib-only python3 MCP server (JSON-RPC 2.0 over stdio, Content-Length
framing per the MCP stdio spec; newline-delimited input also accepted).
Tools:

| Tool | Arguments | Returns |
|------|-----------|---------|
| `jev_ask` | `state`, `question`, `options?` | With `options`: a `choice` answer `{answer, probabilities, confidence, endpoint, model}`. Without: a `noul` probability. |
| `jev_models` | — | `{endpoint, models[]}` from `GET /v1/models`. |
| `jev_stats_summary` | — | Aggregate of the local `decisions.jsonl` evidence log. |

Reads `JEV_BASE_URL` or `TYPESAFE_BASE_URL`, `JEV_API_KEY` or
`TYPESAFE_API_KEY`, `JEV_MODEL` (default `jev-latest`), `JEV_MCP_TIMEOUT`
(default 4 s). An unreachable endpoint yields a structured `isError: true`
result — never a hang, never a crash. Question names are never sent to the
model; all semantics live in `instructions`/`criteria` (per the verified
systemone wire format).

### 7.1 Adopting Jev in your own project: the Decision Architecture Rule

Once `jev-setup` has installed the per-agent artifacts for a consuming
project, paste this rule into that project's own `CLAUDE.md` so Claude Code
reaches for `jev_ask` instead of spending a full LLM turn on a decision that
doesn't need one:

```markdown
## Decision Architecture Rule

Before writing any conditional logic that requires semantic understanding
(classification, routing, scoring, quality judgment), ask:

1. Can this be expressed as a Noul, Choice, or Score question?
2. If yes, define the question and options explicitly in code comments.
3. Call the `jev_ask` MCP tool (installed by this toolkit's `jev-setup`) for
   the decision.
4. Write the threshold and fallback logic in plain code.
5. Only fall back to Claude Code for the generative parts (descriptions,
   summaries, explanations, code generation).
```

This is the "jev-architect" pattern: propose the split — routing/urgency on
Jev, the reply on an LLM — before writing the code, not after.

### 7.2 `jev_recommend_tier` — advisory model-tier routing

**Important constraint:** Claude Code's PreToolUse hooks (what `jev-gate.sh`
is) can only return `allow`/`ask`/`deny` — they cannot rewrite a tool call's
parameters. Jev therefore cannot literally force which model a Task/Agent
subagent dispatch uses; there is no hard enforcement point for that in the
current hook API. `jev_recommend_tier(task_description, risk_hint?)` is an
ADVISORY MCP tool instead: the orchestrating Claude calls it explicitly
before deciding which model to pass to a subagent dispatch, gets back
`{"tier": "haiku"|"sonnet"|"opus", "confidence", "reasoning"}`, and decides
for itself whether to act on it. Nothing in this toolkit enforces the
recommendation — if you want cost reduction from this, your own CLAUDE.md
(or the Decision Architecture Rule above) needs to instruct the orchestrator
to call it and act on the result.

### 7.3 Multi-candidate specialization/voting gateway (`JEV_ROUTES_FILE`)

Opt-in and additive — absent entirely, `jev_ask` behaves exactly as it
always has (single configured endpoint, no routing). Point `JEV_ROUTES_FILE`
at a routes config (template: `scripts/providers/jev-routes.json.template`)
mapping a `decision_type` string to an ordered list of candidate endpoints
(the same record shape `detect_jev_records()` produces — `provider_id`,
`base_url`, `key_var`, `model`), a `min_confidence` floor, and an optional
`min_agreement`. Pass `decision_type` to `jev_ask` to route through it:

- **No `min_agreement`:** ordered failover — the first candidate whose
  confidence clears `min_confidence` wins.
- **`min_agreement` set:** requires at least two candidates to independently
  return the SAME answer, each clearing `min_confidence`, before the result
  is trusted (`agreement: true`, `agreed_candidates: [...]`). When
  candidates disagree or neither clears the bar, the gateway degrades
  honestly — it reports `degraded: true, agreement: false` and falls back
  to the highest-priority live answer rather than silently trusting one
  candidate.

**Per-candidate CA:** a candidate may carry its own `ca_file`. A relative
path resolves against the directory of the `JEV_ROUTES_FILE` that names it
(never the process working directory). A candidate with no `ca_file`
deliberately trusts `JEV_CA_FILE` as an extra root on top of the system store.
An explicit `ca_file` that is unreadable fails closed; TLS verification is
never off.

**Honest limitation:** this environment has no second real decision model
(Kev, Laya, etc. — surveyed in `docs/research/jev-ecosystem.md`) reachable
over the network. The routing/gating MECHANISM above is real and covered by
`scripts/tests/test_jev_routes_gateway.sh` against two fixture endpoints —
but no live multi-model vote has actually run against a real second
decision model. Wiring a real Kev/Laya endpoint in as a second candidate is
a follow-up integration step, not something this toolkit fabricates.

## 8. `jev-stats` — savings and calibration report

`jev-stats [--days N] [--json]` reads `decisions.jsonl` and reports:
totals by answer / mode / agent / endpoint, fallback count, average latency,
the shadow-mode would-be split (deny / ask / allow, plus the would-deny
rate), and **ESTIMATED tokens saved**:

```
saved = total_decisions * JEV_EST_INPUT_TOKENS   (default 1500)
      + enforced_ask_or_deny * JEV_EST_OUTPUT_TOKENS (default 200)
```

Rationale: each gated decision replaces approximately one avoided LLM
round-trip of guard reasoning, and each enforced ask/deny deflects one wasted
tool-result ingestion. Both constants are env-overridable; the formula is
printed in the report header. **These are estimates, not metered values** —
no token counter is read anywhere in this pipeline. With an empty log the
report prints a zero-state hint and exits 0. The report footer repeats the
calibration policy: review shadow verdicts for a week before
`jev-setup --mode enforce`.

## 8a. `jev-calibrate` — threshold calibration loop

The gate's `ask`/`deny` thresholds (0.7/0.8 by default) are population-level
constants. The POC design doc is explicit that per-project calibration is
mandatory — "nobody can hand you trustworthy numbers for your use case."
`jev-calibrate.sh` implements the shadow -> label -> sweep -> enforce ->
drift-check loop against this toolkit's own stdlib-only tooling (not the
unverified third-party `jevcal`/`jevkit-calibrate` packages the doc names).

```
cp "$JEV_STATE_DIR/decisions.jsonl" shadow_batch.jsonl   # freeze a snapshot
jev-calibrate label --data shadow_batch.jsonl --labels ground_truth.json --out labeled.jsonl
jev-calibrate sweep --data labeled.jsonl --target-accuracy 0.95 --lock "$JEV_STATE_DIR/decisions.lock.json"
jev-calibrate check --data fresh_labeled.jsonl --lock "$JEV_STATE_DIR/decisions.lock.json" --max-ece 0.05 --max-mce 0.15
```

**Honest gap**: there is no built-in "ask an LLM to label this" call. `label`
merges OPERATOR-SUPPLIED ground truth — a JSON array of
`{"index":N,"ground_truth_ask":bool,"ground_truth_deny":bool}` keyed by
0-based line number in the frozen snapshot — into the decisions. Wiring a
live LLM-teacher call (e.g. asking Claude to label each shadow decision) is a
documented follow-up integration point, not something this script fakes.

`sweep` finds the lowest `risky_p` threshold reaching `--target-accuracy`
against each of `ground_truth_ask`/`ground_truth_deny` independently (the
same `risky_p` predictor the gate already emits), and writes the result —
including ECE (Expected Calibration Error), MCE (Maximum Calibration Error),
and Brier score — to a `decisions.lock.json` lock file. If no threshold
reaches the target, that threshold is reported as `null` with an explanatory
note: per the POC doc, "none is a real answer" — it means the gate question
needs revising, not the bar lowered.

`jev-gate.sh` reads `decisions.lock.json` automatically (precedence: an
explicit `JEV_GATE_THRESHOLD`/`JEV_RISKY_THRESHOLD` env var wins over the
lock file, which wins over the 0.8/0.7 fixed defaults) — no extra wiring
needed once a lock file exists.

`check` recomputes ECE/MCE/Brier on a *fresh* labeled batch using the
*locked* thresholds (no re-sweep) and reports `PASS`/`WARN`/`FAIL` plus the
drift percentage against the lock's own recorded calibration. Exit codes
follow the POC doc's CI-gate convention: `0` = pass, `1` = bounds exceeded,
`2` = config/input error (e.g. missing lock file) — never a silent pass on
bad input.

## 8b. Kill-switch record and setup consent

- `JEV_GATE=off` still passes every tool call straight through, but each use is
  now **recorded**: one UTC-timestamped line (agent, cwd) is appended to
  `$JEV_STATE_DIR/gate-off.log`, and `jev-stats` (text and `--json` as
  `gate_off.count` / `gate_off.last`) reports the number of uses, so an
  unevaluated tool call is never invisible.
- `jev-setup` edits files in agent homes (`~/.claude-*`, `~/.kimi-*`, `~/.pi`,
  `~/.config/opencode`, the shared `CLAUDE.md`). It does so **only with
  consent**: `--yes`, `JEV_SETUP_CONSENT=1`, an interactive `y`, or - for the
  launch-time lazy `--if-stale` refresh only - the stamp
  (`$JEV_STATE_DIR/consent`) a previous consented run left. Without consent it
  exits 3 and writes nothing. `--check` never writes and `--uninstall` only
  restores. Every file it edits is backed up first (`*.prejev.<timestamp>`).

## 9. `jev-spec-setup` — CI spec verification (opt-in)

`jev-spec-setup [--force] /path/to/target-repo` writes two templates into a
target repository: `jev-spec.config.ts` (spec requirement ↔ `codePaths`
targets, one focused question per requirement) and
`.github/workflows/jev-verify.yml` (PR verification: trusted PRs run `bunx
jev-spec check --diff origin/main...HEAD --format markdown` into the step
summary; fork PRs get `--dry-run` so the key is never exposed to forks). It
refuses to overwrite without `--force` and never runs npm itself — it prints
`npm i -D jev-spec` as the next step. Key-name note: jev-spec reads
`TYPESAFE_AI_API_KEY`, which is deliberately different from the runtime
`TYPESAFE_API_KEY` used by the gate and MCP server. Not part of default
`jev-setup`.

## 10. Environment variable reference

| Variable | Default | Meaning |
|----------|---------|---------|
| `JEV_BASE_URL` / `JEV_API_KEY` / `JEV_MODEL` | — / keys-file / `jev-latest` | Active endpoint, key, model (exported per launch from the cache). |
| `TYPESAFE_BASE_URL` / `TYPESAFE_API_KEY` | = JEV_* | SDK-convention aliases of the above. |
| `TYPESAFE_AI_API_KEY` | — | jev-spec CI key name (different by design; §9). |
| `JEV_MODE` | `shadow` | `shadow` (log would-be decisions) or `enforce`. |
| `JEV_GATE` | `on` | `off` = gate kill switch (instant allow, nothing logged). |
| `JEV_GATE_THRESHOLD` | `0.8` | Risky-probability deny floor. |
| `JEV_RISKY_THRESHOLD` | `0.7` | Risky-probability floor that escalates allow→ask. |
| `JEV_GATE_TIMEOUT` | `2` | Gate curl timeout (seconds). |
| `JEV_GATE_FAIL` | `open` | `closed` = fail-closed on endpoint error (risky; §6). |
| `JEV_STATE_DIR` | `~/.local/state/jev` | Evidence log directory. |
| `JEV_MCP_TIMEOUT` | `4` | MCP server HTTP timeout (seconds). |
| `JEV_AGENT` | `unknown` | Agent name fallback in the evidence log. |
| `JEV_EST_INPUT_TOKENS` / `JEV_EST_OUTPUT_TOKENS` | `1500` / `200` | Savings-estimate constants (§8). |
| `CMA_JEV_PINS_FILE` | `scripts/providers/jev.json` | Pins-file override (test seam). |
| `CMA_JEV_HTTP_TIMEOUT` | `2` | Detection probe timeout (seconds). |
| `CMA_JEV_CACHE_TTL` | `300` | Endpoint-cache TTL (seconds). |
| `CMA_JEV_PREFER` | — | Comma list of provider_ids ranked first. |
| `CMA_JEV_DISABLE` | `0` | `1` = global opt-out (no exports, no notice, no refresh). |
| `CMA_JEV_QUIET` | `0` | `1` = suppress the INACTIVE notice. |
| `CMA_JEV_ACTIVE` / `CMA_JEV_ENDPOINT_ID` | — | Launch-time outputs of `cma_jev_env`. |
| `CMA_JEV_REFRESH_KICKED` | — | Set to 1 when a launch kicked a background cache refresh (test seam). |
| `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` / `MAX_THINKING_TOKENS` | `50` / `10000` | Token-reduction knobs exported when Jev is active (pre-set values preserved). |

## 11. Honest limitations

1. The OpenCode gate covers **built-in tools only**: `tool.execute.before`
   does not intercept MCP tool calls (upstream #2319) or subagent tool calls
   (#5894).
2. `@riposta/pi-jev` requires network at install time; offline hosts get the
   exact manual command. Its env-var names beyond the SDK convention are
   unverified.
3. **Shadow-first is mandatory**: run at least one calibration week reviewing
   `jev-stats` shadow verdicts before `--mode enforce`.
4. Jev confidence is a calibration score, **not** an error probability; the
   gate thresholds (0.8 / 0.7) are heuristics.
5. The gate is **fail-open by design** — availability over enforcement.
   `JEV_GATE_FAIL=closed` exists but is not the default and is risky.
6. `jev-architect` (BenjaminPolge) does not call Jev (heuristics only) and is
   excluded from this integration.
7. The pi package is `@riposta/pi-jev`; `jev-pi` / `jev-pi-orchestrator` in
   older material are wrong/renamed — do not reference them.
8. `jev-stats` token savings are documented **estimates**, not metered
   values.
9. TypeSafe hosted has a signup waitlist; OpenRouter is the reliable hosted
   path — reflected in the endpoint priority order.
10. StartLux-Decision local replication weights are **CC BY-NC-4.0** —
    non-commercial use only (code is Apache-2.0). See
    [../research/jev-ecosystem.md](../research/jev-ecosystem.md).
11. **Decide-gateway transport (fixed in v1.32.0), with an honest boundary.**
    Detection, the gate and the MCP server speak HTTPS + bearer key as above.
    Verified only against a hermetic stand-in (`jev_https_server.py`, a
    self-signed cert, 401/no-key/untrusted-CA/plain-http/unreachable cases);
    it has **not** been run against a real `llmctl decide` gateway. The
    OpenCode plugin does not read `JEV_CA_FILE` (export `NODE_EXTRA_CA_CERTS`).
    Plain http is opt-in (`CMA_JEV_ALLOW_HTTP=1`), loopback-only and key-free.
12. Cross-references: decision models are governed by Constitution §11.4.279 (A detection, C never an alias, D
    validation);
    local-model validation by §11.4.277; Vision QA by §11.4.278; the toolkit's
    hub-engine placement by §11.4.28(C)/§11.4.31 (see
    [hub-engine-placement](../diagrams/hub-engine-placement.svg)).
