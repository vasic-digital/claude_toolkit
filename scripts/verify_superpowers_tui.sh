#!/usr/bin/env bash
# verify_superpowers_tui.sh — layer-4 live test: launch REAL Claude Code through a
# provider alias and confirm (a) no trust/overwrite prompt fires and (b) the
# superpowers plugin engages end-to-end. This is the ONLY thing that flips a
# provider to fully 'verified' (§4.4, §11.4.108 layer-4 user-visible).
#
# Honest SKIP (§11.4.3), never a faked PASS: SKIPs (exit 0, prints "SKIP: <why>")
# when the real claude binary / the alias / a key / the network is absent.
# PASS -> exit 0 + "PASS: ...". FAIL -> exit 1 + "FAIL: ...".
#
# Usage: verify_superpowers_tui.sh --alias ID [--prompt STR] [--timeout N] [--out FILE]
set -uo pipefail
TESTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PDIR="$HOME/.local/share/claude-multi-account/providers"
ALIASES_FILE="${ALIAS_FILE:-$HOME/.local/share/claude-multi-account/aliases.sh}"

ALIAS_ID="" PROMPT="" TIMEOUT=180 OUT=""

# --- unforgeable engagement challenge ---------------------------------------
# The old marker greped the transcript for skill-ish vocabulary. That is a
# HEURISTIC, and it failed in BOTH directions:
#   - false PASS: refusals and prompt-echo once satisfied looser variants of it
#     (documented in the classify section below);
#   - false FAIL (found 2026-07-20): siliconflow and xiaomi genuinely loaded the
#     skill but phrased it "skills will be invoked before any ACTION", while the
#     marker demanded "before any RESPONSE". Both were reported as
#     no-engagement. An independent probe proved they had in fact loaded it.
#
# Replace the heuristic with a secret-knowledge challenge: ask for one exact
# cell of the skill's Red Flags table. That string exists ONLY inside the
# skill file — it cannot be echoed from the prompt, cannot be guessed, and is
# not phrasing-dependent. A model that did not load the skill cannot produce
# it; a model that did will, however it words the rest of its reply.
#
# The expected answer is read FROM the skill at runtime rather than hardcoded,
# so this stays correct when the skill is updated.
#
# HONEST BOUNDARY of what a PASS here proves. The slash-command expansion
# injects SKILL.md into the conversation, so a model can answer the challenge by
# READING that injected content — it does not have to invoke the Skill tool.
# Observed directly: nemotron-3-ultra-550b answered in a single turn with no
# tool call at all, while the nano model called the Skill tool and also passed.
# So a PASS proves the skill content genuinely reached the model's context and
# the model could use it — real engagement, and far stronger than the vocabulary
# grep this replaced, which a confident guess could satisfy. It does NOT prove
# the model is capable of tool use; that is layer-1's tool-calling probe
# (providers-verify.sh), which every 'verified' provider has already passed.
sp_skill_file() {
  local root all
  all=""
  for root in "$HOME/.claude-shared/plugins/cache" "$HOME/.claude/plugins/cache"; do
    [[ -d "$root" ]] || continue
    all+="$(find "$root" -path '*/skills/using-superpowers/SKILL.md' 2>/dev/null)"$'\n'
  done
  # Prefer the stable marketplace install over transient `temp_git_*` checkouts,
  # which come and go; newest version wins within each class. Note `tail` exits 0
  # on empty input, so the choice must be made on CONTENT, not on exit status.
  local official picked
  official="$(printf '%s' "$all" | grep -v '^$' | grep 'claude-plugins-official' | sort -V | tail -n 1)"
  picked="$official"
  [[ -n "$picked" ]] || picked="$(printf '%s' "$all" | grep -v '^$' | sort -V | tail -n 1)"
  printf '%s' "$picked"
}

# sp_expected_answer extracts the "Reality" cell for the "I remember this skill"
# row: | "I remember this skill" | Skills evolve. Read current version. |
sp_expected_answer() {
  local f="$1"
  awk -F'|' '/I remember this skill/ {gsub(/^[ \t]+|[ \t]+$/,"",$3); print $3; exit}' "$f"
}
while (( $# )); do
  case "$1" in
    --alias)   ALIAS_ID="$2"; shift 2 ;;
    --prompt)  PROMPT="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --out)     OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
: "${OUT:=${PROOF_DIR:-$TESTS_ROOT/tests/proof}/providers-${ALIAS_ID}-superpowers.txt}"
mkdir -p "$(dirname "$OUT")"

# skip() APPENDS its marker rather than truncating, because a precondition SKIP
# fires before the launch truncates $OUT and the earlier content is still
# context. That makes the append LOAD-BEARING: the sweeps in
# verify_providers_live.sh read only the LAST marker line, so an older
# '# FAIL: route-*' from a previous run stays the verdict unless this append
# lands on top of it. Swallowing the failure under `2>/dev/null || true` meant
# an unwritable evidence file silently left that stale FAIL as the current
# verdict — and the status-independent route sweep then failed the whole suite
# on a verdict belonging to a run that already finished. The append is still
# non-fatal (an unwritable proof dir must not turn a SKIP into a FAIL), but it
# is no longer SILENT: the diagnostic goes to stderr, which
# verify_providers_live.sh captures with 2>&1 and prints on the SKIP line.
#
# Two portability details, both load-bearing:
#   * `2>/dev/null` is placed BEFORE the `>>`. Redirections are applied left to
#     right, so trailing it (the original order) meant the shell's own
#     "Permission denied" for the FAILED `>>` was emitted before stderr had been
#     silenced — noisy AND still uncaught.
#   * the status is captured into a variable rather than tested inline. bash
#     reports a compound command's redirection failure as rc 1 when its status
#     is read normally, but `if ! { …; } >> f` evaluates as SUCCESS (verified on
#     bash 5), so the obvious inline form silently never fires.
skip() {
  echo "SKIP: $1"
  local _skip_rc
  { echo "# SKIP $(date): $1"; } 2>/dev/null >> "$OUT"
  # shellcheck disable=SC2320  # deliberate: this $? IS the compound's status,
  # which is 1 when the `>>` redirection failed and echo's own 0 otherwise —
  # exactly the distinction being tested.
  _skip_rc=$?
  if (( _skip_rc != 0 )); then
    echo "SKIP-EVIDENCE-UNWRITABLE: could not append the SKIP marker to $OUT (rc=$_skip_rc) — any marker already in that file is STALE and does NOT describe this run" >&2
  fi
  exit 0
}

# --- preconditions (each an honest SKIP) ------------------------------------
[[ -n "$ALIAS_ID" ]] || skip "no --alias given"
CB="${CLAUDE_BIN:-$(command -v claude || true)}"
[[ -n "$CB" && "$CB" != "/usr/bin/true" && "$(basename "$CB")" == claude* ]] || skip "no real claude binary (CLAUDE_BIN=$CB)"
[[ -f "$ALIASES_FILE" ]] || skip "no alias file ($ALIASES_FILE) — run install.sh"
[[ -f "$PDIR/$ALIAS_ID.env" ]] || skip "alias '$ALIAS_ID' not installed"
command -v curl >/dev/null 2>&1 || skip "no curl (cannot pre-check network)"
# key present?
keyvar="$( set -a; . "$PDIR/$ALIAS_ID.env"; set +a; printf '%s' "${CMA_PROVIDER_KEYVAR:-}" )"
( set -a +u; [[ -f "${CMA_KEYS_FILE:-$HOME/api_keys.sh}" ]] && . "${CMA_KEYS_FILE:-$HOME/api_keys.sh}"; set +a
  eval "tok=\"\${$keyvar:-}\""; [[ -n "${tok:-}" ]] ) || skip "no key in \$$keyvar for '$ALIAS_ID'"

# --- route attribution: which backend ACTUALLY served the turn? --------------
# Layer-4 evidence used to record nothing about this, and the transcript itself
# CANNOT supply it. The router branch of cma_run_provider never exports
# ANTHROPIC_MODEL, so Claude Code labels and prices every router-transport turn
# with its OWN defaults ("modelUsage": claude-opus-4-8[1m], contextWindow
# 1000000) while ccr rewrites the model server-side. That is not a leak to the
# operator's Anthropic account — but it does mean the evidence file's own
# modelUsage can NEVER be used to attribute the backend. An independent source
# of truth is required.
#
# That source is ccr's resolved route, .Router.default ("<provider>,<model>").
# cma_run_provider rewrites it to THIS provider immediately before handing off
# to `ccr default-claude-code` -- EXCEPT when the provider's base_url IS the ccr
# gateway itself, which trips lib.sh's self-reference guard and skips the
# rewrite entirely. Such an alias INHERITS whatever the previously-launched
# provider left in that alias's own ~/.claude-code-router/<provider-id>/config.json.
#
# That is not hypothetical. `helixagent` (base_url http://127.0.0.1:3456/v1)
# never talked to helixagent: in the v1.23.0 proof run it inherited a ~1M-context
# provider and pushed 157,419 tokens through a nominally 24,576-token alias --
# and that was recorded as a layer-4 PASS. The badge measured whichever router
# provider happened to run last, and would have named a different backend had
# the run order changed. A pass attributable to a different backend is not a
# weak pass; it is a false claim, and worse than a failure.
IFS=$'\t' read -r P_TRANSPORT P_MODEL P_FAST_MODEL P_ID < <(
  set -a
  # shellcheck source=/dev/null  # runtime provider env file, path known only at execution
  . "$PDIR/$ALIAS_ID.env"
  set +a
  printf '%s\t%s\t%s\t%s' "${CMA_PROVIDER_TRANSPORT:-native}" "${CMA_PROVIDER_MODEL:-}" \
                      "${CMA_PROVIDER_FAST_MODEL:-}" "${CMA_PROVIDER_ID:-$ALIAS_ID}"
)
ROUTE_INTENDED="$ALIAS_ID/$P_MODEL"
# BOTH router entries must be attributed, not just .default. cma_run_provider
# writes .Router.default AND .Router.background in the same jq upsert
# (lib.sh:1022-1023), and Claude Code dispatches background sub-requests of the
# SAME turn through the background entry. Checking only .default therefore left
# a turn that was PARTLY served by another backend able to pass the gate — the
# same attribution hole as the original bluff, one router key over. The
# background intent mirrors lib.sh's own fallback: fast model, else strong.
ROUTE_INTENDED_BG="$ALIAS_ID/${P_FAST_MODEL:-$P_MODEL}"
# Per-alias CCR_HOME (lib.sh cma_run_provider router branch, ~1618-1627): every
# router-transport alias runs its OWN ccr gateway whose config.json, pidfile
# (service.json) and service.log live under ~/.claude-code-router/<provider-id>/,
# with CCR_HOME passed to `ccr restart` / `ccr default-claude-code`. That
# isolation landed in lib.sh on 2026-07-24 (5f9d82f, refined by 8695577) — THREE
# DAYS AFTER this script's route reads were last touched (88b4695, 2026-07-21),
# which still pointed at the GLOBAL ~/.claude-code-router/. Nothing writes the
# global config any more, so every router leg resolved a STALE route left there
# by the pre-isolation launcher (observed live: intended=xiaomi/mimo-v2.5-pro,
# resolved=deepseek/deepseek-v4-pro from Jul 20) and failed attribution. The
# reads below must name the SAME per-alias dir the launcher writes. P_ID is
# CMA_PROVIDER_ID from the alias's own env file — the exact value the launcher
# uses for the subdirectory.
#
# The deterministic per-alias port (CMA_CCR_PORT in the env file, else
# 3460 + java-hash(id) % 500, scripts/lib.sh — see _ccr_port/_ccr_mgmt_port)
# is deliberately NOT mirrored here: both restart receipts are filesystem
# facts INSIDE CCR_HOME (a new 'gateway listening on' line / a changed
# pidfile), not a port probe, so the port never enters the gate.
if [[ "$P_TRANSPORT" == "router" ]]; then
  CCR_DIR="$HOME/.claude-code-router/$P_ID"
else
  # Native transport never launches ccr; the n/a path below never reads these,
  # so the base dir is only a placeholder.
  CCR_DIR="$HOME/.claude-code-router"
fi
CCR_CFG="$CCR_DIR/config.json"
# Written by the Go router's startService (cmd/ccr/service.go:264) on every
# successful (re)start: pid + StartedAt of the CURRENTLY running daemon.
CCR_STATE="$CCR_DIR/service.json"
# The detached `serve` child's stdout, O_APPENDed by startService
# (service.go:240-247). serve.go:104 prints "gateway listening on ..." once the
# gateway is actually up.
CCR_LOG="$CCR_DIR/service.log"

# ccr_route_for KEY — "<provider>/<model>" parsed from .Router.<KEY>, or ""
# when it cannot be read at all. MUST be called AFTER the launch: the rewrite
# happens just before ccr serves the turn, so the post-launch value is the route
# that actually served it (and, for a self-referencing alias that never
# rewrites, the inherited route that genuinely did serve it).
ccr_route_for() {
  local key="$1" d p m
  [[ -f "$CCR_CFG" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  d="$(jq -r --arg k "$key" '.Router[$k] // empty' "$CCR_CFG" 2>/dev/null)"
  [[ -n "$d" ]] || return 0
  p="${d%%,*}"
  m=""
  [[ "$d" == *,* ]] && m="${d#*,}"
  printf '%s/%s' "$p" "$m"
}

# --- proof that the on-disk route was APPLIED to the live gateway ------------
# Reading config.json tells us what the file SAYS, not what the daemon SERVES.
# cma_run_provider writes the file and then runs `ccr restart` under `|| true`
# (lib.sh:1026) — failure is swallowed. A FAILED or SKIPPED restart leaves the
# running gateway serving the PREVIOUS provider's route while the post-launch
# file read returns the intended value: gate passes, turn served by a different
# backend. Exactly the class this gate claims to make impossible.
#
# That failure mode is reachable, not theoretical: cmdRestart REFUSES to restart
# an authenticated gateway when CCR_API_KEYS is not visible to the call
# (service.go:556-560, "refusing to restart ... would bring the gateway back
# UNAUTHENTICATED") and returns 1 — which `|| true` discards.
#
# (The often-cited lib.sh:930 comment claiming "config.json is not re-imported
# on restart" describes the RETIRED JS router. The Go router documents the
# opposite at cmd/ccr/service.go:357-364: the running gateway keeps serving the
# config it STARTED with, which is precisely why cmdRestart exists and why a
# bounce is what applies a rewrite. So the residual risk is a restart that did
# not happen, not one that did.)
#
# The router exposes no live-route query to assert against directly: its only
# HTTP surface is the management server's /health, which reports
# {status, service, providers:<count>} and no route at all (cmd/ccr/management.go:42-49),
# and `ccr config show|validate` merely re-reads the same file from disk
# (cmd/ccr/config_cmd.go). So the strongest available assertion is a RESTART
# RECEIPT bracketing this launch: proof that a fresh gateway process started
# after we snapshotted, i.e. that some config load happened during this launch.
# Two independent receipts, either sufficient:
#   1. a new "gateway listening on" line appended to service.log past the
#      pre-launch byte offset;
#   2. a changed service.json (new pid / StartedAt) — the pidfile is rewritten
#      only by a successful startService.
# When NEITHER is available we cannot prove the route was applied, and the gate
# FAILS CLOSED rather than trusting the file.
ccr_service_fingerprint() {
  [[ -f "$CCR_STATE" ]] || { printf '<absent>'; return 0; }
  printf '%s' "$(<"$CCR_STATE")"
}
ccr_log_size() {
  local n
  [[ -f "$CCR_LOG" ]] || { printf '0'; return 0; }
  n="$(wc -c < "$CCR_LOG" 2>/dev/null | tr -d ' \n')"
  printf '%s' "${n:-0}"
}
# ccr_log_restart_receipt OFFSET — true when a gateway-start line was appended
# past OFFSET. `tail -c +N` is POSIX (1-based), hence OFFSET+1.
ccr_log_restart_receipt() {
  local off="${1:-0}"
  [[ -f "$CCR_LOG" ]] || return 1
  tail -c "+$((off + 1))" "$CCR_LOG" 2>/dev/null | grep -q 'gateway listening on'
}

# --- build the engagement challenge -----------------------------------------
# CHALLENGE_ANSWER is the ground truth the model can only know by having loaded
# the skill. If the skill is not installed we cannot pose the challenge at all —
# that is an honest SKIP (§11.4.3), never a FAIL of the provider: an absent
# plugin says nothing about the alias under test.
SP_SKILL="$(sp_skill_file)"
CHALLENGE_ANSWER=""
if [[ -n "$SP_SKILL" && -f "$SP_SKILL" ]]; then
  CHALLENGE_ANSWER="$(sp_expected_answer "$SP_SKILL")"
fi
[[ -n "$CHALLENGE_ANSWER" ]] || skip "superpowers skill not found on this host (looked for skills/using-superpowers/SKILL.md) — cannot pose the engagement challenge"

if [[ -z "$PROMPT" ]]; then
  PROMPT="Use the using-superpowers skill. Then, from the Red Flags table in that skill, reply with ONLY the exact text in the \"Reality\" column for the thought \"I remember this skill\". Output nothing else."
fi

# --- launch (scrubbed env + throwaway cwd, like verify_claude_live.sh) -------
# BASH_ENV is scrubbed too, and it is LOAD-BEARING rather than cosmetic. A
# non-interactive `bash -c` sources $BASH_ENV before running its command, and on
# a host where that points at the operator's ~/.bashrc it transitively sources
# the MANAGED ALIAS FILE. The launch below then has a working cma_run_provider
# supplied from somewhere OTHER than "$ALIASES_FILE" — so the evidence names one
# alias file while the turn was served by whatever another one defined, and a
# broken/empty/stale $ALIASES_FILE cannot be detected at all (verified on this
# host: `bash -c 'declare -F cma_run_provider'` succeeds with BASH_ENV set and
# fails with it unset). Scrubbing it makes the launch depend on exactly one
# alias file: the one this script names in its own evidence.
SCRUB=(env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_ENTRYPOINT
       -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_EXECPATH -u CLAUDE_EFFORT
       -u CLAUDE_CONFIG_DIR -u ANTHROPIC_MODEL -u ANTHROPIC_BASE_URL
       -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u BASH_ENV)
tmpd="$(mktemp -d "${TMPDIR:-/tmp}/cma-stui.XXXXXX")"
: > "$OUT"
printf '# ROUTE-INTENDED: %s (transport=%s)\n' "$ROUTE_INTENDED" "$P_TRANSPORT" >> "$OUT"
printf '# ROUTE-INTENDED-BACKGROUND: %s\n' "$ROUTE_INTENDED_BG" >> "$OUT"
# Snapshot the gateway's liveness markers BEFORE the launch so the restart
# receipt is scoped to THIS launch and cannot be satisfied by an older bounce.
CCR_LOG_PRE="$(ccr_log_size)"
CCR_STATE_PRE="$(ccr_service_fingerprint)"
# The prompt travels in the ENVIRONMENT, never interpolated into the script
# text. The challenge prompt contains double quotes (it names the "Reality"
# column and the "I remember this skill" row); splicing that into the
# double-quoted -p argument inside this single-quoted bash -c body terminated
# the string early and mangled the command. Every alias then failed the
# challenge — including ones proven by hand to answer it correctly, which is how
# this was caught. Passing by env removes the quoting hazard entirely.
#
# BROKEN-INSTALLATION GUARD. The only alias-file precondition above is
# `[[ -f "$ALIASES_FILE" ]]`, and the `source` below runs under `>/dev/null 2>&1`
# — source errors are SWALLOWED. A truncated or syntactically broken alias file
# therefore satisfies the precondition, fails silently, and leaves
# cma_run_provider UNDEFINED, so bash's own "command not found" returns rc 127
# for EVERY alias. That corruption happened on this host, so it is a fact about
# the world, not a hypothetical.
#
# Inferring "a binary was missing" from rc 127 would then convert a wholly
# broken installation into an honest-looking SKIP, and the entire layer-4 leg
# would report green having tested nothing — a false-GREEN, which in this
# codebase is strictly worse than the loud (if misattributed) route-unknown it
# replaced. So the wrapper's EXISTENCE is asserted positively, before the
# launch, and reported with a sentinel: the exit code alone is never trusted to
# mean this, because the agent can produce any exit code it likes (see the
# refusal-classification block below).
#
# HONEST BOUNDARY on that sentinel, corrected 2026-07-20. This was previously
# described as "unforgeable". It is not, and cannot be: the sentinel is EXPORTED
# into the launch environment, so `ccr`, every proxy and the agent itself all
# inherit it, and since `ccr` forwards exit codes verbatim an agent with a shell
# tool could print the value it was handed and exit 96 — supplying BOTH halves
# from material we gave it. Two cheap hardenings narrow that window rather than
# closing it:
#   * the sentinel is derived PER RUN, so a value learned from one run (or read
#     out of this source file) does not satisfy the next one;
#   * it is `unset` inside the launch shell the instant the guard has passed,
#     BEFORE cma_run_provider is invoked, so the agent never inherits it at all
#     on the path where an agent exists to read it.
# What the sentinel honestly buys is therefore: rc 96 is not mistaken for a
# broken install on the strength of the code alone, and the value cannot be
# replayed or read from the environment of the process that could abuse it.
CMA_STUI_NO_WRAPPER="__CMA_STUI_WRAPPER_UNDEFINED__$$-$(date +%s)-${RANDOM}${RANDOM}__"
out="$( timeout "$TIMEOUT" "${SCRUB[@]}" CMA_STUI_PROMPT="$PROMPT" \
        CMA_STUI_NO_WRAPPER="$CMA_STUI_NO_WRAPPER" bash -c '
    cd "'"$tmpd"'" || exit 97
    source "'"$ALIASES_FILE"'" >/dev/null 2>&1
    # Printed to STDOUT, not stderr: $out captures stdout only (the launch
    # itself reaches stderr solely via its own explicit 2>&1), so a sentinel on
    # stderr would vanish and the guard would be unobservable.
    declare -F cma_run_provider >/dev/null 2>&1 || {
      printf "%s\n" "$CMA_STUI_NO_WRAPPER"
      printf "cma_run_provider is not defined after sourcing the alias file\n"
      exit 96
    }
    # The guard has served its purpose; drop the sentinel before anything that
    # could read it exists. ccr, the proxies and the agent are all launched by
    # the next line and would otherwise inherit the exact string the parent
    # greps for (see the honest boundary above).
    unset CMA_STUI_NO_WRAPPER
    cma_run_provider "'"$ALIAS_ID"'" -p "$CMA_STUI_PROMPT" --output-format json 2>&1
  ' )"
rc=$?
rmdir "$tmpd" 2>/dev/null || true
printf '%s\n' "$out" >> "$OUT"

# --- REFUSED / NEVER-ATTEMPTED LAUNCHES (must precede the attribution gate) ---
# A route marker is a statement about WHICH BACKEND SERVED A TURN. When
# cma_run_provider REFUSES to launch, no turn was served at all, and every such
# statement is false by construction.
#
# This is not hypothetical, it is the common case on a real host. The activation
# gate (lib.sh:668-680) returns rc 3 for any non-'verified' alias BEFORE the
# router branch, so no config.json rewrite and no `ccr restart` happen. Reading
# .Router.default afterwards therefore returns the PREVIOUS provider's route,
# and the attribution gate below would dutifully report
#   # FAIL: route-mismatch (intended=deadprov/... resolved=chutes/...)
# for a launch that never occurred. Because route markers are deliberately
# un-gated (a lying evidence file is a failure at every provider status), that
# turns every non-verified alias into a permanent hard suite failure — the exact
# "restates known account state as new breakage" outcome gate_for_status exists
# to prevent.
#
# So the refusal codes are classified HERE, on their own terms, and never with a
# `route-` marker:
#   rc 3   activation gate: the alias is not 'verified'. Account-side; the
#          refusal is CORRECT behaviour. A distinctly-named FAIL, left to
#          verify_providers_live.sh's status gate (excused as KNOWN-NON-WORKING
#          for a non-verified provider, a real failure for a 'verified' one,
#          where it would mean status.json disagrees with itself).
#   rc 78  route-integrity refusal: lib.sh would not launch because the ccr
#          route could not be written/applied, or the provider's base_url IS the
#          gateway (the helixagent self-reference). The refusal is correct, and
#          no ACCOUNT state explains it — so it is an UN-GATED failure, the same
#          non-account class as a route mismatch, just detected one step earlier.
#
#          HONEST BOUNDARY, corrected 2026-07-20. This was previously written as
#          "a genuine toolkit/config defect that no account state explains".
#          The second half holds; the first over-claims. There are two
#          `return 78` sites in lib.sh (:1049, :1192) and the second is reachable
#          from FIVE conditions (lib.sh:1131-1186), only two of which are defects:
#            * base_url IS the ccr gateway (self-reference)      — config defect
#            * corrupt config.json => the jq rewrite fails       — config defect
#            * jq is not on PATH                                 — ENVIRONMENTAL
#            * `mv -f` fails: disk full / read-only / immutable  — ENVIRONMENTAL
#            * `ccr restart` fails, incl. transient port contention — TRANSIENT
#          The jq case is the sharpest inconsistency: an absent binary is an
#          honest SKIP elsewhere in this very script (:123, :126). Un-gating is
#          still correct — all five leave an alias that cannot launch, and none
#          is excused by the provider's account — but rc 78 should be read as
#          "could not launch, for a non-account reason", not as proof of a bug.
#          Separating the environmental subset needs lib.sh to report WHICH
#          condition fired (it composes exactly that text into $_route_msg and
#          then folds it all into rc 78); that is a lib.sh change, not one this
#          script can make, and it is deliberately NOT attempted here.
#   rc 127 a required binary (ccr / claude) is absent from this host. Purely
#          environmental, indistinguishable from the preconditions this script
#          already SKIPs on (§11.4.3) — an honest SKIP, never a verdict.
#
# NOT IN THE REFUSAL SET, and worth stating explicitly because it is the same
# detection/verdict asymmetry the `*)` arm below guards. cma_run_provider has two
# further refusal paths that return rc 1, not 3/78/127: an unknown provider
# (lib.sh:793, "unknown provider <id> (missing <env>)") and an empty key
# (lib.sh:893, "$<KEYVAR> is empty"). Both print a `claude-providers:` refusal —
# so half (b) of the corroboration would recognise them — but rc 1 is outside the
# set enumerated above, so neither is ever CLASSIFIED as a refusal. Such a launch
# would fall straight through to the route gate and earn an UN-GATED route
# verdict for a turn that never ran, which is precisely the N1 trap.
#
# It is currently UNREACHABLE, and only by luck of ordering: the preconditions at
# :125 SKIP on a missing `$PDIR/$ALIAS_ID.env` and at :130 on an empty key, so
# this script exits before either lib.sh path can fire. Observed live on this
# host: `kimi-k3` sits in status.json (status=failed) with NO .env file and
# returns exactly that rc 1 when launched directly — and the :125 precondition
# SKIPs it first. Deliberately not "fixed" by widening the refusal set: adding
# rc 1 would make every unrelated rc-1 failure look like a refusal, which is the
# opposite mistake. Recorded so the next edit to those preconditions knows what
# it is holding up.
#
# WHY BARE EXIT CODES CANNOT BE TRUSTED HERE. `ccr` forwards the agent's own
# exit code VERBATIM (cmd/ccr/launch.go:377 returns ee.ExitCode(); only signal
# deaths remap), and the native branch is a bare `"$CLAUDE_BIN" "$@"; rc=$?;
# return $rc` (lib.sh:1219,1229). So ANY code the agent itself produces reaches
# this keying unchanged, and a turn that RAN and exited 3/78/127 is
# indistinguishable from a refusal on the code alone.
#
# CORROBORATION IS THEREFORE POSITIVE, AND IT MUST FAIL CLOSED. The earlier form
# keyed only on a completed '"type": "result"' line, which failed OPEN for every
# genuine turn that died before emitting one: an assistant chunk on the wire, no
# result line, rc 127 -> reported as "nothing ran". A run that DID happen was
# recorded as never having happened, and because rc 127 is the SKIP arm the whole
# leg went green having tested nothing. That is a false-GREEN, strictly worse
# than the false-RED it replaced.
#
# A launch is classified as refused ONLY when BOTH hold:
#   (a) NO conversation-shaped chunk appears in the captured output; AND
#   (b) the output is EMPTY, or carries the wrapper's OWN refusal text. Every
#       refusal path in lib.sh prints one (`claude-providers:` / `cma_run:` at
#       lines 594, 696, 990, 1005, 1046, 1189). bash's own "command not found"
#       does NOT match it — which is exactly the broken-installation case that
#       must fail loudly rather than SKIP.
# Failing this test un-classifies the refusal, and the run falls through to the
# route gate, where it earns a loud, un-gated verdict. That keeps the I4
# property intact: a route mismatch on a turn that ACTUALLY RAN still fails at
# every status.
#
# WHICH HALF DOES THE WORK, corrected 2026-07-20 — this used to be misdescribed.
# (a) was written as `"type": *"(result|assistant|user|system)"`, and the comment
# credited the widened alternation with catching "a turn killed mid-stream". It
# cannot, and never did. The launch below hardcodes `--output-format json`
# (:328), which buffers the whole turn and emits ONE terminal
# `{"type":"result",…}` object and nothing before it — an assistant/user/system
# chunk is a `--output-format stream-json` shape this script never requests. All
# 33 layer-4 evidence files in scripts/tests/proof/ bear this out: `"type":
# "result"` x33, `assistant|user|system` x0. A turn killed mid-stream under
# `--output-format json` emits NO json at all, so (a) is FALSE for exactly the
# case the widening claimed to cover.
#
# The alternation is therefore deleted rather than kept as untestable breadth
# that the comments credit with real work. What remains — the `result` form — is
# live and behaviourally pinned by case (n) of test_layer4_route_attribution.sh
# (rc in the refusal set + a completed transcript + wrapper refusal text present,
# where (a) is the SOLE thing that can clear the refusal).
#
# So (b) is what actually carries the mid-stream case: such a turn leaves ccr's
# own diagnostics on the wire ("Service not running, starting service…" is in
# the real evidence), which is non-empty and matches no refusal prefix, so
# `! _stui_wrapper_refused` clears the refusal and the run earns a loud verdict.
# RESIDUAL, stated rather than papered over: a turn that dies mid-stream leaving
# stdout COMPLETELY empty still satisfies both halves and is read as a refusal.
# Nothing observable distinguishes it from a genuine silent refusal, so it fails
# in the conservative direction by construction, not by oversight.
_stui_conversation_started() {
  printf '%s' "$out" | grep -qE '"type": *"result"'
}
_stui_wrapper_refused() {
  [[ -z "$out" ]] && return 0
  printf '%s' "$out" | grep -qE '^(claude-providers|cma_run):'
}

# BROKEN INSTALLATION — handled before the refusal keying, because it is the one
# thing rc 127 must never be allowed to mean. Requires the sentinel as well as
# the code: rc 96 alone could come from the agent.
if (( rc == 96 )) && printf '%s' "$out" | grep -qF "$CMA_STUI_NO_WRAPPER"; then
  echo "FAIL: launch-impossible-no-wrapper — '$ALIASES_FILE' exists but does not define cma_run_provider (truncated / syntactically broken alias file). NOTHING could have been launched through ANY alias; this is a broken installation, not a provider verdict. Re-run: bash scripts/install.sh"
  echo "# FAIL: launch-impossible-no-wrapper (rc=96 aliases=$ALIASES_FILE; the launch wrapper is UNDEFINED — no alias on this host can launch)" >> "$OUT"
  exit 1
fi

launch_refused=""
case "$rc" in
  3)   launch_refused="activation gate — alias not 'verified'; refused before any ccr route write" ;;
  78)  launch_refused="route-integrity refusal — lib.sh would not launch against a route it could not apply" ;;
  127) launch_refused="required binary missing (ccr / claude not on PATH)" ;;
esac
if [[ -n "$launch_refused" ]] && { _stui_conversation_started || ! _stui_wrapper_refused; }; then
  # Either the turn demonstrably ran, or nothing corroborates a refusal. Both
  # mean the exit code must not be read as one.
  launch_refused=""
fi
if [[ -n "$launch_refused" ]]; then
  printf '# LAUNCH-REFUSED: rc=%s — %s\n' "$rc" "$launch_refused" >> "$OUT"
  # NOTE: this case MUST stay total. It and the detection case above carry the
  # same code set today, so nothing falls through — but a code added to one and
  # not the other would write '# LAUNCH-REFUSED: rc=N' and then CONTINUE into
  # route resolution, producing evidence that simultaneously claims the launch
  # was refused AND names a resolved backend. The `*)` arm makes that drift a
  # loud failure instead of a silent contradiction.
  case "$rc" in
    127)
      skip "launch refused: $launch_refused — nothing ran, so this run says nothing about '$ALIAS_ID'" ;;
    3)
      echo "FAIL: launch-refused-unverified — cma_run_provider refused to launch '$ALIAS_ID' ($launch_refused); no turn ran, so no route can be attributed"
      echo "# FAIL: launch-refused-unverified (rc=3 intended=$ROUTE_INTENDED; NO turn ran — route attribution is not applicable)" >> "$OUT"
      exit 1 ;;
    78)
      echo "FAIL: launch-refused-route-integrity — cma_run_provider refused to launch '$ALIAS_ID' because its ccr route was not applied / its base_url is the gateway itself; no turn ran"
      echo "# FAIL: launch-refused-route-integrity (rc=78 intended=$ROUTE_INTENDED; NO turn ran — the route could not be applied)" >> "$OUT"
      exit 1 ;;
    *)
      echo "FAIL: launch-refused-unclassified — rc=$rc was detected as a launch refusal but has no verdict arm; refusing to continue into route resolution, which would emit evidence claiming BOTH a refused launch and a resolved backend. The detection and verdict code sets have drifted apart."
      echo "# FAIL: launch-refused-unclassified (rc=$rc intended=$ROUTE_INTENDED; detection/verdict case sets disagree — toolkit defect)" >> "$OUT"
      exit 1 ;;
  esac
fi

# Resolved AFTER the launch (see ccr_resolved_route). Recorded unconditionally,
# next to the intent, so every layer-4 evidence file states on its face which
# backend served the turn — the fact whose absence let the helixagent bluff
# survive a release.
ROUTE_APPLIED=""
if [[ "$P_TRANSPORT" == "router" ]]; then
  ROUTE_RESOLVED="$(ccr_route_for default)"
  ROUTE_RESOLVED_BG="$(ccr_route_for background)"
  if ccr_log_restart_receipt "$CCR_LOG_PRE"; then
    ROUTE_APPLIED="service.log: new 'gateway listening on' past byte $CCR_LOG_PRE"
  elif [[ "$(ccr_service_fingerprint)" != "$CCR_STATE_PRE" ]]; then
    ROUTE_APPLIED="service.json: daemon pidfile changed across the launch"
  fi
else
  ROUTE_RESOLVED="n/a (native transport — the alias talks to its endpoint directly, no ccr route involved)"
  ROUTE_RESOLVED_BG="$ROUTE_RESOLVED"
  ROUTE_APPLIED="n/a (native transport — no ccr gateway to apply a route)"
fi
printf '# ROUTE-RESOLVED: %s\n' "${ROUTE_RESOLVED:-<unreadable>}" >> "$OUT"
printf '# ROUTE-RESOLVED-BACKGROUND: %s\n' "${ROUTE_RESOLVED_BG:-<unreadable>}" >> "$OUT"
printf '# ROUTE-APPLIED: %s\n' "${ROUTE_APPLIED:-<unproven>}" >> "$OUT"

# --- classify ---------------------------------------------------------------
# A trust/overwrite prompt makes the non-interactive launch hang -> timeout (124),
# or leaves its dialog text in the transcript.
#
# But rc 124 says ONLY that the bound expired — never why, and the two causes it
# conflates need opposite responses. Consult the transcript we just captured
# before naming one, because guessing here has already cost real debugging time:
# every failing alias on this host (chutes1-4, kilo, nvidia, nvidia3,
# openrouter2/3, poe3 — long-time-to-first-token reasoning models, while every
# fast model passed) was reported as a possible trust/overwrite dialog, and NONE
# of them had one. Their own result JSON, written into this same evidence file,
# says `terminal_reason":"aborted_streaming"` with output_tokens 0, cost 0 and
# duration_api_ms 0. A dialog that was never shown is a false diagnosis of
# exactly the kind this suite refuses to emit anywhere else, and it sends the
# reader looking for a prompt instead of at the route.
#
# Be careful what the replacement claims, too. It is NOT true that "the backend
# accepted the request and streamed nothing back" — on the run that motivated
# this, the requests never left the host: ~/.claude-code-router/<id>/service.log
# shows 10+ retries each answered 503 in 1-4ms by the LOCAL gateway (a route
# whose model id carried a vendor prefix). So the marker states the observed
# fields and points at the gateway log; it does not name a layer it cannot see.
# For the same reason it must not advise a larger --timeout: the retries were
# still 503ing past 180s, and no bound fixes a rejected route.
if (( rc == 124 )); then
  if printf '%s' "$out" | grep -qF '"terminal_reason":"aborted_streaming"'; then
    _stui_ms="$(printf '%s' "$out" | grep -oE '"duration_ms":[0-9]+' | tail -1 | cut -d: -f2)"
    _stui_tok="$(printf '%s' "$out" | grep -oE '"output_tokens":[0-9]+' | head -1 | cut -d: -f2)"
    echo "FAIL: stream-aborted — the CLI produced a result (duration_ms=${_stui_ms:-unknown}) with ${_stui_tok:-0} output tokens and terminal_reason=aborted_streaming. NOT a trust/overwrite dialog. WHERE it died is not determined here: read ~/.claude-code-router/$ALIAS_ID/service.log — a burst of 503s at 1-4ms each means the LOCAL gateway rejected the route and the request never reached the provider, which no --timeout value can fix."
    echo "# FAIL: stream-aborted (output_tokens=${_stui_tok:-0} duration_ms=${_stui_ms:-unknown} bound=${TIMEOUT}s)" >> "$OUT"
    exit 1
  fi
  echo "FAIL: launch hung within ${TIMEOUT}s (trust/overwrite prompt?)"; echo "# FAIL: timeout" >> "$OUT"; exit 1
fi
# ATTRIBUTION GATE — runs before every transcript-derived verdict below, because
# every one of those verdicts is a statement ABOUT A BACKEND, and a statement
# about the wrong backend is worthless whichever way it lands. (Only the
# timeout above outranks it: there the launch was killed mid-flight, so the
# config state is indeterminate and the hang is the more actionable finding.)
if [[ "$P_TRANSPORT" == "router" ]]; then
  if [[ -z "$ROUTE_RESOLVED" || -z "$ROUTE_RESOLVED_BG" ]]; then
    # No jq, or no/empty .Router.default/.background. Note this is exactly the
    # state in which cma_run_provider ALSO skipped its own rewrite (its upsert
    # is `command -v jq`-guarded, and it writes both keys or neither), so the
    # turn really was served by an inherited route. Unattributable => cannot
    # verify, and must not silently pass.
    echo "FAIL: route-unknown — cannot read ccr's resolved route from $CCR_CFG; this turn is not attributable to '$ALIAS_ID' (intended $ROUTE_INTENDED)"
    echo "# FAIL: route-unknown (intended=$ROUTE_INTENDED resolved=${ROUTE_RESOLVED:-<unreadable>} intended-bg=$ROUTE_INTENDED_BG resolved-bg=${ROUTE_RESOLVED_BG:-<unreadable>})" >> "$OUT"; exit 1
  fi
  if [[ "$ROUTE_RESOLVED" != "$ROUTE_INTENDED" ]]; then
    echo "FAIL: route-mismatch — intended '$ROUTE_INTENDED' but ccr resolved '$ROUTE_RESOLVED'; the turn was served by a DIFFERENT backend and proves nothing about '$ALIAS_ID'"
    echo "# FAIL: route-mismatch (intended=$ROUTE_INTENDED resolved=$ROUTE_RESOLVED)" >> "$OUT"; exit 1
  fi
  # Background sub-requests of this same turn route through .Router.background.
  # A turn served PARTLY by another backend is no more attributable than one
  # served wholly by it.
  if [[ "$ROUTE_RESOLVED_BG" != "$ROUTE_INTENDED_BG" ]]; then
    echo "FAIL: route-mismatch-background — intended '$ROUTE_INTENDED_BG' but ccr resolved '$ROUTE_RESOLVED_BG'; background sub-requests of this turn were served by a DIFFERENT backend"
    echo "# FAIL: route-mismatch-background (intended=$ROUTE_INTENDED_BG resolved=$ROUTE_RESOLVED_BG)" >> "$OUT"; exit 1
  fi
  # Both routes on disk name this alias — but a file is not a live gateway.
  # Without a restart receipt we cannot show the daemon ever loaded them, and a
  # swallowed `ccr restart` failure leaves the PREVIOUS provider serving while
  # this file reads correct. Fail closed.
  if [[ -z "$ROUTE_APPLIED" ]]; then
    echo "FAIL: route-unproven — $CCR_CFG names '$ROUTE_INTENDED', but no ccr restart receipt brackets this launch (no new 'gateway listening on' in $CCR_LOG and $CCR_STATE unchanged), so the running gateway may still be serving the previous provider's route"
    echo "# FAIL: route-unproven (intended=$ROUTE_INTENDED resolved=$ROUTE_RESOLVED applied=<unproven>)" >> "$OUT"; exit 1
  fi
fi
if printf '%s' "$out" | grep -qiE 'do you (trust|want to open)|overwrite.*config|trust the files'; then
  echo "FAIL: a trust/overwrite prompt fired"; echo "# FAIL: trust-prompt" >> "$OUT"; exit 1
fi
# A completed API conversation is a hard prerequisite: when Claude Code itself
# reports an error (HTTP 400/401/402/… from the provider) the launch is a
# genuine runtime FAIL, regardless of any skill vocabulary in the transcript.
if printf '%s' "$out" | grep -qE '"is_error": ?true'; then
  echo "FAIL: Claude Code reported an API error through the alias"; echo "# FAIL: api-error" >> "$OUT"; exit 1
fi
# superpowers engagement marker (review Finding 4 — HONESTY): a false PASS here
# is far worse than a false FAIL, since PASS is what flips a provider to
# 'verified' via `cmd_verify --deep`. The marker MUST NOT be satisfiable by the
# model merely ECHOING the injected prompt or using a generic word:
#   - bare 'skill'/'superpowers' matched refusals like "I don't have a skill
#     called using-superpowers, but..." -> false PASS.
#   - the literal prompt term 'using-superpowers' (PROMPT="/using-superpowers")
#     matched its own echo -> false PASS.
# The marker accepts either (a) the skill's self-announcement form
# ("superpowers:<name>"), or (b) vocabulary that only exists in the session if
# the skill content genuinely loaded: the chained skill names
# 'systematic-debugging' / 'brainstorming', or the framework's signature rule
# ("invoke … skills BEFORE any response"). None of these appear in the bare
# prompt, and refusals never produce them. Model-dependent phrasing of a
# genuine engagement (e.g. a summary of the framework rules without the exact
# announce string) therefore no longer false-FAILs, while echo/refusal bluffs
# still cannot PASS.
#
# This tightening is NOT Tier-A testable (no real claude in the sandbox to
# generate a genuine negative-case transcript). The DEFINITIVE live check --
# real claude, superpowers NOT engaging, must NOT PASS -- is deferred to
# Task 5's Tier-B test.
# An empty final result is its own failure mode and deserves its own name.
# Observed with nvidia/nemotron-3-nano-omni-30b-a3b-reasoning: the model invoked
# the Skill tool successfully, spent 809 output tokens, emitted ZERO text blocks,
# and stayed silent even after Claude Code's built-in "produce a user-visible
# response" nudge. Reporting that as "superpowers did not engage" was actively
# misleading — the skill HAD loaded; the model simply never spoke. Naming it
# precisely saves the next investigator from hunting a skill-loading bug.
if printf '%s' "$out" | grep -qE '"result": ?""'; then
  echo "FAIL: session completed but the model produced an EMPTY final response (no text blocks)"
  echo "# FAIL: empty-result" >> "$OUT"; exit 1
fi
# The challenge answer is a verbatim cell of the skill's Red Flags table. It is
# matched as a fixed string (grep -F), anywhere in the transcript: a model may
# be more verbose than "output nothing else" asked for and still have proven it
# loaded the skill. What it cannot do is produce this sentence without the skill
# in context — the prompt never contains it, and it is not guessable.
if printf '%s' "$out" | grep -qF "$CHALLENGE_ANSWER"; then
  echo "PASS: superpowers engaged (answered the skill-content challenge), no trust/overwrite prompt"
  echo "# PASS" >> "$OUT"; exit 0
fi
echo "FAIL: session ran but superpowers did not engage (could not answer the skill-content challenge)"
echo "# FAIL: no-engagement" >> "$OUT"; exit 1
