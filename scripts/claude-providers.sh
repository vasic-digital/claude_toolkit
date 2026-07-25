#!/usr/bin/env bash
# claude-providers.sh — create/refresh/list/remove Claude Code aliases for
# non-Anthropic LLM providers, fully dynamically.
#
# Pipeline (sync): read the API-key VARIABLE NAMES from the keys file, fetch +
# cache the models.dev catalog, resolve each LLM key into a concrete provider
# record (provider id, alias, base URL, transport, strong/fast model) via
# providers_resolve.py, optionally verify with LLMsVerifier, then generate for
# each provider: a non-secret env file, a shell alias (cma_run_provider <id>),
# a config dir (~/.claude-prov-<id>) linking all shared items (so every plugin
# is available), and the always-on plugin set. Idempotent + re-runnable.
#
# Subcommands:
#   sync   (default)  discover + create/refresh all provider aliases
#   list              show installed provider aliases + model overrides
#   show <id>         detail for one provider
#   remove <id>       remove a provider alias + config dir
#   add  --from-key VAR [--id ID]   register a key→provider mapping, then sync
#
# Nothing about providers/models is hardcoded — everything derives from
# models.dev + the editable providers/key-aliases.json and overrides.json.
set -euo pipefail

_cma_src="${BASH_SOURCE[0]}"
while [ -L "$_cma_src" ]; do
  _cma_tgt="$(readlink "$_cma_src")"
  case "$_cma_tgt" in /*) _cma_src="$_cma_tgt" ;; *) _cma_src="$(dirname "$_cma_src")/$_cma_tgt" ;; esac
done
LIB_DIR="$(cd "$(dirname "$_cma_src")" && pwd)"
unset _cma_src _cma_tgt
# shellcheck source=lib.sh
source "$LIB_DIR/lib.sh"

# --- knobs ------------------------------------------------------------------
: "${CMA_KEYS_FILE:=$HOME/api_keys.sh}"
: "${CMA_MODELS_DEV_URL:=https://models.dev/api.json}"
: "${CMA_MODELS_DEV_TTL:=86400}"        # cache lifetime in seconds (24h)
: "${CMA_PROVIDER_DIR_PREFIX:=${ACCOUNT_PREFIX}prov-}"
# Always-on plugins (keys as they appear in settings.json enabledPlugins).
: "${CMA_ALWAYS_ON_PLUGINS:=superpowers@anthropics systematic-debugging@anthropics frontend-design@anthropics code-review@anthropics}"

RESOLVER="$LIB_DIR/providers_resolve.py"
VERIFY="${CMA_PROVIDERS_VERIFY:-$LIB_DIR/providers-verify.sh}"
SEMANTIC="${CMA_PROVIDERS_SEMANTIC:-$LIB_DIR/providers-semantic.sh}"
MODEL_VERIFY="$LIB_DIR/model_verify.py"
PROVIDERS_GENERATE="$LIB_DIR/providers_generate.py"
KEY_ALIASES="$LIB_DIR/providers/key-aliases.json"
OVERRIDES="$LIB_DIR/providers/overrides.json"
CACHE="$(cma_providers_dir)/models.dev.cache.json"
VERIFIED_CACHE="$(cma_providers_dir)/verification_cache.json"

# ATM-860 (operator decision D14, 2026-07-23): the per-model multi-alias
# pipeline runs as part of the DEFAULT sync, restricted to FREE-tier models
# (models.dev cost 0/0, `:free` ids, self-hosted local endpoints). Paid /
# unknown-tier models are NEVER sent a completion by default — probing them
# requires the explicit opt-in --include-paid (or CMA_SYNC_INCLUDE_PAID=1).
# CMA_SYNC_MULTI=0 disables the default multi phase entirely (legacy shape).
: "${CMA_SYNC_MULTI:=1}"
: "${CMA_SYNC_INCLUDE_PAID:=0}"

# shellcheck disable=SC2034  # ASSUME_YES reserved for --yes prompt suppression (not yet wired into cmds)
NO_VERIFY=0 OFFLINE=0 DRY_RUN=0 ASSUME_YES=0 MULTI=0
REFRESH_ALIASES=0 QUIET=0 PRUNE_UNRESOLVED=0
INCLUDE_PAID="$CMA_SYNC_INCLUDE_PAID"
MAX_ALIASES=5 MIN_SCORE=25 VERIFY_CONCURRENCY=5

usage() {
  cat <<EOF
Usage: claude-providers [SUBCOMMAND] [options]

Subcommands:
  sync [<id>]          (default) discover + create/refresh all provider aliases,
                       or just the named provider if <id> is given.
                       Then verify FREE-tier models per provider and create
                       per-model aliases (paid models are NEVER probed by
                       default — see --include-paid; CMA_SYNC_MULTI=0 skips
                       the per-model phase).  When a provider <id> is given
                       only the base alias is synced (the per-model phase
                       is not run).
  sync --multi         run ONLY the per-model multi-alias phase (free-tier
                       by default; add --include-paid to probe paid models)
  list                 list only VALIDATED + VERIFIED provider aliases
  list-all             list every installed provider alias (any status)
  list-faulty          list only aliases with an issue (failed/unverified/pending)
  show <id>            show details for one provider
  verify <id> [--deep] re-run verification for one provider + persist status
                       (layers 1-3; --deep also runs the live superpowers-TUI layer 4)
  remove <id>          remove a provider alias + its config dir (backed up)
  prune [--dry-run] [--unresolved]
                       report (or, unless --dry-run, remove) orphaned providers.
                       Two distinct classes are detected and reported separately:
                         status-only  — a status.json record with no backing
                                        *.env file. Always pure dead weight
                                        (invisible to list/list-all/remove);
                                        removed unconditionally, even without
                                        --unresolved.
                         unresolved   — a *.env-backed provider whose id no
                                        longer resolves against the current
                                        catalog/keys (its key may just be
                                        temporarily missing). Reported but
                                        NOT removed unless --unresolved is
                                        also passed.
  add --from-key VAR [--id PROVIDER]   register a key->provider mapping then sync

Options:
  --keys-file PATH     keys file to read var names from (default: \$CMA_KEYS_FILE or ~/api_keys.sh)
  --no-verify          skip LLMsVerifier/HTTP verification (aliases still created)
  --offline            do not fetch models.dev; require the local cache
  --dry-run            print what would change; write nothing
  --unresolved         with prune: also remove UNRESOLVED orphans (has a
                       *.env but no longer resolves) — without this flag,
                       prune only ever auto-removes status-only orphans
  --multi              with sync: run ONLY the per-model multi-alias phase
  --include-paid       ALSO fire verification completions at paid/unknown-tier
                       models (spends real money; default is free-tier only —
                       operator decision D14). Env: CMA_SYNC_INCLUDE_PAID=1
  --max-aliases N      max aliases per provider (default: 5)
  --min-score N        minimum verification score (default: 25)
  --verify-concurrency N  concurrent model verifications (default: 5)
  -y, --yes            assume yes to prompts
  -h, --help           this help
EOF
}

# --- models.dev catalog: fetch + cache, graceful degrade --------------------
ensure_catalog() {
  mkdir -p "$(dirname "$CACHE")"
  local fresh=0
  if [[ -s "$CACHE" ]] && _catalog_valid "$CACHE"; then
    local age now mtime
    now="$(date +%s)"
    # Platform-specific stat: macOS uses -f %m, Linux uses -c %Y.
    # The old `||` chain broke on Linux because `stat -f` succeeds there too
    # (returning filesystem info, not mtime), so both outputs merged.
    case "$(uname -s)" in
      Darwin*) mtime="$(stat -f %m "$CACHE" 2>/dev/null || echo 0)" ;;
      *)       mtime="$(stat -c %Y "$CACHE" 2>/dev/null || echo 0)" ;;
    esac
    age=$(( now - mtime ))
    (( age < CMA_MODELS_DEV_TTL )) && fresh=1
  fi
  if (( OFFLINE )); then
    # shellcheck disable=SC2015  # C (cma_die) is desired when A&&B fails: die if cache absent/invalid
    [[ -s "$CACHE" ]] && _catalog_valid "$CACHE" \
      || cma_die "offline and no valid models.dev cache at $CACHE — run once online first"
    cma_warn "offline: using cached catalog ($CACHE)"
    return 0
  fi
  if (( fresh )); then return 0; fi
  cma_require curl
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
  if curl -s --max-time 45 "$CMA_MODELS_DEV_URL" -o "$tmp" \
     && python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$tmp" 2>/dev/null; then
    mv "$tmp" "$CACHE"
    cma_log "refreshed models.dev catalog -> $CACHE ($(wc -c < "$CACHE") bytes)"
  else
    rm -f "$tmp"
    if [[ -s "$CACHE" ]]; then
      cma_warn "models.dev fetch failed; using stale cache ($CACHE)"
    else
      cma_die "models.dev fetch failed and no cache available"
    fi
  fi
}

# Extract API-key VARIABLE NAMES from the keys file WITHOUT executing it.
present_key_vars() {
  # -e (not -f): a process-substitution / FIFO keys file (e.g. --keys-file
  # <(...)) is a legitimate way to supply keys and is NOT a POSIX "regular
  # file" per -f, but it is a readable, existing path per -e.
  [[ -e "$CMA_KEYS_FILE" ]] || cma_die "keys file not found: $CMA_KEYS_FILE (pass --keys-file)"
  # -e accepts a FIFO/process-substitution but ALSO a directory; a directory would
  # slip past -e and then yield a silent "0 key vars" (grep on a dir). Die clearly.
  [[ -d "$CMA_KEYS_FILE" ]] && cma_die "keys file is a directory, not a file: $CMA_KEYS_FILE (pass a file with --keys-file)"
  # `|| true`: a keys file with no assignments must yield an empty list, not a
  # grep exit-1 that aborts the script under `set -e`/pipefail.
  local names
  names="$( { grep -oE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "$CMA_KEYS_FILE" || true; } \
    | sed -E 's/^[[:space:]]*(export[[:space:]]+)?//; s/=$//' \
    | sort -u )"
  # Keep only vars whose VALUE is non-empty. A declared-but-empty key
  # (e.g. `export SARVAM_API_KEY=`) must NOT spawn a provider alias — it would
  # only fail at launch with "$VAR is empty (set it in ...)". Source the keys
  # file in a subshell (it may `exit` at top level or carry set -u-hostile
  # refs) and print just the NAMES (never values) that resolve to a value.
  # shellcheck source=/dev/null  # $CMA_KEYS_FILE is the user's runtime keys file
  ( set +e; set -a +u; . "$CMA_KEYS_FILE" >/dev/null 2>&1; set +a
    while IFS= read -r _n; do
      [[ -z "$_n" ]] && continue
      eval "_v=\"\${$_n:-}\""
      [[ -n "$_v" ]] && printf '%s\n' "$_n"
    done <<< "$names"
  ) | sort -u
}

# Validate that the catalog cache is parseable JSON.
_catalog_valid() { python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$1" 2>/dev/null; }

# --- local HelixAgent PATH-detection (decoupled; providers_resolve.py stays pure)
# HelixAgent is a LOCAL binary with no cloud API key, so it never appears in the
# models.dev catalog and the env-key-name pipeline can't discover it. This
# detector gates on `command -v helixagent` (the PATH), enumerates the served
# models from the LIVE OpenAI-compatible `/v1/models` endpoint (single source of
# truth — no hardcoded model list, mirrors CONST-036), and emits ONE
# `resolved`-shaped JSON record that flows through the SAME
# cma_provider_write_env / cma_provider_write_alias / verification loop as every
# other provider (see cmd_sync). Everything is env-overridable (CMA_HELIXAGENT_*)
# so no host-specific path is baked in (CONST-045). Server-down is HONEST: the
# alias is still registered off the configured pins, and verification marks it
# 'unverified' rather than fabricate a live model list (§11.4.6).
#
# transport = router: HelixAgent's /v1 is OpenAI-compatible (NOT Anthropic-
# native), so the alias routes through ccr (claude-code-router) exactly like
# every other OpenAI-style provider. A future Anthropic-native HelixAgent
# endpoint can be promoted via CMA_HELIXAGENT_TRANSPORT=native.
detect_helixagent_record() {
  # Git-tracked facade pins (Variant B — §11.4.28 consumer-owned data): load the
  # HelixAgent/HelixLLM facade pins from providers/helixagent.json so the alias
  # is registered from TRACKED config (base_url -> the HelixLLM server 127.0.0.1:18434, strong/fast ->
  # HelixAgent/HelixLLM, key_var -> HELIXAGENT_GATEWAY_KEY, real ctx 24576) rather
  # than shell-rc-only env. Precedence: process-env > pins-file > built-in
  # defaults — a field is taken from the file ONLY when its env var is unset.
  # The pins-file path is env-overridable (CMA_HELIXAGENT_PINS_FILE) so hermetic
  # tests can point it at a sandbox/absent file and still exercise the built-in
  # defaults (the repo pins-file must not leak into a sandboxed test HOME).
  local _ha_json="${CMA_HELIXAGENT_PINS_FILE:-$LIB_DIR/providers/helixagent.json}"
  if [[ -f "$_ha_json" ]] && command -v jq >/dev/null 2>&1; then
    local _hk _hv
    while IFS=$'\t' read -r _hk _hv; do
      case "$_hk" in
        bin)           [[ -n "${CMA_HELIXAGENT_BIN+x}" ]]           || CMA_HELIXAGENT_BIN="$_hv" ;;
        id)            [[ -n "${CMA_HELIXAGENT_ID+x}" ]]            || CMA_HELIXAGENT_ID="$_hv" ;;
        base_url)      [[ -n "${CMA_HELIXAGENT_BASE_URL+x}" ]]      || CMA_HELIXAGENT_BASE_URL="$_hv" ;;
        transport)     [[ -n "${CMA_HELIXAGENT_TRANSPORT+x}" ]]     || CMA_HELIXAGENT_TRANSPORT="$_hv" ;;
        strong_model)  [[ -n "${CMA_HELIXAGENT_STRONG+x}" ]]        || CMA_HELIXAGENT_STRONG="$_hv" ;;
        fast_model)    [[ -n "${CMA_HELIXAGENT_FAST+x}" ]]          || CMA_HELIXAGENT_FAST="$_hv" ;;
        key_var)       [[ -n "${CMA_HELIXAGENT_KEYVAR+x}" ]]        || CMA_HELIXAGENT_KEYVAR="$_hv" ;;
        context_limit) [[ -n "${CMA_HELIXAGENT_CONTEXT_LIMIT+x}" ]] || CMA_HELIXAGENT_CONTEXT_LIMIT="$_hv" ;;
        max_output)    [[ -n "${CMA_HELIXAGENT_MAX_OUTPUT+x}" ]]    || CMA_HELIXAGENT_MAX_OUTPUT="$_hv" ;;
      esac
    done < <(jq -r 'to_entries[] | [.key, (.value|tostring)] | @tsv' "$_ha_json" 2>/dev/null)
  fi
  # PIN PROVENANCE (2026-07-23 live defect): record — BEFORE the built-in
  # defaults below make it undecidable — whether strong/fast were EXPLICITLY
  # pinned (process-env or pins-file, the two authoritative sources) or are
  # about to be filled from the built-in defaults. An explicit pin is a facade
  # contract (e.g. "HelixAgent/HelixLLM") that the live /v1/models listing must
  # NEVER overwrite: llama.cpp reports the loaded .gguf PATH as its model id,
  # so the old positional fallback (`head -n1`) replaced the pinned facade with
  # '/models/….gguf' whenever the endpoint was UP but did not list the facade
  # id — while base_url/key_var/context_limit (never live-derived) survived.
  # Built-in defaults stay data-driven: live enumeration keeps winning there.
  local _ha_strong_pinned=0 _ha_fast_pinned=0
  [[ -n "${CMA_HELIXAGENT_STRONG+x}" ]] && _ha_strong_pinned=1
  [[ -n "${CMA_HELIXAGENT_FAST+x}"   ]] && _ha_fast_pinned=1
  : "${CMA_HELIXAGENT_BIN:=helixagent}"
  : "${CMA_HELIXAGENT_ID:=helixagent}"
  : "${CMA_HELIXAGENT_HOST:=localhost}"
  : "${CMA_HELIXAGENT_PORT:=8100}"
  : "${CMA_HELIXAGENT_KEYVAR:=HELIXAGENT_API_KEY}"
  : "${CMA_HELIXAGENT_TRANSPORT:=router}"
  : "${CMA_HELIXAGENT_STRONG:=helix-debate}"
  : "${CMA_HELIXAGENT_FAST:=helix-llm}"
  : "${CMA_HELIXAGENT_CONTEXT_LIMIT:=128000}"
  : "${CMA_HELIXAGENT_MAX_OUTPUT:=8192}"
  local base="${CMA_HELIXAGENT_BASE_URL:-http://${CMA_HELIXAGENT_HOST}:${CMA_HELIXAGENT_PORT}/v1}"

  # PATH/pins gate: register the facade when EITHER the helixagent binary is on
  # PATH OR the git-tracked pins file exists (opt-in on tracked config -> no stub
  # binary needed for Variant B). Absent BOTH -> no record (honest; the whole
  # feature stays opt-in). $_ha_json is the same path resolved in the pins-load
  # block above (CMA_HELIXAGENT_PINS_FILE override honored).
  if ! command -v "$CMA_HELIXAGENT_BIN" >/dev/null 2>&1 && [[ ! -f "$_ha_json" ]]; then
    printf '[]\n'; return 0
  fi

  # Truthful reason string (§11.4.6/§11.4.201): the gate above admits EITHER a
  # PATH binary OR a pins-file; a literal "detected on PATH" would be a false
  # factual claim in the pins-only (Variant B) case where no binary exists.
  # Branch on which gate actually fired -- PATH takes precedence in wording
  # when both are present, matching the gate's own precedence.
  local _ha_reason="helixagent detected via pins-file"
  if command -v "$CMA_HELIXAGENT_BIN" >/dev/null 2>&1; then
    _ha_reason="helixagent detected on PATH"
  fi

  # Enumerate models from the live endpoint. The auth token (if any) is read by
  # NAME from the environment and passed via `curl --config -` (stdin), never on
  # argv (no secret leak, §11.4.10). During resolve the key-var is usually not
  # exported (present_key_vars sources the keys file only in a subshell), so an
  # unauthenticated /v1/models listing is the common path — acceptable + honest.
  local ids="" key=""
  key="${!CMA_HELIXAGENT_KEYVAR:-}"
  if command -v curl >/dev/null 2>&1; then
    local t="${CMA_HELIXAGENT_HTTP_TIMEOUT:-8}"
    if [[ -n "$key" ]]; then
      ids="$(printf 'header = "Authorization: Bearer %s"\n' "$key" \
             | curl -s --max-time "$t" --config - "${base%/}/models" 2>/dev/null \
             | jq -r '.data[].id? // empty' 2>/dev/null || true)"
    else
      ids="$(curl -s --max-time "$t" "${base%/}/models" 2>/dev/null \
             | jq -r '.data[].id? // empty' 2>/dev/null || true)"
    fi
  fi

  local strong="" fast=""
  if (( _ha_strong_pinned )); then
    # EXPLICITLY pinned (env or pins-file): the pin is the facade contract and
    # is AUTHORITATIVE. The live listing is still fetched above (verification /
    # reachability evidence) but must not overwrite the pin — the 2026-07-23
    # defect was exactly this overwrite ('HelixAgent/HelixLLM' replaced by the
    # endpoint-reported '/models/….gguf' path).
    strong="$CMA_HELIXAGENT_STRONG"
  elif [[ -n "$ids" ]]; then
    # Nothing pinned: data-driven selection from the LIVE id list — prefer the
    # built-in default id when the server serves it, else positional pick.
    if printf '%s\n' "$ids" | grep -qxF -- "$CMA_HELIXAGENT_STRONG"; then
      strong="$CMA_HELIXAGENT_STRONG"
    else
      strong="$(printf '%s\n' "$ids" | head -n1)"
    fi
  else
    strong="$CMA_HELIXAGENT_STRONG"
  fi
  if (( _ha_fast_pinned )); then
    fast="$CMA_HELIXAGENT_FAST"
  elif [[ -n "$ids" ]]; then
    if printf '%s\n' "$ids" | grep -qxF -- "$CMA_HELIXAGENT_FAST"; then
      fast="$CMA_HELIXAGENT_FAST"
    else
      fast="$(printf '%s\n' "$ids" | sed -n '2p')"
      [[ -z "$fast" ]] && fast="$strong"
    fi
  fi
  # Server unreachable / no models returned AND fast not pinned: honest
  # fallback to the configured value so the alias still exists (verification
  # will mark it 'unverified'). strong's own else-branch above already did the
  # same for the strong model.
  [[ -z "$fast" ]] && fast="$CMA_HELIXAGENT_FAST"

  # Emit ONE record with the exact schema providers_resolve.py produces.
  jq -cn \
    --arg key_var "$CMA_HELIXAGENT_KEYVAR" \
    --arg pid     "$CMA_HELIXAGENT_ID" \
    --arg alias   "$CMA_HELIXAGENT_ID" \
    --arg base    "$base" \
    --arg transport "$CMA_HELIXAGENT_TRANSPORT" \
    --arg strong  "$strong" \
    --arg fast    "$fast" \
    --arg reason  "$_ha_reason" \
    --argjson ctx "${CMA_HELIXAGENT_CONTEXT_LIMIT:-null}" \
    --argjson out "${CMA_HELIXAGENT_MAX_OUTPUT:-null}" \
    '[{key_var:$key_var, classification:"llm", provider_id:$pid, alias:$alias,
       base_url:$base, transport:$transport, strong_model:$strong,
       fast_model:$fast, context_limit:$ctx, max_output:$out,
        status:"resolved", reason:$reason}]'
}

# --- local HelixLLM PATH-detection (router + native transports) --------------
# HelixLLM Go binary serves an OpenAI-compatible /v1 (port 18435) for the
# cloud-fallback chain AND an Anthropic-compatible /v1/messages endpoint on the
# same host:port for the native transport. Both are registered as separate
# provider aliases so the operator can choose the CCR-routed chain OR the direct
# Anthropic-native path per session.
#
# helixllm-gateway: transport=router, base_url=http://127.0.0.1:18435/v1
# helixagent-native: transport=native, base_url=http://127.0.0.1:18435
# (Anthropic-compatible /v1/messages, bypasses CCR entirely)
#
# Pins are loaded from providers/helixllm-gateway.json and
# providers/helixagent-native.json respectively. Process-env vars prefixed
# CMA_HELIXLLM_GW_* / CMA_HELIXLLM_NATIVE_* override the pins, then fall
# back to built-in defaults. Both share the same upstream binary; two records
# are emitted so the sync pipeline creates two distinct aliases.
detect_helixllm_records() {
  local _ljson="${CMA_HELIXLLM_PINS_FILE:-$LIB_DIR/providers/helixllm-gateway.json}"
  local _njson="${CMA_HELIXLLM_NATIVE_PINS_FILE:-$LIB_DIR/providers/helixagent-native.json}"

  # --- helixllm-gateway pins ------------------------------------------------
  local _lgw_bin="" _lgw_id="" _lgw_base="" _lgw_transport="" _lgw_strong="" _lgw_fast="" _lgw_keyvar="" _lgw_ctx="" _lgw_out=""
  if [[ -f "$_ljson" ]] && command -v jq >/dev/null 2>&1; then
    local _k _v
    while IFS=$'\t' read -r _k _v; do
      case "$_k" in
        bin)           _lgw_bin="$_v" ;;
        id)            _lgw_id="$_v" ;;
        base_url)      _lgw_base="$_v" ;;
        transport)     _lgw_transport="$_v" ;;
        strong_model)  _lgw_strong="$_v" ;;
        fast_model)    _lgw_fast="$_v" ;;
        key_var)       _lgw_keyvar="$_v" ;;
        context_limit) _lgw_ctx="$_v" ;;
        max_output)    _lgw_out="$_v" ;;
      esac
    done < <(jq -r 'to_entries[] | [.key, (.value|tostring)] | @tsv' "$_ljson" 2>/dev/null)
  fi
  # Defaults (only used when the pins file is absent or a field is missing)
  : "${_lgw_bin:=helixllm}"
  : "${_lgw_id:=helixllm-gateway}"
  : "${_lgw_base:=http://127.0.0.1:18435/v1}"
  : "${_lgw_transport:=router}"
  : "${_lgw_strong:=helixllm-multi}"
  : "${_lgw_fast:=helixllm-multi}"
  : "${_lgw_keyvar:=HELIXLLM_GATEWAY_KEY}"
  : "${_lgw_ctx:=229376}"
  : "${_lgw_out:=8192}"

  # --- helixagent-native pins -----------------------------------------------
  local _lnat_bin="" _lnat_id="" _lnat_base="" _lnat_transport="" _lnat_strong="" _lnat_fast="" _lnat_keyvar="" _lnat_ctx="" _lnat_out=""
  if [[ -f "$_njson" ]] && command -v jq >/dev/null 2>&1; then
    local _k _v
    while IFS=$'\t' read -r _k _v; do
      case "$_k" in
        bin)           _lnat_bin="$_v" ;;
        id)            _lnat_id="$_v" ;;
        base_url)      _lnat_base="$_v" ;;
        transport)     _lnat_transport="$_v" ;;
        strong_model)  _lnat_strong="$_v" ;;
        fast_model)    _lnat_fast="$_v" ;;
        key_var)       _lnat_keyvar="$_v" ;;
        context_limit) _lnat_ctx="$_v" ;;
        max_output)    _lnat_out="$_v" ;;
      esac
    done < <(jq -r 'to_entries[] | [.key, (.value|tostring)] | @tsv' "$_njson" 2>/dev/null)
  fi
  : "${_lnat_bin:=helixllm}"
  : "${_lnat_id:=helixagent-native}"
  : "${_lnat_base:=http://127.0.0.1:18435}"
  : "${_lnat_transport:=native}"
  : "${_lnat_strong:=helixllm-multi}"
  : "${_lnat_fast:=helixllm-multi}"
  : "${_lnat_keyvar:=HELIXLLM_GATEWAY_KEY}"
  : "${_lnat_ctx:=229376}"
  : "${_lnat_out:=8192}"

  # Gate: register BOTH providers when EITHER the helixllm binary is on PATH
  # OR the pins files exist (opt-in via tracked config, Variant B).
  if ! command -v "$_lgw_bin" >/dev/null 2>&1 && [[ ! -f "$_ljson" ]] && [[ ! -f "$_njson" ]]; then
    printf '[]\n'; return 0
  fi

  local _l_reason="helixllm-gateway detected via pins-file"
  if command -v "$_lgw_bin" >/dev/null 2>&1; then
    _l_reason="helixllm-gateway detected on PATH"
  fi
  local _n_reason="helixagent-native detected via pins-file"
  if command -v "$_lnat_bin" >/dev/null 2>&1; then
    _n_reason="helixagent-native detected on PATH"
  fi

  # Emit TWO records — one for the CCR-routed gateway, one for the native path.
  jq -n \
    --arg gw_keyvar "$_lgw_keyvar" --arg gw_pid "$_lgw_id" --arg gw_alias "$_lgw_id" \
    --arg gw_base "$_lgw_base" --arg gw_transport "$_lgw_transport" \
    --arg gw_strong "$_lgw_strong" --arg gw_fast "$_lgw_fast" \
    --arg gw_reason "$_l_reason" \
    --argjson gw_ctx "${_lgw_ctx:-null}" --argjson gw_out "${_lgw_out:-null}" \
    --arg nat_keyvar "$_lnat_keyvar" --arg nat_pid "$_lnat_id" --arg nat_alias "$_lnat_id" \
    --arg nat_base "$_lnat_base" --arg nat_transport "$_lnat_transport" \
    --arg nat_strong "$_lnat_strong" --arg nat_fast "$_lnat_fast" \
    --arg nat_reason "$_n_reason" \
    --argjson nat_ctx "${_lnat_ctx:-null}" --argjson nat_out "${_lnat_out:-null}" \
    '[{key_var:$gw_keyvar, classification:"llm", provider_id:$gw_pid, alias:$gw_alias,
       base_url:$gw_base, transport:$gw_transport, strong_model:$gw_strong,
       fast_model:$gw_fast, context_limit:$gw_ctx, max_output:$gw_out,
       status:"resolved", reason:$gw_reason},
      {key_var:$nat_keyvar, classification:"llm", provider_id:$nat_pid, alias:$nat_alias,
       base_url:$nat_base, transport:$nat_transport, strong_model:$nat_strong,
       fast_model:$nat_fast, context_limit:$nat_ctx, max_output:$nat_out,
       status:"resolved", reason:$nat_reason}]'
}

# --- local Kimi Code OAuth PATH-detection -----------------------------------
# Kimi Code uses OAuth tokens (15-min expiry), not static API keys. The token
# lives in ~/.kimi-code/credentials/kimi-code.json. Gates on `command -v kimi`.
# The sentinel key_var _CMA_KIMICODE_OAUTH_ signals to both the verification
# path and the launch wrapper to read the token from the provider token file
# ($PROVIDER_DIR/kimi-for-coding.token). Token is refreshed at sync time.
detect_kimicode_record() {
  command -v kimi >/dev/null 2>&1 || { printf '[]\n'; return 0; }
  local cred_file="$HOME/.kimi-code/credentials/kimi-code.json"
  [[ -f "$cred_file" ]] || { printf '[]\n'; return 0; }

  # Token refresh: if expired, run kimi -p to trigger OAuth refresh.
  local now expires token
  now="$(date +%s)"
  expires="$(jq -r '.expires_at // 0' "$cred_file" 2>/dev/null || echo 0)"
  if (( expires <= now )); then
    timeout 20 kimi -p "hi" --output-format text >/dev/null 2>&1 || true
    expires="$(jq -r '.expires_at // 0' "$cred_file" 2>/dev/null || echo 0)"
  fi

  token="$(jq -r '.access_token // ""' "$cred_file" 2>/dev/null)"
  [[ -n "$token" ]] || { printf '[]\n'; return 0; }

  # Discover the models THIS subscription actually serves (never hardcode):
  # GET {base}/models with the OAuth token; fall back to the models.dev
  # catalog list when the endpoint can't be reached (offline sync still
  # yields the known aliases, which verification then gates honestly).
  local base="https://api.kimi.com/coding/v1"
  local models_json=""
  (( OFFLINE )) || models_json="$(curl -s --max-time 15 \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "$token") \
    "$base/models" 2>/dev/null | jq -c '[.data[]?.id] | unique' 2>/dev/null)"
  if [[ -z "$models_json" || "$models_json" == "[]" || "$models_json" == "null" ]]; then
    models_json="[]"
  fi
  # Union the discovery result with the catalog's known models for this
  # endpoint + the account-default id: /models is authoritative for what is
  # LISTED, but it under-reports (e.g. k2p7 answers chat/tools fine on the
  # subscription yet is absent from the listing). Anything the subscription
  # does not actually serve is filtered out by the strict sync-time probes.
  local catalog_models
  catalog_models="$(jq -c '."kimi-for-coding".models | keys' "$CACHE" 2>/dev/null || echo '[]')"
  models_json="$(jq -c --argjson a "$models_json" --argjson b "$catalog_models" \
    '$a + $b + ["kimi-for-coding"] | unique' <<<"{}")"

  # One token-file snapshot per alias (the launch path prefers the LIVE
  # credentials file; these are only the last-resort fallback).
  local tdir; tdir="$(cma_providers_dir)"; mkdir -p "$tdir"
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && ( umask 077; printf '%s' "$token" > "$tdir/$pid.token" ) || true
  done < <(jq -r '.[] | if . == "kimi-for-coding" then "kimi-for-coding"
                     elif startswith("kimi-") then . else "kimi-" + . end' <<<"$models_json")

  # Emit ONE record per served model. Alias naming: the account default keeps
  # 'kimi-for-coding'; ids already carrying the kimi- prefix keep it; bare ids
  # (k3, k2p7, ...) become kimi-<id>. Context/output limits come from the
  # models.dev catalog entry for the model, with the endpoint's documented
  # defaults (k3: 1M/131072; the K2.7 family: 262144/32768) as fallback.
  # NOTE: only the kimi-for-coding models subtree is passed to jq — the full
  # catalog is far too large for --argjson (ARG_MAX).
  local model_limits; model_limits="$(jq -c '."kimi-for-coding".models // {}' "$CACHE" 2>/dev/null || echo '{}')"
  jq -n --arg keyvar "_CMA_KIMICODE_OAUTH_" --arg base "$base" \
        --argjson models "$models_json" --argjson limits "$model_limits" '
    def limits($m): ($limits[$m].limit // {})
      | {ctx: (.context // (if $m == "k3" then 1048576 else 262144 end)),
         out: (.output  // (if $m == "k3" then 131072  else 32768  end))};
    def alias_for($m): if $m == "kimi-for-coding" then "kimi-for-coding"
                       elif ($m | startswith("kimi-")) then $m
                       else "kimi-" + $m end;
    $models[] | (limits(.) ) as $l | (alias_for(.)) as $a |
    {key_var:$keyvar, classification:"llm", provider_id:$a, alias:$a,
     base_url:$base, transport:"router", strong_model:., fast_model:.,
     context_limit:$l.ctx, max_output:$l.out, status:"resolved",
     reason:("kimi-code detected on PATH (OAuth subscription model: " + . + ")")}
  ' | jq -s '.'
}

# --- OpenCode Zen multi-alias detection (5 aliases from one API key) ----------
# OpenCode Zen serves 59 models via an OpenAI-compatible endpoint. One API key
# (ApiKey_Opencode_Zen) maps to the entire catalog. This detector emits 5
# provider records (opencode-zen1 through opencode-zen5), each with a distinct
# strong/fast model pair spanning different capability profiles (Claude family,
# GPT family, Gemini family, balanced reasoning, and best overall).
#
# Pins are loaded from providers/opencode-zen.json. Detection gates on the
# tracked pins file AND the Zen API key being present.
detect_opencode_zen_records() {
  local _z_json="${CMA_OPENCODE_ZEN_PINS_FILE:-$LIB_DIR/providers/opencode-zen.json}"
  [[ -f "$_z_json" ]] || { printf '[]\n'; return 0; }

  local _key_present=0
  if [[ -f "$CMA_KEYS_FILE" ]]; then
    local _key_val
    # shellcheck source=/dev/null
    _key_val="$( ( set +e; set -a +u; . "$CMA_KEYS_FILE" 2>/dev/null; set +a; printf '%s' "${ApiKey_Opencode_Zen:-}" ) )" || true
    [[ -n "$_key_val" ]] && _key_present=1
  fi
  (( _key_present )) || { printf '[]\n'; return 0; }

  local _z_bin="" _z_id="" _z_base="" _z_transport="" _z_strong="" _z_fast="" _z_keyvar="" _z_ctx="" _z_out=""
  if command -v jq >/dev/null 2>&1; then
    local _k _v
    while IFS=$'\t' read -r _k _v; do
      case "$_k" in
        bin)           _z_bin="$_v" ;;
        id)            _z_id="$_v" ;;
        base_url)      _z_base="$_v" ;;
        transport)     _z_transport="$_v" ;;
        strong_model)  _z_strong="$_v" ;;
        fast_model)    _z_fast="$_v" ;;
        key_var)       _z_keyvar="$_v" ;;
        context_limit) _z_ctx="$_v" ;;
        max_output)    _z_out="$_v" ;;
      esac
    done < <(jq -r 'to_entries[] | [.key, (.value|tostring)] | @tsv' "$_z_json" 2>/dev/null)
  fi

  : "${_z_id:=opencode-zen}"
  : "${_z_base:=https://opencode.ai/zen/v1}"
  : "${_z_transport:=router}"
  : "${_z_strong:=claude-fable-5}"
  : "${_z_fast:=deepseek-v4-flash}"
  : "${_z_keyvar:=ApiKey_Opencode_Zen}"
  : "${_z_ctx:=262144}"
  : "${_z_out:=32768}"

  local _reason="OpenCode Zen multi-alias detected via pins-file (59 models, OpenAI-compatible)"

  jq -n \
    --arg keyvar "$_z_keyvar" \
    --arg base    "$_z_base" \
    --arg transport "$_z_transport" \
    --arg reason  "$_reason" \
    --argjson ctx "${_z_ctx:-null}" \
    --argjson out "${_z_out:-null}" \
    '[
      {
        key_var:             $keyvar,
        classification:      "llm",
        provider_id:         "opencode-zen1",
        alias:               "opencode-zen1",
        base_url:            $base,
        transport:           $transport,
        strong_model:        "claude-fable-5",
        fast_model:          "deepseek-v4-flash",
        context_limit:       $ctx,
        max_output:          $out,
        status:              "resolved",
        reason:              ($reason + " (best-reasoning: Claude Fable 5 / DeepSeek V4 Flash)")
      },
      {
        key_var:             $keyvar,
        classification:      "llm",
        provider_id:         "opencode-zen2",
        alias:               "opencode-zen2",
        base_url:            $base,
        transport:           $transport,
        strong_model:        "claude-opus-5",
        fast_model:          "claude-haiku-4-5",
        context_limit:       $ctx,
        max_output:          $out,
        status:              "resolved",
        reason:              ($reason + " (claude-family: Claude Opus 5 / Claude Haiku 4.5)")
      },
      {
        key_var:             $keyvar,
        classification:      "llm",
        provider_id:         "opencode-zen3",
        alias:               "opencode-zen3",
        base_url:            $base,
        transport:           $transport,
        strong_model:        "claude-sonnet-5",
        fast_model:          "gemini-3.6-flash",
        context_limit:       $ctx,
        max_output:          $out,
        status:              "resolved",
        reason:              ($reason + " (balanced: Claude Sonnet 5 / Gemini 3.6 Flash)")
      },
      {
        key_var:             $keyvar,
        classification:      "llm",
        provider_id:         "opencode-zen4",
        alias:               "opencode-zen4",
        base_url:            $base,
        transport:           $transport,
        strong_model:        "gpt-5.4",
        fast_model:          "gpt-5.4-mini",
        context_limit:       $ctx,
        max_output:          $out,
        status:              "resolved",
        reason:              ($reason + " (gpt-family: GPT-5.4 / GPT-5.4 Mini)")
      },
      {
        key_var:             $keyvar,
        classification:      "llm",
        provider_id:         "opencode-zen5",
        alias:               "opencode-zen5",
        base_url:            $base,
        transport:           $transport,
        strong_model:        "gemini-3.1-pro",
        fast_model:          "gemini-3-flash",
        context_limit:       $ctx,
        max_output:          $out,
        status:              "resolved",
        reason:              ($reason + " (gemini-family: Gemini 3.1 Pro / Gemini 3 Flash)")
      }
    ]'
}

# --- OpenCode Go cloud-API detection -----------------------------------------
# OpenCode Go is a subscription tier on top of the same Zen API key. It uses a
# different base URL (https://opencode.ai/zen/go/v1) and serves a curated subset
# of models distinct from the full Zen catalog. Detection gates on the tracked
# pins file (providers/opencode-go.json) AND the Zen API key being present.
# The key var is the SAME as Zen (ApiKey_Opencode_Zen) — both tiers share one
# account key. Detector emits 5 records (opencode-go1 through opencode-go5)
# with distinct strong/fast model pairings.
#
# transport = router: the /zen/go/v1/chat/completions endpoint is OpenAI-compatible.
detect_opencode_go_records() {
  local _og_json="${CMA_OPENCODE_GO_PINS_FILE:-$LIB_DIR/providers/opencode-go.json}"
  [[ -f "$_og_json" ]] || { printf '[]\n'; return 0; }

  local _key_present=0
  if [[ -f "$CMA_KEYS_FILE" ]]; then
    local _key_val
    # shellcheck source=/dev/null
    _key_val="$( ( set +e; set -a +u; . "$CMA_KEYS_FILE" 2>/dev/null; set +a; printf '%s' "${ApiKey_Opencode_Zen:-}" ) )" || true
    [[ -n "$_key_val" ]] && _key_present=1
  fi
  (( _key_present )) || { printf '[]\n'; return 0; }

  local _og_bin="" _og_id="" _og_base="" _og_transport="" _og_strong="" _og_fast="" _og_keyvar="" _og_ctx="" _og_out=""
  if command -v jq >/dev/null 2>&1; then
    local _k _v
    while IFS=$'\t' read -r _k _v; do
      case "$_k" in
        bin)           _og_bin="$_v" ;;
        id)            _og_id="$_v" ;;
        base_url)      _og_base="$_v" ;;
        transport)     _og_transport="$_v" ;;
        strong_model)  _og_strong="$_v" ;;
        fast_model)    _og_fast="$_v" ;;
        key_var)       _og_keyvar="$_v" ;;
        context_limit) _og_ctx="$_v" ;;
        max_output)    _og_out="$_v" ;;
      esac
    done < <(jq -r 'to_entries[] | [.key, (.value|tostring)] | @tsv' "$_og_json" 2>/dev/null)
  fi

  : "${_og_id:=opencode-go}"
  : "${_og_base:=https://opencode.ai/zen/go/v1}"
  : "${_og_transport:=router}"
  : "${_og_strong:=deepseek-v4-pro}"
  : "${_og_fast:=deepseek-v4-flash}"
  : "${_og_keyvar:=ApiKey_Opencode_Zen}"
  : "${_og_ctx:=262144}"
  : "${_og_out:=32768}"

  local _reason="OpenCode Go multi-alias detected via pins-file (23 models, OpenAI-compatible)"

  jq -n \
    --arg keyvar "$_og_keyvar" \
    --arg base    "$_og_base" \
    --arg transport "$_og_transport" \
    --arg reason  "$_reason" \
    --argjson ctx "${_og_ctx:-null}" \
    --argjson out "${_og_out:-null}" \
    '[
      {
        key_var:             $keyvar,
        classification:      "llm",
        provider_id:         "opencode-go1",
        alias:               "opencode-go1",
        base_url:            $base,
        transport:           $transport,
        strong_model:        "deepseek-v4-pro",
        fast_model:          "deepseek-v4-flash",
        context_limit:       $ctx,
        max_output:          $out,
        status:              "resolved",
        reason:              ($reason + " (deepseek-family: DeepSeek V4 Pro / V4 Flash)")
      },
      {
        key_var:             $keyvar,
        classification:      "llm",
        provider_id:         "opencode-go2",
        alias:               "opencode-go2",
        base_url:            $base,
        transport:           $transport,
        strong_model:        "glm-5",
        fast_model:          "qwen-3.7",
        context_limit:       $ctx,
        max_output:          $out,
        status:              "resolved",
        reason:              ($reason + " (glm-family: GLM-5 / Qwen 3.7)")
      },
      {
        key_var:             $keyvar,
        classification:      "llm",
        provider_id:         "opencode-go3",
        alias:               "opencode-go3",
        base_url:            $base,
        transport:           $transport,
        strong_model:        "kimi-k2",
        fast_model:          "deepseek-v4-flash",
        context_limit:       $ctx,
        max_output:          $out,
        status:              "resolved",
        reason:              ($reason + " (long-context: Kimi K2 / DeepSeek V4 Flash)")
      },
      {
        key_var:             $keyvar,
        classification:      "llm",
        provider_id:         "opencode-go4",
        alias:               "opencode-go4",
        base_url:            $base,
        transport:           $transport,
        strong_model:        "qwen-3.7",
        fast_model:          "kimi-k2",
        context_limit:       $ctx,
        max_output:          $out,
        status:              "resolved",
        reason:              ($reason + " (qwen-family: Qwen 3.7 / Kimi K2)")
      },
      {
        key_var:             $keyvar,
        classification:      "llm",
        provider_id:         "opencode-go5",
        alias:               "opencode-go5",
        base_url:            $base,
        transport:           $transport,
        strong_model:        "deepseek-v4-pro",
        fast_model:          "qwen-3.7",
        context_limit:       $ctx,
        max_output:          $out,
        status:              "resolved",
        reason:              ($reason + " (balanced: DeepSeek V4 Pro / Qwen 3.7)")
      }
    ]'
}

# --- Chutes multi-alias detection (5 aliases from one API key) ---------------
# Chutes serves 14 open-weight models in TEE enclaves via an OpenAI-compatible
# endpoint. One API key maps to the entire catalog. This detector emits 5
# provider records (chutes1-chutes5), each with a distinct strong/fast model
# pair spanning different capability profiles (reasoning, vision, long-context,
# multimodal, budget). If the first alias fails verification, the next is tried.
#
# Model list refreshed from the live API (cached 24h). Override with env
# CMA_CHUTES_PINS_FILE to point at a different pins config.
detect_chutes_records() {
  local _ch_json="${CMA_CHUTES_PINS_FILE:-$LIB_DIR/providers/chutes.json}"
  [[ -f "$_ch_json" ]] || { printf '[]\n'; return 0; }

  # Gate: CHUTES_API_KEY must be present
  local _key_present=0
  if [[ -f "$CMA_KEYS_FILE" ]]; then
    local _key_val
    # shellcheck source=/dev/null
    _key_val="$( ( set +e; set -a +u; . "$CMA_KEYS_FILE" 2>/dev/null; set +a; printf '%s' "${CHUTES_API_KEY:-}" ) )" || true
    [[ -n "$_key_val" ]] && _key_present=1
  fi
  (( _key_present )) || { printf '[]\n'; return 0; }

  local _ch_base="" _ch_transport="" _ch_keyvar="" _ch_ctx="" _ch_out=""
  if command -v jq >/dev/null 2>&1; then
    local _k _v
    while IFS=$'\t' read -r _k _v; do
      case "$_k" in
        base_url)      _ch_base="$_v" ;;
        transport)     _ch_transport="$_v" ;;
        key_var)       _ch_keyvar="$_v" ;;
        context_limit) _ch_ctx="$_v" ;;
        max_output)    _ch_out="$_v" ;;
      esac
    done < <(jq -r 'to_entries[] | [.key, (.value|tostring)] | @tsv' "$_ch_json" 2>/dev/null)
  fi

  : "${_ch_base:=https://llm.chutes.ai/v1}"
  : "${_ch_transport:=router}"
  : "${_ch_keyvar:=CHUTES_API_KEY}"
  : "${_ch_ctx:=262144}"
  : "${_ch_out:=65536}"

  # 5 model pairings — each alias gets a distinct strong+fast combo.
  # If a specific model becomes unavailable, the next alias is tried.
  # All models are from the 2026-07-25 live catalog snapshot.
  local _reason="Chutes multi-alias detected via pins-file (TEE-enclave models, OpenAI-compatible)"

  jq -n \
    --arg keyvar "$_ch_keyvar" \
    --arg base    "$_ch_base" \
    --arg transport "$_ch_transport" \
    --arg reason  "$_reason" \
    --argjson ctx "${_ch_ctx:-null}" \
    --argjson out "${_ch_out:-null}" \
    '[
      {
        key_var:             $keyvar,
        classification:      "llm",
        provider_id:         "chutes1",
        alias:               "chutes1",
        base_url:            $base,
        transport:           $transport,
        strong_model:        "deepseek-ai/DeepSeek-V3.2-TEE",
        fast_model:          "Qwen/Qwen3-32B-TEE",
        context_limit:       $ctx,
        max_output:          $out,
        status:              "resolved",
        reason:              ($reason + " (deep-reasoning: DeepSeek V3.2 / Qwen3 32B)")
      },
      {
        key_var:             $keyvar,
        classification:      "llm",
        provider_id:         "chutes2",
        alias:               "chutes2",
        base_url:            $base,
        transport:           $transport,
        strong_model:        "Qwen/Qwen3.5-397B-A17B-TEE",
        fast_model:          "google/gemma-4-31B-turbo-TEE",
        context_limit:       $ctx,
        max_output:          $out,
        status:              "resolved",
        reason:              ($reason + " (vision: Qwen3.5 397B / Gemma 4 31B)")
      },
      {
        key_var:             $keyvar,
        classification:      "llm",
        provider_id:         "chutes3",
        alias:               "chutes3",
        base_url:            $base,
        transport:           $transport,
        strong_model:        "Qwen/Qwen3-235B-A22B-Thinking-2507-TEE",
        fast_model:          "MiniMaxAI/MiniMax-M2.5-TEE",
        context_limit:       $ctx,
        max_output:          $out,
        status:              "resolved",
        reason:              ($reason + " (thinking: Qwen3 235B-A22B / MiniMax M2.5)")
      },
      {
        key_var:             $keyvar,
        classification:      "llm",
        provider_id:         "chutes4",
        alias:               "chutes4",
        base_url:            $base,
        transport:           $transport,
        strong_model:        "zai-org/GLM-5.2-TEE",
        fast_model:          "moonshotai/Kimi-K2.5-TEE",
        context_limit:       $ctx,
        max_output:          $out,
        status:              "resolved",
        reason:              ($reason + " (long-context: GLM-5.2 1M / Kimi K2.5)")
      },
      {
        key_var:             $keyvar,
        classification:      "llm",
        provider_id:         "chutes5",
        alias:               "chutes5",
        base_url:            $base,
        transport:           $transport,
        strong_model:        "moonshotai/Kimi-K2.6-TEE",
        fast_model:          "Qwen/Qwen3.6-27B-TEE",
        context_limit:       $ctx,
        max_output:          $out,
        status:              "resolved",
        reason:              ($reason + " (multimodal: Kimi K2.6 / Qwen3.6 27B)")
      }
    ]'
}

# --- Hyper API multi-alias detection (5 aliases from one API key) ----------------
# Hyper (https://hyper.charm.land/) serves 21 open-weight + proprietary models via
# an OpenAI-compatible endpoint. One API key (HYPER_API_KEY) maps to the entire
# catalog. This detector emits 5 provider records (hyper1-hyper5), each with a
# distinct strong/fast model pair spanning different capability profiles
# (deep-reasoning, long-context, code-focused, qwen family, GLM/Kimi).
#
# Model list is fetched live from the API at sync time (NOT hardcoded catalog).
# Pins are loaded from providers/hyper.json.
detect_hyper_records() {
  local _hy_json="${CMA_HYPER_PINS_FILE:-$LIB_DIR/providers/hyper.json}"
  [[ -f "$_hy_json" ]] || { printf '[]\n'; return 0; }

  local _key_present=0
  if [[ -f "$CMA_KEYS_FILE" ]]; then
    local _key_val
    # shellcheck source=/dev/null
    _key_val="$( ( set +e; set -a +u; . "$CMA_KEYS_FILE" 2>/dev/null; set +a; printf '%s' "${HYPER_API_KEY:-}" ) )" || true
    [[ -n "$_key_val" ]] && _key_present=1
  fi
  (( _key_present )) || { printf '[]\n'; return 0; }

  local _hy_base="" _hy_transport="" _hy_keyvar="" _hy_ctx="" _hy_out=""
  if command -v jq >/dev/null 2>&1; then
    local _k _v
    while IFS=$'\t' read -r _k _v; do
      case "$_k" in
        base_url)      _hy_base="$_v" ;;
        transport)     _hy_transport="$_v" ;;
        key_var)       _hy_keyvar="$_v" ;;
        context_limit) _hy_ctx="$_v" ;;
        max_output)    _hy_out="$_v" ;;
      esac
    done < <(jq -r 'to_entries[] | [.key, (.value|tostring)] | @tsv' "$_hy_json" 2>/dev/null)
  fi

  : "${_hy_base:=https://hyper.charm.land/v1}"
  : "${_hy_transport:=router}"
  : "${_hy_keyvar:=HYPER_API_KEY}"
  : "${_hy_ctx:=1000000}"
  : "${_hy_out:=384000}"

  local _reason="Hyper multi-alias detected via pins-file (Charm.land inference, OpenAI-compatible)"

  jq -n \
    --arg keyvar "$_hy_keyvar" \
    --arg base    "$_hy_base" \
    --arg transport "$_hy_transport" \
    --arg reason  "$_reason" \
    --argjson ctx "${_hy_ctx:-null}" \
    --argjson out "${_hy_out:-null}" \
    '[
      {
        key_var:             $keyvar,
        classification:      "llm",
        provider_id:         "hyper1",
        alias:               "hyper1",
        base_url:            $base,
        transport:           $transport,
        strong_model:        "deepseek-v4-pro",
        fast_model:          "deepseek-v4-flash",
        context_limit:       $ctx,
        max_output:          $out,
        status:              "resolved",
        reason:              ($reason + " (deep-reasoning: DeepSeek V4 Pro / V4 Flash)")
      },
      {
        key_var:             $keyvar,
        classification:      "llm",
        provider_id:         "hyper2",
        alias:               "hyper2",
        base_url:            $base,
        transport:           $transport,
        strong_model:        "glm-5.2",
        fast_model:          "qwen3.6-flash",
        context_limit:       $ctx,
        max_output:          $out,
        status:              "resolved",
        reason:              ($reason + " (long-context: GLM-5.2 1M / Qwen3.6 Flash)")
      },
      {
        key_var:             $keyvar,
        classification:      "llm",
        provider_id:         "hyper3",
        alias:               "hyper3",
        base_url:            $base,
        transport:           $transport,
        strong_model:        "kimi-k2.7-code",
        fast_model:          "gemma-4-26b-a4b-it",
        context_limit:       $ctx,
        max_output:          $out,
        status:              "resolved",
        reason:              ($reason + " (code-focused: Kimi K2.7 Code / Gemma 4 26B)")
      },
      {
        key_var:             $keyvar,
        classification:      "llm",
        provider_id:         "hyper4",
        alias:               "hyper4",
        base_url:            $base,
        transport:           $transport,
        strong_model:        "qwen3.7-max",
        fast_model:          "qwen3.7-plus",
        context_limit:       $ctx,
        max_output:          $out,
        status:              "resolved",
        reason:              ($reason + " (qwen-family: Qwen3.7 Max / Qwen3.7 Plus)")
      },
      {
        key_var:             $keyvar,
        classification:      "llm",
        provider_id:         "hyper5",
        alias:               "hyper5",
        base_url:            $base,
        transport:           $transport,
        strong_model:        "glm-5.1",
        fast_model:          "kimi-k2.6",
        context_limit:       $ctx,
        max_output:          $out,
        status:              "resolved",
        reason:              ($reason + " (multimodal: GLM-5.1 / Kimi K2.6)")
      }
    ]'
}

resolve_records() {
  local keys; keys="$(present_key_vars | paste -sd, -)"
  local args=(--models-dev "$CACHE" --keys "$keys")
  [[ -f "$KEY_ALIASES" ]] && args+=(--key-aliases "$KEY_ALIASES")
  [[ -f "$OVERRIDES" ]] && args+=(--overrides "$OVERRIDES")
  local base_records extra rc
  # Capture BOTH the output and the real exit code explicitly. Do not rely on
  # `set -e` here: resolve_records() is itself invoked via a command
  # substitution (`records="$(resolve_records)"` in cmd_sync/cmd_sync_multi),
  # and a failing `var="$(cmd)"` assignment INSIDE a function that is itself
  # only reached through another command substitution does not reliably
  # trigger errexit in bash (a well-known nested-command-substitution
  # quirk) — a hard resolver crash could otherwise read as success with
  # $base_records silently left empty.
  base_records="$(python3 "$RESOLVER" "${args[@]}")"; rc=$?
  if (( rc != 0 )); then
    cma_die "providers_resolve.py failed (exit $rc) — refusing to merge in an empty/partial provider list"
  fi
  # A resolver that exits 0 but prints empty/invalid JSON is exactly as
  # dangerous as a nonzero exit: merging THAT in used to silently drop every
  # real provider (the old `jq -s` merge slurped both process-substitution
  # streams into one flat array and indexed into it by position — an empty
  # first stream shifted the HelixAgent record into `.[0]`, so the sync ran
  # with ONLY the local HelixAgent provider and zero real providers, exit 0,
  # no warning). Validate before ever reaching the merge.
  if ! printf '%s' "$base_records" | jq -e 'type=="array"' >/dev/null 2>&1; then
    cma_die "providers_resolve.py produced no/invalid JSON output — refusing to merge (would silently drop all providers)"
  fi
  # Merge the local-detector record(s) into the resolver output BEFORE cmd_sync
  # consumes it, so PATH-detected providers reuse the whole env/alias/verify
  # loop verbatim. Guard against emitting a HelixAgent/KimiCode record whose
  # provider_id a key-var already resolved to (cmd_sync also dedupes).
  extra="$(detect_helixagent_record)"
  if ! printf '%s' "$extra" | jq -e 'type=="array"' >/dev/null 2>&1; then
    cma_die "detect_helixagent_record produced no/invalid JSON output"
  fi
  extra_kc="$(detect_kimicode_record)" || true
  if ! printf '%s' "$extra_kc" | jq -e 'type=="array"' >/dev/null 2>&1; then
    cma_die "detect_kimicode_record produced no/invalid JSON output"
  fi
  extra_hl="$(detect_helixllm_records)" || true
  if ! printf '%s' "$extra_hl" | jq -e 'type=="array"' >/dev/null 2>&1; then
    cma_die "detect_helixllm_records produced no/invalid JSON output"
  fi
  extra_z="$(detect_opencode_zen_records)" || true
  if ! printf '%s' "$extra_z" | jq -e 'type=="array"' >/dev/null 2>&1; then
    cma_die "detect_opencode_zen_records produced no/invalid JSON output"
  fi
  extra_og="$(detect_opencode_go_records)" || true
  if ! printf '%s' "$extra_og" | jq -e 'type=="array"' >/dev/null 2>&1; then
    cma_die "detect_opencode_go_records produced no/invalid JSON output"
  fi
  extra_cht="$(detect_chutes_records)" || true
  if ! printf '%s' "$extra_cht" | jq -e 'type=="array"' >/dev/null 2>&1; then
    cma_die "detect_chutes_records produced no/invalid JSON output"
  fi
  extra_hy="$(detect_hyper_records)" || true
  if ! printf '%s' "$extra_hy" | jq -e 'type=="array"' >/dev/null 2>&1; then
    cma_die "detect_hyper_records produced no/invalid JSON output"
  fi
  # Merge all eight sources, deduped by provider_id. The Kimi Code OAuth
  # detector records take PRECEDENCE over key-var records (an OAuth
  # subscription is the user's priority for kimi-for-coding; the API key
  # remains the fallback on hosts without the OAuth session). Resolver
  # records still win over local PATH-detection. First occurrence wins.
  jq -n --argjson base "$base_records" --argjson e1 "$extra" --argjson e2 "$extra_kc" --argjson e3 "$extra_hl" --argjson e4 "$extra_og" --argjson e5 "$extra_cht" --argjson e6 "$extra_hy" --argjson e7 "$extra_z" '
    ($e2 + $base + $e3 + $e1 + $e4 + $e5 + $e6 + $e7) | unique_by(.provider_id)
  '
}

# --- status-cache deletion + orphan detection --------------------------------
# cma_status_delete <id> — remove one provider's entry from the status cache.
# Atomic (mktemp + mv, never an in-place redirect that could truncate the file
# on a partial/failed write). No-op if the cache is absent/empty or the id has
# no entry. lib.sh owns cma_status_write/cma_status_read/cma_status_all (the
# read/write API + the cma_status_cache() path helper, reused here) but ships
# no delete — that lives here since claude-providers.sh is the sole owner of
# provider lifecycle mutations (create/remove/prune).
cma_status_delete() {
  local id="$1" f; f="$(cma_status_cache)"
  [[ -s "$f" ]] || return 0
  cma_require jq
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
  if jq --arg id "$id" 'del(.[$id])' "$f" > "$tmp" 2>/dev/null; then
    command mv -f "$tmp" "$f"
  else
    rm -f "$tmp"; cma_warn "could not update status cache $f"
  fi
}

# cma_find_orphans <resolved-ids-space-separated>
# An "orphan" is a provider id that has a status.json entry and/or a leftover
# *.env file, but is NOT in the CURRENT resolved-records set (its catalog
# entry disappeared, its key was removed from the keys file, its key-alias/
# override entry was deleted, ...). Emits one candidate id per line. Uses the
# same padded-string membership test ("$seen"/case) already used elsewhere in
# this file for dedupe, rather than a jq/grep set-diff, so provider ids can
# never be misinterpreted as regex/glob patterns.
cma_find_orphans() {
  local resolved=" $1 " pdir; pdir="$(cma_providers_dir)"
  local sf; sf="$(cma_status_cache)"
  local candidates="" cid
  if [[ -s "$sf" ]]; then
    while IFS= read -r cid; do
      [[ -n "$cid" ]] || continue
      case "$candidates" in *" $cid "*) ;; *) candidates="$candidates $cid " ;; esac
    done < <(jq -r 'keys[]' "$sf" 2>/dev/null)
  fi
  if [[ -d "$pdir" ]] && compgen -G "$pdir/*.env" >/dev/null 2>&1; then
    local f base
    for f in "$pdir"/*.env; do
      base="$(basename "$f" .env)"
      case "$candidates" in *" $base "*) ;; *) candidates="$candidates $base " ;; esac
    done
  fi
  for cid in $candidates; do
    case "$resolved" in *" $cid "*) ;; *) printf '%s\n' "$cid" ;; esac
  done
}

# --- prune-only: the two DISTINCT orphan classes ----------------------------
# cma_find_orphans (above) answers one question — "is this candidate id
# missing from the CURRENT resolved set?" — over the UNION of status.json
# keys and *.env basenames. That union conflates two genuinely different
# situations, which is exactly the discrepancy this section resolves:
#
#   STATUS-ONLY: a status.json entry with NO backing *.env file. This can
#   happen even for an id that resolves PERFECTLY FINE today — cmd_sync's
#   failed-verification branch writes a status record ("failed") but
#   deliberately never calls cma_provider_write_env (see cmd_sync above), so
#   a provider that fails its very first existence probe gets a status entry
#   and nothing else. Whatever the cause, an id with no *.env is invisible to
#   list/list-all/list-faulty (_list_rows iterates *.env files only) and
#   unreachable by `claude-providers remove` (which requires the env file to
#   exist) — so it is permanently stuck, pure dead weight in status.json.
#   Deleting the record is always safe: if the id still resolves, the next
#   sync recreates an equivalent (or better) record from scratch; if it does
#   not, nothing else referenced it anyway.
#
#   UNRESOLVED: an id WITH a *.env file (so it IS visible/launchable state)
#   whose provider id is no longer in the CURRENT resolved set. Unlike
#   STATUS-ONLY, this id has a live alias, config dir (~/<prefix>prov-<id>,
#   possibly holding real session/plugin state), and status record — the
#   underlying cause is very often a key temporarily missing from the keys
#   file rather than a permanent catalog change, so removing it is a real,
#   possibly-inconvenient action, not pure cleanup. cmd_prune therefore
#   requires the (see below) explicit `--unresolved` flag before touching
#   this class for real.
#
# Neither helper takes/needs the padded-string dance cma_find_orphans uses
# for candidates: cma_find_status_only_orphans has no "resolved" input at
# all, and cma_find_unresolved_orphans only ever walks *.env basenames (never
# treats a provider id as a regex/glob pattern).

# cma_find_status_only_orphans — status.json ids with no *.env. Unconditional:
# deliberately NOT filtered by resolved-ness (see rationale above). Emits one
# candidate id per line.
cma_find_status_only_orphans() {
  local pdir; pdir="$(cma_providers_dir)"
  local sf; sf="$(cma_status_cache)"
  [[ -s "$sf" ]] || return 0
  local id
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    [[ -f "$pdir/$id.env" ]] || printf '%s\n' "$id"
  done < <(jq -r 'keys[]' "$sf" 2>/dev/null)
}

# cma_find_unresolved_orphans <resolved-ids-space-separated> — *.env ids that
# are NOT in the current resolved set. Emits one candidate id per line.
cma_find_unresolved_orphans() {
  local resolved=" $1 " pdir; pdir="$(cma_providers_dir)"
  [[ -d "$pdir" ]] && compgen -G "$pdir/*.env" >/dev/null 2>&1 || return 0
  local f base
  for f in "$pdir"/*.env; do
    base="$(basename "$f" .env)"
    case "$resolved" in *" $base "*) ;; *) printf '%s\n' "$base" ;; esac
  done
}

# cma_demote_orphans <resolved-ids-space-separated>
# Warns about + demotes every id cma_find_orphans reports, so the launch-time
# activation gate (which trusts ONLY status=="verified") stops trusting a
# provider that quietly disappeared from the catalog/keys. Deliberately does
# NOT touch the .env/alias/config dir — actual removal is an explicit
# `claude-providers remove`/`prune` action, never implicit sync fallout.
cma_demote_orphans() {
  local resolved="$1" pdir; pdir="$(cma_providers_dir)"
  local sf; sf="$(cma_status_cache)"
  local oid
  while IFS= read -r oid; do
    [[ -n "$oid" ]] || continue
    local model="" ef="$pdir/$oid.env"
    if [[ -f "$ef" ]]; then
      # shellcheck disable=SC1090
      model="$( ( set -a; . "$ef"; set +a; printf '%s' "${CMA_PROVIDER_MODEL:-}" ) )"
    fi
    [[ -n "$model" ]] || model="$(jq -r --arg id "$oid" '.[$id].model // ""' "$sf" 2>/dev/null)"
    cma_warn "provider '$oid' is ORPHANED — it no longer resolves against the current catalog/keys, but its status/config was left behind. Demoting so the launch gate refuses it. Run 'claude-providers prune' to remove it, or restore its key to re-adopt it."
    cma_status_write "$oid" orphaned "$model" orphan
  done < <(cma_find_orphans "$resolved")
}

# --- subcommand: sync -------------------------------------------------------
cmd_sync() {
  local _filter="${1:-}"
  # Fail fast + clearly if the keys file is a directory (present_key_vars also warns,
  # but it runs in a subshell so its die can't abort the main sync — v1.12.1 5a).
  [[ -d "$CMA_KEYS_FILE" ]] && cma_die "keys file is a directory, not a file: $CMA_KEYS_FILE (pass a file with --keys-file)"
  ensure_catalog
  # Heal a stale/outdated alias file ONCE per full sync (idempotent): the self-heal
  # path for an outdated cma_run_provider wrapper (e.g. a pre-Phase-2 one lacking the
  # activation gate). cma_provider_write_alias only bootstraps the file when absent
  # (keeping --refresh-aliases byte-idempotent), so the healing migration must run
  # here, once, not per alias line (final-review I-2).
  (( DRY_RUN )) || cma_ensure_alias_file
  # One-time migration of pre-v1.17.0 LOCAL daemon/jobs dirs under existing
  # provider dirs into the shared store (idempotent via marker file): their
  # background-agent rosters must join the shared registry, not be stranded.
  (( DRY_RUN )) || cma_migrate_daemon_dirs_once
  local records; records="$(resolve_records)"
  local total resolved
  total="$(jq 'length' <<<"$records")"
  resolved="$(jq '[.[]|select(.status=="resolved")]|length' <<<"$records")"
  cma_log "discovered $total key vars; $resolved resolve to a provider"
  local resolved_ids
  resolved_ids="$(jq -r '[.[] | select(.status=="resolved") | .provider_id] | unique | join(" ")' <<<"$records")"

  if [[ -n "$_filter" ]]; then
    local _match_count
    _match_count="$(jq --arg f "$_filter" '[.[] | select(.provider_id == $f or .alias == $f)] | length' <<<"$records")"
    if (( _match_count == 0 )); then
      cma_die "no provider matching '$_filter' found (check with: claude-providers list)"
    fi
    records="$(jq --arg f "$_filter" '[.[] | select(.provider_id == $f or .alias == $f)]' <<<"$records")"
    cma_log "filtered to provider '$_filter' ($_match_count record(s))"
  fi

  # Always-on plugins (additive union) — once, before per-provider work.
  if (( ! DRY_RUN )); then
    # shellcheck disable=SC2086
    cma_enable_plugins $CMA_ALWAYS_ON_PLUGINS 2>/dev/null || true
  fi

  # Dedupe by provider_id: one alias per provider even if multiple key vars map
  # to it (e.g. CODESTRAL_API_KEY + MISTRAL_API_KEY both -> mistral).
  local seen=" "
  local n_created=0 n_skipped=0 n_disabled=0
  while IFS=$'\t' read -r status pid alias keyvar transport base model fast ctx_limit max_out; do
    [[ "$status" == "resolved" ]] || { n_skipped=$((n_skipped+1)); continue; }
    case "$seen" in *" $pid "*) cma_warn "provider '$pid' already handled; skipping duplicate key $keyvar"; continue ;; esac
    seen="$seen$pid "

    local cdir="$HOME/${CMA_PROVIDER_DIR_PREFIX}${pid}"
    if (( DRY_RUN )); then
      printf '  would create: alias %-14s -> %-16s [%s] %s\n' "$alias" "$pid" "$transport" "$model"
      continue
    fi

    # Verification (pluggable). verified|unverified -> activate; failed -> disable.
    local vstatus="unverified"
    if (( ! NO_VERIFY )); then
      local vargs=(--provider "$pid" --model "$model" --key-var "$keyvar")
      [[ -n "$base" && "$base" != "null" ]] && vargs+=(--base-url "$base")
      (( OFFLINE )) && vargs+=(--offline)
            # Source keys so the verifier/probe can read the secret (subshell only).
      # Disable nounset while sourcing: the user-controlled keys file may
      # contain dangling references (e.g. `export X=$UNSET`), which under the
      # inherited `set -u` would abort the source mid-file — silently leaving
      # every key defined after that point unexported, so those providers fail
      # verification ("unverified") and a stream of "unbound variable" errors
      # spams stderr. `+u` makes the source tolerant; it is subshell-local.
      # shellcheck source=/dev/null  # runtime user keys file, path only known at execution
      # Kimi Code OAuth sentinel: inject the live token from the provider
      # token file BEFORE the verification subshell so ${!_CMA_KIMICODE_OAUTH_}
      # resolves correctly inside the verifier's ${!KEYVAR} expansion.
      if [[ "$keyvar" == "_CMA_KIMICODE_OAUTH_" ]]; then
        local _kimi_tokf; _kimi_tokf="$(cma_providers_dir)/kimi-for-coding.token"
        [[ -f "$_kimi_tokf" ]] && export _CMA_KIMICODE_OAUTH_="$(cat "$_kimi_tokf" 2>/dev/null)"
      fi
      vstatus="$( ( [[ -e "$CMA_KEYS_FILE" ]] && { set -a +u; . "$CMA_KEYS_FILE"; set +a; }; bash "$VERIFY" "${vargs[@]}" 2>/dev/null ) )" || true
      [[ -z "$vstatus" ]] && vstatus="unverified"
    fi

    if [[ "$vstatus" == "failed" ]]; then
      cma_warn "provider '$pid' FAILED verification — alias NOT activated"
      cma_status_write "$pid" failed "$model" existence
      n_disabled=$((n_disabled+1))
      continue
    fi

    cma_link_shared_items "$cdir"
    cma_provider_write_env "$pid" "$keyvar" "$transport" "$base" "$model" "$fast" "$cdir" "$ctx_limit" "$max_out" "$alias"
    cma_provider_write_alias "$alias" "$pid"

    # Layer bookkeeping. vstatus here is 'verified' (existence+tool-call passed)
    # or 'unverified' (existence probe inconclusive). failing_layer records the
    # FIRST layer that did not pass ("" when none failed).
    local flayer=""
    if [[ "$vstatus" == "verified" ]]; then
      # Layer 3: semantic code-visibility. Only attempt when verification is on
      # and we are not offline; a 'skip' (precondition absent) NEVER downgrades.
      if (( ! NO_VERIFY )) && (( ! OFFLINE )); then
        local sstatus
        # shellcheck source=/dev/null  # runtime user keys file, path only known at execution
        sstatus="$( ( [[ -e "$CMA_KEYS_FILE" ]] && { set -a +u; . "$CMA_KEYS_FILE"; set +a; }; \
                      bash "$SEMANTIC" --provider "$pid" --model "$model" --key-var "$keyvar" \
                        ${base:+--base-url "$base"} 2>/dev/null ) )" || true
        if [[ "$sstatus" == "unverified" ]]; then
          vstatus="unverified"; flayer="semantic"
        fi
        # 'verified' | 'skip' | '' -> keep the existence verdict (verified).
      fi
    else
      # existence probe was inconclusive -> the layer that did not pass is existence.
      flayer="existence"
    fi
    cma_status_write "$pid" "$vstatus" "$model" "$flayer"
    cma_log "provider '$pid' -> alias '$alias' [$transport] model=$model ($vstatus${flayer:+/$flayer})"
    n_created=$((n_created+1))
  done < <(jq -r '.[] | [.status,.provider_id,.alias,.key_var,.transport,.base_url,.strong_model,.fast_model,.context_limit,.max_output] | @tsv' <<<"$records")

  # Orphan detection: any status.json/*.env record whose provider id is NOT in
  # the CURRENT resolved set (catalog/key/override dropped it) is demoted +
  # warned about — never silently left trusting a stale 'verified' forever.
  # Skipped under --dry-run (nothing else in a dry-run sync is written either).
  (( DRY_RUN )) || cma_demote_orphans "$resolved_ids"

  cma_log "sync done: $n_created active, $n_disabled disabled (failed verify), $n_skipped not-resolved"
  cma_log "reload your shell or: source $ALIAS_FILE"
}

# --- subcommand: verify ------------------------------------------------------
# claude-providers verify <id> [--deep]
# Re-run verification for ONE already-installed provider and persist status.
# --deep also runs the live superpowers-TUI (layer 4); without it, layers 1-3.
cmd_verify() {
  local id="${1:-}" deep=0; shift 2>/dev/null || true
  [[ "${1:-}" == "--deep" ]] && deep=1
  [[ -n "$id" ]] || cma_die "usage: claude-providers verify <id> [--deep]"
  local envf; envf="$(cma_providers_dir)/$id.env"
  [[ -f "$envf" ]] || cma_die "unknown provider: $id (run: claude-providers sync)"
  # shellcheck source=/dev/null
  ( set -a +u; . "$envf"; set +a
    local base="$CMA_PROVIDER_BASE_URL" model="$CMA_PROVIDER_MODEL" keyvar="$CMA_PROVIDER_KEYVAR"
    # Kimi Code OAuth sentinel: cmd_verify has no detector to refresh/inject
    # the token (cmd_sync does it in its loop), so do it here — live cred file
    # when unexpired (60s skew), else the token-file snapshot (same freshness
    # order as the launch wrapper).
    if [[ "$keyvar" == "_CMA_KIMICODE_OAUTH_" ]]; then
      local _kcred="$HOME/.kimi-code/credentials/kimi-code.json" _kexp=0 _ktokf
      [[ -f "$_kcred" ]] && _kexp="$(jq -r '.expires_at // 0' "$_kcred" 2>/dev/null || echo 0)"
      if (( _kexp > $(date +%s) + 60 )); then
        export _CMA_KIMICODE_OAUTH_="$(jq -r '.access_token // ""' "$_kcred" 2>/dev/null)"
      else
        _ktokf="$(cma_providers_dir)/$id.token"
        [[ -f "$_ktokf" ]] && export _CMA_KIMICODE_OAUTH_="$(cat "$_ktokf" 2>/dev/null)"
      fi
    fi
    local vst sst flayer=""
    vst="$( ( [[ -e "$CMA_KEYS_FILE" ]] && { set -a +u; . "$CMA_KEYS_FILE"; set +a; }; \
              bash "$VERIFY" --provider "$id" --model "$model" --key-var "$keyvar" ${base:+--base-url "$base"} 2>/dev/null ) )" || true
    [[ -z "$vst" ]] && vst=unverified
    if [[ "$vst" == "failed" ]]; then cma_status_write "$id" failed "$model" existence; echo "failed"; return; fi
    if [[ "$vst" != "verified" ]]; then cma_status_write "$id" unverified "$model" existence; echo "unverified"; return; fi
    sst="$( ( [[ -e "$CMA_KEYS_FILE" ]] && { set -a +u; . "$CMA_KEYS_FILE"; set +a; }; \
              bash "$SEMANTIC" --provider "$id" --model "$model" --key-var "$keyvar" ${base:+--base-url "$base"} 2>/dev/null ) )" || true
    if [[ "$sst" == "unverified" ]]; then cma_status_write "$id" unverified "$model" semantic; echo "unverified"; return; fi
    if (( deep )); then
      # Capture the exit code into a variable BEFORE it is consumed by the
      # `if`/`fi` test below — `$?` immediately after an `if cond; then …; fi`
      # whose condition was false is the if-STATEMENT's own status (0 per
      # POSIX when no branch ran), never the condition command's real code, so
      # reading `$?` after the `fi` would silently and permanently disable the
      # FAIL-demotes branch below.
      local tui_rc=0
      bash "$LIB_DIR/verify_superpowers_tui.sh" --alias "$id" >/dev/null 2>&1 || tui_rc=$?
      if [[ "$tui_rc" -eq 0 ]]; then
        cma_status_write "$id" verified "$model" ""; echo "verified"; return
      fi
      # layer-4 SKIP or FAIL: SKIP keeps verified-through-3; FAIL demotes.
      # verify_superpowers_tui.sh exits 0 on PASS *and* on SKIP (honest), 1 on FAIL.
      if [[ "$tui_rc" -eq 1 ]]; then cma_status_write "$id" unverified "$model" superpowers_tui; echo "unverified"; return; fi
      # Any OTHER exit (2/127 = crash/bad-arg) is NOT a layer-4 pass: treat as an
      # honest SKIP — keep the verified-through-layer-3 status, never claim layer-4
      # passed on a crash (final-review M-2). Falls through to the verified write.
      cma_warn "provider '$id': layer-4 verifier exited $tui_rc (crash) — treating as SKIP (verified through layer 3)"
    fi
    cma_status_write "$id" verified "$model" ""; echo "verified" )
}

# --- subcommand: list family ------------------------------------------------
# The three list subcommands share one row emitter, filtered by status:
#   list         -> only VERIFIED aliases (safe to launch; the default view).
#   list-all     -> every installed alias (the pre-split behavior).
#   list-faulty  -> only non-verified aliases (failed/unverified/pending) —
#                   the "what do I need to fix" view, with the failing layer.
# Status is read from the status cache (cma_status_read); an alias with no
# cache entry reads 'pending'.
# _list_rows <filter>   filter: verified | faulty | all
_list_rows() {
  local filter="$1" pdir; pdir="$(cma_providers_dir)"
  if [[ ! -d "$pdir" ]] || ! compgen -G "$pdir/*.env" >/dev/null; then
    echo "No provider aliases installed. Run: claude-providers sync"
    return 0
  fi
  printf '%-14s %-16s %-10s %-12s %-24s\n' ALIAS PROVIDER STATUS LAYER STRONG_MODEL
  local f
  for f in "$pdir"/*.env; do
    local id status layer keep=0
    # shellcheck disable=SC1090
    id="$( ( set -a; . "$f"; set +a; printf '%s' "$CMA_PROVIDER_ID" ) )"
    status="$(cma_status_read "$id")"
    case "$filter" in
      verified) [[ "$status" == "verified" ]] && keep=1 ;;
      faulty)   [[ "$status" != "verified" ]] && keep=1 ;;
      all)      keep=1 ;;
    esac
    (( keep )) || continue
    layer="$(cma_status_all | awk -F'\t' -v i="$id" '$1==i{print $5}')"
    # shellcheck disable=SC1090
    ( set -a; . "$f"; set +a
      # `|| alias=""` is LOAD-BEARING: under `set -euo pipefail` a no-match grep
      # (exit 1, propagated by pipefail) would abort the subshell — and the whole
      # listing — for any provider whose alias line is absent.
      alias="$(grep -E "cma_run_provider $CMA_PROVIDER_ID(\"| )" "$ALIAS_FILE" 2>/dev/null | sed -E 's/^alias ([^=]+)=.*/\1/' | head -1)" || alias=""
      printf '%-14s %-16s %-10s %-12s %-24s\n' \
        "${alias:-?}" "$CMA_PROVIDER_ID" "$status" "${layer:--}" "$CMA_PROVIDER_MODEL" )
  done
}
cmd_list()        { _list_rows verified; }
cmd_list_all()    { _list_rows all; }
cmd_list_faulty() { _list_rows faulty; }

# --- subcommand: show -------------------------------------------------------
cmd_show() {
  local id="${1:-}"; [[ -n "$id" ]] || cma_die "usage: claude-providers show <id>"
  case "$id" in *[!A-Za-z0-9._-]*) cma_die "invalid provider id: $id" ;; esac
  local f; f="$(cma_providers_dir)/$id.env"
  [[ -f "$f" ]] || cma_die "no such provider: $id"
  echo "# $f"; cat "$f"
}

# --- subcommand: remove -----------------------------------------------------
cmd_remove() {
  local id="${1:-}"; [[ -n "$id" ]] || cma_die "usage: claude-providers remove <id>"
  case "$id" in *[!A-Za-z0-9._-]*) cma_die "invalid provider id: $id" ;; esac
  local f; f="$(cma_providers_dir)/$id.env"
  [[ -f "$f" ]] || cma_die "no such provider: $id"
  # `|| alias=""` is LOAD-BEARING: under `set -euo pipefail` a no-match grep would
  # abort cmd_remove before `rm -f "$f"`, leaving the provider half-removed.
  local alias; alias="$(grep -E "cma_run_provider $id(\"| )" "$ALIAS_FILE" 2>/dev/null | sed -E 's/^alias ([^=]+)=.*/\1/' | head -1)" || alias=""
  [[ -n "$alias" ]] && cma_remove_alias "$alias"
  rm -f "$f"
  local cdir="$HOME/${CMA_PROVIDER_DIR_PREFIX}${id}"
  if [[ -d "$cdir" ]]; then
    mv "$cdir" "${cdir}.preunify.$(date +%Y%m%d%H%M%S)"
    cma_log "backed up + removed config dir $cdir"
  fi
  # Clear the verification status record too — otherwise a removed provider's
  # LAST status (possibly "verified") lingers in status.json forever. That is
  # not just clutter: a future re-add of the same id (or an orphan left behind
  # by a partial removal) would read the stale record via the activation gate.
  cma_status_delete "$id"
  cma_log "removed provider '$id' (alias '${alias:-none}')"
}

# --- subcommand: prune -------------------------------------------------------
# claude-providers prune [--dry-run] [--unresolved]
# Reports (and, unless --dry-run, removes) orphaned providers. This is the
# explicit, operator-invoked counterpart to cmd_sync's automatic
# demote-on-detect: sync never deletes anything, prune is the only path that
# can actually remove an orphan's alias/env/config dir — via the same
# cmd_remove used for a manual `claude-providers remove <id>`.
#
# TWO DISTINCT classes are detected and handled differently (see the
# cma_find_status_only_orphans/cma_find_unresolved_orphans doc comment above
# for the full rationale):
#
#   status-only  — a status.json record with no backing *.env file. Always
#                  pure dead weight (nothing else references it: invisible to
#                  list/list-all/list-faulty, unreachable by `remove`).
#                  Removed unconditionally — status-only orphans are safe to
#                  drop even without --unresolved, and even a resolving-but-
#                  currently-failing provider (no .env yet) simply gets its
#                  status record recreated by the next sync if it still
#                  resolves, so there is nothing to lose.
#
#   unresolved   — a provider WITH a *.env file (a live alias/config dir,
#                  possibly holding real session/plugin state) whose id no
#                  longer resolves against the CURRENT catalog + keys file.
#                  The most common real-world cause is a key temporarily
#                  missing from the keys file, not a permanent catalog
#                  change — removing it is a real, possibly-inconvenient
#                  action (cmd_remove backs up rather than deletes the config
#                  dir, but the alias/env/status are gone outright). This
#                  class is therefore only ever REPORTED by a plain `prune`;
#                  actually removing it requires the explicit --unresolved
#                  flag (composable with --dry-run to preview it first).
cmd_prune() {
  ensure_catalog
  local records; records="$(resolve_records)"
  local resolved_ids
  resolved_ids="$(jq -r '[.[] | select(.status=="resolved") | .provider_id] | unique | join(" ")' <<<"$records")"

  local status_only; status_only="$(cma_find_status_only_orphans)"
  local unresolved;  unresolved="$(cma_find_unresolved_orphans "$resolved_ids")"

  if [[ -z "$status_only" && -z "$unresolved" ]]; then
    cma_log "prune: no orphaned providers found"
    return 0
  fi

  local oid n_status=0 n_unresolved_acted=0 n_unresolved_reported=0

  if [[ -n "$status_only" ]]; then
    while IFS= read -r oid; do
      [[ -n "$oid" ]] || continue
      n_status=$((n_status+1))
      if (( DRY_RUN )); then
        printf '  would prune: %-28s [status-only orphan — status.json record with no backing .env; always safe to drop]\n' "$oid"
        continue
      fi
      cma_log "pruning status-only orphan '$oid' (no .env — dropping the stale status record)"
      cma_status_delete "$oid"
    done <<< "$status_only"
  fi

  if [[ -n "$unresolved" ]]; then
    while IFS= read -r oid; do
      [[ -n "$oid" ]] || continue
      if (( PRUNE_UNRESOLVED )); then
        n_unresolved_acted=$((n_unresolved_acted+1))
        if (( DRY_RUN )); then
          printf '  would prune: %-28s [unresolved orphan — has a config but no longer resolves against catalog/keys]\n' "$oid"
          continue
        fi
        cma_log "pruning unresolved orphan '$oid' (no longer resolves against catalog/keys; --unresolved was passed)"
        cmd_remove "$oid"
      else
        n_unresolved_reported=$((n_unresolved_reported+1))
        printf '  found (NOT pruned): %-20s [unresolved orphan — has a config but no longer resolves against catalog/keys; its key may just be temporarily missing. Re-add the key to keep it, or re-run with --unresolved to remove its alias/env/config dir]\n' "$oid"
      fi
    done <<< "$unresolved"
  fi

  local n_total=$((n_status + n_unresolved_acted + n_unresolved_reported))
  local n_unresolved_total=$((n_unresolved_acted + n_unresolved_reported))
  if (( DRY_RUN )); then
    local suffix=""
    (( PRUNE_UNRESOLVED )) && suffix=", all would be pruned"
    cma_log "prune --dry-run: $n_total orphan(s) found ($n_status status-only, $n_unresolved_total unresolved$suffix); nothing changed"
  else
    local tail=""
    (( n_unresolved_reported > 0 )) && tail="; $n_unresolved_reported unresolved orphan(s) left untouched — re-run with --unresolved to remove them"
    cma_log "prune: removed $((n_status + n_unresolved_acted)) orphaned provider(s) ($n_status status-only, $n_unresolved_acted unresolved)$tail"
  fi
}

# --- subcommand: add --------------------------------------------------------
cmd_add() {
  local from_key="" pid=""
  while (( $# )); do
    case "$1" in
      --from-key) from_key="$2"; shift 2 ;;
      --id) pid="$2"; shift 2 ;;
      *) cma_die "add: unknown arg $1" ;;
    esac
  done
  [[ -n "$from_key" && -n "$pid" ]] || cma_die "usage: claude-providers add --from-key VAR --id PROVIDER_ID"
  cma_require jq
  mkdir -p "$(dirname "$KEY_ALIASES")"
  [[ -s "$KEY_ALIASES" ]] || echo '{}' > "$KEY_ALIASES"
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
  jq --arg k "$from_key" --arg p "$pid" '.[$k]=$p' "$KEY_ALIASES" > "$tmp" && mv "$tmp" "$KEY_ALIASES"
  cma_log "registered $from_key -> $pid in $KEY_ALIASES"
  cmd_sync
}

# --- subcommand: sync --multi -----------------------------------------------
# Verify ALL models for each provider, score them, and create multiple aliases
# (provider, provider2, provider3...) with paired strong+fast models.
cmd_sync_multi() {
  # Same clear-die-on-directory guard as cmd_sync — present_key_vars dies only in a
  # subshell here too, so the --multi path needs its own main-process check (v1.12.1 5a).
  [[ -d "$CMA_KEYS_FILE" ]] && cma_die "keys file is a directory, not a file: $CMA_KEYS_FILE (pass a file with --keys-file)"
  cma_require python3
  cma_require jq
  ensure_catalog
  (( DRY_RUN )) || cma_ensure_alias_file   # heal stale wrappers once (final-review I-2; see cmd_sync)

  local records; records="$(resolve_records)"
  local total resolved
  total="$(jq 'length' <<<"$records")"
  resolved="$(jq '[.[]|select(.status=="resolved")]|length' <<<"$records")"
  cma_log "multi-sync: discovered $total key vars; $resolved resolve to a provider"

  # Always-on plugins
  if (( ! DRY_RUN )); then
    # shellcheck disable=SC2086
    cma_enable_plugins $CMA_ALWAYS_ON_PLUGINS 2>/dev/null || true
  fi

  local pdir; pdir="$(cma_providers_dir)"; mkdir -p "$pdir"
  local seen=" "
  local n_created=0 n_skipped=0

  while IFS=$'\t' read -r status pid alias keyvar transport base model fast ctx_limit max_out; do
    [[ "$status" == "resolved" ]] || { n_skipped=$((n_skipped+1)); continue; }
    case "$seen" in *" $pid "*) continue ;; esac
    seen="$seen$pid "

    # Get the API key for verification — source keys file in a subshell,
    # then use indirect expansion to read the specific key variable.
    local keysf="${CMA_KEYS_FILE:-$HOME/api_keys.sh}"
    local token=""
    if [[ -f "$keysf" ]]; then
      # Read the key in an isolated subshell (no `bash -c` string interpolation
      # of $keysf, which a quote in the path could break out of). $keyvar is a
      # validated env-var name, so the indirect eval is safe. set +e/+u so a
      # dangling ref or failed source can't abort before the read.
      # shellcheck source=/dev/null  # $keysf is the user's runtime keys file
      token="$( set +e; set -a +u; . "$keysf" 2>/dev/null; set +a; eval "printf '%s' \"\${$keyvar:-}\"" )" || true
    fi

    if [[ -z "$token" ]]; then
      cma_warn "provider '$pid': \$${keyvar} is empty — skipping multi-alias generation"
      continue
    fi

    # Normalize base URL for verification endpoint
    local verify_endpoint="$base"
    case "$verify_endpoint" in
      */chat/completions|*/v1/messages|*/v1/models*) ;;
      *) verify_endpoint="${verify_endpoint%/}/chat/completions" ;;
    esac

    # Free-tier-first (ATM-860 / D14): the default probes ONLY free-tier
    # models; paid + underivable tiers cost real money and need the explicit
    # --include-paid opt-in. model_verify.py owns the classification (real
    # catalog cost data / :free ids / local endpoints — never a roster).
    local tier_args=(--free-only) tier_note="free-tier only"
    if (( INCLUDE_PAID )); then
      tier_args=() tier_note="INCLUDING PAID (explicit opt-in)"
    fi

    cma_log "multi-sync: verifying models for '$pid' at $verify_endpoint ($tier_note)..."

    if (( DRY_RUN )); then
      cma_log "  would verify models for '$pid' ($tier_note) and generate multi-aliases"
      continue
    fi

    # Run model verification — key is passed via env var (not argv) so it
    # does not appear in /proc/<pid>/cmdline or `ps aux` on multi-user hosts.
    local verified_out="$pdir/${pid}_verified.json"
    CMA_PROBE_KEY="$token" python3 "$MODEL_VERIFY" \
      --provider "$pid" \
      --endpoint "$verify_endpoint" \
      --catalog "$CACHE" \
      --concurrency "$VERIFY_CONCURRENCY" \
      --cache-file "$VERIFIED_CACHE" \
      --output "$verified_out" \
      ${tier_args[@]+"${tier_args[@]}"} \
      --verbose 2>&1 || { cma_warn "verification failed for '$pid'"; continue; }

    local vcount; vcount="$(jq '.verified_count' "$verified_out" 2>/dev/null || echo 0)"
    cma_log "  $pid: $vcount models verified"

    if (( vcount == 0 )); then
      cma_warn "provider '$pid': no models verified — skipping"
      continue
    fi

    # Generate multi-alias configuration
    local manifest_out="$pdir/${pid}_manifest.json"
    python3 "$PROVIDERS_GENERATE" \
      --provider "$pid" \
      --verified "$verified_out" \
      --output-dir "$pdir" \
      --max-aliases "$MAX_ALIASES" \
      --min-score "$MIN_SCORE" \
      --key-var "$keyvar" \
      --transport "$transport" \
      --base-url "$base" \
      --context-limit "$ctx_limit" \
      --max-output "$max_out" \
      --account-prefix "$ACCOUNT_PREFIX" \
      --home "$HOME" \
      2>/dev/null > "$manifest_out" || { cma_warn "alias generation failed for '$pid'"; continue; }

    local alias_count; alias_count="$(jq '.alias_count' "$manifest_out" 2>/dev/null || echo 0)"
    cma_log "  $pid: $alias_count aliases generated"

    # Create config dirs and symlinks for each alias
    local i=0
    while (( i < alias_count )); do
      local aname; aname="$(jq -r ".aliases[$i].alias_name // empty" "$manifest_out")"
      local cdir="$HOME/${ACCOUNT_PREFIX}prov-${aname}"

      cma_link_shared_items "$cdir"

      # Write the env file from manifest
      local strong; strong="$(jq -r ".aliases[$i].strong_model // empty" "$manifest_out")"
      local ffast; ffast="$(jq -r ".aliases[$i].fast_model // empty" "$manifest_out")"
      local alias_url; alias_url="$(jq -r ".aliases[$i].base_url // empty" "$manifest_out")"
      local alias_transport; alias_transport="$(jq -r ".aliases[$i].transport // empty" "$manifest_out")"
      local alias_ctx; alias_ctx="$(jq -r ".aliases[$i].context_limit // empty" "$manifest_out")"
      local alias_max; alias_max="$(jq -r ".aliases[$i].max_output // empty" "$manifest_out")"

      cma_provider_write_env "$aname" "$keyvar" "$alias_transport" "$alias_url" "$strong" "$ffast" "$cdir" "$alias_ctx" "$alias_max" "$aname"
      cma_provider_write_alias "$aname" "$aname"

      # Persist verification status to the status cache so the activation
      # gate (cma_run_provider) can determine if this alias is usable.
      # Use the strong-model's verification score from the manifest; aliases
      # with score below MIN_SCORE are marked unverified with failing_layer
      # "existence" (mirrors the cmd_sync pattern).
      local ascore
      ascore="$(jq -r ".aliases[$i].strong_score // 0 | floor" "$manifest_out" 2>/dev/null || echo 0)"
      if (( ascore >= MIN_SCORE )); then
        cma_status_write "$aname" verified "$strong" ""
      else
        cma_status_write "$aname" unverified "$strong" existence
      fi

      cma_log "  alias '$aname': strong=$strong fast=$ffast [$alias_transport]"
      n_created=$((n_created+1))
      i=$((i+1))
    done

  done < <(jq -r '.[] | [.status,.provider_id,.alias,.key_var,.transport,.base_url,.strong_model,.fast_model,.context_limit,.max_output] | @tsv' <<<"$records")

  cma_log "multi-sync done: $n_created aliases created across all providers"
  cma_log "reload your shell or: source $ALIAS_FILE"
}

# --- arg parsing + dispatch -------------------------------------------------
SUBCMD="sync"
case "${1:-}" in
  sync|list|list-all|list-faulty|show|verify|remove|prune|add) SUBCMD="$1"; shift ;;
  -h|--help) usage; exit 0 ;;
esac
POSITIONAL=()
while (( $# )); do
  # shellcheck disable=SC2034  # ASSUME_YES (-y/--yes) accepted as a no-op; reserved
  case "$1" in
    --keys-file) CMA_KEYS_FILE="$2"; shift 2 ;;
    --no-verify) NO_VERIFY=1; shift ;;
    --offline) OFFLINE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --unresolved) PRUNE_UNRESOLVED=1; shift ;;
    --refresh-aliases) REFRESH_ALIASES=1; shift ;;
    --quiet) QUIET=1; shift ;;
    --multi) MULTI=1; shift ;;
    --include-paid) INCLUDE_PAID=1; shift ;;
    --max-aliases) MAX_ALIASES="$2"; shift 2 ;;
    --min-score) MIN_SCORE="$2"; shift 2 ;;
    --verify-concurrency) VERIFY_CONCURRENCY="$2"; shift 2 ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

# Source-guard the executable entrypoint so the module can be sourced (for unit
# tests / to call detect_helixagent_record directly) WITHOUT running dispatch.
# Under normal execution BASH_SOURCE[0] == $0 (both the script path) so this is a
# no-op for real invocations; when sourced, $0 is the caller so this guard skips
# ONLY the --refresh-aliases fast path + the final SUBCMD dispatch (case) below —
# the function definitions above AND the top-level arg-parsing loop (which sets
# SUBCMD/POSITIONAL/flags from whatever "$@" the sourcing context had) still run
# unconditionally either way.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

# --refresh-aliases: rebuild every provider's alias shell line from its cached
# env file — NO network, NO probe. This is the session hook's fast path (run on
# each interactive shell start). Runs before dispatch so `list --refresh-aliases`
# refreshes then exits without printing the (verified-only) list.
if (( REFRESH_ALIASES )); then
  _rpdir="$(cma_providers_dir)"
  if [[ -d "$_rpdir" ]] && compgen -G "$_rpdir/*.env" >/dev/null; then
    for _rf in "$_rpdir"/*.env; do
      # shellcheck disable=SC1090
      _rid="$( ( set -a; . "$_rf"; set +a; printf '%s' "${CMA_PROVIDER_ID:-}" ) )"
      # shellcheck disable=SC1090
      _ral="$( ( set -a; . "$_rf"; set +a; printf '%s' "${CMA_PROVIDER_ALIAS:-}" ) )"
      [[ -n "$_rid" ]] || continue
      [[ -n "$_ral" ]] || _ral="$_rid"
      cma_provider_write_alias "$_ral" "$_rid" 2>/dev/null || true
    done
  fi
  (( QUIET )) || cma_log "refreshed provider aliases from cache (no network)"
  exit 0
fi

case "$SUBCMD" in
  # Default sync = single-alias sync, THEN the per-model multi phase
  # (free-tier only unless --include-paid) — ATM-860 D14 wiring: the multi
  # pipeline is no longer reachable only through the opt-in --multi flag
  # (§11.4.196(F) CONFIGURED != IN USE). `sync --multi` runs ONLY the
  # per-model phase (its pre-D14 shape); CMA_SYNC_MULTI=0 restores the
  # legacy single-alias-only default.
  sync)        if (( MULTI )); then cmd_sync_multi "${POSITIONAL[@]:-}"
               else
                 cmd_sync "${POSITIONAL[0]:-}"
                 if (( CMA_SYNC_MULTI )) && [[ -z "${POSITIONAL[0]:-}" ]]; then cmd_sync_multi; fi
               fi ;;
  list)        cmd_list ;;
  list-all)    cmd_list_all ;;
  list-faulty) cmd_list_faulty ;;
  show)        cmd_show "${POSITIONAL[@]:-}" ;;
  verify)      cmd_verify "${POSITIONAL[@]:-}" ;;
  remove)      cmd_remove "${POSITIONAL[@]:-}" ;;
  prune)       cmd_prune ;;
  add)         cmd_add "${POSITIONAL[@]:-}" ;;
esac

fi  # end source-guard (BASH_SOURCE == $0)
