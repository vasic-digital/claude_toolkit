# Toolkit proof of work

- generated: `2026-10-04T18:49:07+0200`
- host: `Linux 7.0.0-34-generic x86_64`

## Sandbox suite (hermetic, no network)
```
Test files: 91   passed: 91   failed: 0   (skipped-prereq: 1) ALL GREEN 
```
exit code: `0`  ·  full log: [40-sandbox-suite.log](40-sandbox-suite.log)

## Live OpenCode verification (real binary + real config)
```
# OpenCode live verification proof
generated: 2026-10-04T19:24:32+0200
host:      Linux 7.0.0-34-generic x86_64
opencode:  1.18.30
config:    /home/milosvasic/.config/opencode/opencode.json
mcp_total=20 mcp_enabled=1 skill_paths=1
skills_resolved=994 (threshold 200)
mcp_connected=19 mcp_failed=1
instructions=0

result: see PASS/FAIL tally below
```
result: `✗ 1 failed, 8 passed`  ·  exit code: `1`

## Live provider-alias verification (real installed state)
```
✗ 9 failed, 14 passed
```
exit code: `1`  ·  evidence: [50-providers-live.txt](50-providers-live.txt)

## Live alias verification (real provider + Claude aliases)
```
PASS: 11 FAIL: 1 SKIP-QUOTA: 1 SKIP-AUTH: 0 SKIP-TRANSIENT: 2 SKIP-GATED: 47 TOTAL: 63
```
exit code: `1`  ·  full log: [43-live-aliases.log](43-live-aliases.log)  ·  evidence: [alias-verify-evidence.txt](alias-verify-evidence.txt)

## Live alias end-to-end verification (provider endpoints)
```
  "total": 63,   "passed": 11,   "failed": 3, 
```
exit code: `1`  ·  full log: [44-alias-e2e.log](44-alias-e2e.log)

## Live Kimi verification (real CLI + materialized kimi-<id> aliases, v1.27.0)
```
✗ 14 failed, 63 passed
```
exit code: `14`  ·  full log: [46-kimi-live.log](46-kimi-live.log)  ·  evidence: [kimi-live-evidence.txt](kimi-live-evidence.txt)

## Live quota/limits verification (claude-providers quota --json)
```
PASS: claude-providers quota --json produced valid JSON
```
exit code: `0`  ·  full log: [47-quota-live.log](47-quota-live.log)

## Constitution / conformance static checks (Tier C)
```
✓ 7 passed, 0 failed
```
exit code: `0`  ·  full log: [45-constitution.log](45-constitution.log)  ·  evidence: [45-constitution.txt](45-constitution.txt)

Artifacts: `10-debug-config.json`, `21-skill-names.txt`, `31-mcp-list.clean.txt`, `50-providers-live.txt`, `43-live-aliases.log`, `44-alias-e2e.log`, `46-kimi-live.log`, `kimi-live-evidence.txt`, `47-quota-live.log`, `45-constitution.log`, `45-constitution.txt`.
