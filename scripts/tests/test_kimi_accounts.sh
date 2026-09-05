#!/usr/bin/env bash
# test_kimi_accounts.sh — exercises the Kimi family CLI scripts end-to-end:
#   * kimi-add-account creates the dir, links shared kimi items, and
#     registers a kimiN alias carrying KIMI_CODE_HOME
#   * duplicate / reserved-namespace aliases and headless --login refuse
#   * kimi-remove-account --archive / --delete drop the alias and archive or
#     delete the dir; unknown aliases error
#   * kimi-list-accounts reports the account with its links intact
#   * kimi-unify merges sessions + session_index.jsonl into $SHARED_DIR/kimi,
#     symlinks every account onto it, promotes the newest AGENTS.md, and
#     registers an alias for every detected account
#   * kimi-unify --rollback restores the .preunify.* backups and moves the
#     kimi shared area aside
#
# The kimi run_* / make_kimi_* helpers live HERE (local to this file) rather
# than in tests/lib/sandbox.sh — that shared file belongs to the whole suite,
# and the kimi family is the only consumer of these helpers.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
set +e

# ---- family-scoped helpers (local; see header comment) -----------------------
run_kimi_add_account()    { "$SCRIPTS_DIR/kimi-add-account.sh" "$@"; }
run_kimi_remove_account() { "$SCRIPTS_DIR/kimi-remove-account.sh" "$@"; }
run_kimi_list_accounts()  { "$SCRIPTS_DIR/kimi-list-accounts.sh" "$@"; }
run_kimi_unify()          { "$SCRIPTS_DIR/kimi-unify.sh" "$@"; }
run_kimi_rollback()       { "$SCRIPTS_DIR/kimi-rollback.sh" "$@"; }

KSHARED="$SHARED_DIR/kimi"

it "kimi-add-account creates the dir, links shared kimi items, registers a kimiN alias"
run_kimi_add_account --alias kimi1 --yes >/dev/null 2>&1
assert_eq 0 "$?" "exit 0"
kd="$HOME/.kimi-code-kimi1"
assert_dir "$kd" "config dir created"
for item in AGENTS.md plugins skills sessions session_index.jsonl; do
  assert_symlink_to "$kd/$item" "$KSHARED/$item" "$item linked into shared kimi area"
done
assert_file_contains "$ALIAS_FILE" "alias kimi1=" "alias line written"
assert_file_contains "$ALIAS_FILE" "KIMI_CODE_HOME=$kd" "alias carries KIMI_CODE_HOME"

it "kimi-add-account refuses an alias that already exists"
( run_kimi_add_account --alias kimi1 --yes >/dev/null 2>&1 )
cond=$(( $? != 0 ? 0 : 1 ))
assert_eq 0 "$cond" "exits non-zero on duplicate alias"

it "kimi-add-account rejects the reserved kimi-* provider namespace"
( run_kimi_add_account --alias kimi-deepseek --yes >/dev/null 2>&1 )
cond=$(( $? != 0 ? 0 : 1 ))
assert_eq 0 "$cond" "rejects kimi-* account alias"

it "kimi-add-account defaults to the next free kimiN"
run_kimi_add_account --yes >/dev/null 2>&1
assert_file_contains "$ALIAS_FILE" "alias kimi2=" "next free alias used (kimi1 taken)"
assert_dir "$HOME/.kimi-code-kimi2" "default dir created"

it "kimi-add-account refuses headless --login (device flow is interactive)"
( run_kimi_add_account --alias kimi3 --yes --login >/dev/null 2>&1 )
cond=$(( $? != 0 ? 0 : 1 ))
assert_eq 0 "$cond" "--login without a terminal refuses before creating anything"
cond=1; [[ ! -d "$HOME/.kimi-code-kimi3" ]] && cond=0
assert_eq 0 "$cond" "no dir left behind by the refused --login"

it "kimi-list-accounts reports the accounts with links intact"
out="$(run_kimi_list_accounts)"
assert_file_contains <(printf '%s\n' "$out") "kimi1" "kimi1 listed"
assert_file_contains <(printf '%s\n' "$out") "kimi2" "kimi2 listed"
assert_file_contains <(printf '%s\n' "$out") "$KSHARED" "list names the kimi shared store"

it "kimi-remove-account --archive moves the dir aside and drops the alias"
run_kimi_remove_account --alias kimi1 --archive --yes >/dev/null 2>&1
assert_eq 0 "$?" "exit 0"
cond=1; [[ ! -d "$HOME/.kimi-code-kimi1" ]] && cond=0
assert_eq 0 "$cond" "original dir gone"
archived="$(find "$HOME" -maxdepth 1 -name '.kimi-code-kimi1.removed.*' -type d 2>/dev/null | head -1)"
cond=1; [[ -n "$archived" ]] && cond=0
assert_eq 0 "$cond" "archived sibling exists"
assert_file_not_contains "$ALIAS_FILE" "alias kimi1=" "alias line removed"

it "kimi-remove-account --delete really deletes"
run_kimi_remove_account --alias kimi2 --delete --yes >/dev/null 2>&1
assert_eq 0 "$?" "exit 0"
cond=1; [[ ! -d "$HOME/.kimi-code-kimi2" ]] && cond=0
assert_eq 0 "$cond" "dir deleted"

it "kimi-remove-account rejects an unknown alias"
( run_kimi_remove_account --alias nonexistent --yes >/dev/null 2>&1 )
cond=$(( $? != 0 ? 0 : 1 ))
assert_eq 0 "$cond" "unknown alias errors out"

# ---- unify -------------------------------------------------------------------
it "kimi-unify merges account content into \$SHARED_DIR/kimi and symlinks accounts onto it"
mkdir -p "$HOME/.kimi-code-ka/sessions" "$HOME/.kimi-code-kb/sessions"
printf '{"session":"a","msg":"A"}\n' > "$HOME/.kimi-code-ka/sessions/a.jsonl"
printf '{"session":"b","msg":"B"}\n' > "$HOME/.kimi-code-kb/sessions/b.jsonl"
printf '{"id":"idxA"}\n' > "$HOME/.kimi-code-ka/session_index.jsonl"
printf '{"id":"idxB"}\n' > "$HOME/.kimi-code-kb/session_index.jsonl"
printf '# A memory from A\n' > "$HOME/.kimi-code-ka/AGENTS.md"
printf '# A memory from B (newest)\n' > "$HOME/.kimi-code-kb/AGENTS.md"
run_kimi_unify >/dev/null 2>&1
assert_eq 0 "$?" "exit 0"
assert_file "$KSHARED/sessions/a.jsonl" "a session unioned into shared"
assert_file "$KSHARED/sessions/b.jsonl" "b session unioned into shared"
assert_symlink_to "$HOME/.kimi-code-ka/sessions" "$KSHARED/sessions" "a sessions now a shared symlink"
assert_symlink_to "$HOME/.kimi-code-kb/sessions" "$KSHARED/sessions" "b sessions now a shared symlink"
cond=1; grep -q '"id":"idxA"' "$KSHARED/session_index.jsonl" && grep -q '"id":"idxB"' "$KSHARED/session_index.jsonl" && cond=0
assert_eq 0 "$cond" "session_index.jsonl unioned (idxA + idxB present)"
assert_file "$KSHARED/AGENTS.md" "shared AGENTS.md exists"
assert_file_contains "$KSHARED/AGENTS.md" "from B (newest)" "newest account's AGENTS.md promoted"
assert_symlink_to "$HOME/.kimi-code-kb/AGENTS.md" "$KSHARED/AGENTS.md" "b AGENTS.md now a shared symlink"
# NOTE: inside [[ ]] pathname expansion does NOT happen, so a glob test must go
# through find (a literal '*' would test a non-existent `...preunify.*` file).
cond=1; find "$HOME/.kimi-code-kb" -maxdepth 1 -name 'AGENTS.md.preunify.*' -print -quit 2>/dev/null | grep -q . && cond=0
assert_eq 0 "$cond" "b AGENTS.md backed up before linking"
assert_file_contains "$ALIAS_FILE" "alias kimi1=" "unify registered a kimiN alias for ka"
assert_file_contains "$ALIAS_FILE" "alias kimi2=" "unify registered a kimiN alias for kb"

it "kimi-unify --rollback restores backups and moves the kimi shared area aside"
run_kimi_rollback >/dev/null 2>&1
assert_eq 0 "$?" "exit 0"
cond=1; [[ ! -d "$KSHARED" ]] && cond=0
assert_eq 0 "$cond" "kimi shared area moved aside"
assert_file "$HOME/.kimi-code-ka/sessions/a.jsonl" "a sessions restored to a real dir"
assert_not_symlink "$HOME/.kimi-code-ka/sessions" "a sessions is a real dir again (not a symlink)"
assert_file_contains "$HOME/.kimi-code-ka/AGENTS.md" "from A" "a AGENTS.md restored from backup"
cond=1; [[ ! -L "$HOME/.kimi-code-ka/AGENTS.md" ]] && cond=0
assert_eq 0 "$cond" "a AGENTS.md is a real file again"

summary