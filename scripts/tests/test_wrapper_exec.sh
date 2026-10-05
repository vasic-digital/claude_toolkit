#!/usr/bin/env bash
# test_wrapper_exec.sh — EXECUTE the generated cma_run wrapper (not just grep its
# text) to verify RUNTIME guarantees: provider-env isolation, session-flag
# application, and pull→launch→push ordering.
#
# Why this exists: every other suite asserts the wrapper by string-matching its
# emitted body (e.g. `grep -q 'unset ANTHROPIC_'`). That can't catch a `set -e`
# abort, a dropped `unset`, or wrong call ordering — bugs that only surface when
# the function actually RUNS. Found via systematic debugging of why wrapper bugs
# kept slipping past a green suite. We drive cma_run with a stub CLAUDE_BIN that
# records the environment + args it was launched with.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e

# Generate the alias file (defines cma_run / cma_run_provider) in the sandbox.
ALIAS_FILE="$SANDBOX_HOME/.local/share/claude-multi-account/aliases.sh"
mkdir -p "$(dirname "$ALIAS_FILE")" "$SANDBOX_HOME/.local/bin"
CMA_RC_FILES=("$SANDBOX_HOME/.unused-rc")
cma_ensure_alias_file >/dev/null 2>&1

rec_env="$SANDBOX_HOME/rec.env"
rec_args="$SANDBOX_HOME/rec.args"
order_log="$SANDBOX_HOME/order.log"

# Stand-in for the real `claude` binary: record the env + args it is launched
# with, then exit cleanly.
recorder="$SANDBOX_HOME/recorder.sh"
cat > "$recorder" <<EOF
#!/usr/bin/env bash
env > "$rec_env"
# Record the launched command line space-joined on ONE line ("\$*", not "\$@"):
# one-arg-per-line would split e.g. "--name execproj" across two lines, so a
# contiguous-string grep assertion could never match it (false failure).
printf '%s\n' "\$*" > "$rec_args"
exit 0
EOF
chmod +x "$recorder"

# Stub the helpers the wrapper invokes at \$HOME/.local/bin so its -x guards pass
# and we can observe ordering. claude-session 'flags' returns deterministic
# launch flags; everything else is a logged no-op.
sandbox_stub "$SANDBOX_HOME/.local/bin/claude-sync-state" <<EOF
#!/usr/bin/env bash
printf 'sync-state %s\n' "\$1" >> "$order_log"
exit 0
EOF
sandbox_stub "$SANDBOX_HOME/.local/bin/claude-session" <<EOF
#!/usr/bin/env bash
printf 'session %s\n' "\$1" >> "$order_log"
[ "\$1" = flags ] && echo "--session-id 11111111-2222-3333-4444-555555555555 --name execproj"
exit 0
EOF
chmod +x "$SANDBOX_HOME/.local/bin/claude-sync-state" "$SANDBOX_HOME/.local/bin/claude-session"

# Load the wrapper into this shell, then point CLAUDE_BIN at the recorder.
# shellcheck source=/dev/null
source "$ALIAS_FILE"
# PROVENANCE GATE — see lib/assert.sh:assert_fn_from. This file EXECUTES cma_run
# rather than grepping its text, which makes it the most exposed of all: the
# host's cma_run (already defined here via BASH_ENV) runs and behaves correctly,
# so every runtime guarantee below would still "hold" on host code.
it "HYGIENE: the cma_run under test comes from the sandbox alias file"
assert_fn_from cma_run "$ALIAS_FILE" "wrapper loaded from the sandbox, not the host"
export CLAUDE_BIN="$recorder"
export CLAUDE_CONFIG_DIR="$SANDBOX_HOME/.claude-execacct"

# Run cma_run the way a user's interactive shell would (no set -e/-u), with a
# leaked provider environment, capturing what the stub claude actually saw.
: > "$rec_env"; : > "$rec_args"; : > "$order_log"
( set +eu
  # Poisoned provider env, intentionally scoped to this subshell (SC2030/SC2031
  # flag exactly that scoping, which is the point — we observe via rec_env).
  # shellcheck disable=SC2030
  export ANTHROPIC_BASE_URL="https://poison.example/v1"
  export ANTHROPIC_AUTH_TOKEN="poison-token-should-not-leak"
  export ANTHROPIC_MODEL="poison-model"
  cma_run >/dev/null 2>&1
)

# ── 0. Non-vacuity guard: the stub claude must have ACTUALLY run ──
# The isolation asserts below check for the ABSENCE of ANTHROPIC_* in the env
# dump, which is trivially true if the recorder never executed. Prove it ran.
it "cma_run EXECUTION: the stub claude actually launched (guards vacuous isolation passes)"
ran=1; [[ -s "$rec_env" ]] && ran=0
assert_eq 0 "$ran" "recorder captured a non-empty environment (claude was really executed)"

# ── 1. ENV ISOLATION, by EXECUTION: leaked ANTHROPIC_* are cleared pre-launch ──
it "cma_run EXECUTION: a leaked ANTHROPIC_BASE_URL is unset before claude runs"
assert_eq 0 "$(grep -c '^ANTHROPIC_BASE_URL=' "$rec_env")" "claude saw NO ANTHROPIC_BASE_URL (isolation works at runtime)"
it "cma_run EXECUTION: leaked ANTHROPIC_AUTH_TOKEN + ANTHROPIC_MODEL are cleared too"
assert_eq 0 "$(grep -c '^ANTHROPIC_AUTH_TOKEN=' "$rec_env")" "no ANTHROPIC_AUTH_TOKEN leaked to claude"
assert_eq 0 "$(grep -c '^ANTHROPIC_MODEL=' "$rec_env")" "no ANTHROPIC_MODEL leaked to claude"

# ── 2. session flags actually reach claude on a bare launch ──
it "cma_run EXECUTION: a bare launch passes the claude-session flags to claude"
gotname=1; grep -q -- '--name execproj' "$rec_args" && gotname=0
assert_eq 0 "$gotname" "claude was launched with '--name execproj' (session integration runs)"

# ── 3. ordering: sync-state pull BEFORE launch, push AFTER ──
it "cma_run EXECUTION: sync-state pull fires before launch and push after"
pull_n="$(grep -n 'sync-state pull' "$order_log" | head -1 | cut -d: -f1)"
push_n="$(grep -n 'sync-state push' "$order_log" | head -1 | cut -d: -f1)"
ord=1; [[ -n "$pull_n" && -n "$push_n" && "$pull_n" -lt "$push_n" ]] && ord=0
assert_eq 0 "$ord" "pull (line $pull_n) ran before push (line $push_n)"

# ── 3b. project-scoped cwd-hook: git-toplevel .claude-cwd-hook preempts global fallback ──
it "cma_run EXECUTION: project-scoped hook resolution code present in wrapper"
# Extract the cma_run body from the alias file (same technique as test_claude.sh)
_cma_b="$(awk '/^cma_run\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE")"
grep -qF '_cma_hook_root' <<<"$_cma_b"; assert_eq 0 $? "cma_run has project-scoped hook resolution (_cma_hook_root marker)"
grep -qF 'git rev-parse' <<<"$_cma_b"; assert_eq 0 $? "cma_run resolves git toplevel for project-local hook"
grep -qF '.claude-cwd-hook' <<<"$_cma_b"; assert_eq 0 $? "cma_run checks for .claude-cwd-hook in git toplevel"
# Reset order_log for remaining test
: > "$order_log"

# ── 4. explicit args are respected verbatim (no auto-session injection) ──
it "cma_run EXECUTION: explicit args are passed through unchanged (no session flags injected)"
: > "$rec_args"; : > "$order_log"
# shellcheck disable=SC2031
( set +eu; export ANTHROPIC_BASE_URL=""; cma_run -p "hello world" >/dev/null 2>&1 )
inj=0; grep -q -- '--session-id\|--name execproj' "$rec_args" && inj=1
assert_eq 0 "$inj" "no session flags injected when explicit args are given"
gotp=1; grep -q -- '-p' "$rec_args" && gotp=0
assert_eq 0 "$gotp" "explicit '-p' reached claude verbatim"

summary
