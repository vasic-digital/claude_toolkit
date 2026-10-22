#!/usr/bin/env bash
# test_claude_usage_merge.sh — sandboxed tests for `claude-usage merge`,
# which combines N already-rendered `claude-usage report --format json`
# files from one or more source paths into one consolidated report.
#
# All expected sums below are computed BY HAND against the two fixture JSON
# files this test writes (see the comment block above each fixture) — the
# assertions check the implementation against those independently-derived
# numbers, not against whatever the implementation happens to produce.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
set +e   # let failing-by-design assertions report instead of aborting

CLI="$SCRIPTS_DIR/claude-usage.sh"
HELPER="$SCRIPTS_DIR/claude_usage_report.py"

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
#
# Source A: 2024-01-01 only, model-A, project /home/x/projA, 1 session.
#   totals: in=100 out=50 cacheC=10 cacheR=5 total=165 cost=1.0
#
# Source B: 2024-01-01 (OVERLAPS A's date+model) + 2024-01-03 (model-B),
#   project /home/x/projB, 2 sessions.
#   totals: in=200 out=80 cacheC=0 cacheR=0 total=280 cost=2.0
#
# Hand-computed merged (A+B) expectations:
#   totals: in=300 out=130 cacheC=10 cacheR=5 total=445 cost=3.0
#   day 2024-01-01 (A's row + B's row): in=150 out=70 cacheC=10 cacheR=5
#     total=235 cost=1.5; modelBreakdowns.model-A: in=150 out=70 cost=1.5
#   day 2024-01-03 (B only): in=150 out=60 total=210 cost=1.5
#   model model-A (A+B's day-1 contribution): in=150 out=70 total=235 cost=1.5
#   model model-B (B only): in=150 out=60 total=210 cost=1.5
#   project, ANONYMIZED default ("coding agents"), ONE row:
#     sessionCount=3 in=300 out=130 total=445 cost=3.0
#   project, --real-names, TWO rows: projA cost=1.0, projB cost=2.0

FIXDIR_A="$HOME/merge-fixtures/srcA"
FIXDIR_B="$HOME/merge-fixtures/srcB"
mkdir -p "$FIXDIR_A" "$FIXDIR_B"

cat > "$FIXDIR_A/report.json" <<'JSON'
{
  "meta": {"since": "2024-01-01", "until": "2024-01-02", "generatedBy": "ccusage", "providerCatalogLoaded": true, "honestLabeling": "x"},
  "totals": {"inputTokens": 100, "outputTokens": 50, "cacheCreationTokens": 10, "cacheReadTokens": 5, "totalTokens": 165, "totalCost": 1.0},
  "day": [
    {"date": "2024-01-01", "inputTokens": 100, "outputTokens": 50, "cacheCreationTokens": 10, "cacheReadTokens": 5, "totalTokens": 165, "totalCost": 1.0,
     "modelsUsed": ["model-A"],
     "modelBreakdowns": [{"modelName": "model-A", "inputTokens": 100, "outputTokens": 50, "cacheCreationTokens": 10, "cacheReadTokens": 5, "cost": 1.0}]}
  ],
  "model": [
    {"modelName": "model-A", "inputTokens": 100, "outputTokens": 50, "cacheCreationTokens": 10, "cacheReadTokens": 5, "cost": 1.0, "totalTokens": 165,
     "providerBucket": "candidate alias: testprov (verified)", "providerMatchKind": "exact", "providerCandidates": [{"alias": "testprov", "status": "verified"}]}
  ],
  "project": [
    {"projectPath": "/home/x/projA", "sessionCount": 1, "inputTokens": 100, "outputTokens": 50, "cacheCreationTokens": 10, "cacheReadTokens": 5, "totalTokens": 165, "cost": 1.0}
  ],
  "provider": [
    {"providerBucket": "candidate alias: testprov (verified)", "providerMatchKind": "exact", "providerCandidates": [{"alias": "testprov", "status": "verified"}],
     "models": ["model-A"], "inputTokens": 100, "outputTokens": 50, "cacheCreationTokens": 10, "cacheReadTokens": 5, "totalTokens": 165, "cost": 1.0}
  ],
  "session": [
    {"sessionId": "sess-A", "projectPath": "/home/x/projA", "firstActivity": "2024-01-01T10:00:00Z", "lastActivity": "2024-01-01T10:05:00Z", "totalTokens": 165, "totalCost": 1.0}
  ]
}
JSON

cat > "$FIXDIR_B/report.json" <<'JSON'
{
  "meta": {"since": "2024-01-01", "until": "2024-01-03", "generatedBy": "ccusage", "providerCatalogLoaded": true, "honestLabeling": "x"},
  "totals": {"inputTokens": 200, "outputTokens": 80, "cacheCreationTokens": 0, "cacheReadTokens": 0, "totalTokens": 280, "totalCost": 2.0},
  "day": [
    {"date": "2024-01-01", "inputTokens": 50, "outputTokens": 20, "cacheCreationTokens": 0, "cacheReadTokens": 0, "totalTokens": 70, "totalCost": 0.5,
     "modelsUsed": ["model-A"],
     "modelBreakdowns": [{"modelName": "model-A", "inputTokens": 50, "outputTokens": 20, "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": 0.5}]},
    {"date": "2024-01-03", "inputTokens": 150, "outputTokens": 60, "cacheCreationTokens": 0, "cacheReadTokens": 0, "totalTokens": 210, "totalCost": 1.5,
     "modelsUsed": ["model-B"],
     "modelBreakdowns": [{"modelName": "model-B", "inputTokens": 150, "outputTokens": 60, "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": 1.5}]}
  ],
  "model": [
    {"modelName": "model-A", "inputTokens": 50, "outputTokens": 20, "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": 0.5, "totalTokens": 70,
     "providerBucket": "candidate alias: testprov (verified)", "providerMatchKind": "exact", "providerCandidates": [{"alias": "testprov", "status": "verified"}]},
    {"modelName": "model-B", "inputTokens": 150, "outputTokens": 60, "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": 1.5, "totalTokens": 210,
     "providerBucket": "unmapped (no configured provider alias recorded this exact/normalized model id)", "providerMatchKind": "unmapped", "providerCandidates": []}
  ],
  "project": [
    {"projectPath": "/home/x/projB", "sessionCount": 2, "inputTokens": 200, "outputTokens": 80, "cacheCreationTokens": 0, "cacheReadTokens": 0, "totalTokens": 280, "cost": 2.0}
  ],
  "provider": [
    {"providerBucket": "candidate alias: testprov (verified)", "providerMatchKind": "exact", "providerCandidates": [{"alias": "testprov", "status": "verified"}],
     "models": ["model-A"], "inputTokens": 50, "outputTokens": 20, "cacheCreationTokens": 0, "cacheReadTokens": 0, "totalTokens": 70, "cost": 0.5},
    {"providerBucket": "unmapped (no configured provider alias recorded this exact/normalized model id)", "providerMatchKind": "unmapped", "providerCandidates": [],
     "models": ["model-B"], "inputTokens": 150, "outputTokens": 60, "cacheCreationTokens": 0, "cacheReadTokens": 0, "totalTokens": 210, "cost": 1.5}
  ],
  "session": [
    {"sessionId": "sess-B1", "projectPath": "/home/x/projB", "firstActivity": "2024-01-01T09:00:00Z", "lastActivity": "2024-01-01T09:05:00Z", "totalTokens": 70, "totalCost": 0.5},
    {"sessionId": "sess-B2", "projectPath": "/home/x/projB", "firstActivity": "2024-01-03T09:00:00Z", "lastActivity": "2024-01-03T09:05:00Z", "totalTokens": 210, "totalCost": 1.5}
  ]
}
JSON

# ---------------------------------------------------------------------------
# Static checks
# ---------------------------------------------------------------------------

it "claude-usage.sh --help documents merge"
out="$(bash "$CLI" --help 2>&1)"
grep -q 'claude-usage merge' <<<"$out" && _pass "mentions merge subcommand" || _fail "missing from --help" "$out"
grep -q -- '--anonymize-as' <<<"$out" && _pass "documents --anonymize-as" || _fail "missing --anonymize-as doc" "$out"
grep -q -- '--real-names' <<<"$out" && _pass "documents --real-names" || _fail "missing --real-names doc" "$out"

it "merge --from is required"
out="$(bash "$CLI" merge 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && _pass "non-zero exit ($rc)" || _fail "exit 0 with no --from" "$out"
grep -q -- '--from' <<<"$out" && _pass "message names --from" || _fail "message doesn't mention --from" "$out"

it "merge --anonymize-as and --real-names are mutually exclusive"
out="$(bash "$CLI" merge --from "$FIXDIR_A" --anonymize-as X --real-names 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && _pass "non-zero exit ($rc)" || _fail "exit 0 with both flags" "$out"
grep -qi 'mutually exclusive' <<<"$out" && _pass "message explains the conflict" || _fail "no actionable message" "$out"

it "merge rejects a directory with no *.json files inside it"
mkdir -p "$HOME/merge-fixtures/empty"
out="$(bash "$CLI" merge --from "$HOME/merge-fixtures/empty" --format json 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && _pass "non-zero exit ($rc)" || _fail "exit 0 for empty source dir" "$out"

it "merge rejects a source path that is neither a file nor a directory"
out="$(bash "$CLI" merge --from "$HOME/merge-fixtures/does-not-exist" --format json 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && _pass "non-zero exit ($rc)" || _fail "exit 0 for missing source" "$out"

# ---------------------------------------------------------------------------
# Merge math: overlapping day/model keys sum correctly
# ---------------------------------------------------------------------------

it "merge: two directory sources, default anonymization, day/model totals sum correctly"
out="$(bash "$CLI" merge --from "$FIXDIR_A,$FIXDIR_B" --format json 2>&1)"
rc=$?
if [[ $rc -ne 0 ]]; then
  _fail "merge run failed" "rc=$rc out=$out"
else
  _pass "exit 0"
  _check="$(python3 - "$out" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
errs = []

t = d["totals"]
want_t = {"inputTokens": 300, "outputTokens": 130, "cacheCreationTokens": 10, "cacheReadTokens": 5, "totalTokens": 445}
for k, v in want_t.items():
    if t.get(k) != v:
        errs.append(f"totals.{k} want={v} got={t.get(k)}")
if abs(t.get("totalCost", 0) - 3.0) > 1e-9:
    errs.append(f"totals.totalCost want=3.0 got={t.get('totalCost')}")

days = {r["date"]: r for r in d["day"]}
if "2024-01-01" not in days or "2024-01-03" not in days:
    errs.append(f"expected both dates, got {list(days.keys())}")
else:
    d1 = days["2024-01-01"]
    want_d1 = {"inputTokens": 150, "outputTokens": 70, "cacheCreationTokens": 10, "cacheReadTokens": 5, "totalTokens": 235}
    for k, v in want_d1.items():
        if d1.get(k) != v:
            errs.append(f"day[2024-01-01].{k} want={v} got={d1.get(k)}")
    if abs(d1.get("totalCost", 0) - 1.5) > 1e-9:
        errs.append(f"day[2024-01-01].totalCost want=1.5 got={d1.get('totalCost')}")
    mbs = {m["modelName"]: m for m in d1.get("modelBreakdowns", [])}
    if "model-A" not in mbs or mbs["model-A"]["inputTokens"] != 150 or mbs["model-A"]["outputTokens"] != 70:
        errs.append(f"day[2024-01-01].modelBreakdowns.model-A wrong: {mbs.get('model-A')}")

    d3 = days["2024-01-03"]
    if d3.get("inputTokens") != 150 or d3.get("totalTokens") != 210:
        errs.append(f"day[2024-01-03] wrong: {d3}")

models = {m["modelName"]: m for m in d["model"]}
if "model-A" not in models or models["model-A"]["totalTokens"] != 235:
    errs.append(f"model.model-A wrong: {models.get('model-A')}")
if "model-B" not in models or models["model-B"]["totalTokens"] != 210:
    errs.append(f"model.model-B wrong: {models.get('model-B')}")

if errs:
    print("FAIL: " + " | ".join(errs))
else:
    print("OK")
PY
)"
  [[ "$_check" == "OK" ]] && _pass "day/model sums match hand-computed expectations" || _fail "merge math wrong" "$_check"
fi

it "merge: default anonymization collapses both projects into ONE 'coding agents' row, summed"
_check="$(python3 - "$out" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
errs = []
projs = d.get("project", [])
if len(projs) != 1:
    errs.append(f"expected exactly 1 project row after anonymization, got {len(projs)}: {projs}")
else:
    p = projs[0]
    if p.get("projectPath") != "coding agents":
        errs.append(f"expected projectPath='coding agents', got {p.get('projectPath')!r}")
    if p.get("sessionCount") != 3:
        errs.append(f"expected sessionCount=3, got {p.get('sessionCount')}")
    if p.get("totalTokens") != 445:
        errs.append(f"expected totalTokens=445, got {p.get('totalTokens')}")
    if abs(p.get("cost", 0) - 3.0) > 1e-9:
        errs.append(f"expected cost=3.0, got {p.get('cost')}")
raw = json.dumps(d)
if "/home/x/projA" in raw or "/home/x/projB" in raw:
    errs.append("real project path leaked into anonymized output")
if errs:
    print("FAIL: " + " | ".join(errs))
else:
    print("OK")
PY
)"
[[ "$_check" == "OK" ]] && _pass "anonymized project row is a single correctly-summed 'coding agents' row, no real paths leak" || _fail "anonymization wrong" "$_check"

it "merge: anonymized session rows have projectPath masked but are NOT collapsed (3 distinct sessions remain)"
_check="$(python3 - "$out" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
errs = []
sessions = d.get("session", [])
if len(sessions) != 3:
    errs.append(f"expected 3 session rows, got {len(sessions)}")
ids = {s.get("sessionId") for s in sessions}
if ids != {"sess-A", "sess-B1", "sess-B2"}:
    errs.append(f"expected all 3 original session ids, got {ids}")
for s in sessions:
    if s.get("projectPath") != "coding agents":
        errs.append(f"session {s.get('sessionId')} projectPath not masked: {s.get('projectPath')!r}")
if errs:
    print("FAIL: " + " | ".join(errs))
else:
    print("OK")
PY
)"
[[ "$_check" == "OK" ]] && _pass "session rows masked but not collapsed" || _fail "session masking wrong" "$_check"

it "merge: --anonymize-as NAME uses the custom label instead of the default"
out_custom="$(bash "$CLI" merge --from "$FIXDIR_A,$FIXDIR_B" --format json --anonymize-as 'Internal Project' 2>&1)"
_check="$(python3 - "$out_custom" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
projs = d.get("project", [])
if len(projs) == 1 and projs[0].get("projectPath") == "Internal Project" and projs[0].get("totalTokens") == 445:
    print("OK")
else:
    print(f"FAIL: {projs}")
PY
)"
[[ "$_check" == "OK" ]] && _pass "custom anonymization label applied and summed correctly" || _fail "custom label wrong" "$_check"

it "merge: --real-names keeps real project paths distinct, no collapsing"
out_real="$(bash "$CLI" merge --from "$FIXDIR_A,$FIXDIR_B" --format json --real-names 2>&1)"
_check="$(python3 - "$out_real" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
errs = []
projs = {p["projectPath"]: p for p in d.get("project", [])}
if "coding agents" in projs:
    errs.append("anonymization label present despite --real-names")
if "/home/x/projA" not in projs or "/home/x/projB" not in projs:
    errs.append(f"expected both real paths distinct, got {list(projs.keys())}")
else:
    if abs(projs["/home/x/projA"]["cost"] - 1.0) > 1e-9:
        errs.append(f"projA cost wrong: {projs['/home/x/projA']['cost']}")
    if abs(projs["/home/x/projB"]["cost"] - 2.0) > 1e-9:
        errs.append(f"projB cost wrong: {projs['/home/x/projB']['cost']}")
sessions = d.get("session", [])
if any(s.get("projectPath") not in ("/home/x/projA", "/home/x/projB") for s in sessions):
    errs.append(f"a session row has an unexpected projectPath: {sessions}")
if errs:
    print("FAIL: " + " | ".join(errs))
else:
    print("OK")
PY
)"
[[ "$_check" == "OK" ]] && _pass "real project paths preserved and distinct, correctly summed per-path" || _fail "--real-names wrong" "$_check"

it "merge: accepts a single JSON FILE source (not just a directory)"
out_single="$(bash "$CLI" merge --from "$FIXDIR_A/report.json" --format json 2>&1)"
rc=$?
[[ $rc -eq 0 ]] && _pass "exit 0 for single-file source" || _fail "non-zero exit" "rc=$rc out=$out_single"
grep -q '"coding agents"' <<<"$out_single" && _pass "single-source merge still anonymizes" || _fail "missing anonymized label" "$out_single"

it "merge: --out writes to the exact path"
out_path="$HOME/merged-custom.json"
stdout_capture="$(bash "$CLI" merge --from "$FIXDIR_A,$FIXDIR_B" --out "$out_path" 2>/dev/null)"
[[ -f "$out_path" ]] && _pass "file written at --out path" || _fail "no file at --out path" "$out_path"
[[ -z "$stdout_capture" ]] && _pass "no report flooded to stdout with --out" || _fail "unexpected stdout with --out" "$stdout_capture"
grep -q '"totalTokens": 445' "$out_path" 2>/dev/null && _pass "--out file has correct merged content" || _fail "--out content wrong" "$(cat "$out_path" 2>/dev/null)"

it "merge: default (no --format/--out) writes BOTH json+md under SHARED_DIR/usage-reports and prints md"
rm -rf "$SHARED_DIR/usage-reports"
default_stdout="$(bash "$CLI" merge --from "$FIXDIR_A,$FIXDIR_B" 2>/dev/null)"
_found_json=0; _found_md=0
for f in "$SHARED_DIR/usage-reports"/merged_*.json; do [[ -e "$f" ]] && _found_json=1; done
for f in "$SHARED_DIR/usage-reports"/merged_*.md; do [[ -e "$f" ]] && _found_md=1; done
[[ "$_found_json" -eq 1 ]] && _pass "json report written under SHARED_DIR/usage-reports" || _fail "json report not written" "$(ls "$SHARED_DIR/usage-reports" 2>&1)"
[[ "$_found_md" -eq 1 ]] && _pass "md report written under SHARED_DIR/usage-reports" || _fail "md report not written" "$(ls "$SHARED_DIR/usage-reports" 2>&1)"
grep -q '# Claude usage report' <<<"$default_stdout" && _pass "default run also prints markdown to stdout" || _fail "default run printed nothing useful" "$default_stdout"

summary
