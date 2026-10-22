#!/usr/bin/env python3
"""jev_mcp.py — stdlib-only MCP server exposing the Jev decision layer.

Design: toolkit-jev-design §2.5. python3 >= 3.8 stdlib only (json, os, sys,
urllib.request). Speaks MCP over stdio (JSON-RPC 2.0). Framing: Content-Length
LSP-style headers per the MCP stdio spec; newline-delimited JSON is also
accepted on input for robustness.

Tools:
  jev_ask(state, question, options?) -> choice answer (options given) or noul
      probability; passthrough to ${JEV_BASE_URL||TYPESAFE_BASE_URL}/v1/systemone
  jev_models()                       -> GET /v1/models listing
  jev_stats_summary()                -> aggregate of $JEV_STATE_DIR/decisions.jsonl

Env: JEV_BASE_URL or TYPESAFE_BASE_URL, JEV_API_KEY or TYPESAFE_API_KEY,
     JEV_MODEL (default jev-latest), JEV_MODE (default shadow),
     JEV_STATE_DIR (default ~/.local/state/jev), JEV_MCP_TIMEOUT (default 4).

Any unreachable endpoint yields a structured isError:true result — never a
hang, never a crash.
"""
import json
import os
import sys
import urllib.request

PROTOCOL_VERSION = "2024-11-05"
SERVER_INFO = {"name": "jev-mcp", "version": "1.0.0"}

TOOLS = [
    {
        "name": "jev_ask",
        "description": "Ask the Jev decision model an allow/ask/deny-style choice "
                       "question (when options are given) or a noul probability "
                       "question (when they are not).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "state": {"type": "string", "description": "Context the decision is about."},
                "question": {"type": "string", "description": "The decision instruction."},
                "options": {"type": "array", "items": {"type": "string"},
                            "description": "Choice options; omit for a noul probability."},
            },
            "required": ["state", "question"],
        },
    },
    {
        "name": "jev_models",
        "description": "List decision models served by the active Jev endpoint.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "jev_stats_summary",
        "description": "Summarize the local Jev gate evidence log (decisions.jsonl).",
        "inputSchema": {"type": "object", "properties": {}},
    },
]


def _endpoint():
    return (os.environ.get("JEV_BASE_URL")
            or os.environ.get("TYPESAFE_BASE_URL") or "").rstrip("/")


def _api_key():
    return os.environ.get("JEV_API_KEY") or os.environ.get("TYPESAFE_API_KEY") or "local"


def _post_systemone(questions):
    base = _endpoint()
    if not base:
        raise RuntimeError("no JEV_BASE_URL/TYPESAFE_BASE_URL configured")
    payload = json.dumps({
        "model": os.environ.get("JEV_MODEL", "jev-latest"),
        "state": questions.pop("_state", ""),
        "questions": questions["questions"],
    }).encode("utf-8")
    req = urllib.request.Request(
        base + "/v1/systemone", data=payload,
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer " + _api_key()})
    timeout = float(os.environ.get("JEV_MCP_TIMEOUT", "4"))
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _tool_jev_ask(args):
    state = str(args.get("state", ""))[:12000]
    question = str(args.get("question", ""))
    options = args.get("options") or []
    # Verified systemone wire format (research §1.2): questions is a name ->
    # question map; meaning lives in instructions/criteria only.
    if options:
        q = {"ask": {"type": "choice", "instructions": question,
                     "criteria": {str(o): str(o) for o in options}}}
    else:
        q = {"ask": {"type": "noul", "instructions": question,
                     "criteria": {"true": "yes", "false": "no"}}}
    data = _post_systemone({"_state": state, "questions": q})
    a = (data.get("answers") or {}).get("ask")
    if not a:
        raise RuntimeError("endpoint returned no answers")
    answer = a.get("choice", a.get("noul", a.get("answer")))
    return {"answer": answer, "probabilities": a.get("probabilities", {}),
            "confidence": a.get("confidence", 0),
            "endpoint": _endpoint(), "model": data.get("model")}


def _tool_jev_models(_args):
    base = _endpoint()
    if not base:
        raise RuntimeError("no JEV_BASE_URL/TYPESAFE_BASE_URL configured")
    req = urllib.request.Request(base + "/v1/models",
                                 headers={"Authorization": "Bearer " + _api_key()})
    timeout = float(os.environ.get("JEV_MCP_TIMEOUT", "4"))
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    return {"endpoint": base,
            "models": [m.get("id") for m in data.get("data", [])]}


def _tool_jev_stats_summary(_args):
    state_dir = os.environ.get("JEV_STATE_DIR",
                               os.path.expanduser("~/.local/state/jev"))
    path = os.path.join(state_dir, "decisions.jsonl")
    totals = {"total": 0, "by_answer": {}, "by_mode": {}, "by_agent": {},
              "fallbacks": 0, "avg_latency_ms": 0}
    lat_sum = 0
    if os.path.isfile(path):
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                totals["total"] += 1
                for key, field in (("by_answer", "answer"), ("by_mode", "mode"),
                                   ("by_agent", "agent")):
                    v = str(rec.get(field, "unknown"))
                    totals[key][v] = totals[key].get(v, 0) + 1
                if rec.get("fallback"):
                    totals["fallbacks"] += 1
                lat_sum += int(rec.get("latency_ms", 0) or 0)
    if totals["total"]:
        totals["avg_latency_ms"] = round(lat_sum / totals["total"], 1)
    totals["log"] = path
    return totals


def _call_tool(name, args):
    if name == "jev_ask":
        return _tool_jev_ask(args or {})
    if name == "jev_models":
        return _tool_jev_models(args or {})
    if name == "jev_stats_summary":
        return _tool_jev_stats_summary(args or {})
    raise RuntimeError("unknown tool: %s" % name)


def _result(req_id, result):
    return {"jsonrpc": "2.0", "id": req_id, "result": result}


def _error(req_id, code, message):
    return {"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}}


def _handle(msg):
    method = msg.get("method", "")
    req_id = msg.get("id")
    if method == "initialize":
        return _result(req_id, {"protocolVersion": PROTOCOL_VERSION,
                                "capabilities": {"tools": {}},
                                "serverInfo": SERVER_INFO})
    if method in ("notifications/initialized", "initialized"):
        return None
    if method == "tools/list":
        return _result(req_id, {"tools": TOOLS})
    if method == "tools/call":
        params = msg.get("params") or {}
        try:
            out = _call_tool(params.get("name", ""), params.get("arguments"))
            return _result(req_id, {
                "content": [{"type": "text", "text": json.dumps(out)}],
                "structuredContent": out})
        except Exception as exc:  # graceful: endpoint down, bad args, ...
            return _result(req_id, {
                "content": [{"type": "text", "text": "jev error: %s" % exc}],
                "isError": True})
    if method == "ping":
        return _result(req_id, {})
    if req_id is None:
        return None
    return _error(req_id, -32601, "method not found: %s" % method)


def _write(msg):
    body = json.dumps(msg).encode("utf-8")
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    sys.stdout.buffer.flush()


def _read_message(buf):
    """Read one framed (Content-Length) or newline-delimited message."""
    # Header framing?
    nl = buf.find(b"\n")
    first = buf[:nl] if nl != -1 else buf
    if first.lower().startswith(b"content-length:"):
        # Need headers + blank line + body.
        hdr_end = buf.find(b"\r\n\r\n")
        sep_len = 4
        if hdr_end == -1:
            hdr_end = buf.find(b"\n\n")
            sep_len = 2
        if hdr_end == -1:
            return None, buf  # wait for more
        length = int(first.split(b":", 1)[1].strip())
        if len(buf) < hdr_end + sep_len + length:
            return None, buf
        body = buf[hdr_end + sep_len: hdr_end + sep_len + length]
        return json.loads(body.decode("utf-8")), buf[hdr_end + sep_len + length:]
    if nl == -1:
        return None, buf
    line = buf[:nl].strip()
    rest = buf[nl + 1:]
    if not line:
        return "skip", rest
    return json.loads(line.decode("utf-8")), rest


def main():
    buf = b""
    while True:
        chunk = sys.stdin.buffer.read1(65536) if hasattr(sys.stdin.buffer, "read1") \
            else sys.stdin.buffer.read(65536)
        if not chunk:
            break
        buf += chunk
        while True:
            try:
                msg, buf = _read_message(buf)
            except ValueError:
                msg, buf = "skip", buf.split(b"\n", 1)[-1] if b"\n" in buf else b""
            if msg is None:
                break
            if msg == "skip":
                continue
            out = _handle(msg)
            if out is not None:
                _write(out)


if __name__ == "__main__":
    main()
