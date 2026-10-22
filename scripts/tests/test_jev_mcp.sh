#!/usr/bin/env bash
# test_jev_mcp.sh — hermetic test for scripts/jev_mcp.py: MCP initialize +
# tools/list + jev_ask/jev_models round-trip against the fixture server, and
# graceful isError when the endpoint is down.
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
echo '{}' > "$HOME/fixture-responses.json"
CMA_JEV_FIXTURE_RESPONSES="$HOME/fixture-responses.json" python3 "$FIXTURE" "$PORT" &
FIX_PID=$!
trap 'kill "$FIX_PID" 2>/dev/null; cleanup_sandbox' EXIT
for i in $(seq 1 40); do
  curl -sf -m 1 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break
  sleep 0.1
done

# Helper: pipe Content-Length-framed JSON-RPC into the server, print stdout.
_mcp_roundtrip() { # _mcp_roundtrip <base_url|->
  JEV_BASE_URL="$1" python3 - "$MCP" <<'PYEOF'
import json, os, subprocess, sys
msgs = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
     "params": {"name": "jev_ask", "arguments": {
         "state": "ls -la", "question": "allow this?",
         "options": ["allow", "ask", "deny"]}}},
    {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
     "params": {"name": "jev_models", "arguments": {}}},
]
data = b"".join(b"Content-Length: %d\r\n\r\n%s" % (len(json.dumps(m).encode()), json.dumps(m).encode()) for m in msgs)
env = dict(os.environ)
if os.environ.get("JEV_BASE_URL") == "-":
    env.pop("JEV_BASE_URL", None); env.pop("TYPESAFE_BASE_URL", None)
p = subprocess.run(["python3", sys.argv[1]], input=data, capture_output=True, timeout=30, env=env)
sys.stdout.buffer.write(p.stdout)
PYEOF
}

it "initialize + tools/list + jev_ask + jev_models round-trip"
out=$(_mcp_roundtrip "http://127.0.0.1:$PORT")
rc=$?
assert_eq 0 "$rc" "mcp server exited cleanly"
for sig in '"protocolVersion"' '"jev_ask"' '"jev_models"' '"jev_stats_summary"' 'jev-fixture-1'; do
  case "$out" in *"$sig"*) _pass "response contains $sig" ;; *) _fail "missing $sig" "$out" ;; esac
done
printf '%s' "$out" | grep -qF '\"answer\": \"allow\"' \
  && _pass 'jev_ask answered allow' || _fail 'jev_ask answer' "$out"
# Well-formed: every response frame parses as JSON-RPC with an id.
printf '%s' "$out" > "$HOME/mcp-frames.bin"
frames_ok=$(python3 - "$HOME/mcp-frames.bin" <<'PYEOF'
import json, sys
data = open(sys.argv[1], "rb").read()
count = 0
while data:
    hdr, _, rest = data.partition(b"\r\n\r\n")
    n = int(hdr.split(b":")[1]); msg = json.loads(rest[:n]); data = rest[n:]
    assert msg.get("jsonrpc") == "2.0" and "id" in msg
    count += 1
print(count)
PYEOF
)
assert_eq 4 "$frames_ok" "four well-formed JSON-RPC frames"

it "endpoint down -> isError, no hang"
t0=$SECONDS
out=$(_mcp_roundtrip "http://127.0.0.1:1")
dt=$(( SECONDS - t0 ))
case "$out" in *'"isError": true'*) _pass "isError on unreachable endpoint" ;; *) _fail "no isError" "$out" ;; esac
if (( dt < 10 )); then _pass "no hang (${dt}s)"; else _fail "hung" "${dt}s"; fi

it "no endpoint configured -> isError"
out=$(_mcp_roundtrip "-")
case "$out" in *'"isError": true'*) _pass "isError with no endpoint env" ;; *) _fail "no isError" "$out" ;; esac

kill "$FIX_PID" 2>/dev/null
summary
