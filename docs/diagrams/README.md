# Diagrams

Architecture and flow diagrams for the toolkit. Sources are `*.mmd`
([Mermaid](https://mermaid.js.org)); rendered `*.svg` are committed so they
display without a renderer.

| Diagram | Source | Rendered |
|---------|--------|----------|
| OpenCode integration architecture | [architecture.mmd](architecture.mmd) | [architecture.svg](architecture.svg) |
| Sync data flow | [dataflow.mmd](dataflow.mmd) | [dataflow.svg](dataflow.svg) |
| MCP enable policy | [enable-policy.mmd](enable-policy.mmd) | [enable-policy.svg](enable-policy.svg) |
| Kimi + Claude family dispatch | [kimi-family.mmd](kimi-family.mmd) | [kimi-family.svg](kimi-family.svg) |

Regenerate after editing a source:

```bash
echo '{"args":["--no-sandbox"]}' > /tmp/pptr.json
for d in architecture dataflow enable-policy kimi-family; do
  mmdc -i docs/diagrams/$d.mmd -o docs/diagrams/$d.svg -p /tmp/pptr.json
done
```
