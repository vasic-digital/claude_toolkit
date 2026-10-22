#!/usr/bin/env python3
"""jev_server.py — canonical stdlib-only fake System-One (Jev) decision
endpoint for tests (detector-side and gate/MCP-side suites both drive it).

Wire format: the VERIFIED systemone dialect (research/jev-ecosystem.md §1.2):
  - request  {model, state, questions} where questions is a MAP of
    name -> {type, instructions, criteria}; question names are never sent
    to the model, all meaning lives in instructions/criteria.
  - response {"model": ..., "answers": {name -> answer}} where
      choice -> {"type":"choice","choice":<opt>,"probabilities":{...},"confidence":0..1}
      noul   -> {"type":"noul","noul":<0..1>}   (no separate confidence)
      score  -> {"type":"score","score":<weighted level>,"legend":{...},
                 "probabilities":{...},"confidence":0..1}
  The parser is tolerant: it also accepts the legacy list form
  questions:[{name, instructions, options:[...]}] and yes/no noul scripts so
  older callers keep working.

Endpoints:
  GET  /healthz        -> 200 {"status":"ok"}
  GET  /v1/models      -> 200 {"object":"list","data":[{"id":<model>,"object":"model"}]}
  POST /v1/systemone   -> 200 {"model": <echo>, "answers": {name: answer}}
  anything else        -> 404

Scripting (deterministic; no randomness anywhere):
  CMA_JEV_FIXTURE_RESPONSES  path to a JSON object mapping an INSTRUCTION
      SUBSTRING (or an exact question name) to the desired answer for any
      question whose "instructions" text contains it. First matching key
      wins (file order). Value forms:
        - choice question: the option to pick (must be one of the criteria
          keys/options, else the first option is used);
        - noul question:   a float in [0,1] read as P(yes); the strings
          "yes"/"no"/"true"/"false" are tolerated and mapped to 0.9/0.1;
        - score question:  a number = the level to return.
      Absent file / no match -> safe defaults: choice -> FIRST option,
      noul -> 0.1, score -> 0.
  CMA_JEV_FIXTURE_DELAY      seconds (float) to sleep BEFORE answering every
      request — drives timeout tests (default 0).
  CMA_JEV_FIXTURE_MODEL      model id reported by /v1/models and echoed in
      systemone responses (default jev-fixture-1).

Usage:
  jev_server.py PORT [PORT_FILE]
  PORT 0 picks an ephemeral port; the bound port is written to PORT_FILE
  (or stdout when PORT_FILE is '-') so callers can discover it.
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

MODEL_ID = os.environ.get("CMA_JEV_FIXTURE_MODEL", "jev-fixture-1")


def _load_responses():
    path = os.environ.get("CMA_JEV_FIXTURE_RESPONSES", "")
    if not path:
        return {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _delay():
    try:
        d = float(os.environ.get("CMA_JEV_FIXTURE_DELAY", "0") or 0)
    except ValueError:
        d = 0.0
    if d > 0:
        time.sleep(d)


def _match(name, instructions, scripted):
    for key, val in scripted.items():
        if not key:
            continue
        if key == name or key in instructions:
            return val
    return None


def _options_of(q):
    """Choice options: §1.2 criteria is a map opt -> description; tolerate a
    list or the legacy top-level "options" list."""
    criteria = q.get("criteria")
    if isinstance(criteria, dict) and criteria:
        return list(criteria.keys())
    if isinstance(criteria, list) and criteria:
        return [str(c) for c in criteria]
    options = q.get("options")
    if isinstance(options, list) and options:
        return [str(o) for o in options]
    return []


def _answer_choice(name, q, matched):
    options = _options_of(q) or ["allow", "ask", "deny"]
    pick = str(matched) if matched is not None else options[0]
    if pick not in options:
        pick = options[0]
    rest = [o for o in options if o != pick]
    share = round(0.1 / len(rest), 6) if rest else 0.0
    probs = {o: (0.9 if o == pick else share) for o in options}
    return {"type": "choice", "choice": pick,
            "probabilities": probs, "confidence": 0.9}


def _answer_noul(matched):
    if matched is None:
        p = 0.1
    elif isinstance(matched, (int, float)):
        p = max(0.0, min(1.0, float(matched)))
    else:
        p = 0.9 if str(matched).strip().lower() in ("yes", "true", "1") else 0.1
    # §1.2: noul answers carry only the probability — no separate confidence.
    return {"type": "noul", "noul": p}


def _answer_score(q, matched):
    criteria = q.get("criteria")
    levels = criteria if isinstance(criteria, list) and criteria else ["level 0", "level 1"]
    try:
        level = int(matched) if matched is not None else 0
    except (TypeError, ValueError):
        level = 0
    level = max(0, min(len(levels) - 1, level))
    legend = {str(i): str(desc) for i, desc in enumerate(levels)}
    probs = {str(i): (0.9 if i == level else round(0.1 / max(len(levels) - 1, 1), 6))
             for i in range(len(levels))}
    return {"type": "score", "score": float(level), "legend": legend,
            "probabilities": probs, "confidence": 0.9}


def _answer_question(name, q, scripted):
    """One §1.2-shaped answer for question `name` (a dict, or {} if the
    caller posted something unparseable)."""
    if not isinstance(q, dict):
        q = {}
    instructions = str(q.get("instructions", "") or q.get("instruction", "") or "")
    matched = _match(name, instructions, scripted)
    qtype = q.get("type")
    if qtype == "score":
        return _answer_score(q, matched)
    # Tolerant typing: explicit "choice", or anything with options/criteria
    # that is not an explicit noul, is answered as a choice.
    if qtype == "choice" or (qtype != "noul" and _options_of(q)):
        return _answer_choice(name, q, matched)
    return _answer_noul(matched)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        _delay()
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path == "/healthz":
            self._send(200, {"status": "ok"})
        elif path == "/v1/models":
            self._send(200, {"object": "list",
                             "data": [{"id": MODEL_ID, "object": "model"}]})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        _delay()
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path != "/v1/systemone":
            self._send(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0") or 0)
        except ValueError:
            length = 0
        raw = self.rfile.read(length) if length > 0 else b""
        try:
            req = json.loads(raw.decode("utf-8")) if raw else {}
        except Exception:
            self._send(400, {"error": "invalid JSON body"})
            return
        questions = req.get("questions")
        scripted = _load_responses()
        answers = {}
        if isinstance(questions, dict):
            # §1.2 canonical form: name -> question map.
            for name, q in questions.items():
                answers[str(name)] = _answer_question(str(name), q, scripted)
        elif isinstance(questions, list):
            # Legacy list form: each item carries its own "name".
            for i, q in enumerate(questions):
                name = str(q.get("name", "q%d" % i)) if isinstance(q, dict) else "q%d" % i
                answers[name] = _answer_question(name, q, scripted)
        else:
            self._send(400, {"error": "missing questions map"})
            return
        self._send(200, {"model": req.get("model", MODEL_ID),
                         "answers": answers})

    def log_message(self, *args):  # keep test output clean
        pass


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    port_file = sys.argv[2] if len(sys.argv) > 2 else None
    srv = HTTPServer(("127.0.0.1", port), Handler)
    bound = srv.server_address[1]
    if port_file and port_file != "-":
        with open(port_file, "w", encoding="utf-8") as fh:
            fh.write(str(bound))
    else:
        sys.stdout.write(str(bound) + "\n")
        sys.stdout.flush()
    srv.serve_forever()


if __name__ == "__main__":
    main()
