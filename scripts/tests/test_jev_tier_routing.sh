#!/usr/bin/env bash
# test_jev_tier_routing.sh — hermetic test for jev_mcp.py's jev_recommend_tier
# tool: an ADVISORY model-tier recommendation (haiku/sonnet/opus) for a
# planned subagent dispatch. Never enforced by any hook — this proves only
# that the tool round-trips and returns a valid, matched tier.
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

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
cat > "$HOME/fixture-responses.json" <<'EOF'
{"Pick the cheapest Claude model tier": "sonnet"}
EOF
CMA_JEV_FIXTURE_RESPONSES="$HOME/fixture-responses.json" python3 "$FIXTURE" "$PORT" &
FIX_PID=$!
trap 'kill "$FIX_PID" 2>/dev/null; cleanup_sandbox' EXIT
for i in $(seq 1 40); do
  curl -sf -m 1 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break
  sleep 0.1
done

_tier_call() { # _tier_call <task_description> <risk_hint>
  JEV_BASE_URL="http://127.0.0.1:$PORT" python3 - "$MCP" "$1" "$2" <<'PYEOF'
import json, os, subprocess, sys
task, risk = sys.argv[2], sys.argv[3]
msgs = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
     "params": {"name": "jev_recommend_tier",
                "arguments": {"task_description": task, "risk_hint": risk}}},
]
data = b"".join(b"Content-Length: %d\r\n\r\n%s" % (len(json.dumps(m).encode()), json.dumps(m).encode()) for m in msgs)
p = subprocess.run(["python3", sys.argv[1]], input=data, capture_output=True, timeout=30)
sys.stdout.buffer.write(p.stdout)
PYEOF
}

it "jev_recommend_tier is listed in tools/list"
out=$(JEV_BASE_URL="http://127.0.0.1:$PORT" python3 - "$MCP" <<'PYEOF'
import json, subprocess, sys
msgs = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
]
data = b"".join(b"Content-Length: %d\r\n\r\n%s" % (len(json.dumps(m).encode()), json.dumps(m).encode()) for m in msgs)
p = subprocess.run(["python3", sys.argv[1]], input=data, capture_output=True, timeout=30)
sys.stdout.buffer.write(p.stdout)
PYEOF
)
case "$out" in *'"jev_recommend_tier"'*) _pass "jev_recommend_tier listed" ;; *) _fail "jev_recommend_tier missing from tools/list" "$out" ;; esac

it "jev_recommend_tier returns the fixture-scripted tier (sonnet)"
out=$(_tier_call "review a 3-line config change" "normal")
case "$out" in *'"tier": "sonnet"'*) _pass "tier=sonnet returned" ;; *) _fail "expected tier=sonnet" "$out" ;; esac
case "$out" in *'"reasoning"'*) _pass "reasoning field present" ;; *) _fail "missing reasoning field" "$out" ;; esac
case "$out" in *'advisory only, not enforced'*) _pass "advisory disclaimer present in reasoning" ;; *) _fail "missing advisory disclaimer" "$out" ;; esac

it "risk_hint is actually threaded into the instructions sent to the endpoint"
cat > "$HOME/fixture-responses.json" <<'EOF'
{"risk_hint=high": "opus"}
EOF
out=$(_tier_call "touch production credentials" "high")
case "$out" in *'"tier": "opus"'*) _pass "risk_hint=high reached the endpoint and drove the opus pick" ;; *) _fail "expected tier=opus (risk_hint not threaded through)" "$out" ;; esac

summary
