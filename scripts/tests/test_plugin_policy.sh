#!/usr/bin/env bash
# test_plugin_policy.sh -- claude-sync-plugins + the lib.sh policy hooks (v1.34.0):
#   * capture is deterministic (re-capture of an unchanged source is byte-identical)
#   * --dry-run writes nothing; --apply enforces the EXACT enabled set on every
#     alias (claude*, prov-*, default, shared template); unknown plugins => false
#   * every non-plugin settings.json key survives (hash of the rest unchanged),
#     mode 0600 survives, the SOURCE alias is never written
#   * per-project disabledMcpServers reach every project of every other alias
#   * --apply is idempotent (2nd run: 0 changed, files byte-identical)
#   * --verify: 0 conformant, 1 on injected drift, 2 without a policy
#   * a NEW alias seeded after capture inherits the set
#   * claude-unify (any-true union) and claude-sync-state do NOT re-enable
#   * a /plugin change in the source alias is picked up on the next sync
#   * CMA_PLUGIN_POLICY=off and "no policy" are true no-ops

set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
export SCRIPTS_DIR
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
SYNC="$SCRIPTS_DIR/claude-sync-plugins.sh"
command -v jq >/dev/null || { _skip "jq missing"; summary; exit $?; }

mkdir_alias() { # name enabledPlugins-json [extra-json]
  local d="$HOME/.claude-$1"; mkdir -p "$d/plugins"
  jq -n --argjson ep "$2" --argjson x "${3:-{\}}" '{enabledPlugins:$ep, model:"opus-test", hooks:{a:1}} + $x' > "$d/settings.json"
  chmod 600 "$d/settings.json"; echo "$d"
}
ALL_TRUE='{"a@m":true,"b@m":true,"c@m":true,"zz@m":true}'
c1="$(mkdir_alias claude1 '{"a@m":true,"b@m":false,"c@m":true}')"
c2="$(mkdir_alias claude2 "$ALL_TRUE" '{"env":{"FAKE":"x"},"permissions":{"allow":["Bash(ls)"]}}')"
c3="$(mkdir_alias claude3 "$ALL_TRUE")"
pv="$(mkdir_alias prov-foo "$ALL_TRUE" '{"model":"prov-model"}')"
mkdir_alias claude5 '{}' >/dev/null; c5="$HOME/.claude-claude5"
mkdir -p "$SHARED_DIR"; jq -n --argjson ep "$ALL_TRUE" '{enabledPlugins:$ep}' > "$SHARED_DIR/settings.json"
jq -n --argjson ep "$ALL_TRUE" '{enabledPlugins:$ep, theme:"dark"}' > "$DEFAULT_DIR/settings.json"
# .claude.json: source has an MCP disable list in ONE project; others have two projects
jq -n '{userID:"u1",projects:{"/p/one":{disabledMcpServers:["plugin:x:x","plugin:y:y"],keep:1}}}' > "$c1/.claude.json"
for d in "$c2" "$c3" "$pv"; do jq -n '{userID:"u-other",projects:{"/p/one":{lastCost:1},"/p/two":{disabledMcpServers:["plugin:own:own"]}}}' > "$d/.claude.json"; done

rest_hash() { jq -S 'del(.enabledPlugins)' "$1" | sha256sum | cut -d' ' -f1; }
H2="$(rest_hash "$c2/settings.json")"; HP="$(rest_hash "$pv/settings.json")"; HD="$(rest_hash "$DEFAULT_DIR/settings.json")"
SRC_SHA="$(sha256sum "$c1/settings.json" | cut -d' ' -f1)"
SRC_CJ_SHA="$(sha256sum "$c1/.claude.json" | cut -d' ' -f1)"

it "no policy: --verify exits 2, hooks are no-ops"
"$SYNC" --verify >/dev/null 2>&1; assert_eq 2 "$?" "verify without policy -> 2"
before="$(sha256sum "$c2/settings.json" | cut -d' ' -f1)"
( source "$SCRIPTS_DIR/lib.sh"; set +e; cma_policy_enforce_all )
assert_eq "$before" "$(sha256sum "$c2/settings.json" | cut -d' ' -f1)" "enforce_all without policy leaves files alone"

it "capture is deterministic"
"$SYNC" capture --from "$c1" >/dev/null; assert_eq 0 "$?" "capture exits 0"
P="$SHARED_DIR/plugin-policy.json"
h1="$(sha256sum "$P" | cut -d' ' -f1)"; "$SYNC" capture --from "$c1" >/dev/null
assert_eq "$h1" "$(sha256sum "$P" | cut -d' ' -f1)" "re-capture byte-identical"
assert_jq "$P" '.enabledPlugins | to_entries | map(select(.value)) | length' 2 "policy enables exactly a@m,c@m"
assert_jq "$P" '.disabledMcpServers | length' 2 "policy carries the 2 disabled MCP servers"

it "--dry-run writes nothing"
"$SYNC" --dry-run > "$SANDBOX_HOME/dry.out" 2>&1; assert_eq 0 "$?" "dry-run exits 0"
assert_eq "$before" "$(sha256sum "$c2/settings.json" | cut -d' ' -f1)" "claude2 untouched by dry-run"
assert_file_contains "$SANDBOX_HOME/dry.out" "would-change" "dry-run reports pending changes"
"$SYNC" --verify >/dev/null 2>&1; assert_eq 1 "$?" "verify reports drift before apply"

it "--apply enforces the set everywhere"
"$SYNC" --apply --backup-dir "$SANDBOX_HOME/bk" > "$SANDBOX_HOME/apply.out" 2>&1; assert_eq 0 "$?" "apply exits 0"
for d in "$c2" "$c3" "$pv" "$DEFAULT_DIR" "$SHARED_DIR"; do
  assert_eq '{"a@m":true,"b@m":false,"c@m":true,"zz@m":false}' \
    "$(jq -cS '.enabledPlugins | with_entries(select(.key != "__"))' "$d/settings.json" | sed 's/^{/{/')" "enabled set equals source (+unknown=false) in $(basename "$d")" || true
done
assert_eq '{"a@m":true,"b@m":false,"c@m":true}' "$(jq -cS '.enabledPlugins' "$c5/settings.json")" "claude5 (empty map) receives exactly the policy keys"
assert_eq '{"a@m":true,"b@m":false,"c@m":true,"zz@m":false}' "$(jq -c '.enabledPlugins' "$c2/settings.json")" "claude2 exact map"
assert_eq "$H2" "$(rest_hash "$c2/settings.json")" "claude2 non-plugin keys unchanged (hash)"
assert_eq "$HP" "$(rest_hash "$pv/settings.json")" "prov-foo non-plugin keys unchanged (hash)"
assert_eq "$HD" "$(rest_hash "$DEFAULT_DIR/settings.json")" "default non-plugin keys unchanged (hash)"
assert_eq "600" "$(stat -c %a "$c2/settings.json")" "mode 0600 preserved"
assert_eq "$SRC_SHA" "$(sha256sum "$c1/settings.json" | cut -d' ' -f1)" "SOURCE settings.json never written"
assert_eq "$SRC_CJ_SHA" "$(sha256sum "$c1/.claude.json" | cut -d' ' -f1)" "SOURCE .claude.json never written"
it "MCP disables reach every project"
for d in "$c2" "$c3" "$pv"; do
  assert_jq "$d/.claude.json" '[.projects[] | (.disabledMcpServers | index("plugin:x:x") != null) and (.disabledMcpServers | index("plugin:y:y") != null)] | all' true "all projects of $(basename "$d") carry the list"
done
assert_jq "$c2/.claude.json" '.projects["/p/two"].disabledMcpServers | index("plugin:own:own") != null' true "alias-own MCP disable kept (union)"
assert_jq "$c2/.claude.json" '.userID' 'u-other' "auth identity untouched"
it "backups + manifest"
assert_file "$SANDBOX_HOME/bk/manifest.tsv" "manifest written"
assert_file_contains "$SANDBOX_HOME/bk/manifest.tsv" "$c2/settings.json" "manifest names claude2 settings.json"
assert_eq 0 "$(grep -c "$c1" "$SANDBOX_HOME/bk/manifest.tsv")" "source never backed up (never touched)"

it "idempotent"
shas="$(find "$HOME" -name settings.json -o -name .claude.json | sort | xargs sha256sum)"
"$SYNC" --apply --backup-dir "$SANDBOX_HOME/bk2" > "$SANDBOX_HOME/apply2.out" 2>&1; assert_eq 0 "$?" "2nd apply exits 0"
assert_file_contains "$SANDBOX_HOME/apply2.out" "changed: 0" "2nd apply changed 0"
assert_eq "$shas" "$(find "$HOME" -name settings.json -o -name .claude.json | sort | xargs sha256sum)" "all files byte-identical after 2nd apply"
"$SYNC" --verify >/dev/null 2>&1; assert_eq 0 "$?" "verify conformant"

it "verify detects injected drift"
jq '.enabledPlugins["zz@m"]=true' "$c3/settings.json" > "$c3/s.tmp" && mv "$c3/s.tmp" "$c3/settings.json"
"$SYNC" --verify >/dev/null 2>&1; assert_eq 1 "$?" "verify -> 1 on drift"
"$SYNC" --apply --backup-dir "$SANDBOX_HOME/bk3" >/dev/null 2>&1
"$SYNC" --verify >/dev/null 2>&1; assert_eq 0 "$?" "repaired"

it "the source alias is protected even when it drifted from the captured policy"
jq '.enabledPlugins["zz@m"]=true' "$c1/settings.json" > "$c1/s.tmp" && mv "$c1/s.tmp" "$c1/settings.json"
S1="$(sha256sum "$c1/settings.json" | cut -d' ' -f1)"
"$SYNC" --apply --backup-dir "$SANDBOX_HOME/bk4" > "$SANDBOX_HOME/apply4.out" 2>&1
assert_eq "$S1" "$(sha256sum "$c1/settings.json" | cut -d' ' -f1)" "apply never rewrites the drifted source"
assert_file_contains "$SANDBOX_HOME/apply4.out" "policy is stale" "stale-policy NOTE printed"
jq '.enabledPlugins["zz@m"]=false' "$c1/settings.json" > "$c1/s.tmp" && mv "$c1/s.tmp" "$c1/settings.json"
touch -d '2 hours ago' "$c1/settings.json" "$c1/.claude.json"

it "new alias: seeder enforces even when the TEMPLATE itself drifted"
jq '.enabledPlugins["zz@m"]=true' "$SHARED_DIR/settings.json" > "$SHARED_DIR/s.tmp" && mv "$SHARED_DIR/s.tmp" "$SHARED_DIR/settings.json"
mkdir -p "$HOME/.claude-prov-drift"
( source "$SCRIPTS_DIR/lib.sh"; set +e; cma_own_settings_seed "$HOME/.claude-prov-drift" )
assert_eq "false" "$(jq -r '.enabledPlugins["zz@m"]' "$HOME/.claude-prov-drift/settings.json")" "seed-by-copy enforces the policy over a drifted template"

it "sync-state pull (launch hook) re-curates a drifted alias"
jq '.enabledPlugins["zz@m"]=true' "$c3/settings.json" > "$c3/s.tmp" && mv "$c3/s.tmp" "$c3/settings.json"
"$SCRIPTS_DIR/claude-sync-state.sh" pull "$c3" >/dev/null 2>&1
assert_eq "false" "$(jq -r '.enabledPlugins["zz@m"]' "$c3/settings.json")" "pull enforced"

it "new alias inherits via the seeder"
mkdir -p "$HOME/.claude-prov-new"
( source "$SCRIPTS_DIR/lib.sh"; set +e; cma_own_settings_seed "$HOME/.claude-prov-new" )
assert_eq '{"a@m":true,"b@m":false,"c@m":true,"zz@m":false}' "$(jq -c '.enabledPlugins' "$HOME/.claude-prov-new/settings.json")" "fresh alias seeded with the curated set"

it "unify's any-true union does not re-enable"
jq '.enabledPlugins["zz@m"]=true | .enabledPlugins["b@m"]=true' "$c2/settings.json" > "$c2/s.tmp" && mv "$c2/s.tmp" "$c2/settings.json"
"$SCRIPTS_DIR/claude-unify.sh" >/dev/null 2>&1
for d in "$c2" "$c3" "$pv" "$SHARED_DIR"; do
  assert_eq '{"a@m":true,"b@m":false,"c@m":true,"zz@m":false}' "$(jq -c '.enabledPlugins' "$d/settings.json")" "after unify: $(basename "$d") still curated"
done

it "source change is picked up by the sync hook"
sleep 1
jq '.enabledPlugins["b@m"]=true' "$c1/settings.json" > "$c1/s.tmp" && mv "$c1/s.tmp" "$c1/settings.json"
"$SCRIPTS_DIR/claude-sync-state.sh" all >/dev/null 2>&1
assert_eq "true" "$(jq -r '.enabledPlugins["b@m"]' "$c2/settings.json")" "b@m now enabled in claude2"
assert_eq "true" "$(jq -r '.enabledPlugins["b@m"]' "$pv/settings.json")" "b@m now enabled in prov-foo"

it "CMA_PLUGIN_POLICY=off is a no-op"
jq '.enabledPlugins["zz@m"]=true' "$c3/settings.json" > "$c3/s.tmp" && mv "$c3/s.tmp" "$c3/settings.json"
CMA_PLUGIN_POLICY=off "$SCRIPTS_DIR/claude-sync-state.sh" all >/dev/null 2>&1
assert_eq "true" "$(jq -r '.enabledPlugins["zz@m"]' "$c3/settings.json")" "off leaves the drift alone"

summary
