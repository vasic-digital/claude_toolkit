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

it "resolve_window drops the window entirely when only 1 of 3 core values resolves (never a placeholder)"
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util

scripts_dir = sys.argv[1]
sys.path.insert(0, scripts_dir)

spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv

spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

# Only amount_remaining is declared; no amount_used or limit_total signal at
# all, and no unit_literal either -- genuinely incomplete data.
window_spec = {
    "window": "subscription",
    "signals": [
        {"path": ["data", "remaining"], "type": "amount_remaining", "desc": "test fixture"},
    ],
}
body = {"data": {"remaining": 42.0}}

result = qp.resolve_window(window_spec, body)
assert result is None, f"expected None (dropped window), got {result!r}"
PY
assert_eq 0 $? "resolve_window returns None when only amount_remaining resolves (amount_used and limit_total both unresolvable)"

it "resolve_window converts reset_in_seconds to an absolute ISO-8601 reset_at using a frozen clock"
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util
from datetime import datetime, timezone, timedelta

scripts_dir = sys.argv[1]
sys.path.insert(0, scripts_dir)

spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv

spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

FROZEN_NOW = datetime(2026, 1, 1, 0, 0, 0, tzinfo=timezone.utc)

class FrozenDatetime(datetime):
    @classmethod
    def now(cls, tz=None):
        return FROZEN_NOW

qp.datetime = FrozenDatetime  # patch the name resolve_window's module looks up

window_spec = {
    "window": "daily",
    "signals": [
        {"path": ["data", "used"], "type": "amount_used", "desc": "test"},
        {"path": ["data", "remaining"], "type": "amount_remaining", "desc": "test"},
        {"path": ["data", "limit"], "type": "limit_total", "desc": "test"},
        {"path": [], "type": "unit_literal", "value": "requests"},
        {"path": ["data", "reset_in"], "type": "reset_in_seconds", "desc": "test"},
    ],
}
body = {"data": {"used": 10, "remaining": 90, "limit": 100, "reset_in": 3600}}

result = qp.resolve_window(window_spec, body)
assert result is not None, "expected a real window, got None"
expected_reset_at = (FROZEN_NOW + timedelta(seconds=3600)).isoformat()
assert result["reset_at"] == expected_reset_at, f"got {result['reset_at']!r}, want {expected_reset_at!r}"
assert result["resets"] is True, result
PY
assert_eq 0 $? "resolve_window converts reset_in_seconds=3600 to the correct absolute reset_at and sets resets=True"

it "load_quota_cache returns the empty shape for a missing path, and for an expired cache"
python3 - "$SCRIPTS_DIR" "$HOME" <<'PY'
import sys, importlib.util, json, time

scripts_dir, home_dir = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts_dir)

spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv

spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

# Case 1: path does not exist at all.
missing_path = home_dir + "/nonexistent-quota-cache.json"
result = qp.load_quota_cache(missing_path)
assert result == {"_cache_version": qp.QUOTA_CACHE_VERSION, "providers": {}}, result

# Case 2: path exists but its _cached_at is older than QUOTA_CACHE_TTL_SECONDS.
expired_path = home_dir + "/expired-quota-cache.json"
stale_ts = time.time() - qp.QUOTA_CACHE_TTL_SECONDS - 1
with open(expired_path, "w") as f:
    json.dump({"_cache_version": qp.QUOTA_CACHE_VERSION, "_cached_at": stale_ts,
               "providers": {"openrouter": {"fake": "stale data"}}}, f)
result2 = qp.load_quota_cache(expired_path)
assert result2 == {"_cache_version": qp.QUOTA_CACHE_VERSION, "providers": {}}, result2
PY
assert_eq 0 $? "load_quota_cache returns the empty shape for a missing path and for an expired cache (never partially trusted)"

it "save_quota_cache + load_quota_cache round-trip real data intact, with a fresh (non-expired) timestamp"
python3 - "$SCRIPTS_DIR" "$HOME" <<'PY'
import sys, importlib.util

scripts_dir, home_dir = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts_dir)

spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv

spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

cache_path = home_dir + "/roundtrip-quota-cache.json"
real_data = {"providers": {"openrouter": {"amount_remaining": 52.68, "limit_total": 100.0}}}

qp.save_quota_cache(cache_path, real_data)
back = qp.load_quota_cache(cache_path)

assert back["providers"]["openrouter"]["amount_remaining"] == 52.68, back
assert back["providers"]["openrouter"]["limit_total"] == 100.0, back
assert back["_cache_version"] == qp.QUOTA_CACHE_VERSION, back
PY
assert_eq 0 $? "save_quota_cache + load_quota_cache round-trip real provider data intact"

it "probe_provider: successful probe returns resolved windows"
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util, json

scripts_dir = sys.argv[1]
sys.path.insert(0, scripts_dir)

spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv

spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

# Patch quota_probe's OWN bound name (it imported http_get_json directly via
# `from model_verify import ... http_get_json`, which creates a separate
# binding in quota_probe's namespace — patching mv.http_get_json would NOT
# be observed by quota_probe.probe_provider).
body = {"data": {"limit_remaining": 52.68, "limit": 100.0, "usage": 47.32}}
qp.http_get_json = lambda *a, **k: (200, body)

with open(scripts_dir + "/providers/quota-endpoints.json") as f:
    catalog = json.load(f)
entry = catalog["openrouter"]

result = qp.probe_provider("openrouter", entry, "fake-key", 3.0)

assert result["absence_reason"] is None, result
assert len(result["windows"]) >= 1, result
assert result["http_status"] == 200, result
assert result["provider_id"] == "openrouter", result
PY
assert_eq 0 $? "probe_provider returns resolved windows + http_status=200 + absence_reason=None on a successful probe"

it "probe_provider: non-200 response returns probe_failed"
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util, json

scripts_dir = sys.argv[1]
sys.path.insert(0, scripts_dir)

spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv

spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

qp.http_get_json = lambda *a, **k: (500, {})

with open(scripts_dir + "/providers/quota-endpoints.json") as f:
    catalog = json.load(f)
entry = catalog["openrouter"]

result = qp.probe_provider("openrouter", entry, "fake-key", 3.0)

assert result["absence_reason"] == "probe_failed", result
assert result["windows"] == [], result
assert result["http_status"] == 500, result
assert result["account_blocked"] is False, result
PY
assert_eq 0 $? "probe_provider reports absence_reason=probe_failed and no windows on a non-200 HTTP response"

it "probe_provider: a 200 response that resolves zero windows gets a non-null absence_reason (data-model §1 invariant, never silently falls through)"
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util, json

scripts_dir = sys.argv[1]
sys.path.insert(0, scripts_dir)

spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv

spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

# Shaped EXACTLY like a real uncapped OpenRouter key's response: the REAL
# openrouter entry in providers/quota-endpoints.json reads
# data.limit_remaining (amount_remaining), data.limit (limit_total), and
# data.usage (amount_used). An uncapped key genuinely reports both
# limit_remaining and limit as null -- there is no cap, not a failure --
# which leaves only 1 of the 3 core values (amount_used) resolvable, so
# resolve_window drops the window and probe_provider must not silently
# return windows=[] with absence_reason=None (T038 review finding F2).
body = {"data": {"limit_remaining": None, "limit": None, "usage": 12.34}}
qp.http_get_json = lambda *a, **k: (200, body)

with open(scripts_dir + "/providers/quota-endpoints.json") as f:
    catalog = json.load(f)
entry = catalog["openrouter"]

result = qp.probe_provider("openrouter", entry, "fake-key", 3.0)

assert result["windows"] == [], result
assert result["absence_reason"] is not None, result
assert result["absence_reason"] == "probe_failed", result
assert isinstance(result.get("absence_detail"), str) and result["absence_detail"], result
assert result["http_status"] == 200, result
PY
assert_eq 0 $? "probe_provider returns absence_reason=probe_failed (never None) when a successful 200 response resolves zero windows"

it "probe_provider: spec with no url returns not_reported_by_provider, no HTTP call attempted"
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util

scripts_dir = sys.argv[1]
sys.path.insert(0, scripts_dir)

spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv

spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

call_count = {"n": 0}
def counting_http_get_json(*a, **k):
    call_count["n"] += 1
    return (200, {})
qp.http_get_json = counting_http_get_json

result = qp.probe_provider("no-url-provider", {}, "fake-key", 3.0)

assert result["absence_reason"] == "not_reported_by_provider", result
assert result["windows"] == [], result
assert result["http_status"] is None, result
assert call_count["n"] == 0, f"expected http_get_json to never be called, was called {call_count['n']} times"
PY
assert_eq 0 $? "probe_provider never calls http_get_json when the spec has no url, and returns not_reported_by_provider"

it "probe_provider: account_signals correctly sets account_blocked"
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util

scripts_dir = sys.argv[1]
sys.path.insert(0, scripts_dir)

spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv

spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

# This fixture's own quota signals must genuinely resolve a window --
# otherwise, under the F2 fix (T038 review), a zero-windows result legitimately
# gets absence_reason="probe_failed" regardless of account_blocked, and this
# test would be asserting the exact silent-fallthrough bug F2 closed.
body = {"data": {"account_suspended": True, "used": 1.0, "remaining": 9.0, "limit": 10.0}}
qp.http_get_json = lambda *a, **k: (200, body)

fake_spec = {
    "url": "https://example.test/v1/key",
    "auth": "bearer",
    "account_signals": [
        {"path": ["data", "account_suspended"], "type": "account_blocked", "desc": "test fixture"},
    ],
    "windows": [
        {
            "window": "subscription",
            "signals": [
                {"path": ["data", "used"], "type": "amount_used", "desc": "test fixture"},
                {"path": ["data", "remaining"], "type": "amount_remaining", "desc": "test fixture"},
                {"path": ["data", "limit"], "type": "limit_total", "desc": "test fixture"},
                {"path": [], "type": "unit_literal", "value": "credits"},
            ],
        }
    ],
}

result = qp.probe_provider("fake-provider", fake_spec, "fake-key", 3.0)

assert result["account_blocked"] is True, result
assert result["absence_reason"] is None, result
assert len(result["windows"]) == 1, result
PY
assert_eq 0 $? "probe_provider sets account_blocked=True when an account_blocked signal resolves to true"

it "quota_probe.py main(): CLI entrypoint end-to-end with a spec file on disk"
python3 - "$SCRIPTS_DIR" "$HOME" <<'PY'
import sys, importlib.util, json, io, contextlib

scripts_dir, home_dir = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts_dir)

spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv

spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

body = {"data": {"limit_remaining": 52.68, "limit": 100.0, "usage": 47.32}}
qp.http_get_json = lambda *a, **k: (200, body)

spec_path = home_dir + "/cli-quota-endpoints.json"
with open(scripts_dir + "/providers/quota-endpoints.json") as f:
    catalog = json.load(f)
with open(spec_path, "w") as f:
    json.dump({"openrouter": catalog["openrouter"]}, f)

buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rc = qp.main([
        "--provider-id", "openrouter",
        "--spec-file", spec_path,
        "--api-key-env", "FAKE_KEY",
        "--timeout", "3",
    ])

assert rc == 0, rc
parsed = json.loads(buf.getvalue())
assert parsed["provider_id"] == "openrouter", parsed
assert len(parsed["windows"]) >= 1, parsed
assert parsed["absence_reason"] is None, parsed
PY
assert_eq 0 $? "quota_probe.py's main() CLI entrypoint reads a spec file, probes, and prints valid JSON"

it "resolve_account_blocked: account_blocked signal resolves true"
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util

scripts_dir = sys.argv[1]
sys.path.insert(0, scripts_dir)

spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv

spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

spec = {"account_signals": [{"path": ["data", "suspended"], "type": "account_blocked"}]}
body = {"data": {"suspended": True}}
result = qp.resolve_account_blocked(spec, body)
assert result is True, f"expected True, got {result!r}"
PY
assert_eq 0 $? "resolve_account_blocked returns True when account_blocked signal resolves to true"

it "resolve_account_blocked: account_blocked signal resolves false"
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util

scripts_dir = sys.argv[1]
sys.path.insert(0, scripts_dir)

spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv

spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

spec = {"account_signals": [{"path": ["data", "suspended"], "type": "account_blocked"}]}
body = {"data": {"suspended": False}}
result = qp.resolve_account_blocked(spec, body)
assert result is False, f"expected False, got {result!r}"
PY
assert_eq 0 $? "resolve_account_blocked returns False when account_blocked signal resolves to false"

it "resolve_account_blocked: no account_signals key returns False (documented default)"
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util

scripts_dir = sys.argv[1]
sys.path.insert(0, scripts_dir)

spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv

spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

spec = {}
body = {"data": {}}
result = qp.resolve_account_blocked(spec, body)
assert result is False, f"expected False, got {result!r}"
PY
assert_eq 0 $? "resolve_account_blocked returns False when spec has no account_signals key (documented default)"

it "resolve_account_blocked: account_blocked_negated signal inverts correctly"
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util

scripts_dir = sys.argv[1]
sys.path.insert(0, scripts_dir)

spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv

spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

spec = {"account_signals": [{"path": ["data", "active"], "type": "account_blocked_negated"}]}
body = {"data": {"active": False}}
result = qp.resolve_account_blocked(spec, body)
assert result is True, f"expected True (NOT active -> blocked), got {result!r}"
PY
assert_eq 0 $? "resolve_account_blocked handles account_blocked_negated type correctly (inverts the signal)"

summary
