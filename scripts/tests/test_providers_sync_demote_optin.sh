#!/usr/bin/env bash
# test_providers_sync_demote_optin.sh - `claude-providers sync` must NOT demote (orphan) providers by default (operator decision
# 2026-10-28, v1.33.2). Orphan = a status/.env record whose id no longer resolves against the current catalog/keys. A key that is merely
# absent from this shell's keys file must not strip a working provider of its verified status. Default: REPORT (name the ids, say how to
# demote), change nothing. `sync --demote`: demote (status -> orphaned). `--dry-run` never writes. Fast sibling of the long
# test_providers.sh sections; this one is also the mutation target (lib/jev_mutations.py). Values fabricated, offline, sandboxed HOME.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e
PROVIDERS_SH="$SCRIPTS_DIR/claude-providers.sh"
PCACHE="$HOME/.local/share/claude-multi-account/providers/models.dev.cache.json"
mkdir -p "$(dirname "$PCACHE")"
cat > "$PCACHE" <<'JSON'
{"acme":{"env":["ACME_API_KEY"],"api":"https://api.acme.com/anthropic","npm":"@ai-sdk/anthropic",
  "models":{"b":{"id":"acme-big","reasoning":true,"release_date":"2025-05-01","limit":{"context":200000},"cost":{"input":3,"output":15},"tool_call":true}}}}
JSON
KEYS="$HOME/api_keys.sh"
printf 'export ACME_API_KEY="dummy-acme"\n' > "$KEYS"
sync_() { bash "$PROVIDERS_SH" sync "$@" --offline --no-verify --keys-file "$KEYS" 2>&1 >/dev/null; }

cma_status_write ghost-one verified ghost-model ""
cma_provider_write_env "ghost-two" "GHOST_TWO_KEY" "router" "https://api.ghost-two.example/v1" "ghost-two-model" "" "$HOME/.claude-prov-ghost-two" "" "" "ghost-two"
cma_provider_write_alias "ghost-two" "ghost-two"

it "default sync leaves a status-only orphan verified, names it, and says how to demote"
out="$(sync_)"
assert_eq verified "$(cma_status_read ghost-one)" "ghost-one stays verified"
grep -q 'ghost-one' <<<"$out"; assert_eq 0 $? "ghost-one is named"
grep -q -- '--demote' <<<"$out"; assert_eq 0 $? "the notice names the --demote flag"
grep -qi 'left unchanged' <<<"$out"; assert_eq 0 $? "the notice says the status was left unchanged"
it "default sync writes no orphaned status for an env-only orphan either"
assert_eq pending "$(cma_status_read ghost-two)" "ghost-two stays pending"
grep -q 'ghost-two' <<<"$out"; assert_eq 0 $? "ghost-two is named"
it "a provider that still resolves is never reported as an orphan"
grep 'orphaned provider' <<<"$out" | grep -q 'acme'; assert_eq 1 $? "acme not named in the orphan notice"
it "--demote --dry-run writes nothing"
sync_ --demote --dry-run >/dev/null
assert_eq verified "$(cma_status_read ghost-one)" "dry-run leaves ghost-one verified"
it "--demote demotes both orphan classes"
out="$(sync_ --demote)"
assert_eq orphaned "$(cma_status_read ghost-one)" "ghost-one orphaned"
assert_eq orphaned "$(cma_status_read ghost-two)" "ghost-two orphaned"
grep -q 'ORPHANED' <<<"$out"; assert_eq 0 $? "per-id ORPHANED warning emitted"
it "--demote never demotes a provider that still resolves"
cma_status_write acme verified acme-big ""
sync_ --demote >/dev/null
cond=1; [[ "$(cma_status_read acme)" == "orphaned" ]] && cond=0
assert_eq 1 "$cond" "acme not orphaned"
it "the help text documents --demote"
helpout="$(bash "$PROVIDERS_SH" --help 2>&1)"; case "$helpout" in *--demote*) rc=0;; *) rc=1;; esac; assert_eq 0 "$rc" "--demote in --help"
summary
