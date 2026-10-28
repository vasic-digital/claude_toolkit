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

# ---------------------------------------------------------------------------
# Transport framing (MCP stdio = newline-delimited JSON; Claude Code speaks it).
# Root cause of the 30 s CONNECT_TIMEOUT: the server always answered with LSP
# Content-Length frames, which an NDJSON client cannot parse.
# ---------------------------------------------------------------------------
_MCPDRV="$HOME/mcpdrv.py"
cat > "$_MCPDRV" <<'PYEOF'
import json, os, subprocess, sys, time
MCP = sys.argv[1]; scenario = sys.argv[2]
env = dict(os.environ)
env["JEV_BASE_URL"] = os.environ.get("DRV_BASE", "http://127.0.0.1:1")
def nd(m): return (json.dumps(m, ensure_ascii=False) + "\n").encode("utf-8")
def cl(m):
    b = json.dumps(m).encode("utf-8"); return b"Content-Length: %d\r\n\r\n" % len(b) + b
INIT = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
    "protocolVersion": os.environ.get("DRV_PV", "2025-06-18"), "capabilities": {},
    "clientInfo": {"name": "claude-code", "version": "2.1.311"}}}
NOTE = {"jsonrpc": "2.0", "method": "notifications/initialized"}
LIST = {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}
MODELS = {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "jev_models", "arguments": {}}}
STATS = {"jsonrpc": "2.0", "id": "s-4", "method": "tools/call", "params": {"name": "jev_stats_summary", "arguments": {}}}
def run(data, close=True, timeout=20):
    t0 = time.time()
    p = subprocess.run([sys.executable, MCP], input=data, capture_output=True, timeout=timeout, env=env)
    return p, time.time() - t0
def nd_lines(out):
    # strict: every stdout line must be one JSON object, no Content-Length noise
    res = []
    for ln in out.split(b"\n"):
        if ln.strip():
            assert not ln.lower().startswith(b"content-length"), "got Content-Length frame: %r" % ln[:60]
            res.append(json.loads(ln))
    return res
def cl_frames(out):
    res = []
    while out:
        hdr, sep, rest = out.partition(b"\r\n\r\n")
        assert sep and hdr.lower().startswith(b"content-length:"), "not CL framed: %r" % out[:60]
        n = int(hdr.split(b":")[1]); res.append(json.loads(rest[:n])); out = rest[n:]
    return res
ok = lambda c, m: (print(("PASS " if c else "FAIL ") + m), None)[1]
if scenario == "ndjson":
    p, dt = run(b"".join(nd(m) for m in (INIT, NOTE, LIST, MODELS, STATS)))
    ok(p.returncode == 0, "ndjson: clean exit on EOF rc=%s" % p.returncode)
    try: r = nd_lines(p.stdout); ok(True, "ndjson: stdout is pure NDJSON")
    except Exception as e: r = []; ok(False, "ndjson: stdout is pure NDJSON (%s)" % e)
    ok(len(r) == 4, "ndjson: 4 replies (notification gets none), got %d" % len(r))
    ids = [m.get("id") for m in r]
    ok(ids == [1, 2, 3, "s-4"], "ndjson: ids echoed with original types %r" % (ids,))
    ok(r and r[0]["result"]["protocolVersion"] == "2025-06-18", "ndjson: echoes supported protocolVersion 2025-06-18")
    ok(r and "tools" in r[0]["result"]["capabilities"] and r[0]["result"]["serverInfo"]["name"], "ndjson: capabilities.tools + serverInfo")
    names = sorted(t["name"] for t in r[1]["result"]["tools"]) if len(r) > 1 else []
    ok("jev_models" in names and "jev_stats_summary" in names, "ndjson: tools/list %s" % names)
    ok(len(r) > 2 and r[2]["result"].get("isError") is True, "ndjson: jev_models on dead endpoint -> isError (graceful)")
    ok(len(r) > 3 and "content" in r[3]["result"], "ndjson: jev_stats_summary returns content")
    ok(dt < 10, "ndjson: no hang (%.2fs)" % dt)
elif scenario == "pv_unknown":
    os.environ["DRV_PV"] = "2099-01-01"; INIT["params"]["protocolVersion"] = "2099-01-01"
    p, _ = run(nd(INIT)); r = nd_lines(p.stdout)
    pv = r[0]["result"]["protocolVersion"]
    ok(pv in ("2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25") and pv != "2099-01-01", "unknown client version -> server's own supported version (%s)" % pv)
elif scenario == "cl":
    p, _ = run(b"".join(cl(m) for m in (INIT, NOTE, LIST, MODELS)))
    try: r = cl_frames(p.stdout); ok(len(r) == 3 and [m["id"] for m in r] == [1, 2, 3], "content-length in -> content-length out (3 frames)")
    except Exception as e: ok(False, "content-length compat (%s)" % e)
elif scenario == "mixed":
    p, _ = run(nd(INIT) + cl(LIST) + nd(MODELS))
    out = p.stdout
    ok(out.count(b"Content-Length:") == 1, "mixed: only the CL request gets a CL reply (n=%d)" % out.count(b"Content-Length:"))
    ok(out.startswith(b"{") and out.count(b'"id": 2') == 1 and out.count(b'"id": 3') == 1, "mixed: NDJSON replies for NDJSON requests")
elif scenario == "large":
    big = {"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "jev_recommend_tier", "arguments": {"prompt": "x" * 400000}}}
    p, _ = run(nd(INIT) + nd(big)); r = nd_lines(p.stdout)
    ok(p.returncode == 0 and [m["id"] for m in r] == [1, 7], "large 400KB NDJSON line handled, reply id 7")
elif scenario == "unicode":
    m = {"jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": {"name": "jev_recommend_tier", "arguments": {"prompt": "здраво 世界 \U0001F600   ok"}}}
    p, _ = run(nd(INIT) + nd(m)); r = nd_lines(p.stdout)
    ok(len(r) == 2 and r[1]["id"] == 8 and "result" in r[1], "unicode (incl. U+2028) request answered, one JSON object per line")
elif scenario == "partial_eof":
    p, _ = run(json.dumps(INIT).encode("utf-8"))   # no trailing newline, then EOF
    r = nd_lines(p.stdout) if p.stdout else []
    ok(p.returncode == 0 and len(r) == 1 and r[0]["id"] == 1, "unterminated final NDJSON line is still answered at EOF")
elif scenario == "garbage":
    p, _ = run(b"not json at all\n" + nd(INIT) + b"\n\n" + nd({"jsonrpc": "2.0", "id": 5, "method": "ping"}))
    r = nd_lines(p.stdout)
    ok(p.returncode == 0 and 1 in [m.get("id") for m in r] and 5 in [m.get("id") for m in r], "garbage line does not kill the server; later requests answered")
    ok(all(m.get("jsonrpc") == "2.0" for m in r), "garbage: only JSON-RPC objects on stdout")
elif scenario == "notif_only":
    p, _ = run(nd(NOTE) + nd({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 9}}) + nd({"jsonrpc": "2.0", "method": "nonexistent/thing"}))
    ok(p.returncode == 0 and p.stdout == b"", "notifications (known or unknown) produce NO stdout (got %r)" % p.stdout[:80])
elif scenario == "unknown_request":
    p, _ = run(nd({"jsonrpc": "2.0", "id": 11, "method": "nope/nope"})); r = nd_lines(p.stdout)
    ok(r and r[0]["error"]["code"] == -32601 and r[0]["id"] == 11, "unknown request -> -32601 with id")
elif scenario == "stderr_clean":
    p, _ = run(nd(INIT) + nd(LIST))
    ok(p.stdout.count(b"\n") == 2 and p.stderr == b"" , "no stray output: stdout 2 lines, stderr empty (%r)" % p.stderr[:80])
PYEOF
_drv() { python3 "$_MCPDRV" "$MCP" "$1" 2>&1; }
for sc in ndjson pv_unknown cl mixed large unicode partial_eof garbage notif_only unknown_request stderr_clean; do
  it "framing: $sc"
  out=$(_drv "$sc")
  if printf '%s' "$out" | grep -q '^Traceback'; then
    _fail "framing $sc: driver raised (server output not framed as the client needs)" "$(printf '%s' "$out" | tail -3)"
    continue
  fi
  while IFS= read -r line; do
    case "$line" in
      "PASS "*) _pass "${line#PASS }" ;;
      "FAIL "*) _fail "${line#FAIL }" "$out" ;;
      *) [ -n "$line" ] && _fail "driver error" "$line" ;;
    esac
  done <<<"$out"
done

kill "$FIX_PID" 2>/dev/null
summary
