#!/usr/bin/env python3
r"""providers_resolve.py — the dynamic brain of claude-providers.

Given the set of API-key variable NAMES the user has (never values), the
cached models.dev catalog, and two small editable config files, resolve each
LLM key into a concrete provider record: alias name, base URL, transport,
strong + fast model. Nothing about providers/models is hardcoded — every value
is derived from models.dev data, with `key-aliases.json` (name normalization)
and `overrides.json` (manual pins) as the only human inputs.

This module is pure and offline: it reads the models.dev cache from disk, it
does not fetch. The bash wrapper (claude-providers.sh) handles fetching/caching
and consumes this resolver's JSON output.

Usage:
  providers_resolve.py \
    --models-dev PATH \            # cached models.dev api.json
    --keys "A_API_KEY,B_API_KEY" \ # present key var NAMES (comma-sep)
    [--key-aliases PATH] [--overrides PATH] \
    [--only PROVIDER_ID]           # restrict output to one provider

Output: JSON array of records on stdout. Each record:
  {key_var, classification, provider_id, alias, base_url, transport,
   strong_model, fast_model, context_limit, max_output, status, reason,
   credit_status, credit_signal, credit_detail, model_policy, model_tier,
   selection_reason}
context_limit: input context window tokens, from the strong model's limit.context.
max_output:    maximum output tokens, carved out of context_limit.
status ∈ {resolved, unmapped, skipped}.

TOKEN-GUARD CONTRACT. For every `resolved` record both limits are strictly
positive integers (never bools, never floats) and `max_output < context_limit`.
This holds for all 5696 rows of the live models.dev catalog, and the test suite
sweeps every one of them. Neither is ever null and neither is ever a number
the other does not support, because an empty pair is not "honest, we don't
know" — it makes the launch wrapper export NO guard, and Claude Code's own
default for an unguarded custom model is 128000 output tokens against a window
nobody measured. A model whose limits the catalog cannot state therefore falls
back to a conservative derived pair (see UNKNOWN_MODEL_CONTEXT) rather than to
silence — and so does a context that is DERIVED below viability rather than
merely absent: a corroboration correction or a per-provider estimate that lands
too small to carve any positive output cap recovers the same conservative pair
instead of emitting (ctx, None). Operator overrides are held to the same invariant: a pin outranks the
credit rule and the model ranking, but not `input + output <= context`, which
is a property of the endpoint rather than a preference.

CREDIT-AWARE MODEL SELECTION (the operator's mandatory rule)
------------------------------------------------------------
"If the account has purchased tokens, use the STRONGEST PAID model; if it has
no credit, use the STRONGEST FREE model it can use."

This module never probes a balance — it is pure and offline. Credit status is
read from a schema-versioned, TTL'd cache (`--credits PATH`, written by
`model_verify.py --credit-probe`) and can be pinned per provider in
overrides.json. The resulting decision is recorded in the record itself
(credit_status / credit_signal / model_tier / selection_reason) so an operator
can audit WHY a model was chosen instead of trusting magic.

Precedence, highest first:
  1. `strong_model` / `fast_model` pins in overrides.json — a human decision
     always wins, and the credit policy never second-guesses it.
  2. `model_policy` in overrides.json: "free" forces free-only, "paid" allows
     paid, "auto" (default) defers to credit status.
  3. `credit` pin in overrides.json (available/exhausted/unknown).
  4. The credit cache entry for this provider.
  5. Nothing known -> credit_status "unknown" -> treated as NO credit, because
     spending real money on an unverified assumption is the worse error.

Tier preference is an ordering, not a hard filter: if the preferred tier is
empty we fall through to the next and say so in selection_reason. A provider
whose catalog carries no pricing at all yields tier "unknown" — reported
honestly rather than guessed as free.
"""
import argparse
import json
import re
import sys
import time

# --- classification of key variable NAMES (not values) --------------------
# VCS/infra keys are never turned into provider aliases. These patterns are
# intentionally conservative and live here (not models.dev) because "is this
# key a model backend or a git token" is a host-policy decision, not catalog
# data.
VCS_PATTERNS = (
    re.compile(r"^GITHUB(_|$)"), re.compile(r"^GITLAB_"),
    re.compile(r"^GITFLIC_"), re.compile(r"^GITVERSE_"),
)
INFRA_PATTERNS = (
    # FIRE?BASE matches both the correct "FIREBASE" and the keys-file typo
    # "FIRBASE". (The earlier ^FIR?BASE made the E optional in the wrong place
    # and failed to match a correctly-spelled FIREBASE_API_KEY.)
    re.compile(r"^FIRE?BASE"), re.compile(r"^CLOUDFLARE"),
    re.compile(r"^MODAL"),
)
# GITHUB_MODELS_* is an LLM backend despite the GITHUB prefix — exempt it.
VCS_EXEMPT = (re.compile(r"^GITHUB_MODELS"),)


def classify(key_var):
    for p in VCS_EXEMPT:
        if p.search(key_var):
            return "llm"
    for p in VCS_PATTERNS:
        if p.search(key_var):
            return "vcs"
    for p in INFRA_PATTERNS:
        if p.search(key_var):
            return "infra"
    return "llm"


def find_provider_by_env(catalog, key_var):
    """Match a key var name against each provider's models.dev `env` array."""
    for pid, p in catalog.items():
        env = p.get("env") or []
        if key_var in env:
            return pid
    return None


def transport_for(provider):
    """native iff the provider speaks the Anthropic API natively."""
    npm = (provider.get("npm") or "").lower()
    api = (provider.get("api") or "").lower()
    if npm.endswith("anthropic") or api.rstrip("/").endswith("/anthropic"):
        return "native"
    return "router"


def _num(x):
    return x if isinstance(x, (int, float)) else None


def _dget(obj, key):
    """`obj[key]` when obj is a dict, else None.

    models.dev is REMOTE input. A malformed row whose `limit` or `cost` is a
    JSON list rather than an object used to crash the whole sync with an
    AttributeError, because `model.get("limit") or {}` keeps a truthy list and
    the next `.get` explodes. One bad row upstream must degrade to "this row
    states no limits", never to a traceback out of `claude-providers sync`.
    """
    return obj.get(key) if isinstance(obj, dict) else None


def _pos_int(x):
    """A strictly-positive integer, or None. Bools and floats are NOT integers.

    `_num` alone is not a validator: `isinstance(True, int)` is True in Python,
    so a typo'd `"context_limit": true` in overrides.json sailed through as the
    integer 1, carved to no output cap at all, and the launch wrapper then
    exported NEITHER guard — the exact fail-open this module exists to close.
    `-1`, `0` and `50000.5` reached the same place by different routes.

    A clean digit STRING is accepted and coerced: `"200000"` is unambiguous,
    and JSON-by-hand produces it constantly. Everything else is rejected so the
    caller can say WHY in selection_reason instead of dropping it in silence.
    """
    if isinstance(x, bool):
        return None
    if isinstance(x, int):
        return x if x > 0 else None
    if isinstance(x, str) and x.strip().isdigit():
        v = int(x.strip())
        return v if v > 0 else None
    return None


# --- token-budget derivation ----------------------------------------------
# The physical invariant every request must satisfy:
#
#     input_tokens + max_output_tokens <= context_window
#
# The output cap is CARVED OUT of the context window; it is not an independent
# quantity. Nothing upstream enforces that, so this module must.
#
# Claude Code hard-caps custom-model output at 128000 tokens. Critically, that
# is also the value it uses when NO cap is exported — so "we don't know the
# output limit, leave it unset" is not a safe fallback, it is a request for
# 128000 output tokens. On a 262144-context endpoint carrying Claude Code's
# ~137k system-prompt + tool-schema floor, 128000 overflows. The cap must
# therefore ALWAYS be derived whenever the context is known.
CLI_MAX_OUTPUT_TOKENS = 128000

# Claude Code's per-request input floor, before a single turn of conversation:
# the system prompt, tool schemas, skills and plugin metadata. Measured on the
# live 400 that motivated this guard (openrouter, v1.24.0 proof run):
#   "you requested about 265483 tokens (33796 of text input,
#    103687 of tool input, 128000 in the output)"
# 33796 + 103687 = 137483 of input before any user content. Rounded up to leave
# room for a few turns of actual conversation.
CLAUDE_CODE_INPUT_FLOOR = 160000

# Never emit an output cap below this; a smaller one makes the alias useless.
# Reached only when a model's context cannot host Claude Code's input floor at
# all, in which case a small honest cap beats a large impossible one.
MIN_SAFE_OUTPUT = 8192

# Fallback window for a model whose context this catalog cannot state — an
# operator pin naming a model models.dev has never heard of (inference's
# `glm-5.2`), or a catalogued row carrying no `limit.context` at all.
#
# "Unknown" is NOT a safe thing to emit. An empty CMA_PROVIDER_CONTEXT_LIMIT
# plus an empty CMA_PROVIDER_MAX_OUTPUT makes the launch wrapper export NEITHER
# guard, and Claude Code's no-cap default is 128000 output tokens against a
# window nobody measured. That is the same fail-open shape as the large-context
# hole above, just reached from the other end, so unknown must resolve to a
# conservative *number*, never to silence.
#
# 128000 is measured, not invented: of the 4544 tool-call-capable models in the
# live models.dev cache, 93.95% publish a context of at least 128000 (p10 =
# 128000, i.e. 128000 IS the catalog-wide 10th percentile). Assuming it
# therefore UNDERSTATES the real window for ~94% of the models an alias could
# plausibly be pinned to — which costs capability — and OVERSTATES it for the
# remaining ~6%, which is the direction that kills the alias with a 400.
#
# That ~6% tail is real and must be narrowed by the provider's own evidence,
# not waved away. It used to be bounded by the provider's LARGEST published
# window, which is almost no bound at all: provider maxes are huge (openrouter's
# is 10,000,000, kilo's and poe's 2,000,000), so pinning an uncatalogued 32k
# model on openrouter emitted 128000, the wrapper exported a ~119808 input
# window, and Claude Code packed ~120k into a 32k endpoint. Measured as "how
# often does the mechanism pull the fallback below the 128000 default": the bare
# ceiling (published = pool[-1]) does so for only 3 of 167 providers (1.8%) —
# inference 125000, llmtr 16384, morph 32000 — while
# `_conservative_unknown_context`, which uses the provider's own 10th percentile
# (the same statistic that produced the 128000 above) instead, does so for 32 of
# 167 (19.2%). Both counts are unaffected by the median clamp: the ceiling reads
# no floor term at all, and the clamp moves only two estimates (inference
# 65536->16000, atomic-chat 65536->32768), both already below 128000 either way.
# (Whether pool[-1] is the term that DECIDES the returned value is a different
# question, answering 1 of 167 under the shipped clamp and 2 before it — the
# reading the old "2 of 167" was computed under.)
UNKNOWN_MODEL_CONTEXT = 128000

# Floor under the per-provider conservative estimate. "Conservative" has to
# stay usable to mean anything: poe's raw 10th-percentile tool-call context is
# 480 tokens (it serves image/audio endpoints that advertise tool_call), and a
# 480-token window would not "cost capability", it would be unable to hold
# Claude Code's own system prompt. 65536 is the largest floor under which every
# provider the percentile tightens still lands on a workable coding window.
MIN_USABLE_UNKNOWN_CONTEXT = 65536

# Smallest pool on which the per-provider median is allowed to clamp the floor
# above. Three, for the same arithmetic reason MIN_CORROBORATING_PROVIDERS is
# three: at n=2 the lower median is the minimum, so one narrow row would set
# the estimate single-handedly.
MEDIAN_CLAMP_MIN_POOL = 3


def _free_output_anomaly(model, siblings):
    """SUSPICION only: a `:free` record claiming a bigger output budget than
    its own paid sibling.

    A `:free` variant is a *weaker* offering of the same weights — the provider
    throttles it, so an output budget above the paid sibling's is not credible
    and something in the record is mislabelled. Live catalog, both from
    openrouter itself:

        nvidia/nemotron-3-super-120b-a12b       -> {context:1000000, output: 16384}
        nvidia/nemotron-3-super-120b-a12b:free  -> {context:1000000, output:262144}

    What this function must NOT do is decide WHICH field is wrong. It used to:
    it read the offending output value as the record's real context, and on the
    live catalog that inference was a coin flip. Of the 10 rows it fires on, 4
    would shrink the context and 2 of those 4 were false positives:

        nvidia/nemotron-3-ultra-550b-a55b:free {1000000, 65536} -> ctx 65536
            but nvidia's OWN record for that model is {1000000, 65536} and
            vercel's is {1000000, 65000}; 65536 is a genuine output budget.
            934,464 tokens (93.4%) destroyed.
        google/gemma-4-26b-a4b-it:free {262144, 32768} -> ctx 32768
            but 32768 is the most commonly published output for this model
            (8 of 16 catalog records) and 14 of those 16 publish
            context=262144. 229,376 tokens (87.5%) destroyed, output dropping
            to the 8192 floor — near-unusable for agentic work.

    The governing asymmetry (understating a window costs capability;
    overstating kills the alias with a 400) does not license this: an 8192
    output cap on a coding model is its own kind of dead alias. So the
    suspicion is raised here and ADJUDICATED by cross-provider corroboration
    in `_corroborated_context`, which resolves all four firings correctly.

    Both output values are read through `_pos_int`, NOT `_num`. `_num` accepts
    floats and bare bools, so a record carrying `"output": 262144.7` — a value
    this module elsewhere declares unusable and reports as "not a usable cap;
    treated as unknown" — used to raise the suspicion anyway and, on the live
    shape, drag a corroborated context from 1,000,000 down to 32,768 (96.7% of
    the window) on the strength of a number the module had already rejected.
    A value not good enough to BE a cap is not good enough to convict a context.

    Returns the suspicious output value, or None.
    """
    if not siblings:
        return None
    mid = str(model.get("id") or "")
    mine = _pos_int(_dget(model.get("limit"), "output"))
    if mine is None:
        return None
    for sfx in FREE_ID_SUFFIXES:
        if not mid.endswith(sfx):
            continue
        sib = siblings.get(mid[: -len(sfx)])
        if not isinstance(sib, dict):
            continue
        theirs = _pos_int(_dget(sib.get("limit"), "output"))
        if theirs is not None and mine > theirs:
            return mine
    return None


def normalize_model_key(mid):
    """Fold the spellings different providers use for the SAME model together.

    The catalog holds one record per (provider, model) pair and providers do
    not agree on the id: `nvidia/nemotron-3-super-120b-a12b:free` (openrouter),
    `nvidia/nemotron-3-super-120b-a12b` (nvidia, kilo, nebius, vercel...),
    `nemotron-3-super-120b-a12b` (cortecs), `@cf/google/gemma-4-26b-a4b-it`
    (cloudflare), `google/gemma-4-26B-A4B-it` (deepinfra, case-shifted),
    `alibaba/qwen3-coder` (vercel, re-vendored). Dropping the `:free` suffix
    and the vendor prefix, then case-folding, unifies all of them.

    The collision this creates is NOT hypothetical, and is why the key alone is
    never sufficient. Measured on the live cache: 392 normalized keys span more
    than one distinct vendor prefix and 257 of those disagree on context.
    `auto` merges four routers' meta-models (32000 … 2000000);
    `mistral-7b-instruct-v0.1` merges a 2824-token Cloudflare deployment with
    mistralai's 128000; `deepseek-r1` folds eight different contexts across
    `deepseek`, `deepseek-ai`, `Pro/deepseek-ai` and `public`. Left unguarded,
    an `alpha/turbo` with a genuine 1,000,000 window is sentenced by entirely
    unrelated `beta/turbo` and `gamma/turbo` rows.

    So the key is paired with `vendor_of` below: a corroborating row must agree
    on the VENDOR too (or omit it), which keeps cortecs's bare
    `nemotron-3-super-120b-a12b` voting alongside openrouter's
    `nvidia/nemotron-3-super-120b-a12b` while refusing mistralai-vs-cloudflare.
    """
    m = str(mid or "")
    for sfx in FREE_ID_SUFFIXES:
        if m.endswith(sfx):
            m = m[: -len(sfx)]
    return m.rsplit("/", 1)[-1].strip().lower()


def vendor_of(mid):
    """The vendor prefix `normalize_model_key` discards, normalized.

    Only the segment immediately before the model name counts, so cloudflare's
    `workers-ai/@cf/mistral/mistral-7b-instruct-v0.1` reduces to `mistral` and
    openrouter's `mistralai/mistral-7b-instruct-v0.1` to `mistralai` — different
    vendors, correctly kept apart. `@` is stripped because cloudflare writes
    `@cf/google/...` where everyone else writes `google/...`.

    Returns "" for an unprefixed id, which is treated as "vendor unstated" and
    therefore compatible with any vendor rather than as a vendor of its own.
    """
    m = str(mid or "")
    for sfx in FREE_ID_SUFFIXES:
        if m.endswith(sfx):
            m = m[: -len(sfx)]
    if "/" not in m:
        return ""
    return m.rsplit("/", 1)[0].rsplit("/", 1)[-1].strip().lower().lstrip("@")


def build_context_corroboration(catalog):
    """{normalized key: [(provider_id, vendor, context), ...]} over the catalog.

    Built once per run and threaded into derive_limits so the per-model lookup
    is a dict hit rather than a rescan. The provider id rides along so the
    record under adjudication can be excluded from its own tally, and the
    vendor so unrelated models that share a last segment can be excluded too.
    """
    index = {}
    for pid, provider in (catalog or {}).items():
        models = (provider or {}).get("models")
        if not isinstance(models, dict):
            continue
        for mid, m in models.items():
            if not isinstance(m, dict):
                continue
            ctx = _pos_int(_dget(m.get("limit"), "context"))
            if ctx is None:
                continue
            index.setdefault(normalize_model_key(mid), []).append(
                (pid, vendor_of(mid), ctx))
    return index


# How many providers OTHER THAN the accused must publish a context before their
# lower median is allowed to overrule the record under adjudication.
#
# Three, not two, and the reason is arithmetic rather than taste. The value
# returned is the lower median `vals[(n-1)//2]`, so the corrected context is a
# number at least ceil(n/2) of the n independents publish at or below. At n=3
# that is 2 of 3 — an actual majority. At n=2 the lower median IS the minimum,
# so a single peer decides the outcome alone, which is precisely the evidence
# the old single-record detector had and which was measured to be right about
# half the time. Requiring 3 is what makes "outvote" mean outvote.
MIN_CORROBORATING_PROVIDERS = 3


def _corroborated_context(mid, corroboration, accused_pid=None):
    """Whether OTHER providers contradict this record's claimed context.

    Be precise about what this can and cannot establish, because the mechanism
    fails in both directions if it is read as more than it is.

    It CANNOT establish "the model's real context". There is no such quantity:
    the catalog holds one record per (provider, model) PAIR and each deployment
    genuinely has its own window. `llama-3.2-3b-instruct` is served at 16000 by
    inference, 32768 by nvidia/novita/llmgateway, 80000 by cloudflare and
    131072 by openrouter/nano-gpt/pioneer — none of those is wrong, and the
    median of that pool is a fact about the population of hosts, not about any
    one endpoint.

    It equally CANNOT establish the legitimate case the `:free` anomaly is
    named for — a genuinely throttled free tier. Every peer record describes
    the PAID tier, so a `:free` row that really is narrowed will be corroborated
    at the paid value and left alone. This mechanism is structurally blind to
    free-tier throttling and must never be described as catching it.

    What it CAN establish is narrow and is the only thing it is used for: that a
    context claim is not credible AS DATA. When a record is already
    self-inconsistent (see `_free_output_anomaly`) AND a majority of independent
    providers publish materially less, the claim is far more likely a catalog
    error than a uniquely wide deployment. That is a plausibility ceiling drawn
    from peers, not a measurement.

    Accordingly: one vote per provider, the accused provider EXCLUDED from its
    own trial, corroborators restricted to the same vendor, and the lower median
    of at least MIN_CORROBORATING_PROVIDERS independents returned — or None.

    The exclusion is load-bearing, not hygiene. Indexing every row including the
    one under adjudication let {accused, one peer} satisfy a threshold of 2, and
    with exactly two voters the lower median is the MINIMUM, so the single peer
    won outright: a provider publishing a genuine 1,000,000 free row was
    sentenced to 8192 by one obscure peer's truncated deployment — 99.2% of the
    window destroyed — under a note that claimed two independent providers had
    agreed. Nothing had agreed with anything.

    Measured against the live catalog this settles every row the anomaly flags:

      nemotron-3-super-120b-a12b  7 independents, median 262144 < openrouter's
          1000000 -> corrected (kilo, nvidia, cortecs all say 262144, and the
          live 400 said "maximum context length is 262144 tokens")
      qwen3-coder                 5 independents, median 262144 < openrouter's
          1048576 -> corrected
      nemotron-3-ultra-550b-a55b  4 independents, median 1000000 -> LEFT ALONE
          (nvidia and vercel corroborate openrouter's own context)
      gemma-4-26b-a4b-it         14 independents, median 262144 -> LEFT ALONE
    """
    accused_vendor = vendor_of(mid)
    seen = {}
    for pid, vendor, ctx in (corroboration or {}).get(normalize_model_key(mid), ()):
        # The accused does not vote in its own trial.
        if accused_pid is not None and pid == accused_pid:
            continue
        # A bare id states no vendor and corroborates anything; two STATED and
        # different vendors are different models that happen to share a suffix.
        #
        # ASYMMETRY, DOCUMENTED NOT FORCED: this gate is silent whenever EITHER
        # side is bare. When the VOTER is bare it corroborates any vendor — the
        # load-bearing, tested case (cortecs's bare `nemotron-...` voting for
        # openrouter's `nvidia/nemotron-...`; see I3_BARE_STILL_VOTES). The flip
        # side is that when the ACCUSED is bare (`accused_vendor == ""`) it is
        # voted on by EVERY vendor, because a bare accused states no vendor to
        # match against. This is not cleanly closable: the only tightening
        # available — "a bare accused accepts only bare voters" — would break
        # the exact symmetric case above (a bare accused legitimately
        # corroborated by a vendored peer), since the governing rule is "bare ==
        # vendor-unstated == compatible with any vendor" and that rule has to
        # cut both ways or it is not a rule about vendor identity. The bare
        # accused is NOT unguarded: it is still bounded by the same normalized
        # key, one-vote-per-provider, self-exclusion, and the
        # MIN_CORROBORATING_PROVIDERS lower-median. It costs 0 violations on the
        # live catalog (no bare `:free` id there is mis-corroborated), so
        # tightening it would trade a tested guarantee for a hypothetical one.
        if vendor and accused_vendor and vendor != accused_vendor:
            continue
        # One vote per provider: a provider publishing both the paid and the
        # `:free` row must not get to vote twice for its own number.
        if pid not in seen or ctx < seen[pid]:
            seen[pid] = ctx
    if len(seen) < MIN_CORROBORATING_PROVIDERS:
        return None
    vals = sorted(seen.values())
    return vals[(len(vals) - 1) // 2]


def _conservative_unknown_context(siblings):
    """A conservative context to assume for a model this catalog cannot state.

    Evidence: the windows this provider publishes for models it DOES document.
    The statistic is the 10th percentile — deliberately the same one that
    produced UNKNOWN_MODEL_CONTEXT itself from the catalog as a whole, applied
    to one provider instead of all of them — restricted to tool-call-capable
    models, because that is the only kind of model an alias can actually use
    and it excludes the embedding/ASR rows whose 4000-token windows would drag
    the estimate into uselessness. A provider with no tool-call rows at all
    falls back to all of its rows.

    Three guards keep it honest in both directions:
      * never above the provider's widest published window — the old ceiling,
        which is still correct, just far too loose on its own (measured as how
        often it pulls the fallback below the 128000 default, it does so for 3
        of 167 providers; the percentile for 32);
      * never below MIN_USABLE_UNKNOWN_CONTEXT — conservative must stay usable;
      * but never let that floor RAISE the estimate above the provider's own
        median, because a floor that overstates is the failure this module
        exists to prevent.

    That last guard is the one that was missing. The 65536 floor was clamped
    only by the provider MAXIMUM, which almost never binds, so for 5 of 167
    providers the unclamped floor sat above that provider's own median context
    — predicate: MIN_USABLE_UNKNOWN_CONTEXT > the lower median of the provider's
    tool-call contexts (atomic-chat, inference, llmtr, morph, subconscious); by
    the stricter reading "more than half that provider's rows fall below the
    floor" it is 4. Worst on `inference`, the very provider cited as the
    motivating case for the unknown-model fallback: p10 4000, median 16000, yet
    the estimate came out 65536 with 6 of its 8 tool-call rows below that. An
    unknown model pinned there exported a ~61440 input window against an
    endpoint that may serve 4000, which 400s on the first request. Clamping the
    floor at the median means the estimate can only be raised to a width at
    least half the provider's own catalog demonstrably honours, and changes the
    returned estimate for 2 of 167 providers: `inference` now yields 16000 and
    `atomic-chat` 32768, while poe, pioneer, nebius and evroc — whose medians
    are all comfortably above — keep the full 65536.

    The median clamp needs at least MEDIAN_CLAMP_MIN_POOL rows to apply, for
    exactly the arithmetic reason MIN_CORROBORATING_PROVIDERS is 3: on a
    two-element pool the lower median IS the minimum, so a single narrow row
    would decide the estimate by itself. That is not a distribution, and
    honouring it would drag a provider serving {480 image, 2000000 flagship}
    down to 480 — a window that cannot hold Claude Code's own system prompt,
    which is the unusability the floor exists to prevent. Below the threshold
    the floor stands unclamped and the provider maximum remains the only
    ceiling, which is the pre-existing behaviour.

    Returns None when the provider publishes no context at all.
    """
    tool_call, every = [], []
    for m in (siblings or {}).values():
        if not isinstance(m, dict):
            continue
        c = _pos_int(_dget(m.get("limit"), "context"))
        if c is None:
            continue
        every.append(c)
        if m.get("tool_call"):
            tool_call.append(c)
    pool = sorted(tool_call or every)
    if not pool:
        return None
    p10 = pool[int(0.10 * len(pool))]
    floor = MIN_USABLE_UNKNOWN_CONTEXT
    if len(pool) >= MEDIAN_CLAMP_MIN_POOL:
        floor = min(floor, pool[(len(pool) - 1) // 2])
    return min(pool[-1], max(p10, floor))


def _carve_output(ctx, out):
    """Carve a valid output cap out of a known context. Returns (out, notes).

    The single place the invariant `out < ctx` is enforced, shared by the
    catalog path and the operator-override path so a hand-pinned pair is held
    to the same physics as a derived one.

    This carve is what fixes the 1099 catalog rows whose `limit.output` is >=
    their `limit.context`. It needs no separate detector to do it: `cap` is
    strictly below `ctx` on every branch below, so for any `out >= ctx` the
    `min(out, cap)` on the way out already collapses to `cap` — the same value
    an absent output would have produced. (A detector that nulled such an
    output first therefore changed the result on 0 of 5696 live rows, and was
    removed rather than left as untested code the docs credited with work it
    did not do.)
    """
    notes = []
    cap = min(ctx - CLAUDE_CODE_INPUT_FLOOR, CLI_MAX_OUTPUT_TOKENS)
    if cap < MIN_SAFE_OUTPUT:
        notes.append(
            "context=%d cannot host Claude Code's %d input floor; output "
            "floored at %d" % (ctx, CLAUDE_CODE_INPUT_FLOOR, MIN_SAFE_OUTPUT))
        cap = MIN_SAFE_OUTPUT
    if cap >= ctx:
        # The floor must never breach the invariant it exists to protect. 243
        # live catalog rows (189 distinct model ids) land here — every row whose
        # context is <= MIN_SAFE_OUTPUT (mistral/open-mistral-7b at 8000/8000,
        # evroc's 448-token whisper rows): the 8192 floor would sit at or above
        # the whole window, which is precisely the overstatement that 400s.
        # Half the window is the largest cap that provably leaves room for
        # input.
        cap = ctx // 2
        notes.append(
            "output floor %d does not fit context=%d; cap halved to %d"
            % (MIN_SAFE_OUTPUT, ctx, cap))
    out = cap if out is None else min(out, cap)
    if out < 1:
        # A window too small to carve anything from. Say nothing rather than
        # emit a cap that violates the invariant.
        out, _ = None, notes.append(
            "context=%d leaves no room for any output cap" % ctx)
    return out, notes


# The smallest context from which `_carve_output` can carve any positive cap.
# Below it the derived pair is (ctx, None) — a context with NO output guard,
# which is the exact fail-open shape this module exists to close, and worse
# here than anywhere else because the derived pair is what the override path
# FALLS BACK TO when it refuses an operator's value. `context: 1` was the only
# live-reachable input that produced it (0 catalog rows, but overrides.json is
# hand-edited). A window that cannot host even one output token is not a small
# window, it is a hole, and is treated exactly like `context: 0`: unknown.
# 2 is the arithmetic bound — at ctx=2 the halving branch yields a cap of 1.
MIN_VIABLE_CONTEXT = 2


def derive_limits(model, siblings=None, corroboration=None, provider_id=None):
    """Derive (context_limit, max_output, note) that satisfy the invariant.

    models.dev stores limits per (provider, model) PAIR, and the records are
    not internally consistent. 1099 of 5696 catalogued models report
    `limit.output >= limit.context` (counted over raw published values,
    including the 104 rows whose context is 0 — those are later treated as
    unknown rather than as a cap of zero, which is why the both-fields-positive
    count is 995), which is physically impossible — the output budget is carved
    out of the context, so it is strictly smaller. Those rows need no detector:
    `_carve_output` already collapses any such output to the same cap an absent
    one would produce.

    What DOES need adjudicating is the opposite mislabel — a record whose
    CONTEXT is fiction. `_free_output_anomaly` raises the suspicion (a `:free`
    row claiming a larger output budget than its own paid sibling) and
    `_corroborated_context` settles it against what every other provider
    publishes for the same model. Only a context the rest of the catalog
    contradicts is lowered, and only to a number other providers actually
    publish. A record that agrees with its peers is left exactly as it is:
    openrouter's nemotron-3-ultra-550b-a55b:free keeps its 1,000,000 window
    because nvidia and vercel publish the same, and gemma-4-26b-a4b-it:free
    keeps 262144 because 14 of 16 records agree on it.

    Everything else keeps its catalog numbers. A large but credible output
    budget is left alone — xiaomi's mimo-v2.5-pro genuinely serves
    {context:1048576, output:131072}, and must not be collapsed to a 131072
    window just because its output exceeds the CLI's own ceiling.

    The output cap is then always carved out of whatever context survives, so
    the caller can never end up on Claude Code's 128000 default by accident.
    """
    limit = model.get("limit")
    # A context of 0 or a negative is not data, it is a hole — 104 live rows
    # (stepfun, stepfun-ai) carry `"context": 0` and used to resolve to the
    # contract-violating pair (0, None). Same for `"output": 0` on 166 rows: a
    # cap of zero tokens is not a cap, and reading it as one produced
    # max_output=None — no guard at all — on 176 rows, 18 of them with a
    # context >= 32768 and 11 of those tool-call capable. Both are UNKNOWN.
    ctx = _pos_int(_dget(limit, "context"))
    out = _pos_int(_dget(limit, "output"))
    notes = []
    if ctx is None and _num(_dget(limit, "context")) is not None:
        notes.append("limit.context=%r is not a usable window; treated as unknown"
                     % _dget(limit, "context"))
    elif ctx is not None and ctx < MIN_VIABLE_CONTEXT:
        notes.append(
            "limit.context=%d leaves no room for any output cap; treated as "
            "unknown rather than emitting a context with no guard" % ctx)
        ctx = None
    if out is None and _num(_dget(limit, "output")) is not None:
        notes.append("limit.output=%r is not a usable cap; treated as unknown"
                     % _dget(limit, "output"))

    # ATM-853 (2026-07-23, live opencode compaction loop): some catalog rows
    # publish a limit.input BELOW limit.context (opencode/big-pickle:
    # {context:200000, input:160000, output:32000}). The emitted context_limit
    # drives CLAUDE_CODE_AUTO_COMPACT_WINDOW — the INPUT-side guard — so a
    # window derived from limit.context alone puts the client-side compact
    # trigger ABOVE the server's real input cap: the guard can never fire
    # before the endpoint rejects, and every over-limit turn loops
    # reject -> compact -> reject regardless of the prompt. When the catalog
    # publishes a smaller real input cap, the input-side window MUST respect
    # it. A limit.input at/above the context adds no information (the context
    # already binds), and one below MIN_VIABLE_CONTEXT is treated like an
    # unusably-small context (noted, ignored) rather than emitting a window
    # nothing can fit in.
    inp = _pos_int(_dget(limit, "input"))
    if inp is not None and ctx is not None and inp < ctx:
        if inp >= MIN_VIABLE_CONTEXT:
            notes.append(
                "limit.input=%d is below limit.context=%d; the input-side "
                "guard uses the smaller real input cap" % (inp, ctx))
            ctx = inp
        else:
            notes.append(
                "limit.input=%d is below the minimum viable window; ignored "
                "(context %d kept)" % (inp, ctx))

    suspicious = _free_output_anomaly(model, siblings)
    # The anomaly is only EVIDENCE ABOUT THE CONTEXT when the record's output
    # sits strictly below its context. Where `output == context` the record is
    # exhibiting the far commoner and far more obvious mislabel — output copied
    # from context, the shape 1099 of 5696 live rows are in, which `_carve_output`
    # already fixes without any detector. Comparing that copied context against
    # a paid sibling's genuine output cap makes the free row look "bigger" as a
    # matter of arithmetic, not of evidence, so treating it as grounds to
    # rewrite the context is a category error. It cost three real windows:
    # llama-3.2-3b-instruct:free 131072->80000 (39% lost, and the low votes were
    # other hosts' truncations, not evidence about openrouter's endpoint),
    # llama-3.3-70b-instruct:free 131072->128000, tencent/hy3:free 262144->256000.
    # Restricting adjudication to the anomaly it was actually built for leaves
    # all three alone and still corrects both genuine cases.
    if suspicious is not None and ctx is not None and suspicious < ctx:
        corroborated = _corroborated_context(
            model.get("id"), corroboration, provider_id)
        if corroborated is None:
            notes.append(
                "limit.output exceeds this model's own paid sibling's budget, "
                "but fewer than %d OTHER providers publish a context for it — "
                "no corroboration, catalog context %d kept"
                % (MIN_CORROBORATING_PROVIDERS, ctx))
        elif corroborated < ctx:
            notes.append(
                "limit.output exceeds this model's own paid sibling's budget "
                "AND a majority of at least %d OTHER providers put this model's "
                "context at %d, below the %d claimed here — context corrected "
                "to %d"
                % (MIN_CORROBORATING_PROVIDERS, corroborated, ctx, corroborated))
            ctx = corroborated
        else:
            notes.append(
                "limit.output exceeds this model's own paid sibling's budget, "
                "but other providers corroborate context=%d — kept" % ctx)

    if ctx is None:
        # Unknown context. Emit a conservative NUMBER, never silence — see
        # UNKNOWN_MODEL_CONTEXT. Any output figure the record carried is
        # unanchored (it was never checked against a window), so it is subject
        # to the same carve-out as everything else rather than trusted.
        published = _conservative_unknown_context(siblings)
        if published is None:
            ctx = UNKNOWN_MODEL_CONTEXT
            notes.append(
                "context unknown and provider publishes none; assumed the "
                "conservative default %d so a guard always exists" % ctx)
        else:
            ctx = min(UNKNOWN_MODEL_CONTEXT, published)
            notes.append(
                "context unknown; assumed %d = min(conservative default %d, "
                "conservative estimate from this provider's own catalog %d)"
                % (ctx, UNKNOWN_MODEL_CONTEXT, published))

    carved, carve_notes = _carve_output(ctx, out)

    # THE SINGLE VIABILITY CHOKE POINT. `_carve_output` returns out=None for
    # exactly one reason: `ctx` is too small to host any positive output cap.
    # The raw-catalog path can never arrive here in that state — the
    # MIN_VIABLE_CONTEXT guard above already routed a sub-viable *catalog*
    # context into the unknown branch — so out=None here means `ctx` was
    # RE-ASSIGNED below viability AFTER that guard ran, on one of the two paths
    # the guard does not re-cover: a corroboration correction (`ctx = corroborated`)
    # or the unknown/min path (`ctx = min(UNKNOWN_MODEL_CONTEXT, published)`)
    # bottoming out on a provider that publishes only sub-viable windows.
    # Emitting (ctx, None) is the precise fail-open this module exists to close:
    # the launch wrapper would export a 1-token context and NO output cap, and
    # Claude Code would revert to its 128000 default against that hole. So rather
    # than re-running the raw guard after every re-assignment, we let the carve
    # be the one authority on viability and recover HERE, from the same
    # conservative estimate the uncatalogued-pin path uses — floored at
    # MIN_USABLE_UNKNOWN_CONTEXT so the recovery is itself always carvable.
    # Deliberately narrow: this fires only when the derived context cannot host
    # a positive cap AT ALL (ctx <= 1), never merely because it is small. A
    # corroboration to a small-but-viable window (peers agree on 32768) still
    # carves (32768, positive) and is NOT inflated up to the floor, which would
    # re-introduce the opposite 400.
    if carved is None:
        published = _conservative_unknown_context(siblings)
        recovered = max(
            MIN_USABLE_UNKNOWN_CONTEXT,
            UNKNOWN_MODEL_CONTEXT if published is None
            else min(UNKNOWN_MODEL_CONTEXT, published))
        notes.append(
            "derived context %d cannot host any output cap; fell back to the "
            "conservative estimate %d (floored at %d) rather than emitting a "
            "context with no guard"
            % (ctx, recovered, MIN_USABLE_UNKNOWN_CONTEXT))
        ctx = recovered
        carved, carve_notes = _carve_output(ctx, out)

    notes.extend(carve_notes)
    return ctx, carved, "; ".join(notes)


# --- free / paid classification -------------------------------------------
# models.dev prices a model under `cost: {input, output, cache_read, ...}` in
# USD per million tokens. Zero on BOTH sides means the model costs the account
# nothing per request — either a genuine free tier (openrouter's `:free` ids,
# NVIDIA NIM) or a flat-rate subscription whose per-token price is not
# meaningful (zai-coding-plan, kimi-for-coding). Both are "does not draw down
# pay-as-you-go credit", which is exactly what the operator's rule cares about.
#
# Missing/partial pricing is NOT free — 399 of the 5696 catalogued models carry
# no usable cost (poe, vercel, qiniu-ai...). Calling those free would be a
# guess that spends money; they are reported as tier "unknown".
FREE_ID_SUFFIXES = (":free",)

TIER_FREE = "free"
TIER_PAID = "paid"
TIER_UNKNOWN = "unknown"

CREDIT_AVAILABLE = "available"
CREDIT_EXHAUSTED = "exhausted"
CREDIT_UNKNOWN = "unknown"
CREDIT_STATES = (CREDIT_AVAILABLE, CREDIT_EXHAUSTED, CREDIT_UNKNOWN)

POLICY_AUTO = "auto"
POLICY_FREE = "free"
POLICY_PAID = "paid"
POLICIES = (POLICY_AUTO, POLICY_FREE, POLICY_PAID)

# Credit cache written by `model_verify.py --credit-probe`. The version gate
# mirrors model_verify's: bump it whenever the probe's semantics change so
# results produced by weaker/older logic are never replayed.
CREDIT_CACHE_VERSION = 1
CREDIT_CACHE_TTL_SECONDS = 86400  # 24h — balances cost money and time to probe


def model_cost_tier(model):
    """Classify one catalog model as free / paid / unknown from its pricing."""
    cost = model.get("cost")
    if isinstance(cost, dict):
        inp = _num(cost.get("input"))
        out = _num(cost.get("output"))
        if inp is not None and out is not None:
            return TIER_FREE if (inp == 0 and out == 0) else TIER_PAID
    # No usable price data — fall back to the provider's own free marker
    # (openrouter/kilo publish `<model>:free` ids) before giving up.
    mid = str(model.get("id") or "")
    if any(mid.endswith(sfx) for sfx in FREE_ID_SUFFIXES):
        return TIER_FREE
    return TIER_UNKNOWN


def tier_preference(credit_status, policy):
    """Return (ordered tier list, human explanation) for the credit rule."""
    if policy == POLICY_PAID:
        return [TIER_PAID, TIER_UNKNOWN, TIER_FREE], "operator pinned model_policy=paid"
    if policy == POLICY_FREE:
        return [TIER_FREE, TIER_UNKNOWN, TIER_PAID], "operator pinned model_policy=free"
    if credit_status == CREDIT_AVAILABLE:
        return [TIER_PAID, TIER_UNKNOWN, TIER_FREE], "credit available -> strongest paid"
    if credit_status == CREDIT_EXHAUSTED:
        return [TIER_FREE, TIER_UNKNOWN, TIER_PAID], "no credit -> strongest free"
    return ([TIER_FREE, TIER_UNKNOWN, TIER_PAID],
            "credit unknown -> conservative, strongest free")


def _strong_key(m):
    """Capability ranking: reasoning, then newest, then biggest context,
    tie-break highest output cost (proxy for flagship within a tier)."""
    return (
        1 if m.get("reasoning") else 0,
        str(m.get("release_date") or ""),
        _num(_dget(m.get("limit"), "context")) or 0,
        _num(_dget(m.get("cost"), "output")) or 0,
    )


def _fast_key(m):
    # lowest input cost, then smallest context; unknown cost sorts last.
    c = _num(_dget(m.get("cost"), "input"))
    return (
        c if c is not None else float("inf"),
        _num(_dget(m.get("limit"), "context")) or float("inf"),
    )


def select_models(provider, credit_status=CREDIT_UNKNOWN, policy=POLICY_AUTO,
                  corroboration=None, provider_id=None):
    """Pick (strong, fast) model IDs honouring the credit rule.

    Within the selected tier: strong = reasoning first, then newest
    release_date, then largest context, tie-break highest output cost; fast =
    lowest input cost among tool-call-capable models (else any). Both come from
    the SAME tier so a "free" alias cannot quietly bill through its fast model.

    Returns (strong_id, fast_id, context_limit, max_output, audit) — any of the
    first four may be None. context_limit/max_output are always taken from the
    model actually selected, so the launch-time token guards describe the model
    that will really serve the traffic.
    """
    models = provider.get("models") or {}
    items = [m for m in models.values() if isinstance(m, dict)]
    audit = {
        "model_tier": TIER_UNKNOWN,
        "counts": {TIER_FREE: 0, TIER_PAID: 0, TIER_UNKNOWN: 0},
        "reason": "",
        "limit_note": "",
    }
    if not items:
        audit["reason"] = "provider has no models in catalog"
        return None, None, None, None, audit

    buckets = {TIER_FREE: [], TIER_PAID: [], TIER_UNKNOWN: []}
    for m in items:
        buckets[model_cost_tier(m)].append(m)
    audit["counts"] = {t: len(v) for t, v in buckets.items()}

    order, why = tier_preference(credit_status, policy)
    skipped = []
    chosen_tier, pool = None, None
    for tier in order:
        if buckets[tier]:
            chosen_tier, pool = tier, buckets[tier]
            break
        skipped.append(tier)

    if pool is None:  # unreachable while items is non-empty, but stay honest
        audit["reason"] = "no model matched any tier"
        return None, None, None, None, audit

    strong = max(pool, key=_strong_key)
    tool_models = [m for m in pool if m.get("tool_call")] or pool
    fast = min(tool_models, key=_fast_key)

    # Limits go through derive_limits() — never straight from the catalog — so
    # the invariant input+output <= context holds for the model that will
    # actually serve the traffic.
    ctx_limit, out_limit, limit_note = derive_limits(
        strong, models, corroboration, provider_id)
    audit["limit_note"] = limit_note
    audit["model_tier"] = chosen_tier
    fallback = ""
    if skipped:
        fallback = " (no %s model in catalog; fell through)" % "/".join(skipped)
    audit["reason"] = (
        "%s; selected tier=%s%s [free=%d paid=%d unknown=%d]"
        % (why, chosen_tier, fallback,
           audit["counts"][TIER_FREE], audit["counts"][TIER_PAID],
           audit["counts"][TIER_UNKNOWN])
    )

    if limit_note:
        audit["reason"] += "; limits: " + limit_note

    return strong.get("id"), fast.get("id"), ctx_limit, out_limit, audit


def credit_status_for(pid, ov, credits):
    """Resolve a provider's credit status. Override pin beats the probe cache;
    an absent/expired/mis-versioned cache entry is honestly 'unknown'."""
    pinned = str(ov.get("credit") or "").lower()
    if pinned in CREDIT_STATES:
        return {"status": pinned, "signal": "override",
                "detail": "credit pinned in overrides.json"}
    entry = (credits.get("providers") or {}).get(pid)
    if isinstance(entry, dict):
        state = str(entry.get("credit") or "").lower()
        if state in CREDIT_STATES:
            return {"status": state,
                    "signal": str(entry.get("signal") or "probe"),
                    "detail": str(entry.get("detail") or "")}
    return {"status": CREDIT_UNKNOWN, "signal": "none",
            "detail": "no usable credit probe on record for this provider"}


def sanitize_alias(name):
    """Make a provider id into a valid shell alias (letter-led, [A-Za-z0-9_-])."""
    a = re.sub(r"[^A-Za-z0-9_-]", "-", name)
    a = re.sub(r"-+", "-", a).strip("-")
    if not a or not a[0].isalpha():
        a = "p-" + a
    return a


def resolve(catalog, present_keys, key_aliases, overrides, only=None, credits=None,
            legacy_map=None):
    credits = credits or {}
    legacy_map = legacy_map or {}
    # Built once: cross-provider context evidence for every model in the
    # catalog, used to adjudicate self-inconsistent records (see
    # `_corroborated_context`).
    corroboration = build_context_corroboration(catalog)
    records = []
    for key_var in present_keys:
        cls = classify(key_var)
        rec = {
            "key_var": key_var, "classification": cls,
            "provider_id": None, "alias": None, "base_url": None,
            "transport": None, "strong_model": None, "fast_model": None,
            "context_limit": None, "max_output": None,
            "status": "skipped", "reason": "",
            # Credit-rule audit trail — always present so downstream consumers
            # never have to guess whether the rule ran.
            "credit_status": CREDIT_UNKNOWN, "credit_signal": "none",
            "credit_detail": "", "model_policy": POLICY_AUTO,
            "model_tier": TIER_UNKNOWN, "selection_reason": "",
        }
        if cls != "llm":
            rec["reason"] = f"classified {cls}; not a model backend"
            records.append(rec)
            continue

        base_pid = key_aliases.get(key_var) or find_provider_by_env(catalog, key_var)
        # Legacy id rename (kimi-* -> kc-*): the EMITTED id is the mapped one,
        # but the catalog lookup still uses the UPSTREAM id (models.dev keeps
        # the original "kimi-for-coding"; the new kc-for-coding is not a
        # catalog key). The uniqueness/merge/status machinery upstream keys on
        # the emitted id, so the rename survives every re-resolve.
        pid = legacy_map.get(base_pid, base_pid) if base_pid else base_pid
        if not base_pid or base_pid not in catalog:
            rec["status"] = "unmapped"
            rec["reason"] = "no models.dev provider for this key var"
            rec["provider_id"] = base_pid
            records.append(rec)
            continue

        provider = catalog[base_pid]

        # overrides.json: per-provider manual pins (alias/base_url/transport/
        # strong_model/fast_model/credit/model_policy). This is how a user
        # promotes e.g. deepseek to a native /anthropic endpoint, or forces
        # free-only spending, without any hardcoding in code. Check the mapped
        # (kc-*) key first, then the upstream id for a legacy-written pin.
        ov = overrides.get(pid) or overrides.get(base_pid) or {}

        # The credit rule runs BEFORE selection: which tier we may spend from
        # decides which models are even candidates.
        policy = str(ov.get("model_policy") or POLICY_AUTO).lower()
        policy_note = ""
        if policy not in POLICIES:
            policy_note = " (ignored unknown model_policy=%r)" % ov.get("model_policy")
            policy = POLICY_AUTO
        cinfo = credit_status_for(pid, ov, credits)

        strong, fast, context_limit, max_output, audit = select_models(
            provider, cinfo["status"], policy, corroboration, pid)
        rec.update({
            "provider_id": pid,
            "alias": sanitize_alias(pid),
            "base_url": provider.get("api"),
            "transport": transport_for(provider),
            "strong_model": strong,
            "fast_model": fast,
            "context_limit": context_limit,
            "max_output": max_output,
            "status": "resolved",
            "credit_status": cinfo["status"],
            "credit_signal": cinfo["signal"],
            "credit_detail": cinfo["detail"],
            "model_policy": policy,
            "model_tier": audit["model_tier"],
            "selection_reason": "credit=%s(signal=%s) policy=%s%s; %s" % (
                cinfo["status"], cinfo["signal"], policy, policy_note,
                audit["reason"]),
        })

        for field in ("alias", "base_url", "transport", "strong_model", "fast_model"):
            if ov.get(field):
                rec[field] = ov[field]

        # A strong_model pin INVALIDATES the limits computed above: select_models
        # derived context_limit/max_output from the model IT chose, not from the
        # pinned one. Left stale, the generated .env advertises one model's window
        # for another model's traffic — e.g. nvidia pinned the 30B nano
        # (256000/65536) but kept z-ai/glm-5.2's 1000000/131072, so the launch
        # wrapper exported an output cap ~2x the model's real limit. Re-derive
        # from the model actually pinned.
        #
        # A pinned id the catalog does not know (a provider-only model) must not
        # report an unrelated model's numbers — but it must not report NOTHING
        # either. Empty limits looked honest and were in fact the last fail-open
        # hole: the launch wrapper exports no guard at all for an empty pair, and
        # Claude Code's own no-cap default is 128000 output tokens against an
        # unmeasured window. That is the same failure the large-context fix
        # closed, reached from the other end. derive_limits() therefore falls back
        # to a conservative pair (see UNKNOWN_MODEL_CONTEXT) so a guard always
        # exists; the operator can state the real numbers via the
        # context_limit / max_output override fields, which win over the catalog
        # (previously they were accepted in overrides.json but silently ignored —
        # kimi-for-coding's "context_limit": 262144 never reached the .env).
        if ov.get("strong_model"):
            _pmodels = provider.get("models") or {}
            pinned = _pmodels.get(rec["strong_model"]) or {}
            # Same derivation as the auto-selected path: a pin changes WHICH
            # model's numbers we read, never whether they are sanity-checked.
            # (This is the path openrouter/kilo take — both pin
            # nvidia/nemotron-3-super-120b-a12b:free in overrides.json.)
            rec["context_limit"], rec["max_output"], _pin_note = derive_limits(
                pinned, _pmodels, corroboration, pid)
            # A human pin outranks the credit rule, but the record must still
            # say which tier the operator actually pinned into — a pin onto a
            # paid model while credit is exhausted is exactly the kind of thing
            # someone needs to be able to see afterwards.
            rec["model_tier"] = model_cost_tier(pinned) if pinned else TIER_UNKNOWN
            rec["selection_reason"] = (
                "credit=%s(signal=%s) policy=%s; OVERRIDE PIN strong_model=%s "
                "(tier=%s) wins over the credit rule%s"
                % (cinfo["status"], cinfo["signal"], policy, rec["strong_model"],
                   rec["model_tier"],
                   "" if pinned else " — model unknown to catalog, tier undetermined")
            )
            if _pin_note:
                rec["selection_reason"] += "; limits: " + _pin_note
        # An operator override is data from a hand-edited file, so it is
        # VALIDATED, not merely present-checked. `_num` was not a validator:
        # `isinstance(True, int)` is True in Python, so `"context_limit": true`
        # became the integer 1, carved to no cap at all, and the launch wrapper
        # exported NEITHER guard — reproducing exactly the fail-open this work
        # closes. `-1`, `0` and `50000.5` arrived at the same place. A rejected
        # value is dropped AND said out loud in selection_reason; silently
        # ignoring a typo is how an operator ends up debugging the wrong thing.
        _derived_pair = (rec["context_limit"], rec["max_output"])
        _ov_ctx = _ov_out = False
        for field in ("context_limit", "max_output"):
            if field not in ov:
                continue
            value = _pos_int(ov[field])
            if value is None:
                rec["selection_reason"] += (
                    "; ignored override %s=%r: not a positive integer"
                    % (field, ov[field]))
                continue
            rec[field] = value
            if field == "context_limit":
                _ov_ctx = True
            else:
                _ov_out = True

        # A context_limit override INVALIDATES an output cap derived from the
        # catalog, for the same reason a strong_model pin invalidates the
        # auto-picked model's limits: the cap was carved out of a different
        # window. kimi-for-coding is the live case — it states context_limit
        # 262144, but the cap on record was carved from the 128000 unknown-model
        # fallback, leaving the alias pinned to 8192 output when its own stated
        # window affords 102144. Drop the stale cap and re-carve from what the
        # operator actually said. An explicitly stated max_output is a decision,
        # not a derivation, so it survives.
        if _ov_ctx and not _ov_out:
            rec["max_output"] = None

        # Final invariant pass over whatever survived — catalog value, pin, or
        # operator override. A human pin outranks the credit rule and the model
        # ranking, but it does not outrank physics: `input + output <= context`
        # is a property of the endpoint, not a preference. An operator who pins
        # an output >= their own context would otherwise ship a pair that 400s
        # on the first request. Re-carving is idempotent for any already-valid
        # pair, so a correct pin passes through untouched.
        # It also enforces the TYPE half of the contract, which the pass never
        # used to: `out < ctx` says nothing if ctx is True or 0.5.
        _fctx, _fout = _pos_int(rec["context_limit"]), _pos_int(rec["max_output"])
        if _fctx is not None:
            _fixed, _fnotes = _carve_output(_fctx, _fout)
            if _fixed is None:
                # The stated window cannot host any output cap at all (an
                # operator's `"context_limit": 1`). A pair with no cap is the
                # fail-open shape, so the override is refused outright and the
                # derived pair — which is always valid — stands instead.
                rec["context_limit"], rec["max_output"] = _derived_pair
                rec["selection_reason"] += (
                    "; refused override context_limit=%d: too small to carve any "
                    "output cap from; kept derived pair %s/%s"
                    % (_fctx, _derived_pair[0], _derived_pair[1]))
            else:
                if _fixed != _fout:
                    rec["selection_reason"] += "; limits normalized: " + (
                        "; ".join(_fnotes) or
                        "output cap %s recarved to %s from context %d"
                        % (_fout, _fixed, _fctx))
                rec["context_limit"], rec["max_output"] = _fctx, _fixed
        elif rec["context_limit"] is not None or _fout is not None:
            # A cap with no context basis proves nothing fits; a context that
            # is not a positive integer is not a context. Either way the only
            # trustworthy pair left is the derived one.
            _bad = (rec["context_limit"], rec["max_output"])
            rec["context_limit"], rec["max_output"] = _derived_pair
            rec["selection_reason"] += (
                "; limits %s/%s unusable; kept derived pair %s/%s"
                % (_bad[0], _bad[1], _derived_pair[0], _derived_pair[1]))

        if not rec["strong_model"]:
            rec["status"] = "unmapped"
            rec["reason"] = "provider has no usable models in catalog"
        if rec["transport"] == "router" and not rec["base_url"]:
            # A router provider with no base URL can't be configured for ccr —
            # don't activate a broken alias; surface it for an override instead.
            rec["status"] = "unmapped"
            rec["reason"] = "router provider missing base_url (catalog api null)"

        records.append(rec)

    if only:
        records = [r for r in records if r.get("provider_id") == only]
    return records


def load_json(path, default):
    if not path:
        return default
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def load_credits(path, now=None):
    """Load the credit-probe cache, refusing anything we must not trust.

    Three ways a cache is rejected — all of them silently degrade to "unknown",
    which the policy treats as no-credit (free-only), never as credit:
      * wrong/absent `_cache_version`: written by older probe logic whose
        semantics we no longer stand behind — replaying it would resurrect a
        decision this code never made;
      * `_cached_at` missing/non-numeric/older than the TTL: balances change,
        and a week-old "available" is not evidence of anything today;
      * malformed JSON on disk.
    """
    if not path:
        return {}
    try:
        with open(path) as f:
            data = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}
    if not isinstance(data, dict):
        return {}
    if data.get("_cache_version") != CREDIT_CACHE_VERSION:
        return {}
    ts = data.get("_cached_at")
    if not isinstance(ts, (int, float)) or isinstance(ts, bool):
        return {}
    now = time.time() if now is None else now
    if now - ts > CREDIT_CACHE_TTL_SECONDS or now < ts - 60:
        # Future-dated beyond clock skew is as untrustworthy as expired.
        return {}
    return data


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--models-dev", required=True)
    ap.add_argument("--keys", default="")
    ap.add_argument("--key-aliases")
    ap.add_argument("--overrides")
    ap.add_argument("--legacy-renames",
                    help="legacy provider-id map (old->new, e.g. kimi-* -> kc-*): "
                         "the EMITTED id is mapped, catalog lookup stays on the "
                         "upstream id")
    ap.add_argument("--only")
    ap.add_argument("--credits",
                    help="credit-probe cache (model_verify.py --credit-probe); "
                         "absent/stale/mis-versioned => credit unknown => free-only")
    args = ap.parse_args(argv)

    with open(args.models_dev) as f:
        catalog = json.load(f)
    present = [k.strip() for k in args.keys.split(",") if k.strip()]
    key_aliases = load_json(args.key_aliases, {})
    overrides = load_json(args.overrides, {})
    legacy_map = load_json(args.legacy_renames, {})
    credits = load_credits(args.credits)

    records = resolve(catalog, present, key_aliases, overrides, only=args.only,
                      credits=credits, legacy_map=legacy_map)
    json.dump(records, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
