# Issue 4 — Pi CLI alias "unverified" (WS-C forensics record)

**Feature**: spec 006, WS-C Issue 4
**Date**: 2026-09-12
**Status**: investigated; the refusal is a DESIGNED activation gate. No fix authored.

## Reported symptom

`pi-helixllm-gateway` fails as "unverified", with the report noting the remedy
`claude-providers verify helixllm-gateway` then `claude-providers sync`, or a
`--force` override.

## Real surface (measured)

| Role | Location |
|---|---|
| Pi alias emission + `~/.pi-prov-<id>/config.toml` render | `scripts/claude-providers.sh:2385`, `:2400` |
| Verification status assignment | `claude-providers.sh:2580-2614`, `:2638-2663` |
| **Launch gate (Pi)** | `scripts/lib.sh:4139-4157` |
| Launch gate (Kimi twin, same shape) | `scripts/lib.sh:3843-3861` |

The gate is explicit about its contract:

```
# Shared activation gate (same record as the claude twin) — only a 'verified'
# id launches, unless the operator passes --force.
...
if [[ "$_cp_st" != "verified" ]]; then
  printf 'claude-providers: alias pi-%s is %s — not launching.\n' ...
  printf '  Re-verify: claude-providers verify %s   (and claude-providers sync)\n' ...
  printf '  Override (operator): run the alias with --force\n' ...
  return 3
fi
```

## Finding: this is the gate WORKING, not a defect

The reported message is **verbatim the gate's own output**, including the
remediation text. So the operator met a deliberate refusal, not a crash or a
silent failure. Note also the deliberate asymmetry recorded at
`claude-providers.sh:2580`:

```
# verified|unverified -> activate; failed -> disable
```

i.e. the *provider record* still activates when unverified, while the *launch
gate* refuses — the strict reading is the second one, and it is the one the user
hit.

**Bypassing this gate is not a fix.** It is the mechanism that stops an
unverified backend from being launched; removing it would trade a clear refusal
for an unverified live request.

## The hypothesis that WOULD be a real defect (unconfirmed)

For an `unverified` status to be a dead end, verification must be *unable* to
succeed for this provider class. `claude-providers.sh:2638` notes the Pi twin is
"Pi CLI over the SAME backend", and `:2662` sets `vstatus=unverified` with
`failing_layer=semantic` when the semantic probe is inconclusive.

`helixllm-gateway` uses the **`router`** transport (see Issue 5 surface:
`scripts/providers/helixllm-gateway.json`, transport `router`). If the semantic /
existence probe is structurally inconclusive for a `router` transport, the status
would be permanently `unverified`, the gate could never open legitimately, and
`--force` would be the only path — a real defect worth fixing.

**Not confirmed.** It requires running `claude-providers verify helixllm-gateway`
against the live gateway and reading `status.json` + `failing_layer`.

## Honest boundary (§11.4.6)

- Not reproduced. No verification run was performed and no `status.json` for the
  provider was inspected.
- "Permanently unverified for router transports" is a **hypothesis** derived from
  reading the status-assignment code, not a measurement.
- **No fix authored** — the observed behaviour is a designed safety gate, and
  changing it without a reproduced defect violates §11.4.102.

## Ordered next steps for Issue 4

1. Run `claude-providers verify helixllm-gateway` and capture the output.
2. Read `~/.local/share/claude-multi-account/providers/status.json` for the id's
   `status` and `failing_layer`.
3. If `failing_layer=semantic` and the transport is `router`, decide whether the
   probe should be transport-aware (a router-backed provider is verifiable by a
   reachability probe, not a model-list probe). That is the candidate fix.
4. Only then: RED (a router-transport provider that must reach `verified`) → fix
   → paired mutation.
