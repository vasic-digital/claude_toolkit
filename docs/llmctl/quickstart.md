# llmctl Integration — Quick Start

[llmctl](https://github.com/vasic-digital/llmctl) is a separate, sibling
project that runs local LLMs on your own machine — each model profile as its
own independent server, serving an OpenAI-compatible API on a fixed port.
`claude-providers` automatically recognizes every llmctl profile you have
**running right now** and exposes it as a normal, launchable Claude Code (and
Kimi Code) alias — no manual provider-file editing, no separate registration
step.

---

## 1. Prerequisites

| Need | Why |
|------|-----|
| llmctl installed, with at least one model profile downloaded | this integration discovers and uses llmctl — it does not install, configure, or manage llmctl itself (see llmctl's own docs for `llmctl setup` / `llmctl models download`) |
| The toolkit installed | provides `claude-providers`, the alias file, the launch wrappers |
| `jq`, `curl`, `ss` | catalog parse + liveness probe + bind-address check |

## 2. Quick start

```bash
llmctl start fast              # start a profile directly via llmctl
claude-providers sync          # re-sync claude_toolkit
source ~/.local/share/claude-multi-account/aliases.sh   # or open a new shell
claude-providers list | grep llmctl-   # confirm llmctl-fast appears
claude llmctl-fast -p "hi"      # launch Claude Code against it
```

The alias is always named `llmctl-<profile>` — never a bare profile name —
so it is immediately distinguishable from a native account or any other
provider alias. The same profile is also reachable through Kimi Code as
`kimi-llmctl-<profile>` (e.g. `kimi-llmctl-fast`), using the exact same
underlying detection.

## 3. The alias only exists while the model is actually running

`claude-providers sync` re-detects every llmctl profile on every run. If you
stop the profile (`llmctl stop fast`), the next sync removes the alias —
there is never a stale alias pointing at a model that is no longer there. If
llmctl is not installed, or installed but serving nothing, `claude-providers
sync` behaves exactly as if llmctl were absent: no error, no broken alias.

## 4. Switching models

Launching a **different** `llmctl-<profile>` alias than the one currently
active switches the model automatically — the toolkit hands this off to
llmctl's own exclusive switch (stop the previous profile, start exactly the
one you asked for). You do not need a separate switch command on the
claude_toolkit side; just launch the alias you want:

```bash
claude llmctl-fast -p "hi"      # fast is now active
claude llmctl-coder -p "hi"     # automatically switches: fast stops, coder starts
```

If the target profile does not fit your host's currently available
resources, the switch is refused with a clear reason, and whatever was
previously active is left exactly as it was.

## 5. Two honest warnings you may see

- **LAN-exposure warning** — the model is reachable from your local network,
  not only from this machine. llmctl binds to all network interfaces by
  default; the alias still works, this is just telling you who else can
  reach it.
- **Context-size warning** — this profile's real context window is smaller
  than what a CLI agent's own prompt + tool-schema overhead typically needs,
  so a real turn may fail with a context-exceeded error. The alias still
  works for lighter use; this is an honest heads-up about a specific
  profile's capacity, not a toolkit defect.

## 6. Something not working?

See the full [user guide](./user-guide.md) for switching details, both
warnings in depth, and troubleshooting — and the [FAQ](./FAQ.md) for quick
answers to the most common "why isn't..." questions.
