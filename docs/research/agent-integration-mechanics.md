# Jev-Class Decision Models × CLI Coding Agents — Integration Mechanics

Research date: October 2026. Status tags:
- **VERIFIED** = confirmed against official docs, vendor changelogs, or source repositories cited below.
- **UNVERIFIED** = found only on third-party/community sources, or not found at all; treat as a lead to confirm before relying on it.

## 0. What a "Jev-class decision model" is (shared ground)

- TypeSafe AI's **Jev** is the reference "System One" decision model: `POST https://api.typesafe.ai/v1/systemone`, Bearer key in `TYPESAFE_API_KEY`. Request: `{model, state, questions}`; question types **noul** (P(yes) 0–1), **choice** (≤255 named options + probability distribution + confidence), **score** (2–10 ordered levels). Model id `jev-1.13.0`; aliases `jev-latest`, `jev-preview`. Pricing $0.042/1M input tokens, output free; ~70–500 ms latency; 64k context (32k state). SDKs: Python `typesafe-sdk`, JS `@typesafe-ai/sdk` (honor `TYPESAFE_BASE_URL` / `TYPESAFE_DEFAULT_MODEL`). **VERIFIED** (docs.typesafe.ai, openrouter.ai docs, Vercel changelog coverage).
- Jev is **not** an LLM endpoint: it cannot be wired in as a chat model via `ANTHROPIC_BASE_URL`-style redirects. Integration into coding agents is therefore via **hooks** (decision gates on tool calls), **MCP tools** (agent calls `jev_evaluate` explicitly), or **plugins/extensions** (routing, compaction, gating logic that calls `/v1/systemone` internally).
- Local wire-compatible servers (LAN hosts exposing `POST /v1/systemone`, e.g. `http://127.0.0.1:8095/v1/systemone`) work anywhere a base URL is configurable (SDKs honor `TYPESAFE_BASE_URL`; Laya-style servers accept the same body). **VERIFIED pattern** (multiple compatible-server docs confirm the request shape is stable).

---

## 1. Claude Code (Anthropic)

### 1.1 Hooks system — VERIFIED (code.claude.com/docs/en/hooks, hooks-guide)

Hooks are declared in `.claude/settings.json` (project), `~/.claude/settings.json` (user), or `.claude/settings.local.json`. Three nesting levels: event → matcher group → handlers. Five handler types: `command` (shell, JSON on stdin, exit codes/stdout reply), `http`, `mcp_tool`, `prompt`, `agent`. Default timeout 600 s for command/http.

Exact schema for a Jev permission gate:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/jev-gate.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

- Matcher is a **regex against the tool name** (e.g. `"Edit|Write"`, `"Bash"`, `""` or `"*"` for all).
- PreToolUse contract: exit 0 = allow; exit 2 = block, stderr shown to Claude; or stdout JSON `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow|deny|ask|defer", "permissionDecisionReason": "..."}}` (also `updatedInput` to rewrite args). Precedence when hooks disagree: deny > defer > ask > allow.
- Other useful events for Jev integration: `UserPromptSubmit` (skill/routing suggestion), `PostToolUse` / `PostToolUseFailure`, `Stop` (loop-until-verified), `PreCompact`, `SubagentStart`/`SubagentStop`, `SessionStart`.
- **HTTP hook type** (VERIFIED in hooks reference) can POST event JSON directly to a gateway: `{"type": "http", "url": "http://127.0.0.1:8095/hooks/pre-tool-use"}` — the gateway can itself call `/v1/systemone` and return the decision JSON. This is the cleanest LAN-gateway integration.

### 1.2 MCP registration — VERIFIED

- `claude mcp add <name> <command> [args...]`; `claude mcp add --transport http <name> <url>` for remote servers.
- Project-scoped `.mcp.json` in repo root: `{"mcpServers": {"jev": {"command": "uvx", "args": ["jev-netlify-mcp"], "env": {"TYPESAFE_API_KEY": "..."}}}}` (standard mcpServers shape).

### 1.3 Plugins / skills — VERIFIED mechanics

`claude plugin marketplace add <owner/repo>` then `claude plugin install <plugin>@<marketplace>`. Plugins can bundle hooks, skills (SKILL.md with frontmatter), agents, and MCP servers. Hooks can also live in skill/agent frontmatter in the same settings format.

### 1.4 Model / env configuration — VERIFIED

- `ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY`/`ANTHROPIC_AUTH_TOKEN` redirect the whole agent through a proxy/gateway.
- Model env vars: `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL` (per-tier routing: subagents can be pinned to haiku/sonnet tiers).
- CLAUDE.md / `.claude/rules/` loaded into context each session.

### 1.5 Jev plugin inventory (Claude Code)

| Plugin | Repo | What it does | Install | Hook config | Status |
|---|---|---|---|---|---|
| jev-claude-code (weiping) | github.com/weiping/jev-claude-code | Hooks call Jev for allow/ask/deny gating, output truncation, conditional project guidance, subagent model routing; thresholds in code; **shadow mode default → enforce** | `git clone` (pin commit `8351fb26…`) or `claude plugin marketplace add weiping/jev-claude-code && claude plugin install jev@jev-engineering` | PreToolUse/PostToolUse/UserPromptSubmit command hooks | VERIFIED via jevlist.ai review (upstream README at pinned commit); repo itself not independently opened |
| jev-architect (BenjaminPolge) | github.com/BenjaminPolge/jev-architect | Makes Claude Code/Codex ask whether a step needs a generative LLM at all or belongs on Jev ("architecture arbitrage") | plugin/skill install per README | UNVERIFIED — jev.page notes it "does not call Jev; proposals are heuristics"; do not confuse with karanb192/jev-architect | PARTIALLY VERIFIED |
| gatekeeper (AgriciDaniel) | github.com/AgriciDaniel/gatekeeper | Python routing engine: YAML rules + Jev judgments route requests to agents/skills; Claude Code hooks discover installed roster, confidence bands → route/suggest/confirm verdicts. Env: `GATEKEEPER_ENV_FILE`, `~/.config/gatekeeper/env`, `GATEKEEPER=off` kill switch; Python 3.11+ | per repo README | Claude Code hook (UserPromptSubmit-style router) | VERIFIED existence (jevland repo tracker, 19 stars, last push 2026-09-23) |
| jev-semaphore | — | **Not found** in any search. Likely very new or renamed | — | — | UNVERIFIED / NOT FOUND |
| jev-use | — | **Not found** as a distinct repo | — | — | UNVERIFIED / NOT FOUND |
| jev-agent-hooks | (listed in hellogumbo/awesome-jev) | Jev hooks for Claude Code, Codex **and pi**: per-turn skill suggestion, subagent model routing | per repo | PreToolUse/UserPromptSubmit | VERIFIED existence (awesome-jev directory) |
| jev-firewall | (site, awesome-jev) | PreToolUse hook: deterministic shell-aware rules first; unmatched actions → Jev calibrated allow/ask/block, fails closed | per repo | PreToolUse command hook | VERIFIED existence (awesome-jev) |
| DarioFontanel/jev-claude-code | github.com/DarioFontanel/jev-claude-code | Paste-in prompt pack, no hooks (alternative to weiping's) | copy prompts | none | VERIFIED via jevlist.ai |
| jev-spec skills | github.com/nozomi-koborinai/jev-spec | `gh skill install nozomi-koborinai/jev-spec jev-spec-init` / `jev-spec-fix` (Agent Skills; needs gh CLI v2.90+) | gh skill install | n/a (skills, not hooks) | VERIFIED (repo README) |

### 1.6 Token-reduction mechanics — VERIFIED

- `/clear` wipes conversation context; `/compact [instructions]` manual compaction.
- `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` (1–100): moves auto-compact trigger earlier than default ~83.5%; values above default are silently clamped (Math.min in source; issue #31806). `CLAUDE_CODE_AUTO_COMPACT_WINDOW` sets absolute window.
- `MAX_THINKING_TOKENS=0` disables extended thinking (except newest adaptive-reasoning models); on Opus 4.6/Sonnet 4.6 `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING=1` reverts to fixed budget. Effort levels (`low|medium|high|xhigh|max`) via `/model` or settings trade tokens vs capability.
- `claudeMdExcludes`: `{"claudeMdExcludes": ["**/vendor/**/CLAUDE.md"]}` — glob list of CLAUDE.md files to skip loading; merges across settings layers. Session-wide (cannot scope per-subagent; open feature request).
- Prompt caching: automatic on Anthropic API; keep CLAUDE.md stable and put volatile content last to maximize cache hits.
- Subagent model tiers: frontmatter `model: haiku|sonnet|opus` in `.claude/agents/*.md` (or `ANTHROPIC_DEFAULT_HAIKU_MODEL` etc.) — VERIFIED pattern.

---

## 2. opencode (sst/opencode)

### 2.1 Config file — VERIFIED (opencode.ai/docs)

- Locations: `~/.config/opencode/opencode.json` (global) and `opencode.json` (project; merged, project wins). `$schema: "https://opencode.ai/config.json"`.
- Custom OpenAI-compatible provider (VERIFIED docs example):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "jev-gw": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Local Jev gateway (LLM tier)",
      "options": {
        "baseURL": "http://127.0.0.1:8095/v1",
        "apiKey": "{env:LOCAL_LLM_KEY}",
        "headers": {}
      },
      "models": {
        "my-chat-model": { "name": "Chat model", "limit": { "context": 128000, "output": 8192 } }
      }
    }
  },
  "model": "jev-gw/my-chat-model"
}
```

- `options.baseURL` = everything before `/chat/completions`. `apiKey` supports `{env:VAR}` and `{file:path}` interpolation. Agents are configured under the `agent` key (per-agent model, prompt, tools, permissions). MCP servers go in the same config (`mcp` key; VERIFIED pattern per opencode MCP docs).

### 2.2 Plugin system — VERIFIED (opencode.ai/docs/plugins)

- Local: `.opencode/plugins/*.ts|js` (project) or `~/.config/opencode/plugins/` (global). npm: `"plugin": ["opencode-helicone-session", "@my-org/custom"]` in opencode.json; installed via Bun at startup, cached in `~/.cache/opencode/node_modules/`.
- Plugin signature: `export const MyPlugin: Plugin = async ({ project, client, $, directory, worktree }) => ({ "tool.execute.before": async (input, output) => { ... }, ... })`.
- Hook events: `tool.execute.before` (can **block** a native tool call by throwing), `tool.execute.after`, `chat.message`, `experimental.chat.system.transform` (SessionStart surrogate), `experimental.session.compacting` (inject/replace compaction context), `session.created`, `permission` hooks. Custom tools via `tool()` helper (Zod schema; plugin tool names override built-ins).
- **Caveats VERIFIED from upstream issues**: plugin `tool.execute.before` does **not** intercept MCP tool calls (bug #2319) nor subagent tool calls (bug #5894); context injection into LLM turns from hooks is a feature request (#17412). A Jev permission gate in opencode therefore covers built-in tools (bash/edit/write) only — acceptable for most gating.

### 2.3 Jev decision-model hook (blueprint sketch)

A `.opencode/plugins/jev-gate.ts` implementing `tool.execute.before` → POST state (tool name + args summary) to `http://127.0.0.1:8095/v1/systemone` with a noul question "Is this tool call safe to auto-approve?" → throw to block below threshold. See §8 blueprint. **Mechanics VERIFIED; specific plugin code is my synthesis (UNVERIFIED as shipped artifact).**

---

## 3. pi (Mario Zechner / badlogic, Earendil Inc.)

### 3.1 Core config — VERIFIED (pi.dev, github.com/earendil-works/pi, multiple provider guides)

- Config dir: `~/.pi/agent/` (override `PI_CODING_AGENT_DIR`). Files: `models.json`, `settings.json`, `auth.json`, `extensions/`, `skills/`, `AGENTS.md`, `APPEND_SYSTEM.md`. Project-local: `.pi/`.
- `models.json` — top-level must be `providers`; custom OpenAI-compatible endpoint (VERIFIED, multiple aligned guides):

```json
{
  "providers": {
    "lan-gateway": {
      "baseUrl": "http://192.168.1.20:8095/v1",
      "api": "openai-completions",
      "apiKey": "$LAN_GW_KEY",
      "models": [
        { "id": "qwen3-coder", "name": "Qwen3 Coder (LAN)", "contextWindow": 128000, "maxTokens": 16384 }
      ]
    }
  }
}
```

- Fields: `api`: `openai-completions` | `openai-responses` | `anthropic-messages` | `google-generative-ai`; `apiKey` accepts raw string or `"$ENV_VAR"` (pi ≥1.0 env syntax); optional `headers`, `compat` (`supportsStore` etc.), per-model `reasoning`, `input`, `cost`, `contextWindow`, `maxTokens`. **A `models` array replaces the provider's built-ins.** Verify with `pi --list-models`, `pi --provider lan-gateway --model qwen3-coder`; `/model` re-reads the file each open.
- `settings.json` holds `packages: [...]` (installed package specs) and general settings. `auth.json` optional key store: `{"provider": {"type": "api_key", "key": "..."}}`.
- Note: Jev is not a chat model; the `models.json` route is for the LLM tier (routing *to* cheap local models), while Jev itself enters via extensions.

### 3.2 Package/extension system — VERIFIED

- `pi install npm:<pkg>[@version]`, `pi install git:github.com/<user>/<repo>`, `pi install /abs/path`; `-l` for project-local (`.pi/settings.json`), global → `~/.pi/agent/settings.json` `packages` array. Try without installing: `pi -e npm:<pkg>`. Update: `pi update --extensions` / `--all` (versioned npm specs skipped); remove: `pi remove npm:<pkg>`. Restart or `/restart` after install. Single-file extensions can also be dropped into `~/.pi/agent/extensions/` (hot-reload with `/reload`).
- Extensions are TypeScript: register tools, slash commands, keybindings, event hooks, system-prompt edits, custom TUI. **They run with full user permissions — review before installing** (official warning).
- MCP: in core since 2026-09-29 (+ Codemode); before that, `pi-mcp-adapter` extension.

### 3.3 Jev packages for pi

| Package | npm / repo | What it installs | Status |
|---|---|---|---|
| @riposta/pi-jev | npm `@riposta/pi-jev` | Full Jev layer: **router** (model routing), **gate** (permission confirm), **shield**, **prune** (context pruning), **watchdog** modules, each with `off`/`shadow`/`live` modes (shadow→enforce). Commands under `/jev`: `/jev` status, `/jev explain [hook]`, `/jev shadow <module> on\|off`, `/jev off`/`/jev on` kill switch, `/jev stats [days]` (telemetry jsonl), `/jev trace [n]`, `/jev recommend`. | VERIFIED (libraries.io/npm page, 2026-09-24). Install: `pi install npm:@riposta/pi-jev` |
| pi-typesafe family (narumiruna/pi-extensions) | `@narumitw/pi-typesafe`, `pi-typesafe-compact`, `pi-typesafe-search` | Typed Jev decisions as tools; Jev-selected history compaction; FTS5 + Jev rerank search. Marked experimental | VERIFIED (monorepo README) |
| jev-pi / jev-pi-orchestrator (as named in task) | — | The described feature set (permission gate, output ladder, conditional context, routing, `/jev:init`, `/jev:stats`, shadow→enforce) matches **@riposta/pi-jev** closely but with `/jev:`-prefixed command names. No packages literally named `jev-pi` or `jev-pi-orchestrator` were found | UNVERIFIED as named; likely renamed/conflated with @riposta/pi-jev |
| pi-autoresearch | — | Not found | UNVERIFIED / NOT FOUND |

---

## 4. Kimi Code CLI (Moonshot AI)

### 4.1 Config — VERIFIED (kimi.com/code/docs, moonshotai.github.io/kimi-code, Vercel docs)

- Install: `curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash` or `npm install -g @moonshot-ai/kimi-code` (Node ≥22.19); repo `MoonshotAI/kimi-code` (MIT). The old Python `MoonshotAI/kimi-cli` is **archived** (2026-09-23) — its `~/.kimi/config.toml` + `~/.kimi/mcp.json` belong to the legacy tool.
- Config: `~/.kimi-code/config.toml` (override dir with `KIMI_CODE_HOME`; some third-party docs cite `$KIMI_SHARE_DIR` — the official docs use `~/.kimi-code`). Keys include `default_model`, `default_permission_mode`, `default_thinking`, `default_plan_mode`, provider blocks with `base_url` + literal `api_key` (file created 0600), `[models]` shortlist. `/login` for OAuth (Kimi Code platform, moonshot.cn, moonshot.ai).
- Third-party provider: add provider with `base_url` pointing at any OpenAI-/Anthropic-compatible endpoint (VERIFIED via Vercel AI Gateway guide which writes exactly this).

### 4.2 MCP — VERIFIED

- `~/.kimi-code/mcp.json` (global) or `.kimi-code/mcp.json` (project wins); standard `mcpServers` shape: `{"mcpServers": {"locus": {"command": "/abs/path", "args": ["serve"]}}}`. Manage in-session with `/mcp-config`.

### 4.3 Hooks — VERIFIED (official hooks docs)

`[[hooks]]` array in `~/.kimi-code/config.toml`; exactly four fields allowed (`event`, `matcher`, `command`, `timeout`; extras fail config load):

```toml
[[hooks]]
event = "PreToolUse"
matcher = "Bash|WriteFile|StrReplaceFile"
command = ".kimi/hooks/jev-gate.sh"
timeout = 10
```

- Events include `PreToolUse`, `PostToolUse`, `Notification`, `Stop`, `SubagentStop`, `SessionStart` (13 events in the current docs). Scripts get JSON on stdin (`hook_event_name`, `session_id`, `cwd`, plus tool fields, snake_case). Matcher = regex. Parallel execution; identical commands dedupe. Working dir = project dir.

---

## 5. Jev MCP servers (agent-agnostic)

| Server | Repo / package | Tools | Install | Status |
|---|---|---|---|---|
| jev-netlify-mcp (demircigoksu) | glama.ai/mcp/servers/demircigoksu/jev-netlify-mcp | `jev_evaluate(state, questions, model="jev-latest")`, `jev_models()`; ships agent instructions for good question-writing; key-locked Netlify proxy (no TypeSafe key needed) or direct `TYPESAFE_BASE_URL`/`TYPESAFE_API_KEY` fallback. Env: `JEV_PROXY_URL`, `JEV_PROXY_KEY` | uvx/pip package `jev-netlify-mcp` per repo README | VERIFIED (glama listing + README) |
| System One Connector (itsmostafa) | mcpservers.org/servers/itsmostafa/system-one-connector | noul/choice/score evaluate, batch up to 500 records as `items`; single static binary, `evaluate setup mcp` auto-configures clients | download binary; `evaluate setup mcp` | VERIFIED (mcpservers.org listing) |
| gnapse/jev MCP | npm package (MCP batches cap 100) | evaluate tools | npx | VERIFIED existence (jev.page resource table) |
| Other community servers | glama lists ≥4 Jev MCP servers (offline-mock default, caching/cost-tracking variants) | mostly `jev_evaluate`-style | npx/uvx | VERIFIED existence, quality mixed |

Generic registration for Claude Code: `claude mcp add jev -- npx <pkg>` or `.mcp.json`; for opencode: `mcp` block in opencode.json; for kimi: `~/.kimi-code/mcp.json`; for pi: core MCP config or `pi-mcp-adapter`.

---

## 6. OpenRouter as Jev provider — VERIFIED (openrouter.ai/docs/guides/community/jev)

- Two surfaces, same OpenRouter key, same billing:
  - **Decisions API**: `POST https://openrouter.ai/api/alpha/decisions` — plain HTTP or OpenRouter TS/Python/Go SDKs.
  - **System One API**: `POST https://openrouter.ai/api/v1/systemone` — drop-in for TypeSafe SDK: `new TypeSafeClient({ apiKey: process.env.OPENROUTER_API_KEY, baseURL: 'https://openrouter.ai/api' })` (SDK appends `/v1/systemone`; tested with SDK 0.6.0).
- Model ids: `typesafe/jev-1.13` (bare `jev-1.13` maps to it), `jev-latest`. Task's "typesafe/jev-1.13" is correct.
- Auth: `Authorization: Bearer $OPENROUTER_API_KEY`. Context on OpenRouter route listed as 32k (vs 64k direct).
- Also: **Jev Router** on OpenRouter (free) uses Jev to pick which LLM answers each request.

---

## 7. Token-consumption reduction patterns — VERIFIED components

1. **Permission gating (Jev noul)**: hook asks "is this tool call safe/necessary?" — replaces long guard prompts in CLAUDE.md with a $0.000056-class decision call (gatekeeper author's measured figure, 351 ms). Shadow mode first, then enforce with threshold + fail-open/fail-closed policy.
2. **Model routing per tier/subagent**: Jev **choice** question picks haiku/sonnet/opus (or local/cheap/cloud) per subtask; Claude Code: subagent `model:` frontmatter / `ANTHROPIC_DEFAULT_*_MODEL`; pi: @riposta/pi-jev `router` module; opencode: per-`agent` model keys. weiping/jev-claude-code and jev-agent-hooks implement exactly this.
3. **Output ladder / truncation**: PostToolUse hook scores tool output (Jev score: "how much of this output is noise?") and truncates before it enters context. In weiping/jev-claude-code (output truncation hook); pi: @riposta/pi-jev `prune`; opencode: `experimental.session.compacting` or context-mode plugin (claimed 98% reduction).
4. **Conditional context loading**: UserPromptSubmit/SessionStart hook uses Jev choice to decide *which* CLAUDE.md fragments/skills/rules to inject (29/32 correct skill picks reported for a 581-skill library, Reddit/r/ClaudeCode); Claude Code `claudeMdExcludes` as the static complement.
5. **Spec verification (jev-spec)** — VERIFIED (github.com/nozomi-koborinai/jev-spec): `npm i -D jev-spec`; config `jev-spec.config.ts` declaring targets (spec requirements ↔ `codePaths`, one focused Jev question per requirement); CLI `bunx jev-spec check`, `--target`, `--staged` (pre-commit), `--diff origin/main...HEAD` (PR CI; untouched targets SKIPPED, not billed), `--dry-run` for untrusted fork PRs, `--format markdown >> $GITHUB_STEP_SUMMARY`. Env key: `TYPESAFE_AI_API_KEY`. Recommended GitHub Actions workflow in repo README (never expose the key to fork PRs; use dry-run or environment approvals).
6. **Compaction hygiene**: `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` earlier triggers; pi `pi-typesafe-compact` (Jev selects what to summarize); opencode compaction hooks.

---

## 8. Consolidated integration blueprint

Assume a local decide gateway at `http://127.0.0.1:8095/v1/systemone` (or LAN `http://192.168.1.20:8095/v1/systemone`), wire-compatible with TypeSafe (accepts `{model, state, questions}`, returns `answers`). Optional HTTP wrapper endpoint `/hooks/decide` that maps hook-event JSON → Jev questions → hook-decision JSON.

### Shared gate script (POSIX, works for Claude Code & Kimi Code)

```bash
#!/usr/bin/env bash
# jev-gate.sh — PreToolUse gate; reads hook JSON on stdin
set -uo pipefail
[ "${JEV_GATE:-on}" = "off" ] && exit 0
GW="${JEV_GATEWAY:-http://127.0.0.1:8095}"
INPUT=$(cat)
STATE=$(printf '%s' "$INPUT" | jq -c '{tool: .tool_name, input: .tool_input}' | head -c 12000)
RESP=$(curl -fsS -m 5 -X POST "$GW/v1/systemone" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer ${TYPESAFE_API_KEY:-local}" \
  -d "$(jq -nc --arg s "$STATE" '{model:"jev-latest", state:$s, questions:{safe:{type:"noul",instructions:"Is this tool call safe to auto-approve in a coding agent session? Destructive, secret-reading, or network-exfiltrating actions are unsafe."}}}')" \
) || exit 0   # fail-open on gateway down; use exit 2 to fail-closed
P=$(printf '%s' "$RESP" | jq -r '.answers.safe.noul // 1')
awk "BEGIN{exit !($P < ${JEV_GATE_THRESHOLD:-0.8})}" && {
  echo "Blocked by Jev gate (P(safe)=$P < threshold). Use a safer approach or ask the user." >&2
  exit 2
}
exit 0
```

### 8.1 Claude Code blueprint

Files to write:
- `.claude/hooks/jev-gate.sh` (above; `chmod +x`)
- `.claude/settings.json`:

```json
{
  "claudeMdExcludes": ["**/vendor/**/CLAUDE.md"],
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash|Edit|Write",
        "hooks": [{ "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/jev-gate.sh", "timeout": 10 }] }
    ],
    "UserPromptSubmit": [
      { "matcher": "",
        "hooks": [{ "type": "http", "url": "http://127.0.0.1:8095/hooks/skill-router" }] }
    ]
  }
}
```

- `.mcp.json`: `{"mcpServers": {"jev": {"command": "uvx", "args": ["jev-netlify-mcp"], "env": {"TYPESAFE_BASE_URL": "http://127.0.0.1:8095", "TYPESAFE_API_KEY": "local"}}}}`
- Env: `export ANTHROPIC_BASE_URL=http://192.168.1.20:4000` (LLM proxy), `MAX_THINKING_TOKENS=0`, `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=75`, `ANTHROPIC_DEFAULT_HAIKU_MODEL=...` for tier pinning.
- Or one-command: `claude plugin marketplace add weiping/jev-claude-code && claude plugin install jev@jev-engineering` (shadow default; flip to enforce after reviewing shadow logs).

### 8.2 opencode blueprint

- `opencode.json`: provider block for LAN LLM (§2.1), plus `mcp` block for a Jev MCP server, plus per-agent model tiers:

```json
{ "$schema": "https://opencode.ai/config.json",
  "provider": { "lan": { "npm": "@ai-sdk/openai-compatible", "options": { "baseURL": "http://192.168.1.20:8095/v1", "apiKey": "{env:LAN_KEY}" }, "models": { "coder": { "name": "LAN Coder" } } } },
  "model": "lan/coder",
  "mcp": { "jev": { "type": "local", "command": ["uvx", "jev-netlify-mcp"], "environment": { "TYPESAFE_BASE_URL": "http://127.0.0.1:8095", "TYPESAFE_API_KEY": "local" } } }
}
```

- `.opencode/plugins/jev-gate.ts`:

```ts
import type { Plugin } from "@opencode-ai/plugin"
const GW = process.env.JEV_GATEWAY ?? "http://127.0.0.1:8095"
export const JevGate: Plugin = async ({ client }) => ({
  "tool.execute.before": async (input, output) => {
    if (process.env.JEV_GATE === "off") return
    const state = JSON.stringify({ tool: input.tool, args: output.args }).slice(0, 12000)
    const r = await fetch(`${GW}/v1/systemone`, {
      method: "POST", headers: { "Content-Type": "application/json", "Authorization": `Bearer ${process.env.TYPESAFE_API_KEY ?? "local"}` },
      body: JSON.stringify({ model: "jev-latest", state, questions: { safe: { type: "noul", instructions: "Safe to auto-approve this coding-agent tool call?" } } }),
      signal: AbortSignal.timeout(4000),
    }).catch(() => null)
    if (!r) return // fail-open
    const j = await r.json()
    if ((j.answers?.safe?.noul ?? 1) < 0.8) throw new Error("Blocked by Jev gate (P(safe) below threshold)")
  },
})
```

(Caveat: does not intercept MCP-tool or subagent calls — upstream bugs #2319/#5894.)

### 8.3 pi blueprint

- `~/.pi/agent/models.json`: LAN provider (§3.1).
- Jev layer: `pi install npm:@riposta/pi-jev` (permission gate, router, prune/shield/watchdog, `/jev` command family, shadow→live per module). Point it at the LAN gateway per its config (`TYPESAFE_BASE_URL=http://127.0.0.1:8095`, `TYPESAFE_API_KEY=local` — its docs should confirm exact env names; UNVERIFIED detail).
- Alternatives/companions: `pi install npm:@narumitw/pi-typesafe-compact` (Jev-guided compaction), `npm:context-mode` (output sandboxing).
- Custom extension fallback: drop a `.ts` into `~/.pi/agent/extensions/` registering a tool-call hook that POSTs to the gateway (extension API per pi.dev docs; exact hook names UNVERIFIED here).

### 8.4 Kimi Code blueprint

- `~/.kimi-code/config.toml`:

```toml
default_model = "lan-coder"

[providers.lan]
base_url = "http://192.168.1.20:8095/v1"
api_key = "local"

[[hooks]]
event = "PreToolUse"
matcher = "Bash|WriteFile|StrReplaceFile"
command = ".kimi/hooks/jev-gate.sh"
timeout = 10
```

(Provider TOML key names follow the pattern written by `npx vercel ai-gateway setup --agent kimi`; verify exact field names against your kimi version's docs.)
- `~/.kimi-code/mcp.json`: `{"mcpServers": {"jev": {"command": "uvx", "args": ["jev-netlify-mcp"], "env": {"TYPESAFE_BASE_URL": "http://127.0.0.1:8095", "TYPESAFE_API_KEY": "local"}}}}`

---

## 9. Gaps / unresolved

- **jev-semaphore**, **jev-use**, **pi-autoresearch**: no trace found — likely renamed, very new, or misremembered names. Closest matches: weiping/jev-claude-code, gatekeeper, @riposta/pi-jev.
- **jev-pi / jev-pi-orchestrator** with `/jev:init`, `/jev:stats`: feature set matches **@riposta/pi-jev** (which uses `/jev` command tree); confirm whether the colon-names are an older/newer release of the same package.
- **jev-architect (BenjaminPolge)**: third-party tracker claims it uses heuristics and "does not call Jev" — verify before recommending.
- Exact env-var names each plugin uses for gateway base URL (`TYPESAFE_BASE_URL` is the SDK convention) — confirm per-repo.
- opencode plugin hook gaps for MCP/subagent interception are open upstream bugs; a Jev gate there is partial by design.
- Kimi Code provider TOML schema details vary across sources ($KIMI_SHARE_DIR vs ~/.kimi-code, ~/.kimi-code vs ~/.kimi-code legacy paths); the hooks `[[hooks]]` schema is the one firmly documented piece.
