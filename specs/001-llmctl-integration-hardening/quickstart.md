# Quickstart Validation: llmctl Integration Hardening & Verified Release

**Feature**: [spec.md](./spec.md) | **Contracts**: [contracts/](./contracts/)

Runnable scenarios proving this feature end-to-end, mapped to the spec's
user stories. These are validation steps, not implementation — the
implementing tasks live in `tasks.md`.

## Prerequisites

- A host with llmctl installed (`../llmctl` relative to this repo, or on
  `PATH`) and at least one profile downloaded (`llmctl models download fast`
  or similar — see llmctl's own quickstart).
- claude_toolkit installed on the same host (`bash scripts/install.sh`).
- For the live-command checks: a real `claude` binary and/or `kimi` binary
  on `PATH`, with the Superpowers plugin installed (already a toolkit
  prerequisite for `verify_superpowers_tui.sh`).

## US1 — Every running llmctl model becomes a ready-to-use alias

```bash
llmctl start fast                 # start one profile directly via llmctl
claude-providers sync             # re-sync claude_toolkit
claude-providers list | grep llmctl-fast   # expect: present, verified
```

**Expected**: exactly one new alias, `llmctl-fast`, labeled with the real
model `fast` serves. Stop it (`llmctl stop fast`), re-sync, and confirm the
alias is gone — never left pointing at a stopped model.

Multi-profile case:

```bash
llmctl start fast coder           # two profiles, if they fit together
claude-providers sync
claude-providers list | grep llmctl-   # expect: llmctl-fast AND llmctl-coder
```

Absence case:

```bash
# on a host with llmctl not installed, or with it installed but nothing running
claude-providers sync             # expect: no error, no llmctl-* alias, plain report
```

## US2 — Switch which llmctl model is active

```bash
llmctl start fast
claude-providers sync             # llmctl-fast now exists
claude llmctl-fast -p "ping"      # confirm it answers
# now switch
cma_run_provider llmctl-coder -p "ping"   # triggers the on-demand switch
llmctl status                      # expect: coder running, fast stopped
```

**Expected**: the switch is exclusive — `fast` stops, `coder` starts, and a
native account alias (`claude1`, say) launched at any point during this
sequence is wholly unaffected.

Refusal case: request a switch to a profile too large to fit alongside
current host load; expect a clear refusal naming what doesn't fit, with the
previously active profile independently confirmed still live afterward
(contracts/alias-behavior-contract.md's FR-007 refinement).

## US3 — Deterministic, evidence-backed proof

```bash
scripts/tests/verify_llmctl_superpowers_live.sh --alias llmctl-fast --agent claude
scripts/tests/verify_llmctl_superpowers_live.sh --alias llmctl-fast --agent kimi
```

(Script name illustrative — the actual entrypoint is defined in `tasks.md`;
it is the extension of `verify_superpowers_tui.sh` described in
`research.md §4`.)

**Expected**: one captured evidence file per (alias × agent × command)
combination, each containing a PASS/FAIL/SKIP verdict, the route that
actually served the turn, and (for PASS) the unforgeable-challenge response
the model produced. Run the full matrix twice; expect byte-identical
verdicts across both runs (FR-013).

## US4 — Documentation reachable from the README

```bash
# starting only from README.md, follow links to:
#   docs/llmctl/quickstart.md -> docs/llmctl/user-guide.md -> docs/llmctl/FAQ.md
#   -> docs/diagrams/llmctl-*.mmd / .svg
```

**Expected**: every link resolves; no page exists outside this reachable
set (checked by the project's existing link-check / doc-sync tooling, extended
to the new llmctl doc set).

## US5 — Verified release

```bash
# after every above scenario passes:
git tag v1.29.0
gh release create v1.29.0 --notes-file <(sed -n '/## v1.29.0/,/## v1.28.0/p' CHANGELOG.md)
glab release create v1.29.0 --notes-file <(sed -n '/## v1.29.0/,/## v1.28.0/p' CHANGELOG.md)
```

**Expected**: the release is visible, correctly tagged, on both GitHub and
GitLab, with a changelog section whose every bullet matches a real, tested
change from US1–US4.
