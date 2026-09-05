#!/usr/bin/env bash
# kimi-rollback.sh — Convenience wrapper that calls kimi-unify.sh with
# --rollback. Restores every .preunify.<timestamp> backup created by the kimi
# unification run and moves the kimi shared area ($SHARED_DIR/kimi) out of the
# way. Claude's $SHARED_DIR/** is never touched.

set -euo pipefail

# Resolve LIB_DIR through any symlinks (install.sh symlinks into ~/.local/bin).
_cma_src="${BASH_SOURCE[0]}"
while [ -L "$_cma_src" ]; do
  _cma_tgt="$(readlink "$_cma_src")"
  case "$_cma_tgt" in /*) _cma_src="$_cma_tgt" ;; *) _cma_src="$(dirname "$_cma_src")/$_cma_tgt" ;; esac
done
LIB_DIR="$(cd "$(dirname "$_cma_src")" && pwd)"
unset _cma_src _cma_tgt
exec "$LIB_DIR/kimi-unify.sh" --rollback "$@"