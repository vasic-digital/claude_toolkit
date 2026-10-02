# External Contract: what claude_toolkit assumes about llmctl

**Feature**: [../spec.md](../spec.md) | **Research**: [../research.md](../research.md)

This is the dependency contract between claude_toolkit and the separate
`llmctl` project. It exists so that a future llmctl change breaking any of
these assumptions is **detectable by a test**, not discovered as a live
failure. claude_toolkit's own task list must add one assertion per row; this
feature does not modify `../llmctl` itself (clarified scope).

## Commands claude_toolkit invokes

| Command | Assumed behavior claude_toolkit relies on | Source of truth |
|---|---|---|
| `llmctl plan --json` | Emits `{"profiles": {<name>: {...}}, "budgets": {...}, "groups": [...]}`; each profile object carries `port`, `ctx`, `engine`, `capability`, `fits`, `mode` as documented in `research.md §3.A`. **Never** carries a `running` field. | `research.md §3.A` |
| `llmctl status` | Human-readable text table only; **not** parsed by claude_toolkit (no `--json` exists upstream — `research.md §3.D LLMCTL-F1`). claude_toolkit MUST NOT start depending on this output's exact column layout. | `research.md §3.D LLMCTL-F1` |
| `llmctl switch <profile>` | Exit code `0` on success; non-zero on failure. On failure, the previously-running set is *usually* restored (best-effort — `research.md §3.B`), but claude_toolkit MUST independently re-verify the previous profile's liveness after a failed switch rather than trusting the exit code alone to mean "previous state preserved." | `research.md §3.B LLMCTL-F2` |
| `<profile's own base URL>/v1/models` | OpenAI-compatible; when present, `meta.n_ctx` is authoritative for the profile's real context size. | `research.md §1`, `§2` |

## Assumptions that, if they change upstream, require re-running this feature's contract tests

1. `plan --json`'s per-profile object always contains `port` and `ctx` as
   integers (claude_toolkit's context-limit carve, `research.md §2`, depends
   on `ctx` being present and numeric).
2. The resolved `port` for a given profile is not assumed to equal the
   README's static table — it is always read fresh from `plan --json`.
3. No API key is required by llmctl's per-profile OpenAI-compatible
   endpoints by default (`research.md §3.F`) — claude_toolkit's
   `LLMCTL_API_KEY` key_var stays a toolkit-internal registration key, never
   sent as a real credential. If llmctl ever adds a real default
   authentication requirement, this assumption breaks and must be revisited.
4. llmctl never reports a profile's bind address via any JSON command
   (`research.md §3.C`) — claude_toolkit's FR-009 implementation reads the
   real kernel socket state directly and does not wait for or depend on an
   upstream API addition.
5. Every llmctl-managed profile is reachable at `127.0.0.1:<resolved port>`
   regardless of its actual bind address — claude_toolkit always probes via
   loopback for liveness, and separately inspects the real bind address only
   to decide the FR-009 warning, never to decide whether the profile is
   "running."

## Contract test obligations (feeds tasks.md)

- A new test asserts `detect_llmctl_records` fails closed (an honest SKIP/
  error, never a silent `[]`) when `llmctl plan --json` returns a `profiles`
  object whose entries are missing `port` or `ctx` — detecting an upstream
  schema drift the moment it would otherwise silently produce a broken or
  undersized alias.
- A new test asserts the context-limit carve (`research.md §2`) is applied
  using `ctx` from `plan --json` when `/v1/models` `meta.n_ctx` is absent,
  and that the carve's floor-violation warning fires on a fixture profile
  whose `ctx` is deliberately set below the CLI-agent-overhead floor.
