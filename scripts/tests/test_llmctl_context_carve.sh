#!/usr/bin/env bash
# test_llmctl_context_carve.sh — RED-first reproduction of the captured
# production defect in detect_llmctl_records (claude-providers.sh): a
# profile whose REAL, correctly-detected context (meta.n_ctx) is too small
# for a CLI agent's own baseline overhead is exported with NO warning at
# all, exactly as it was when `llmctl-small`'s real context of 8192 tokens
# broke a live Kimi Code turn needing 92,436 tokens — see
# scripts/tests/proof/kimi-llmctl-integration-evidence.txt and
# specs/001-llmctl-integration-hardening/research.md §2.
#
# This file is INTENTIONALLY RED at the time it is written: task T007 is
# test-only (TDD discipline). The fix (an explicit `context_warning` field
# on the resolved record when the real n_ctx is below the floor this
# codebase already uses for a CLI agent's minimum usable window —
# CMA_INPUT_FLOOR default 160000 + an 8192 minimum output = 168192, see
# scripts/lib.sh's _cma_out_guard carve around line 1585) is implemented
# separately under task T011 and is NOT part of this file's scope.
#
# Cases:
#   TINY  — a profile whose live /v1/models reports meta.n_ctx=8192 (below
#           the 168192 floor) MUST carry an explicit context_warning field
#           naming the shortfall. Currently FAILS (no such field exists).
#   LARGE — a profile whose live /v1/models reports meta.n_ctx=131072+36864
#           worth of margin above the floor (well above it) MUST carry NO
#           warning field — the negative control proving this assertion is
#           not vacuously true regardless of input.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
PROOF_DIR="$TESTS_DIR/proof"
mkdir -p "$PROOF_DIR"
PROOF="$PROOF_DIR/test_llmctl_context_carve.txt"
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
KEYS="$HOME/api_keys.sh"
: > "$KEYS"

# --- REAL local /v1/models servers (ephemeral ports) ------------------------
start_mock() {  # $1 = model id  $2 = n_ctx  $3 = port-file path
  python3 - "$3" "$1" "$2" >/dev/null 2>&1 <<'PY' &
import http.server, socketserver, sys, json
port_file, model_id, n_ctx = sys.argv[1], sys.argv[2], int(sys.argv[3])
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
srv = socketserver.TCPServer(('127.0.0.1', 0), H)
open(port_file, 'w').write(str(srv.server_address[1]))
srv.serve_forever()
PY
  echo $!
}
wait_port_file() {  # $1 = path
  for _ in $(seq 1 50); do [[ -s "$1" ]] && break; sleep 0.1; done
  cat "$1" 2>/dev/null
}

TINY_PORT_FILE="$HOME/.llmctl_tiny_port"
TINY_PID="$(start_mock "qwen2.5-coder-0.5b-instruct-q4_k_m" 8192 "$TINY_PORT_FILE")"
LARGE_PORT_FILE="$HOME/.llmctl_large_port"
LARGE_PID="$(start_mock "qwen2.5-coder-32b-instruct-q4_k_m" 196608 "$LARGE_PORT_FILE")"

reap_mocks() {
  for p in "${TINY_PID:-}" "${LARGE_PID:-}"; do
    [[ -n "$p" ]] && kill "$p" 2>/dev/null
  done
  cleanup_sandbox
}
trap reap_mocks EXIT

TINY_PORT="$(wait_port_file "$TINY_PORT_FILE")"
LARGE_PORT="$(wait_port_file "$LARGE_PORT_FILE")"

{
  echo "=== test_llmctl_context_carve.sh evidence ==="
  echo "date: $(date -u +%FT%TZ)"
  echo "tiny mock (n_ctx=8192) port=$TINY_PORT pid=$TINY_PID"
  echo "large mock (n_ctx=196608) port=$LARGE_PORT pid=$LARGE_PID"
} >> "$PROOF" 2>&1

write_llmctl_stub() {
  mkdir -p "$HOME/.local/bin"
  sandbox_stub "$HOME/.local/bin/llmctl" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "plan" && "\${2:-}" == "--json" ]]; then
  cat <<'JSON'
{
  "profiles": {
    "tiny":  {"port": $TINY_PORT,  "ctx": 8192,   "fits": true, "engine": "llama"},
    "large": {"port": $LARGE_PORT, "ctx": 196608, "fits": true, "engine": "llama"}
  }
}
JSON
  exit 0
fi
echo "llmctl (test stub): unhandled args: \$*" >&2
exit 2
EOF
  chmod +x "$HOME/.local/bin/llmctl"
}
write_llmctl_stub
export PATH="$HOME/.local/bin:$PATH"

DET="$(CMA_LLMCTL_BIN=llmctl \
    bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_llmctl_records')"
echo "--- detect_llmctl_records output ---" >> "$PROOF"
echo "$DET" >> "$PROOF"

TINY_REC="$(jq -c '[.[] | select(.provider_id=="llmctl-tiny")] | .[0]' <<<"$DET")"
LARGE_REC="$(jq -c '[.[] | select(.provider_id=="llmctl-large")] | .[0]' <<<"$DET")"

# ===========================================================================
# CASE TINY — real n_ctx (8192) is far below the 168192 CLI-agent-overhead
# floor (CMA_INPUT_FLOOR 160000 + 8192 minimum output, scripts/lib.sh
# ~line 1585). detect_llmctl_records MUST attach an explicit warning field
# so the shortfall is surfaced to the operator, never silently exported as
# if 8192 were a workable ceiling. THIS IS THE DEFECT THIS TEST PROVES.
# ===========================================================================
it "CASE TINY: real n_ctx=8192 is below the 168192 floor -> context_warning MUST be set (currently FAILS — the defect)"
assert_eq "8192" "$(jq -r '.context_limit' <<<"$TINY_REC")" "context_limit reflects the real (small) n_ctx"
_tiny_warning="$(jq -r '.context_warning // "ABSENT"' <<<"$TINY_REC")"
echo "tiny record context_warning field: $_tiny_warning" >> "$PROOF"
assert_eq 0 "$([[ "$_tiny_warning" != "ABSENT" && -n "$_tiny_warning" ]]; echo $?)" \
  "detect_llmctl_records must set a non-empty context_warning naming the real n_ctx (8192) and the 168192 floor it cannot clear — field is currently ABSENT, reproducing the unguarded production failure"

# ===========================================================================
# CASE LARGE — negative control: a profile whose real n_ctx (196608) is
# comfortably above the floor must carry NO warning field at all, proving
# the assertion above is testing something real rather than always failing.
# ===========================================================================
it "CASE LARGE: real n_ctx=196608 clears the floor -> no context_warning (negative control)"
assert_eq "196608" "$(jq -r '.context_limit' <<<"$LARGE_REC")" "context_limit reflects the real (large) n_ctx"
_large_warning="$(jq -r '.context_warning // "ABSENT"' <<<"$LARGE_REC")"
echo "large record context_warning field: $_large_warning" >> "$PROOF"
assert_eq "ABSENT" "$_large_warning" "a comfortably-sized real context carries no warning field (negative control)"

summary
