#!/usr/bin/env python3
"""claude_usage_report.py — turn real `ccusage claude daily/session --json`
output into the groupings claude-usage.sh's `report` subcommand presents
(day, model, session, project, provider-family, or all of them combined).

This is a pure, offline formatter. It never shells out, never fetches
anything, and never guesses at data it was not given — every number in its
output traces back to a field ccusage emitted for this host's REAL
~/.claude-shared/projects data (confirmed live: see claude-usage.sh's own
doc comment and the task that produced it).

WHY THIS EXISTS, AND WHY IT IS HONEST ABOUT WHAT IT CANNOT KNOW
-----------------------------------------------------------------
Every Claude Code account dir AND every provider-alias config dir on this
host symlinks `projects/` to the exact same `$SHARED_DIR/projects` (verified
directly with `readlink -f` against this host's real `~/.claude-claude5`,
`~/.claude-prov-chutes`, etc. — see claude-usage.sh's header). Nothing in the
stored JSONL transcripts (cwd, sessionId, timestamp, message.model,
message.usage.*) records which CLAUDE_CONFIG_DIR produced a given message.
So:
  - day / model / session / project groupings are REAL — ccusage computes
    them directly from the merged transcripts, with no inference by us.
  - "provider" is NOT a transcript field. We derive a best-effort guess by
    cross-referencing each model id against this toolkit's OWN provider
    catalog (scripts/providers/status.json, written by claude-providers.sh)
    for a model string that some currently-configured provider alias was
    last verified/probed against. This mapping is DELIBERATELY reported as
    "candidate alias(es)", not "alias": the same catalog model id can be
    served by more than one configured alias (e.g. nvidia/nvidia2/nvidia3,
    openrouter/openrouter2/openrouter3), and when that happens every
    candidate is listed — never silently narrowed to one. A model with no
    match in status.json is reported as "unmapped", never silently dropped
    or silently assigned to the nearest provider.
  - Every model name matching `^claude-` with no `/` in it (Anthropic's own
    internal ids, e.g. "claude-opus-5-5") is native-Claude-account traffic.
    All native `claude1..N` accounts share the exact same generic model
    field, so they are POOLED into one explicitly-labeled bucket and are
    NEVER reported as if attributable to one subscription.

Usage:
  claude_usage_report.py --daily FILE --session FILE --status FILE \
      --since YYYY-MM-DD --until YYYY-MM-DD --group-by all --format md

--daily/--session are the raw JSON ccusage printed for
  `ccusage claude daily --json --breakdown ...` /
  `ccusage claude session --json --breakdown ...`.
--status is scripts/providers/status.json's path (optional — provider-family
  grouping degrades to "no provider catalog available" if missing/unreadable,
  it never errors the whole report).
"""
import argparse
import json
import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load_json(path):
    if not path:
        return None
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def _import_providers_resolve():
    """Reuse this repo's OWN normalize_model_key/vendor_of rather than
    re-implementing model-id folding with different (and silently
    divergent) rules. providers_resolve.py is pure/offline at import time
    (its network/catalog logic lives behind `if __name__ == "__main__"`),
    so importing it here has no side effects. Returns (None, None) if the
    module cannot be imported, so provider-family grouping degrades to
    exact-match-only rather than crashing the whole report.
    """
    scripts_dir = os.path.join(REPO_ROOT, "scripts")
    if scripts_dir not in sys.path:
        sys.path.insert(0, scripts_dir)
    try:
        import providers_resolve as pr  # noqa: PLC0415 (intentional lazy/optional import)
        return pr.normalize_model_key, pr.vendor_of
    except Exception:
        return None, None


NORMALIZE_MODEL_KEY, VENDOR_OF = _import_providers_resolve()

NATIVE_LABEL = (
    "native Claude accounts (pooled — claude1..N share one generic model "
    "field; NOT separable by subscription)"
)
UNMAPPED_LABEL = "unmapped (no configured provider alias recorded this exact/normalized model id)"


def _is_native_claude_model(model_name):
    m = (model_name or "").strip()
    return bool(m) and "/" not in m and m.lower().startswith("claude-")


def build_provider_index(status):
    """{exact_model_string: [(alias_id, status), ...]} and
    {normalized_key: [(alias_id, status, model_string), ...]} across every
    alias status.json currently knows about (verified AND non-verified —
    non-verified aliases are shown too, clearly tagged, since the usage data
    may predate their current status and the model string is still real
    evidence of what that alias was pointed at)."""
    exact = {}
    normalized = {}
    if not isinstance(status, dict):
        return exact, normalized
    for alias_id, rec in status.items():
        if not isinstance(rec, dict):
            continue
        model = rec.get("model")
        st = rec.get("status", "unknown")
        if not model:
            continue
        exact.setdefault(model, []).append((alias_id, st))
        if NORMALIZE_MODEL_KEY:
            key = NORMALIZE_MODEL_KEY(model)
            if key:
                normalized.setdefault(key, []).append((alias_id, st, model))
    return exact, normalized


def resolve_provider_candidates(model_name, exact_index, normalized_index):
    """Return (bucket_label, match_kind, candidates) for one usage model id.

    candidates is a list of {"alias": id, "status": status} dicts — never a
    single winner picked out of a many-to-one match.
    """
    if _is_native_claude_model(model_name):
        return NATIVE_LABEL, "native", []

    hits = exact_index.get(model_name)
    if hits:
        cands = sorted({(a, s) for a, s in hits})
        return _format_bucket(model_name, cands, "exact"), "exact", [
            {"alias": a, "status": s} for a, s in cands
        ]

    if NORMALIZE_MODEL_KEY:
        key = NORMALIZE_MODEL_KEY(model_name)
        hits = normalized_index.get(key)
        if hits:
            # vendor compatibility: only count a candidate whose own vendor
            # agrees with the usage model's vendor, or either side is
            # vendor-unstated (mirrors providers_resolve.py's corroboration
            # gate — an unrelated same-named model on a different vendor
            # must never be reported as a candidate alias).
            want_vendor = VENDOR_OF(model_name) if VENDOR_OF else ""
            cands = sorted(
                {
                    (a, s)
                    for a, s, m in hits
                    if not want_vendor
                    or not VENDOR_OF(m)
                    or VENDOR_OF(m) == want_vendor
                }
            )
            if cands:
                return (
                    _format_bucket(model_name, cands, "normalized (fuzzy — vendor-prefix/case/:free folded)"),
                    "normalized",
                    [{"alias": a, "status": s} for a, s in cands],
                )

    return UNMAPPED_LABEL, "unmapped", []


def _format_bucket(model_name, cands, kind):
    names = ", ".join(f"{a} ({s})" for a, s in cands)
    if len(cands) == 1:
        return f"candidate alias: {names} [{kind} match on '{model_name}']"
    return f"AMBIGUOUS — {len(cands)} candidate aliases currently share this model id: {names} [{kind} match on '{model_name}']"


def aggregate_models(daily_rows, exact_index, normalized_index):
    """Collapse every day's modelBreakdowns into one row per model across
    the whole requested range, each carrying its best-effort provider
    candidates."""
    agg = {}
    for day in daily_rows or []:
        for mb in day.get("modelBreakdowns") or []:
            name = mb.get("modelName") or "(unknown)"
            row = agg.setdefault(
                name,
                {
                    "modelName": name,
                    "inputTokens": 0,
                    "outputTokens": 0,
                    "cacheCreationTokens": 0,
                    "cacheReadTokens": 0,
                    "cost": 0.0,
                },
            )
            row["inputTokens"] += mb.get("inputTokens") or 0
            row["outputTokens"] += mb.get("outputTokens") or 0
            row["cacheCreationTokens"] += mb.get("cacheCreationTokens") or 0
            row["cacheReadTokens"] += mb.get("cacheReadTokens") or 0
            row["cost"] += mb.get("cost") or 0.0
    rows = []
    for name, row in agg.items():
        row["totalTokens"] = (
            row["inputTokens"]
            + row["outputTokens"]
            + row["cacheCreationTokens"]
            + row["cacheReadTokens"]
        )
        bucket, kind, cands = resolve_provider_candidates(name, exact_index, normalized_index)
        row["providerBucket"] = bucket
        row["providerMatchKind"] = kind
        row["providerCandidates"] = cands
        rows.append(row)
    rows.sort(key=lambda r: r["cost"], reverse=True)
    return rows


def aggregate_providers(model_rows):
    """Re-key the per-model rows by their resolved provider bucket, so the
    'provider' grouping shows totals per bucket (native pool / a single
    unambiguous alias / an ambiguous multi-alias group / unmapped) instead
    of per model id."""
    agg = {}
    for row in model_rows:
        bucket = row["providerBucket"]
        out = agg.setdefault(
            bucket,
            {
                "providerBucket": bucket,
                "providerMatchKind": row["providerMatchKind"],
                "providerCandidates": row["providerCandidates"],
                "models": [],
                "inputTokens": 0,
                "outputTokens": 0,
                "cacheCreationTokens": 0,
                "cacheReadTokens": 0,
                "totalTokens": 0,
                "cost": 0.0,
            },
        )
        out["models"].append(row["modelName"])
        for k in ("inputTokens", "outputTokens", "cacheCreationTokens", "cacheReadTokens", "totalTokens"):
            out[k] += row[k]
        out["cost"] += row["cost"]
    rows = list(agg.values())
    rows.sort(key=lambda r: r["cost"], reverse=True)
    return rows


def aggregate_projects(session_rows):
    agg = {}
    for s in session_rows or []:
        proj = s.get("projectPath") or "(unknown project path)"
        row = agg.setdefault(
            proj,
            {
                "projectPath": proj,
                "sessionCount": 0,
                "inputTokens": 0,
                "outputTokens": 0,
                "cacheCreationTokens": 0,
                "cacheReadTokens": 0,
                "totalTokens": 0,
                "cost": 0.0,
            },
        )
        row["sessionCount"] += 1
        for k in ("inputTokens", "outputTokens", "cacheCreationTokens", "cacheReadTokens"):
            row[k] += s.get(k) or 0
        row["totalTokens"] += s.get("totalTokens") or 0
        row["cost"] += s.get("totalCost") or 0.0
    rows = list(agg.values())
    rows.sort(key=lambda r: r["cost"], reverse=True)
    return rows


def money(v):
    return f"${v:,.2f}"


def num(v):
    return f"{v:,}"


def build_report(daily, session, status, since, until, group_by):
    daily_rows = (daily or {}).get("daily") or []
    daily_totals = (daily or {}).get("totals") or {}
    session_rows = (session or {}).get("sessions") or []

    exact_index, normalized_index = build_provider_index(status)
    model_rows = aggregate_models(daily_rows, exact_index, normalized_index)
    provider_rows = aggregate_providers(model_rows)
    project_rows = aggregate_projects(session_rows)

    report = {
        "meta": {
            "since": since,
            "until": until,
            "generatedBy": "ccusage (real `ccusage claude daily/session --json`)",
            "providerCatalogLoaded": status is not None,
            "honestLabeling": (
                "day/model/session/project groupings are real ccusage output. "
                "'provider' is a best-effort cross-reference against this "
                "toolkit's scripts/providers/status.json — see providerBucket/"
                "providerMatchKind/providerCandidates on each row. A model "
                "matched by more than one currently-configured alias is "
                "reported as AMBIGUOUS with every candidate listed, never "
                "narrowed to one. Native claude1..N accounts cannot be told "
                "apart at all and are pooled under one explicit label."
            ),
        },
        "totals": daily_totals,
    }

    want = set(["day", "model", "session", "project", "provider"]) if group_by == "all" else {group_by}

    if "day" in want:
        report["day"] = daily_rows
    if "model" in want:
        report["model"] = model_rows
    if "session" in want:
        report["session"] = session_rows
    if "project" in want:
        report["project"] = project_rows
    if "provider" in want:
        report["provider"] = provider_rows

    return report


# ---------------------------------------------------------------------------
# Renderers
# ---------------------------------------------------------------------------

def render_json(report):
    return json.dumps(report, indent=2, sort_keys=False)


def render_csv(report):
    """CSV covers the 'day' grouping only (the nice-to-have format; day is
    the one grouping every --group-by selection can unambiguously flatten to
    one row per key with a fixed column set)."""
    lines = ["date,inputTokens,outputTokens,cacheCreationTokens,cacheReadTokens,totalTokens,totalCost"]
    for d in report.get("day") or []:
        lines.append(
            ",".join(
                str(x)
                for x in (
                    d.get("date", ""),
                    d.get("inputTokens", 0),
                    d.get("outputTokens", 0),
                    d.get("cacheCreationTokens", 0),
                    d.get("cacheReadTokens", 0),
                    d.get("totalTokens", 0),
                    f"{d.get('totalCost', 0.0):.4f}",
                )
            )
        )
    if "day" not in report:
        lines.append("# NOTE: --group-by excluded 'day'; CSV always renders the day table when present.")
    return "\n".join(lines)


def _md_table(headers, rows):
    out = ["| " + " | ".join(headers) + " |", "| " + " | ".join(["---"] * len(headers)) + " |"]
    for r in rows:
        out.append("| " + " | ".join(str(c) for c in r) + " |")
    return "\n".join(out)


def render_md(report):
    meta = report["meta"]
    totals = report.get("totals") or {}
    out = []
    out.append(f"# Claude usage report — {meta['since']} .. {meta['until']}")
    out.append("")
    out.append(f"_Source: {meta['generatedBy']}_")
    out.append("")
    out.append("> " + meta["honestLabeling"])
    out.append("")
    out.append("## Totals")
    out.append("")
    out.append(
        _md_table(
            ["inputTokens", "outputTokens", "cacheCreationTokens", "cacheReadTokens", "totalTokens", "totalCost"],
            [
                [
                    num(totals.get("inputTokens", 0)),
                    num(totals.get("outputTokens", 0)),
                    num(totals.get("cacheCreationTokens", 0)),
                    num(totals.get("cacheReadTokens", 0)),
                    num(totals.get("totalTokens", 0)),
                    money(totals.get("totalCost", 0.0)),
                ]
            ],
        )
    )
    out.append("")

    if "day" in report:
        out.append("## By day")
        out.append("")
        rows = [
            [
                d.get("date", ""),
                num(d.get("inputTokens", 0)),
                num(d.get("outputTokens", 0)),
                num(d.get("totalTokens", 0)),
                money(d.get("totalCost", 0.0)),
                ", ".join(d.get("modelsUsed") or []),
            ]
            for d in report["day"]
        ]
        out.append(_md_table(["date", "input", "output", "total tokens", "cost", "models used"], rows))
        out.append("")

    if "model" in report:
        out.append("## By model (whole range)")
        out.append("")
        rows = [
            [
                m["modelName"],
                num(m["totalTokens"]),
                money(m["cost"]),
                m["providerBucket"],
            ]
            for m in report["model"]
        ]
        out.append(_md_table(["model", "total tokens", "cost", "provider (best-effort)"], rows))
        out.append("")

    if "provider" in report:
        out.append("## By provider family (best-effort — see honest-labeling note above)")
        out.append("")
        rows = [
            [
                p["providerBucket"],
                ", ".join(sorted(set(p["models"]))),
                num(p["totalTokens"]),
                money(p["cost"]),
            ]
            for p in report["provider"]
        ]
        out.append(_md_table(["provider bucket", "models in bucket", "total tokens", "cost"], rows))
        out.append("")

    if "project" in report:
        out.append("## By project path")
        out.append("")
        rows = [
            [
                p["projectPath"],
                p["sessionCount"],
                num(p["totalTokens"]),
                money(p["cost"]),
            ]
            for p in report["project"]
        ]
        out.append(_md_table(["project path", "sessions", "total tokens", "cost"], rows))
        out.append("")

    if "session" in report:
        out.append("## By session (top 25 by cost)")
        out.append("")
        sessions = sorted(report["session"], key=lambda s: s.get("totalCost", 0.0), reverse=True)[:25]
        rows = [
            [
                s.get("sessionId", "")[:12],
                s.get("projectPath", ""),
                s.get("firstActivity", "")[:19],
                s.get("lastActivity", "")[:19],
                num(s.get("totalTokens", 0)),
                money(s.get("totalCost", 0.0)),
            ]
            for s in sessions
        ]
        out.append(_md_table(["session (short id)", "project path", "first activity", "last activity", "total tokens", "cost"], rows))
        out.append("")

    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--daily", required=True, help="path to ccusage claude daily --json output")
    ap.add_argument("--session", required=True, help="path to ccusage claude session --json output")
    ap.add_argument("--status", default="", help="path to scripts/providers/status.json (optional)")
    ap.add_argument("--since", required=True)
    ap.add_argument("--until", required=True)
    ap.add_argument("--group-by", default="all", choices=["day", "model", "session", "project", "provider", "all"])
    ap.add_argument("--format", default="json", choices=["json", "md", "csv"])
    args = ap.parse_args(argv)

    daily = _load_json(args.daily)
    session = _load_json(args.session)
    status = _load_json(args.status) if args.status else None

    if daily is None:
        print("claude_usage_report.py: could not read/parse --daily JSON", file=sys.stderr)
        return 1
    if session is None:
        print("claude_usage_report.py: could not read/parse --session JSON", file=sys.stderr)
        return 1

    report = build_report(daily, session, status, args.since, args.until, args.group_by)

    if args.format == "json":
        print(render_json(report))
    elif args.format == "csv":
        print(render_csv(report))
    else:
        print(render_md(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
