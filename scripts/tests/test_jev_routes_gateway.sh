#!/usr/bin/env bash
# test_jev_routes_gateway.sh — hermetic test for jev_mcp.py's opt-in
# multi-candidate specialization/voting gateway (JEV_ROUTES_FILE). Proves
# the GATING MECHANISM (ordered failover, agreement-required voting, honest
# degrade-on-disagreement) against two fixture endpoints — this environment
# has no real second decision model (Kev/Laya) to call, so both candidates
# are instances of the same stdlib fixture server on different ports,
# scripted independently via their own CMA_JEV_FIXTURE_RESPONSES files.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
set +e

MCP="$SCRIPTS_DIR/jev_mcp.py"
FIXTURE="$SCRIPTS_DIR/tests/fixtures/jev_server.py"

PORT_A=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
PORT_B=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
echo '{}' > "$HOME/fixture-a.json"
echo '{}' > "$HOME/fixture-b.json"
CMA_JEV_FIXTURE_RESPONSES="$HOME/fixture-a.json" python3 "$FIXTURE" "$PORT_A" &
FIX_A=$!
CMA_JEV_FIXTURE_RESPONSES="$HOME/fixture-b.json" python3 "$FIXTURE" "$PORT_B" &
FIX_B=$!
trap 'kill "$FIX_A" "$FIX_B" 2>/dev/null; cleanup_sandbox' EXIT
for p in "$PORT_A" "$PORT_B"; do
  for i in $(seq 1 40); do
    curl -sf -m 1 "http://127.0.0.1:$p/healthz" >/dev/null 2>&1 && break
    sleep 0.1
  done
done

_routes_file() { # _routes_file <min_confidence> <min_agreement_or_null>
  cat > "$HOME/jev-routes.json" <<EOF
{"routes": {"test_route": {
  "candidates": [
    {"provider_id": "fixture-a", "base_url": "http://127.0.0.1:$PORT_A", "key_var": ""},
    {"provider_id": "fixture-b", "base_url": "http://127.0.0.1:$PORT_B", "key_var": ""}
  ],
  "min_confidence": $1,
  "min_agreement": $2
}}}
EOF
}

_route_ask_call() { # _route_ask_call
  JEV_ROUTES_FILE="$HOME/jev-routes.json" python3 - "$MCP" <<'PYEOF'
import json, os, subprocess, sys
msgs = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
     "params": {"name": "jev_ask", "arguments": {
         "state": "ctx", "question": "allow?",
         "options": ["allow", "ask", "deny"], "decision_type": "test_route"}}},
]
data = b"".join(b"Content-Length: %d\r\n\r\n%s" % (len(json.dumps(m).encode()), json.dumps(m).encode()) for m in msgs)
p = subprocess.run(["python3", sys.argv[1]], input=data, capture_output=True, timeout=30)
sys.stdout.buffer.write(p.stdout)
PYEOF
}

it "no routes.json -> jev_ask ignores decision_type and uses the single default endpoint unchanged"
unset JEV_ROUTES_FILE_UNUSED 2>/dev/null
rm -f "$HOME/jev-routes.json"
echo '{}' > "$HOME/fixture-a.json"
out=$(JEV_BASE_URL="http://127.0.0.1:$PORT_A" python3 - "$MCP" <<'PYEOF'
import json, subprocess, sys
msgs = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
     "params": {"name": "jev_ask", "arguments": {
         "state": "ctx", "question": "allow?",
         "options": ["allow", "ask", "deny"], "decision_type": "nonexistent_route"}}},
]
data = b"".join(b"Content-Length: %d\r\n\r\n%s" % (len(json.dumps(m).encode()), json.dumps(m).encode()) for m in msgs)
p = subprocess.run(["python3", sys.argv[1]], input=data, capture_output=True, timeout=30)
sys.stdout.buffer.write(p.stdout)
PYEOF
)
case "$out" in *'"answer": "allow"'*) _pass "unmatched decision_type falls back to default single-endpoint path" ;; *) _fail "expected fallback to default path" "$out" ;; esac

it "ordered failover (no min_agreement): first candidate meeting min_confidence wins"
_routes_file 0.5 null
echo '{"allow?": "ask"}' > "$HOME/fixture-a.json"
echo '{"allow?": "deny"}' > "$HOME/fixture-b.json"
out=$(_route_ask_call)
case "$out" in *'"answer": "ask"'*) _pass "first candidate (fixture-a=ask) wins ordered failover" ;; *) _fail "expected answer=ask from fixture-a" "$out" ;; esac
case "$out" in *'"degraded": false'*) _pass "not degraded when a candidate cleared the bar" ;; *) _fail "expected degraded:false" "$out" ;; esac

it "agreement-required voting: two candidates AGREEING on the same answer is trusted"
_routes_file 0.5 0.5
echo '{"allow?": "ask"}' > "$HOME/fixture-a.json"
echo '{"allow?": "ask"}' > "$HOME/fixture-b.json"
out=$(_route_ask_call)
case "$out" in *'"agreement": true'*) _pass "agreement:true when both candidates agree" ;; *) _fail "expected agreement:true" "$out" ;; esac
case "$out" in *'"answer": "ask"'*) _pass "agreed answer=ask returned" ;; *) _fail "expected answer=ask" "$out" ;; esac
case "$out" in *'"fixture-a"'*'"fixture-b"'*) _pass "both agreeing candidates named" ;; *) _fail "expected both candidate ids in agreed_candidates" "$out" ;; esac

it "agreement-required voting: two candidates DISAGREEING degrades honestly instead of silently trusting one"
_routes_file 0.5 0.5
echo '{"allow?": "ask"}' > "$HOME/fixture-a.json"
echo '{"allow?": "deny"}' > "$HOME/fixture-b.json"
out=$(_route_ask_call)
case "$out" in *'"degraded": true'*) _pass "disagreement is reported as degraded, not silently trusted" ;; *) _fail "expected degraded:true on disagreement" "$out" ;; esac
case "$out" in *'"agreement": false'*) _pass "agreement:false on disagreement" ;; *) _fail "expected agreement:false" "$out" ;; esac
case "$out" in *'"reason"'*) _pass "degrade reason explained" ;; *) _fail "missing degrade reason" "$out" ;; esac

summary
