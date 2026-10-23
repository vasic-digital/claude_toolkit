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
STATE_DIR="${JEV_STATE_DIR:-$HOME/.local/state/jev}"
_stamp_on()    { mkdir -p "$STATE_DIR"; printf 'agents=kimi\n' > "$STATE_DIR/installed.stamp"; }
_stamp_legacy() { mkdir -p "$STATE_DIR"; : > "$STATE_DIR/installed.stamp"; }      # pre-1.32.1 stamp: names nobody
_stamp_claude() { mkdir -p "$STATE_DIR"; printf 'agents=claude\n' > "$STATE_DIR/installed.stamp"; }
_stamp_off()   { rm -f "$STATE_DIR/installed.stamp"; }
_have_gate()   { printf '#!/bin/sh\nexit 0\n' > "$GATE"; chmod +x "$GATE"; _stamp_on; }
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

it "8: matcher VALUE — Kimi tests the matcher with an UNANCHORED RegExp.test(toolName): exact matched set over real tool names"
_have_gate; _cache_full; _render
if (( RED_MODE )); then :; else
  M="$(python3 -c 'import sys,tomllib; print(tomllib.load(open(sys.argv[1],"rb"))["hooks"][0]["matcher"])' "$CFG")"
  # Control needle: the instrument (node RegExp.test, the SAME semantics Kimi Code 2.2.0
  # uses) must see a match for a known-present name and NO match for a fabricated one.
  if command -v node >/dev/null 2>&1; then
    rx() { node -e 'process.stdout.write(new RegExp(process.argv[1]).test(process.argv[2]) ? "1" : "0")' "$1" "$2"; }
    assert_eq "1" "$(rx 'Bash' 'Bash')" "control needle: RegExp.test sees a known match"
    assert_eq "0" "$(rx 'Bash' 'ZzNoSuchTool')" "control needle: RegExp.test sees a known non-match"
    # Unanchored semantics: a bare substring hit matches, so an over-broad matcher would be caught here.
    assert_eq "1" "$(rx 'Edit' 'NotebookEdit')" "needle: unanchored substring semantics are real (Edit matches NotebookEdit)"
    got=""
    for t in Bash Write Edit Read Grep Glob WebSearch WebFetch Agent ZzNoSuchTool; do
      [ "$(rx "$M" "$t")" = 1 ] && got="$got $t"
    done
    assert_eq " Bash Write Edit" "$got" "matcher '$M' selects EXACTLY Bash, Write, Edit among real read-only + decoy tool names (no over-matching)"
  else
    _fail "node required for the RegExp.test semantic check" "install node to run this test"
  fi
  assert_eq "$(tr -d '[:space:]' < "$SCRIPTS_DIR/jev-kimi-tools.txt" 2>/dev/null)" "$M" "rendered matcher == the single constant file"
  # no stale (non-tool) names left anywhere in shipped scripts or docs
  stale="$(grep -rnE '[|"]WriteFile|StrReplaceFile' "$SCRIPTS_DIR" "$SCRIPTS_DIR/../docs" 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*#'  | grep -v '/tests/' | head)"
  assert_eq "" "$stale" "no WriteFile/StrReplaceFile outside tests"
fi

it "9: gate path containing a BACKSLASH is refused and the config still parses (tomllib)"
_cache_full; BSH="$HOME/we\\ird"; mkdir -p "$BSH"; printf '#!/bin/sh\n' > "$BSH/jev-gate.sh"; chmod +x "$BSH/jev-gate.sh"; _stamp_on
( _cma_kimi_jev_gate_path() { echo "$BSH/jev-gate.sh"; }; _render )
if (( RED_MODE )); then :; else
  assert_eq "0" "$(_nbegin)" "backslash gate path -> no block"
  python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$CFG"; assert_eq "0" "$?" "config still valid TOML with backslash path"
fi

it "10: installed-stamp gate — gate+cache but NO stamp -> no block; stamp -> block; stamp removed -> gone"
_have_gate; _cache_full; _stamp_off; _render
(( RED_MODE )) || assert_eq "0" "$(_nbegin)" "no installed stamp -> no block (uninstall must stick)"
_stamp_on; _render
(( RED_MODE )) || assert_eq "1" "$(_nbegin)" "stamp present -> block"
_stamp_off; _render
(( RED_MODE )) || assert_eq "0" "$(_nbegin)" "stamp removed -> block gone on next render"

it "11: _cma_jev_after_sync re-renders Kimi twins (hook state not one sync behind)"
_have_gate; rm -f "$CACHE"; _render
assert_eq "0" "$(_nbegin)" "precondition: rendered with no cache -> no block"
RECS='[{"classification":"decision","status":"resolved","provider_id":"p","base_url":"https://127.0.0.1:1","strong_model":"m","key_var":"K","priority":1,"reason":"t"}]'
_cma_jev_after_sync "$RECS" >/dev/null 2>&1
if (( RED_MODE )); then :; else
  assert_eq "1" "$(_nbegin)" "after_sync created the cache AND refreshed the twin's hook block"
  assert_eq "1 command,event,matcher,timeout PreToolUse $GATE" "$(_hooks_probe)" "refreshed twin parses with the gate command"
  _ordering_ok; assert_eq "0" "$?" "default_model still first after refresh"
  h1="$(sha256sum "$CFG" | cut -d' ' -f1)"; _cma_jev_after_sync "$RECS" >/dev/null 2>&1; h2="$(sha256sum "$CFG" | cut -d' ' -f1)"
  assert_eq "$h1" "$h2" "refresh is idempotent (byte-identical)"
  _stamp_off; _cma_jev_after_sync "$RECS" >/dev/null 2>&1
  assert_eq "0" "$(_nbegin)" "after uninstall (stamp gone) the next after_sync strips the block"
  assert_eq "0" "$(stat -c %a "$CFG" | grep -c '^600$' | awk '{print ($1==1)?0:1}')" "config keeps mode 600"
fi
it "12: a gate path containing a NEWLINE / TAB / DEL (control chars) is refused and the config still parses"
for cc in $'\n' $'\t' $'\x7f'; do
  _cache_full; CCD="$HOME/cc${cc}dir"; mkdir -p "$CCD"; printf '#!/bin/sh\n' > "$CCD/jev-gate.sh"; chmod +x "$CCD/jev-gate.sh"; _stamp_on
  ( _cma_kimi_jev_gate_path() { echo "$CCD/jev-gate.sh"; }; _render )
  assert_eq "0" "$(_nbegin)" "control-char gate path ($(printf %q "$cc")) -> no block"
  python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$CFG"; assert_eq "0" "$?" "config still valid TOML ($(printf %q "$cc"))"
done

it "13: consent — the stamp must LIST kimi: agents=claude and a legacy EMPTY stamp both fail closed"
_have_gate; _cache_full
_stamp_claude; _render; assert_eq "0" "$(_nbegin)" "stamp agents=claude -> no kimi twin hook"
_stamp_legacy; _render; assert_eq "0" "$(_nbegin)" "legacy empty stamp -> no hook (consent for kimi was never recorded)"
printf 'agents=claude,kimi\n' > "$STATE_DIR/installed.stamp"; _render; assert_eq "1" "$(_nbegin)" "agents=claude,kimi -> hook rendered"
printf 'agents=all\n' > "$STATE_DIR/installed.stamp"; _render; assert_eq "1" "$(_nbegin)" "agents=all -> hook rendered"
printf 'agents=kimix\n' > "$STATE_DIR/installed.stamp"; _render; assert_eq "0" "$(_nbegin)" "agents=kimix (prefix decoy) -> no hook"

it "14: refresh fails CLOSED — a failing rewrite keeps the original config and warns"
_have_gate; _cache_full; _render
before="$(sha256sum "$CFG" | cut -d' ' -f1)"
out="$( awk() { return 1; }; _cma_kimi_jev_hooks_refresh 2>&1 )"
assert_eq "$before" "$(sha256sum "$CFG" | cut -d' ' -f1)" "original config byte-identical after a failed rewrite"
echo "$out" | grep -q 'left untouched' && _pass "failure is reported, not swallowed" || _fail "silent failure" "$out"
assert_eq "0" "$(ls "$(dirname "$CFG")"/.hooks.* 2>/dev/null | wc -l)" "no temp file left behind"
assert_eq "600" "$(stat -c %a "$CFG")" "config still mode 600"

it "15: unusable jev-kimi-tools.txt -> the renderer warns naming the file and emits no block"
_have_gate; _cache_full
T2="$(mktemp -d)"; find "$SCRIPTS_DIR" -maxdepth 1 -type f -exec cp -p {} "$T2/" \; ; ln -s "$SCRIPTS_DIR/providers" "$T2/providers" 2>/dev/null
printf 'Bash|\n' > "$T2/jev-kimi-tools.txt"
err="$( LIB_DIR="$T2" _cma_kimi_render_config hk HK_KEY native https://api.example.invalid m-1 8192 2>&1 >/dev/null )"
assert_eq "0" "$(_nbegin)" "invalid constant file -> no block"
echo "$err" | grep -q 'jev-kimi-tools.txt' && _pass "warning names jev-kimi-tools.txt" || _fail "silent about an invalid constant file" "$err"
rm -rf "$T2"
it "16: refresh fails CLOSED when the rewritten config would lose its default_model line"
_have_gate; _cache_full
mkdir -p "$(dirname "$CFG")"
# default_model exists ONLY inside the marker block: stripping the block (the first step of any
# rewrite) removes it, so a rewrite that kept going would silently produce a config with no model.
printf '[meta]\nx = 1\n\n# cma-jev:hooks BEGIN\ndefault_model = "p/m"\n# cma-jev:hooks END\n' > "$CFG"; chmod 600 "$CFG"
before="$(sha256sum "$CFG" | cut -d' ' -f1)"
out="$( _cma_kimi_jev_hooks_refresh 2>&1 )"
assert_eq "$before" "$(sha256sum "$CFG" | cut -d' ' -f1)" "original config byte-identical (no model-less rewrite)"
echo "$out" | grep -q 'left untouched' && _pass "the refusal is reported, not swallowed" || _fail "silent refusal" "$out"
assert_eq "0" "$(ls "$(dirname "$CFG")"/.hooks.* 2>/dev/null | wc -l)" "no temp file left behind"
rm -f "$CFG"

summary
