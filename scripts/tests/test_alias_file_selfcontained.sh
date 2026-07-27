#!/usr/bin/env bash
# test_alias_file_selfcontained.sh — the GENERATED alias file must not call
# lib.sh-only helpers bare.
#
# WHY THIS EXISTS (live defect 2026-07-27, v1.26.6 payload). `cma_run_provider`
# is emitted into $ALIAS_FILE by a `cat <<'CMA_PROV_BODY_EOF'` heredoc in
# lib.sh, and that alias file NEVER sources lib.sh — it is sourced by the user's
# interactive shell. So `cma_log` / `cma_warn` do not exist at run time. The
# helixagent pre-flight added six bare calls, and the operator got
#
#     cma_warn: command not found
#
# verbatim in providers-helixagent-superpowers.txt, exactly where the
# coder-mode remedy should have been. The message IS the feature there: it is
# the only thing that tells an operator to flip HelixLLM out of coder mode.
#
# The older guard idiom (`command -v cma_log >/dev/null 2>&1 && cma_log …`) is
# accepted here because it cannot produce the shell error — but note it SILENTLY
# DROPS the text, which is why the helixagent path uses fallback emitters that
# print either way. This test enforces the floor (no bare call), not the choice
# between the two.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
set +e

# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e

cma_ensure_alias_file >/dev/null 2>&1

it "the alias file was generated and defines the provider wrapper"
assert_file "$ALIAS_FILE"
assert_eq 1 "$(grep -cF 'cma_run_provider()' "$ALIAS_FILE")" "cma_run_provider defined exactly once"

# --- the lint --------------------------------------------------------------
# A call is BARE when the helper name appears in command position and the same
# line carries no `command -v` guard. Comments and the guard lines themselves
# are excluded. Anti-vacuity: the file must be big enough to have been really
# rendered, else an empty file would pass trivially.
it "no lib.sh-only helper is called bare in the generated alias file"
lines="$(wc -l < "$ALIAS_FILE")"
if [[ "$lines" -lt 50 ]]; then
  _fail "alias file too small to lint" "only $lines lines — did generation fail?"
else
  _pass "alias file is substantial ($lines lines)"
fi

# The guard idiom in this file spans LINES: `command -v cma_log … \` continued
# by `&& cma_log …`, and `cma_log … || true` whose guard sits on the line above.
# A per-line grep therefore reports guarded code as bare. Join continuations
# first — a line ending in `\`, or a line whose successor opens with `&&`/`||`
# — and lint the joined logical lines.
joined="$SANDBOX_HOME/alias-joined.sh"
# Pass 1: fold explicit `\` continuations. Pass 2: fold a line onto its
# predecessor when it opens with `&&` or `||`.
sed -e ':a' -e '/\\$/{N;s/\\\n/ /;ba}' "$ALIAS_FILE" \
  | awk 'NR==1 { printf "%s", $0; next }
         /^[[:space:]]*(&&|\|\|)/ { printf " %s", $0; next }
         { printf "\n%s", $0 }
         END { printf "\n" }' > "$joined"

bare=""
for helper in cma_log cma_warn cma_die cma_require; do
  hits="$(grep -nE "(^|[;&|]|\bthen\b|\belse\b|\bdo\b|\{)[[:space:]]*${helper}[[:space:]]+\"" "$joined" \
          | grep -v "command -v ${helper}" \
          | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
  [[ -n "$hits" ]] && bare="$bare$hits"$'\n'
done
if [[ -n "${bare//[[:space:]]/}" ]]; then
  _fail "bare lib.sh helper call(s) in the generated alias file" "$(printf '%s' "$bare" | head -6)"
else
  _pass "every lib.sh helper reference is guarded or routed through a fallback emitter"
fi

# --- behavioural: the helixagent emitters must PRINT without lib.sh ---------
# The lint proves no bare call ships. This proves the replacement actually
# emits — a guard that swallows the text would satisfy the lint while still
# losing the operator guidance the pre-flight exists to deliver.
it "the helixagent fallback emitters print even when lib.sh is absent"
probe="$SANDBOX_HOME/hl_emit_probe.sh"
{
  printf '#!/usr/bin/env bash\n'
  # Exactly the definitions emitted into the alias file, extracted from it so
  # the test cannot drift from the shipped text.
  grep -F '_hl_log()  {' "$ALIAS_FILE" | head -1
  grep -F '_hl_warn() {' "$ALIAS_FILE" | head -1
  printf '_hl_log "LOGLINE"\n_hl_warn "WARNLINE"\n'
} > "$probe"
chmod +x "$probe"
out="$(env -u BASH_ENV bash "$probe" 2>&1)"
if grep -q 'command not found' <<<"$out"; then
  _fail "the emitters still hit a missing helper" "$out"
else
  _pass "no 'command not found' from the emitters"
fi
grep -q 'LOGLINE'  <<<"$out"; assert_eq 0 $? "the log message actually reached the operator"
grep -q 'WARNLINE' <<<"$out"; assert_eq 0 $? "the warning message actually reached the operator (not silently dropped)"

# ===========================================================================
# CMA_HELIX_AUTOSTART — booting a Helix service must be OPT-IN (operator
# mandate 2026-07-27).
#
# Starting HelixLLM claims the machine's single GPU and EVICTS whatever
# HelixCode had running in coder mode, so a provider alias must never do it
# merely because someone launched the alias. Default is OFF. This pins BOTH
# directions — an accidental `:-1` default, or a parse that treats "false" as
# truthy, are the two ways this silently regresses into booting by itself.
# ===========================================================================

it "the emitted wrapper gates HelixLLM auto-start behind CMA_HELIX_AUTOSTART"
assert_file_contains "$ALIAS_FILE" 'CMA_HELIX_AUTOSTART' "the opt-in knob is present in the shipped wrapper"
# The default must be the OFF literal. `${CMA_HELIX_AUTOSTART:-1}` would boot
# by default and is exactly the regression this pins.
if grep -qF 'CMA_HELIX_AUTOSTART:-0' "$ALIAS_FILE"; then
  _pass "default is OFF (\${CMA_HELIX_AUTOSTART:-0})"
else
  _fail "auto-start default is not OFF" "$(grep -oE 'CMA_HELIX_AUTOSTART:-[^}]*' "$ALIAS_FILE" | head -1)"
fi

it "the auto-start gate parses truthy/falsey exactly as documented"
# Behavioural: extract the SHIPPED case statement from the alias file and run
# it, so the test cannot pass against a gate that only looks right.
# `local` is stripped: the shipped line is `local _hl_autostart=…` because it
# lives inside cma_run_provider, and `local` outside a function is a hard error
# ("can only be used in a function") that would blank the variable and make
# EVERY value fall through to 0 — i.e. the test would report the gate broken
# while the gate is fine. Strip only that keyword; the logic under test is
# otherwise the shipped text verbatim.
gate_src="$(awk '/_hl_autostart="\$\{CMA_HELIX_AUTOSTART/{f=1} f{print} f&&/esac/{exit}' "$ALIAS_FILE" \
            | sed -E 's/^([[:space:]]*)local[[:space:]]+/\1/')"
if [[ -z "$gate_src" ]]; then
  _fail "could not extract the auto-start gate" "pattern not found in $ALIAS_FILE"
else
  _pass "extracted the shipped gate ($(printf '%s' "$gate_src" | wc -l) lines)"
  for pair in ":0" "0:0" "false:0" "no:0" "off:0" "random:0" "1:1" "true:1" "yes:1" "on:1" "TRUE:1" "Yes:1"; do
    val="${pair%%:*}"; want="${pair##*:}"
    got="$(env CMA_HELIX_AUTOSTART="$val" bash -c "$gate_src"'; printf "%s" "$_hl_autostart"' 2>/dev/null)"
    if [[ "$got" == "$want" ]]; then
      _pass "CMA_HELIX_AUTOSTART='$val' -> $got"
    else
      _fail "CMA_HELIX_AUTOSTART='$val' misparsed" "want=$want got=${got:-<empty>}"
    fi
  done
fi

it "with auto-start OFF the operator still gets the command to run"
# Turning the boot off must not cost the operator the information. The off
# branch has to name the manual mode-switch AND the opt-in.
off_branch="$(awk '/_hl_autostart" -ne 1 \]\]; then/{f=1} f{print} f&&/^ *fi/{exit}' "$ALIAS_FILE")"
if [[ -z "$off_branch" ]]; then
  _fail "could not extract the auto-start-off branch" "pattern not found"
else
  grep -q 'helixllm-mode.sh claude' <<<"$off_branch"
  assert_eq 0 $? "the off path prints the manual start command"
  grep -q 'CMA_HELIX_AUTOSTART=1' <<<"$off_branch"
  assert_eq 0 $? "the off path names the opt-in"
  grep -qE '_hl_warn' <<<"$off_branch"
  assert_eq 0 $? "it goes through the guarded emitter, not a bare cma_warn"
fi

summary
