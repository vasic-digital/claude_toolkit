#!/usr/bin/env bash
# test_jev_installed_gate.sh - round-4 B1: the INSTALLED copy of the gate (the one
# the Claude and Kimi hooks actually run) must behave exactly like the repo copy.
# It reads the shipped pins from providers/jev.json next to itself, so jev-setup
# must install that file beside the gate. Drives the real jev-setup, then the
# installed gate with a PATH-shim curl (no network, dummy keys built from fragments).
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${CMA_TEST_SCRIPTS_DIR:-$(cd "$TESTS_DIR/.." && pwd)}"
export SCRIPTS_DIR
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
trap cleanup_sandbox EXIT
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }
set +e
unset JEV_MODE JEV_STATE_DIR JEV_BASE_URL JEV_API_KEY JEV_CA_FILE JEV_GATE JEV_SETUP_CONSENT TYPESAFE_API_KEY LLMCTL_API_KEY

DUMMY="dum""my-k""ey-$$-0123456789"
mkdir -p "$HOME/.claude-acct1" "$SHARED_DIR"
echo '{"model":"opus"}' > "$HOME/.claude-acct1/settings.json"
bash "$SCRIPTS_DIR/jev-setup.sh" --quiet --yes --agents claude >"$HOME/.out" 2>&1
INST="$HOME/.local/share/claude-multi-account/jev/jev-gate.sh"
SHAREDG="$SHARED_DIR/jev/jev-gate.sh"

SHIM="$HOME/shim"; mkdir -p "$SHIM"
printf '%s\n' '#!/usr/bin/env bash' \
  'log="${SHIM_LOG:?}"; prev=""' \
  'for a in "$@"; do' \
  '  if [[ "$prev" == "-H" && "$a" == @* ]]; then cat "${a#@}" >> "$log.hdr" 2>/dev/null; fi' \
  '  case "$a" in http://*|https://*) printf "%s\n" "$a" >> "$log.url" ;; esac' \
  '  prev="$a"' \
  'done' 'exit 7' > "$SHIM/curl"
chmod +x "$SHIM/curl"
shim_reset() { rm -f "$HOME/shim.log.hdr" "$HOME/shim.log.url"; }
shim_urls() { cat "$HOME/shim.log.url" 2>/dev/null | wc -l | tr -d ' '; }
shim_keyseen() { grep -q "$DUMMY" "$HOME/shim.log.hdr" 2>/dev/null && echo yes || echo no; }
export JEV_STATE_DIR="$HOME/.local/state/jev-inst"
HOOK='{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
rungate() { # rungate <gate> <env...>
  local g="$1"; shift
  printf '%s' "$HOOK" | env -u JEV_API_KEY -u TYPESAFE_API_KEY -u JEV_KEY_VAR -u CMA_JEV_TRUSTED_ORIGINS -u LLMCTL_API_KEY \
    -u OPENROUTER_API_KEY -u CMA_PROVIDERS_DIR -u CMA_JEV_PINS_FILE CMA_KEYS_FILE="$HOME/no-such-keys.sh" \
    PATH="$SHIM:$PATH" SHIM_LOG="$HOME/shim.log" JEV_MODE=shadow "$@" bash "$g" >/dev/null 2>&1
}
lastfb() { tail -n1 "$JEV_STATE_DIR/decisions.jsonl" 2>/dev/null | jq -r '.fallback // "none"'; }

for G in "$INST" "$SHAREDG"; do
  it "B1: installed gate [${G#$HOME/}] accepts a shipped pin + its key variable"
  assert_file "$G" "gate installed"
  assert_file "$(dirname "$G")/providers/jev.json" "shipped pins installed beside the gate"
  shim_reset
  rungate "$G" JEV_BASE_URL="https://api.typesafe.ai" JEV_KEY_VAR=TYPESAFE_API_KEY TYPESAFE_API_KEY="$DUMMY"
  assert_eq "1" "$(shim_urls)" "installed gate: shipped pin -> one request"
  assert_eq "yes" "$(shim_keyseen)" "installed gate: shipped pin -> key sent"
  shim_reset
  rungate "$G" JEV_BASE_URL="https://openrouter.ai/api" JEV_KEY_VAR=OPENROUTER_API_KEY OPENROUTER_API_KEY="$DUMMY"
  assert_eq "yes" "$(shim_keyseen)" "installed gate: shipped OpenRouter pin -> key sent"
  it "B1: installed gate [${G#$HOME/}] still refuses an unpinned origin"
  shim_reset
  rungate "$G" JEV_BASE_URL="https://evil.example.invalid" JEV_KEY_VAR=TYPESAFE_API_KEY TYPESAFE_API_KEY="$DUMMY"
  assert_eq "0" "$(shim_urls)" "installed gate: unpinned origin -> zero requests"
  assert_eq "key_unpinned" "$(lastfb)" "installed gate: unpinned origin -> key_unpinned"
  shim_reset
  rungate "$G" JEV_BASE_URL="https://api.typesafe.ai" JEV_KEY_VAR=OPENROUTER_API_KEY OPENROUTER_API_KEY="$DUMMY"
  assert_eq "0" "$(shim_urls)" "installed gate: shipped origin with the other slot's key variable -> refused"
done

it "B1: an upgrade refreshes the installed pins (stale copy replaced)"
printf '{"hosted":{}}\n' > "$(dirname "$INST")/providers/jev.json"
bash "$SCRIPTS_DIR/jev-setup.sh" --quiet --yes --agents claude >"$HOME/.out" 2>&1
assert_eq "$(jq -S . "$SCRIPTS_DIR/providers/jev.json")" "$(jq -S . "$(dirname "$INST")/providers/jev.json")" "installed pins equal the shipped pins after re-run"

summary
