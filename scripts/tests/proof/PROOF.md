# Toolkit proof of work

- generated: `2026-07-26T21:04:06+0300`
- host: `Linux 6.12.61-6.12-alt1 x86_64`

## Sandbox suite (hermetic, no network)
```
Test files: 55   passed: 55   failed: 0   (skipped-prereq: 0) ALL GREEN 
```
exit code: `0`  ·  full log: [40-sandbox-suite.log](40-sandbox-suite.log)

## Live OpenCode verification (real binary + real config)
```
# OpenCode live verification proof
generated: 2026-07-26T21:14:30+0300
host:      Linux 6.12.61-6.12-alt1 x86_64
opencode:  1.18.5
config:    /home/milosvasic/.config/opencode/opencode.json
mcp_total=132 mcp_enabled=10 skill_paths=177
skills_resolved=1497 (threshold 200)
mcp_connected=10 mcp_failed=0
instructions=1

result: see PASS/FAIL tally below
```
result: `✓ 9 passed, 0 failed`  ·  exit code: `0`

## Live provider-alias verification (real installed state)
```
✗ 10 failed, 34 passed
```
exit code: `1`  ·  evidence: [50-providers-live.txt](50-providers-live.txt)

## Live alias verification (real provider + Claude aliases)
```
PASS: 15 FAIL: 0 SKIP-QUOTA: 6 SKIP-AUTH: 1 SKIP-TRANSIENT: 0 SKIP-GATED: 32 TOTAL: 57
```
exit code: `0`  ·  full log: [43-live-aliases.log](43-live-aliases.log)  ·  evidence: [alias-verify-evidence.txt](alias-verify-evidence.txt)

## Live alias end-to-end verification (provider endpoints)
```
  "total": 54,   "passed": 15,   "failed": 0, 
```
exit code: `0`  ·  full log: [44-alias-e2e.log](44-alias-e2e.log)

## Constitution / conformance static checks (Tier C)
```
✓ 7 passed, 0 failed
```
exit code: `0`  ·  full log: [45-constitution.log](45-constitution.log)  ·  evidence: [45-constitution.txt](45-constitution.txt)

Artifacts: `10-debug-config.json`, `21-skill-names.txt`, `31-mcp-list.clean.txt`, `50-providers-live.txt`, `43-live-aliases.log`, `44-alias-e2e.log`, `45-constitution.log`, `45-constitution.txt`.
