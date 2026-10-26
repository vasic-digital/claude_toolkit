#!/usr/bin/env bash
# test_jev_probe_http_nokey.sh - round-4 M1: the hosted live probe in
# claude-providers.sh must follow rule 1 of docs/jev/Jev_Key_Send_Paths.md: over
# plain http NO key is sent (a local user could bind the port). https loopback
# keeps the key. curl is a shell function that records whether the header file
# it is handed contains the dummy key; no network, no real key.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
trap cleanup_sandbox EXIT
set +e
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }
DUMMY="dum""my-k""ey-$$-0123456789"
KEYS="$HOME/api_keys.sh"
printf "export TYPESAFE_API_KEY='%s'\n" "$DUMMY" > "$KEYS"
probe() { # probe <base> -> "calls=<n> key=<yes|no>"
  local base="$1" pins="$HOME/pins.json" log="$HOME/curl.log"
  rm -f "$log" "$log.key"
  jq -n --arg b "$base" '{hosted:{typesafe:{key_var:"TYPESAFE_API_KEY",base_url:$b,systemone_path:"/v1/systemone",
    models:["jev-latest"],context_limit:64000,enabled:true}}, local_gateway:{enabled:false}, lan:[]}' > "$pins"
  env -u LLMCTL_API_KEY CMA_JEV_PINS_FILE="$pins" CMA_KEYS_FILE="$KEYS" CMA_JEV_LIVE=1 CMA_JEV_HTTP_TIMEOUT=1 DUM="$DUMMY" \
    bash -c 'curl() { printf "x\n" >>"'"$log"'"; prev=""; for a in "$@"; do
        if [ "$prev" = "-H" ] && [[ "$a" == @* ]]; then if grep -q "$DUM" "${a#@}" 2>/dev/null; then : > "'"$log"'.key"; fi; fi; prev="$a"; done; return 7; }
      export -f curl; source "'"$SCRIPTS_DIR/claude-providers.sh"'" >/dev/null 2>&1; detect_jev_records' >/dev/null 2>&1
  printf 'calls=%s key=%s' "$(wc -l < "$log" 2>/dev/null | tr -d ' ' || echo 0)" "$([ -e "$log.key" ] && echo yes || echo no)"
}
it "M1: https loopback probe carries the key (control)"
assert_eq "calls=1 key=yes" "$(probe https://127.0.0.1:8095)" "https loopback: probe made, key sent"
it "M1: plain-http loopback probe never carries the key (rule 1)"
R="$(probe http://127.0.0.1:8095)"
case "$R" in *"key=no") _pass "http loopback: key not handed to curl [$R]" ;; *) _fail "http loopback: key not handed to curl" "$R" ;; esac
summary
