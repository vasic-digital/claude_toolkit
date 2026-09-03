#!/usr/bin/env bash
# providers-verify.sh — pluggable verification adapter for claude-providers.
#
# Verifies that a provider's key works and a model exists/responds. Strategy,
# in order:
#   1. If the LLMsVerifier binary is built (submodules/LLMsVerifier/bin/
#      model-verification), use it — the authoritative "Do you see my code?"
#      check. Pass/fail is read from its stdout (Status: verified + Can See
#      Code: true), per its documented contract.
#   2. Else, if curl+jq are present, network is allowed, and the key is set,
#      run two live probes against the provider's CHAT endpoint with the
#      SELECTED model: a VERIFY_OK sentinel probe (anti-bluff — a bare 200
#      proves the key is accepted, not that the model responds) followed by a
#      tool-calling probe (Claude Code is entirely tool-driven, so a chat-only
#      model is a broken alias in practice).
#   3. Else, report 'unverified' (NOT a failure) — the alias is still usable;
#      full verification is opt-in (build the submodule).
#
# Output: one word on stdout — verified | failed | unverified — plus a reason
# on stderr. Exit code: 0 verified, 1 failed, 2 unverified.
#
# Args: --provider ID --model M --key-var VAR [--base-url URL] [--offline]
set -uo pipefail

_cma_src="${BASH_SOURCE[0]}"
while [ -L "$_cma_src" ]; do
  _cma_tgt="$(readlink "$_cma_src")"
  case "$_cma_tgt" in /*) _cma_src="$_cma_tgt" ;; *) _cma_src="$(dirname "$_cma_src")/$_cma_tgt" ;; esac
done
LIB_DIR="$(cd "$(dirname "$_cma_src")" && pwd)"
unset _cma_src _cma_tgt

# Gate 0 below needs the ccr-gateway test. lib.sh OWNS it (_cma_is_ccr_gateway,
# emitted from _cma_emit_ccr_gateway_guard) and the launch gate in
# cma_run_provider uses the very same bytes — sourcing here is what keeps the
# verify gate and the launch gate from drifting apart, which is exactly how the
# duplicated `case` statements came to disagree. lib.sh turns on `set -e`; this
# script's contract is non-zero-tolerant (probes are graded, not fatal), so its
# own flags are restored immediately.
# shellcheck source=lib.sh
. "$LIB_DIR/lib.sh"
set -uo pipefail
set +e

PROVIDER="" MODEL="" KEYVAR="" BASEURL="" OFFLINE=0
while (( $# )); do
  case "$1" in
    --provider) PROVIDER="$2"; shift 2 ;;
    --model)    MODEL="$2"; shift 2 ;;
    --key-var)  KEYVAR="$2"; shift 2 ;;
    --base-url) BASEURL="$2"; shift 2 ;;
    --offline)  OFFLINE=1; shift ;;
    *) echo "providers-verify: unknown arg $1" >&2; exit 2 ;;
  esac
done

# Overridable so a hermetic test can prove strategy 1 is unavailable instead of
# depending on whether this host happens to have built the submodule.
VERIFIER_BIN="${CMA_VERIFIER_BIN:-$LIB_DIR/../submodules/LLMsVerifier/bin/model-verification}"

emit() { echo "$1"; [[ -n "${2:-}" ]] && echo "providers-verify[$PROVIDER]: $2" >&2; }

# --- CA trust for a private / self-signed endpoint --------------------------
# A local backend commonly serves TLS with a self-signed certificate — HelixLLM
# on 127.0.0.1:8443 does — and curl then refuses the connection with exit 60
# while `-w '%{http_code}'` still prints 000. In the HTTP code ALONE that is
# indistinguishable from "nothing is listening", so a live endpoint looks dead
# when it is merely untrusted. CMA_PROVIDER_CA_CERT names the CA/cert PEM this
# probe should trust. There is deliberately NO default (CONST-045): a
# certificate path is a property of the host, not of the toolkit. curl's own
# CURL_CA_BUNDLE keeps working alongside it — curl reads that variable itself.
#
# The path travels in the --config stdin rather than on argv, for the same
# reason the key does: argv is world-readable through /proc/<pid>/cmdline.
CA_CERT="${CMA_PROVIDER_CA_CERT:-}"

# _cma_pv_is_loopback URL — true when URL's host is a loopback/unspecified
# address AND the URL carries an explicit port.
#
# It defines no new host parser. It calls the SHARED _cma_is_ccr_gateway
# (sourced from lib.sh above), passing URL's OWN port as the port-to-match,
# which collapses that function to exactly its host test — the one place in
# this codebase that knows every spelling of loopback (all of 127/8, 0.0.0.0,
# `localhost` in any case, IPv6 loopback in every zero-compression, tolerating
# userinfo/path/query/fragment). Misreading the port can only make this return
# FALSE, because the host test is what decides and it never admits a
# non-loopback host; a parse slip therefore degrades to "no probe" — the
# pre-existing behaviour — and can never probe a remote endpoint keyless.
_cma_pv_is_loopback() {
  local url="${1:-}" hp port host
  [[ -n "$url" ]] || return 1
  hp="${url#*://}"; hp="${hp%%/*}"; hp="${hp%%\?*}"; hp="${hp%%#*}"; hp="${hp##*@}"
  case "$hp" in
    \[*\]:*) port="${hp##*]:}" ;;
    *:*)     port="${hp##*:}" ;;
    *)       return 1 ;;
  esac
  _cma_is_ccr_gateway "$url" "$port" || return 1
  # The shared test's PURE-IPv6 branch is deliberately loose: it squashes
  # colons and zeros and accepts a remainder of "" or "1", so [1::], [10::],
  # [1000::], [100::] and [::1:0] all pass it. For the ccr-gateway guard that
  # looseness is harmless — it only ever makes the guard REFUSE to grade
  # something. Here the same verdict decides whether a KEYLESS probe may be
  # sent, and every one of those addresses is REMOTE, so the looseness would
  # be a hole. An IPv6 literal therefore has to clear a strict check too.
  case "$hp" in
    \[*\]:*)
      host="${hp%]:*}"; host="${host#[}"
      _cma_pv_ipv6_is_loopback "$host" || return 1 ;;
  esac
  return 0
}

# _cma_pv_ipv6_is_loopback ADDR — true only for a genuine IPv6 loopback (::1)
# or unspecified (::) address, in any zero-compression.
#
# It expands ADDR to its full eight groups and requires the first seven to be
# zero and the last to be 0 or 1. A v4-mapped/compatible form (it contains a
# dot) is left to the shared test's own IPv4 branch, which already grades the
# embedded quad; returning true here just means "no IPv6-specific objection".
_cma_pv_ipv6_is_loopback() {
  local a="${1:-}" pre post i g last
  case "$a" in *.*) return 0 ;; esac
  case "$a" in *[!0-9a-fA-F:]*) return 1 ;; esac
  local -a HEAD=() TAIL=() FULL=()
  if [[ "$a" == *::* ]]; then
    pre="${a%%::*}"; post="${a##*::}"
    # A second "::" is illegal; the split above would silently accept it.
    [[ "${a//::/}" == *::* ]] && return 1
  else
    pre="$a"; post=""
  fi
  local IFS=':'
  read -r -a HEAD <<< "$pre"
  read -r -a TAIL <<< "$post"
  unset IFS
  for g in ${HEAD[@]+"${HEAD[@]}"}; do [[ -n "$g" ]] && FULL+=("$g"); done
  local nhead=${#FULL[@]} ntail=0
  local -a T=()
  for g in ${TAIL[@]+"${TAIL[@]}"}; do [[ -n "$g" ]] && T+=("$g"); done
  ntail=${#T[@]}
  local fill=$(( 8 - nhead - ntail ))
  if [[ "$a" == *::* ]]; then
    (( fill < 1 )) && return 1
  else
    (( fill != 0 )) && return 1
  fi
  for ((i=0;i<fill;i++)); do FULL+=("0"); done
  for g in ${T[@]+"${T[@]}"}; do FULL+=("$g"); done
  (( ${#FULL[@]} == 8 )) || return 1
  for ((i=0;i<7;i++)); do
    g="${FULL[i]}"
    (( ${#g} <= 4 )) || return 1
    (( 16#${g:-0} == 0 )) || return 1
  done
  last="${FULL[7]}"
  (( ${#last} <= 4 )) || return 1
  last=$(( 16#${last:-0} ))
  (( last == 0 || last == 1 ))
}

# _cma_pv_curl_diag RC URL — one sentence explaining a curl exit code.
#
# HTTP 000 is curl saying "I never got a reply", and it covers outcomes whose
# fixes have nothing in common: nothing listening, the wrong scheme, an
# untrusted certificate, a timeout, a DNS miss. Reporting only "HTTP 000"
# conflates all of them, so the operator cannot tell a WRONG endpoint from a
# REACHABLE one that refused the handshake. curl's exit code does distinguish
# them, so the exit code is what gets reported.
_cma_pv_curl_diag() {
  case "${1:-0}" in
    0)  printf 'curl completed the request, so this code came from the endpoint itself' ;;
    6)  printf 'DNS — the host in %s could not be resolved' "$2" ;;
    7)  printf 'CONNECTION REFUSED — nothing is listening at %s; the endpoint is wrong, or the backend is not running' "$2" ;;
    28) printf 'TIMEOUT — %s did not answer within the probe window' "$2" ;;
    35|53|54|58|59|60|77|83|91)
        printf 'TLS — %s IS reachable, but the connection was refused at the TLS layer, which is exactly what an untrusted (e.g. self-signed) certificate does. Point CMA_PROVIDER_CA_CERT at the CA/cert PEM so the probe can trust it' "$2" ;;
    52) printf 'EMPTY REPLY — %s accepted the connection, then closed it without answering' "$2" ;;
    56) printf 'CONNECTION RESET while reading the reply from %s' "$2" ;;
    *)  printf 'curl exited %s against %s' "$1" "$2" ;;
  esac
}

# --- Gate 0: a base_url that IS the ccr gateway is not verifiable -----------
# Every probe below targets $BASEURL. When that URL is the local ccr gateway,
# the answer comes from whatever provider ccr's .Router.default currently names
# — NOT from the provider under test. That is how `helixagent` (base_url
# http://127.0.0.1:3456/v1, no `helixagent` provider in ccr's config at all)
# collected a `verified` badge for a turn served by `deepseek`. A sentinel that
# some OTHER backend echoed proves nothing about this alias, so refuse to grade
# it rather than record an unattributable pass. cma_run_provider (lib.sh)
# refuses to launch the same shape for the same reason.
#
# The test itself is _cma_is_ccr_gateway, sourced from lib.sh above — NOT a
# copy. What stood here was a `case` listing four literal spellings, duplicated
# from lib.sh's launch gate, and the two copies had already drifted: neither
# matched `127.0.1.1:3456` (Debian's default loopback for the local hostname,
# i.e. the gateway on a stock install), any other 127/8 address, the v4-mapped
# or fully-expanded IPv6 loopbacks, `LOCALHOST`, or a `user@`/`?query`/`#frag`
# spelling. One definition, three call sites, no drift.
if _cma_is_ccr_gateway "$BASEURL"; then
  emit failed "base_url ($BASEURL) is the ccr gateway itself — any probe is answered by whichever provider ccr routes to, so no verdict is attributable to this alias. Repoint it at its real backing endpoint."
  exit 1
fi

# --- Strategy 1: LLMsVerifier binary ---------------------------------------
if [[ -x "$VERIFIER_BIN" ]]; then
  out="$("$VERIFIER_BIN" --provider "$PROVIDER" --model "$MODEL" --verbose 2>&1)"
  if grep -q 'Status: verified' <<<"$out" && grep -q 'Can See Code: true' <<<"$out"; then
    emit verified "LLMsVerifier confirmed model + code visibility"; exit 0
  fi
  emit failed "LLMsVerifier did not confirm (see its output)"; exit 1
fi

# --- Strategy 2: live chat + tool-calling probes -----------------------------
# The credential gate is "a key IS set, OR the endpoint is loopback".
#
# WHY LOOPBACK IS EXEMPT. A key was previously mandatory, and for a remote
# provider it must stay so: probing a cloud endpoint without one buys a
# guaranteed 401 that says nothing about the model. But a LOCAL backend on
# 127.0.0.1 commonly authenticates nothing — HelixAgent's /v1/models answers
# 200 unauthenticated on this host — so requiring a key there did not protect
# anything; it just skipped the probe entirely and fell through to strategy 3,
# whose verdict ("unverified, no probe possible") is identical whether the
# endpoint is perfect or pointed at a dead port. That is the conflation this
# change exists to remove: on loopback the probe now RUNS and the verdict
# reports what the endpoint actually did.
#
# The gate is exactly as tight as before for everything non-loopback, and
# _cma_pv_is_loopback fails closed (see its comment). When no key is present
# the Authorization/x-api-key header is OMITTED rather than sent empty — an
# empty bearer is a malformed credential, and a 401 for it would be the
# probe's own fault.
# An EMPTY --key-var is reachable (a keyless local record may carry key_var
# ""), and `${!KEYVAR}` on an empty name is a hard "invalid variable name"
# error that kills the script before it prints any verdict word — the caller
# then maps empty stdout to 'unverified' with no reason at all. Guard the
# indirection instead of trusting the name to be non-empty.
key=""
[[ -n "$KEYVAR" ]] && key="${!KEYVAR:-}"
have_key=0; [[ -n "$key" ]] && have_key=1
if (( ! OFFLINE )) && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
   && [[ -n "$BASEURL" ]] && { (( have_key )) || _cma_pv_is_loopback "$BASEURL"; }; then
  # Build the probe URL to match the URL the runtime actually calls.
  # An /anthropic segment in the ORIGINAL base selects the Anthropic
  # request/response shape — and the segment is KEPT, because native endpoints
  # (e.g. https://api.deepseek.com/anthropic) serve /v1/messages UNDER that
  # prefix, not at the host root. For the OpenAI shape: a base that already
  # ends in a version segment (/v1, /v4, …) takes only /chat/completions
  # (e.g. https://api.z.ai/api/coding/paas/v4 -> …/paas/v4/chat/completions);
  # anything else gets the standard /v1/chat/completions.
  base="${BASEURL%/}"
  anthropic=0
  case "$base" in */anthropic*) anthropic=1 ;; esac
  base="${base%/chat/completions}"

  # Pass the API key via --config (a process-substituted fd), never via -H on
  # the command line, so the secret is not exposed in ps/argv. printf is a
  # shell builtin, so the key never appears as a process argument either. The
  # substitution must run per probe: each pipe drains after one read.
  # cfg_extra holds curl-config lines that are NOT the secret: the constant
  # Anthropic version header, and the CA cert when one is configured. It is
  # written into the SAME --config stdin so nothing new reaches argv. Splitting
  # anthropic-version out of auth_fmt is what lets the credential header be
  # omitted on a keyless loopback probe without also losing the version header.
  cfg_extra=""
  if (( anthropic )); then
    base="${base%/v1/messages}"
    base="${base%/v1}"
    url="$base/v1/messages"
    auth_fmt='header = "x-api-key: %s"\n'
    cfg_extra='header = "anthropic-version: 2023-06-01"'$'\n'
    tools_json='[{"name":"get_weather","description":"Get weather","input_schema":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}]'
  else
    base="${base%/coding}"
    base="${base%/v1}"
    case "$base" in
      */chat/completions) url="$base" ;;
      *)
        if [[ "$base" =~ /v[0-9]+$ ]]; then url="$base/chat/completions"
        else url="$base/v1/chat/completions"; fi ;;
    esac
    auth_fmt='header = "Authorization: Bearer %s"\n'
    tools_json='[{"type":"function","function":{"name":"get_weather","description":"Get weather","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}]'
  fi

  # A configured CA cert joins the config only when it is actually usable, and
  # an unusable one is REPORTED rather than silently ignored — a typo'd path
  # would otherwise present as a bare TLS failure the operator has no way to
  # attribute. `"` and newline are rejected because curl's config parser reads
  # a double-quoted value, so either character would break out of it.
  if [[ -n "$CA_CERT" ]]; then
    if [[ "$CA_CERT" == *'"'* || "$CA_CERT" == *\\* || "$CA_CERT" == *$'\n'* ]]; then
      echo "providers-verify[$PROVIDER]: CMA_PROVIDER_CA_CERT contains a quote, backslash or newline — curl's config parser reads backslash escapes inside a quoted value, so any of the three could break out of it; refusing to build a config from this path and probing without it" >&2
    elif [[ ! -r "$CA_CERT" ]]; then
      echo "providers-verify[$PROVIDER]: CMA_PROVIDER_CA_CERT=$CA_CERT is not readable — probing without it (a self-signed endpoint will fail at TLS)" >&2
    else
      cfg_extra+='cacert = "'"$CA_CERT"'"'$'\n'
    fi
  fi

  resp="$(mktemp "${TMPDIR:-/tmp}/cma-verify.XXXXXX")"
  # curl's EXIT code, which -w '%{http_code}' cannot express: every transport
  # failure prints 000, so the code alone cannot separate "refused" from
  # "untrusted certificate" from "timed out". chat_probe runs in a command
  # substitution (a subshell), so a variable could not carry the code back to
  # the grader — a file can.
  rcf="$(mktemp "${TMPDIR:-/tmp}/cma-verify-rc.XXXXXX")"
  trap 'rm -f "$resp" "$rcf"' EXIT

  # chat_probe BODY — prints the HTTP code (000 on transport error, which curl
  # already emits via -w), leaves the response body in $resp, and curl's own
  # exit code in $rcf.
  chat_probe() {
    local out rc=0
    # shellcheck disable=SC2059  # auth_fmt is a fixed per-shape template chosen above, not user input
    out="$(curl -4 -s -o "$resp" -w '%{http_code}' --max-time 15 \
      -H 'Content-Type: application/json' \
      --config <( { (( have_key )) && printf "$auth_fmt" "$key"; printf '%s' "$cfg_extra"; } ) \
      -d "$1" "$url" 2>/dev/null)" || rc=$?
    printf '%s' "$rc" > "$rcf"
    printf '%s' "$out"
  }

  # backend_says — the endpoint's OWN error text, trimmed for one log line.
  # Quoting it is what turns "HTTP 503" into an actionable report: HelixAgent's
  # 503 body, for instance, says "no provider in the chain was able to handle
  # the request", which is a backend condition and not a wrong endpoint.
  backend_says() {
    jq -r '(.error.message? // .error? // .message? // .detail? // empty) | tostring' "$resp" 2>/dev/null \
      | tr '\n\t' '  ' | tr -cd '[:print:]' | cut -c1-240
  }

  # max_tokens 512, not 128: reasoning models (k3, deepseek-v4-pro) spend a
  # large budget on chain-of-thought before any visible text; 128 reliably
  # produced false "empty content / sentinel missing" failures on them.
  chat_body="$(jq -nc --arg m "$MODEL" \
    '{model:$m,max_tokens:512,messages:[{role:"user",content:"Reply with exactly: VERIFY_OK"}]}')"
  tools_body="$(jq -nc --arg m "$MODEL" --argjson t "$tools_json" \
    '{model:$m,max_tokens:512,messages:[{role:"user",content:"What is the weather in Paris? Use the tool."}],tools:$t}')"

  # Retry policy: auth/billing codes (401/402/403) are deterministic — never
  # retried. Other definitive-looking outcomes DO flap: 400/404/412/000 on
  # load-balanced gateways, and a 200 with a missing sentinel or missing tool
  # call on weak models (instruction-following is non-deterministic — the same
  # model can pass and fail minutes apart). Each gets exactly ONE retry; the
  # second result decides. Consistent bluffs fail both attempts, so the
  # anti-bluff guarantee is preserved.
  retry_if_flappy() {  # $1=code $2=body -> prints the (possibly retried) code
    case "$1" in
      400|404|412|000)
        sleep 3
        chat_probe "$2" ;;
      *) printf '%s' "$1" ;;
    esac
  }

  # Extract the text content of a chat response ($resp): OpenAI shape
  # (choices[0].message.content) or Anthropic (text blocks in content[]).
  # Invalid JSON extracts as empty and fails downstream checks.
  extract_content() {
    jq -r 'if ((.choices // []) | length) > 0
             then .choices[0].message.content // ""
             else ([.content[]? | select(.type == "text") | .text] | join(""))
             end' "$resp" 2>/dev/null
  }
  has_tool_call() {
    jq -e '((.choices[0].message.tool_calls // []) | length) > 0
           or (.choices[0].message.function_call != null)
           or (([.content[]? | select(.type == "tool_use")] | length) > 0)' \
      "$resp" >/dev/null 2>&1
  }

  # Probe 1: the sentinel. A 200 without VERIFY_OK (or with an error object
  # smuggled into the body) is a bluff — the endpoint answered *something*,
  # not the requested model — and that is a definitive failure, not transient.
  # Weak models flake on instruction-following, so a missing sentinel gets ONE
  # retry (see retry policy above); consistent bluffs fail both attempts.
  attempt=0
  while :; do
    attempt=$((attempt+1))
    code="$(chat_probe "$chat_body")"
    code="$(retry_if_flappy "$code" "$chat_body")"
    case "$code" in
      200)
        if jq -e '.error' "$resp" >/dev/null 2>&1; then
          emit failed "chat probe returned HTTP 200 with an error body at $url"; exit 1
        fi
        content="$(extract_content)"
        case "$content" in
          *VERIFY_OK*) break ;;  # sentinel confirmed -> probe 2
          *)
            if (( attempt < 2 )); then sleep 3; continue; fi
            emit failed "chat probe 200 but VERIFY_OK sentinel missing at $url on both attempts (bluff or non-functional model)"; exit 1 ;;
        esac ;;
      400|401|402|403|404|412)
        # A 400 whose body says the request overflowed the model's OWN context
        # window is a DISTINCT, provider-side backend-size condition — not an
        # auth/billing/model-missing rejection. The operator's fix is to relaunch
        # the backing server with a larger context (as account-dead's fix is to
        # add funds), so name it honestly and point them at the right lever rather
        # than sending them to top up a balance or hunt a missing model. The
        # verdict is UNCHANGED — still `failed`/exit 1, and the live gate leaves it
        # uncounted via status either way — so this only affects the reason text;
        # the numbers come from the backend's OWN 400, never a declared/pinned
        # context. (Only reachable if a backend is so small the ~512-token probe
        # itself overflows; the large layer-4 request is classified separately in
        # verify_providers_live.sh.)
        if [[ "$code" == 400 ]] && grep -qiE 'exceeds the available context size|maximum context length|context (window|length) .*(exceed|too )' "$resp" 2>/dev/null; then
          ov="$(grep -oiE 'request \([0-9]+ tokens\) exceeds the available context size \([0-9]+ tokens\)' "$resp" | head -n1)"
          emit failed "context-inadequate: the model's context window is smaller than even the verification probe at $url (backend 400: ${ov:-context overflow}) — relaunch the backing server with a larger context"; exit 1
        fi
        emit failed "chat probe HTTP $code at $url (auth/billing/model-missing/account-suspended is definitive)"; exit 1 ;;
      5??)
        # REACHABLE BUT UNABLE — a distinct condition from an unreachable
        # endpoint, and previously reported with the same words. A 5xx means
        # the URL is right, the service is up, and the request still could not
        # be served (no upstream provider available, model not loaded,
        # overload). The verdict stays 'unverified' — the alias is honestly
        # not proven — but the operator is now pointed at the backend instead
        # of at the endpoint configuration.
        _bs="$(backend_says)"
        emit unverified "REACHABLE BUT UNABLE: $url answered HTTP $code, so the endpoint is correct and the service is up — it could not serve the request${_bs:+ (backend says: $_bs)}. Fix the backend (upstream/model availability), not the base_url."
        exit 2 ;;
      *)
        _crc="$(cat "$rcf" 2>/dev/null || true)"
        emit unverified "chat probe inconclusive (HTTP $code at $url) — $(_cma_pv_curl_diag "${_crc:-0}" "$url")"; exit 2 ;;
    esac
  done

  # Probe 2: tool calling. A tool call shows up as tool_calls / function_call
  # (OpenAI) or a tool_use content block (Anthropic). A 200 without one means
  # no tool support — a failure, since Claude Code cannot drive the model.
  # Models non-deterministically skip tool calls, so a missing call gets ONE
  # retry before the failure is declared (see retry policy above).
  attempt=0
  while :; do
    attempt=$((attempt+1))
    code="$(chat_probe "$tools_body")"
    code="$(retry_if_flappy "$code" "$tools_body")"
    case "$code" in
      200)
        if has_tool_call; then
          emit verified "chat + tool-calling probes passed at $url"; exit 0
        fi
        if (( attempt < 2 )); then sleep 3; continue; fi
        emit failed "chat probe passed but the model made no tool call at $url on both attempts (tool calling is required by Claude Code)"; exit 1 ;;
      429)
        emit unverified "chat probe passed but tool probe rate-limited (HTTP 429 at $url)"; exit 2 ;;
      4??)
        emit failed "tool-calling probe rejected (HTTP $code at $url)"; exit 1 ;;
      5??)
        _bs="$(backend_says)"
        emit unverified "chat probe passed, then $url answered HTTP $code to the tool-calling probe — reachable and up, but unable to serve it${_bs:+ (backend says: $_bs)}"; exit 2 ;;
      *)
        _crc="$(cat "$rcf" 2>/dev/null || true)"
        emit unverified "chat probe passed but tool probe inconclusive (HTTP $code at $url) — $(_cma_pv_curl_diag "${_crc:-0}" "$url")"; exit 2 ;;
    esac
  done
fi

# --- Strategy 3: cannot verify here ----------------------------------------
# Name the precondition that is ACTUALLY missing. "no probe possible" sent
# operators off to build a submodule when the real blocker was an unset key
# var or a record carrying no base_url — and, worse, it read exactly like a
# probe that had run and come back empty. A verdict that cannot say whether
# anything was even attempted is the same class of conflation as an HTTP 000
# that cannot say whether anything was listening.
_why=""
if (( OFFLINE )); then
  _why="--offline was requested, so no network probe was attempted"
elif ! command -v curl >/dev/null 2>&1; then
  _why="curl is not installed, so no probe could be issued"
elif ! command -v jq >/dev/null 2>&1; then
  _why="jq is not installed, so a probe response could not be graded"
elif [[ -z "$BASEURL" ]]; then
  _why="this provider record carries no base_url, so there is nothing to probe"
elif [[ -z "$key" ]]; then
  _why="\$$KEYVAR is not set and $BASEURL is not a loopback address with an explicit port, so the probe had no credential to present (a loopback backend that needs no auth is probed without one; a remote endpoint needs \$$KEYVAR set)"
else
  _why="no probe strategy applied"
fi
emit unverified "not verified — $_why. Layer 1 is unavailable too: no LLMsVerifier binary at $VERIFIER_BIN (build submodules/LLMsVerifier for full verification)."
exit 2
