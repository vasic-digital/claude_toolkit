# Phase 0 Research: Universal Alias Quota/Limits Reporting

All unknowns from the Technical Context are resolved below. Each entry
cites what was actually inspected in this session (file + line, or a live
command run), per this project's own anti-bluff/no-guessing discipline —
nothing here is asserted from memory of "how these APIs usually work"
without a citation back to this codebase or a live check.

## 1. Subcommand naming and dispatch integration point

**Decision**: Add `quota` and `limits` as two new, fully equivalent case
labels in `claude-providers.sh`'s top-level dispatch (`scripts/
claude-providers.sh:4179-4194`), both calling the same new `cmd_quota()`
function. `kimi-providers.sh` requires **zero changes** — its dispatch
(`scripts/kimi-providers.sh`, the `SUBCMD` case block) only special-cases
`""|-h|--help` and `list|list-all|list-faulty`; everything else, including
`quota`/`limits`, already falls through its catch-all `*) exec "$ENGINE"
"$@"` and reaches `claude-providers.sh` unchanged.

**Rationale**: Both scripts already define a bash function literally named
`usage()` (`scripts/claude-providers.sh:98`, `scripts/kimi-providers.sh`'s
own `usage()`) that prints `--help` text — this is a different namespace
(a shell function name) from a dispatched subcommand string, so there is
no hard technical collision, but naming the new subcommand `usage` would
be genuinely confusing against the near-universal CLI convention that
`<tool> usage` means "show me how to invoke this." `quota` and `limits`
were confirmed, by direct inspection of both dispatch tables (`sync`,
`helixllm-export`, `list`, `list-all`, `list-faulty`, `show`, `verify`,
`sync-all-llmctl`, `remove`, `prune`, `add`, `migrate-names` in
claude-providers.sh; the same set minus a few, forwarded, in
kimi-providers.sh), to collide with nothing. `scripts/
claude-release-gate.sh:198` already uses the word "quota" informally in
its own log line ("account quota (usage limit)") for this exact concept,
confirming it is the codebase's own natural word, not an import.

**Alternatives considered**: `usage` (rejected — the collision risk this
clarification exists to avoid). A brand-new top-level script
(`claude-quota.sh`) was considered and rejected: it would duplicate
alias/provider enumeration logic `claude-providers.sh` already owns, and
the spec's FR-001 explicitly wants this reachable the same way other
subcommands are, not as a separate entrypoint.

## 2. Resolving a provider alias's base URL + API key for probing

**Decision**: `cmd_quota()` resolves each provider's `base_url`/`key`
exactly the way `cma_run_provider()` already does (`scripts/lib.sh:1394+`):
source `$pdir/$id.env` (`pdir="$HOME/.local/share/claude-multi-account/
providers"`, confirmed via `cma_providers_dir()` at `scripts/
lib.sh:3326`) to get `CMA_PROVIDER_BASE_URL`, `CMA_PROVIDER_KEYVAR`,
`CMA_PROVIDER_MODEL`, `CMA_PROVIDER_ID`, `CMA_PROVIDER_TRANSPORT`; then
resolve the real secret by indirect expansion of `CMA_PROVIDER_KEYVAR`
against the already-sourced `~/api_keys.sh` environment — the identical
pattern `scripts/lib.sh:1523`'s `eval "token=\"\${$CMA_PROVIDER_KEYVAR:-}\""`
uses, and the identical `--key-var`/`${!KEYVAR}` pattern `scripts/
providers-semantic.sh:58` uses for the same purpose.

**Rationale**: This is the ONE existing, tested way this codebase resolves
a provider's live credential without ever printing it. Reusing it exactly
avoids a second, divergent credential-resolution path that could drift out
of sync with `cma_run_provider`'s own (a real defect class this
constitution's Principle XII explicitly guards against).

**Alternatives considered**: Reading `~/api_keys.sh` directly and
re-deriving the key-var name from the catalog. Rejected — `$id.env`
already carries the resolved `CMA_PROVIDER_KEYVAR`, making a second
derivation redundant and a second place for that mapping to go stale.

## 3. Extracting usage-window data (used/remaining/limit/reset) from a provider's response

**Decision**: Extend the existing declarative balance-endpoint pattern
rather than inventing a new one. `scripts/providers/credit-endpoints.json`
(3 providers documented: `deepseek`, `openrouter`, `tokenrouter`) and
`scripts/model_verify.py`'s `_dig`/`_walk`/`_dig_bool`/
`probe_balance_endpoint` (`scripts/model_verify.py:760-831`) already walk
an ordered `signals` list of `{path, type, minus, desc}` entries against a
provider's JSON response — but today only to produce a BINARY
funded/not-funded verdict (`CREDIT_AVAILABLE`/`CREDIT_EXHAUSTED`/
`CREDIT_UNKNOWN`). A new, sibling declarative file,
`scripts/providers/quota-endpoints.json`, adds the SAME per-provider
`url`/`auth`/`doc` shape but a richer signal vocabulary for NUMERIC
usage-window extraction: `amount_used`, `amount_remaining`, `limit_total`,
`reset_at` (absolute timestamp) or `reset_in_seconds` (relative), and
`window` (`session`/`daily`/`weekly`/`subscription`, a literal string
naming which window this signal belongs to — a provider with more than one
window, e.g. OpenRouter's `limit_remaining` for the subscription cap, gets
one `signals` entry group per window, not one flat list). A NEW Python
function set (`scripts/quota_probe.py`) imports and reuses `model_verify`'s
`_dig`/`_walk` primitives directly (`from model_verify import _dig, _walk`)
rather than copying them, to guarantee the two walkers never drift apart on
the same `path` semantics.

**Concretely verified against a real provider**: OpenRouter's documented
`/v1/key` response (`scripts/providers/credit-endpoints.json:48-60`,
`doc: https://openrouter.ai/docs/api-reference/limits`) already exposes
`data.limit_remaining` as a genuine NUMBER, not a boolean — meaning
OpenRouter can report a real subscription-window remaining figure on day
one of this feature with no new endpoint research, only a richer signal
entry than the existing binary one.

**Rationale**: Reusing the walker primitives and the "ordered signals,
first present wins" design (already proven against real provider schema
drift — the code comment at `model_verify.py:792-796` documents exactly
this for OpenRouter's own null-when-uncapped case) avoids a second,
parallel JSON-extraction implementation for what is conceptually the same
problem at a different numeric granularity.

**Alternatives considered**: A single unified file merging credit-probing
and quota-probing signal specs. Rejected for this plan — credit probing
answers "is this account funded" (a model-TIER-selection input,
consumed by `providers_resolve.py:select_models`) and quota probing
answers "how much of a window is left" (an operator-facing report); they
have different consumers, different cache lifetimes, and conflating their
schemas would make BOTH harder to review. They may be unified later if a
provider's real schema makes that natural — not assumed up front.

## 4. Caching usage-window data (FR-012: disclose staleness, short-lived cache)

**Decision**: A new cache file, `~/.local/share/claude-multi-account/
providers/quota-cache.json`, mirrors `model_verify.py`'s existing
`load_credit_cache`/`save_credit_cache` (`scripts/model_verify.py:908-934`)
exactly: a `_cache_version` field (schema version, so an old cache from a
pre-fix version of this feature is never silently trusted — the same
reason the existing credit cache carries `CREDIT_CACHE_VERSION`), a
`_cached_at` epoch timestamp, and a provider-keyed `providers` map. A read
past `CREDIT_CACHE_TTL_SECONDS`'s quota analog (a new, separately-named
TTL constant — quota data is operator-facing and should default to a
SHORTER TTL than the credit cache's selection-time concern; the exact
seconds value is a `tasks.md`-level decision, not a planning-level one) is
rejected the same way an expired credit cache is — returned as empty, never
partially trusted.

**Rationale**: Identical shape to a cache this codebase already ships,
reviewed, and tested (`scripts/tests/test_provider_credit.sh` exercises
the credit cache's version/TTL gate). Re-deriving the same guarantee from
scratch would risk a subtly different (and unreviewed) staleness rule.

**Alternatives considered**: No caching at all (every invocation live-probes
every alias). Rejected per the spec's own Assumptions — a short-lived cache
is the documented default, with live-probing still available via an
explicit force-fresh flag (named in `contracts/quota-limits-cli-contract.md`).

## 5. Bounded-concurrency fan-out across many aliases (FR-017)

**Decision**: Reuse this codebase's existing bounded-concurrency
batch-probe pattern verbatim, found in `claude-providers.sh`'s
per-llmctl-profile liveness probe (`scripts/claude-providers.sh:2140-2270`):
background each alias's probe as `( ... ) </dev/null >/dev/null 2>&1 &`,
writing its result to a zero-padded-index temp file for deterministic
reassembly, batching with a PLAIN `wait` (no args) every
`CMA_QUOTA_MAX_PARALLEL_PROBES` (default matching the existing
`CMA_LLMCTL_MAX_PARALLEL_PROBES` default of 8) backgrounded jobs — never
`wait -n`, because this project targets macOS's stock bash 3.2 as a real
platform (`wait -n` needs bash ≥4.3; documented at `claude-providers.sh:2149-2152`
and this repo's own CLAUDE.md portability notes) — and each individual
probe uses `curl -sf --max-time "$t"` for its own bounded per-provider
timeout, exactly as the llmctl probe does at `claude-providers.sh:2169`.
The `</dev/null >/dev/null 2>&1` on the subshell GROUP (not merely inside
it) is load-bearing for the SAME documented reason
(`claude-providers.sh:2225-2240`): a backgrounded job that inherits the
outer command-substitution's stdout file descriptor and never explicitly
detaches it hangs the whole script at exit, waiting for EOF on a pipe
whose write end the probe still implicitly holds open.

**Rationale**: This exact bug class (background-job fd-1 inheritance
hanging the script) was already found, root-caused, and fixed once in
this codebase for an almost-identical fan-out probe. Reusing the pattern
verbatim is not just convenient — it is the only way to be certain this
feature does not reintroduce a bug this project has already paid to fix.

**Alternatives considered**: `xargs -P` for parallelism. Rejected —
`claude-providers.sh` has zero existing `xargs -P` usage, and introducing
a second concurrency idiom alongside the proven one (for no behavioral
benefit) raises review surface without reducing risk.

## 6. Color rendering, NO_COLOR, and `--json`

**Decision**: `scripts/lib.sh` gains a small new set of helpers alongside
the existing log-level colorizers (`cma_log`/`cma_warn`/`cma_err`,
`scripts/lib.sh:47-50`, which use raw `\033[36m`/`\033[33m`/`\033[31m`
ANSI codes with no NO_COLOR/isatty gating today): a severity-to-color
mapper for the four quota/limits states (green/yellow/red/limit-exceeded)
and a single gate function deciding whether to emit color at all — color
is emitted only when stdout is a terminal (`[[ -t 1 ]]`) AND the `NO_COLOR`
environment variable (checked for ANY non-empty value, the de facto
cross-tool standard this project does not yet implement anywhere but
should adopt here) is unset AND `--json` was not requested (FR-016's JSON
output carries the severity as a plain string field, never ANSI codes, by
FR-016's own text).

**Rationale**: No existing convention in this codebase to extend (log-level
colors are unconditional today), so this is new, minimal, standard-following
design rather than an extension of prior art — confirmed by grep across
every `*.sh` in `scripts/` finding zero `NO_COLOR`/`isatty`/`[[ -t 1 ]]`
hits before this feature.

**Alternatives considered**: A `--color=always|auto|never` flag (the
`ls`/`grep` convention). Not rejected outright — left as an additive
option `contracts/quota-limits-cli-contract.md` may specify alongside the
NO_COLOR/isatty default, since it costs little and some operators will
want an explicit override.

## 7. Native account (`claudeN`/`kimiN`) live usage-percentage data

**Decision**: For this feature's first version, native accounts are
reported through the SAME honest "not reported by provider" status
(FR-009) already defined for an API-key provider with no documented
balance endpoint — optionally annotated with the account's cached
rate-limit TIER NAME as informational context (e.g. "not reported by
provider (plan tier: default_claude_max_20x)"), never as a percentage or
color. Discovering a genuine, safely-callable live usage endpoint for
native OAuth accounts is flagged as a recommended, separately-tracked
research spike for `tasks.md` (and the originating request's own "full
LIVE testing" phase is the natural place to run it), not resolved by
invented guesswork here.

**What was actually checked, live, in this session** (not assumed):
- `claude --help` has no `Commands:` section and no usage/billing/status/
  cost subcommand; directly probing `claude usage --help`, `claude billing
  --help`, `claude account --help`, `claude status --help`, and `claude
  cost --help` each silently fell through to the generic top-level help,
  confirming none is a recognized subcommand on the installed version.
- `kimi --help` likewise lists no usage/billing/quota-related flag or
  subcommand.
- `~/.claude.json` was recursively scanned for any key containing
  `usage`/`limit`/`quota`/`rate`/`budget`/`reset`/`window`/`remaining`.
  Real hits exist, but none is a live remaining-quota percentage:
  `oauthAccount.organizationRateLimitTier` ("default_claude_max_20x", a
  PLAN NAME, not a used/remaining figure), `oauthAccount.hasExtraUsageEnabled`
  / `cachedExtraUsageDisabledReason` (whether pay-as-you-go overage is
  available at all, and why not — a boolean/reason pair, not a percentage),
  `passesEligibilityCache.<uuid>.{remaining_passes,limit}` (a narrow,
  separate "model access pass" feature with real integers, not the
  general weekly/session token quota the spec asks about), and a large set
  of `cachedGrowthBookFeatures.*` fields that are this account's A/B-test
  FEATURE-GATING configuration (e.g. `tengu_lapis_anchor_budget`), not
  personal usage data at all.
- No session JSONL transcript under `~/.claude/projects/` was found to
  contain Anthropic's documented `anthropic-ratelimit-*` response headers
  (a `grep -rl` across this user's own transcripts returned nothing),
  so there is no local artifact of a real rate-limit header ever having
  been captured to parse retroactively either.

**Rationale**: Per this constitution's Principle II (no guessing — state
what is confirmed, not what "should" exist) and the spec's own Assumption
that a provider/account with no genuine usage API must be reported
honestly rather than estimated, inventing an unverified endpoint URL at
plan time would be exactly the kind of bluff this feature exists to
prevent on provider aliases — doing it for native accounts would be the
same defect in a different place. The TIER NAME is real, already cached,
and IS useful context (it tells the operator what subscription they are
on even without a live percentage), so surfacing it is a genuine, honest,
low-risk addition — not a consolation prize.

**Alternatives considered**: Deriving an ESTIMATED session-window usage
from this toolkit's own local session JSONL transcripts (Claude Code logs
real per-turn input/output token counts locally). Rejected as the PRIMARY
source for native accounts — a local tally reflects only THIS machine's
THIS CLI's consumption, not the account's true server-side usage (which
also counts other devices, the web UI, and direct API usage outside
Claude Code), so presenting it as the account's remaining quota would
itself be the fabrication FR-009 forbids. It remains available as a
clearly-labeled supplementary figure (e.g. "local session tokens observed:
N — not the account's authoritative quota") if `tasks.md` chooses to add
it, but it must never replace or be confused with the honest
"not reported by provider" status.

## 8. Test-mocking convention for the new Python probing code

**Decision**: `test_quota_probe.sh` unit-tests `quota_probe.py`'s
signal-walking functions by monkeypatching `model_verify.http_get_json`
(and, by extension, whatever thin wrapper `quota_probe.py` calls) at the
MODULE level inside an embedded `python3 -c` block — the exact, already-
proven pattern `scripts/tests/test_provider_credit.sh:609-610` uses
(`mv.http_get_json = lambda *a, **k: (status, body)`), never a real
network call in a unit test, per constitution Principle V.

**Rationale**: An existing, working, reviewed convention for exactly this
class of test already exists in this codebase; using a different mocking
library or approach would add a second convention for the same problem
with no benefit.

## 9. Documentation surfaces to update (FR-015)

**Decision**: `docs/Provider_Aliases_User_Guide.md` (+ its `.html`/`.docx`/
`.pdf` re-exports via `scripts/claude-export-docs.sh`), `docs/
Provider_FAQ.md`, `docs/Provider_Verification_Guide.md` (cross-reference
only — quota/limits is a distinct concern from verification, not merged
into that guide), `docs/diagrams/provider-aliases.md` (cross-reference) +
a new `docs/diagrams/quota-limits-flow.mmd`/`.svg` diagram pair (matching
this project's existing `.mmd`+`.svg` diagram convention, e.g. `docs/
diagrams/llmctl-detection-flow.mmd`/`.svg`), and `README.md`'s "📋 Daily
commands" section (`README.md:122`) — all confirmed, by direct inspection,
to be the existing surfaces that already document `claude-providers`'/
`kimi-providers`' other subcommands.

**Rationale**: FR-015 requires updating every EXISTING surface that
already documents these subcommands, not inventing a parallel doc tree;
these are that set, confirmed present in this checkout, not assumed from
a typical project layout.
