#!/usr/bin/env bash
# test_quota_probe.sh — unit tests for scripts/quota_probe.py's HTTP-probing
# and JSON-signal-walking logic (the `quota`/`limits` feature's provider-side
# extraction layer).
#
# Hermetic and offline: every test monkeypatches model_verify.http_get_json
# (the same function model_verify.py's own probe_balance_endpoint uses), so
# no real network call or API key is ever needed.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
set +e

it "resolve_window extracts amount_used/remaining/limit/unit/percent from an OpenRouter-shaped response"
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util, json

scripts_dir = sys.argv[1]
sys.path.insert(0, scripts_dir)  # so quota_probe.py's own `from model_verify import ...` resolves

spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv  # so quota_probe.py's `from model_verify import _dig, _walk, _dig_bool` finds THIS loaded instance

spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

# Monkeypatch at the model_verify module level — quota_probe.py does not
# call HTTP itself in resolve_window (resolve_window takes an already-fetched
# `body` dict as its second argument, per the brief for Task 3), so this
# monkeypatch exists for forward-compatibility with later tests in this file
# that DO exercise a live-fetch path; it is harmless here.
mv.http_get_json = lambda *a, **k: (200, {})

# The quota-endpoints.json fixture entry for openrouter, read from the REAL
# file Task 1 created (not duplicated here) — this is exactly
# contracts/quota-endpoint-spec-contract.md's worked example.
with open(scripts_dir + "/providers/quota-endpoints.json") as f:
    catalog = json.load(f)
entry = catalog["openrouter"]

body = {"data": {"limit_remaining": 52.68, "limit": 100.0, "usage": 47.32}}

result = qp.resolve_window(entry["windows"][0], body)

assert result is not None, "resolve_window returned None for a fully-populated response"
assert result["amount_remaining"] == 52.68, result
assert result["limit_total"] == 100.0, result
assert result["amount_used"] == 47.32, result
assert result["unit"] == "credits", result
assert result["percent_remaining"] == 100 * 52.68 / 100.0, result
assert result["resets"] is False, result
assert result["reset_at"] is None, result
PY
assert_eq 0 $? "resolve_window returns the correct dict shape for a fully-populated OpenRouter-style response"

summary
