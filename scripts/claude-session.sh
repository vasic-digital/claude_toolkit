#!/usr/bin/env bash
# claude-session.sh — derive per-project session launch flags for the alias
# wrappers (cma_run / cma_run_provider).
#
# Each project (identified by its root directory) gets ONE long-lived Claude
# session so launching any alias inside it resumes the same ongoing work, or
# creates it the first time. The session is named after the root dir in
# lowercase kebab-case.
#
# Subcommands:
#   flags <config_dir>          Print launch flags for `claude` on stdout:
#                               either `--resume <sid>` (session exists) or
#                               `--session-id <sid> --name <kebab>` (first run).
#                               Picks the MOST RECENTLY ACTIVE *resumable*
#                               session (degenerate assistant-free reload
#                               debris is skipped — see _cma_pick_session).
#                               Side effect: trust the project in <config_dir>.
#   name  [path]                Print the kebab-case session name for a path.
#   id    [path]                Print the stable session UUID for a path.
#   latest-id [config_dir]      Print most-recently-active session UUID.
#   context-size <dir> [sid]    Print the session's estimated current context
#                               tokens (last assistant usage input+cache sum).
#   color <label>              Print the mapped color for an alias label.
#   hint  <label> [path]        Print a human color/session hint on stderr.
#
# All subcommands default <path> to $PWD's project root (git toplevel if any,
# else $PWD). Designed to be sourced-free: a normal PATH script with a shebang,
# so it runs under a known bash regardless of the user's interactive shell.
set -euo pipefail

# Claude Code's /color palette (verified from the native binary: the `Ky`
# array). Order is load-bearing for the deterministic label->color mapping.
CMA_COLORS=(red blue green yellow purple orange pink cyan)

# Resolve the project root: prefer the git working-tree root so every dir in a
# repo shares one session; fall back to the given path (or $PWD).
cma_project_root() {
  local p="${1:-$PWD}"
  local root
  if root="$(cd "$p" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)"; then
    printf '%s\n' "$root"
  else
    ( cd "$p" 2>/dev/null && pwd -P ) || printf '%s\n' "$p"
  fi
}

# Sanitize a user-facing session name: lowercase, collapse non-alnum to single
# dash, trim leading/trailing dashes.
cma_session_name() {
  local root base
  root="$(cma_project_root "${1:-$PWD}")"
  base="$(basename "$root")"
  printf '%s\n' "$base" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[^a-z0-9]+/-/g; s/-+/-/g; s/^-//; s/-$//'
}

# Stable RFC-4122-shaped UUID derived from the project root path.
cma_session_id() {
  local root hash
  root="$(cma_project_root "${1:-$PWD}")"
  if command -v md5sum >/dev/null 2>&1; then
    hash="$(printf '%s' "cma-session:$root" | md5sum | cut -d' ' -f1)"
  else
    hash="$(printf '%s' "cma-session:$root" | md5 -q)"
  fi
  printf '%s-%s-%s-%s-%s\n' \
    "${hash:0:8}" "${hash:8:4}" "${hash:12:4}" "${hash:16:4}" "${hash:20:12}"
}

# Deterministic alias-label -> color.
cma_label_color() {
  local label="${1:-}" hash num
  if command -v md5sum >/dev/null 2>&1; then
    hash="$(printf '%s' "$label" | md5sum | cut -d' ' -f1)"
  elif command -v md5 >/dev/null 2>&1; then
    hash="$(printf '%s' "$label" | md5 -q)"
  else
    hash="$(printf '%s' "$label" | cksum | cut -d' ' -f1)"
  fi
  num=$(( 0x${hash:0:6} % ${#CMA_COLORS[@]} ))
  printf '%s\n' "${CMA_COLORS[$num]}"
}

# Mark the project as trusted in <config_dir>/.claude.json
cma_trust_project() {
  local config_dir="$1" root="$2" f tmp
  # An empty config dir (e.g. a no-arg call with CLAUDE_CONFIG_DIR unset) has
  # nothing to trust into — return quietly rather than writing /.claude.json.
  [[ -n "$config_dir" ]] || return 0
  f="$config_dir/.claude.json"
  command -v jq >/dev/null 2>&1 || return 0
  [[ -f "$f" ]] || printf '{}\n' > "$f" 2>/dev/null || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX" 2>/dev/null)" || return 0
  if jq --arg p "$root" '
        .projects = (.projects // {})
        | .projects[$p] = ((.projects[$p] // {}) + {hasTrustDialogAccepted: true})
      ' "$f" > "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
    mv "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

# Find the MOST RECENTLY active session UUID for a project directory.
# Scans *.jsonl (excluding subagents/), sorts by mtime descending.
# Falls back to the deterministic UUID on first launch.

# Degenerate-session guard (2026-09-03 compaction-loop cascade): the store is
# SHARED across every alias, and resolution used to be purely mtime-based, so a
# launch that loaded a large resumed context under a smaller provider window
# and died with ZERO assistant events left a fresh-mtime transcript that the
# NEXT alias launch then resumed — the cascade that made the compaction loop
# endless (35 near-identical ~319KB corpses measured on the live store). A
# transcript is resumable when it carries an assistant event, OR is small: a
# small assistant-free file is a one-prompt session the user simply walked
# away from (continuity must survive); a LARGE assistant-free file is reload
# debris that can only die the same way again. The threshold is bytes, not
# tokens, because a died-on-load transcript has no usage line to measure.
# 0 / negative / non-numeric values mean "use default" — 0 would classify
# every non-empty assistant-free transcript as dead debris and silently break
# one-prompt continuity.
CMA_SESSION_DEAD_BYTES="${CMA_SESSION_DEAD_BYTES:-65536}"
case "$CMA_SESSION_DEAD_BYTES" in
  ''|0|*[!0-9]*) CMA_SESSION_DEAD_BYTES=65536 ;;
esac

# Assistant event: a JSON-object line (starts with `{"key":`) carrying an
# UNESCAPED "type":"assistant". Real Claude Code transcripts put "type" AFTER the
# large "message" object (and old ones before it), so it cannot be anchored to
# the line start. Debris that does not start as a JSON object, or that holds the
# substring only escaped inside a string (\"type\":\"assistant\"), is rejected.
_CMA_ASSIST_RE='^\{("[A-Za-z]+":.*)?"type":"assistant"'

_cma_session_resumable() {
  local f="$1" sz
  [[ -f "$f" ]] || return 1
  sz="$(wc -c < "$f" 2>/dev/null || printf '0')"
  if [ "$sz" -le "$CMA_SESSION_DEAD_BYTES" ]; then return 0; fi
  # Anchored to the JSONL object start: a pasted/debris line that merely
  # CONTAINS the substring mid-line must not count as an assistant event.
  if command -v jq >/dev/null 2>&1; then
    # Candidate lines must also PARSE as JSON with a top-level type of
    # assistant: pasted debris that is not a valid event never counts.
    # pipefail off: head closing the pipe SIGPIPEs grep (141) on many matches,
    # which must not turn a successful jq verdict into "not resumable".
    ( set +o pipefail
      grep -E "$_CMA_ASSIST_RE" "$f" 2>/dev/null | head -200 | \
        jq -nRe 'first(inputs | fromjson? | select(.type == "assistant")) | true' >/dev/null 2>&1 ) || return 1
  else
    grep -Eq "$_CMA_ASSIST_RE" "$f" 2>/dev/null
  fi
}

# Print the newest RESUMABLE session id for a session dir, nothing when every
# transcript is degenerate. Callers decide the no-session behaviour.
_cma_pick_session() {
  local sess_dir="$1" f latest=""
  [[ -d "$sess_dir" ]] || return 1
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if _cma_session_resumable "$f"; then latest="$f"; break; fi
  done <<CMA_PICK_EOF
$(ls -t "$sess_dir"/*.jsonl 2>/dev/null | grep -v '/subagents/' || true)
CMA_PICK_EOF
  [[ -n "$latest" ]] || return 1
  basename "$latest" .jsonl
}

cma_latest_session_id() {
  local config_dir="${1:-${CLAUDE_CONFIG_DIR:-}}" root="${2:-}"
  root="${root:-$PWD}"
  local proj_slug sess_dir latest
  proj_slug="$(printf '%s' "$root" | sed -E 's/[^A-Za-z0-9]/-/g')"
  sess_dir="$config_dir/projects/$proj_slug"
  latest="$(_cma_pick_session "$sess_dir" 2>/dev/null || true)"
  if [[ -n "${latest:-}" ]]; then
    printf '%s\n' "$latest"
  else
    cma_session_id "$root"
  fi
}

# Print the most-recent RESUMABLE session UUID ONLY when one exists for this
# project (empty otherwise). Used by the wrapper's args resume-injection:
# injecting --resume with the deterministic-but-never-created fallback UUID
# makes Claude Code fail hard ("No conversation found with session ID").
cma_existing_session_id() {
  local config_dir="${1:-${CLAUDE_CONFIG_DIR:-}}" root="${2:-}"
  root="${root:-$PWD}"
  local proj_slug sess_dir latest
  proj_slug="$(printf '%s' "$root" | sed -E 's/[^A-Za-z0-9]/-/g')"
  sess_dir="$config_dir/projects/$proj_slug"
  latest="$(_cma_pick_session "$sess_dir" 2>/dev/null || true)"
  [[ -n "${latest:-}" ]] && printf '%s\n' "$latest"
  return 0
}

# --- org-switch guard (v1.33.2) ---------------------------------------------
# Each claudeN alias is a DIFFERENT Anthropic organization, yet claude-unify
# shares projects/ (so one session JSONL is resumed under another org).
# Thinking-block signatures are organization-bound: Claude Code discards them
# on resume and re-reads the whole session uncached ("Claude can't use thinking
# from another organization"). That cost is UNAVOIDABLE at API level for an
# unmodified session; the toolkit can only (a) warn BEFORE it happens, with the
# size, (b) point at a same-org alias, (c) on explicit opt-in resume a
# sanitized COPY (thinking blocks dropped; original never touched or deleted).
_cma_valid_sid() { [[ "${1:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }

# Print the organizationUuid of an alias config dir (empty when unknown).
cma_org_id() {
  local cd="${1:-}" f="${1:-}/.claude.json" v=""
  [[ -n "$cd" && -r "$f" ]] && command -v jq >/dev/null 2>&1 || return 0
  v="$(jq -r '.oauthAccount.organizationUuid // empty' "$f" 2>/dev/null || true)"
  [[ "$v" =~ ^[A-Za-z0-9-]{8,64}$ ]] && printf '%s\n' "$v"
  return 0
}

_cma_org_dir() {
  local cd="${1:-}" d t
  if [[ -n "${CMA_SESSION_ORG_DIR:-}" ]]; then d="$CMA_SESSION_ORG_DIR"
  else
    # one-level symlink resolution via plain readlink (no `readlink -f`: absent on BSD/macOS)
    d="$cd/projects"
    if [[ -L "$d" ]]; then
      t="$(readlink "$d" 2>/dev/null || true)"
      if [[ -n "$t" ]]; then case "$t" in /*) d="$t" ;; *) d="$cd/$t" ;; esac; fi
    fi
    d="$(dirname "$d")/session-orgs"
  fi
  printf '%s\n' "$d"
}

# Another alias dir whose org equals $2 (first match, excluding $1).
_cma_same_org_alias() {
  local self="${1:-}" org="${2:-}" d o
  for d in "$HOME"/.claude-claude*; do
    [[ -d "$d" && "$d" != "$self" ]] || continue
    o="$(cma_org_id "$d")"; [[ -n "$o" && "$o" == "$org" ]] && { basename "$d" | sed 's/^\.claude-//'; return 0; }
  done
  return 0
}

# Non-destructive sanitized fork: <new>.jsonl without thinking blocks.
# usage: cma_sanitize_fork <src.jsonl> <new_sid>   (prints new path)
cma_sanitize_fork() {
  local src="${1:-}" nsid="${2:-}" out
  _cma_valid_sid "$nsid" && [[ -f "$src" ]] || return 2
  out="$(dirname "$src")/$nsid.jsonl"
  [[ -e "$out" ]] && return 3
  python3 - "$src" "$out" "$nsid" <<'PY' || return 4
import json,sys,os
src,out,nsid=sys.argv[1:4]
lines=[];drop={}
for raw in open(src,encoding='utf-8',errors='surrogateescape'):
    raw=raw.rstrip('\n'); o=None
    try: o=json.loads(raw)
    except Exception: pass
    if isinstance(o,dict):
        m=o.get('message')
        c=m.get('content') if isinstance(m,dict) else None
        if isinstance(c,list):
            k=[b for b in c if not (isinstance(b,dict) and b.get('type') in('thinking','redacted_thinking'))]
            if len(k)!=len(c):
                if not k and o.get('uuid'):
                    drop[o['uuid']]=o.get('parentUuid'); continue
                m['content']=k
    lines.append((raw,o))
tmp=out+'.tmp.%d'%os.getpid()
fd=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'w',encoding='utf-8',errors='surrogateescape') as f:
    for raw,o in lines:
        if isinstance(o,dict):
            p=o.get('parentUuid'); n=0
            while p in drop and n<100000: p=drop[p]; n+=1
            if 'parentUuid' in o: o['parentUuid']=p
            if 'sessionId' in o: o['sessionId']=nsid
            raw=json.dumps(o,ensure_ascii=False,separators=(',',':'))
        f.write(raw+'\n')
try:
    os.link(tmp,out)
except FileExistsError:
    os.unlink(tmp); sys.exit(3)
except OSError:
    os.unlink(tmp); raise
os.unlink(tmp)
PY
  printf '%s\n' "$out"
}

# org-guard <config_dir> <flags-string>
# Prints the (possibly replaced) flags on stdout; warnings on stderr.
# Never fails the launch: any internal problem returns the flags unchanged.
cma_org_guard() {
  local cd="${1:-}" flags="${2:-}" sid="" cur rec dir prev prevalias label root slug src nsid tok same
  if [[ "$flags" =~ --resume\ ([0-9a-fA-F-]{36}) ]]; then sid="${BASH_REMATCH[1]}"; fi
  if [[ -z "$sid" ]] || ! _cma_valid_sid "$sid"; then printf '%s\n' "$flags"; return 0; fi
  cur="$(cma_org_id "$cd")"
  if [[ -z "$cur" ]]; then printf '%s\n' "$flags"; return 0; fi
  label="$(basename "$cd")"; label="${label#.claude-}"
  dir="$(_cma_org_dir "$cd")"; rec="$dir/$sid"
  if [[ -f "$rec" ]]; then
    prev="$(sed -n 's/^org=//p' "$rec" | head -1)"; prevalias="$(sed -n 's/^alias=//p' "$rec" | head -1)"
  fi
  if [[ -n "${prev:-}" && "$prev" != "$cur" ]]; then
    root="$(cma_project_root "$PWD")"
    slug="$(printf '%s' "$root" | sed -E 's/[^A-Za-z0-9]/-/g')"
    tok="$("$0" context-size "$cd" "$sid" 2>/dev/null || true)"
    {
      printf 'claude-session: WARNING — this session was last used by alias "%s" (organization %s…) and you are launching "%s" (organization %s…).\n' \
        "${prevalias:-?}" "${prev:0:8}" "$label" "${cur:0:8}"
      printf '  Thinking blocks are organization-bound: Claude Code will discard them and re-read the session UNCACHED%s.\n' \
        "${tok:+ (~$tok tokens of context)}"
      printf '  This cannot be avoided at API level for the unmodified session.\n'
      same="$(_cma_same_org_alias "$cd" "$prev")"
      [[ -n "$same" ]] && printf '  Same-org alias (no penalty): %s\n' "$same"
      printf '  Opt-in: CMA_SESSION_SANITIZE_ON_ORG_CHANGE=1 resumes a sanitized COPY (thinking dropped, original kept).\n'
    } >&2
    if [[ "${CMA_SESSION_SANITIZE_ON_ORG_CHANGE:-0}" == "1" ]]; then
      src="$cd/projects/$slug/$sid.jsonl"
      nsid="$(python3 -c 'import uuid;print(uuid.uuid4())' 2>/dev/null || true)"
      if _cma_valid_sid "$nsid" && cma_sanitize_fork "$src" "$nsid" >/dev/null 2>&1; then
        printf 'claude-session: resuming sanitized copy %s (original %s untouched).\n' "$nsid" "$sid" >&2
        flags="${flags//$sid/$nsid}"; sid="$nsid"
      else
        printf 'claude-session: sanitized fork failed; resuming the original.\n' >&2
      fi
    fi
  fi
  # record the org of THIS launch (atomic, private); failure is non-fatal
  ( umask 077; mkdir -p "$dir" 2>/dev/null && { printf 'org=%s\nalias=%s\nts=%s\n' "$cur" "$label" "$(date +%s)" > "$rec.tmp.$$" && mv -f "$rec.tmp.$$" "$rec"; } ) 2>/dev/null || true
  printf '%s\n' "$flags"
}

main() {
  local cmd="${1:-flags}"; shift 2>/dev/null || true
  case "$cmd" in
    name)  cma_session_name "${1:-$PWD}" ;;
    id)    cma_session_id "${1:-$PWD}" ;;
    color) cma_label_color "${1:-}" ;;
    existing-id)
      local config_dir="${1:-${CLAUDE_CONFIG_DIR:-}}" root
      root="$(cma_project_root "$PWD")"
      cma_existing_session_id "$config_dir" "$root"
      ;;
    latest-id)
      local config_dir="${1:-${CLAUDE_CONFIG_DIR:-}}" root
      root="$(cma_project_root "$PWD")"
      cma_latest_session_id "$config_dir" "$root"
      ;;
    context-size)
      # Estimated CURRENT context tokens of a session: the last assistant
      # usage's input+cache_creation+cache_read sum (that triple IS the prompt
      # size of the last completed turn; output is the reply, not the context).
      # Empty output when unknown — callers treat empty as "no data", never 0.
      local config_dir="${1:-${CLAUDE_CONFIG_DIR:-}}" sid="${2:-}" root
      root="$(cma_project_root "$PWD")"
      if [[ -z "$sid" ]]; then
        sid="$(cma_existing_session_id "$config_dir" "$root")"
      fi
      [[ -n "$sid" ]] || exit 0
      local proj_slug sess_file
      proj_slug="$(printf '%s' "$root" | sed -E 's/[^A-Za-z0-9]/-/g')"
      sess_file="$config_dir/projects/$proj_slug/$sid.jsonl"
      [[ -f "$sess_file" ]] || exit 0
      command -v jq >/dev/null 2>&1 || exit 0
      # grep|tail|jq under pipefail: a no-assistant transcript makes grep exit
      # 1 — the || true keeps that an empty print, never an abort. Anchored to
      # the JSONL object start, matching _cma_session_resumable, so a mid-line
      # substring (pasted debris) is not mistaken for an assistant event.
      grep -E "$_CMA_ASSIST_RE" "$sess_file" 2>/dev/null | tail -20 | \
        jq -rR 'fromjson? | select(.type == "assistant") | (.message.usage // {}) | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)) | select(. > 0)' 2>/dev/null | tail -1 || true
      ;;
    flags)
      local config_dir="${1:-${CLAUDE_CONFIG_DIR:-}}" root sid name proj_slug sess_file
      root="$(cma_project_root "$PWD")"
      sid="$(cma_latest_session_id "$config_dir" "$root")"
      name="$(cma_session_name "$root")"
      cma_trust_project "$config_dir" "$root" || true
      proj_slug="$(printf '%s' "$root" | sed -E 's/[^A-Za-z0-9]/-/g')"
      sess_file="$config_dir/projects/$proj_slug/$sid.jsonl"
      if [[ -f "$sess_file" ]]; then
        printf -- '--resume %s --name %s\n' "$sid" "$name"
      else
        printf -- '--session-id %s --name %s\n' "$sid" "$name"
      fi
      ;;
    org-id)    cma_org_id "${1:-${CLAUDE_CONFIG_DIR:-}}" ;;
    org-guard) cma_org_guard "${1:-${CLAUDE_CONFIG_DIR:-}}" "${2:-}" ;;
    sanitize-fork)
      # sanitize-fork <config_dir> [sid]: opt-in manual fork; prints new sid.
      local config_dir="${1:-${CLAUDE_CONFIG_DIR:-}}" sid="${2:-}" root slug nsid
      root="$(cma_project_root "$PWD")"; slug="$(printf '%s' "$root" | sed -E 's/[^A-Za-z0-9]/-/g')"
      [[ -n "$sid" ]] || sid="$(cma_existing_session_id "$config_dir" "$root")"
      _cma_valid_sid "$sid" || { echo "claude-session: no resumable session" >&2; return 2; }
      nsid="$(python3 -c 'import uuid;print(uuid.uuid4())')"
      cma_sanitize_fork "$config_dir/projects/$slug/$sid.jsonl" "$nsid" >/dev/null && printf '%s\n' "$nsid"
      ;;
    apply-color)
      local config_dir="${1:-${CLAUDE_CONFIG_DIR:-}}" label="${2:-}" root sid color proj_slug sess_file latest
      root="$(cma_project_root "$PWD")"
      sid="$(cma_latest_session_id "$config_dir" "$root")"
      color="$(cma_label_color "$label")"
      proj_slug="$(printf '%s' "$root" | sed -E 's/[^A-Za-z0-9]/-/g')"
      sess_file="$config_dir/projects/$proj_slug/$sid.jsonl"
      [[ -f "$sess_file" ]] || return 0
      latest="$(grep '"type":"agent-color"' "$sess_file" 2>/dev/null | tail -1 \
                | sed -E 's/.*"agentColor":"([^"]*)".*/\1/')" || latest=""
      [[ "$latest" == "$color" ]] && return 0
      printf '{"type":"agent-color","agentColor":"%s","sessionId":"%s"}\n' "$color" "$sid" >> "$sess_file"
      ;;
    hint)
      local label="${1:-}" color name
      color="$(cma_label_color "$label")"
      name="$(cma_session_name "$PWD")"
      printf 'claude-session: project "%s" — alias color: %s (auto-applied).\n' \
        "$name" "$color" >&2
      ;;
    *) printf 'usage: claude-session {org-id|org-guard|sanitize-fork|flags|name|id|color|apply-color|hint|latest-id|existing-id|context-size} [args]\n' >&2; return 2 ;;
  esac
}

main "$@"
