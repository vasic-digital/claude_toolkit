#!/usr/bin/env bash
# test_jev_gate_placeholder_key.sh - a malformed LLMCTL_API_KEY in the process env (e.g. a 1-char placeholder exported by a
# shell profile) MUST be treated as ABSENT so the key-files fallback is consulted (llmctl's own contract:
# [A-Za-z0-9_-]{32,512}). RED before the fix: the placeholder is sent as the bearer and the gateway answers 401 (fail-open).
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
set +e
GATE="$SCRIPTS_DIR/jev-gate.sh"
export JEV_STATE_DIR="$HOME/.local/state/jev"
GOOD="Zk3_goodkey-0123456789abcdefghijklmnopqrstuv"   # 43 chars, fabricated test value
mkdir -p "$HOME/bin" "$HOME/.config/jev"
cat > "$HOME/bin/curl" <<'STUB'
#!/usr/bin/env bash
# records the Authorization header file content (arg after -H @file) and answers an allow
for a in "$@"; do case "$a" in @*) cat "${a#@}" >> "$STUB_HDR" 2>/dev/null;; esac; done
printf '{"answer":"allow","risky":0.1,"confidence":0.9}\n200'
STUB
chmod +x "$HOME/bin/curl"
printf 'LLMCTL_API_KEY=%s\n' "$GOOD" > "$HOME/llmctl.env"; chmod 600 "$HOME/llmctl.env"
HOOK='{"tool_name":"Bash","tool_input":{"command":"ls"}}'
run() { # run <LLMCTL_API_KEY value>
  : > "$HOME/hdr.txt"
  printf '%s' "$HOOK" | PATH="$HOME/bin:$PATH" STUB_HDR="$HOME/hdr.txt" LLMCTL_API_KEY="$1" CMA_JEV_KEY_FILES="$HOME/llmctl.env" \
    JEV_BASE_URL="https://127.0.0.1:9" JEV_KEY_VAR=LLMCTL_API_KEY JEV_MODE=shadow bash "$GATE" >/dev/null 2>&1
}
it "1-char placeholder env value is ignored; key-file key is the bearer"
run "x"
assert_file_contains "$HOME/hdr.txt" "Bearer $GOOD" "key-file key used"
it "short non-placeholder garbage is also ignored"
run "short-1234"
assert_file_contains "$HOME/hdr.txt" "Bearer $GOOD" "key-file key used (short value)"
it "a well-formed env value still wins over the key file"
OTHER="Env_wellformed-0123456789abcdefghijklmnopqrstu"
run "$OTHER"
assert_file_contains "$HOME/hdr.txt" "Bearer $OTHER" "env key wins when well-formed"
it "placeholder in the keys file (~/api_keys.sh) is ignored too; key-file key is the bearer"
printf 'export LLMCTL_API_KEY=x\n' > "$HOME/api_keys.sh"
: > "$HOME/hdr.txt"
printf '%s' "$HOOK" | PATH="$HOME/bin:$PATH" STUB_HDR="$HOME/hdr.txt" env -u LLMCTL_API_KEY CMA_KEYS_FILE="$HOME/api_keys.sh" CMA_JEV_KEY_FILES="$HOME/llmctl.env" \
  JEV_BASE_URL="https://127.0.0.1:9" JEV_KEY_VAR=LLMCTL_API_KEY JEV_MODE=shadow bash "$GATE" >/dev/null 2>&1
assert_file_contains "$HOME/hdr.txt" "Bearer $GOOD" "key-file key used (placeholder in keys file)"
it "env placeholder + valid key in the keys file: the keys file is consulted (precedence env > keys file)"
printf 'export LLMCTL_API_KEY=%s\n' "$GOOD" > "$HOME/api_keys.sh"
: > "$HOME/hdr.txt"
printf '%s' "$HOOK" | PATH="$HOME/bin:$PATH" STUB_HDR="$HOME/hdr.txt" LLMCTL_API_KEY=x CMA_KEYS_FILE="$HOME/api_keys.sh" CMA_JEV_KEY_FILES=/nonexistent \
  JEV_BASE_URL="https://127.0.0.1:9" JEV_KEY_VAR=LLMCTL_API_KEY JEV_MODE=shadow bash "$GATE" >/dev/null 2>&1
assert_file_contains "$HOME/hdr.txt" "Bearer $GOOD" "keys-file key used after env placeholder"
it "multi-line env value is rejected (no header injection)"
: > "$HOME/hdr.txt"
run "$(printf 'x\n%s' "$GOOD")"
assert_file_contains "$HOME/hdr.txt" "Bearer $GOOD" "key-file key used, injected line never sent"
if grep -q 'x$' "$HOME/hdr.txt" && [ "$(wc -l < "$HOME/hdr.txt")" -gt 1 ]; then _fail "multi-line value was sent" "$(wc -l < "$HOME/hdr.txt") lines"; else _pass "single header line sent"; fi
it "513-char value is rejected, 512-char accepted"
BIG512="$(head -c 512 /dev/zero | tr '\0' 'a')"; run "$BIG512"; assert_file_contains "$HOME/hdr.txt" "Bearer $BIG512" "512 accepted"
run "${BIG512}a"; assert_file_contains "$HOME/hdr.txt" "Bearer $GOOD" "513 rejected -> key file"
summary
