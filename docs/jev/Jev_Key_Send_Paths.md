# Jev key send paths - where a bearer/API key can leave the machine

| Field | Value |
|---|---|
| Revision | 1 |
| Created | 2026-10-26 |
| Status | active |
| Guarded by | `scripts/tests/test_jev_key_origin_class.sh` (C6 fails if a script that builds a bearer/api-key header is missing from this table) |

## The class

"A key can reach a host that was never validated." Every place that builds an
`Authorization: Bearer` or `x-api-key` header is listed below with the check that
stands between the key and the network. The Jev (decision-layer) paths share ONE rule.

### The Jev origin rule

A key held in variable `KEYVAR` may be sent to base URL `B` only when:

1. `B` is plain http: NO key is sent at all (header omitted);
2. `B` is https and its authority is loopback (`127.x.x.x`, `localhost`, `[::1]`;
   userinfo, backslash, percent and whitespace in the authority are refused);
3. `B`'s origin and `KEYVAR` equal a SHIPPED pin in `providers/jev.json`
   (read next to the script; not overridable by environment, cache or
   `CMA_JEV_PINS_FILE`; when the gate runs through a `~/.local/bin` symlink, absolute or
   relative, single hop or chain of up to 40 hops, the pins are read from the directory of
   the resolved REAL script, never from the directory of the link; resolution uses a
   bounded portable `readlink` loop, not `readlink -f`, which BSD/macOS lack; a directory
   that cannot be entered means no pins and no key); or
4. the operator listed `origin=KEYVAR` in `CMA_JEV_TRUSTED_ORIGINS`.

Installed copies: `jev-setup` installs `providers/jev.json` beside EVERY installed
gate copy (`~/.local/share/claude-multi-account/jev/` and `$SHARED_DIR/jev/`), because
the gate resolves the shipped pins from its own directory. The installed gate
therefore behaves exactly like the repo copy (test_jev_installed_gate.sh runs the
installed copies); an installed gate without the pins file refuses every hosted
endpoint (`key_unpinned`), i.e. the decision layer would be silently off.

Residual risk (stated, not fixed): rule 2 allows ANY key variable to https loopback.
On a multi-user host another local user could bind that loopback port and read the key.

Anything else makes NO request (gate fallback `key_unpinned`). The endpoint cache
(`jev-endpoints.json`) and a `CMA_JEV_PINS_FILE` override do not attest a key.
A probe's `systemone_path` must match `^/[A-Za-z0-9._~/-]*$` without `..` before it
is appended to a base.

## Sites

| File | Site(s) | Host check | Status |
|---|---|---|---|
| `scripts/jev-gate.sh` | bearer via `curl -H @<(...)` (~line 274) | Jev origin rule above | covered |
| `scripts/jev_mcp.py` | `_post_systemone`, `_tool_jev_models` | `_key_for_base` (same rule; `JEV_API_KEY` explicit override sent as given) | covered |
| `scripts/jev-setup.sh` | `_jev_endpoint_env` writes `JEV_API_KEY`/`TYPESAFE_API_KEY` into the claude `.mcp.json`, the kimi `mcp.json` and the opencode config | the cache is untrusted: `key_var` must be a plain name, and the real key is written only when `jev_mcp._origin_allows_key(base, key_var)` holds; otherwise the placeholder `local` | covered |
| `scripts/opencode-jev-plugin.js` | `fetch` Authorization | `originAllowsKey` (same rule; shipped list embedded, kept equal to `providers/jev.json` by test; no header when no key or http; `key_var` passed as data, never in script text) | covered; the JS scenarios are SKIPPED where `node` is absent |
| `scripts/claude-providers.sh` | hosted live probe in `detect_jev_records` (~line 2482) | path validated; loopback base + loopback final URL, or shipped pin with matching key variable | covered |
| `scripts/claude-providers.sh` | local/LAN gateway probe (~line 2611) | host declared by the pins; the key is sent only after the gateway answered `/healthz` over TLS with a trusted certificate | residual risk: a LAN pin is operator-declared trust |
| `scripts/claude-providers.sh` | lines ~382, 550, 1050, 1290, 1908 | non-Jev provider endpoints: the provider's own configured base URL, key read from the operator's keys file | out of scope of the Jev rule; the operator configures the destination |
| `scripts/http_noredirect.py` | shared opener | never follows redirects, so a credential cannot be replayed to another origin | covered |
| `scripts/providers-verify.sh` | ~lines 316, 328 | provider endpoint under verification, configured by the operator; header omitted when no key | out of scope (operator-configured) |
| `scripts/model_verify.py` | ~lines 292-313, 789-793 | provider endpoint under verification; no redirects via `http_noredirect` | out of scope (operator-configured) |
| `scripts/quota_probe.py` | ~lines 310-312, 521 | provider quota endpoints from the provider registry; no redirects | out of scope (operator-configured) |
| `scripts/alias_e2e_test.py` | ~lines 142, 149, 401, 417 | a deliberate real-host test: it sends the alias's key to that alias's own endpoint | intentionally left |

## Residual risks (stated, not hidden)

- A `routes.json` candidate names a `key_var` (a variable NAME, never a secret); the
  bearer is that variable's value from the keys file. `_candidate_answer` applies the
  same origin rule per candidate: an https candidate whose origin is not loopback, a
  shipped pin for that key variable, or operator-trusted is skipped (no request).
- A LAN pin is operator-declared trust: whoever can edit the pins file picks the host.
- Without `node`, the JS plugin scenarios of the test are skipped (reported as such).
- Non-Jev provider paths send the key to the endpoint the operator configured for
  that provider; they are not subject to the Jev origin rule.
