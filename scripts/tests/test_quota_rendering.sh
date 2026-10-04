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

it "_cma_quota_render_text: a blocked account shows a distinct ACCOUNT BLOCKED statement"
out="$(printf '%s\n' "${FIXTURE[@]}" "$BLOCKED_ROW" | _cma_quota_render_text --force-no-tty)"
echo "$out" | grep -qi "account blocked" || assert_eq "contains 'account blocked'" "missing" "FR-011: distinct statement required"

it "_cma_quota_render_text: a blocked account's windows are STILL shown, not hidden"
echo "$out" | grep -q "session" || assert_eq "contains window line" "missing" "prior windows must remain visible, only annotated as moot"

it "_cma_quota_render_json: account_blocked field is true for the blocked row"
json_out="$(printf '%s\n' "${FIXTURE[@]}" "$BLOCKED_ROW" | _cma_quota_render_json)"
ab="$(echo "$json_out" | jq -r '.rows[] | select(.display_name=="blockedprov") | .account_blocked')"
assert_eq "true" "$ab" "account_blocked must survive into the JSON output"

summary
