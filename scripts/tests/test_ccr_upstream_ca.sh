#!/usr/bin/env bash
# test_ccr_upstream_ca.sh — a self-signed https upstream must be trusted at
# LAUNCH, not only at verify time.
#
# Field failure (2026-09-04, helixllm-anton-qwen2-5-coder-3b alias): the
# verification probe honors CMA_PROVIDER_CA_CERT (providers-verify.sh builds a
# curl config with `cacert = ...`), so the alias earned `verified` — but the
# LAUNCH path wires no CA at all. The Go ccr router's outbound client
# (internal/proxy/upstream_proxy.go: a bare &http.Transport{}) verifies the
# upstream against the SYSTEM pool only, so the first real request died with
#   502 upstream request failed: tls: failed to verify certificate:
#   x509: certificate signed by unknown authority
# A `verified` alias that cannot serve a single turn is exactly the
# verify-green/launch-broken gap this suite exists to close.
#
# Fix under test (this EXECUTES the real generated wrapper against stub ccr /
# stub claude — it does not grep the source):
#   1. ROUTER transport: when the provider env file carries
#      CMA_PROVIDER_CA_CERT and the base URL is https, the wrapper builds a
#      COMBINED bundle (system roots + the extra CA — Go's SSL_CERT_FILE
#      REPLACES the pool, so the narrow bundle would break every other TLS
#      dial the router makes) and passes SSL_CERT_FILE to every ccr
#      invocation that (re)spawns or uses the gateway: the route-applying
#      `restart` AND the `default-claude-code` launch.
#   2. NATIVE transport: the wrapper exports NODE_EXTRA_CA_CERTS (Node APPENDS
#      to the system roots, so the raw CA path is enough) before launching
#      claude against the https upstream.
#   3. NEGATIVE CONTROLS: with no CMA_PROVIDER_CA_CERT neither knob is set —
#      a provider without a self-signed upstream must not have its TLS trust
#      narrowed to an empty bundle.
#
# Honest scope boundary (code-review 2026-09-04, finding 6): this suite is
# STUB-BASED — it proves the wrapper passes SSL_CERT_FILE / NODE_EXTRA_CA_CERTS
# to the child processes, not that Go's crypto/tls or Node's trust store accept
# the bundle. That end-to-end leg is covered LIVE instead: the
# helixllm-anton-qwen2-5-coder-3b alias was relaunched against the real
# self-signed https://127.0.0.1:8443 router after this fix and returned the
# sentinel on turn one (evidence: helix_code repo,
# scratch/discovery/live_resume_tests_evidence.md, 2026-09-04). A future
# hermetic live-TLS case (boot a real self-signed https upstream in the
# sandbox) would close the remaining gap without the live dependency.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e

# A stand-in CA/cert PEM with a unique marker the bundle assertions grep for.
# (Never a real key — the content only needs to be a distinct byte string.)
CA_PEM="$SANDBOX_HOME/upstream-ca.pem"
cat > "$CA_PEM" <<'PEM'
-----BEGIN CERTIFICATE-----
CMA-TEST-UPSTREAM-CA-MARKER-7f3a9c
-----END CERTIFICATE-----
PEM

pdir="$(cma_providers_dir)"; mkdir -p "$pdir"
mkdir -p "$SANDBOX_HOME/.claude-code-router"
printf '{}\n' > "$SANDBOX_HOME/.claude-code-router/config.json"

# ROUTER provider whose upstream is https + self-signed: the CA path is
# persisted in its env file exactly the way `helixllm-export --apply` does.
cma_provider_write_env testrtr TESTKEY router "https://127.0.0.1:9/v1" testmodel testmodel \
  "$SANDBOX_HOME/.claude-prov-testrtr" 200000 8192 testrtr
printf 'CMA_PROVIDER_CA_CERT=%s\n' "'$CA_PEM'" >> "$pdir/testrtr.env"
cma_status_write testrtr verified testmodel ""

# NATIVE provider, same https+self-signed shape.
cma_provider_write_env testnat TESTKEY native "https://127.0.0.1:9/v1" testmodel testmodel \
  "$SANDBOX_HOME/.claude-prov-testnat" 200000 8192 testnat
printf 'CMA_PROVIDER_CA_CERT=%s\n' "'$CA_PEM'" >> "$pdir/testnat.env"
cma_status_write testnat verified testmodel ""

# NEGATIVE CONTROLS: same shapes, no CA cert persisted.
cma_provider_write_env testrtrno TESTKEY router "https://127.0.0.1:9/v1" testmodel testmodel \
  "$SANDBOX_HOME/.claude-prov-testrtrno" 200000 8192 testrtrno
cma_status_write testrtrno verified testmodel ""
cma_provider_write_env testnatno TESTKEY native "https://127.0.0.1:9/v1" testmodel testmodel \
  "$SANDBOX_HOME/.claude-prov-testnatno" 200000 8192 testnatno
cma_status_write testnatno verified testmodel ""

export TESTKEY="dummy-key-present"

ALIAS_FILE="$SANDBOX_HOME/.local/share/claude-multi-account/aliases.sh"
mkdir -p "$(dirname "$ALIAS_FILE")" "$SANDBOX_HOME/.local/bin"
CMA_RC_FILES=("$SANDBOX_HOME/.unused-rc")
cma_ensure_alias_file >/dev/null 2>&1

# --- stubs ---
# ccr: records the SSL_CERT_FILE it was invoked with, per subcommand.
ccrenv="$SANDBOX_HOME/ccr.envlog"
sandbox_stub "$SANDBOX_HOME/.local/bin/ccr" <<STUB
#!/usr/bin/env bash
printf '%s SSL_CERT_FILE=[%s]\n' "\$1" "\${SSL_CERT_FILE:-}" >> "$ccrenv"
case "\$1" in
  --help) printf 'Usage:\n  ccr start\n  ccr serve\n  ccr restart\n'; exit 0 ;;
  *) exit 0 ;;
esac
STUB
# claude (native transport target): records NODE_EXTRA_CA_CERTS.
claudeenv="$SANDBOX_HOME/claude.envlog"
sandbox_stub "$SANDBOX_HOME/.local/bin/claude-stub" <<STUB
#!/usr/bin/env bash
printf 'NODE_EXTRA_CA_CERTS=[%s]\n' "\${NODE_EXTRA_CA_CERTS:-}" >> "$claudeenv"
exit 0
STUB
sandbox_stub "$SANDBOX_HOME/.local/bin/claude-sync-state" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
sandbox_stub "$SANDBOX_HOME/.local/bin/claude-session" <<'STUB'
#!/usr/bin/env bash
[ "$1" = flags ] && echo ""
exit 0
STUB
export PATH="$SANDBOX_HOME/.local/bin:$PATH"

# shellcheck source=/dev/null
source "$ALIAS_FILE"
it "HYGIENE: cma_run_provider under test comes from the sandbox alias file"
assert_fn_from cma_run_provider "$ALIAS_FILE" "wrapper loaded from the sandbox, not the host"
export CLAUDE_BIN="$SANDBOX_HOME/.local/bin/claude-stub"

# ── ROUTER + CA ──
: > "$ccrenv"
outR="$( set +eu; cma_run_provider testrtr -p hi 2>&1 )"; rcR=$?

it "router+CA: the launch is not refused"
[ "$rcR" -eq 0 ]; assert_eq 0 $? "cma_run_provider testrtr exited 0 (rc=$rcR)${outR:+ — out: $(head -c 200 <<<"$outR")}"

it "router+CA: ccr restart receives SSL_CERT_FILE"
rst_line="$(grep '^restart ' "$ccrenv" | tail -1)"
case "$rst_line" in
  *"SSL_CERT_FILE=[]"*) assert_eq 1 0 "restart saw an EMPTY SSL_CERT_FILE: $rst_line" ;;
  *"SSL_CERT_FILE=["*"]"*) assert_eq 0 0 "restart saw SSL_CERT_FILE set" ;;
  *) assert_eq 1 0 "no restart line with SSL_CERT_FILE recorded (log: $(cat "$ccrenv"))" ;;
esac

it "router+CA: the ccr launch receives SSL_CERT_FILE"
launch_line="$(grep '^default-claude-code ' "$ccrenv" | tail -1)"
case "$launch_line" in
  *"SSL_CERT_FILE=[]"*) assert_eq 1 0 "default-claude-code saw an EMPTY SSL_CERT_FILE: $launch_line" ;;
  *"SSL_CERT_FILE=["*"]"*) assert_eq 0 0 "default-claude-code saw SSL_CERT_FILE set" ;;
  *) assert_eq 1 0 "no default-claude-code line recorded (log: $(cat "$ccrenv"))" ;;
esac

it "router+CA: the bundle lives under the per-alias CCR_HOME and contains the upstream CA"
bundle="$SANDBOX_HOME/.claude-code-router/testrtr/ca-bundle.pem"
assert_file "$bundle" "combined CA bundle written under the per-alias CCR_HOME"
_mode="$(stat -c %a "$bundle" 2>/dev/null || stat -f %Lp "$bundle" 2>/dev/null)"
assert_eq "600" "$_mode" "CA bundle is chmod 600 (private upstream CA)"
grep -q 'CMA-TEST-UPSTREAM-CA-MARKER-7f3a9c' "$bundle"
assert_eq 0 $? "the bundle contains the upstream CA cert"

it "router+CA: the bundle is COMBINED (system roots preserved when a system bundle exists)"
_sys=""
for _c in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
  [ -r "$_c" ] && { _sys="$_c"; break; }
done
if [ -n "$_sys" ]; then
  _sys_lines="$(grep -c 'BEGIN CERTIFICATE' "$_sys")"
  _bnd_lines="$(grep -c 'BEGIN CERTIFICATE' "$bundle")"
  [ "$_bnd_lines" -gt "$_sys_lines" ]
  assert_eq 0 $? "bundle holds system roots ($_sys: $_sys_lines certs) PLUS the upstream CA ($_bnd_lines total)"
else
  assert_eq 0 0 "no readable system bundle on this host — combined-bundle assertion not applicable"
fi

# ── ROUTER negative control ──
: > "$ccrenv"
cma_run_provider testrtrno -p hi >/dev/null 2>&1
it "router WITHOUT CA: SSL_CERT_FILE stays unset (trust is not narrowed)"
noCA_lines="$(grep -cE 'SSL_CERT_FILE=\[\]' "$ccrenv")"
all_lines="$(wc -l < "$ccrenv")"
[ "$all_lines" -gt 0 ] && [ "$noCA_lines" -eq "$all_lines" ]
assert_eq 0 $? "every ccr invocation saw an empty SSL_CERT_FILE ($noCA_lines/$all_lines)"

# ── NATIVE + CA ──
: > "$claudeenv"
outN="$( set +eu; cma_run_provider testnat -p hi 2>&1 )"; rcN=$?
it "native+CA: the launch is not refused"
[ "$rcN" -eq 0 ]; assert_eq 0 $? "cma_run_provider testnat exited 0 (rc=$rcN)${outN:+ — out: $(head -c 200 <<<"$outN")}"
it "native+CA: claude is launched with NODE_EXTRA_CA_CERTS pointing at the CA PEM"
grep -q "NODE_EXTRA_CA_CERTS=\[$CA_PEM\]" "$claudeenv"
assert_eq 0 $? "claude child saw NODE_EXTRA_CA_CERTS=$CA_PEM (log: $(cat "$claudeenv"))"

# ── NATIVE negative control ──
: > "$claudeenv"
cma_run_provider testnatno -p hi >/dev/null 2>&1
it "native WITHOUT CA: NODE_EXTRA_CA_CERTS stays unset"
grep -q 'NODE_EXTRA_CA_CERTS=\[\]' "$claudeenv"
assert_eq 0 $? "claude child saw an empty NODE_EXTRA_CA_CERTS (log: $(cat "$claudeenv"))"

summary
