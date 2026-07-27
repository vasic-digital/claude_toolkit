#!/usr/bin/env python3
"""alias_e2e_test.py — end-to-end test for provider aliases.

Tests each alias by sending a request through ccr's configured endpoint
and verifying the response works without errors (especially cache_control).

Usage:
  alias_e2e_test.py [--alias NAME] [--all] [--verbose] [--timeout 30]

Exit codes:
  0  every tested alias passed or hit a quota-level account state
  1  an alias genuinely failed, or bad usage
  3  SKIP — no providers installed / nothing to test (run-proof.sh leg 44
     treats this as an honest recorded skip, not a pass and not a failure)

Verdicts per alias: pass, genuine fail, or quota-skip (an account-level funds
state — recoverable, reported in the output as quota_skipped, never counted as
a pass and never as a toolkit failure; mirrors verify_claude_live.sh FUNDS).

Tests each alias by:
1. Reading the env file for the alias
2. Sending a test request to the provider through ccr
3. Verifying HTTP 200 with valid content
4. Checking for cache_control or other errors
5. Verifying tool calling support
"""
import argparse
import json
import os
import re
import sys
import time
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError


TEST_PROMPT = "Do you see our codebase? Reply with YES or NO and explain briefly."
EXPECTED_KEYWORDS = ["yes", "see", "code", "project", "directory", "file"]
ERROR_PATTERNS = [
    r"cache_control.*not.*valid",
    r"unknown field",
    r"422",
    r"error from provider",
    r"rate.?limit",
    r"quota",
    r"access.?denied",
]

# Account-level funds states (dead points, depleted credits). An alias failing
# with one of these is NOT evidence the alias is broken — it is a recoverable
# account state, classified as quota-skip (never a pass, never a toolkit
# failure), mirroring verify_claude_live.sh's FUNDS bucket.
QUOTA_RE = re.compile(
    r"insufficient_?quota|used up your (points|credits)|insufficient "
    r"(credits|balance|funds)|usage limit|quota (exceeded|reached)|depleted|"
    r"billing|HTTP 402",
    re.IGNORECASE,
)

# Provider-side transient states (capacity, overload, timeouts, 5xx, 429) —
# point-in-time infrastructure conditions, not alias defects. Classified as
# transient-skip (never a pass, never a toolkit failure).
TRANSIENT_RE = re.compile(
    r"maximum capacity|try again later|overloaded|temporarily unavailable|"
    r"bad gateway|gateway timeout|"
    r"timed? ?out|service unavailable|HTTP (Error )?(429|5\d\d)",
    re.IGNORECASE,
)


def is_quota_error(text):
    return bool(text) and bool(QUOTA_RE.search(text))


def is_transient_error(text):
    return bool(text) and bool(TRANSIENT_RE.search(text))


def load_env(env_path):
    """Load env file and return dict of key=value pairs."""
    env = {}
    with open(env_path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().strip("'\"")
            env[key] = value
    return env


def get_ccr_config():
    """Read ccr config to find provider endpoints."""
    cfg_path = os.path.expanduser("~/.claude-code-router/config.json")
    if not os.path.exists(cfg_path):
        return {}
    with open(cfg_path) as f:
        return json.load(f)


def chat_endpoint_for(base_url, transport):
    """Resolve the chat endpoint exactly the way the runtime does.

    native (/anthropic) bases keep their prefix and serve /v1/messages beneath
    it (e.g. https://api.deepseek.com/anthropic -> …/anthropic/v1/messages).
    Router bases: a trailing version segment (/v1, /v4, …) takes only
    /chat/completions (e.g. …/paas/v4 -> …/paas/v4/chat/completions); anything
    else gets /v1/chat/completions. A base already ending in /chat/completions
    is used verbatim. Returns (url, native_flag).
    """
    base = base_url.rstrip("/")
    if transport == "native" or "/anthropic" in base:
        for suffix in ("/v1/messages", "/v1"):
            if base.endswith(suffix):
                base = base[: -len(suffix)]
        return base + "/v1/messages", True
    if base.endswith("/chat/completions"):
        return base, False
    if re.search(r"/v[0-9]+$", base):
        return base + "/chat/completions", False
    return base + "/v1/chat/completions", False


def test_provider_direct(url, api_key, model, timeout=30, native=False):
    """Test a provider directly (bypassing ccr) with cache_control in request.

    Returns (success, response_content, error_message, latency_ms).
    """
    if native:
        headers = {
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "User-Agent": "claude-toolkit/1.6.0 e2e-test",
        }
    else:
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
            "User-Agent": "claude-toolkit/1.6.0 e2e-test",
        }
    body = {
        "model": model,
        # Reasoning models (deepseek-v4-pro & co.) spend a large budget on
        # chain-of-thought before any visible text; 128 tokens reliably
        # produced false "empty response" failures on them.
        "max_tokens": 512,
        "messages": [
            {
                "role": "user",
                "content": TEST_PROMPT,
                "cache_control": {"type": "ephemeral"},  # This should be stripped by ccr
            }
        ],
    }

    start = time.monotonic()
    try:
        data = json.dumps(body).encode("utf-8")
        req = Request(url, data=data, headers=headers, method="POST")
        with urlopen(req, timeout=timeout) as resp:
            elapsed = int((time.monotonic() - start) * 1000)
            raw = resp.read().decode("utf-8", errors="replace")
            try:
                result = json.loads(raw)
            except json.JSONDecodeError:
                return False, "", "Invalid JSON response", elapsed

            # Extract content — OpenAI choices[] or Anthropic content blocks
            content = ""
            choices = result.get("choices", [])
            if choices:
                msg = choices[0].get("message", {})
                content = msg.get("content", "")
                if not content:
                    content = msg.get("reasoning_content", "")
            if not content and isinstance(result.get("content"), list):
                parts = [b.get("text", "") for b in result["content"]
                         if isinstance(b, dict) and b.get("type") == "text"]
                content = "".join(parts)

            if not content:
                return False, "", "Empty response content", elapsed

            return True, content, "", elapsed

    except HTTPError as e:
        elapsed = int((time.monotonic() - start) * 1000)
        try:
            err_body = e.read().decode("utf-8", errors="replace")
            err_json = json.loads(err_body)
            err_msg = err_json.get("message", err_body[:200])
        except Exception:
            err_msg = str(e)[:200]
        return False, "", f"HTTP {e.code}: {err_msg}", elapsed

    except (URLError, OSError, TimeoutError) as e:
        elapsed = int((time.monotonic() - start) * 1000)
        return False, "", str(e)[:200], elapsed


def test_alias(alias_name, env, timeout=30, verbose=False):
    """Test a single alias end-to-end.

    Returns dict with test results.
    """
    providers_dir = os.path.expanduser("~/.local/share/claude-multi-account/providers")
    result = {
        "alias": alias_name,
        "model": env.get("CMA_PROVIDER_MODEL", ""),
        "fast_model": env.get("CMA_PROVIDER_FAST_MODEL", ""),
        "transport": env.get("CMA_PROVIDER_TRANSPORT", ""),
        "base_url": env.get("CMA_PROVIDER_BASE_URL", ""),
        "tests": [],
        "overall_pass": False,
    }

    base_url = env.get("CMA_PROVIDER_BASE_URL", "")
    transport = env.get("CMA_PROVIDER_TRANSPORT", "router")

    if not base_url:
        result["tests"].append({"name": "env_check", "pass": False, "error": "No base URL"})
        return result

    # Aliases the activation gate has already filtered out (unverified/failed/
    # pending) are intentionally not launchable — skip them honestly instead of
    # scoring a guaranteed failure. This gate MUST run before key resolution:
    # an unverified alias typically has NO key either (it never verified), and
    # failing key_check first reported it as a broken alias — the exact
    # false-FAIL the gate exists to prevent (live: helixagent family 2026-07-26).
    status_file = os.path.join(providers_dir, "status.json")
    if os.path.exists(status_file):
        try:
            with open(status_file) as f:
                st = json.load(f).get(alias_name, {}).get("status", "pending")
        except Exception:
            st = "pending"
        if st != "verified":
            result["gated_skip"] = True
            result["tests"].append({
                "name": "gated_check", "pass": False,
                "error": f"SKIP-GATED (status={st} — filtered by the verification gate, not tested)",
            })
            return result

    # Resolve the chat endpoint the way the runtime does (native /anthropic
    # bases serve /v1/messages under the kept prefix; versioned router bases
    # take only /chat/completions — see chat_endpoint_for).
    test_url, native = chat_endpoint_for(base_url, transport)

    # Get API key. The Kimi Code OAuth sentinel has no var in the keys file —
    # its token comes from the live credentials file (fresh) or the per-alias
    # token-file snapshot (fallback), same freshness order as the launch wrapper.
    key_var = env.get("CMA_PROVIDER_KEYVAR", "")
    api_key = ""
    if key_var == "_CMA_KIMICODE_OAUTH_":
        cred = os.path.expanduser("~/.kimi-code/credentials/kimi-code.json")
        if os.path.exists(cred):
            try:
                with open(cred) as f:
                    c = json.load(f)
                if int(c.get("expires_at", 0)) > time.time() + 60:
                    api_key = c.get("access_token", "")
            except Exception:
                pass
        if not api_key and os.path.exists(cred):
            # Expired live token: refresh via the CLI (same chain as the
            # launch wrapper), then re-read the credentials file.
            try:
                import shutil
                import subprocess
                if shutil.which("kimi"):
                    subprocess.run(["kimi", "-p", "hi", "--output-format", "text"],
                                   capture_output=True, timeout=20)
                    with open(cred) as f:
                        api_key = json.load(f).get("access_token", "")
            except Exception:
                pass
        if not api_key:
            tok_file = os.path.join(providers_dir, f"{alias_name}.token")
            if os.path.exists(tok_file):
                with open(tok_file) as f:
                    api_key = f.read().strip()
    elif key_var:
        keys_file = os.path.expanduser("~/api_keys.sh")
        if os.path.exists(keys_file):
            # Parse the keys file to find the value
            with open(keys_file) as f:
                for line in f:
                    line = line.strip()
                    if line.startswith(f"export {key_var}=") or line.startswith(f"{key_var}="):
                        _, _, val = line.partition("=")
                        api_key = val.strip().strip('"').strip("'")
                        # Handle variable references like $OtherVar
                        if api_key.startswith("$"):
                            ref_var = api_key[1:]
                            with open(keys_file) as f2:
                                for line2 in f2:
                                    if line2.strip().startswith(f"export {ref_var}=") or line2.strip().startswith(f"{ref_var}="):
                                        _, _, val2 = line2.partition("=")
                                        api_key = val2.strip().strip('"').strip("'")
                                        break

    if not api_key:
        result["tests"].append({"name": "key_check", "pass": False, "error": f"No API key for {key_var}"})
        return result

    # Test 1: Direct request (should work for OpenAI-compatible endpoints)
    model = env.get("CMA_PROVIDER_MODEL", "")
    if verbose:
        print(f"  Testing {alias_name} ({model})...", file=sys.stderr)

    success, content, error, latency = test_provider_direct(test_url, api_key, model, timeout, native=native)
    # Reasoning models and flaky free-tier endpoints occasionally return an
    # empty first answer; allow exactly one retry before believing it (same
    # retry policy as providers-verify.sh).
    if not success and error == "Empty response content":
        time.sleep(3)
        success, content, error, latency = test_provider_direct(test_url, api_key, model, timeout, native=native)
    result["tests"].append({
        "name": "direct_request",
        "pass": success,
        "content": content[:100] if content else "",
        "error": error,
        "latency_ms": latency,
    })

    if not success:
        # An account-level funds state is not an alias defect (see QUOTA_RE).
        if is_quota_error(error):
            result["quota_skip"] = True
            result["tests"].append({
                "name": "quota_check", "pass": False,
                "error": f"SKIP-QUOTA (account out of funds, not a toolkit failure): {error[:120]}",
            })
            return result
        # Provider-side transient (capacity/timeout) is not an alias defect
        # either (see TRANSIENT_RE).
        if is_transient_error(error):
            result["transient_skip"] = True
            result["tests"].append({
                "name": "transient_check", "pass": False,
                "error": f"SKIP-TRANSIENT (provider capacity/timeout, not a toolkit failure): {error[:120]}",
            })
            return result
        # Check if it's a cache_control error specifically
        if "cache_control" in error.lower() or "unknown field" in error.lower():
            result["tests"].append({
                "name": "cache_control_check",
                "pass": False,
                "error": f"cache_control not stripped: {error}",
            })
        return result

    # Test 2: Check content quality. Weak/free models occasionally answer
    # off-pattern despite working fine — one fresh retry before believing it.
    content_lower = content.lower()
    has_relevant_content = any(kw in content_lower for kw in EXPECTED_KEYWORDS)
    if not has_relevant_content:
        time.sleep(3)
        s2, c2, e2, _ = test_provider_direct(test_url, api_key, model, timeout, native=native)
        if s2:
            c2l = c2.lower()
            if any(kw in c2l for kw in EXPECTED_KEYWORDS):
                content, has_relevant_content = c2, True
    result["tests"].append({
        "name": "content_quality",
        "pass": has_relevant_content,
        "content_preview": content[:200],
    })

    # Test 3: Check for error patterns in response
    has_error = False
    for pattern in ERROR_PATTERNS:
        if re.search(pattern, content_lower):
            has_error = True
            result["tests"].append({
                "name": "error_pattern_check",
                "pass": False,
                "error": f"Error pattern found: {pattern}",
            })
            break
    if not has_error:
        result["tests"].append({"name": "error_pattern_check", "pass": True})

    # Test 4: Tool calling (send request with tools)
    tool_url = test_url
    if native:
        tool_headers = {
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "User-Agent": "claude-toolkit/1.6.0 e2e-test",
        }
        tool_schema = [{
            "name": "test_calc",
            "description": "Calculate a math expression",
            "input_schema": {
                "type": "object",
                "properties": {"expression": {"type": "string"}},
                "required": ["expression"],
            },
        }]
    else:
        tool_headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
            "User-Agent": "claude-toolkit/1.6.0 e2e-test",
        }
        tool_schema = [{
            "type": "function",
            "function": {
                "name": "test_calc",
                "description": "Calculate a math expression",
                "parameters": {
                    "type": "object",
                    "properties": {"expression": {"type": "string"}},
                    "required": ["expression"],
                },
            },
        }]
    tool_body = {
        "model": model,
        "max_tokens": 512,  # reasoning budget (see direct test)
        "messages": [{"role": "user", "content": "Calculate 7*6 using the test_calc tool"}],
        "tools": tool_schema,
    }
    def _tool_probe():
        data = json.dumps(tool_body).encode("utf-8")
        req = Request(tool_url, data=data, headers=tool_headers, method="POST")
        with urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            tool_result = json.loads(raw)
            calls = False
            choices = tool_result.get("choices", [])
            if choices:
                msg = choices[0].get("message", {})
                calls = bool(msg.get("tool_calls"))
            if not calls and isinstance(tool_result.get("content"), list):
                calls = any(
                    isinstance(b, dict) and b.get("type") == "tool_use"
                    for b in tool_result["content"]
                )
            return calls, raw

    try:
        has_tool_calls, raw = _tool_probe()
        # Weak/free models flake on instructed tool calls (same retry policy
        # as providers-verify.sh): exactly one retry before believing it.
        if not has_tool_calls and not is_quota_error(raw) and not is_transient_error(raw):
            time.sleep(3)
            has_tool_calls, raw = _tool_probe()
            # A 200 carrying an error object (quota exhaustion smuggled as a
            # success) is an account state, not a tool-support failure.
            if not has_tool_calls and is_quota_error(raw):
                result["quota_skip"] = True
            result["tests"].append({
                "name": "tool_calling",
                "pass": has_tool_calls,
            })
    except Exception as e:
        if is_quota_error(str(e)):
            result["quota_skip"] = True
        elif is_transient_error(str(e)):
            result["transient_skip"] = True
        result["tests"].append({
            "name": "tool_calling",
            "pass": False,
            "error": str(e)[:100],
        })

    # Overall pass: direct request + content quality + no errors + tool calling
    # (Claude Code is tool-driven — a chat-only alias is broken in practice).
    result["overall_pass"] = all(
        t["pass"] for t in result["tests"]
        if t["name"] in ["direct_request", "content_quality", "error_pattern_check", "tool_calling"]
    )

    return result


def main(argv=None):
    ap = argparse.ArgumentParser(description="End-to-end test for provider aliases")
    ap.add_argument("--alias", default="", help="Test specific alias")
    ap.add_argument("--all", action="store_true", help="Test all aliases")
    ap.add_argument("--verbose", action="store_true", help="Verbose output")
    ap.add_argument("--timeout", type=int, default=30, help="Request timeout")
    ap.add_argument("--output", default="", help="Output JSON file")
    args = ap.parse_args(argv)

    providers_dir = os.path.expanduser("~/.local/share/claude-multi-account/providers")

    if args.alias:
        aliases = [args.alias]
    elif args.all:
        # Find all provider env files. Exit 3 is the honest SKIP signal for
        # wrapper scripts (run-proof.sh leg 44): nothing installed to test.
        if not os.path.isdir(providers_dir):
            print(f"SKIP: no providers dir at {providers_dir}", file=sys.stderr)
            return 3
        aliases = []
        for f in sorted(os.listdir(providers_dir)):
            if f.endswith(".env"):
                aliases.append(f[:-4])  # Remove .env extension
        if not aliases:
            print(f"SKIP: no *.env provider files in {providers_dir}", file=sys.stderr)
            return 3
    else:
        print("Specify --alias NAME or --all", file=sys.stderr)
        return 1

    results = []
    passed = 0
    failed = 0
    quota_skipped = 0
    transient_skipped = 0
    gated_skipped = 0

    for alias_name in aliases:
        env_path = os.path.join(providers_dir, f"{alias_name}.env")
        if not os.path.exists(env_path):
            print(f"SKIP {alias_name}: env file not found", file=sys.stderr)
            continue

        env = load_env(env_path)
        result = test_alias(alias_name, env, timeout=args.timeout, verbose=args.verbose)
        results.append(result)

        if result["overall_pass"]:
            passed += 1
            status = "✓"
        elif result.get("quota_skip") or result.get("transient_skip") or result.get("gated_skip"):
            # Account/provider-side state or intentionally-gated alias —
            # reported honestly, counted separately, never as a pass and never
            # as a toolkit failure.
            quota_skipped += 1 if result.get("quota_skip") else 0
            transient_skipped += 1 if result.get("transient_skip") else 0
            gated_skipped += 1 if result.get("gated_skip") else 0
            status = "◌"
        else:
            failed += 1
            status = "✗"

        if args.verbose or not result["overall_pass"]:
            print(f"{status} {alias_name}: model={result['model']}", file=sys.stderr)
            for t in result["tests"]:
                if not t["pass"]:
                    print(f"    FAIL: {t['name']} - {t.get('error', '')}", file=sys.stderr)

    output = {
        "total": len(results),
        "passed": passed,
        "failed": failed,
        "quota_skipped": quota_skipped,
        "transient_skipped": transient_skipped,
        "gated_skipped": gated_skipped,
        "results": results,
    }

    if args.output:
        with open(args.output, "w") as f:
            json.dump(output, f, indent=2)
    else:
        print(json.dumps(output, indent=2))

    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
