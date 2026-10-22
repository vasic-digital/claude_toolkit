#!/usr/bin/env bash
# test_sync_usage_refresh.sh — hermetic test for _cma_usage_refresh_after_sync,
# the fail-soft hook that `cmd_sync`/`cmd_sync_multi` call so the usage reports
# `claude-usage report` writes under $SHARED_DIR/usage-reports/ are refreshed
# automatically on every sync, not only when the operator remembers to run
# `claude-usage report` by hand (operator directive: "CCUsage reports MUST BE
# always refreshed on demand, automatically and on every sync we do!").
#
# Unit-level (function-sourced, not a full `claude-providers sync`
# subprocess): a real sync needs a resolvable provider catalog/keys, which is
# unrelated to what this hook does. `CMA_USAGE_REFRESH_SCRIPT` is the same
# kind of override `CMA_PROVIDERS_VERIFY`/`CMA_PROVIDERS_SEMANTIC` already use
# to make a sibling script path test-substitutable.
#
# Cases:
#   A. default: the refresh script is invoked (marker touched)
#   B. CMA_SYNC_SKIP_USAGE_REFRESH=1 suppresses it entirely
#   C. missing/non-executable script: a clean skip, never a hard failure
#   D. refresh script exits non-zero: a warning, never propagated as a failure
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${CMA_TEST_SCRIPTS_DIR:-$(cd "$TESTS_DIR/.." && pwd)}"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
# shellcheck source=../claude-providers.sh
source "$SCRIPTS_DIR/claude-providers.sh"
set +e

MARKER="$HOME/usage-refresh.marker"
FAKE="$HOME/fake-claude-usage.sh"

it "CASE A: refresh script invoked by default (marker touched)"
cat > "$FAKE" <<EOF
#!/usr/bin/env bash
echo "called with: \$*" > "$MARKER"
exit 0
EOF
chmod +x "$FAKE"
rm -f "$MARKER"
unset CMA_SYNC_SKIP_USAGE_REFRESH
CMA_USAGE_REFRESH_SCRIPT="$FAKE" _cma_usage_refresh_after_sync
assert_file "$MARKER" "default sync invokes the usage-refresh script"
assert_eq "called with: report" "$(cat "$MARKER")" "invoked with the 'report' subcommand"

it "CASE B: CMA_SYNC_SKIP_USAGE_REFRESH=1 suppresses the refresh entirely"
rm -f "$MARKER"
CMA_SYNC_SKIP_USAGE_REFRESH=1 CMA_USAGE_REFRESH_SCRIPT="$FAKE" _cma_usage_refresh_after_sync
_exists=0; [[ -e "$MARKER" ]] && _exists=1
assert_eq 0 "$_exists" "skip flag prevents the refresh script from ever running"
unset CMA_SYNC_SKIP_USAGE_REFRESH

it "CASE C: missing/non-executable refresh script is a clean skip, not a failure"
rm -f "$MARKER"
_rc=0
CMA_USAGE_REFRESH_SCRIPT="$HOME/does-not-exist.sh" _cma_usage_refresh_after_sync; _rc=$?
assert_eq 0 "$_rc" "missing script never fails the caller (fail-soft, like _cma_jev_after_sync)"
_exists=0; [[ -e "$MARKER" ]] && _exists=1
assert_eq 0 "$_exists" "nothing was invoked"

it "CASE D: refresh script exits non-zero -> warning, still returns success"
cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAKE"
_rc=0
CMA_USAGE_REFRESH_SCRIPT="$FAKE" _cma_usage_refresh_after_sync 2>/dev/null; _rc=$?
assert_eq 0 "$_rc" "a failing refresh never fails the sync it ran inside"

summary
