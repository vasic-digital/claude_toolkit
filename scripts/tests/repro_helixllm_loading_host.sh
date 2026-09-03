#!/usr/bin/env bash
# repro_helixllm_loading_host.sh — the data-loss reproduction for the
# "gateway up, backend still loading" state.
#
# WHAT THIS SHOWS. `helixllm-export --apply` retires a provider whenever its
# host "answered". But a HelixLLM whose gateway is up while its llama.cpp
# backend is still loading a model answers:
#
#     200 {"object":"list","data":[],"reason":"a model-serving backend is
#          configured but is currently serving no models"}
#
# because /health returns 503 while loading (internal/brain/llamacpp.go),
# Brain.Models() drops unavailable options (internal/brain/brain.go), and the
# gateway therefore serves an empty listing (internal/gateway/openai.go).
#
# That is INDISTINGUISHABLE, to a gate that only asks "did it reply?", from a
# host that genuinely withdrew every model — so the sweep deletes the user's
# whole configuration for that host. Run this in the first ~30 seconds after a
# HelixLLM restart and your aliases are gone.
#
# POLARITY. No flag: the script simply reports what it observes.
#   * Against the pre-fix script it prints "LOST" and exits 1 — the defect.
#   * Against the fixed script it prints "KEPT" and exits 0 — the guard.
# Re-run it any time; it is self-contained and uses a throwaway $HOME.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
source "$SCRIPTS_DIR/lib.sh"
set +e

PROVIDERS_SH="$SCRIPTS_DIR/claude-providers.sh"
PDIR="$HOME/.local/share/claude-multi-account/providers"
mkdir -p "$PDIR"; echo '{}' > "$PDIR/models.dev.cache.json"

KEYS="$HOME/api_keys.sh"
printf 'export HELIXLLM_GATEWAY_KEY="dummy-gateway-key-never-real"\n' > "$KEYS"

# One stub gateway. It re-reads its whole response body from a file on every
# request, so the run can flip the host between "serving" and "loading".
BODY="$HOME/.body.json"
PORTF="$HOME/.port"
python3 - "$PORTF" "$BODY" >/dev/null 2>&1 <<'PY' &
import http.server, socketserver, sys, os
port_file, body_file = sys.argv[1:3]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if not self.path.rstrip('/').endswith('/models'):
            self.send_response(404); self.end_headers(); return
        payload = open(body_file, 'rb').read()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers(); self.wfile.write(payload)
    def log_message(self, *a): pass
srv = socketserver.TCPServer(('127.0.0.1', 0), H)
open(port_file, 'w').write(str(srv.server_address[1]))
srv.serve_forever()
PY
SRV=$!
trap 'kill "$SRV" 2>/dev/null; cleanup_sandbox' EXIT
for _ in $(seq 1 60); do [[ -s "$PORTF" ]] && break; sleep 0.1; done
PORT="$(cat "$PORTF")"; [[ -n "$PORT" ]] || { echo "FATAL: stub gateway did not start" >&2; exit 1; }
BASE="http://127.0.0.1:$PORT/v1"
export CMA_HELIXLLM_HOSTS="$BASE"
export CMA_HELIXLLM_HTTP_TIMEOUT=5

echo "=== repro: HelixLLM gateway up, backend still loading ==="
echo "date: $(date -u +%FT%TZ)"
echo "host: $BASE"
echo

# --- step 1: the host is serving; the user applies the configuration --------
cat > "$BODY" <<'JSON'
{"object":"list","data":[
 {"id":"helixllm-llama3-8b-a1b2c3d4e5f6","object":"model","owned_by":"helixllm",
  "model_identity":"helixllm/lab/llama3:8b","host":"lab","availability":"serving"}
]}
JSON
echo "--- step 1: host is SERVING ---"
echo "GET $BASE/models -> $(curl -s --max-time 5 "$BASE/models")"
bash "$PROVIDERS_SH" helixllm-export --apply --keys-file "$KEYS" 2>&1 | sed 's/^/    /'
PID="helixllm-llama3-8b-a1b2c3d4e5f6"
ENVF="$PDIR/$PID.env"
echo
echo "user's configuration after --apply:"
echo "    env file : $ENVF  -> $([[ -f $ENVF ]] && echo PRESENT || echo MISSING)"
# Counted on its own line, never nested inside an echo: a `grep` for the
# wrapper's NAME buried in a command substitution reads, to the suite's
# wrapper-provenance lint, like an actual CALL to it. This script only ever
# SEARCHES the alias file; it never invokes the wrapper.
_alias_n="$(grep -c "cma_run_provider $PID" "$ALIAS_FILE" 2>/dev/null; true)"
echo "    alias    : ${_alias_n:-0} entry/entries in $ALIAS_FILE"
[[ -f "$ENVF" ]] || { echo "FATAL: setup failed — no provider was written to retire."; exit 1; }

# --- step 2: HelixLLM restarts; the gateway is up, the model is loading -----
# This body is EXACTLY what internal/gateway/openai.go HandleListModels emits
# when a backend is configured but Brain.Models() is empty (llama.cpp /health
# is 503 while it loads, so the option is dropped as unavailable).
cat > "$BODY" <<'JSON'
{"object":"list","data":[],"reason":"a model-serving backend is configured but is currently serving no models"}
JSON
echo
echo "--- step 2: host RESTARTED, backend still LOADING ---"
echo "GET $BASE/models -> $(curl -s --max-time 5 "$BASE/models")"
echo "the user runs --apply again, ~10 seconds into the restart:"
bash "$PROVIDERS_SH" helixllm-export --apply --keys-file "$KEYS" 2>&1 | sed 's/^/    /'

echo
echo "--- result ---"
_env_state="$([[ -f $ENVF ]] && echo PRESENT || echo GONE)"
_alias_n="$(grep -c "cma_run_provider $PID" "$ALIAS_FILE" 2>/dev/null; true)"
_alias_n="${_alias_n:-0}"
echo "    env file : $ENVF  -> $_env_state"
echo "    alias    : $_alias_n entry/entries remain"
echo
if [[ "$_env_state" == "GONE" || "$_alias_n" == "0" ]]; then
  echo "VERDICT: LOST — the user's entire configuration for a host that is merely"
  echo "         restarting was deleted. An empty listing is not proof of withdrawal."
  exit 1
fi
echo "VERDICT: KEPT — a listing naming nothing the host serves is treated as"
echo "         'we cannot tell', exactly like an unreachable host."
exit 0
