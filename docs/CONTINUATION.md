# CONTINUATION — claude_toolkit

**Last updated:** 2026-07-28
**Last commit:** `main @ 5474545` — *feat: auto-start HelixLLM for helixagent alias (v1.26.6)*
**Working tree:** **DIRTY** — the whole `v1.26.7` payload is uncommitted (see §1.2)
**Active branch:** `main`
**Declared version:** `1.26.7` (`package.json`, `CHANGELOG.md` entry dated 2026-07-27) — **not tagged, not released**
**Next action:** commit + tag + push the `v1.26.7` payload (§2). Everything in it is written and the hermetic suite is green; nothing is half-implemented.

> **How to read this file.** §1 is the *current* state — trust it. §2 is what remains. §3 is the honest evidence snapshot. §4 collects known gaps. §5 is a dated archive of superseded programme history, kept only so a reader can date a claim they find elsewhere; **nothing in §5 describes the tree as it is today.**

---

## 0. Out-of-the-box resumption

A fresh session resumes by reading, in order:

1. `CLAUDE.md` at the repo root — the authoritative architecture + invariants document (`AGENTS.md`, `QWEN.md`, `GEMINI.md` are byte-lockstep mirrors of it; keep all four in step on any edit).
2. this file (`docs/CONTINUATION.md`).
3. the top entry of `CHANGELOG.md` (currently `## v1.26.7`), which carries the per-defect forensics for the release in flight.

Then `git fetch --all --prune` and `git status` — the tree is expected to be dirty (§1.2).

> **Correction (2026-07-28).** Earlier revisions of this file told the reader to open `.remember/remember.md` FIRST and referred §4 "Binding constraints" to it. **That file does not exist** — `.remember/` contains only `.gitignore`, `logs/` and `tmp/`. Both references were dangling and have been removed; the binding constraints now live in §4.3 of this file and in `CLAUDE.md`.

---

## 1. Current state

### 1.1 Version and release status

| Fact | Value | Where verified |
|---|---|---|
| `package.json` version | `1.26.7` | `package.json` |
| Top `CHANGELOG.md` entry | `## v1.26.7 — 2026-07-27` | `CHANGELOG.md:5` |
| Latest commit | `5474545` (subject stamped `v1.26.6`) | `git log -1` |
| Latest tag of any kind | `claude_toolkit-1.26.1` | `git tag` (86 tags total) |
| Tags for 1.26.5 / 1.26.6 / 1.26.7 | **none** | `git tag \| grep 1.26` |

Two numbering facts a reader will otherwise re-derive:

- **`1.26.2`, `1.26.3` and `1.26.4` were never used** by any commit or tag; the sequence jumps `1.26.1 → 1.26.5`. Pre-existing, recorded rather than silently inherited.
- **The tag prefix changed mid-stream.** Everything up to `v1.26.0` carries the bare `v` prefix; `claude_toolkit-1.26.1` is the first (and so far only) tag on the `claude_toolkit-<ver>` convention. New tags use the `claude_toolkit-` form.
- **Owned submodules do not carry the release prefix** (`llmsverifier-v1.12.2`, `helixcode-v1.1.0`, `v0.4.9`). Standing deviation, flagged not fixed.

### 1.2 What is uncommitted

The `v1.26.7` payload sits in the working tree. Non-proof changes:

```
 M CLAUDE.md AGENTS.md QWEN.md GEMINI.md      # router-selector + Go-toolchain sections
 M CHANGELOG.md README.md (+ .html/.pdf/.docx renders)
 M Claude_Multi_Account_Fine_Tuning.md
 M package.json package-lock.json             # 1.0.0 -> 1.26.7
 M docs/Provider_FAQ.md
 M scripts/lib.sh                             # helix autostart opt-in, alias-file self-containment
 M scripts/claude-ccr-build.sh                # vendored-Go `command -v` probe + honest failure text
 M scripts/providers-semantic.sh              # layer-3 verdict reads the driver's reason
 M scripts/verify_superpowers_tui.sh          # stream-aborted vs dialog-hang discrimination
 M scripts/tests/verify_providers_live.sh scripts/tests/verify_aliases_live.sh
 M scripts/tests/test_{output_tokens,128k_output_clamp,ccr_build,layer4_route_attribution}.sh
 M submodules/{LLMsVerifier,challenges,claude-code-router}   # pointer bumps
?? scripts/tests/test_proxy_daemon_stdio.sh
?? scripts/tests/test_failure_cause_attribution.sh
?? scripts/tests/test_alias_file_selfcontained.sh
```

Plus a large churn under `scripts/tests/proof/` (regenerated evidence, some files newly untracked).

### 1.3 Submodule pointers

| Submodule | Pinned at | Pushed? | Note |
|---|---|---|---|
| `submodules/LLMsVerifier` | `2a105fe7` (`llmsverifier-v1.12.2-12-g2a105fe7`) | detached HEAD | +6 over the previous pointer |
| `submodules/challenges` | `2e3ef88` (`helixcode-v1.1.0-18-g2e3ef88`) | detached HEAD | +2 |
| `submodules/claude-code-router` | `9accd18` (`v0.4.9-5-g9accd18`) | **yes** — `origin/main` is 0 ahead / 0 behind | carries the release-blocking selector fix |
| `submodules/go` | `a9ce111` = **`go1.26.4`** | — | **deliberately held**; see below |
| `submodules/containers` | `a432efa` | — | 136 behind; not on any toolkit code path, deferred |

**`submodules/go` must never be bumped to `origin/master`.** That is the unreleased next-major dev tree and carries **no `VERSION` file**, which `claude-go-build.sh` requires — presence check at `:35`, parse hard-fails `exit 1` at `:45-51`. Only point releases on `release-branch.go1.N` are valid bump targets, and a bump must be followed by `claude-go-build` + `claude-ccr-build` + the live router legs.

### 1.4 Test suite

**58 test files** on disk (`ls scripts/tests/test_*.sh | wc -l`). Three are new in this release:

- `test_proxy_daemon_stdio.sh` — the backgrounded `cma-proxy` must redirect its own stdio (26 cases; RED 15/26 pre-fix). Its behavioural cases **extract and execute the shipped spawn line out of the generated alias file**, so a comment that merely looks like a fix cannot satisfy them.
- `test_failure_cause_attribution.sh` — no failure message may assert a cause its own evidence contradicts (50 cases; RED 14/50 pre-fix). Drives the real script through its `CMA_SEMANTIC_DRIVER` seam.
- `test_alias_file_selfcontained.sh` — the **generated** alias file may not call `lib.sh`-only helpers, because the user's interactive shell sources that file and never sources `lib.sh` (7 cases; RED 4/7 pre-fix).

> The captured proof bundle (`scripts/tests/proof/40-sandbox-suite.log`) records `Test files: 57 … ALL GREEN` — that run pre-dates the newest of the three additions. The CHANGELOG records a subsequent `Test files: 58   passed: 58   failed: 0   ALL GREEN`. **Re-run `bash scripts/tests/run-all.sh` before the release commit so the bundle and the tree agree.**

### 1.5 Provider fleet

From `~/.local/share/claude-multi-account/providers/status.json` (host state, not repo state):

| Status | Count |
|---|---|
| `verified` (launchable) | **24** |
| `unverified` (created, launch gate refuses) | 5 |
| `failed` | 25 |
| `orphaned` | 3 |
| **total** | **57** |

Most `failed` entries are account-side (unfunded keys, suspended accounts, rejected credentials), not toolkit defects — `providers-semantic.sh` now prints the driver's own reason (`non-200 status 401/402/403/404`) instead of blanket-blaming a bluff, so the distinction is readable straight off the evidence file.

### 1.6 Behaviours this release turns on

- **Vendor-prefixed model ids route again.** `internal/router/selector.go` treated `,` and `/` as equally trustworthy separators. A comma is this project's own on-disk route syntax and appears in no model id, so an unknown provider stays a loud caller error. A slash is ambiguous — it is both Node CCR's `Provider/model` wire format *and* the near-universal `vendor/model` catalog convention. Once `lib.sh` (`a5e396d`) began exporting `ANTHROPIC_MODEL` for the **router** transport too, the gateway read the *vendor* as a provider name, found none configured, and returned an unknown-provider error instead of falling through to `Router.default`: **503 in 1-4 ms, before any network call**, retried until the 180s launch bound expired. Blast radius **16 of the 24 verified aliases** — every one whose `CMA_PROVIDER_MODEL` carries a prefix, `helixagent` (`HelixAgent/HelixLLM`) included. The slash form is now decided from **evidence**: if a configured provider serves the whole string it is a catalog id; if nobody serves it the unknown-provider error still stands. Fixed in `9accd18`, covered by `internal/router/vendor_prefixed_model_test.go`.
  **Why layers 1-3 were green throughout:** `providers-verify.sh` and `providers-semantic.sh` curl the provider's own `base_url` directly and never touch the ccr route path. Only the layer-4 live launch exercises the real chain — which is exactly why `claude-release-gate.sh` is mandatory before a release commit.
- **HelixLLM auto-start is OPT-IN** (`CMA_HELIX_AUTOSTART`, default **off**). See §1.7.
- **`claude-ccr-build.sh` can actually fall back to system Go.** `VENDORED_GO="${VENDORED_GO:-…}"` assigns a path *string* unconditionally, so `${VENDORED_GO:-go}` could never reach its `:-go` branch; with `~/.local/share/claude-go` absent on a normal install the build exec'd a missing file (exit 127). A `command -v "$_go_bin"` probe (`:163`) is the whole fallback. The failure text no longer names a cause the script cannot observe.

### 1.7 `CMA_HELIX_AUTOSTART` — default OFF

`cma_run_provider` probes HelixLLM's `/health` for `context_limit` before launching a `helixagent*` alias. When HelixLLM is not answering:

- **Default (`CMA_HELIX_AUTOSTART` unset or not one of `1|true|yes|on`)** — the alias does **not** start anything. It warns that auto-start is off, and prints both the manual command and the opt-in form. Booting HelixLLM claims the single GPU and **evicts HelixCode's coder mode**; a provider alias must not do that to a host merely because someone launched it.
- **Opt-in (`CMA_HELIX_AUTOSTART=1 helixagent`)** — searches four known locations for `helixllm-mode.sh`, starts it in claude mode, and polls `/health` for up to 120s.
- **Already running in coder mode (`context_limit=24576`)** — warns regardless of the knob; the first request (~67K system+tools) would immediately overflow.

The pre-flight's messages route through `_hl_log` / `_hl_warn`, which print through `cma_log`/`cma_warn` when those exist and through `printf` when they do not. This is load-bearing: the alias file is sourced by the user's interactive shell and **never sources `lib.sh`**, so the six bare calls added by `5474545`/`bee402a` printed `cma_warn: command not found` exactly where the coder-mode remedy belonged. For this pre-flight the message *is* the feature.

### 1.8 Token guards — the arithmetic that now applies

`lib.sh` exports both halves, **co-derived** so they can never sum past the context:

1. **Carve** the output cap out of the context: `out = min(context − CMA_INPUT_FLOOR(160000), 128000)`, floored at 8192.
2. **Window** = `context − out − CMA_TOOL_TOKEN_BUDGET(80000)`, capped at `CMA_AUTO_COMPACT_CAP(200000)`.
3. **Compression-loop guard** — *only if* that window lands below `CMA_MIN_COMPACT_WINDOW(120000)`, buy it back out of the output cap: `out = context − 120000 − 80000`, window = `120000`.

Worked example, a 262144-context provider: carve gives `out=102144`, window `262144−102144−80000 = 80000 < 120000`, so the guard rebalances to `out=62144`, `window=120000` — an exact fit (`62144+120000+80000 = 262144`).

**The honest limit, measured 2026-07-27 on this host: 227 enabled plugins produce 158112 tokens of tool input.** Since `158112 + 120000 > 262144`, **no output cap makes a 262144-context provider fit on such a host.** The enabled-plugin surface has to shrink, or a wider-context provider must be used — nvidia (1000000) and xiaomi (1048576) fit comfortably. Override per host with `CMA_TOOL_TOKEN_BUDGET`.

Be exact about the direction of danger: an **under**estimate of the tool budget does not merely compact earlier — because the output cap is derived as `ctx − min_win − budget`, too small a budget **inflates** the output cap and the request overflows with a 400.

---

## 2. What remains before the release is out

1. **Re-run the hermetic suite** (`bash scripts/tests/run-all.sh`) so the proof bundle records 58, not 57.
2. **Run the mandatory gate:** `bash scripts/claude-release-gate.sh`. It is fail-closed and layer 2 is the only thing that exercises the real ccr route path — the exact blindness that let the selector bug ship.
3. **Commit** the payload in §1.2 (submodule pointer bumps included — `claude-code-router` `9accd18` is already on its `origin/main`, so the pointer will not dangle).
4. **Tag** `claude_toolkit-1.26.7` and push across the four-way remote fan-out (`github`, `gitlab`, `gitflic`, `gitverse`). No force-push, ever.
5. Optionally re-run `bash scripts/tests/run-proof.sh` to refresh `scripts/tests/proof/PROOF.md`.

---

## 3. Evidence snapshot (`scripts/tests/proof/PROOF.md`, generated 2026-07-27T19:58:08)

The proof bundle is **honest, not all-green** — three legs exit non-zero and `PROOF.md` reports them faithfully rather than hiding them:

| Leg | Result | Exit |
|---|---|---|
| Sandbox suite (hermetic) | `Test files: 57  passed: 57  failed: 0  ALL GREEN` | 0 |
| Live OpenCode verification | `9 passed, 0 failed` (`skills_resolved=1356`, `mcp_connected=26`, `instructions=1`) | 0 |
| Live provider-alias verification | `10 failed, 42 passed` | 1 |
| Live alias verification | `PASS 23  FAIL 1  SKIP-GATED 30  TOTAL 56` | 1 |
| Live alias end-to-end | `total 56, passed 20, failed 2` | 1 |
| Constitution / conformance (Tier C) | `7 passed, 0 failed` | 0 |

Layer-4 route attribution is now recorded per alias. Post-fix spot checks in the bundle: `kilo` (`kilo/nvidia/nemotron-3-super-120b-a12b:free`) and `nvidia` (`nvidia/nvidia/nemotron-3-nano-omni-30b-a3b-reasoning`) both carry `# ROUTE-RESOLVED:` matching `# ROUTE-INTENDED:` and `# PASS` — vendor-prefixed ids that would have 503'd before `9accd18`.

**Evidence hygiene rule established this release:** an evidence file may not carry a label its own captured JSON contradicts. `providers-poe3-*.txt` were deleted rather than shipped for exactly that reason (a `# FAIL: timeout` label over a JSON recording `"terminal_reason":"aborted_streaming"`), and a sweep confirms no remaining file is in that state. **The `scripts/tests/proof/` directory holds files of mixed vintage** (2026-07-18 through 2026-07-27) — always read the timestamp inside a file before quoting it as current.

---

## 4. Known gaps / deferred

### 4.1 Gaps introduced or left open by this release

- **Nothing bumps `package.json`.** There is no `VERSION` file and `claude-release-gate.sh` has no version reference, so `1.26.7` will silently re-stale. Worse than the old obvious `1.0.0` scaffold, because a bumped-once number *looks* maintained. Add it to the release checklist.
- **`CMA_HELIX_AUTOSTART` has no test.** `grep -rl CMA_HELIX_AUTOSTART scripts/tests/` returns nothing — neither the default-off branch nor the opt-in parse (`1|true|yes|on`) is pinned by the suite.
- **`shellcheck` is clean only at `-S error` (0).** Warning level reports **62**, style level **203**. The README badge now says `0 errors` rather than implying a clean lint at every severity.
- **`submodules/containers` is 136 behind** and deliberately not absorbed during a release window.

### 4.2 Long-standing

- `submodules/LLMsVerifier/CONSTITUTION.md` is **~284 KB** (290,921 bytes) and exceeds the 256 KB Read limit — use `offset`/`limit` or `grep`. (Earlier revisions of this file said 282.2 KB; it grows.)
- Owned submodules do not carry the `claude_toolkit-` release prefix (§1.1).
- The Go port of the TOON encoder (`scripts/toon/`) is built and tested but **nothing in the toolkit invokes it** — see `docs/TOON_Integration.md`.

### 4.3 Binding constraints (unchanging)

SSH-key-only remotes; **no force-push**; no silent removals; every change reviewed; release-tag prefix from `HELIX_RELEASE_PREFIX` or the lowercased project root (`claude_toolkit-<ver>`, no `v`); CI/CD disabled; `AGENTS.md`/`QWEN.md`/`GEMINI.md` kept in byte-lockstep with `CLAUDE.md`; submodules decoupled from consumer names (CONST-051); no fixes without a root cause (§11.4.102); no failure message may name a cause its own evidence contradicts (§11.4.201(1)).

---

## 5. Archive — superseded programme history

> **Everything below is dated and superseded.** It is retained so a reader who finds one of these claims quoted elsewhere can date it. None of it describes the tree as it is today.

### 5.1 Release log (condensed)

| Version | Landed | One-line |
|---|---|---|
| v1.26.7 | 2026-07-27 (uncommitted) | vendor-prefixed ids routable; vendored-Go fallback; four misattributed failure messages retired |
| v1.26.6 | `5474545` | HelixAgent auto-start + mode pre-flight (auto-start later made opt-in, §1.7) |
| v1.26.5 | `bb29346` | `claude-ccr-build` `_built_ok` never set on a successful build; vendored Go integration |
| v1.26.1 | `claude_toolkit-1.26.1` | ccr buildable on same-minor toolchains; launch locks that actually lock |
| v1.26.0 | `v1.26.0` | free-tier-first per-model aliases by default; dynamic account dispatch; provider-scoped gateway paths |
| v1.25.5 | `79529be` | fail-loud install + anti-fossil hardening |
| v1.25.4 | `18780db` | un-fossilise the `cma-proxy` address; TOON Go port |
| v1.19.0 | `fec3c4f` | all active providers routed through ccr uniformly; `curl -4` IPv4 fix |
| v1.18.x | `0e30dfb`, `b51228e` | ccr identity guard moved to `ccr --help`; alias-file migration marker |
| v1.12.x | — | kebab-case session names; auto-registered `claudeN` aliases; judge-family independence |

Full forensics for every entry live in `CHANGELOG.md`.

### 5.2 Provider-verification programme (2026-06-16 → 2026-07-19) — **COMPLETE**

All three phases shipped. The four-layer verification pipeline (existence → semantic code-visibility → live superpowers TUI → route attribution), the `list` / `list-all` / `list-faulty` split, the launch gate that refuses non-`verified` aliases, per-alias config dirs, and the install-time session sync are all in the tree and documented in `docs/Provider_Verification_Guide.md` and `docs/Provider_FAQ.md`.

Design and plan artifacts, kept for provenance:

- `docs/superpowers/specs/2026-06-16-provider-aliases-design.md`
- `docs/superpowers/specs/2026-07-04-provider-verification-design.md`
- `docs/superpowers/plans/2026-07-04-provider-verification-plan.md`
- `docs/superpowers/plans/2026-07-05-phase2-semantic-live-plan.md`
- `docs/superpowers/plans/2026-07-08-provider-status-and-shared-files-fix-plan.md`

### 5.3 Items this file previously listed as pending, now closed

| Was listed as | Actual state (2026-07-28) |
|---|---|
| "Phase 2 (semantic + live) — toolkit wiring is the remaining implementation" | **Shipped.** `scripts/claude-semantic-visibility.sh`, `scripts/providers-semantic.sh`, `scripts/verify_superpowers_tui.sh` all exist and run in the proof suite. |
| "Phase 3 (docs + release) — deferred, separate plan" | **Shipped** (`7f2d86e`, `a64eec1`), and eleven further releases have landed since. |
| "CONST-052 ID collision — renumber draft, land in Phase 3" | **Resolved** as CONST-069. |
| "GEMINI.md lockstep — Phase-3 release blocker" | **Resolved** (`1c53562`); all four root mirrors are maintained in lockstep. |
| "Go command committed INSIDE the submodule at `a48c03a5`, LOCAL-ONLY, must be pushed first" | **Long superseded.** `submodules/LLMsVerifier` is at `2a105fe7`, hundreds of commits later. |
| "11 providers still failing (account-side)" | Now **25 `failed` / 5 `unverified` / 24 `verified`** of 57 (§1.5). |
| "`.remember/remember.md` — read FIRST" | **File does not exist.** Reference removed (§0). |
| "The `AskUserQuestion` call must be re-issued with `label` fields" | Session-scoped tooling note; no longer applicable to this repo. |
| "Full suite 27/27 green" / "20/20" / "14 suites" | All stale counts. **58 test files** (§1.4). |

---

## 6. Update protocol

Every commit that advances state MUST update this file in the SAME commit (§6.S / §11.4.131). The header block's **Last updated** / **Last commit** / **Working tree** lines MUST track reality. **A stale CONTINUATION is a CRITICAL DEFECT** — a hand-off document that describes a state that no longer exists is worse than no hand-off at all, because it is believed.
