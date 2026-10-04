# Data Model: Universal Alias Quota/Limits Reporting

Source of truth for every entity this feature introduces or reads from.
Field names here are the CONCEPTUAL shape; `contracts/quota-limits-cli-
contract.md` pins the exact `--json` field names (snake_case, matching
this project's existing JSON conventions, e.g. `context_limit`,
`lan_exposed` in the llmctl-detection JSON at `claude-providers.sh:2224`).

## 1. Reportable Entity (abstract)

Every row `quota`/`limits` ever prints is one of exactly two concrete
kinds, both satisfying this shared shape:

| Field | Type | Notes |
|---|---|---|
| `kind` | enum: `provider_account` \| `native_account` | Which concrete entity this is (§2 / §3) |
| `display_name` | string | What the operator sees as the row's identity |
| `windows` | list of **Usage Window** (§4) | Zero or more — zero means "no window could be determined" |
| `absence_reason` | enum: `null` \| `not_reported_by_provider` \| `probe_failed` | Set only when `windows` is empty; mutually exclusive with having any window (FR-009/FR-010) |
| `absence_detail` | string \| `null` | Human-readable cause when `absence_reason` is set (e.g. the timeout/network error text for `probe_failed`; `null` for `not_reported_by_provider`, which needs no further explanation) |
| `account_blocked` | boolean | True only when the WHOLE account/subscription is stopped, not merely one window (FR-011) — orthogonal to `windows`/`absence_reason`: a blocked account can still have had real windows before the block, which stay reported, with this flag making the hard-stop visible alongside them |
| `data_source` | enum: `live` \| `cached` | Per FR-012 |
| `data_age_seconds` | integer \| `null` | `null` when `data_source == "live"`; required (non-null) when `cached` |

**Invariant (mechanically tested)**: `windows` non-empty XOR
`absence_reason` non-null XOR a probe is still genuinely pending (never
observed in a FINISHED report — FR-017 guarantees every probe resolves to
one of these three states within the bounded timeout). No row may have
both real windows AND an absence_reason; no row may have neither.

## 2. Provider Account

A **Provider Account** is the thing `quota`/`limits` actually probes once
for API-key-backed providers — keyed by the provider id as it appears in
`$id.env` (`CMA_PROVIDER_ID`), e.g. `deepseek`, `openrouter`. **This is
the critical de-duplication key**: `deepseek`, `kimi-deepseek`, and
`pi-deepseek` are three different ALIAS names a user can launch, but they
all authenticate as the SAME real account via the SAME real API key
(confirmed: `cma_run_provider`/`cma_run_kimi_provider`/`cma_run_pi_provider`
all source the identical `$pdir/deepseek.env`, research.md §2) — so they
share ONE Provider Account entity and therefore ONE identical set of Usage
Windows. The probe runs exactly once per distinct Provider Account per
invocation, never once per alias-family name (this is what makes FR-017's
"bounded by alias count, not by N-times-as-many-as-the-family-fan-out"
property achievable, and avoids showing a human three numbers for one
real account — which the operator could reasonably read as three
independent accounts with independent remaining budgets, a confusing and
wrong impression).

| Field | Type | Notes |
|---|---|---|
| `provider_id` | string | `CMA_PROVIDER_ID` from `$id.env` |
| `alias_names` | list of string | Every currently-installed alias name that maps to this account (e.g. `["deepseek", "kimi-deepseek"]`) — shown so the operator can see which launch names this one report covers, never iterated to re-probe |
| `base_url` | string | `CMA_PROVIDER_BASE_URL`, carried for traceability in `--json`, never re-derived |
| `endpoint_spec_present` | boolean | Whether `providers/quota-endpoints.json` has an entry for this `provider_id` — directly determines whether a real probe is even attempted vs. an immediate `not_reported_by_provider` (no endpoint spec means no attempt is made at all, which is distinct from attempting and failing) |

## 3. Native Account

A **Native Account** is `claudeN` or `kimiN` — unlike a Provider Account,
EACH slot is independently a genuinely distinct real subscription (this
toolkit's entire purpose is multi-ACCOUNT management of distinct real
accounts), so there is no de-duplication here: every configured native
account slot gets its own probe and its own row, always.

| Field | Type | Notes |
|---|---|---|
| `account_id` | string | `claude1`, `kimi2`, etc. |
| `family` | enum: `claude` \| `kimi` | Which native CLI family |
| `plan_tier` | string \| `null` | The cached rate-limit tier name where available (research.md §7 — e.g. `default_claude_max_20x` for Claude; the Kimi-family analog, if one is found during implementation); `null` when nothing is cached |

## 4. Usage Window

One countable budget period, independently reported (FR-004 — never
blended across windows).

| Field | Type | Notes |
|---|---|---|
| `window` | enum: `session` \| `daily` \| `weekly` \| `subscription` | Which budget period this is |
| `amount_used` | number | Exact, in the provider's own unit |
| `amount_remaining` | number | Exact, same unit as `amount_used` |
| `limit_total` | number | `amount_used + amount_remaining`, carried explicitly (not left for the consumer to add) so a rendering bug can never silently imply a different total than the provider actually reported |
| `unit` | string | Free-form, provider-reported (e.g. `"tokens"`, `"requests"`, `"USD"`) — FR-005 explicitly allows whatever unit the provider itself uses; never normalized/converted across providers |
| `percent_remaining` | number (0–100, provider's own precision) | `100 * amount_remaining / limit_total` UNLESS the provider reports a percentage directly, in which case the provider's own value wins over a locally-derived one (never silently override a provider's more precise figure with a cruder local computation) |
| `severity` | enum: `green` \| `yellow` \| `red` \| `limit_exceeded` | Derived from `percent_remaining` by the exact FR-008 scale; `limit_exceeded` when `amount_remaining <= 0` regardless of the percentage math (so a provider reporting a NEGATIVE remaining, e.g. after overage, still classifies correctly rather than producing an undefined or incorrectly-colored percentage) |
| `resets` | boolean | Whether this window has a reset at all |
| `reset_at` | ISO-8601 timestamp \| `null` | Required (non-null) when `resets == true`; `null` when `resets == false` — the two fields together make "does this reset, and when" answerable without a sentinel value doing double duty (e.g. a `0`/empty-string reset_at that could be mistaken for "resets immediately" rather than "never resets") |

**Boundary rule (mechanically tested, ties to plan.md's TDD requirement)**:
`percent_remaining == 30` is green (the FR-008 scale is `30%–100%` green,
inclusive at 30); `percent_remaining == 10` is yellow (the scale is
`10%` down to just-under-30% yellow, inclusive at 10); anything
`< 10` and `> 0` is red; `<= 0` is `limit_exceeded`. These exact boundary
values are the test table's first-class inputs, not incidental cases
inside a broader range test.

## 5. Usage Report (the top-level `quota`/`limits` output)

| Field | Type | Notes |
|---|---|---|
| `generated_at` | ISO-8601 timestamp | When THIS invocation ran — distinct from any individual row's `data_age_seconds`, which is about cache age, not report-generation time |
| `rows` | list of **Reportable Entity** (§1) | One per Provider Account + one per configured Native Account; order is stable (configuration order), never re-sorted by severity (an operator scanning for "what's red" uses color/the `--json` severity field, not row position, to find it — re-sorting would make the report harder to diff run-to-run) |
| `scoped_to` | string \| `null` | The single alias name when invoked as `quota <alias>` (FR-003); `null` for the fleet-wide form. When non-null, `rows` has at most one entry. |
| `unknown_alias` | boolean | True only when `scoped_to` names an alias that does not currently exist (FR-003's "state plainly... when the named alias does not exist") — when true, `rows` is empty and this is the ONLY field carrying the outcome; this is a fourth, narrower state than the three in §1's invariant, scoped to the single-alias form only |

## 6. `providers/quota-endpoints.json` entry (the declarative probe spec)

One entry per provider id that has a documented usage-window endpoint —
absence of an entry for a given `provider_id` is precisely what sets
`endpoint_spec_present = false` (§2), which short-circuits straight to
`not_reported_by_provider` with no network attempt at all.

| Field | Type | Notes |
|---|---|---|
| `url` | string (https) | The balance/usage endpoint, GET |
| `auth` | enum: `bearer` \| `x-api-key` \| `raw` | Matches `credit-endpoints.json`'s existing vocabulary exactly (research.md §3) |
| `auth_header` | string | Only present when `auth == "raw"`, naming the header |
| `doc` | string (URL) | Citation for the response shape, carried into `--json` evidence for auditability — matches existing `credit-endpoints.json` convention |
| `windows` | list of per-window signal groups | Each group names its `window` (`session`/`daily`/`weekly`/`subscription`) and an ORDERED `signals` list (first-present-wins, matching `model_verify.py`'s existing rule) of `{path, type, minus?, desc}` entries, where `type` is one of `amount_used`, `amount_remaining`, `limit_total`, `percent_remaining`, `reset_at`, `reset_in_seconds` — a strict superset of `credit-endpoints.json`'s existing `balance`/`boolean`/`boolean_negated` vocabulary, reusable by the same walker |

## State Transitions

There is exactly one lifecycle, per invocation, per row — this is a
read-only reporting feature, so "state transitions" means the flow a
single probe moves through, not a persisted state machine:

```text
start
  │
  ▼
endpoint_spec_present? ──No──► absence_reason = not_reported_by_provider  [TERMINAL]
  │ Yes
  ▼
probe (bounded timeout, FR-017)
  │
  ├─ timeout / network error / auth error ──► absence_reason = probe_failed  [TERMINAL]
  │
  └─ HTTP 200 + at least one signal present per window
        │
        ▼
     windows populated, severity computed per window  [TERMINAL]
```

A row never moves from one terminal state to another within a single
invocation; the NEXT invocation is a fresh traversal (cached data, per
FR-012, is a property of what `data_source`/`data_age_seconds` the fresh
traversal chose to report, not a different path through this diagram).
