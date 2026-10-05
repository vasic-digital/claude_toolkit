#!/usr/bin/env bash
# test_free_tier_multi_sync.sh — ATM-860 free-tier-first multi-alias sync
# (operator decision D14, 2026-07-23: "Free-tier first — verify only free
# endpoints by default; paid providers stay opt-in per sync").
#
# CONTRACT UNDER TEST
#   1. The DEFAULT `claude-providers.sh sync` runs the per-model multi-alias
#      pipeline (previously reachable only via the opt-in `sync --multi`,
#      §11.4.196(F) CONFIGURED != IN USE) and emits per-model aliases.
#   2. In the default mode the verifier fires REAL completion probes ONLY at
#      FREE-tier models. Free-vs-paid derives from REAL catalog data
#      (models.dev `cost` rows; the `:free` id convention; a self-hosted
#      loopback/private endpoint). A model whose tier is UNDERIVABLE is
#      treated as PAID (fail-safe on spend, §11.4.101(d)) — and said so.
#   3. Paid probing is an explicit opt-in: `--include-paid` (or
#      CMA_SYNC_INCLUDE_PAID=1). Never by default.
#   4. A models-list entry is NOT evidence: a model listed free whose real
#      completion fails is NEVER admitted (anti-bluff, §11.4/§11.4.1).
#   5. Alias generation is idempotent + re-runnable; naming deterministic
#      (stable tie-break) + collision-free (provider, provider2, ...).
#   6. Native-first (§11.4.196(A)) is structural: generated aliases are
#      provider-class (`cma_run_provider`, `~/.claude-prov-*`), a namespace
#      the account-class dispatcher REFUSES (see
#      test_dynamic_account_dispatch.sh: prov-* refusal) — so a generated
#      alias can never outrank or shadow an operational native account.
#
# INSTRUMENT (control-needle honest, §11.4.201(7)(b)): a REAL local HTTP
# server records EVERY completion request's model id to $REQ_LOG. "paid was
# not probed" is asserted only AFTER the needle proves the log records free
# probes through the same path.
#
# RED  (pre-fix):  default sync emits no multi artifacts; --free-only and
#                  --include-paid do not exist.
# GREEN (post-fix): all assertions pass.
# Paired §1.1 mutations (run by the evidence harness, restored after):
#   M1 strip the free-only filter        -> "paid never probed" FAILs
#   M2 admit unverified models           -> "broken model never admitted" FAILs
#   M3 unwire the default multi phase    -> "default sync emits aliases" FAILs
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# Volatile run output (D1): written to a temp file beside the final path and
# renamed into the git-ignored proof/volatile/ folder only on completion.
# shellcheck source=lib/proof.sh
source "$TESTS_DIR/lib/proof.sh"
PROOF_DIR="$(cma_proof_volatile_dir)"
PROOF_FINAL="$PROOF_DIR/96-free-tier-multi-sync.txt"
PROOF="$(cma_proof_open "$PROOF_FINAL")"

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

KEYS="$HOME/api_keys.sh"
cat > "$KEYS" <<'SH'
export STUBPROV_API_KEY="dummy-stub-key-never-real"
SH

# --- REAL local completion server, recording every probed model id ----------
PORT_FILE="$HOME/.stub_srv_port"
REQ_LOG="$HOME/.stub_srv_requests"
: > "$REQ_LOG"
python3 - "$PORT_FILE" "$REQ_LOG" >/dev/null 2>&1 <<'PY' &
import http.server, socketserver, sys, json
port_file, req_log = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        try:
            body = json.loads(self.rfile.read(n) or b'{}')
        except Exception:
            body = {}
        model = str(body.get('model') or '?')
        kind = 'tools' if body.get('tools') else ('stream' if body.get('stream') else 'chat')
        with open(req_log, 'a') as f:
            f.write('%s %s\n' % (model, kind))
        if model == 'brokenfree':
            # Listed as free in the catalog, but NON-OPERATIONAL: the real
            # completion fails. Admitting it would be the metadata-only bluff.
            self.send_response(500)
            self.end_headers()
            return
        msg = {"role": "assistant", "content": "VERIFY_OK"}
        finish = "stop"
        if body.get('tools'):
            msg["tool_calls"] = [{"id": "t1", "type": "function",
                                  "function": {"name": "test_calc",
                                               "arguments": "{\"expression\":\"7*6\"}"}}]
            finish = "tool_calls"
        out = json.dumps({"choices": [{"message": msg, "finish_reason": finish}]}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(out)))
        self.end_headers()
        self.wfile.write(out)
    def do_GET(self):
        if self.path.rstrip('/').endswith('/models'):
            out = json.dumps({"object": "list", "data": [
                {"id": m, "object": "model"} for m in
                ("freealpha", "freebeta", "freegamma", "freedelta",
                 "brokenfree", "paidx", "mysterym")]}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(out)))
            self.end_headers()
            self.wfile.write(out)
        else:
            self.send_response(404); self.end_headers()
    def log_message(self, *a):
        pass
srv = socketserver.TCPServer(('127.0.0.1', 0), H)
open(port_file, 'w').write(str(srv.server_address[1]))
srv.serve_forever()
PY
SRV_PID=$!
trap '[[ -n "${SRV_PID:-}" ]] && kill "$SRV_PID" 2>/dev/null; cleanup_sandbox' EXIT
for _ in $(seq 1 50); do [[ -s "$PORT_FILE" ]] && break; sleep 0.1; done
PORT="$(cat "$PORT_FILE" 2>/dev/null)"
[[ -n "$PORT" ]] || { echo "FATAL: mock server did not start" >&2; exit 1; }

# --- models.dev-shaped catalog fixture: free / paid / unknown / broken ------
# NOTE: the endpoint host is 127.0.0.1 — a loopback endpoint is itself a
# "free" signal (self-hosted, no billing). To make the CATALOG-COST rule the
# one under test, paid/unknown tiers must still be excluded even though the
# endpoint is local: the classifier's catalog verdict must OUTRANK locality.
cat > "$PCACHE" <<JSON
{
  "stubprov": {
    "id": "stubprov", "name": "Stub Provider",
    "env": ["STUBPROV_API_KEY"],
    "api": "http://127.0.0.1:$PORT/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "freealpha":  {"id": "freealpha",  "tool_call": true, "cost": {"input": 0,   "output": 0}, "limit": {"context": 128000, "output": 8192}},
      "freebeta":   {"id": "freebeta",   "tool_call": true, "cost": {"input": 0,   "output": 0}, "limit": {"context": 128000, "output": 8192}},
      "freegamma":  {"id": "freegamma",  "tool_call": true, "cost": {"input": 0,   "output": 0}, "limit": {"context": 32000,  "output": 4096}},
      "freedelta":  {"id": "freedelta",  "tool_call": true, "cost": {"input": 0,   "output": 0}, "limit": {"context": 32000,  "output": 4096}},
      "brokenfree": {"id": "brokenfree", "tool_call": true, "cost": {"input": 0,   "output": 0}, "limit": {"context": 64000,  "output": 8192}},
      "paidx":      {"id": "paidx",      "tool_call": true, "cost": {"input": 1.5, "output": 2}, "limit": {"context": 200000, "output": 16384}},
      "mysterym":   {"id": "mysterym",   "tool_call": true, "limit": {"context": 200000, "output": 16384}}
    }
  }
}
JSON

run_sync() {  # run_sync [extra args...] — offline (catalog pre-seeded), real multi probes
  bash "$PROVIDERS_SH" sync --offline --no-verify --keys-file "$KEYS" "$@"
}

{
  echo "=== test_free_tier_multi_sync.sh evidence ==="
  echo "date: $(date -u +%FT%TZ)"
  echo "server port: $PORT pid: $SRV_PID"
} >> "$PROOF" 2>&1

# ===========================================================================
# CASE 1 — DEFAULT sync wires the multi pipeline (free-only) out of the box.
# ===========================================================================
it "default sync runs the per-model multi phase and emits multi-alias artifacts"
run_sync >>"$PROOF" 2>&1
assert_eq 0 $? "default sync exits cleanly"
assert_file "$PDIR/stubprov_verified.json" "per-model verification output produced by DEFAULT sync"
assert_file "$PDIR/stubprov_manifest.json" "multi-alias manifest produced by DEFAULT sync"

it "control needle: the recorder really records completion probes (free models hit)"
grep -q '^freealpha ' "$REQ_LOG"
assert_eq 0 $? "freealpha was probed with a REAL completion (needle: instrument sees probes)"
grep -q '^freealpha tools$' "$REQ_LOG"
assert_eq 0 $? "the probe includes the tool-call round-trip (not a bare models-list read)"

it "free-only default: paid and unknown-tier models are NEVER probed"
grep -q '^paidx ' "$REQ_LOG"
assert_eq 1 $? "paidx (catalog cost > 0) received ZERO completion requests"
grep -q '^mysterym ' "$REQ_LOG"
assert_eq 1 $? "mysterym (no cost data => underivable => treated as PAID) received ZERO requests"

it "skips are honest: verified.json says free_only and names the skipped tiers"
assert_eq "true" "$(jq -r '.free_only' "$PDIR/stubprov_verified.json")" "free_only flag recorded"
assert_eq "paid" "$(jq -r '.skipped_models[] | select(.model_id=="paidx") | .credit_tier' "$PDIR/stubprov_verified.json")" \
  "paidx skipped with tier=paid"
assert_eq "unknown" "$(jq -r '.skipped_models[] | select(.model_id=="mysterym") | .credit_tier' "$PDIR/stubprov_verified.json")" \
  "mysterym skipped with tier=unknown (treated as paid, said so)"

# ===========================================================================
# CASE 2 — anti-bluff: a listed-free but NON-OPERATIONAL model is not admitted.
# ===========================================================================
it "a models-list entry is not evidence: brokenfree (real completion fails) never admitted"
grep -q '^brokenfree ' "$REQ_LOG"
assert_eq 0 $? "brokenfree WAS probed (free tier => probe allowed)"
assert_eq "false" "$(jq -r '.models[] | select(.model_id=="brokenfree") | .verified' "$PDIR/stubprov_verified.json")" \
  "brokenfree recorded verified=false"
assert_eq "" "$(jq -r '.aliases[] | select(.strong_model=="brokenfree" or .fast_model=="brokenfree") | .alias_name' "$PDIR/stubprov_manifest.json")" \
  "brokenfree appears in NO generated alias"

# ===========================================================================
# CASE 3 — deterministic, collision-free naming + per-model aliases emitted.
# ===========================================================================
it "per-model aliases: provider, provider2 — deterministic strong/fast pairing"
assert_eq 2 "$(jq -r '.alias_count' "$PDIR/stubprov_manifest.json")" "4 verified free models => 2 paired aliases"
assert_eq "stubprov"  "$(jq -r '.aliases[0].alias_name' "$PDIR/stubprov_manifest.json")" "primary alias name"
assert_eq "stubprov2" "$(jq -r '.aliases[1].alias_name' "$PDIR/stubprov_manifest.json")" "second alias name (collision-free suffix)"
assert_eq "freealpha" "$(jq -r '.aliases[0].strong_model' "$PDIR/stubprov_manifest.json")" \
  "equal-score tie broken deterministically by model id (freealpha before freebeta)"
assert_eq "freebeta" "$(jq -r '.aliases[0].fast_model' "$PDIR/stubprov_manifest.json")" "fast = next-ranked model"
assert_file "$PDIR/stubprov.env"  "primary alias env file"
assert_file "$PDIR/stubprov2.env" "second alias env file"

# ===========================================================================
# CASE 4 — idempotency: a second default sync is byte-identical (env files).
# ===========================================================================
it "idempotent + re-runnable: second sync leaves byte-identical alias env files"
sum1="$(cat "$PDIR"/stubprov*.env | sha256sum | cut -d' ' -f1)"
aliases1="$(jq -r '.aliases[].alias_name' "$PDIR/stubprov_manifest.json" | paste -sd,)"
run_sync >>"$PROOF" 2>&1
assert_eq 0 $? "second sync exits cleanly"
sum2="$(cat "$PDIR"/stubprov*.env | sha256sum | cut -d' ' -f1)"
aliases2="$(jq -r '.aliases[].alias_name' "$PDIR/stubprov_manifest.json" | paste -sd,)"
assert_eq "$sum1" "$sum2" "env files byte-identical across runs"
assert_eq "$aliases1" "$aliases2" "alias set + order identical across runs"

# ===========================================================================
# CASE 5 — paid probing is opt-in ONLY (--include-paid / CMA_SYNC_INCLUDE_PAID).
# ===========================================================================
it "opt-in: --include-paid probes paid + unknown tiers too"
: > "$REQ_LOG"
run_sync --include-paid >>"$PROOF" 2>&1
assert_eq 0 $? "sync --include-paid exits cleanly"
grep -q '^paidx ' "$REQ_LOG"
assert_eq 0 $? "paidx probed under the explicit opt-in"
grep -q '^mysterym ' "$REQ_LOG"
assert_eq 0 $? "mysterym probed under the explicit opt-in"

# ===========================================================================
# CASE 6 — native-first is structural: provider class, never account class.
# ===========================================================================
it "generated aliases are provider-class: cma_run_provider + ~/.claude-prov-* namespace"
bad_dir="$(jq -r '.aliases[].config_dir' "$PDIR/stubprov_manifest.json" | grep -vc "/.claude-prov-")"
assert_eq 0 "$bad_dir" "every generated config_dir is in the .claude-prov-* namespace (disjoint from account dirs)"
grep -q 'alias stubprov="cma_run_provider stubprov"' "$ALIAS_FILE"
assert_eq 0 $? "generated alias invokes cma_run_provider (provider class — the account dispatcher refuses prov-*, see test_dynamic_account_dispatch.sh)"

echo >> "$PROOF"
echo "=== result: pass=$TESTS_PASSED fail=$TESTS_FAILED ===" >> "$PROOF"

cma_proof_commit "$PROOF" "$PROOF_FINAL"
summary
