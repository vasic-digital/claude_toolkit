# Test suite prerequisites

The suite under `scripts/tests/` is plain bash (`tests/lib/assert.sh` +
`tests/lib/sandbox.sh`), run via `run-all.sh` / `run-proof.sh`. Beyond a
POSIX-ish shell, the following external tools must be on `PATH`:

- `jq` — JSON construction/parsing (provider records, llmctl catalogs,
  status/pins files).
- `curl` — HTTP probes against provider and llmctl mock/live endpoints.
- `ss` — reads real kernel listening-socket state for the llmctl
  `lan_exposed` field (`test_llmctl_lan_exposure.sh`); falls back to a
  conservative `false` when absent.

See the root `CLAUDE.md` for the broader test-harness conventions
(`make_sandbox`, `sandbox_stub`, suite locking).
