# Behavioral Contract: what an operator can rely on from an llmctl-backed alias

**Feature**: [../spec.md](../spec.md) | **Data model**: [../data-model.md](../data-model.md)

This is the contract claude_toolkit exposes to its own operators and CLI
agents. Every row is directly testable and maps to one or more spec FRs.
Documentation (`quickstart.md`, the user guide, the FAQ) must never claim
more than this contract promises, and the live-test suite must never claim
less.

## Naming

- An llmctl-backed alias is **always** named `llmctl-<profile>` for Claude
  Code and `kimi-llmctl-<profile>` for Kimi Code — never a bare profile name,
  never a different prefix. *(FR-002; already implemented.)*

## Appearance and disappearance

- An alias appears the sync after its backing llmctl profile starts
  answering its own `/v1/models` endpoint — never merely because the profile
  is listed in `llmctl plan --json`, and never merely because its port is
  open. *(FR-001, FR-003; already implemented.)*
- An alias disappears the sync after its backing profile stops answering.
  *(FR-003; already implemented.)*
- On a host with no llmctl binary, or with llmctl installed but serving
  nothing, zero llmctl-backed aliases exist and no error is raised.
  *(FR-004; already implemented.)*

## Starting a model

- claude_toolkit never starts an llmctl profile except in direct response to
  the operator explicitly launching/selecting the alias backed by that
  profile. *(FR-006; already implemented — enforced structurally, not by a
  checkable-but-bypassable flag.)*

## Switching

- Launching a different llmctl-backed alias than the one currently active
  stops the previous profile and starts exactly the newly requested one —
  never both active at once. *(FR-005; already implemented.)*
- If the requested profile does not fit the host's current resources, the
  switch is refused with a specific, readable reason, and the previously
  active profile is independently re-verified as still live afterward — not
  merely assumed so because the switch command exited non-zero.
  *(FR-007; refinement over existing behavior per the llmctl rollback
  finding in research.md §3.B.)*
- Switching, or losing, an llmctl-backed alias has zero effect on any native
  account alias or any other provider alias. *(FR-008; already implemented
  and already tested.)*

## LAN exposure (new)

- The moment an llmctl-backed alias becomes available, if its real listening
  socket is bound to a non-loopback address, the operator sees an explicit,
  plainly worded warning naming the exposure — the alias remains usable.
  *(FR-009; new.)*

## Context-fit honesty (new)

- An llmctl-backed alias's advertised `context_limit` is the real,
  currently-configured context size the profile itself reports (`/v1/models`
  `meta.n_ctx`, else `plan --json`'s own `ctx` field, else the configured
  default — never the literal digit-string `"0"` a missing `ctx` field used
  to silently produce). When that real context cannot clear the minimum a
  CLI agent's own overhead needs (168192 tokens — this project's own
  `CMA_INPUT_FLOOR` carve floor, `research.md §2`), the operator sees an
  explicit `context_warning` field naming the real context and the
  shortfall at the point the alias becomes available — the alias remains
  usable. *(New — closes the captured, already-reproduced failure in
  research.md §2; implemented as an honest warning field alongside the
  real value, never a silent substitution or a borrowed carve from an
  unrelated catalog-correction mechanism.)*

## Live command proof (new)

- For every llmctl-backed alias and every supported CLI agent family, the
  "Use Superpowers," "Turn on Systematic Debugging," and "Turn on
  Sub-Agent-Driven Development" commands each produce a durable, inspectable
  pass/fail/skip record — never a result that exists only as narrated
  success, and never silently omitted. *(FR-011, FR-012, FR-013, FR-014;
  new — extends `verify_superpowers_tui.sh`'s existing unforgeable-challenge
  design per research.md §4.)*
- A genuine model-capability limitation (for example, a profile's model
  failing to tool-call at all) is recorded as a real, evidenced FAIL — never
  reclassified as a SKIP, and never force-passed. *(FR-013/FR-014; new.)*
