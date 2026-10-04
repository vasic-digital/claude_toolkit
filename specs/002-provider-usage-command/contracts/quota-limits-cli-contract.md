# Contract: `quota`/`limits` CLI Surface

This is the user-facing contract — exact invocation forms, flags, exit
codes, and output shape. Anything not specified here is an implementation
detail for `tasks.md`/implementation to decide, not a contract violation
either way.

## Invocation forms

```text
claude-providers quota [<alias>] [--json] [--fresh] [--timeout <seconds>] [--no-color]
claude-providers limits [<alias>] [--json] [--fresh] [--timeout <seconds>] [--no-color]
kimi-providers quota [<alias>] [--json] [--fresh] [--timeout <seconds>] [--no-color]
kimi-providers limits [<alias>] [--json] [--fresh] [--timeout <seconds>] [--no-color]
```

`quota` and `limits` are 100% interchangeable — same flags, same output,
same exit codes, for both `claude-providers` and `kimi-providers` (the
latter via its existing catch-all forward, research.md §1). Every example
below says `quota`; read every one as equally true of `limits`.

### Flags

| Flag | Default | Meaning |
|---|---|---|
| `<alias>` (positional, optional) | none (fleet-wide) | Scope to one named alias (FR-003). Unrecognized name → `unknown_alias: true` in the report, not a crash (§5 of data-model.md). |
| `--json` | off | Emit the machine-readable form (FR-016) instead of colored/plain text. Mutually exclusive in SPIRIT with `--no-color` (JSON never carries ANSI either way, so `--no-color --json` is accepted but `--no-color` is simply redundant). |
| `--fresh` | off (short-lived cache allowed) | Force a live probe, bypassing the cache for this invocation (the "operator-facing way to force a fresh probe" the spec's Assumptions flagged as needed; named here). |
| `--timeout <seconds>` | the bounded per-provider default (see Performance Contract below) | Override the per-provider probe timeout for this invocation only — never persisted. |
| `--no-color` | off (color auto-detected) | Force plain text even on a color-capable terminal. `NO_COLOR` (any non-empty value) and a non-terminal stdout already do this automatically (research.md §6); this flag is the explicit, scriptable override for a terminal that CAN show color but the operator does not want it to. |

### Exit codes

| Code | Meaning |
|---|---|
| `0` | The command ran to completion and produced a report — this is true EVEN WHEN every row is red/limit-exceeded/not-reported. Exit code reflects whether the REPORT succeeded, not the SEVERITY of what it found (mirrors this project's own `providers-semantic.sh` convention: `skip`/`unverified` are legitimate, non-crash outcomes with their own meaning, not folded into a generic failure code). |
| `1` | A genuine command-level failure unrelated to any one alias's probe outcome (e.g. the providers directory cannot be read at all, invalid flag combination). |
| `2` | `<alias>` was given and does not exist (`unknown_alias: true`) — distinct from `0` so a script checking "did the alias I asked about even exist" does not have to parse output to find out. |

Severity-aware scripting (e.g. "fail CI if anything is red") reads the
`--json` output's `severity`/`absence_reason` fields and decides for
itself — this command does not impose an opinion on what severity should
fail a caller's script, consistent with it being a REPORT, not a policy
gate.

## Human-readable output shape

One line per Usage Window (not one line per row — a row with 3 windows is
3 lines, grouped under one alias header), e.g.:

```text
deepseek  (alias: deepseek, kimi-deepseek)
  subscription   47.32 USD used / 52.68 USD left of 100.00 USD   (52.7% left)   [GREEN]

openrouter  (alias: openrouter)
  subscription   —   not reported by provider

claude1  (native, plan tier: default_claude_max_20x)
  —   not reported by provider

helixagent  (alias: helixagent)
  session   198,204 / 229,376 tokens used (31,172 left, 13.6% left)   [RED]
  (probe failed for window: weekly — connection timed out after 4s)
```

Column alignment, exact wording, and whether severity also gets an
inline glyph (e.g. `●`) alongside color are implementation-level choices
for `tasks.md` — the CONTRACT is: every window on its own line under its
alias's header; absence/failure stated in words, never a bare dash with
no explanation; a visually distinct marker for `limit_exceeded` vs. plain
red (FR-008), satisfied by ANY rendering choice that a color-stripped
reading of the same line still shows the distinction in words (FR-013).

## `--json` output shape

One JSON object (not an array at the top level, so future top-level
metadata can be added without a breaking shape change), matching
data-model.md §5 field-for-field:

```json
{
  "generated_at": "2026-10-04T10:15:30Z",
  "scoped_to": null,
  "unknown_alias": false,
  "rows": [
    {
      "kind": "provider_account",
      "display_name": "deepseek",
      "alias_names": ["deepseek", "kimi-deepseek"],
      "base_url": "https://api.deepseek.com",
      "endpoint_spec_present": true,
      "account_blocked": false,
      "data_source": "live",
      "data_age_seconds": null,
      "absence_reason": null,
      "absence_detail": null,
      "windows": [
        {
          "window": "subscription",
          "amount_used": 47.32,
          "amount_remaining": 52.68,
          "limit_total": 100.0,
          "unit": "USD",
          "percent_remaining": 52.68,
          "severity": "green",
          "resets": false,
          "reset_at": null
        }
      ]
    },
    {
      "kind": "native_account",
      "display_name": "claude1",
      "account_id": "claude1",
      "family": "claude",
      "plan_tier": "default_claude_max_20x",
      "account_blocked": false,
      "data_source": "live",
      "data_age_seconds": null,
      "absence_reason": "not_reported_by_provider",
      "absence_detail": null,
      "windows": []
    }
  ]
}
```

Every field in data-model.md §1/§2/§3/§4/§5 MUST be present in every
object of its kind — `null` is a valid value for an optional field, but
the KEY is never omitted (so a consumer never has to distinguish "absent
key" from "present key with value null"; this matches this project's
existing `--json` conventions elsewhere, e.g. `llmctl plan --json`'s
per-profile objects always carrying every key).

## Performance contract (FR-017)

- The per-provider probe timeout defaults to a short, single-digit-second
  budget (the exact number is a `tasks.md` decision informed by this
  project's existing `CMA_LLMCTL_HTTP_TIMEOUT`-style precedent, not pinned
  here) and is overridable via `--timeout`.
- Fleet-wide total wall-clock time is bounded by
  `ceil(N_accounts / CMA_QUOTA_MAX_PARALLEL_PROBES) × per_provider_timeout`,
  the same shape as this project's existing documented llmctl-probe bound
  (research.md §5) — NOT `N_accounts × per_provider_timeout`.
- One slow/unresponsive account's probe degrades ONLY that row to
  `absence_reason: probe_failed` and never delays any other row's
  reporting or the command's own total exit (SC-008's contract).

## Collision-freedom contract (FR-001, mechanically tested)

Neither `quota` nor `limits`, nor any new flag above, may ever match:
- Any existing top-level subcommand case label in `claude-providers.sh`'s
  dispatch (`sync`, `helixllm-export`, `list`, `list-all`, `list-faulty`,
  `show`, `verify`, `sync-all-llmctl`, `remove`, `prune`, `add`,
  `migrate-names`) or `kimi-providers.sh`'s (`list`, `list-all`,
  `list-faulty`, plus whatever it forwards).
- Any existing bash FUNCTION name in either script or in `scripts/lib.sh`
  (including, explicitly, `usage()` in both scripts — the collision this
  whole naming decision exists to avoid, asserted by name, not just by
  absence from the dispatch table).
- Any existing flag accepted by either script's argument loop.
- Any existing `CMA_*` environment-variable prefix already documented in
  this project's CLAUDE.md or defined in `scripts/lib.sh`.

The test asserting this (`test_quota_cli.sh`, plan.md's Execution
Strategy) enumerates the CURRENT dispatch tables/function lists/flag lists
BEFORE this feature's change lands, and again after, diffing for any
label that exists in both the new subcommand/flag set and the pre-existing
set — not a hand-picked list of "the ones we thought of," so it also
catches a collision with something this contract's author did not think
to name.
