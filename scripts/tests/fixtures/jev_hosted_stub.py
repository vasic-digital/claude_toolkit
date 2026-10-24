#!/usr/bin/env python3
"""jev_hosted_stub.py - plain-HTTP loopback stand-in for the hosted System-One
wire contract (TypeSafe /v1/systemone), as VERIFIED against the live server
2026-10-24 (evidence: hosted-Jev validation NOTES G2).

usage: jev_hosted_stub.py PORT PORTFILE
  PORT 0 = ephemeral. Writes the bound port to PORTFILE and its pid to
  PORTFILE.pid so the test records pids without a $(...) subshell.

Wire rules (the part the probe fix is tested against):
  POST /v1/systemone  body {model, state, questions}
    questions MUST be a JSON object (map name -> {type, instructions,
    criteria}); anything else -> HTTP 422 with the server's real wording
    "questions: Input should be a valid dictionary".
    each question type must be noul|choice|score, instructions a string,
    else HTTP 400 "Invalid request."
    ok -> 200 {"model": "jev-1.14.0", "answers": {<name>: <typed answer>},
               "usage": {...}}
  GET /healthz -> 200

Env:
  JEV_STUB_DELAY  seconds to sleep before answering a POST (default 0)
  JEV_STUB_LOG    if set, one line per request: "METHOD PATH auth=<hdr|->"
"""
import json, os, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer

DELAY = float(os.environ.get("JEV_STUB_DELAY", "0") or 0)
LOG = os.environ.get("JEV_STUB_LOG", "")


class H(BaseHTTPRequestHandler):
    def _log(self):
        if LOG:
            with open(LOG, "a") as fh:
                fh.write("%s %s auth=%s\n" % (self.command, self.path,
                                              "present" if self.headers.get("Authorization") else "-"))

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._log()
        if self.path == "/healthz":
            return self._send(200, {"status": "ok"})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        self._log()
        n = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(n)
        if self.path != "/v1/systemone":
            return self._send(404, {"error": "not found"})
        try:
            req = json.loads(raw)
        except Exception:
            return self._send(422, {"detail": [{"msg": "JSON decode error"}]})
        qs = req.get("questions") if isinstance(req, dict) else None
        if not isinstance(qs, dict):
            return self._send(422, {"detail": [{"loc": ["body", "questions"],
                                                "msg": "Input should be a valid dictionary"}]})
        answers = {}
        for name, q in qs.items():
            if not isinstance(q, dict) or q.get("type") not in ("noul", "choice", "score") \
                    or not isinstance(q.get("instructions"), str):
                return self._send(400, {"error_type": "invalid_request", "message": "Invalid request."})
            t = q["type"]
            if t == "noul":
                answers[name] = {"type": "noul", "noul": 0.05}
            elif t == "choice":
                answers[name] = {"type": "choice", "choice": "allow",
                                 "probabilities": {"allow": 0.9, "ask": 0.07, "deny": 0.03},
                                 "confidence": 0.9}
            else:
                answers[name] = {"type": "score", "score": 3, "confidence": 0.8}
        if DELAY:
            time.sleep(DELAY)
        self._send(200, {"model": "jev-1.14.0", "answers": answers,
                         "usage": {"input_tokens": 10, "output_tokens": 5}})

    def log_message(self, *a):
        pass


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    portfile = sys.argv[2] if len(sys.argv) > 2 else ""
    srv = HTTPServer(("127.0.0.1", port), H)
    if portfile:
        with open(portfile + ".pid", "w") as fh:
            fh.write(str(os.getpid()))
        with open(portfile, "w") as fh:
            fh.write(str(srv.server_address[1]))
    srv.serve_forever()


main()
