# Gap Ledger — Task F4: toolkit/exporter (spec 002, FR-037 + review-branch merge)

- Date: 2026-09-05
- Author: forensic extraction agent (read-only; no git mutations performed — controller owns all commits)
- Scope: FR-037 canonical-repo resolution; state of `fix/helixllm-export-review-findings`; merge entailments

## FR-037 — which repo is canonical

**Canonical GitHub/GitLab repository: `vasic-digital/claude_toolkit` (underscore).** The hyphen
name `vasic-digital/claude-toolkit` is a GitHub rename-redirect alias of the SAME physical
repository — not a second repo.

Evidence (captured live 2026-09-05):

```
$ gh repo view vasic-digital/claude_toolkit --json name,id,createdAt
{"createdAt":"2026-05-26T05:03:01Z","id":"R_kgDOSn8-DQ","name":"claude_toolkit"}
$ gh repo view vasic-digital/claude-toolkit --json name,id,createdAt
{"createdAt":"2026-05-26T05:03:01Z","id":"R_kgDOSn8-DQ","name":"claude_toolkit"}
  → identical repo id + creation timestamp for both names; GitHub reports the canonical name as claude_toolkit

$ git ls-remote git@github.com:vasic-digital/claude_toolkit.git HEAD → 6b7e70c...
$ git ls-remote git@github.com:vasic-digital/claude-toolkit.git HEAD → 6b7e70c...
$ git ls-remote gitlab/gitverse (underscore form) HEAD → 6b7e70c...   (GitLab redirects hyphen → underscore too)
$ git ls-remote gitflic (hyphen form only; underscore repo does not exist there) → 6b7e70c...
```

Per-name mirror availability (matches spec research `05-consumer-integration.md` §2): GitHub +
GitLab + GitVerse canonical = underscore; GitFlic = hyphen only (no underscore repo). Both local
checkouts push to the identical four-URL push set; they differ only in the `origin` FETCH url
(standalone fetches underscore, `helix_code/submodules/claude-toolkit` fetches hyphen — works
only via GitHub's redirect).

## Repo / branch state (captured live)

| Repo / ref | Commit | State |
|---|---|---|
| `/home/milosvasic/Projects/claude_toolkit` main | `672f89b` | **11 ahead, 0 behind** `github/main`; unpushed anywhere |
| `/home/milosvasic/Projects/claude_toolkit` fix/helixllm-export-review-findings (local) | `0cb55a1` | **0 ahead, 4 behind** local main → fully merged into local main already |
| `github/fix/helixllm-export-review-findings` | `fdeef17` | stale: missing `0cb55a1` (1 behind local fix) |
| `gitlab`,`gitverse`,`gitflic` fix branch | `0cb55a1` | in sync with local fix |
| ALL mirrors' `main` | `6b7e70c` | 11 commits behind local main `672f89b` |
| `helix_code/submodules/claude-toolkit` (checkout + pointer) | `6b7e70c` | clean, but 11 commits behind canonical local main; no local fix branch |

The 11 unpushed main commits = 8 review-branch commits (`8ecf6aa` fix(helixllm-export): corrupted
model names…, `1feda4b`, `37c4f48`, `e8e877a`, `328cf27`, `267182b`, `fdeef17`, `0cb55a1`) +
`3871136` merge + 2 kimi-code-support plan/docs commits (`430822b`, `672f89b`).

## Merge plan (for the controller — nothing executed here)

1. Review branch → canonical main: **no-op** — `0cb55a1` is an ancestor of local main
   (`git rev-list --left-right --count fix...main` = `0 4`). Merging = already done locally.
2. ff-push local main `672f89b` to github + gitlab + gitflic + gitverse (fast-forward only,
   §11.4.113 — no force ever needed).
3. Reconcile `github/fix/helixllm-export-review-findings`: ff-push `0cb55a1` (or retire the
   branch after main lands, since it is fully contained).
4. Bring `helix_code/submodules/claude-toolkit` to `672f89b` (fetch + ff checkout), then bump
   the helix_code submodule pointer as its OWN commit (§11.4.124).
5. Fix `.gitmodules:519` URL to the canonical underscore form + `git submodule sync` (entry F4-001).

## Gap ledger

| id | repo | severity | file | defect | fix_direction | test_plan |
|---|---|---|---|---|---|---|
| F4-001 | helix_code | high | `.gitmodules:517-519` | Submodule `submodules/claude-toolkit` declared with legacy hyphen URL `git@github.com:vasic-digital/claude-toolkit.git`; canonical repo is `claude_toolkit.git` (gh id `R_kgDOSn8-DQ`). Works today only via GitHub rename-redirect; CONST-052-non-compliant and redirect-dependent. | Point `.gitmodules` url at canonical `git@github.com:vasic-digital/claude_toolkit.git`; `git submodule sync`; keep GitFlic hyphen push-url in the checkout config (GitFlic has no underscore repo). | (1) `grep url .gitmodules` shows canonical underscore URL; (2) `git ls-remote <declared-url> HEAD` == `git ls-remote git@github.com:vasic-digital/claude_toolkit.git HEAD`; (3) fresh-clone submodule init resolves without redirect warning. |
| F4-002 | claude_toolkit | high | repo-wide | Local main `672f89b` is 11 ahead / 0 behind `github/main`; mirrors gitlab/gitflic/gitverse `main` also at `6b7e70c` — the entire review-branch merge + kimi-code plan work exists only on the local standalone checkout. Release (FR-036) pushed today would publish the pre-review state. | ff-push main to all four mirrors; verify each with `git ls-remote` post-push; never force. | For each mirror: `git rev-list --count <mirror>/main..main` == 0 and `git ls-remote <mirror> HEAD` == `672f89b`. |
| F4-003 | claude_toolkit | medium → **resolved** | `fix/helixllm-export-review-findings` | ~~Local fix branch fully merged into local main (0 ahead, 4 behind) but `github/fix` is stale at `fdeef17` (missing `0cb55a1`)~~ — **CORRECTED 2026-09-05 (review agent-13 + controller re-verification):** live `git ls-remote origin refs/heads/fix/...` returns `0cb55a1`; the `fdeef17` figure was a stale local *tracking ref*, never a live remote state. All four mirrors already carry `0cb55a1`; the original "divergent mirror tips" defect does not exist. Entry closed as resolved; only residual action is retiring the branch on all mirrors after main lands. | Retire `fix/helixllm-export-review-findings` on all four mirrors after F4-002 main lands (branch fully contained in main). | `git merge-base --is-ancestor fix/helixllm-export-review-findings main` exit 0; branch absent on all mirrors (or all tips equal `0cb55a1` until retirement). |
| F4-004 | helix_code | high | `submodules/claude-toolkit` (pointer `6b7e70c`) | Submodule checkout is 11 commits behind canonical main — all 8 helixllm-export review fixes (corrupted model names, misdirected credential, add-only --apply, withheld-guard test, endpoint repointing, TLS CA at launch, etc.; 33 files, +4044/-229) absent from the checkout that spec-002 consumer work builds/tests against. | After F4-002 ff-push: fetch canonical main in the submodule checkout, ff to `672f89b`, bump helix_code pointer as its own commit (§11.4.124). | `git -C submodules/claude-toolkit rev-parse HEAD` == `672f89b`; `bash scripts/tests/run-all.sh helixllm_model_export provider_validation session` green inside the submodule checkout; `git diff fix..HEAD` empty in checkout. |
| F4-005 | claude_toolkit | low | `scripts/curl-install.sh:20` | Bootstrap `REPO_URL="https://github.com/vasic-digital/claude-toolkit.git"` clones via the legacy hyphen alias instead of the canonical underscore name (redirect-dependent; contradicts the repo's own resolved release prefix `claude_toolkit` per `docs/qa/2026-07-04-constitution-audit/report.md:55`). | Change REPO_URL to `https://github.com/vasic-digital/claude_toolkit.git`. | `grep REPO_URL scripts/curl-install.sh` shows canonical URL; sandboxed dry-run bootstrap clone succeeds and `git -C <clone> remote get-url origin` == canonical URL. |

## Machine-readable entries

```json
[
  {
    "id": "F4-001",
    "repo": "helix_code",
    "severity": "high",
    "file": ".gitmodules:517-519",
    "defect": "Submodule submodules/claude-toolkit declared with legacy hyphen URL (vasic-digital/claude-toolkit.git); canonical repo is vasic-digital/claude_toolkit.git (gh repo id R_kgDOSn8-DQ, both names verified to resolve to the same repository). Works only via GitHub rename-redirect; CONST-052-non-compliant.",
    "fix_direction": "Point .gitmodules url at git@github.com:vasic-digital/claude_toolkit.git, run git submodule sync; retain GitFlic hyphen push-url in checkout config (GitFlic hosts only the hyphen name).",
    "test_plan": "grep .gitmodules shows canonical underscore URL; git ls-remote of declared URL equals ls-remote of canonical URL; fresh submodule init resolves without redirect."
  },
  {
    "id": "F4-002",
    "repo": "claude_toolkit",
    "severity": "high",
    "file": "repo-wide (main)",
    "defect": "Local main 672f89b is 11 commits ahead / 0 behind github/main 6b7e70c; gitlab/gitflic/gitverse main also at 6b7e70c. The merged review branch (8 commits) plus kimi-code plan/docs (2) + merge commit exist only in the local standalone checkout; a release pushed today would publish the pre-review state.",
    "fix_direction": "Fast-forward push main 672f89b to github, gitlab, gitflic, gitverse (ff-only, no force); verify each mirror post-push.",
    "test_plan": "For each mirror: git rev-list --count <mirror>/main..main == 0 and git ls-remote <mirror> HEAD == 672f89b."
  },
  {
    "id": "F4-003",
    "repo": "claude_toolkit",
    "severity": "medium",
    "status": "resolved-2026-09-05",
    "file": "fix/helixllm-export-review-findings",
    "defect": "CORRECTED 2026-09-05: original claim (github/fix stale at fdeef17) was read from a stale local tracking ref. Live ls-remote shows github/fix = 0cb55a1 like all other mirrors; no divergence exists. Entry resolved; residual action is branch retirement after main lands.",
    "fix_direction": "Retire fix/helixllm-export-review-findings on all four mirrors after F4-002 main lands (branch fully contained in main).",
    "test_plan": "git merge-base --is-ancestor fix/helixllm-export-review-findings main exits 0; branch absent on all mirrors (or all tips equal 0cb55a1 until retirement)."
  },
  {
    "id": "F4-004",
    "repo": "helix_code",
    "severity": "high",
    "file": "submodules/claude-toolkit (pointer 6b7e70c)",
    "defect": "Submodule checkout is 11 commits behind canonical main; all 8 helixllm-export review fixes (33 files, +4044/-229: corrupted model names, misdirected credential, add-only --apply, withheld-guard regression test, endpoint repointing, TLS CA wiring, compaction-loop fix) absent from the checkout spec-002 consumer work targets.",
    "fix_direction": "After F4-002 ff-push: fetch canonical main in the submodule checkout, fast-forward to 672f89b, bump the helix_code submodule pointer as its own commit per §11.4.124.",
    "test_plan": "git -C submodules/claude-toolkit rev-parse HEAD == 672f89b; scripts/tests/run-all.sh helixllm_model_export provider_validation session green inside the submodule checkout."
  },
  {
    "id": "F4-005",
    "repo": "claude_toolkit",
    "severity": "low",
    "file": "scripts/curl-install.sh:20",
    "defect": "Bootstrap REPO_URL clones via legacy hyphen alias https://github.com/vasic-digital/claude-toolkit.git instead of canonical underscore name; redirect-dependent and contradicts the repo's own resolved release prefix claude_toolkit (docs/qa/2026-07-04-constitution-audit/report.md:55).",
    "fix_direction": "Set REPO_URL=https://github.com/vasic-digital/claude_toolkit.git.",
    "test_plan": "grep REPO_URL shows canonical URL; sandboxed bootstrap clone succeeds and the cloned origin URL is the canonical one."
  }
]
```

## UNCONFIRMED items

- None — every entry above is backed by command output captured during this extraction
  (gh repo view, git ls-remote per mirror, git rev-list --left-right --count, git diff --stat,
  git status, .gitmodules grep). GitFlic underscore-name absence was taken from spec research
  doc `05-consumer-integration.md` §2 (live-verified 2026-09-02) plus the checkout's own
  GitFlic remote being hyphen-named; not re-probed with a failing ls-remote today.
