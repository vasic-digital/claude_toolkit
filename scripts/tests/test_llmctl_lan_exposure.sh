#!/usr/bin/env bash
# test_llmctl_lan_exposure.sh — RED-first test for FR-009 (LAN-exposure
# warning for llmctl-backed aliases).
#
# llmctl binds every profile to 0.0.0.0 (LAN-reachable) by default
# (research.md §3.C — llmctl's own lib/common.sh:74,
# `LLMCTL_BIND_HOST="${LLMCTL_BIND_HOST:-0.0.0.0}"`), with no authentication
# on its OpenAI-compatible API. llmctl exposes NO bind-address field in
# `plan --json` (confirmed by the upstream audit in research.md §3.A — the
# schema carries mode/ram_mb/vram_mb/ctx/port/engine/capability/etc., never a
# bind-host), so `detect_llmctl_records` (scripts/claude-providers.sh) has no
# way to learn a profile's real bind address from llmctl's own API at all.
#
# The only reliable signal is reading the REAL kernel listening-socket bind
# address for the profile's resolved port directly — `ss -ltn`. Confirmed
# empirically on this host: `ss -ltn "sport = :<port>"` prints a `Local
# Address:Port` column of `0.0.0.0:<port>` for a wildcard bind and
# `127.0.0.1:<port>` for a loopback-only bind.
#
# This test is RED-first (TDD): it asserts a `lan_exposed` field
# `detect_llmctl_records` does NOT emit yet (confirmed absent — a prior audit
# grepped the whole function for "0.0.0.0"/"bind"/"LAN" and found zero hits).
# The "exposed" case below is EXPECTED TO FAIL until T012 implements the
# real-socket-read + field. The "local" case passes trivially today (field
# absence reads as not-exposed) and exists as the negative control so a
# future implementation that sets lan_exposed=true unconditionally would be
# caught.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
PROOF_DIR="$TESTS_DIR/proof"
mkdir -p "$PROOF_DIR"
PROOF="$PROOF_DIR/test_llmctl_lan_exposure.txt"
: > "$PROOF"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e   # lib.sh sets -e; the harness asserts on failures, so relax it.

PROVIDERS_SH="$SCRIPTS_DIR/claude-providers.sh"
PDIR="$HOME/.local/share/claude-multi-account/providers"
PCACHE="$PDIR/models.dev.cache.json"
mkdir -p "$PDIR"

export CMA_LLMCTL_PINS_FILE="$HOME/.no-llmctl-pins-$$.json"
[[ -e "$CMA_LLMCTL_PINS_FILE" ]] && rm -f "$CMA_LLMCTL_PINS_FILE"
echo '{}' > "$PCACHE"

# --- REAL local /v1/models servers, one on each bind address -----------------
start_mock() {  # $1 = bind host  $2 = model id  $3 = n_ctx  $4 = port-file path
  python3 - "$1" "$4" "$2" "$3" >/dev/null 2>&1 <<'PY' &
import http.server, socketserver, sys, json
bind_host, port_file, model_id, n_ctx = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.rstrip('/').endswith('/models'):
            body = json.dumps({"object": "list", "data": [
                {"id": model_id, "object": "model", "meta": {"n_ctx": n_ctx}}
            ]}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()
    def log_message(self, *a):
        pass
srv = socketserver.TCPServer((bind_host, 0), H)
open(port_file, 'w').write(str(srv.server_address[1]))
srv.serve_forever()
PY
  echo $!
}
wait_port_file() {  # $1 = path
  for _ in $(seq 1 50); do [[ -s "$1" ]] && break; sleep 0.1; done
  cat "$1" 2>/dev/null
}

EXPOSED_PORT_FILE="$HOME/.llmctl_exposed_port"
EXPOSED_PID="$(start_mock "0.0.0.0" "lan-model" 131072 "$EXPOSED_PORT_FILE")"
LOCAL_PORT_FILE="$HOME/.llmctl_local_port"
LOCAL_PID="$(start_mock "127.0.0.1" "local-model" 131072 "$LOCAL_PORT_FILE")"

reap_mocks() {
  for p in "${EXPOSED_PID:-}" "${LOCAL_PID:-}"; do
    [[ -n "$p" ]] && kill "$p" 2>/dev/null
  done
  cleanup_sandbox
}
trap reap_mocks EXIT

EXPOSED_PORT="$(wait_port_file "$EXPOSED_PORT_FILE")"
LOCAL_PORT="$(wait_port_file "$LOCAL_PORT_FILE")"

{
  echo "=== test_llmctl_lan_exposure.sh evidence ==="
  echo "date: $(date -u +%FT%TZ)"
  echo "exposed (0.0.0.0) mock port=$EXPOSED_PORT pid=$EXPOSED_PID"
  echo "local (127.0.0.1) mock port=$LOCAL_PORT pid=$LOCAL_PID"
  echo "--- ss -ltn for exposed port (sanity check on this host) ---"
  ss -ltn "sport = :$EXPOSED_PORT" 2>&1
  echo "--- ss -ltn for local port (sanity check on this host) ---"
  ss -ltn "sport = :$LOCAL_PORT" 2>&1
} >> "$PROOF" 2>&1

# --- fake llmctl binary on PATH -----------------------------------------------
sandbox_stub "$HOME/.local/bin/llmctl" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "plan" && "\${2:-}" == "--json" ]]; then
  cat <<'JSON'
{
  "profiles": {
    "exposed": {"port": $EXPOSED_PORT, "ctx": 131072, "fits": true, "engine": "llama"},
    "local":   {"port": $LOCAL_PORT,   "ctx": 131072, "fits": true, "engine": "llama"}
  }
}
JSON
  exit 0
fi
echo "llmctl (test stub): unhandled args: \$*" >&2
exit 2
EOF
chmod +x "$HOME/.local/bin/llmctl"
export PATH="$HOME/.local/bin:$PATH"

DET="$(CMA_LLMCTL_BIN=llmctl \
    bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_llmctl_records')"
echo "--- detect_llmctl_records output ---" >> "$PROOF"
echo "$DET" >> "$PROOF"

EXPOSED_REC="$(jq -c '[.[] | select(.provider_id=="llmctl-exposed")] | .[0]' <<<"$DET")"
LOCAL_REC="$(jq -c '[.[] | select(.provider_id=="llmctl-local")] | .[0]' <<<"$DET")"

it "CASE EXPOSED (RED — expected to fail until T012 lands): a profile bound to 0.0.0.0 is flagged lan_exposed=true"
EXPOSED_FLAG="$(jq -r '.lan_exposed // false' <<<"$EXPOSED_REC")"
assert_eq "true" "$EXPOSED_FLAG" "llmctl-exposed carries lan_exposed=true (real bind address read via ss, not from llmctl's JSON — no such field exists there per research.md §3.A)"

it "CASE LOCAL (negative control — passes today by field absence, must keep passing after T012 lands): a profile bound to 127.0.0.1 is NOT flagged lan_exposed"
LOCAL_FLAG="$(jq -r '.lan_exposed // false' <<<"$LOCAL_REC")"
assert_eq "false" "$LOCAL_FLAG" "llmctl-local does not carry lan_exposed=true"

summary
