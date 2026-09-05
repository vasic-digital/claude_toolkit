#!/usr/bin/env bash
# verify_kimi_live.sh — live verification of the Kimi Code CLI support (v1.27.0).
#
# Runs against REAL installed state: the real `kimi` binary, the real OAuth
# credentials slot, the real rendered alias file, and any real rendered
# ~/.kimi-prov-<id>/config.toml. Honest SKIPs are the norm on hosts that have
# not run `claude-providers sync` since v1.27.0 — the kimi provider twins are
# MATERIALIZED by that sync, so their absence is a prerequisite, never a FAIL.
#
# Checks:
#   1. NATIVE smoke   : `kimi -p "Reply exactly: KIMI-OK" --output-format text`
#                       against the real OAuth subscription. SKIPs when the
#                       binary is absent or no credentials slot exists (not
#                       signed in).
#   2. ALIAS invariant: for every materialized `kimi-<id>` twin, the alias FILE
#                       (never source) must keep `# <id>` on `cma_run_provider`
#                       (Claude side, unchanged) and `kimi-<id>` on
#                       `cma_run_kimi_provider` (Kimi side).
#   3. kimi-<id> smoke : through the real rendered ~/.kimi-prov-<id>/config.toml
#                       for each materialized twin (wrapper, env, status gate,
#                       CA wiring). SKIPs honestly per prerequisite.
#   4. CA trust       : a CONFIGURED-but-unreadable CA cert on an https twin is
#                       a SKIP (the launch would silently trust nothing). A
#                       public-CA https twin with no CA pin is exercised against
#                       system roots — the mere absence of a pin is not a skip.
#   5. LEGACY rename  : a `kc-*` key present in status.json must carry the
#                       `cma_run_provider <kc-id>` alias form; a `kimi-kc-*` alias
#                       may never exist. A host still holding old `kimi-for-coding`
#                       keys (sync not yet run) SKIPs rather than FAILs — the
#                       rename runs AT sync by construction.
#
# Also the helper `kimi aliases` expose counts both kinds of alias in the file.
#
# Usage:  bash scripts/tests/verify_kimi_live.sh
# Exit code is the count of GENUINE failures; SKIPs are never failures.

set +e
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/lib/assert.sh"

PROOF_DIR="${PROOF_DIR:-$TESTS_DIR/proof}"
mkdir -p "$PROOF_DIR"
EV="$PROOF_DIR/kimi-live-evidence.txt"
: > "$EV"

ALIAS_FILE="${ALIAS_FILE:-$HOME/.local/share/claude-multi-account/aliases.sh}"
PDIR="${CMA_PROVIDERS_DIR:-$HOME/.local/share/claude-multi-account/providers}"
KIMI_CRED="$HOME/.kimi-code/credentials"

passed=0 failed=0 skipped=0

echo "Kimi Code live verification: $(date)" | tee -a "$EV"
echo "alias file: $ALIAS_FILE" | tee -a "$EV"

# The legacy map is the ONE canonical source: scripts/providers/legacy-renames.json.
# Re-declaring it here (rather than parsing JSON in bash) is a deliberate
# duplication-with-warning: it keeps this verifier runnable on hosts whose
# checkout predates the file, and the kimi test suite asserts the two agree.
legacy_new_of() {
  case "$1" in
    kimi-for-coding) echo kc-for-coding ;;
    kimi-for-coding2) echo kc-for-coding2 ;;
    kimi-for-coding-highspeed) echo kc-for-coding-highspeed ;;
    kimi-k3) echo kc-k3 ;;
    kimi-k2p7) echo kc-k2p7 ;;
    *) echo "" ;;
  esac
}

# ── 1. Native smoke ─────────────────────────────────────────────────────────
it "native kimi smoke (real CLI + real OAuth subscription)"
KIMI_BIN=""
for cand in "$HOME/.kimi-code/bin/kimi" "$HOME/.local/bin/kimi"; do
  [[ -x "$cand" ]] && { KIMI_BIN="$cand"; break; }
done
[[ -z "$KIMI_BIN" ]] && KIMI_BIN="$(command -v kimi 2>/dev/null || true)"
if [[ -z "$KIMI_BIN" ]] || [[ ! -x "$KIMI_BIN" ]]; then
  echo "  SKIP: kimi binary absent on this host" | tee -a "$EV"
  skipped=$((skipped + 1))
elif ! compgen -G "$KIMI_CRED/*.json" >/dev/null 2>&1; then
  echo "  SKIP: kimi not signed in (no OAuth credentials slot in $KIMI_CRED)" | tee -a "$EV"
  skipped=$((skipped + 1))
else
  _n="$(timeout 90 "$KIMI_BIN" -p "Reply exactly: KIMI-OK" --output-format text 2>&1 || true)"
  if printf '%s' "$_n" | grep -q 'KIMI-OK'; then
    _pass "native kimi -p replies KIMI-OK"
    passed=$((passed + 1))
  elif printf '%s' "$_n" | grep -qiE 'usage limit|quota will reset|rate limit|5-hour window'; then
    # Account-side state, live-proven 2026-09-05: the code-faster plan's 5-hour
    # usage window is exhausted (403 auth_error "quota will reset"). Same
    # family as SKIP-QUOTA in verify_aliases_live.sh — operator state, never a
    # toolkit FAIL.
    echo "  SKIP: kimi OAuth subscription is quota-limited right now (usage limit — not a toolkit defect)" | tee -a "$EV"
    skipped=$((skipped + 1))
  else
    _fail "native kimi smoke" "no KIMI-OK in reply: $(printf '%s' "$_n" | tail -c 300)"
    failed=$((failed + 1))
  fi
  printf '  detail(native): %.300s\n' "$(printf '%s' "$_n" | tr '\n' ' ')" >> "$EV"
fi

# ── 2. Discover + 3. smoke every materialized kimi twin ─────────────────────
# A kimi-<id> twin is ONLY the cma_run_kimi_provider form. The legacy names
# (kimi-for-coding etc.) are cma_run_provider lines and are NOT twins — they
# are picked apart by the legacy walk below. No fallback discovery: an alias
# file with zero twins is an honest "not materialized" SKIP.
KIMI_IDS=()
if [[ -f "$ALIAS_FILE" ]]; then
  mapfile -t KIMI_IDS < <(grep -E '^alias kimi-[A-Za-z0-9_-]+="cma_run_kimi_provider ' "$ALIAS_FILE" 2>/dev/null | sed -E 's/^alias (kimi-[A-Za-z0-9_-]+)="cma_run_kimi_provider ([A-Za-z0-9_-]+)"$/\1:\2/')
fi

if [[ ${#KIMI_IDS[@]} -eq 0 ]]; then
  it "kimi-<id> twin aliases (materialized by a v1.27.0 sync)"
  echo "  SKIP: no kimi-<id> alias in $ALIAS_FILE — run 'claude-providers sync' to materialize (needs a provider key on the host)" | tee -a "$EV"
  skipped=$((skipped + 1))
else
  for twin in "${KIMI_IDS[@]}"; do
    kimi_alias="${twin%%:*}"
    id="${twin#*:}"
    it "alias invariant: '$id' stays Claude (cma_run_provider), '$kimi_alias' is Kimi (cma_run_kimi_provider)"
    cf="$HOME/.kimi-prov-$id/config.toml"
    ef="$PDIR/$id.env"
    if ! grep -qE "^alias $id=\"cma_run_provider $id\"$" "$ALIAS_FILE"; then
      _fail "Claude twin invariant" "alias line for '$id' missing or not the cma_run_provider form (no-prefix behavior changed!)"
      failed=$((failed + 1))
    # A twin whose wrapper/config is missing was honestly emitted but never
    # rendered — a real defect of a sync that ran, not an absent prerequisite.
    elif [[ ! -f "$cf" ]]; then
      _fail "kimi-prov config" "missing $cf — the twin was emitted but its config.toml was not rendered"
      failed=$((failed + 1))
    elif [[ ! -f "$ef" ]]; then
      _fail "provider env" "missing $ef — the twin was emitted but its env record is gone"
      failed=$((failed + 1))
    else
      _pass "twin '$id'/'$kimi_alias' materialized (config + env + Claude-twin form intact)"
      passed=$((passed + 1))

      it "kimi-$id smoke through real ~/.kimi-prov-$id/config.toml"
      # Activation gate — same rule as the launch wrapper: a non-verified record
      # is not launchable without --force, so an honest SKIP (never a FAIL).
      _st="$(jq -r --arg x "$id" '.[$x].status // "pending"' "$PDIR/status.json" 2>/dev/null)"
      if [[ "$_st" != "verified" ]]; then
        echo "  SKIP: $id status=$_st — filtered by the verification gate, not launchable" | tee -a "$EV"
        skipped=$((skipped + 1))
        continue
      fi
      # CA wiring (spec §6.2): a private/self-signed https backend needs its CA
      # cert exported (NODE_EXTRA_CA_CERTS/SSL_CERT_FILE) or TLS is refused. The
      # launch wrapper sources the per-id env record (which may carry
      # CMA_PROVIDER_CA_CERT via the env writers) and the ambient var is only the
      # fallback. A PUBLIC-CA https provider (e.g. deepseek) needs NO CA var —
      # system roots suffice — so the mere absence of a CA pin is NOT a skip;
      # skipping it would starve the headline smoke leg on the common case. Only
      # a CONFIGURED-but-unreadable cert skips: the wrapper gates its export on
      # -r, so the launch would silently trust nothing and any exercise would be
      # false confidence.
      _ca="$(grep -E '^CMA_PROVIDER_CA_CERT=' "$ef" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "\"'")"
      [[ -z "$_ca" ]] && _ca="${CMA_PROVIDER_CA_CERT:-}"
      _base="$(grep -E '^CMA_PROVIDER_BASE_URL=' "$ef" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "\"'")"
      if [[ "$_base" == https://* && -n "$_ca" && ! -r "$_ca" ]]; then
        echo "  SKIP: $id configures CMA_PROVIDER_CA_CERT=$_ca but it is unreadable — TLS trust broken, nothing to exercise" | tee -a "$EV"
        skipped=$((skipped + 1))
        continue
      fi
      # Key availability: a resolved-empty key is an account-side absence, not a
      # toolkit defect — SKIP it as unavailable (matches the alias-verify SKIP
      # for no-key aliases).
      _kv="$(grep -E '^CMA_PROVIDER_KEYVAR=' "$ef" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "\"'")"
      _have=""
      if [[ "$_kv" == "_CMA_KIMICODE_OAUTH_" ]]; then
        compgen -G "$KIMI_CRED/*.json" >/dev/null 2>&1 && _have=1
      elif [[ -n "$_kv" ]]; then
        # shellcheck disable=SC1091  # runtime user keys file, path only known at execution
        ( set +u; source "${CMA_KEYS_FILE:-$HOME/api_keys.sh}" 2>/dev/null; eval "printf '%s' \"\${$_kv:-}\"" ) | grep -q . && _have=1
      fi
      if [[ -z "$_have" ]]; then
        echo "  SKIP: $id has no usable key on this host — account/key absent, alias unavailable" | tee -a "$EV"
        skipped=$((skipped + 1))
        continue
      fi
      _o="$( set +u; source "$ALIAS_FILE" >/dev/null 2>&1
              cma_run_kimi_provider "$id" -p "Reply exactly: KIMI-OK" --output-format text 2>&1 || true )"
      if printf '%s' "$_o" | grep -q 'KIMI-OK'; then
        _pass "kimi-$id replies KIMI-OK through the rendered config.toml"
        passed=$((passed + 1))
      else
        _fail "kimi-$id smoke" "no KIMI-OK in: $(printf '%s' "$_o" | tail -c 300)"
        failed=$((failed + 1))
      fi
      printf '  detail(kimi-%s): %.300s\n' "$id" "$(printf '%s' "$_o" | tr '\n' ' ')" >> "$EV"
    fi
  done
fi

# ── 4. Legacy rename walking the map ────────────────────────────────────────
it "legacy rename: kc-* forms + no kimi-kc-* echo"
_kc_leaks="$(grep -cE '^alias kimi-kc-' "$ALIAS_FILE" 2>/dev/null || true)"
if [[ -z "$_kc_leaks" || "$_kc_leaks" == "0" ]]; then
  _pass "no kimi-kc-* alias exists (the kimi-kc-* namespace is permanently vacated)"
  passed=$((passed + 1))
else
  _fail "kimi-kc-* alias exists" "found $_kc_leaks line(s) — forbidden by the namespace contract"
  failed=$((failed + 1))
fi
if [[ -f "$PDIR/status.json" ]]; then
  for old in kimi-for-coding kimi-for-coding2 kimi-for-coding-highspeed kimi-k3 kimi-k2p7; do
    new="$(legacy_new_of "$old")"
    [[ -z "$new" ]] && continue
    if jq -e --arg k "$new" 'has($k)' "$PDIR/status.json" >/dev/null 2>&1; then
      if grep -qE "^alias $new=\"cma_run_provider $new\"$" "$ALIAS_FILE"; then
        _pass "$new present as cma_run_provider $new (Kimi-native backend, Claude agent)"
        passed=$((passed + 1))
      else
        _fail "$new missing from alias file" "status.json carries $new but the alias is absent/wrong-form"
        failed=$((failed + 1))
      fi
      if grep -qE "^alias $old=" "$ALIAS_FILE"; then
        _fail "old name $old survives after migration" "status.json has $new yet the alias file still carries $old"
        failed=$((failed + 1))
      fi
    elif jq -e --arg k "$old" 'has($k)' "$PDIR/status.json" >/dev/null 2>&1; then
      echo "  SKIP: $old still in status.json (pre-sync host) — the rename runs AT 'claude-providers sync', not before it" | tee -a "$EV"
      skipped=$((skipped + 1))
    else
      echo "  SKIP: neither $old nor $new in status.json on this host" | tee -a "$EV"
      skipped=$((skipped + 1))
    fi
  done
fi

echo | tee -a "$EV"
echo "KIMI: passed: $passed failed: $failed skipped: $skipped" | tee -a "$EV"
summary
exit $failed