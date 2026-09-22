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
#   sync-all-llmctl   deterministic one-by-one sweep: switches the local
#                     llmctl orchestrator through EVERY catalog profile
#                     (discovered live, never hardcoded), verifying each and
#                     reporting PASS/FAIL/GATED per profile
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
MODEL_VERIFY="${CMA_PROVIDERS_MODEL_VERIFY:-$LIB_DIR/model_verify.py}"
PROVIDERS_GENERATE="${CMA_PROVIDERS_GENERATE:-$LIB_DIR/providers_generate.py}"
# key-aliases.json / overrides.json / legacy-renames.json are operator-editable
# data files AND, for the Kimi kimi-* -> kc-* rename, are rewritten in place
# once by cmd_migrate_names. They are made env-overridable (`:=`, cma_alias-style)
# so the hermetic test suite can point them at sandbox copies — otherwise a sync
# inside a test would rewrite the TRACKED repo files.
KEY_ALIASES="${CMA_PROVIDERS_KEY_ALIASES:-$LIB_DIR/providers/key-aliases.json}"
OVERRIDES="${CMA_PROVIDERS_OVERRIDES:-$LIB_DIR/providers/overrides.json}"
LEGACY_RENAMES="${CMA_PROVIDERS_LEGACY_RENAMES:-$LIB_DIR/providers/legacy-renames.json}"
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
# Per-provider Kimi Code twin aliases (`kimi-<id>` -> `cma_run_kimi_provider`).
# On by default; --no-kimi-aliases turns emission off for a run (existing twins
# are only ever removed by `remove`/`prune`, never silently dropped).
: "${KIMI_ALIASES:=1}"
# Per-provider Pi CLI twin aliases (`pi-<id>` -> `cma_run_pi_provider`), mirrors
# KIMI_ALIASES immediately above. Root-caused via an independent deterministic-
# validation audit, 2026-09-17: unlike KIMI_ALIASES, this had NO top-level
# default - only a local `: "${PI_ALIASES:=1}"` inside ONE function
# (cmd_sync's own multi-sync leg, :2815), so any OTHER function referencing
# `(( PI_ALIASES ))` before that one ever ran in the same process - e.g.
# cmd_helixllm_export's --apply path at :2971 - hit a real "PI_ALIASES: unbound
# variable" crash under this script's own `set -u`. Confirmed live: this was
# the SOLE root cause of 26 real test failures across
# test_helixllm_model_export.sh (25) and test_kimi_wire_and_status_freshness.sh
# (1) - every one of them traced to this exact line via the real captured
# evidence in scripts/tests/proof/97-helixllm-model-export.txt.
: "${PI_ALIASES:=1}"

# shellcheck disable=SC2034  # ASSUME_YES reserved for --yes prompt suppression (not yet wired into cmds)
NO_VERIFY=0 OFFLINE=0 DRY_RUN=0 ASSUME_YES=0 MULTI=0
REFRESH_ALIASES=0 QUIET=0 PRUNE_UNRESOLVED=0
# helixllm-export: --apply writes the configuration; --host adds an endpoint.
# Declared here (not lazily) so `${#HELIXLLM_HOST_ARGS[@]}` is safe under set -u.
APPLY=0
HELIXLLM_HOST_ARGS=()
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
  migrate-names        one-time, idempotent rename of legacy Kimi provider ids
                       (kimi-for-coding/kimi-k3/... -> kc-*), per
                       providers/legacy-renames.json: status record, env, token
                       snapshot, config dir, alias-file line, key-aliases value,
                       overrides key. Runs automatically at the front of every
                       sync; execute directly to run it standalone
                       (--dry-run previews exactly what would change)
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
  helixllm-export [--host URL]... [--apply]
                       obtain the HelixLLM provider configuration ON DEMAND:
                       enumerate every configured host's live /v1/models and
                       report ONE option per model per host, writing the
                       catalogue to providers/helixllm-models.json. Hosts that
                       do not answer contribute nothing. Re-running UPDATES the
                       catalogue rather than duplicating it. Nothing else is
                       touched unless you pass --apply, which then makes your
                       configuration match the catalogue.

Options:
  --keys-file PATH     keys file to read var names from (default: \$CMA_KEYS_FILE or ~/api_keys.sh)
  --no-verify          skip LLMsVerifier/HTTP verification (aliases still created)
  --offline            do not fetch models.dev; require the local cache
  --dry-run            print what would change; write nothing
  --unresolved         with prune: also remove UNRESOLVED orphans (has a
                       *.env but no longer resolves) — without this flag,
                       prune only ever auto-removes status-only orphans
  --multi              with sync: run ONLY the per-model multi-alias phase
--kimi-aliases       emit the Kimi Code twin aliases (kimi-<id>) + config.toml
                        for every provider alias (default ON; harmless no-op for
                        kc-*/kimi-* ids). Env: KIMI_ALIASES=0
  --no-kimi-aliases    skip Kimi twin emission for this run (does not remove
                        already-emitted twins)
  --pi-aliases         emit the Pi CLI twin aliases (pi-<id>) + config.toml
                        for every provider alias (default ON; harmless no-op for
                        pi-*/kimi-*/kc-* ids). Env: PI_ALIASES=0
  --no-pi-aliases      skip Pi twin emission for this run (does not remove
                        already-emitted twins)
  --host URL           with helixllm-export: a serving endpoint to enumerate
                       (repeatable). Default: \$CMA_HELIXLLM_HOSTS, else the
                       hosts/base_url pinned in providers/helixllm-gateway.json
  --apply              with helixllm-export: make your configuration MATCH the
                       catalogue — write the provider env + alias records, and
                       retire the ones their host is demonstrably no longer
                       serving (config dir backed up, never deleted). A record
                       is retired ONLY when its host named other models it IS
                       serving without naming this one; a host that is
                       unreachable, or that replies while naming nothing it
                       serves (how one answers while its backend is still
                       loading), is reported and its records are KEPT.
                       Without it, nothing else is modified. Combine with
                       --dry-run to preview both halves.
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
  # is registered from TRACKED config (base_url -> the HelixAgent OpenAI-compatible server 127.0.0.1:7061, strong/fast ->
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
  : "${CMA_HELIXAGENT_HOST:=127.0.0.1}"
  : "${CMA_HELIXAGENT_PORT:=7061}"
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
# The HelixLLM Go binary serves an OpenAI-compatible /v1 for the cloud-fallback
# chain AND an Anthropic-compatible /v1/messages endpoint on the same host:port
# for the native transport. Both are registered as separate provider aliases so
# the operator can choose the CCR-routed chain OR the direct Anthropic-native
# path per session.
#
# helixllm-gateway: transport=router, base_url=<pin>/v1
# helixagent-native: transport=native, base_url=<pin>
# (Anthropic-compatible /v1/messages, bypasses CCR entirely)
#
# THE PORT AND SCHEME ARE NOT BAKED IN HERE (CONST-045 / §11.4.111 — resolve,
# never hardcode). They are RESOLVED, in this order:
#
#   process-env  CMA_HELIXLLM_GW_BASE_URL / CMA_HELIXLLM_NATIVE_BASE_URL
#   pins-file    providers/helixllm-gateway.json / providers/helixagent-native.json
#   built-in     the loopback default below
#
# The built-in default is `https://127.0.0.1:8443` — HelixLLM's real listener,
# measured with `ss -ltnp` on 2026-09-03, serving TLS with a self-signed cert
# (plain http on that port answers "Client sent an HTTP request to an HTTPS
# server"). The previous default was `http://127.0.0.1:18435`, and it was not
# an invented port: :18435 is the TEI embeddings container and :18434 the
# llama.cpp coder container, so each old value named a REAL port belonging to a
# DIFFERENT service — and both were DOWN when measured, so every probe returned
# curl exit 7 / HTTP 000. Either way both aliases could never reach `verified`,
# and `claude-providers list` — which shows only verified providers — never
# displayed them at all. A self-signed
# endpoint additionally needs the probe to be told which CA to trust; see
# CMA_PROVIDER_CA_CERT in providers-verify.sh.
#
# Both aliases share the same upstream binary; two records are emitted so the
# sync pipeline creates two distinct aliases.
# --- facade model resolution (the fix for the invented `helixllm-multi` pin) --
#
# These four helpers answer ONE question for the two facade aliases: what model
# name should this alias carry? The old answer was a constant written into the
# tracked pins files, and it named nothing (see the block inside
# detect_helixllm_records). The new answer is measured.
#
# --- local llama.cpp coder endpoint (the third local service) ---------------
#
# WHY THIS IS A DETECTOR AND NOT AN EXTENSION OF `helixllm-export`.
#
# The coder container on :18434 is a RAW llama.cpp server, not a HelixLLM. Its
# /v1/models entries carry no `model_identity`, and `helixllm-export` refuses
# them for exactly that reason — see _CMA_HELIXLLM_SERVING_JQ: a missing
# identity is how a REMOTE VENDOR PASSTHROUGH is told apart from a
# locally-served HelixLLM model, and exporting a passthrough as a local
# provider would point an alias at a model the host does not serve. Relaxing
# that gate to admit :18434 would not be "extending the generator"; it would
# delete the one signal that keeps the export honest, in order to admit a
# service the export was never about. The refusal is correct and stays.
#
# The right seam is the one the other two local services already use: a
# pins-file-gated detector merged into resolve_records, which then gets the
# same env/alias/verify loop as every other provider. This is that, for the
# third service.
#
# WHAT IS RESOLVED RATHER THAN DECLARED (the lesson from `helixllm-multi`):
# BOTH the model id AND the context window come from the endpoint's own
# /v1/models. llama.cpp publishes `meta.n_ctx` per model — measured 2026-09-07,
# qwen2.5-coder-3b-instruct-q4_k_m reports n_ctx 32768 — so the context guard
# is sourced from the backend rather than being a number someone typed. When
# the host cannot be asked, NOTHING is emitted: no invented name, no invented
# ceiling.
detect_helixcoder_record() {
  local _json="${CMA_HELIXCODER_PINS_FILE:-$LIB_DIR/providers/helixcoder.json}"
  local _bin="${CMA_HELIXCODER_BIN-}" _id="${CMA_HELIXCODER_ID-}" \
        _base="${CMA_HELIXCODER_BASE_URL-}" _transport="${CMA_HELIXCODER_TRANSPORT-}" \
        _strong="${CMA_HELIXCODER_STRONG-}" _fast="${CMA_HELIXCODER_FAST-}" \
        _keyvar="${CMA_HELIXCODER_KEYVAR-}" _ctx="${CMA_HELIXCODER_CONTEXT_LIMIT-}" \
        _out="${CMA_HELIXCODER_MAX_OUTPUT-}"
  if [[ -f "$_json" ]] && command -v jq >/dev/null 2>&1; then
    local _k _v
    while IFS=$'\t' read -r _k _v; do
      case "$_k" in
        bin)           [[ -n "${CMA_HELIXCODER_BIN+x}" ]]           || _bin="$_v" ;;
        id)            [[ -n "${CMA_HELIXCODER_ID+x}" ]]            || _id="$_v" ;;
        base_url)      [[ -n "${CMA_HELIXCODER_BASE_URL+x}" ]]      || _base="$_v" ;;
        transport)     [[ -n "${CMA_HELIXCODER_TRANSPORT+x}" ]]     || _transport="$_v" ;;
        strong_model)  [[ -n "${CMA_HELIXCODER_STRONG+x}" ]]        || _strong="$_v" ;;
        fast_model)    [[ -n "${CMA_HELIXCODER_FAST+x}" ]]          || _fast="$_v" ;;
        key_var)       [[ -n "${CMA_HELIXCODER_KEYVAR+x}" ]]        || _keyvar="$_v" ;;
        context_limit) [[ -n "${CMA_HELIXCODER_CONTEXT_LIMIT+x}" ]] || _ctx="$_v" ;;
        max_output)    [[ -n "${CMA_HELIXCODER_MAX_OUTPUT+x}" ]]    || _out="$_v" ;;
      esac
    done < <(jq -r 'to_entries[] | [.key, (.value|tostring)] | @tsv' "$_json" 2>/dev/null)
  fi
  : "${_id:=helixcoder}"
  : "${_base:=http://127.0.0.1:18434/v1}"
  : "${_transport:=router}"
  : "${_keyvar:=HELIXCODER_API_KEY}"
  : "${_out:=4096}"

  # Opt-in, like the other two: a tracked pins file, or the binary on PATH.
  if [[ ! -f "$_json" ]] && { [[ -z "$_bin" ]] || ! command -v "$_bin" >/dev/null 2>&1; }; then
    printf '[]\n'; return 0
  fi
  command -v jq >/dev/null 2>&1 || { printf '[]\n'; return 0; }

  # Live enumeration. The key travels over stdin, never argv (§11.4.10); an
  # unauthenticated loopback listing is the normal shape here and sends none.
  local _body="" _t="${CMA_HELIXCODER_HTTP_TIMEOUT:-4}" _key=""
  if (( ! ${OFFLINE:-0} )) && command -v curl >/dev/null 2>&1; then
    [[ "$_keyvar" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && _key="${!_keyvar:-}"
    _body="$( { [[ -n "$_key" ]] && printf 'header = "Authorization: Bearer %s"\n' "$_key"; :; } \
              | curl -sf --max-time "$_t" --config - "${_base%/}/models" 2>/dev/null)" || _body=""
  fi
  local _ids=""
  [[ -n "$_body" ]] && _ids="$(jq -r '[.data[]?.id] | .[]?' <<<"$_body" 2>/dev/null)"
  if [[ -n "$_ids" ]]; then
    # A pinned model the host IS serving is kept; otherwise the host decides.
    if [[ -z "$_strong" ]] || ! printf '%s\n' "$_ids" | grep -qxF -- "$_strong"; then
      _strong="$(printf '%s\n' "$_ids" | head -n1)"
    fi
    printf '%s\n' "$_ids" | grep -qxF -- "${_fast:-}" 2>/dev/null || _fast="$_strong"
    # Context window from the backend's own metadata when it publishes one.
    local _live_ctx
    _live_ctx="$(jq -r --arg m "$_strong" '[.data[]? | select(.id==$m)
                   | (.meta.n_ctx // empty)] | .[0] // empty' <<<"$_body" 2>/dev/null)"
    [[ "$_live_ctx" =~ ^[0-9]+$ ]] && _ctx="$_live_ctx"
  fi
  : "${_fast:=$_strong}"
  # Same `skipped`-not-omitted rule as the HelixLLM facades: the endpoint
  # configuration is true even while the host is down, so the record travels and
  # stays inspectable, but without a nameable model it is not `resolved`, so
  # cmd_sync writes no alias and no env record for it.
  local _status="resolved" _reason
  _reason="local llama.cpp coder endpoint serving $_strong at ${_base%/}"
  if [[ -z "$_strong" ]]; then
    _status="skipped"
    _reason="$_base named no model and none is pinned, so there is nothing to point an alias at"
    cma_warn "helixcoder: '$_id' has an endpoint but no nameable model — $_reason"
  fi
  jq -n --arg keyvar "$_keyvar" --arg pid "$_id" --arg base "${_base%/}" \
        --arg transport "$_transport" --arg strong "$_strong" --arg fast "$_fast" \
        --arg status "$_status" --arg reason "$_reason" \
        --argjson ctx "${_ctx:-null}" --argjson out "${_out:-null}" \
    '[{key_var:$keyvar, classification:"llm", provider_id:$pid, alias:$pid,
       base_url:$base, transport:$transport, strong_model:$strong, fast_model:$fast,
       context_limit:$ctx, max_output:$out, status:$status, reason:$reason}]'
}
#
# They deliberately reuse the machinery the per-model fan-out already owns —
# _cma_helixllm_fetch_models, _CMA_HELIXLLM_SERVING_JQ, _cma_helixllm_catalogue,
# all defined further down this file — so "a model this host is serving" has ONE
# definition here and cannot drift into two that disagree. (Bash resolves
# function names at CALL time, so defining these before those is fine: nothing
# below runs until the whole file is sourced.)

# _cma_helixllm_listing_base BASE — the /v1 root whose /models lists this host.
# The gateway facade's base already ends in /v1; the native facade's base is the
# Anthropic-compatible root and does not. Measured on the live gateway:
# GET /models -> 404, GET /v1/models -> 200.
_cma_helixllm_listing_base() {
  local b="${1%/}"
  case "$b" in */v1) printf '%s' "$b" ;; *) printf '%s/v1' "$b" ;; esac
}

# _cma_helixllm_served_ids BASE KEYVAR — every model id this host says it is
# SERVING right now, one per line, sorted. Prints NOTHING when the host cannot
# be asked (offline, unreachable, non-2xx, not a model listing) — "cannot be
# asked" and "serves nothing" both correctly yield no ids here, and the caller
# treats both as "the live tier could not answer" rather than as a withdrawal.
#
# Memoised on the listing base: both facades front the same upstream, so a sync
# asks once, not four times (strong + fast per facade). The lookup timeout is
# deliberately shorter than the export path's — this runs on every sync,
# including the background one lib.sh fires, and a hung host must not stretch it.
_CMA_HELIXLLM_SERVED_MEMO_KEY=""
_CMA_HELIXLLM_SERVED_MEMO_VAL=""
_cma_helixllm_served_ids() {
  local base; base="$(_cma_helixllm_listing_base "$1")"
  local keyvar="${2:-}"
  (( ${OFFLINE:-0} )) && return 0
  command -v curl >/dev/null 2>&1 || return 0
  command -v jq   >/dev/null 2>&1 || return 0
  if [[ "$_CMA_HELIXLLM_SERVED_MEMO_KEY" == "$base" ]]; then
    printf '%s' "$_CMA_HELIXLLM_SERVED_MEMO_VAL"; return 0
  fi
  # `local` is dynamically scoped in bash, so this bounds the fetch below
  # without mutating the caller's environment or the export path's timeout.
  local CMA_HELIXLLM_HTTP_TIMEOUT="${CMA_HELIXLLM_FACADE_TIMEOUT:-4}"
  local body ids=""
  if body="$(_cma_helixllm_fetch_models "$base" "$keyvar")"; then
    ids="$(jq -r '.data[]? | '"$_CMA_HELIXLLM_SERVING_JQ"' | .id' <<<"$body" 2>/dev/null | sort)"
  fi
  _CMA_HELIXLLM_SERVED_MEMO_KEY="$base"; _CMA_HELIXLLM_SERVED_MEMO_VAL="$ids"
  printf '%s' "$ids"
}

# _cma_helixllm_catalogue_model BASE — the id the LAST successful live listing
# recorded for this host, from the catalogue `helixllm-export` writes. Real
# measured data with a timestamp, not a literal anyone typed, which is why it
# outranks an unproven pins-file value when the host cannot be reached now.
_cma_helixllm_catalogue_model() {
  local base; base="$(_cma_helixllm_listing_base "$1")"
  local f; f="$(_cma_helixllm_catalogue)"
  [[ -s "$f" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r --arg b "$base" '[(.entries // [])[]
                          | select((.base_url // "") == $b) | .id]
                         | sort | .[0] // empty' "$f" 2>/dev/null
}

# _cma_helixllm_facade_model BASE KEYVAR PINNED ENV_PINNED — the model name a
# facade alias should carry, or empty when none can be named. Precedence:
#
#   1. A process-env pin (CMA_HELIXLLM_GW_STRONG / _FAST, CMA_HELIXLLM_NATIVE_*).
#      The operator naming a model explicitly is never second-guessed, even if
#      the host does not list it — they may know something the listing omits.
#   2. The live listing, when the host answered with something it is serving:
#      2a. a pins-file value the host IS serving wins (stable across runs, and
#          it keeps an operator's deliberate choice among several models);
#      2b. otherwise the host is serving something ELSE, and what it serves
#          wins. THIS IS THE FIX. The old behaviour — a pinned name surviving a
#          live listing that does not contain it — is precisely what let
#          `helixllm-multi` persist through every sync while returning 503.
#          A pin is a preference, not a fact; the serving layer is the fact.
#   3. The catalogue: the last listing this toolkit actually measured. Used
#      when the host cannot be asked, so a briefly-down gateway does not lose
#      its facades (the same "unreachable is not withdrawn" rule the retirement
#      sweep is built around).
#   4. A pins-file literal, unproven by anything. Last, and only because an
#      operator who put it there gets it back when nothing better is known.
#   5. Nothing. The caller does not emit the record.
_cma_helixllm_facade_model() {
  local base="$1" keyvar="${2:-}" pinned="${3:-}" env_pinned="${4:-0}"
  if (( env_pinned )) && [[ -n "$pinned" ]]; then printf '%s' "$pinned"; return 0; fi
  local ids; ids="$(_cma_helixllm_served_ids "$base" "$keyvar")"
  if [[ -n "$ids" ]]; then
    if [[ -n "$pinned" ]] && printf '%s\n' "$ids" | grep -qxF -- "$pinned"; then
      printf '%s' "$pinned"; return 0
    fi
    printf '%s\n' "$ids" | head -n1 | tr -d '\n'; return 0
  fi
  local cached; cached="$(_cma_helixllm_catalogue_model "$base")"
  if [[ -n "$cached" ]]; then printf '%s' "$cached"; return 0; fi
  printf '%s' "$pinned"
}

detect_helixllm_records() {
  local _ljson="${CMA_HELIXLLM_PINS_FILE:-$LIB_DIR/providers/helixllm-gateway.json}"
  local _njson="${CMA_HELIXLLM_NATIVE_PINS_FILE:-$LIB_DIR/providers/helixagent-native.json}"

  # --- helixllm-gateway pins ------------------------------------------------
  # PRECEDENCE, made real. The comment above has always PROMISED process-env >
  # pins-file > default, but the loader used to assign from the file
  # UNCONDITIONALLY, so a CMA_HELIXLLM_GW_* export was silently ignored
  # whenever the tracked pins file existed — which is always. Each local is
  # therefore seeded from its documented env var, and every pins-file arm is
  # guarded on that var's PRESENCE (`+x`, so an intentional empty export still
  # counts as "set"), matching detect_helixagent_record's loader exactly.
  local _lgw_bin="${CMA_HELIXLLM_GW_BIN-}" _lgw_id="${CMA_HELIXLLM_GW_ID-}" \
        _lgw_base="${CMA_HELIXLLM_GW_BASE_URL-}" _lgw_transport="${CMA_HELIXLLM_GW_TRANSPORT-}" \
        _lgw_strong="${CMA_HELIXLLM_GW_STRONG-}" _lgw_fast="${CMA_HELIXLLM_GW_FAST-}" \
        _lgw_keyvar="${CMA_HELIXLLM_GW_KEYVAR-}" _lgw_ctx="${CMA_HELIXLLM_GW_CONTEXT_LIMIT-}" \
        _lgw_out="${CMA_HELIXLLM_GW_MAX_OUTPUT-}"
  if [[ -f "$_ljson" ]] && command -v jq >/dev/null 2>&1; then
    local _k _v
    while IFS=$'\t' read -r _k _v; do
      case "$_k" in
        bin)           [[ -n "${CMA_HELIXLLM_GW_BIN+x}" ]]           || _lgw_bin="$_v" ;;
        id)            [[ -n "${CMA_HELIXLLM_GW_ID+x}" ]]            || _lgw_id="$_v" ;;
        base_url)      [[ -n "${CMA_HELIXLLM_GW_BASE_URL+x}" ]]      || _lgw_base="$_v" ;;
        transport)     [[ -n "${CMA_HELIXLLM_GW_TRANSPORT+x}" ]]     || _lgw_transport="$_v" ;;
        strong_model)  [[ -n "${CMA_HELIXLLM_GW_STRONG+x}" ]]        || _lgw_strong="$_v" ;;
        fast_model)    [[ -n "${CMA_HELIXLLM_GW_FAST+x}" ]]          || _lgw_fast="$_v" ;;
        key_var)       [[ -n "${CMA_HELIXLLM_GW_KEYVAR+x}" ]]        || _lgw_keyvar="$_v" ;;
        context_limit) [[ -n "${CMA_HELIXLLM_GW_CONTEXT_LIMIT+x}" ]] || _lgw_ctx="$_v" ;;
        max_output)    [[ -n "${CMA_HELIXLLM_GW_MAX_OUTPUT+x}" ]]    || _lgw_out="$_v" ;;
      esac
    done < <(jq -r 'to_entries[] | [.key, (.value|tostring)] | @tsv' "$_ljson" 2>/dev/null)
  fi
  # Defaults (only used when neither the env nor the pins file supplied a value)
  #
  # THERE IS DELIBERATELY NO DEFAULT MODEL NAME HERE. There used to be:
  # `helixllm-multi`, for strong AND fast, on BOTH facades, in the pins files
  # and again as the built-in `:=` fallback. It was never a model any HelixLLM
  # served — `grep -rn helixllm-multi submodules/helix_llm` returns ZERO hits —
  # it was invented when these aliases were first added (8695577) and nothing
  # downstream could tell. Measured 2026-09-07 against the live gateway:
  #
  #   POST https://127.0.0.1:8443/v1/chat/completions {"model":"helixllm-multi"}
  #     -> HTTP 503 "no model-serving backend is currently available"
  #   POST     (same second, an id from that host's own /v1/models)
  #     -> HTTP 200
  #
  # So both facades carried a name the endpoint refuses: neither could ever
  # reach `verified`, and `claude-providers list` — which shows only verified
  # providers — never displayed either of them. That is the dead-PORT defect
  # documented above, one field over, and it is fixed the same way it was: by
  # MEASURING. The model is RESOLVED from the host's own /v1/models listing
  # (CONST-036 — the serving layer is the single source of truth for what it
  # serves), never guessed, never baked in. See _cma_helixllm_facade_model for
  # the precedence. When nothing can name a model the record is NOT emitted,
  # because an alias pinned to an unservable name is worse than no alias.
  : "${_lgw_bin:=helixllm}"
  : "${_lgw_id:=helixllm-gateway}"
  : "${_lgw_base:=https://127.0.0.1:8443/v1}"
  : "${_lgw_transport:=router}"
  : "${_lgw_keyvar:=HELIXLLM_GATEWAY_KEY}"
  # 32768, not the 229376 that used to sit here. That number was a second,
  # quieter copy of an advertisement no HelixLLM backend can honour: measured
  # 2026-09-07, the model this gateway fronts publishes n_ctx = 32768 (and
  # n_ctx_train = 32768) on its own /v1/models, and the gateway refuses larger
  # prompts with HTTP 413 rather than silently truncating them. Advertising 7x
  # the real ceiling makes the auto-compact guard (CLAUDE_CODE_AUTO_COMPACT_WINDOW,
  # which is built from this value) compact far too late, so a session walks
  # into a hard refusal it was told could not happen. The gateway does not
  # publish a context field of its own; when it does, source this from the
  # listing instead of carrying it here.
  : "${_lgw_ctx:=32768}"
  : "${_lgw_out:=8192}"
  # Was the model PINNED by the process environment? Recorded before resolution
  # so an explicit operator pin (tier 1, never second-guessed) stays
  # distinguishable from a pins-file value, which is honoured only when the host
  # is actually serving it.
  local _lgw_envpin=0 _lgw_envpin_fast=0
  [[ -n "${CMA_HELIXLLM_GW_STRONG+x}" ]] && _lgw_envpin=1
  [[ -n "${CMA_HELIXLLM_GW_FAST+x}"   ]] && _lgw_envpin_fast=1
  _lgw_strong="$(_cma_helixllm_facade_model "$_lgw_base" "$_lgw_keyvar" "$_lgw_strong" "$_lgw_envpin")"
  _lgw_fast="$(_cma_helixllm_facade_model   "$_lgw_base" "$_lgw_keyvar" "${_lgw_fast:-$_lgw_strong}" "$_lgw_envpin_fast")"
  : "${_lgw_fast:=$_lgw_strong}"

  # --- helixagent-native pins -----------------------------------------------
  # Same precedence, same reason, CMA_HELIXLLM_NATIVE_* prefix (the one already
  # used by CMA_HELIXLLM_NATIVE_PINS_FILE above).
  local _lnat_bin="${CMA_HELIXLLM_NATIVE_BIN-}" _lnat_id="${CMA_HELIXLLM_NATIVE_ID-}" \
        _lnat_base="${CMA_HELIXLLM_NATIVE_BASE_URL-}" _lnat_transport="${CMA_HELIXLLM_NATIVE_TRANSPORT-}" \
        _lnat_strong="${CMA_HELIXLLM_NATIVE_STRONG-}" _lnat_fast="${CMA_HELIXLLM_NATIVE_FAST-}" \
        _lnat_keyvar="${CMA_HELIXLLM_NATIVE_KEYVAR-}" _lnat_ctx="${CMA_HELIXLLM_NATIVE_CONTEXT_LIMIT-}" \
        _lnat_out="${CMA_HELIXLLM_NATIVE_MAX_OUTPUT-}"
  if [[ -f "$_njson" ]] && command -v jq >/dev/null 2>&1; then
    local _k _v
    while IFS=$'\t' read -r _k _v; do
      case "$_k" in
        bin)           [[ -n "${CMA_HELIXLLM_NATIVE_BIN+x}" ]]           || _lnat_bin="$_v" ;;
        id)            [[ -n "${CMA_HELIXLLM_NATIVE_ID+x}" ]]            || _lnat_id="$_v" ;;
        base_url)      [[ -n "${CMA_HELIXLLM_NATIVE_BASE_URL+x}" ]]      || _lnat_base="$_v" ;;
        transport)     [[ -n "${CMA_HELIXLLM_NATIVE_TRANSPORT+x}" ]]     || _lnat_transport="$_v" ;;
        strong_model)  [[ -n "${CMA_HELIXLLM_NATIVE_STRONG+x}" ]]        || _lnat_strong="$_v" ;;
        fast_model)    [[ -n "${CMA_HELIXLLM_NATIVE_FAST+x}" ]]          || _lnat_fast="$_v" ;;
        key_var)       [[ -n "${CMA_HELIXLLM_NATIVE_KEYVAR+x}" ]]        || _lnat_keyvar="$_v" ;;
        context_limit) [[ -n "${CMA_HELIXLLM_NATIVE_CONTEXT_LIMIT+x}" ]] || _lnat_ctx="$_v" ;;
        max_output)    [[ -n "${CMA_HELIXLLM_NATIVE_MAX_OUTPUT+x}" ]]    || _lnat_out="$_v" ;;
      esac
    done < <(jq -r 'to_entries[] | [.key, (.value|tostring)] | @tsv' "$_njson" 2>/dev/null)
  fi
  : "${_lnat_bin:=helixllm}"
  : "${_lnat_id:=helixagent-native}"
  : "${_lnat_base:=https://127.0.0.1:8443}"
  : "${_lnat_transport:=native}"
  : "${_lnat_keyvar:=HELIXLLM_GATEWAY_KEY}"
  # Same measured ceiling as the gateway — same upstream. See the note above.
  : "${_lnat_ctx:=32768}"
  : "${_lnat_out:=8192}"
  # Same model-reality resolution as the gateway above, same reason. The native
  # base_url has no `/v1` suffix (it is the Anthropic-compatible root), and the
  # model listing lives one level down at `<base>/v1/models` — measured: GET
  # https://127.0.0.1:8443/models -> 404, /v1/models -> 200 — which is what
  # _cma_helixllm_listing_base normalises. Both facades front the SAME upstream,
  # so this is the same listing and the memo makes it one request.
  local _lnat_envpin=0 _lnat_envpin_fast=0
  [[ -n "${CMA_HELIXLLM_NATIVE_STRONG+x}" ]] && _lnat_envpin=1
  [[ -n "${CMA_HELIXLLM_NATIVE_FAST+x}"   ]] && _lnat_envpin_fast=1
  _lnat_strong="$(_cma_helixllm_facade_model "$_lnat_base" "$_lnat_keyvar" "$_lnat_strong" "$_lnat_envpin")"
  _lnat_fast="$(_cma_helixllm_facade_model   "$_lnat_base" "$_lnat_keyvar" "${_lnat_fast:-$_lnat_strong}" "$_lnat_envpin_fast")"
  : "${_lnat_fast:=$_lnat_strong}"

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

  # Emit TWO records — one for the CCR-routed gateway, one for the native path —
  # and mark a record whose model could NOT be named `skipped` rather than
  # `resolved`.
  #
  # WHY `skipped`, AND NOT "omit the record entirely".
  #
  # Omitting looked right at first, by analogy with the per-model fan-out below
  # ("a host that does not answer contributes NOTHING"). But the facades are not
  # the fan-out. A fan-out record IS a model. A facade record is the
  # CONFIGURATION of an endpoint — which port, which scheme, which key var,
  # which transport — and that configuration is true whether or not the host is
  # up this second. Omitting it conflates "this gateway is momentarily
  # unreachable" with "this gateway is not configured", and destroys the ability
  # to inspect or grade the endpoint at all while the host is down.
  # test_helix_endpoint_reality.sh exists to grade exactly those base_urls and
  # cannot grade a record that is not there — omitting broke ten of its
  # assertions, not one of which is about a model.
  #
  # `skipped` says both true things at once. It is a status the resolver already
  # emits and cmd_sync already handles, so the record travels (endpoint stays
  # visible and gradeable) while the sync loop's `[[ "$status" == "resolved" ]]`
  # guard means NO alias and NO env record is written from it. The invariant
  # that actually matters is intact — an alias is never created pointing at a
  # model name no endpoint accepts — and `reason` says why, in words.
  local _l_out="[]" _l_status="resolved" _n_status="resolved"
  if [[ -z "$_lgw_strong" ]]; then
    _l_status="skipped"
    _l_reason="no model could be named for $_lgw_base — the host named none it is serving, nothing was exported into the model catalogue, and nothing is pinned. Run 'claude-providers helixllm-export' once the gateway is serving, or pin one with CMA_HELIXLLM_GW_STRONG."
    cma_warn "helixllm: '$_lgw_id' has an endpoint but no nameable model — $_l_reason"
  fi
  if [[ -z "$_lnat_strong" ]]; then
    _n_status="skipped"
    _n_reason="no model could be named for $_lnat_base (see the note for '$_lgw_id'; pin one with CMA_HELIXLLM_NATIVE_STRONG if you know it)."
    cma_warn "helixllm: '$_lnat_id' has an endpoint but no nameable model — $_n_reason"
  fi
  _l_out="$(jq -cn \
    --arg gw_keyvar "$_lgw_keyvar" --arg gw_pid "$_lgw_id" --arg gw_alias "$_lgw_id" \
    --arg gw_base "$_lgw_base" --arg gw_transport "$_lgw_transport" \
    --arg gw_strong "$_lgw_strong" --arg gw_fast "$_lgw_fast" \
    --arg gw_reason "$_l_reason" --arg gw_status "$_l_status" \
    --argjson gw_ctx "${_lgw_ctx:-null}" --argjson gw_out "${_lgw_out:-null}" \
    --arg nat_keyvar "$_lnat_keyvar" --arg nat_pid "$_lnat_id" --arg nat_alias "$_lnat_id" \
    --arg nat_base "$_lnat_base" --arg nat_transport "$_lnat_transport" \
    --arg nat_strong "$_lnat_strong" --arg nat_fast "$_lnat_fast" \
    --arg nat_reason "$_n_reason" --arg nat_status "$_n_status" \
    --argjson nat_ctx "${_lnat_ctx:-null}" --argjson nat_out "${_lnat_out:-null}" \
    '[{key_var:$gw_keyvar, classification:"llm", provider_id:$gw_pid, alias:$gw_alias,
       base_url:$gw_base, transport:$gw_transport, strong_model:$gw_strong,
       fast_model:$gw_fast, context_limit:$gw_ctx, max_output:$gw_out,
       status:$gw_status, reason:$gw_reason},
      {key_var:$nat_keyvar, classification:"llm", provider_id:$nat_pid, alias:$nat_alias,
       base_url:$nat_base, transport:$nat_transport, strong_model:$nat_strong,
       fast_model:$nat_fast, context_limit:$nat_ctx, max_output:$nat_out,
       status:$nat_status, reason:$nat_reason}]')"
  printf '%s\n' "$_l_out"
}

# --- HelixLLM per-model-per-host fan-out ------------------------------------
# detect_helixllm_records (above) registers the two FACADE aliases — one CCR
# routed, one Anthropic-native — and continues to do so unchanged. What it does
# NOT do is tell the operator which models are actually being served: both
# facade records carry a single pinned model name for the whole instance.
#
# The functions below EXTEND that with one record PER MODEL PER HOST, driven by
# each host's live OpenAI-compatible /v1/models listing (single source of truth,
# CONST-036 — no hardcoded model list).
#
# Two published fields make this possible, and the difference between them is
# load-bearing:
#
#   id              a derived, charset-safe identifier. This is the ONLY value
#                   used as a provider id / alias name / model name, because it
#                   is the only one that satisfies the toolkit's validators.
#   model_identity  the human-readable `helixllm/<host>/<model>[:<variant>]`.
#                   It contains `/` and `:`, which BOTH validators reject on
#                   purpose (the provider-id charset guard in lib.sh is a
#                   shell-injection control: the id is interpolated into the
#                   alias body and re-parsed when the alias is invoked). So the
#                   identity travels as a VALUE — a catalogue field and the
#                   record's `reason` — and NEVER becomes an identifier.
#                   Neither validator is widened to admit it (FR-014a).
#
# model_identity is also the availability signal: HelixLLM omits it for remote
# vendor models it merely proxies, so an entry without one is NOT a locally
# served model and is skipped. Exporting a vendor passthrough as a local
# provider would point an alias at a model this host does not serve.
#
# A host that does not answer, answers non-2xx, or answers something that is not
# a model listing contributes NOTHING — it is never written as available.

# _cma_helixllm_hosts — the base URLs to enumerate, one per line.
# Precedence: explicit --host args > $CMA_HELIXLLM_HOSTS (whitespace/comma
# separated) > the pins-file `hosts` array > the pins-file base_url > default.
# Nothing host-specific is baked in (CONST-045).
_cma_helixllm_hosts() {
  local h
  if (( ${#HELIXLLM_HOST_ARGS[@]} )); then
    printf '%s\n' "${HELIXLLM_HOST_ARGS[@]}"; return 0
  fi
  if [[ -n "${CMA_HELIXLLM_HOSTS:-}" ]]; then
    printf '%s\n' "${CMA_HELIXLLM_HOSTS//,/ }" | tr ' ' '\n' | while read -r h; do
      [[ -n "$h" ]] && printf '%s\n' "$h"
    done
    return 0
  fi
  local pins="${CMA_HELIXLLM_PINS_FILE:-$LIB_DIR/providers/helixllm-gateway.json}"
  if [[ -f "$pins" ]] && command -v jq >/dev/null 2>&1; then
    local from_file
    from_file="$(jq -r '(.hosts // []) | .[]?' "$pins" 2>/dev/null)"
    if [[ -n "$from_file" ]]; then printf '%s\n' "$from_file"; return 0; fi
    from_file="$(jq -r '.base_url // empty' "$pins" 2>/dev/null)"
    if [[ -n "$from_file" ]]; then printf '%s\n' "$from_file"; return 0; fi
  fi
  printf '%s\n' "https://127.0.0.1:8443/v1"
}

# _cma_helixllm_gateway_key KEYVAR — the gateway API key for $KEYVAR, or empty.
#
# WHY THIS IS THE GATEWAY KEY AND NOT THE DISCOVERY SECRET.
#
# An earlier revision sent $HELIXLLM_DISCOVERY_SECRET here as an
# `Authorization: Bearer` header. That was wrong on both counts, and the
# server's own code says so:
#
#   * `/v1/models` sits behind ONE authenticating middleware, APIKeyAuth, and
#     it compares the Bearer token against exactly one value set — the
#     comma-separated $HELIX_AUTH_API_KEYS list. Nothing else is accepted. So
#     with API-key auth switched on, a discovery secret presented as a Bearer
#     token is simply "invalid API key" -> 401 -> every host contributes
#     nothing and the export is honest-but-dead.
#
#   * The discovery secret is not an HTTP credential at all. No HTTP
#     middleware reads it. It is used by the discovery CLIENT to sign OUTBOUND
#     attestation requests to a different path entirely, via its own
#     nonce/proof header pair — never as a Bearer token. Sending it to
#     /v1/models therefore disclosed a fleet-wide trust credential to every URL
#     in $CMA_HELIXLLM_HOSTS / --host, none of which could ever use it. Since
#     the server's DEFAULT is open access ($HELIX_AUTH_API_KEYS empty), that
#     disclosure happened on the happy path, silently, while the export
#     appeared to work.
#
# So: send the credential this endpoint actually accepts, and stop sending the
# one it cannot. The gateway key is the SAME key the provider records written
# by --apply use at launch to talk to this very base_url, so no new trust
# relationship is created by asking for the model list with it.
#
# Lookup order: the process environment, then the toolkit's keys file (the
# canonical non-secret-in-repo store every other provider's key comes from).
# The value is returned on stdout for one purpose only: to be piped into
# `curl --config -` as an Authorization header. It is NEVER placed on argv
# (where it would appear in /proc/<pid>/cmdline and `ps aux`), NEVER logged, and
# NEVER written to any generated file (§11.4.10).
_cma_helixllm_gateway_key() {
  local var="${1:-}" v=""
  # Indirect expansion below reads ${!var}; keep the name to a shell-variable
  # shape so a hostile pins file cannot point it at something surprising.
  [[ "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 0
  v="${!var:-}"
  if [[ -z "$v" && -n "${CMA_KEYS_FILE:-}" && -f "${CMA_KEYS_FILE:-}" ]]; then
    # Same keys-file read every other provider in this file uses: sourced in a
    # subshell so nothing leaks into this process's environment.
    # shellcheck disable=SC1090  # $CMA_KEYS_FILE is the user's runtime keys file
    v="$( ( set +e; set -a +u; . "$CMA_KEYS_FILE" >/dev/null 2>&1; set +a
            printf '%s' "${!var:-}" ) )" || true
  fi
  printf '%s' "$v"
}

# _cma_helixllm_id_safe — true when an id satisfies BOTH toolkit validators.
#
# These are the two rules from lib.sh, applied here LITERALLY so an id that
# fails either one is DROPPED rather than written. Copying the rules is the
# point: the alternative — relaxing a validator so a richer name fits — would
# trade a naming convenience for a shell-injection hole (FR-014a).
#
#   cma_validate_alias        ^[a-zA-Z][a-zA-Z0-9_-]*$
#   provider-id charset       [A-Za-z0-9._-] only, non-empty
_cma_helixllm_id_safe() {
  local id="$1"
  [[ "$id" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]] || return 1
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

# _cma_helixllm_fetch_models BASE [KEYVAR] — the raw /v1/models body, or nothing.
# Exit 1 (and print nothing) unless the host answered 2xx with a model listing:
# an unreachable or unhealthy instance must never be written as available.
#
# KEYVAR names the environment variable holding the gateway API key (the
# pins-file `key_var`, default HELIXLLM_GATEWAY_KEY). When no key is configured
# NO Authorization header is sent at all — which is the correct request for a
# HelixLLM running in its default open-access mode, and means this function
# never transmits a credential the endpoint has no use for. See
# _cma_helixllm_gateway_key for why this is the gateway key and not the
# discovery secret.
_cma_helixllm_fetch_models() {
  local base="${1%/}" keyvar="${2:-}" body="" t="${CMA_HELIXLLM_HTTP_TIMEOUT:-8}" key
  command -v curl >/dev/null 2>&1 || return 1
  command -v jq   >/dev/null 2>&1 || return 1
  key="$(_cma_helixllm_gateway_key "$keyvar")"
  # CA TRUST. A HelixLLM gateway on https with a self-signed certificate — the
  # default local shape, and now the pinned one — is rejected by curl at the
  # TLS layer, and `curl -sf` reports that EXACTLY as it reports an unreachable
  # host: non-zero, empty body. The host then contributes nothing to the export
  # while looking merely absent, which is the same conflation that made the
  # dead-port defect invisible. CMA_PROVIDER_CA_CERT (the same knob
  # providers-verify.sh reads) supplies the trust anchor.
  #
  # Both the cert path and the key travel over STDIN, never argv (§11.4.10).
  # An empty config is valid, so the keyed and keyless paths share one call.
  # A `"` in the path would break out of curl's quoted value, so it is refused.
  local _ca=""
  if [[ -n "${CMA_PROVIDER_CA_CERT:-}" ]] \
     && [[ -r "${CMA_PROVIDER_CA_CERT}" ]] \
     && [[ "${CMA_PROVIDER_CA_CERT}" != *'"'* ]] \
     && [[ "${CMA_PROVIDER_CA_CERT}" != *\\* ]] \
     && [[ "${CMA_PROVIDER_CA_CERT}" != *$'\n'* ]]; then
    _ca="${CMA_PROVIDER_CA_CERT}"
  fi
  body="$( { [[ -n "$_ca" ]] && printf 'cacert = "%s"\n' "$_ca"
             [[ -n "$key" ]] && printf 'header = "Authorization: Bearer %s"\n' "$key"
             :; } \
           | curl -sf --max-time "$t" --config - "$base/models" 2>/dev/null)" || return 1
  printf '%s' "$body" | jq -e '.data | type == "array"' >/dev/null 2>&1 || return 1
  printf '%s' "$body"
}

# _CMA_HELIXLLM_SERVING_JQ — the ONE definition of "this listing entry is a
# model this host is serving to us RIGHT NOW". Used both to build the records
# and to decide whether the host proved it is serving, so the two can never
# drift apart and disagree about the same listing.
#
# Two conditions, and the reason for each:
#
#   `model_identity` is non-empty  — the entry is a LOCALLY-served HelixLLM
#     model. Remote vendor passthroughs deliberately omit it, and they must not
#     count here: a remote provider stays reachable while the local backend is
#     down, so a listing of nothing but vendor models is exactly what a loading
#     host looks like. Counting it would put us straight back in the hole.
#
#   `availability` is "serving", or absent — the serving layer's own affirmative
#     report (pkg/api Model.Availability). Absent is accepted, but the reason
#     changed and the old one is no longer true. It used to be that the LISTING
#     ITSELF was the affirmative act: Brain.Models() dropped every unavailable
#     option before rendering, so anything reaching the wire was being served.
#     That stopped being so when the server began PUBLISHING withheld options
#     with `availability: "withheld"` and a reason — which is what lets us tell
#     a loading backend from a withdrawn model instead of inferring it from
#     silence. So absence now rests on one narrower argument only: a build old
#     enough to omit the field is also old enough that nothing unserved reached
#     its wire. An explicit value other than "serving" is honoured as the
#     stronger per-entry signal
#     and excluded — we never overrule the server saying no.
_CMA_HELIXLLM_SERVING_JQ='select((.model_identity // "") != "")
  | select((.availability // "serving") == "serving")'

# detect_helixllm_model_records — ONE `resolved`-shaped record PER MODEL PER
# HOST, in the exact schema providers_resolve.py produces (plus the identity
# and serving host as extra VALUE fields).
#
# Emits an ENVELOPE, not a bare array:
#
#   {"hosts_serving":             [<base_url>, ...],
#    "hosts_answered_not_serving":[<base_url>, ...],
#    "records":                   [<record>, ...]}
#
# The host lists are load-bearing and cannot be reconstructed from `records`:
# a host serving NOTHING is indistinguishable, by records alone, from a host
# that was unreachable. `--apply` needs to tell those apart before it removes
# anything. Emits an envelope with all three lists empty when nothing is
# reachable.
#
# WHY THE SPLIT IS "SERVING" vs "NOT SERVING" AND NOT "ANSWERED" vs "SILENT".
# An earlier revision recorded every host that returned a `data` array as
# `hosts_answered`, and let the retirement sweep treat that reply as licence to
# delete. That is a two-state model of a three-state world, and the third state
# is the common one: a HelixLLM whose gateway is up while its backend is still
# loading answers `200 {"data":[], "reason":...}` — /health is 503 during load,
# so the option is unavailable, so it is dropped from the listing. A reply that
# names NOTHING the host serves is not the serving layer telling us a model was
# withdrawn; it is the same "we cannot tell" an unreachable host gives us, and
# it must be reported and kept, never acted on. (The `reason` string that
# travels with the empty list does not rescue it: the server sends the same
# "a model-serving backend is configured but is currently serving no models"
# whether the backend is mid-load or has genuinely stopped serving everything,
# so it distinguishes neither.)
detect_helixllm_model_records() {
  command -v jq >/dev/null 2>&1 || {
    printf '{"hosts_serving":[],"hosts_answered_not_serving":[],"records":[]}\n'; return 0; }

  # Non-model fields come from the gateway pins (transport/key_var/limits),
  # with process-env overrides. base_url is per HOST, not from the pins.
  local pins="${CMA_HELIXLLM_PINS_FILE:-$LIB_DIR/providers/helixllm-gateway.json}"
  local transport="" keyvar="" ctx="" out=""
  if [[ -f "$pins" ]]; then
    transport="$(jq -r '.transport // empty'     "$pins" 2>/dev/null)"
    keyvar="$(  jq -r '.key_var // empty'        "$pins" 2>/dev/null)"
    ctx="$(     jq -r '.context_limit // empty'  "$pins" 2>/dev/null)"
    out="$(     jq -r '.max_output // empty'     "$pins" 2>/dev/null)"
  fi
  transport="${CMA_HELIXLLM_MODEL_TRANSPORT:-${transport:-router}}"
  keyvar="${CMA_HELIXLLM_MODEL_KEYVAR:-${keyvar:-HELIXLLM_GATEWAY_KEY}}"
  # Fallback only (the pins normally supply it). 32768 is the measured
  # ceiling of the backend these ids are served by; see detect_helixllm_records.
  ctx="${ctx:-32768}"; out="${out:-8192}"

  # HOW THE MODEL LISTING IS READ, AND WHY NOT @tsv.
  #
  # `@tsv` is an ESCAPING format: it rewrites a literal backslash in a value as
  # two characters, and a tab/newline/CR as the two-character sequences \t \n
  # \r. `read -r` then faithfully preserves whatever it was handed, so the
  # escaping is applied and never undone — a model identity of
  # `helixllm/h/org\llama3:8b` was being recorded as `helixllm/h/org\\llama3:8b`
  # in the catalogue and in the record's `reason`, and the server's own identity
  # parser treats `\` as its escape character, so the mangled string no longer
  # round-trips. (Forward slashes and colons are NOT escaped by @tsv, so the
  # ordinary `org/model` and `hf.co/...` shapes were never affected — this bit
  # only backslash-bearing and control-bearing names.)
  #
  # `jq -r` emits each string RAW, with no escaping whatsoever, so reading one
  # field per line round-trips a backslash exactly. The one hazard that buys is
  # a value containing a newline, which would desync the id/identity pairing —
  # so entries carrying ANY control character are rejected inside jq (via
  # `explode`) and reported, rather than silently mangled into a wrong name.
  # That matches the posture already taken for hostile ids just below: refuse
  # what we cannot represent faithfully; never quietly rewrite it.
  local recs="[]" serving="[]" not_serving="[]" base body host_label id identity one rejected
  while read -r base; do
    [[ -n "$base" ]] || continue
    body="$(_cma_helixllm_fetch_models "$base" "$keyvar")" || {
      cma_warn "helixllm: host $base did not answer with a model listing — no models exported from it"
      continue
    }
    # Did the host prove it is SERVING, or merely that it is up? Only the first
    # can license a removal downstream; see _CMA_HELIXLLM_SERVING_JQ.
    if jq -e '[.data[]? | '"$_CMA_HELIXLLM_SERVING_JQ"'] | length > 0' <<<"$body" >/dev/null 2>&1; then
      serving="$(jq -c --arg b "${base%/}" '. + [$b] | unique' <<<"$serving")"
    else
      not_serving="$(jq -c --arg b "${base%/}" '. + [$b] | unique' <<<"$not_serving")"
      cma_warn "helixllm: host $base replied, but its listing named no model it is serving$(
        jq -r 'if (.reason // "") != "" then " (it said: " + .reason + ")" else "" end' <<<"$body" 2>/dev/null
      ) — that is also what a host whose backend is still loading looks like, so nothing of its is treated as withdrawn"
    fi
    # Host label for FR-023 ("label every model with the host serving it").
    host_label="${base#*://}"; host_label="${host_label%%/*}"
    rejected="$(jq -r '.data[] | '"$_CMA_HELIXLLM_SERVING_JQ"'
                       | select((((.id // "") + .model_identity) | explode
                                 | map(select(. < 32)) | length) > 0)
                       | .id' <<<"$body" 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${rejected:-0}" != "0" ]]; then
      cma_warn "helixllm: dropped $rejected model listing(s) from $host_label whose id or identity contains a control character — such a name cannot be recorded faithfully, so it is refused rather than rewritten"
    fi
    while IFS= read -r id && IFS= read -r identity; do
      [[ -n "$id" && -n "$identity" ]] || continue
      if ! _cma_helixllm_id_safe "$id"; then
        cma_warn "helixllm: refusing a model id from $host_label — it does not satisfy the toolkit's identifier rules (the rules are not relaxed to fit a name)"
        continue
      fi
      one="$(jq -cn \
        --arg id "$id" --arg identity "$identity" --arg base "${base%/}" \
        --arg host "$host_label" --arg keyvar "$keyvar" --arg transport "$transport" \
        --argjson ctx "${ctx:-null}" --argjson out "${out:-null}" \
        '{key_var:$keyvar, classification:"llm", provider_id:$id, alias:$id,
          base_url:$base, transport:$transport, strong_model:$id, fast_model:$id,
          context_limit:$ctx, max_output:$out, status:"resolved",
          model_identity:$identity, serving_host:$host,
          reason:("HelixLLM model " + $identity + " served by " + $host)}')"
      recs="$(jq -c --argjson r "$one" '. + [$r]' <<<"$recs")"
    done < <(jq -r '.data[] | '"$_CMA_HELIXLLM_SERVING_JQ"'
                    | select((((.id // "") + .model_identity) | explode
                              | map(select(. < 32)) | length) == 0)
                    | (.id, .model_identity)' <<<"$body" 2>/dev/null)
  done < <(_cma_helixllm_hosts)

  # Dedupe by id: the same model reachable through two configured URLs for one
  # host is one option, not two.
  jq -c -n --argjson recs "$recs" --argjson serving "$serving" \
    --argjson notserving "$not_serving" \
    '{hosts_serving: $serving,
      hosts_answered_not_serving: $notserving,
      records: ($recs | group_by(.provider_id) | map(.[0]))}'
}

# _cma_helixllm_catalogue — where the exported per-model configuration lives.
_cma_helixllm_catalogue() { printf '%s/helixllm-models.json\n' "$(cma_providers_dir)"; }

# _cma_helixllm_catalogue_merge RECORDS_JSON — idempotent write (T048).
#
# The stable key is the published `id`: derived from the model's full canonical
# identity (which already includes the serving host), so it is unique per model
# per host AND stable across runs. Re-running therefore UPDATES the entry that
# already carries that id — first_seen is preserved, last_seen is bumped — and
# never appends a second copy of it.
#
# Entries whose host was not successfully queried this run are NOT carried
# forward: a model the serving layer is no longer offering must not keep being
# presented as available.
_cma_helixllm_catalogue_merge() {
  local records="$1" cat_file; cat_file="$(_cma_helixllm_catalogue)"
  local dir; dir="$(dirname "$cat_file")"; mkdir -p "$dir"
  local old='{"entries":[]}'
  [[ -f "$cat_file" ]] && old="$(jq -c '.' "$cat_file" 2>/dev/null || printf '{"entries":[]}')"
  local now; now="$(date -u +%FT%TZ)"
  local merged
  merged="$(jq --argjson new "$records" --arg now "$now" '
      ((.entries // []) | map({key: .id, value: .}) | from_entries) as $prev
      | { schema: 1, updated_at: $now,
          entries: ( $new
            | map({ id:             .provider_id,
                    model_identity: .model_identity,
                    host:           .serving_host,
                    base_url:       .base_url,
                    transport:      .transport,
                    key_var:        .key_var,
                    context_limit:  .context_limit,
                    max_output:     .max_output,
                    first_seen:     (($prev[.provider_id].first_seen) // $now),
                    last_seen:      $now })
            | sort_by(.id) ) }' <<<"$old")" || return 1
  # Atomic replace so a concurrent reader never sees a half-written catalogue.
  local tmp="$cat_file.tmp.$$"
  printf '%s\n' "$merged" > "$tmp" && mv -f "$tmp" "$cat_file"
}

# --- local Kimi Code OAuth PATH-detection -----------------------------------
# Kimi Code uses OAuth tokens (15-min expiry), not static API keys. The token
# lives in ~/.kimi-code/credentials/kimi-code.json. Gates on `command -v kimi`.
# The sentinel key_var _CMA_KIMICODE_OAUTH_ signals to both the verification
# path and the launch wrapper to read the token from the provider token file
# ($PROVIDER_DIR/<id>.token). Token is refreshed at sync time.
#
# Namespace (v1.27.0): the KIMI-* PROVIDER ids that used to be emitted here
# (kimi-for-coding, kimi-k3, ...) were vacated: `kimi-<id>` now means the Kimi
# CLI agent over a backend. Claude-over-Kimi providers therefore emit as kc-*
# (kc-for-coding, kc-k3, ...). The models.dev CATALOG key is upstream data and
# stays "kimi-for-coding"; only the emitted ids/aliases/token files are kc-*.
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
  # credentials file; these are only the last-resort fallback). Token files are
  # named after the EMITTED provider id (<id>.token), which is now kc-*.
  local tdir; tdir="$(cma_providers_dir)"; mkdir -p "$tdir"
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && ( umask 077; printf '%s' "$token" > "$tdir/$pid.token" ) || true
  done < <(jq -r 'def k($m): if $m == "kimi-for-coding" then "kc-for-coding"
                     elif ($m | startswith("kimi-")) then "kc-" + ($m | sub("^kimi-";""))
                     elif ($m | startswith("kc-")) then $m
                     else "kc-" + $m end;
                   .[] | k(.)' <<<"$models_json")

  # Emit ONE record per served model. Alias naming (v1.27.0): every emitted id
  # carries the vacated kimi-* namespace as kc-* — the account default becomes
  # 'kc-for-coding', ids already carrying the kimi- prefix keep it as kc-*, and
  # bare ids (k3, k2p7, ...) become kc-<id>. Context/output limits come from the
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
    def alias_for($m): if $m == "kimi-for-coding" then "kc-for-coding"
                       elif ($m | startswith("kimi-")) then "kc-" + ($m | sub("^kimi-";""))
                       elif ($m | startswith("kc-")) then $m
                       else "kc-" + $m end;
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

# --- Token Router multi-model detection ---------------------------------------
# Token Router serves 138+ models via an OpenAI-compatible endpoint (https://api.tokenrouter.com/v1).
# One API key (TOKENROUTER_API_KEY) maps to the entire catalog.
# Detection gates on the tracked pins file (providers/tokenrouter.json) AND the API key being present.
# The detector emits multiple provider records (tokenrouter1 through tokenrouterN) with distinct
# strong/fast model pairings spanning different capability profiles.
detect_tokenrouter_records() {
  local _tr_json="${CMA_TOKENROUTER_PINS_FILE:-$LIB_DIR/providers/tokenrouter.json}"
  [[ -f "$_tr_json" ]] || { printf '[]\n'; return 0; }

  local _key_present=0
  if [[ -f "$CMA_KEYS_FILE" ]]; then
    local _key_val
    # shellcheck source=/dev/null
    _key_val="$( ( set +e; set -a +u; . "$CMA_KEYS_FILE" 2>/dev/null; set +a; printf '%s' "${TOKENROUTER_API_KEY:-}" ) )" || true
    [[ -n "$_key_val" ]] && _key_present=1
  fi
  (( _key_present )) || { printf '[]\n'; return 0; }

  local _tr_base="" _tr_transport="" _tr_keyvar="" _tr_ctx="" _tr_out=""
  if command -v jq >/dev/null 2>&1; then
    local _k _v
    while IFS=$'\t' read -r _k _v; do
      case "$_k" in
        base_url)      _tr_base="$_v" ;;
        transport)     _tr_transport="$_v" ;;
        key_var)       _tr_keyvar="$_v" ;;
        context_limit) _tr_ctx="$_v" ;;
        max_output)    _tr_out="$_v" ;;
      esac
    done < <(jq -r 'to_entries[] | [.key, (.value|tostring)] | @tsv' "$_tr_json" 2>/dev/null)
  fi

  : "${_tr_base:=https://api.tokenrouter.com/v1}"
  : "${_tr_transport:=router}"
  : "${_tr_keyvar:=TOKENROUTER_API_KEY}"
  : "${_tr_ctx:=2000000}"
  : "${_tr_out:=131072}"

  local _reason="Token Router multi-alias detected via pins-file (138+ models, OpenAI-compatible)"

  # Fetch live models from Token Router API for dynamic model selection
  local _models_json=""
  if (( ! OFFLINE )); then
    _models_json="$(curl -s --max-time 15 \
      --config <(printf 'header = "Authorization: Bearer %s"\n' "$_key_val") \
      "$_tr_base/models" 2>/dev/null | jq -c '[.data[]?.id] | unique' 2>/dev/null)"
  fi
  [[ -z "$_models_json" || "$_models_json" == "[]" || "$_models_json" == "null" ]] && _models_json="[]"

  # Define model profiles based on capabilities and use cases
  # These profiles ensure we cover different use cases: best overall, coding, reasoning, fast/cheap, long-context
  jq -n \
    --arg keyvar "$_tr_keyvar" \
    --arg base    "$_tr_base" \
    --arg transport "$_tr_transport" \
    --arg reason  "$_reason" \
    --argjson models "$_models_json" \
    --argjson ctx "${_tr_ctx:-null}" \
    --argjson out "${_tr_out:-null}" \
    '[
      {
        key_var:             $keyvar,
        classification:      "llm",
        provider_id:         "tokenrouter",
        alias:               "tokenrouter",
        base_url:            $base,
        transport:           $transport,
        strong_model:        "anthropic/claude-opus-5",
        fast_model:          "deepseek/deepseek-v4.1-flash",
        context_limit:       $ctx,
        max_output:          $out,
        status:              "resolved",
        reason:              ($reason + " (flagship: Claude Opus 5 / DeepSeek V4.1 Flash)")
      },
      {
        key_var:             $keyvar,
        classification:      "llm",
        provider_id:         "tokenrouter-code",
        alias:               "tokenrouter-code",
        base_url:            $base,
        transport:           $transport,
        strong_model:        "moonshotai/kimi-k2.7-code",
        fast_model:          "qwen/qwen3-coder-next",
        context_limit:       $ctx,
        max_output:          $out,
        status:              "resolved",
        reason:              ($reason + " (coding: Kimi K2.7 Code / Qwen3 Coder Next)")
      },
      {
        key_var:             $keyvar,
        classification:      "llm",
        provider_id:         "tokenrouter-reasoning",
        alias:               "tokenrouter-reasoning",
        base_url:            $base,
        transport:           $transport,
        strong_model:        "anthropic/claude-sonnet-5",
        fast_model:          "google/gemini-3.5-flash",
        context_limit:       $ctx,
        max_output:          $out,
        status:              "resolved",
        reason:              ($reason + " (reasoning: Claude Sonnet 5 / Gemini 3.5 Flash)")
      },
      {
        key_var:             $keyvar,
        classification:      "llm",
        provider_id:         "tokenrouter-fast",
        alias:               "tokenrouter-fast",
        base_url:            $base,
        transport:           $transport,
        strong_model:        "deepseek/deepseek-v4.1-flash",
        fast_model:          "z-ai/glm-5.3-flash",
        context_limit:       $ctx,
        max_output:          $out,
        status:              "resolved",
        reason:              ($reason + " (fast/cheap: DeepSeek V4.1 Flash / GLM-5.3 Flash)")
      },
      {
        key_var:             $keyvar,
        classification:      "llm",
        provider_id:         "tokenrouter-long",
        alias:               "tokenrouter-long",
        base_url:            $base,
        transport:           $transport,
        strong_model:        "z-ai/glm-5.3",
        fast_model:          "nvidia/nemotron-3-super-120b-a12b",
        context_limit:       $ctx,
        max_output:          $out,
        status:              "resolved",
        reason:              ($reason + " (long-context: GLM-5.3 1M / Nemotron-3 Super 1M)")
      }
    ]'
}

# --- local llmctl PATH-detection (multi-profile, one record per RUNNING port) -
#
# llmctl (a sibling local-LLM orchestrator, github.com/.../llmctl) runs each
# catalog PROFILE as its OWN independent llama.cpp/colibri server process on a
# FIXED, catalog-assigned port (`llmctl plan --json` -> .profiles.<name>.port,
# llmctl/lib/catalog.sh `catalog_port` -- a per-profile constant; only WHICH
# profiles fit the host varies with hardware, WHERE a fitting one listens does
# not). This is architecturally different from HelixAgent/HelixLLM (ONE
# multi-model server, one /v1/models listing many ids): llmctl is
# N-INDEPENDENT-SERVERS, zero to many of which may be running at once (llmctl
# supports multi-model co-residency). This detector therefore emits ZERO, ONE,
# or MANY records per sync -- one per profile that answers ITS OWN /v1/models
# right now -- never a static list of "what the catalog COULD run".
#
# THE CATALOG (profile names + ports) IS RESOLVED FROM LLMCTL ITSELF, NEVER
# HARDCODED HERE (CONST-045 / §11.4.111): `llmctl plan --json` is llmctl's own
# hardware-aware planner and the single source of truth for where each profile
# listens. Copying that port list into a second file here would recreate
# exactly the class of stale/duplicated pin the HelixLLM :18434/:18435
# postmortem above in this file warns about, so this detector re-asks llmctl
# every sync instead of caching its answer in a tracked pins file.
#
# RUNNING == answers ITS OWN /v1/models with a genuine OpenAI-shaped listing
# right now. A port merely being *occupied* is not enough evidence: measured
# live on the development host, port 8080 (llmctl's own "fast" profile port)
# was held by an UNRELATED service that answers HTTP 200 plain-text "404 page
# not found" on /v1/models -- jq fails to parse that as JSON, `.data[0].id`
# yields empty, and the profile is correctly read as NOT running rather than
# mis-registered against the wrong backend. This is the same defensive posture
# detect_helixcoder_record and detect_helixagent_record already take -- a
# non-JSON/empty response is silently "not this backend", never a crash and
# never a bluffed record.
#
# key_var default LLMCTL_API_KEY is deliberately a NORMALLY-UNSET variable:
# llmctl's llama-server processes are launched with no API-key flag (confirmed
# in llmctl/lib/scheduler.sh's sched_build_launch -- it never adds an
# --api-key argument), so every profile's /v1 is unauthenticated plaintext
# localhost HTTP -- the same no-key-needed shape this file already handles for
# other loopback backends. The var still gets a name so the resolved record
# and the .env file carry the SAME field every other provider does, and an
# operator who later fronts llmctl with an auth proxy can export it without
# any code change here.
#
# ON-DEMAND SWITCH (lib.sh, scripts/lib.sh). Registering a record here does
# NOT mean the profile stays running forever — this host's RAM/VRAM budget
# typically fits only 1-2 llmctl profiles at once. So an `llmctl-<profile>`
# alias (base `llmctl-<profile>`, Kimi twin `kimi-llmctl-<profile>`, Pi twin
# `pi-llmctl-<profile>`) does NOT assume its registered port still hosts the
# right model at launch time: cma_run_provider / cma_run_kimi_provider /
# cma_run_pi_provider each call the shared `_cma_llmctl_ensure_active`
# (lib.sh) immediately before actually exec'ing claude/kimi/pi, which checks
# `llmctl status` and, if <profile> is not already the sole running profile,
# transparently runs `llmctl switch <profile>` FIRST. This means: (a)
# invoking any llmctl-backed alias may trigger a LIVE MODEL SWITCH on the
# host — expect the launch to take noticeably longer than usual the first
# time you switch to a given profile in a session, and expect it to switch
# away from whatever OTHER llmctl profile was previously active; (b) a
# `llmctl switch` failure ABORTS the launch outright (a clear, actionable
# stderr message, never a silent connect-to-the-wrong-model); (c) invoking
# the SAME alias twice in a row is cheap — the status check short-circuits
# and no switch/reload happens when the profile is already active.
#
# FULL-CATALOG SWEEP: `claude-providers.sh sync-all-llmctl` (cmd_sync_all_llmctl
# below) drives this SAME switch mechanism through EVERY catalog profile,
# one at a time, deterministically, verifying each with the ordinary cmd_sync
# pipeline and reporting PASS/FAIL/GATED per profile — see cmd_sync_all_llmctl's
# own header comment for the full contract.
detect_llmctl_records() {
  local _lc_json="${CMA_LLMCTL_PINS_FILE:-$LIB_DIR/providers/llmctl.json}"
  local _lc_bin="${CMA_LLMCTL_BIN-}" _lc_keyvar="${CMA_LLMCTL_KEYVAR-}" \
        _lc_transport="${CMA_LLMCTL_TRANSPORT-}" _lc_ctx="${CMA_LLMCTL_CONTEXT_LIMIT-}" \
        _lc_out="${CMA_LLMCTL_MAX_OUTPUT-}"
  if [[ -f "$_lc_json" ]] && command -v jq >/dev/null 2>&1; then
    local _k _v
    while IFS=$'\t' read -r _k _v; do
      case "$_k" in
        bin)           [[ -n "${CMA_LLMCTL_BIN+x}" ]]           || _lc_bin="$_v" ;;
        key_var)       [[ -n "${CMA_LLMCTL_KEYVAR+x}" ]]        || _lc_keyvar="$_v" ;;
        transport)     [[ -n "${CMA_LLMCTL_TRANSPORT+x}" ]]     || _lc_transport="$_v" ;;
        context_limit) [[ -n "${CMA_LLMCTL_CONTEXT_LIMIT+x}" ]] || _lc_ctx="$_v" ;;
        max_output)    [[ -n "${CMA_LLMCTL_MAX_OUTPUT+x}" ]]    || _lc_out="$_v" ;;
      esac
    done < <(jq -r 'to_entries[] | [.key, (.value|tostring)] | @tsv' "$_lc_json" 2>/dev/null)
  fi
  : "${_lc_bin:=llmctl}"
  : "${_lc_keyvar:=LLMCTL_API_KEY}"
  : "${_lc_transport:=router}"
  : "${_lc_ctx:=8192}"
  : "${_lc_out:=4096}"
  [[ "$_lc_ctx" =~ ^[0-9]+$ ]] || _lc_ctx=8192
  [[ "$_lc_out" =~ ^[0-9]+$ ]] || _lc_out=4096

  # PATH/pins gate, same shape as detect_helixagent_record/detect_helixcoder_record:
  # attempt discovery iff EITHER the llmctl binary resolves OR the git-tracked
  # pins file exists. UNLIKE those two, llmctl's ports are never declared in
  # the pins file (see the header comment above) -- they can only be learned
  # by actually running `llmctl plan --json` -- so a pins-file-only host with
  # no runnable binary honestly discovers zero profiles below; the gate still
  # admits it (rather than requiring the binary up front) so an operator who
  # tracks llmctl.json purely to override key_var/context defaults is not
  # silently ignored, and so CMA_LLMCTL_PINS_FILE alone can exercise this
  # function hermetically.
  if ! command -v "$_lc_bin" >/dev/null 2>&1 && [[ ! -f "$_lc_json" ]]; then
    printf '[]\n'; return 0
  fi
  command -v jq   >/dev/null 2>&1 || { printf '[]\n'; return 0; }
  command -v curl >/dev/null 2>&1 || { printf '[]\n'; return 0; }

  # Cannot discover ANYTHING without a runnable binary: llmctl.json (unlike
  # helixagent.json/helixcoder.json) carries no base_url/port by design (see
  # header) -- pins-only-no-binary is therefore an honest empty catalog, not a
  # crash and not a guess.
  command -v "$_lc_bin" >/dev/null 2>&1 || { printf '[]\n'; return 0; }

  # OFFLINE means "assume nothing is reachable" everywhere else in this file
  # (_cma_helixllm_served_ids, detect_helixcoder_record); "running" is a
  # live-network fact even on loopback, so honour the same contract: zero
  # probes attempted -> zero profiles provably running -> [].
  (( ${OFFLINE:-0} )) && { printf '[]\n'; return 0; }

  # This file is sourced with `set -euo pipefail` active, so every command
  # substitution below MUST be guarded (`|| true` / `|| var=default`) --
  # `var="$(cmd)"` as a bare simple command is subject to errexit exactly like
  # any other, and an unguarded one here would silently abort the WHOLE
  # function (and the whole multi-profile scan) the instant `llmctl` exits
  # nonzero or `jq` fails to parse one profile's response -- observed live
  # while writing this detector's own test: an unguarded `jq` on the
  # "wrong-service" mock's non-JSON body killed detection of every OTHER,
  # perfectly-healthy profile in the same pass, not just the bad one.
  local _plan_timeout="${CMA_LLMCTL_PLAN_TIMEOUT:-10}" _plan=""
  if command -v timeout >/dev/null 2>&1; then
    _plan="$(timeout "$_plan_timeout" "$_lc_bin" plan --json 2>/dev/null)" || _plan=""
  else
    _plan="$("$_lc_bin" plan --json 2>/dev/null)" || _plan=""
  fi
  if ! printf '%s' "$_plan" | jq -e '.profiles | type == "object"' >/dev/null 2>&1; then
    cma_warn "llmctl: '$_lc_bin plan --json' produced no/invalid catalog -- treating as no running profiles"
    printf '[]\n'; return 0
  fi

  # name<TAB>port<TAB>ctx for every catalog profile llmctl currently knows
  # about, regardless of `fits`/`recommended` -- a profile can be STARTED and
  # answering even on a host llmctl itself would not recommend it for (an
  # operator override), so those two fields are irrelevant to "is it running
  # right now" and are deliberately not consulted here.
  local _t="${CMA_LLMCTL_HTTP_TIMEOUT:-3}"
  local _name _port _pctx _served_json="[]"
  while IFS=$'\t' read -r _name _port _pctx; do
    [[ -n "$_name" && "$_port" =~ ^[0-9]+$ ]] || continue
    local _base="http://127.0.0.1:${_port}/v1"
    local _body=""
    _body="$(curl -sf --max-time "$_t" "${_base}/models" 2>/dev/null)" || _body=""
    [[ -n "$_body" ]] || continue
    local _mid="" _mctx=""
    # A non-JSON / non-OpenAI-shaped body (the real "another service already
    # owns this port" case, measured live: HTTP 200 plain-text "404 page not
    # found") makes jq fail to parse -- `|| _mid=""` is what keeps that
    # failure LOCAL to this one profile instead of aborting every other
    # profile's detection in the same pass (see the set -e note above).
    _mid="$(jq -r '.data[0].id? // empty' <<<"$_body" 2>/dev/null)" || _mid=""
    [[ -n "$_mid" ]] || continue
    _mctx="$(jq -r --arg m "$_mid" \
      '[.data[]? | select(.id==$m) | (.meta.n_ctx // empty)] | .[0] // empty' \
      <<<"$_body" 2>/dev/null)" || _mctx=""
    [[ "$_mctx" =~ ^[0-9]+$ ]] || _mctx="$_pctx"
    [[ "$_mctx" =~ ^[0-9]+$ ]] || _mctx="$_lc_ctx"
    _served_json="$(jq -c --arg name "$_name" --arg port "$_port" --arg base "$_base" \
                       --arg model "$_mid" --arg ctx "$_mctx" \
      '. + [{name:$name, port:($port|tonumber), base_url:$base, model:$model, context_limit:($ctx|tonumber)}]' \
      <<<"$_served_json" 2>/dev/null)" || _served_json=""
    [[ -n "$_served_json" ]] || _served_json="[]"
  done < <(jq -r '.profiles | to_entries[] | [.key, (.value.port|tostring), ((.value.ctx // 0)|tostring)] | @tsv' \
             <<<"$_plan" 2>/dev/null)

  if [[ "$_served_json" == "[]" || -z "$_served_json" ]]; then
    printf '[]\n'; return 0
  fi

  jq -cn --argjson served "$_served_json" --arg keyvar "$_lc_keyvar" \
         --arg transport "$_lc_transport" --argjson out "$_lc_out" '
    [ $served[] |
      {key_var: $keyvar, classification: "llm",
       provider_id: ("llmctl-" + .name), alias: ("llmctl-" + .name),
       base_url: .base_url, transport: $transport,
       strong_model: .model, fast_model: .model,
       context_limit: .context_limit, max_output: $out,
       status: "resolved",
       reason: ("llmctl profile " + .name + " live at " + .base_url + " serving " + .model)}
    ]
  '
}

resolve_records() {
  local keys; keys="$(present_key_vars | paste -sd, -)"
  local args=(--models-dev "$CACHE" --keys "$keys")
  [[ -f "$KEY_ALIASES" ]] && args+=(--key-aliases "$KEY_ALIASES")
  [[ -f "$OVERRIDES" ]] && args+=(--overrides "$OVERRIDES")
  # Legacy Kimi id map (kimi-* -> kc-*): the RESOLVER applies it at emission so
  # a key that maps to catalog id "kimi-for-coding" (models.dev upstream id)
  # yields a kc-for-coding record. Without this the rename could never stick —
  # cmd_migrate_names renames the disk state each sync, but resolve_records
  # re-emits the legacy id from the catalog every run, a race the resolver wins.
  [[ -f "$LEGACY_RENAMES" ]] && args+=(--legacy-renames "$LEGACY_RENAMES")
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
  extra_hc="$(detect_helixcoder_record)" || true
  if ! printf '%s' "$extra_hc" | jq -e 'type=="array"' >/dev/null 2>&1; then
    cma_die "detect_helixcoder_record produced no/invalid JSON output"
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
  extra_tr="$(detect_tokenrouter_records)" || true
  if ! printf '%s' "$extra_tr" | jq -e 'type=="array"' >/dev/null 2>&1; then
    cma_die "detect_tokenrouter_records produced no/invalid JSON output"
  fi
  extra_lc="$(detect_llmctl_records)" || true
  if ! printf '%s' "$extra_lc" | jq -e 'type=="array"' >/dev/null 2>&1; then
    cma_die "detect_llmctl_records produced no/invalid JSON output"
  fi
  # Merge all ten sources, deduped by provider_id. The Kimi Code OAuth
  # detector records take PRECEDENCE over key-var records (an OAuth
  # subscription is the user's priority for kimi-for-coding; the API key
  # remains the fallback on hosts without the OAuth session). Resolver
  # records still win over local PATH-detection. First occurrence wins.
  jq -n --argjson base "$base_records" --argjson e1 "$extra" --argjson e2 "$extra_kc" --argjson e3 "$extra_hl" --argjson e4 "$extra_og" --argjson e5 "$extra_cht" --argjson e6 "$extra_hy" --argjson e7 "$extra_z" --argjson e8 "$extra_hc" --argjson e9 "$extra_tr" --argjson e10 "$extra_lc" '
    ($e2 + $base + $e3 + $e1 + $e4 + $e5 + $e6 + $e7 + $e8 + $e9 + $e10) | unique_by(.provider_id)
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
# _cma_provider_source ID — the CMA_PROVIDER_SOURCE marker on a provider's env
# record, or empty. Read in a subshell so nothing from the (generated, but
# still user-writable) env file leaks into this process — the same isolation
# _cma_helixllm_retire_stale uses to read the very same field.
_cma_provider_source() {
  local pdir; pdir="$(cma_providers_dir)"
  local f="$pdir/$1.env"
  [[ -f "$f" ]] || return 0
  # shellcheck disable=SC1090
  ( unset CMA_PROVIDER_SOURCE; set +e; . "$f" >/dev/null 2>&1
    printf '%s' "${CMA_PROVIDER_SOURCE:-}" )
}

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
    case "$resolved" in *" $cid "*) continue ;; esac
    # NOT EVERY UNRESOLVED ID IS AN ORPHAN — SOME HAVE A DIFFERENT OWNER.
    #
    # "Resolved" here means "sync's detectors produced a record for it this
    # run". Records written by `helixllm-export --apply` are, BY DESIGN, never
    # in that set: FR-018 keeps the per-model fan-out OUT of the default sync
    # (see cmd_helixllm_export's header — fanning every served model out on
    # every sync is exactly the silent config mutation FR-018 forbids). So
    # every one of them looked "no longer resolves against the current
    # catalog/keys" to this sweep and was demoted on the very next sync.
    #
    # Measured 2026-09-07, one `claude-providers sync` after an export + verify:
    #   helixllm-anton-...-f6771589d190: verified -> orphaned
    # The launch gate trusts only `verified`, so a route the operator had just
    # configured and proved working stopped working, every time, with the two
    # commands silently undoing each other. (A previous agent restored such a
    # route by hand and recorded that the next sync would break it again.)
    #
    # The marker is a POSITIVE, per-file claim of ownership, written by exactly
    # one code path and read here exactly as _cma_helixllm_retire_stale reads
    # it. Skipping is not "trust it forever": export-owned records have their
    # OWN convergence sweep, which retires them on evidence this one does not
    # have — that their serving host is up, is serving, and no longer lists the
    # model. That sweep can delete; this one only demotes. Deferring to the
    # owner that can actually tell is the whole fix.
    [[ -n "$(_cma_provider_source "$cid")" ]] && continue
    printf '%s\n' "$cid"
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

# --- Kimi legacy id migration (kimi-* -> kc-*) ------------------------------
# One-time, idempotent, convergent. Every sync (and every prune-safe mount
# point) renames the EXISTING disk state left by pre-v1.27.0 kimi-* provider
# ids (status records, .env, .token snapshot, ~/.claude-prov-<id>, alias-file
# line, key-aliases.json value, overrides.json key) to the vacated kc-* names.
# The resolver's --legacy-renames mapping (see resolve_records) guarantees the
# names STAY renamed on every re-resolve; this pass only repairs state already
# on disk. All renames are atomic (tmp+mv, or rename-only), never deletes, so
# `claude-providers rollback`-style recovery is a rename away. A second run on
# a clean tree changes nothing and prints nothing (byte no-op).
cmd_migrate_names() {
  local map
  map="$(jq -c . "$LEGACY_RENAMES" 2>/dev/null)" || { cma_warn "cannot read legacy-renames map: $LEGACY_RENAMES"; return 0; }
  [[ "$map" == "{}" || "$map" == "null" ]] && return 0
  local old new pdir changed=0
  local do_write=1
  [[ "$DRY_RUN" == "1" ]] && do_write=0
  pdir="$(cma_providers_dir)"
  while IFS=$'\t' read -r old new; do
    [[ -n "$old" && -n "$new" ]] || continue
    [[ "$old" != "$new" ]] || continue

    # 1. status.json record key (rename in place, atomic tmp+mv).
    if [[ -f "$pdir/status.json" ]] && [[ "$(jq -r --arg o "$old" 'has($o)' "$pdir/status.json" 2>/dev/null)" == "true" ]]; then
      if (( do_write )); then
        local stmp; stmp="$(mktemp "${TMPDIR:-/tmp}/cma-mig.XXXXXX")"
        if jq --arg o "$old" --arg n "$new" \
          'with_entries(if .key == $o then .key = $n else . end)' "$pdir/status.json" > "$stmp" 2>/dev/null; then
          mv -f "$stmp" "$pdir/status.json" && printf '  renamed status record: %s -> %s\n' "$old" "$new" && changed=1
        fi
        rm -f "$stmp"
      else
        printf '  would rename status record: %s -> %s\n' "$old" "$new"
      fi
    fi

    # 2. .env record — regenerate under the new id (preserves trim knob, key
    #    from file, transport, models, limits; key material never lives here).
    #    Values are captured OUT of the source subshell via process
    #    substitution — a bare `( . env )` would set them only inside the
    #    subshell and the rewrite would silently produce an empty env. A
    #    degenerate env carrying only CMA_PROVIDER_ID still migrates; fields
    #    that were absent come out empty rather than blocking the move.
    if [[ -f "$pdir/$old.env" ]]; then
      if (( do_write )); then
        local e_key e_trans e_base e_model e_fast e_ctx e_out e_trim
        IFS=$'\t' read -r e_key e_trans e_base e_model e_fast e_ctx e_out e_trim \
          < <( set +e +u; set -a; . "$pdir/$old.env" 2>/dev/null; set +a; \
               printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                 "${CMA_PROVIDER_KEYVAR:-}" "${CMA_PROVIDER_TRANSPORT:-}" \
                 "${CMA_PROVIDER_BASE_URL:-}" "${CMA_PROVIDER_MODEL:-}" \
                 "${CMA_PROVIDER_FAST_MODEL:-}" "${CMA_PROVIDER_CONTEXT_LIMIT:-}" \
                 "${CMA_PROVIDER_MAX_OUTPUT:-}" "${CMA_PROVIDER_TRIM:-}" )
        # cma_provider_write_env preserves the opt-in CMA_PROVIDER_TRIM knob only
        # by reading the TARGET env before truncating it. On a rename the target
        # does not exist yet, so the source's trim would be silently dropped —
        # seed the target with it first (write_env sources it, then rewrites the
        # whole file and re-emits the trim). An existing target keeps its own.
        if [[ ! -f "$pdir/$new.env" && -n "$e_trim" && "$e_trim" != "null" ]]; then
          printf 'CMA_PROVIDER_TRIM=%s\n' "$e_trim" > "$pdir/$new.env"
        fi
        if cma_provider_write_env "$new" "$e_key" "$e_trans" "$e_base" "$e_model" "$e_fast" "$HOME/${CMA_PROVIDER_DIR_PREFIX}${new}" "$e_ctx" "$e_out" "$new"; then
          rm -f "$pdir/$old.env"
          printf '  renamed env: %s.env -> %s.env\n' "$old" "$new" && changed=1
        else
          cma_warn "could not rewrite env for $old -> $new; leaving $pdir/$old.env in place"
        fi
      else
        printf '  would rename env: %s.env -> %s.env\n' "$old" "$new"
      fi
    fi

    # 3. OAuth token snapshot rename (rename preserves inode/permissions).
    if [[ -f "$pdir/$old.token" ]]; then
      if (( do_write )); then
        mv -f "$pdir/$old.token" "$pdir/$new.token" 2>/dev/null \
          && printf '  renamed token: %s.token -> %s.token\n' "$old" "$new" && changed=1
      else
        printf '  would rename token: %s.token -> %s.token\n' "$old" "$new"
      fi
    fi

    # 4. Config dir rename. If a fresh kc-* dir already exists (sync re-created
    #    it via cma_link_shared_items), keep the fresh one and ARCHIVE the old
    #    data rather than throw it away; otherwise move the old dir into place so
    #    the user's settings/plugins survive the rename.
    local odir="$HOME/${CMA_PROVIDER_DIR_PREFIX}${old}" ndir="$HOME/${CMA_PROVIDER_DIR_PREFIX}${new}"
    if [[ -e "$odir" ]]; then
      if (( do_write )); then
        if [[ -e "$ndir" ]]; then
          mv "$odir" "${odir}.preunify.$(date +%Y%m%d%H%M%S)" 2>/dev/null \
            && printf '  archived old config dir: %s -> %s.preunify.*\n' "$odir" "$odir" && changed=1
        else
          mv "$odir" "$ndir" 2>/dev/null \
            && printf '  renamed config dir: %s -> %s\n' "$odir" "$ndir" && changed=1
        fi
      elif [[ -e "$ndir" ]]; then
        printf '  would archive config dir: %s -> %s.preunify.*\n' "$odir" "$odir"
      else
        printf '  would rename config dir: %s -> %s\n' "$odir" "$ndir"
      fi
    fi

    # 5. Alias-file line: drop the old id alias, add the new one, in ONE render.
    if [[ -f "$ALIAS_FILE" ]] && grep -q "^alias ${old}=" "$ALIAS_FILE" 2>/dev/null; then
      if (( do_write )); then
        if cma_alias_commit "$old" "$(printf 'alias %s="cma_run_provider %s"' "$new" "$new")" keep 2>/dev/null; then
          printf '  renamed alias: %s -> %s\n' "$old" "$new" && changed=1
        fi
      else
        printf '  would rename alias: %s -> %s\n' "$old" "$new"
      fi
    fi

    # 6. key-aliases.json value rewrite (atomic temp+mv; idempotent).
    if [[ -f "$KEY_ALIASES" ]] && [[ "$(jq -r --arg o "$old" '[.[] | select(. == $o)] | length' "$KEY_ALIASES" 2>/dev/null)" != "0" ]]; then
      if (( do_write )); then
        local ktmp; ktmp="$(mktemp "${TMPDIR:-/tmp}/cma-mig.XXXXXX")"
        if jq --arg o "$old" --arg n "$new" \
          'with_entries(if .value == $o then .value = $n else . end)' "$KEY_ALIASES" > "$ktmp" 2>/dev/null; then
          mv -f "$ktmp" "$KEY_ALIASES" && printf '  rewritten %s: value %s -> %s\n' "$KEY_ALIASES" "$old" "$new" && changed=1
        fi
        rm -f "$ktmp"
      else
        printf '  would rewrite %s: value %s -> %s\n' "$KEY_ALIASES" "$old" "$new"
      fi
    fi

    # 7. overrides.json key rewrite (atomic temp+mv; idempotent).
    if [[ -f "$OVERRIDES" ]] && [[ "$(jq -r --arg o "$old" 'has($o)' "$OVERRIDES" 2>/dev/null)" == "true" ]]; then
      if (( do_write )); then
        local otmp; otmp="$(mktemp "${TMPDIR:-/tmp}/cma-mig.XXXXXX")"
        if jq --arg o "$old" --arg n "$new" \
          'with_entries(if .key == $o then .key = $n else . end)' "$OVERRIDES" > "$otmp" 2>/dev/null; then
          mv -f "$otmp" "$OVERRIDES" && printf '  rewritten %s: key %s -> %s\n' "$OVERRIDES" "$old" "$new" && changed=1
        fi
        rm -f "$otmp"
      else
        printf '  would rewrite %s: key %s -> %s\n' "$OVERRIDES" "$old" "$new"
      fi
    fi
  done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' <<<"$map")

  [[ "$changed" == "1" ]] && cma_log "migrate-names: renamed kimi-* provider ids to kc-*"
  return 0
}

# Emit the Kimi Code twin of a provider alias. `kimi-<id>` runs the Kimi CLI
# over the SAME backend/env as the Claude twin (launch wrapper: the lib.sh
# cma_run_kimi_provider). Namespace contract: kc-* ids are Claude-over-Kimi and
# never get a kimi-kc-* twin; legacy kimi-* ids are being vacated so never get
# a kimi-kimi-* twin either (they migrate to kc-*). Excluded ids still return 0
# (absence is the contract, not an error).
_cma_kimi_twin_alias() {
  local id="$1"
  case "$id" in
    ''|kc-*|kimi-*) return 0 ;;
  esac
  case "$id" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  local twin="kimi-$id"
  cma_alias_commit "$twin" "$(printf 'alias %s="cma_run_kimi_provider %s"' "$twin" "$id")" keep 2>/dev/null || return 1
  return 0
}

# Emit the Pi CLI twin of a provider alias. `pi-<id>` runs the Pi CLI
# over the SAME backend/env as the Claude twin (launch wrapper: the lib.sh
# cma_run_pi_provider). Namespace contract: pi-*, kimi-*, kc-* are reserved
# provider namespaces — excluded ids still return 0 (absence is the contract).
_cma_pi_twin_alias() {
  local id="$1"
  case "$id" in
    ''|pi-*|kimi-*|kc-*) return 0 ;;
  esac
  case "$id" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  local twin="pi-$id"
  cma_alias_commit "$twin" "$(printf 'alias %s="cma_run_pi_provider %s"' "$twin" "$id")" keep 2>/dev/null || return 1
  return 0
}

# Render the per-alias Pi CLI config (~/.pi-prov-<id>/models.json) from the
# SYNC-time record. This function is the ONLY writer of that file: the launch
# wrapper (lib.sh cma_run_pi_provider) READS the provider/model id + baseUrl
# out of it and refuses to launch when it is missing, but never rewrites it.
#
# WHY models.json AND NOT config.toml (root-cause note, do not "simplify" away
# without re-reading this): the ORIGINAL renderer wrote a `config.toml` file
# mirroring the sibling Kimi CLI's config format — but the Pi CLI has NO TOML
# reader anywhere in its source (`grep -rn toml` over its installed dist/
# bundle returns zero hits) and NO `PI_HOME` env var either (same zero-hit
# grep for "PI_HOME"). Every pi-<id> twin launch silently ignored this file in
# full and fell through to Pi's shared, unconfigured `~/.pi/agent/` state —
# confirmed live: `pi --list-models llmctl` found nothing, and a real launch
# failed with `Error: Model "..." not found`. Pi's REAL custom-provider config
# mechanism (verified against the installed pi CLI's own dist/config.js +
# docs/models.md, v0.85.1) is a JSON file named exactly `models.json`, read
# from whatever directory the `PI_CODING_AGENT_DIR` env var names (default
# `~/.pi/agent`) — see cma_run_pi_provider, which exports that variable
# pointing at this SAME per-id directory so pi resolves exactly this file.
_cma_pi_render_config() {
  local id="$1" keyvar="$2" transport="$3" base="$4" strong="$5" ctx="${6:-}"
  case "$id" in ''|pi-*|kimi-*|kc-*) return 0 ;; esac
  local pdir="$HOME/.pi-prov-$id"
  ( umask 077; mkdir -p "$pdir" )
  # API-TYPE SELECTION — from the TRANSPORT, not from what the URL happens to
  # spell. Pi's models.json schema (docs/models.md "Supported APIs") names its
  # provider `api` field "openai-completions" / "anthropic-messages" /
  # "openai-responses" / "google-generative-ai" — NOT the bare "openai" /
  # "anthropic" strings the sibling Kimi config.toml `type` field uses (a
  # DIFFERENT CLI with a DIFFERENT schema; copying that value verbatim would
  # silently mismatch Pi's enum and the provider would fail to load).
  local api_type=""
  case "$transport" in
    native) api_type="anthropic-messages" ;;
    *) api_type="openai-completions" ;;
  esac
  # Resolve the actual API key value for this provider (not the keyvar name).
  # The key is read from the keys file at launch time, but we need the value
  # at sync time to write it into models.json.
  local api_key=""
  if [[ -f "$CMA_KEYS_FILE" ]]; then
    # shellcheck source=/dev/null
    api_key="$( set +e; set -a +u; . "$CMA_KEYS_FILE" 2>/dev/null; set +a; eval "printf '%s' \"\${$keyvar:-}\"" )" || true
  fi
  local base_clean="${base%/}"
  # Normalize a missing/literal-"null" context limit the same way the Kimi
  # renderer does (a catalog miss surfaces as the literal string "null" from
  # an upstream `jq -r`, never a real number) — `--argjson` below requires a
  # syntactically valid JSON number.
  [[ -n "$ctx" && "$ctx" != "null" ]] || ctx="2000000"
  # jq is a hard dependency of claude-providers.sh generally (used pervasively
  # for status.json throughout this file), so using it here to build the JSON
  # safely (correct escaping of a secret-bearing api_key, arbitrary model-id
  # strings that may contain slashes) introduces no new dependency.
  local json
  json="$(jq -n \
    --arg id "$id" \
    --arg baseUrl "$base_clean" \
    --arg api "$api_type" \
    --arg apiKey "$api_key" \
    --arg modelId "$strong" \
    --argjson ctx "$ctx" \
    '{providers: {($id): {baseUrl: $baseUrl, api: $api, apiKey: $apiKey, models: [{id: $modelId, contextWindow: $ctx}]}}}')" || return 1
  ( umask 077; printf '%s\n' "$json" > "$pdir/models.json.tmp" )
  mv "$pdir/models.json.tmp" "$pdir/models.json"
  # Retire a stale config.toml from a prior render (pre-fix layout) — Pi never
  # read it, but leaving it behind is confusing debris in an operator's `ls`.
  rm -f "$pdir/config.toml"
}

# Render the per-alias Kimi Code config (~/.kimi-prov-<id>/config.toml) from the
# SYNC-time record. This function is the ONLY writer of that file: the launch
# wrapper (lib.sh cma_run_kimi_provider) READS default_model/base_url out of it
# and refuses to launch when it is missing, but never rewrites it. So whatever
# is rendered here is what the Kimi CLI dials — there is no second, later chance
# to correct it. (An earlier revision of this comment claimed the wrapper
# refreshes the file at launch; it does not, and believing that sends anyone
# debugging a wrong backend to the wrong file.)
# The api_key here is the RESOLVED KEY VALUE (or the OAuth token snapshot), never
# a keyvar name — this file is the one secret-bearing artifact of the kimi twin.
# Written 0600/0700 via umask + temp + atomic rename. `kc-*` ids render no
# config (they are the Claude-over-Kimi names and have no kimi twin).
_cma_kimi_render_config() {
  local id="$1" keyvar="$2" transport="$3" base="$4" strong="$5" ctx="${6:-}"
  case "$id" in ''|kc-*|kimi-*) return 0 ;; esac
  local kdir="$HOME/.kimi-prov-$id"
  ( umask 077; mkdir -p "$kdir" )
  # WIRE SELECTION — from the TRANSPORT, not from what the URL happens to spell.
  #
  # The kimi CLI dispatches on `type`, and each wire's SDK builds its path
  # RELATIVE to base_url: the bundled openai SDK posts "/chat/completions", the
  # bundled @anthropic-ai/sdk posts "/v1/messages" (and kimi strips a trailing
  # `/v1` for the anthropic wire so it cannot become /v1/v1/messages). So the
  # wire label decides which URL is actually dialled.
  #
  # Selecting it from the URL shape alone mislabels every provider that speaks
  # Anthropic natively without saying so in its path. Measured on the real
  # gateway — transport `native`, base https://127.0.0.1:8443 with no `/v1`:
  #
  #   GET  /v1/models            200      GET  /models             404
  #   POST /v1/chat/completions  400      POST /chat/completions   404
  #   POST /v1/messages          400
  #
  # Typed `openai`, the twin aimed at /chat/completions — a 404. Typed
  # `anthropic`, it aims at /v1/messages, which is the route that exists. The
  # base_url is NOT wrong; it is correct for its own native transport (Claude
  # Code appends /v1/messages to it too). Only the wire label was.
  #
  # AND THE FIX IS NOT "APPEND /v1" TO THE BASE. `deepseek`
  # (https://api.deepseek.com), `kilo` (/api/gateway) and `zai` (/paas/v4) are
  # openai-typed providers with no `/v1` whose roots serve /chat/completions
  # directly; appending would break all three, and appending to this native
  # record would give the Claude side /v1/v1/messages. transport is the honest
  # discriminator — providers_resolve.transport_for defines it as exactly this:
  # "native iff the provider speaks the Anthropic API natively".
  local api_key="" typ="openai"
  [[ "$transport" == "native" ]] && typ="anthropic"
  # Kept for the router-transport provider that has been PROMOTED to an
  # Anthropic endpoint via overrides.json (the documented
  # "deepseek -> native /anthropic" path): its transport can still read router
  # while its base names the anthropic surface.
  case "$base" in */anthropic*|/v1/messages*) typ="anthropic" ;; esac
  if [[ "$keyvar" == "_CMA_KIMICODE_OAUTH_" ]]; then
    local tokf; tokf="$(cma_providers_dir)/$id.token"
    [[ -f "$tokf" ]] && api_key="$(cat "$tokf" 2>/dev/null)" || true
  else
    local kf="${CMA_KEYS_FILE:-$HOME/api_keys.sh}"
    [[ -f "$kf" ]] && api_key="$( set +e +u; set -a; . "$kf" 2>/dev/null; set +a; eval "printf '%s' \"\${$keyvar:-}\"" )" || true
  fi
  [[ "$transport" == "router" && -z "$api_key" ]] && cma_warn "kimi config: '$id' key empty — config.toml will carry an empty api_key"
  [[ -n "$ctx" && "$ctx" != "null" ]] || ctx="128000"
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/cma-kimi.XXXXXX")"
  # `default_model` MUST be written BEFORE any `[table]` header. TOML has no
  # "close this table" syntax: once a `[table]` header opens, every following
  # `key = value` line belongs to THAT table until the NEXT table header — so
  # emitting `default_model = "..."` at the end of this heredoc (after
  # `[models."<id>/<model>"]` had already opened) silently nested it INSIDE
  # that model's own table instead of the file's root table. The Kimi CLI
  # reads `defaultModel` from the ROOT config (confirmed against the shipped
  # binary's own decompiled error path: `config.get("defaultModel")` /
  # `AuthModelNotResolvedError` when it comes back undefined), so a
  # root-less default_model made every `kimi-<id>` twin — cloud AND
  # locally-hosted alike — fail non-interactive `-p` prompt mode with
  # "no default model configured" / "No model configured", even though
  # `kimi doctor` and `kimi provider list` both read it as fine (neither
  # consults `defaultModel`). A plain `grep '^default_model ='` (what
  # cma_run_kimi_provider itself uses to build its `-m` argument) still finds
  # the line regardless of TOML scope, which is why this stayed invisible.
  # Regression coverage: test_kimi_render_config_default_model_toml.sh.
  {
    printf 'default_model = "%s/%s"\n\n' "$id" "$strong"
    printf '[providers."%s"]\n' "$id"
    printf 'type = "%s"\n' "$typ"
    printf 'base_url = "%s"\n' "$base"
    printf 'api_key = "%s"\n' "$api_key"
    printf '\n[models."%s/%s"]\n' "$id" "$strong"
    printf 'provider = "%s"\n' "$id"
    printf 'model = "%s"\n' "$strong"
    printf 'max_context_size = %s\n' "$ctx"
    printf 'capabilities = [ "tool_use", "thinking" ]\n'
  } > "$tmp"
  ( umask 077; mv -f "$tmp" "$kdir/config.toml" ) 2>/dev/null
  return 0
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
  # One-time, idempotent Kimi legacy id rename (kimi-* -> kc-*): repairs the
  # disk state carried over from pre-v1.27.0 BEFORE resolve_records re-resolves.
  # The resolver's --legacy-renames mapping then keeps the names renamed (see
  # cmd_migrate_names + resolve_records for why both halves are necessary).
  (( DRY_RUN )) || cmd_migrate_names
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
    # Declared here, not in the branch below: the failure branch reads it even
    # when --no-verify skipped the probe entirely, and under `set -u` an unset
    # read is fatal. Empty is the honest value there — nothing was measured.
    local _vreason="" _vreason_f="" _vlayer="" _vlayer_f=""
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
        local _kimi_tokf; _kimi_tokf="$(cma_providers_dir)/$pid.token"
        [[ -f "$_kimi_tokf" ]] && export _CMA_KIMICODE_OAUTH_="$(cat "$_kimi_tokf" 2>/dev/null)"
      fi
      # providers-verify.sh:59 emit(): VERDICT on stdout, REASON on stderr, and
      # (providers-verify.sh:70-93) the LAYER as a third, machine-readable
      # channel: a token written to the file named by CMA_VERIFY_LAYER_FILE,
      # closed-vocabulary and authoritative (the verifier itself determined
      # it - see providers-verify.sh's own emit() doc comment for the full
      # vocabulary). Root-caused via systematic debugging, 2026-09-17: this
      # call site never set that variable, so it silently got the documented
      # no-op fallback (providers-verify.sh:71: "Unset ... is a silent
      # no-op") and instead re-derived a layer by pattern-matching stderr
      # PROSE through the separately-maintained cma_verify_failing_layer() -
      # which uses a DIFFERENT, older vocabulary (`tool_calling` vs the real
      # one's `tool_call`; no case at all for an HTTP-404/"model missing"
      # reason, which fell through to a generic `chat_http` bucket instead of
      # `existence`). The reason used to go to /dev/null entirely and this
      # branch wrote the literal `existence` for all eight of the verifier's
      # distinct `failed` reasons - seven of which are not about the model
      # existing; keeping stderr was step one, reading the authoritative
      # layer token the verifier already computed (instead of re-guessing it
      # from that same prose) is the fix that actually closes the gap.
      _vreason_f="$(mktemp "${TMPDIR:-/tmp}/cma-verify.XXXXXX")"
      _vlayer_f="$(mktemp "${TMPDIR:-/tmp}/cma-verify-layer.XXXXXX")"; : > "$_vlayer_f"
      vstatus="$( ( [[ -e "$CMA_KEYS_FILE" ]] && { set -a +u; . "$CMA_KEYS_FILE"; set +a; }; CMA_VERIFY_LAYER_FILE="$_vlayer_f" bash "$VERIFY" "${vargs[@]}" 2>"$_vreason_f" ) )" || true
      [[ -s "$_vreason_f" ]] && _vreason="$(cat "$_vreason_f")"
      _vlayer="$(cat "$_vlayer_f" 2>/dev/null)"
      rm -f "$_vreason_f" "$_vlayer_f"
      [[ -z "$vstatus" ]] && vstatus="unverified"
    fi

    if [[ "$vstatus" == "failed" ]]; then
      cma_warn "provider '$pid' FAILED verification — alias NOT activated${_vreason:+: $_vreason}"
      # Authoritative layer token first (see the comment above); the
      # stderr-prose regex mapper is now only a fallback for a verifier
      # implementation that predates the layer-file protocol.
      cma_status_write "$pid" failed "$model" "${_vlayer:-$(cma_verify_failing_layer "$_vreason")}"
      n_disabled=$((n_disabled+1))
      continue
    fi

    cma_link_shared_items "$cdir"
    cma_provider_write_env "$pid" "$keyvar" "$transport" "$base" "$model" "$fast" "$cdir" "$ctx_limit" "$max_out" "$alias"
    cma_provider_write_alias "$alias" "$pid"

    # Kimi Code twin (v1.27.0): `kimi-<id>` = Kimi CLI over the SAME backend.
    # Emission is independent of verify status (the launch gate in lib.sh is
    # the single status.json gate for both twins). Excluded ids (kc-*, kimi-*)
    # are a no-op. Config.toml is the file the Kimi CLI actually reads at
    # launch — render it here so a bare sync produces a usable kimi alias.
    if (( KIMI_ALIASES )); then
      _cma_kimi_twin_alias "$pid" || true
      _cma_kimi_render_config "$pid" "$keyvar" "$transport" "$base" "$model" "$ctx_limit" || true
    fi

    # Pi CLI twin (v1.28.0): `pi-<id>` = Pi CLI over the SAME backend.
    # Emission is independent of verify status (the launch gate in lib.sh is
    # the single status.json gate for both twins). Excluded ids (pi-*, kimi-*, kc-*)
    # are a no-op. Config.toml is the file the Pi CLI actually reads at
    # launch — render it here so a bare sync produces a usable pi alias.
    : "${PI_ALIASES:=1}"
    if (( PI_ALIASES )); then
      _cma_pi_twin_alias "$pid" || true
      _cma_pi_render_config "$pid" "$keyvar" "$transport" "$base" "$model" "$ctx_limit" || true
    fi

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
      # Not "verified": prefer the verifier's OWN authoritative layer token
      # (root-caused 2026-09-17, see the comment at the verify call site
      # above) - an "unverified" (not "failed") verdict is not always an
      # inconclusive existence probe (e.g. a tool-probe rate-limit is
      # "unverified" too, and its real layer is tool_call, not existence);
      # `unknown` - never a confident wrong guess - when the verifier
      # determined no layer at all, matching providers-verify.sh's own
      # documented contract ("found this file absent or empty has learned
      # that NO layer was determined, and must record that honestly").
      flayer="${_vlayer:-unknown}"
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

# --- subcommand: helixllm-export ---------------------------------------------
# claude-providers helixllm-export [--host URL]... [--apply]
#
# On-demand retrieval of the HelixLLM provider configuration (FR-018). The
# operator asks for it and gets it; nothing waits for — or is surprised by — an
# automatic sync.
#
# WHY THIS IS NOT WIRED INTO THE DEFAULT `sync`. FR-018 also says the system
# MUST NOT silently modify another tool's configuration files. Fanning every
# served model out into alias + env records on every sync (the session hook runs
# one per interactive shell) is exactly that. So the default run is READ-ONLY
# apart from the catalogue it is asked to produce, it PRINTS what it found and
# how to apply it, and `--apply` — an explicit act by the operator — is what
# writes the provider records. `sync` keeps its existing behaviour untouched.
cmd_helixllm_export() {
  local envelope records serving not_serving
  envelope="$(detect_helixllm_model_records)" || true
  if ! printf '%s' "$envelope" | jq -e 'type=="object" and (.records|type=="array")' \
       >/dev/null 2>&1; then
    cma_die "detect_helixllm_model_records produced no/invalid JSON output"
  fi
  records="$(jq -c '.records'                            <<<"$envelope")"
  serving="$(jq -c '.hosts_serving // []'                <<<"$envelope")"
  not_serving="$(jq -c '.hosts_answered_not_serving // []' <<<"$envelope")"
  local n; n="$(jq 'length' <<<"$records")"

  _cma_helixllm_catalogue_merge "$records" \
    || cma_die "failed to write the HelixLLM model catalogue"
  local cat_file; cat_file="$(_cma_helixllm_catalogue)"

  if (( n == 0 )); then
    cma_warn "no HelixLLM-served models found on any configured host — nothing to export"
    cma_log "catalogue: $cat_file"
    # NOT an early return when --apply is set: a host that is demonstrably
    # serving a reduced set is a host whose dropped models are genuinely gone,
    # and the convergence sweep below is exactly what retires them. Returning
    # here would leave every one of them permanently invocable. (The sweep
    # itself is what refuses to act on a host that named nothing — reaching it
    # with an empty record set is safe.)
    (( APPLY )) || return 0
  fi

  if (( n > 0 )); then
    cma_log "HelixLLM: $n model option(s) across $(jq -r '[.[].serving_host]|unique|length' <<<"$records") host(s)"
    if ! (( QUIET )); then
      jq -r '.[] | "\(.provider_id)\t\(.model_identity)\t\(.base_url)"' <<<"$records" \
        | while IFS=$'\t' read -r _id _identity _base; do
            printf '  %-44s %-40s %s\n' "$_id" "$_identity" "$_base"
          done
    fi
  fi
  cma_log "catalogue: $cat_file"

  if (( ! APPLY )); then
    cma_log "nothing else was modified. To create the aliases yourself, run:"
    cma_log "  claude-providers helixllm-export --apply"
    return 0
  fi

  # --apply: write the same env + alias records every other provider gets, via
  # the SAME writers (so the identifier passes the very validators that would
  # reject the human-readable identity). Re-applying overwrites in place — the
  # provider id is the file name, so this is idempotent by construction.
  (( DRY_RUN )) || cma_ensure_alias_file
  local pid keyvar transport base model fast ctx_limit max_out n_written=0
  while IFS=$'\t' read -r pid keyvar transport base model fast ctx_limit max_out; do
    [[ -n "$pid" ]] || continue
    if (( DRY_RUN )); then
      printf '  would create: alias %-40s -> %s [%s]\n' "$pid" "$model" "$transport"
      continue
    fi
    local cdir="$HOME/${CMA_PROVIDER_DIR_PREFIX}${pid}"
    cma_link_shared_items "$cdir"
    cma_provider_write_env "$pid" "$keyvar" "$transport" "$base" "$model" "$fast" \
                           "$cdir" "$ctx_limit" "$max_out" "$pid"
    # PROVENANCE MARKER. This one line is what makes the retirement sweep below
    # safe: it is written ONLY here, so it is a positive, per-file claim that
    # `helixllm-export --apply` created this record. Nothing else the sweep
    # could reach — a hand-authored env file, another provider's env file, a
    # record from `sync` — carries it, so nothing else can be removed by it.
    # cma_provider_write_env rewrites the whole file, so this is appended after
    # every write rather than once.
    printf '%s\n' \
      "# Written by 'claude-providers helixllm-export --apply'. This marker is the" \
      "# ONLY thing that lets that command retire this record when the serving host" \
      "# stops offering the model; remove it and the record becomes permanent." \
      "CMA_PROVIDER_SOURCE='helixllm-export'" >> "$(cma_providers_dir)/$pid.env"
    # Persist the CA trust anchor the export ran with, so the LAUNCH path (not
    # just the verify probe) can trust a self-signed https gateway: router
    # aliases build SSL_CERT_FILE from it, native aliases export
    # NODE_EXTRA_CA_CERTS. Same refusal rules as providers-verify.sh — a path
    # that is unreadable or could break a quoted assignment is not persisted.
    if [[ -n "${CMA_PROVIDER_CA_CERT:-}" && -r "${CMA_PROVIDER_CA_CERT:-}" ]] \
       && [[ "${CMA_PROVIDER_CA_CERT}" != *"'"* ]] \
       && [[ "${CMA_PROVIDER_CA_CERT}" != *\\* ]] \
       && [[ "${CMA_PROVIDER_CA_CERT}" != *$'\n'* ]]; then
      printf 'CMA_PROVIDER_CA_CERT=%s\n' "'$CMA_PROVIDER_CA_CERT'" >> "$(cma_providers_dir)/$pid.env"
    fi
    cma_provider_write_alias "$pid" "$pid"
    # Kimi Code twin — the SAME pairing every other alias-emitting path makes
    # (cmd_sync and the multi-sync leg both do this under the same gate). Its
    # absence here was the whole defect: an exported record got a `claude` alias
    # and no `kimi-` twin, so `kimi-<id>` simply did not exist for any model that
    # arrived through the export path — while the two other paths produced twins
    # normally, making the gap look like an intermittent one. Emission is
    # independent of verify status; the launch gate in lib.sh is the single
    # status.json gate for both twins. Excluded ids (kc-*, kimi-*) are a no-op.
    if (( KIMI_ALIASES )); then
      _cma_kimi_twin_alias "$pid" || true
      _cma_kimi_render_config "$pid" "$keyvar" "$transport" "$base" "$model" "$ctx_limit" || true
    fi

    # Pi CLI twin — mirrors the Kimi twin logic for Pi CLI agent.
    if (( PI_ALIASES )); then
      _cma_pi_twin_alias "$pid" || true
      _cma_pi_render_config "$pid" "$keyvar" "$transport" "$base" "$model" "$ctx_limit" || true
    fi
    n_written=$((n_written + 1))
  done < <(jq -r '.[] | [.provider_id, .key_var, .transport, .base_url,
                         .strong_model, .fast_model,
                         (.context_limit|tostring), (.max_output|tostring)] | @tsv' <<<"$records")
  cma_log "applied $n_written HelixLLM model provider(s)"

  _cma_helixllm_retire_stale "$records" "$serving" "$not_serving"

  cma_log "reload your shell or: source $ALIAS_FILE"
}

# _cma_helixllm_retire_stale RECORDS_JSON SERVING_JSON NOT_SERVING_JSON —
# make --apply CONVERGE.
#
# Writing is only half of "apply the current catalogue". Without this, a model
# the serving host has stopped offering keeps its alias and its *.env forever:
# the catalogue correctly drops it, but the shell alias stays invocable and
# points at a model that is no longer there. Applying a current catalogue has
# to mean the configuration MATCHES it — what is gone stops being offered.
#
# Deleting from a user's configuration deserves more care than adding to it, so
# a record is retired only when ALL THREE of these hold. Each one on its own
# would be too loose; together they make "provably stale" mean it.
#
#   1. IT IS OURS. The env file carries the CMA_PROVIDER_SOURCE marker that
#      only the --apply path above writes. A hand-authored provider, or one
#      belonging to any other provider family, is invisible to this sweep — not
#      because its name looks different, but because it never made the claim.
#      (Records written before this marker existed are also skipped. That is
#      deliberate: fail closed. A leftover alias is a nuisance; deleting
#      something we cannot prove we created is not.)
#
#   2. ITS HOST PROVED IT IS SERVING THIS RUN. This is the one that matters
#      most, and it asks for POSITIVE evidence — at least one model the host
#      named as one it is serving now (_CMA_HELIXLLM_SERVING_JQ) — not merely
#      that a reply arrived.
#
#      An unreachable host — laptop asleep, VPN down — produces an empty record
#      set. So does a host whose gateway is up while its backend is still
#      loading: /health answers 503 during the load, the option is dropped as
#      unavailable, and the listing comes back `{"data":[], "reason":...}`. So
#      does a host serving nothing but remote vendor passthroughs, whose local
#      backend is down. NONE of those is the serving layer reporting a
#      withdrawal — they are all "we cannot tell yet" — and treating any of
#      them as licence to delete wipes a user's entire working HelixLLM
#      configuration because a machine was briefly restarting. That is far
#      worse than the stale alias this function exists to remove.
#
#      So an ANSWER is not evidence either; only a host naming something it
#      serves is. Everything else is reported, not acted on. (This gate cost a
#      user their whole configuration once: the earlier version asked only "did
#      it reply?", and a reply arrives from a loading host within milliseconds
#      of the restart. See scripts/tests/repro_helixllm_loading_host.sh.)
#
#   3. THE HOST NO LONGER LISTS IT. The host is serving, and this model was not
#      among what it served. That — and only that — is the serving layer
#      telling us the model is gone.
#
# Removal goes through cmd_remove, the same path `prune` uses, so the config
# dir is MOVED aside rather than deleted and any session/plugin state in it
# survives. --dry-run reports without touching anything.
_cma_helixllm_retire_stale() {
  local records="$1" serving="$2" not_serving="${3:-[]}"
  local pdir; pdir="$(cma_providers_dir)"
  [[ -d "$pdir" ]] || return 0
  compgen -G "$pdir/*.env" >/dev/null 2>&1 || return 0

  local f pid src base n_retired=0 n_kept_unproven=0
  for f in "$pdir"/*.env; do
    [[ -f "$f" ]] || continue
    # Read the three fields in a subshell so nothing from the env file leaks
    # into this process (the same isolation cma_provider_write_env uses).
    # shellcheck disable=SC1090
    pid="$( ( unset CMA_PROVIDER_ID; set +e; . "$f" >/dev/null 2>&1; printf '%s' "${CMA_PROVIDER_ID:-}" ) )"
    src="$( ( unset CMA_PROVIDER_SOURCE; set +e; . "$f" >/dev/null 2>&1; printf '%s' "${CMA_PROVIDER_SOURCE:-}" ) )"
    base="$( ( unset CMA_PROVIDER_BASE_URL; set +e; . "$f" >/dev/null 2>&1; printf '%s' "${CMA_PROVIDER_BASE_URL:-}" ) )"

    # Gate 1: ours, and only ours.
    [[ "$src" == "helixllm-export" ]] || continue
    [[ -n "$pid" ]] || continue

    # Gate 2: its host proved it is SERVING this run. Neither silence nor a
    # reply that names nothing is evidence of removal.
    if ! jq -e --arg b "${base%/}" 'index($b) != null' <<<"$serving" >/dev/null 2>&1; then
      n_kept_unproven=$((n_kept_unproven + 1))
      if jq -e --arg b "${base%/}" 'index($b) != null' <<<"$not_serving" >/dev/null 2>&1; then
        cma_warn "helixllm: keeping '$pid' — its host ($base) replied but named no model it is serving, which is exactly how a host whose backend is still loading answers, so we cannot tell whether the model was withdrawn"
      else
        cma_warn "helixllm: keeping '$pid' — its host ($base) did not answer this run, so we cannot tell whether the model was withdrawn or the host is merely unreachable"
      fi
      continue
    fi

    # Gate 3: the host is serving, and did not list it.
    if jq -e --arg p "$pid" 'any(.[]; .provider_id == $p)' <<<"$records" >/dev/null 2>&1; then
      continue
    fi

    if (( DRY_RUN )); then
      printf '  would retire: %-44s [its host is serving, and no longer serves this model]\n' "$pid"
      n_retired=$((n_retired + 1))
      continue
    fi
    cma_log "retiring '$pid': $base is serving other models and no longer serves this one"
    cmd_remove "$pid"
    n_retired=$((n_retired + 1))
  done

  if (( n_retired > 0 )); then
    if (( DRY_RUN )); then
      cma_log "helixllm: $n_retired provider(s) would be retired; nothing changed"
    else
      cma_log "helixllm: retired $n_retired provider(s) no longer served (config dirs backed up, not deleted)"
    fi
  fi
  (( n_kept_unproven > 0 )) && \
    cma_log "helixllm: $n_kept_unproven provider(s) left in place because their host never proved it is serving (unreachable, or replying while it has nothing loaded) — re-run once it is serving again to converge them"
  return 0
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
    local vst sst flayer="" _verr _vlayer=""
    # KEEP THE REASON. The verifier writes one word to stdout and its
    # EXPLANATION to stderr, and this call site used to send that stderr to
    # /dev/null — so `claude-providers verify <id>` answered "unverified" and
    # nothing else, which is precisely the question an operator runs it to
    # answer. Every distinction the verifier draws (nothing listening vs an
    # untrusted certificate vs a reachable backend that cannot serve the
    # request vs no credential configured) died right here. Capture it and
    # print it on stderr for any non-verified verdict; stdout stays the single
    # verdict word, so callers that capture it are unaffected.
    #
    # LAYER: root-caused 2026-09-17 (systematic debugging, same finding as
    # cmd_sync above) - this call site previously wrote the literal
    # `existence` unconditionally for BOTH a "failed" and an "unverified"
    # verdict, regardless of what the verifier actually determined. Set
    # CMA_VERIFY_LAYER_FILE so providers-verify.sh's own emit() (its
    # doc-commented authoritative third output channel) tells us the REAL
    # layer; `unknown` — never a confident wrong guess — when it determined
    # none.
    _verr="$(mktemp "${TMPDIR:-/tmp}/cma-verify-reason.XXXXXX")"
    local _vlayer_f; _vlayer_f="$(mktemp "${TMPDIR:-/tmp}/cma-verify-layer.XXXXXX")"; : > "$_vlayer_f"
    vst="$( ( [[ -e "$CMA_KEYS_FILE" ]] && { set -a +u; . "$CMA_KEYS_FILE"; set +a; }; \
              CMA_VERIFY_LAYER_FILE="$_vlayer_f" bash "$VERIFY" --provider "$id" --model "$model" --key-var "$keyvar" ${base:+--base-url "$base"} 2>"$_verr" ) )" || true
    _vlayer="$(cat "$_vlayer_f" 2>/dev/null)"; rm -f "$_vlayer_f"
    [[ -z "$vst" ]] && vst=unverified
    if [[ "$vst" != "verified" ]] && [[ -s "$_verr" ]]; then
      while IFS= read -r _rl; do [[ -n "$_rl" ]] && cma_warn "$_rl"; done < "$_verr"
    fi
    if [[ "$vst" == "failed" ]]; then rm -f "$_verr"; cma_status_write "$id" failed "$model" "${_vlayer:-unknown}"; echo "failed"; return; fi
    if [[ "$vst" != "verified" ]]; then rm -f "$_verr"; cma_status_write "$id" unverified "$model" "${_vlayer:-unknown}"; echo "unverified"; return; fi
    sst="$( ( [[ -e "$CMA_KEYS_FILE" ]] && { set -a +u; . "$CMA_KEYS_FILE"; set +a; }; \
              bash "$SEMANTIC" --provider "$id" --model "$model" --key-var "$keyvar" ${base:+--base-url "$base"} 2>"$_verr" ) )" || true
    if [[ "$sst" == "unverified" ]]; then
      [[ -s "$_verr" ]] && while IFS= read -r _rl; do [[ -n "$_rl" ]] && cma_warn "$_rl"; done < "$_verr"
      rm -f "$_verr"; cma_status_write "$id" unverified "$model" semantic; echo "unverified"; return
    fi
    rm -f "$_verr"
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

# --- subcommand: sync-all-llmctl --------------------------------------------
#
# Full-catalog, deterministic, one-by-one sweep: switches llmctl through
# EVERY catalog profile (never a hardcoded profile-name list — the catalog
# is discovered LIVE from `llmctl plan --json`, the exact same source
# detect_llmctl_records already uses, so this stays correct as llmctl's own
# catalog evolves), and for each profile: switches to it, then reuses cmd_sync
# verbatim (the SAME chat-completion + tool-call verification probe already
# run for every other llmctl provider — never reimplemented) to register +
# verify it, recording ONE of three deterministic outcomes:
#
#   PASS  — `llmctl switch <profile>` succeeded AND cmd_sync's verification
#           left the provider's status "verified".
#   FAIL  — the switch succeeded but verification did not reach "verified"
#           (unverified/failed/absent) — a genuine defect worth investigating,
#           never silently skipped.
#   GATED — `llmctl switch <profile>` itself failed. This is a LEGITIMATE,
#           honest outcome — e.g. llmctl reporting the host cannot even start
#           that profile in isolation (insufficient RAM/VRAM) — never a bug to
#           hide and never a reason to omit the profile from the report; cmd_sync
#           is never invoked for a GATED profile (there is nothing running to
#           verify).
#
# cmd_sync's own resolve_records() call re-probes ALL currently-running llmctl
# profiles via detect_llmctl_records — a `cma_die` there (e.g. the switch
# reported success but the profile never actually answered /v1/models in
# time) is isolated to THIS profile's subshell, so one profile's failure can
# NEVER abort the sweep — that is the entire point of validating each
# profile deterministically, one by one.
#
# Binary resolution mirrors detect_llmctl_records as closely as a standalone
# subcommand reasonably can: CMA_LLMCTL_BIN env override first, then the
# `bin` field of CMA_LLMCTL_PINS_FILE (defaulting to this script's own
# providers/llmctl.json pins file, exactly like detect_llmctl_records), then
# the bare `llmctl` name resolved off PATH.
cmd_sync_all_llmctl() {
  local _lc_json="${CMA_LLMCTL_PINS_FILE:-$LIB_DIR/providers/llmctl.json}"
  local _lc_bin="${CMA_LLMCTL_BIN-}"
  if [[ -z "$_lc_bin" ]]; then
    if [[ -f "$_lc_json" ]] && command -v jq >/dev/null 2>&1; then
      _lc_bin="$(jq -r '.bin // empty' "$_lc_json" 2>/dev/null)" || _lc_bin=""
      [[ "$_lc_bin" != "null" ]] || _lc_bin=""
    fi
  fi
  : "${_lc_bin:=llmctl}"
  command -v jq >/dev/null 2>&1 || cma_die "sync-all-llmctl needs jq"
  command -v "$_lc_bin" >/dev/null 2>&1 \
    || cma_die "llmctl binary ($_lc_bin) not found -- cannot run the full-catalog sweep (install llmctl, or set CMA_LLMCTL_BIN)"

  local _plan_timeout="${CMA_LLMCTL_PLAN_TIMEOUT:-10}" _plan=""
  if command -v timeout >/dev/null 2>&1; then
    _plan="$(timeout "$_plan_timeout" "$_lc_bin" plan --json 2>/dev/null)" || _plan=""
  else
    _plan="$("$_lc_bin" plan --json 2>/dev/null)" || _plan=""
  fi
  printf '%s' "$_plan" | jq -e '.profiles | type == "object"' >/dev/null 2>&1 \
    || cma_die "'$_lc_bin plan --json' produced no/invalid catalog -- cannot discover the profile set"

  local -a _profiles=()
  while IFS= read -r _p; do [[ -n "$_p" ]] && _profiles+=("$_p"); done \
    < <(jq -r '.profiles | keys[]' <<<"$_plan" 2>/dev/null)
  (( ${#_profiles[@]} )) || cma_die "llmctl catalog has zero profiles (see: $_lc_bin models list)"

  cma_log "sync-all-llmctl: sweeping ${#_profiles[@]} catalog profile(s): ${_profiles[*]}"

  local -a _rows=()
  local _p _pid _sw_out _sw_rc _sync_out _sync_rc _verdict _detail
  for _p in "${_profiles[@]}"; do
    _pid="llmctl-$_p"
    cma_log "sync-all-llmctl: [$_pid] switching..."
    _sw_out="$("$_lc_bin" switch "$_p" 2>&1)"; _sw_rc=$?
    if (( _sw_rc != 0 )); then
      _detail="llmctl switch exit $_sw_rc: $(printf '%s' "$_sw_out" | tr '\n' ' ' | cut -c1-200)"
      cma_warn "sync-all-llmctl: [$_pid] GATED -- $_detail"
      _rows+=("$_p"$'\t'"GATED"$'\t'"$_detail")
      continue
    fi
    cma_log "sync-all-llmctl: [$_pid] switched -- verifying (chat-completion + tool-call)..."
    # A subshell isolates cmd_sync's own cma_die (unmatched/unresolved
    # provider — e.g. switched but never answered /v1/models in time) so one
    # profile's failure can NEVER abort the whole sweep.
    _sync_out="$( ( cmd_sync "$_pid" ) 2>&1 )"; _sync_rc=$?
    _verdict="$(cma_status_read "$_pid")"
    if [[ "$_verdict" == "verified" ]]; then
      _rows+=("$_p"$'\t'"PASS"$'\t'"verified")
      cma_log "sync-all-llmctl: [$_pid] PASS (verified)"
    else
      _detail="$_verdict"
      (( _sync_rc != 0 )) && _detail="$_verdict (sync exit $_sync_rc): $(printf '%s' "$_sync_out" | tail -1 | cut -c1-200)"
      _rows+=("$_p"$'\t'"FAIL"$'\t'"$_detail")
      cma_warn "sync-all-llmctl: [$_pid] FAIL -- $_detail"
    fi
  done

  printf '\n%-16s %-8s %s\n' "profile" "verdict" "detail"
  local _row _rp _rv _rd
  for _row in "${_rows[@]}"; do
    IFS=$'\t' read -r _rp _rv _rd <<<"$_row"
    printf '%-16s %-8s %s\n' "$_rp" "$_rv" "$_rd"
  done

  local _n_pass=0 _n_fail=0 _n_gated=0
  for _row in "${_rows[@]}"; do
    case "$_row" in
      *$'\t'PASS$'\t'*)  _n_pass=$((_n_pass+1)) ;;
      *$'\t'FAIL$'\t'*)  _n_fail=$((_n_fail+1)) ;;
      *$'\t'GATED$'\t'*) _n_gated=$((_n_gated+1)) ;;
    esac
  done
  cma_log "sync-all-llmctl: done -- $_n_pass PASS, $_n_fail FAIL, $_n_gated GATED (of ${#_profiles[@]})"
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
  # CHECKED is not decoration. A verdict is a claim about a REMOTE endpoint at
  # ONE moment, and this listing is the surface an operator reads most — so a
  # verdict rendered with no age reads as present-tense success forever. That
  # really happened: `helixllm-gateway` showed STATUS `verified` here while a
  # live probe of that exact endpoint answered HTTP 401. The record ALREADY
  # carried `checked_at`; only the renderer never looked.
  #
  # WHY A MARKER AND NOT A RE-PROBE. Re-verifying on read would make `list` — a
  # command people run reflexively — do N network round-trips against every
  # configured backend, several of them remote, before printing a line. The
  # verdict's AGE is local, free, and already recorded; showing it lets the
  # operator decide whether to trust it, and `claude-providers verify <id>`
  # remains the one command that actually re-probes.
  printf '%-14s %-16s %-15s %-8s %-12s %-24s\n' ALIAS PROVIDER STATUS CHECKED LAYER STRONG_MODEL
  local f
  for f in "$pdir"/*.env; do
    local id status layer checked age age_s keep=0
    # shellcheck disable=SC1090
    id="$( ( set -a; . "$f"; set +a; printf '%s' "$CMA_PROVIDER_ID" ) )"
    status="$(cma_status_read "$id")"
    case "$filter" in
      verified) [[ "$status" == "verified" ]] && keep=1 ;;
      faulty)   [[ "$status" != "verified" ]] && keep=1 ;;
      all)      keep=1 ;;
    esac
    (( keep )) || continue
    # One read of the cache serves both columns (layer was already paying for it),
    # and the row is split IN THE SHELL rather than by piping it through `cut`
    # twice: this loop runs once per provider and every subshell here is a fork
    # the operator waits for on a command people run reflexively.
    local srow _s_id _s_status _s_model
    srow="$(cma_status_all | awk -F'\t' -v i="$id" '$1==i{print; exit}')"
    # A herestring always supplies a trailing newline, so this `read` returns 0
    # (leaving every field empty) even when the record is absent — it cannot
    # abort the listing under `set -e`, which the alias-less-provider case in
    # tests/test_providers.sh covers.
    IFS=$'\t' read -r _s_id _s_status _s_model checked layer <<<"$srow"
    # MEASURE ONCE, DERIVE TWICE. The human string and the staleness verdict are
    # two readings of ONE age; asking each helper to parse the timestamp itself
    # forked `date` twice per row for the same number. Measured on a 40-row
    # listing: ~4.72 s -> ~2.83 s (baseline without the column, ~1.64 s).
    age_s="$(cma_status_age_seconds "$checked")"
    age="$(cma_status_age_human_s "$age_s")"
    # A PROVABLY old verdict is prefixed so the bare word `verified` cannot
    # appear on a row whose evidence is past the horizon. An UNKNOWN age is not
    # marked stale — it is unknown, and the `?` in CHECKED says exactly that.
    if cma_status_is_stale_s "$age_s"; then status="stale:$status"; fi
    # shellcheck disable=SC1090
    ( set -a; . "$f"; set +a
      # `|| alias=""` is LOAD-BEARING: under `set -euo pipefail` a no-match grep
      # (exit 1, propagated by pipefail) would abort the subshell — and the whole
      # listing — for any provider whose alias line is absent.
      alias="$(grep -E "cma_run_provider $CMA_PROVIDER_ID(\"| )" "$ALIAS_FILE" 2>/dev/null | sed -E 's/^alias ([^=]+)=.*/\1/' | head -1)" || alias=""
      printf '%-14s %-16s %-15s %-8s %-12s %-24s\n' \
        "${alias:-?}" "$CMA_PROVIDER_ID" "$status" "$age" "${layer:--}" "$CMA_PROVIDER_MODEL" )
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
  # Kimi twin alias is NOT matched by the grep above (`cma_run_kimi_provider`
  # contains no `cma_run_provider` substring), so drop it explicitly. kc-* and
  # kimi-* ids never have a twin, so the default `kimi-$id` is a no-op there.
  if [[ "$id" != kc-* && "$id" != kimi-* ]]; then
    grep -q "^alias kimi-$id=" "$ALIAS_FILE" 2>/dev/null && cma_remove_alias "kimi-$id"
  fi
  rm -f "$f"
  local cdir="$HOME/${CMA_PROVIDER_DIR_PREFIX}${id}"
  if [[ -d "$cdir" ]]; then
    mv "$cdir" "${cdir}.preunify.$(date +%Y%m%d%H%M%S)"
    cma_log "backed up + removed config dir $cdir"
  fi
  # Kimi twin config dir backs up alongside the Claude one (same preunify
  # convention; removed with `remove`, restored with a plain rename).
  local kdir="$HOME/.kimi-prov-$id"
  if [[ -d "$kdir" ]]; then
    mv "$kdir" "${kdir}.preunify.$(date +%Y%m%d%H%M%S)"
    cma_log "backed up + removed kimi config dir $kdir"
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
  # One-time, idempotent Kimi legacy id rename (kimi-* -> kc-*), same rationale
  # and ordering as cmd_sync: repair pre-v1.27.0 disk state before re-resolving.
  (( DRY_RUN )) || cmd_migrate_names

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

      # Kimi Code twin for multi aliases: one kimi-<aname> alias + config.toml
      # per generated Claude alias (same shared status gate; excluded kc-*/kimi-*
      # ids are a no-op). Only the strong model is forwarded on the Kimi side.
      if (( KIMI_ALIASES )); then
        _cma_kimi_twin_alias "$aname" || true
        _cma_kimi_render_config "$aname" "$keyvar" "$alias_transport" "$alias_url" "$strong" "$alias_ctx" || true
      fi

      # Pi CLI twin for multi aliases: one pi-<aname> alias + config.toml
      # per generated Claude alias (same shared status gate; excluded pi-*/kimi-*/kc-*
      # ids are a no-op). Only the strong model is forwarded on the Pi side.
      if (( PI_ALIASES )); then
        _cma_pi_twin_alias "$aname" || true
        _cma_pi_render_config "$aname" "$keyvar" "$alias_transport" "$alias_url" "$strong" "$alias_ctx" || true
      fi

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
  sync|list|list-all|list-faulty|show|verify|remove|prune|add|helixllm-export|migrate-names) SUBCMD="$1"; shift ;;
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
    --apply) APPLY=1; shift ;;
    --host) HELIXLLM_HOST_ARGS+=("$2"); shift 2 ;;
    --include-paid) INCLUDE_PAID=1; shift ;;
    --max-aliases) MAX_ALIASES="$2"; shift 2 ;;
    --min-score) MIN_SCORE="$2"; shift 2 ;;
    --verify-concurrency) VERIFY_CONCURRENCY="$2"; shift 2 ;;
    --kimi-aliases) KIMI_ALIASES=1; shift ;;
    --no-kimi-aliases) KIMI_ALIASES=0; shift ;;
    --pi-aliases) PI_ALIASES=1; shift ;;
    --no-pi-aliases) PI_ALIASES=0; shift ;;
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
      # The kimi twin is an alias line like any other, and this loop is what
      # REBUILDS the alias file — so omitting it here meant that after the alias
      # file was lost or rotated, the session hook faithfully restored every
      # claude alias and silently restored no kimi twin at all. Measured: with a
      # synced provider, deleting the alias file and running --refresh-aliases
      # gave back `alias beta` and not `alias kimi-beta`.
      #
      # Only the alias LINE is written here, never the config.toml: this path is
      # the no-network/no-probe fast path that runs on every interactive shell
      # start, and rendering config.toml would make it read the keys file and
      # write a secret-bearing artifact on every shell.
      #
      # RESTORE ONLY WHERE THE CONFIG ALREADY EXISTS, and that gate carries the
      # weight of this whole block. RESTORE is the operative word: this path may
      # put back a twin a sync established, and may not INVENT one.
      #
      #  1. It is what keeps refresh a NO-OP. The `-f` test is the difference
      #     between "this shell start rewrites nothing" and "this shell start
      #     rewrites the alias file". Ungated, EVERY record without a twin line
      #     — one seeded by cma_provider_write_alias alone, one written before
      #     twins existed, one synced under --no-kimi-aliases — makes the first
      #     shell start after that state a whole-file rewrite. That is not a
      #     cosmetic idempotence nicety: the no-op guard is precisely what keeps
      #     steady-state shell starts OUT of the concurrent-writer race that
      #     shredded the live aliases.sh on 2026-07-20 (see the header of
      #     tests/test_alias_file_concurrency.sh), and this session hook fires on
      #     every single interactive shell. Ungated it FAILS that suite's
      #     "the refresh fast path is a no-op too" case, by design of the case.
      #
      #  2. It honours --no-kimi-aliases. All three emitting paths (cmd_sync,
      #     the multi-sync leg, helixllm-export --apply) pair the twin alias and
      #     the config under the SAME `(( KIMI_ALIASES ))` gate, so the config's
      #     presence records what that flag decided for this record. Ungated,
      #     a record synced with --no-kimi-aliases grew a twin back on the next
      #     shell start, because KIMI_ALIASES defaults to 1 here (:69) and the
      #     session hook passes no override.
      #
      #  3. It cannot manufacture drift. kimi-providers.sh defines a REAL twin
      #     as BOTH artifacts on disk (alias line AND config.toml) and reports
      #     anything else as `no-twin`. This path can only ever restore the
      #     alias half; emitting it without the config half would fabricate the
      #     exact half-wired state that tool exists to flag — an alias that
      #     lists but cannot launch, which is what the operator hit with
      #     `kimi-helixllm-anton-…`.
      #
      # The gate FAILS CLOSED: no config, no alias — never an alias that
      # cma_run_kimi_provider would refuse anyway. A record whose config was
      # deleted independently is repaired by `sync` (or, for the export class,
      # `helixllm-export --apply`), which is the only writer of that file, and
      # both then restore the twin here on the next shell start.
      if (( KIMI_ALIASES )) && [[ -f "$HOME/.kimi-prov-$_rid/config.toml" ]]; then
        _cma_kimi_twin_alias "$_rid" 2>/dev/null || true
      fi
      if (( PI_ALIASES )) && [[ -f "$HOME/.pi-prov-$_rid/models.json" ]]; then
        _cma_pi_twin_alias "$_rid" 2>/dev/null || true
      fi
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
  helixllm-export) cmd_helixllm_export ;;
  list)        cmd_list ;;
  list-all)    cmd_list_all ;;
  list-faulty) cmd_list_faulty ;;
  show)        cmd_show "${POSITIONAL[@]:-}" ;;
  verify)      cmd_verify "${POSITIONAL[@]:-}" ;;
  sync-all-llmctl) cmd_sync_all_llmctl ;;
  remove)      cmd_remove "${POSITIONAL[@]:-}" ;;
  prune)       cmd_prune ;;
  add)         cmd_add "${POSITIONAL[@]:-}" ;;
  migrate-names) cmd_migrate_names ;;
esac

fi  # end source-guard (BASH_SOURCE == $0)
