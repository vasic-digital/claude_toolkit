#!/usr/bin/env bash
# test_sandbox_hygiene.sh — mechanical enforcement of a handful of suite-wide
# hygiene invariants. This is a lint over the test sources, not a behavioural
# test of the toolkit.
#
# Why these two rules exist (both are real, already-observed failure modes):
#
#   (a) HARDCODED /tmp WRITE TARGETS.
#       A path like /tmp/cma-test-unify.log is shared by every concurrent run
#       on the host. Two suite runs (CI matrix, a developer plus an agent, two
#       terminals) write and grep the SAME inode, so one run can assert against
#       another run's output. It is not reliably reproducible — the collision is
#       invisible whenever both runs happen to write identical bytes — which is
#       exactly what makes it worth pinning mechanically rather than by eye.
#       Everything must go under $SANDBOX_HOME (a per-run mktemp dir) or through
#       mktemp itself.
#
#   (c) WRAPPER CALLS WITHOUT A PROVENANCE ASSERTION.
#       ~/.bash_profile exports BASH_ENV=~/.bashrc, so EVERY non-interactive
#       bash — including run-all.sh's `bash "$f"` per test — sources the
#       PRODUCTION alias file before the test's first line runs. cma_run and
#       cma_run_provider are therefore already defined, from the HOST, in every
#       test shell. A test that sources its sandbox $ALIAS_FILE and then calls
#       the wrapper looks correct, but tests run with `set +e`: a silently
#       failed source falls straight through to the fully-working host function,
#       and the test passes having graded live host code. Tests written to prove
#       cma_ensure_alias_file emits a correct body then report green for exactly
#       the regression they exist to catch. Every file that invokes a wrapper
#       must therefore also assert where that wrapper came from — via
#       assert_fn_from (lib/assert.sh) or the equivalent inline
#       `shopt -s extdebug; declare -F` idiom.
#
#   (b) BARE REDIRECTS INTO ~/.local/bin.
#       install.sh symlinks every claude-*.sh into ~/.local/bin, and those links
#       point at the REAL repo. A redirect follows symlinks, so `> ~/.local/bin/
#       claude-session` truncates scripts/claude-session.sh itself. That already
#       happened: 201 lines -> 8. Crucially, $HOME was a VALID sandbox at the
#       time — install.sh had created the links inside it — so assert_sandboxed
#       cannot catch this class. Only sandbox_stub can: it rm's an existing
#       symlink before writing instead of writing through it.
#
#   (d) VACUOUS EMPTY-IS-SUCCESS ASSERTIONS.
#       A test runs a command, throws its stderr away, captures stdout, and
#       asserts the output is EMPTY as the success condition:
#           _prop="$(python3 -c '…big sweep…' 2>/dev/null)"
#           assert_eq "" "$_prop" "derive_limits invariant violations"
#       If the harness CRASHES — unimportable module, syntax error, missing
#       interpreter, wrong path — stdout is empty and the assertion PASSES.
#       This was proven live: making the module unimportable left BOTH of
#       test_providers.sh's flagship sweeps reporting `[PASS] … violations: ''`
#       — a 2240-case property sweep and a 5696-row live-catalog sweep, the two
#       most load-bearing checks in the file, verifying nothing. The suite only
#       went red because an UNRELATED nearby test happened to lack the
#       redirect. Compounding it, both sweeps printed their case counts to
#       STDERR, so the one number that would have exposed the vacuity was the
#       thing being discarded.
#       The remedy, and what scanner (d) enforces: assert a POSITIVE quantity
#       (cases examined, rows swept, files scanned, an exit status, a sentinel)
#       alongside the "no violations" check, so an empty result can never be
#       mistaken for a successful one.
#
# The scanners deliberately report file:line so a violation is actionable, and
# they are proven non-vacuous below against planted fixtures — in both
# directions, since a scanner that flags everything is as useless as one that
# flags nothing.

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

# ── scanners ────────────────────────────────────────────────────────────────
# Both emit zero or more "<file>:<line>: <offending source>" records on stdout
# and always exit 0; callers judge by whether output is empty. Full-line
# comments are stripped first (prose legitimately mentions /tmp paths, e.g.
# test_rc_sourcing.sh's description of the bug it covers).
#
# Portability: plain POSIX-ish grep -E / sed, no GNU-only constructs — matching
# the BSD-vs-GNU rule the rest of the toolkit follows.

_strip_comments() {  # <file>  -> numbered, comment-free source on stdout
  grep -n '' -- "$1" | sed 's/^\([0-9]*\):[[:space:]]*#.*$/\1:/'
}

# scan_tmp_paths FILE... — flag literal /tmp/ used as a WRITE TARGET.
#
# Three shapes are caught:
#   R1  a redirect:            > /tmp/x    2>/tmp/x    >>"/tmp/x"
#   R2  a hardcoded mktemp:    mktemp -d /tmp/foo.XXXXXX
#   R3  a writing command:     tee|cp|mv|touch|mkdir|install|ln ... /tmp/x
#
# Deliberately NOT flagged:
#   * "${TMPDIR:-/tmp}/x.XXXXXX" — the project's documented portable mktemp
#     idiom. It cannot match: after the quote comes `$`, never `/tmp/`.
#   * bare `mktemp -d` with no template (the correct usage).
#   * /tmp/ appearing as inert data, e.g. the JSON project keys "/tmp/projectA"
#     in test_providers.sh — those are map keys in a fixture, never a path
#     anything opens for writing.
scan_tmp_paths() {
  local f
  for f in "$@"; do
    _strip_comments "$f" | grep -E \
      -e '>[[:space:]]*["'"'"']?/tmp/' \
      -e 'mktemp[^;|&]*[[:space:]]["'"'"']?/tmp/' \
      -e '(tee|cp|mv|touch|mkdir|install|ln)[[:space:]][^;|&]*[[:space:]]["'"'"']?/tmp/' \
      | sed "s|^|${f}:|"
  done
  return 0
}

# scan_bin_writes FILE... — flag a redirect whose TARGET is under .local/bin/.
#
# Matches only when .local/bin/ appears AFTER the `>`, so these stay clean:
#   * BIN_DIR="$HOME/.local/bin" cmd >"$install_log"   (path is an argument)
#   * printf 'CLAUDE_BIN="$HOME/.local/bin/claude"' > "$f"  (path is content)
#   * sandbox_stub "$HOME/.local/bin/x" <<'EOF'       (path is an argument)
# The last one is the required replacement: sandbox_stub takes the path as an
# argument and breaks any existing symlink before writing, so it never matches.
scan_bin_writes() {
  local f
  for f in "$@"; do
    _strip_comments "$f" \
      | grep -E '>[[:space:]]*["'"'"']?[^"'"'"'[:space:]]*\.local/bin/' \
      | sed "s|^|${f}:|"
  done
  return 0
}

# _strip_quotes — drop balanced "…" and '…' spans from already-numbered source.
# Wrapper NAMES appear constantly as prose inside quotes — `it "native cma_run
# clears …"`, assert messages, printf banners, awk programs like
# '/^cma_run\(\) ?\{/'. None of those are calls. Removing quoted spans is what
# separates a command word from a mention; stripping full-line comments alone
# is not enough here (unlike scanners (a)/(b), whose noise IS comments).
#
# It is a left-to-right lexer, not a pair of regexes, because a regex pairing
# `"[^"]*"` treats a backslash-escaped \" as a span TERMINATOR. Bash does not:
# inside "…" a \" is a literal quote and the span continues. Mis-pairing then
# shifts every later quote by one, which fails in both directions — prose
# inside an echoed alias line gets EXPOSED as a call, and a real call after an
# odd number of \" gets SWALLOWED into a bogus span (a hidden violation). The
# lexer follows bash's rules for the three cases that matter here:
#   outside quotes  \x is an escaped char (so \" does NOT open a span); " and '
#                   open a span.
#   inside "…"      \x is an escaped char (\" and \\ both stay in the span);
#                   only an unescaped " closes it.
#   inside '…'      no escapes at all; the next ' closes it.
# An unterminated span runs to end of line and is dropped, as before. Nested
# "$( … "…" … )" is still not modelled (LIMITS item 4 below).
_strip_quotes() {
  awk '{
    s = $0; out = ""; st = 0; n = length(s); i = 1
    while (i <= n) {
      ch = substr(s, i, 1)
      if (st == 0) {
        if (ch == "\\") { out = out substr(s, i, 2); i += 2; continue }
        if (ch == "\"") st = 1
        else if (ch == "'"'"'") st = 2
        else out = out ch
      } else if (st == 1) {
        if (ch == "\\") { i += 2; continue }
        if (ch == "\"") st = 0
      } else if (ch == "'"'"'") st = 0
      i++
    }
    print out
  }'
}

# scan_wrapper_provenance FILE... — flag a test that CALLS cma_run /
# cma_run_provider but never asserts which file defined it.
#
# A file is compliant if it contains either:
#   * an assert_fn_from call (lib/assert.sh), or
#   * the inline `shopt -s extdebug` + `declare -F` idiom (the hand-rolled form
#     that predates the helper — a real provenance check, so it counts).
# Non-compliant files get every invocation line reported as file:line.
#
# ── LIMITS — do not over-trust this lint ────────────────────────────────────
# It is a STATIC scan, and it is deliberately the weaker half of a two-part
# control. What it CANNOT see:
#   1. Whether the `source` actually SUCCEEDED. It verifies a provenance
#      assertion is PRESENT in the file, not that the sandbox wrapper really
#      loaded. That self-masking runtime case is precisely why the RUNTIME
#      assert_fn_from must exist alongside this scanner — the lint cannot
#      replace it, only ensure it was not forgotten.
#   2. ORDERING within a file. An assertion placed AFTER the calls it is meant
#      to guard, or guarding a different function than the one invoked, reads
#      as compliant here.
#   3. Wrappers invoked from a separately spawned shell (`bash -c '…'`, a
#      generated script, a stub) — a new process, whose provenance this file's
#      text cannot describe.
#   4. Invocations whose whole line is swallowed by an outer quoted span, e.g.
#      `out="$( ( source "$F"; cma_run_provider acme ) 2>&1 )"`. Quote-stripping
#      removes it. In practice such files also contain unquoted call sites, so
#      the FILE is still flagged; only the line count is short.
# EXCLUDED: verify_*.sh. Those are live verifiers that legitimately drive the
# host's real aliases — inheritance is their design, not a defect.
scan_wrapper_provenance() {
  local f hits
  for f in "$@"; do
    case "$(basename "$f")" in verify_*.sh) continue ;; esac
    # Compliant? Then nothing in this file is a violation.
    if grep -qE '(^|[[:space:];(&|])assert_fn_from[[:space:]]' -- "$f"; then continue; fi
    if grep -q 'shopt -s extdebug' -- "$f" && grep -q 'declare -F' -- "$f"; then continue; fi
    # Invocation = the token in command position: preceded by start-of-line,
    # whitespace or a shell operator, and followed by whitespace/EOL/`)`.
    # `cma_run(_provider)?` needs the trailing class so `cma_run` does not match
    # inside `cma_run_provider`, and the leading class so an awk anchor like
    # `/^cma_run\(\)/` (preceded by `^`) is not mistaken for a call.
    hits="$(_strip_comments "$f" | _strip_quotes \
      | grep -E '(^[0-9]+:|[[:space:];(&|])cma_run(_provider)?([[:space:]]|$|\))' \
      | sed "s|^|${f}:|")"
    [[ -n "$hits" ]] && printf '%s\n' "$hits"
  done
  return 0
}

# scan_vacuous_empty FILE... — flag an assertion whose PASSING condition is
# "nothing came back" from a command whose stderr was thrown away.
#
# Three shapes are caught:
#   V1  VAR="$(… 2>/dev/null …)"   …later…   assert_eq "" "$VAR"
#       The capture may span many lines — a multi-line `python3 -c` sweep puts
#       its 2>/dev/null on the CLOSING line — so an open capture is tracked
#       until the line that ends the substitution. Both real-world cases
#       (test_providers.sh's 2240-case and 5696-row sweeps) are of this shape
#       and would be missed by a single-line regex.
#   V2  [[ -z "$(… 2>/dev/null …)" ]]        (inline, emptiness = success)
#   V3  assert_eq 0 "$(… 2>/dev/null … | wc -l)"  /  … | grep -c …
#
# A hit is SUPPRESSED when the enclosing `it` block already proves the command
# ran. Two accepted forms, and only two:
#   * an explicit opt-out marker `vacuity-ok` in a comment on the offending
#     line or anywhere in the capture — for the cases where an empty result
#     genuinely is the whole story and the author says so on the record; or
#   * an accompanying POSITIVE assertion in the same `it` block: a non-zero /
#     non-empty expected literal (`assert_eq 2 …`, `assert_eq "VAL:" …`), an
#     exit-status assertion (`assert_eq 0 "$?"`, `assert_eq 0 "$foo_rc"`), or
#     an existence assertion (assert_file / assert_dir / assert_file_contains /
#     assert_fn_from / assert_symlink_to / assert_lines / assert_exit).
#
# ── LIMITS — stated honestly, because this lint cannot be clever ────────────
# A STATIC scan cannot tell whether an empty result is genuinely expected. It
# does not execute anything, so it has no idea whether the command works. It
# therefore does NOT try to judge correctness — it flags the SHAPE and demands
# that the author either add a positive assertion or say `vacuity-ok` out loud.
# Specifically, it cannot see:
#   1. Whether the positive assertion it accepted actually covers the SAME
#      command. `assert_eq 0 "$rc"` in the block satisfies the rule even if
#      $rc came from an unrelated call. Block-scoped proximity is the whole
#      heuristic; it is not provenance.
#   2. Emptiness-as-success that never touches a captured variable — a bare
#      `grep -q … || fail`, an `if [[ -n "$x" ]]; then fail; fi` funnelled into
#      an `ok=1` flag (verify_constitution.sh's `fx_ok` pattern). Those are the
#      same hazard; only the syntactic form differs, and the form is all this
#      scanner has.
#   3. An empty GLOB or an empty input set — `for f in dir/*.sh` over a wrong
#      directory yields "no violations" with no suppressed stderr anywhere.
#      That vacuity is real and is why the fixes in test_coverage.sh and
#      test_mutation_residue.sh assert a file COUNT; the scanner cannot detect
#      it, so do not read a clean (d) as "no vacuity in the suite".
#   4. Suppression written some other way — `exec 2>/dev/null`, `2>"$devnull"`,
#      a wrapper function that redirects internally.
scan_vacuous_empty() {
  local f
  for f in "$@"; do
    awk -v FNAME="$f" '
      # A "positive" assertion: something that cannot pass on an empty result.
      function is_pos(l) {
        if (l ~ /assert_(file|dir|file_contains|fn_from|symlink_to|lines|exit)[[:space:](]/) return 1
        if (l ~ /assert_eq[[:space:]]+["'"'"']?[1-9]/) return 1              # non-zero literal
        if (l ~ /assert_eq[[:space:]]+["'"'"'][^"'"'"']/) return 1           # non-EMPTY string literal
        # exit-status form: `assert_eq 0 "$?"` / `assert_eq 0 "$foo_rc"`. The
        # trailing anchor is load-bearing — without it the name may match a
        # PREFIX of an arbitrary expression, and `assert_eq 0 "$(…)"` starts
        # reading as an exit-status assertion, which silently disarms (d).
        if (l ~ /assert_eq[[:space:]]+["'"'"']?0["'"'"']?[[:space:]]+"?\$(\?|\{?[A-Za-z_][A-Za-z0-9_]*(rc|RC|_status|code)\}?)"?[[:space:]]*($|")/) return 1
        return 0
      }
      function varname(l,   s) {          # "$VAR" / "${VAR}" -> VAR
        if (match(l, /"\$\{?[A-Za-z_][A-Za-z0-9_]*/) == 0) return ""
        s = substr(l, RSTART, RLENGTH); sub(/^"\$\{?/, "", s); return s
      }
      {
        # Comment stripping is essential (prose describes this very pattern),
        # but the opt-out marker LIVES in a comment — so full-line comments are
        # blanked for code matching while the raw line is kept for the marker.
        raw[NR] = $0
        code = ($0 ~ /^[[:space:]]*#/) ? "" : $0
        c[NR] = code
        if ($0 ~ /^[[:space:]]*it[[:space:]]/) blk++
        b[NR] = blk
        if ($0 ~ /vacuity-ok/) optout[NR] = 1
        if (is_pos(code)) pos[blk] = 1
        if (open == "") {
          if (code ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*="\$\(/) {
            v = code; sub(/^[[:space:]]*/, "", v); sub(/=.*$/, "", v)
            open = v; openline = NR
            closenow = (code ~ /\)"[[:space:]]*$/) ? 1 : 0
          }
        } else if (code ~ /\)"[[:space:]]*$/) closenow = 1
        if (open != "") {
          if (code ~ /2>[[:space:]]*\/dev\/null/ || code ~ /2>&-/) suppseen = 1
          if ($0 ~ /vacuity-ok/) okseen = 1
          if (closenow) {
            if (suppseen) { supp[open] = openline; if (okseen) suppok[open] = 1 }
            open = ""; suppseen = 0; okseen = 0; closenow = 0
          }
        }
        n = NR
      }
      END {
        for (i = 1; i <= n; i++) {
          l = c[i]
          if (l == "" || optout[i] || pos[b[i]]) continue
          hit = ""
          if (l ~ /assert_eq[[:space:]]+(""|'"'"''"'"')[[:space:]]/) {
            rest = l; sub(/^.*assert_eq[[:space:]]+(""|'"'"''"'"')[[:space:]]+/, "", rest)
            v = varname(rest)
            if (v != "" && (v in supp) && !suppok[v])
              hit = "V1 empty-is-success on $" v " (captured with stderr suppressed at line " supp[v] ")"
          }
          if (hit == "" && l ~ /\[\[[[:space:]]*-z[[:space:]]*"\$\(/ && l ~ /2>[[:space:]]*\/dev\/null/)
            hit = "V2 inline -z over a stderr-suppressed capture"
          if (hit == "" && l ~ /assert_eq[[:space:]]+["'"'"']?0["'"'"']?[[:space:]]+"\$\(/ &&
              l ~ /2>[[:space:]]*\/dev\/null/ && (l ~ /wc[[:space:]]+-l/ || l ~ /grep[[:space:]]+-c/))
            hit = "V3 zero-count from a stderr-suppressed capture"
          if (hit != "") printf "%s:%d: %s | %s\n", FNAME, i, hit, raw[i]
        }
      }
    ' "$f"
  done
  return 0
}

# ── anti-vacuous-pass guard ─────────────────────────────────────────────────
# A scanner whose regex silently matches nothing would report a pristine tree
# forever. Prove it bites BEFORE trusting a clean result on the real suite:
# plant known-bad fixtures and require a hit, plant known-good ones and require
# no hit. Without the negative fixtures a scanner that flags EVERY line would
# also "pass".

FIXTURES="$SANDBOX_HOME/fixtures"
mkdir -p "$FIXTURES"

# The fixture bodies are ASSEMBLED from these two fragments rather than written
# as heredoc literals. A literal violating line sitting in this file would be
# found by the suite-wide scan below — this file is one of the files it scans —
# and the only ways out would be to exclude this file (a permanent blind spot
# in the very lint that guards the suite) or to weaken the regex. Composing the
# offending strings at runtime keeps this file both self-checked and able to
# carry genuinely-bad fixtures.
T='/tmp'
B='.local/bin'
# Same reason as T/B: a literal wrapper CALL written here would be found by
# scanner (c) when it sweeps this file. Composed at runtime, `R=` survives
# quote-stripping with the name gone, so this file stays self-checked.
R='cma_run'
A='assert_fn_from'

{
  printf '#!/usr/bin/env bash\n'
  printf 'run_unify > %s/cma-test-unify.log 2>&1\n' "$T"
  printf 'scratch="$(mktemp -d %s/cma-fixed.XXXXXX)"\n' "$T"
} > "$FIXTURES/bad_tmp.sh"

{
  printf '#!/usr/bin/env bash\n'
  printf 'cat > "$HOME/%s/claude-session" <<EOS\n' "$B"
  printf '#!/usr/bin/env bash\n'
  printf 'EOS\n'
  printf 'printf "stub\\n" > "$HOME/%s/claude-sync-state"\n' "$B"
} > "$FIXTURES/bad_bin.sh"

# Compliant counterparts: every construct the suite is ALLOWED to use, so a
# regex that flagged everything would fail here instead of passing silently.
{
  printf '#!/usr/bin/env bash\n'
  printf '# A comment mentioning %s/cma-test-unify.log must NOT be flagged.\n' "$T"
  printf 'log="$SANDBOX_HOME/test-logs/unify.log"\n'
  printf 'scratch="$(mktemp -d "${TMPDIR:-%s}/cma-test.XXXXXX")"\n' "$T"
  printf 'run_unify > "$log" 2>&1\n'
  printf 'sandbox_stub "$HOME/%s/claude-session" <<EOS\n' "$B"
  printf '#!/usr/bin/env bash\n'
  printf 'EOS\n'
  printf 'data=%s{"projects":{"%s/projectA":{"sessionId":"sess-a1"}}}%s\n' "'" "$T" "'"
  printf 'BIN_DIR="$HOME/%s" bash install.sh > "$log" 2>&1\n' "$B"
} > "$FIXTURES/good.sh"

it "GUARD: the /tmp scanner actually flags a planted violation"
bad_tmp_hits="$(scan_tmp_paths "$FIXTURES/bad_tmp.sh")"
bad_tmp_count="$(printf '%s' "$bad_tmp_hits" | grep -c . || true)"
assert_eq 2 "$bad_tmp_count" "planted /tmp violations detected (redirect + hardcoded mktemp)"
[[ "$bad_tmp_count" == 2 ]] || printf '    scanner output|\n%s\n' "$bad_tmp_hits"

it "GUARD: the .local/bin scanner actually flags a planted violation"
bad_bin_hits="$(scan_bin_writes "$FIXTURES/bad_bin.sh")"
bad_bin_count="$(printf '%s' "$bad_bin_hits" | grep -c . || true)"
assert_eq 2 "$bad_bin_count" "planted .local/bin violations detected (cat > and printf >)"
[[ "$bad_bin_count" == 2 ]] || printf '    scanner output|\n%s\n' "$bad_bin_hits"

# (c) fixtures. bad_prov CALLS the wrapper with no provenance assertion
# anywhere. good_prov makes the SAME calls but asserts provenance first, and
# additionally carries every prose form the scanner must ignore: a test name, an
# assert message, an awk body anchor, a comment, and an alias string.
{
  printf '#!/usr/bin/env bash\n'
  printf 'source "$ALIAS_FILE"\n'
  printf '( set +eu; CLAUDE_BIN="$rec" %s_provider acme </dev/null >/dev/null 2>&1 )\n' "$R"
  printf '%s -p "hello" >/dev/null 2>&1\n' "$R"
} > "$FIXTURES/bad_prov.sh"

{
  printf '#!/usr/bin/env bash\n'
  printf 'source "$ALIAS_FILE"\n'
  printf '%s %s_provider "$ALIAS_FILE" "from the sandbox"\n' "$A" "$R"
  printf '( set +eu; CLAUDE_BIN="$rec" %s_provider acme </dev/null >/dev/null 2>&1 )\n' "$R"
  printf '%s -p "hello" >/dev/null 2>&1\n' "$R"
} > "$FIXTURES/good_prov.sh"

# Prose-only: no calls at all, and no assertion either. A scanner keying on the
# mere APPEARANCE of the name would flag all four lines; the correct answer is
# silence, which is what separates "reports calls" from "reports mentions".
{
  printf '#!/usr/bin/env bash\n'
  printf '# a comment about how %s clears the leaked guards\n' "$R"
  printf 'it "native %s clears leaked token guards (sink-side)"\n' "$R"
  printf 'body="$(awk %s/^%s\\(\\) ?\\{/{f=1} f{print}%s "$ALIAS_FILE")"\n' "'" "$R" "'"
  printf 'assert_eq 4 "$n" "4 tier exports in %s_provider body"\n' "$R"
  printf 'printf %salias acme="%s_provider acme"\\n%s > "$f"\n' "'" "$R" "'"
} > "$FIXTURES/prose_only.sh"

it "GUARD: the provenance scanner flags wrapper calls with no provenance assertion"
bad_prov_hits="$(scan_wrapper_provenance "$FIXTURES/bad_prov.sh")"
bad_prov_count="$(printf '%s' "$bad_prov_hits" | grep -c . || true)"
assert_eq 2 "$bad_prov_count" "planted unguarded wrapper calls detected (provider + native)"
[[ "$bad_prov_count" == 2 ]] || printf '    scanner output|\n%s\n' "$bad_prov_hits"

it "GUARD: the provenance scanner does NOT flag a file that asserts provenance"
good_prov_hits="$(scan_wrapper_provenance "$FIXTURES/good_prov.sh")"
assert_eq "" "$good_prov_hits" "identical calls are clean once assert_fn_from is present"

it "GUARD: the provenance scanner ignores prose (test names, asserts, awk, comments)"
prose_hits="$(scan_wrapper_provenance "$FIXTURES/prose_only.sh")"
assert_eq "" "$prose_hits" "mentions of the wrapper name are not calls"

# Backslash-escaped double quotes (\") inside a "…" span. The span does NOT end
# at \" — bash keeps it as a literal quote — so a quote-stripper that treats \"
# as a terminator mis-pairs every quote after it, in BOTH directions:
#   esc_alias_echo   an alias line echoed into a file. Every name is prose.
#                    Mis-pairing EXPOSES it as a call (false positive).
#   esc_then_call    a span holding an ODD number of \" followed by a REAL call.
#                    Mis-pairing swallows the call into a bogus span (false
#                    negative) — the dangerous half: a real call hides.
#                    Line 3 is the escaped-BACKSLASH case (\\ then a real ")
#                    so the fix cannot simply treat every \" as literal.
#   esc_quoted_prose the call text lives wholly inside one "…" span alongside
#                    escaped quotes — genuinely quoted prose, not a call.
{
  printf '#!/usr/bin/env bash\n'
  printf 'echo "alias x=\\"%s_provider x\\"" >> "$F"\n' "$R"
} > "$FIXTURES/esc_alias_echo.sh"

{
  printf '#!/usr/bin/env bash\n'
  printf 'echo "a \\" quote" ; %s_provider foo "x"\n' "$R"
  printf 'echo "dir\\\\" ; %s -p "y"\n' "$R"
} > "$FIXTURES/esc_then_call.sh"

{
  printf '#!/usr/bin/env bash\n'
  printf 'it "say \\"%s_provider acme\\" to launch; then %s \\"x\\" works"\n' "$R" "$R"
  printf 'printf "%%s\\n" "run \\"%s -p hi\\" (prose)" > "$f"\n' "$R"
} > "$FIXTURES/esc_quoted_prose.sh"

it "GUARD: an escaped-quote alias echo is NOT flagged as a wrapper call"
esc_alias_hits="$(scan_wrapper_provenance "$FIXTURES/esc_alias_echo.sh")"
assert_eq "" "$esc_alias_hits" "\\\" inside a \"…\" span does not end the span"

it "GUARD: a REAL unguarded call after an escaped quote on the same line IS flagged"
esc_call_hits="$(scan_wrapper_provenance "$FIXTURES/esc_then_call.sh")"
esc_call_count="$(printf '%s' "$esc_call_hits" | grep -c . || true)"
assert_eq 2 "$esc_call_count" "both real calls survive quote-stripping (odd \\\" count, and \\\\ before a closing quote)"
[[ "$esc_call_count" == 2 ]] || printf '    scanner output|\n%s\n' "$esc_call_hits"

it "GUARD: a wrapper name inside a quoted span with escaped quotes is prose, not a call"
esc_prose_hits="$(scan_wrapper_provenance "$FIXTURES/esc_quoted_prose.sh")"
assert_eq "" "$esc_prose_hits" "quoted text carrying \\\"…\\\" is still quoted text"

it "GUARD: the provenance scanner skips verify_*.sh (live inheritance is by design)"
cp "$FIXTURES/bad_prov.sh" "$FIXTURES/verify_prov_live.sh"
verify_hits="$(scan_wrapper_provenance "$FIXTURES/verify_prov_live.sh")"
assert_eq "" "$verify_hits" "a verify_* file with the same body is exempt"

# (d) fixtures. Same runtime-assembly discipline as T/B/R above, and for the
# same reason: a LITERAL `assert_eq "" "$x"` paired with a suppressed capture,
# written here as a heredoc, would be found by scanner (d) when it sweeps this
# file — and the only ways out would be to exclude this file (a blind spot in
# the lint that guards the suite) or to weaken the regex. Composing `D` and `E`
# at runtime keeps this file both self-checked and able to carry bad fixtures.
D='2>/dev/null'
E='""'

{
  printf '#!/usr/bin/env bash\n'
  printf 'it "a property sweep with no positive evidence"\n'
  printf '_prop="$(python3 -c %ssweep()%s %s)"\n' "'" "'" "$D"
  printf 'assert_eq %s "$_prop" "derive_limits invariant violations"\n' "$E"
  printf 'it "an inline emptiness check"\n'
  printf 'cond=1; [[ -z "$(find "$HOME" -name %sx.*%s %s)" ]] && cond=0\n' "'" "'" "$D"
  printf 'it "a zero-count check"\n'
  printf 'assert_eq 0 "$(grep -rn PAT "$DIR" %s | wc -l)" "no hits"\n' "$D"
} > "$FIXTURES/bad_vac.sh"

# Compliant counterparts: the SAME commands, each rescued by one of the three
# accepted forms of proof. A scanner keying only on the shape would flag all
# four blocks; the correct answer is silence.
{
  printf '#!/usr/bin/env bash\n'
  printf 'it "rescued by an exit-status assertion"\n'
  printf '_prop="$(python3 -c %ssweep()%s %s)"; _prop_rc=$?\n' "'" "'" "$D"
  printf 'assert_eq 0 "$_prop_rc" "the sweep harness ran"\n'
  printf 'assert_eq %s "$_prop" "derive_limits invariant violations"\n' "$E"
  printf 'it "rescued by a positive case count"\n'
  printf '_prop2="$(python3 -c %ssweep()%s %s)"\n' "'" "'" "$D"
  printf 'assert_eq 2240 "$_cases" "cases actually examined"\n'
  printf 'assert_eq %s "$_prop2" "invariant violations"\n' "$E"
  printf 'it "rescued by an explicit opt-out marker"\n'
  printf '_prop3="$(cat "$f" %s)"   # vacuity-ok: absence IS the whole check\n' "$D"
  printf 'assert_eq %s "$_prop3" "file is empty"\n' "$E"
  printf 'it "an inline emptiness check next to a real assertion"\n'
  printf 'assert_eq 3 "$_seen" "the sweep saw files"\n'
  printf 'cond=1; [[ -z "$(find "$HOME" -name %sx.*%s %s)" ]] && cond=0\n' "'" "'" "$D"
} > "$FIXTURES/good_vac.sh"

# Shape-alike but NOT suppressed: an empty expectation over a capture that
# keeps its stderr is out of scope by construction — a crash is visible in the
# run log. Flagging these would drown the real signal.
{
  printf '#!/usr/bin/env bash\n'
  printf 'it "unsuppressed capture"\n'
  printf 'NOJQ_MISSING="$(build_nojq_path)"\n'
  printf 'assert_eq %s "$NOJQ_MISSING" "the jq-less PATH shim could be built"\n' "$E"
  printf 'it "suppression on an unrelated command"\n'
  printf 'rm -rf "$d" %s\n' "$D"
  printf '_lost=""\n'
  printf 'for n in a b c; do grep -q "^alias $n=" "$F" %s || _lost="$_lost $n"; done\n' "$D"
  printf 'assert_eq %s "$_lost" "no concurrent write was lost"\n' "$E"
} > "$FIXTURES/unsuppressed_vac.sh"

it "GUARD: the vacuity scanner flags all three empty-is-success shapes"
bad_vac_hits="$(scan_vacuous_empty "$FIXTURES/bad_vac.sh")"
bad_vac_count="$(printf '%s' "$bad_vac_hits" | grep -c . || true)"
assert_eq 3 "$bad_vac_count" "planted vacuous assertions detected (V1 capture + V2 inline -z + V3 zero-count)"
[[ "$bad_vac_count" == 3 ]] || printf '    scanner output|\n%s\n' "$bad_vac_hits"

it "GUARD: the vacuity scanner does NOT flag a rescued equivalent"
good_vac_hits="$(scan_vacuous_empty "$FIXTURES/good_vac.sh")"
assert_eq "" "$good_vac_hits" "identical shapes are clean with rc / positive count / vacuity-ok"

it "GUARD: the vacuity scanner ignores empty expectations that keep their stderr"
unsupp_vac_hits="$(scan_vacuous_empty "$FIXTURES/unsuppressed_vac.sh")"
assert_eq "" "$unsupp_vac_hits" "only SUPPRESSED captures are in scope"

it "GUARD: neither scanner fires on compliant code (not a match-everything regex)"
good_tmp_hits="$(scan_tmp_paths "$FIXTURES/good.sh")"
assert_eq "" "$good_tmp_hits" "sandbox-relative logs, TMPDIR mktemp, comments and JSON data are clean"
good_bin_hits="$(scan_bin_writes "$FIXTURES/good.sh")"
assert_eq "" "$good_bin_hits" "sandbox_stub and .local/bin-as-argument are clean"

# ── the real invariants ─────────────────────────────────────────────────────
# Scan every test script in the suite, which is exactly the set run-all.sh and
# run-proof.sh execute.

SUITE_FILES=()
for f in "$TESTS_DIR"/*.sh; do
  [[ -f "$f" ]] && SUITE_FILES+=("$f")
done

it "the suite has test files to scan (guards against an empty glob)"
cond=1; (( ${#SUITE_FILES[@]} >= 10 )) && cond=0
assert_eq 0 "$cond" "found ${#SUITE_FILES[@]} scripts under $TESTS_DIR"

it "(a) no test writes to a hardcoded /tmp path outside the sandbox"
tmp_violations="$(scan_tmp_paths "${SUITE_FILES[@]}")"
assert_eq "" "$tmp_violations" "no fixed /tmp write targets in the suite"
[[ -z "$tmp_violations" ]] || {
  printf '    Offenders (use "$SANDBOX_HOME/..." or mktemp "${TMPDIR:-/tmp}/x.XXXXXX"):\n'
  printf '%s\n' "$tmp_violations" | sed 's/^/      /'
}

it "(b) no test writes into \$HOME/.local/bin via a bare redirect"
bin_violations="$(scan_bin_writes "${SUITE_FILES[@]}")"
assert_eq "" "$bin_violations" "no bare redirects into .local/bin in the suite"
[[ -z "$bin_violations" ]] || {
  printf '    Offenders (use sandbox_stub, which breaks the symlink first):\n'
  printf '%s\n' "$bin_violations" | sed 's/^/      /'
}

it "(c) no test calls cma_run/cma_run_provider without asserting its provenance"
prov_violations="$(scan_wrapper_provenance "${SUITE_FILES[@]}")"
assert_eq "" "$prov_violations" "every wrapper call in the suite is provenance-guarded"
[[ -z "$prov_violations" ]] || {
  printf '    Offenders (add: assert_fn_from cma_run_provider "$ALIAS_FILE"\n'
  printf '     right after the sandbox source, BEFORE the wrapper is exercised):\n'
  printf '%s\n' "$prov_violations" | sed 's/^/      /'
}

it "(d) no assertion treats an empty result from a stderr-suppressed command as success"
vac_violations="$(scan_vacuous_empty "${SUITE_FILES[@]}")"
assert_eq "" "$vac_violations" "every empty-is-success assertion in the suite carries positive evidence"
[[ -z "$vac_violations" ]] || {
  printf '    Offenders. A crash in the captured command produces the SAME empty\n'
  printf '    output as a clean result, so these assertions can pass having run\n'
  printf '    nothing. Stop suppressing stderr blanket-style, capture the exit\n'
  printf '    status and assert it, and assert a POSITIVE quantity (cases swept,\n'
  printf '    rows read, files scanned) beside the "no violations" check. If an\n'
  printf '    empty result really is the whole story, say so: # vacuity-ok: <why>\n'
  printf '%s\n' "$vac_violations" | sed 's/^/      /'
}

summary
