#!/usr/bin/env bash
# test_claude_usage.sh — sandboxed tests for claude-usage.sh +
# claude_usage_report.py, the ccusage-backed usage/cost reporting command.
#
# Covers: argument parsing (date ranges, group-by, format, subcommand
# validation), the "ccusage not on PATH" actionable-error path, and a
# guarded live-smoke test against a tiny SYNTHETIC fixture (two fake
# transcript JSONL files in the real ccusage/Claude-Code schema) that
# exercises the REAL ccusage binary end-to-end when it is present on this
# host, honestly SKIPping (not silently passing) when it is not.
#
# Never touches the real ~/.claude-shared — every live call below points
# SHARED_DIR/CLAUDE_CONFIG_DIR at a throwaway fixture dir inside the sandbox
# $HOME that make_sandbox created.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
set +e   # let failing-by-design assertions report instead of aborting

CLI="$SCRIPTS_DIR/claude-usage.sh"
HELPER="$SCRIPTS_DIR/claude_usage_report.py"

# ---------------------------------------------------------------------------
# Static checks
# ---------------------------------------------------------------------------

it "claude-usage.sh exists and is executable"
assert_file "$CLI"
if [[ -x "$CLI" ]]; then _pass "executable"; else _fail "not executable" "$CLI"; fi

it "claude_usage_report.py exists"
assert_file "$HELPER"

it "claude-usage.sh has valid bash syntax"
assert_exit 0 bash -n "$CLI"

it "claude_usage_report.py has valid python syntax"
assert_exit 0 python3 -m py_compile "$HELPER"

it "install.sh needs no special-casing — the claude-*.sh glob already covers it"
assert_file_contains "$SCRIPTS_DIR/install.sh" 'for f in "$LIB_DIR"/claude-*.sh;'
_matched=0
for f in "$SCRIPTS_DIR"/claude-*.sh; do
  [[ "$(basename "$f")" == "claude-usage.sh" ]] && _matched=1
done
if [[ "$_matched" == 1 ]]; then _pass "claude-usage.sh matches install.sh's symlink glob"
else _fail "claude-usage.sh does NOT match the glob" "install.sh would never symlink it"; fi

it "the usage-feature commits never edited lib.sh / claude-providers.sh / install.sh (file-scope constraint)"
# The constraint belongs to the commits that BUILT the usage feature, not to every
# later branch: a branch may legitimately change lib.sh (1.33.0 does). So inspect
# the named feature commits themselves, with a control that the instrument sees a
# commit that DID touch a protected file. Never vacuous: unresolvable commits SKIP
# loudly instead of passing.
_prot='^scripts/(lib\.sh|claude-providers\.sh|install\.sh)$'
_touch() { git -C "$REPO_ROOT" diff-tree --no-commit-id --name-only -r "$1" 2>/dev/null | grep -cE "$_prot"; }
if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  _ctl=adae02d   # known to change lib.sh + claude-providers.sh (positive control)
  if git -C "$REPO_ROOT" cat-file -e "$_ctl^{commit}" 2>/dev/null; then
    _n="$(_touch "$_ctl")"
    [[ "${_n:-0}" -ge 1 ]] && _pass "control: commit $_ctl is seen touching a protected file ($_n)" \
      || _fail "control: commit $_ctl is seen touching a protected file" "instrument is blind"
    for _c in 5b27915 47b98ff; do
      if git -C "$REPO_ROOT" cat-file -e "$_c^{commit}" 2>/dev/null; then
        _n="$(_touch "$_c")"
        [[ "${_n:-0}" -eq 0 ]] && _pass "usage-feature commit $_c touched none of lib.sh/claude-providers.sh/install.sh" \
          || _fail "usage-feature commit $_c touched a protected file" "$_n file(s)"
      else
        echo "SKIP: usage-feature commit $_c not present in this checkout"
      fi
    done
  else
    echo "SKIP: control commit $_ctl not present (shallow clone?)"
  fi
else
  echo "SKIP: not a git worktree"
fi

# ---------------------------------------------------------------------------
# --help / usage
# ---------------------------------------------------------------------------

it "--help exits 0 and documents the report subcommand"
out="$(bash "$CLI" --help 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && _pass "exit 0" || _fail "non-zero exit" "rc=$rc out=$out"
grep -q 'claude-usage report' <<<"$out" && _pass "mentions report subcommand" || _fail "missing usage text" "$out"

it "no args at all => usage + non-zero exit"
out="$(bash "$CLI" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && _pass "non-zero exit ($rc)" || _fail "exit 0 with no args" "$out"

it "unknown subcommand => non-zero exit, actionable message"
out="$(bash "$CLI" bogus-subcommand 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && _pass "non-zero exit ($rc)" || _fail "exit 0 for unknown subcommand" "$out"
grep -qi 'unknown subcommand' <<<"$out" && _pass "names the problem" || _fail "no actionable message" "$out"

# ---------------------------------------------------------------------------
# Argument parsing (pure validation — no ccusage call needed, these all
# fail before ccusage would ever be invoked)
# ---------------------------------------------------------------------------

it "--group-by rejects an invalid value"
out="$(bash "$CLI" report --group-by bogus 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && _pass "non-zero exit ($rc)" || _fail "exit 0 for invalid --group-by" "$out"
grep -q 'group-by' <<<"$out" && _pass "message names --group-by" || _fail "message doesn't mention --group-by" "$out"

it "--group-by accepts every documented value (parses past validation)"
for g in day model session project provider all; do
  out="$(bash "$CLI" report --group-by "$g" --since bogus-date 2>&1)"
  # forced to fail LATER (bad date) so this only proves --group-by itself was accepted
  grep -q 'group-by' <<<"$out" && _fail "rejected valid --group-by=$g" "$out" || _pass "accepted --group-by=$g"
done

it "--format rejects an invalid value"
out="$(bash "$CLI" report --format bogus 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && _pass "non-zero exit ($rc)" || _fail "exit 0 for invalid --format" "$out"
grep -q 'format' <<<"$out" && _pass "message names --format" || _fail "message doesn't mention --format" "$out"

it "--since with an invalid date is rejected before any ccusage call"
out="$(bash "$CLI" report --since not-a-real-date 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && _pass "non-zero exit ($rc)" || _fail "exit 0 for invalid --since" "$out"
grep -q 'since' <<<"$out" && _pass "message names --since" || _fail "message doesn't mention --since" "$out"

it "--until with an invalid date is rejected before any ccusage call"
out="$(bash "$CLI" report --until 2024-99-99 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && _pass "non-zero exit ($rc)" || _fail "exit 0 for invalid --until" "$out"
grep -q 'until' <<<"$out" && _pass "message names --until" || _fail "message doesn't mention --until" "$out"

it "--since after --until is rejected"
out="$(bash "$CLI" report --since 2026-10-22 --until 2026-10-01 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && _pass "non-zero exit ($rc)" || _fail "exit 0 for since>until" "$out"
grep -qi 'after' <<<"$out" && _pass "message explains the ordering problem" || _fail "no actionable message" "$out"

it "unknown flag is rejected, not silently ignored"
out="$(bash "$CLI" report --totally-bogus-flag value 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && _pass "non-zero exit ($rc)" || _fail "exit 0 for unknown flag" "$out"

# ---------------------------------------------------------------------------
# "ccusage not on PATH" — forced via an empty PATH containing no ccusage.
# ---------------------------------------------------------------------------

it "missing ccusage => clear actionable error, non-zero exit, no --build"
out="$(PATH="/usr/bin:/bin" bash "$CLI" report --since 2026-10-20 --until 2026-10-21 2>&1)"; rc=$?
if command -v ccusage >/dev/null 2>&1 && [[ -x /usr/bin/ccusage || -x /bin/ccusage ]]; then
  echo "SKIP: a real ccusage is installed in /usr/bin or /bin on this host — cannot force PATH to lack it"
else
  [[ $rc -ne 0 ]] && _pass "non-zero exit ($rc)" || _fail "exit 0 with ccusage missing" "$out"
  grep -q 'not on PATH' <<<"$out" && _pass "names the problem" || _fail "message doesn't say ccusage is missing" "$out"
  grep -q 'claude-ccusage-build.sh' <<<"$out" && _pass "points at claude-ccusage-build.sh" || _fail "no actionable remedy" "$out"
  grep -q -- '--build' <<<"$out" && _pass "mentions the --build escape hatch" || _fail "doesn't mention --build" "$out"
fi

it "missing ccusage WITH --build => attempts claude-ccusage-build.sh, not a silent no-op"
out="$(PATH="/usr/bin:/bin" bash "$CLI" report --since 2026-10-20 --until 2026-10-21 --build 2>&1)"; rc=$?
if command -v ccusage >/dev/null 2>&1 && [[ -x /usr/bin/ccusage || -x /bin/ccusage ]]; then
  echo "SKIP: a real ccusage is installed in /usr/bin or /bin on this host — cannot force PATH to lack it"
else
  grep -qi 'ccusage-build' <<<"$out" && _pass "invokes/references claude-ccusage-build.sh" || _fail "no build attempt" "$out"
fi

# ---------------------------------------------------------------------------
# Guarded live-smoke test: REAL ccusage against a tiny synthetic fixture.
# ---------------------------------------------------------------------------

it "live smoke test: real ccusage end-to-end against a synthetic fixture (guarded)"
if ! command -v ccusage >/dev/null 2>&1; then
  echo "SKIP: ccusage is not on PATH on this host (run: bash $SCRIPTS_DIR/claude-ccusage-build.sh) — live smoke not exercised"
else
  FIXDIR="$HOME/usage-fixture"
  mkdir -p "$FIXDIR/projects/-home-test-projA" "$FIXDIR/projects/-home-test-projB"

  cat > "$FIXDIR/projects/-home-test-projA/11111111-1111-1111-1111-111111111111.jsonl" <<'JSONL'
{"type":"assistant","message":{"model":"test-vendor/test-model-A","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":10,"cache_read_input_tokens":5}},"timestamp":"2024-01-01T10:00:00.000Z","sessionId":"11111111-1111-1111-1111-111111111111","cwd":"/home/test/projA","uuid":"a1111111-0000-0000-0000-000000000001"}
JSONL

  cat > "$FIXDIR/projects/-home-test-projB/22222222-2222-2222-2222-222222222222.jsonl" <<'JSONL'
{"type":"assistant","message":{"model":"claude-sonnet-9-9","usage":{"input_tokens":200,"output_tokens":100,"cache_creation_input_tokens":20,"cache_read_input_tokens":10}},"timestamp":"2024-01-02T11:00:00.000Z","sessionId":"22222222-2222-2222-2222-222222222222","cwd":"/home/test/projB","uuid":"a2222222-0000-0000-0000-000000000002"}
JSONL

  # A fake provider catalog so the 'provider' grouping has something to
  # match test-vendor/test-model-A against (and so we can assert the
  # ambiguous ::free-stripped / native-pool logic is actually exercised).
  mkdir -p "$HOME/.local/share/claude-multi-account/providers"
  cat > "$HOME/.local/share/claude-multi-account/providers/status.json" <<'JSONSTATUS'
{
  "testprovider": {"status": "verified", "model": "test-vendor/test-model-A", "checked_at": "2024-01-01T00:00:00Z", "failing_layer": ""}
}
JSONSTATUS

  out="$(SHARED_DIR="$FIXDIR" bash "$CLI" report --since 2024-01-01 --until 2024-01-02 --format json 2>"$HOME/usage-smoke.err")"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    _fail "live smoke run failed" "rc=$rc stderr=$(cat "$HOME/usage-smoke.err")"
  else
    _pass "live smoke run succeeded (rc=0)"
    _check="$(SANDBOX_HOME="$HOME" python3 - "$out" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
errs = []
tot = data.get("totals", {})
if tot.get("totalTokens") != 495:
    errs.append(f"totals.totalTokens want=495 got={tot.get('totalTokens')}")
days = data.get("day", [])
if len(days) != 2:
    errs.append(f"expected 2 daily rows, got {len(days)}")
models = {m["modelName"]: m for m in data.get("model", [])}
if "test-vendor/test-model-A" not in models:
    errs.append("missing test-vendor/test-model-A in model grouping")
elif "testprovider" not in models["test-vendor/test-model-A"]["providerBucket"]:
    errs.append(f"test-model-A providerBucket didn't name testprovider: {models['test-vendor/test-model-A']['providerBucket']}")
if "claude-sonnet-9-9" not in models:
    errs.append("missing claude-sonnet-9-9 in model grouping")
elif "native Claude accounts" not in models["claude-sonnet-9-9"]["providerBucket"]:
    errs.append(f"claude-sonnet-9-9 should be pooled native, got: {models['claude-sonnet-9-9']['providerBucket']}")
projects = {p["projectPath"]: p for p in data.get("project", [])}
if "-home-test-projA" not in projects or "-home-test-projB" not in projects:
    errs.append(f"expected both project paths, got {list(projects.keys())}")
else:
    if projects["-home-test-projA"]["sessionCount"] != 1 or projects["-home-test-projB"]["sessionCount"] != 1:
        errs.append("expected 1 session per project")
if errs:
    print("FAIL: " + " | ".join(errs))
else:
    print("OK")
PY
)"
    if [[ "$_check" == "OK" ]]; then
      _pass "JSON report shape + values correct (totals, day, model->provider mapping, native pooling, project grouping)"
    else
      _fail "JSON report assertions failed" "$_check"
    fi
  fi

  it "live smoke test: --format md renders without error"
  out_md="$(SHARED_DIR="$FIXDIR" bash "$CLI" report --since 2024-01-01 --until 2024-01-02 --format md 2>&1)"
  rc=$?
  [[ $rc -eq 0 ]] && _pass "exit 0" || _fail "non-zero exit" "rc=$rc out=$out_md"
  grep -q '# Claude usage report' <<<"$out_md" && _pass "has markdown heading" || _fail "missing markdown heading" "$out_md"
  grep -q 'test-vendor/test-model-A' <<<"$out_md" && _pass "model row present in markdown" || _fail "model row missing" "$out_md"

  it "live smoke test: --format csv renders the day table"
  out_csv="$(SHARED_DIR="$FIXDIR" bash "$CLI" report --since 2024-01-01 --until 2024-01-02 --format csv 2>&1)"
  rc=$?
  [[ $rc -eq 0 ]] && _pass "exit 0" || _fail "non-zero exit" "rc=$rc out=$out_csv"
  grep -q '^date,inputTokens' <<<"$out_csv" && _pass "has CSV header" || _fail "missing CSV header" "$out_csv"
  grep -q '^2024-01-01,100,50' <<<"$out_csv" && _pass "day-1 row present with correct values" || _fail "day-1 row wrong/missing" "$out_csv"
  grep -q '^2024-01-02,200,100' <<<"$out_csv" && _pass "day-2 row present with correct values" || _fail "day-2 row wrong/missing" "$out_csv"

  it "live smoke test: --out writes to the exact path, no stdout flood"
  out_path="$HOME/custom-report.json"
  out_stdout="$(SHARED_DIR="$FIXDIR" bash "$CLI" report --since 2024-01-01 --until 2024-01-02 --out "$out_path" 2>/dev/null)"
  if [[ -f "$out_path" ]]; then _pass "file written at --out path"; else _fail "no file at --out path" "$out_path"; fi
  if [[ -z "$out_stdout" ]]; then _pass "no report flooded to stdout with --out"; else _fail "unexpected stdout with --out" "$out_stdout"; fi
  grep -q '"totalTokens": 495' "$out_path" 2>/dev/null && _pass "--out file has correct content" || _fail "--out file content wrong" "$(cat "$out_path" 2>/dev/null)"

  it "live smoke test: default (no --format/--out) writes BOTH json+md under SHARED_DIR/usage-reports and prints md"
  rm -rf "$FIXDIR/usage-reports"
  default_stdout="$(SHARED_DIR="$FIXDIR" bash "$CLI" report --since 2024-01-01 --until 2024-01-02 2>/dev/null)"
  if [[ -f "$FIXDIR/usage-reports/2024-01-01_2024-01-02.json" ]]; then _pass "json report written under SHARED_DIR/usage-reports"
  else _fail "json report not written" "$(ls "$FIXDIR/usage-reports" 2>&1)"; fi
  if [[ -f "$FIXDIR/usage-reports/2024-01-01_2024-01-02.md" ]]; then _pass "md report written under SHARED_DIR/usage-reports"
  else _fail "md report not written" "$(ls "$FIXDIR/usage-reports" 2>&1)"; fi
  grep -q '# Claude usage report' <<<"$default_stdout" && _pass "default run also prints markdown to stdout" || _fail "default run printed nothing useful" "$default_stdout"
fi

summary
