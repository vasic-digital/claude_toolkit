#!/usr/bin/env bash
# test_jev_env_stat_race.sh - a failed `stat -c %Y` must not poison the launch wrapper's arithmetic.
#
# Root cause (2026-10-27, captured with stderr of a failing run of test_kimi_alias_file.sh; 1 of 20 stress runs):
#   cma_jev_env read the cache mtime as
#       stat -c %Y "$cache" 2>/dev/null || stat -f %m "$cache" 2>/dev/null || echo 0
#   that is the GNU form, then the BSD form. On GNU coreutils `stat -f` is FILESYSTEM status, not a format flag.
#   When `-c %Y` fails because the cache does not exist YET (the function's own detached refresh creates it) and the
#   file appears before the fallback runs, `stat -f %m "$cache"` prints "File: ... ID: ... Namelen: ..." on STDOUT
#   (exit 1 because '%m' is read as a missing file operand), `echo 0` then appends "0", and
#   `[ $(( _jev_now - _jev_mtime )) -gt "$_jev_ttl" ]` dies with "syntax error in expression" (under `set -u`: "File: unbound
#   variable"). A failed expansion aborts
#   a non-interactive shell's current function: the launch wrapper (cma_run_kimi_provider, cma_run_provider, ...) returned
#   rc 1 and did not launch. The same shape sat in _cma_mtime, the provider-sync TTL check and cma_jq_edit's chmod mode.
# Fix: the value is validated as digits only (octal for the mode); anything else is "unknown" = stale / no chmod.
#
# This test makes the race deterministic: a `stat` shim on PATH fails the FIRST `-c` call exactly like an absent file and
# delegates everything else to the real stat, so the fallback runs against a file that now exists.
#   S1  control : the shim really reproduces the poisoned value (the unguarded expression yields non-digits)
#   S2  cma_jev_env returns 0 and still exports the cached endpoint (stale cache is used for this launch)
#   S3  _cma_mtime returns digits only under the same shim
#   S4  paired mutant: the guard line removed from a COPY of the rendered function -> S2 fails (rc != 0)
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }
REAL_STAT="$(command -v stat)"
case "$("$REAL_STAT" --version 2>&1 | head -1)" in
  *coreutils*) ;;
  *) echo "SKIP: GNU coreutils stat required (this is the GNU-side hazard of the BSD fallback)"; exit 0 ;;
esac
set +e
unset CMA_JEV_DISABLE CMA_JEV_QUIET JEV_BASE_URL TYPESAFE_BASE_URL JEV_KEY_VAR JEV_MODEL
trap 'cleanup_sandbox' EXIT

# shellcheck source=/dev/null
source "$SCRIPTS_DIR/lib.sh"
set +e   # lib.sh turns errexit on when sourced: the failure paths below must be REPORTED, not kill this test
PDIR="$HOME/.local/share/claude-multi-account/providers"; mkdir -p "$PDIR"
CACHE="$PDIR/jev-endpoints.json"
printf '%s\n' '{"endpoints":[{"base_url":"http://127.0.0.1:9/v1","key_var":"K","model":"m1","provider_id":"p1","ca_file":""}]}' > "$CACHE"

# The shim: the first `stat -c ...` fails like an absent file; every other call is the real stat.
SHIM="$HOME/shim"; mkdir -p "$SHIM"; STATE="$HOME/shimstate"; mkdir -p "$STATE"
cat > "$SHIM/stat" <<EOF
#!/bin/sh
if [ "\$1" = "-c" ] && [ ! -e "$STATE/failed-once" ]; then : > "$STATE/failed-once"; exit 1; fi
exec "$REAL_STAT" "\$@"
EOF
chmod +x "$SHIM/stat"
# keep the detached refresh that a stale cache kicks from reaching the real claude-providers
printf '#!/bin/sh\nexit 0\n' > "$SHIM/claude-providers"; chmod +x "$SHIM/claude-providers"
rearm() { rm -f "$STATE/failed-once"; }

it "S1 control: the shim reproduces the poisoned value on the UNGUARDED expression"
rearm
poisoned="$(PATH="$SHIM:$PATH" bash -c 'f="$1"; stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0' _ "$CACHE")"
case "$poisoned" in ''|*[!0-9]*) assert_eq "non-digits" "non-digits" "unguarded expression yields non-digit text under the race" ;;
  *) assert_eq "non-digits" "digits:$poisoned" "unguarded expression yields non-digit text under the race" ;; esac

it "S2 cma_jev_env survives the race (rc 0, cached endpoint still exported)"
eval "$(_cma_emit_cma_jev_env)"
rearm
out="$( PATH="$SHIM:$PATH" CMA_JEV_QUIET=1 bash -c 'source "$1"; eval "$(_cma_emit_cma_jev_env)"; cma_jev_env; rc=$?; echo "rc=$rc base=${JEV_BASE_URL:-} active=${CMA_JEV_ACTIVE:-}"' _ "$SCRIPTS_DIR/lib.sh" 2>"$HOME/s2.err" )"
assert_eq "rc=0 base=http://127.0.0.1:9/v1 active=1" "$out" "cma_jev_env under the race"
grep -q -E 'syntax error in expression|unbound variable' "$HOME/s2.err" && se=1 || se=0
assert_eq 0 "$se" "no arithmetic error on stderr ('syntax error in expression', or 'unbound variable' when nounset is on)"

it "S3 _cma_mtime returns digits only under the same race"
rearm
m="$(PATH="$SHIM:$PATH" bash -c 'source "$1"; _cma_mtime "$2"' _ "$SCRIPTS_DIR/lib.sh" "$CACHE")"
case "$m" in ''|*[!0-9]*) assert_eq "digits" "got:$m" "_cma_mtime result" ;; *) assert_eq "digits" "digits" "_cma_mtime result" ;; esac

it "S4 paired mutant: removing the guard from the rendered function is detected by S2"
MUT="$HOME/jev_env_mutant.sh"
python3 -I - "$SCRIPTS_DIR/lib.sh" "$MUT" <<'PY'
import sys
s = open(sys.argv[1]).read()
g = "  case \"$_jev_mtime\" in ''|*[!0-9]*) _jev_mtime=0 ;; esac\n"
assert g in s, "guard line not found in the emitted cma_jev_env"
open(sys.argv[2], "w").write(s.replace(g, "", 1))
PY
[[ -s "$MUT" ]] && built=1 || built=0
assert_eq 1 "$built" "mutant copy of lib.sh built (guard line removed)"
rearm
mout="$( PATH="$SHIM:$PATH" CMA_JEV_QUIET=1 bash -c 'source "$1"; eval "$(_cma_emit_cma_jev_env)"; cma_jev_env; rc=$?; echo "rc=$rc base=${JEV_BASE_URL:-} active=${CMA_JEV_ACTIVE:-}"' _ "$MUT" 2>"$HOME/s4.err" )"
[[ "$mout" == "rc=0 base=http://127.0.0.1:9/v1 active=1" ]] && killed=0 || killed=1
assert_eq 1 "$killed" "mutant (guard removed) does NOT pass the S2 check: killed (output: '${mout:-<none>}')"

summary
