# Toolkit proof of work

- generated: `2026-09-06T00:10:35+0200`
- host: `Linux 7.0.0-30-generic x86_64`

## Sandbox suite (hermetic, no network)
```
Test files: 67   passed: 67   failed: 0   (skipped-prereq: 0) ALL GREEN 
```
exit code: `0`  ·  full log: [40-sandbox-suite.log](40-sandbox-suite.log)

## Live OpenCode verification (real binary + real config)
```
# OpenCode live verification proof
generated: 2026-09-06T00:32:37+0200
host:      Linux 7.0.0-30-generic x86_64
opencode:  1.18.29
config:    /home/milosvasic/.config/opencode/opencode.json
mcp_total=20 mcp_enabled=1 skill_paths=1
skills_resolved=15 (threshold 200)
mcp_connected=18 mcp_failed=2
instructions=0

result: see PASS/FAIL tally below
```
result: `✗ 2 failed, 7 passed`  ·  exit code: `1`

## Live provider-alias verification (real installed state)
```
✗ 20 failed, 7 passed
```
exit code: `1`  ·  evidence: [50-providers-live.txt](50-providers-live.txt)

## Live alias verification (real provider + Claude aliases)
```
PASS: 19 FAIL: 0 SKIP-QUOTA: 0 SKIP-AUTH: 0 SKIP-TRANSIENT: 0 SKIP-GATED: 10 TOTAL: 29
```
exit code: `0`  ·  full log: [43-live-aliases.log](43-live-aliases.log)  ·  evidence: [alias-verify-evidence.txt](alias-verify-evidence.txt)

## Live alias end-to-end verification (provider endpoints)
```
  "total": 29,   "passed": 0,   "failed": 19, 
```
exit code: `1`  ·  full log: [44-alias-e2e.log](44-alias-e2e.log)

## Live Kimi verification (real CLI + materialized kimi-<id> aliases, v1.27.0)
```
✓ 2 passed, 0 failed
```
exit code: `0`  ·  full log: [46-kimi-live.log](46-kimi-live.log)  ·  evidence: [kimi-live-evidence.txt](kimi-live-evidence.txt)

## Constitution / conformance static checks (Tier C)
```
✓ 7 passed, 0 failed
```
exit code: `0`  ·  full log: [45-constitution.log](45-constitution.log)  ·  evidence: [45-constitution.txt](45-constitution.txt)

Artifacts: `10-debug-config.json`, `21-skill-names.txt`, `31-mcp-list.clean.txt`, `50-providers-live.txt`, `43-live-aliases.log`, `44-alias-e2e.log`, `46-kimi-live.log`, `kimi-live-evidence.txt`, `45-constitution.log`, `45-constitution.txt`.
