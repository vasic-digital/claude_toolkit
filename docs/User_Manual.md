# Claude Toolkit — User Manual

This is the single entry point to the toolkit's documentation (Constitution
§11.4.257: manual + guides + FAQ per feature, §11.4.212: everything reachable
from the README). Each feature has a guide for doing the task and an FAQ for
the questions people actually ask; the manual below indexes them in reading
order.

## 1. Orientation

| You want to... | Read |
|---|---|
| Install and run several Claude Code accounts on one host | [README quick start](../README.md#-quick-start), [Fine-Tuning deep dive](../Claude_Multi_Account_Fine_Tuning.md) |
| Know where claude_toolkit sits in a constitution-governed project | [README hub-engine section](../README.md#-constitution-hub-engine), [placement diagram](diagrams/hub-engine-placement.svg) |
| See every command | [README daily commands](../README.md#-daily-commands) |

## 2. Provider aliases (any LLM as a Claude Code alias)

- Guide: [Provider Aliases User Guide](Provider_Aliases_User_Guide.md)
- FAQ: [Provider FAQ](Provider_FAQ.md)
- Verification: [Provider Verification Guide](Provider_Verification_Guide.md)
- Kimi Code accounts: [Kimi Accounts User Guide](../Kimi_Accounts_User_Guide.md)
- Diagrams: [index](diagrams/README.md) ([quota-limits-flow](diagrams/quota-limits-flow.svg), [kimi-family](diagrams/kimi-family.svg), [enable-policy](diagrams/enable-policy.svg))

## 3. Local models through llmctl (and the validation gate)

- Quickstart: [llmctl quickstart](llmctl/quickstart.md)
- Guide: [llmctl user guide](llmctl/user-guide.md) — includes §5a, the
  §11.4.277 validation gate (`LLMCTL_VALIDATE_STRICT=1`,
  `llmctl require-validated`) and the §11.4.278 Vision QA relationship
- FAQ: [llmctl FAQ](llmctl/FAQ.md)
- Diagrams: [detection](diagrams/llmctl-detection-flow.svg), [switch](diagrams/llmctl-switch-flow.svg)

## 4. Decision models (Jev) — the §11.4.279 layer

- Quickstart: [Jev quickstart](jev/Jev_Quickstart.md)
- Guide: [Jev user guide](jev/Jev_User_Guide.md) (gate, MCP server, stats,
  calibration, the HTTPS + bearer-key decide gateway, honest limitations)
- FAQ: [Jev FAQ](jev/Jev_FAQ.md)
- Diagrams: [architecture](diagrams/jev-architecture.svg), [decide-gateway flow](diagrams/decide-gateway-flow.svg)

## 5. Other utilities

- [OpenCode Integration](../OpenCode_Integration.md) — share Skills + MCP + `CLAUDE.md`
- [Session & Color](SESSION_COLOR.md) — per-project session naming
- [TOON Integration](TOON_Integration.md) — token-efficient JSON
- [Multi-host rollout](MULTI_HOST_ROLLOUT.md)

## 6. Project

- [CHANGELOG](../CHANGELOG.md) — release history
- [Diagram index](diagrams/README.md) — Mermaid sources and rendered SVGs

## 7. Honest scope

The manual indexes documentation that exists; it does not claim features
beyond what the guides state. The decide-gateway transport (HTTPS + bearer
key) is verified only against a hermetic TLS stand-in, not a real llmctl
gateway (Jev guide, limitation 11). The toolkit forwards the llmctl validation
gate's environment and honours its refusals but runs no Vision known-answer
suite of its own.
