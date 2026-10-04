#!/usr/bin/env python3
"""quota_probe.py — resolves a provider's `quota-endpoints.json` window spec
against an already-fetched HTTP response body into a plain Usage Window dict,
and (since Task 17a) live-probes one provider over HTTP via `probe_provider`
plus a `main()` CLI entrypoint for a later bash orchestrator (T017b) to invoke
as a subprocess per provider.

`resolve_window` itself remains a pure function over `(window_spec, body)` —
`probe_provider` is the thin HTTP-calling wrapper around it.

Reuses `model_verify.py`'s JSON-path helpers rather than re-implementing
JSON-path walking (`research.md §3`'s explicit decision).

`QUOTA_CACHE_TTL_SECONDS` (21600 = 6 hours) is `model_verify.CREDIT_CACHE_TTL_SECONDS`
(86400 = 24 hours, as of this task) divided by 4: quota data is operator-facing
and should go stale faster than the credit cache's model-selection concern
(research.md §4).
"""

import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone, timedelta

from model_verify import _dig, _walk, _dig_bool, http_get_json  # noqa: F401 (re-exported for later tasks)

QUOTA_CACHE_VERSION = 1
QUOTA_CACHE_TTL_SECONDS = 21600  # 6 hours = CREDIT_CACHE_TTL_SECONDS (86400) / 4 —
# quota data is operator-facing and should go stale faster than the
# credit cache's model-selection concern (research.md §4).


def _first_signal_value(signals, type_name, body):
    """Scan `signals` in list order and return the value from the FIRST entry
    whose `"type"` matches `type_name` — ordered, first-present-wins, the same
    rule every declarative spec file in this project already uses."""
    for sig in signals:
        if sig.get("type") != type_name:
            continue
        if type_name == "unit_literal":
            if "value" in sig:
                return sig["value"]
            continue
        val = _dig(body, sig.get("path") or [])
        if val is None:
            continue
        minus_path = sig.get("minus")
        if minus_path:
            spent = _dig(body, minus_path)
            if spent is not None:
                val = val - spent
        return val
    return None


def resolve_window(window_spec: dict, body: dict) -> dict | None:
    """Resolve one `quota-endpoints.json` window entry against an
    already-fetched response `body`. Returns a Usage Window dict, or `None`
    if the window must be dropped (a required value could not be resolved
    or derived)."""
    window = window_spec.get("window")
    signals = window_spec.get("signals") or []

    amount_used = _first_signal_value(signals, "amount_used", body)
    amount_remaining = _first_signal_value(signals, "amount_remaining", body)
    limit_total = _first_signal_value(signals, "limit_total", body)
    percent_direct = _first_signal_value(signals, "percent_remaining", body)
    unit = _first_signal_value(signals, "unit_literal", body)
    reset_at_direct = _first_signal_value(signals, "reset_at", body)
    reset_in_seconds = _first_signal_value(signals, "reset_in_seconds", body)

    # Derivation (rule 2): if exactly 2 of the 3 core values are present,
    # derive the third.
    present_count = sum(
        1 for v in (amount_used, amount_remaining, limit_total) if v is not None
    )
    if present_count == 2:
        if amount_used is None:
            amount_used = limit_total - amount_remaining
        elif amount_remaining is None:
            amount_remaining = limit_total - amount_used
        elif limit_total is None:
            limit_total = amount_used + amount_remaining

    # Drop conditions (rules 3 and 6, plus the ruling on the under-specified
    # edge case): any of the three core values still missing, or no unit at
    # all, means this window can never be rendered correctly downstream.
    if amount_used is None or amount_remaining is None or limit_total is None:
        return None
    if unit is None:
        return None

    # Percent remaining (rule 4): trust the provider's own figure if present.
    if percent_direct is not None:
        percent_remaining = percent_direct
    else:
        percent_remaining = 100 * amount_remaining / limit_total

    # Reset handling (rule 5).
    if reset_in_seconds is not None:
        reset_at = (
            datetime.now(timezone.utc) + timedelta(seconds=reset_in_seconds)
        ).isoformat()
        resets = True
    elif reset_at_direct is not None:
        reset_at = reset_at_direct
        resets = True
    else:
        reset_at = None
        resets = False

    return {
        "window": window,
        "amount_used": amount_used,
        "amount_remaining": amount_remaining,
        "limit_total": limit_total,
        "unit": unit,
        "percent_remaining": percent_remaining,
        "resets": resets,
        "reset_at": reset_at,
    }


def probe_provider(provider_id, spec, api_key, timeout):
    """Live-probe one quota-endpoints.json provider entry. Returns a dict:
    {provider_id, windows: [...], account_blocked: bool,
     absence_reason: str|None, http_status: int|None}."""
    url = spec.get("url")
    if not url:
        return {
            "provider_id": provider_id, "windows": [], "account_blocked": False,
            "absence_reason": "not_reported_by_provider", "http_status": None,
        }

    auth = (spec.get("auth") or "bearer").lower()
    if auth == "bearer":
        headers = {"Authorization": f"Bearer {api_key}"}
    elif auth == "x-api-key":
        headers = {"x-api-key": api_key}
    else:
        headers = {(spec.get("auth_header") or "Authorization"): api_key}

    status, body = http_get_json(url, headers, timeout)
    if status != 200 or not isinstance(body, dict):
        return {
            "provider_id": provider_id, "windows": [], "account_blocked": False,
            "absence_reason": "probe_failed", "http_status": status,
        }

    account_blocked = False
    for sig in (spec.get("account_signals") or []):
        kind = (sig.get("type") or "").lower()
        if kind not in ("account_blocked", "account_blocked_negated"):
            continue
        flag = _dig_bool(body, sig.get("path") or [])
        if flag is None:
            continue
        account_blocked = flag if kind == "account_blocked" else (not flag)
        break

    windows = []
    for w in (spec.get("windows") or []):
        resolved = resolve_window(w, body)
        if resolved is not None:
            windows.append(resolved)

    return {
        "provider_id": provider_id, "windows": windows,
        "account_blocked": account_blocked, "absence_reason": None,
        "http_status": status,
    }


def load_quota_cache(path):
    """Read the quota cache, honouring the same version+TTL gate the
    credit cache applies. A rejected cache comes back empty, never
    partially trusted."""
    if not path or not os.path.exists(path):
        return {"_cache_version": QUOTA_CACHE_VERSION, "providers": {}}
    try:
        with open(path) as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError):
        return {"_cache_version": QUOTA_CACHE_VERSION, "providers": {}}
    if not isinstance(data, dict) or data.get("_cache_version") != QUOTA_CACHE_VERSION:
        return {"_cache_version": QUOTA_CACHE_VERSION, "providers": {}}
    ts = data.get("_cached_at")
    if not isinstance(ts, (int, float)) or time.time() - ts > QUOTA_CACHE_TTL_SECONDS:
        return {"_cache_version": QUOTA_CACHE_VERSION, "providers": {}}
    data.setdefault("providers", {})
    return data


def save_quota_cache(path, data):
    if not path:
        return
    data["_cache_version"] = QUOTA_CACHE_VERSION
    data["_cached_at"] = time.time()
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Probe one provider's quota/limits")
    ap.add_argument("--provider-id", required=True)
    ap.add_argument("--spec-file", required=True)
    ap.add_argument("--api-key-env", default="")
    ap.add_argument("--timeout", type=float, default=3.0)
    args = ap.parse_args(argv)

    try:
        with open(args.spec_file) as f:
            all_specs = json.load(f)
    except (OSError, json.JSONDecodeError):
        all_specs = {}

    spec = all_specs.get(args.provider_id)
    if spec is None:
        print(json.dumps({
            "provider_id": args.provider_id, "windows": [], "account_blocked": False,
            "absence_reason": "not_reported_by_provider", "http_status": None,
        }))
        return 0

    api_key = os.environ.get(args.api_key_env, "") if args.api_key_env else ""
    result = probe_provider(args.provider_id, spec, api_key, args.timeout)
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
