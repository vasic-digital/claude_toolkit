# Quickstart: Validating `quota`/`limits`

A runnable validation guide proving this feature works end-to-end against
a real, installed copy of the toolkit — the "full LIVE testing... on LIVE
installed latest Claude Toolkit codebase with fully deterministic checks
against machine produced rock-solid evidence" the originating request
requires. See `contracts/quota-limits-cli-contract.md` for exact flag/
output definitions and `data-model.md` for field meanings — not repeated
here.

## Prerequisites

- This toolkit installed (`bash scripts/install.sh`, idempotent) with at
  least:
  - One native account configured (`claude-add-account` or equivalent —
    any already-authenticated `claudeN`/`kimiN` slot works).
  - One provider alias whose underlying provider has a real entry in
    `scripts/providers/quota-endpoints.json` (OpenRouter is the reference
    example throughout this guide, per `contracts/
    quota-endpoint-spec-contract.md`'s worked example — any
    `OPENROUTER_API_KEY` in `~/api_keys.sh`, synced via `claude-providers
    sync`, works).
  - One provider alias whose provider has NO entry in that file (any
    provider not yet documented there — this proves the honest-absence
    path, Scenario 3 below).
- `jq` installed (already a hard toolkit dependency).

## Scenario 1 — Fleet-wide view (User Story 1 / SC-001, SC-002, SC-004)

```bash
claude-providers quota
```

**Expected**: every configured native account and provider alias appears
exactly once (grouped by underlying Provider Account for alias-family
twins, per data-model.md §2 — e.g. `deepseek` and `kimi-deepseek` appear
under ONE row, not two). The OpenRouter row shows a real
used/remaining/percentage/limit figure, colored per the FR-008 scale. Run
it a second time piped to a file:

```bash
claude-providers quota > /tmp/quota-plain.txt
cat -A /tmp/quota-plain.txt | grep -c $'\033'   # expect: 0
```

**Expected**: zero ANSI escape sequences in redirected output (color
auto-disables on a non-terminal, research.md §6), and every severity
still readable as plain words (FR-013) — confirm by eye that the
OpenRouter row's line states its percentage/severity in text, not only
via color that just vanished.

## Scenario 2 — Per-alias detail (User Story 2 / spec Acceptance Scenario 2.1/2.2/2.3)

```bash
claude-providers quota openrouter
```

**Expected**: the SAME OpenRouter figures as Scenario 1, scoped to just
this one alias (`contracts/quota-limits-cli-contract.md`'s `scoped_to`
field, via `--json` — see Scenario 5). Then a name that does not exist:

```bash
claude-providers quota this-alias-does-not-exist; echo "exit=$?"
```

**Expected**: a plain statement that the alias does not exist, and
`exit=2` (the CLI contract's dedicated exit code for this case) — never a
silent empty success (`exit=0` with no output) and never a crash.

## Scenario 3 — Honest absence (User Story 3 / SC-003)

```bash
claude-providers quota <alias-with-no-quota-endpoints-entry>
```

**Expected**: an explicit "not reported by provider" status — no
percentage, no green/yellow/red color implying a real measurement was
made. Then force a probe failure to prove the SEPARATE failure path
(temporarily point the alias's provider at an unreachable host, or use
`--timeout 1` against a genuinely slow endpoint if one is available):

```bash
claude-providers quota <alias> --timeout 1
```

**Expected**: an explicit probe-failure status, textually distinct from
"not reported by provider" — read both outputs side by side and confirm a
human cannot confuse one for the other.

## Scenario 4 — Native account honest status (research.md §7)

```bash
claude-providers quota claude1   # or whichever native slot is configured
```

**Expected**: "not reported by provider" (native OAuth accounts have no
discovered live usage endpoint as of this feature's first version,
research.md §7) — OPTIONALLY annotated with the cached plan-tier name
(e.g. "plan tier: default_claude_max_20x") if one is cached locally.
Confirm this reads as informative, not as a bug report.

## Scenario 5 — Machine-readable output (FR-016 / SC-007)

```bash
claude-providers quota --json | jq .
```

**Expected**: valid JSON parses cleanly; every row carries every field
`data-model.md` §1 requires (no silently-omitted keys); the OpenRouter
row's `severity` field matches the color shown in Scenario 1's human
output for the SAME invocation's data — assert this directly:

```bash
diff <(claude-providers quota --json | jq -r '.rows[] | select(.display_name=="openrouter") | .windows[0].severity') \
     <(echo green)   # or whatever this run's real severity is
```

## Scenario 6 — Bounded concurrency / timeout isolation (FR-017 / SC-008)

This is the one scenario this guide describes rather than gives a literal
command for, because it needs a controlled slow-provider fixture — see
`scripts/tests/test_quota_concurrency.sh` for the hermetic, automated
version of this exact check (a sandboxed fake provider that sleeps past
the timeout). As a live sanity check with real aliases:

```bash
time claude-providers quota
```

**Expected**: total wall-clock time stays within
`ceil(N_accounts / CMA_QUOTA_MAX_PARALLEL_PROBES) × per_provider_timeout`
(contracts/quota-limits-cli-contract.md's Performance Contract) — NOT
`N_accounts × per_provider_timeout`. On a host with more configured
accounts than `CMA_QUOTA_MAX_PARALLEL_PROBES`, confirm the total time does
not scale linearly with account count by comparing against a run with
half as many accounts temporarily removed (e.g. via `--scoped` runs
combined).

## Scenario 7 — Collision-freedom (FR-001, regression-critical)

```bash
bash scripts/tests/test_quota_cli.sh
```

**Expected**: PASS, including the specific assertion that `usage()` in
both `claude-providers.sh` and `kimi-providers.sh` still prints `--help`
text unchanged, and that `quota`/`limits` reach the new reporting logic —
proving the naming decision this spec's clarification session made is
actually upheld in the shipped code, not just documented.

## Full regression confirmation

```bash
bash scripts/tests/run-all.sh
bash scripts/claude-release-gate.sh
```

**Expected**: every pre-existing test still passes unmodified (SC-006),
and the release gate's live leg includes this feature's end-to-end check
among its evidence under `scripts/tests/proof/`.
