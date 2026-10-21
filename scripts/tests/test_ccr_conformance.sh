#!/usr/bin/env bash
# test_ccr_conformance.sh — static, no-network conformance between the launch
# grammar the toolkit SPEAKS and the grammar the bundled Go router UNDERSTANDS.
#
# Why this exists: the v1.23.0 JS->Go router swap passed the whole suite while
# the router launch was broken end-to-end. The wrapper invoked
# `ccr default-claude-code`, the real binary rejected every unknown first arg
# with `Profile "<arg>" was not found or is disabled.` (exit 1), and the only
# tests covering the router path used fake `ccr` stubs that silently `exit 0`
# on anything they didn't recognise. Stubs can only ever certify the stub.
#
# So: derive the REQUIRED set by scanning scripts/lib.sh for `ccr <word>` in
# command position, derive the SUPPORTED set by parsing the `case` arms of the
# router's top-level dispatch, and assert required ⊆ supported. Pure text
# analysis — no build, no network, no launch.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e

LIB_SH="$SCRIPTS_DIR/lib.sh"
# Flat router checkout via the single resolver (loud on failure; the
# assert_file below then FAILs naming the unresolved path).
ROUTER_DIR="$(bash "$SCRIPTS_DIR/resolve_deps.sh" claude_code_router "$REPO_ROOT")" \
  || ROUTER_DIR="<claude_code_router not resolvable>"
ROUTER_MAIN="$ROUTER_DIR/cmd/ccr/main.go"

# ---------------------------------------------------------------------------
# Extractors
# ---------------------------------------------------------------------------

# Every `ccr <subcommand>` the toolkit actually RUNS. Command position only:
# the line is split on shell command separators, each segment is trimmed of
# leading whitespace and leading keywords, and only a segment that BEGINS with
# `ccr ` — or, since the §11.4.111 stable-path resolution (2026-07-22), the
# resolved-binary form `"$_ccr" ` — counts. That rejects the many
# non-invocations in lib.sh — comments, `case *"ccr start"*` identity-guard
# patterns, printf help text, and the
# `[[ "$_prov_body" != *'ccr default-claude-code …'* ]]` migration markers.
# Portable awk only (2-arg match + substr/RSTART/RLENGTH; no gawk captures).
ccr_required_subcommands() {
  awk '
    {
      trimmed = $0
      sub(/^[[:space:]]+/, "", trimmed)
      if (trimmed ~ /^#/) next
      n = split($0, seg, /[;&|(`]/)
      for (i = 1; i <= n; i++) {
        s = seg[i]
        sub(/^[[:space:]]+/, "", s)
        while (s ~ /^(then|do|else|!)[[:space:]]+/) sub(/^(then|do|else|!)[[:space:]]+/, "", s)
        rest = ""
        if (s ~ /^ccr[[:space:]]/) {
          rest = substr(s, 4)
        } else if (s ~ /^"\$_ccr"[[:space:]]/) {
          rest = substr(s, 8)
        }
        if (rest != "") {
          sub(/^[[:space:]]+/, "", rest)
          if (match(rest, /^[^[:space:]]+/)) print substr(rest, RSTART, RLENGTH)
        }
      }
    }
  ' "$1" | sort -u
}

# Every subcommand the bundled Go router's top-level dispatch accepts, read
# from the `case "…":` arms of `switch args[0]`. Scoped to that one switch so a
# future unrelated switch elsewhere in main.go cannot widen the set and make
# this check vacuously pass.
ccr_supported_subcommands() {
  awk '
    /switch[[:space:]]+args\[0\][[:space:]]*\{/ { inswitch = 1; next }
    inswitch && /^[[:space:]]*default:/ { inswitch = 0 }
    inswitch && /^[[:space:]]*case[[:space:]]/ {
      line = $0
      while (match(line, /"[^"]*"/)) {
        print substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$1" | sort -u
}

# ===========================================================================
# Section 0 — the inputs exist and the parsers actually parsed something
# ===========================================================================
# Without these, a renamed file or a silently-broken extractor would make the
# real conformance assertions below iterate over an empty set and "pass" —
# precisely the failure mode this whole test file exists to prevent.
it "inputs are present"
assert_file "$LIB_SH" "toolkit lib.sh"
assert_file "$ROUTER_MAIN" "bundled Go router main.go"

REQUIRED="$(ccr_required_subcommands "$LIB_SH")"
SUPPORTED="$(ccr_supported_subcommands "$ROUTER_MAIN")"

it "extractors returned non-empty sets (anti-vacuous-pass guard)"
req_n="$(printf '%s\n' "$REQUIRED" | grep -c '[^[:space:]]')"
sup_n="$(printf '%s\n' "$SUPPORTED" | grep -c '[^[:space:]]')"
[[ "$req_n" -gt 0 ]]; assert_eq 0 $? "lib.sh scan found at least one 'ccr <subcommand>' invocation (found $req_n: $(echo $REQUIRED))"
[[ "$sup_n" -gt 0 ]]; assert_eq 0 $? "main.go scan found at least one dispatch case (found $sup_n: $(echo $SUPPORTED))"

it "the scan does not mistake identity-guard patterns / comments for invocations"
# lib.sh mentions `ccr start`, `ccr serve` and `ccr code` in a case pattern, a
# printf and comments respectively. None is an invocation; if any shows up in
# REQUIRED the command-position filter has regressed and the real assertions
# below become noise.
for _noise in code on PATH; do
  case $'\n'"$REQUIRED"$'\n' in
    *$'\n'"$_noise"$'\n'*) _ok=1 ;;
    *) _ok=0 ;;
  esac
  assert_eq 0 "$_ok" "non-invocation token '$_noise' correctly excluded from the required set"
done

# ===========================================================================
# Section 1 — every subcommand the toolkit needs is implemented by the router
# ===========================================================================
it "every 'ccr <subcommand>' in lib.sh is implemented by the bundled Go router"
for _sub in $REQUIRED; do
  case $'\n'"$SUPPORTED"$'\n' in
    *$'\n'"$_sub"$'\n'*) _ok=0 ;;
    *) _ok=1 ;;
  esac
  assert_eq 0 "$_ok" \
    "lib.sh invokes 'ccr $_sub' — router dispatch implements it (supported: $(echo $SUPPORTED))"
done

# ===========================================================================
# Section 2 — the launch grammar specifically
# ===========================================================================
# Called out on its own because this is the one that broke: an unimplemented
# launch subcommand does not degrade, it makes EVERY router-transport alias
# unusable ("Profile … was not found or is disabled.", exit 1).
it "the launch subcommand used by the wrapper is a real router subcommand"
launch_sub="$(awk '
  {
    # The §11.4.111 stable-path resolution launches via the resolved binary
    # ("$_ccr" default-claude-code -- "$@"); normalize that token back to the
    # bare form so ONE extraction covers both spellings.
    line = $0
    gsub(/"\$_ccr"/, "ccr", line)
    if (line ~ /ccr[[:space:]]+[^[:space:]]+[[:space:]]+--[[:space:]]+"\$@"/) {
      if (match(line, /ccr[[:space:]]+[^[:space:]]+/)) {
        tok = substr(line, RSTART, RLENGTH)
        sub(/^ccr[[:space:]]+/, "", tok)
        print tok
      }
    }
  }
' "$LIB_SH" | sort -u | head -1)"
assert_eq "default-claude-code" "$launch_sub" "wrapper launches the router via this subcommand"
case $'\n'"$SUPPORTED"$'\n' in
  *$'\n'"$launch_sub"$'\n'*) ok=0 ;;
  *) ok=1 ;;
esac
assert_eq 0 "$ok" "router implements the launch subcommand '$launch_sub' (else every router alias is dead on launch)"

summary
