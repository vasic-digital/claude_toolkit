#!/usr/bin/env python3
"""jev_mcp.py — stdlib-only MCP server exposing the Jev decision layer.

Design: toolkit-jev-design §2.5. python3 >= 3.8 stdlib only (json, os, sys,
urllib.request). Speaks MCP over stdio (JSON-RPC 2.0). Framing: Content-Length
LSP-style headers per the MCP stdio spec; newline-delimited JSON is also
accepted on input for robustness.

Tools:
  jev_ask(state, question, options?, decision_type?) -> choice answer
      (options given) or noul probability; passthrough to
      ${JEV_BASE_URL||TYPESAFE_BASE_URL}/v1/systemone, UNLESS decision_type
      matches a route in JEV_ROUTES_FILE, in which case the multi-candidate
      gateway (see _route_ask) answers instead.
  jev_models()                       -> GET /v1/models listing
  jev_stats_summary()                -> aggregate of $JEV_STATE_DIR/decisions.jsonl
  jev_recommend_tier(task_description, risk_hint?) -> {"tier", "confidence",
      "reasoning"}; ADVISORY ONLY. Claude Code's PreToolUse hooks (jev-gate.sh)
      can only allow/ask/deny a tool call — they cannot rewrite its
      parameters, so Jev cannot literally pick which model a Task/Agent
      subagent spawn uses. This tool exists for the ORCHESTRATING Claude to
      call explicitly before it decides which model to pass to a subagent
      dispatch; nothing here enforces the recommendation.

Env: JEV_BASE_URL or TYPESAFE_BASE_URL, JEV_API_KEY or TYPESAFE_API_KEY
     (explicit override) or JEV_KEY_VAR (the key's variable NAME in
     api_keys.sh, resolved here at call time rather than exported as secret
     material into the launched agent's whole process tree),
     JEV_MODEL (default jev-latest), JEV_MODE (default shadow),
     JEV_STATE_DIR (default ~/.local/state/jev), JEV_MCP_TIMEOUT (default 4),
     JEV_ROUTES_FILE (optional; see jev-routes.json.template — opt-in
     multi-candidate routing by decision_type, additive, never required).

Any unreachable endpoint yields a structured isError:true result — never a
hang, never a crash.
"""
import json
import os
import re
import subprocess
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import http_noredirect as _http  # noqa: E402  (the one shared credential-safe opener)

_KEY_VAR_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

PROTOCOL_VERSION = "2024-11-05"
SERVER_INFO = {"name": "jev-mcp", "version": "1.0.0"}

TOOLS = [
    {
        "name": "jev_ask",
        "description": "Ask the Jev decision model an allow/ask/deny-style choice "
                       "question (when options are given) or a noul probability "
                       "question (when they are not). If decision_type matches a "
                       "route in JEV_ROUTES_FILE, the multi-candidate gateway "
                       "answers instead of the single default endpoint.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "state": {"type": "string", "description": "Context the decision is about."},
                "question": {"type": "string", "description": "The decision instruction."},
                "options": {"type": "array", "items": {"type": "string"},
                            "description": "Choice options; omit for a noul probability."},
                "decision_type": {"type": "string",
                                   "description": "Optional route key into JEV_ROUTES_FILE "
                                                   "for multi-candidate specialization/voting."},
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
    {
        "name": "jev_recommend_tier",
        "description": "ADVISORY: recommend a Claude model tier (haiku/sonnet/opus) for a "
                       "planned subagent dispatch. Never enforced — the orchestrating "
                       "Claude decides whether to act on the recommendation.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "task_description": {"type": "string", "description": "What the subagent will do."},
                "risk_hint": {"type": "string", "description": "normal|high; default normal."},
            },
            "required": ["task_description"],
        },
    },
]


def _endpoint():
    return (os.environ.get("JEV_BASE_URL")
            or os.environ.get("TYPESAFE_BASE_URL") or "").rstrip("/")


def _resolve_key_var(key_var):
    """Resolve a key-variable NAME to its value from the keys file. Shared by
    the default single-endpoint path and route candidates that name their
    own key_var (routes.json candidates reuse detect_jev_records()'s
    key_var field rather than ever carrying a secret inline)."""
    if not key_var or not _KEY_VAR_RE.match(key_var):
        return "local"
    keys_file = os.environ.get("CMA_KEYS_FILE") or os.path.expanduser("~/api_keys.sh")
    try:
        out = subprocess.run(
            # the keys-file path and the (regex-validated) variable name are
            # positional arguments, never shell text
            ["bash", "-c", 'f=$1; v=$2; source "$f" >/dev/null 2>&1; printf %s "${!v:-}"',
             "_", keys_file, key_var],
            capture_output=True, text=True, timeout=4,
        )
        return out.stdout.strip() or "local"
    except Exception:
        return "local"


def _api_key():
    direct = os.environ.get("JEV_API_KEY")
    if direct:
        return direct
    # TYPESAFE_API_KEY is the implicit default ONLY when no other key variable is
    # declared: an endpoint bound to a different variable (JEV_KEY_VAR) must never
    # be handed the TypeSafe key. (Origin pinning is enforced in jev-gate.sh.)
    kv = os.environ.get("JEV_KEY_VAR", "")
    if not kv or kv == "TYPESAFE_API_KEY":
        implicit = os.environ.get("TYPESAFE_API_KEY")
        if implicit:
            return implicit
    return _resolve_key_var(kv)


_LOOPBACK_RE = re.compile(r"^(127(\.[0-9]{1,3}){3}|localhost|\[::1\])$")


def _shipped_pins():
    """(origin, key_var) pairs from the SHIPPED providers/jev.json next to this
    script. Deliberately NOT overridable by environment or cache: an override
    file must never be able to attest where a key may go."""
    try:
        path = os.path.join(os.path.dirname(os.path.realpath(__file__)), "providers", "jev.json")
        with open(path, "r", encoding="utf-8") as fh:
            hosted = (json.load(fh).get("hosted") or {})
        out = set()
        for h in hosted.values():
            if not h.get("enabled", True):
                continue
            m = re.match(r"^(https://[^/?#]+)", h.get("base_url") or "")
            if m:                      # ORIGIN of the shipped base (openrouter lives under /api)
                out.add((m.group(1), h.get("key_var") or ""))
        return out
    except Exception:
        return set()


def _origin_allows_key(base, key_var):
    """True when a key held in variable `key_var` may be sent to `base`.
    http never carries a key. https only to: a loopback host; the shipped pin
    with the SAME key variable; or an operator-listed
    CMA_JEV_TRUSTED_ORIGINS=origin=KEYVAR pair."""
    m = re.match(r"^(https://[^/?#]+)", base or "")
    if not m:
        return False
    origin = m.group(1)
    hostport = origin[len("https://"):]
    if re.search(r"[@\\%\s]", hostport):
        return False
    host = hostport.split("]")[0] + "]" if hostport.startswith("[") else hostport.split(":")[0]
    if _LOOPBACK_RE.match(host):
        octets = host.split(".")
        if not (len(octets) == 4 and any(int(o) > 255 for o in octets)):
            return True
    if (origin, key_var) in _shipped_pins():
        return True
    for t in os.environ.get("CMA_JEV_TRUSTED_ORIGINS", "").split():
        o, sep, k = t.partition("=")
        if sep and o == origin and k == key_var:
            return True
    return False


def _key_for_base(base):
    """The bearer for `base`, or RuntimeError('key_unpinned...') when the key
    would reach an https origin that was never validated for it."""
    if os.environ.get("JEV_API_KEY"):
        return os.environ["JEV_API_KEY"]          # explicit operator override
    kv = os.environ.get("JEV_KEY_VAR", "") or "TYPESAFE_API_KEY"
    key = _api_key()
    if (base or "").lower().startswith("https://"):
        if not _origin_allows_key(base, kv):
            raise RuntimeError("key_unpinned: origin is not loopback, a shipped pin for "
                               "this key variable, or in CMA_JEV_TRUSTED_ORIGINS")
    return key


def _ssl_ctx(ca_file=None):
    """TLS context for an https decide gateway: trust a CA in ADDITION to the
    system store; verification is never off. ca_file None -> JEV_CA_FILE (the
    single configured endpoint). A routes.json candidate WITHOUT its own
    ca_file also reaches this branch, so it trusts JEV_CA_FILE as an extra root
    on top of the system store - deliberate and documented (the operator's own
    configured CA; see the Jev User Guide, routes.json). An EXPLICIT ca_file
    (a candidate's own CA) must be a readable file: otherwise raise (fail
    closed) instead of silently falling back to a different trust root."""
    import ssl
    ctx = ssl.create_default_context()
    if ca_file:
        if not os.path.isfile(ca_file) or not os.access(ca_file, os.R_OK):
            raise RuntimeError("candidate ca_file is not a readable file")
        ca = ca_file
        ctx.load_verify_locations(cafile=ca)
        return ctx
    ca = os.environ.get("JEV_CA_FILE", "")
    if ca and os.path.isfile(ca):
        ctx.load_verify_locations(cafile=ca)
    return ctx


def _open(req, timeout, ca_file=None):
    """urlopen with the CA-aware TLS context, no redirects, and the bearer
    key only ever sent over https (stripped for any other scheme)."""
    if not req.full_url.lower().startswith("https://"):
        req.headers.pop("Authorization", None)
    return _http.open_url(req, timeout=timeout, context=_ssl_ctx(ca_file))


def _post_systemone(state, questions, model=None, base=None, key=None, ca_file=None):
    """POST one systemone request. base/key/model default to the single
    configured endpoint's env vars; a route candidate overrides any subset
    to call a different endpoint without touching the process environment."""
    base = (base or _endpoint())
    if not base:
        raise RuntimeError("no JEV_BASE_URL/TYPESAFE_BASE_URL configured")
    payload = json.dumps({
        "model": model or os.environ.get("JEV_MODEL", "jev-latest"),
        "state": state,
        "questions": questions,
    }).encode("utf-8")
    req = urllib.request.Request(
        base.rstrip("/") + "/v1/systemone", data=payload,
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer " + (key if key is not None else _key_for_base(base))})
    timeout = float(os.environ.get("JEV_MCP_TIMEOUT", "4"))
    with _open(req, timeout, ca_file) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _load_routes():
    """Opt-in routes.json: {"routes": {decision_type: {candidates:[...],
    min_confidence, min_agreement}}}. Absent/unreadable/malformed -> {} so
    every caller falls back to the single-endpoint path unchanged."""
    path = os.environ.get("JEV_ROUTES_FILE", "")
    if not path or not os.path.isfile(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        routes = data.get("routes") if isinstance(data, dict) else None
        return routes if isinstance(routes, dict) else {}
    except Exception:
        return {}


def _route_ca_file(ca):
    """A candidate's relative ca_file is relative to the routes.json that names
    it (never to the process cwd, which is attacker/launcher-controlled)."""
    if not ca or os.path.isabs(ca):
        return ca or None
    base = os.path.dirname(os.path.abspath(os.environ.get("JEV_ROUTES_FILE", "")))
    return os.path.join(base, ca)


def _candidate_answer(candidate, state, questions):
    """Query one route candidate; returns the raw answers dict for the
    'ask' question, or None on any failure (never raises — a candidate
    going down must not abort the route, just fall through to the next)."""
    try:
        base = candidate.get("base_url", "")
        kv = candidate.get("key_var", "")
        key = _resolve_key_var(kv)
        # Same origin rule as the single endpoint: an https candidate gets a
        # key only at loopback, a shipped pin for this key variable, or an
        # operator-trusted origin. A candidate whose key_var names a secret
        # but whose origin fails the rule is skipped, never sent unauthenticated.
        if key and (base or "").lower().startswith("https://") and not _origin_allows_key(base, kv):
            return None
        data = _post_systemone(
            state, questions,
            model=candidate.get("model"),
            base=base,
            key=key,
            ca_file=_route_ca_file(candidate.get("ca_file")),
        )
        return (data.get("answers") or {}).get("ask")
    except Exception:
        return None


def _answer_value(a):
    return a.get("choice", a.get("noul", a.get("answer")))


def _route_ask(route, state, questions):
    """Multi-candidate specialization/voting gateway for one route. Never
    requires a second real decision model to exist: with one candidate (or
    min_agreement unset) it behaves as ordered failover; with
    min_agreement set and >=2 candidates configured, it requires two
    candidates to agree before trusting the result, degrading honestly
    (never silently) when they don't."""
    candidates = route.get("candidates") or []
    min_confidence = float(route.get("min_confidence", 0.0) or 0.0)
    min_agreement = route.get("min_agreement")
    results = []  # [(candidate, answer_dict_or_None)]
    for c in candidates:
        results.append((c, _candidate_answer(c, state, questions)))
        if min_agreement is None and results[-1][1] is not None \
                and results[-1][1].get("confidence", results[-1][1].get("noul", 0)) >= min_confidence:
            a = results[-1][1]
            return {"answer": _answer_value(a), "probabilities": a.get("probabilities", {}),
                    "confidence": a.get("confidence", 0), "endpoint": c.get("base_url", ""),
                    "provider_id": c.get("provider_id"), "degraded": False}
    live = [(c, a) for c, a in results if a is not None]
    if min_agreement is not None:
        for i in range(len(live)):
            for j in range(i + 1, len(live)):
                c1, a1 = live[i]
                c2, a2 = live[j]
                conf1 = a1.get("confidence", a1.get("noul", 0))
                conf2 = a2.get("confidence", a2.get("noul", 0))
                if _answer_value(a1) == _answer_value(a2) and conf1 >= min_confidence and conf2 >= min_confidence:
                    return {"answer": _answer_value(a1), "probabilities": a1.get("probabilities", {}),
                            "confidence": min(conf1, conf2),
                            "agreement": True,
                            "agreed_candidates": [c1.get("provider_id"), c2.get("provider_id")],
                            "degraded": False}
    # No candidate (or pair) cleared the bar: degrade honestly to the
    # highest-priority live answer rather than hard-failing the tool call.
    if live:
        c, a = live[0]
        return {"answer": _answer_value(a), "probabilities": a.get("probabilities", {}),
                "confidence": a.get("confidence", a.get("noul", 0)),
                "endpoint": c.get("base_url", ""), "provider_id": c.get("provider_id"),
                "agreement": False, "degraded": True,
                "reason": "no candidate met min_confidence/min_agreement"}
    raise RuntimeError("no route candidate reachable")


def _tool_jev_ask(args):
    state = str(args.get("state", ""))[:12000]
    question = str(args.get("question", ""))
    options = args.get("options") or []
    decision_type = str(args.get("decision_type", "") or "")
    # Verified systemone wire format (research §1.2): questions is a name ->
    # question map; meaning lives in instructions/criteria only.
    if options:
        q = {"ask": {"type": "choice", "instructions": question,
                     "criteria": {str(o): str(o) for o in options}}}
    else:
        q = {"ask": {"type": "noul", "instructions": question,
                     "criteria": {"true": "yes", "false": "no"}}}
    routes = _load_routes() if decision_type else {}
    route = routes.get(decision_type) if routes else None
    if route:
        return _route_ask(route, state, q)
    data = _post_systemone(state, q)
    a = (data.get("answers") or {}).get("ask")
    if not a:
        raise RuntimeError("endpoint returned no answers")
    answer = _answer_value(a)
    return {"answer": answer, "probabilities": a.get("probabilities", {}),
            "confidence": a.get("confidence", 0),
            "endpoint": _endpoint(), "model": data.get("model")}


def _tool_jev_recommend_tier(args):
    """ADVISORY: a Choice question over {haiku, sonnet, opus}. The caller
    (the orchestrating Claude, before dispatching a subagent) decides
    whether to act on the recommendation — nothing here is enforced."""
    task_description = str(args.get("task_description", ""))[:4000]
    risk_hint = str(args.get("risk_hint", "normal") or "normal")
    tiers = ["haiku", "sonnet", "opus"]
    instructions = (
        "Pick the cheapest Claude model tier that can reliably complete this "
        "subagent task without needing escalation. risk_hint={0}. "
        "Prefer haiku for mechanical/narrow work, sonnet for standard "
        "multi-step work, opus only for tasks needing deep judgment or "
        "high-stakes correctness.".format(risk_hint)
    )
    q = {"ask": {"type": "choice", "instructions": instructions,
                 "criteria": {t: t for t in tiers}}}
    data = _post_systemone(task_description, q)
    a = (data.get("answers") or {}).get("ask")
    if not a:
        raise RuntimeError("endpoint returned no answers")
    tier = _answer_value(a)
    if tier not in tiers:
        tier = "sonnet"
    return {"tier": tier, "confidence": a.get("confidence", 0),
            "reasoning": "jev choice over {0}; advisory only, not enforced".format(tiers),
            "probabilities": a.get("probabilities", {})}


def _tool_jev_models(_args):
    base = _endpoint()
    if not base:
        raise RuntimeError("no JEV_BASE_URL/TYPESAFE_BASE_URL configured")
    req = urllib.request.Request(base + "/v1/models",
                                 headers={"Authorization": "Bearer " + _key_for_base(base)})
    timeout = float(os.environ.get("JEV_MCP_TIMEOUT", "4"))
    with _open(req, timeout) as resp:
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
    if name == "jev_recommend_tier":
        return _tool_jev_recommend_tier(args or {})
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
