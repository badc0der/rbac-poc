#!/usr/bin/env python3
"""
rules_daemon.py
Applies a ruleset over the SAME 36-feature vector as the model, logs decisions,
and flips an SELinux boolean (rule_block) when any rule fires.

Rules JSON format (example):
[
  {
    "name": "rss_and_lock_churn",
    "any": [
      {"feature": "Memory Info RSS", "op": ">", "value": 5_000_000},
      {"all": [
          {"feature": "locks_remove_posix()", "op": ">", "value": 30},
          {"feature": "betweenness", "op": ">", "value": 0.05}
      ]}
    ]
  },
  ...
]
Supported keys: "all", "any", "not" (boolean composition), and atomic predicates.

Usage:
  rules_daemon.py --rules rules.json --keys ftrace_keys.json \
    --csv decisions_rules.csv --log rules_daemon.log --penc-threshold 0.50
"""
from __future__ import annotations
import argparse, json, time, os, sys, csv
from pathlib import Path
from typing import Any, Dict

from feature_collector import Collector

def _set_bool(name: str, value: bool) -> None:
    try:
        os.system(f"/usr/sbin/setsebool -P {name} {'on' if value else 'off'} >/dev/null 2>&1")
    except Exception:
        pass

def _cmp(lhs: float, op: str, rhs: float) -> bool:
    if op == ">":  return lhs >  rhs
    if op == ">=": return lhs >= rhs
    if op == "<":  return lhs <  rhs
    if op == "<=": return lhs <= rhs
    if op == "==": return lhs == rhs
    if op == "!=": return lhs != rhs
    raise ValueError(f"Unknown op: {op}")

def eval_rule(rule: Dict[str, Any], row: Dict[str, float]) -> bool:
    if "all" in rule:
        return all(eval_rule(r, row) for r in rule["all"])
    if "any" in rule:
        return any(eval_rule(r, row) for r in rule["any"])
    if "not" in rule:
        return not eval_rule(rule["not"], row)
    # atomic predicate
    f = rule.get("feature")
    op = rule.get("op", ">")
    v  = float(rule.get("value", 0.0))
    lhs = float(row.get(f, 0.0))
    return _cmp(lhs, op, v)

def decision_from_rules(rules, row) -> bool:
    """Return True if ANY top-level rule fires."""
    for r in rules:
        if eval_rule(r, row):
            return True
    return False

def load_json(path: str | Path):
    return json.loads(Path(path).read_text())

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rules", required=True, help="rules.json")
    ap.add_argument("--keys", required=True, help="ftrace_keys.json")
    ap.add_argument("--csv", required=True)
    ap.add_argument("--log", default=None)
    ap.add_argument("--penc-threshold", type=float, default=0.50,
                    help="optional probability-like threshold if rules include p_enc fields (not required otherwise)")
    ap.add_argument("--period", type=float, default=1.0)
    ap.add_argument("--duration", type=float, default=0.0)
    ap.add_argument("--selinux-boolean", default="rule_block")
    args = ap.parse_args()

    rules = load_json(args.rules)
    coll = Collector(args.keys)

    csv_path = Path(args.csv)
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    new_file = not csv_path.exists()
    with csv_path.open("a", newline="") as f:
        # We don't know the exact feature order here; we just dump what we have per row
        writer = None

        start = time.time()
        while True:
            row = coll.collect()  # dict of features
            # Lazy-init CSV header with row keys when first sample arrives
            if writer is None:
                fieldnames = ["ts", "rule_block"] + sorted(row.keys())
                writer = csv.DictWriter(f, fieldnames=fieldnames)
                if new_file:
                    writer.writeheader()

            block = decision_from_rules(rules, row)
            if block:
                _set_bool(args.selinux_boolean, True)
            else:
                _set_bool(args.selinux_boolean, False)

            out = {"ts": time.time(), "rule_block": int(block)}
            out.update(row)
            writer.writerow(out)
            f.flush()

            if args.duration and (time.time() - start) >= args.duration:
                break
            time.sleep(max(0.05, args.period))

if __name__ == "__main__":
    sys.exit(main())
