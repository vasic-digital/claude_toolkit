#!/usr/bin/env bash
# test_sandbox_hermetic_jev.sh - make_sandbox must scrub the CALLER's Jev / decision-endpoint environment, so no suite's verdict depends on
# the developer shell (this host exports JEV_BASE_URL, JEV_KEY_VAR, LLMCTL_API_KEY, TYPESAFE_API_KEY, CMA_JEV_* ...). The two suites that
# resolve endpoint/key (test_jev_detect_https.sh and its mutation harness) get this through make_sandbox. A non-Jev variable is NOT scrubbed.
# SANDBOX_LIB overrides the library under test (mutation harness). All values are fabricated.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
LIB="${SANDBOX_LIB:-$TESTS_DIR/lib/sandbox.sh}"
probe() { # probe <VAR> -> "set" | "unset" inside a fresh make_sandbox
  env JEV_BASE_URL=http://x JEV_KEY_VAR=K JEV_MODE=enforce JEV_MODEL=m JEV_API_KEY=a CMA_JEV_ENDPOINT_ID=e CMA_JEV_ACTIVE=1 \
      LLMCTL_API_KEY=short TYPESAFE_API_KEY=t TYPESAFE_BASE_URL=http://y UNRELATED_KEEP=1 \
      bash -c 'source "$1"; make_sandbox >/dev/null 2>&1; if [ -n "${!2+x}" ]; then echo set; else echo unset; fi' _ "$LIB" "$1"
}
it "every ambient Jev / decision-endpoint variable is scrubbed by make_sandbox"
for v in JEV_BASE_URL JEV_KEY_VAR JEV_MODE JEV_MODEL JEV_API_KEY CMA_JEV_ENDPOINT_ID CMA_JEV_ACTIVE LLMCTL_API_KEY TYPESAFE_API_KEY TYPESAFE_BASE_URL; do
  assert_eq unset "$(probe "$v")" "$v scrubbed"
done
it "an unrelated variable is left alone (no over-scrub)"
assert_eq set "$(probe UNRELATED_KEEP)" "UNRELATED_KEEP kept"
summary
