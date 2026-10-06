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
import math
import os
import re
import shlex
import ssl
import sys
import threading
import tempfile
import time
from datetime import datetime, timezone, timedelta
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit

import model_verify as _mv
from model_verify import _dig, _walk, _dig_bool  # noqa: F401 (re-exported for later tasks)


def http_get_json(url, headers=None, timeout=_mv.TIMEOUT_DEFAULT):
    """quota_probe's own GET-JSON call: model_verify.http_get_json's exact
    semantics (same Request, same urlopen, same ca_ssl_context(), same
    (status, body) return), with ONE difference -- a TLS failure is RE-RAISED
    instead of being folded into (0, {}).

    Operator decision "Surface the real error": model_verify.http_get_json
    swallows ssl.SSLError (an OSError) and URLError(reason=SSLError) into the
    same (0, {}) an outage produces, so a bad certificate was reported as
    "connection failed or timed out". model_verify.py is deliberately NOT
    changed (other flows depend on its contract); probe_provider() catches the
    re-raised TLS error and records its text in absence_detail. Every non-TLS
    failure still returns (0, {}) exactly as before.

    Request / urlopen / ca_ssl_context are looked up on the model_verify
    module at call time, so a test that stubs model_verify.urlopen drives this
    real path offline."""
    req = _mv.Request(url, headers=headers or {}, method="GET")
    try:
        with _mv.urlopen(req, timeout=timeout, context=_mv.ca_ssl_context()) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            return resp.status, json.loads(raw)
    except HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode("utf-8", errors="replace"))
        except Exception:
            return e.code, {}
    except ssl.SSLError:
        raise
    except URLError as e:
        if isinstance(e.reason, ssl.SSLError):
            raise
        return 0, {}
    except (OSError, TimeoutError):
        return 0, {}


_TLS_DETAIL_MAX = 300


def _tls_failure_detail(exc, url, api_key):
    """absence_detail for a TLS failure: names it as TLS and carries the real
    exception text, with the API key and any URL query string redacted (the
    text comes from the ssl layer, which today never embeds either -- this is
    a defence, not an observed leak)."""
    err = exc.reason if isinstance(exc, URLError) else exc
    text = getattr(err, "strerror", None)
    if not isinstance(text, str) or not text:
        args = getattr(err, "args", ())
        text = args[0] if len(args) == 1 and isinstance(args[0], str) else str(err)
    if api_key:
        text = text.replace(api_key, "<redacted>")
    if url and "?" in url:
        text = text.replace(url, url.split("?", 1)[0] + "?<redacted>")
    text = re.sub(r"\?[^\s'\")]+", "?<redacted>", text)
    text = " ".join(text.split())
    if len(text) > _TLS_DETAIL_MAX:
        text = text[:_TLS_DETAIL_MAX] + "..."
    return f"TLS error (certificate/handshake failed): {text}"

# v2: bumped so every record cached under v1 (which includes the pre-F2
# windowless rows of v1.30.0) is invalidated wholesale on upgrade, rather
# than relying only on the per-record windows filter in load_quota_cache.
# load_quota_cache accepts ONLY this exact integer; any other value is
# treated as an empty cache.
QUOTA_CACHE_VERSION = 2
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
        if type_name == "reset_at":
            # reset_at is a direct ISO-8601 TIMESTAMP string, never a
            # number -- _dig() exists only to coerce numeric fields and
            # would wrongly discard a genuine timestamp (T038-independent-
            # review finding I1). Validate it parses as ISO-8601; never
            # guess at a malformed value.
            raw = _walk(body, sig.get("path") or [])
            if not isinstance(raw, str):
                continue
            try:
                datetime.fromisoformat(raw.replace("Z", "+00:00"))
            except ValueError:
                continue
            return raw
        if type_name == "reset_cadence":
            # A cadence LABEL ("daily", "monthly"), never a timestamp: walk
            # the raw value (it is a string, so _dig() would discard it) and
            # accept only a non-empty string other than a literal "null".
            # JSON null / absent / non-string all mean "no cadence reported".
            raw = _walk(body, sig.get("path") or [])
            if not isinstance(raw, str):
                continue
            label = raw.strip()
            if not label or label.lower() == "null":
                continue
            return label
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
    reset_cadence = _first_signal_value(signals, "reset_cadence", body)

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
    elif limit_total == 0:
        # A genuine zero-cap key has nothing left, by definition, whatever
        # amount_remaining happens to report -- avoid the ZeroDivisionError
        # a literal zero limit_total would otherwise cause (T038-independent-
        # review finding S2).
        percent_remaining = 0.0
    else:
        percent_remaining = 100 * amount_remaining / limit_total

    # Reset handling (rule 5). reset_at is ONLY ever a real ISO-8601
    # timestamp (computed from reset_in_seconds or read directly). A
    # cadence label ("daily", "monthly") proves the cap resets but says
    # nothing about WHEN, so it sets resets=True with reset_at=None and is
    # carried verbatim in reset_cadence -- a timestamp is never invented
    # from it (known-issues I2-residual-cadence).
    if reset_in_seconds is not None:
        reset_at = (
            datetime.now(timezone.utc) + timedelta(seconds=reset_in_seconds)
        ).isoformat()
        resets = True
    elif reset_at_direct is not None:
        reset_at = reset_at_direct
        resets = True
    elif reset_cadence is not None:
        reset_at = None
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
        "reset_cadence": reset_cadence,
    }


def resolve_account_blocked(provider_spec, body):
    """Resolve the OPTIONAL account_signals list on a provider's
    quota-endpoints.json entry into a single account_blocked boolean.
    No account_signals at all -> False (the documented default, never
    "unknown" -- contracts/quota-endpoint-spec-contract.md's
    account_blocked section)."""
    account_blocked = False
    for sig in (provider_spec.get("account_signals") or []):
        kind = (sig.get("type") or "").lower()
        if kind not in ("account_blocked", "account_blocked_negated"):
            continue
        flag = _dig_bool(body, sig.get("path") or [])
        if flag is None:
            continue
        account_blocked = flag if kind == "account_blocked" else (not flag)
        break
    return account_blocked


def probe_provider(provider_id, spec, api_key, timeout):
    """Live-probe one quota-endpoints.json provider entry. Returns a dict:
    {provider_id, windows: [...], account_blocked: bool,
     absence_reason: str|None, http_status: int|None}.

    TLS precondition: the HTTP call goes through this module's http_get_json
    (model_verify.http_get_json's semantics, TLS errors re-raised so their
    real text reaches absence_detail), whose ca_ssl_context() trusts ONLY the CA named by CMA_PROVIDER_CA_CERT
    when that variable is set. This function does NOT clear it. main()
    removes CMA_PROVIDER_CA_CERT from the environment before probing (the
    quota endpoints are public HTTPS hosts); an in-process caller that
    invokes probe_provider() directly must clear it the same way, or a
    host-wide value set for an unrelated self-signed endpoint makes every
    public-HTTPS probe fail verification."""
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

    try:
        status, body = http_get_json(url, headers, timeout)
    except (ssl.SSLError, URLError) as e:
        reason = e.reason if isinstance(e, URLError) else e
        if not isinstance(reason, ssl.SSLError):
            raise
        return {
            "provider_id": provider_id, "windows": [], "account_blocked": False,
            "absence_reason": "probe_failed",
            "absence_detail": _tls_failure_detail(e, url, api_key),
            "http_status": 0,
        }
    if status != 200 or not isinstance(body, dict):
        detail = f"HTTP {status}" if status else "connection failed or timed out"
        return {
            "provider_id": provider_id, "windows": [], "account_blocked": False,
            "absence_reason": "probe_failed", "absence_detail": detail,
            "http_status": status,
        }

    account_blocked = resolve_account_blocked(spec, body)

    windows = []
    for w in (spec.get("windows") or []):
        resolved = resolve_window(w, body)
        if resolved is not None:
            windows.append(resolved)

    if not windows:
        return {
            "provider_id": provider_id, "windows": [],
            "account_blocked": account_blocked,
            "absence_reason": "probe_failed",
            "absence_detail": "provider responded but no interpretable usage signals were found (possibly an uncapped/unlimited key, or an unexpected response shape)",
            "http_status": status,
        }

    return {
        "provider_id": provider_id, "windows": windows,
        "account_blocked": account_blocked, "absence_reason": None,
        "http_status": status,
    }


# --- Kimi native accounts: the /coding/v1/usages endpoint ---------------------
#
# A signed-in Kimi Code account's subscription windows are read from
# GET {base}/usages, whose `usages` object carries `limit_5h` and `limit_7d`,
# each with a numeric `used_ratio` and a string `reset_time`. (The parallel
# `usage` object and `limits` list carry string fields and are NOT read.)
#
# NO REFRESH FLOW, by design: the probe reads the CURRENT access token from
# the account's credentials file and makes exactly ONE GET. The access token
# expires routinely and the `kimi` CLI refreshes it; when it has lapsed the
# endpoint answers 401 and this reports auth_expired with an instruction to
# run `KIMI_CODE_HOME=<account dir> kimi login` -- a bare `kimi login` would
# sign in the DEFAULT ~/.kimi-code, not the probed account. It never reads refresh_token and never calls any token
# or OAuth endpoint. The token and the response body stay in-process: only
# the derived window numbers and reset timestamps leave this function.

KIMI_USAGE_BASE_URL_DEFAULT = "https://api.kimi.com/coding/v1"
# The detail is this constant text plus the probed account's directory --
# never anything from the credentials file or the response.
KIMI_AUTH_EXPIRED_TEMPLATE = "Kimi access token expired: run `KIMI_CODE_HOME={home} kimi login` to refresh"
KIMI_AUTH_EXPIRED_FALLBACK = ("Kimi access token expired: run `kimi login` with KIMI_CODE_HOME "
                              "set to this account's directory to refresh")
KIMI_NON_JSON_DETAIL = "Kimi usages endpoint returned non-JSON"
KIMI_RATIO_OMITTED_NOTE = "one Kimi usage window was out of range and omitted"
KIMI_INSECURE_URL_DETAIL = "Kimi usage endpoint must be https (loopback excepted)"
_KIMI_LOOPBACK_HOSTS = ("127.0.0.1", "::1", "localhost")
_KIMI_WINDOWS = (("limit_5h", "subscription_5h", "5h"), ("limit_7d", "subscription_7d", "7d"))
KIMI_RATIO_RANGE_DETAIL = "Kimi usage returned an out-of-range or non-finite used_ratio"
# used_ratio is a fraction in [0, 1.0]. Anything above 1.0 by more than float
# noise (_KIMI_RATIO_EPS) is not a reading of this window. It is REJECTED,
# never clamped: clamping 25 to 1 would fabricate a limit-exceeded window the
# provider never reported. ONLY a sub-epsilon overshoot is clamped to 1.0.
_KIMI_RATIO_MAX = 1.0
_KIMI_RATIO_EPS = 1e-12


def _kimi_ratio_out_of_range(ratio):
    """True when ratio is a real (non-bool) number that is non-finite or
    outside [0, _KIMI_RATIO_MAX + _KIMI_RATIO_EPS] -- a numeric value that
    must not render."""
    if isinstance(ratio, bool) or not isinstance(ratio, (int, float)):
        return False
    return (not math.isfinite(ratio) or ratio < 0
            or ratio > _KIMI_RATIO_MAX + _KIMI_RATIO_EPS)


def kimi_auth_expired_detail(login_home):
    """The auth_expired detail naming the account home to log in. An
    unusable path (empty, relative, control characters, backticks) falls back
    to a path-free instruction rather than rendering something misleading."""
    home = login_home if isinstance(login_home, str) else ""
    if (not home or not os.path.isabs(home) or "`" in home
            or any(ord(c) < 32 or ord(c) == 127 for c in home)):
        return KIMI_AUTH_EXPIRED_FALLBACK
    return KIMI_AUTH_EXPIRED_TEMPLATE.format(home=shlex.quote(home))


def _kimi_usage_url_allowed(url):
    """The bearer token may only travel over https, or plain http to a
    loopback host (local stubs). Anything else -- http to a remote host,
    another scheme, an unparseable URL -- is refused before any request."""
    try:
        parts = urlsplit(url)
        host = (parts.hostname or "").lower()
    except ValueError:
        return False
    scheme = (parts.scheme or "").lower()
    if scheme == "https":
        return bool(host)
    return scheme == "http" and host in _KIMI_LOOPBACK_HOSTS


def _kimi_access_token(account_dir):
    """The CURRENT access_token from the account's credentials file, or "".
    Prefers credentials/kimi-code.json, else the first *.json (sorted) that
    carries a non-empty access_token. refresh_token is never read."""
    cdir = os.path.join(account_dir, "credentials")
    try:
        names = sorted(n for n in os.listdir(cdir) if n.endswith(".json"))
    except OSError:
        return ""
    if "kimi-code.json" in names:
        names.remove("kimi-code.json")
        names.insert(0, "kimi-code.json")
    for name in names:
        try:
            with open(os.path.join(cdir, name)) as f:
                tok = json.load(f).get("access_token")
        except (OSError, ValueError, AttributeError):
            continue
        if isinstance(tok, str) and tok.strip():
            return tok.strip()
    return ""


def resolve_kimi_window(name, cadence, entry):
    """One Kimi `usages.limit_*` object -> a Usage Window dict in the same
    shape resolve_window() returns, or None when used_ratio is unusable.
    used_ratio is a fraction of the window's quota, so the window is
    expressed in percent: limit_total 100, percent_remaining
    100 - used_ratio*100."""
    if not isinstance(entry, dict):
        return None
    ratio = entry.get("used_ratio")
    if isinstance(ratio, bool) or not isinstance(ratio, (int, float)):
        return None
    if _kimi_ratio_out_of_range(ratio):
        return None
    if ratio > _KIMI_RATIO_MAX:
        # Only reachable for a sub-epsilon float overshoot (the guard above
        # rejected anything larger): clamp that noise, and nothing else.
        ratio = _KIMI_RATIO_MAX
    def _num(x):
        # Float noise (0.07*100 = 7.000000000000001) is rounded off, and a
        # whole value is emitted as an int so it renders as "75", not "75.0".
        x = round(float(x), 4)
        return int(x) if x.is_integer() else x
    used = _num(ratio * 100)
    remaining = _num(100 - ratio * 100)
    reset_at = None
    raw = entry.get("reset_time")
    if isinstance(raw, str) and raw.strip():
        try:
            datetime.fromisoformat(raw.strip().replace("Z", "+00:00"))
            reset_at = raw.strip()
        except ValueError:
            reset_at = None
    return {
        "window": name,
        "amount_used": used,
        "amount_remaining": remaining,
        "limit_total": 100,
        "unit": "percent",
        "percent_remaining": remaining,
        # A rolling 5h/7d window always resets; when reset_time is not a
        # parseable timestamp the cadence label (taken from the provider's
        # own key name) is carried instead of an invented timestamp.
        "resets": True,
        "reset_at": reset_at,
        "reset_cadence": None if reset_at else cadence,
    }


def probe_kimi_native(account_dir, timeout, base_url=None, login_home=None):
    """Probe one Kimi native account's usages endpoint. Returns
    {windows, account_blocked, absence_reason, absence_detail, http_status}.
    login_home is the account directory named in the auth_expired detail
    (defaults to account_dir)."""
    def _absent(reason, detail, status):
        return {"windows": [], "account_blocked": False, "absence_reason": reason,
                "absence_detail": detail, "http_status": status}

    base = (base_url or os.environ.get("CMA_KIMI_USAGE_BASE_URL") or KIMI_USAGE_BASE_URL_DEFAULT).rstrip("/")
    url = base + "/usages"
    if not _kimi_usage_url_allowed(url):
        return _absent("probe_failed", KIMI_INSECURE_URL_DETAIL, None)
    token = _kimi_access_token(account_dir)
    if not token:
        return _absent("probe_failed", "no Kimi access token found in the account's credentials", None)
    try:
        status, body = http_get_json(url, {"Authorization": f"Bearer {token}"}, timeout)
    except ValueError:
        # http_get_json parses the 2xx body with json.loads; an HTML gateway
        # page raises JSONDecodeError (a ValueError) here. Keep the cause.
        return _absent("probe_failed", KIMI_NON_JSON_DETAIL, None)
    except (ssl.SSLError, URLError) as e:
        reason = e.reason if isinstance(e, URLError) else e
        if not isinstance(reason, ssl.SSLError):
            raise
        return _absent("probe_failed", _tls_failure_detail(e, url, token), 0)
    if status == 401:
        return _absent("auth_expired",
                       kimi_auth_expired_detail(login_home if login_home else account_dir), 401)
    if status != 200 or not isinstance(body, dict):
        return _absent("probe_failed", f"HTTP {status}" if status else "connection failed or timed out", status)

    usages = body.get("usages")
    windows = []
    bad_ratio = False
    if isinstance(usages, dict):
        for key, name, cadence in _KIMI_WINDOWS:
            entry = usages.get(key)
            w = resolve_kimi_window(name, cadence, entry)
            if w is not None:
                windows.append(w)
            elif isinstance(entry, dict) and _kimi_ratio_out_of_range(entry.get("used_ratio")):
                bad_ratio = True
    if not windows and bad_ratio:
        return _absent("probe_failed", KIMI_RATIO_RANGE_DETAIL, status)
    if not windows:
        return _absent("probe_failed",
                       "Kimi usages endpoint responded but no interpretable usage windows were found", status)
    # A window rejected for range while another survived is not silent: the
    # row still renders the valid window and carries a note in absence_detail.
    return {"windows": windows, "account_blocked": False, "absence_reason": None,
            "absence_detail": KIMI_RATIO_OMITTED_NOTE if bad_ratio else None,
            "http_status": status}


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
    version = data.get("_cache_version") if isinstance(data, dict) else None
    # type() not isinstance(): a bool is an int subclass and True == 1, so
    # only an exact int equal to the current version is accepted.
    if type(version) is not int or version != QUOTA_CACHE_VERSION:
        return {"_cache_version": QUOTA_CACHE_VERSION, "providers": {}}
    ts = data.get("_cached_at")
    if not isinstance(ts, (int, float)) or time.time() - ts > QUOTA_CACHE_TTL_SECONDS:
        return {"_cache_version": QUOTA_CACHE_VERSION, "providers": {}}
    providers = data.get("providers")
    if not isinstance(providers, dict):
        providers = {}
    # Only a SUCCESSFUL probe is ever cache-worthy, and a successful probe
    # always carries at least one window (the windows-XOR-absence_reason
    # invariant). A record with no windows is either a pre-F2 empty row
    # cached under v1.30.0 (windows:[] with absence_reason:null) or some
    # other non-success; replaying it renders a blank row for up to the
    # full TTL (known-issues F2-stale-cache-replay). Drop it so the caller
    # re-probes live instead.
    data["providers"] = {
        pid: rec for pid, rec in providers.items()
        if isinstance(rec, dict) and isinstance(rec.get("windows"), list) and rec["windows"]
    }
    return data


def save_quota_cache(path, data):
    """Write the quota cache atomically: dump to a temp file in the SAME
    directory, fsync it, then os.replace() it over `path`. A concurrent
    reader therefore sees either the complete previous file or the complete
    new one, never a truncated one, and a write that dies mid-dump leaves
    the previous cache untouched (known-issues T17b-crossprocess-race).
    This does not serialize concurrent read-modify-write cycles: two
    writers that loaded the same snapshot still resolve last-writer-wins."""
    if not path:
        return
    data["_cache_version"] = QUOTA_CACHE_VERSION
    data["_cached_at"] = time.time()
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(
        prefix="." + os.path.basename(path) + ".", suffix=".tmp", dir=directory
    )
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, path)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def main(argv=None):
    # Quota probes target real public HTTPS quota endpoints -- none of
    # quota-endpoints.json's documented entries need a non-default CA.
    # CMA_PROVIDER_CA_CERT is set HOST-WIDE for an unrelated local
    # self-signed endpoint (HelixLLM) and must not leak into this
    # subprocess's TLS verification, or every public-HTTPS probe fails
    # (model_verify.ca_ssl_context() trusts ONLY the named CA when set,
    # by design, for its own original use case -- T038 review finding F1).
    os.environ.pop("CMA_PROVIDER_CA_CERT", None)
    ap = argparse.ArgumentParser(description="Probe one provider's quota/limits")
    ap.add_argument("--provider-id")
    ap.add_argument("--spec-file")
    ap.add_argument("--api-key-env", default="")
    ap.add_argument("--kimi-native-dir", default="",
                    help="probe a Kimi native account dir's usages endpoint instead of a provider")
    ap.add_argument("--kimi-login-home", default="",
                    help="account directory named in the auth_expired detail (KIMI_CODE_HOME=<dir> kimi login)")
    ap.add_argument("--timeout", type=float, default=3.0)
    args = ap.parse_args(argv)

    if args.kimi_native_dir:
        # Same hard-deadline guarantee as the provider path below: exactly
        # one JSON line, whichever of probe / deadline finishes first.
        deadline = args.timeout + 2.0
        k_lock = threading.Lock()
        k_emitted = []

        def _k_emit(payload):
            with k_lock:
                if k_emitted:
                    return False
                k_emitted.append(True)
                print(json.dumps(payload), flush=True)
                return True

        def _k_deadline():
            if _k_emit({"windows": [], "account_blocked": False,
                        "absence_reason": "probe_failed",
                        "absence_detail": f"probe exceeded its hard deadline of {deadline:g}s",
                        "http_status": None}):
                os._exit(0)

        k_timer = threading.Timer(deadline, _k_deadline)
        k_timer.daemon = True
        k_timer.start()
        try:
            k_result = probe_kimi_native(args.kimi_native_dir, args.timeout,
                                         login_home=args.kimi_login_home or None)
        finally:
            k_timer.cancel()
        _k_emit(k_result)
        return 0

    if not args.provider_id or not args.spec_file:
        ap.error("--provider-id and --spec-file are required unless --kimi-native-dir is given")

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
    # Hard deadline (I3-residual-no-coreutils). claude-providers.sh wraps
    # this script in coreutils `timeout` when present, but falls back to a
    # bare python3 run when it is absent -- and --timeout only bounds each
    # socket operation, not the whole probe (DNS + connect + slow read can
    # sum past it). A daemon threading.Timer is the portable bound: no
    # SIGALRM, no main-thread restriction, stdlib only. If it fires first it
    # emits probe_provider's own probe_failed shape and os._exit()s; the
    # lock guarantees exactly ONE JSON line whichever side finishes first.
    # The +2.0s margin keeps it behind `timeout`'s own +1s kill when that
    # binary exists, so the coreutils path is unchanged.
    deadline = args.timeout + 2.0
    emit_lock = threading.Lock()
    emitted = []

    def _emit_once(payload):
        with emit_lock:
            if emitted:
                return False
            emitted.append(True)
            print(json.dumps(payload), flush=True)
            return True

    def _hard_deadline_fired():
        if _emit_once({
            "provider_id": args.provider_id, "windows": [], "account_blocked": False,
            "absence_reason": "probe_failed",
            "absence_detail": f"probe exceeded its hard deadline of {deadline:g}s",
            "http_status": None,
        }):
            os._exit(0)

    watchdog = threading.Timer(deadline, _hard_deadline_fired)
    watchdog.daemon = True
    watchdog.start()
    try:
        result = probe_provider(args.provider_id, spec, api_key, args.timeout)
    finally:
        watchdog.cancel()
    _emit_once(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
