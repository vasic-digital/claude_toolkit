# Provider Aliases — Diagrams

Mermaid sources for the `claude-providers` feature. Render with any Mermaid
tool (e.g. `mmdc`, the GitHub viewer, or the doc export pipeline).

## 1. Component architecture

```mermaid
flowchart TB
  subgraph Inputs["Inputs (no hardcoding)"]
    KEYS["~/api_keys.sh\n(key var NAMES)"]
    MDEV["models.dev/api.json\n(catalog: api, npm, models)"]
    KA["providers/key-aliases.json\n(name normalization)"]
    OV["providers/overrides.json\n(per-provider pins)"]
  end

  subgraph Engine["claude-providers"]
    CP["claude-providers.sh\n(sync/list/show/remove/add)"]
    RES["providers_resolve.py\n(dynamic resolver)"]
    VER["providers-verify.sh\n(LLMsVerifier | HTTP probe)"]
    LIB["lib.sh helpers\n(env/alias/link/enable)"]
  end

  subgraph Verifier["submodules/LLMsVerifier (optional)"]
    BIN["bin/model-verification"]
  end

  subgraph Outputs
    ENV["providers/<id>.env\n(non-secret)"]
    ALIAS["aliases.sh\n(alias <name>=cma_run_provider <id>)"]
    DIR["~/.claude-prov-<id>\n(shared items symlinked)"]
    CCR["~/.claude-code-router/config.json\n(router providers, at launch)"]
  end

  KEYS --> CP
  MDEV --> RES
  KA --> RES
  OV --> RES
  CP --> RES
  CP --> VER
  VER -.uses if built.-> BIN
  CP --> LIB
  LIB --> ENV
  LIB --> ALIAS
  LIB --> DIR
  CP --> CCR
```

## 2. `sync` pipeline

```mermaid
flowchart LR
  A["read key var NAMES\n(grep, no exec)"] --> B["fetch + cache\nmodels.dev (TTL)"]
  B --> C["resolve per key\n(provider, models, transport)"]
  C --> D{classification}
  D -- vcs/infra --> S1["skip"]
  D -- no match --> S2["unmapped\n(log, retry next run)"]
  D -- llm match --> E["dedupe by provider_id"]
  E --> F{verify?}
  F -- failed --> S3["disabled\n(alias NOT activated)"]
  F -- verified/unverified --> G["write env + alias\n+ link config dir"]
  G --> H["enable always-on plugins\n(shared settings)"]
```

## 3. Verification pipeline (4 layers)

```mermaid
flowchart TB
  A["claude-providers sync"] --> B["Layer 1: Existence\n(HTTP probe: reachable? valid key? active account?)"]
  B -->|fail| F1["status: failed/existence"]
  B -->|inconclusive| U1["status: unverified/existence"]
  B -->|pass| C["Layer 2: Tool-Call\n(model recognizes tool schema?)"]
  C -->|fail| F2["status: failed"]
  C -->|pass| D["Layer 3: Semantic\n(sentinel echo + judge evaluation)"]
  D -->|fail| U2["status: unverified/semantic"]
  D -->|skip| D2["keep prior verdict\n(no downgrade)"]
  D -->|pass| E["Layer 4: Superpowers-TUI\n(real Claude Code session)"]
  E -->|fail| U3["status: unverified/superpowers_tui"]
  E -->|skip| E2["keep prior verdict\n(no downgrade)"]
  E -->|pass| V["status: verified\n(final — launchable)"]
```

## 4. Launch data flow (`cma_run_provider`)

```mermaid
sequenceDiagram
  participant U as User shell
  participant G as Activation gate
  participant W as cma_run_provider
  participant K as ~/api_keys.sh
  participant R as ccr (router)
  participant C as Claude Code
  U->>G: deepseek  (alias)
  G->>G: check status.json → verified?
  alt not verified
    G-->>U: refused: "provider not verified"
  else verified
    G->>W: proceed
    W->>W: source providers/<id>.env (non-secret)
    W->>K: source keys file (secret in-memory only)
    W->>W: upsert provider into ccr config (chmod 600, live key)
    W->>R: ccr default-claude-code -- "$@"
    R->>C: translates Anthropic ↔ OpenAI
    C-->>U: Claude Code session on provider's models
  end
```

## See also

- [`quota-limits-flow.mmd`](quota-limits-flow.mmd) / [`.svg`](quota-limits-flow.svg) — the `quota`/`limits` reporting flow (a separate, read-only concern from the diagrams above; see the Provider Aliases User Guide §14).
