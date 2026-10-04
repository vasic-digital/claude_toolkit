#!/usr/bin/env python3
"""quota_probe.py — resolves a provider's `quota-endpoints.json` window spec
against an already-fetched HTTP response body into a plain Usage Window dict.

This module does no HTTP itself (that is a later task's job); `resolve_window`
is a pure function over `(window_spec, body)`.

Reuses `model_verify.py`'s JSON-path helpers rather than re-implementing
JSON-path walking (`research.md §3`'s explicit decision).
"""

from datetime import datetime, timezone, timedelta

from model_verify import _dig, _walk, _dig_bool  # noqa: F401 (re-exported for later tasks)


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
