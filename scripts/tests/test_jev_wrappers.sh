#!/usr/bin/env bash
# test_jev_wrappers.sh — launch-wiring test for the Jev decision layer:
# the managed alias file's emitted wrappers (cma_run, cma_run_provider,
# cma_run_kimi, cma_run_kimi_provider, cma_run_pi, cma_run_pi_provider) export
# JEV_* + TYPESAFE_* from the ranked jev-endpoints.json cache (zero network),
# print the one-line MOTD, honor CMA_JEV_DISABLE, and degrade to INACTIVE +
# detached background refresh (launch <1s) when the cache is missing.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e
# These suites drive plain-http loopback fixtures; since v1.32.0 plain http is an
# explicit opt-in (TLS is the default). test_jev_detect_https.sh covers the default.
export CMA_JEV_ALLOW_HTTP=1

PDIR="$HOME/.local/share/claude-multi-account/providers"
mkdir -p "$PDIR" "$HOME/.claude-prov-testprov" "$HOME/.kimi-prov-testprov" "$HOME/.pi-prov-testprov"

# Mock agent binaries that dump their environment.
for b in claude kimi pi; do
  sandbox_stub "$HOME/.local/bin/$b" <<'EOF'
#!/usr/bin/env bash
env > "$JEV_TEST_DUMP"
EOF
done
export PATH="$HOME/.local/bin:$PATH"

# Ranked endpoint cache + keys file (cache holds the key var NAME only).
cat > "$PDIR/jev-endpoints.json" <<'EOF'
{"endpoints":[{"provider_id":"jev-local","base_url":"http://127.0.0.1:8095","key_var":"TEST_JEV_KEY","model":"jev-fixture-1","priority":10,"probed_at":1}]}
EOF
echo 'TEST_JEV_KEY=secret123' > "$HOME/api_keys.sh"

# Minimal verified provider fixtures so the provider wrappers pass their gates.
cat > "$PDIR/testprov.env" <<EOF
CMA_PROVIDER_ID="testprov"
CMA_PROVIDER_CONFIG_DIR="$HOME/.claude-prov-testprov"
CMA_PROVIDER_BASE_URL="http://127.0.0.1:9999/v1"
CMA_PROVIDER_KEYVAR="TEST_JEV_KEY"
CMA_PROVIDER_MODEL="m"
EOF
echo '{"testprov":{"status":"verified"}}' > "$PDIR/status.json"
printf 'default_model = "m"\nbase_url = "http://127.0.0.1:9999/v1"\n' > "$HOME/.kimi-prov-testprov/config.toml"
cat > "$HOME/.pi-prov-testprov/models.json" <<'EOF'
{"providers":{"testprov":{"baseUrl":"http://127.0.0.1:9999/v1","models":[{"id":"m"}]}}}
EOF

_cma_emit_managed "$HOME/.local/bin/claude" > "$ALIAS_FILE"

# PROVENANCE GATE — see lib/assert.sh:assert_fn_from. Every wrapper exercised
# below must come from the sandbox alias render, never from the host shell.
for _fn in cma_run cma_run_provider cma_run_kimi cma_run_kimi_provider cma_run_pi cma_run_pi_provider cma_jev_env; do
  assert_fn_from --source "$ALIAS_FILE" "$_fn" "$_fn under test comes from the sandbox alias file"
done

# _run_wrapper <label> <wrapper args...>: fresh shell, source alias file,
# capture the launched stub's env + the wrapper's stderr.
_run_wrapper() {
  local label="$1"; shift
  bash -c "
    source '$ALIAS_FILE'
    export JEV_TEST_DUMP='$HOME/dump.$label'
    $* >/dev/null 2>'$HOME/motd.$label'
  "
  echo $? > "$HOME/rc.$label"
}

_expect_jev_env() { # _expect_jev_env <label> <present:0|1>
  local label="$1" want="$2" dump="$HOME/dump.$label"
  if [ "$want" = 1 ]; then
    assert_file "$dump" "$label: stub env dumped"
    for v in JEV_BASE_URL=http://127.0.0.1:8095 TYPESAFE_BASE_URL=http://127.0.0.1:8095 \
             JEV_KEY_VAR=TEST_JEV_KEY JEV_MODEL=jev-fixture-1 \
             JEV_MODE=shadow CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50 MAX_THINKING_TOKENS=10000; do
      if grep -q "^$v\$" "$dump"; then _pass "$label: $v"; else _fail "$label env" "missing $v"; fi
    done
    # Secret-scoping fix (security review): the launched agent's own process
    # must NOT see the real key material -- only JEV_KEY_VAR (the non-secret
    # variable NAME) is exported broadly; jev-gate.sh/jev_mcp.py resolve the
    # actual secret themselves at call time.
    if grep -qE '^(JEV_API_KEY|TYPESAFE_API_KEY)=secret123$' "$dump"; then
      _fail "$label: real secret leaked into launched agent env" "$(grep -E '^(JEV_API_KEY|TYPESAFE_API_KEY)=' "$dump")"
    else
      _pass "$label: real secret not exported into launched agent env"
    fi
  else
    if [ -f "$dump" ] && grep -q '^JEV_BASE_URL=' "$dump"; then
      _fail "$label: Jev vars should be absent" "$(grep '^JEV_BASE_URL=' "$dump")"
    else
      _pass "$label: no Jev exports"
    fi
  fi
}

it "all six emitted wrappers export JEV_* + TYPESAFE_* and print the MOTD"
_run_wrapper run          cma_run
_run_wrapper runprov      cma_run_provider testprov
_run_wrapper kimi         cma_run_kimi
_run_wrapper kimiprov     cma_run_kimi_provider testprov
_run_wrapper pi           cma_run_pi
_run_wrapper piprov       cma_run_pi_provider testprov
for label in run runprov kimi kimiprov pi piprov; do
  _expect_jev_env "$label" 1
  assert_file_contains "$HOME/motd.$label" \
    "Jev decision layer: ACTIVE (endpoint: jev-local, mode: shadow)" "$label: MOTD line"
done
assert_eq 0 "$(cat "$HOME/rc.run")" "cma_run rc"
assert_eq 0 "$(cat "$HOME/rc.kimi")" "cma_run_kimi rc"
assert_eq 0 "$(cat "$HOME/rc.pi")" "cma_run_pi rc"

it "additive token knobs never clobber user-set values"
bash -c "
  source '$ALIAS_FILE'
  export JEV_TEST_DUMP='$HOME/dump.custom' MAX_THINKING_TOKENS=777 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=90
  cma_run_kimi >/dev/null 2>/dev/null
"
assert_eq 777 "$(grep '^MAX_THINKING_TOKENS=' "$HOME/dump.custom" | cut -d= -f2)" "user MAX_THINKING_TOKENS preserved"
assert_eq 90 "$(grep '^CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=' "$HOME/dump.custom" | cut -d= -f2)" "user autocompact pct preserved"

it "CMA_JEV_DISABLE=1 is a full opt-out"
bash -c "
  source '$ALIAS_FILE'
  export JEV_TEST_DUMP='$HOME/dump.disabled' CMA_JEV_DISABLE=1
  cma_run_kimi >/dev/null 2>'$HOME/motd.disabled'
  # Assert inside the child, synchronously: after the wrapper returns, the
  # launched stub's env must contain no Jev exports.
  if grep -q '^JEV_BASE_URL=' '$HOME/dump.disabled' 2>/dev/null; then
    echo leak > '$HOME/disabled.leaked'
  else
    echo clean > '$HOME/disabled.leaked'
  fi
"
assert_eq clean "$(cat "$HOME/disabled.leaked")" "disabled: no Jev exports in launched env"
if [ -s "$HOME/motd.disabled" ]; then _fail "disabled MOTD should be empty" "$(cat "$HOME/motd.disabled")"; else _pass "disabled: no MOTD"; fi

it "missing cache -> INACTIVE notice + background refresh kicked + fast launch"
rm -f "$PDIR/jev-endpoints.json"
t0=$SECONDS
bash -c "
  source '$ALIAS_FILE'
  export JEV_TEST_DUMP='$HOME/dump.nocache'
  cma_run_kimi >/dev/null 2>'$HOME/motd.nocache'
  env | grep '^CMA_JEV_REFRESH_KICKED=' > '$HOME/kicked'
"
dt=$(( SECONDS - t0 ))
assert_file_contains "$HOME/motd.nocache" "Jev decision layer: INACTIVE" "INACTIVE notice with reason"
assert_file_contains "$HOME/kicked" "CMA_JEV_REFRESH_KICKED=1" "background refresh kicked"
if [ -f "$HOME/dump.nocache" ] && grep -q '^JEV_BASE_URL=' "$HOME/dump.nocache"; then
  _fail "nocache: Jev vars leaked"; else _pass "nocache: launch proceeds without Jev exports"; fi
if (( dt <= 2 )); then _pass "launch within ${dt}s (<1s budget, loose)"; else _fail "launch too slow" "${dt}s"; fi

it "stale cache still used this launch while refresh is kicked"
mkdir -p "$PDIR"
cat > "$PDIR/jev-endpoints.json" <<'EOF'
{"endpoints":[{"provider_id":"jev-local","base_url":"http://127.0.0.1:8095","key_var":"TEST_JEV_KEY","model":"jev-fixture-1","priority":10,"probed_at":1}]}
EOF
touch -d '1 hour ago' "$PDIR/jev-endpoints.json" 2>/dev/null || touch -t 202001010000 "$PDIR/jev-endpoints.json"
bash -c "
  source '$ALIAS_FILE'
  export JEV_TEST_DUMP='$HOME/dump.stale' CMA_JEV_CACHE_TTL=60
  cma_run_kimi >/dev/null 2>/dev/null
  env | grep '^CMA_JEV_REFRESH_KICKED=' > '$HOME/kicked2'
"
_expect_jev_env stale 1
assert_file_contains "$HOME/kicked2" "CMA_JEV_REFRESH_KICKED=1" "stale cache kicks refresh"

it "lib.sh copies and emitted copies stay in sync"
# The managed render contains exactly one cma_jev_env definition
# and every wrapper body calls it.
assert_eq 1 "$(grep -c '^cma_jev_env() {' "$ALIAS_FILE")" "one emitted cma_jev_env definition"
for fn in cma_run cma_run_provider cma_run_kimi cma_run_kimi_provider cma_run_pi cma_run_pi_provider; do
  n=$(awk -v fn="$fn" '
    index($0, fn"() {") == 1 { f = 1; next }
    f && /^}/ { f = 0 }
    f && /cma_jev_env/ { c++ }
    END { print c + 0 }' "$ALIAS_FILE")
  assert_eq 1 "$n" "$fn calls cma_jev_env exactly once"
done

summary
