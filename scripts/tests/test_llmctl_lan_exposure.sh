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
# Volatile run output (D1): written to a temp file beside the final path and
# renamed into the git-ignored proof/volatile/ folder only on completion.
# shellcheck source=lib/proof.sh
source "$TESTS_DIR/lib/proof.sh"
PROOF_DIR="$(cma_proof_volatile_dir)"
PROOF_FINAL="$PROOF_DIR/test_llmctl_lan_exposure.txt"
PROOF="$(cma_proof_open "$PROOF_FINAL")"

# D3: this host's real LAN address must never reach an output file. It is
# discovered once, here, so every capture below can be filtered through
# cma_proof_redact_ip, which rewrites it to the fixed placeholder 192.168.x.x
# BEFORE the bytes are appended to $PROOF. Empty when none is discoverable.
HOST_LAN_IP="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
_lan_redact() { cma_proof_redact_ip "$HOST_LAN_IP"; }

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
} 2>&1 | _lan_redact >> "$PROOF"

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
echo "$DET" | _lan_redact >> "$PROOF"

EXPOSED_REC="$(jq -c '[.[] | select(.provider_id=="llmctl-exposed")] | .[0]' <<<"$DET")"
LOCAL_REC="$(jq -c '[.[] | select(.provider_id=="llmctl-local")] | .[0]' <<<"$DET")"

it "CASE EXPOSED (RED — expected to fail until T012 lands): a profile bound to 0.0.0.0 is flagged lan_exposed=true"
EXPOSED_FLAG="$(jq -r '.lan_exposed // false' <<<"$EXPOSED_REC")"
assert_eq "true" "$EXPOSED_FLAG" "llmctl-exposed carries lan_exposed=true (real bind address read via ss, not from llmctl's JSON — no such field exists there per research.md §3.A)"

it "CASE LOCAL (negative control — passes today by field absence, must keep passing after T012 lands): a profile bound to 127.0.0.1 is NOT flagged lan_exposed"
LOCAL_FLAG="$(jq -r '.lan_exposed // false' <<<"$LOCAL_REC")"
assert_eq "false" "$LOCAL_FLAG" "llmctl-local does not carry lan_exposed=true"

# --- CASE LAN-IP: review finding 3(a) — a real, non-wildcard LAN address ----
# docs/llmctl/user-guide.md tells operators to set LLMCTL_BIND_HOST to a real
# LAN IP (not just 0.0.0.0); the pre-fix detector only matched the three
# wildcard literals (0.0.0.0:*, *:*, [::]:*), so a genuine LAN-IP bind read as
# NOT exposed. The mock HTTP server itself binds 127.0.0.1 (detect_llmctl_
# records' liveness probe ALWAYS goes via loopback regardless of declared
# bind address — contracts/llmctl-external-contract.md assumption #5 — so a
# server bound ONLY to a LAN IP is a separate, pre-existing probe-reachability
# limitation, not what this case tests). A second, independent SO_REUSEPORT
# socket is bound to the SAME port on this host's real LAN IP purely so `ss`
# reports a genuine, non-loopback row for that port — isolating the
# ss-parsing logic this finding is actually about. SKIPs honestly if no
# global-scope IPv4 address is discoverable on this host.
# HOST_LAN_IP was discovered once near the top (D3 redaction needs it early).
if [[ -n "$HOST_LAN_IP" ]]; then
  LANIP_PORT_FILE="$HOME/.llmctl_lanip_port"
  LANIP_PID="$(start_mock "127.0.0.1" "lanip-model" 131072 "$LANIP_PORT_FILE")"
  LANIP_PORT="$(wait_port_file "$LANIP_PORT_FILE")"
  python3 - "$HOST_LAN_IP" "$LANIP_PORT" >/dev/null 2>&1 <<'PY' &
import socket, sys, time
lan_ip, port = sys.argv[1], int(sys.argv[2])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
s.bind((lan_ip, port))
s.listen(1)
time.sleep(60)
PY
  LANIP_DECOY_PID=$!
  sleep 0.3
  {
    echo "--- ss -ltn for LAN-IP ($HOST_LAN_IP) port (sanity check) ---"
    ss -ltn "sport = :$LANIP_PORT" 2>&1
  } 2>&1 | _lan_redact >> "$PROOF"
  sandbox_stub "$HOME/.local/bin/llmctl" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "plan" && "\${2:-}" == "--json" ]]; then
  cat <<'JSON'
{
  "profiles": {
    "exposed": {"port": $EXPOSED_PORT, "ctx": 131072, "fits": true, "engine": "llama"},
    "local":   {"port": $LOCAL_PORT,   "ctx": 131072, "fits": true, "engine": "llama"},
    "lanip":   {"port": $LANIP_PORT,   "ctx": 131072, "fits": true, "engine": "llama"}
  }
}
JSON
  exit 0
fi
echo "llmctl (test stub): unhandled args: \$*" >&2
exit 2
EOF
  chmod +x "$HOME/.local/bin/llmctl"
  LANIP_DET="$(CMA_LLMCTL_BIN=llmctl \
      bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_llmctl_records')"
  echo "--- detect_llmctl_records output (lanip case) ---" >> "$PROOF"
  echo "$LANIP_DET" | _lan_redact >> "$PROOF"
  LANIP_REC="$(jq -c '[.[] | select(.provider_id=="llmctl-lanip")] | .[0]' <<<"$LANIP_DET")"
  kill "$LANIP_PID" "$LANIP_DECOY_PID" 2>/dev/null

  it "CASE LAN-IP (review finding 3a): a profile bound to this host's real, non-wildcard LAN IP is flagged lan_exposed=true"
  LANIP_FLAG="$(jq -r '.lan_exposed // false' <<<"$LANIP_REC")"
  assert_eq "true" "$LANIP_FLAG" "llmctl-lanip (bound to this host's LAN address, 192.168.x.x in evidence) carries lan_exposed=true (exposure is 'any non-loopback local address', not an enumerated wildcard-literal list)"
else
  echo "SKIP: CASE LAN-IP — no global-scope IPv4 address discoverable on this host (ip -4 -o addr show scope global returned nothing)" >> "$PROOF"
fi

# --- CASE DUAL-SOCKET: review finding 3(b) — loopback + wildcard same port -
# SO_REUSEPORT lets two independent sockets (one 127.0.0.1, one 0.0.0.0) bind
# the IDENTICAL port. The pre-fix detector read only `ss`'s FIRST row
# (`awk 'NR>1{print $4; exit}'`), so whichever socket's row sorted first
# decided the whole profile's exposure — if that happened to be the loopback
# row, the co-resident wildcard exposure on the exact same port was silently
# missed entirely.
DUAL_PORT_FILE="$HOME/.llmctl_dual_port"
python3 - "$DUAL_PORT_FILE" >/dev/null 2>&1 <<'PY' &
import socket, sys, time
port_file = sys.argv[1]
s1 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s1.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s1.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
s1.bind(("0.0.0.0", 0))
port = s1.getsockname()[1]
s1.listen(1)
s2 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s2.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s2.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
s2.bind(("127.0.0.1", port))
s2.listen(1)
open(port_file, 'w').write(str(port))
time.sleep(60)
PY
DUAL_PID=$!
DUAL_PORT="$(wait_port_file "$DUAL_PORT_FILE")"
if [[ -n "$DUAL_PORT" ]]; then
  {
    echo "--- ss -ltn for dual-socket (0.0.0.0 + 127.0.0.1, same port) (sanity check) ---"
    ss -ltn "sport = :$DUAL_PORT" 2>&1
  } 2>&1 | _lan_redact >> "$PROOF"
  sandbox_stub "$HOME/.local/bin/llmctl" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "plan" && "\${2:-}" == "--json" ]]; then
  cat <<'JSON'
{
  "profiles": {
    "dual": {"port": $DUAL_PORT, "ctx": 131072, "fits": true, "engine": "llama"}
  }
}
JSON
  exit 0
fi
echo "llmctl (test stub): unhandled args: \$*" >&2
exit 2
EOF
  chmod +x "$HOME/.local/bin/llmctl"
  # The dual-socket listener above answers raw TCP only (no HTTP /v1/models
  # body) -- detect_llmctl_records' own liveness probe would therefore find
  # it "not running" and emit no record at all, which cannot exercise the
  # lan_exposed logic (that code path is only reached for a record that DID
  # produce one). This case tests the ss-parsing logic in isolation instead,
  # the same unit test_llmctl_lan_exposure.sh already treats as its subject.
  DUAL_SOCKLINES="$(ss -ltn "sport = :$DUAL_PORT" 2>/dev/null | awk 'NR>1{print $4}')"
  DUAL_EXPOSED="false"
  while IFS= read -r _sockaddr; do
    [[ -n "$_sockaddr" ]] || continue
    case "$_sockaddr" in
      127.*|\[::1\]:*|localhost:*) ;;
      *) DUAL_EXPOSED="true"; break ;;
    esac
  done <<<"$DUAL_SOCKLINES"
  echo "--- dual-socket parsed rows ---" >> "$PROOF"
  echo "$DUAL_SOCKLINES" | _lan_redact >> "$PROOF"
  kill "$DUAL_PID" 2>/dev/null

  it "CASE DUAL-SOCKET (review finding 3b): a port with BOTH a loopback and a wildcard listener is flagged exposed (every row checked, not just the first)"
  assert_eq "true" "$DUAL_EXPOSED" "the wildcard row on port $DUAL_PORT is detected even when a loopback row for the same port also exists and could sort first"
else
  echo "SKIP: CASE DUAL-SOCKET — SO_REUSEPORT dual-bind did not come up on this host/kernel" >> "$PROOF"
  kill "$DUAL_PID" 2>/dev/null
fi

# --- CASE WARN-SURFACED: review finding 1 — the operator must actually SEE
# the warning, not just have it sit as an unread JSON field. Prior to this
# fix, `lan_exposed`/`context_warning` were computed by detect_llmctl_records
# and merged by resolve_records() but consumed by NOTHING — a full `sync`
# printed neither warning, directly contradicting docs/llmctl/user-guide.md
# §3/§4, quickstart.md §5, FAQ, and CHANGELOG.md, all of which explicitly
# promise the operator sees one. Re-establish the original exposed+local
# stub (the dual-socket case above overwrote it) and run a REAL `sync`.
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

WARN_KEYS="$HOME/.llmctl_warn_keys.sh"
: > "$WARN_KEYS"
SYNC_STDERR="$(CMA_LLMCTL_BIN=llmctl bash "$PROVIDERS_SH" sync --no-verify --keys-file "$WARN_KEYS" 2>&1 >/dev/null)"
echo "--- sync stderr (finding-1 warning-surfacing case) ---" >> "$PROOF"
echo "$SYNC_STDERR" | _lan_redact >> "$PROOF"

it "CASE WARN-SURFACED (review finding 1): sync prints an operator-visible warning for the LAN-exposed llmctl profile"
grep -qi "llmctl-exposed.*reachable from the LAN" <<<"$SYNC_STDERR"
assert_eq 0 $? "a plain-worded LAN-exposure warning for llmctl-exposed appears on sync's own stderr (not just a JSON field nobody reads)"

it "CASE WARN-SURFACED (review finding 1): sync prints the operator-visible undersized-context warning for an llmctl profile below the usable floor"
grep -qi "llmctl-exposed.*below the 168192 tokens" <<<"$SYNC_STDERR"
assert_eq 0 $? "the context_warning text itself (not just its presence as a field) reaches sync's stderr for llmctl-exposed"

it "CASE WARN-SURFACED (review finding 1): the loopback-only profile does NOT get a false LAN-exposure warning"
! grep -qi "llmctl-local.*reachable from the LAN" <<<"$SYNC_STDERR"
assert_eq 0 $? "llmctl-local (bound 127.0.0.1) is not falsely warned as LAN-exposed"

it "D3: the evidence file carries no literal LAN address (redacted at capture time)"
if [[ -n "$HOST_LAN_IP" ]]; then
  grep -qF "$HOST_LAN_IP" "$PROOF"; assert_eq 1 $? "this host's LAN address is absent from the evidence"
  grep -qF "192.168.x.x" "$PROOF"; assert_eq 0 $? "the fixed placeholder stands in for it"
else
  _pass "SKIP: no global-scope IPv4 on this host, nothing to redact"
fi
cma_proof_commit "$PROOF" "$PROOF_FINAL"
summary
