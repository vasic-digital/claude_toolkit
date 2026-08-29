# Toolkit proof of work

- generated: `2026-08-29T03:10:53+0500`
- host: `Linux 6.12.41-6.12-alt1 x86_64`

## Sandbox suite (hermetic, no network)
```
Test files: 59   passed: 59   failed: 0   (skipped-prereq: 0) ALL GREEN 
```
exit code: `0`  ·  full log: [40-sandbox-suite.log](40-sandbox-suite.log)

## Live OpenCode verification (real binary + real config)
```
# OpenCode live verification proof
generated: 2026-08-29T03:23:06+0500
host:      Linux 6.12.41-6.12-alt1 x86_64
opencode:  1.18.23
config:    /home/milos/.config/opencode/opencode.json
mcp_total=20 mcp_enabled=1 skill_paths=0
skills_resolved=1 (threshold 200)
mcp_connected=20 mcp_failed=0
instructions=0

result: see PASS/FAIL tally below
```
result: `✗ 2 failed, 7 passed`  ·  exit code: `1`

## Live provider-alias verification (real installed state)
```
✗ 7 failed, 20 passed
```
exit code: `1`  ·  evidence: [50-providers-live.txt](50-providers-live.txt)

## Live alias verification (real provider + Claude aliases)
```
PASS: 19 FAIL: 0 SKIP-QUOTA: 1 SKIP-AUTH: 0 SKIP-TRANSIENT: 0 SKIP-GATED: 39 TOTAL: 61
```
exit code: `0`  ·  full log: [43-live-aliases.log](43-live-aliases.log)  ·  evidence: [alias-verify-evidence.txt](alias-verify-evidence.txt)

## Live alias end-to-end verification (provider endpoints)
```
  "total": 61,   "passed": 19,   "failed": 0, 
```
exit code: `0`  ·  full log: [44-alias-e2e.log](44-alias-e2e.log)

## Constitution / conformance static checks (Tier C)
```
✓ 7 passed, 0 failed
```
exit code: `0`  ·  full log: [45-constitution.log](45-constitution.log)  ·  evidence: [45-constitution.txt](45-constitution.txt)

Artifacts: `10-debug-config.json`, `21-skill-names.txt`, `31-mcp-list.clean.txt`, `50-providers-live.txt`, `43-live-aliases.log`, `44-alias-e2e.log`, `45-constitution.log`, `45-constitution.txt`.
