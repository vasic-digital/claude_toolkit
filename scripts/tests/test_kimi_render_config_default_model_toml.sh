#!/usr/bin/env bash
# test_kimi_render_config_default_model_toml.sh — _cma_kimi_render_config
# (scripts/claude-providers.sh) must emit a config.toml whose `default_model`
# key resolves at the file's ROOT table, not nested inside the
# [models."<id>/<model>"] table it just opened.
#
# WHY THIS EXISTS (measured defect, 2026-09-18 — investigating the Kimi Code
# twin for the local llmctl-small provider, but NOT specific to llmctl and NOT
# specific to router transport: the SAME defect reproduces against a REAL
# cloud provider, deepseek, with a REAL API key).
#
# TOML has no "close this table" syntax — once a `[table]` header opens, every
# following `key = value` line belongs to THAT table until the next table
# header appears. _cma_kimi_render_config's heredoc writes, in order:
#
#   [models."<id>/<model>"]
#   provider = "<id>"
#   model = "<model>"
#   max_context_size = <n>
#   capabilities = [ ... ]
#
#   default_model = "<id>/<model>"      <-- STILL inside [models."<id>/<model>"]
#
# so `default_model` lands as a field of the model TABLE, never at the file's
# root — the exact key the Kimi CLI reads (via `config.get("defaultModel")`,
# confirmed by decompiling the bundled binary's own error-message code) when
# deciding which model answers a `-p` prompt. Confirmed with real strings from
# the shipped ~/.kimi-code/bin/kimi (v0.42.0):
#
#   AuthModelNotResolvedError(...): modelId === void 0
#     ? "no default model configured"
#     : `model ${modelId} does not resolve to a configured provider`
#
# The rendered file still passes `kimi doctor` (schema-valid TOML) and
# `kimi provider list` (which reads `providers`/`models`, never `defaultModel`)
# — both existing sanity surfaces stay green while the twin is genuinely
# unusable. Live-reproduced against the REAL kimi binary, REAL rendered
# ~/.kimi-prov-<id>/config.toml, on BOTH a locally-hosted router-transport
# provider (llmctl-small, http://127.0.0.1:8085/v1) and a real cloud provider
# (deepseek, https://api.deepseek.com, real API key):
#
#   $ kimi -p "..."                        -> "No model configured. Run
#                                              `kimi` and use /login..."
#   $ kimi -m "<id>/<model>" -p "..."      -> "no default model configured"
#
# A naive line-grep for `^default_model = ` — exactly what
# cma_run_kimi_provider (scripts/lib.sh) uses to build its `-m` argument —
# still finds the line regardless of TOML scope, which is exactly why this
# defect was invisible to every prior check in this suite (see
# test_kimi_wire_and_status_freshness.sh, which only greps `^type = `): grep
# has no notion of table scope. Only parsing the file with a real TOML parser
# distinguishes "the string default_model appears somewhere" from "default_model
# resolves at the root the CLI reads it from" — Case 3 below documents that
# blind spot directly so it is never mistaken for coverage again.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# The tree under test. Overridable so a RED leg can point at the PRE-FIX tree
# and genuinely reproduce the defect instead of merely asserting it inverted.
SCRIPTS_DIR="${CMA_TEST_SCRIPTS_DIR:-$DEFAULT_SCRIPTS_DIR}"
export SCRIPTS_DIR

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 is required"; exit 0; }
python3 -c 'import tomllib' >/dev/null 2>&1 || { echo "SKIP: python3 tomllib (3.11+) is required"; exit 0; }

RED_MODE="${RED_MODE:-0}"

# shellcheck source=../claude-providers.sh
source "$SCRIPTS_DIR/claude-providers.sh"
set +e   # claude-providers.sh (and the lib.sh it sources) set -e; this
         # harness asserts on failures rather than aborting on the first one.

# _toml_probe CFG — prints "ROOT_DEFAULT_MODEL<TAB>NESTED_FLAG" for one
# rendered config.toml: ROOT_DEFAULT_MODEL is the value of the top-level
# `default_model` key (empty if it is not present at the root), and
# NESTED_FLAG is "1" iff some [models.*] sub-table carries its OWN
# `default_model` field instead (the exact shape of this defect).
_toml_probe() {
  python3 - "$1" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    doc = tomllib.load(f)
root_default = doc.get("default_model", "")
nested = "0"
for _mid, mtbl in (doc.get("models") or {}).items():
    if isinstance(mtbl, dict) and "default_model" in mtbl:
        nested = "1"
print(f"{root_default}\t{nested}")
PY
}

# ---------------------------------------------------------------------------
# Case 1 — router transport, llmctl-shaped model id: the model id itself
# STARTS with "/" (the exact shape llama-server's /v1/models reports, e.g.
# "/home/.../models/small/Llama-3.2-3B-Instruct-Q4_K_M.gguf"), so the
# rendered [models."<id>/<model>"] table key contains a literal "//".
# ---------------------------------------------------------------------------
it "router-transport twin (llmctl-shaped model id): default_model resolves at the TOML root"
_cma_kimi_render_config "llmctl-test" "LLMCTL_TEST_KEY" "router" \
  "http://127.0.0.1:39999/v1" "/models/small/fake-model.gguf" "8192"
CFG1="$HOME/.kimi-prov-llmctl-test/config.toml"
assert_file "$CFG1" "config.toml rendered for router-transport twin"
if [[ -f "$CFG1" ]]; then
  _out1="$(_toml_probe "$CFG1")"
  # `cut`, NOT `IFS=$'\t' read`: bash's `read` treats tab as IFS-WHITESPACE
  # even when it is the ONLY character in IFS, so it silently SKIPS a leading
  # empty field instead of preserving it — measured live: input "\tB" (empty
  # root, nested="B") parsed as root="B" nested="" via `read`, the exact
  # class of instrument-side mis-split this file exists to guard against
  # elsewhere (§11.4.273). `cut -f1`/`-f2` splits on the literal byte and
  # preserves an empty leading field correctly.
  _root1="$(cut -f1 <<<"$_out1")"
  _nested1="$(cut -f2 <<<"$_out1")"
  if (( RED_MODE )); then
    assert_eq "" "$_root1" "RED: default_model is NOT resolvable at the TOML root"
    assert_eq "1" "$_nested1" "RED: default_model landed nested inside [models.*] instead"
  else
    assert_eq "llmctl-test//models/small/fake-model.gguf" "$_root1" \
      "default_model resolves at the TOML root"
    assert_eq "0" "$_nested1" "default_model is NOT nested inside [models.*]"
  fi
fi

# ---------------------------------------------------------------------------
# Case 2 — cloud/native-shaped provider (a plain model id with no leading or
# embedded "/"), proving this is a render-FUNCTION defect that hits every
# twin, not something specific to llmctl or to router transport.
# ---------------------------------------------------------------------------
it "cloud-shaped twin (simple model id): default_model resolves at the TOML root"
_cma_kimi_render_config "cloudtest" "CLOUDTEST_KEY" "native" \
  "https://api.example.invalid" "cloud-model-x" "262144"
CFG2="$HOME/.kimi-prov-cloudtest/config.toml"
assert_file "$CFG2" "config.toml rendered for cloud-shaped twin"
if [[ -f "$CFG2" ]]; then
  _out2="$(_toml_probe "$CFG2")"
  _root2="$(cut -f1 <<<"$_out2")"
  _nested2="$(cut -f2 <<<"$_out2")"
  if (( RED_MODE )); then
    assert_eq "" "$_root2" "RED: default_model is NOT resolvable at the TOML root (cloud-shaped id too)"
    assert_eq "1" "$_nested2" "RED: default_model landed nested inside [models.*] (cloud-shaped id too)"
  else
    assert_eq "cloudtest/cloud-model-x" "$_root2" \
      "default_model resolves at the TOML root (cloud-shaped id too)"
    assert_eq "0" "$_nested2" "default_model is NOT nested inside [models.*] (cloud-shaped id too)"
  fi
fi

# ---------------------------------------------------------------------------
# Case 3 — documents the grep blind spot directly: the SAME naive line-grep
# cma_run_kimi_provider (scripts/lib.sh) runs to build its `-m` argument finds
# the identical string whether default_model is correctly scoped at the root
# or wrongly nested inside [models.*] — proving a grep-only check can never
# distinguish the two, which is exactly why the bug survived every prior test
# in this suite. This assertion is expected to PASS in BOTH RED and GREEN
# runs; it is not itself a regression guard, it is the reason one was needed.
# ---------------------------------------------------------------------------
it "documents the grep blind spot: line-grep finds default_model regardless of TOML scope"
if [[ -f "$CFG1" ]]; then
  _grepped="$(grep -E '^[[:space:]]*default_model[[:space:]]*=' "$CFG1" 2>/dev/null \
    | head -n1 | cut -d= -f2- | tr -d ' "')"
  assert_eq "llmctl-test//models/small/fake-model.gguf" "$_grepped" \
    "grep alone cannot tell root-scope from nested-scope"
fi

summary
