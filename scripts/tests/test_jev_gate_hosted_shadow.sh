#!/usr/bin/env bash
# test_jev_gate_hosted_shadow.sh - a HOSTED Jev endpoint (host not loopback / RFC1918 / link-local / *.local / *.lan) must
# NEVER enforce: JEV_MODE=enforce is clamped to shadow, a "deny" answer never blocks (exit 0, no deny JSON), and the
# decision log records mode=shadow. A LOCAL endpoint still enforces. JEV_GATE=off is still respected (pass-through).
# RED before the fix: hosted + enforce + deny exits 2.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
set +e
GATE="$SCRIPTS_DIR/jev-gate.sh"
export JEV_STATE_DIR="$HOME/.local/state/jev"
GOOD="Zk3_goodkey-0123456789abcdefghijklmnopqrstuv"   # fabricated test value
mkdir -p "$HOME/bin" "$HOME/.config/jev"
cat > "$HOME/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '{"answers":{"gate":{"type":"choice","choice":"deny","confidence":0.99},"risky":{"type":"noul","noul":0.95}}}\n200'
STUB
chmod +x "$HOME/bin/curl"
printf 'LLMCTL_API_KEY=%s\n' "$GOOD" > "$HOME/llmctl.env"; chmod 600 "$HOME/llmctl.env"
HOOK='{"tool_name":"Bash","tool_input":{"command":"ls"}}'
run() { # run <base_url> [extra env assignments...] ; sets OUT, RC
  rm -f "$JEV_STATE_DIR/decisions.jsonl"
  local url="$1" org; shift
  org="$(printf '%s' "$url" | sed -E 's#^(https://[^/?\#]+).*#\1#')"
  OUT=$(printf '%s' "$HOOK" | env PATH="$HOME/bin:$PATH" CMA_JEV_KEY_FILES="$HOME/llmctl.env" JEV_BASE_URL="$url" CMA_JEV_TRUSTED_ORIGINS="$org=LLMCTL_API_KEY" \
    JEV_KEY_VAR=LLMCTL_API_KEY JEV_MODE=enforce "$@" bash "$GATE" 2>/dev/null)
  RC=$?
}
lastmode() { tail -n1 "$JEV_STATE_DIR/decisions.jsonl" 2>/dev/null | jq -r '.mode // "none"' 2>/dev/null; }
lastans() { tail -n1 "$JEV_STATE_DIR/decisions.jsonl" 2>/dev/null | jq -r '.answer // "none"' 2>/dev/null; }

it "local endpoint (127.0.0.1) + enforce + deny blocks (exit 2)"
run "https://127.0.0.1:9"
assert_eq 2 "$RC" "local enforce deny exits 2"
it "RFC1918 / .local / .lan endpoints are local and still enforce"
for u in "https://10.1.2.3:9" "https://192.168.1.5:9" "https://172.20.0.9:9" "https://thinker.local:9" "https://box.lan:9" "https://localhost:9"; do
  run "$u"; assert_eq 2 "$RC" "enforces for $u"
done
it "hosted endpoint + enforce + deny does NOT block (exit 0), log says shadow"
for u in "https://api.example.com" "https://llmctl.example.org:8443/v1" "https://8.8.8.8:9" "https://172.32.0.1:9"; do
  run "$u"
  assert_eq 0 "$RC" "hosted never blocks: $u"
  case "$OUT" in *'"permissionDecision":"deny"'*) _fail "deny JSON emitted for $u" "$OUT" ;; *) _pass "no deny JSON for $u" ;; esac
  assert_eq shadow "$(lastmode)" "log mode shadow for $u"
  assert_eq deny "$(lastans)" "answer still recorded (shadow) for $u"
done
it "hosted + userinfo/uppercase host spoof does not count as local"
run "https://127.0.0.1.example.com:9"; assert_eq 0 "$RC" "127.0.0.1.example.com is hosted"
run "https://user@api.example.com:9"; assert_eq 0 "$RC" "userinfo hosted"
run "https://127.0.0.1:9@evil.example.com"; assert_eq 0 "$RC" "loopback-looking userinfo is hosted"
run "https://localhost:9@evil.example.com"; assert_eq 0 "$RC" "localhost userinfo is hosted"
assert_eq shadow "$(lastmode)" "userinfo spoof clamped to shadow"
it "plain-http userinfo spoof of a loopback host is hosted (shadow), plain-http loopback enforces"
run "http://127.0.0.1:9@evil.example.com"; assert_eq 0 "$RC" "http userinfo spoof does not block"
run "http://127.0.0.1:9"; assert_eq 2 "$RC" "plain-http loopback still enforces"
it "JEV_GATE=off is still respected for hosted and local (pass-through, exit 0)"
run "https://api.example.com" JEV_GATE=off; assert_eq 0 "$RC" "hosted off"
run "https://127.0.0.1:9" JEV_GATE=off; assert_eq 0 "$RC" "local off"

# --- the opencode plugin follows the same rule (it enforces by throwing) -------------------------------------------------
if command -v node >/dev/null 2>&1; then
  mkdir -p "$HOME/plughome" "$HOME/plugstate"
  plug() { # plug <base_url> [env...] -> "blocked=<bool> mode=<mode>"
    local url="$1" org R; shift
    org="$(printf '%s' "$url" | sed -E 's#^(https://[^/?\#]+).*#\1#')"
    rm -f "$HOME/plugstate/decisions.jsonl"
    R="$(env -i HOME="$HOME/plughome" PATH="$PATH" JEV_TEST_SCRATCH_HOME="$HOME/plughome" JEV_TEST_DUMMY="$GOOD" JEV_STATE_DIR="$HOME/plugstate" \
      JEV_TEST_CHOICE=deny JEV_MODE=enforce JEV_BASE_URL="$url" JEV_KEY_VAR=LLMCTL_API_KEY CMA_KEYS_FILE="$HOME/no-such-keys.sh" \
      CMA_JEV_KEY_FILES="$HOME/llmctl.env" JEV_CONFIG_DIR=/nonexistent/jev CMA_JEV_TRUSTED_ORIGINS="$org=LLMCTL_API_KEY" "$@" \
      node "$TESTS_DIR/jev_plugin_origin_test.mjs" 2>&1 | tail -n1)"
    printf 'blocked=%s mode=%s' "$(jq -r '.blocked' <<<"$R" 2>/dev/null)" "$(jq -r '.log.mode // "none"' <<<"$R" 2>/dev/null)"
  }
  it "plugin: local endpoints enforce (deny blocks), hosted endpoints are clamped to shadow"
  for u in "https://127.0.0.1:9" "https://10.1.2.3:9" "https://192.168.1.5:9" "https://172.20.0.9:9" "https://thinker.local:9" "https://localhost:9"; do
    assert_eq "blocked=true mode=enforce" "$(plug "$u")" "plugin local enforces: $u"
  done
  for u in "https://api.example.com" "https://8.8.8.8:9" "https://172.32.0.1:9" "https://127.0.0.1.example.com:9"; do
    assert_eq "blocked=false mode=shadow" "$(plug "$u")" "plugin hosted shadow: $u"
  done
  it "plugin: plain-http userinfo spoof of a loopback host is hosted (shadow)"
  assert_eq "blocked=false mode=shadow" "$(plug "http://127.0.0.1:9@evil.example.com")" "plugin http userinfo spoof"
  assert_eq "blocked=true mode=enforce" "$(plug "http://127.0.0.1:9")" "plugin plain-http loopback enforces"
  it "plugin: JEV_GATE=off is respected"
  assert_eq "blocked=false mode=none" "$(plug "https://127.0.0.1:9" JEV_GATE=off)" "plugin off (local)"
else
  _pass "node not installed - plugin scenarios SKIPPED (honest skip)"
fi
summary
