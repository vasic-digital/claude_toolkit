# Contract: `providers/quota-endpoints.json` Schema

Declarative, data-only (§11.4.111-style: an operator can add a provider
here without touching Python), sibling to the existing `scripts/
providers/credit-endpoints.json`. This file is consumed exclusively by
`scripts/quota_probe.py`.

## Top-level shape

```json
{
  "_comment": ["... same documentation-array convention as credit-endpoints.json ..."],
  "<provider_id>": {
    "url": "https://api.example.com/v1/usage",
    "auth": "bearer",
    "auth_header": null,
    "doc": "https://docs.example.com/usage-endpoint",
    "windows": [
      {
        "window": "subscription",
        "signals": [
          { "path": ["data", "limit_remaining"], "type": "amount_remaining", "desc": "..." },
          { "path": ["data", "limit"],           "type": "limit_total",     "desc": "..." },
          { "path": ["data", "usage"],            "type": "amount_used",    "desc": "..." },
          { "path": ["data", "unit"],             "type": "unit_literal",   "value": "USD" }
        ]
      }
    ]
  }
}
```

## Field reference

| Field | Required | Notes |
|---|---|---|
| `url` | Yes | Absolute `https://` GET endpoint. Never `http://` — this file carries a real credential in its Authorization header at probe time, same as `credit-endpoints.json`. |
| `auth` | Yes | One of `bearer` \| `x-api-key` \| `raw` — identical vocabulary to `credit-endpoints.json`, same meaning. |
| `auth_header` | Only when `auth == "raw"` | Names the literal header. |
| `doc` | Yes | A real, checkable URL to the provider's own documentation of this endpoint — carried into `--json` evidence (data-model.md §6) so a reviewer or a future maintainer can verify a signal's meaning against the source, not against this file's own `desc` text alone. |
| `windows` | Yes, at least one entry | Each entry is one budget-period group (§ below). A provider that only ever reports ONE window (e.g. a flat lifetime credit balance) still uses a one-entry list, tagged `"window": "subscription"` — there is no "windowless" shorthand, so every provider entry has the same shape regardless of how many windows it actually has. |

### `windows[]` entry

| Field | Required | Notes |
|---|---|---|
| `window` | Yes | One of `session` \| `daily` \| `weekly` \| `subscription` — matches data-model.md §4's `Usage Window.window` enum exactly; this is the value copied verbatim into the probe's output. |
| `signals` | Yes, at least one entry | ORDERED list — first signal whose `path` resolves to a present value in the response WINS for that `type`; later signals of the SAME `type` in the list are fallbacks for a null/absent earlier one (mirrors `credit-endpoints.json`'s existing "most precise first" rule, research.md §3), never an averaging or merge across multiple present signals of the same type. |

### `signals[]` entry

| Field | Required | Notes |
|---|---|---|
| `path` | Yes (except `unit_literal`, see below) | List of dict keys / integer list indices, walked by the SAME `_dig`/`_walk` primitives `model_verify.py` already uses (research.md §3) — identical semantics, not a new walker. |
| `type` | Yes | One of `amount_used` \| `amount_remaining` \| `limit_total` \| `percent_remaining` \| `reset_at` \| `reset_in_seconds` \| `unit_literal` \| `account_blocked` \| `account_blocked_negated`. |
| `minus` | No | Only meaningful for `amount_used`/`amount_remaining`/`limit_total` — a second `path`, subtracted from the first (reused verbatim from `credit-endpoints.json`'s existing `minus` field, e.g. "granted minus spent"). |
| `value` | Only for `type: "unit_literal"` | A fixed string (e.g. `"USD"`, `"tokens"`) used when the provider's response never states its own unit and it is otherwise a fixed, known constant for that provider/endpoint — `path` is omitted for this one type, since there is nothing to walk. |
| `desc` | Yes | Human-readable explanation of what this field actually means in the provider's own terms, for the audit trail — identical convention to `credit-endpoints.json`'s existing `desc`. |

### `account_blocked` / `account_blocked_negated` signals

Independent of any `windows[]` entry (checked once per probe, not per
window — FR-011's "whole account" stop is orthogonal to any single
window, data-model.md §1's `account_blocked` field). `path`/`minus`/
`value` follow the same walker rules as every other signal type; `type`
resolves to a boolean exactly the way `credit-endpoints.json`'s existing
`boolean`/`boolean_negated` types already do via `model_verify.py`'s
`_dig_bool` (research.md §3) — `account_blocked` is true when the dug
value is `true`; `account_blocked_negated` is true when the dug value is
`false` (for a provider that reports e.g. `"account_active": false`
rather than a direct "is blocked" flag). Signals of this type live in a
top-level `account_signals` list on the provider entry (sibling to
`windows`), since they describe the ACCOUNT, not any one window:

```json
"<provider_id>": {
  "url": "...", "auth": "bearer", "doc": "...",
  "account_signals": [
    { "path": ["data", "account_suspended"], "type": "account_blocked", "desc": "..." }
  ],
  "windows": [ ... ]
}
```

`account_signals` is OPTIONAL — most providers have no such field, and
its absence simply leaves `account_blocked` at its default `false`
(data-model.md §1), never treated as "unknown".

## Resolution rules (how `quota_probe.py` turns this + a live response into one Usage Window)

1. For each `windows[]` entry, walk its `signals` list once per `type`
   needed (`amount_used`, `amount_remaining`, `limit_total`,
   `percent_remaining`, `reset_at`/`reset_in_seconds`, `unit_literal`),
   taking the first present value for that type.
2. If BOTH `amount_remaining` and `limit_total` resolve, but `amount_used`
   does not, derive `amount_used = limit_total - amount_remaining`
   (and the reverse: if `amount_used` + one of the other two resolve, the
   third is derived) — the probe never REQUIRES a provider to report all
   three when two suffice, but data-model.md §4's `Usage Window` always
   carries all three in its OUTPUT regardless of which were derived vs.
   read directly (a provenance flag is not part of this feature's
   contract — it over-engineers a distinction this report does not need
   to expose to the operator).
3. If NEITHER `amount_remaining` nor `limit_total` resolves for a given
   `windows[]` entry (only `amount_used` or nothing at all present), that
   WINDOW is dropped from the result (not reported as a zero/null window)
   — a provider that tells you only what you've used, with no cap, has
   not actually told you a quota at all, and FR-009's honest-absence
   framing applies PER WINDOW, not only per whole provider. A provider
   with 2 real windows and 1 unresolvable one reports exactly 2 windows,
   never a 3rd placeholder.
4. If `percent_remaining` resolves directly from the provider, it is used
   AS-IS (never recomputed from amount_used/amount_remaining, which could
   silently contradict a provider's own more precise rounding/derivation
   rule) — this is `providers_resolve.py`'s own established principle
   ("read raw data fields, let the consumer judge thresholds") applied to
   quota the same way it already applies to catalog data.
5. `reset_in_seconds`, if present instead of `reset_at`, is converted to
   an absolute `reset_at` timestamp at PROBE time (now + N seconds) —
   `Usage Window.reset_at` (data-model.md §4) is always an absolute
   timestamp in the output; the relative-vs-absolute choice is a property
   of what the PROVIDER returns, normalized away before the result ever
   reaches rendering or `--json`.
6. If `unit` resolves from neither a `unit_literal` signal nor any
   `unit`-typed field in the response, the probe REJECTS that window
   entirely (same as rule 3) rather than emitting a window with an empty/
   guessed unit — FR-005 requires a real unit, not an invented one.

## Worked example: extending OpenRouter from today's binary credit entry

Today (`credit-endpoints.json`, binary credit-only):

```json
"openrouter": {
  "url": "https://openrouter.ai/api/v1/key",
  "auth": "bearer",
  "doc": "https://openrouter.ai/docs/api-reference/limits",
  "signals": [
    { "path": ["data", "limit_remaining"], "type": "balance", "desc": "credits left under this key's spending cap; null when the key is uncapped" },
    { "path": ["data", "is_free_tier"], "type": "boolean_negated", "desc": "false once the account has purchased credits" }
  ]
}
```

The NEW, richer `quota-endpoints.json` entry for the same real, documented
endpoint (confirmed live-shaped per OpenRouter's own docs cited above —
the same response additionally carries `data.limit` and `data.usage`):

```json
"openrouter": {
  "url": "https://openrouter.ai/api/v1/key",
  "auth": "bearer",
  "doc": "https://openrouter.ai/docs/api-reference/limits",
  "windows": [
    {
      "window": "subscription",
      "signals": [
        { "path": ["data", "limit_remaining"], "type": "amount_remaining", "desc": "credits left under this key's spending cap; null when the key is uncapped" },
        { "path": ["data", "limit"], "type": "limit_total", "desc": "the key's total spending cap; null when uncapped" },
        { "path": ["data", "usage"], "type": "amount_used", "desc": "credits consumed so far under this key" },
        { "path": [], "type": "unit_literal", "value": "credits" }
      ]
    }
  ]
}
```

(`credit-endpoints.json` itself is UNCHANGED by this feature — research.md
§3's decision keeps the two files and their consumers separate.)
