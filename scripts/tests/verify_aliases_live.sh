#!/usr/bin/env bash
# verify_aliases_live.sh — comprehensive live verification for ALL provider aliases.
#
# Tests each alias with 6 checks:
#   1. Basic chat completion          (verdict-relevant)
#   2. Tools with missing 'parameters' field (proxy fix; verdict-relevant)
#   3. Tools with $ref/$defs (Grok-4 fix; verdict-relevant)
#   4. cache_control parameter (cleancache fix; verdict-relevant)
#   5. Streaming                      (recorded; 0 chunks = warning only —
#                                     ccr can buffer a non-streaming upstream)
#   6. Tool calling                   (verdict-relevant: Claude Code is
#                                     tool-driven; an alias whose model never
#                                     calls tools is broken in practice)
#
# Automatically starts proxy for providers that need it (e.g. Poe).
#
# Usage:
#   bash scripts/tests/verify_aliases_live.sh
#   bash scripts/tests/verify_aliases_live.sh --alias poe
#   bash scripts/tests/verify_aliases_live.sh --verbose

set +e
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/lib/assert.sh"

PROOF_DIR="${PROOF_DIR:-$TESTS_DIR/proof}"
VERBOSE=0 TARGET_ALIAS="" PROXY_PORT=3457

while (( $# )); do
  case "$1" in --alias) TARGET_ALIAS="$2"; shift 2 ;; --verbose) VERBOSE=1; shift ;; --timeout) TIMEOUT="$2"; shift 2 ;;
  esac; shift
done
: "${TIMEOUT:=30}"

mkdir -p "$PROOF_DIR"
EV="$PROOF_DIR/alias-verify-evidence.txt"
: > "$EV"

set -a
# shellcheck source=/dev/null  # runtime user file; path not known at analysis time
if [[ -f "${CMA_KEYS_FILE:-$HOME/api_keys.sh}" ]]; then source "${CMA_KEYS_FILE:-$HOME/api_keys.sh}" 2>/dev/null; fi
set +a
# shellcheck disable=SC2015,SC1091  # C is `true` (benign); aliases.sh exists only on installed hosts
[[ -f "$HOME/.local/share/claude-multi-account/aliases.sh" ]] && source "$HOME/.local/share/claude-multi-account/aliases.sh" 2>/dev/null || true

PDIR="$HOME/.local/share/claude-multi-account/providers"
total=0 passed=0 failed=0 qskip=0 askip=0 tskip=0 gated=0

if [[ -n "$TARGET_ALIAS" ]]; then
  f="$PDIR/$TARGET_ALIAS.env"
  if [[ -f "$f" ]]; then ALIASES=("$TARGET_ALIAS"); else echo "No env for $TARGET_ALIAS"; exit 1; fi
else
  ALIASES=(); for f in "$PDIR"/*.env; do ALIASES+=("$(basename "$f" .env)"); done
fi

echo "Alias verification: $(date)" | tee -a "$EV"
echo "Testing ${#ALIASES[@]} aliases" | tee -a "$EV"

# Start Poe proxy if needed
PROXY_PID=""
maybe_start_proxy() {
  local id="$1"
  # Same discovery as the launch wrapper (migrated to Go 2026-07-22): the single
  # cma-proxy binary resolves the family key itself (poe2->poe, kimi-*->kimi), so
  # just ask `--has-transform`. It lives where claude-proxy-build.sh installs it
  # ($SHARED_DIR/proxy/cma-proxy), the same dir cma_run_provider resolves at
  # launch. (Previously this mirrored the per-provider python <id>_proxy.py
  # discovery against a path that had drifted from install.sh — the sweep then
  # silently tested the RAW endpoint. The binary + --has-transform removes the
  # path-guessing entirely.)
  local _proxy_bin="${SHARED_DIR:-$HOME/.claude-shared}/proxy/cma-proxy"
  local proxy_script=""
  if [[ -x "$_proxy_bin" ]] && "$_proxy_bin" --has-transform "$id" >/dev/null 2>&1; then
    proxy_script="$_proxy_bin"
  fi
  if [[ -n "$proxy_script" && -z "$PROXY_PID" ]]; then
    # Upstream = the provider's real backend from its env (cma-proxy strips a
    # trailing /v1), passed explicitly so cloud providers proxy correctly and
    # do not fall back to cma-proxy's local default.
    local _up=""
    [[ -f "$PDIR/$id.env" ]] && _up="$( set -a; . "$PDIR/$id.env"; set +a; printf '%s' "${CMA_PROVIDER_BASE_URL:-}" )"
    # Pick a genuinely free port: a squatter on the default (ccr's own gateway
    # holds 3457 on some hosts) would otherwise make us proxy-to-nothing.
    local _pp_try=0
    while lsof -i ":$PROXY_PORT" >/dev/null 2>&1 && (( _pp_try < 20 )); do
      PROXY_PORT=$((PROXY_PORT + 1)); _pp_try=$((_pp_try + 1))
    done
    # shellcheck disable=SC2086
    "$_proxy_bin" --provider "$id" --port "$PROXY_PORT" ${_up:+--upstream "$_up"} &
    PROXY_PID=$!
    # Wait for OUR pid to own the port, not merely for the port to be busy.
    local _w=0
    while ! lsof -a -p "$PROXY_PID" -i ":$PROXY_PORT" >/dev/null 2>&1 && (( _w < 25 )); do
      kill -0 "$PROXY_PID" 2>/dev/null || break
      sleep 0.2; _w=$((_w + 1))
    done
    if lsof -a -p "$PROXY_PID" -i ":$PROXY_PORT" >/dev/null 2>&1; then
      echo "Started cma-proxy for $id on port $PROXY_PORT (pid=$PROXY_PID)" >&2
    else
      echo "WARNING: cma-proxy for $id failed to start on port $PROXY_PORT — testing the direct endpoint (shims INACTIVE)" >&2
      PROXY_PID=""; proxy_script=""
    fi
  fi
}

maybe_stop_proxy() {
  if [[ -n "$PROXY_PID" ]]; then
    kill "$PROXY_PID" 2>/dev/null || true
    PROXY_PID=""
    sleep 1
  fi
}

cfg=""
trap 'rm -f "${cfg:-}"' EXIT INT TERM

for alias_name in "${ALIASES[@]}"; do
  env_file="$PDIR/$alias_name.env"
  [[ -f "$env_file" ]] || continue
  total=$((total+1))

  # Parse env
  keyvar=""; base_url=""; model=""; fast_model=""; transport=""
  while IFS='=' read -r key val; do
    key="$(echo "$key" | xargs)"
    val="$(echo "$val" | tr -d "'\"")"
    case "$key" in CMA_PROVIDER_KEYVAR) keyvar="$val" ;;
      CMA_PROVIDER_BASE_URL) base_url="$val" ;;
      CMA_PROVIDER_MODEL) model="$val" ;; CMA_PROVIDER_FAST_MODEL) fast_model="$val" ;;
      CMA_PROVIDER_TRANSPORT) transport="$val" ;;
    esac
  done < <(grep '^CMA_PROVIDER_' "$env_file")

  model="${model:-$fast_model}"
  [[ -z "$model" ]] && continue

  # Get key. The Kimi Code OAuth sentinel has no var in the keys file — its
  # token comes from the live credentials file (fresh) or the per-alias
  # token-file snapshot (fallback), same freshness order as the launch wrapper.
  key=""
  if [[ "$keyvar" == "_CMA_KIMICODE_OAUTH_" ]]; then
    _kcred="$HOME/.kimi-code/credentials/kimi-code.json"
    if [[ -f "$_kcred" ]]; then
      _kexp="$(jq -r '.expires_at // 0' "$_kcred" 2>/dev/null || echo 0)"
      if (( _kexp > $(date +%s) + 60 )); then
        key="$(jq -r '.access_token // ""' "$_kcred" 2>/dev/null)"
      fi
    fi
    # Expired live token: refresh via the CLI (same chain as the launch wrapper).
    if [[ -z "$key" && -f "$_kcred" ]] && command -v kimi >/dev/null 2>&1; then
      timeout 20 kimi -p "hi" --output-format text >/dev/null 2>&1 || true
      key="$(jq -r '.access_token // ""' "$_kcred" 2>/dev/null)"
    fi
    [[ -z "$key" && -f "$PDIR/$alias_name.token" ]] && key="$(cat "$PDIR/$alias_name.token" 2>/dev/null)"
  elif [[ -n "${!keyvar:-}" ]]; then key="${!keyvar}"
  elif [[ -f "${CMA_KEYS_FILE:-$HOME/api_keys.sh}" ]]; then
    set +u
    # shellcheck source=/dev/null  # runtime user keys file, path only known at execution
    source "${CMA_KEYS_FILE:-$HOME/api_keys.sh}" 2>/dev/null || true
    set -u 2>/dev/null || true
    key="$(eval "echo \"\${$keyvar:-}\"" 2>/dev/null || true)"
  fi
  [[ -z "$key" ]] && { echo "SKIP $alias_name (no key)"; continue; }

  # Aliases the activation gate has already filtered out (unverified/failed/
  # pending) are intentionally not launchable — skip them honestly instead of
  # scoring a guaranteed failure (e.g. rate-limited coding plans re-created by
  # a sync but still gated out).
  _st="$(jq -r --arg id "$alias_name" '.[$id].status // "pending"' "$PDIR/status.json" 2>/dev/null)"
  if [[ "$_st" != "verified" ]]; then
    echo "◌ $alias_name: SKIP-GATED (status=${_st} — filtered by the verification gate, not launched)"
    gated=$((gated+1))
    { echo "--- $alias_name ($model) ---"; echo "verdict=SKIP-GATED status=$_st"; } >> "$EV"
    continue
  fi

  # Write API key to a temp config file so it never appears on argv (ps/proc visibility)
  cfg=$(mktemp "${TMPDIR:-/tmp}/curl-cfg.XXXXXX")
  chmod 600 "$cfg"

  # Build endpoint — use proxy if available. Native (/anthropic) transport is
  # probed at /v1/messages UNDER the kept prefix with x-api-key +
  # anthropic-version and Anthropic-shaped payloads — mirroring the runtime
  # (Bearer + OpenAI shape against an /anthropic base hangs/400s; that was a
  # live false-FAIL source for deepseek/xiaomi).
  test_url="${base_url:-}"
  maybe_start_proxy "$alias_name"
  native=0
  if [[ -n "$PROXY_PID" ]]; then
    test_url="http://127.0.0.1:$PROXY_PORT/v1/chat/completions"
  elif [[ "$transport" == "native" || "$test_url" == */anthropic* ]]; then
    native=1
    test_url="${test_url%/}"; test_url="${test_url%/v1/messages}"; test_url="${test_url%/v1}"
    test_url="$test_url/v1/messages"
  elif [[ "$test_url" != */chat/completions ]]; then
    test_url="${test_url%/}/chat/completions"
  fi
  if (( native )); then
    printf 'header = "x-api-key: %s"\nheader = "anthropic-version: 2023-06-01"\n' "$key" > "$cfg"
    tools_bare='"tools":[{"name":"test","description":"test"}]'
    tools_ref='"tools":[{"name":"test","description":"test","input_schema":{"type":"object","properties":{"x":{"$ref":"#/$defs/T"}},"$defs":{"T":{"type":"string"}}}}]'
    tools_calc='"tools":[{"name":"calc","description":"Calculate math","input_schema":{"type":"object","properties":{"expr":{"type":"string"}},"required":["expr"]}}]'
  else
    printf 'header = "Authorization: Bearer %s"\n' "$key" > "$cfg"
    tools_bare='"tools":[{"type":"function","function":{"name":"test","description":"test"}}]'
    tools_ref='"tools":[{"type":"function","function":{"name":"test","description":"test","parameters":{"type":"object","properties":{"x":{"$ref":"#/$defs/T"}},"$defs":{"T":{"type":"string"}}}}}]'
    tools_calc='"tools":[{"type":"function","function":{"name":"calc","description":"Calculate math","parameters":{"type":"object","properties":{"expr":{"type":"string"}},"required":["expr"]}}}]'
  fi

  # Quota/funds signature: an account-level state (dead points, depleted
  # credits), NOT evidence the alias is broken — same distinction
  # verify_claude_live.sh makes with its FUNDS bucket. Such aliases are
  # recorded as SKIP-QUOTA (never a PASS, never a toolkit FAIL).
  # Quota/billing signature. English phrases are NOT sufficient: providers
  # localize their error text. Live-proven 2026-07-19 — ZhipuAI returns
  #   HTTP 429 {"error":{"code":"1113","message":"余额不足或无可用资源包,请充值。"}}
  # ("insufficient balance / no resource package — please recharge"), which
  # matched none of the English patterns and was scored as a hard toolkit FAIL
  # rather than SKIP-QUOTA. The same key on the account's other model returns
  # HTTP 200, proving the key and the request shape are fine and only the
  # billing state differs — exactly what SKIP-QUOTA exists to express.
  # So also match language-independent signals: known provider billing codes,
  # and the CJK recharge/insufficient-balance wording.
  is_quota() {
    printf '%s' "$1" | grep -qiE 'insufficient_?quota|used up your (points|credits)|insufficient (credits|balance|funds)|usage limit|quota (exceeded|reached)|depleted|billing|fair.?usage|usage pattern' && return 0
    # ZhipuAI 1113 = "account in arrears"; 1112/1120 are sibling balance codes.
    printf '%s' "$1" | grep -qE '"code" *: *"?(1112|1113|1120)"?' && return 0
    # Locale-independent: 余额不足 (insufficient balance) / 充值 (recharge) /
    # 欠费 (in arrears) / 资源包 (resource package).
    printf '%s' "$1" | grep -qE '余额不足|请充值|欠费|无可用资源包'
  }
  # Transient signature: provider-side capacity/timeout/overload — a
  # point-in-time infrastructure state, not an alias defect. Recorded as
  # SKIP-TRANSIENT (never a PASS, never a toolkit FAIL).
  is_transient() { printf '%s' "$1" | grep -qiE 'maximum capacity|try again later|overloaded|temporarily unavailable|timed? ?out|service unavailable'; }

  VERDICT="PASS" ERRORS=""

  # Test 1: Basic chat completion. 000/429/400 flap under load (chutes/kilo
  # gateways return bare 400s during capacity wobbles — recovered within
  # minutes during live runs), so they get up to two retries; a quota
  # signature short-circuits to SKIP-QUOTA (deterministic account state),
  # and a persistent 400 after the retries stays a definitive FAIL.
  code=000 resp=""
  for attempt in 1 2 3; do
    [[ $VERBOSE -eq 1 ]] && echo "  $alias_name: test 1 (basic, attempt $attempt)..." >&2
    resp=$(curl -s --max-time "$TIMEOUT" -X POST "$test_url" -H "Content-Type: application/json" --config "$cfg" \
      -d "{\"model\":\"$model\",\"max_tokens\":256,\"messages\":[{\"role\":\"user\",\"content\":\"Say OK\"}]}" 2>/dev/null || echo "{}")
    code=$(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(200 if (d.get('choices') or d.get('content')) else d.get('error',{}).get('code',400))" 2>/dev/null || echo 000)
    [[ "$code" == "200" ]] && break
    if is_quota "$resp" || [[ "$code" == "402" ]]; then code="QUOTA"; break; fi
    case "$code" in 000|429|400) (( attempt < 3 )) && sleep 3 ;; *) break ;; esac
  done
  if [[ "$code" == "QUOTA" ]]; then VERDICT="SKIP-QUOTA"; ERRORS="${ERRORS}funds "
  elif is_transient "$resp" || [[ "$code" =~ ^(000|429|5..)$ ]]; then VERDICT="SKIP-TRANSIENT"; ERRORS="${ERRORS}transient($code) "
  elif [[ "$code" != "200" ]]; then ERRORS="${ERRORS}basic($code) "; VERDICT="FAIL"; fi

  # Test 2: Tools missing parameters
  [[ $VERBOSE -eq 1 ]] && echo "  $alias_name: test 2 (missing params)..." >&2
  resp2=$(curl -s --max-time "$TIMEOUT" -X POST "$test_url" -H "Content-Type: application/json" --config "$cfg" \
    -d "{\"model\":\"$model\",\"max_tokens\":256,\"messages\":[{\"role\":\"user\",\"content\":\"Say OK\"}],$tools_bare}" 2>/dev/null || echo "{}")
  err2=$(echo "$resp2" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('error',{}).get('message',''))" 2>/dev/null || true)
  echo "$err2" | grep -qi "Field required\|parameters" && { ERRORS="${ERRORS}tools-params "; VERDICT="FAIL"; }

  # Test 3: Tools with $ref
  [[ $VERBOSE -eq 1 ]] && echo "  $alias_name: test 3 (\$ref)..." >&2
  resp3=$(curl -s --max-time "$TIMEOUT" -X POST "$test_url" -H "Content-Type: application/json" --config "$cfg" \
    -d "{\"model\":\"$model\",\"max_tokens\":256,\"messages\":[{\"role\":\"user\",\"content\":\"Say OK\"}],$tools_ref}" 2>/dev/null || echo "{}")
  err3=$(echo "$resp3" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('error',{}).get('message',''))" 2>/dev/null || true)
  echo "$err3" | grep -qi "unresolvable\|\$ref\|\$defs" && { ERRORS="${ERRORS}dollar-ref "; VERDICT="FAIL"; }

  # Test 4: cache_control
  [[ $VERBOSE -eq 1 ]] && echo "  $alias_name: test 4 (cache_control)..." >&2
  resp4=$(curl -s --max-time "$TIMEOUT" -X POST "$test_url" -H "Content-Type: application/json" --config "$cfg" \
    -d "{\"model\":\"$model\",\"max_tokens\":256,\"messages\":[{\"role\":\"user\",\"content\":\"Say OK\",\"cache_control\":{\"type\":\"ephemeral\"}}]}" 2>/dev/null || echo "{}")
  err4=$(echo "$resp4" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('error',{}).get('message',''))" 2>/dev/null || true)
  echo "$err4" | grep -qi "cache_control\|unknown field" && { ERRORS="${ERRORS}cache_control "; VERDICT="FAIL"; }

  # Test 5: Streaming
  [[ $VERBOSE -eq 1 ]] && echo "  $alias_name: test 5 (stream)..." >&2
  chunks=$(curl -s --max-time "$TIMEOUT" -X POST "$test_url" -H "Content-Type: application/json" --config "$cfg" \
    -d "{\"model\":\"$model\",\"max_tokens\":16,\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}]}" 2>/dev/null | grep -c 'data: {"id"' || true)

  # Test 6: Tool calling. An instructed tool call that never happens means the
  # alias cannot drive Claude Code's tool-centric protocol — verdict-relevant
  # (anti-bluff). Model discretion flakes, so one retry is allowed; a quota
  # signature buckets the alias as SKIP-QUOTA, not a tool-support FAIL.
  has_tool=no
  for attempt in 1 2; do
    [[ $VERBOSE -eq 1 ]] && echo "  $alias_name: test 6 (tool call, attempt $attempt)..." >&2
    resp6=$(curl -s --max-time "$TIMEOUT" -X POST "$test_url" -H "Content-Type: application/json" --config "$cfg" \
      -d "{\"model\":\"$model\",\"max_tokens\":512,\"messages\":[{\"role\":\"user\",\"content\":\"Calculate 7*6 using the calc tool. You MUST call the tool.\"}],$tools_calc}" 2>/dev/null || echo "{}")
    if is_quota "$resp6"; then has_tool="QUOTA"; break; fi
    has_tool=$(echo "$resp6" | python3 -c "
import json,sys
d=json.load(sys.stdin)
tc=d.get('choices',[{}])[0].get('message',{}).get('tool_calls')
if tc: print(tc)
elif any(isinstance(b,dict) and b.get('type')=='tool_use' for b in (d.get('content') or [])): print('tool_use')
else: print('no')" 2>/dev/null || echo "no")
    [[ "$has_tool" != "no" ]] && break
    (( attempt < 2 )) && sleep 3
  done
  if [[ "$has_tool" == "QUOTA" ]]; then VERDICT="SKIP-QUOTA"; ERRORS="${ERRORS}funds "
  elif [[ "$has_tool" == "no" ]] && { [[ -z "$resp6" || "$resp6" == "{}" ]] || is_transient "$resp6"; }; then
    VERDICT="SKIP-TRANSIENT"; ERRORS="${ERRORS}transient(tool-timeout) "
  elif [[ "$has_tool" == "no" ]]; then ERRORS="${ERRORS}no-tool-call "; VERDICT="FAIL"; fi

  # Record
  {
    echo "--- $alias_name ($model) ---"
    echo "test1(basic)=$code test2(no_params)=${err2:0:40} test3(ref)=${err3:0:40} test4(cache)=${err4:0:40} test5(stream)=${chunks}chunks test6(tool)=${has_tool:0:20}"
    echo "verdict=$VERDICT"
  } >> "$EV"

  if [[ "$VERDICT" == "PASS" ]]; then passed=$((passed+1)); [[ $VERBOSE -eq 1 ]] && echo "✓ $alias_name: PASS"
  elif [[ "$VERDICT" == "SKIP-QUOTA" ]]; then qskip=$((qskip+1)); echo "◌ $alias_name: SKIP-QUOTA (account out of funds/credits — not a toolkit failure)"
  elif [[ "$VERDICT" == "SKIP-TRANSIENT" ]]; then tskip=$((tskip+1)); echo "◌ $alias_name: SKIP-TRANSIENT (provider capacity/timeout — point-in-time, not a toolkit failure)"
  else failed=$((failed+1)); echo "✗ $alias_name: FAIL — $ERRORS"
  fi
  maybe_stop_proxy
  rm -f "${cfg:-}"; cfg=""
done
maybe_stop_proxy

# --- Claude Alias Tests (native Anthropic transport) ---
test_claude_alias() {
  local alias_name="$1" config_dir="$2"
  total=$((total+1))
  export CLAUDE_CONFIG_DIR="$config_dir"

  # Basic test. Account-level states are NOT toolkit failures — quota
  # (weekly/usage limits) and an expired OAuth session (live-proven
  # 2026-07-26: milos85vasic FAILed this leg on "Failed to authenticate:
  # OAuth session expired and could not be refreshed" — its
  # .credentials.json refresh token had lapsed 4 days earlier, an
  # account-SIDE state needing an interactive `claude /login`; the toolkit
  # never touches .credentials.json, a PRIVATE_ITEM). stderr is captured
  # separately and consulted ONLY for classification + detail: the auth
  # error is not guaranteed to arrive on stdout, but merging stderr into
  # the PASS grep below would risk a false PASS from hook noise.
  local _errf result errtxt
  _errf=$(mktemp "${TMPDIR:-/tmp}/cma-alias-err.XXXXXX")
  result=$(cma_run -p "Say OK" 2>"$_errf" || true)
  errtxt=$(cat "$_errf" 2>/dev/null); rm -f "$_errf"
  if printf '%s\n%s' "$result" "$errtxt" | grep -qiE 'failed to authenticate|oauth session expired|not logged in'; then
    askip=$((askip+1))
    echo "◌ $alias_name: SKIP-AUTH (OAuth session expired — re-login with claude /login; not a toolkit failure)" | tee -a "$EV"
  elif printf '%s\n%s' "$result" "$errtxt" | grep -qiE 'weekly limit|usage limit|rate limit|hit your.*limit|insufficient'; then
    qskip=$((qskip+1))
    echo "◌ $alias_name: SKIP-QUOTA (account limit — not a toolkit failure)" | tee -a "$EV"
  elif printf '%s' "$result" | grep -qi "OK\|ready\|help"; then
    passed=$((passed+1))
    echo "✓ $alias_name: PASS" | tee -a "$EV"
  else
    failed=$((failed+1))
    echo "✗ $alias_name: FAIL" | tee -a "$EV"
  fi
  # Detail for EVERY verdict: a bare "✗ name: FAIL" with the captured output
  # discarded is undiagnosable — that is exactly how the 2026-07-26
  # milos85vasic FAIL shipped with no error text in any artifact.
  printf '  detail(%s): %.300s\n' "$alias_name" "${result}${errtxt:+ | stderr: $errtxt}" >> "$EV"
  unset CLAUDE_CONFIG_DIR
}

# Claude alias tests drive the real `cma_run` wrapper (from aliases.sh) over the
# native Anthropic transport, so they need BOTH a resolvable claude binary AND
# the cma_run function loaded. On a host missing either, skip them instead of
# emitting false FAILs (matches the live-verifier SKIP convention).
claude_bin="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || true)}"
if [[ -z "$TARGET_ALIAS" ]]; then
  if [[ -n "$claude_bin" ]] && declare -F cma_run >/dev/null 2>&1; then
    # Dynamically test only the account dirs that actually exist on this host,
    # so the script does not produce false FAILs on hosts with different account names.
    for _cdir in "$HOME/.claude-milos85vasic" "$HOME/.claude-milos85vasic2nd" "$HOME/.claude-milos85vasic3rd"; do
      [[ -d "$_cdir" ]] || continue
      test_claude_alias "${_cdir##*/.claude-}" "$_cdir"
    done
  else
    echo "SKIP claude-alias tests (no claude binary or cma_run wrapper present)" | tee -a "$EV"
  fi
fi

# Nothing was actually exercised (no provider env files, and the Claude alias
# tests were skipped): SKIP cleanly with exit 0 so run-proof doesn't count an
# absent prerequisite as a failure (mirrors verify_opencode/providers_live.sh).
if (( total == 0 )); then
  echo | tee -a "$EV"
  echo "SKIP: no provider aliases and no runnable Claude alias tests on this host — alias live verification skipped." | tee -a "$EV"
  exit 0
fi

echo | tee -a "$EV"
echo "PASS: $passed FAIL: $failed SKIP-QUOTA: ${qskip:-0} SKIP-AUTH: ${askip:-0} SKIP-TRANSIENT: ${tskip:-0} SKIP-GATED: ${gated:-0} TOTAL: $total" | tee -a "$EV"
# Exit code counts only GENUINE failures. SKIP-QUOTA aliases are account-level
# funds states, SKIP-TRANSIENT aliases are provider capacity/timeout states,
# and SKIP-GATED aliases are intentionally not launchable (the verification
# gate already filtered them) — all reported honestly in the evidence, never
# PASSed, never counted as toolkit failures (mirrors verify_claude_live.sh).
exit $failed
