#!/usr/bin/env bash
# Runtime test of the emitted cma_run org-guard wiring (not a grep): the real
# function body is extracted from lib.sh and run against stub claude-session
# binaries and a fake claude. Covers: guard failing / missing subcommand
# (older installed binary) => original flags launch; guard replacing the
# flags => the replacement reaches claude; and the mutation that removes the
# fallback is killed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/assert.sh"
source "$HERE/lib/sandbox.sh"
make_sandbox
set +e
LIB="$HERE/../lib.sh"
SID=11111111-2222-4333-8444-555555555555
NSID=99999999-2222-4333-8444-555555555555
mkdir -p "$HOME/.local/bin" "$HOME/cfg" "$HOME/w"
OUT="$HOME/claude.args"
cat > "$HOME/fakeclaude" <<FC
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$OUT"
FC
chmod +x "$HOME/fakeclaude"
stub() { # <org-guard body>
  sandbox_stub "$HOME/.local/bin/claude-session" <<ST
#!/usr/bin/env bash
case "\$1" in
  flags) echo "--resume $SID --name w";;
  hint|apply-color) exit 0;;
  org-guard) $1;;
  *) exit 0;;
esac
ST
  chmod +x "$HOME/.local/bin/claude-session"
}
body() { sed -n '/^cma_run() {/,/^}/p' "$1"; }
body "$LIB" > "$HOME/cma_run_body.sh"
cma_jev_env() { :; }
source "$HOME/cma_run_body.sh"
it "HYGIENE: the cma_run under test is the body extracted from lib.sh"
assert_fn_from cma_run "$HOME/cma_run_body.sh" "wrapper loaded from the extracted lib.sh body"
runit() { # <lib file>
  rm -f "$OUT"
  ( cd "$HOME/w"
    cma_jev_env() { :; }
    source <(body "$1")
    export HOME CLAUDE_CONFIG_DIR="$HOME/cfg" CLAUDE_BIN="$HOME/fakeclaude"
    cma_run ) >/dev/null 2>&1
  cat "$OUT" 2>/dev/null
}
it "org-guard failing => original flags still launch"
stub 'exit 1'
assert_eq "--resume $SID --name w" "$(runit "$LIB")" "fallback to original flags"
it "older installed claude-session without org-guard (usage, rc 2) => original flags"
stub 'echo usage >&2; exit 2'
assert_eq "--resume $SID --name w" "$(runit "$LIB")" "version skew tolerated"
it "org-guard printing a replacement => claude receives the new session id"
stub "echo '--resume $NSID --name w'"
assert_eq "--resume $NSID --name w" "$(runit "$LIB")" "sanitized sid reaches launcher"
it "org-guard exiting 0 with EMPTY output => original flags (never wiped)"
stub 'exit 0'
assert_eq "--resume $SID --name w" "$(runit "$LIB")" "empty answer keeps flags"
it "mutation: trusting an empty/failed guard answer is detected"
sed 's/if \[ -n "\$_cma_sg" \]; then/if true; then/' "$LIB" > "$HOME/lib_mut.sh"
cmp -s "$LIB" "$HOME/lib_mut.sh" && _fail "mutation did not apply"
stub 'exit 1'
got="$(runit "$HOME/lib_mut.sh")"
[ "$got" != "--resume $SID --name w" ]; assert_eq 0 $? "no-fallback variant fails the launch test"
summary
