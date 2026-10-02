# Data Model: llmctl Integration Hardening & Verified Release

**Feature**: [spec.md](./spec.md) | **Research**: [research.md](./research.md)

This is a CLI-orchestration feature with no database; "data model" here means
the shapes of the records the toolkit reads, derives, and exposes, and the
state transitions those records go through. Field names/types for
llmctl-sourced data are taken verbatim from the authoritative schema
confirmed in `research.md §3.A`.

## Entities

### llmctl Catalog Profile (external — owned by llmctl, read-only to claude_toolkit)

The record `llmctl plan --json` emits per profile name (key). claude_toolkit
never redefines or mutates this shape; it only reads it.

| Field | Type | Notes |
|---|---|---|
| `mode` | enum `gpu\|cpu\|colibri\|none` | Which inference backend class serves this profile. |
| `ram_mb` / `vram_mb` / `storage_mb` | int | Footprint llmctl computed for this profile. |
| `ctx` | int | llmctl's own configured context size for this profile — the authoritative fallback source for `context_limit` (research.md §2). |
| `ngl` / `parallel` / `flash_attn` | various | Engine-tuning fields, not consumed by claude_toolkit today. |
| `fits` | bool | Whether this profile currently fits the host's live budget. |
| `port` | int | The profile's **resolved** port (never hardcode the README's default table — `research.md §3.A`). |
| `engine` | enum `llama.cpp\|colibri` | Which engine backs this profile. |
| `capability` | array of string | e.g. `chat`, used to distinguish coder/vision/etc. profile intent. |
| `min_tier` / `tier_ok` / `recommended` | various | Hardware-tier fit hints. |

**No `running` field exists on this record** (`research.md §3.A`) — liveness
is never derived from `plan --json` alone.

### llmctl-Backed Record (claude_toolkit-internal — derived, not persisted beyond one sync)

Produced by `detect_llmctl_records()` for each catalog profile that
**independently verified as live** (its own `/v1/models` endpoint answered —
see `research.md §1`). This is the record that becomes a provider alias.

| Field | Type | Derivation | Validation |
|---|---|---|---|
| `provider_id` / `alias` | string | `"llmctl-" + <profile name>` (`research.md §1`) | MUST always carry the `llmctl-` prefix; a bare profile name is a defect (FR-002). |
| `base_url` | string | `http://127.0.0.1:<resolved port>/v1` | Port taken from the catalog profile's resolved `port`, never the README's static table. |
| `transport` | enum | `CMA_LLMCTL_TRANSPORT` (default `router`) | — |
| `context_limit` | int | Best-available real `n_ctx` (from `/v1/models` `meta.n_ctx`, else the catalog profile's own `ctx` field) **then carved** by the same `derive_limits()`-style floor every other provider record already gets (new — `research.md §2`) | MUST NOT be a flat, unconditional default; MUST be honestly flagged when the carved result cannot clear the minimum usable floor for a CLI agent's own overhead. |
| `max_output` | int | Carved jointly with `context_limit` | Same carve discipline as `context_limit`. |
| `key_var` | string | `CMA_LLMCTL_KEYVAR` (default `LLMCTL_API_KEY`) | Toolkit-internal registration key only — never sent to llmctl as a real credential (`research.md §3.F`). |
| `lan_exposed` | bool (new field) | Read from the real listening socket's bind address for the resolved port (e.g. via `ss -ltnp`), never from llmctl's JSON — llmctl exposes no such field (`research.md §3.C`) | Drives FR-009's warning; MUST reflect the real kernel socket state, not a cached/assumed value. |
| `status` | enum `live` | Only ever emitted for profiles that passed the independent HTTP liveness probe | A catalog profile that exists but did not answer its probe produces **no** record at all (not a record with `status: dead`). |

**State transitions** (one llmctl-Backed Record per profile, implicit —
there is no persisted record when a profile is not running):

```
(profile not running)
      │ llmctl starts the profile (operator-driven, via llmctl itself or
      │ via claude_toolkit's on-demand-only start per FR-006)
      ▼
(profile running, not yet probed this sync)
      │ detect_llmctl_records() HTTP-probes /v1/models
      ├─ probe succeeds ──────────────► RECORD EXISTS → alias `llmctl-<profile>` is exposed
      └─ probe fails/times out ───────► NO RECORD → alias absent/removed (FR-003)
```

A switch (`_cma_llmctl_ensure_active`) does not directly mutate this record;
it calls `llmctl switch <profile>`, and the **next** `detect_llmctl_records()`
call observes the new live set. FR-007's "leave the previous profile exactly
as it was" is therefore verified by a **post-switch-failure liveness
re-probe** of whatever was previously active (new, per `research.md §3.B`'s
rollback-is-best-effort finding), not by assuming the switch's exit code
alone proves the previous state held.

### CLI Agent Family

Fixed, closed set at this feature's scope (per spec Assumptions):
`claude` (Claude Code) and `kimi` (Kimi Code). Each llmctl-Backed Record is
expected to produce one launchable alias per family (`llmctl-<profile>` for
Claude Code, `kimi-llmctl-<profile>` for Kimi Code), consistent with the
existing twin-alias pattern already used for every other provider.

### Extension Command

A fixed, closed set of three for this feature's live-test scope:

| Command | Target skill | Unforgeable-challenge source |
|---|---|---|
| Use Superpowers | `superpowers:using-superpowers` | Existing — Red-Flags table cell, read from `SKILL.md` at runtime (`verify_superpowers_tui.sh`). |
| Turn on Systematic Debugging | `superpowers:systematic-debugging` | New — an analogous unique fact extracted from `systematic-debugging/SKILL.md` at runtime. |
| Turn on Sub-Agent-Driven Development | `superpowers:subagent-driven-development` | New — an analogous unique fact extracted from `subagent-driven-development/SKILL.md` at runtime. |

### Check Result

One durable record per (llmctl-Backed Record × CLI Agent Family × Extension
Command) combination, plus one per constitution-test-type check applied to
detection/switching itself.

| Field | Type | Notes |
|---|---|---|
| `combination_id` | string | `<alias>__<cli_agent_family>__<command>` (or `<alias>__<check_name>` for non-live checks). |
| `verdict` | enum `pass\|fail\|skip` | Never a fourth, ambiguous state (spec Key Entities). |
| `evidence` | path/blob | Captured transcript/output backing `pass`/`fail`; a stated reason for `skip`. |
| `route_resolved` | string (live checks only) | Which backend actually served the turn — reused from `verify_superpowers_tui.sh`'s existing route-attribution mechanism, since a result attributable to the wrong backend is worse than a plain failure. |
| `run_index` | int | 1 or 2 — FR-013's reproducibility check runs the full matrix twice and compares. |

### llmctl-Side Finding (tracking only — not fixed under this feature)

| Field | Type | Notes |
|---|---|---|
| `finding_id` | string | `LLMCTL-F<n>`, stable (research.md §7 is the seed register). |
| `description` | string | Precise, with file:line citation into `../llmctl`. |
| `confidence` | enum `confirmed\|suspected` | Per research.md's own distinction. |
| `tracked_as` | reference | The separately-filed follow-up item this finding maps to (FR-010a) — never a claude_toolkit task. |

## Relationships

```
Catalog Profile (llmctl, external)
      │ 1:1 (when independently verified live)
      ▼
llmctl-Backed Record (claude_toolkit, derived per sync)
      │ 1:N (one per CLI Agent Family)
      ▼
Alias (llmctl-<profile>, kimi-llmctl-<profile>, ...)
      │ N:M (one check per Extension Command × run_index)
      ▼
Check Result
```

Catalog Profiles that are never independently verified live never produce a
Record, and therefore never produce an Alias or a Check Result — there is no
"stub" or "placeholder" state anywhere in this chain (consistent with the
spec's "never a fourth, ambiguous state" rule).
