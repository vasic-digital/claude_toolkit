#!/usr/bin/env bash
# test_lib.sh — unit tests for the helper functions in lib.sh.
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
# lib.sh enables `set -e`. The test harness is intentionally tolerant of
# non-zero exits (we assert on them), so turn it back off here.
set +e

it "cma_validate_alias accepts well-formed names"
( set -e; cma_validate_alias "claude3" ); assert_eq 0 $? "claude3"
( set -e; cma_validate_alias "work_acct-1" ); assert_eq 0 $? "work_acct-1"

it "cma_validate_alias rejects invalid names"
( cma_validate_alias "3claude" >/dev/null 2>&1 ); assert_eq 1 $? "rejects digit-leading"
( cma_validate_alias "bad name" >/dev/null 2>&1 ); assert_eq 1 $? "rejects spaces"
( cma_validate_alias "" >/dev/null 2>&1 ); assert_eq 1 $? "rejects empty"

it "cma_suggest_alias starts at claude1 when nothing exists"
suggestion="$(cma_suggest_alias)"
assert_eq "claude1" "$suggestion" "first suggestion"

it "cma_suggest_alias increments past existing claudeN aliases"
cma_write_alias claude1 "$HOME/.claude-acct1"
cma_write_alias claude2 "$HOME/.claude-acct2"
cma_write_alias claude5 "$HOME/.claude-acct5"   # gap
suggestion="$(cma_suggest_alias)"
assert_eq "claude6" "$suggestion" "skips past highest, not count"

it "cma_write_alias is idempotent — rewriting same alias doesn't duplicate"
cma_write_alias claude1 "$HOME/.claude-acct1"   # second write
count="$(grep -c '^alias claude1=' "$ALIAS_FILE")"
assert_eq "1" "$count" "one alias line for claude1"

it "cma_remove_alias removes the line"
cma_remove_alias claude5
assert_file_not_contains "$ALIAS_FILE" "alias claude5=" "claude5 removed"

it "cma_ensure_alias_file sources from the shell rc file"
# lib.sh manages .zshrc on macOS and .bashrc + .zshrc on Linux (CMA_RC_FILES).
# Assert against the platform-appropriate target, selected the same way lib.sh
# selects it, so the test is correct on both OSes.
if [[ "$(uname -s)" == "Darwin" ]]; then RC_FILE="$HOME/.zshrc"; else RC_FILE="$HOME/.bashrc"; fi
touch "$RC_FILE"
rm -f "$ALIAS_FILE"
cma_ensure_alias_file
assert_file "$ALIAS_FILE" "alias file created"
assert_file_contains "$RC_FILE" "source \"$ALIAS_FILE\"" "rc file gets source line"

it "cma_detect_accounts skips the shared store"
mkdir -p "$HOME/.claude-shared" "$HOME/.claude-acct1"
found=(); while IFS= read -r _l; do found+=("$_l"); done < <(cma_detect_accounts)
joined="${found[*]:-}"
cond=1; [[ "$joined" == *".claude-acct1"* ]] && cond=0; assert_eq 0 "$cond" "finds .claude-acct1"
cond=1; [[ "$joined" != *".claude-shared"* ]] && cond=0; assert_eq 0 "$cond" "excludes .claude-shared"

it "cma_detect_accounts excludes non-Claude .claude-* dirs (e.g. .claude-server-commander)"
# Mimic the real-world false positive seen on mistborn.local: an MCP server
# config dir whose name happens to start with .claude- but has only its own
# config files, no Claude markers.
mkdir -p "$HOME/.claude-server-commander"
printf '{}\n' > "$HOME/.claude-server-commander/config.json"
printf '{}\n' > "$HOME/.claude-server-commander/feature-flags.json"
found=(); while IFS= read -r _l; do found+=("$_l"); done < <(cma_detect_accounts)
joined="${found[*]:-}"
cond=1; [[ "$joined" != *".claude-server-commander"* ]] && cond=0; assert_eq 0 "$cond" "excludes .claude-server-commander"
cond=1; [[ "$joined" == *".claude-acct1"* ]] && cond=0; assert_eq 0 "$cond" "still finds the legit empty account"

it "cma_detect_accounts includes a populated account dir even if it has foreign config too"
# A real account dir with the Claude marker (projects/) shouldn't get
# falsely excluded just because some other file happens to be there.
mkdir -p "$HOME/.claude-real/projects"
printf '{}\n' > "$HOME/.claude-real/some-other-tool.json"
found=(); while IFS= read -r _l; do found+=("$_l"); done < <(cma_detect_accounts)
joined="${found[*]:-}"
cond=1; [[ "$joined" == *".claude-real"* ]] && cond=0; assert_eq 0 "$cond" "finds .claude-real"

it "cma_realpath resolves a symlink chain to its canonical target (no readlink -f)"
mkdir -p "$HOME/rp/real"
: > "$HOME/rp/real/file"
ln -s "$HOME/rp/real/file" "$HOME/rp/link1"
ln -s "$HOME/rp/link1" "$HOME/rp/link2"          # chain: link2 -> link1 -> real/file
got="$(cma_realpath "$HOME/rp/link2")"
want="$(cd "$HOME/rp/real" && pwd -P)/file"
assert_eq "$want" "$got" "cma_realpath follows the symlink chain"
# A plain (non-symlink) path canonicalizes to itself.
got2="$(cma_realpath "$HOME/rp/real/file")"
assert_eq "$want" "$got2" "cma_realpath is identity on a real path"

it "no runtime script INVOKES 'readlink -f' (absent on BSD/macOS)"
# Strip comments first so explanatory comments mentioning the flag don't count;
# we only care about real invocations. kimi-*.sh is in the same loop (v1.27.0)
# so the family can never drift into a GNU-only construct.
hits="$(for f in "$SCRIPTS_DIR"/lib.sh "$SCRIPTS_DIR"/install.sh "$SCRIPTS_DIR"/claude-*.sh "$SCRIPTS_DIR"/kimi-*.sh; do sed 's/#.*//' "$f"; done 2>/dev/null | grep -c 'readlink -f')"
assert_eq 0 "$hits" "zero 'readlink -f' invocations in runtime scripts"

it "no committed proof artifact contains a literal secret"
# Regression guard for the H2 incident: live proof files (opencode debug config /
# mcp list) once committed a real API key + a DB connection-string password.
# We count *suspect* lines rather than print them, so a failure never re-echoes a
# secret into the test log. Provider-key prefixes + URL user:password@ are the
# signatures; redacted placeholders carry the word REDACTED and are excluded.
proof_dir="$SCRIPTS_DIR/tests/proof"
if [[ -d "$proof_dir" ]]; then
  # Prefixes match only at a TOKEN BOUNDARY (line start or a non-word char
  # before them): a real leaked key appears after a quote/=/:/space (e.g.
  # "api_key":"sk-ant-…"), never embedded mid-identifier. Without the boundary,
  # innocent identifiers captured in build/log noise false-positive — e.g. `re_`
  # inside a Go-cache path `reti​re_connection_id_frame_test.go`, or `secret_`
  # inside `my_secret_value`.
  leaks="$(grep -rIE \
    -e '(^|[^A-Za-z0-9_-])(sk-ant-|sk-|gsk_|xai-|hf_|AIza|xoxb-|xoxp-|xoxs-|pc-|re_|secret_|ghp_|github_pat_|AKIA)[A-Za-z0-9_-]{12,}' \
    -e '://[^:/@ "]+:[^@/ "]{4,}@' \
    -e 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' \
    "$proof_dir" 2>/dev/null | grep -vc 'REDACTED' || true)"
  [[ -z "$leaks" ]] && leaks=0
  assert_eq 0 "$leaks" "proof dir free of literal secrets (suspect-line count)"
else
  _pass "no proof dir on this host (nothing to scan)"
fi

# Regression guard for the token-boundary anchor (a Go-cache path
# `retire_connection_id_frame_test.go` in captured build noise once false-
# positived on the `re_` prefix). The scanner MUST ignore a secret prefix
# embedded mid-identifier, yet still catch a real key at a token boundary.
it "proof-secret scanner: boundary-anchored (embedded prefix ignored, real key caught)"
_scan_fx="$(mktemp -d "${TMPDIR:-/tmp}/cma-scanfx.XXXXXX")"
{
  echo "rm: cannot remove '/go/pkg/mod/quic-go/internal/wire/retire_connection_id_frame_test.go'"
  echo "my_secret_value_identifier_here = 1"
} > "$_scan_fx/noise.log"
printf '"api_key":"sk-ant-abc123def456ghi789jkl"\n' > "$_scan_fx/leak.log"
_scan_re='(^|[^A-Za-z0-9_-])(sk-ant-|sk-|gsk_|xai-|hf_|AIza|xoxb-|xoxp-|xoxs-|pc-|re_|secret_|ghp_|github_pat_|AKIA)[A-Za-z0-9_-]{12,}'
_scan_noise="$(grep -cE "$_scan_re" "$_scan_fx/noise.log" || true)"
_scan_leak="$(grep -cE "$_scan_re" "$_scan_fx/leak.log" || true)"
assert_eq 0 "${_scan_noise:-0}" "embedded prefixes (retire_/my_secret_) are NOT flagged"
assert_eq 1 "${_scan_leak:-0}" "a real boundary-anchored sk-ant- key IS flagged"
rm -rf "$_scan_fx"

# cma_merge_claude_json must UNION the projects subtree across accounts while
# keeping each account's private auth keys (userID/oauthAccount/...) to ITSELF.
# A regression here would either lose sessions (no union) or leak credentials
# between accounts (CRITICAL). Locks the property verified by hand this session.
it "cma_merge_claude_json: private keys stay per-account; projects union (no credential leak)"
if command -v jq >/dev/null 2>&1; then
  mj_a="$SANDBOX_HOME/.mrg-a"; mj_b="$SANDBOX_HOME/.mrg-b"; mkdir -p "$mj_a" "$mj_b"
  printf '%s\n' '{"userID":"UID-A","oauthAccount":"a@x","projects":{"pa":{"v":1}}}' > "$mj_a/.claude.json"
  printf '%s\n' '{"userID":"UID-B","oauthAccount":"b@x","projects":{"pb":{"v":2}}}' > "$mj_b/.claude.json"
  cma_merge_claude_json "$mj_a" "$mj_b" >/dev/null 2>&1
  assert_eq "UID-A" "$(jq -r .userID "$mj_a/.claude.json")" "account A keeps its OWN userID after merge"
  assert_eq "UID-B" "$(jq -r .userID "$mj_b/.claude.json")" "account B keeps its OWN userID after merge"
  assert_eq '["pa","pb"]' "$(jq -rc '.projects|keys' "$mj_a/.claude.json")" "A sees both projects (union)"
  assert_eq '["pa","pb"]' "$(jq -rc '.projects|keys' "$mj_b/.claude.json")" "B sees both projects (union)"
  mj_leak=0
  grep -q 'UID-B\|b@x' "$mj_a/.claude.json" && mj_leak=1
  grep -q 'UID-A\|a@x' "$mj_b/.claude.json" && mj_leak=1
  assert_eq 0 "$mj_leak" "no cross-account credential leak in either direction"
else
  _pass "jq absent — skipping cma_merge_claude_json security test"
fi

it "cma_ensure_alias_file generates cma_run with project-scoped cwd-hook resolution"
# Verify the emitted cma_run body has the _cma_hook_root marker (project-local
# .claude-cwd-hook support) and the three-tier resolution order:
# 1. CMA_CWD_HOOK env var  2. <git-toplevel>/.claude-cwd-hook  3. global fallback
_mig_ph="$ALIAS_FILE.ph"
cat > "$_mig_ph" <<'PHFMT'
export CLAUDE_BIN="/usr/bin/true"

cma_run() {
  "$CLAUDE_BIN" "$@"
}

alias claude1="CLAUDE_CONFIG_DIR=$SANDBOX_HOME/.claude-1 cma_run"
PHFMT
( ALIAS_FILE="$_mig_ph" cma_ensure_alias_file ) >/dev/null 2>&1
# Extract the regenerated cma_run body and check the markers
_ph_body="$(awk '/^cma_run\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$_mig_ph")"
grep -q '_cma_hook_root' <<<"$_ph_body"; assert_eq 0 $? "cma_run has _cma_hook_root marker (project-scoped hook support)"
# With no CMA_CWD_HOOK set, should check git toplevel first, then global
grep -q 'git rev-parse --show-toplevel' <<<"$_ph_body"; assert_eq 0 $? "cma_run resolves git toplevel for project-local hook"
grep -q '\.claude-cwd-hook' <<<"$_ph_body"; assert_eq 0 $? "cma_run checks for .claude-cwd-hook in project root"
grep -q 'CMA_CWD_HOOK:-' <<<"$_ph_body"; assert_eq 0 $? "cma_run respects CMA_CWD_HOOK env var override"
grep -q '.local/bin/claude-cwd-hook' <<<"$_ph_body"; assert_eq 0 $? "cma_run falls back to global claude-cwd-hook"
rm -f "$_mig_ph"

# --- wrapper self-heal is unconditional, not marker-driven -------------------
# HISTORY: cma_ensure_alias_file used to decide whether to regenerate each
# wrapper by matching ~22 "markers" against the on-disk body, then DROPPING the
# function block and re-appending it. That drop-then-re-append left the file
# without the function between two separate whole-file writes — one half of the
# concurrency race that destroyed the live alias file (see the alias-file
# section header in lib.sh). The renderer now always emits the current wrapper
# text, so there is no marker list, no drop window, and no stale body can
# survive a write.
#
# What still must hold: emitting the current body may never be short-circuited
# by a cached version stamp. A corrupted body with an intact stamp line would
# otherwise be wrongly trusted and the self-heal skipped
# (test_128k_output_clamp.sh deliberately constructs exactly that shape).
# The behavioural half of this is the cwd-hook regeneration test above, which
# feeds in a stale cma_run body and asserts the current one comes back.
it "wrapper regeneration has no marker/version-stamp short-circuit"
_mk_body="$(awk '/^_cma_alias_render\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$SCRIPTS_DIR/lib.sh")
$(awk '/^_cma_emit_managed\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$SCRIPTS_DIR/lib.sh")"
_mk_stamp="$(grep -ciE 'version.?stamp|CMA_ALIAS_VERSION' <<<"$_mk_body" || true)"
assert_eq 0 "$_mk_stamp" "no version-stamp short-circuit (would skip a needed self-heal)"
_mk_cond="$(grep -cE 'grep -q.*cma_run(_provider)?\(\)' <<<"$_mk_body" || true)"
assert_eq 0 "$_mk_cond" "wrapper emission is unconditional (not gated on the old body)"

it "\$ALIAS_FILE has exactly one writer"
# Nothing outside cma_alias_commit may write, append to, or rename onto the
# alias file. That single-committer property is what makes the exclusive lock
# and the sanity gate impossible to bypass — the incident was two writers, each
# individually correct, interleaving.
_wr="$(grep -nE '(command )?mv +-?f? *"?\$[A-Za-z_]+" *"\$ALIAS_FILE"|> *"\$ALIAS_FILE"|>> *"\$ALIAS_FILE"' \
        "$SCRIPTS_DIR"/*.sh | grep -v ':[0-9]*: *#' || true)"
_wr_n="$(printf '%s\n' "$_wr" | grep -c . || true)"
assert_eq 1 "$_wr_n" "exactly one writer of \$ALIAS_FILE remains" "$_wr"

# ===========================================================================
# The ccr self-reference guard: ONE definition, and it matches the whole shape
# ===========================================================================
# The original guard was a `case` listing four literal spellings, DUPLICATED in
# lib.sh's launch gate and providers-verify.sh's Gate 0. Everything it did not
# literally list went through — including `127.0.1.1:3456`, which is Debian's
# default loopback for the local hostname, i.e. a form that IS the gateway on a
# stock install. Both halves matter and both are asserted here: that the two
# call sites share one definition, and that the definition covers the shape.
it "the ccr-gateway guard has exactly one definition (no drifting copy)"
# lib.sh owns it; providers-verify.sh must CALL it, never re-implement it.
_gw_defs="$(grep -c '^_cma_is_ccr_gateway() {' "$SCRIPTS_DIR/lib.sh" || true)"
assert_eq 1 "${_gw_defs:-0}" "_cma_is_ccr_gateway defined once in lib.sh"
_gw_dup="$(grep -c '_cma_is_ccr_gateway() {' "$SCRIPTS_DIR/providers-verify.sh" || true)"
assert_eq 0 "${_gw_dup:-0}" "providers-verify.sh does not re-define it"
_gw_call="$(grep -c '_cma_is_ccr_gateway ' "$SCRIPTS_DIR/providers-verify.sh" || true)"
_gw_ok=1; (( _gw_call >= 1 )) && _gw_ok=0
assert_eq 0 "$_gw_ok" "providers-verify.sh calls the shared helper"
# The literal-spelling `case` that under-matched must be gone from both.
_gw_legacy="$(grep -cE '127\.0\.0\.1:"?\$(_ccr_port|\{CMA_CCR_PORT)' \
               "$SCRIPTS_DIR/lib.sh" "$SCRIPTS_DIR/providers-verify.sh" 2>/dev/null \
             | awk -F: '{s+=$2} END{print s+0}')"
assert_eq 0 "${_gw_legacy:-0}" "the duplicated literal-spelling case is gone"

it "the ccr-gateway guard matches every form that IS the gateway"
# Each of these resolves to the local ccr gateway on port 3456. Every one of
# them was ALLOWED through by the old guard.
_gw_missed=""
for _u in \
  'http://127.0.0.1:3456/v1' \
  'http://localhost:3456/v1' \
  'http://[::1]:3456/v1' \
  'http://0.0.0.0:3456/v1' \
  'http://127.0.1.1:3456/v1' \
  'http://127.0.0.2:3456/v1' \
  'http://127.255.255.254:3456/v1' \
  'http://[::ffff:127.0.0.1]:3456/v1' \
  'http://[0:0:0:0:0:0:0:1]:3456/v1' \
  'http://[0::1]:3456/v1' \
  'http://LOCALHOST:3456/v1' \
  'http://LocalHost:3456' \
  'http://user@127.0.0.1:3456/v1' \
  'http://user:pw@localhost:3456/v1' \
  'http://127.0.0.1:3456?x=1' \
  'http://127.0.0.1:3456#frag' \
  'http://127.0.0.1:3456/v1?x=1' \
  'http://127.0.0.1:3456' \
; do
  _cma_is_ccr_gateway "$_u" || _gw_missed="$_gw_missed $_u"
done
assert_eq "" "$_gw_missed" "no gateway spelling slips through" "missed:$_gw_missed"

it "the ccr-gateway guard does NOT false-positive on legitimate bases"
# A guard that refuses everything is not a fix. These must all still launch.
_gw_false=""
for _u in \
  'http://127.0.0.1:8080/v1' \
  'http://127.0.0.1:3457/v1' \
  'http://localhost:3457/v1' \
  'http://localhost/v1' \
  'https://api.deepseek.com/anthropic' \
  'https://api.z.ai/api/coding/paas/v4' \
  'https://openrouter.ai/api/v1' \
  'http://192.168.1.10:3456/v1' \
  'http://10.0.0.5:3456/v1' \
  'https://127.0.0.1.example.com:3456/v1' \
  'http://[fe80::1]:3456/v1' \
  'http://[2001:db8::1]:3456/v1' \
  'https://api.test/v1' \
  'http://myhost:3456/v1' \
; do
  _cma_is_ccr_gateway "$_u" && _gw_false="$_gw_false $_u"
done
assert_eq "" "$_gw_false" "no legitimate base is swept up" "false positives:$_gw_false"

it "the ccr-gateway guard honours a non-default CMA_CCR_PORT"
( CMA_CCR_PORT=9999; _cma_is_ccr_gateway 'http://127.0.0.1:9999/v1' ); assert_eq 0 $? "9999 is the gateway when CMA_CCR_PORT=9999"
( CMA_CCR_PORT=9999; _cma_is_ccr_gateway 'http://127.0.0.1:3456/v1' ); assert_eq 1 $? "3456 is NOT the gateway when CMA_CCR_PORT=9999"

# ===========================================================================
# Account detection must not count directories that are no longer accounts
# ===========================================================================
it "cma_detect_accounts ignores archived (.removed.*) and .preunify.* dirs"
# claude-remove-account's DEFAULT (non---delete) mode renames the config dir to
# `<dir>.removed.<ts>`, which keeps its projects/ marker. Counting those kept
# the detected total permanently above the alias count, and _cma_alias_gate's
# account floor arms only while `src_acct >= n_acct` — so a single ordinary
# removal disarmed that floor forever on that host.
_det_home="$(mktemp -d "$HOME/detect.XXXXXX")"
mkdir -p "$_det_home/.claude-one/projects" "$_det_home/.claude-two/projects"
mkdir -p "$_det_home/.claude-three.removed.20260101120000/projects"
mkdir -p "$_det_home/.claude-four.preunify.20260101120000/projects"
_det_n="$( HOME="$_det_home" cma_detect_accounts | wc -l | tr -d ' ' )"
assert_eq 2 "$_det_n" "only the two live accounts are detected" \
  "$(HOME="$_det_home" cma_detect_accounts)"
_det_arch="$( HOME="$_det_home" cma_detect_accounts | grep -c 'removed\|preunify' || true )"
assert_eq 0 "${_det_arch:-0}" "no archived dir appears in the detected set"

# ===========================================================================
# The renderer must not report success for a write it did not make
# ===========================================================================
it "_cma_alias_render propagates an output write failure"
# The `{ ... } > \$out` status used to be discarded and the function always
# returned 0. A candidate truncated by ENOSPC then reached the committer as a
# successful render — and against a zero-alias source such a stump also clears
# the sanity gate, which only requires the header plus the two wrapper opening
# lines and has no aliases left to miss.
rm -f "$ALIAS_FILE"; cma_ensure_alias_file >/dev/null 2>&1
# (a) the output path cannot be opened at all
( _cma_alias_render "$ALIAS_FILE" "" "" keep "$HOME/no/such/dir/cand" ) >/dev/null 2>&1
assert_eq 1 $? "an unopenable output path is a failed render"
# (b) a genuine ENOSPC. /dev/full accepts the open and fails every write, which
#     is the real shape of the hazard. Linux-only; skipped elsewhere.
if [[ -w /dev/full ]]; then
  ( _cma_alias_render "$ALIAS_FILE" "" "" keep /dev/full ) >/dev/null 2>&1
  assert_eq 1 $? "an ENOSPC write (/dev/full) is a failed render"
else
  _pass "SKIP (no writable /dev/full on this platform)"
fi
# CONTROL: a healthy render still succeeds.
( _cma_alias_render "$ALIAS_FILE" "" "" keep "$HOME/.cand-ok" ) >/dev/null 2>&1
assert_eq 0 $? "CONTROL: a normal render still returns success"

# ===========================================================================
# The alias lock is scoped to the file it guards, not to the host
# ===========================================================================
it "the alias lock is per-\$ALIAS_FILE — two alias files never contend"
# Deliberately the OPPOSITE of tests/lib/suite-lock.sh, which is global by
# design (one suite run per checkout, lock in the git dir). If this lock were
# global, every sandbox — and every $HOME on a multi-user box — would serialize
# against unrelated runs for up to CMA_ALIAS_LOCK_WAIT.
_lk_a="$HOME/lockscope-a/aliases.sh"
_lk_b="$HOME/lockscope-b/aliases.sh"
mkdir -p "$(dirname "$_lk_a")" "$(dirname "$_lk_b")"
cat > "$HOME/lockscope-hold.sh" <<'LK_EOF'
#!/usr/bin/env bash
set -uo pipefail
source "$SCRIPTS_DIR/lib.sh"; set +e
_cma_alias_lock_acquire || exit 9
: > "$HOME/.lockscope-held"
sleep 4
LK_EOF
chmod +x "$HOME/lockscope-hold.sh"
rm -f "$HOME/.lockscope-held"
SCRIPTS_DIR="$SCRIPTS_DIR" ALIAS_FILE="$_lk_a" "$HOME/lockscope-hold.sh" & _lk_pid=$!
_lk_w=0
while [[ ! -f "$HOME/.lockscope-held" ]] && (( _lk_w < 400 )); do sleep 0.01 2>/dev/null || sleep 1; _lk_w=$(( _lk_w + 1 )); done
# B must acquire instantly even at zero wait: it protects a DIFFERENT file.
SCRIPTS_DIR="$SCRIPTS_DIR" ALIAS_FILE="$_lk_b" CMA_ALIAS_LOCK_WAIT=0 bash -c '
  source "$SCRIPTS_DIR/lib.sh"; set +e; _cma_alias_lock_acquire' >/dev/null 2>&1
assert_eq 0 $? "a lock on alias file B is unaffected by a holder of alias file A"
# CONTROL: the same file DOES contend — otherwise the assertion above is vacuous.
SCRIPTS_DIR="$SCRIPTS_DIR" ALIAS_FILE="$_lk_a" CMA_ALIAS_LOCK_WAIT=0 bash -c '
  source "$SCRIPTS_DIR/lib.sh"; set +e; _cma_alias_lock_acquire' >/dev/null 2>&1
assert_eq 1 $? "CONTROL: the SAME alias file still contends (the lock is real)"
kill "$_lk_pid" 2>/dev/null; wait "$_lk_pid" 2>/dev/null

summary
