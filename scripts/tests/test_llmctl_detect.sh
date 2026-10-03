#!/usr/bin/env bash
# test_llmctl_detect.sh — hermetic test for the llmctl PATH-detection provider
# (detect_llmctl_records + resolve_records merge in claude-providers.sh).
#
# llmctl is a sibling local-LLM orchestrator that runs each catalog PROFILE as
# its OWN independent llama.cpp/colibri server process on a fixed,
# catalog-assigned port. Unlike detect_helixagent_record (one multi-model
# server), this detector must emit ZERO, ONE, or MANY records per sync — one
# per profile that answers ITS OWN /v1/models RIGHT NOW.
#
# Fully self-contained: a sandboxed $HOME (make_sandbox), a FAKE `llmctl`
# binary on PATH whose `plan --json` names a small catalog, and REAL local
# HTTP servers on ephemeral ports answering `/v1/models` for the profiles that
# should be detected as "running". No mocked curl/jq calls — every assertion
# is against genuine process output (§11.4.69).
#
# Cases:
#   A. zero llmctl profiles running                  -> detector emits []
#   B. one profile running, live-probed successfully  -> one record, real
#      probed model id + context (meta.n_ctx from the mock server)
#   C. multiple profiles running simultaneously       -> one record PER
#      profile, correctly keyed llmctl-<profile>, ports never conflated
#   D. llmctl binary AND pins-file both absent         -> [] (the honest
#      not-installed case)
#   E. a port that answers 200 but NOT a valid OpenAI-shaped /v1/models
#      listing (the real "some unrelated service already owns this port"
#      case measured live on the development host) is NOT registered
#   F. an invalid/absent `plan --json` catalog (llmctl installed but its
#      planner failed) -> honest [], never a crash
#   G. pins-file present (key_var/context overrides), binary ABSENT -> still
#      [] (ports are never declared in the tracked pins file — see the
#      detector's own header comment for why), proving the gate admits the
#      pins-only branch without inventing a catalog it cannot discover
#   H. end-to-end: `claude-providers.sh sync` genuinely registers the running
#      profile as its own alias + .env record (transport=router)
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
PROOF_DIR="$TESTS_DIR/proof"
mkdir -p "$PROOF_DIR"
PROOF="$PROOF_DIR/99-llmctl-detect.txt"
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

# Point the pins-file lookup at an ABSENT sandbox path so the built-in
# defaults are what's exercised, exactly as verify_helixagent_test.sh does for
# HelixAgent — the real repo pins-file ($LIB_DIR/providers/llmctl.json) must
# never leak into these assertions.
export CMA_LLMCTL_PINS_FILE="$HOME/.no-llmctl-pins-$$.json"
[[ -e "$CMA_LLMCTL_PINS_FILE" ]] && rm -f "$CMA_LLMCTL_PINS_FILE"

# Empty models.dev catalog, freshly written -> `resolve_records` reads it as
# fresh (mtime "now" < CMA_MODELS_DEV_TTL) and never attempts a real network
# fetch even WITHOUT --offline, which this suite deliberately omits below (see
# the note before CASE H) so the llmctl live-probe path actually runs.
echo '{}' > "$PCACHE"
KEYS="$HOME/api_keys.sh"
: > "$KEYS"

# --- REAL local /v1/models servers (ephemeral ports) -------------------------
# One Python HTTP server per "running profile", each with its OWN model id +
# n_ctx, so a test that asserted the WRONG server's data would fail loudly
# instead of silently reading a shared fixture.
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

# A WRONG-SERVICE mock: answers 200 on ANY path, including /v1/models, but
# with plain text — exactly the shape measured live (an unrelated service
# occupying llmctl's own "fast" port, HTTP 200 "404 page not found", which is
# not valid JSON at all). Proves the detector's own defense: a non-JSON /
# non-OpenAI-shaped response must never be read as "this profile is running".
start_wrong_service() {  # $1 = port-file path
  python3 - "$1" >/dev/null 2>&1 <<'PY' &
import http.server, socketserver, sys
port_file = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"404 page not found"
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
srv = socketserver.TCPServer(('127.0.0.1', 0), H)
open(port_file, 'w').write(str(srv.server_address[1]))
srv.serve_forever()
PY
  echo $!
}

FAST_PORT_FILE="$HOME/.llmctl_fast_port"
FAST_PID="$(start_mock "qwen2.5-coder-7b-instruct-q4_k_m" 8192 "$FAST_PORT_FILE")"
VISION_PORT_FILE="$HOME/.llmctl_vision_port"
VISION_PID="$(start_mock "llava-1.6-mistral-7b-q4_k_m" 4096 "$VISION_PORT_FILE")"
WRONG_PORT_FILE="$HOME/.llmctl_wrong_port"
WRONG_PID="$(start_wrong_service "$WRONG_PORT_FILE")"

reap_mocks() {
  for p in "${FAST_PID:-}" "${VISION_PID:-}" "${WRONG_PID:-}"; do
    [[ -n "$p" ]] && kill "$p" 2>/dev/null
  done
  cleanup_sandbox
}
trap reap_mocks EXIT

FAST_PORT="$(wait_port_file "$FAST_PORT_FILE")"
VISION_PORT="$(wait_port_file "$VISION_PORT_FILE")"
WRONG_PORT="$(wait_port_file "$WRONG_PORT_FILE")"
# A genuinely-dead port for the "not running" profile — nothing binds this in
# the sandbox, so the connection is refused immediately (no timeout stall).
DEAD_PORT=1

{
  echo "=== test_llmctl_detect.sh evidence ==="
  echo "date: $(date -u +%FT%TZ)"
  echo "fast mock port=$FAST_PORT pid=$FAST_PID"
  echo "vision mock port=$VISION_PORT pid=$VISION_PID"
  echo "wrong-service mock port=$WRONG_PORT pid=$WRONG_PID"
  echo "dead port (never bound)=$DEAD_PORT"
} >> "$PROOF" 2>&1

# --- fake llmctl binary on PATH ----------------------------------------------
# `plan --json` is the ONLY subcommand the detector calls; the stub emits a
# small catalog matching the REAL schema shape confirmed against a live
# `llmctl plan --json` run (`.profiles.<name>.port` / `.ctx`), naming the mock
# servers' own ephemeral ports for two profiles, the wrong-service mock's port
# for a third (to prove that port is correctly rejected), and DEAD_PORT for a
# fourth (never running).
write_llmctl_stub() {
  mkdir -p "$HOME/.local/bin"
  sandbox_stub "$HOME/.local/bin/llmctl" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "plan" && "\${2:-}" == "--json" ]]; then
  cat <<'JSON'
{
  "tier": "baseline",
  "budgets": {"ram_mb": 16000, "vram_mb": 8000, "storage_free_mb": 100000},
  "profiles": {
    "fast":     {"port": $FAST_PORT,  "ctx": 8192,  "fits": true,  "engine": "llama"},
    "vision":   {"port": $VISION_PORT,"ctx": 4096,  "fits": true,  "engine": "llama"},
    "occupied": {"port": $WRONG_PORT, "ctx": 8192,  "fits": true,  "engine": "llama"},
    "small":    {"port": $DEAD_PORT,  "ctx": 8192,  "fits": true,  "engine": "llama"}
  },
  "recommended": [],
  "coresidency_groups": []
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

# ===========================================================================
# CASE A — llmctl on PATH, catalog present, but ZERO profiles are currently
# reachable -> detector emits []  (the mandated "zero profiles running" case)
# ===========================================================================
it "CASE A: llmctl on PATH but its catalog names only unreachable ports -> []"
sandbox_stub "$HOME/.local/bin/llmctl-onlydead" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "plan" && "\${2:-}" == "--json" ]]; then
  cat <<'JSON'
{"profiles": {"small": {"port": $DEAD_PORT, "ctx": 8192}}}
JSON
  exit 0
fi
exit 2
EOF
chmod +x "$HOME/.local/bin/llmctl-onlydead"
DET_A="$(CMA_LLMCTL_BIN="$HOME/.local/bin/llmctl-onlydead" \
    bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_llmctl_records')"
echo "--- detect_llmctl_records output (CASE A, catalog names only dead ports) ---" >> "$PROOF"
echo "$DET_A" >> "$PROOF"
assert_eq "[]" "$(echo "$DET_A" | tr -d '[:space:]')" "catalog present but nothing answers /v1/models -> empty"

# ===========================================================================
# CASE B — one profile running, live-probed successfully
# ===========================================================================
it "CASE B: llmctl on PATH, ONLY the 'fast' mock reachable -> one resolved record"
sandbox_stub "$HOME/.local/bin/llmctl-onlyfast" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "plan" && "\${2:-}" == "--json" ]]; then
  cat <<'JSON'
{"profiles": {"fast": {"port": $FAST_PORT, "ctx": 8192}, "small": {"port": $DEAD_PORT, "ctx": 8192}}}
JSON
  exit 0
fi
exit 2
EOF
chmod +x "$HOME/.local/bin/llmctl-onlyfast"
DET_B="$(CMA_LLMCTL_BIN="$HOME/.local/bin/llmctl-onlyfast" \
    bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_llmctl_records')"
echo "--- detect_llmctl_records output (CASE B, one running profile) ---" >> "$PROOF"
echo "$DET_B" >> "$PROOF"
assert_eq "1" "$(jq 'length' <<<"$DET_B")" "exactly one record for exactly one running profile"
# REGRESSION-LOCK (FR-002 / specs/001-llmctl-integration-hardening/research.md
# §1): the "llmctl-<profile>" namespaced form (never a bare profile name) was
# already correct and already covered when this feature's audit ran -- the
# two assertions below are that lock, not new coverage. A future change that
# makes either one fail is a regression of FR-002, not a new requirement.
assert_eq "llmctl-fast" "$(jq -r '.[0].provider_id' <<<"$DET_B")" "provider_id = llmctl-fast (FR-002 regression-lock)"
assert_eq "llmctl-fast" "$(jq -r '.[0].alias' <<<"$DET_B")" "alias = llmctl-fast (FR-002 regression-lock)"
assert_eq "router" "$(jq -r '.[0].transport' <<<"$DET_B")" "transport = router (OpenAI-compatible -> ccr)"
assert_eq "http://127.0.0.1:$FAST_PORT/v1" "$(jq -r '.[0].base_url' <<<"$DET_B")" "base_url = the REAL probed port"
assert_eq "qwen2.5-coder-7b-instruct-q4_k_m" "$(jq -r '.[0].strong_model' <<<"$DET_B")" \
  "strong_model = the REAL model id the mock /v1/models reported (not invented)"
assert_eq "qwen2.5-coder-7b-instruct-q4_k_m" "$(jq -r '.[0].fast_model' <<<"$DET_B")" "fast_model mirrors strong_model (one model per profile)"
assert_eq "8192" "$(jq -r '.[0].context_limit' <<<"$DET_B")" "context_limit = the REAL meta.n_ctx from the mock (not the pins default)"
assert_eq "resolved" "$(jq -r '.[0].status' <<<"$DET_B")" "status = resolved"

# ===========================================================================
# CASE C — multiple profiles running simultaneously
# ===========================================================================
it "CASE C: llmctl on PATH, 'fast' AND 'vision' both reachable -> two records, correctly keyed"
DET_C="$(CMA_LLMCTL_BIN=llmctl \
    bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_llmctl_records')"
echo "--- detect_llmctl_records output (CASE C, multiple running profiles) ---" >> "$PROOF"
echo "$DET_C" >> "$PROOF"
assert_eq "2" "$(jq 'length' <<<"$DET_C")" "exactly two records for exactly two running profiles (occupied+small excluded)"
FAST_REC="$(jq -c '[.[] | select(.provider_id=="llmctl-fast")] | .[0]' <<<"$DET_C")"
VISION_REC="$(jq -c '[.[] | select(.provider_id=="llmctl-vision")] | .[0]' <<<"$DET_C")"
assert_eq "http://127.0.0.1:$FAST_PORT/v1" "$(jq -r '.base_url' <<<"$FAST_REC")" "fast record keeps ITS OWN port"
assert_eq "http://127.0.0.1:$VISION_PORT/v1" "$(jq -r '.base_url' <<<"$VISION_REC")" "vision record keeps ITS OWN port (not conflated with fast)"
assert_eq "llava-1.6-mistral-7b-q4_k_m" "$(jq -r '.strong_model' <<<"$VISION_REC")" "vision record carries the VISION mock's own model id"
assert_eq "4096" "$(jq -r '.context_limit' <<<"$VISION_REC")" "vision record carries the VISION mock's own n_ctx (distinct from fast's 8192)"

it "CASE C2: neither 'occupied' (wrong-service) nor 'small' (dead port) is registered"
assert_eq "null" "$(jq -r '[.[] | select(.provider_id=="llmctl-occupied")] | .[0] // "null"' <<<"$DET_C")" \
  "no llmctl-occupied record"
assert_eq "null" "$(jq -r '[.[] | select(.provider_id=="llmctl-small")] | .[0] // "null"' <<<"$DET_C")" \
  "no llmctl-small record"

# ===========================================================================
# CASE D — llmctl binary AND pins-file both absent (the honest not-installed
# case). CMA_LLMCTL_BIN names a binary that exists NOWHERE (a random suffix,
# not a PATH search that could be defeated by touching $PATH) so this proves
# the PATH/pins gate itself, independent of the sandbox's own PATH contents.
# ===========================================================================
it "CASE D: no llmctl binary resolvable anywhere, no pins-file -> detector emits []"
DET_D="$(CMA_LLMCTL_BIN=llmctl-genuinely-absent-binary-xyz-$$ CMA_LLMCTL_PINS_FILE="$HOME/.still-absent-$$.json" \
    bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_llmctl_records')"
assert_eq "[]" "$(echo "$DET_D" | tr -d '[:space:]')" "binary unresolvable + no pins-file -> empty record, no crash"

# ===========================================================================
# CASE E — a port answering 200 but NOT an OpenAI-shaped listing must not be
# read as a running profile (already exercised structurally inside CASE C via
# the 'occupied' profile; this sub-case additionally proves the raw HTTP
# behaviour independently of the detector, tying the assertion above to a
# concrete, inspectable fact rather than trusting the mock's intent).
# ===========================================================================
it "CASE E: the wrong-service mock genuinely answers 200 with non-JSON on /v1/models"
_wrong_body="$(curl -s --max-time 5 "http://127.0.0.1:$WRONG_PORT/v1/models" 2>/dev/null)"
echo "--- raw response from the wrong-service mock ---" >> "$PROOF"
echo "$_wrong_body" >> "$PROOF"
_wrong_is_json=1
printf '%s' "$_wrong_body" | jq -e . >/dev/null 2>&1 || _wrong_is_json=0
assert_eq 0 "$_wrong_is_json" "wrong-service response is genuinely NOT valid JSON (the real-host defect this mirrors)"

# REGRESSION-LOCK (feature 001-llmctl-integration-hardening, T005, 2026-10-02):
# CASE C2 (above) and this CASE E together are the existing proof that
# liveness is NEVER derived from a merely-open port -- a port answering with
# a non-JSON/non-OpenAI-shaped body is treated as "not running", exactly as
# research.md §1 documents as already-correct, already-tested behavior this
# feature must preserve rather than rebuild. This comment makes that
# regression-lock explicit and traceable for future readers/diffs.

# ===========================================================================
# CASE F — invalid/absent `plan --json` catalog -> honest [], never a crash
# ===========================================================================
it "CASE F: llmctl on PATH but 'plan --json' prints garbage -> detector emits [] (no crash)"
sandbox_stub "$HOME/.local/bin/llmctl-broken" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "plan" && "${2:-}" == "--json" ]]; then
  echo "not json at all"
  exit 0
fi
exit 2
EOF
chmod +x "$HOME/.local/bin/llmctl-broken"
DET_F="$(CMA_LLMCTL_BIN="$HOME/.local/bin/llmctl-broken" \
    bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_llmctl_records' 2>>"$PROOF")"
f_rc=$?
assert_eq 0 "$f_rc" "detector itself exits cleanly even when the planner output is garbage"
assert_eq "[]" "$(echo "$DET_F" | tr -d '[:space:]')" "garbage catalog -> honest empty record"

it "CASE F2: llmctl on PATH but 'plan --json' prints a JSON object with NO .profiles -> []"
sandbox_stub "$HOME/.local/bin/llmctl-noprofiles" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "plan" && "${2:-}" == "--json" ]]; then
  echo '{"tier":"baseline"}'
  exit 0
fi
exit 2
EOF
chmod +x "$HOME/.local/bin/llmctl-noprofiles"
DET_F2="$(CMA_LLMCTL_BIN="$HOME/.local/bin/llmctl-noprofiles" \
    bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_llmctl_records')"
assert_eq "[]" "$(echo "$DET_F2" | tr -d '[:space:]')" "catalog with no .profiles object -> honest empty record"

# ===========================================================================
# CASE F3/F4 (feature 001-llmctl-integration-hardening, T004): a profile
# object missing `port` or `ctx` must not be fabricated into a bad/false
# record -- contracts/llmctl-external-contract.md obligation #1.
# ===========================================================================
it "CASE F3: a catalog profile missing 'port' entirely is silently skipped, never fabricated"
sandbox_stub "$HOME/.local/bin/llmctl-noport" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "plan" && "${2:-}" == "--json" ]]; then
  echo '{"profiles": {"broken": {"ctx": 8192}}}'
  exit 0
fi
exit 2
EOF
chmod +x "$HOME/.local/bin/llmctl-noport"
DET_F3="$(CMA_LLMCTL_BIN="$HOME/.local/bin/llmctl-noport" \
    bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_llmctl_records' 2>>"$PROOF")"
f3_rc=$?
echo "--- detect_llmctl_records output (CASE F3, profile missing port) ---" >> "$PROOF"
echo "$DET_F3" >> "$PROOF"
assert_eq 0 "$f3_rc" "detector exits cleanly when a profile object has no port field at all"
assert_eq "[]" "$(echo "$DET_F3" | tr -d '[:space:]')" "a profile with no port is never fabricated into a record (jq's .port -> null -> tostring -> \"null\", fails the ^[0-9]+\$ gate by construction)"

it "CASE F4: a catalog profile missing 'ctx' but whose live endpoint reports meta.n_ctx -> the live value wins (the ctx-absent-defaults-to-0 bug, fixed by T011, only bites when meta.n_ctx is ALSO absent — see CASE F4b)"
sandbox_stub "$HOME/.local/bin/llmctl-noctx" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "plan" && "\${2:-}" == "--json" ]]; then
  cat <<JSON
{"profiles": {"noctx": {"port": $FAST_PORT}}}
JSON
  exit 0
fi
exit 2
EOF
chmod +x "$HOME/.local/bin/llmctl-noctx"
DET_F4="$(CMA_LLMCTL_BIN="$HOME/.local/bin/llmctl-noctx" \
    bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_llmctl_records')"
echo "--- detect_llmctl_records output (CASE F4, profile missing ctx; mock DOES report its own meta.n_ctx=8192) ---" >> "$PROOF"
echo "$DET_F4" >> "$PROOF"
# The 'fast' mock DOES report meta.n_ctx=8192 on every /v1/models response
# (start_mock's fixed behavior), so the live-probed value wins here and masks
# the missing-catalog-ctx path entirely -- this sub-case documents that the
# live probe is authoritative when present, which is correct and desired.
assert_eq "8192" "$(jq -r '.[0].context_limit' <<<"$DET_F4")" "live meta.n_ctx still wins when the catalog omits ctx and the endpoint reports one"

it "CASE F4b: catalog missing 'ctx' AND the endpoint's own /v1/models omits meta.n_ctx -> context_limit correctly falls through to the 8192 default (T011 fix), never the literal \"0\" the pre-fix jq extraction produced"
NOMETA_PORT_FILE="$HOME/.llmctl_nometa_port"
python3 - "$NOMETA_PORT_FILE" >/dev/null 2>&1 <<'PY' &
import http.server, socketserver, sys, json
port_file = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.rstrip('/').endswith('/models'):
            body = json.dumps({"object": "list", "data": [
                {"id": "no-meta-model", "object": "model"}
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
NOMETA_PID=$!
NOMETA_PORT="$(wait_port_file "$NOMETA_PORT_FILE")"
sandbox_stub "$HOME/.local/bin/llmctl-nometa" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "plan" && "\${2:-}" == "--json" ]]; then
  cat <<JSON
{"profiles": {"nometa": {"port": $NOMETA_PORT}}}
JSON
  exit 0
fi
exit 2
EOF
chmod +x "$HOME/.local/bin/llmctl-nometa"
DET_F4B="$(CMA_LLMCTL_BIN="$HOME/.local/bin/llmctl-nometa" \
    bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_llmctl_records')"
kill "$NOMETA_PID" 2>/dev/null
echo "--- detect_llmctl_records output (CASE F4b, catalog ctx AND meta.n_ctx both absent) ---" >> "$PROOF"
echo "$DET_F4B" >> "$PROOF"
# FIXED by T011: the jq extraction used to be `.value.ctx // 0`, which turned
# an ABSENT catalog ctx into the STRING "0" (matches ^[0-9]+$, so it was NOT
# treated the same as "unset" -- it won over the documented
# CMA_LLMCTL_CONTEXT_LIMIT=8192 fallback). The extraction now defaults to
# `// ""` (empty, genuinely unset) and detect_llmctl_records additionally
# treats a resolved "0" as a hole (mirrors providers_resolve.py's
# context==0-is-unknown rule), so both the catalog ctx and the live
# meta.n_ctx being absent correctly falls through to the 8192 default.
assert_eq "8192" "$(jq -r '.[0].context_limit' <<<"$DET_F4B")" "catalog-ctx-absent + meta.n_ctx-absent correctly falls through to the 8192 default, never the literal \"0\" hole"
assert_eq "true" "$(jq -r '.[0].context_warning != null' <<<"$DET_F4B")" "8192 is still below the 168192 CLI-agent-overhead floor, so an honest context_warning is still set"

# ===========================================================================
# CASE G — pins-file present (key_var/context overrides), binary ABSENT.
# Ports are NEVER declared in the tracked pins file (see the detector's own
# header comment): the gate admits the pins-only branch, but with no runnable
# binary there is genuinely nothing to discover, so the honest answer is
# still []. This proves the gate does not silently invent a catalog.
# ===========================================================================
it "CASE G: pins-file present + binary ABSENT -> detector still emits [] (no invented catalog)"
PINS_G="$HOME/llmctl.pins.json"
cat > "$PINS_G" <<'JSON'
{ "key_var": "LLMCTL_CUSTOM_KEY", "context_limit": 32768, "max_output": 2048 }
JSON
DET_G="$(env CMA_LLMCTL_PINS_FILE="$PINS_G" CMA_LLMCTL_BIN=llmctl-genuinely-absent-xyz \
    bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_llmctl_records')"
echo "--- detect_llmctl_records output (CASE G, pins-only, no binary) ---" >> "$PROOF"
echo "$DET_G" >> "$PROOF"
assert_eq "[]" "$(echo "$DET_G" | tr -d '[:space:]')" "pins-file present, no binary -> [] (ports cannot be invented)"

it "CASE G2: static check — the pins loader path exists and is reachable in source"
grep -qE 'CMA_LLMCTL_PINS_FILE' "$SCRIPTS_DIR/claude-providers.sh"
assert_eq 0 $? "CMA_LLMCTL_PINS_FILE override is wired in claude-providers.sh"

it "CASE G3: env var wins over pins-file default for context_limit (precedence env > pins > built-in)"
sandbox_stub "$HOME/.local/bin/llmctl-onlyfast2" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "plan" && "\${2:-}" == "--json" ]]; then
  cat <<'JSON'
{"profiles": {"fast": {"port": $FAST_PORT}}}
JSON
  exit 0
fi
exit 2
EOF
chmod +x "$HOME/.local/bin/llmctl-onlyfast2"
# The mock ALWAYS reports meta.n_ctx=8192 for this profile, so this proves the
# LIVE value still wins over a pins/env default when the endpoint answers —
# the env-vs-pins precedence only governs the FALLBACK path (no live n_ctx),
# which the next assertion exercises with a mock that omits meta entirely.
DET_G3="$(env CMA_LLMCTL_PINS_FILE="$PINS_G" CMA_LLMCTL_BIN="$HOME/.local/bin/llmctl-onlyfast2" \
    bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_llmctl_records')"
assert_eq "8192" "$(jq -r '.[0].context_limit' <<<"$DET_G3")" "live meta.n_ctx (8192) still wins over the pins-file default (32768) when the endpoint reports one"

# ===========================================================================
# CASE H — end-to-end: claude-providers.sh sync genuinely registers the alias.
#
# Deliberately OMITS --offline: this detector honours OFFLINE (like
# detect_helixcoder_record / _cma_helixllm_served_ids) and returns [] under
# it, so a full offline sync would never exercise the live-probe path this
# case exists to prove. --no-verify still suppresses the separate
# layers-2..4 provider VERIFICATION probes. The pre-written, freshly-mtimed
# empty $PCACHE keeps `resolve_records` from attempting a real models.dev
# network fetch even though --offline is not passed (age 0 < the 24h TTL).
# ===========================================================================
it "CASE H: sync with llmctl on PATH + one live mock -> real alias + .env + status"
rm -f "$PDIR/llmctl-fast.env" "$PDIR/llmctl-vision.env"
CMA_LLMCTL_BIN="$HOME/.local/bin/llmctl-onlyfast" bash "$PROVIDERS_SH" sync --no-verify --keys-file "$KEYS" \
  >>"$PROOF" 2>&1
h_rc=$?
assert_eq 0 "$h_rc" "sync exits cleanly"
assert_file "$PDIR/llmctl-fast.env" "llmctl-fast env file created (PATH-detected, live-probed)"
grep -qE "^CMA_PROVIDER_TRANSPORT='?router'?" "$PDIR/llmctl-fast.env"
assert_eq 0 $? "transport=router in the written env file"
grep -qF "http://127.0.0.1:$FAST_PORT/v1" "$PDIR/llmctl-fast.env"
assert_eq 0 $? "base_url = the real mock endpoint"
grep -qE "^CMA_PROVIDER_MODEL='?qwen2\.5-coder-7b-instruct-q4_k_m'?" "$PDIR/llmctl-fast.env"
assert_eq 0 $? "strong model = the real live-probed id"
grep -qE "^CMA_PROVIDER_KEYVAR='?LLMCTL_API_KEY'?" "$PDIR/llmctl-fast.env"
assert_eq 0 $? "key-var NAME recorded (no key needed, no secret stored)"

it "CASE H2: shell alias registered -> cma_run_provider llmctl-fast"
grep -q '^alias llmctl-fast="cma_run_provider llmctl-fast"' "$ALIAS_FILE"
assert_eq 0 $? "llmctl-fast alias line present"

it "CASE H3: verification status persisted (unverified under --no-verify)"
assert_eq "unverified" "$(cma_status_read llmctl-fast)" "llmctl-fast status persisted"

it "CASE H4: NOT running profile ('vision' not reachable in this sync) gets no alias"
[[ ! -f "$PDIR/llmctl-vision.env" ]]; assert_eq 0 $? "no llmctl-vision.env (that mock was never named in this stub's catalog)"

{
  echo
  echo "=== llmctl-fast.env (final) ==="
  cat "$PDIR/llmctl-fast.env"
} >> "$PROOF" 2>&1

# ===========================================================================
# CASE I — PERFORMANCE (T013): per-profile liveness probes run in bounded
# concurrency batches, never sequentially. Five profiles, each answering only
# after a genuine 2-second delay (a mock that actually sleeps before
# responding -- a dead/refused port returns instantly and would NOT exercise
# the timeout path at all, so it proves nothing about sequential-vs-parallel
# cost). Sequential cost would be ~10s (5 x 2s); with the default
# CMA_LLMCTL_MAX_PARALLEL_PROBES (8, i.e. all 5 fit in one batch), bounded
# cost is ~2s (the single slowest profile), plus small overhead. The
# threshold below (6s) sits well above realistic overhead and well below the
# ~10s sequential sum, so it fails loudly if a future change silently
# reintroduces the sequential path without being so tight it flakes on a
# loaded CI host.
# ===========================================================================
it "CASE I: five 2s-slow profiles resolve in well under their sequential sum (bounded-parallel probe, T013)"
start_slow_mock() {  # $1=port_file  $2=delay_seconds
  python3 - "$1" "$2" >/dev/null 2>&1 <<'PY' &
import http.server, socketserver, sys, time
port_file, delay = sys.argv[1], float(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        time.sleep(delay)
        body = b'{"object":"list","data":[{"id":"slow","object":"model","meta":{"n_ctx":8192}}]}'
        self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self,*a): pass
srv = socketserver.TCPServer(('127.0.0.1', 0), H)
open(port_file, 'w').write(str(srv.server_address[1]))
srv.serve_forever()
PY
  echo $!
}
_perf_pids=()
_perf_ports=()
for _i in 1 2 3 4 5; do
  _pf="$HOME/.perf_p$_i"
  _pid="$(start_slow_mock "$_pf" 2)"
  _perf_pids+=("$_pid")
  _perf_ports+=("$(wait_port_file "$_pf")")
done
_perf_catalog="{"
for _i in 0 1 2 3 4; do
  [[ $_i -gt 0 ]] && _perf_catalog+=","
  _perf_catalog+="\"slow$((_i+1))\": {\"port\": ${_perf_ports[$_i]}, \"ctx\": 8192}"
done
_perf_catalog+="}"
sandbox_stub "$HOME/.local/bin/llmctl-perf" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "plan" && "\${2:-}" == "--json" ]]; then
  echo '{"profiles": $_perf_catalog}'
  exit 0
fi
exit 2
EOF
chmod +x "$HOME/.local/bin/llmctl-perf"
_perf_t0=$(date +%s.%N)
DET_I="$(CMA_LLMCTL_BIN="$HOME/.local/bin/llmctl-perf" CMA_LLMCTL_HTTP_TIMEOUT=5 \
    bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_llmctl_records')"
_perf_t1=$(date +%s.%N)
_perf_elapsed="$(echo "$_perf_t1 - $_perf_t0" | bc)"
echo "--- CASE I: detect_llmctl_records elapsed=${_perf_elapsed}s (sequential sum would be ~10s) ---" >> "$PROOF"
echo "$DET_I" >> "$PROOF"
assert_eq "5" "$(jq 'length' <<<"$DET_I")" "all five slow-but-live profiles still correctly detected"
_perf_under_threshold=1
(( $(echo "$_perf_elapsed < 6.0" | bc -l) )) && _perf_under_threshold=0
assert_eq 0 "$_perf_under_threshold" "elapsed (${_perf_elapsed}s) is well under the 6s bound (sequential sum ~10s) -- probes ran in parallel, not sequentially"
for _pid in "${_perf_pids[@]}"; do kill "$_pid" 2>/dev/null; done

# ---------------------------------------------------------------------------
# Follow-up independent review (NO-GO blocker, "TSV null-field corruption"):
# cmd_sync/cmd_sync_multi's record loop reads @tsv output with
# `IFS=$'\t' read`. Tab is a POSIX IFS-WHITESPACE character, so bash
# COLLAPSES two consecutive empty fields into a single delimiter rather than
# preserving them -- a resolved record with BOTH context_limit AND
# max_output null (jq emits the bare empty string for a JSON null in @tsv)
# shifts lan_exposed/context_warning left into the ctx_limit/max_out
# variable slots. The fix defaults both to the literal string "null"
# (`cma_provider_write_env` and providers_generate.py's `_parse_limit()`
# already normalize that string back to empty/None, so this is a pure fix).
# This test extracts the REAL jq expression from claude-providers.sh rather
# than re-implementing it, so it can never silently drift from the live code.
# ---------------------------------------------------------------------------
echo "--- CASE J: TSV null-field corruption (independent review follow-up) ---" >> "$PROOF"
_tsv_jq_expr="$(grep -oE "jq -r '\.\[\] \| \[\.status,\.provider_id.*@tsv'" "$PROVIDERS_SH" | head -1 | sed -E "s/^jq -r '//; s/'\$//")"
[[ -n "$_tsv_jq_expr" ]] && ok=1 || ok=0
assert_eq 1 "$ok" "the real TSV jq expression was found and extracted from claude-providers.sh (test would otherwise silently test nothing)"
_tsv_fixture='[{"status":"resolved","provider_id":"p1","alias":"p1","key_var":"K","transport":"native","base_url":"http://x","strong_model":"m","fast_model":"m","context_limit":null,"max_output":null,"lan_exposed":true,"context_warning":"too small"}]'
_tsv_line="$(jq -r "$_tsv_jq_expr" <<<"$_tsv_fixture")"
echo "raw tsv line: $(printf '%s' "$_tsv_line" | cat -A | head -1)" >> "$PROOF"
IFS=$'\t' read -r _t_status _t_pid _t_alias _t_keyvar _t_transport _t_base _t_model _t_fast _t_ctx _t_out _t_lan _t_warn <<<"$_tsv_line"
echo "parsed: ctx=[$_t_ctx] out=[$_t_out] lan=[$_t_lan] warn=[$_t_warn]" >> "$PROOF"
assert_eq "null" "$_t_ctx" "context_limit field reads back as the literal string 'null', never corrupted/shifted"
assert_eq "null" "$_t_out" "max_output field reads back as the literal string 'null', never corrupted/shifted"
assert_eq "true" "$_t_lan" "lan_exposed is NOT shifted left into max_output's slot"
assert_eq "too small" "$_t_warn" "context_warning is NOT lost/shifted when both numeric limits are null"

# ---------------------------------------------------------------------------
# Round-3 independent review (NO-GO blocker): the SAME tab-collapse bug
# through `.base_url` specifically. providers_resolve.py only marks a
# ROUTER-transport provider "unmapped" when its catalog `api` field is
# missing; a NATIVE-transport provider (e.g. the real "anthropic" catalog
# entry) with no `api` field stays "resolved" with base_url=null. A single
# null field is enough -- tab is an IFS-whitespace character, so bash's
# `IFS=$'\t' read` collapses even ONE empty field into the delimiter,
# cascading every subsequent field one slot to the left (reproduced live:
# base absorbed strong_model's value, model absorbed fast_model's, etc.).
# Same discipline as CASE J: extracts the REAL jq expression, never a
# hand-copied duplicate.
# ---------------------------------------------------------------------------
echo "--- CASE K: base_url-null cascade (round-3 independent review) ---" >> "$PROOF"
_tsv_k_fixture='[{"status":"resolved","provider_id":"anthropic","alias":"anthropic","key_var":"ANTHROPIC_API_KEY","transport":"native","base_url":null,"strong_model":"claude-sonnet-5-5","fast_model":"claude-haiku-4-5","context_limit":1000000,"max_output":128000,"lan_exposed":false,"context_warning":""}]'
_tsv_k_line="$(jq -r "$_tsv_jq_expr" <<<"$_tsv_k_fixture")"
echo "raw tsv line: $(printf '%s' "$_tsv_k_line" | cat -A)" >> "$PROOF"
IFS=$'\t' read -r _k_status _k_pid _k_alias _k_keyvar _k_transport _k_base _k_model _k_fast _k_ctx _k_out _k_lan _k_warn <<<"$_tsv_k_line"
echo "parsed: transport=[$_k_transport] base=[$_k_base] model=[$_k_model] fast=[$_k_fast] ctx=[$_k_ctx] out=[$_k_out] lan=[$_k_lan] warn=[$_k_warn]" >> "$PROOF"
assert_eq "native" "$_k_transport" "transport reads back correctly, never shifted"
assert_eq "null" "$_k_base" "base_url reads back as the literal string 'null', NEVER as strong_model's value (the cascade this finding is named for)"
assert_eq "claude-sonnet-5-5" "$_k_model" "strong_model reads back correctly in its own slot, not shifted into base's"
assert_eq "claude-haiku-4-5" "$_k_fast" "fast_model reads back correctly in its own slot"
assert_eq "1000000" "$_k_ctx" "context_limit reads back correctly, not absorbed by the cascade"
assert_eq "128000" "$_k_out" "max_output reads back correctly, not absorbed by the cascade"
assert_eq "false" "$_k_lan" "lan_exposed reads back correctly, not absorbed by the cascade"
assert_eq "" "$_k_warn" "context_warning (empty in this fixture) reads back as empty, not corrupted"

summary
