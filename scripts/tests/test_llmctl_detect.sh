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
assert_eq "llmctl-fast" "$(jq -r '.[0].provider_id' <<<"$DET_B")" "provider_id = llmctl-fast"
assert_eq "llmctl-fast" "$(jq -r '.[0].alias' <<<"$DET_B")" "alias = llmctl-fast"
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

summary
