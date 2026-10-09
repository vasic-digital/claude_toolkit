# Issue 5 — helixllm-gateway endpoint / connection errors (WS-C forensics record)

**Feature**: spec 006, WS-C Issue 5
**Date**: 2026-09-12
**Status**: investigated; endpoint resolution is configurable AND covered. **No
reproduced defect; no fix authored.**

## Reported symptom

Connection errors attributed to the HelixLLM gateway endpoint (and, in the same
report, to `helixagent-debate` / `helixagent-llm`).

## Real surface (measured)

| Role | Location |
|---|---|
| Gateway pin (base_url, transport, key var) | `scripts/providers/helixllm-gateway.json` — `base_url https://127.0.0.1:8443/v1`, `transport router`, `key_var HELIXLLM_GATEWAY_KEY` |
| Pin override | `CMA_HELIXLLM_PINS_FILE` (`claude-providers.sh:665, 913, 1100`) |
| Detection / reason recording | `claude-providers.sh:429-437, 665-801` |
| Sibling local providers | `helixagent.json` `http://127.0.0.1:7061/v1`, `helixcoder.json` `http://127.0.0.1:18434/v1` |

## Finding

**The endpoint is not hardcoded** — it is a *pin* whose file is replaceable via
`CMA_HELIXLLM_PINS_FILE`, and the component that consumes it detects the gateway
and records its reason (`claude-providers.sh:799`). All three local providers
point at loopback by design; that is a local default, not a stray host
(CONST-045 governs container distribution targets, not a toolkit's local
gateway pin).

Coverage, measured on unchanged code:

```
test_helix_endpoint_reality.sh            45 passed, 0 failed
test_helixagent_pins_survive_live_sync.sh  12 passed, 0 failed
test_kimi_wire_and_status_freshness.sh     58 passed, 0 failed
```

## Most likely cause of the reported errors (hypothesis, not a defect)

`https://127.0.0.1:8443/v1` is a **precondition**: the HelixLLM gateway must be
running on that port. If it is not, every consumer correctly reports it
unreachable — that is the toolkit telling the truth, not failing.

Note also that the `helixagent-debate` / `helixagent-llm` half of that report was
addressed on the *agent* side in WS-B (`3f33980a` pooled transport, `efa5e003`
retry, `60cb7bce` body-rewind + fail-closed, `903a58f8` review fixes), where the
providers used a bare `&http.Transport{}` with no dial timeout or pooling.

## Honest boundary (§11.4.6)

- **Not reproduced.** No live gateway was started and no connection was driven,
  so "the gateway was simply not running" is a **hypothesis**, not a finding.
- No fix authored: the endpoint surface is configurable and its suites are green
  (§11.4.102 — no change without a reproduced defect).

## Ordered next steps for Issue 5

1. Start the gateway on 127.0.0.1:8443 and run `test_helix_endpoint_reality.sh`
   against it (it is written to exercise a live endpoint) to see the real error,
   if any.
2. If it fails, capture the failure and treat THAT as the RED.
3. Re-verify the `helixagent-debate`/`-llm` route against a live gateway with the
   WS-B retry/pooled transport in place, capturing the 200-request evidence that
   T050 still owes.
