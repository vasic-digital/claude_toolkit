#!/usr/bin/env bash
# test_kimi_alias_file.sh — hermetic Tier-A coverage for the Kimi family layer
# in scripts/lib.sh (Unit 1): account-home helpers, marker-based detection,
# alias suggestion/validation, kimi alias commit/remove, the emitted
# cma_run_kimi / cma_run_kimi_provider wrappers, and the alias-gate structural
# floor that now requires both kimi wrappers. No network, no real ~/.kimi-code,
# no real ~/.claude*. Uses make_sandbox + sandbox_stub throughout.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox

# Hermeticity (test defect, fixed 2026-09-12): the "https twin with NO CA pin"
# case asserts that a provider whose env record carries no CMA_PROVIDER_CA_CERT
# exports NO NODE_EXTRA_CA_CERTS. A runner whose shell EXPORTS
# CMA_PROVIDER_CA_CERT — this host does, pointing at
# projects/.../helix_llm/certs/cert.pem — leaks it into the child, the wrapper
# faithfully exports the variable, and the case fails for a reason unrelated to
# the code under test. Same class already fixed in test_ccr_upstream_ca.sh and
# test_helixllm_model_export.sh.
unset CMA_PROVIDER_CA_CERT SSL_CERT_FILE NODE_EXTRA_CA_CERTS

# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e

# ---------------------------------------------------------------------------
# Section 1 — home / shared-items helpers
# ---------------------------------------------------------------------------
it "cma_kimi_home returns ~/.kimi-code"
assert_eq "$HOME/.kimi-code" "$(cma_kimi_home)" "kimi user-scope root"

it "cma_kimi_account_home returns ~/.kimi-code-<alias>"
assert_eq "$HOME/.kimi-code-kimi3" "$(cma_kimi_account_home kimi3)" "account home"

it "cma_kimi_provider_home returns ~/.kimi-prov-<id>"
assert_eq "$HOME/.kimi-prov-deepseek" "$(cma_kimi_provider_home deepseek)" "provider home"

it "CMA_KIMI_SHARED_ITEMS carries the five kimi shared items"
assert_eq "AGENTS.md plugins skills sessions session_index.jsonl" \
  "${CMA_KIMI_SHARED_ITEMS[*]}" "shared items list"

# ---------------------------------------------------------------------------
# Section 2 — binary resolution
# ---------------------------------------------------------------------------
it "cma_resolve_kimi_bin prefers ~/.kimi-code/bin/kimi"
mkdir -p "$HOME/.kimi-code/bin"
FAKE_KIMI="$HOME/.kimi-code/bin/kimi"
cat > "$FAKE_KIMI" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_KIMI"
assert_eq "$FAKE_KIMI" "$(cma_resolve_kimi_bin)" "root bin preferred"

it "cma_resolve_kimi_bin falls back to ~/.local/bin then PATH"
rm -rf "$HOME/.kimi-code" "$HOME/.local/bin/kimi"
mkdir -p "$HOME/.local/bin"
FAKE_PATH="$HOME/.local/bin/kimi"
cat > "$FAKE_PATH" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_PATH"
assert_eq "$FAKE_PATH" "$(PATH="/usr/bin:/bin" cma_resolve_kimi_bin)" "local bin fallback"

# ---------------------------------------------------------------------------
# Section 3 — alias suggestion / validation
# ---------------------------------------------------------------------------
it "cma_suggest_kimi_alias returns next free kimiN"
cma_write_kimi_alias kimi1 "$HOME/.kimi-code-kimi1"
assert_eq "kimi2" "$(cma_suggest_kimi_alias)" "kimi1 taken -> kimi2"

it "cma_validate_kimi_alias rejects reserved kimi-* and kc-* namespaces"
out="$(cma_validate_kimi_alias kimi-deepseek 2>&1)"; rc=$?
assert_eq 1 "$rc" "kimi-deepseek rejected"
[[ "$out" == *reserved* ]] && pass=0 || pass=1
assert_eq 0 "$pass" "rejection names the reserved namespace"
out="$(cma_validate_kimi_alias kc-for-coding 2>&1)"; rc=$?
assert_eq 1 "$rc" "kc-* rejected"

it "cma_validate_kimi_alias accepts an ordinary kimiN name"
cma_validate_kimi_alias kimi5
assert_eq 0 $? "kimi5 accepted"

# ---------------------------------------------------------------------------
# Section 4 — kimi alias commit / remove / idempotence
# ---------------------------------------------------------------------------
it "cma_write_kimi_alias writes KIMI_CODE_HOME form"
cma_write_kimi_alias kimi7 "$HOME/.kimi-code-kimi7"
assert_file_contains "$ALIAS_FILE" "alias kimi7=\"KIMI_CODE_HOME=$HOME/.kimi-code-kimi7 cma_run_kimi\"" \
  "kimi7 alias line with KIMI_CODE_HOME="

it "re-writing the same kimi alias is a byte no-op"
before="$(sha256sum "$ALIAS_FILE" | awk '{print $1}')"
cma_write_kimi_alias kimi7 "$HOME/.kimi-code-kimi7"
after="$(sha256sum "$ALIAS_FILE" | awk '{print $1}')"
assert_eq "$before" "$after" "idempotent kimi alias write"

it "cma_remove_kimi_alias drops the alias"
cma_remove_kimi_alias kimi7
assert_file_not_contains "$ALIAS_FILE" "alias kimi7=" "kimi7 alias removed"

# ---------------------------------------------------------------------------
# Section 5 — detection honors markers + exclusions
# ---------------------------------------------------------------------------
it "cma_detect_kimi_accounts includes marker dirs and empty dirs, excludes shared/marker-less"
rm -rf "$HOME/.kimi-code-"*
mkdir -p "$HOME/.kimi-code-a/sessions" "$HOME/.kimi-code-b" \
         "$HOME/.kimi-code-c/sub-file" "$HOME/.kimi-code-shared"
# marker-less non-empty dir must NOT count
mkdir -p "$HOME/.kimi-code-c/config-something"
touch "$HOME/.kimi-code-c/not-a-kimi-marker.txt"
got="$(cma_detect_kimi_accounts)"
[[ "$got" == *".kimi-code-a"* && "$got" == *".kimi-code-b"* ]] && ok=0 || ok=1
assert_eq 0 "$ok" "a (sessions marker) and b (empty) detected"
[[ "$got" == *".kimi-code-shared"* ]] && bad=0 || bad=1
assert_eq 1 "$bad" "kimi-code-shared excluded"
[[ "$got" == *".kimi-code-c"* ]] && bad=0 || bad=1
assert_eq 1 "$bad" "marker-less non-empty dir excluded"

it "cma_detect_kimi_accounts recognizes config.toml as a marker"
mkdir -p "$HOME/.kimi-code-d"
printf '[providers."x"]\ntype = "kimi"\n' > "$HOME/.kimi-code-d/config.toml"
got="$(cma_detect_kimi_accounts)"
[[ "$got" == *".kimi-code-d"* ]] && ok=0 || ok=1
assert_eq 0 "$ok" "config.toml is a kimi marker"

# ---------------------------------------------------------------------------
# Section 6 — managed block emits both kimi wrappers
# ---------------------------------------------------------------------------
it "rendered alias file contains cma_run_kimi and cma_run_kimi_provider"
rm -rf "$HOME/.local/share/claude-multi-account"
cma_ensure_alias_file
grep -q '^cma_run_kimi() {' "$ALIAS_FILE";             assert_eq 0 $? "cma_run_kimi present"
grep -q '^cma_run_kimi_provider() {' "$ALIAS_FILE";     assert_eq 0 $? "cma_run_kimi_provider present"

# ---------------------------------------------------------------------------
# Section 7 — emitted cma_run_kimi launch behaviour
# ---------------------------------------------------------------------------
# Rebuild alias file and load it so the wrappers are sourced from the sandbox.
rm -rf "$HOME/.local/share/claude-multi-account"
cma_ensure_alias_file

# Fake kimi that records the env + args it is called with.
REC_DIR="$HOME/rec"; mkdir -p "$REC_DIR"
mkdir -p "$HOME/.kimi-code/bin"
sandbox_stub "$HOME/.kimi-code/bin/kimi" <<EOF
#!/usr/bin/env bash
env | grep -E '^(KIMI_CODE_HOME|CLAUDE_CODE_MAX_OUTPUT_TOKENS|ANTHROPIC_BASE_URL|NODE_EXTRA_CA_CERTS|SSL_CERT_FILE)=' > "$REC_DIR/env"
printf '%s\n' "\$*" > "$REC_DIR/args"
exit 0
EOF

# shellcheck source=/dev/null
source "$ALIAS_FILE"
it "HYGIENE: wrappers under test come from the sandbox alias file"
assert_fn_from cma_run_kimi "$ALIAS_FILE" "cma_run_kimi from sandbox"
assert_fn_from cma_run_kimi_provider "$ALIAS_FILE" "cma_run_kimi_provider from sandbox"

it "cma_run_kimi resolves the bundled bin, scrubs leaked provider env, forwards args"
# Leak provider env vars that must be scrubbed before launch.
export ANTHROPIC_BASE_URL="https://leaked.example"
export CLAUDE_CODE_MAX_OUTPUT_TOKENS="9999"
( set +eu; KIMI_CODE_HOME="$HOME/.kimi-code-kimi9" cma_run_kimi -p "hi" --output-format text </dev/null >/dev/null 2>&1 )
args="$(cat "$REC_DIR/args")"
assert_eq "-p hi --output-format text" "$args" "kimi args forwarded verbatim"
grep -q "^CLAUDE_CODE_MAX_OUTPUT_TOKENS=" "$REC_DIR/env" && leak=0 || leak=1
assert_eq 1 "$leak" "CLAUDE_CODE_MAX_OUTPUT_TOKENS not leaked to kimi"
grep -q "^ANTHROPIC_BASE_URL=" "$REC_DIR/env" && leak=0 || leak=1
assert_eq 1 "$leak" "ANTHROPIC_BASE_URL not leaked to kimi"
grep -q "^KIMI_CODE_HOME=$HOME/.kimi-code-kimi9" "$REC_DIR/env" && ok=0 || ok=1
assert_eq 0 "$ok" "KIMI_CODE_HOME from the alias line is preserved"

# ---------------------------------------------------------------------------
# Section 8 — emitted cma_run_kimi_provider launch behaviour
# ---------------------------------------------------------------------------
PDIR="$(cma_providers_dir)"; mkdir -p "$PDIR"

it "cma_run_kimi_provider refuses non-verified without --force"
printf '{"deepseek":{"status":"unverified","model":"x"}}\n' > "$PDIR/status.json"
mkdir -p "$HOME/.kimi-prov-deepseek"
printf 'default_model = "deepseek/deepseek-chat"\n' > "$HOME/.kimi-prov-deepseek/config.toml"
: > "$REC_DIR/args"
out="$( set +eu; cma_run_kimi_provider deepseek hi </dev/null 2>&1 )"; rc=$?
assert_eq 3 "$rc" "non-verified refuses with rc 3"
[[ "$out" == *"claude-providers verify deepseek"* ]] && hint=0 || hint=1
assert_eq 0 "$hint" "refusal names the verify hint"

it "cma_run_kimi_provider honors --force"
out="$( set +eu; cma_run_kimi_provider --force deepseek hi </dev/null 2>&1 )"; rc=$?
assert_eq 0 "$rc" "--force launches despite non-verified"

it "cma_run_kimi_provider refuses when config.toml is missing"
rm -rf "$HOME/.kimi-prov-deepseek"
out="$( set +eu; cma_run_kimi_provider --force deepseek hi </dev/null 2>&1 )"; rc=$?
assert_eq 1 "$rc" "missing config.toml refuses"
[[ "$out" == *"claude-providers sync"* ]] && hint=0 || hint=1
assert_eq 0 "$hint" "refusal names sync hint"

it "cma_run_kimi_provider launches with KIMI_CODE_HOME and -m default_model"
mkdir -p "$HOME/.kimi-prov-deepseek"
printf 'default_model = "deepseek/deepseek-chat"\n' > "$HOME/.kimi-prov-deepseek/config.toml"
: > "$REC_DIR/env"; : > "$REC_DIR/args"
( set +eu; cma_run_kimi_provider --force deepseek "Reply exactly: KIMI-PROV-OK" </dev/null >/dev/null 2>&1 )
grep -q "^KIMI_CODE_HOME=$HOME/.kimi-prov-deepseek" "$REC_DIR/env" && ok=0 || ok=1
assert_eq 0 "$ok" "KIMI_CODE_HOME points at per-id home"
args="$(cat "$REC_DIR/args")"
assert_eq "-m deepseek/deepseek-chat Reply exactly: KIMI-PROV-OK" "$args" "launch uses -m default_model then user args"

it "cma_run_kimi_provider FORCES the per-id home over an ambient KIMI_CODE_HOME"
# An exported KIMI_CODE_HOME (Moonshot's documented data-root switch) must not
# redirect the provider launch to a different config.toml — the wrapper owns
# ~/.kimi-prov-<id> unconditionally, mirroring cma_run_provider's forced
# CLAUDE_CONFIG_DIR. Regression for the review finding that the wrapper honored
# the ambient var (a silently wrong-backend launch).
: > "$REC_DIR/env"; : > "$REC_DIR/args"
( set +eu; KIMI_CODE_HOME="$HOME/.kimi-code-other" \
  cma_run_kimi_provider --force deepseek hi </dev/null >/dev/null 2>&1 )
grep -q "^KIMI_CODE_HOME=$HOME/.kimi-prov-deepseek" "$REC_DIR/env" && ok=0 || ok=1
assert_eq 0 "$ok" "ambient KIMI_CODE_HOME ignored; per-id home still used"

it "cma_run_kimi_provider exports NODE_EXTRA_CA_CERTS only for https + CA"
CA_PEM="$HOME/ca.pem"; printf 'FAKE-CERT\n' > "$CA_PEM"
printf 'CMA_PROVIDER_CA_CERT=%s\n' "'$CA_PEM'" > "$PDIR/deepseek.env"
# https base -> export must happen
printf 'default_model = "deepseek/deepseek-chat"\nbase_url = "https://api.example.com/v1"\n' > "$HOME/.kimi-prov-deepseek/config.toml"
: > "$REC_DIR/env"
( set +eu; cma_run_kimi_provider --force deepseek hi </dev/null >/dev/null 2>&1 )
grep -q "^NODE_EXTRA_CA_CERTS=$CA_PEM" "$REC_DIR/env" && ok=0 || ok=1
assert_eq 0 "$ok" "NODE_EXTRA_CA_CERTS exported for https+CA"
# http base -> no export
printf 'default_model = "deepseek/deepseek-chat"\nbase_url = "http://api.example.com/v1"\n' > "$HOME/.kimi-prov-deepseek/config.toml"
: > "$REC_DIR/env"
( set +eu; cma_run_kimi_provider --force deepseek hi </dev/null >/dev/null 2>&1 )
grep -q "^NODE_EXTRA_CA_CERTS=" "$REC_DIR/env" && leak=0 || leak=1
assert_eq 1 "$leak" "NODE_EXTRA_CA_CERTS not exported for http base"

it "cma_run_kimi_provider launches an https twin with NO CA pin (system roots)"
# A public-CA https backend (deepseek etc.) needs no CMA_PROVIDER_CA_CERT — the
# launch must proceed and export nothing, so the live verifier may exercise it
# rather than SKIP. Regression for the over-broad https-no-CA verifier skip.
printf 'CMA_PROVIDER_KEYVAR=K\nCMA_PROVIDER_TRANSPORT=native\n' > "$PDIR/deepseek.env"
printf 'default_model = "deepseek/deepseek-chat"\nbase_url = "https://api.example.com/v1"\n' > "$HOME/.kimi-prov-deepseek/config.toml"
: > "$REC_DIR/env"
( set +eu; cma_run_kimi_provider --force deepseek hi </dev/null >/dev/null 2>&1 ); rc=$?
assert_eq 0 "$rc" "https twin without CA pin still launches"
grep -q "^NODE_EXTRA_CA_CERTS=" "$REC_DIR/env" && leak=0 || leak=1
assert_eq 1 "$leak" "NODE_EXTRA_CA_CERTS not exported without a CA pin"

# ---------------------------------------------------------------------------
# Section 9 — structural floor requires both kimi wrappers
# ---------------------------------------------------------------------------
it "_cma_alias_gate rejects a render missing cma_run_kimi"
cand="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
# Simulate a stale renderer that dropped the kimi wrappers.
sed '/^cma_run_kimi() {/,/^}/d; /^cma_run_kimi_provider() {/,/^}/d' "$ALIAS_FILE" > "$cand"
out="$(_cma_alias_gate "$cand" "$ALIAS_FILE" "" "" 2>&1)"; rc=$?
assert_eq 1 "$rc" "gate refuses candidate without cma_run_kimi"
[[ "$out" == *"cma_run_kimi"* ]] && ok=0 || ok=1
assert_eq 0 "$ok" "gate names cma_run_kimi as a missing floor item"
rm -f "$cand"

summary
