# Per-project sessions & per-alias colors

> One long-lived Claude session per project, shared across every account/provider alias, plus a deterministic, **auto-applied** color per alias (since v1.10.0). Implemented by `scripts/claude-session.sh`, driven by the `cma_run` / `cma_run_provider` alias wrappers in `scripts/lib.sh`.

> **Verification vintage (read before quoting a transcript below).** The script-side behaviour in this document was re-checked against the tree on **2026-07-28** (`claude_toolkit` v1.26.7). The `claude`-side captures — session renaming on resume, `agent-color` persistence across `--resume`, and the "no CLI flag / settings key / env var for the color" finding — were taken live against **`claude 2.1.195`** and have **not** been re-run since; this host now runs **2.1.220**. Treat those blocks as dated evidence, not as a current guarantee.

## Overview

When you launch any toolkit alias with **no arguments** inside a project, the wrapper does two things for you:

1. **Auto-session** — it resumes (or, the first time, creates) *one* long-lived Claude session tied to the project's root directory, named after that directory. Every alias — `claude1`/`claude2`/`claude3` and every provider alias (`deepseek`, `kimi-for-coding`, …) — maps to the **same** session for a given project, so switching aliases continues the same ongoing work.
2. **Auto-color** — it auto-applies a deterministic, per-alias prompt color to that session (by writing the same `agent-color` record `/color` writes), so you can visually tell aliases apart in the TUI without typing anything.

Both behaviors are **opt-out by intent** on a bare launch. **Auto-color** fires *only* on a bare launch, in both wrappers. **Auto-session** is no longer bare-only for provider aliases: since v1.17.0 `cma_run_provider` also injects `--resume <existing-id>` for a conversation argument, so `deepseek -p "…"` continues the project session instead of starting a fresh one every time. Explicit session selectors and non-conversation subcommands are still passed through verbatim. See [Respecting explicit args](#respecting-explicit-args).

---

## Per-project auto-session naming

### How it works

On a bare launch the wrapper calls `claude-session flags`, which:

1. Resolves the **project root** — the git working-tree root if you are inside a repo (`git rev-parse --show-toplevel`), otherwise the current directory (`$PWD`). Because the whole repo shares one root, every subdirectory of a repo maps to the same session.
2. Picks the **session UUID** via `cma_latest_session_id`, which is a two-step rule, not a single derivation:
   - if the project already has session files, take the **most recently active** one — `ls -t "$config_dir/projects/<slug>"/*.jsonl`, subagent dirs excluded, newest first;
   - otherwise fall back to a **deterministic UUID derived from the root path** (md5 of `cma-session:<root>`, formatted as a UUID).

   So the deterministic id is the *first-launch* id, and after that the wrapper follows whichever session in that project was touched last. That is deliberate: a session created by plain `claude`, or by an older wrapper, is picked up and continued rather than orphaned.
3. Derives a **session name** = the root directory's basename in lowercase `kebab-case`, sanitized: leading/trailing whitespace is trimmed, internal whitespace and underscores are collapsed to `-`, and any remaining characters that are not `[a-z0-9-]` are stripped.
4. Emits the launch flags:
   - **First time** (no session file on disk yet): `--session-id <uuid> --name <kebab>` — creates the session with that id and name.
   - **Afterwards** (session file exists): `--resume <uuid> --name <kebab>` — resumes that session and re-applies the name.

It also marks the project as trusted in the launching account's `.claude.json` (suppresses the "workspace has not been trusted" prompt). This is best-effort and never blocks the launch.

### The kebab-case naming rule

The root directory's basename is lowercased, leading/trailing whitespace is trimmed, whitespace and underscores are collapsed to a single `-`, and any remaining characters that are not `[a-z0-9-]` are stripped. Consecutive `-` are collapsed and leading/trailing `-` are trimmed:

| Project directory | Session name |
|---|---|
| `claude_toolkit` | `claude-toolkit` |
| `Android 15` | `android-15` |
| `My-Cool Project` | `my-cool-project` |
| `  My!!!   Project  ` | `my-project` |

> Verified by running `bash scripts/claude-session.sh name <path>`:
> ```
> $ bash scripts/claude-session.sh name "$PWD"          # claude_toolkit repo
> claude-toolkit
> $ bash scripts/claude-session.sh name "/tmp/cma-demo/Android 15"
> android-15
> $ bash scripts/claude-session.sh name "/tmp/cma-demo/My-Cool Project"
> my-cool-project
> $ bash scripts/claude-session.sh name "/tmp/cma-demo/  My!!!   Project  "
> my-project
> ```

### Shared session across aliases — two mechanisms, not one

The first-launch id is derived purely from the root **path**, so it is identical no matter which alias launches it:

```
$ bash scripts/claude-session.sh id "$PWD"     # claude_toolkit repo
c126464c-94cc-d45a-0019-303e01a11155
```

> That value is **path-dependent**, not a constant — it is `md5("cma-session:$PWD")` re-formatted as a UUID, so a checkout at a different path yields a different id. (An earlier revision of this doc recorded `9fdcf748-…`, captured when this repo lived elsewhere.) Verify your own with the command above.

Beyond the first launch, sharing is carried by the **shared store** rather than by the id derivation: `projects/` is in `CMA_SHARED_ITEMS`, so every account dir and every provider config dir symlinks the *same* `projects/<slug>/*.jsonl` tree. `cma_latest_session_id` therefore sees the same set of session files from every alias and resolves all of them to the same most-recently-active session.

Launch `claude1` in this repo today and `deepseek` tomorrow — both land on the same conversation.

### Create vs. resume, and naming on both

The name is passed on **both** create and resume. On a fresh id it names the new session; on a resume it re-applies the name. This is deliberate: it means a session that was created *without* a name — by an older version of the wrapper, or by a plain `claude` invocation — finally gets named on its next bare launch.

> This was verified live against `claude 2.1.195`: `claude --resume <id> --name <x>` renames a previously **unnamed** session (its custom title goes from `<NONE>` to `<x>`). So legacy unnamed sessions are not stuck — they pick up the project name automatically the next time you launch an alias into them.

---

## Per-alias color (auto-applied)

Each alias deterministically maps to one of Claude Code's 8 prompt colors, and since v1.10.0 the toolkit **applies that color for you** on a bare launch. The palette (order is load-bearing, taken from the native binary) is:

```
red  blue  green  yellow  purple  orange  pink  cyan
```

The mapping (`cma_label_color`) takes the **first 6 hex digits** of `md5(alias-label)`, reads them as a number, and takes it modulo the palette size: `num=$(( 0x${hash:0:6} % ${#CMA_COLORS[@]} ))`. So a given alias always maps to the same color, and distinct aliases spread across the palette. (`md5sum` is preferred, `md5 -q` on BSD/macOS, and `cksum` as a last resort — the last of which yields a *different* mapping, so a host without either md5 tool will not agree with the table below.)

> Verified 2026-07-28 by running `bash scripts/claude-session.sh color <label>`:

| Alias label | Color |
|---|---|
| `claude1` | purple |
| `claude2` | red |
| `claude3` | orange |
| `deepseek` | red |
| `kimi-for-coding` | purple |
| `xiaomi` | pink |
| `helixagent` | green |
| `nvidia` | cyan |
| `chutes1` | blue |

(The label for a native alias is the config-dir basename with the `.claude-` prefix stripped; for a provider alias it is `$CMA_PROVIDER_ID`. Note that a collision is expected, not a bug — 8 colors over an unbounded alias set: `claude2` and `deepseek` are both red, `claude1` and `kimi-for-coding` both purple.)

### How it's auto-applied

On a bare launch the wrapper calls `claude-session apply-color`, which writes one `agent-color` record into the project session's `.jsonl`:

```json
{"type":"agent-color","agentColor":"purple","sessionId":"9fdcf748-0fab-00b3-bdb5-e2d6d3a944e9"}
```

This is **exactly** the record Claude Code's in-TUI `/color` command writes — the toolkit just writes it from outside the TUI. It is the **only** non-interactive mechanism for setting the prompt color (see [Why injection is the only mechanism](#why-injection-is-the-only-mechanism)).

The wrapper calls `apply-color` twice so the right thing happens in both states:

- **Before launch** — a resumable session's `.jsonl` already exists, so the color is set immediately for this run.
- **After exit** — a brand-new session's `.jsonl` only appears *during* the first launch, so the post-exit call colors it so the color is already in place on the next resume.

It is **idempotent**: the record is appended only when the session's current color differs from the alias's color. So re-launching the same alias adds nothing, and switching aliases on the same project (e.g. `claude1` → `claude2`) re-colors the **same** session by appending one new record — the file never grows unbounded.

> Verified live against `claude 2.1.195` (write + idempotency + re-color of the same session):
> ```
> $ bash scripts/claude-session.sh apply-color "$CFG" claude1   # writes purple
> $ bash scripts/claude-session.sh apply-color "$CFG" claude1   # no-op (same color)
> $ bash scripts/claude-session.sh apply-color "$CFG" claude2   # appends red to the SAME session
> $ grep '"type":"agent-color"' "$CFG/projects/.../<id>.jsonl"
> {"type":"agent-color","agentColor":"purple","sessionId":"9fdcf748-0fab-00b3-bdb5-e2d6d3a944e9"}
> {"type":"agent-color","agentColor":"red","sessionId":"9fdcf748-0fab-00b3-bdb5-e2d6d3a944e9"}
> ```
> The injected record also **persists across `claude --resume`** — re-opening the session keeps the color.

On launch the wrapper also prints a one-line confirmation:

```
$ bash scripts/claude-session.sh hint claude1     # inside the claude_toolkit repo
claude-session: project "claude_toolkit" — alias color: purple (auto-applied).
```

### Honest caveat — confirm it visually once

The toolkit writes the record and the record persists, using the same mechanism `/color` uses, but it **cannot programmatically observe the TUI**. So on the very first launch, glance at the prompt bar to confirm the color rendered as expected. (The in-TUI `/color <color>` still works for the current session, but note the next bare launch of that *same* alias re-applies the alias's deterministic color, since `apply-color` re-colors whenever the session's current color differs from the alias's.)

### Why injection is the only mechanism

There is no supported way to set the prompt color from the command line:

- Claude Code's `/color` is a **TUI-only** command, and `claude -p '/color purple'` is a **no-op** (the slash command is not interpreted in print mode).
- Verified against `claude 2.1.195` (and the official docs): there is **no** CLI flag, **no** `settings.json` key, and **no** environment variable that sets the prompt color.
- The color lives only *inside the session's `.jsonl`* as the `agent-color` record above. Writing that record — what `apply-color` does — is therefore the single non-interactive way to set it.

---

## Respecting explicit args

The two behaviors no longer have the same trigger. Be precise about which is which.

### Auto-color — bare launch only, both wrappers

`apply-color` runs only inside the `$# -eq 0` branch of `cma_run` and `cma_run_provider`, and the post-exit re-colour is guarded on a flag (`_cma_pcolor`) that only that branch sets. Pass any argument and no color is written.

### Auto-session — bare launch for native aliases, bare *or* conversation args for provider aliases

- **`cma_run` (`claude1`, `claude2`, …)** is still bare-only: with any argument it injects no `--session-id` / `--resume` / `--name`.
- **`cma_run_provider` (`deepseek`, `helixagent`, `chutes1`, …)** additionally injects `--resume <existing-id>` when you pass conversation args. This landed in v1.17.0 because `alias -p "…"` previously started a brand-new session on every single invocation.

Three rules bound that injection, and all three matter:

1. It is skipped when the **first argument is an explicit session selector** — `--resume`, `--session-id`, `--continue`, `--fork-session`, `-c`. Your selector always wins.
2. It is skipped for **non-conversation subcommands** — `agents`, `mcp`, `export`, `doctor`, `install`, `update`, `config`, `plugin`, `setup`, `acp`, `server`, `web`, `provider`.
3. It uses `claude-session existing-id`, **never** `latest-id`. `latest-id` falls back to the deterministic-but-never-created UUID for a project that has no sessions yet, and injecting `--resume` with such an id fails hard: `No conversation found with session ID: …`. `existing-id` prints nothing unless a real session file exists, so nothing is injected.

```bash
claude1                              # auto: resume/create the project session, auto-apply purple
claude1 -p "summarize this file"     # native + args: passed verbatim, no auto-session, no auto-color
claude1 --resume <some-other-uuid>   # explicit: your resume wins
deepseek                             # auto: same project session as claude1, auto-apply deepseek's color
deepseek -p "summarize this file"    # provider + conversation args: --resume <existing-id> IS injected,
                                     #   but no color is applied
deepseek --resume <some-other-uuid>  # explicit selector: nothing injected
deepseek mcp list                    # non-conversation subcommand: nothing injected
```

### The `CMA_PROVIDER_TRIM=bare` exception

A provider whose `.env` carries `CMA_PROVIDER_TRIM=bare` skips **both** session seams — the bare-launch `flags` and the conversation-args `--resume` — and gets a fresh session each launch, plus a `--bare` launch that drops the hook/plugin/MCP/CLAUDE.md surface. This is an opt-in knob for small-context local backends: resumed history riding along overflowed a 229,376-token local-model window (live issue 2026-07-22). Auto-color is unaffected.

The flags `claude-session` emits contain no shell metacharacters (just a UUID and a kebab-case name), so the wrapper splits them safely in both bash and zsh.

---

## FAQ

**Why did my old session suddenly get a name?**
Because the name is re-applied on resume. The first time you bare-launch any alias into a project whose session predates this feature (or was created by plain `claude`), the wrapper runs `--resume <id> --name <project_kebab>`, which renames the previously-unnamed session. Verified live on `claude 2.1.195`.

**Is the color automatic?**
Yes, since v1.10.0. On a bare launch the wrapper writes the alias's deterministic color into the session as an `agent-color` record — the same record `/color` writes — via `claude-session apply-color`. Claude Code exposes no CLI flag, settings key, or env var for the color (verified against `claude 2.1.195` and the official docs), and `claude -p '/color x'` is a no-op, so injecting that record is the only non-interactive mechanism. It is idempotent and persists across `--resume`. The toolkit can't see the TUI, so confirm the prompt-bar rendering visually on first launch.

**Can I change the session name?**
The auto-name is just the project directory's basename in kebab-case, so the simplest way is to rename (or work from) a differently-named directory. Within a running session you can also use Claude Code's own `/rename` to set a custom title; note that a later bare launch will re-apply the directory-derived name on resume.

**Do all my aliases really share one session per project?**
Yes, but by two mechanisms rather than one. The *first-launch* id is derived from the project root path, not from the alias, so every alias creates the same id. Afterwards, `projects/` is a shared item (`CMA_SHARED_ITEMS`) symlinked into every account and provider config dir, so every alias reads the same set of `.jsonl` session files and `cma_latest_session_id` resolves them all to the same most-recently-active session. The exception is a provider running with `CMA_PROVIDER_TRIM=bare`, which deliberately starts fresh each launch.

**Why did my alias resume an id that isn't the one `claude-session id` prints?**
Because `flags` uses `cma_latest_session_id`, not `id`. The deterministic path-derived UUID is only the fallback used when the project has no session files yet; once any session exists — including one created by plain `claude` — the wrapper follows the most recently active one. `claude-session latest-id` prints what will actually be resumed.

---

## Reference

- Implementation: `scripts/claude-session.sh` (`cma_project_root`, `cma_session_name`, `cma_session_id`, `cma_latest_session_id`, `cma_existing_session_id`, `cma_label_color`, `cma_trust_project`).
- Alias wrappers that call it: `cma_run` and `cma_run_provider` in `scripts/lib.sh`.
- Palette definition: `CMA_COLORS=(red blue green yellow purple orange pink cyan)` — `scripts/claude-session.sh:29`. Order is load-bearing (taken from the native binary).
- Subcommands you can run yourself:
  - `claude-session name [path]` — print the kebab-case session name.
  - `claude-session id [path]` — print the **deterministic** path-derived session UUID (the first-launch id / fallback).
  - `claude-session latest-id [config_dir]` — print the id that will actually be resumed: the most recently active session for this project, falling back to `id`.
  - `claude-session existing-id [config_dir]` — same as `latest-id` but prints **nothing** when the project has no session file yet. This is what the provider wrapper uses before injecting `--resume`, precisely so it never injects a never-created id.
  - `claude-session color <label>` — print the mapped color for an alias label.
  - `claude-session apply-color <config_dir> <label>` — write the alias's `agent-color` record into the project session's `.jsonl` (idempotent; used by the wrappers to auto-apply the color).
  - `claude-session hint <label> [path]` — print the human color/session confirmation (on stderr).
  - `claude-session flags <config_dir>` — print the launch flags (used by the wrappers).

  > The script's own `usage:` line lists `{flags|name|id|color|apply-color|hint|latest-id}` and omits `existing-id`, which the dispatcher does implement. Both work.
