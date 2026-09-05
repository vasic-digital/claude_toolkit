# FR-037 Resolution — canonical repo name + review-branch merge state (F4-005 decision note)

- Date: 2026-09-05
- Task: W2d-1 (local-only adaptive serving, Wave 2d)
- Scope: FR-037 canonical-repository resolution; evidence that
  `fix/helixllm-export-review-findings` is already merged into local main;
  Wave-4 push plan for the controller
- Companion doc: `docs/qa/2026-09-05-gap-ledger.md` (F4-001 … F4-005)

## 1. Canonical-name resolution

**Canonical name: `vasic-digital/claude_toolkit` (underscore).**
`vasic-digital/claude-toolkit` (hyphen) is a GitHub rename-alias of the SAME
physical repository, not a second repo.

Evidence (captured live 2026-09-05):

```
$ gh repo view vasic-digital/claude_toolkit --json name,id,createdAt
{"createdAt":"2026-05-26T05:03:01Z","id":"R_kgDOSn8-DQ","name":"claude_toolkit"}
$ gh repo view vasic-digital/claude-toolkit --json name,id,createdAt
{"createdAt":"2026-05-26T05:03:01Z","id":"R_kgDOSn8-DQ","name":"claude_toolkit"}
```

Identical repo id (`R_kgDOSn8-DQ`) and identical creation timestamp for both
names; GitHub reports the canonical name as `claude_toolkit`. GitLab also
resolves the hyphen form to the underscore repo; GitFlic hosts ONLY the hyphen
name (`vasic-digital/claude-toolkit.git`) — there is no underscore repo there
(spec research `05-consumer-integration.md` §2, live-verified 2026-09-02).

Implication: any clone/fetch URL may use either name on GitHub/GitLab (the
hyphen works only via redirect), but every declarative reference (`.gitmodules`,
bootstrap `REPO_URL`, docs) should use the canonical underscore form to be
CONST-052-compliant and redirect-independent. F4-005 (this task) fixes
`scripts/curl-install.sh:20`; F4-001 (controller, helix_code) fixes
`.gitmodules:519`. GitFlic checkouts keep the hyphen push-url in their local
remote config — that is the only mirror where the hyphen name is real.

## 2. No-op merge evidence — fix branch is already fully merged

Local branch `fix/helixllm-export-review-findings` (`0cb55a1`) vs local main
(`672f89b`):

```
$ git rev-list --left-right --count fix/helixllm-export-review-findings...main
0	4        # 0 commits only on fix side, 4 commits only on main side
$ git merge-base --is-ancestor fix/helixllm-export-review-findings main
exit 0    # fix IS an ancestor of main — merge already happened
```

Conclusion: merging the review branch into main is a **no-op**; nothing to
merge. The branch is fully contained in main and exists on the mirrors only as
history — safe to retire after main lands (§3).

Local main is **11 ahead / 0 behind** every mirror's main. The 11 unpushed
commits = 8 review-branch commits (`8ecf6aa`, `1feda4b`, `37c4f48`, `e8e877a`,
`328cf27`, `267182b`, `fdeef17`, `0cb55a1`) + merge commit `3871136` + 2
kimi-code-support plan/docs commits (`430822b`, `672f89b`).

## 3. Mirror state (live ls-remote, captured 2026-09-05)

| Mirror | Remote URL | `main` | `fix/helixllm-export-review-findings` |
|---|---|---|---|
| GitHub | `git@github.com:vasic-digital/claude_toolkit.git` | `6b7e70c` | `0cb55a1` |
| GitLab | `git@gitlab.com:vasic-digital/claude_toolkit.git` | `6b7e70c` | `0cb55a1` |
| GitFlic | `git@gitflic.ru:vasic-digital/claude-toolkit.git` | `6b7e70c` | `0cb55a1` |
| GitVerse | `git@gitverse.ru:vasic-digital/claude_toolkit.git` | `6b7e70c` | `0cb55a1` |
| local main | — | `672f89b` (11 ahead) | local fix `0cb55a1` (ancestor of main) |

Full SHAs: main tip on all four mirrors
`6b7e70c10d5200cf6238225b5a350d6014713cec`; fix tip on all four mirrors
`0cb55a1876423f3245be02bbb08489918d8eba03`; local main
`672f89b70f16a38c5368349e8a7c52c086783b3b`.

F4-003 correction (already applied in the gap ledger): the earlier claim that
`github/fix` was stale at `fdeef17` was read from a stale local *tracking ref*.
Live `ls-remote` shows all four mirrors already carry `0cb55a1`; no mirror
divergence exists. Residual action is branch retirement only.

## 4. Wave-4 push plan (controller-owned; nothing pushed by W2d-1)

Checklist, in order:

1. [ ] Fetch all mirrors (`git fetch --all --prune`) and re-confirm tips before
       pushing — mirror state is only knowable from a fresh fetch (§11.4.71).
2. [ ] **F4-002 — ff-push main**: `git push github main` then gitlab, gitflic,
       gitverse. Must be a fast-forward of `6b7e70c` → `672f89b` on every
       mirror; §11.4.113 ff-only, **never force**. After each push verify
       `git ls-remote <mirror> refs/heads/main` == `672f89b...` and
       `git rev-list --count <mirror>/main..main` == 0.
3. [ ] **F4-003 — retire fix branch** on all four mirrors
       (`git push <mirror> --delete fix/helixllm-export-review-findings`) —
       only AFTER main lands and the ancestor check still passes
       (`git merge-base --is-ancestor fix main`, exit 0). Verify absence with
       `git ls-remote <mirror> 'refs/heads/fix/*'` returning empty.
4. [ ] **F4-001 (helix_code)** — point `.gitmodules:519` at
       `git@github.com:vasic-digital/claude_toolkit.git`, `git submodule sync`,
       keep the GitFlic hyphen push-url in the checkout config (GitFlic has no
       underscore repo). Verify: declared URL ls-remote == canonical ls-remote.
5. [ ] **F4-004 (helix_code)** — in `submodules/claude-toolkit`: fetch, ff
       checkout to `672f89b`, then bump the helix_code submodule pointer as its
       OWN commit (§11.4.124). Verify: `git -C submodules/claude-toolkit
       rev-parse HEAD` == `672f89b`; suite legs
       `run-all.sh helixllm_model_export provider_validation session` green
       inside the submodule checkout.
6. [ ] Do NOT push anything else from this repo's working tree: other modified
       files (kimi-code-support docs/scripts in progress) belong to other
       work-streams and must not ride along on Wave 4 (§11.4.84 quiescence).

## 5. What W2d-1 changed here

- `scripts/curl-install.sh:20` — `REPO_URL` now the canonical
  `https://github.com/vasic-digital/claude_toolkit.git` (F4-005).
- `scripts/tests/test_curl_install.sh` — REPO_URL assertion switched to the
  canonical form (legacy hyphen form explicitly asserted absent), plus a
  hermetic sandboxed bootstrap dry-run (`sandbox_stub`'d `git` records the
  clone invocation; asserts `git clone --recursive` was called with the
  canonical URL; no network, no real `~/.claude` state).
- This note + the gap ledger, committed as
  `docs(qa): F4 gap ledger + FR-037 resolution note (W2d-1)`.
