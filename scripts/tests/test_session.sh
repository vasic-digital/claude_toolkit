#!/usr/bin/env bash
# test_session.sh — hermetic tests for claude-session.sh.
#
# Covers:
#   1. name   – kebab-case sanitization from dir basename
#   2. id     – stable, valid, unique UUID per project root
#   3. color  – palette membership and determinism
#   4. flags (first-run) – outputs --session-id + --name when no session file exists
#   5. flags (resume)    – outputs --resume when the session .jsonl is present
#   6. trust  – flags writes hasTrustDialogAccepted=true into <config_dir>/.claude.json
#   7. git-root – subdir shares the same session as the repo root
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
# lib.sh sets -e; tests assert on failures deliberately, so relax it.
set +e

SESSION_SH="$SCRIPTS_DIR/claude-session.sh"

# ── helper: run the session script from a specific directory ──────────────
# All invocations that need $PWD-sensitive behaviour (flags, id without path,
# name without path) should use this helper so the script sees the right $PWD.
run_session_from() {
  local dir="$1"; shift
  (cd "$dir" && bash "$SESSION_SH" "$@")
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 1. name – kebab-case sanitization
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

it "name: 'My_Cool-Project' → 'my-cool-project'"
proj_name1="$SANDBOX_HOME/My_Cool-Project"
mkdir -p "$proj_name1"
out1="$(bash "$SESSION_SH" name "$proj_name1")"
assert_eq "my-cool-project" "$out1" "mixed-case with dash/underscore → kebab-case"

it "name: 'Android 15' → 'android-15'"
proj_name2="$SANDBOX_HOME/Android 15"
mkdir -p "$proj_name2"
out2="$(bash "$SESSION_SH" name "$proj_name2")"
assert_eq "android-15" "$out2" "space in name → hyphen"

it "name: 'claude_toolkit' → 'claude-toolkit'"
proj_name3="$SANDBOX_HOME/claude_toolkit"
mkdir -p "$proj_name3"
out3="$(bash "$SESSION_SH" name "$proj_name3")"
assert_eq "claude-toolkit" "$out3" "underscores converted to hyphens"

it "name: no leading, trailing, or double hyphens in output"
proj_name4="$SANDBOX_HOME/__Weird--Name__"
mkdir -p "$proj_name4"
out4="$(bash "$SESSION_SH" name "$proj_name4")"
cond=1; [[ "$out4" != -* && "$out4" != *- && "$out4" != *--* ]] && cond=0
assert_eq 0 "$cond" "no leading/trailing/double hyphens (got: '$out4')"

it "name: strips leading and trailing whitespace"
proj_name5="$SANDBOX_HOME/  Spaced Out  "
mkdir -p "$proj_name5"
out5="$(bash "$SESSION_SH" name "$proj_name5")"
assert_eq "spaced-out" "$out5" "leading/trailing whitespace trimmed"

it "name: collapses multiple internal spaces to a single hyphen"
proj_name6="$SANDBOX_HOME/Too   Many    Spaces"
mkdir -p "$proj_name6"
out6="$(bash "$SESSION_SH" name "$proj_name6")"
assert_eq "too-many-spaces" "$out6" "multiple spaces collapsed to one hyphen"

it "name: strips special invalid characters (keeping alphanumerics and hyphens)"
proj_name7="$SANDBOX_HOME/My!@#Cool\$%^Project&*()"
mkdir -p "$proj_name7"
out7="$(bash "$SESSION_SH" name "$proj_name7")"
assert_eq "my-cool-project" "$out7" "special chars stripped, words joined by hyphen"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 2. id – stable UUID
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

it "id: returns a valid RFC-4122-shaped UUID"
proj_id="$SANDBOX_HOME/id_test_proj"
mkdir -p "$proj_id"
sid="$(bash "$SESSION_SH" id "$proj_id")"
cond=1; [[ "$sid" =~ $uuid_re ]] && cond=0
assert_eq 0 "$cond" "UUID shape valid (got: $sid)"

it "id: stable — two calls to the same directory give identical output"
sid1="$(bash "$SESSION_SH" id "$proj_id")"
sid2="$(bash "$SESSION_SH" id "$proj_id")"
assert_eq "$sid1" "$sid2" "id is deterministic across calls"

it "id: different project directories produce different UUIDs"
proj_alpha="$SANDBOX_HOME/proj_alpha"
proj_beta="$SANDBOX_HOME/proj_beta"
mkdir -p "$proj_alpha" "$proj_beta"
sid_a="$(bash "$SESSION_SH" id "$proj_alpha")"
sid_b="$(bash "$SESSION_SH" id "$proj_beta")"
cond=1; [[ "$sid_a" != "$sid_b" ]] && cond=0
assert_eq 0 "$cond" "alpha ($sid_a) ≠ beta ($sid_b)"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 3. color – palette membership and determinism
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

palette_re='^(red|blue|green|yellow|purple|orange|pink|cyan)$'

it "color: each label maps to a known palette color"
for _label in claude1 claude2 work personal xiaomi; do
  _col="$(bash "$SESSION_SH" color "$_label")"
  cond=1; [[ "$_col" =~ $palette_re ]] && cond=0
  assert_eq 0 "$cond" "label '$_label' → '$_col' is in palette"
done

it "color: same label always maps to the same color (deterministic)"
col_a="$(bash "$SESSION_SH" color "myalias")"
col_b="$(bash "$SESSION_SH" color "myalias")"
assert_eq "$col_a" "$col_b" "color stable for 'myalias'"

it "color: empty label does not error and returns a palette color"
col_empty="$(bash "$SESSION_SH" color "" 2>/dev/null)"
cond=1; [[ "$col_empty" =~ $palette_re ]] && cond=0
assert_eq 0 "$cond" "empty label → '$col_empty' (in palette)"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 4. flags – first-run (no session file present)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

it "flags first-run: output contains '--session-id' and '--name', not '--resume'"
proj_fr="$SANDBOX_HOME/first_run_proj"
cfg_fr="$SANDBOX_HOME/cfg_first_run"
mkdir -p "$proj_fr" "$cfg_fr"
flags_fr="$(run_session_from "$proj_fr" flags "$cfg_fr")"
cond=1; [[ "$flags_fr" == *"--session-id"* ]] && cond=0
assert_eq 0 "$cond" "first-run output contains --session-id"
cond=1; [[ "$flags_fr" == *"--name"* ]] && cond=0
assert_eq 0 "$cond" "first-run output contains --name"
cond=1; [[ "$flags_fr" != *"--resume"* ]] && cond=0
assert_eq 0 "$cond" "first-run output does NOT contain --resume"

it "flags first-run: --name matches the kebab-case of the project dir basename"
expected_kebab="first-run-proj"
cond=1; [[ "$flags_fr" == *"--name $expected_kebab"* ]] && cond=0
assert_eq 0 "$cond" "flags --name is '$expected_kebab' (got: $flags_fr)"

it "flags first-run: --session-id is a valid UUID"
# Extract the word immediately following --session-id.
sid_fr="$(printf '%s' "$flags_fr" | sed -E 's/.*--session-id ([^ ]+).*/\1/')"
cond=1; [[ "$sid_fr" =~ $uuid_re ]] && cond=0
assert_eq 0 "$cond" "flags --session-id is a valid UUID (got: $sid_fr)"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 5. flags – resume (session .jsonl already exists)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

it "flags resume: when session .jsonl exists, output is '--resume <uuid> --name <kebab>'"
proj_res="$SANDBOX_HOME/resume_proj"
cfg_res="$SANDBOX_HOME/cfg_resume"
mkdir -p "$proj_res" "$cfg_res"

# The UUID and slug must match what the script itself would compute when run
# from inside $proj_res.  Use the same invocations so path canonicalisation
# (pwd -P) is handled identically on both sides. Slug uses the PER-CHAR rule
# (s/[^A-Za-z0-9]/-/g) — claude's real on-disk slug does NOT collapse runs.
res_sid="$(run_session_from "$proj_res" id)"
res_root="$(cd "$proj_res" && pwd -P)"
res_slug="$(printf '%s' "$res_root" | sed -E 's/[^A-Za-z0-9]/-/g')"
res_name="$(run_session_from "$proj_res" name)"

sess_dir="$cfg_res/projects/$res_slug"
mkdir -p "$sess_dir"
printf '{"type":"user","content":"hello"}\n' > "$sess_dir/$res_sid.jsonl"

flags_res="$(run_session_from "$proj_res" flags "$cfg_res")"
# Resume now ALSO carries --name: re-passing the name on --resume is what lets an
# existing UNNAMED session finally get named (proven live on claude 2.1.195:
# `claude --resume <id> --name <x>` sets custom-title <NONE> -> <x>).
assert_eq "--resume $res_sid --name $res_name" "$flags_res" "resume output is '--resume <uuid> --name <snake>'"

it "flags resume: output carries --name (renames legacy unnamed sessions), no --session-id"
cond=1; [[ "$flags_res" != *"--session-id"* ]] && cond=0
assert_eq 0 "$cond" "resume output has no --session-id"
cond=1; [[ "$flags_res" == *"--name $res_name"* ]] && cond=0
assert_eq 0 "$cond" "resume output carries --name $res_name"

# Regression for the per-char slug fix: a project path with CONSECUTIVE
# non-alnum chars (e.g. a hidden '/.cfg/' segment) must still resolve to claude's
# real slug so an existing session is RESUMED, not re-created. The old collapsing
# slug (s/…+/-/g) produced a single '-' here and false-negatived the lookup.
it "flags resume: consecutive separators in the path still resume (per-char slug)"
proj_cs="$SANDBOX_HOME/.cfg/cs_proj"
cfg_cs="$SANDBOX_HOME/cfg_cs"
mkdir -p "$proj_cs" "$cfg_cs"
cs_sid="$(run_session_from "$proj_cs" id)"
cs_root="$(cd "$proj_cs" && pwd -P)"
cs_slug="$(printf '%s' "$cs_root" | sed -E 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$cfg_cs/projects/$cs_slug"
printf '{"type":"user","content":"hi"}\n' > "$cfg_cs/projects/$cs_slug/$cs_sid.jsonl"
flags_cs="$(run_session_from "$proj_cs" flags "$cfg_cs")"
cond=1; [[ "$flags_cs" == "--resume $cs_sid"* ]] && cond=0
assert_eq 0 "$cond" "path with '/.' resumes (not re-creates); got: $flags_cs"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 6. trust – flags writes hasTrustDialogAccepted=true into .claude.json
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

it "trust: .claude.json gains hasTrustDialogAccepted=true after a flags call"
proj_trust="$SANDBOX_HOME/trust_proj"
cfg_trust="$SANDBOX_HOME/cfg_trust"
mkdir -p "$proj_trust" "$cfg_trust"
run_session_from "$proj_trust" flags "$cfg_trust" > /dev/null 2>&1

trust_file="$cfg_trust/.claude.json"
assert_file "$trust_file" ".claude.json was created by flags"

# The project key stored by the script is cma_project_root($PWD) = pwd -P.
trust_root="$(cd "$proj_trust" && pwd -P)"
assert_jq "$trust_file" \
  ".projects[\"$trust_root\"].hasTrustDialogAccepted" \
  "true" \
  "hasTrustDialogAccepted is true for $trust_root"

it "trust: repeated flags calls are idempotent (file stays valid JSON)"
run_session_from "$proj_trust" flags "$cfg_trust" > /dev/null 2>&1
run_session_from "$proj_trust" flags "$cfg_trust" > /dev/null 2>&1
# jq must still be able to parse the file after multiple writes.
trust_val="$(jq -r ".projects[\"$trust_root\"].hasTrustDialogAccepted" "$trust_file" 2>/dev/null || echo '<jq-error>')"
assert_eq "true" "$trust_val" "trust flag still true after repeated flags calls"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 7. git-root – subdir shares the same session as the repo root
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

it "git-root: id and name from a deep subdir match those from the repo root"
if ! command -v git >/dev/null 2>&1; then
  _pass "git not available on this host — skipping git-root test"
else
  git_repo="$SANDBOX_HOME/git_root_test"
  mkdir -p "$git_repo"
  # Suppress "hints" noise; we only need git to recognise the directory.
  git -C "$git_repo" init -q 2>/dev/null || git -C "$git_repo" init 2>/dev/null

  subdir="$git_repo/src/deep/nested"
  mkdir -p "$subdir"

  id_from_root="$(run_session_from "$git_repo" id)"
  id_from_sub="$(run_session_from "$subdir"   id)"
  assert_eq "$id_from_root" "$id_from_sub" \
    "id is identical from repo root and deep subdir"

  name_from_root="$(run_session_from "$git_repo" name)"
  name_from_sub="$(run_session_from "$subdir"   name)"
  assert_eq "$name_from_root" "$name_from_sub" \
    "name is identical from repo root and deep subdir"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 8. apply-color – inject the per-alias agent-color into the session jsonl
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

it "apply-color: writes the alias colour into a session that has none (set -e regression)"
ac_proj="$SANDBOX_HOME/ac_proj"; ac_cfg="$SANDBOX_HOME/ac_cfg"
mkdir -p "$ac_proj"
ac_sid="$(run_session_from "$ac_proj" id)"
ac_root="$(cd "$ac_proj" && pwd -P)"; ac_slug="$(printf '%s' "$ac_root" | sed -E 's/[^A-Za-z0-9]/-/g')"
ac_sf="$ac_cfg/projects/$ac_slug/$ac_sid.jsonl"
mkdir -p "$(dirname "$ac_sf")"
printf '{"type":"user","content":"hi"}\n' > "$ac_sf"   # session with NO agent-color record
ac_color="$(run_session_from "$ac_proj" color alias_one)"
run_session_from "$ac_proj" apply-color "$ac_cfg" alias_one
ac_got="$(grep '"type":"agent-color"' "$ac_sf" 2>/dev/null | tail -1 | sed -E 's/.*"agentColor":"([^"]*)".*/\1/')"
assert_eq "$ac_color" "$ac_got" "agent-color for alias_one written (=$ac_color)"

it "apply-color: idempotent — same alias does not append a duplicate"
ac_b="$(grep -c '"type":"agent-color"' "$ac_sf")"
run_session_from "$ac_proj" apply-color "$ac_cfg" alias_one
ac_a="$(grep -c '"type":"agent-color"' "$ac_sf")"
assert_eq "$ac_b" "$ac_a" "no duplicate agent-color on re-apply"

it "apply-color: switching alias re-colours the session"
ac_color2="$(run_session_from "$ac_proj" color alias_two)"
run_session_from "$ac_proj" apply-color "$ac_cfg" alias_two
ac_got2="$(grep '"type":"agent-color"' "$ac_sf" 2>/dev/null | tail -1 | sed -E 's/.*"agentColor":"([^"]*)".*/\1/')"
assert_eq "$ac_color2" "$ac_got2" "session colour follows the current alias (=$ac_color2)"

it "apply-color: no-op (exit 0) when the session file does not exist yet"
ac_empty="$SANDBOX_HOME/ac_empty"; mkdir -p "$ac_empty"
run_session_from "$ac_empty" apply-color "$ac_cfg" alias_one; rc=$?
assert_eq 0 "$rc" "apply-color returns 0 when no session file exists"

# --- hint: EXECUTE it (cma_run calls `claude-session hint` on every bare launch;
# previously this path was only string-matched in the wrapper body, never run) --
it "hint: EXECUTES cleanly and writes the project + colour to stderr only"
hint_proj="$SANDBOX_HOME/Hint_Demo"; mkdir -p "$hint_proj"
hint_out="$(run_session_from "$hint_proj" hint claude2 2>/dev/null)"            # stdout only
hint_err="$(run_session_from "$hint_proj" hint claude2 2>&1 1>/dev/null)"; hint_rc=$?
assert_eq 0 "$hint_rc" "hint exits 0 (no set -e abort)"
assert_eq "" "$hint_out" "hint writes nothing to stdout (must not pollute the launch)"
grep -q 'hint-demo' <<<"$hint_err"; assert_eq 0 $? "hint stderr names the kebab-case project"
grep -q 'alias color:' <<<"$hint_err"; assert_eq 0 $? "hint stderr states the alias colour"

it "hint: EXECUTES with an empty label (edge case) without aborting"
run_session_from "$hint_proj" hint >/dev/null 2>&1; assert_eq 0 $? "hint with no label exits 0"

# --- cma_project_root branches (exercised via `name`): git-toplevel + pwd -P ---
# `name` was only tested on non-git sandbox dirs (the pwd -P branch). Cover the
# git-rev-parse branch and the symlink-resolution behaviour (the macOS
# /tmp -> /private/tmp class that already bit a live test).
if command -v git >/dev/null 2>&1; then
  it "name: a git subdir resolves to the repo TOPLEVEL basename (project-root git branch)"
  gitrepo="$SANDBOX_HOME/My_Repo"; mkdir -p "$gitrepo/src/deep"
  git -C "$gitrepo" init -q >/dev/null 2>&1
  name_git="$(bash "$SESSION_SH" name "$gitrepo/src/deep")"
  assert_eq "my-repo" "$name_git" "git subdir resolves to repo toplevel basename, kebab-cased"
fi

it "name: a symlinked project dir resolves to its physical basename (pwd -P branch)"
phys="$SANDBOX_HOME/Phys_Proj"; mkdir -p "$phys"
ln -s "$phys" "$SANDBOX_HOME/link_proj" 2>/dev/null
name_link="$(bash "$SESSION_SH" name "$SANDBOX_HOME/link_proj")"
assert_eq "phys-proj" "$name_link" "symlinked dir resolves via pwd -P to the physical basename"

# --- S12.7.0 pipefail + head SIGPIPE regression guard ---
# When a project has many session files, `ls -t ... | head -1`
# triggers SIGPIPE because head exits before grep, and `set -o pipefail`
# turns that into exit 141 which `set -e` treats as fatal.  Without
# the `|| true` guard in cma_latest_session_id, EVERY launch becomes a
# "first run" creating a brand-new session instead of resuming the
# shared one.  This test creates 200 dummy session files and proves
# the resolution still finds the most recent AND returns --resume.
it "flags: many-session stress (200 files) to exercise pipefail SIGPIPE guard"
many_proj="$SANDBOX_HOME/Many_Sessions_Proj"; mkdir -p "$many_proj"
many_cfg="$SANDBOX_HOME/.claude-many"
many_proj_slug="$(printf '%s' "$many_proj" | sed -E 's/[^A-Za-z0-9]/-/g')"
many_sess_dir="$many_cfg/projects/$many_proj_slug"
mkdir -p "$many_sess_dir"
for _m_i in $(seq 1 200); do
  touch "$many_sess_dir/dummy-$_m_i-$(printf '%032s' "$_m_i" | tr ' ' '0').jsonl"
done
sleep 1
_m_known_id="$(bash "$SESSION_SH" id "$many_proj")"
_m_known_name="$(bash "$SESSION_SH" name "$many_proj")"
mkdir -p "$many_sess_dir"
touch "$many_sess_dir/$_m_known_id.jsonl"
_m_flags="$(run_session_from "$many_proj" flags "$many_cfg")"
grep -q "^--resume $_m_known_id" <<<"$_m_flags"; rc=$?
assert_eq 0 $rc "stress: flags returns --resume with 200 files pipefail guard"
grep -q "$_m_known_name" <<<"$_m_flags"; rc=$?
assert_eq 0 $rc "stress: flags carries --name $_m_known_name"
_m_latest="$(run_session_from "$many_proj" latest-id "$many_cfg")"
assert_eq "$_m_known_id" "$_m_latest" "stress: latest-id returns the most recent session"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 9. degenerate-session skip + context-size (2026-09-03 compaction-loop cascade)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Forensic root cause (scratch/discovery/compaction_loop_forensics.md): 35
# near-identical ~319KB transcripts, each a launch that loaded a large resumed
# context under a small provider window and died with ZERO assistant events.
# Because the store is shared across aliases and resolution was purely
# mtime-based, every such dead transcript became the NEXT launch's resume
# target — the cascade that made the loop endless. Resolution must skip a
# transcript that is BOTH assistant-free AND large (a died-on-load resume
# attempt), while a small assistant-free file (user typed one prompt and quit)
# must STILL resume — that continuity is the feature.
#
# A "dead" transcript: no '"type":"assistant"' line AND size above
# CMA_SESSION_DEAD_BYTES (default 65536 — far above any one-prompt file, far
# below the ~319KB reload debris observed live).

mk_dead() { # mk_dead <file> <bytes> — an assistant-free transcript of ~bytes
  local f="$1" n="$2" line
  line='{"type":"user","content":"'"$(printf 'x%.0s' $(seq 1 1000))"'"}'
  : > "$f"
  while [ "$(wc -c < "$f")" -lt "$n" ]; do printf '%s\n' "$line" >> "$f"; done
}

it "degenerate: a large assistant-free transcript is skipped; the older LIVE session resumes"
dg_proj="$SANDBOX_HOME/Degen_Proj"; dg_cfg="$SANDBOX_HOME/cfg_degen"
mkdir -p "$dg_proj"
dg_root="$(cd "$dg_proj" && pwd -P)"; dg_slug="$(printf '%s' "$dg_root" | sed -E 's/[^A-Za-z0-9]/-/g')"
dg_dir="$dg_cfg/projects/$dg_slug"; mkdir -p "$dg_dir"
# Older LIVE session (user + assistant).
dg_live="11111111-2222-3333-4444-555555555555"
printf '{"type":"user","content":"hello"}\n{"type":"assistant","message":{"usage":{"input_tokens":10}}}\n' \
  > "$dg_dir/$dg_live.jsonl"
sleep 1
# Newer DEAD session: big, no assistant event.
dg_dead="99999999-8888-7777-6666-555555555555"
mk_dead "$dg_dir/$dg_dead.jsonl" 200000

dg_got="$(run_session_from "$dg_proj" existing-id "$dg_cfg")"
assert_eq "$dg_live" "$dg_got" "existing-id skips the dead 200KB transcript, returns the live one"
dg_got2="$(run_session_from "$dg_proj" latest-id "$dg_cfg")"
assert_eq "$dg_live" "$dg_got2" "latest-id skips the dead transcript too"
dg_flags="$(run_session_from "$dg_proj" flags "$dg_cfg")"
dg_ok=1; [[ "$dg_flags" == "--resume $dg_live"* ]] && dg_ok=0
assert_eq 0 "$dg_ok" "flags resumes the live session, not the dead one (got: $dg_flags)"

it "degenerate: ALL dead-and-large -> no resume target (fresh start, cascade broken)"
dg2_proj="$SANDBOX_HOME/Degen_All"; dg2_cfg="$SANDBOX_HOME/cfg_degen2"
mkdir -p "$dg2_proj"
dg2_root="$(cd "$dg2_proj" && pwd -P)"; dg2_slug="$(printf '%s' "$dg2_root" | sed -E 's/[^A-Za-z0-9]/-/g')"
dg2_dir="$dg2_cfg/projects/$dg2_slug"; mkdir -p "$dg2_dir"
mk_dead "$dg2_dir/aaaaaaaa-1111-2222-3333-444444444444.jsonl" 150000
mk_dead "$dg2_dir/bbbbbbbb-1111-2222-3333-444444444444.jsonl" 150000
dg2_got="$(run_session_from "$dg2_proj" existing-id "$dg2_cfg")"
assert_eq "" "$dg2_got" "existing-id is empty when every transcript died on load"
dg2_flags="$(run_session_from "$dg2_proj" flags "$dg2_cfg")"
dg2_ok=1; [[ "$dg2_flags" == "--session-id "* && "$dg2_flags" != *"--resume"* ]] && dg2_ok=0
assert_eq 0 "$dg2_ok" "flags falls back to a fresh --session-id (got: $dg2_flags)"

it "degenerate: a SMALL assistant-free transcript still resumes (one-prompt continuity)"
dg3_proj="$SANDBOX_HOME/Degen_Small"; dg3_cfg="$SANDBOX_HOME/cfg_degen3"
mkdir -p "$dg3_proj"
dg3_root="$(cd "$dg3_proj" && pwd -P)"; dg3_slug="$(printf '%s' "$dg3_root" | sed -E 's/[^A-Za-z0-9]/-/g')"
dg3_dir="$dg3_cfg/projects/$dg3_slug"; mkdir -p "$dg3_dir"
dg3_sid="cccccccc-1111-2222-3333-444444444444"
printf '{"type":"user","content":"hello?"}\n' > "$dg3_dir/$dg3_sid.jsonl"
dg3_got="$(run_session_from "$dg3_proj" existing-id "$dg3_cfg")"
assert_eq "$dg3_sid" "$dg3_got" "a 60-byte user-only session is NOT debris — resume it"

it "context-size: returns the LAST assistant usage sum (input + cache_creation + cache_read)"
cs_proj="$SANDBOX_HOME/Ctx_Proj"; cs_cfg="$SANDBOX_HOME/cfg_ctx"
mkdir -p "$cs_proj"
cs_root="$(cd "$cs_proj" && pwd -P)"; cs_slug="$(printf '%s' "$cs_root" | sed -E 's/[^A-Za-z0-9]/-/g')"
cs_dir="$cs_cfg/projects/$cs_slug"; mkdir -p "$cs_dir"
cs_sid="dddddddd-1111-2222-3333-444444444444"
cat > "$cs_dir/$cs_sid.jsonl" <<'EOF'
{"type":"user","content":"hi"}
{"type":"assistant","message":{"usage":{"input_tokens":1000,"cache_creation_input_tokens":200,"cache_read_input_tokens":50,"output_tokens":10}}}
{"type":"user","content":"more"}
{"type":"assistant","message":{"usage":{"input_tokens":5000,"cache_creation_input_tokens":0,"cache_read_input_tokens":300,"output_tokens":20}}}
EOF
cs_got="$(run_session_from "$cs_proj" context-size "$cs_cfg" "$cs_sid")"
assert_eq "5300" "$cs_got" "last assistant usage: 5000+0+300 = 5300 (output not counted)"

it "context-size: empty for a transcript with no usage data"
cs_got2="$(run_session_from "$cs_proj" context-size "$cs_cfg" "eeeeeeee-1111-2222-3333-444444444444")"
assert_eq "" "$cs_got2" "missing/usage-free session -> empty, never a crash"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 10. code-review 2026-09-04 hardening (degenerate classifier + env knobs)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

it "degenerate: a mid-line '\"type\":\"assistant\"' substring does NOT make debris resumable"
# The classifier used to grep the substring anywhere in the file; a pasted or
# malformed line merely CONTAINING it (here: inside a user content tail, so the
# line starts with "user") would mark reload debris resumable. The match is now
# anchored to the JSONL object start.
dg4_proj="$SANDBOX_HOME/Degen_Substr"; dg4_cfg="$SANDBOX_HOME/cfg_degen4"
mkdir -p "$dg4_proj"
dg4_root="$(cd "$dg4_proj" && pwd -P)"; dg4_slug="$(printf '%s' "$dg4_root" | sed -E 's/[^A-Za-z0-9]/-/g')"
dg4_dir="$dg4_cfg/projects/$dg4_slug"; mkdir -p "$dg4_dir"
dg4_sid="ffffffff-1111-2222-3333-444444444444"
dg4_line='{"type":"user","content":"pasted chunk: "type":"assistant" not really an event"}'
: > "$dg4_dir/$dg4_sid.jsonl"
while [ "$(wc -c < "$dg4_dir/$dg4_sid.jsonl")" -lt 100000 ]; do printf '%s\n' "$dg4_line" >> "$dg4_dir/$dg4_sid.jsonl"; done
dg4_got="$(run_session_from "$dg4_proj" existing-id "$dg4_cfg")"
assert_eq "" "$dg4_got" "large file whose only 'assistant' mention is mid-line is still debris -> no resume target"

it "degenerate: CMA_SESSION_DEAD_BYTES=0 degrades to the default (one-prompt continuity preserved)"
# A 0 override used to classify EVERY non-empty assistant-free transcript as
# debris, silently killing one-prompt continuity. 0/empty/non-numeric mean
# "use the default".
dg5_proj="$SANDBOX_HOME/Degen_Zero"; dg5_cfg="$SANDBOX_HOME/cfg_degen5"
mkdir -p "$dg5_proj"
dg5_root="$(cd "$dg5_proj" && pwd -P)"; dg5_slug="$(printf '%s' "$dg5_root" | sed -E 's/[^A-Za-z0-9]/-/g')"
dg5_dir="$dg5_cfg/projects/$dg5_slug"; mkdir -p "$dg5_dir"
dg5_sid="12121212-1111-2222-3333-444444444444"
printf '{"type":"user","content":"hello?"}\n' > "$dg5_dir/$dg5_sid.jsonl"
dg5_got="$(CMA_SESSION_DEAD_BYTES=0 run_session_from "$dg5_proj" existing-id "$dg5_cfg")"
assert_eq "$dg5_sid" "$dg5_got" "DEAD_BYTES=0 -> default 65536: the small user-only session still resumes"
dg5_dead="13131313-1111-2222-3333-444444444444"
mk_dead "$dg5_dir/$dg5_dead.jsonl" 200000
sleep 1
dg5_got2="$(CMA_SESSION_DEAD_BYTES=0 run_session_from "$dg5_proj" existing-id "$dg5_cfg")"
assert_eq "$dg5_sid" "$dg5_got2" "DEAD_BYTES=0 -> default: the 200KB dead transcript is still skipped"

it "no-arg subcommands do not abort under set -u when CLAUDE_CONFIG_DIR is unset"
# cma_latest_session_id / cma_existing_session_id / the main() subcommands used
# `${1:-$CLAUDE_CONFIG_DIR}`, which aborts with "unbound variable" when the
# caller passes no arg AND the env var is unset. Now guarded; empty config dir
# yields empty output / the deterministic fallback, never a crash.
nu_proj="$SANDBOX_HOME/NoUnset"; mkdir -p "$nu_proj"
nu_out="$(cd "$nu_proj" && env -u CLAUDE_CONFIG_DIR bash "$SESSION_SH" existing-id 2>&1)"
nu_rc=$?
assert_eq 0 "$nu_rc" "existing-id without arg and without CLAUDE_CONFIG_DIR exits 0"
assert_eq "" "$nu_out" "existing-id prints nothing (no config dir, no sessions)"
nu_out2="$(cd "$nu_proj" && env -u CLAUDE_CONFIG_DIR bash "$SESSION_SH" context-size 2>&1)"
nu_rc2=$?
assert_eq 0 "$nu_rc2" "context-size without arg and without CLAUDE_CONFIG_DIR exits 0"
assert_eq "" "$nu_out2" "context-size prints nothing (no config dir)"
nu_out3="$(cd "$nu_proj" && env -u CLAUDE_CONFIG_DIR bash "$SESSION_SH" flags 2>&1)"
nu_rc3=$?
assert_eq 0 "$nu_rc3" "flags without arg and without CLAUDE_CONFIG_DIR exits 0"
nu_ok3=1; [[ "$nu_out3" == "--session-id "* ]] && nu_ok3=0
assert_eq 0 "$nu_ok3" "flags still emits the fresh-session flags (got: $nu_out3)"

summary
