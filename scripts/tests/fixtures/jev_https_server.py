#!/usr/bin/env python3
"""jev_https_server.py — hermetic stand-in for the llmctl decide gateway
transport: TLS (self-signed cert supplied by the test) + mandatory bearer key.

usage: jev_https_server.py PORT PORTFILE MODE [CERT KEY EXPECTED_KEY BIND]
  MODE  tls      HTTPS; /healthz open; /v1/models + /v1/systemone need
                 'Authorization: Bearer <EXPECTED_KEY>' else 401
        tls404   HTTPS; /v1/models answers 404 (not an auth failure)
        redirect HTTPS; /v1/models answers 302 -> $JEV_FIXTURE_REDIRECT_TO
        plain    plain HTTP, no auth (a server that is NOT the real gateway)
  BIND  address to bind (default 127.0.0.1; never 0.0.0.0 in the suites)
Writes the bound port to PORTFILE and its own pid to PORTFILE.pid, so the
test records pids WITHOUT capturing the process in a $(...) subshell.
If $JEV_FIXTURE_LOG is set, every request appends one line
'METHOD PATH auth=<Authorization header or ->' (sink-side evidence).
"""
import json, os, ssl, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

MODE = sys.argv[3] if len(sys.argv) > 3 else "tls"
EXPECTED = sys.argv[6] if len(sys.argv) > 6 else ""
BIND = sys.argv[7] if len(sys.argv) > 7 else "127.0.0.1"
LOG = os.environ.get("JEV_FIXTURE_LOG", "")


class H(BaseHTTPRequestHandler):
    def _log(self):
        if LOG:
            with open(LOG, "a") as fh:
                fh.write("%s %s auth=%s\n" % (self.command, self.path,
                                              self.headers.get("Authorization", "-")))

    def _send(self, code, obj, extra=None):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _authed(self):
        if MODE == "plain":
            return True
        return self.headers.get("Authorization", "") == "Bearer " + EXPECTED

    def do_GET(self):
        self._log()
        if self.path == "/healthz":
            return self._send(200, {"status": "ok"})
        if self.path == "/v1/models":
            if MODE == "redirect":
                return self._send(302, {}, {"Location": os.environ.get("JEV_FIXTURE_REDIRECT_TO", "/")})
            if not self._authed():
                return self._send(401, {"error": "unauthorized"})
            if MODE == "tls404":
                return self._send(404, {"error": "no such route"})
            return self._send(200, {"object": "list", "data": [
                {"id": "jev-tls-fixture", "object": "model"}]})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        self._log()
        n = int(self.headers.get("Content-Length", "0") or 0)
        self.rfile.read(n)
        if self.path != "/v1/systemone":
            return self._send(404, {"error": "not found"})
        if not self._authed():
            return self._send(401, {"error": "unauthorized"})
        self._send(200, {"model": "jev-tls-fixture", "answers": {
            "gate": {"type": "choice", "choice": "deny",
                     "probabilities": {"deny": 0.97, "allow": 0.02, "ask": 0.01},
                     "confidence": 0.97},
            "risky": {"type": "noul", "noul": 0.05}}})

    def log_message(self, *a):
        pass


def main():
    srv = HTTPServer((BIND, int(sys.argv[1])), H)
    if MODE != "plain":
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(sys.argv[4], sys.argv[5])
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    with open(sys.argv[2] + ".pid", "w") as fh:
        fh.write(str(os.getpid()))
    with open(sys.argv[2], "w") as fh:
        fh.write(str(srv.server_address[1]))
    srv.serve_forever()


if __name__ == "__main__":
    main()
