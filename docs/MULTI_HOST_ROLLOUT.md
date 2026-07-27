# Multi-host rollout

Two parts: the **current runbook** for provisioning a fresh host (§A, kept in
step with the scripts), and the **historical record** of the original four-host
v1.7.6 rollout (§B, frozen — do not read it as instructions).

---

# A. Current runbook — v1.26.7 (2026-07-28)

Every command below was checked against the script that implements it: the
entry point exists, and each flag shown appears in that script's own argument
parser.

## A.1 What a fresh host needs before you start

| Requirement | Hard? | Checked by |
|---|---|---|
| `rsync`, `jq`, `awk` | **hard** — `install.sh` aborts without them | `install.sh` step 1 (`cma_require`) |
| `bash` 4+ | **hard** on macOS (`brew install bash`) — several scripts re-exec under `/opt/homebrew/bin/bash` or `/usr/local/bin/bash` | `install.sh`, `claude-bootstrap.sh`, `claude-opencode-sync.sh` |
| A Go toolchain matching `submodules/claude-code-router/go.mod` | **hard for router-transport aliases** — a build failure is recorded and re-raised as a real install failure | `install.sh` step 2b → `claude-ccr-build.sh` |
| `node` + `npm` | soft — only the optional TOON utility; a warning, not a failure | `install.sh` step 1b |
| `pandoc` + a PDF engine | soft — doc export is skipped without them | `install.sh` steps 1 and 6 |
| `python3` | needed by `claude-opencode-sync` and the provider resolver | `cma_require python3` |
| Claude Code itself (`npm i -g @anthropic-ai/claude-code`) | needed to *launch*; not needed to install the toolkit or detect providers | — |

## A.2 Install

One line, from nothing:

```bash
curl -fsSL https://raw.githubusercontent.com/vasic-digital/claude-toolkit/main/scripts/curl-install.sh | bash
```

`curl-install.sh` detects the platform, installs missing hard deps via the
system package manager where it can, clones into `${CLAUDE_TOOLKIT_DIR:-$HOME/claude-toolkit}`
with `git clone --recursive` (re-runs do `git pull --ff-only --recurse-submodules`
followed by `git submodule update --init --recursive`), then runs
`scripts/install.sh`. It is idempotent.

From an existing checkout:

```bash
git submodule update --init --recursive     # submodules are NOT optional
bash scripts/install.sh                     # idempotent
```

`install.sh` runs, in order: dependency check → optional `npm install` for TOON
→ symlink **every** `scripts/claude-*.sh` into `~/.local/bin` → build the
bundled Go `ccr` → PATH wiring in the rc files → alias file + inline-alias
migration → build `cma-proxy` → install the provider session hook and run one
soft `claude-providers sync` → `claude-unify.sh` → optional doc export →
**`claude-install-verify.sh`**.

Because step 2 links every `claude-*.sh`, all of these land on `PATH`:
`claude-unify`, `claude-add-account`, `claude-remove-account`,
`claude-list-accounts`, `claude-rollback`, `claude-export-docs`,
`claude-opencode-sync`, `claude-providers`, `claude-sync-state`,
`claude-bootstrap`, `claude-session`, `claude-ccr-build`, `claude-proxy-build`,
`claude-go-build`, `claude-install-verify`, `claude-release-gate`,
`claude-verify-providers`, `claude-semantic-visibility`, `claude-gc`.

**The banner is earned, not printed.** `install.sh` exits non-zero and prints
`[FAILED]` with the actionable fix if the bundled router did not build or if
`claude-install-verify` fails. A missing `cma-proxy` is reported separately as
`DEGRADED` (those aliases still launch, without their compatibility shims). To
re-check later without a full re-install:

```bash
claude-install-verify
```

## A.3 Accounts

On a host with existing `~/.claude-*` account dirs, `install.sh` already ran
`claude-unify`. On a genuinely clean machine there is nothing to merge —
use the bootstrap instead:

```bash
claude-bootstrap --count 2 --yes                 # creates claude1, claude2
claude-bootstrap --aliases personal,work --yes   # custom alias names
```

Then authenticate each once: `claude1 /login`, `claude2 /login`, …

## A.4 Provider aliases

```bash
claude-providers sync            # discover keys, resolve, verify, write aliases
claude-providers list            # only VERIFIED (launchable) aliases
claude-providers list-all        # every alias, any status
claude-providers list-faulty     # failed / unverified / pending only
claude-providers show <id>
claude-providers verify <id> --deep     # adds the live superpowers-TUI layer 4
```

Keys are read from `$CMA_KEYS_FILE`, default `~/api_keys.sh`
(`--keys-file PATH` overrides). Default `sync` runs the single-alias phase and
then the per-model phase, **free-tier only** — paid models are never probed
unless you pass `--include-paid` (it spends real money). `sync --multi` runs
*only* the per-model phase. Other flags the parser accepts: `--no-verify`,
`--offline`, `--dry-run`, `--refresh-aliases`, `--quiet`, `--max-aliases N`,
`--min-score N`, `--verify-concurrency N`, `-y|--yes`.

The launch wrapper **refuses** any alias that is not `verified`. That is the
gate working, not a bug — check `claude-providers list-faulty` and the reason
recorded in `~/.local/share/claude-multi-account/providers/status.json`.

## A.5 OpenCode — **you must APPLY the sync, not just preview it**

`install.sh` does **not** run the OpenCode sync (there is no `opencode`
reference anywhere in it). It is a separate, deliberate step, and on a fresh
host it is the difference between OpenCode seeing the whole Claude plugin
Skills/MCP surface and seeing none of it.

```bash
claude-opencode-sync --dry-run --stats   # preview: prints config to stdout, WRITES NOTHING
claude-opencode-sync                     # APPLY: backs up, then writes opencode.json
```

`--dry-run` short-circuits before the write (`cat "$OC_TMP"; cma_log "dry-run:
no files written"; exit 0`). A host where the operator only ever previewed
therefore still has an untouched `opencode.json` — no `skills.paths` key — and
OpenCode resolves **none** of the plugin skills. Applied, this host's live
verification records `skill_paths=163`, `skills_resolved=1356`,
`mcp_connected=26`, `instructions=1`
(`scripts/tests/proof/00-summary.txt`).

Notes for a fresh host:

- The script requires `python3` and an existing plugin cache
  (`CLAUDE_PLUGINS_DIR`, default `~/.claude/plugins/cache/claude-plugins-official`);
  it `die`s if that directory is absent. It does **not** probe for the
  `opencode` binary, so it will happily write a config on a host where OpenCode
  is not installed yet.
- Other accepted flags: `--no-backup`, `--enable-all-local-runnable`,
  `--enable-all`, `-h|--help`. Nothing else — an unknown argument is a hard
  `die`.
- By default only a curated allowlist of MCP servers is enabled (public
  no-auth docs servers plus local servers whose runtime is present and which
  need no secret env). Everything else is written `enabled:false`, ready for
  `opencode mcp auth`. Override with `OPENCODE_ALLOWLIST` (one `plugin/server`
  per line).
- It is additive and idempotent — existing providers and MCP keys are never
  clobbered; re-running on unchanged input is a no-op.

## A.6 Router / proxy builds

```bash
claude-ccr-build       # build the bundled Go claude-code-router, install as `ccr`
claude-proxy-build     # build the Go compatibility proxy (cma-proxy)
```

Both are already run by `install.sh`; run them by hand after a
`git submodule update` that moves either pointer. Both prefer a **vendored**
Go at `$VENDORED_GO` (default `~/.local/share/claude-go/bin/go`) and fall back
to system `go` — the fallback is a `command -v` probe on the resolved path, and
without it the fallback does not exist at all (the variable is assigned a path
string unconditionally, so it is never empty).

`claude-go-build` builds Go itself from `submodules/go` (pinned at
**`go1.26.4`**) into `~/.local/share/claude-go`. It is **opt-in**: `install.sh`
only symlinks it, deliberately, because an alias installer must not download an
~80MB compiler. So `~/.local/share/claude-go` does **not** exist on a normal
install, and system Go is the normal path.

## A.7 HelixAgent hosts — `CMA_HELIX_AUTOSTART` is OFF by default

Only relevant on a host running a local HelixLLM backend.

The `helixagent` alias probes HelixLLM's `/health` before launching. If
HelixLLM is not answering, **it does not start it.** Starting HelixLLM claims
the single GPU and **evicts HelixCode's coder mode**, so a provider alias must
not do that to a host merely because someone launched it. The default warns and
prints both remedies:

```bash
helix_code/scripts/helixllm-mode.sh claude     # start it yourself (companion repo)
CMA_HELIX_AUTOSTART=1 helixagent               # opt in for this launch
```

Accepted truthy values are `1`, `true`, `yes`, `on` (case-insensitive);
anything else, including unset, is off. With auto-start enabled the wrapper
looks for `helixllm-mode.sh` in four known locations
(`$HOME/projects/helix_code/scripts/`, `$HOME/helix_code/scripts/`, a fixed
`/run/media/...` path, and `${HELIX_CODE_DIR}/scripts/`), starts it in claude
mode, and polls `/health` for up to 120s.

If HelixLLM *is* running but in **coder mode** (`context_limit=24576`) the
wrapper warns regardless of the knob — `helixagent` is pinned to a
229376-token context and the first request (~67K of system prompt + tool
schemas) would immediately overflow. Because coder mode is the common
operational state, `helixagent` is honestly demoted to `unverified` and refused
by the launch gate until the operator flips modes and re-runs
`claude-providers verify helixagent --deep`.

## A.8 Token budget — check it per host before blaming a provider

The wrapper derives both guards from the provider's context:

1. `out = min(context − CMA_INPUT_FLOOR(160000), 128000)`, floored at 8192
2. `window = context − out − CMA_TOOL_TOKEN_BUDGET(80000)`, capped at 200000
3. if that window is below `CMA_MIN_COMPACT_WINDOW(120000)`, buy it back out of
   the output cap: `out = context − 120000 − 80000`, `window = 120000`

**A large enabled-plugin surface can make a provider unusable no matter how the
guards are tuned.** Measured 2026-07-27 on this host: **227 enabled plugins →
158112 tokens of tool input.** Since `158112 + 120000 > 262144`, no output cap
lets a **262144-context** provider fit. The options are to shrink the enabled
plugin set, raise `CMA_TOOL_TOKEN_BUDGET` to match reality (which lowers the
output cap), or use a wider-context provider — nvidia (1000000) and xiaomi
(1048576) fit comfortably.

## A.9 Verify the host

```bash
claude-install-verify              # real probes of the real artifacts
bash scripts/tests/run-all.sh      # hermetic suite (58 test files)
bash scripts/tests/run-proof.sh    # + live legs, writes scripts/tests/proof/
claude-list-accounts
claude-providers list
```

Both suite entry points take an exclusive suite lock; a second concurrent run
waits up to `CMA_SUITE_LOCK_WAIT` (default 600s) and then exits **75**
(`EX_TEMPFAIL`) rather than hanging.

`run-proof.sh` is **honest, not all-green** by design: the live legs report real
provider failures rather than hiding them, and `PROOF.md` records their non-zero
exit codes.

## A.10 Rollout gotchas seen in the field

- **A stale `ccr` on `PATH` beats a correct rebuild.** An npm
  `@musistudio/claude-code-router` at `~/.local/bin/ccr` shadows the bundled Go
  router and no amount of rebuilding fixes it. `claude-install-verify` probes
  the *stable identity the runtime actually resolves* using `ccr restart` as the
  discriminator (`ccr start` matches both binaries and cannot discriminate).
- **Layers 1-3 of provider verification cannot see routing defects.** They curl
  the provider's own `base_url` directly and never touch the ccr route path.
  Only the layer-4 live launch — and `claude-release-gate.sh` — exercise the
  real chain. This is how a router bug once 503'd 16 of 24 verified aliases in
  1-4 ms while every earlier gate stayed green.
- **A dangling `export FOO=$Bar` in `~/api_keys.sh` is tolerated** (the file is
  sourced with `nounset` disabled), but defining or removing the line is
  cleaner.
- **`~/.claude` is not an account dir.** It is the user-scope plugin root
  (`DEFAULT_DIR`) and is excluded from account auto-detection; account dirs are
  `~/.claude-<name>`.

---

# B. Historical record — 2026-06-28 (v1.7.6)

> **Frozen snapshot.** Record of the original four-host setup, key
> distribution, live provider/model detection, and verification performed for
> the v1.7.6 release. **The counts below are v1.7.6-era and are not current** —
> the suite has grown from 9 test files to 58, and the provider fleet is now
> tracked by verification status rather than a flat "active" count. Use §A for
> anything operational.

## Hosts

| Host             | OS                  | Login shell | node/npm | claude            | Role        |
|------------------|---------------------|-------------|----------|-------------------|-------------|
| nezha (local)    | Linux (alt 6.12)    | bash        | ✓        | ✓ (npm-global)    | source host |
| mistborn.local   | macOS (Darwin 24.5) | zsh         | ✗        | ✗ (no node/brew)  | remote      |
| thinker.local    | Linux (6.17)        | bash        | ✗        | ✓ (/usr/local)    | remote      |
| amber.local      | Linux (6.8)         | bash        | ✓        | ✓ (installed now) | remote      |

All hosts: user `milosvasic`, reachable by SSH **key** (no password used or stored).

## What was done

1. **Fixed the toolkit** (see CHANGELOG v1.7.6): alias-file migration corruption,
   `set -u` keys-sourcing abort, always-non-interactive execution
   (`CMA_NONINTERACTIVE` + `cma_can_prompt`), and macOS/bash-3.2 portability of the
   test harness.
2. **Distributed `~/api_keys.sh`** to every host via a **no-loss merge** — each host
   ends up with at least the source host's keys while keeping any host-local keys:
   - mistborn: +1 from source, **2 host-local keys preserved** (Kimi-Platform) → 86 keys
   - thinker: +7 from source → 84 keys
   - amber: created fresh → 84 keys
   - nezha (source): 84 keys
   Both `~/.bashrc` and `~/.zshrc` source it on every host.
3. **Installed/updated the toolkit** on all four hosts (`scripts/install.sh`,
   non-interactive) and configured `claude1` / `claude2` / `claude3` on each.
4. **Installed Claude Code** on amber (`npm i -g @anthropic-ai/claude-code`, 2.1.195).
   mistborn intentionally left without the runtime (no node/Homebrew) — toolkit,
   provider detection, and aliases are fully set up there regardless.
5. **Live provider/model detection** (`claude-providers sync`) on every host.

## Verification evidence

**Test suite — `scripts/tests/run-all.sh` (9 files at the time; 58 today):**

| Host     | Result            |
|----------|-------------------|
| nezha    | 9/9 ALL GREEN     |
| thinker  | 9/9 ALL GREEN     |
| amber    | 9/9 ALL GREEN     |
| mistborn | 9/9 ALL GREEN (bash 3.2) |

`test_export.sh` runs fully where pandoc + a PDF engine exist (nezha) and SKIPs
gracefully elsewhere.

**Live provider detection (active providers, 0 unbound errors on every host):**

| Host     | Active providers |
|----------|------------------|
| nezha    | 20               |
| mistborn | 18               |
| thinker  | 17               |
| amber    | 17               |

(Counts vary slightly by host due to live HTTP verification timing/rate limits.
This was a flat "active" count; since v1.14.0 aliases are tracked as
`verified` / `unverified` / `failed` and only `verified` ones may launch.)

**Cross-host config check:** both rc files source `api_keys.sh`; `claude1/2/3` and the
`poe` / `deepseek` / `xiaomi` provider aliases are present on all four hosts.

## Notes / follow-ups (as recorded in 2026-06-28)

- The user's `~/api_keys.sh` contains a dangling reference
  (`export SARVAM_API_KEY=$ApiKey_Sarvam_AI_India`). The toolkit now tolerates this
  (sources keys with `nounset` disabled), but defining or removing that line in the
  keys file would be cleaner.
- mistborn has no Claude runtime (no node/Homebrew). Install node (e.g. via Homebrew
  or nvm) then `npm i -g @anthropic-ai/claude-code` to enable launching aliases there.
- Remotes were provisioned by rsync of the verified working tree; they can be switched
  to `git pull` checkouts of the released tag at any time.
