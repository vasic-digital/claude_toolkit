#!/usr/bin/env bash
# claude-install-verify.sh — post-install SELF-VERIFY: assert every component the
# toolkit declares as installed is actually USABLE, and fail loudly when it is not.
#
# Why this exists (field failure 2026-07-22, operator host, v1.25.4):
#   install.sh built the bundled Go router BEST-EFFORT (`if ! bash
#   claude-ccr-build.sh; then cma_warn ...`), so a build failure only WARNED,
#   the install continued, and the banner still printed "[done] installed".
#   The npm @musistudio/claude-code-router at ~/.local/bin/ccr then kept
#   answering for `ccr`, and the FIRST symptom the operator ever saw was a
#   provider alias dying at RUNTIME with:
#     "resolved ccr (...) is not the bundled claude-code-router ..."
#   An installer that prints [done] over a broken product is a §11.4 PASS-bluff
#   at the install layer. This script is the gate that makes that impossible.
#
# What it asserts (each check is a REAL probe of the real artifact — never a
# grep of our own source, §11.4.201: assert the real condition):
#   ccr        the STABLE identity the runtime actually resolves
#              ($CMA_CCR_BIN, else $HOME/.local/bin/ccr) exists, is executable,
#              and its --help carries the BUNDLED router's discriminator.
#   cma-proxy  when present it must execute; when absent it is reported as an
#              honest, named DEGRADED capability (never a silent fall-through).
#
# The ccr discriminator is `ccr restart` — NOT `ccr start`/`ccr serve`
# (§11.4.201(7)(a) match structure, not a substring a carrier also carries).
# Captured 2026-07-22 on this host:
#     npm  @musistudio ccr --help | grep -c 'ccr start'   -> 2
#     bundled Go       ccr --help | grep -c 'ccr start'   -> 1
#   => 'ccr start' matches BOTH: it cannot discriminate (control needle).
#     npm  @musistudio ccr --help | grep -c 'ccr restart' -> 0
#     bundled Go       ccr --help | grep -c 'ccr restart' -> 1
#   => 'ccr restart' discriminates. The npm router has no `restart` subcommand,
#      which is exactly why route-apply failed in the field.
#
# Usage:
#   claude-install-verify              # verify; exit 0 green, 1 on any FAIL
#   claude-install-verify --quiet      # only print FAIL/DEGRADED lines
#
# Exit codes:
#   0  every required component verified usable (DEGRADED optionals allowed)
#   1  at least one REQUIRED component is missing or unusable
#
# Env knobs:
#   CMA_CCR_BIN              override the router path (same knob cma_run_provider honours)
#   SHARED_DIR               where cma-proxy lives (default ~/.claude-shared)
#   CMA_VERIFY_PROBE_BUDGET  seconds before a silent probe (ccr --help, and
#                            each cma-proxy arm) is declared wedged and killed
#                            (default 15)
set -uo pipefail

_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _tgt="$(readlink "$_src")"
  case "$_tgt" in /*) _src="$_tgt" ;; *) _src="$(dirname "$_src")/$_tgt" ;; esac
done
LIB_DIR="$(cd "$(dirname "$_src")" && pwd)"
unset _src _tgt
# shellcheck source=lib.sh
source "$LIB_DIR/lib.sh"

QUIET=0
for a in "$@"; do
  case "$a" in
    --quiet) QUIET=1 ;;
    -h|--help) sed -n '2,47p' "$0"; exit 0 ;;
  esac
done

_fails=0
_degraded=0

# Every binary probe below (ccr --help, both cma-proxy arms) runs through
# lib.sh's cma_probe_run/cma_probe_help: bounded on EVERY host by its own
# watchdog (returns 124 on a kill, like coreutils timeout). The previous local
# probe was bounded only where coreutils `timeout` existed — its fallback
# branch (macOS without coreutils) ran the binary UNBOUNDED, so a wedged router
# hung the install forever (review finding I1, 2026-07-22); the cma-proxy check
# was the same class unbounded until review residual (b), 2026-07-23.
_PROBE_BUDGET="${CMA_VERIFY_PROBE_BUDGET:-15}"

_ok()   { (( QUIET )) || printf '  [ok]       %s\n' "$1"; }
_degr() { printf '  [DEGRADED] %s\n' "$1" >&2; _degraded=$((_degraded + 1)); }
_fail() { printf '  [FAIL]     %s\n' "$1" >&2; _fails=$((_fails + 1)); }

(( QUIET )) || printf '\n[verify] claude-multi-account install self-verify\n'

# --- 1. ccr: the bundled Go claude-code-router, resolved the way the RUNTIME
#        resolves it (stable install identity first, PATH only as last resort,
#        like cma_run_provider) with ONE deliberate difference: the runtime
#        falls through to PATH whenever the stable path is not executable,
#        because at launch time surviving on a PATH router beats not launching;
#        verify instead HOLDS a stable path that exists-but-cannot-run and
#        fails on it (review M1) — at install time, a broken bundled artifact
#        must be surfaced and fixed, not masked by whatever PATH happens to
#        offer. When the stable path is healthy the two resolve identically,
#        so a green here still means the alias resolves the same binary.
_ccr="${CMA_CCR_BIN:-$HOME/.local/bin/ccr}"
_ccr_src="stable install path"
if [ ! -e "$_ccr" ] && [ ! -L "$_ccr" ]; then
  # Truly ABSENT at the stable path (not merely broken) — only then consult
  # PATH. A stable path that EXISTS but cannot run (dangling symlink after a
  # deleted build, a chmod-less copy) must be diagnosed AS ITSELF below —
  # falling through to PATH would trade the actually-broken install artifact
  # for whatever unrelated ccr PATH happens to hold (review M1: this is what
  # made the 'not executable' branch unreachable).
  _ccr="$(command -v ccr 2>/dev/null || true)"
  _ccr_src="PATH fallback"
fi

if [ -z "$_ccr" ]; then
  _fail "ccr: no router found at \$HOME/.local/bin/ccr nor on PATH.
             Provider aliases using the router transport CANNOT launch.
             Fix: ensure a Go toolchain new enough for submodules/claude-code-router/go.mod
             (install/upgrade Go: https://go.dev/dl/ — or, with an older Go already
             installed and network access: GOTOOLCHAIN=auto claude-ccr-build),
             then run: claude-ccr-build"
elif [ ! -x "$_ccr" ]; then
  _fail "ccr: '$_ccr' exists but is not executable (dangling symlink or bad build).
             Fix: claude-ccr-build"
else
  # rc captured, not discarded (review M2): a binary the watchdog had to KILL
  # is a different defect (wedged/hung) than one that answered with the wrong
  # grammar, and conflating them sent operators chasing the wrong fix.
  # NOTE (I2 -> HEL-009): hardening the RUNTIME gate against an npm
  # doppelganger swapped in AFTER install is tracked as HEL-009 — deliberately
  # not re-attempted here (it regressed 5 tests last time; §11.4.120).
  _hrc=0; _help="$(cma_probe_help "$_ccr" "$_PROBE_BUDGET")" || _hrc=$?
  if [ "$_hrc" -eq 124 ]; then
    _fail "ccr: '$_ccr' did not answer --help within ${_PROBE_BUDGET}s — killed by the probe watchdog.
             A WEDGED/hanging router binary, not a grammar mismatch.
             Fix: claude-ccr-build   (rebuilding replaces the wedged binary)"
  else
    case "$_help" in
      *"ccr restart"*)
        _ok "ccr: bundled Go router verified via $_ccr_src ($_ccr)"
        ;;
      *"ccr start"*|*"ccr serve"*)
        # Router-shaped, but NOT ours: this is the npm @musistudio doppelganger
        # (no `restart`). It passes the legacy start/serve fingerprint and then
        # fails every route-apply at runtime. This is the EXACT field failure.
        _fail "ccr: '$_ccr' is a router but NOT the bundled Go claude-code-router
             (no 'ccr restart' subcommand — this is the npm @musistudio build).
             Every route-apply will fail at runtime.
             Fix: claude-ccr-build   (it backs up and replaces \$HOME/.local/bin/ccr)
             If an EARLIER PATH entry still shadows it, remove that ccr:
               npm rm -g @musistudio/claude-code-router"
        ;;
      *)
        _fail "ccr: '$_ccr' is not a claude-code-router at all (--help showed no router commands; probe rc=$_hrc).
             Fix: claude-ccr-build"
        ;;
    esac
  fi
fi

# --- 2. cma-proxy: OPTIONAL capability. Absent is allowed, but it MUST be
#        reported by name — the runtime used to skip its shims in silence
#        (§11.4.69 honest SKIP-with-reason, never a silent pass).
_proxy_bin="${SHARED_DIR:-$HOME/.claude-shared}/proxy/cma-proxy"
if [ -x "$_proxy_bin" ]; then
  # BOUNDED (review residual (b), 2026-07-23): both probe arms run under the
  # same watchdog as the ccr probe above — a WEDGED proxy binary is the same
  # hang class at the same install seam and must not stall the install.
  # --has-transform is the arm the REAL binary answers with exit 0 (measured
  # on both the worktree-built and installed binaries, re-review 2026-07-23);
  # its --help ALSO exits 0 — Go stdlib flag exits 0 on ErrHelp, 2 is the
  # parse-ERROR path — so --help is a generosity fallback that genuinely
  # rescues a Go-flag binary lacking the has-transform grammar. A 124 on
  # either arm is a HANG, reported as one (the M2 discipline) — never
  # conflated with "does not execute".
  _prc=0; cma_probe_run "$_PROBE_BUDGET" "$_proxy_bin" --has-transform helixagent >/dev/null || _prc=$?
  if [ "$_prc" -ne 0 ] && [ "$_prc" -ne 124 ]; then
    _prc=0; cma_probe_help "$_proxy_bin" "$_PROBE_BUDGET" >/dev/null || _prc=$?
  fi
  if [ "$_prc" -eq 0 ]; then
    _ok "cma-proxy: compatibility proxy verified ($_proxy_bin)"
  elif [ "$_prc" -eq 124 ]; then
    _fail "cma-proxy: '$_proxy_bin' did not answer within ${_PROBE_BUDGET}s — killed by the probe watchdog.
             A WEDGED/hanging proxy binary, not a grammar mismatch.
             Fix: claude-proxy-build   (rebuilding replaces the wedged binary)"
  else
    _fail "cma-proxy: '$_proxy_bin' exists but does not execute (probe rc=$_prc).
             Fix: claude-proxy-build"
  fi
else
  _degr "cma-proxy: NOT installed ($_proxy_bin).
             helixagent/poe/kimi/sarvam aliases run WITHOUT their compat shims
             (Hermes tool-call recovery + request-schema fixes are inactive).
             Fix: claude-proxy-build   (needs the Go toolchain)"
fi

# --- verdict -----------------------------------------------------------------
if (( _fails > 0 )); then
  printf '\n[verify] FAILED — %d required component(s) unusable, %d degraded.\n' \
    "$_fails" "$_degraded" >&2
  printf '[verify] The install is NOT complete. Fix the items above and re-run:\n' >&2
  printf '           claude-install-verify\n' >&2
  exit 1
fi

if (( _degraded > 0 )); then
  printf '\n[verify] OK with %d degraded optional component(s) — see above.\n' "$_degraded"
else
  (( QUIET )) || printf '\n[verify] OK — all components verified usable.\n'
fi
exit 0
