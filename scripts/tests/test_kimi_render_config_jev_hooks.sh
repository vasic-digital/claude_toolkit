#!/usr/bin/env bash
# test_kimi_render_config_jev_hooks.sh — T017: _cma_kimi_render_config
# (scripts/claude-providers.sh) emits ONE marker-guarded Kimi `[[hooks]]` PreToolUse
# block (the Jev gate) into ~/.kimi-prov-<id>/config.toml, ONLY when the Jev endpoint
# cache has >=1 endpoint AND the installed gate is executable. The file is fully
# rewritten each sync, so a stale block disappears; default_model stays first.
# RED_MODE=1 asserts the pre-T017 behaviour (no block) and is used against a
# tree that lacks the code (CMA_TEST_SCRIPTS_DIR) — see MUTATIONS in the report.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${CMA_TEST_SCRIPTS_DIR:-$(cd "$TESTS_DIR/.." && pwd)}"
export SCRIPTS_DIR
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required"; exit 0; }
python3 -c 'import tomllib' >/dev/null 2>&1 || { echo "SKIP: tomllib (3.11+) required"; exit 0; }
RED_MODE="${RED_MODE:-0}"
source "$SCRIPTS_DIR/claude-providers.sh"
set +e

PDIR="$HOME/.local/share/claude-multi-account/providers"
CACHE="$PDIR/jev-endpoints.json"
GATE_DIR="$HOME/.local/share/claude-multi-account/jev"
GATE="$GATE_DIR/jev-gate.sh"
CFG="$HOME/.kimi-prov-hk/config.toml"
mkdir -p "$PDIR" "$GATE_DIR"

_render() { _cma_kimi_render_config "hk" "HK_KEY" "native" "https://api.example.invalid" "m-1" "8192"; }
_have_gate()   { printf '#!/bin/sh\nexit 0\n' > "$GATE"; chmod +x "$GATE"; }
_cache_full()  { printf '{"version":1,"generated_at":1,"ttl":300,"endpoints":[{"provider_id":"p","base_url":"https://127.0.0.1:1","model":"m","priority":1}]}\n' > "$CACHE"; }
_cache_empty() { printf '{"version":1,"generated_at":1,"ttl":300,"endpoints":[]}\n' > "$CACHE"; }
_nbegin() { grep -c 'cma-jev:hooks BEGIN' "$CFG" 2>/dev/null; }
_hooks_probe() { python3 - "$CFG" <<'PY'
import sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))
h = d.get("hooks", [])
print(len(h), ",".join(sorted(h[0].keys())) if h else "-", h[0].get("event") if h else "-", h[0].get("command") if h else "-")
PY
}
_ordering_ok() { # first non-comment line is default_model and no default_model after first '['
  awk 'BEGIN{f=0} /^[[:space:]]*(#|$)/{next} {n++; if(n==1 && $0 !~ /^default_model =/){exit 1}
       if($0 ~ /^\[/){f=1} else if(f && $0 ~ /^default_model/){exit 1}} END{exit 0}' "$CFG"; }

it "1: cache non-empty + gate executable -> exactly one block, four fields only"
_have_gate; _cache_full; _render
if (( RED_MODE )); then
  assert_eq "0" "$(_nbegin)" "RED: no hooks block exists pre-T017"
else
  assert_eq "1" "$(_nbegin)" "one BEGIN marker"
  assert_eq "1" "$(grep -c 'cma-jev:hooks END' "$CFG")" "one END marker"
  assert_eq "1 command,event,matcher,timeout PreToolUse $GATE" "$(_hooks_probe)" "TOML parses: 1 hook, exactly event/matcher/command/timeout, command=gate"
fi

it "2: idempotent — second render is byte-identical"
h1="$(sha256sum "$CFG" | cut -d' ' -f1)"; _render; h2="$(sha256sum "$CFG" | cut -d' ' -f1)"
assert_eq "$h1" "$h2" "re-render byte-identical"
(( RED_MODE )) || assert_eq "1" "$(_nbegin)" "still exactly one BEGIN"

it "3: empty / missing / invalid cache -> no block"
_cache_empty; _render; assert_eq "0" "$(_nbegin)" "empty endpoints -> no block"
rm -f "$CACHE"; _render; assert_eq "0" "$(_nbegin)" "missing cache -> no block"
echo 'not json' > "$CACHE"; _render; assert_eq "0" "$(_nbegin)" "invalid JSON cache -> no block"

it "4: missing / non-executable gate -> no block"
_cache_full; chmod -x "$GATE"; _render; assert_eq "0" "$(_nbegin)" "non-executable gate -> no block"
rm -f "$GATE"; _render; assert_eq "0" "$(_nbegin)" "missing gate -> no block"

it "5: ordering guard — default_model first, never after a table header"
_have_gate; _cache_full; _render
_ordering_ok; assert_eq "0" "$?" "default_model precedes every [table]"

it "6: stale block removed when cache later empties"
_cache_empty; _render
assert_eq "0" "$(_nbegin)" "block gone after cache emptied"

it "7: gate path with a double quote is refused (no malformed TOML)"
_cache_full; mkdir -p "$HOME/we\"ird"; 
( HOME_SAVE="$HOME"; _cma_kimi_jev_gate_path() { echo "$HOME_SAVE/we\"ird/jev-gate.sh"; }; mkdir -p "$HOME/we\"ird"; printf '#!/bin/sh\n' > "$HOME/we\"ird/jev-gate.sh"; chmod +x "$HOME/we\"ird/jev-gate.sh"; _render )
if (( RED_MODE )); then :; else
  assert_eq "0" "$(_nbegin)" "unsafe gate path -> no block"
  python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$CFG"; assert_eq "0" "$?" "config still valid TOML"
fi
summary
