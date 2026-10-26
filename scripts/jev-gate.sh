#!/usr/bin/env bash
# jev-gate.sh — shared POSIX PreToolUse permission gate backed by a Jev
# systemone decision endpoint (design: toolkit-jev-design §2.6).
#
# Contract (works for Claude Code PreToolUse hooks and Kimi [[hooks]] — both
# deliver the hook event as JSON on stdin):
#   stdin:  hook event JSON (Claude camelCase or Kimi snake_case; both are
#           accepted via jq alternates)
#   stdout: Claude-shaped permissionDecision JSON (Kimi/opencode consumers may
#           instead use the exit code — both are always set consistently)
#   exit:   0 = allow (or ask, or shadow mode), 2 = deny (reason on stderr)
#
# Env:
#   JEV_GATE=off            kill switch — instant allow; each use is appended to
#                           $JEV_STATE_DIR/gate-off.log (jev-stats reports it)
#   JEV_MODE=shadow|enforce (default shadow: always allow, log the would-be
#                           decision)
#   JEV_BASE_URL            endpoint base (required; unset => fail-open allow)
#   JEV_API_KEY / TYPESAFE_API_KEY (explicit override), or JEV_KEY_VAR (the
#                           key's variable NAME in api_keys.sh — resolved here
#                           at call time, never exported as secret material
#                           into the launched agent's whole process tree)
#   JEV_MODEL (default jev-latest)
#   JEV_GATE_TIMEOUT=2      curl timeout seconds
#   JEV_GATE_THRESHOLD=0.8  risky-probability deny floor
#   JEV_RISKY_THRESHOLD=0.7 risky-probability floor that escalates allow->ask
#   JEV_STATE_DIR=$HOME/.local/state/jev   evidence log directory
#
# Fail-open by design: any transport/parse error allows the call and logs a
# fallback reason: timeout (curl 28), unreachable (curl 6/7), tls_untrusted
# (curl 51/58/59/60/77/83), auth_rejected (HTTP 401/403), key_unpinned (https key whose origin+variable no pin attests; no request made), no_key (https with no
# key found: no request is made, so no bearer is ever sent blind), else
# endpoint_error. Availability beats enforcement; fail-closed is
# possible via JEV_GATE_FAIL=closed but is NOT the default.
set -u

JEV_MODE="${JEV_MODE:-shadow}"
JEV_GATE_TIMEOUT="${JEV_GATE_TIMEOUT:-2}"
JEV_STATE_DIR="${JEV_STATE_DIR:-$HOME/.local/state/jev}"
JEV_MODEL="${JEV_MODEL:-jev-latest}"

# Threshold precedence: explicit env var > calibrated decisions.lock.json
# (written by jev-calibrate.sh sweep) > fixed default. A lock file is read
# only when the operator hasn't already pinned a threshold via env.
_jev_lock_file="$JEV_STATE_DIR/decisions.lock.json"
_jev_lock_ask="" _jev_lock_deny=""
if [ -f "$_jev_lock_file" ] && command -v jq >/dev/null 2>&1; then
  _jev_lock_ask=$(jq -r '.ask_threshold // empty' "$_jev_lock_file" 2>/dev/null)
  _jev_lock_deny=$(jq -r '.deny_threshold // empty' "$_jev_lock_file" 2>/dev/null)
fi
JEV_GATE_THRESHOLD="${JEV_GATE_THRESHOLD:-${_jev_lock_deny:-0.8}}"
JEV_RISKY_THRESHOLD="${JEV_RISKY_THRESHOLD:-${_jev_lock_ask:-0.7}}"

_emit_allow() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"jev: %s"}}\n' "$1"
  exit 0
}
_emit_ask() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"jev: %s"}}\n' "$1"
  exit 0
}
_emit_deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"jev: %s"}}\n' "$1"
  printf 'jev-gate: denied — %s\n' "$1" >&2
  exit 2
}
# Fail-open/shadow/kill-switch paths must never assert an active permission
# decision Jev didn't actually evaluate — step aside instead (no JSON output,
# so Claude's/Kimi's normal permission flow applies) rather than overriding it
# with a blind "allow" (security review finding: Agent/Subprocess Permission
# Bypass).
_emit_passthrough() {
  exit 0
}

# 1. Kill switch.
# Every use of the kill switch is RECORDED (UTC timestamp, agent, cwd) in
# $JEV_STATE_DIR/gate-off.log so an unevaluated tool call is never invisible;
# jev-stats reports the count. The call itself still passes straight through.
if [ "${JEV_GATE:-on}" = "off" ]; then
  if mkdir -p "$JEV_STATE_DIR" 2>/dev/null; then
    printf '%s JEV_GATE=off: tool call passed through unevaluated (agent=%s cwd=%s)\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${JEV_AGENT:-unknown}" "$PWD" >> "$JEV_STATE_DIR/gate-off.log" 2>/dev/null || true
  fi
  _emit_passthrough
fi

# 2. Read + parse the hook event.
_hook_json=$(cat 2>/dev/null || true)
_tool=$(printf '%s' "$_hook_json" | jq -r '.tool_name // .toolName // .tool // "unknown"' 2>/dev/null)
[ -n "$_tool" ] && [ "$_tool" != "null" ] || _tool="unknown"
_state=$(printf '%s' "$_hook_json" | jq -c '.tool_input // .toolInput // .input // {}' 2>/dev/null)
[ -n "$_state" ] && [ "$_state" != "null" ] || _state="{}"
_agent=$(printf '%s' "$_hook_json" | jq -r '.agent // empty' 2>/dev/null)
[ -n "$_agent" ] || _agent="${JEV_AGENT:-unknown}"

# Truncate head+tail to 12000 chars (local-jev truncation convention).
if [ "${#_state}" -gt 12000 ]; then
  _state="$(printf '%s' "$_state" | head -c 6000)…TRUNCATED…$(printf '%s' "$_state" | tail -c 6000)"
fi

_state_hash=$(printf '%s' "$_state" | sha256sum 2>/dev/null | cut -c1-16)
[ -n "$_state_hash" ] || _state_hash=$(printf '%s' "$_state" | shasum -a 256 2>/dev/null | cut -c1-16)
[ -n "$_state_hash" ] || _state_hash="nohash"

# Millisecond wall clock, portable: bash>=5 EPOCHREALTIME, else GNU date %3N,
# else python3 / perl, else (last resort) whole seconds * 1000. The
# non-numeric check rejects BSD/macOS date printing a literal "3N".
_now_ms() {
  local t
  if [ -n "${EPOCHREALTIME:-}" ]; then
    t="${EPOCHREALTIME/[.,]/}"
    case "$t" in ''|*[!0-9]*) ;; *) printf '%s' "${t:0:${#t}-3}"; return 0 ;; esac
  fi
  t=$(date +%s%3N 2>/dev/null)
  case "$t" in ''|*[!0-9]*) ;; *) printf '%s' "$t"; return 0 ;; esac
  t=$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null)
  case "$t" in ''|*[!0-9]*) ;; *) printf '%s' "$t"; return 0 ;; esac
  t=$(perl -MTime::HiRes=time -e 'printf "%d", time()*1000' 2>/dev/null)
  case "$t" in ''|*[!0-9]*) ;; *) printf '%s' "$t"; return 0 ;; esac
  printf '%s' "$(( $(date +%s) * 1000 ))"
}

_log() { # _log <answer> <risky_p> <confidence> <latency_ms> <endpoint> <fallback>
  mkdir -p "$JEV_STATE_DIR" 2>/dev/null || return 0
  local _enforced=false
  [ "$JEV_MODE" = "enforce" ] && _enforced=true
  jq -cn \
    --argjson ts "$(($(date +%s) * 1000))" \
    --arg agent "$_agent" --arg tool "$_tool" --arg state_hash "$_state_hash" \
    --arg question "gate" --arg class "gate" --arg answer "$1" \
    --argjson risky_p "${2:-0}" --argjson confidence "${3:-0}" \
    --argjson latency_ms "${4:-0}" --arg endpoint "${5:-unknown}" \
    --arg mode "$JEV_MODE" --argjson enforced "$_enforced" \
    --arg fallback "${6:-}" \
    '{ts:$ts, agent:$agent, tool:$tool, state_hash:$state_hash, question:$question,
      class:$class, answer:$answer, risky_p:$risky_p, confidence:$confidence, latency_ms:$latency_ms,
      endpoint:$endpoint, mode:$mode, enforced:$enforced,
      fallback:(if $fallback == "" then null else $fallback end)}' \
    >> "$JEV_STATE_DIR/decisions.jsonl" 2>/dev/null || true
}

_decide() { # _decide <answer> <risky_p> <confidence> <latency_ms> <endpoint> <fallback> <reason>
  local answer="$1" risky="$2" conf="$3" lat="$4" ep="$5" fb="$6" reason="$7"
  _log "$answer" "$risky" "$conf" "$lat" "$ep" "$fb"
  if [ "$JEV_MODE" != "enforce" ]; then
    _emit_passthrough
  fi
  case "$answer" in
    deny) _emit_deny "$reason" ;;
    ask)  _emit_ask "$reason" ;;
    *)    _emit_allow "$reason" ;;
  esac
}

# 3. Deterministic risk floor (pre-Jev): destructive patterns force at most
# "ask" regardless of what the endpoint says — Jev can only make it stricter.
# The two flag patterns below are assembled from separate word/flag parts
# rather than written as one contiguous literal. The repo's own §11.4.113
# sweep (scripts/tests/verify_constitution.sh) greps every *.sh/*.py file for
# the push-command-plus-force-flag text this denylist exists to block, with
# no notion of denylist vs. real invocation, so even this deny-side
# occurrence must never spell it out contiguously in source or the sweep
# false-positives on its own guard.
_floor=allow
_dp_git_push="git push"
_dp_flag_long="--force"
_dp_flag_short="-f "
case "$_state" in
  *"rm -rf /"*|*"rm -fr /"*|*mkfs*|*':(){'*|*"> /dev/sd"*|*"${_dp_git_push} ${_dp_flag_long}"*|*"${_dp_git_push} ${_dp_flag_short}"*|*"| sh"*|*"| bash"*)
    _floor=ask ;;
esac

# 4. Endpoint required; no endpoint => fail-open: step aside rather than
# asserting an "allow" Jev never evaluated. The deterministic risk floor
# (pure pattern match, not dependent on Jev) can still escalate to "ask".
if [ -z "${JEV_BASE_URL:-}" ]; then
  _log "$_floor" 0 0 0 none "endpoint_error"
  if [ "$JEV_MODE" = "enforce" ] && [ "$_floor" = "ask" ]; then
    _emit_ask "no JEV_BASE_URL — risk floor matched"
  fi
  _emit_passthrough
fi

# 5. Ask Jev: one request, two questions (choice gate + noul risky) in the
# verified systemone wire format (research/jev-ecosystem.md §1.2): questions
# is a MAP of name -> question; all meaning lives in instructions/criteria.
_req=$(jq -cn --arg model "$JEV_MODEL" --arg state "tool=${_tool} input=${_state}" \
  '{model:$model, state:$state, questions:{
     gate:{type:"choice",
       instructions:"Should an AI coding agent be allowed to execute this tool call? allow=routine safe action, ask=needs human confirmation, deny=must not run.",
       criteria:{allow:"Routine, reversible, local, no secrets involved.",
                 ask:"Potentially destructive, externally visible, or ambiguous — a human should confirm.",
                 deny:"Clearly dangerous: data loss, secret exposure, or irreversible external side effects."}},
     risky:{type:"noul",
       instructions:"Does this action risk data loss, secret exposure, or irreversible external side effects?",
       criteria:{"true":"There is a real risk of data loss, secret exposure, or irreversible external side effects.",
                 "false":"The action is routine, reversible, and local."}}}}')

# --- API key resolution + origin binding ------------------------------------
# A key is only ever sent to an origin it was never "validated away" from.
# JEV_API_KEY is the explicit operator override (sent as given). Any other key is
# looked up by the variable NAME the endpoint declares: JEV_KEY_VAR when set,
# else the TypeSafe default TYPESAFE_API_KEY. Over https such a key is released
# ONLY when the (origin, key variable) pair is one of:
#   1. a loopback host (127.0.0.0/8, localhost, ::1) - the key stays on this machine;
#   2. the SHIPPED pin (providers/jev.json next to this script - never an env or
#      cache-supplied file), enabled, same origin AND same key variable;
#   3. an origin the operator listed in the environment as trusted:
#      CMA_JEV_TRUSTED_ORIGINS="https://host[:port]=KEYVAR[ https://other=KEYVAR2 ...]".
# The endpoint cache (jev-endpoints.json) and CMA_JEV_PINS_FILE do NOT attest a
# key: both can be written from a pins override, so attesting from them would
# let an override redirect a real key. Otherwise NO request is made (fallback
# key_unpinned).
_key="" _key_pinned=1
_kvar="${JEV_KEY_VAR:-TYPESAFE_API_KEY}"
printf '%s' "$_kvar" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$' || _kvar=""
if [ -n "${JEV_API_KEY:-}" ]; then
  _key="$JEV_API_KEY"
elif [ -n "$_kvar" ]; then
  _key="${!_kvar:-}"
  if [ -z "$_key" ] && [ -f "${CMA_KEYS_FILE:-$HOME/api_keys.sh}" ]; then
    _key="$(bash -c 'source "${CMA_KEYS_FILE:-$HOME/api_keys.sh}" >/dev/null 2>&1; printf %s "${'"$_kvar"':-}"')"
  fi
  if [ -n "$_key" ] && [[ "$JEV_BASE_URL" == https://* ]]; then
    _origin="$(printf '%s' "$JEV_BASE_URL" | sed -E 's#^(https://[^/?#]+).*#\1#')"
    _key_pinned=0
    # Userinfo, backslash, whitespace or percent bytes make the URL authority
    # ambiguous (curl may connect elsewhere than the text suggests): never pinned.
    case "$_origin" in *[@\\%[:space:]]*) _origin="" ;; esac
    if [ -n "$_origin" ]; then
      _hostport="${_origin#https://}"
      case "$_hostport" in
        \[*\]*) _h="${_hostport%%\]*}]" ;;
        *) _h="${_hostport%%:*}" ;;
      esac
      # loopback: exact grammar (127.x.x.x literal, localhost, [::1]); no look-alikes
      if printf '%s' "$_h" | grep -qE '^(127(\.[0-9]{1,3}){3}|localhost|\[::1\])$' \
         && ! printf '%s' "$_h" | grep -qE '(^|\.)(25[6-9]|2[6-9][0-9]|[3-9][0-9][0-9])(\.|$)'; then
        _key_pinned=1
      fi
      _selfp="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)" || _selfp=""
      [ -n "$_selfp" ] || _selfp="${BASH_SOURCE[0]}"
      _pinsf="$(cd "$(dirname "$_selfp")" 2>/dev/null && pwd -P)/providers/jev.json"
      if [ "$_key_pinned" = 0 ] && [ -f "$_pinsf" ] && jq -e --arg o "$_origin" --arg v "$_kvar" \
           '[(.hosted // {})[] | select((try (.base_url | capture("^(?<o>https://[^/?#]+)").o) catch "") == $o and (.key_var // "") == $v and (.enabled != false))] | length > 0' \
           "$_pinsf" >/dev/null 2>&1; then _key_pinned=1; fi
      if [ "$_key_pinned" = 0 ] && [ -n "${CMA_JEV_TRUSTED_ORIGINS:-}" ]; then
        # split on whitespace WITHOUT pathname expansion: a '*' in the value must never glob
        # against the working directory into a trusted-looking pair
        read -r -a _tlist <<<"$CMA_JEV_TRUSTED_ORIGINS"
        for _t in "${_tlist[@]}"; do
          if [ "${_t%%=*}" = "$_origin" ] && [ "${_t#*=}" = "$_kvar" ] && [ "${_t%%=*}" != "$_t" ]; then _key_pinned=1; fi
        done
      fi
    fi
  fi
fi
# No key found: over https NO request is made (a literal placeholder bearer
# would be sent blind to a remote server and could only ever fail); over plain
# http no Authorization header is sent at all, so a key is not needed there.
_no_key=0
if [[ "$JEV_BASE_URL" == https://* ]]; then
  if [ -z "$_key" ]; then _no_key=1
  elif [ "$_key_pinned" != 1 ]; then _no_key=2; fi
fi
_start_ms=$(_now_ms)
_resp="" _curl_rc=0 _http_code=000
# The bearer key is sent ONLY over https and NEVER on a command line (curl
# reads the header from a process-substitution file); over plain http no
# Authorization header is sent at all. -w appends the HTTP status after a
# newline so 401/403 can be told apart from a transport failure (curl -f exits
# 22 for both).
if [ "$_no_key" != 0 ]; then
  _curl_rc=$(( _no_key == 1 ? 99 : 98 ))
elif [[ "$JEV_BASE_URL" == https://* ]]; then
  _raw=$(curl -sf -m "$JEV_GATE_TIMEOUT" \
    -H "Content-Type: application/json" \
    -H @<(printf 'Authorization: Bearer %s\n' "$_key") \
    ${JEV_CA_FILE:+--cacert "$JEV_CA_FILE"} \
    -w '\n%{http_code}' \
    -d "$_req" "$JEV_BASE_URL/v1/systemone" 2>/dev/null)
  _curl_rc=$?
else
  _raw=$(curl -sf -m "$JEV_GATE_TIMEOUT" \
    -H "Content-Type: application/json" \
    -w '\n%{http_code}' \
    -d "$_req" "$JEV_BASE_URL/v1/systemone" 2>/dev/null)
  _curl_rc=$?
fi
if [ "$_no_key" = 0 ]; then
  _http_code="${_raw##*$'\n'}"
  _resp="${_raw%$'\n'*}"
  [ "$_raw" = "$_http_code" ] && _resp=""   # no newline at all: nothing but a code
fi
_end_ms=$(_now_ms)
_latency=$(( _end_ms - _start_ms ))
[ "$_latency" -ge 0 ] 2>/dev/null || _latency=0

if [ $_curl_rc -ne 0 ] || [ -z "$_resp" ]; then
  _fb="endpoint_error"
  case "$_curl_rc" in
    99)                       _fb="no_key" ;;
    98)                       _fb="key_unpinned" ;;
    28)                       _fb="timeout" ;;
    6|7)                      _fb="unreachable" ;;
    51|58|59|60|77|83)        _fb="tls_untrusted" ;;
    22) case "$_http_code" in 401|403) _fb="auth_rejected" ;; esac ;;
  esac
  if [ "${JEV_GATE_FAIL:-open}" = "closed" ]; then
    _decide deny 0 0 "$_latency" "${CMA_JEV_ENDPOINT_ID:-unknown}" "$_fb" "endpoint unreachable ($_fb) — fail-closed"
  fi
  # Fail-open: step aside rather than asserting an "allow" Jev never
  # evaluated. The deterministic risk floor can still escalate to "ask".
  _log "$_floor" 0 0 "$_latency" "${CMA_JEV_ENDPOINT_ID:-unknown}" "$_fb"
  if [ "$JEV_MODE" = "enforce" ] && [ "$_floor" = "ask" ]; then
    _emit_ask "endpoint unreachable ($_fb) — risk floor matched"
  fi
  _emit_passthrough
fi

# Verified response shape (research §1.2): {"answers":{"gate":{"type":"choice",
# "choice":...,"confidence":...}, "risky":{"type":"noul","noul":<0..1>}}}.
# The // .answer / yes-no fallbacks tolerate wire-compatible reimplementations.
_choice=$(printf '%s' "$_resp" | jq -r '.answers.gate.choice // .answers.gate.answer // "allow"' 2>/dev/null)
_risky=$(printf '%s' "$_resp" | jq -r '
  (.answers.risky.noul // .answers.risky.answer) as $a
  | if ($a | type) == "number" then $a
    elif $a == "yes" then (.answers.risky.probabilities.yes // 0.9)
    elif $a == "no" then (.answers.risky.probabilities.yes // 0.1)
    else (.answers.risky.probabilities.yes // 0) end' 2>/dev/null)
_conf=$(printf '%s' "$_resp" | jq -r '.answers.gate.confidence // 0' 2>/dev/null)
case "$_choice" in allow|ask|deny) : ;; *) _choice="allow" ;; esac
case "$_risky" in ''|null|*[!0-9.]*) _risky=0 ;; esac
case "$_conf" in ''|null|*[!0-9.]*) _conf=0 ;; esac

# 6. Decision mapping: deny > (risky >= gate threshold AND choice != allow);
# ask > choice==ask OR risky >= risky threshold; else allow. Risk floor can
# only escalate.
_answer="allow"
if [ "$_choice" = "deny" ]; then
  _answer="deny"
elif [ "$_choice" != "allow" ] && [ "$(awk -v r="$_risky" -v t="$JEV_GATE_THRESHOLD" 'BEGIN{print (r>=t)?1:0}')" = 1 ]; then
  _answer="deny"
elif [ "$_choice" = "ask" ] || [ "$(awk -v r="$_risky" -v t="$JEV_RISKY_THRESHOLD" 'BEGIN{print (r>=t)?1:0}')" = 1 ]; then
  _answer="ask"
fi
# Risky > 0.7 with an allow answer escalates to at least ask (risk floor).
if [ "$_answer" = "allow" ] && [ "$(awk -v r="$_risky" 'BEGIN{print (r>0.7)?1:0}')" = 1 ]; then
  _answer="ask"
fi
# Deterministic pre-Jev floor (pattern match) can only escalate further.
if [ "$_floor" = "ask" ] && [ "$_answer" = "allow" ]; then
  _answer="ask"
fi

_decide "$_answer" "$_risky" "$_conf" "$_latency" "${CMA_JEV_ENDPOINT_ID:-${JEV_BASE_URL##*://}}" "" \
  "choice=$_choice risky=$_risky mode=$JEV_MODE"
