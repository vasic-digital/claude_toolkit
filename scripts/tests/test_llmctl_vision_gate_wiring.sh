#!/usr/bin/env bash
# test_llmctl_vision_gate_wiring.sh — hermetic wiring test for the Vision /
# model-validation path between claude_toolkit and llmctl (Constitution
# §11.4.277 gate, §11.4.278 Vision QA).
#
# WHAT IS (AND IS NOT) CLAIMED. The known-answer validation gate lives INSIDE
# llmctl (`llmctl validate`, `require-validated`, LLMCTL_VALIDATE_STRICT=1,
# exit 0 pass / 1 wrong / 2 undetermined / 75 pressure / 98 port-in-use). It
# runs on `llmctl switch|start|restart|enable`. claude_toolkit does NOT
# re-implement it and runs no Vision known-answer suite of its own. What the
# toolkit owns, and what this test proves, is the WIRING:
#   1. a llmctl-vision alias launch forwards the operator's
#      LLMCTL_VALIDATE_STRICT=1 to `llmctl switch vision` (so the gate runs
#      strict), and does not invent or strip the variable;
#   2. a gate refusal (exit 2 UNDETERMINED, exit 1 wrong answer, exit 75
#      pressure) makes the launch FAIL with that code — it is never turned
#      into a silent launch against an unvalidated model;
#   3. the gate is not a toolkit-side no-op for other profiles: a successful
#      switch for a non-vision profile still launches (no false refusal).
# Fake llmctl only; the real llmctl and any model are NEVER invoked.
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

LC_DIR="$HOME/lc-state"; mkdir -p "$LC_DIR"
LC_BIN="$HOME/.local/bin/llmctl-fake"
sandbox_stub "$LC_BIN" <<'EOF2'
#!/usr/bin/env bash
set -u
DIR="${LLMCTL_TEST_DIR:?}"
case "${1:-}" in
  status)
    active="$(cat "$DIR/active" 2>/dev/null || true)"
    if [[ -z "$active" ]]; then echo "no llmctl services running"; else
      printf '%-16s %-6s\n' profile port
      printf '%-16s %-6s\n' "$active" 8080
    fi ;;
  require-validated)
    printf 'require-validated %s\n' "${2:-}" >> "$DIR/calls"
    exit "$(cat "$DIR/rv_rc" 2>/dev/null || echo 0)"
    ;;
  switch)
    printf 'switch %s strict=%s\n' "${2:-}" "${LLMCTL_VALIDATE_STRICT:-<unset>}" >> "$DIR/calls"
    if [[ -f "$DIR/pressure" ]]; then
      # exit 75 from the host-pressure gate: refuses BEFORE stopping anything
      echo "switch refused under host memory pressure (simulated)" >&2
      [[ -f "$DIR/pressure_clears_active" ]] && rm -f "$DIR/active"
      exit 75
    fi
    if [[ -f "$DIR/gate_rc" ]]; then
      echo "validation gate refused profile ${2:-} (simulated)" >&2
      exit "$(cat "$DIR/gate_rc")"
    fi
    printf '%s' "${2:-}" > "$DIR/active"; exit 0 ;;
  *) exit 64 ;;
esac
EOF2
export CMA_LLMCTL_BIN="$LC_BIN" LLMCTL_TEST_DIR="$LC_DIR"
reset_lc() { rm -f "$LC_DIR/calls" "$LC_DIR/active" "$LC_DIR/gate_rc" "$LC_DIR/rv_rc" "$LC_DIR/pressure" "$LC_DIR/pressure_clears_active"; }

it "the ensure-active helper is present in the sandbox alias-file machinery"
assert_eq "function" "$(type -t _cma_llmctl_ensure_active 2>/dev/null || true)" "_cma_llmctl_ensure_active defined"

it "STRICT is forwarded: LLMCTL_VALIDATE_STRICT=1 reaches 'llmctl switch vision'"
reset_lc
( set +eu; export LLMCTL_VALIDATE_STRICT=1; _cma_llmctl_ensure_active llmctl-vision >/dev/null 2>&1 ); rc=$?
assert_eq 0 "$rc" "gate passes -> helper returns 0"
assert_eq "switch vision strict=1" "$(grep '^switch ' "$LC_DIR/calls")" "switch vision saw STRICT=1"

it "toolkit does not invent STRICT: unset in -> unset at llmctl"
reset_lc
( set +eu; unset LLMCTL_VALIDATE_STRICT; _cma_llmctl_ensure_active llmctl-vision >/dev/null 2>&1 ); rc=$?
assert_eq 0 "$rc" "helper returns 0"
assert_eq "switch vision strict=<unset>" "$(grep '^switch ' "$LC_DIR/calls")" "STRICT stays unset"

for gate_rc in 2 1 75; do
  it "gate refusal exit $gate_rc is NOT swallowed: launch path fails (no silent unvalidated launch)"
  reset_lc
  printf '%s' "$gate_rc" > "$LC_DIR/gate_rc"
  out="$( set +eu; export LLMCTL_VALIDATE_STRICT=1; _cma_llmctl_ensure_active llmctl-vision 2>&1 )"; rc=$?
  assert_eq "$gate_rc" "$rc" "helper returns EXACTLY llmctl's gate exit code ($gate_rc), never 0 or a generic 1"
  case "$out" in *"validation gate refused"*) _pass "llmctl's own refusal text is surfaced" ;;
    *) _fail "llmctl's own refusal text is surfaced" "output: $out" ;; esac
done

it "exit 75 from the pressure gate with the running set intact is NOT reported as a failed rollback"
reset_lc; printf 'chat' > "$LC_DIR/active"; : > "$LC_DIR/pressure"
out="$( set +eu; _cma_llmctl_ensure_active llmctl-vision 2>&1 )"; rc=$?
assert_eq 75 "$rc" "launch aborts with exit 75"
case "$out" in *CRITICAL*) _fail "no CRITICAL line on a pressure refusal" "$out" ;; *) _pass "no CRITICAL line on a pressure refusal" ;; esac
case "$out" in *"declined to switch"*) _pass "message says llmctl declined under pressure" ;; *) _fail "pressure message" "$out" ;; esac

it "exit 75 with the running set GONE is still the CRITICAL rollback marker"
reset_lc; printf 'chat' > "$LC_DIR/active"; : > "$LC_DIR/pressure"; : > "$LC_DIR/pressure_clears_active"
out="$( set +eu; _cma_llmctl_ensure_active llmctl-vision 2>&1 )"; rc=$?
assert_eq 75 "$rc" "launch aborts with exit 75"
case "$out" in *CRITICAL*) _pass "CRITICAL raised when the previous set disappeared" ;; *) _fail "CRITICAL raised" "$out" ;; esac

it "already-active vision + STRICT=1: require-validated is asked (the switch gate would not run)"
reset_lc; printf 'vision' > "$LC_DIR/active"; printf '2' > "$LC_DIR/rv_rc"
out="$( set +eu; export LLMCTL_VALIDATE_STRICT=1; _cma_llmctl_ensure_active llmctl-vision 2>&1 )"; rc=$?
assert_eq 2 "$rc" "require-validated exit 2 aborts the launch with exit 2"
assert_eq "require-validated vision" "$(grep -v '^status' "$LC_DIR/calls" | head -1)" "llmctl was asked require-validated vision"
reset_lc; printf 'vision' > "$LC_DIR/active"; printf '0' > "$LC_DIR/rv_rc"
( set +eu; export LLMCTL_VALIDATE_STRICT=1; _cma_llmctl_ensure_active llmctl-vision >/dev/null 2>&1 ); rc=$?
assert_eq 0 "$rc" "fresh PASS -> launch proceeds"
reset_lc; printf 'vision' > "$LC_DIR/active"; printf '1' > "$LC_DIR/rv_rc"
( set +eu; unset LLMCTL_VALIDATE_STRICT; _cma_llmctl_ensure_active llmctl-vision >/dev/null 2>&1 ); rc=$?
assert_eq 0 "$rc" "STRICT not requested: no extra gate call, launch proceeds (llmctl validated at start)"
assert_eq "0" "$(cat "$LC_DIR/calls" 2>/dev/null | grep -c '^require-validated')" "no require-validated call without STRICT"

it "non-llmctl alias ids never touch llmctl (no false gate coupling)"
reset_lc
( set +eu; _cma_llmctl_ensure_active deepseek >/dev/null 2>&1 ); rc=$?
assert_eq 0 "$rc" "returns 0"
assert_eq "0" "$( [[ -f "$LC_DIR/calls" ]] && wc -l < "$LC_DIR/calls" || echo 0 )" "llmctl not called at all"

it "docs state the division of responsibility (gate in llmctl, wiring in toolkit)"
REPO_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
assert_file_contains "$REPO_ROOT/docs/llmctl/user-guide.md" "11.4.277" "user-guide cites §11.4.277"
assert_file_contains "$REPO_ROOT/docs/llmctl/user-guide.md" "require-validated" "user-guide names require-validated"

summary
