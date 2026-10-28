#!/usr/bin/env bash
# Real Claude Code transcripts put parentUuid/... BEFORE "type":"assistant".
# Resumable detection + context-size must see them; debris must not count.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/assert.sh"
S="$HERE/../claude-session.sh"
T="$(mktemp -d)"; trap 'rm -rf -- "$T"' EXIT
pad() { head -c 70000 /dev/zero | tr '\0' 'x'; }
real="$T/real.jsonl"
real2="$T/real2.jsonl"
printf '{"parentUuid":"a","isSidechain":false,"message":{"usage":{"input_tokens":5,"cache_creation_input_tokens":10,"cache_read_input_tokens":100}},"requestId":"r","type":"assistant","uuid":"u"}\n' > "$real2"; printf '{"type":"user","x":"%s"}\n' "$(head -c 70000 /dev/zero | tr '\0' x)" >> "$real2"
{ printf '{"parentUuid":null,"isSidechain":false,"cwd":"/p","sessionId":"s","type":"user","message":{"content":"hi"}}\n'
  printf '{"parentUuid":"a","isSidechain":false,"cwd":"/p","sessionId":"s","type":"assistant","message":{"usage":{"input_tokens":5,"cache_creation_input_tokens":10,"cache_read_input_tokens":100}}}\n'
  printf '{"type":"user","x":"%s"}\n' "$(pad)"; } > "$real"
old="$T/old.jsonl"
{ printf '{"type":"assistant","message":{"usage":{"input_tokens":1}}}\n'; printf '{"type":"user","x":"%s"}\n' "$(pad)"; } > "$old"
debris="$T/debris.jsonl"
{ printf 'junk {"type":"assistant"} paste\n'; printf '{"type":"user","x":"%s"}\n' "$(pad)"; } > "$debris"
esc="$T/esc.jsonl"
{ printf '{"type":"user","x":"%s \\"type\\":\\"assistant\\""}\n' "$(pad)"; } > "$esc"
res() { ( source "$S" >/dev/null 2>&1 || true; _cma_session_resumable "$1" ) 2>/dev/null; }
it "real-format assistant line is resumable"; res "$real"; assert_eq "$?" 0 "real"
it "legacy type-first line is resumable"; res "$old"; assert_eq "$?" 0 "old"
it "mid-line debris is not resumable"; res "$debris"; assert_eq "$?" 1 "debris"
it "escaped substring inside a string is not resumable"; res "$esc"; assert_eq "$?" 1 "esc"
it "message-before-type (current real layout) is resumable"; res "$real2"; assert_eq "$?" 0 "real2"
it "context-size reads usage of message-first layout"
P="$T/proj"; mkdir -p "$P" "$T/cfg/projects"
slug="$(printf '%s' "$(cd "$P" && pwd -P)" | sed -E 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$T/cfg/projects/$slug"; cp "$real2" "$T/cfg/projects/$slug/11111111-1111-4111-8111-111111111111.jsonl"
ctx="$(cd "$P" && bash "$S" context-size "$T/cfg" 11111111-1111-4111-8111-111111111111 2>/dev/null)"
assert_eq 115 "$ctx" "ctx"
many="$T/many.jsonl"
for i in $(seq 1 600); do printf '{"parentUuid":"a","isSidechain":false,"message":{"usage":{"input_tokens":1}},"type":"assistant","uuid":"u%s"}\n' "$i"; done > "$many"
printf '{"type":"user","x":"%s"}\n' "$(pad)" >> "$many"
it "many assistant lines (grep SIGPIPE under pipefail) is still resumable"; res "$many"; assert_eq "$?" 0 "many"
it "lib.sh wires org-guard into the emitted cma_run (not into providers)"
LIB="$HERE/../lib.sh"
n="$(grep -c 'claude-session" org-guard' "$LIB")"; assert_eq 1 "$n" "exactly one org-guard call (cma_run)"
summary
