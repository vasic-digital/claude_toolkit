#!/usr/bin/env bash
# test_cma_proxy.sh — the Go compatibility proxy (cma-proxy) build + unit tests.
#
# cma-proxy (scripts/proxy/, module cmaproxy) replaced the former per-provider
# python proxies. Its transforms are unit-tested by Go tests co-located with the
# source:
#   hermes_test.go   helixagent Hermes tool-call recovery (streaming + not),
#                    passthrough safety, </function>/</parameter>-in-value regressions
#   poe_test.go      poe tool-param injection + $ref resolve + cap + cache strip
#   kimi_test.go     kimi moonshot-flavored schema normalization
#   sarvam_test.go   sarvam content-block flatten + max_tokens tier clamp
#   nvidia_test.go   nvidia schema-aware cache_control strip (message/block/
#                    tool level; schema property named cache_control preserved)
#
# This bash test drives `go build` + `go test` so the whole proxy is covered by
# the standard suite. SKIPs (does not fail) when the Go toolchain is absent —
# same best-effort posture as the bundled ccr/proxy build.

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$TESTS_DIR/.." && pwd)}"
source "$TESTS_DIR/lib/assert.sh"
set +e

PROXY_SRC="$SCRIPTS_DIR/proxy"

# ---------------------------------------------------------------------------
# M4 (review 2026-07-22): the lib.sh transform-family gate must EQUAL the
# registered proxy set — asserted BEFORE the Go gate because it needs no
# toolchain. cma_run_provider warns about a missing cma-proxy ONLY for
# providers cma_proxy_transform_family() matches; the proxy's authoritative
# registry is the registerRequest/registerResponse calls in scripts/proxy/*.go.
# If the two diverge, a FUTURE transform provider silently misses the warning
# (false negative), or a shim-less provider gets warned on every launch
# (§11.4.201(1) false positive). Both directions are asserted.
it "M4. lib.sh transform families == proxy registry (both directions)"
reg_keys="$(grep -hoE 'register(Request|Response)\("[a-z0-9_]+"' "$PROXY_SRC"/*.go 2>/dev/null \
            | sed -E 's/.*"([a-z0-9_]+)"/\1/' | sort -u)"
# Control needle (§11.4.201(7)(b)): the extractor must SEE — a blind grep would
# report an empty registry, vacuously passing direction 2 and asserting nothing
# in direction 1. helixagent is known-registered (hermes.go), so it is the
# needle of the same query class.
if [ -n "$reg_keys" ] && printf '%s\n' "$reg_keys" | grep -qx 'helixagent'; then
  _pass "registry extractor sees the Go registrations: $(printf '%s' "$reg_keys" | tr '\n' ' ')"
else
  _fail "registry extractor is blind (got: '$reg_keys') — cannot certify the family gate"
fi
# Direction 1 (behavioural, not textual): every registered key AND its variant
# forms (poe2-style digit suffix, kimi-k2-style dash suffix — the folds
# providerKey() performs) must pass the lib.sh gate. A new registerRequest()
# without a lib.sh family update fails HERE, not silently in the field.
# Sourcing lib.sh is subshelled (it sets -euo pipefail); pass/fail lands here.
d1="$(
  set +e
  source "$SCRIPTS_DIR/lib.sh" 2>/dev/null
  set +e
  for k in $reg_keys; do
    for id in "$k" "${k}2" "${k}-variant"; do
      cma_proxy_transform_family "$id" 2>/dev/null || printf 'MISSING:%s ' "$id"
    done
  done
  # Negative control: a provider with NO registered transform must not match —
  # warning there would be the §11.4.201(1) false positive.
  cma_proxy_transform_family opencode 2>/dev/null && printf 'FALSE-POSITIVE:opencode '
  :
)"
if [ -z "$d1" ]; then
  _pass "every registered key (+ digit/dash variants) hits the family gate; opencode does not"
else
  _fail "family gate out of sync with the registry" "$d1"
fi
# Direction 2 (textual, needle-guarded): every family PREFIX in the lib.sh
# pattern must map to a registered transform key — no over-warning.
fam_line="$(sed -n '/^cma_proxy_transform_family()/,/^}/p' "$SCRIPTS_DIR/lib.sh" | grep -m1 '\*)')"
if [ -z "$fam_line" ]; then
  _fail "cannot extract the family pattern from lib.sh (function or pattern missing)"
else
  _pass "family pattern extracted: $(printf '%s' "$fam_line" | sed 's/^[[:space:]]*//')"
  d2=""
  for pfx in $(printf '%s' "$fam_line" | tr '|' '\n' | sed -E 's/[[:space:]]//g; s/\).*$//; s/\*//g'); do
    printf '%s\n' "$reg_keys" | grep -qx "$pfx" || d2="$d2 $pfx"
  done
  if [ -z "$d2" ]; then
    _pass "every family prefix maps to a registered transform (no over-warning)"
  else
    _fail "family prefixes with NO registered transform (§11.4.201(1) would-be false warners)" "$d2"
  fi
fi

if ! command -v go >/dev/null 2>&1; then
  it "go toolchain present"
  echo "  SKIP: go not on PATH — cma-proxy build/tests skipped (best-effort, like ccr)"
  summary
  exit 0
fi

it "scripts/proxy has a go.mod (module cmaproxy)"
grep -q '^module cmaproxy' "$PROXY_SRC/go.mod" 2>/dev/null
assert_eq 0 $? "go.mod declares module cmaproxy"

it "cma-proxy builds"
tmpbin="$(mktemp -d "${TMPDIR:-/tmp}/cma-proxy-test.XXXXXX")/cma-proxy"
( cd "$PROXY_SRC" && go build -o "$tmpbin" . ) 2>/dev/null
assert_eq 0 $? "go build -o <tmp> . succeeds"

it "go vet is clean"
( cd "$PROXY_SRC" && go vet ./... ) 2>/dev/null
assert_eq 0 $? "go vet ./... clean"

it "go test passes (hermes + poe + kimi + sarvam)"
tout="$( cd "$PROXY_SRC" && go test ./... 2>&1 )"; trc=$?
assert_eq 0 "$trc" "go test ./... passes"
printf '%s' "$tout" | grep -q '^ok' || printf '%s' "$tout" | grep -q 'PASS'
assert_eq 0 $? "test output reports ok/PASS"

it "gofmt is clean (no unformatted proxy sources)"
# Capture stderr into the value (2>&1, NOT suppressed) so a gofmt crash surfaces
# in the assertion instead of vacuously passing as "clean" — and so the suite's
# vacuity scanner sees a non-suppressed capture (out of scope by construction).
unformatted="$( cd "$PROXY_SRC" && gofmt -l . 2>&1 )"
assert_eq "" "$unformatted" "all .go files are gofmt-clean (and gofmt ran)"

if [ -x "$tmpbin" ]; then
  it "--has-transform gate answers for known + family + unknown providers"
  "$tmpbin" --has-transform helixagent >/dev/null 2>&1; assert_eq 0 $? "helixagent -> transform (exit 0)"
  "$tmpbin" --has-transform kimi-for-coding >/dev/null 2>&1; assert_eq 0 $? "kimi-for-coding -> kimi family (exit 0)"
  "$tmpbin" --has-transform poe2 >/dev/null 2>&1; assert_eq 0 $? "poe2 -> poe base (exit 0)"
  "$tmpbin" --has-transform no_such_provider >/dev/null 2>&1; assert_eq 1 $? "unknown provider -> no transform (exit 1)"
fi

summary
