# Research: llmctl Integration Hardening & Verified Release

**Feature**: [spec.md](./spec.md) | **Date**: 2026-10-02

This document consolidates two exhaustive codebase audits (claude_toolkit-side
and the separate `../llmctl` upstream project) performed for this feature's
planning phase, resolves every `NEEDS CLARIFICATION` in the plan's Technical
Context, and records the decisions that drive `data-model.md`, `contracts/`,
and `tasks.md`.

## 0. Audit methodology

Two independent, parallel deep-reads were performed (not grep-only — full
function bodies, test files, and captured evidence were read):

1. **claude_toolkit-side**: `scripts/claude-providers.sh` (`detect_llmctl_records`,
   lines 2050–2241), `scripts/lib.sh` (`_cma_llmctl_ensure_active`, lines
   1256–1314), every `test_llmctl_*`/`test_kimi_llmctl_*` test file, and the
   captured proof corpus (`scripts/tests/proof/99-llmctl-detect.txt`,
   `kimi-llmctl-integration-evidence.txt`).
2. **llmctl upstream** (`/home/milosvasic/Projects/llmctl`, per the spec's
   resolved clarification: investigate and document, never fix): `bin/llmctl`
   dispatch table, `lib/catalog.sh`, `lib/scheduler.sh`, `lib/common.sh`,
   `lib/cluster.sh`, `models/catalog.json`, `CHANGELOG.md`,
   `docs/CONTINUATION.md`.

Every finding below cites its source file:line per the constitution's
anti-bluff / no-guessing discipline (`§11.4.6`, `§11.4.2`).

## 1. Decision: what is ALREADY correct and must only be preserved

Three of the spec's functional requirements are **already fully
implemented and already tested** — the plan's task list must prove this
with the existing evidence rather than re-build it from scratch.

- **FR-002 (always-namespaced `llmctl-<profile>` alias naming)** — `scripts/claude-providers.sh:2236-2237`:
  `provider_id: ("llmctl-" + .name), alias: ("llmctl-" + .name)`. Twins for
  Kimi/Pi families follow the same prefix (`scripts/claude-providers.sh:2026-2029`).
- **FR-004 (graceful no-op when llmctl is absent)** — `detect_llmctl_records`
  returns `[]` with no error when the binary and pins file are both absent
  (`scripts/claude-providers.sh:2135-2142`); `_cma_llmctl_ensure_active` is an
  immediate no-op for any non-`llmctl-*` provider id (`scripts/lib.sh:~1262`).
  Both paths are covered by existing tests (Case D in `test_llmctl_detect.sh`;
  the "non-llmctl provider id is an immediate no-op" case in
  `test_llmctl_ondemand_switch.sh`).
- **FR-005/FR-006/FR-007/FR-008 (exclusive, on-demand-only switch that leaves
  non-llmctl aliases untouched)** — `_cma_llmctl_ensure_active`
  (`scripts/lib.sh:1256-1314`) is called **only** from inside the three launch
  wrappers (`cma_run_provider`/`cma_run_kimi_provider`/`cma_run_pi_provider`),
  so it only ever fires in direct response to an explicit operator launch —
  FR-006 is already true by construction, not by a check that could be
  bypassed. It checks `llmctl status` first and short-circuits with no switch
  call if the target is already the sole running profile, then delegates the
  actual stop/start to `llmctl switch <profile>` and propagates its exit code
  verbatim — it never reimplements stop/start logic itself. `test_llmctl_ondemand_switch.sh`
  (327 lines) already asserts: already-active no-op, different-profile
  triggers a switch, switch-failure aborts the launch (×3, once per account
  family), non-llmctl providers never touch llmctl, and an unresolvable
  binary refuses cleanly.
- **Detection (FR-001, FR-003)** — `detect_llmctl_records` calls `llmctl plan
  --json` once for the catalog→port map, then **independently HTTP-probes
  each catalog profile's own `/v1/models` endpoint** to confirm it is
  genuinely answering — a listening port alone is never trusted (there is a
  documented, previously-reproduced case of an unrelated service squatting
  port 8080). This sidesteps the upstream gap found in §3 below (no JSON
  `running` field, no `status --json`) entirely, because detection never
  depends on either. `test_llmctl_detect.sh` already has 14 explicit cases
  (A–H4) covering zero/one/many running profiles, wrong-service port-squatting,
  garbage JSON, and env-var precedence.

**Rationale for calling this out explicitly**: the spec's SC-003 target is
"100% of identified gaps fixed, each with a passing, previously-failing check."
Re-implementing already-correct, already-tested behavior would waste the
scope budget and risk introducing a regression into code that is provably
fine today. The task list treats these four requirement groups as
**regression-locked** (add the still-missing live/evidence layer from §4, but
do not touch the detection/switch logic itself without a new, independently
reproduced defect).

**Alternatives considered**: Rewriting detection/switch from scratch for
"consistency" with the newly-written FRs — rejected; the existing design is
more robust than a naive re-implementation would be (independent HTTP
liveness probing beats trusting llmctl's own undocumented `.run` marker files
or text-only `status`, see §3).

## 2. Decision: the real, confirmed danger zone — context-limit mismatch

**Finding** (severity: highest; already has live captured-evidence of a real
failure, not a hypothetical): `scripts/tests/proof/kimi-llmctl-integration-evidence.txt`
records a genuine production failure —

```
claude-providers: switching llmctl to profile small (currently: vision)...
kimi version 0.42.0
error: failed to run prompt: provider.api_error: 400 request (92436 tokens)
exceeds the available context size (8192 tokens), try increasing it
```

**Root cause**: `detect_llmctl_records` sets `context_limit`/`max_output` for
an llmctl record from, in order: the model's own `/v1/models` `meta.n_ctx`
field if present, else the catalog's `ctx` field (confirmed present in
`llmctl plan --json`'s per-profile schema, see §3.A), else a flat
`CMA_LLMCTL_CONTEXT_LIMIT` default of `8192`. **No carve-from-real-context
logic is applied to llmctl records** — every other resolver-driven provider
gets `providers_resolve.py:derive_limits()`'s carve (reserving room for a CLI
agent's own system-prompt/tool-schema overhead, ~67K tokens minimum per this
project's own documented host forensics), but llmctl/helixagent/helixcoder
set `context_limit`/`max_output` directly on their own records, bypassing
that carve entirely. A real Kimi Code turn needing 92,436 tokens of its own
overhead against an 8192-token ceiling is exactly the failure mode the carve
exists to prevent everywhere else.

**Decision**: apply the same carve-from-real-context discipline llmctl
records already should have had — derive `context_limit`/`max_output` for an
llmctl record from its real, best-available `n_ctx` (now confirmed obtainable
two ways: `/v1/models` `meta.n_ctx`, or `llmctl plan --json`'s own `"ctx"`
field as a second, authoritative source to cross-check or fall back to), then
carve the usual CLI-agent-overhead floor out of it exactly as
`derive_limits()` already does for catalog-resolved providers. **When the
carved result cannot clear the minimum usable floor** (the profile's real
context is simply too small for a CLI agent's own baseline overhead), the
alias is not silently exported with an unusable ceiling — it is exported with
an explicit, honest warning surfaced at the same point FR-009's LAN-exposure
warning surfaces, naming the real `n_ctx` and the minimum needed.

**Rationale**: this is the single highest-value fix in this feature — it
closes a defect with *already-captured, already-reproduced* evidence of
real-world breakage, is squarely in claude_toolkit's own scope (FR-010, not
FR-010a), and the fix pattern (reuse `derive_limits()`'s carve) is already
proven correct for every other provider — no new design is needed, only
applying an existing, trusted mechanism to a record class that was
accidentally exempted from it.

**Alternatives considered**: raising the flat default from 8192 to some
larger constant — rejected; this is the exact "guessed value instead of a
measured one" pattern `§11.4.6` forbids, and a differently-sized profile
would just move the same failure to a different threshold. Refusing to
create an alias for any profile below a fixed context floor — rejected as
too blunt; a profile that is merely a poor fit for a CLI agent's overhead is
still a legitimate, usable OpenAI-API-compatible endpoint for other callers,
so the correct behavior is an honest warning, not a refusal (mirrors the
spec's own resolved decision for FR-009: verify-and-warn, never a silent
refusal, applied here to context-fit by the same precedent).

## 3. llmctl-upstream findings (documented per FR-010a — NOT fixed here)

Per the clarified spec scope, every item below is a `llmctl-Side Finding`:
precisely documented, filed as a separately tracked follow-up, and **no code
in `../llmctl` is touched by this feature**.

### 3.A `llmctl plan --json` schema (authoritative, read from `lib/catalog.sh:221` `catalog_plan_json()`)

```json
{
  "profiles": {
    "<name>": {
      "mode": "gpu|cpu|colibri|none", "ram_mb": 0, "vram_mb": 0,
      "storage_mb": 0, "ctx": 0, "ngl": 0, "parallel": 0,
      "flash_attn": "auto|off|...", "fits": true, "port": 0,
      "engine": "llama.cpp|colibri", "capability": ["chat", "..."],
      "min_tier": "...", "tier_ok": true, "recommended": true
    }
  },
  "budgets": {"ram_mb": 0, "vram_mb": 0},
  "groups": [ ]
}
```

**Confirmed: no `"running"` field exists anywhere in this schema.** `plan
--json` is a pure hypothetical fit-check, never a statement of current
state. `port` resolves through `resolve_port()`, honoring an opt-in
`LLMCTL_PORT_<PROFILE>` override (`lib/catalog.sh:252-262`) — the README's
fixed port table is a default, not a guarantee; a consumer must read the
resolved `port` from this JSON on every call, never hardcode the README's
numbers. (claude_toolkit's `detect_llmctl_records` already does this
correctly.)

**llmctl-Side Finding #1** (confidence: confirmed by reading code): there is
no machine-readable status/running-state command at all. `status` →
`sched_status` (`lib/scheduler.sh:753-780`) emits a fixed-width human text
table only (`printf '%-16s...'`); no `--json` flag exists on it or anywhere
else. The only ground truth for "what is actually running right now" is
`sched_running()` (`lib/scheduler.sh:75-90`), which reads
`${LLMCTL_RUNTIME_DIR}/*.run` marker files — a simple `key=value` text
format that is exported as an env var (`lib/common.sh:39`) but is
**undocumented as a stable external contract** (zero mentions in
`docs/architecture.md`). A future internal refactor of that file format or
location would silently break any external consumer depending on it, with no
deprecation signal. *claude_toolkit is not such a consumer* — it independently
HTTP-probes each profile's own endpoint (§1 above) — but this finding is
filed for llmctl's own tracking because any OTHER external integration would
be exposed to it.

### 3.B `llmctl switch <profile>` robustness (`lib/scheduler.sh:610-668`)

Genuinely atomic as of the current commit (landed 2026-09-22, after a real
incident documented inline at `lib/scheduler.sh:616-634` where a failed
switch once left the host with zero services running and no auto-recovery):
`sched_switch()` wraps the whole operation in one `scheduler::with_lock`
unit, snapshots the running set before stopping anything, and best-effort
restores that snapshot if starting the target fails. A no-op path exists
when the target is already the sole running profile.

**llmctl-Side Finding #2** (confidence: confirmed by reading code): the
rollback is explicitly **best-effort**, not guaranteed — if the rollback
itself also fails, llmctl logs `"ROLLBACK ALSO FAILED - the host may have
fewer services running than before"` (`lib/scheduler.sh:661-665`) and
returns the *original* failure code, with no distinct machine-readable
signal distinguishing "switch failed, rollback succeeded" from "switch
failed, rollback also failed" — a caller must parse stderr text to tell them
apart.

**Implication for claude_toolkit's own FR-007** (in scope, not a
llmctl-side finding): `_cma_llmctl_ensure_active` must not treat "switch
exited non-zero" as proof the previous profile is still running — it already
propagates the failure (so the launch is correctly aborted), but per FR-007's
"leave previously active completely unchanged" guarantee, the task list adds
a post-failure state re-check (an honest liveness re-probe of whatever was
previously active) rather than assuming llmctl's rollback always held, and
surfaces the rare "rollback also failed" case as a distinctly-worded,
higher-severity warning rather than conflating it with an ordinary refusal.

### 3.C Bind-address mechanism (`lib/common.sh:44-74`, `lib/scheduler.sh:295-317`)

Not hardcoded: `LLMCTL_BIND_HOST="${LLMCTL_BIND_HOST:-0.0.0.0}"`
(`lib/common.sh:74`) — defaults to LAN-exposed **by explicit documented
operator-facing trade-off** (`llama-server`'s OpenAI-compatible API has no
built-in authentication). Override: `LLMCTL_BIND_HOST=127.0.0.1` globally, or
`LLMCTL_BIND_HOST_<PROFILE>=127.0.0.1` per-profile — so the real bind address
can differ per profile and is **not** reported anywhere in `plan --json`'s
schema (§3.A).

**Decision for FR-009** (claude_toolkit-side fix, informed by this upstream
finding): since llmctl's own JSON never reports the resolved bind address,
FR-009's warning cannot be derived from llmctl's API at all. The reliable
signal is reading the real listening socket's bind address directly from the
kernel socket table for the profile's resolved port (e.g. via `ss -ltnp` or
equivalent), per the constitution's `§11.4.201` discipline — a guard must
assert the real condition from its authoritative source, never a proxy. This
is fully implementable from claude_toolkit's side alone, requires no upstream
change, and is immune to `LLMCTL_BIND_HOST_<PROFILE>`'s per-profile override
surprising a naive "check the one global env var" approach.

**llmctl-Side Finding #3** (confidence: confirmed by reading code): colibri
engine profiles (`colibri-glm`, `colibri-qwen36`) carry their own independent
fail-closed guard — they refuse to bind non-loopback at all unless
`COLI_ALLOW_INSECURE_BIND=1` is set, and llmctl deliberately does not
auto-set that on the operator's behalf (`lib/scheduler.sh:295-313`). Under
the LAN-exposed default, a colibri profile will therefore crash-loop unless
the operator explicitly opts in. claude_toolkit's existing liveness-probing
detection (§1) already handles this gracefully by construction — a
crash-looping profile simply never answers its `/v1/models` probe, so it is
correctly reported as "not running," never as a false positive.

### 3.D Known, pre-existing model-capability and performance risk for live testing (`docs/CONTINUATION.md:983-1065`, §10m, dated 2026-09-17)

**llmctl-Side Finding #4** (confidence: confirmed by reading dated project
history; whether still current requires a fresh live test): a documented
per-profile status table records the `vision` profile (Gemma-3-4b) **failing
even layer-1-through-3 tool-calling outright** — the model made no tool call
at all, a genuine model-capability limit, not an infrastructure defect — and
`small`/`moe-fast` failing layer-4 (a real multi-turn Superpowers session)
due to CPU-only inference being too slow within Claude Code's own
per-request timeout. A later entry (`docs/CONTINUATION.md:1304+`, §10p)
records GPU enablement resolving the CPU-speed root cause with a measured
56.6× throughput improvement, but **explicitly discloses the real
Superpowers-TUI session was not re-run after that fix**.

**Decision for this feature's User Story 3 live-testing plan**: this is an
**anticipated, pre-known test outcome**, not a surprise to be discovered
mid-execution. The live-test design (§4 below) must:
1. Expect `llmctl-vision` to plausibly FAIL the tool-calling-dependent
   Superpowers checks for a genuine model-capability reason, and record that
   as an honest FAIL with captured evidence — never silently excluded, never
   force-passed, consistent with FR-013/FR-014's no-false-result requirement.
2. Treat `llmctl-small`/`llmctl-moe-fast` (and any other CPU-bound profile on
   the test host) as needing a fresh, current-commit re-verification, since
   the last-known timeout failure's claimed fix was never re-confirmed against
   the actual live-test shape this feature is about to build.
3. Document, in the user-facing FAQ (§5), that a given llmctl profile's
   *model itself* may not support tool-calling or may be too slow for
   interactive use — this is a model/profile characteristic the operator
   chooses, not a claude_toolkit integration defect, and the documentation
   must say so plainly rather than implying every profile is equally capable.

### 3.E Memory-safety interaction outside llmctl's own accounting (`docs/CONTINUATION.md:1018-1029`)

**llmctl-Side Finding #5** (confidence: confirmed by reading documented
incident): llmctl's own budget/overcommit checks only cover processes
launched *through* its own scheduler — a manually-launched raw test process
alongside two llmctl-managed persistent services previously drove swap to
100% and free RAM to ~278 MiB.

**Decision for this feature's test design**: every live-test harness
component in this feature launches/stops llmctl-backed models **strictly
through llmctl's own commands** (`llmctl start`/`switch`/`stop` by way of
claude_toolkit's existing wrappers), never a raw/manual process reaching
into llmctl's managed profiles, so test execution stays inside llmctl's own
safety accounting and this constitution's `§12.6`/`§12.11` host-memory
ceilings.

### 3.F Authentication (confirms claude_toolkit's existing design is correct)

Confirmed directly (`lib/common.sh:51-56`): no API key is required by
default on llmctl's per-profile OpenAI-compatible endpoints. The only
auth-like mechanism in the codebase, `LLMCTL_CLUSTER_TOKEN`
(`lib/cluster.sh:50,91`), governs the unrelated distributed-cluster daemon
(`llmctld`)'s own `/v1/cluster/*`/`/v1/tenants/*` API — not the per-profile
model-serving endpoints claude_toolkit actually talks to. This confirms
claude_toolkit's `LLMCTL_API_KEY` key_var is correctly treated as a
toolkit-internal registration key, never sent to llmctl as a real
credential — no change needed.

### 3.G Positive prior art (not a defect — cited for completeness)

`../llmctl`'s own `CHANGELOG.md` records a prior fix: `bin/llmctl` PATH-symlink
resolution was broken and was fixed specifically because it was needed for
claude_toolkit's own llmctl provider detection. A direct coupling between
these two projects, and a precedent of upstream fixing issues that affect
this integration, already exists.

## 4. Decision: live, evidence-producing Superpowers-command test design (FR-011/FR-012/FR-013/FR-014)

**Finding**: no live test of this kind exists today. Every current
llmctl-related test (`test_llmctl_detect.sh`, `test_llmctl_ondemand_switch.sh`,
`test_llmctl_sync_all.sh`, `test_kimi_llmctl_integration.sh`) is hermetic —
fake `llmctl`/`claude`/`kimi` binaries exercising wrapper logic, never a real
model. This is the single biggest implementation gap relative to the spec.

**Decision**: extend, never reinvent, the toolkit's existing
`scripts/verify_superpowers_tui.sh` anti-bluff architecture — it already
solves exactly the problem this feature's User Story 3 describes (proving a
skill genuinely engaged, not merely that no exception was thrown) via an
**unforgeable-knowledge challenge**: it asks the model to reproduce one exact
cell from the `superpowers:using-superpowers` skill's own Red-Flags table —
a string that exists only inside the skill file, cannot be echoed from the
prompt, cannot be guessed, and is read from the skill file at runtime (never
hardcoded) so it stays correct as the skill evolves.

The same pattern generalizes cleanly to the other two required commands,
because both target skills ship their own uniquely-extractable facts:

- **"Use Superpowers"** → already implemented exactly this way by
  `verify_superpowers_tui.sh`; reused as-is against every `llmctl-<profile>`
  alias.
- **"Turn on Systematic Debugging"** → challenge extracted from
  `systematic-debugging/SKILL.md` (present in the installed plugin cache at
  `.../superpowers/6.4.1/skills/systematic-debugging/SKILL.md`), analogous to
  the existing Red-Flags-table extraction.
- **"Turn on Sub-Agent-Driven Development"** → challenge extracted from
  `subagent-driven-development/SKILL.md` (same plugin cache, sibling
  directory), same pattern.

Each check inherits the existing script's already-correct anti-bluff
machinery: honest SKIP (never a faked PASS) when the real `claude`/`kimi`
binary, the alias, or network access is absent; the bare-provider
(`CMA_PROVIDER_TRIM=bare`) honest skip, since bare providers intentionally
disable the skill surface this check requires; and the route-attribution
fix (checking which backend *actually* served the turn, not just which one
was intended) — directly relevant here, since a false pass attributable to
the wrong backend would be exactly the kind of result the spec's FR-013
determinism requirement and the constitution's anti-bluff covenant forbid.

**Reproducibility (FR-013)**: the three unforgeable-challenge checks are
read directly from the installed skill files at run time and compared
byte-for-byte to the model's response, giving a deterministic pass/fail
oracle (the existing design's own stated property — "a model that did not
load the skill cannot produce it"). The task list adds an explicit
double-run assertion (run the full three-command × alias × CLI-agent matrix
twice against an unchanged system, assert identical verdicts) as the
concrete mechanical proof of FR-013, since no such explicit check exists
today even though the underlying oracle is already deterministic by design.

**Honest skip for the anticipated model-capability case (§3.D)**: when
`llmctl-vision` or any CPU-bound profile genuinely cannot complete a
tool-calling turn or times out, the result is recorded as a real FAIL with
captured output (per FR-013/FR-014) — not reclassified as a SKIP, since the
precondition (the model is running and reachable) is genuinely met; only
the model's own capability is the limiting factor, and that is exactly what
this check must honestly surface.

**Alternatives considered**: building a new, separate live-test harness from
scratch — rejected; it would duplicate the route-attribution and
bare-provider-skip logic `verify_superpowers_tui.sh` already solved
correctly, violating the constitution's extend-don't-reimplement discipline
(`§11.4.74`) and re-introducing bugs that mechanism's own history already
fixed. A vocabulary/keyword-grep check instead of the unforgeable-knowledge
challenge — rejected; the existing script's own documented history shows
this approach fails in both directions (false PASS on confident guesses,
false FAIL on correct-but-differently-worded engagement).

## 5. Decision: performance — parallelize the per-profile liveness probe

**Finding**: `detect_llmctl_records` performs one sequential `curl` per
catalog profile on every sync, each with its own up-to-3-second timeout
(`CMA_LLMCTL_HTTP_TIMEOUT`), plus the upstream `llmctl plan --json` call
(up to a 10-second timeout). On a host with many catalog profiles but few
actually running, a sync could pay up to `N_profiles × 3s` sequentially
before reaching any other provider's own detection work.

**Decision**: bound the worst case by probing every catalog profile's
`/v1/models` endpoint concurrently (not sequentially) within
`detect_llmctl_records`, so the total added latency approaches the single
slowest profile's timeout rather than the sum of all of them, while keeping
the existing per-probe timeout and the "a listening port alone is never
trusted" liveness semantics unchanged. This is a pure internal-latency fix;
it changes no external behavior, output shape, or test expectation other
than wall-clock time, and is covered by a new performance check asserting
total detection time stays bounded regardless of catalog size.

**Alternatives considered**: caching the previous sync's result and only
re-probing on a timer — rejected; it would violate FR-001's "re-detect it on
every toolkit sync so the recognized set always reflects what llmctl is
actually running right now" requirement, trading correctness for speed when
the actual fix (parallelizing independent, already-bounded probes) achieves
both.

## 6. Technical Context resolutions (for plan.md)

| Field | Resolution |
|---|---|
| Language/Version | Bash (POSIX-leaning, Bash 5), matching the whole toolkit; no new language introduced. |
| Primary Dependencies | `jq` (JSON parsing of `llmctl plan --json` / `/v1/models`), `curl` (liveness probing), `ss` (new — reading real socket bind address for FR-009), existing `cma_run_provider`/`cma_run_kimi_provider`/`cma_run_pi_provider` wrappers. |
| Storage | N/A — no new persistent storage; existing provider-record/status.json mechanisms are reused. |
| Testing | The toolkit's existing hermetic sandbox harness (`tests/lib/assert.sh`, `tests/lib/sandbox.sh`) for unit/integration, extended with a new live-test layer following `verify_superpowers_tui.sh`'s existing pattern for the real-model checks. |
| Target Platform | Linux + macOS (same hosts the toolkit already targets); llmctl itself is explicitly Linux/macOS-only, matching. |
| Project Type | CLI tool / shell-script library (no new project type). |
| Performance Goals | Detection overhead bounded by the slowest single profile's timeout (≤ ~3–10s), not the sum across the catalog (§5); no perceptible delay to interactive shell startup on a host with zero or few llmctl profiles. |
| Constraints | No changes to `../llmctl`'s own codebase (clarified scope); every llmctl-backed model launch/stop goes strictly through llmctl's own commands (§3.E); live-test execution stays inside this constitution's `§12.6` memory ceiling and `§12.11` dynamic-resource rules. |

## 7. llmctl-Side Findings register (for tracking per FR-010a)

| ID | Finding | Confidence | File:line |
|---|---|---|---|
| LLMCTL-F1 | No machine-readable status/running-state command; only an undocumented `.run` marker-file format | Confirmed (code read) | `lib/scheduler.sh:75-90,753-780`; `lib/common.sh:39` |
| LLMCTL-F2 | Switch rollback is best-effort; "rollback also failed" has no distinct machine-readable signal | Confirmed (code read) | `lib/scheduler.sh:661-665` |
| LLMCTL-F3 | Colibri profiles crash-loop under the LAN-exposed bind default unless `COLI_ALLOW_INSECURE_BIND=1` | Confirmed (code read) | `lib/scheduler.sh:295-313` |
| LLMCTL-F4 | `vision` profile fails tool-calling outright (model-capability limit); `small`/`moe-fast` CPU-timeout fix not re-verified live | Confirmed (dated project history); needs fresh live re-verification | `docs/CONTINUATION.md:983-1065,1304+` |
| LLMCTL-F5 | llmctl's own memory/overcommit accounting only covers processes launched through its scheduler | Confirmed (documented incident) | `docs/CONTINUATION.md:1018-1029` |
