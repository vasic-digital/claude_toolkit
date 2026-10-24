#!/usr/bin/env bash
# test_jev_portable_path.sh — jev_realpath (scripts/jev-kimi-lib.sh): the ONE portable
# path resolver the jev scripts use instead of `readlink -f` (absent on BSD/macOS, where
# `readlink -f` prints an error and returns empty).
#
#   P1  a plain file resolves to its canonical absolute path
#   P2  a symlink chain (relative + absolute links) resolves to the final target
#   P3  a relative input path resolves against the cwd
#   P4  a missing path and a dangling symlink FAIL (rc 1, no stdout) - never a guess
#   P5  a symlink loop FAILS (rc 1) instead of hanging
#   P6  a symlinked DIRECTORY component is canonicalised (pwd -P)
#   P7  no jev-*.sh script INVOKES `readlink -f` (comments excluded)
#   (the symlinked-config rewrite through jev-setup stays covered by lifecycle cell L27/L31)
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${CMA_TEST_SCRIPTS_DIR:-$(cd "$TESTS_DIR/.." && pwd)}"
export SCRIPTS_DIR
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
set +e

# shellcheck source=../jev-kimi-lib.sh
source "$SCRIPTS_DIR/jev-kimi-lib.sh"

B="$SANDBOX_HOME/rp"
mkdir -p "$B/real/sub" "$B/links"
printf 'x\n' > "$B/real/sub/file.txt"
CANON="$(cd -P "$B/real/sub" && pwd -P)/file.txt"

it "P1 plain file resolves to its canonical absolute path"
got="$(jev_realpath "$B/real/sub/file.txt")"; rc=$?
assert_eq 0 "$rc" "rc"
assert_eq "$CANON" "$got" "canonical path"

it "P2 symlink chain (relative then absolute) resolves to the final target"
ln -s ../real/sub/file.txt "$B/links/l1"
ln -s "$B/links/l1" "$B/links/l2"
got="$(jev_realpath "$B/links/l2")"; rc=$?
assert_eq 0 "$rc" "rc"
assert_eq "$CANON" "$got" "chain target"

it "P3 relative input resolves against the cwd"
got="$(cd "$B/links" && jev_realpath l2)"; rc=$?
assert_eq 0 "$rc" "rc"
assert_eq "$CANON" "$got" "relative"
got="$(cd "$B/real" && jev_realpath ./sub/../sub/file.txt)"; rc=$?
assert_eq "$CANON" "$got" "dot-dot relative"

it "P3b a hostile exported CDPATH cannot change a relative resolution"
mkdir -p "$B/decoy/real/sub"; : > "$B/decoy/real/sub/file.txt"
got="$(cd "$B" && CDPATH="$B/decoy" jev_realpath real/sub/file.txt)"; rc=$?
assert_eq 0 "$rc" "rc"
assert_eq "$CANON" "$got" "CDPATH ignored (single line, the real file)"
it "P3c a relative path starting with a dash is a path, not an option"
mkdir -p "$B/dash"; : > "$B/dash/-odd"
got="$(cd "$B/dash" && jev_realpath ./-odd)"; assert_eq "$B/dash/-odd" "$got" "dash path with ./"
got="$(cd "$B/dash" && jev_realpath -- 2>/dev/null)"; rc=$?; assert_eq 1 "$rc" "bare -- is not a path"

it "P4 missing path and dangling symlink fail with rc 1 and no stdout"
got="$(jev_realpath "$B/nope/none.txt")"; rc=$?
assert_eq 1 "$rc" "missing rc"
assert_eq "" "$got" "missing stdout"
ln -s "$B/gone" "$B/links/dangling"
got="$(jev_realpath "$B/links/dangling")"; rc=$?
assert_eq 1 "$rc" "dangling rc"
assert_eq "" "$got" "dangling stdout"
got="$(jev_realpath "")"; rc=$?
assert_eq 1 "$rc" "empty rc"

it "P5 symlink loop fails instead of hanging"
ln -s "$B/links/loopb" "$B/links/loopa"
ln -s "$B/links/loopa" "$B/links/loopb"
got="$(timeout 10 bash -c 'source "$1"; jev_realpath "$2"' _ "$SCRIPTS_DIR/jev-kimi-lib.sh" "$B/links/loopa")"; rc=$?
assert_eq 1 "$rc" "loop rc (124 would mean a hang)"
assert_eq "" "$got" "loop stdout"

it "P6 a symlinked directory component is canonicalised"
ln -s "$B/real" "$B/dirlink"
got="$(jev_realpath "$B/dirlink/sub/file.txt")"
assert_eq "$CANON" "$got" "dir symlink"

it "P7 no jev-*.sh script invokes 'readlink -f'"
hits="$(for f in "$SCRIPTS_DIR"/jev-*.sh; do sed 's/#.*//' "$f"; done 2>/dev/null | grep -c 'readlink -f')"
assert_eq 0 "$hits" "zero 'readlink -f' invocations in jev-*.sh"

summary
