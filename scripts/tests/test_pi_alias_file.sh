#!/usr/bin/env bash
# test_pi_alias_file.sh — hermetic Tier-A coverage for the Pi family layer in
# scripts/lib.sh (Unit 1): account-home helpers, marker-based detection, alias
# suggestion/validation, pi alias commit/remove, and the emitted cma_run_pi /
# cma_run_pi_provider wrappers. No network, no real ~/.pi, no real ~/.claude*.
# Uses make_sandbox + sandbox_stub throughout.
#
# IMPORTANT (root-cause notes, do not "simplify" away — verified live against
# the real installed pi CLI, v0.85.1, before these tests were written):
#   1. Pi's model flag is `--model` ONLY. Unlike the Kimi CLI (which defines
#      `-m` as a documented shorthand for `--model`), Pi's own `--help` lists
#      no `-m` alias, and `pi -m <anything>` exits 1 with
#      `Error: Unknown option: -m`.
#   2. Pi has NO `PI_HOME` env var and NO TOML config reader anywhere in its
#      source (grepped its installed dist/ bundle for both: zero hits). Its
#      real per-directory override is `PI_CODING_AGENT_DIR`, and its real
#      custom-provider config format is a JSON file named exactly
#      `models.json` (docs/models.md) — never `config.toml`.
# cma_run_pi_provider must use `--model` (never `-m`) and PI_CODING_AGENT_DIR
# + models.json (never PI_HOME + config.toml) — Section 8 below is the
# regression guard for both defect classes.
set -u
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

# ---------------------------------------------------------------------------
# Section 1 — home / shared-items helpers
# ---------------------------------------------------------------------------
it "cma_pi_home returns ~/.pi"
assert_eq "$HOME/.pi" "$(cma_pi_home)" "pi user-scope root"

it "cma_pi_account_home returns ~/.pi-<alias>"
assert_eq "$HOME/.pi-pi3" "$(cma_pi_account_home pi3)" "account home"

it "cma_pi_provider_home returns ~/.pi-prov-<id>"
assert_eq "$HOME/.pi-prov-llmctl-small" "$(cma_pi_provider_home llmctl-small)" "provider home"

it "CMA_PI_SHARED_ITEMS carries the five pi shared items"
assert_eq "AGENTS.md plugins skills sessions session_index.jsonl" \
  "${CMA_PI_SHARED_ITEMS[*]}" "shared items list"

# ---------------------------------------------------------------------------
# Section 2 — binary resolution
# ---------------------------------------------------------------------------
it "cma_resolve_pi_bin prefers ~/.pi/bin/pi"
mkdir -p "$HOME/.pi/bin"
FAKE_PI="$HOME/.pi/bin/pi"
cat > "$FAKE_PI" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_PI"
assert_eq "$FAKE_PI" "$(cma_resolve_pi_bin)" "root bin preferred"

it "cma_resolve_pi_bin falls back to ~/.local/bin then PATH"
rm -rf "$HOME/.pi" "$HOME/.local/bin/pi"
mkdir -p "$HOME/.local/bin"
FAKE_PATH="$HOME/.local/bin/pi"
cat > "$FAKE_PATH" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_PATH"
assert_eq "$FAKE_PATH" "$(PATH="/usr/bin:/bin" cma_resolve_pi_bin)" "local bin fallback"

# ---------------------------------------------------------------------------
# Section 3 — alias suggestion / validation
# ---------------------------------------------------------------------------
it "cma_suggest_pi_alias returns next free piN"
cma_write_pi_alias pi1 "$HOME/.pi-pi1"
assert_eq "pi2" "$(cma_suggest_pi_alias)" "pi1 taken -> pi2"

it "cma_validate_pi_alias rejects reserved pi-*/kimi-*/kc-* namespaces"
out="$(cma_validate_pi_alias pi-deepseek 2>&1)"; rc=$?
assert_eq 1 "$rc" "pi-deepseek rejected"
[[ "$out" == *reserved* ]] && pass=0 || pass=1
assert_eq 0 "$pass" "rejection names the reserved namespace"
out="$(cma_validate_pi_alias kimi-deepseek 2>&1)"; rc=$?
assert_eq 1 "$rc" "kimi-deepseek rejected"
out="$(cma_validate_pi_alias kc-for-coding 2>&1)"; rc=$?
assert_eq 1 "$rc" "kc-* rejected"

it "cma_validate_pi_alias accepts an ordinary piN name"
cma_validate_pi_alias pi5
assert_eq 0 $? "pi5 accepted"

# ---------------------------------------------------------------------------
# Section 4 — pi alias commit / remove / idempotence
# ---------------------------------------------------------------------------
it "cma_write_pi_alias writes PI_HOME= form"
cma_write_pi_alias pi7 "$HOME/.pi-pi7"
assert_file_contains "$ALIAS_FILE" "alias pi7=\"PI_HOME=$HOME/.pi-pi7 cma_run_pi\"" \
  "pi7 alias line with PI_HOME="

it "re-writing the same pi alias is a byte no-op"
before="$(sha256sum "$ALIAS_FILE" | awk '{print $1}')"
cma_write_pi_alias pi7 "$HOME/.pi-pi7"
after="$(sha256sum "$ALIAS_FILE" | awk '{print $1}')"
assert_eq "$before" "$after" "idempotent pi alias write"

it "cma_remove_pi_alias drops the alias"
cma_remove_pi_alias pi7
assert_file_not_contains "$ALIAS_FILE" "alias pi7=" "pi7 alias removed"

# ---------------------------------------------------------------------------
# Section 5 — detection honors markers + exclusions
# ---------------------------------------------------------------------------
it "cma_detect_pi_accounts includes marker dirs and empty dirs, excludes shared/marker-less"
rm -rf "$HOME/.pi-"*
mkdir -p "$HOME/.pi-a/sessions" "$HOME/.pi-b" \
         "$HOME/.pi-c/sub-file" "$HOME/.pi-shared"
# marker-less non-empty dir must NOT count
mkdir -p "$HOME/.pi-c/config-something"
touch "$HOME/.pi-c/not-a-pi-marker.txt"
got="$(cma_detect_pi_accounts)"
[[ "$got" == *".pi-a"* && "$got" == *".pi-b"* ]] && ok=0 || ok=1
assert_eq 0 "$ok" "a (sessions marker) and b (empty) detected"
[[ "$got" == *".pi-shared"* ]] && bad=0 || bad=1
assert_eq 1 "$bad" "pi-shared excluded"
[[ "$got" == *".pi-c"* ]] && bad=0 || bad=1
assert_eq 1 "$bad" "marker-less non-empty dir excluded"

it "cma_detect_pi_accounts recognizes config.toml as a marker"
mkdir -p "$HOME/.pi-d"
printf '[providers."x"]\ntype = "pi"\n' > "$HOME/.pi-d/config.toml"
got="$(cma_detect_pi_accounts)"
[[ "$got" == *".pi-d"* ]] && ok=0 || ok=1
assert_eq 0 "$ok" "config.toml is a pi marker"

# ---------------------------------------------------------------------------
# Section 6 — managed block emits both pi wrappers
# ---------------------------------------------------------------------------
it "rendered alias file contains cma_run_pi and cma_run_pi_provider"
rm -rf "$HOME/.local/share/claude-multi-account"
cma_ensure_alias_file
grep -q '^cma_run_pi() {' "$ALIAS_FILE";           assert_eq 0 $? "cma_run_pi present"
grep -q '^cma_run_pi_provider() {' "$ALIAS_FILE";  assert_eq 0 $? "cma_run_pi_provider present"

# ---------------------------------------------------------------------------
# Section 7 — emitted cma_run_pi launch behaviour
# ---------------------------------------------------------------------------
# Rebuild alias file and load it so the wrappers are sourced from the sandbox.
rm -rf "$HOME/.local/share/claude-multi-account"
cma_ensure_alias_file

# Fake pi that records the env + args it is called with.
REC_DIR="$HOME/rec"; mkdir -p "$REC_DIR"
mkdir -p "$HOME/.pi/bin"
sandbox_stub "$HOME/.pi/bin/pi" <<EOF
#!/usr/bin/env bash
env | grep -E '^(PI_HOME|PI_CODING_AGENT_DIR|CLAUDE_CODE_MAX_OUTPUT_TOKENS|ANTHROPIC_BASE_URL|NODE_EXTRA_CA_CERTS|SSL_CERT_FILE|KIMI_CODE_HOME)=' > "$REC_DIR/env"
printf '%s\n' "\$*" > "$REC_DIR/args"
exit 0
EOF

# shellcheck source=/dev/null
source "$ALIAS_FILE"
it "HYGIENE: wrappers under test come from the sandbox alias file"
assert_fn_from cma_run_pi "$ALIAS_FILE" "cma_run_pi from sandbox"
assert_fn_from cma_run_pi_provider "$ALIAS_FILE" "cma_run_pi_provider from sandbox"

it "cma_run_pi resolves the bundled bin, scrubs leaked provider/kimi env, forwards args"
# Leak provider env vars that must be scrubbed before launch.
export ANTHROPIC_BASE_URL="https://leaked.example"
export CLAUDE_CODE_MAX_OUTPUT_TOKENS="9999"
export KIMI_CODE_HOME="$HOME/.kimi-code-leaked"
( set +eu; PI_HOME="$HOME/.pi-pi9" cma_run_pi -p "hi" --mode json </dev/null >/dev/null 2>&1 )
args="$(cat "$REC_DIR/args")"
assert_eq "-p hi --mode json" "$args" "pi args forwarded verbatim"
grep -q "^CLAUDE_CODE_MAX_OUTPUT_TOKENS=" "$REC_DIR/env" && leak=0 || leak=1
assert_eq 1 "$leak" "CLAUDE_CODE_MAX_OUTPUT_TOKENS not leaked to pi"
grep -q "^ANTHROPIC_BASE_URL=" "$REC_DIR/env" && leak=0 || leak=1
assert_eq 1 "$leak" "ANTHROPIC_BASE_URL not leaked to pi"
grep -q "^KIMI_CODE_HOME=" "$REC_DIR/env" && leak=0 || leak=1
assert_eq 1 "$leak" "KIMI_CODE_HOME not leaked to pi"
grep -q "^PI_HOME=$HOME/.pi-pi9" "$REC_DIR/env" && ok=0 || ok=1
assert_eq 0 "$ok" "PI_HOME from the alias line is preserved"

# ---------------------------------------------------------------------------
# Section 8 — emitted cma_run_pi_provider launch behaviour
# ---------------------------------------------------------------------------
PDIR="$(cma_providers_dir)"; mkdir -p "$PDIR"

# _mkmodelsjson DEST PROVIDER_ID MODEL_ID BASE_URL — writes a models.json
# fixture in the EXACT shape _cma_pi_render_config emits (one provider, one
# model), matching Pi's real docs/models.md schema.
_mkmodelsjson() {
  local dest="$1" pid="$2" mid="$3" base="$4"
  jq -n --arg pid "$pid" --arg mid "$mid" --arg base "$base" \
    '{providers: {($pid): {baseUrl: $base, api: "openai-completions", apiKey: "x", models: [{id: $mid, contextWindow: 8192}]}}}' \
    > "$dest"
}

it "cma_run_pi_provider refuses non-verified without --force"
printf '{"llmctl-small":{"status":"unverified","model":"x"}}\n' > "$PDIR/status.json"
mkdir -p "$HOME/.pi-prov-llmctl-small"
_mkmodelsjson "$HOME/.pi-prov-llmctl-small/models.json" "llmctl-small" "x" "http://127.0.0.1:8085/v1"
: > "$REC_DIR/args"
out="$( set +eu; cma_run_pi_provider llmctl-small hi </dev/null 2>&1 )"; rc=$?
assert_eq 3 "$rc" "non-verified refuses with rc 3"
[[ "$out" == *"claude-providers verify llmctl-small"* ]] && hint=0 || hint=1
assert_eq 0 "$hint" "refusal names the verify hint"

it "cma_run_pi_provider honors --force"
out="$( set +eu; cma_run_pi_provider --force llmctl-small hi </dev/null 2>&1 )"; rc=$?
assert_eq 0 "$rc" "--force launches despite non-verified"

it "cma_run_pi_provider refuses when models.json is missing"
rm -rf "$HOME/.pi-prov-llmctl-small"
out="$( set +eu; cma_run_pi_provider --force llmctl-small hi </dev/null 2>&1 )"; rc=$?
assert_eq 1 "$rc" "missing models.json refuses"
[[ "$out" == *"claude-providers sync"* ]] && hint=0 || hint=1
assert_eq 0 "$hint" "refusal names sync hint"

it "cma_run_pi_provider launches with PI_CODING_AGENT_DIR and --model provider/id (NOT -m, NOT PI_HOME)"
# This is the regression guard for the TWO root-cause bugs found live against
# the real installed pi binary (v0.85.1):
#   1. pi has NO -m shorthand for --model ('pi -m foo/bar' exits 1 with
#      "Error: Unknown option: -m"; 'pi --model foo/bar' is accepted).
#      cma_run_pi_provider previously copied the Kimi wrapper's
#      '-m "$_ckdm"' invocation verbatim — correct for kimi (kimi DOES
#      define -m), wrong for pi.
#   2. pi has NO PI_HOME env var and NO TOML config reader at all (grepped
#      its installed dist/ bundle for both: zero hits); its real per-directory
#      override is PI_CODING_AGENT_DIR and its real custom-provider format is
#      a JSON models.json (docs/models.md) — never config.toml.
mkdir -p "$HOME/.pi-prov-llmctl-small"
_mkmodelsjson "$HOME/.pi-prov-llmctl-small/models.json" "llmctl-small" "/home/x/models/small/model.gguf" "http://127.0.0.1:8085/v1"
: > "$REC_DIR/env"; : > "$REC_DIR/args"
( set +eu; cma_run_pi_provider --force llmctl-small "Reply exactly: LLMCTL-PROV-OK" </dev/null >/dev/null 2>&1 )
grep -q "^PI_CODING_AGENT_DIR=$HOME/.pi-prov-llmctl-small" "$REC_DIR/env" && ok=0 || ok=1
assert_eq 0 "$ok" "PI_CODING_AGENT_DIR points at per-id home"
grep -q "^PI_HOME=" "$REC_DIR/env" && bad=0 || bad=1
assert_eq 1 "$bad" "PI_HOME is NOT exported (pi CLI ignores it entirely)"
args="$(cat "$REC_DIR/args")"
assert_eq "--model llmctl-small//home/x/models/small/model.gguf Reply exactly: LLMCTL-PROV-OK" "$args" \
  "launch uses --model provider/model-id then user args (not -m)"
[[ "$args" == "-m "* ]] && bad=0 || bad=1
assert_eq 1 "$bad" "launch does NOT use the bare -m flag pi rejects"

it "cma_run_pi_provider FORCES the per-id home over an ambient PI_CODING_AGENT_DIR"
# An exported PI_CODING_AGENT_DIR must not redirect the provider launch to a
# different models.json — the wrapper owns ~/.pi-prov-<id> unconditionally,
# mirroring cma_run_kimi_provider's forced KIMI_CODE_HOME and
# cma_run_provider's forced CLAUDE_CONFIG_DIR.
: > "$REC_DIR/env"; : > "$REC_DIR/args"
( set +eu; PI_CODING_AGENT_DIR="$HOME/.pi-other" \
  cma_run_pi_provider --force llmctl-small hi </dev/null >/dev/null 2>&1 )
grep -q "^PI_CODING_AGENT_DIR=$HOME/.pi-prov-llmctl-small" "$REC_DIR/env" && ok=0 || ok=1
assert_eq 0 "$ok" "ambient PI_CODING_AGENT_DIR ignored; per-id home still used"

it "cma_run_pi_provider exports NODE_EXTRA_CA_CERTS only for https + CA"
CA_PEM="$HOME/ca.pem"; printf 'FAKE-CERT\n' > "$CA_PEM"
printf 'CMA_PROVIDER_CA_CERT=%s\n' "'$CA_PEM'" > "$PDIR/llmctl-small.env"
# https base -> export must happen
_mkmodelsjson "$HOME/.pi-prov-llmctl-small/models.json" "llmctl-small" "x" "https://api.example.com/v1"
: > "$REC_DIR/env"
( set +eu; cma_run_pi_provider --force llmctl-small hi </dev/null >/dev/null 2>&1 )
grep -q "^NODE_EXTRA_CA_CERTS=$CA_PEM" "$REC_DIR/env" && ok=0 || ok=1
assert_eq 0 "$ok" "NODE_EXTRA_CA_CERTS exported for https+CA"
# http base -> no export (the llmctl-small real-world case: a loopback
# http://127.0.0.1:8085/v1 backend, no CA pin, no TLS at all)
unset CMA_PROVIDER_CA_CERT NODE_EXTRA_CA_CERTS SSL_CERT_FILE
_mkmodelsjson "$HOME/.pi-prov-llmctl-small/models.json" "llmctl-small" "x" "http://127.0.0.1:8085/v1"
: > "$REC_DIR/env"
( set +eu; cma_run_pi_provider --force llmctl-small hi </dev/null >/dev/null 2>&1 )
grep -q "^NODE_EXTRA_CA_CERTS=" "$REC_DIR/env" && leak=0 || leak=1
assert_eq 1 "$leak" "NODE_EXTRA_CA_CERTS not exported for http (loopback) base"

summary
