#!/usr/bin/env bash
# test_add_account_tmux_notice.sh — ATM-850 remediation guard (2026-07-23).
#
# The dispatcher (test_dynamic_account_dispatch.sh) closes the staleness class
# STRUCTURALLY for every shell that sourced a dispatcher-bearing alias file.
# This test guards the OPERATOR-FACING half: claude-add-account must DETECT
# running tmux servers (the canonical long-lived stale shells — SSH re-login
# re-attaches the SAME server, so "log out and back in" fixes nothing), say
# exactly which shells are covered by the dispatcher vs which need ONE
# re-source, print the EXACT re-source + per-server broadcast commands, and
# NEVER send keys into any pane autonomously (an unrequested send-keys could
# type into a pane the operator is mid-edit in — forbidden).
#
# RED (pre-fix): cma_tmux_stale_shell_notice does not exist and
# claude-add-account.sh never mentions tmux -> FAIL.
# Paired §1.1 mutation: remove the cma_tmux_stale_shell_notice call from
# claude-add-account.sh (or the function from lib.sh) -> this test FAILs.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# Volatile run output (D1): written to a temp file beside the final path and
# renamed into the git-ignored proof/volatile/ folder only on completion.
# shellcheck source=lib/proof.sh
source "$TESTS_DIR/lib/proof.sh"
PROOF_DIR="$(cma_proof_volatile_dir)"
PROOF_FINAL="$PROOF_DIR/95-add-account-tmux-notice.txt"
PROOF="$(cma_proof_open "$PROOF_FINAL")"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
make_account acct1 >/dev/null
# shellcheck disable=SC2119
run_unify >/dev/null 2>&1
[[ -f "$ALIAS_FILE" ]] || { echo "FATAL: no alias file rendered" >&2; exit 1; }

# --- fake tmux world -------------------------------------------------------
# One fake server socket; a stub tmux that reports three panes (bash, nvim,
# zsh) and RECORDS every send-keys invocation — the no-autonomous-send proof.
export TMUX_TMPDIR="$SANDBOX_HOME/tmuxtmp"
FAKE_SOCK_DIR="$TMUX_TMPDIR/tmux-$(id -u)"
mkdir -p "$FAKE_SOCK_DIR"
python3 - "$FAKE_SOCK_DIR/default" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
PY
STUB_DIR="$SANDBOX_HOME/stubbin"
mkdir -p "$STUB_DIR"
SENDLOG="$SANDBOX_HOME/send-keys.log"
cat > "$STUB_DIR/tmux" <<STUB
#!/usr/bin/env bash
# stub tmux: -S <sock> <cmd> ...
sock=""
if [[ "\${1:-}" == -S ]]; then sock="\$2"; shift 2; fi
case "\${1:-}" in
  list-panes)
    # format '#{pane_current_command}' or '#{pane_id} #{pane_current_command}'
    case "\$*" in
      *'#{pane_id}'*) printf '%%1 bash\n%%2 nvim\n%%3 zsh\n' ;;
      *)              printf 'bash\nnvim\nzsh\n' ;;
    esac ;;
  send-keys)
    printf 'send-keys sock=%s args=%s\n' "\$sock" "\$*" >> "$SENDLOG" ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/tmux"
export PATH="$STUB_DIR:$PATH"

# --- exercise the notice ---------------------------------------------------
it "notice function exists and reports the tmux reality"
NOTICE_OUT="$SANDBOX_HOME/notice.out"
(
  set +u
  # shellcheck disable=SC1091
  source "$SCRIPTS_DIR/lib.sh" >/dev/null 2>&1
  declare -f cma_tmux_stale_shell_notice >/dev/null || exit 97
  cma_tmux_stale_shell_notice "$ALIAS_FILE"
) > "$NOTICE_OUT" 2>&1
assert_eq 0 $? "cma_tmux_stale_shell_notice exists in lib.sh and exits 0 (97 = function absent — the RED state)"
grep -q "$FAKE_SOCK_DIR/default" "$NOTICE_OUT"
assert_eq 0 $? "notice names the detected tmux server socket path"
grep -q "source $ALIAS_FILE" "$NOTICE_OUT"
assert_eq 0 $? "notice prints the exact re-source command"
grep -q 'send-keys' "$NOTICE_OUT"
assert_eq 0 $? "notice prints a per-server broadcast command (send-keys) for the operator"
grep -Eq '2 shell pane' "$NOTICE_OUT"
assert_eq 0 $? "notice counts ONLY shell panes (bash+zsh, nvim excluded)"

it "dispatcher-aware wording: covered shells are told they need nothing"
grep -q '_cma_cnf_impl' "$ALIAS_FILE"
assert_eq 0 $? "sandbox alias file carries the dispatcher (precondition)"
grep -qi 'no re-source needed' "$NOTICE_OUT"
assert_eq 0 $? "notice states dispatcher-covered shells need NO re-source"

it "the notice never sends keys autonomously"
[[ ! -s "$SENDLOG" ]]
assert_eq 0 $? "stub send-keys log is empty (print-only; broadcast is operator-confirmed elsewhere)"

it "claude-add-account is wired to the notice (non-interactive: no sends)"
grep -q 'cma_tmux_stale_shell_notice' "$SCRIPTS_DIR/claude-add-account.sh"
assert_eq 0 $? "claude-add-account.sh calls cma_tmux_stale_shell_notice"
ADD_OUT="$SANDBOX_HOME/add.out"
"$SCRIPTS_DIR/claude-add-account.sh" --yes --alias tmuxprobe > "$ADD_OUT" 2>&1
assert_eq 0 $? "add-account --yes succeeds with the notice wired in"
grep -q 'tmux' "$ADD_OUT"
assert_eq 0 $? "add-account output surfaces the tmux notice"
[[ ! -s "$SENDLOG" ]]
assert_eq 0 $? "non-interactive add-account performed NO send-keys (offer is prompt-gated, default No)"

{ echo; echo "=== result: pass=$TESTS_PASSED fail=$TESTS_FAILED ==="; } >> "$PROOF"
cma_proof_commit "$PROOF" "$PROOF_FINAL"
summary
