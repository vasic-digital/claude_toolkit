#!/usr/bin/env bash
# test_llmctl_sync_all.sh — hermetic TDD coverage for
# `claude-providers.sh sync-all-llmctl`: the full-catalog, deterministic,
# one-by-one sweep that switches llmctl through EVERY catalog profile (never
# a hardcoded profile-name list — discovered live from `llmctl plan --json`,
# the SAME catalog source detect_llmctl_records already uses), verifies each
# with the SAME probe claude-providers already runs for llmctl providers
# (cmd_sync's chat-completion + tool-call verification, reused verbatim —
# never reimplemented), and records a deterministic PASS / FAIL / GATED
# status per profile:
#   PASS  — switched successfully AND cmd_sync verified it.
#   FAIL  — switched successfully but verification did not pass.
#   GATED — `llmctl switch <profile>` itself failed (e.g. llmctl reports the
#           host cannot even start that profile in isolation — a legitimate,
#           honest outcome for a handful of very large catalog profiles on a
#           given host, NOT a bug to hide or a reason to skip the profile).
#
# cmd_sync itself is REPLACED with a test double in this file: its own
# verification pipeline (VERIFY_OK sentinel probe + tool-call probe against a
# real-shaped chat endpoint) is already covered by test_llmctl_detect.sh's
# CASE H and the rest of this suite — this file's job is to prove
# cmd_sync_all_llmctl's OWN logic (live catalog discovery, per-profile
# switch, GATED-on-switch-failure, and status-based PASS/FAIL
# classification), not to re-derive cmd_sync's verification correctness.
#
# Fully hermetic — the REAL /home/milosvasic/Projects/llmctl/bin/llmctl and
# the REAL running llmctl services are NEVER invoked by this file (a fake
# `llmctl` resolved via CMA_LLMCTL_BIN, exactly as detect_llmctl_records
# already supports).
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
PROVIDERS_SH="$SCRIPTS_DIR/claude-providers.sh"
# shellcheck source=../claude-providers.sh
source "$PROVIDERS_SH"   # sources lib.sh internally; CLI dispatch is
                          # guarded by `[[ "${BASH_SOURCE[0]}" == "$0" ]]`,
                          # so this defines functions only (same technique
                          # test_llmctl_detect.sh already relies on).
set +e

REC="$HOME/rec"; mkdir -p "$REC"
: > "$REC/cmd_sync_calls"

# --- fake llmctl: real catalog discovery + per-profile switch outcomes -----
LC_DIR="$HOME/lc-state"; mkdir -p "$LC_DIR"
PLAN_FILE="$LC_DIR/plan.json"
cat > "$PLAN_FILE" <<'JSON'
{"profiles": {"fast": {"port": 18080, "ctx": 8192}, "vision": {"port": 18082, "ctx": 8192}, "huge": {"port": 18099, "ctx": 8192}}}
JSON
LC_BIN="$HOME/.local/bin/llmctl-sweep-fake"
sandbox_stub "$LC_BIN" <<EOF
#!/usr/bin/env bash
set -u
DIR="\${LLMCTL_TEST_DIR:?}"
PLAN="\${LLMCTL_TEST_PLAN:?}"
mkdir -p "\$DIR"
case "\${1:-}" in
  plan)
    [[ "\${2:-}" == "--json" ]] || exit 2
    cat "\$PLAN"
    ;;
  switch)
    profile="\${2:-}"
    printf 'switch %s\n' "\$profile" >> "\$DIR/calls"
    if [[ "\$profile" == "huge" ]]; then
      echo "switch to 'huge' failed - insufficient VRAM even in isolation on this host" >&2
      exit 1
    fi
    printf '%s' "\$profile" > "\$DIR/active"
    exit 0
    ;;
  *)
    echo "llmctl-sweep-fake: unhandled args: \$*" >&2
    exit 64
    ;;
esac
EOF
export CMA_LLMCTL_BIN="$LC_BIN"
export LLMCTL_TEST_DIR="$LC_DIR"
export LLMCTL_TEST_PLAN="$PLAN_FILE"

lc_calls() { cat "$LC_DIR/calls" 2>/dev/null || true; }

# --- test double for cmd_sync: proves cmd_sync_all_llmctl's OWN wiring -----
# without re-deriving cmd_sync's already-covered verification internals.
# "fast" ends up verified (PASS); "vision" ends up unverified (FAIL); "huge"
# must NEVER be reached (its switch already failed -> GATED).
cmd_sync() {
  local id="$1"
  printf '%s\n' "$id" >> "$REC/cmd_sync_calls"
  case "$id" in
    llmctl-fast)   cma_status_write "$id" verified   "fast-model"   "" ;;
    llmctl-vision) cma_status_write "$id" unverified "vision-model" "semantic" ;;
    *) return 1 ;;
  esac
}

it "cmd_sync_all_llmctl: discovers the catalog LIVE from 'llmctl plan --json' (never hardcoded) and switches through EVERY profile"
rm -f "$LC_DIR/calls"; : > "$REC/cmd_sync_calls"
out="$(cmd_sync_all_llmctl 2>&1)"; rc=$?
assert_eq 0 "$rc" "sweep exits 0 even with a GATED profile in the catalog"
assert_eq "switch fast
switch huge
switch vision" "$(lc_calls | sort)" "switch attempted for every catalog profile, sorted"

it "cmd_sync_all_llmctl: GATED profile's switch failure means cmd_sync is NEVER called for it"
grep -q '^llmctl-huge$' "$REC/cmd_sync_calls" && bad=0 || bad=1
assert_eq 1 "$bad" "cmd_sync never invoked for the GATED profile"

it "cmd_sync_all_llmctl: PASS + FAIL profiles both DID reach cmd_sync"
grep -q '^llmctl-fast$' "$REC/cmd_sync_calls" && ok=0 || ok=1
assert_eq 0 "$ok" "cmd_sync invoked for llmctl-fast"
grep -q '^llmctl-vision$' "$REC/cmd_sync_calls" && ok=0 || ok=1
assert_eq 0 "$ok" "cmd_sync invoked for llmctl-vision"

it "cmd_sync_all_llmctl: report table classifies fast=PASS, vision=FAIL, huge=GATED"
[[ "$out" == *"fast"*"PASS"* ]] && ok=0 || ok=1
assert_eq 0 "$ok" "fast reported PASS"
[[ "$out" == *"vision"*"FAIL"* ]] && ok=0 || ok=1
assert_eq 0 "$ok" "vision reported FAIL"
[[ "$out" == *"huge"*"GATED"* ]] && ok=0 || ok=1
assert_eq 0 "$ok" "huge reported GATED"

it "cmd_sync_all_llmctl: GATED detail cites llmctl's own stderr reason (never hidden)"
[[ "$out" == *"insufficient VRAM"* || "$out" == *"switch exit"* ]] && ok=0 || ok=1
assert_eq 0 "$ok" "GATED detail is honest, not a generic bluff message"

it "cmd_sync_all_llmctl: status.json genuinely reflects fast=verified after the sweep"
assert_eq "verified" "$(cma_status_read llmctl-fast)" "llmctl-fast status persisted verified"

it "cmd_sync_all_llmctl: status.json genuinely reflects vision=unverified after the sweep"
assert_eq "unverified" "$(cma_status_read llmctl-vision)" "llmctl-vision status persisted unverified"

it "cmd_sync_all_llmctl: llmctl binary unresolvable -> refuses loudly, non-zero exit"
out2="$(CMA_LLMCTL_BIN=/no/such/llmctl-binary-for-sweep cmd_sync_all_llmctl 2>&1)"; rc2=$?
[[ "$rc2" -ne 0 ]] && ok=0 || ok=1
assert_eq 0 "$ok" "missing llmctl binary is a non-zero refusal"
[[ "$out2" == *"llmctl"* ]] && ok=0 || ok=1
assert_eq 0 "$ok" "refusal names llmctl"

it "cmd_sync_all_llmctl: an empty catalog refuses loudly rather than silently doing nothing"
EMPTY_PLAN="$LC_DIR/empty_plan.json"
echo '{"profiles": {}}' > "$EMPTY_PLAN"
out3="$(LLMCTL_TEST_PLAN="$EMPTY_PLAN" cmd_sync_all_llmctl 2>&1)"; rc3=$?
[[ "$rc3" -ne 0 ]] && ok=0 || ok=1
assert_eq 0 "$ok" "empty catalog is a non-zero refusal, not a silent no-op"

# ---------------------------------------------------------------------------
# REAL CLI-ENTRYPOINT REGRESSION: every assertion above calls
# cmd_sync_all_llmctl as a sourced FUNCTION, never through the real CLI
# argument dispatcher (`claude-providers.sh`'s own `case "${1:-}" in ...`
# whitelist that sets $SUBCMD before the later `case "$SUBCMD" in
# sync-all-llmctl) ...` dispatch arm can ever run). A real, live-reproduced
# defect this session: the dispatch arm was added, but "sync-all-llmctl"
# was never added to that EARLIER whitelist - so `$SUBCMD` silently stayed
# at its "sync" default, "sync-all-llmctl" fell through as a POSITIONAL
# argument (a provider id) to the default sync command, and running
# `claude-providers.sh sync-all-llmctl` for real failed with "no provider
# matching 'sync-all-llmctl' found" - the feature was completely
# unreachable from the command line despite 14/14 function-level
# assertions passing. Proving the function works is not the same as
# proving the CLI routes to it; this test closes that exact gap by
# actually EXECUTING the real script as a subprocess. -----------------------
it "REAL CLI: 'claude-providers.sh sync-all-llmctl' actually reaches cmd_sync_all_llmctl (not swallowed as a sync provider-id positional)"
cli_out="$(CMA_LLMCTL_BIN=/no/such/llmctl-binary-for-cli-dispatch-test bash "$PROVIDERS_SH" sync-all-llmctl 2>&1)"; cli_rc=$?
[[ "$cli_rc" -ne 0 ]] && ok=0 || ok=1
assert_eq 0 "$ok" "real CLI invocation exits non-zero (llmctl binary deliberately unresolvable)"
[[ "$cli_out" == *"no provider matching"* ]] && ok=1 || ok=0
assert_eq 0 "$ok" "REGRESSION GUARD: real CLI invocation does NOT fall through to sync's 'no provider matching' positional-arg path"
[[ "$cli_out" == *"llmctl"* ]] && ok=0 || ok=1
assert_eq 0 "$ok" "real CLI invocation reaches cmd_sync_all_llmctl's own honest refusal (names llmctl)"

summary
