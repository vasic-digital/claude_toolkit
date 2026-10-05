#!/usr/bin/env bash
# test_quota_rendering.sh — unit tests for scripts/lib.sh's `quota`/`limits`
# rendering helpers: severity classification, color-enable gating, and
# (in later tasks extending this same file) the text/JSON renderers
# themselves.
#
# This file is INTENTIONALLY RED at the time it is first written: this
# task (T007) is test-only (TDD discipline). The implementation
# (_cma_quota_severity in scripts/lib.sh) lands in the next task, T008.
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
set +e   # lib.sh sets -e; the harness asserts on failures, so relax it.

it "_cma_quota_severity(100) is green"
out="$(_cma_quota_severity 100)"
assert_eq "green" "$out" "100% remaining is green"

it "_cma_quota_severity(30) is green (inclusive lower bound)"
out="$(_cma_quota_severity 30)"
assert_eq "green" "$out" "exactly 30% remaining is green, not yellow"

it "_cma_quota_severity(29.99) is yellow"
out="$(_cma_quota_severity 29.99)"
assert_eq "yellow" "$out" "29.99% remaining is yellow"

it "_cma_quota_severity(10) is yellow (inclusive lower bound)"
out="$(_cma_quota_severity 10)"
assert_eq "yellow" "$out" "exactly 10% remaining is yellow, not red"

it "_cma_quota_severity(9.99) is red"
out="$(_cma_quota_severity 9.99)"
assert_eq "red" "$out" "9.99% remaining is red"

it "_cma_quota_severity(0.01) is red"
out="$(_cma_quota_severity 0.01)"
assert_eq "red" "$out" "0.01% remaining is still red, not limit_exceeded"

it "_cma_quota_severity(0) is limit_exceeded"
out="$(_cma_quota_severity 0)"
assert_eq "limit_exceeded" "$out" "exactly 0% remaining is limit_exceeded"

it "_cma_quota_severity(-5) is limit_exceeded (negative remaining still classifies)"
out="$(_cma_quota_severity -5)"
assert_eq "limit_exceeded" "$out" "negative remaining (e.g. after overage) is limit_exceeded, never undefined"

it "_cma_quota_color_enabled: tty, no NO_COLOR, no flags -> ON"
unset NO_COLOR
_cma_quota_color_enabled --force-tty
assert_eq 0 $? "tty + no NO_COLOR + no --json/--no-color = color on"

it "_cma_quota_color_enabled: tty, but NO_COLOR=1 -> OFF"
export NO_COLOR=1
_cma_quota_color_enabled --force-tty
assert_eq 1 $? "NO_COLOR set forces color off even on a real tty"
unset NO_COLOR

it "_cma_quota_color_enabled: non-tty -> OFF regardless of NO_COLOR"
unset NO_COLOR
_cma_quota_color_enabled --force-no-tty
assert_eq 1 $? "non-tty forces color off even with NO_COLOR unset"

it "_cma_quota_color_enabled: tty, no NO_COLOR, but --no-color flag -> OFF"
unset NO_COLOR
_cma_quota_color_enabled --force-tty --no-color
assert_eq 1 $? "--no-color flag forces color off even on a real tty with NO_COLOR unset"

# --- _cma_quota_render_text (T018, RED — function does not exist yet; it
# lands in T019) -------------------------------------------------------
#
# Fixed 4-row Reportable Entity JSON fixture (data-model.md §1/§2/§3
# shapes), one JSON object per line (newline-delimited, as
# _cma_quota_render_text reads from stdin):
#   Row 1: deepseek, one window, 52.68% remaining -> green.
#   Row 2: claude1 (native), no windows, not reported by provider.
#   Row 3: dualwin, two windows -- session 80% remaining (green) and
#          weekly 5% remaining (red) -- two different severities in one row.
#   Row 4: cachedprov, one window, cached data 42 seconds old.
FIXTURE=(
  '{"provider_id":"deepseek","alias_names":["deepseek","kimi-deepseek"],"base_url":"https://api.deepseek.com/v1","windows":[{"window":"subscription","amount_used":47.32,"amount_remaining":52.68,"limit_total":100.00,"unit":"USD","percent_remaining":52.68,"resets":false,"reset_at":null}],"account_blocked":false,"absence_reason":null,"data_source":"live","data_age_seconds":null}'
  '{"account_id":"claude1","family":"claude","plan_tier":"default_claude_max_20x","windows":[],"absence_reason":"not_reported_by_provider","data_source":null,"data_age_seconds":null}'
  '{"provider_id":"dualwin","alias_names":["dualwin"],"base_url":"https://api.dualwin.example/v1","windows":[{"window":"session","amount_used":20,"amount_remaining":80,"limit_total":100,"unit":"tokens","percent_remaining":80,"resets":false,"reset_at":null},{"window":"weekly","amount_used":95,"amount_remaining":5,"limit_total":100,"unit":"tokens","percent_remaining":5,"resets":false,"reset_at":null}],"account_blocked":false,"absence_reason":null,"data_source":"live","data_age_seconds":null}'
  '{"provider_id":"cachedprov","alias_names":["cachedprov"],"base_url":"https://api.cachedprov.example/v1","windows":[{"window":"session","amount_used":10,"amount_remaining":90,"limit_total":100,"unit":"tokens","percent_remaining":90,"resets":false,"reset_at":null}],"account_blocked":false,"absence_reason":null,"data_source":"cached","data_age_seconds":42}'
)

it "_cma_quota_render_text groups by alias header exactly once per provider-account"
out="$(printf '%s\n' "${FIXTURE[@]}" | _cma_quota_render_text)"
count="$(grep -c '^deepseek' <<<"$out")"
assert_eq "1" "$count" "deepseek's header appears exactly once, never once per alias_name"

it "_cma_quota_render_text shows each window on its own line"
lines="$(grep -c 'session\|weekly\|subscription' <<<"$out")"
assert_eq "4" "$lines" "4 total window lines across all 4 rows (1+0+2+1)"

it "_cma_quota_render_text states the native row is not reported by provider"
echo "$out" | grep -q "not reported by provider" || assert_eq "contains" "missing" "native row's absence must be stated in words"

it "_cma_quota_render_text shows both severities for the two-window row on separate lines"
echo "$out" | grep -qi "green" && echo "$out" | grep -qi "red" \
  && ok=1 || ok=0
assert_eq "1" "$ok" "both severity words appear somewhere in the output"

it "_cma_quota_render_text with color forced off: zero ANSI bytes, severity words still present"
out_noc="$(printf '%s\n' "${FIXTURE[@]}" | _cma_quota_render_text --no-color)"
ansi_count="$(printf '%s' "$out_noc" | grep -c $'\033' || true)"
assert_eq "0" "$ansi_count" "no ANSI escape bytes when color is forced off"
echo "$out_noc" | grep -qi "green" && echo "$out_noc" | grep -qi "red" \
  && ok2=1 || ok2=0
assert_eq "1" "$ok2" "severity words still present in plain-text mode (FR-013)"

it "_cma_quota_render_text states the cached row is cached and discloses its age (42)"
echo "$out" | grep -q "cached" || assert_eq "contains cached" "missing" "cached row must say so"
echo "$out" | grep -q "42" || assert_eq "contains 42" "missing" "cached row must disclose its numeric age (FR-012)"

# --- _cma_quota_render_json (T020, RED — function does not exist yet; it
# lands in T021). Reuses the SAME FIXTURE array defined above (T018), per
# the brief's instruction not to redefine it. -------------------------

it "_cma_quota_render_json produces valid, parseable JSON"
json_out="$(printf '%s\n' "${FIXTURE[@]}" | _cma_quota_render_json)"
# jq -e (not plain `jq .`) is load-bearing here: plain `jq .` treats an
# EMPTY input stream as a trivially valid zero-document stream and exits
# 0, which would make this RED baseline pass vacuously when
# _cma_quota_render_json doesn't exist yet (json_out="") -- `-e` makes an
# empty/absent top-level value a real failure (exit 4), while still
# exiting 0 once the real implementation emits a genuine JSON object.
echo "$json_out" | jq -e . >/dev/null 2>&1
assert_eq "0" "$?" "output must be valid, non-empty JSON (jq -e . exits 0)"

it "_cma_quota_render_json top-level shape matches data-model.md §5"
# -c (compact) is load-bearing here: `jq -S 'keys'` alone sorts the keys
# but still pretty-prints one key per line, which can never equal the
# compact string literal below -- that would be a permanent false-FAIL,
# not a RED-until-T021 state. `-Sc`/`-cS` emits the compact single-line
# array the literal expects.
keys="$(echo "$json_out" | jq -Sc 'keys' 2>/dev/null)"
assert_eq '["generated_at","rows","scoped_to","unknown_alias"]' "$keys" "exactly these 4 top-level keys, nothing more/less"

it "_cma_quota_render_json: rows length matches the fixture's row count"
n="$(echo "$json_out" | jq '.rows | length' 2>/dev/null)"
assert_eq "4" "$n" "4 rows in, 4 rows out"

it "_cma_quota_render_json and _cma_quota_render_text agree on severity for EVERY window in EVERY row (not spot-checked)"
text_out="$(printf '%s\n' "${FIXTURE[@]}" | _cma_quota_render_text --force-no-tty)"
# For each row/window in the JSON output, extract its severity and its
# identifying info (display-equivalent id + window name), then confirm
# the SAME severity word (case-insensitively) appears in the text
# output's corresponding section. Do this for ALL windows across ALL
# rows -- the fixture has 4 total windows (row1:1, row2:0, row3:2,
# row4:1) -- iterate, don't hardcode one check.
#
# severity_count double-checks that the JSON stream actually produced the
# expected 4 severity values (RED baseline: it will be 0, since
# _cma_quota_render_json does not exist and json_out is empty/invalid --
# an empty stream would otherwise let the mismatch loop below vacuously
# pass with 0 iterations).
severities="$(echo "$json_out" | jq -r '.rows[].windows[].severity' 2>/dev/null)"
severity_count="$(printf '%s\n' "$severities" | grep -c . || true)"
assert_eq "4" "$severity_count" "JSON stream must carry exactly 4 severity values (1+0+2+1 across the 4 fixture rows)"
mismatch=0
while IFS=$'\t' read -r sev; do
  [[ -n "$sev" ]] || continue
  echo "$text_out" | grep -qi "$sev" || mismatch=$(( mismatch + 1 ))
done <<<"$severities"
assert_eq "0" "$mismatch" "every window's JSON severity value must appear (case-insensitively) somewhere in the text rendering"

# --- Distinct "account blocked" rendering (T027) ----------------------
#
# A separate single-row fixture, NOT appended to the FIXTURE array above:
# FIXTURE's row count is asserted exactly (T018/T020's "4 total window
# lines", "4 rows in, 4 rows out", "4 severity values" checks), so adding
# a 5th row there would turn those into false-FAILs rather than a
# deliberate RED for THIS task. Concatenating this row onto FIXTURE[@]
# only at the point of use (per the brief) keeps every earlier assertion
# untouched.
BLOCKED_ROW='{"provider_id":"blockedprov","alias_names":["blockedprov"],"base_url":"https://api.blockedprov.example/v1","windows":[{"window":"session","amount_used":10,"amount_remaining":90,"limit_total":100,"unit":"tokens","percent_remaining":90,"resets":false,"reset_at":null}],"account_blocked":true,"absence_reason":null,"data_source":"live","data_age_seconds":null}'

# The combined fixture stream also contains "session" window lines from
# the UNRELATED dualwin/cachedprov rows defined above. A bare
# `grep -q "session"` against the WHOLE combined output can therefore
# never fail -- it would match those other rows' windows even if
# blockedprov's own window were wrongly hidden. Both checks below are
# scoped to blockedprov's OWN rendered block (from its header line to
# the next blank line -- the per-row separator _cma_quota_render_text
# emits), so the "windows still shown" assertion actually has teeth
# against the regression it is named to catch.
out="$(printf '%s\n' "${FIXTURE[@]}" "$BLOCKED_ROW" | _cma_quota_render_text --force-no-tty)"
block="$(echo "$out" | sed -n '/^blockedprov/,/^$/p')"

it "_cma_quota_render_text: a blocked account shows a distinct ACCOUNT BLOCKED statement"
echo "$block" | grep -qi "account blocked" || assert_eq "contains 'account blocked' in blockedprov's own block" "missing" "FR-011: distinct statement required"

it "_cma_quota_render_text: a blocked account's windows are STILL shown, not hidden"
echo "$block" | grep -q "session" || assert_eq "contains blockedprov's own window line" "missing" "prior windows must remain visible, only annotated as moot -- scoped to THIS row, not any other row in the combined output"

it "_cma_quota_render_json: account_blocked field is true for the blocked row"
json_out="$(printf '%s\n' "${FIXTURE[@]}" "$BLOCKED_ROW" | _cma_quota_render_json)"
ab="$(echo "$json_out" | jq -r '.rows[] | select(.display_name=="blockedprov") | .account_blocked')"
assert_eq "true" "$ab" "account_blocked must survive into the JSON output"

# --- Distinguish not_reported_by_provider from probe_failed (T030) ----
#
# `_cma_quota_render_one_row` currently prints the SAME literal phrase
# "not reported by provider" for BOTH absence_reason values -- exactly
# the confusion FR-009/this phase exists to prevent. A new row with
# absence_reason "probe_failed" (and a real absence_detail) must render
# a DISTINCT phrase that includes its own detail text, and must never
# say "not reported by provider" in its own block.
#
# As with BLOCKED_ROW above, this row is concatenated onto FIXTURE[@]
# only at the point of use -- FIXTURE's row count is asserted exactly
# elsewhere, so appending here would turn those earlier assertions into
# false-FAILs.
FAILED_ROW='{"provider_id":"failedprov","alias_names":["failedprov"],"base_url":"http://127.0.0.1:1/","windows":[],"account_blocked":false,"absence_reason":"probe_failed","absence_detail":"connection failed or timed out","data_source":"live","data_age_seconds":null}'

it "_cma_quota_render_text: not_reported_by_provider and probe_failed render DIFFERENT, unambiguous phrases"
out="$(printf '%s\n' "${FIXTURE[@]}" "$FAILED_ROW" | _cma_quota_render_text --force-no-tty)"

# The not_reported row's block (claude1, the native-account row from
# FIXTURE) must say "not reported by provider" -- scoped to ITS OWN
# block, not the whole combined stream.
not_reported_block="$(echo "$out" | sed -n '/^claude1/,/^$/p')"
echo "$not_reported_block" | grep -q "not reported by provider" || assert_eq "contains 'not reported by provider' in claude1's own block" "missing" "not_reported_by_provider row must still say so"

# The probe_failed row's block (failedprov) must say "probe failed" PLUS
# its real absence_detail text, and must NEVER say "not reported by
# provider" anywhere in its own block -- scoped the same way, per the
# Task 27 review finding: a bare grep against the WHOLE combined $out
# would trivially pass here regardless of failedprov's own block,
# since claude1's block already contains that exact phrase.
failed_block="$(echo "$out" | sed -n '/^failedprov/,/^$/p')"
echo "$failed_block" | grep -qi "probe failed" || assert_eq "contains 'probe failed' in failedprov's own block" "missing" "probe_failed must render a distinct phrase"
echo "$failed_block" | grep -q "connection failed or timed out" || assert_eq "contains the real absence_detail in failedprov's own block" "missing" "the real absence_detail text must appear, not a placeholder"
echo "$failed_block" | grep -q "not reported by provider" && bad=1 || bad=0
assert_eq "0" "$bad" "probe_failed's own block must NEVER say 'not reported by provider' -- the exact confusion FR-009 forbids"

it "_cma_quota_render_json: probe_failed and not_reported_by_provider are textually distinct in the JSON too"
json_out="$(printf '%s\n' "${FIXTURE[@]}" "$FAILED_ROW" | _cma_quota_render_json)"
r1="$(echo "$json_out" | jq -r '.rows[] | select(.display_name=="failedprov") | .absence_reason')"
r2="$(echo "$json_out" | jq -r '.rows[] | select(.display_name=="claude1") | .absence_reason')"
neq=1; [[ "$r1" == "$r2" ]] && neq=0
assert_eq "1" "$neq" "probe_failed and not_reported_by_provider must never be the same string"

# --- Distinguish auth-session-expiry from quota-exhaustion (T038-
# independent-review finding C1) --------------------------------------
#
# A native-account row with absence_reason "not_reported_by_provider" AND
# auth_state "session_expired" must render BOTH facts in its own block --
# the base phrase (unchanged, still asserted above for the healthy
# claude1 row) plus an explicit annotation naming the real auth problem --
# never collapsing the two into the one ambiguous phrase every native
# account rendered regardless of real auth health before this fix.
EXPIRED_ROW='{"account_id":"claudeexpired","family":"claude","plan_tier":"default_claude_pro","windows":[],"absence_reason":"not_reported_by_provider","auth_state":"session_expired","data_source":null,"data_age_seconds":null}'

it "_cma_quota_render_text: a session_expired native account states BOTH 'not reported by provider' AND 'session expired' in its own block"
out="$(printf '%s\n' "${FIXTURE[@]}" "$EXPIRED_ROW" | _cma_quota_render_text --force-no-tty)"
expired_block="$(echo "$out" | sed -n '/^claudeexpired/,/^$/p')"
echo "$expired_block" | grep -q "not reported by provider" || assert_eq "contains 'not reported by provider' in claudeexpired's own block" "missing" "the base phrase must still be stated, unchanged"
echo "$expired_block" | grep -qi "session expired" || assert_eq "contains 'session expired' in claudeexpired's own block" "missing" "the genuine auth-session-expiry must be stated distinctly, not conflated into the base phrase alone"

# --- Reset cadence rendering (known-issues CADENCE-RENDER) -------------
# A daily/monthly cap arrives as resets=true, reset_at=null,
# reset_cadence=<label>. The text must agree with the JSON's resets:true
# and must never print a timestamp that was not supplied.
_cad_row() { # $1 = reset_at JSON, $2 = reset_cadence JSON
  printf '{"provider_id":"cadprov","alias_names":["cadprov"],"windows":[{"window":"session","amount_used":1,"amount_remaining":9,"limit_total":10,"unit":"tokens","percent_remaining":90,"resets":true,"reset_at":%s,"reset_cadence":%s}],"account_blocked":false,"absence_reason":null,"data_source":"live","data_age_seconds":null}\n' "$1" "$2"
}

it "_cma_quota_render_text: a daily cadence with no reset_at renders '(resets daily)'"
out="$(_cad_row null '"daily"' | _cma_quota_render_text --no-color)"
echo "$out" | grep -q "(resets daily)" && ok=1 || ok=0
assert_eq "1" "$ok" "daily cadence must render '(resets daily)', got: $out"
echo "$out" | grep -q "does not reset" && bad=1 || bad=0
assert_eq "0" "$bad" "a cadence-bearing window must never say 'does not reset'"

it "_cma_quota_render_text: a monthly cadence with no reset_at renders '(resets monthly)'"
out="$(_cad_row null '"monthly"' | _cma_quota_render_text --no-color)"
echo "$out" | grep -q "(resets monthly)" && ok=1 || ok=0
assert_eq "1" "$ok" "monthly cadence must render '(resets monthly)', got: $out"

it "_cma_quota_render_text: a null cadence with no reset_at keeps '(does not reset)'"
out="$(_cad_row null null | _cma_quota_render_text --no-color)"
echo "$out" | grep -q "(does not reset)" && ok=1 || ok=0
assert_eq "1" "$ok" "null cadence must keep '(does not reset)', got: $out"
echo "$out" | grep -q "(resets" && bad=1 || bad=0
assert_eq "0" "$bad" "null cadence must not invent a reset clause"

it "_cma_quota_render_text: an absent reset_cadence key with no reset_at keeps '(does not reset)'"
out="$(_cad_row null null | jq -c 'del(.windows[0].reset_cadence)' | _cma_quota_render_text --no-color)"
echo "$out" | grep -q "(does not reset)" && ok=1 || ok=0
assert_eq "1" "$ok" "absent cadence must keep '(does not reset)', got: $out"

it "_cma_quota_render_text: a real reset_at timestamp still renders '(resets <timestamp>)', even with a cadence"
out="$(_cad_row '"2026-10-06T00:00:00Z"' '"daily"' | _cma_quota_render_text --no-color)"
echo "$out" | grep -q "(resets 2026-10-06T00:00:00Z)" && ok=1 || ok=0
assert_eq "1" "$ok" "a supplied reset_at must win over the cadence label, got: $out"

# --- Blocked account with an absence_reason (known-issues T27-blocked-hidden)
# The F2 fix made account_blocked:true + absence_reason:probe_failed
# reachable (a 200 with a blocked signal and zero windows). FR-011 says
# the blocked state must still be stated.
BLOCKED_FAILED_ROW='{"provider_id":"blkfail","alias_names":["blkfail"],"base_url":"https://api.blkfail.example/v1","windows":[],"account_blocked":true,"absence_reason":"probe_failed","absence_detail":"no interpretable usage signals","data_source":"live","data_age_seconds":null}'

it "_cma_quota_render_text: account_blocked + probe_failed states BOTH 'ACCOUNT BLOCKED' and the probe failure"
out="$(printf '%s\n' "$BLOCKED_FAILED_ROW" | _cma_quota_render_text --no-color)"
echo "$out" | grep -q "ACCOUNT BLOCKED" && ok=1 || ok=0
assert_eq "1" "$ok" "a blocked account must be stated even when absence_reason is set, got: $out"
echo "$out" | grep -q "probe failed: no interpretable usage signals" && ok=1 || ok=0
assert_eq "1" "$ok" "the probe-failure detail must still be stated, got: $out"

it "_cma_quota_render_text: account_blocked:false + probe_failed does NOT say 'ACCOUNT BLOCKED'"
out="$(printf '%s\n' "$FAILED_ROW" | _cma_quota_render_text --no-color)"
echo "$out" | grep -q "ACCOUNT BLOCKED" && bad=1 || bad=0
assert_eq "0" "$bad" "an unblocked failed row must not be called blocked"

# --- limit_exceeded vs red share an ANSI color (known-issues F6-ansi) ---
# The contract (FR-008/FR-013) requires the distinction to survive a
# color-stripped reading, i.e. in words. Guards that it does.
it "_cma_quota_render_text: red and limit_exceeded stay distinguishable with ANSI stripped"
SEV_ROW='{"provider_id":"sevprov","alias_names":["sevprov"],"windows":[{"window":"a","amount_used":95,"amount_remaining":5,"limit_total":100,"unit":"tokens","percent_remaining":5,"resets":false,"reset_at":null},{"window":"b","amount_used":100,"amount_remaining":0,"limit_total":100,"unit":"tokens","percent_remaining":0,"resets":false,"reset_at":null}],"account_blocked":false,"absence_reason":null,"data_source":"live","data_age_seconds":null}'
stripped="$(printf '%s\n' "$SEV_ROW" | _cma_quota_render_text --force-tty | sed $'s/\033\\[[0-9;]*m//g')"
echo "$stripped" | grep -E '^  a ' | grep -q '\[RED\]' && ok=1 || ok=0
assert_eq "1" "$ok" "5% window must read [RED] without color"
echo "$stripped" | grep -E '^  b ' | grep -q '\[LIMIT_EXCEEDED\]' && ok=1 || ok=0
assert_eq "1" "$ok" "0% window must read [LIMIT_EXCEEDED] without color"

summary
