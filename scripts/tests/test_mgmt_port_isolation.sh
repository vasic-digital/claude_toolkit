#!/usr/bin/env bash
# test_mgmt_port_isolation.sh — every router alias must get its OWN ccr
# management port, not just its own gateway port.
#
# Live defect (2026-07-25, captured on the sarvam alias): per-alias CCR_HOME
# isolation gave every alias its own gateway port ([3460,3959] by hash) but
# left the MANAGEMENT port at ccr's default 3458 for EVERY alias, so exactly
# one per-alias gateway could be up at a time. Every second alias's
# `ccr restart` child died with:
#   start management interface: listen on 127.0.0.1:3458: bind: address already in use
# and the launch refused with rc=78 ("route was written but never applied").
# Worse, the child binds its gateway socket BEFORE the management bind fails,
# so waitForReady could WIN the race against the dying child — a launch that
# "succeeded" against a gateway that was already exiting (heisenbug).
#
# Fix under test: the launcher derives a per-alias management port from the
# same provider-id hash in the DISJOINT [3960,4459] space (CMA_CCR_MGMT_PORT
# in the provider env pins it) and passes it to every `ccr restart` call.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e

pdir="$(cma_providers_dir)"; mkdir -p "$pdir"
mkprov() { # $1=id $2=keyvar
  cma_provider_write_env "$1" "$2" router "http://127.0.0.1:9/v1" "${1}-big" "${1}-fast" \
    "$SANDBOX_HOME/.claude-prov-$1" 200000 8192 "$1"
  cma_status_write "$1" verified "${1}-big" ""
  export "$2=dummy-key"
}
mkprov prova PROVA_KEY
mkprov provb PROVB_KEY
# Third provider with a PINNED management port.
mkprov provc PROVC_KEY
printf 'CMA_CCR_MGMT_PORT=3999\n' >> "$pdir/provc.env"

# Alias file with the real emitted cma_run_provider body.
ALIAS_FILE="$SANDBOX_HOME/.local/share/claude-multi-account/aliases.sh"
mkdir -p "$(dirname "$ALIAS_FILE")" "$SANDBOX_HOME/.local/bin"
CMA_RC_FILES=("$SANDBOX_HOME/.unused-rc")
cma_ensure_alias_file >/dev/null 2>&1

# Fake ccr with the CURRENT bundled grammar (restart in --help) that records
# the argv of every restart and launch.
CCRCALLS="$SANDBOX_HOME/ccr.calls"
sandbox_stub "$SANDBOX_HOME/.local/bin/ccr" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
  --help|-h|help)
    printf 'Usage:\n  ccr start [...]\n  ccr serve [...]\n  ccr restart [--host <host>] [--port <port>] [--gateway|--no-gateway]\n  ccr stop\n'
    exit 0 ;;
  restart)
    printf 'restart %s\n' "\$*" >> "$CCRCALLS"
    exit 0 ;;
  code|default-claude-code)
    printf 'launch %s\n' "\$*" >> "$CCRCALLS"
    exit 0 ;;
  *) exit 0 ;;
esac
STUB

# shellcheck disable=SC1090
source "$ALIAS_FILE"
# Provenance: BASH_ENV sources the HOST alias file into every non-interactive
# bash, so prove the wrapper under test came from the SANDBOX file (generated
# from THIS checkout's lib.sh), not the host's (assert.sh:assert_fn_from).
assert_fn_from cma_run_provider "$ALIAS_FILE"

it "two router aliases launch and each restart carries BOTH isolated ports"
cma_run_provider prova >/dev/null 2>&1; rc_a=$?
cma_run_provider provb >/dev/null 2>&1; rc_b=$?
assert_eq "0" "$rc_a" "prova launch rc"
assert_eq "0" "$rc_b" "provb launch rc"

gw_a="$(grep '^restart ' "$CCRCALLS" | sed -n '1s/.*--gateway-port \([0-9]*\).*/\1/p')"
mg_a="$(grep '^restart ' "$CCRCALLS" | sed -n '1s/.*--port \([0-9]*\).*/\1/p')"
gw_b="$(grep '^restart ' "$CCRCALLS" | sed -n '2s/.*--gateway-port \([0-9]*\).*/\1/p')"
mg_b="$(grep '^restart ' "$CCRCALLS" | sed -n '2s/.*--port \([0-9]*\).*/\1/p')"

in_range() { (( ${1:-0} >= $2 && ${1:-0} <= $3 )); }
if in_range "$gw_a" 3460 3959 && in_range "$gw_b" 3460 3959; then
  _pass "gateway ports in [3460,3959] ($gw_a, $gw_b)"
else
  _fail "gateway ports out of range" "gw_a=$gw_a gw_b=$gw_b"
fi
if in_range "$mg_a" 3960 4459 && in_range "$mg_b" 3960 4459; then
  _pass "management ports in [3960,4459] ($mg_a, $mg_b)"
else
  _fail "management ports out of range (the 3458 collision class)" "mg_a=$mg_a mg_b=$mg_b"
fi
[[ "$gw_a" != "$gw_b" && "$mg_a" != "$mg_b" ]] \
  && _pass "prova and provb get DIFFERENT ports (gw $gw_a/$gw_b, mgmt $mg_a/$mg_b)" \
  || _fail "port collision between aliases" "gw $gw_a/$gw_b mgmt $mg_a/$mg_b"
# The two spaces are disjoint by construction — assert the recorded values
# never cross over.
if in_range "$mg_a" 3460 3959 || in_range "$mg_b" 3460 3959; then
  _fail "management port landed in the gateway space" "mg_a=$mg_a mg_b=$mg_b"
else
  _pass "management ports never land in the gateway space"
fi

it "a CMA_CCR_MGMT_PORT pin in the provider env is honoured"
: > "$CCRCALLS"
cma_run_provider provc >/dev/null 2>&1; rc_c=$?
assert_eq "0" "$rc_c" "provc launch rc"
assert_file_contains "$CCRCALLS" "--port 3999" "pinned management port passed to ccr restart"

summary
