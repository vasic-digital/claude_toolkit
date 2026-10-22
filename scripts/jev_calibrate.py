#!/usr/bin/env python3
"""jev_calibrate.py — stdlib-only Jev decision-threshold calibration
(design: toolkit-jev-design §2.6 follow-up; mirrors the POC calibration loop
documented in Jev.md — shadow -> label -> sweep -> enforce -> drift check).

python3 >= 3.8 stdlib only (argparse, json, math, statistics).

Subcommands:
  label --data DECISIONS --labels LABELS --out OUT
      Merge operator-supplied ground truth into a decisions.jsonl-shaped
      snapshot by 0-based line index. LABELS is a JSON array of
      {"index": int, "ground_truth_ask": bool, "ground_truth_deny": bool}
      (either field may be omitted per entry). There is NO built-in
      LLM-teacher auto-labeling call in this implementation — ground truth
      must come from an operator-supplied file (e.g. hand-reviewed shadow
      decisions, or a file your own LLM-teacher script writes in this exact
      shape). Wiring a live "ask Claude to label this" call is a documented
      follow-up integration point, not something this script fabricates.

  sweep --data LABELED [--target-accuracy 0.95] [--lock LOCK] [--json]
      Find the lowest risky_p threshold that reaches --target-accuracy
      against each of ground_truth_ask / ground_truth_deny independently
      (both compared against the same risky_p predictor jev-gate.sh already
      emits). If no threshold reaches the target, that threshold is null
      ("None is a real answer" — the question needs revising, not the bar
      lowered). Also computes ECE/MCE/Brier against ground_truth_ask (the
      primary escalation signal) and writes LOCK (default decisions.lock.json
      next to --data) unless --lock - is given.

  check --data LABELED --lock LOCK [--max-ece 0.05] [--max-mce 0.15]
        [--warn-drift-pct 20] [--json]
      Recompute ECE/MCE/Brier on fresh labeled data using the LOCKED
      thresholds (no re-sweep) and report PASS/WARN/FAIL. Exit codes follow
      the POC doc's CI-gate convention: 0 = pass, 1 = bounds exceeded (fail),
      2 = config/input error (missing lock file, unreadable data, etc).
"""
import argparse
import json
import sys
from datetime import datetime, timezone


def _read_jsonl(path):
    rows = []
    with open(path, "r") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                rows.append(None)
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                rows.append(None)
    return rows


def _write_jsonl(path, rows):
    with open(path, "w") as fh:
        for row in rows:
            fh.write(json.dumps(row, sort_keys=True) + "\n")


def cmd_label(args):
    decisions = _read_jsonl(args.data)
    with open(args.labels, "r") as fh:
        labels = json.load(fh)
    if not isinstance(labels, list):
        print("jev_calibrate: --labels must be a JSON array", file=sys.stderr)
        return 2
    by_index = {}
    for entry in labels:
        idx = entry.get("index")
        if not isinstance(idx, int):
            continue
        by_index[idx] = entry

    labeled_count = 0
    out_rows = []
    for i, row in enumerate(decisions):
        if row is None:
            out_rows.append(row)
            continue
        merged = dict(row)
        entry = by_index.get(i)
        merged.setdefault("ground_truth_ask", None)
        merged.setdefault("ground_truth_deny", None)
        if entry is not None:
            if "ground_truth_ask" in entry:
                merged["ground_truth_ask"] = bool(entry["ground_truth_ask"])
            if "ground_truth_deny" in entry:
                merged["ground_truth_deny"] = bool(entry["ground_truth_deny"])
            labeled_count += 1
        out_rows.append(merged)

    _write_jsonl(args.out, out_rows)
    print(
        "jev_calibrate: labeled %d of %d decisions -> %s"
        % (labeled_count, len(decisions), args.out)
    )
    return 0


def _labeled_pairs(rows, field):
    """[(risky_p, ground_truth_bool), ...] for rows where field is not null."""
    pairs = []
    for row in rows:
        if row is None:
            continue
        gt = row.get(field)
        if gt is None:
            continue
        p = row.get("risky_p")
        if p is None:
            continue
        pairs.append((float(p), bool(gt)))
    return pairs


def _best_threshold(pairs, target_accuracy):
    """Lowest threshold reaching target_accuracy; None if none does."""
    if not pairs:
        return None, 0.0
    candidates = sorted({0.0, 1.0} | {p for p, _ in pairs})
    best = None
    best_acc = 0.0
    for tau in candidates:
        correct = sum(1 for p, gt in pairs if (p >= tau) == gt)
        acc = correct / len(pairs)
        if acc > best_acc or (acc == best_acc and best is not None and tau < best):
            best_acc = acc
        if acc >= target_accuracy and (best is None or tau < best):
            best = tau
    return best, best_acc


def _calibration_metrics(pairs, n_bins=10):
    """(ece, mce, brier) for [(predicted_prob, actual_bool), ...]."""
    if not pairs:
        return 0.0, 0.0, 0.0
    n = len(pairs)
    brier = sum((p - (1.0 if gt else 0.0)) ** 2 for p, gt in pairs) / n

    bins = [[] for _ in range(n_bins)]
    for p, gt in pairs:
        idx = min(int(p * n_bins), n_bins - 1)
        bins[idx].append((p, gt))

    ece = 0.0
    mce = 0.0
    for bucket in bins:
        if not bucket:
            continue
        avg_pred = sum(p for p, _ in bucket) / len(bucket)
        frac_pos = sum(1.0 for _, gt in bucket if gt) / len(bucket)
        gap = abs(avg_pred - frac_pos)
        ece += (len(bucket) / n) * gap
        mce = max(mce, gap)
    return round(ece, 6), round(mce, 6), round(brier, 6)


def cmd_sweep(args):
    rows = _read_jsonl(args.data)
    ask_pairs = _labeled_pairs(rows, "ground_truth_ask")
    deny_pairs = _labeled_pairs(rows, "ground_truth_deny")

    ask_threshold, ask_acc = _best_threshold(ask_pairs, args.target_accuracy)
    deny_threshold, deny_acc = _best_threshold(deny_pairs, args.target_accuracy)
    ece, mce, brier = _calibration_metrics(ask_pairs)

    result = {
        "ask_threshold": ask_threshold,
        "ask_threshold_accuracy": round(ask_acc, 4),
        "deny_threshold": deny_threshold,
        "deny_threshold_accuracy": round(deny_acc, 4),
        "calibrated_at": datetime.now(timezone.utc).isoformat(),
        "sample_size": len(ask_pairs),
        "deny_sample_size": len(deny_pairs),
        "target_accuracy": args.target_accuracy,
        "ece": ece,
        "mce": mce,
        "brier": brier,
    }
    if ask_threshold is None:
        result["ask_note"] = (
            "no threshold reaches target_accuracy=%s against ground_truth_ask "
            "— that is a real answer: revise the gate question, don't lower "
            "the bar." % args.target_accuracy
        )
    if deny_threshold is None:
        result["deny_note"] = (
            "no threshold reaches target_accuracy=%s against ground_truth_deny"
            % args.target_accuracy
        )

    if args.lock != "-":
        with open(args.lock, "w") as fh:
            json.dump(result, fh, indent=2, sort_keys=True)
            fh.write("\n")

    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print("jev-calibrate sweep (target accuracy %s, n=%d ask / %d deny)" %
              (args.target_accuracy, len(ask_pairs), len(deny_pairs)))
        print("  ask_threshold:  %s (accuracy %.4f)" % (ask_threshold, ask_acc))
        print("  deny_threshold: %s (accuracy %.4f)" % (deny_threshold, deny_acc))
        print("  ECE=%.4f  MCE=%.4f  Brier=%.4f" % (ece, mce, brier))
        if args.lock != "-":
            print("  wrote %s" % args.lock)
    return 0


def cmd_check(args):
    try:
        with open(args.lock, "r") as fh:
            lock = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        print("jev_calibrate: cannot read lock file %s: %s" % (args.lock, exc), file=sys.stderr)
        return 2

    rows = _read_jsonl(args.data)
    ask_pairs = _labeled_pairs(rows, "ground_truth_ask")
    ece, mce, brier = _calibration_metrics(ask_pairs)

    locked_ece = lock.get("ece", 0.0) or 0.0
    drift_pct = (abs(ece - locked_ece) / locked_ece * 100.0) if locked_ece else (100.0 if ece else 0.0)

    verdict = "PASS"
    if ece > args.max_ece or mce > args.max_mce:
        verdict = "FAIL"
    elif drift_pct > args.warn_drift_pct:
        verdict = "WARN"

    result = {
        "verdict": verdict,
        "ece": ece, "mce": mce, "brier": brier,
        "locked_ece": locked_ece,
        "drift_pct": round(drift_pct, 2),
        "max_ece": args.max_ece, "max_mce": args.max_mce,
        "sample_size": len(ask_pairs),
    }
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print("jev-calibrate check: %s (ECE=%.4f MCE=%.4f Brier=%.4f, drift %.1f%% vs lock)" %
              (verdict, ece, mce, brier, drift_pct))
    return 0 if verdict in ("PASS", "WARN") else 1


def main():
    parser = argparse.ArgumentParser(prog="jev_calibrate.py")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_label = sub.add_parser("label")
    p_label.add_argument("--data", required=True)
    p_label.add_argument("--labels", required=True)
    p_label.add_argument("--out", required=True)
    p_label.set_defaults(func=cmd_label)

    p_sweep = sub.add_parser("sweep")
    p_sweep.add_argument("--data", required=True)
    p_sweep.add_argument("--target-accuracy", type=float, default=0.95)
    p_sweep.add_argument("--lock", default="decisions.lock.json")
    p_sweep.add_argument("--json", action="store_true")
    p_sweep.set_defaults(func=cmd_sweep)

    p_check = sub.add_parser("check")
    p_check.add_argument("--data", required=True)
    p_check.add_argument("--lock", required=True)
    p_check.add_argument("--max-ece", type=float, default=0.05)
    p_check.add_argument("--max-mce", type=float, default=0.15)
    p_check.add_argument("--warn-drift-pct", type=float, default=20.0)
    p_check.add_argument("--json", action="store_true")
    p_check.set_defaults(func=cmd_check)

    args = parser.parse_args()
    try:
        return args.func(args)
    except (OSError, json.JSONDecodeError) as exc:
        print("jev_calibrate: %s" % exc, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
