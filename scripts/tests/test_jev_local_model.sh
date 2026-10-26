#!/usr/bin/env bash
# test_jev_local_model.sh - which model of the LOCAL llmctl decision gateway the Jev layer uses (claude-providers sync-jev).
#
# Root cause (2026-10-26, captured: the endpoint cache named decide-2b after a sync with decide-max validated and serving):
#   detect_jev_records took `.data[0].id` of GET /v1/models. The llmctl gateway lists its profiles ALPHABETICALLY, so the
#   "first" model was whatever sorts first - decide-2b, the smallest generative profile - which answered `ask` where
#   decide-max answered `deny` on the same dangerous call (the operator's finding). The documented knob did not exist.
# Now (_cma_jev_pick_local_model): CMA_JEV_LOCAL_MODEL pin > evidence ranking (validated per `llmctl status --json`, then the
# largest weights per `llmctl plan --json`) > first listed ready model. This suite drives the REAL detector against a REAL
# loopback gateway fixture listing 5 profiles alphabetically and a fake `llmctl` CLI that answers status/plan --json from fixture
# files (the real output shapes, captured from llmctl 3.2.2). Paired mutations run against a COPY of scripts/ (never the real tree).
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
set +e
export CMA_JEV_ALLOW_HTTP=1                       # plain-http loopback fixture (TLS default is covered by test_jev_detect_https.sh)
unset CMA_JEV_LOCAL_MODEL CMA_LLMCTL_BIN CMA_JEV_PINS_FILE
FIXTURE="$SCRIPTS_DIR/tests/fixtures/jev_server.py"
FX="$SCRIPTS_DIR/tests/fixtures/llmctl"
KEYS="$HOME/api_keys.sh"; : > "$KEYS"; export CMA_KEYS_FILE="$KEYS"
PDIR="$HOME/.local/share/claude-multi-account/providers"; mkdir -p "$PDIR"

# --- a loopback gateway that lists five profiles alphabetically (status ready), like llmctl's --------------------------------
start_gateway() { # start_gateway <MODELS-spec> -> sets GW_PORT GW_PID
  local pf="$HOME/gw.port.$RANDOM"
  CMA_JEV_FIXTURE_MODELS="$1" python3 "$FIXTURE" 0 "$pf" >/dev/null 2>&1 &
  GW_PID=$!
  local _; for _ in $(seq 1 50); do [[ -s "$pf" ]] && break; sleep 0.1; done
  GW_PORT="$(cat "$pf" 2>/dev/null)"
}
ALPHA="decide-2b,decide-kev-9b,decide-max,decide-nli,decide-pro"
start_gateway "$ALPHA"; MAIN_PID="$GW_PID"; MAIN_PORT="$GW_PORT"
trap 'kill "$MAIN_PID" "${GW_PID:-0}" 2>/dev/null; cleanup_sandbox' EXIT

PINS="$HOME/jev-pins.json"
mkpins() { jq --argjson p "$1" '.hosted.typesafe.enabled=false | .hosted.openrouter.enabled=false | .local_gateway.port=$p | .local_gateway.scheme="http" | .local_gateway.key_var="" | .lan=[]' \
  "$SCRIPTS_DIR/providers/jev.json" > "$PINS"; }
mkpins "$MAIN_PORT"; export CMA_JEV_PINS_FILE="$PINS"

# --- a fake llmctl CLI: status --json / plan --json answer from files ------------------------------------------------------
BIN="$HOME/bin"; mkdir -p "$BIN"
cat > "$BIN/llmctl" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "status --json") cat "${FAKE_LLMCTL_STATUS:?}" ;;
  "plan --json")   cat "${FAKE_LLMCTL_PLAN:?}" ;;
  *) echo "fake llmctl: unsupported: $*" >&2; exit 2 ;;
esac
SH
chmod +x "$BIN/llmctl"
export CMA_LLMCTL_BIN="$BIN/llmctl" FAKE_LLMCTL_PLAN="$FX/plan_decide.json" FAKE_LLMCTL_STATUS="$FX/status_decide_all_validated.json"

PROVIDERS_SH="$SCRIPTS_DIR/claude-providers.sh"
ERRF="$HOME/err.txt"
# local_rec [script] [env...] : the jev-local record of the real detector (stderr kept in $ERRF)
local_rec() {
  local script="${1:-$PROVIDERS_SH}"; shift || true
  env "$@" bash -c 'source "'"$script"'" >/dev/null 2>&1; detect_jev_records' 2>"$ERRF" \
    | jq -c '[.[] | select(.provider_id=="jev-local")] | .[0] // {}'
}
model_of() { jq -r '.strong_model // "absent"' <<<"$1"; }

it "B1 THE DEFECT: five validated profiles listed alphabetically, no pin -> the largest validated model (decide-max), not decide-2b"
R="$(local_rec)"
assert_eq "decide-max" "$(model_of "$R")" "strong_model is decide-max (legacy .data[0] gave decide-2b)"
assert_eq "decide-max" "$(jq -r '.fast_model' <<<"$R")" "fast_model follows"
case "$(jq -r '.reason' <<<"$R")" in *"evidence: validated (llmctl status) and the largest validated model of 5 (9086 MiB weights"*) _pass "the record's reason names the evidence" ;; *) _fail "reason names the evidence" "$(jq -r '.reason' <<<"$R")" ;; esac

it "B2 an UNVALIDATED model is never preferred: decide-max NOT validated -> the largest validated one (decide-kev-9b)"
jq '(.[] | select(.profile=="decide-max") | .validation) = "NOT VALIDATED (no record)"' "$FX/status_decide_all_validated.json" > "$HOME/status_nomax.json"
R="$(local_rec "$PROVIDERS_SH" FAKE_LLMCTL_STATUS="$HOME/status_nomax.json")"
assert_eq "decide-kev-9b" "$(model_of "$R")" "decide-max skipped (not validated), decide-kev-9b (6064 MiB) wins"

it "B3 CMA_JEV_LOCAL_MODEL pins the model (an operator's measurement beats the capacity rule)"
R="$(local_rec "$PROVIDERS_SH" CMA_JEV_LOCAL_MODEL=decide-pro)"
assert_eq "decide-pro" "$(model_of "$R")" "pinned decide-pro"
case "$(jq -r '.reason' <<<"$R")" in *"pinned by CMA_JEV_LOCAL_MODEL"*) _pass "reason says pinned" ;; *) _fail "reason says pinned" "$(jq -r '.reason' <<<"$R")" ;; esac

it "B4 a pin the gateway does not serve is NOT served blind: warning + the evidence ranking"
R="$(local_rec "$PROVIDERS_SH" CMA_JEV_LOCAL_MODEL=decide-ghost)"
assert_eq "decide-max" "$(model_of "$R")" "falls back to the evidence ranking"
grep -q "CMA_JEV_LOCAL_MODEL='decide-ghost' is not served" "$ERRF" && _pass "the operator is told the pin was not honoured" || _fail "pin warning" "$(cat "$ERRF")"

it "B5 a pin on a model the gateway reports degraded (not ready) is not honoured either"
start_gateway "decide-2b,decide-kev-9b,decide-max,decide-nli,decide-pro:degraded"; DEG_PID="$GW_PID"; mkpins "$GW_PORT"
R="$(local_rec "$PROVIDERS_SH" CMA_JEV_LOCAL_MODEL=decide-pro)"
assert_eq "decide-max" "$(model_of "$R")" "degraded pin -> evidence ranking over the ready models"
kill "$DEG_PID" 2>/dev/null; mkpins "$MAIN_PORT"

it "B6 no usable llmctl CLI -> the first listed ready model, and the record says there was no evidence"
R="$(local_rec "$PROVIDERS_SH" CMA_LLMCTL_BIN=/nonexistent/llmctl)"
assert_eq "decide-2b" "$(model_of "$R")" "legacy first listed (honest fallback)"
case "$(jq -r '.reason' <<<"$R")" in *"no llmctl validation evidence available"*) _pass "reason is honest about the missing evidence" ;; *) _fail "honest reason" "$(jq -r '.reason' <<<"$R")" ;; esac

it "B7 nothing validated -> first listed ready model (never an unvalidated 'strongest')"
jq 'map(.validation = "NOT VALIDATED (no record)")' "$FX/status_decide_all_validated.json" > "$HOME/status_none.json"
R="$(local_rec "$PROVIDERS_SH" FAKE_LLMCTL_STATUS="$HOME/status_none.json")"
assert_eq "decide-2b" "$(model_of "$R")" "first listed"

it "B8 garbage from the llmctl CLI is survived (not JSON) -> first listed, no crash"
echo 'not json' > "$HOME/junk.json"
R="$(local_rec "$PROVIDERS_SH" FAKE_LLMCTL_STATUS="$HOME/junk.json" FAKE_LLMCTL_PLAN="$HOME/junk.json")"
assert_eq "decide-2b" "$(model_of "$R")" "first listed"

it "B9 END TO END: claude-providers sync-jev writes the endpoint cache naming decide-max; the launch env exports it"
rm -f "$PDIR/jev-endpoints.json"
bash "$PROVIDERS_SH" sync-jev --quiet >"$HOME/sync.out" 2>&1
CACHE="$PDIR/jev-endpoints.json"
assert_file "$CACHE" "endpoint cache written"
assert_eq "decide-max" "$(jq -r '.endpoints[0].model' "$CACHE")" "cache endpoints[0].model = decide-max"
M="$(bash -c 'source "'"$SCRIPTS_DIR"'/lib.sh" >/dev/null 2>&1; CMA_JEV_QUIET=1 cma_jev_env; printf %s "$JEV_MODEL"')"
assert_eq "decide-max" "$M" "cma_jev_env exports JEV_MODEL=decide-max at launch"
CMA_JEV_LOCAL_MODEL=decide-pro bash "$PROVIDERS_SH" sync-jev --quiet >/dev/null 2>&1
assert_eq "decide-pro" "$(jq -r '.endpoints[0].model' "$CACHE")" "sync-jev honours CMA_JEV_LOCAL_MODEL in the cache"
bash "$PROVIDERS_SH" sync-jev --quiet >/dev/null 2>&1

# ---------------------------------------------------------------------------------------------------------------------------
# PAIRED MUTATIONS: each re-introduces ONE defect into a COPY of scripts/ and the matching case above MUST go RED.
# ---------------------------------------------------------------------------------------------------------------------------
MUT="$HOME/mut"
mutant() { # mutant <name> <file> <old> <new> -> prints the path of <file> in a copy of scripts/ with ONE exact replacement
  local d="${MUT:?}/${1:?}"
  rm -rf -- "$d"; mkdir -p "$d"; cp -a "$SCRIPTS_DIR" "$d/scripts"
  python3 -I - "$d/scripts/$2" "$3" "$4" <<'PY' || return 1
import sys
f, old, new = sys.argv[1:4]
s = open(f).read()
if s.count(old) != 1:
    sys.exit("mutation anchor found %d times in %s: %r" % (s.count(old), f, old))
open(f, "w").write(s.replace(old, new))
PY
  printf '%s\n' "$d/scripts/$2"
}
killed() { # killed <label> <expected-good-value> <actual>
  if [[ "$3" != "$2" ]]; then _pass "MUTANT $1 -> '$3' instead of '$2': the suite goes RED"; else _fail "MUTANT $1 survived" "still produced '$2'"; fi
}
it "M1 mutant: legacy .data[0] selection restored (the pick function is never called)"
MP="$(mutant legacy claude-providers.sh 'if [[ "$_tid" == "local" ]]; then
              # the LOCAL llmctl gateway' 'if [[ "$_tid" == "never-local" ]]; then
              # the LOCAL llmctl gateway')"
killed legacy decide-max "$(model_of "$(local_rec "$MP")")"

it "M2 mutant: the pin is ignored"
MP="$(mutant nopin claude-providers.sh 'if grep -qxF -- "$pin" <<<"$ids"; then' 'if false; then')"
killed nopin decide-pro "$(model_of "$(local_rec "$MP" CMA_JEV_LOCAL_MODEL=decide-pro)")"

it "M3 mutant: listing order instead of capacity (largest-weights criterion dropped)"
MP="$(mutant order claude-providers.sh 'sort_by([-.mb, .i])' 'sort_by([.i])')"
killed order decide-max "$(model_of "$(local_rec "$MP")")"

it "M4 mutant: validation evidence ignored (an unvalidated model may win)"
MP="$(mutant noval claude-providers.sh '| ($c | map(select(.v))) as $val' '| ($c) as $val')"
killed noval decide-kev-9b "$(model_of "$(local_rec "$MP" FAKE_LLMCTL_STATUS="$HOME/status_nomax.json")")"

it "M5 mutant: the launch path ignores the cache model (cma_jev_env exports a fixed model)"
MP="$(mutant envmodel lib.sh '_jev_model=$(printf '"'"'%s'"'"' "$_jev_line" | cut -f3)' '_jev_model=jev-latest')"
M="$(bash -c 'source "'"${MP}"'" >/dev/null 2>&1; CMA_JEV_QUIET=1 cma_jev_env; printf %s "$JEV_MODEL"' 2>/dev/null)"
killed envmodel decide-max "$M"
rm -rf -- "${MUT:?}"

summary
