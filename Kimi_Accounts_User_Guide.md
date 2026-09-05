# Kimi Accounts — User Guide

The claude_toolkit treats the **Kimi Code CLI** as a full sibling of Claude Code.
You get multiple isolated Kimi accounts (`kimi1`, `kimi2`, …) that share memory,
plugins, and sessions the same way your Claude accounts do, plus a `kimi-<id>`
alias for **every** provider backend you already run through Claude Code — so
the same `deepseek` key that opens Claude Code also opens Kimi Code.

This guide covers the Kimi-specific commands, the account lifecycle, the
`kimi-<id>` provider aliases, and the one-time rename of the legacy `kimi-*`
backend aliases.

## 1. Quick start

```bash
install.sh                       # now also symlinks every kimi-*.sh command

kimi-list-accounts               # see what's wired up
kimi-add-account                 # interactive; prompts for an alias + dir
kimi-add-account kimi1 --login   # create kimi1 AND drive the interactive login
kimi1                            # launch Kimi Code's account 1
```

Adding an account provisions `~/.kimi-code-<alias>`, links the shared items
into `$SHARED_DIR/kimi/`, and wires an `alias kimiN="KIMI_CODE_HOME=~/.kimi-code-<alias> cma_run_kimi"`.
After the dir is created you authenticate with Kimi Code's **interactive device
flow** — `kimi login` prints a URL and code and waits for your approval. There
is no headless login; run it once per account:

```bash
kimi1 login                        # or, if already inside the account:
cma_run_kimi login
```

## 2. Commands

| Command | Purpose |
| ------- | ------- |
| `kimi-add-account [NAME] [--login]` | Add a Kimi account (`~/.kimi-code-<name>`), wire shared items, write the `kimiN` alias. `--login` also drives the interactive login. |
| `kimi-remove-account --alias NAME` | Drop an account; archive (default) or `--delete` its dir. |
| `kimi-list-accounts` | Tabular status of detected Kimi accounts (alias, home, links). |
| `kimi-unify [--dry-run]` | Merge `KIMI_SHARED_ITEMS` across detected Kimi accounts into `$SHARED_DIR/kimi/` and symlink back. |
| `kimi-rollback` | Restore `.preunify.*` backups for the Kimi family. |
| `kimi-providers` | Dispatch wrapper over `claude-providers` with Kimi framing — see §5. |

`install.sh` auto-links every `kimi-*.sh`, mirroring the `claude-*.sh` family.

## 3. What is shared vs private per Kimi account

Kimi Code keeps its whole data root behind `KIMI_CODE_HOME`. The toolkit
unifies only the items that are safe (and useful) to share, symlinking them
into `$SHARED_DIR/kimi/`:

| Shared item (`$SHARED_DIR/kimi/`) | Merge strategy |
| --------------------------------- | -------------- |
| `AGENTS.md` | promoted from the newest/most-active account, symlinked from every home (the `CLAUDE.md` analog) |
| `plugins/` | directory union (two-pass rsync) |
| `skills/` | directory union |
| `sessions/` | directory union — workdir-keyed and home-independent, so cross-account resume works |
| `session_index.jsonl` | concat + line-dedupe (the `history.jsonl` analog) |

**Private — never symlinked, never merged:** `config.toml` (holds
`[providers.*]` + OAuth references), `credentials/`, `oauth/`, `device_id`,
`bin/`, `logs/`, `tui.toml`. These stay per-account, exactly like Claude's
`.credentials.json`.

Because Kimi has no `.claude.json`-style session index and no runtime state
merger, cross-account session continuity comes from the shared, workdir-keyed
`sessions/` + `session_index.jsonl` symlinks — not from a per-launch sync.

## 4. The `kimi-<id>` provider aliases

For **every** provider id that verifies across the same pipeline as the
Claude-side alias, `sync` also emits a Kimi twin:

```bash
alias deepseek="cma_run_provider deepseek"          # Claude Code on deepseek
alias kimi-deepseek="cma_run_kimi_provider deepseek" # Kimi Code on the SAME deepseek
```

- The no-prefix alias is unchanged and always opens **Claude Code**.
- `kimi-<id>` opens **Kimi Code** against the *same* backend, using the same
  key (from the same `<id>.env` provider record) and the same derived
  context limit.
- `cma_run_kimi_provider <id>` launches under
  `KIMI_CODE_HOME="$HOME/.kimi-prov-<id>"`, with the per-provider
  `config.toml` and `default_model` rendering the exact
  `"<host>/<strong-model>"` to run. No `cma-proxy` on this path — the Kimi CLI
  speaks the OpenAI/Anthropic wire protocol natively.
- Verification is **shared**: the `status.json` verdict is the single gate for
  both the Claude and the Kimi twin. A `kimi-<id>` alias is refused at launch
  unless its id is `verified` (override with `--force`).
- CA-cert providers: when `CMA_PROVIDER_CA_CERT` is set, readable, and the
  base URL is `https://`, the wrapper exports `NODE_EXTRA_CA_CERTS` and
  `SSL_CERT_FILE` before launch, gated exactly like the Claude side.

### Flags

| Flag | Effect |
| ---- | ------ |
| `claude-providers sync --no-kimi-aliases` | do **not** emit any `kimi-<id>` twin this run (default is to emit them) |
| `claude-providers list` / `kimi-providers list` | now shows an **agent** column (claude/kimi) and marks `kimi-<x>` twins |

## 5. `kimi-providers` — a dispatch wrapper over the same engine

`kimi-providers` is a thin wrapper exposing the provider engine with Kimi
framing. Its subcommands mirror `claude-providers`:

```bash
kimi-providers sync          # same sync, also emits kimi-<id> twins (+ migration)
kimi-providers list          # both alias kinds, agent column
kimi-providers list-all
kimi-providers list-faulty
kimi-providers show <id>
kimi-providers verify <id>   # same 1-3 layer gates as the Claude alias
kimi-providers migrate-names # run the one-time legacy rename explicitly
```

## 6. The one-time legacy rename: `kimi-*` → `kc-*`

The `kimi-` prefix is reserved so it means *only* "Kimi Code CLI agent".
The legacy aliases that opened **Claude Code** against a Kimi-native backend
are renamed **once**, automatically at `sync` (or via `kimi-providers
migrate-names`). This is a **breaking change** — if you use these aliases,
update your muscle memory and any scripts:

| Old alias | New alias | What it runs |
| --------- | --------- | ------------ |
| `kimi-for-coding` | `kc-for-coding` | Claude Code on the Kimi coding backend |
| `kimi-for-coding2` | `kc-for-coding2` | Claude Code (mirror API-key record) |
| `kimi-for-coding-highspeed` | `kc-for-coding-highspeed` | Claude Code |
| `kimi-k3` | `kc-k3` | Claude Code |
| `kimi-k2p7` | `kc-k2p7` | Claude Code |

`kc-*` ids are Claude Code on a **Kimi-native backend**; they never get a
`kimi-kc-*` twin (the Kimi agent on that backend is the `kimiN` account).
The rename is idempotent — running it twice is a no-op — and reversible via
the standard `backup_and_remove` backups, just like the Claude account
renames.

The name contract, in one line:

```
claudeN → Claude account · kimiN → Kimi account
<id>    → Claude Code on backend <id>   (no prefix — always Claude)
kimi-<id> → Kimi Code on backend <id>    (kimi- prefix — always Kimi CLI)
kc-<id>   → Claude Code on a Kimi-native backend (legacy renamed)
```

## 7. Non-goals / limitations

- **No headless login.** Kimi's device flow is interactive by design; `--login`
  drives it and pauses for your approval.
- **No `kimi-sync-state`.** Kimi has no `.claude.json` analog; continuity comes
  from the shared `sessions/` + `session_index.jsonl`.
- **One strong model per `kimi-<id>` alias** — no fast-model pairing on the
  Kimi side (non-goal).
- No changes to the Claude family, `cma-proxy`, or the no-prefix aliases.
