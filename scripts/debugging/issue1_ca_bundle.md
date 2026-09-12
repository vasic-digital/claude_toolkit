# Issue 1 — ca-bundle.pem overwrite (WS-C forensics record)

**Feature**: spec 006, WS-C Issue 1
**Date**: 2026-09-12
**Status**: root cause identified by CODE ANALYSIS; **runtime reproduction NOT achieved**

## Reported symptom

Failure at
`~/.claude-code-router/helixllm-anton-qwen2-5-coder-3b-instruct-q4_k_m-f6771589d190/ca-bundle.pem`
— described in the originating report as a "ca-bundle.pem overwrite error".

## Real surface (no `internal/router/ca_bundle.go` exists)

`submodules/claude-toolkit/scripts/lib.sh`, lines ~1850–1900. The relevant write is:

```bash
cat "$_ccr_sys_ca" "$CMA_PROVIDER_CA_CERT" > "$_ccr_home/ca-bundle.pem" 2>/dev/null || true
# else-branch: cat "$CMA_PROVIDER_CA_CERT" > "$_ccr_home/ca-bundle.pem" 2>/dev/null || true
```

`$_ccr_home` is the per-alias router home (`~/.claude-code-router/<provider-id>/`), and the
bundle is consumed by the running router through `SSL_CERT_FILE=…` (line ~1894).

## Code-analysis root cause (NOT yet reproduced at runtime)

`>` truncates the destination and then streams the sources into it. That is a
**non-atomic write** with two concrete failure windows:

1. **Reader observes a truncated bundle.** The router process (and any concurrent
   `ccr` invocation) may open `ca-bundle.pem` while it is truncated or
   half-written. Go reads `SSL_CERT_FILE` at dial time; a partial bundle yields
   `x509: certificate signed by unknown authority` — the exact symptom the block
   was written to fix — or a confusing parse error.
2. **Concurrent writers interleave.** If two setup/launch paths reach this block
   for the same `$_ccr_home` at once, both truncate and both append, producing an
   interleaved or partial file. `|| true` swallows the error, so the failure is
   silent and surfaces later as a TLS error.

The correct shape is **write-temp-then-rename** (same directory, so `rename` is
atomic on POSIX) plus a lock around the write, with `0600` applied to the temp
file *before* the rename so the final file is never briefly world-readable.

## What was actually MEASURED

Baseline of the toolkit's own suite, before any change:

```
bash scripts/tests/test_ccr_upstream_ca.sh
→ 2 failed, 10 passed
```

The two failures are **not** the reported overwrite. Both are test-hermeticity
defects: a "WITHOUT CA" case observed ambient environment from the operator's
shell —

```
native WITHOUT CA: claude child saw an empty NODE_EXTRA_CA_CERTS
  (log: NODE_EXTRA_CA_CERTS=[…/submodules/helix_llm/certs/cert.pem])
router WITHOUT CA: every ccr invocation saw an empty SSL_CERT_FILE (1/3)
```

The test expects the variable UNSET and inherits it from the caller's
environment. That is a real defect in the TEST, and it must be fixed before this
suite can serve as a RED/GREEN oracle for the ca-bundle change (§11.4.115: a RED
that fails for the wrong reason proves nothing).

## Honest boundary (§11.4.6)

- The non-atomic-write defect is established by **reading the code**, not by
  reproducing the reported failure on the live Claude Code Router with a
  self-signed gateway. **No runtime reproduction has been captured.**
- No fix is claimed. The fix design above is a proposal whose acceptance requires
  (a) the test-hermeticity failures fixed so the suite has a trustworthy RED
  baseline, and (b) a reproduction on the broken artifact.
- Until both hold, marking Issue 1 fixed would be a PASS-bluff.

## Ordered next steps for Issue 1

1. Fix the two hermeticity failures (unset/scrub ambient `SSL_CERT_FILE` /
   `NODE_EXTRA_CA_CERTS` in the test sandbox) → suite must reach **12/12** on the
   unchanged product code.
2. Author a RED test reproducing the truncation window (concurrent readers while
   the bundle is rewritten; or assert the write is atomic by construction).
3. Implement write-temp + `chmod 600` + `mv` + lock in `scripts/lib.sh`.
4. Flip to GREEN, capture evidence, add the paired §1.1 mutation (revert to
   `cat >`) and confirm the RED test fails again.
