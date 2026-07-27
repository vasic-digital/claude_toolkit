#!/usr/bin/env bash
# test_route_integrity.sh — hermetic proof that a router-transport alias never
# launches against a route it did not prove it set.
#
# THREE DEFECTS, all of which produced a launch that LOOKED successful while
# serving a different provider's model:
#
#   1. SELF-REFERENCE INHERITANCE. `helixagent`'s base_url IS the ccr gateway
#      (http://127.0.0.1:3456/v1). Every other router provider rewrites
#      .Router.default to itself immediately before launching; the self-reference
#      guard made helixagent SKIP that rewrite and launch anyway, inheriting
#      whichever provider the gateway last served. It was badged `verified` on a
#      turn served by `deepseek` — 157,419 tokens through a nominally
#      24,576-token alias — and no `helixagent` provider existed in ccr's config
#      at all. Now: refuse (rc 78), never inherit.
#
#   2. SILENT WRITE. The jq/mv config rewrite ran under `2>/dev/null` with a bare
#      `else rm -f` fallback: a failed write was indistinguishable from a
#      successful one, and the launch proceeded on the previous route.
#
#   3. SILENT RESTART. `ccr restart` ran under `|| true`. The restart is what
#      makes the write LIVE (submodules/claude-code-router/cmd/ccr/service.go,
#      cmdRestart); a failed restart means the config file is right and the
#      running gateway is still wrong — the config says one thing, the wire says
#      another, and nothing anywhere reports it.
#
# Every case here has a matching CONTROL that must still pass, because a guard
# that refuses everything is not a fix.
#
# Hermetic: sandboxed $HOME, a fake `ccr` that records launches, a fake `jq`
# that fails only the route rewrite. No network, no real claude, NO PROVIDER
# ALIAS IS EVER LAUNCHED (that costs real money and contends the shared gateway).
#
# CMA_LIBSH overrides the lib.sh under test so the whole file can be re-run
# against the PRE-CHANGE lib.sh to demonstrate the assertions genuinely have
# teeth (a test that cannot fail against the old code proves nothing).
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
LIBSH="${CMA_LIBSH:-$SCRIPTS_DIR/lib.sh}"
# shellcheck source=../lib.sh
source "$LIBSH"
set +e

VERIFY_SH="${CMA_VERIFY_SH:-$SCRIPTS_DIR/providers-verify.sh}"
# Per-alias CCR_HOME (lib.sh router branch): every router provider's config
# lives in ~/.claude-code-router/<provider-id>/config.json — nothing writes
# the global ~/.claude-code-router/config.json any more, so seeding/reading
# the route must name the provider's OWN dir or the fixtures grade a file the
# launcher never touches.
cfg_for() { printf '%s' "$HOME/.claude-code-router/$1/config.json"; }
REC_LAUNCH="$HOME/rec.launch"
REAL_JQ="$(command -v jq)"

# --- launch plumbing --------------------------------------------------------
cma_ensure_alias_file
mkdir -p "$HOME/.local/bin"
for stub in claude-sync-state claude-session; do
  # sandbox_stub, not a bare redirect: in a real $HOME these names are symlinks
  # into the repo and `>` would write THROUGH the link into the production script.
  sandbox_stub "$HOME/.local/bin/$stub" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
done

# Fake ccr. Mirrors the bundled Go router's dispatch (cmd/ccr/main.go) and
# records every LAUNCH, which is the observable the whole file turns on: a
# refused route must produce NO launch line. `restart` honours FAKE_RESTART_RC
# so defect 3 can be modelled without touching a real gateway.
FAKEBIN="$HOME/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/ccr" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --help|-h|help) echo "Usage: ccr start [--host <host>] [--port <port>]"
                  echo "  ccr serve [--host <host>] [--port <port>]"
                  # MUST advertise `ccr restart` with the bundled Go router's
                  # grammar (submodules/claude-code-router/cmd/ccr/main.go):
                  # aa30853 made cma_run_provider identity-check the resolved
                  # ccr by grepping --help for exactly that subcommand (the
                  # npm router lacks it), so a stale --help trips the rc=127
                  # refusal even though this fake implements `restart` below.
                  echo "  ccr restart [--host <host>] [--port <port>] [--gateway|--no-gateway]"; exit 0 ;;
  code|default-claude-code) shift; echo "LAUNCHED $*" >> "$REC_LAUNCH"; exit 0 ;;
  restart) if [[ "${FAKE_RESTART_LEAK:-0}" == 1 ]]; then
             # Models a router that dumps its EFFECTIVE CONFIG when it cannot
             # restart. That config holds the provider api key, so the key ends
             # up on the tool's stderr — which cma_run_provider interpolates
             # verbatim into its "route was NOT applied" diagnostic. This is the
             # only reason the scrub in lib.sh exists, so it is the fixture the
             # scrub has to be graded against. The key here is synthetic.
             printf 'ccr: restart failed; effective config was {"api_key":"%s"}\n' "${ACME_KEY:-}" >&2
           fi
           exit "${FAKE_RESTART_RC:-0}" ;;
  start|ui|serve|web|stop|config) exit 0 ;;
  *) printf 'fake-ccr: unexpected subcommand %s — not implemented by the bundled Go router\n' "${1:-<none>}" >&2; exit 2 ;;
esac
EOF
chmod +x "$FAKEBIN/ccr"

# Fake jq that fails ONLY the route rewrite (identified by the .Router.default
# assignment in its program) and delegates everything else to the real jq. A
# blanket-failing jq would prove nothing: the wrapper uses jq elsewhere, and the
# assertions must isolate the route write.
make_broken_jq() {
  cat > "$FAKEBIN/jq" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    *Router.default*) echo "jq: error: synthetic route-write failure" >&2; exit 5 ;;
  esac
done
exec "$REAL_JQ" "\$@"
EOF
  chmod +x "$FAKEBIN/jq"
}
restore_jq() { rm -f "$FAKEBIN/jq"; }

seed_route() {  # seed_route ID "<prov>,<model>"
  mkdir -p "$(dirname "$(cfg_for "$1")")"
  printf '{"Providers":[],"Router":{"default":"%s","background":"%s"}}\n' "$2" "$2" > "$(cfg_for "$1")"
}

run_provider() {  # run_provider ID  -> sets $rc, $out; resets the launch record
  : > "$REC_LAUNCH"
  out="$( ( set +eu
            ACME_KEY=sk-test-not-a-real-key \
            REC_LAUNCH="$REC_LAUNCH" FAKE_RESTART_RC="${FAKE_RESTART_RC:-0}" \
            FAKE_RESTART_LEAK="${FAKE_RESTART_LEAK:-0}" \
            PATH="$FAKEBIN:/usr/bin:/bin" \
            cma_run_provider "$1" </dev/null 2>&1 ) )"
  rc=$?
}

# grep -c prints 0 AND exits 1 when there is no match, so `|| echo 0` would
# print it twice. Swallow the status instead.
launch_count() { grep -c '^LAUNCHED' "$REC_LAUNCH" 2>/dev/null || true; }
route_default() { "$REAL_JQ" -r '.Router.default // ""' "$(cfg_for "$1")" 2>/dev/null; }

mkprov() {  # mkprov ID BASEURL
  cma_provider_write_env "$1" ACME_KEY router "$2" "$1-big" "$1-fast" \
    "$HOME/.claude-prov-$1" 262144 131072 "$1"
  cma_provider_write_alias "$1" "$1"
  cma_status_write "$1" verified "$1-big" ""
}

mkprov selfref  'http://127.0.0.1:3456/v1'
mkprov selfalt  'http://localhost:3456/v1'
mkprov normal   'https://api.test/v1'

# cma_run_provider lives ONLY in the generated alias file, so the sandbox copy
# must be sourced before anything can exercise it.
# shellcheck source=/dev/null
source "$ALIAS_FILE"

# Provenance guard. This file was written once WITHOUT the source above and
# still "passed" a launch: the harness shell inherits the HOST's real
# cma_run_provider (the login profile sources the production alias file), so the
# whole run silently graded live host code instead of the code under test —
# identical output before and after the fix. `extdebug` makes `declare -F` print
# "name lineno file"; assert the definition came from the SANDBOX.
it "HYGIENE: the cma_run_provider under test comes from the sandbox alias file"
shopt -s extdebug
def_src="$(declare -F cma_run_provider | awk '{print $3}')"
shopt -u extdebug
assert_eq "$ALIAS_FILE" "$def_src" "cma_run_provider was loaded from the sandbox, not the host"

# ===========================================================================
# Section 0 — CONTROL: the normal router path still works end to end
# ===========================================================================
it "CONTROL: a normal router provider rewrites .Router.default to ITSELF and launches"
seed_route normal 'foreign,foreign-model'
FAKE_RESTART_RC=0 run_provider normal
assert_eq 0 "$rc" "normal router launch succeeds"
assert_eq 1 "$(launch_count)" "the launch actually happened"
assert_eq "normal,normal-big" "$(route_default normal)" "the route names the provider under test (attributable)"

# ===========================================================================
# Section 1 — DEFECT 1: a self-referencing base must never silently inherit
# ===========================================================================
it "a provider whose base_url IS the ccr gateway is REFUSED, not inherited"
seed_route selfref 'foreign,foreign-model'
FAKE_RESTART_RC=0 run_provider selfref
assert_eq 78 "$rc" "self-referencing provider refused with a non-zero status"
assert_eq 0 "$(launch_count)" "NO launch happened on the inherited route (the helixagent bluff)"
assert_eq "foreign,foreign-model" "$(route_default selfref)" "the foreign route was left untouched — nothing claimed it"
case "$out" in *"ccr gateway itself"*) hit=0 ;; *) hit=1 ;; esac
assert_eq 0 "$hit" "the refusal says WHY (base_url is the gateway itself)"
case "$out" in *selfref*) hit=0 ;; *) hit=1 ;; esac
assert_eq 0 "$hit" "the refusal names the provider"

it "the guard is host-form agnostic (localhost, not just 127.0.0.1)"
seed_route selfalt 'foreign,foreign-model'
FAKE_RESTART_RC=0 run_provider selfalt
assert_eq 78 "$rc" "localhost:3456 refused too"
assert_eq 0 "$(launch_count)" "no launch on the inherited route"

# ===========================================================================
# Section 2 — DEFECT 2: a failed route WRITE is never reported as success
# ===========================================================================
it "a failed jq route rewrite refuses the launch instead of proceeding"
seed_route normal 'foreign,foreign-model'
make_broken_jq
FAKE_RESTART_RC=0 run_provider normal
restore_jq
assert_eq 78 "$rc" "failed jq write is fatal (was: silent 'else rm -f')"
assert_eq 0 "$(launch_count)" "no launch against the un-updated route"
assert_eq "foreign,foreign-model" "$(route_default normal)" "the old route is intact — no partial write"
case "$out" in *"NOT applied"*) hit=0 ;; *) hit=1 ;; esac
assert_eq 0 "$hit" "the failure is announced, not swallowed by 2>/dev/null"
# NOTE: this particular fixture's stderr contains no key, so this assertion is
# a smoke check only. The one with teeth is "the key is scrubbed out of a tool
# stderr that really carries it", in section 3 — see the comment there.
case "$out" in *"sk-test-not-a-real-key"*) leak=1 ;; *) leak=0 ;; esac
assert_eq 0 "$leak" "the diagnostic never echoes the live key"

it "a failed install of the rewritten config (mv) refuses the launch"
if (( EUID == 0 )); then
  # root ignores directory permissions, so the mv cannot be made to fail this way.
  _pass "SKIP (running as root: an unwritable dir cannot fail mv)"
else
  seed_route normal 'foreign,foreign-model'
  # The write target is the PER-ALIAS config dir (lib.sh CCR_HOME isolation),
  # so that — not the global dir — is what must be made unwritable for mv to fail.
  chmod 500 "$HOME/.claude-code-router/normal"
  FAKE_RESTART_RC=0 run_provider normal
  chmod 700 "$HOME/.claude-code-router/normal"
  assert_eq 78 "$rc" "failed mv is fatal"
  assert_eq 0 "$(launch_count)" "no launch when the new config never landed"
  assert_eq "foreign,foreign-model" "$(route_default normal)" "the gateway still holds the old route, and we did not pretend otherwise"
fi

# ===========================================================================
# Section 3 — DEFECT 3: a failed `ccr restart` blocks the launch
# ===========================================================================
it "a failed 'ccr restart' refuses the launch (config written, route NOT live)"
seed_route normal 'foreign,foreign-model'
FAKE_RESTART_RC=1 run_provider normal
assert_eq 78 "$rc" "failed restart is fatal (was: '|| true')"
assert_eq 0 "$(launch_count)" "no launch against a route the gateway never applied"
case "$out" in *"restart"*) hit=0 ;; *) hit=1 ;; esac
assert_eq 0 "$hit" "the diagnostic names the restart as the failing step"
# The written file is correct; only the LIVE gateway is stale. That divergence
# is precisely why the file alone is not proof.
assert_eq "normal,normal-big" "$(route_default normal)" "the config file WAS updated — the file is not the proof, the restart is"

it "the key is scrubbed out of a tool stderr that really carries it"
# WHY THIS REPLACES A VACUOUS ASSERTION. This file already claimed to cover the
# key scrub, but the only fixture behind that claim was the broken jq, whose
# stderr is a fixed string with no key anywhere in it. Deleting the scrub from
# lib.sh therefore left the file 28/28 green — it asserted the absence of
# something that was never present. cma_run_provider interpolates the FAILING
# TOOL'S OWN stderr into its diagnostic (`${_rst_out:+: $_rst_out}`), so the
# fixture has to be a tool that actually emits the key. FAKE_RESTART_LEAK=1 is
# that fixture, and the CONTROL below proves it is one.
seed_route normal 'foreign,foreign-model'
FAKE_RESTART_RC=1 FAKE_RESTART_LEAK=1 run_provider normal
assert_eq 78 "$rc" "a leaking, failing restart still refuses the launch"
assert_eq 0 "$(launch_count)" "no launch after a failed restart"
# CONTROL FIRST: without this, a scrub-less build could still pass by accident
# if the fixture quietly stopped emitting the key.
_leak_probe="$( ACME_KEY=sk-test-not-a-real-key FAKE_RESTART_RC=1 FAKE_RESTART_LEAK=1 \
                "$FAKEBIN/ccr" restart 2>&1 )"
case "$_leak_probe" in *"sk-test-not-a-real-key"*) hit=0 ;; *) hit=1 ;; esac
assert_eq 0 "$hit" "CONTROL: the fixture's stderr really does emit the key"
case "$out" in *"<redacted>"*) hit=0 ;; *) hit=1 ;; esac
assert_eq 0 "$hit" "the scrub fired (the diagnostic shows <redacted>)"
case "$out" in *"sk-test-not-a-real-key"*) leak=1 ;; *) leak=0 ;; esac
assert_eq 0 "$leak" "the key never reaches the terminal"

it "CONTROL: with jq and restart healthy, the same provider launches again"
seed_route normal 'foreign,foreign-model'
FAKE_RESTART_RC=0 run_provider normal
assert_eq 0 "$rc" "healthy route write + restart still launches"
assert_eq 1 "$(launch_count)" "the control proves sections 2-3 fail for the right reason"

# ===========================================================================
# Section 4 — the same shape is not gradeable either (no unearned badge)
# ===========================================================================
it "providers-verify refuses to grade a provider whose base_url is the gateway"
v_out="$("$VERIFY_SH" --provider selfref --model selfref-big --key-var ACME_KEY \
          --base-url 'http://127.0.0.1:3456/v1' --offline 2>&1)"; v_rc=$?
assert_eq 1 "$v_rc" "verdict is a hard failure, not a pass"
case "$v_out" in failed*) hit=0 ;; *) hit=1 ;; esac
assert_eq 0 "$hit" "emits 'failed' (was: an unattributable 'verified'/'unverified')"

it "CONTROL: a normal base_url is still graded by the usual strategies"
v_out="$("$VERIFY_SH" --provider normal --model normal-big --key-var ACME_KEY \
          --base-url 'https://api.test/v1' --offline 2>&1)"; v_rc=$?
case "$v_out" in failed*) hit=1 ;; *) hit=0 ;; esac
assert_eq 0 "$hit" "an ordinary provider is not swept up by the gateway gate"

summary
