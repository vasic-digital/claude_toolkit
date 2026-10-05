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
# The real cached-record shape the orchestrator writes (a successful
# probe_provider() result): a windowless record is no longer replayable
# (known-issues F2-stale-cache-replay), so the fixture carries its window.
real_data = {"providers": {"openrouter": {"provider_id": "openrouter", "windows": [
    {"window": "subscription", "amount_used": 47.32, "amount_remaining": 52.68, "limit_total": 100.0,
     "unit": "credits", "percent_remaining": 52.68, "resets": False, "reset_at": None}],
    "account_blocked": False, "absence_reason": None, "http_status": 200}}}

qp.save_quota_cache(cache_path, real_data)
back = qp.load_quota_cache(cache_path)

assert back["providers"]["openrouter"]["windows"][0]["amount_remaining"] == 52.68, back
assert back["providers"]["openrouter"]["windows"][0]["limit_total"] == 100.0, back
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

it "_first_signal_value resolves a reset_at ISO-8601 string signal (not routed through numeric _dig)"
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util

scripts_dir = sys.argv[1]
sys.path.insert(0, scripts_dir)

spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv

spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

signals = [{"path": ["data", "reset_at"], "type": "reset_at", "desc": "test fixture"}]
body = {"data": {"reset_at": "2026-10-06T00:00:00Z"}}

result = qp._first_signal_value(signals, "reset_at", body)
assert result == "2026-10-06T00:00:00Z", f"expected the raw ISO-8601 string, got {result!r}"
PY
assert_eq 0 $? "_first_signal_value resolves a reset_at ISO-8601 string signal without routing it through numeric _dig"

it "_first_signal_value rejects a malformed reset_at string (never guesses)"
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util

scripts_dir = sys.argv[1]
sys.path.insert(0, scripts_dir)

spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv

spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

signals = [{"path": ["data", "reset_at"], "type": "reset_at", "desc": "test fixture"}]
body = {"data": {"reset_at": "not-a-date"}}

result = qp._first_signal_value(signals, "reset_at", body)
assert result is None, f"expected None for a malformed timestamp, got {result!r}"
PY
assert_eq 0 $? "_first_signal_value returns None for a malformed reset_at string rather than guessing"

it "resolve_window sets resets=True and reset_at from a direct ISO-8601 signal (no reset_in_seconds present)"
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util

scripts_dir = sys.argv[1]
sys.path.insert(0, scripts_dir)

spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv

spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

window_spec = {
    "window": "daily",
    "signals": [
        {"path": ["data", "used"], "type": "amount_used", "desc": "test"},
        {"path": ["data", "remaining"], "type": "amount_remaining", "desc": "test"},
        {"path": ["data", "limit"], "type": "limit_total", "desc": "test"},
        {"path": [], "type": "unit_literal", "value": "requests"},
        {"path": ["data", "reset_at"], "type": "reset_at", "desc": "test"},
    ],
}
body = {"data": {"used": 10, "remaining": 90, "limit": 100, "reset_at": "2026-10-06T00:00:00Z"}}

result = qp.resolve_window(window_spec, body)
assert result is not None, "expected a real window, got None"
assert result["resets"] is True, result
assert result["reset_at"] == "2026-10-06T00:00:00Z", result
PY
assert_eq 0 $? "resolve_window resolves resets=True and reset_at from a direct ISO-8601 reset_at signal"

it "probe_provider: real openrouter spec resolves correctly against a response carrying limit_reset (reset_cadence label)"
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util, json

scripts_dir = sys.argv[1]
sys.path.insert(0, scripts_dir)

spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv

spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

# Shaped like a genuine OpenRouter /key response that includes limit_reset.
body = {"data": {"limit": 100, "limit_remaining": 40, "usage": 60, "limit_reset": "monthly"}}
qp.http_get_json = lambda *a, **k: (200, body)

with open(scripts_dir + "/providers/quota-endpoints.json") as f:
    catalog = json.load(f)
entry = catalog["openrouter"]

result = qp.probe_provider("openrouter", entry, "fake-key", 3.0)

assert result["absence_reason"] is None, result
assert len(result["windows"]) == 1, result
window = result["windows"][0]
assert window["amount_used"] == 60, window
assert window["amount_remaining"] == 40, window
assert window["limit_total"] == 100, window
assert window["unit"] == "credits", window
PY
assert_eq 0 $? "probe_provider resolves the real openrouter spec correctly against a response carrying limit_reset, without crashing on the reset_cadence signal"

it "resolve_window: limit_total == 0 resolves percent_remaining=0.0 instead of raising ZeroDivisionError"
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util

scripts_dir = sys.argv[1]
sys.path.insert(0, scripts_dir)

spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv

spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

# window_spec with amount_used=0, amount_remaining=0, limit_total=0 signals
# (all present, all zero) — this would raise ZeroDivisionError without the guard
window_spec = {
    "window": "subscription",
    "signals": [
        {"path": ["data", "used"], "type": "amount_used", "desc": "test"},
        {"path": ["data", "remaining"], "type": "amount_remaining", "desc": "test"},
        {"path": ["data", "limit"], "type": "limit_total", "desc": "test"},
        {"path": [], "type": "unit_literal", "value": "credits"},
    ],
}
body = {"data": {"used": 0, "remaining": 0, "limit": 0}}

result = qp.resolve_window(window_spec, body)
assert result is not None, f"expected a real window, got None"
assert result["percent_remaining"] == 0.0, f"expected percent_remaining=0.0, got {result['percent_remaining']!r}"
PY
assert_eq 0 $? "resolve_window returns percent_remaining=0.0 for limit_total=0 instead of raising ZeroDivisionError"

# --- known-issues B-probe ----------------------------------------------------
# Every block below loads the REAL scripts/quota_probe.py exactly like the
# tests above (model_verify first, so quota_probe's `from model_verify import`
# binds to this instance). Scratch files live under the sandbox $HOME only.

it "T17b-crossprocess-race: concurrent writer PROCESSES never expose a truncated cache file to a reader"
python3 - "$SCRIPTS_DIR" "$HOME" <<'PY'
import sys, importlib.util, json, os, subprocess, time

scripts_dir, home_dir = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts_dir)
spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv
spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

cache_dir = home_dir + "/race-cache"
cache_path = cache_dir + "/quota-cache.json"
# A payload large enough (~100 KB) that a truncate-then-write is observable.
payload = {"providers": {f"p{i}": {"provider_id": f"p{i}", "windows": [
    {"window": "subscription", "amount_used": i, "amount_remaining": 1, "limit_total": i + 1,
     "unit": "credits", "percent_remaining": 1.0, "resets": False, "reset_at": None}]}
    for i in range(400)}}
qp.save_quota_cache(cache_path, json.loads(json.dumps(payload)))

writer = (
    "import sys, json; sys.path.insert(0, sys.argv[1]); import quota_probe as qp\n"
    "data = json.loads(sys.argv[3])\n"
    "for _ in range(120):\n"
    "    qp.save_quota_cache(sys.argv[2], json.loads(json.dumps(data)))\n"
)
procs = [subprocess.Popen([sys.executable, "-c", writer, scripts_dir, cache_path, json.dumps(payload)])
         for _ in range(3)]
reads = bad = 0
deadline = time.time() + 120
while any(p.poll() is None for p in procs) and time.time() < deadline:
    reads += 1
    try:
        with open(cache_path) as f:
            json.load(f)
    except (OSError, json.JSONDecodeError):
        bad += 1
for p in procs:
    p.wait(timeout=60)
    assert p.returncode == 0, f"writer process failed rc={p.returncode}"
print(f"reads={reads} incomplete_reads={bad}")
assert reads > 0, "reader never observed the file while writers ran"
assert bad == 0, f"{bad} of {reads} reads saw a truncated/partial cache file"
leftovers = [n for n in os.listdir(cache_dir) if n != "quota-cache.json"]
assert leftovers == [], f"temp files left behind: {leftovers}"
PY
assert_eq 0 $? "no reader ever sees a truncated quota cache while 3 writer processes save concurrently (atomic temp+os.replace)"

it "T17b-crossprocess-race: a write that dies mid-dump leaves the previous cache intact and no temp file behind"
python3 - "$SCRIPTS_DIR" "$HOME" <<'PY'
import sys, importlib.util, json, os

scripts_dir, home_dir = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts_dir)
spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv
spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

cache_dir = home_dir + "/crash-cache"
cache_path = cache_dir + "/quota-cache.json"
good = {"providers": {"openrouter": {"provider_id": "openrouter", "windows": [
    {"window": "subscription", "amount_used": 1, "amount_remaining": 9, "limit_total": 10,
     "unit": "credits", "percent_remaining": 90.0, "resets": False, "reset_at": None}]}}}
qp.save_quota_cache(cache_path, good)
before = open(cache_path).read()

real_dump = qp.json.dump
def dying_dump(obj, fp, **kw):
    fp.write('{"_cache_version": ')  # partial bytes, then the process "dies"
    raise RuntimeError("simulated crash mid-write")
qp.json.dump = dying_dump
try:
    qp.save_quota_cache(cache_path, {"providers": {}})
    raise AssertionError("save_quota_cache swallowed the simulated crash")
except RuntimeError:
    pass
finally:
    qp.json.dump = real_dump

after = open(cache_path).read()
assert after == before, "the live cache file was modified by a failed write"
json.loads(after)
leftovers = [n for n in os.listdir(cache_dir) if n != "quota-cache.json"]
assert leftovers == [], f"temp files left behind after a failed write: {leftovers}"
PY
assert_eq 0 $? "a crashed save_quota_cache never truncates the live cache and cleans its temp file"

it "F2-stale-cache-replay: a cached record with no windows (pre-F2 empty row) is never replayed"
python3 - "$SCRIPTS_DIR" "$HOME" <<'PY'
import sys, importlib.util, json, time

scripts_dir, home_dir = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts_dir)
spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv
spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

now = time.time()
good_window = {"window": "subscription", "amount_used": 1, "amount_remaining": 9, "limit_total": 10,
               "unit": "credits", "percent_remaining": 90.0, "resets": False, "reset_at": None}
cache_path = home_dir + "/stale-replay-cache.json"
# The v1.30.0-era poisoned record shape from the register row (fresh
# timestamp, windows:[] with absence_reason:null), stamped with the CURRENT
# version so the windows filter -- not the version gate -- is what drops it.
with open(cache_path, "w") as f:
    json.dump({"_cache_version": qp.QUOTA_CACHE_VERSION, "_cached_at": now, "providers": {
        "openrouter": {"provider_id": "openrouter", "windows": [], "absence_reason": None,
                       "http_status": 200, "_cached_at": now},
        "failedprov": {"provider_id": "failedprov", "windows": [], "absence_reason": "probe_failed",
                       "http_status": 500, "_cached_at": now},
        "notalist": {"provider_id": "notalist", "windows": None, "_cached_at": now},
        "goodprov": {"provider_id": "goodprov", "windows": [good_window], "absence_reason": None,
                     "http_status": 200, "_cached_at": now},
    }}, f)

data = qp.load_quota_cache(cache_path)
provs = data["providers"]
assert "openrouter" not in provs, f"empty pre-F2 row was replayed: {provs.get('openrouter')!r}"
assert "failedprov" not in provs, f"a failed (windowless) row was replayed: {provs.get('failedprov')!r}"
assert "notalist" not in provs, f"a malformed windows field was replayed: {provs.get('notalist')!r}"
assert provs.get("goodprov", {}).get("windows") == [good_window], f"a valid record was lost: {provs!r}"
PY
assert_eq 0 $? "load_quota_cache drops windowless cached records (the pre-F2 empty row) and keeps valid ones"

it "I2-residual-cadence: a daily/monthly reset_cadence label reports resets=true, reset_at=null, reset_cadence=<label>"
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util, json

scripts_dir = sys.argv[1]
sys.path.insert(0, scripts_dir)
spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv
spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

with open(scripts_dir + "/providers/quota-endpoints.json") as f:
    window_spec = json.load(f)["openrouter"]["windows"][0]

for cadence in ("daily", "monthly"):
    body = {"data": {"limit": 10, "limit_remaining": 4, "usage": 6, "limit_reset": cadence}}
    r = qp.resolve_window(window_spec, body)
    assert r is not None, cadence
    assert r["resets"] is True, (cadence, r)
    assert r["reset_at"] is None, f"a cadence label must never become an invented timestamp: {r!r}"
    assert r["reset_cadence"] == cadence, (cadence, r)
PY
assert_eq 0 $? "daily and monthly cadence labels set resets=true with an honest null reset_at and a reset_cadence field"

it "I2-residual-cadence: a null / \"null\" / absent cadence still reports resets=false (does not reset)"
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util, json

scripts_dir = sys.argv[1]
sys.path.insert(0, scripts_dir)
spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv
spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

with open(scripts_dir + "/providers/quota-endpoints.json") as f:
    window_spec = json.load(f)["openrouter"]["windows"][0]

for label, data in (("json-null", {"limit_reset": None}), ("string-null", {"limit_reset": "null"}),
                    ("empty", {"limit_reset": ""}), ("absent", {}), ("non-string", {"limit_reset": 7})):
    body = {"data": dict({"limit": 10, "limit_remaining": 4, "usage": 6}, **data)}
    r = qp.resolve_window(window_spec, body)
    assert r is not None, label
    assert r["resets"] is False, (label, r)
    assert r["reset_at"] is None, (label, r)
    assert r.get("reset_cadence") is None, (label, r)
PY
assert_eq 0 $? "a null, \"null\", empty, non-string or absent cadence keeps resets=false and reset_cadence=null"

it "I2-residual-cadence: a real reset timestamp still wins over a cadence label (reset_at stays a real ISO-8601 value)"
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util

scripts_dir = sys.argv[1]
sys.path.insert(0, scripts_dir)
spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv
spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

window_spec = {"window": "daily", "signals": [
    {"path": ["d", "used"], "type": "amount_used"},
    {"path": ["d", "remaining"], "type": "amount_remaining"},
    {"path": ["d", "limit"], "type": "limit_total"},
    {"path": [], "type": "unit_literal", "value": "requests"},
    {"path": ["d", "reset_at"], "type": "reset_at"},
    {"path": ["d", "cadence"], "type": "reset_cadence"},
]}
body = {"d": {"used": 1, "remaining": 9, "limit": 10, "reset_at": "2026-10-06T00:00:00Z", "cadence": "daily"}}
r = qp.resolve_window(window_spec, body)
assert r["resets"] is True, r
assert r["reset_at"] == "2026-10-06T00:00:00Z", r
assert r["reset_cadence"] == "daily", r
PY
assert_eq 0 $? "a genuine reset_at timestamp is preserved when a cadence label is also present"

it "F1-no-hermetic-guard: main() never lets a host-wide CMA_PROVIDER_CA_CERT reach the probe's TLS trust"
python3 - "$SCRIPTS_DIR" "$HOME" <<'PY'
import sys, importlib.util, json, io, contextlib, os

scripts_dir, home_dir = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts_dir)
spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv
spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

# A real, readable (non-CA) file under the sandbox: if it leaked into
# model_verify.ca_ssl_context(), that function would consult it.
ca_path = home_dir + "/host-wide-unrelated-ca.pem"
with open(ca_path, "w") as f:
    f.write("not a certificate\n")
os.environ["CMA_PROVIDER_CA_CERT"] = ca_path

seen = {}
def capturing_http_get_json(url, headers, timeout):
    seen["env"] = os.environ.get("CMA_PROVIDER_CA_CERT")
    seen["ctx"] = mv.ca_ssl_context()  # exactly what the real http_get_json passes to urlopen
    return (200, {"data": {"limit_remaining": 52.68, "limit": 100.0, "usage": 47.32}})
qp.http_get_json = capturing_http_get_json

spec_path = home_dir + "/f1-guard-quota-endpoints.json"
with open(scripts_dir + "/providers/quota-endpoints.json") as f:
    catalog = json.load(f)
with open(spec_path, "w") as f:
    json.dump({"openrouter": catalog["openrouter"]}, f)

buf = io.StringIO()
with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(io.StringIO()):
    rc = qp.main(["--provider-id", "openrouter", "--spec-file", spec_path, "--timeout", "3"])
assert rc == 0, rc
assert "env" in seen, "the probe never reached http_get_json -- guard would be vacuous"
assert seen["env"] is None, f"CMA_PROVIDER_CA_CERT leaked into the probe: {seen['env']!r}"
assert seen["ctx"] is None, "ca_ssl_context() built a custom-CA context instead of system defaults"
assert json.loads(buf.getvalue())["absence_reason"] is None
PY
assert_eq 0 $? "a probe run through main() with CMA_PROVIDER_CA_CERT set uses system TLS defaults, never the host-wide CA"

it "F1-docstring: probe_provider documents the CMA_PROVIDER_CA_CERT precondition for in-process callers"
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util

scripts_dir = sys.argv[1]
sys.path.insert(0, scripts_dir)
spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv
spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

doc = qp.probe_provider.__doc__ or ""
assert "CMA_PROVIDER_CA_CERT" in doc, doc
assert "main()" in doc, doc
PY
assert_eq 0 $? "probe_provider's docstring names the CMA_PROVIDER_CA_CERT precondition that main() enforces"

it "T17a-main-notfound: main() with a provider id absent from the spec prints not_reported_by_provider and never probes"
python3 - "$SCRIPTS_DIR" "$HOME" <<'PY'
import sys, importlib.util, json, io, contextlib

scripts_dir, home_dir = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts_dir)
spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv
spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

calls = {"n": 0}
def counting(*a, **k):
    calls["n"] += 1
    return (200, {})
qp.http_get_json = counting

spec_path = home_dir + "/notfound-quota-endpoints.json"
with open(scripts_dir + "/providers/quota-endpoints.json") as f:
    catalog = json.load(f)
with open(spec_path, "w") as f:
    json.dump({"openrouter": catalog["openrouter"]}, f)

buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rc = qp.main(["--provider-id", "ghost-provider", "--spec-file", spec_path])
assert rc == 0, rc
parsed = json.loads(buf.getvalue())
assert parsed == {"provider_id": "ghost-provider", "windows": [], "account_blocked": False,
                  "absence_reason": "not_reported_by_provider", "http_status": None}, parsed
assert calls["n"] == 0, f"http_get_json called {calls['n']} times for an unknown provider"
PY
assert_eq 0 $? "main() reports not_reported_by_provider for an id missing from the spec, with zero HTTP calls"

# --- Hard probe deadline without coreutils `timeout` (I3-residual-no-coreutils)
# claude-providers.sh falls back to a bare `python3 quota_probe.py` when the
# `timeout` binary is absent, so the bound must hold INSIDE the probe. The
# driver below runs main() in its own process (the deadline ends that process
# with os._exit), with quota_probe's bound http_get_json replaced by a call
# that hangs for 10s -- far past --timeout 0.2 + the 2s deadline margin.
qp_driver="$HOME/.qp-deadline-driver.py"
cat > "$qp_driver" <<'PY'
import sys, json, time, importlib.util
scripts_dir, home_dir, mode = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, scripts_dir)
spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv
spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)
if mode == "hang":
    def hang(*a, **k):
        time.sleep(10)
        return (200, {"data": {"limit_remaining": 1, "limit": 2, "usage": 1}})
    qp.http_get_json = hang
else:
    qp.http_get_json = lambda *a, **k: (200, {"data": {"limit_remaining": 52.68, "limit": 100.0, "usage": 47.32}})
with open(scripts_dir + "/providers/quota-endpoints.json") as f:
    catalog = json.load(f)
spec_path = home_dir + "/deadline-quota-endpoints.json"
with open(spec_path, "w") as f:
    json.dump({"openrouter": catalog["openrouter"]}, f)
sys.exit(qp.main(["--provider-id", "openrouter", "--spec-file", spec_path, "--timeout", "0.2"]))
PY

it "main(): a probe whose HTTP call hangs returns probe_failed within the hard deadline, without the timeout binary"
qp_t0="$(date +%s)"
qp_out="$(python3 "$qp_driver" "$SCRIPTS_DIR" "$HOME" hang 2>/dev/null)"
qp_rc=$?
qp_elapsed=$(( $(date +%s) - qp_t0 ))
qp_fast=0; (( qp_elapsed <= 5 )) && qp_fast=1
assert_eq "1" "$qp_fast" "the probe must end at its ~2.2s hard deadline, not after the 10s hang (elapsed ${qp_elapsed}s)"
assert_eq "0" "$qp_rc" "the deadline exit status must be 0 (same as a normal probe_failed)"
assert_eq "1" "$(printf '%s\n' "$qp_out" | grep -c .)" "exactly one JSON line on stdout (got: $qp_out)"
assert_eq "probe_failed" "$(jq -r '.absence_reason' <<<"$qp_out" 2>/dev/null)" "absence_reason is probe_failed (got: $qp_out)"
assert_eq '["absence_detail","absence_reason","account_blocked","http_status","provider_id","windows"]' \
  "$(jq -c 'keys' <<<"$qp_out" 2>/dev/null)" "same key set as probe_provider's own probe_failed shape (got: $qp_out)"
assert_eq "openrouter|0|false|null" \
  "$(jq -r '"\(.provider_id)|\(.windows|length)|\(.account_blocked)|\(.http_status)"' <<<"$qp_out" 2>/dev/null)" \
  "provider_id / empty windows / account_blocked false / http_status null (got: $qp_out)"
jq -r '.absence_detail' <<<"$qp_out" 2>/dev/null | grep -q 'hard deadline' && ok=1 || ok=0
assert_eq "1" "$ok" "absence_detail names the hard deadline (got: $qp_out)"

it "main(): a fast probe is unaffected by the deadline -- normal windowed result, exactly one line"
qp_out="$(python3 "$qp_driver" "$SCRIPTS_DIR" "$HOME" fast 2>/dev/null)"
assert_eq "0" "$?" "fast probe exits 0"
assert_eq "1" "$(printf '%s\n' "$qp_out" | grep -c .)" "exactly one JSON line on stdout (got: $qp_out)"
assert_eq "null|52.68" "$(jq -r '"\(.absence_reason)|\(.windows[0].amount_remaining)"' <<<"$qp_out" 2>/dev/null)" \
  "the live windowed result is emitted unchanged (got: $qp_out)"

# --- Operator decision "Surface the real error": TLS failures -------------
#
# model_verify.http_get_json swallows every URLError/OSError (ssl.SSLError
# included) into (0, {}), so a bad certificate used to read as the generic
# "connection failed or timed out" -- indistinguishable from an outage.
# model_verify.py is deliberately NOT changed (other flows depend on it);
# quota_probe.py captures the TLS error in its own HTTP call path instead.
# The probe_failed JSON shape stays exactly the same: only absence_detail
# changes, and only for a TLS failure.

it "probe_provider: a TLS error raised by the HTTP call surfaces its real text in absence_detail"
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util, json, ssl

scripts_dir = sys.argv[1]
sys.path.insert(0, scripts_dir)

spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv

spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

def raising(*a, **k):
    raise ssl.SSLError("certificate verify failed: self signed certificate")
qp.http_get_json = raising

with open(scripts_dir + "/providers/quota-endpoints.json") as f:
    entry = json.load(f)["openrouter"]

result = qp.probe_provider("openrouter", entry, "fake-key", 3.0)

assert sorted(result) == ["absence_detail", "absence_reason", "account_blocked", "http_status", "provider_id", "windows"], result
assert result["absence_reason"] == "probe_failed", result
assert result["windows"] == [] and result["account_blocked"] is False, result
assert result["http_status"] == 0, result
d = result["absence_detail"]
assert "certificate verify failed" in d, d
assert "self signed certificate" in d, d
assert "TLS" in d, d
assert "fake-key" not in d, d
PY
assert_eq 0 $? "absence_detail names the TLS failure and carries the real ssl.SSLError text"

it "probe_provider: a real urlopen TLS failure (URLError wrapping SSLCertVerificationError) is not reported as a generic outage"
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util, json, ssl
from urllib.error import URLError

scripts_dir = sys.argv[1]
sys.path.insert(0, scripts_dir)

spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv

spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

# Stub at the lowest seam (urlopen) so the REAL request path runs, offline.
# The error text deliberately embeds the key and a query secret to prove
# neither is echoed into absence_detail.
seen = {}
def fake_urlopen(req, timeout=None, context=None):
    seen["called"] = True
    raise URLError(ssl.SSLCertVerificationError(
        1, "[SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed: "
           "self signed certificate (_ssl.c:1006) sk-SECRET-KEY "
           "https://quota.example/v1/key?token=QSECRET"))
mv.urlopen = fake_urlopen

entry = {"url": "https://quota.example/v1/key?token=QSECRET", "auth": "bearer", "windows": []}
result = qp.probe_provider("openrouter", entry, "sk-SECRET-KEY", 3.0)

assert seen.get("called"), "the stubbed urlopen was never reached"
assert sorted(result) == ["absence_detail", "absence_reason", "account_blocked", "http_status", "provider_id", "windows"], result
assert result["absence_reason"] == "probe_failed", result
assert result["http_status"] == 0, result
d = result["absence_detail"]
assert d != "connection failed or timed out", d
assert "certificate verify failed" in d, d
assert "TLS" in d, d
assert "sk-SECRET-KEY" not in d, d
assert "QSECRET" not in d, d
PY
assert_eq 0 $? "a urlopen-level TLS failure yields a TLS-specific absence_detail with no key or query secret"

it "probe_provider: non-TLS failures (timeout, connection refused, 5xx) keep their existing detail strings (guard)"
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util, json, socket
from urllib.error import URLError

scripts_dir = sys.argv[1]
sys.path.insert(0, scripts_dir)

spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv

spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

entry = {"url": "https://quota.example/v1/key", "auth": "bearer", "windows": []}

# 1) plain timeout at the urlopen seam (real request path).
def timeout_urlopen(req, timeout=None, context=None):
    raise socket.timeout("timed out")
mv.urlopen = timeout_urlopen
r = qp.probe_provider("x", entry, "k", 3.0)
assert r["absence_detail"] == "connection failed or timed out", r
assert r["http_status"] == 0, r

# 2) connection refused wrapped in URLError (non-SSL reason).
def refused_urlopen(req, timeout=None, context=None):
    raise URLError(ConnectionRefusedError(111, "Connection refused"))
mv.urlopen = refused_urlopen
r = qp.probe_provider("x", entry, "k", 3.0)
assert r["absence_detail"] == "connection failed or timed out", r

# 3) the existing (0, {}) contract from a stubbed http_get_json.
qp.http_get_json = lambda *a, **k: (0, {})
r = qp.probe_provider("x", entry, "k", 3.0)
assert r["absence_detail"] == "connection failed or timed out", r

# 4) 5xx keeps "HTTP <status>".
qp.http_get_json = lambda *a, **k: (503, {})
r = qp.probe_provider("x", entry, "k", 3.0)
assert r["absence_detail"] == "HTTP 503", r
assert r["http_status"] == 503, r
PY
assert_eq 0 $? "timeout / refused / (0,{}) give 'connection failed or timed out'; 503 gives 'HTTP 503'"

it "cache-version bump: a record stamped with the OLD version (1) is ignored; the CURRENT version is served"
python3 - "$SCRIPTS_DIR" "$HOME" <<'PY'
import sys, importlib.util, json, time

scripts_dir, home_dir = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts_dir)
spec = importlib.util.spec_from_file_location("model_verify", scripts_dir + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
sys.modules["model_verify"] = mv
spec2 = importlib.util.spec_from_file_location("quota_probe", scripts_dir + "/quota_probe.py")
qp = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qp)

now = time.time()
window = {"window": "subscription", "amount_used": 1, "amount_remaining": 9, "limit_total": 10,
          "unit": "credits", "percent_remaining": 90.0, "resets": False, "reset_at": None}
rec = {"provider_id": "openrouter", "windows": [window], "absence_reason": None,
       "http_status": 200, "_cached_at": now}

def seed(version):
    p = home_dir + "/version-gate-cache-v%s.json" % version
    with open(p, "w") as f:
        json.dump({"_cache_version": version, "_cached_at": now, "providers": {"openrouter": rec}}, f)
    return qp.load_quota_cache(p)

old = seed(1)
assert "openrouter" not in old["providers"], \
    "a version-1 record (pre-bump) was served as a cached row: %r" % old["providers"].get("openrouter")
assert old == {"_cache_version": qp.QUOTA_CACHE_VERSION, "providers": {}}, old

# True == 1 and 2.0 == 2 in Python: the gate must compare type as well as value.
for bogus in (0, 999, str(qp.QUOTA_CACHE_VERSION), None, True, float(qp.QUOTA_CACHE_VERSION)):
    got = seed(bogus)
    assert got["providers"] == {}, "version %r was accepted: %r" % (bogus, got)

cur = seed(qp.QUOTA_CACHE_VERSION)
assert cur["providers"].get("openrouter", {}).get("windows") == [window], cur
PY
assert_eq 0 $? "load_quota_cache rejects a version-1 (and any non-current) record and serves a current-version one"

summary
