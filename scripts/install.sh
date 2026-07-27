#!/usr/bin/env bash
# install.sh — One-shot bootstrap for the Claude multi-account toolkit.
# Idempotent; safe to re-run after pulling updates.
#
# What it does, in order:
#   1. Detect tooling (jq, rsync, awk, pandoc) and fail fast if missing.
#   2. Symlink every script into ~/.local/bin (creates the dir if needed).
#   3. Ensure ~/.local/bin is on PATH for future shells.
#   4. Create the managed alias file at $ALIAS_FILE and source it from
#      ~/.bashrc and ~/.zshrc (whichever exist).
#   5. Run claude-unify.sh to merge any existing account dirs.
#   6. Run claude-export-docs.sh to refresh the PDF/HTML alongside the
#      markdown doc.

set -euo pipefail

# macOS ships bash 3.2 which lacks `mapfile`. If a newer bash is available
# (Homebrew installs it at /opt/homebrew/bin/bash on Apple Silicon, or
# /usr/local/bin/bash on Intel), re-exec with it. Otherwise tell the user
# how to install it.
if (( BASH_VERSINFO[0] < 4 )); then
  for newer in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$newer" ]] && exec "$newer" "$0" "$@"
  done
  echo "claude-toolkit requires bash 4+. Install via: brew install bash" >&2
  exit 1
fi

# Resolve LIB_DIR through any symlinks (install.sh symlinks into ~/.local/bin).
_cma_src="${BASH_SOURCE[0]}"
while [ -L "$_cma_src" ]; do
  _cma_tgt="$(readlink "$_cma_src")"
  case "$_cma_tgt" in /*) _cma_src="$_cma_tgt" ;; *) _cma_src="$(dirname "$_cma_src")/$_cma_tgt" ;; esac
done
LIB_DIR="$(cd "$(dirname "$_cma_src")" && pwd)"
unset _cma_src _cma_tgt
# shellcheck source=lib.sh
source "$LIB_DIR/lib.sh"

cma_log "platform: $(cma_os)"

# 1. Required tooling. pandoc is needed only for doc export; the rest are
# load-bearing for unify/add-account.
for t in rsync jq awk; do cma_require "$t"; done
command -v pandoc >/dev/null 2>&1 || cma_warn "pandoc not found — PDF/HTML export will be skipped"

# 1b. Node deps for the optional TOON utility (scripts/toon.mjs, and the
# toon_encode.py wrapper that shells out to it). Soft by design: the toolkit's
# core (unify/add-account) needs no Node, so a missing npm is a warning, not a
# hard failure. Idempotent — npm install is a no-op once @toon-format/toon is
# already present. (node_modules/ is gitignored; this is how the dep arrives.)
_cma_repo_root="$(cd "$LIB_DIR/.." && pwd)"
if [[ -f "$_cma_repo_root/package.json" ]]; then
  if command -v npm >/dev/null 2>&1; then
    cma_log "installing Node deps for the TOON utility (npm install) ..."
    ( cd "$_cma_repo_root" && npm install --no-audit --no-fund --silent ) \
      || cma_warn "npm install failed — scripts/toon.mjs (TOON utility) may be unavailable"
  else
    cma_warn "npm not found — scripts/toon.mjs (TOON utility) unavailable until you run 'npm install' in $_cma_repo_root"
  fi
fi
unset _cma_repo_root

# 2. Symlink the scripts onto PATH.
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN_DIR"
for f in "$LIB_DIR"/claude-*.sh; do
  name="$(basename "$f" .sh)"
  link="$BIN_DIR/$name"
  if [[ -L "$link" || -e "$link" ]]; then
    if [[ "$(cma_realpath "$link")" != "$(cma_realpath "$f")" ]]; then
      mv "$link" "${link}.preunify.$(date +%Y%m%d%H%M%S)"
      ln -s "$f" "$link"
      cma_log "linked $link -> $f"
    fi
  else
    ln -s "$f" "$link"
    cma_log "linked $link -> $f"
  fi
done

# 2b. Build the BUNDLED Go claude-code-router (submodule) and install it as
# `ccr`, so the provider aliases route through OUR vendored router rather than a
# separately-installed Node one.
#
# NOT best-effort any more (field failure 2026-07-22, operator host, v1.25.4):
# this was `if ! bash ...; then cma_warn ...`, so a build failure only WARNED,
# the install continued, and the banner still printed "[done] installed" while
# the npm @musistudio ccr kept answering for `ccr`. The operator's FIRST
# symptom was a provider alias dying at RUNTIME. An installer that reports
# success over a broken product is a §11.4 PASS-bluff at the install layer.
#
# The failure is RECORDED and re-raised by step 7 rather than aborting here:
# the remaining steps (PATH, aliases, unify) are independent and still worth
# completing, and step 7 then reports EVERY problem at once instead of making
# the operator re-run once per failure.
# Declared together (and BEFORE first use) so `set -u` never trips on an
# append to an unset array, and so step 7 can length-test them safely.
CMA_INSTALL_FAILURES=()
CMA_INSTALL_DEGRADED=()
if ! bash "$LIB_DIR/claude-ccr-build.sh"; then
  CMA_INSTALL_FAILURES+=("bundled claude-code-router (Go) did NOT build/install — provider aliases on the router transport cannot launch. Fix: ensure a Go toolchain new enough for submodules/claude-code-router/go.mod is available (install/upgrade Go: https://go.dev/dl/ — or, with an older Go already installed and network access: GOTOOLCHAIN=auto claude-ccr-build), then run: claude-ccr-build")
fi

# 3. Make sure ~/.local/bin is on PATH for new shells. We add to .bashrc
# and .zshrc once; existing shells need a manual reload.
# shellcheck disable=SC2016  # $HOME/$PATH are intentionally unexpanded literals written into rc files
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
for rc in "${CMA_RC_FILES[@]}"; do
  [[ -f "$rc" ]] || continue
  if ! grep -F -q "$PATH_LINE" "$rc"; then
    # Backup-first, idempotent BEGIN/END block (refuses if it cannot back up).
    cma_rc_append_managed "$rc" path "$PATH_LINE" || true
  fi
done

# 4. Alias file + rc sourcing.
cma_ensure_alias_file

# Re-register any pre-existing aliases from $HOME/.bashrc into the managed
# alias file, then comment out the originals so they're not duplicated.
migrate_inline_aliases() {
  local rc="$1"
  [[ -f "$rc" ]] || return 0
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
  local changed=0
  # `|| [[ -n "$line" ]]` so a final line with NO trailing newline is still
  # processed rather than silently dropped (mirrors lib.sh's rc read loops).
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^alias[[:space:]]+(claude[0-9a-zA-Z_-]+)=.*CLAUDE_CONFIG_DIR=([^[:space:]\"]+) ]]; then
      local a="${BASH_REMATCH[1]}" d="${BASH_REMATCH[2]}"
      d="${d//\"/}"
      d="${d/#\$HOME/$HOME}"
      d="${d/#~/$HOME}"
      cma_write_alias "$a" "$d"
      printf '# migrated to %s: %s\n' "$ALIAS_FILE" "$line" >> "$tmp"
      changed=1
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$rc"
  if (( changed )); then
    # migrate removes NOTHING (it only comment-prefixes lines in place), so the
    # intended removal count is 0 — cma_rc_safe_rewrite's content-loss gate then
    # REFUSES any candidate that lost a line (e.g. a newline-less final line the
    # old read loop could drop) and parks it instead of publishing. The committer
    # also takes the pristine .cma-orig backup, superseding the bespoke .preunify.
    if cma_rc_safe_rewrite "$rc" "$tmp" 0; then
      cma_log "migrated inline claude* aliases in $rc -> $ALIAS_FILE"
    else
      cma_warn "skipped migrating inline aliases in $rc (rejected or unbackupable)"
    fi
  else
    rm -f "$tmp"
  fi
}
for rc in "${CMA_RC_FILES[@]}"; do
  migrate_inline_aliases "$rc"
done

# 4b. Build + install the Go compatibility proxy (cma-proxy) for provider
# compatibility (helixagent Hermes tool-call recovery + poe/kimi/sarvam
# request-schema fixes). Replaces the former per-provider python proxies.
# Recorded (not warn-and-forget) for the same reason as 2b: without it the
# helixagent/poe/kimi/sarvam aliases silently lose their compat shims, which is
# a DEGRADED product the operator must be told about by name — step 7 reports
# it. It is a DEGRADED (not FAILED) capability: those aliases still launch
# against their direct endpoint, so it must not by itself fail the install.
if ! bash "$LIB_DIR/claude-proxy-build.sh"; then
  CMA_INSTALL_DEGRADED+=("compatibility proxy (cma-proxy, Go) did NOT build — helixagent/poe/kimi/sarvam aliases run WITHOUT their compat shims (Hermes tool-call recovery + request-schema fixes inactive). Fix: install Go, then run: claude-proxy-build")
fi

# 4c. Provider session-sync hook + an install-time sync (soft — the host may
# lack keys/network at install time, so a failure here is non-fatal). The hook
# refreshes provider aliases from cache on every new shell (no network) and
# kicks a detached full sync when the cache is stale (§11.4.89).
cma_install_session_hook
if [[ -x "$LIB_DIR/claude-providers.sh" ]]; then
  cma_log "running claude-providers sync (install-time; soft)"
  ( "$LIB_DIR/claude-providers.sh" sync ) || cma_warn "provider sync skipped (no keys/network?)"
fi

# 5. Unify whatever accounts exist now.
if (( $(cma_detect_accounts | wc -l) > 0 )); then
  cma_log "running claude-unify.sh"
  "$LIB_DIR/claude-unify.sh"
else
  cma_warn "no ~/${ACCOUNT_PREFIX}* dirs detected — add one with claude-add-account.sh"
fi

# 6. Refresh docs if pandoc is available.
if command -v pandoc >/dev/null 2>&1 && [[ -f "$HOME/Documents/Claude_Multi_Account_Fine_Tuning.md" ]]; then
  cma_log "running claude-export-docs.sh"
  "$LIB_DIR/claude-export-docs.sh" || cma_warn "doc export failed (continuing)"
fi

# 7. SELF-VERIFY, then report honestly.
#
# The banner below is the toolkit's success claim. It is now EARNED, not
# printed unconditionally: claude-install-verify probes the REAL artifacts the
# runtime will resolve (it does not grep our own source), so "[done]" can no
# longer appear over a product whose router is missing or is the npm
# doppelganger. Any recorded build failure from 2b, or any verify FAIL, exits
# non-zero with the actionable fix.
if [[ ! -f "$LIB_DIR/claude-install-verify.sh" ]]; then
  # Say WHICH file is missing rather than letting bash emit a bare
  # "No such file or directory" that reads like a bug in the installer.
  # A checkout without the gate cannot demonstrate a good install, so this is
  # a failure, not a skip — never assume-good on a missing verifier.
  CMA_INSTALL_FAILURES+=("post-install self-verify is MISSING ($LIB_DIR/claude-install-verify.sh) — this checkout cannot prove the install is good. Fix: re-pull the repository.")
elif ! bash "$LIB_DIR/claude-install-verify.sh"; then
  CMA_INSTALL_FAILURES+=("post-install self-verify FAILED — see the [FAIL] lines above")
fi

if (( ${#CMA_INSTALL_DEGRADED[@]} > 0 )); then
  printf '\n[warn] claude-multi-account installed with DEGRADED optional components:\n' >&2
  for _d in "${CMA_INSTALL_DEGRADED[@]}"; do printf '  - %s\n' "$_d" >&2; done
fi

if (( ${#CMA_INSTALL_FAILURES[@]} > 0 )); then
  printf '\n[FAILED] claude-multi-account install did NOT complete successfully.\n\n' >&2
  for _f in "${CMA_INSTALL_FAILURES[@]}"; do printf '  - %s\n' "$_f" >&2; done
  printf '\nNothing above was silently ignored. Fix the items and re-run: %s\n' "$LIB_DIR/install.sh" >&2
  printf 'To re-check without a full re-install:  claude-install-verify\n' >&2
  exit 1
fi

cat <<EOF

[done] claude-multi-account installed.

  Scripts on PATH:  $BIN_DIR/claude-{unify,add-account,remove-account,list-accounts,rollback,export-docs}
  Alias file:       $ALIAS_FILE
  Shared store:     $SHARED_DIR

Open a new shell (or run: source $ALIAS_FILE) so the aliases load, then:
  claude-list-accounts            # see what's wired up
  claude-add-account              # add another account interactively
EOF
