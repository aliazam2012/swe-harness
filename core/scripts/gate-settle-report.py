#!/usr/bin/env python3
"""Report what the done gate's settle wait actually costs.

stop-done-gate.py waits up to SETTLE_DEADLINE_S for a reply's footer to be
flushed, then blocks if it never arrives. The deadline was set to 3.0 s from a
single observation: one footer that landed 66 ms after the hook read the file.
This reads the hook's telemetry and turns that one observation into a
distribution, so the deadline can be set from data.

The number that sets the deadline is the footer_at_poll distribution: how late
the footer was on the invocations where it did arrive during the wait. Anything
above that is wait nobody needed.

Data Sources:
  - ~/.claude/gate-settle.jsonl, written by the Stop hook on this machine.
    Metadata only: no turn text ever reaches it. No database, no network, no
    credentials.

Default Environment: local. There is no other environment.

Usage:
  scripts/gate-settle-report.py [--log PATH] [--json]

  --log PATH   read this file instead of ~/.claude/gate-settle.jsonl
  --json       print one machine-readable JSON object instead of a table
"""

import argparse
import json
import sys
from pathlib import Path

DEFAULT_LOG = Path.home() / ".claude/gate-settle.jsonl"
# Kept in step with the hook. Used only to express a poll index in milliseconds.
POLL_S = 0.15
VERDICTS = ("pass_first_read", "pass_no_tool", "pass_settled", "block")


def read_rows(path: Path) -> list:
    """Return the well-formed JSON objects in the log, oldest first."""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    rows = []
    for line in text.splitlines():
        if not line.startswith("{"):
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict):
            rows.append(row)
    return rows


def percentile(values: list, pct: float) -> float:
    """Nearest-rank percentile of a sorted-able list. Empty gives 0."""
    if not values:
        return 0.0
    ordered = sorted(values)
    rank = max(1, min(len(ordered), round(pct / 100.0 * len(ordered))))
    return float(ordered[rank - 1])


def distribution(values: list) -> dict:
    """Summarise a list of numbers the way a latency table wants it."""
    clean = [v for v in values if isinstance(v, (int, float))]
    if not clean:
        return {"n": 0}
    return {
        "n": len(clean),
        "min": float(min(clean)),
        "p50": percentile(clean, 50),
        "p90": percentile(clean, 90),
        "p99": percentile(clean, 99),
        "max": float(max(clean)),
        "mean": round(sum(clean) / len(clean), 1),
    }


def summarise(rows: list) -> dict:
    """Build the whole report: counts, elapsed by verdict, footer arrival."""
    total = len(rows)
    by_verdict = {}
    for name in VERDICTS:
        subset = [r for r in rows if r.get("verdict") == name]
        by_verdict[name] = {
            "count": len(subset),
            "pct": round(100.0 * len(subset) / total, 1) if total else 0.0,
            "elapsed_ms": distribution([r.get("elapsed_ms") for r in subset]),
        }
    other = [r for r in rows if r.get("verdict") not in VERDICTS]
    late = [r.get("footer_at_poll") for r in rows
            if isinstance(r.get("footer_at_poll"), int)]
    return {
        "log_rows": total,
        "unknown_verdict": len(other),
        "by_verdict": by_verdict,
        "elapsed_ms_all": distribution([r.get("elapsed_ms") for r in rows]),
        "tail_bytes": distribution([r.get("tail_bytes") for r in rows]),
        "footer_arrived_late": {
            "count": len(late),
            "pct_of_rows": round(100.0 * len(late) / total, 1) if total else 0.0,
            "poll_index": distribution(late),
            "implied_ms": distribution([p * POLL_S * 1000 for p in late]),
        },
    }


def fmt(dist: dict) -> str:
    """One line for a distribution, or a dash when there is nothing in it."""
    if not dist.get("n"):
        return "-"
    return (f"n={dist['n']:<5} min={dist['min']:.0f} p50={dist['p50']:.0f} "
            f"p90={dist['p90']:.0f} p99={dist['p99']:.0f} max={dist['max']:.0f}")


def print_table(report: dict, path: Path) -> None:
    """Print the human-readable report."""
    print(f"gate settle report  ({report['log_rows']} rows from {path})")
    if not report["log_rows"]:
        print("  no rows yet. The hook writes one per settled decision.")
        return
    print("\n  verdict            count      pct   elapsed_ms")
    for name in VERDICTS:
        row = report["by_verdict"][name]
        print(f"  {name:<18} {row['count']:>5}  {row['pct']:>6.1f}%   "
              f"{fmt(row['elapsed_ms'])}")
    if report["unknown_verdict"]:
        print(f"  {'(unknown)':<18} {report['unknown_verdict']:>5}")
    print(f"\n  elapsed_ms, all rows   {fmt(report['elapsed_ms_all'])}")
    print(f"  tail_bytes, first read {fmt(report['tail_bytes'])}")

    late = report["footer_arrived_late"]
    print(f"\n  footer arrived during the wait: {late['count']} rows "
          f"({late['pct_of_rows']}% of all)")
    if late["count"]:
        print(f"    poll index  {fmt(late['poll_index'])}")
        print(f"    implied ms  {fmt(late['implied_ms'])}")
        print(f"\n  The deadline needs to cover {late['implied_ms']['max']:.0f} ms, "
              "not more.")
    else:
        print("    Nothing arrived late. Every footer was there on the first read,")
        print("    so no observation here argues for any deadline at all.")


def main() -> int:
    """Parse arguments, read the log, print the report."""
    parser = argparse.ArgumentParser(description="Report the done gate settle wait.")
    parser.add_argument("--log", default=str(DEFAULT_LOG), help="telemetry file to read")
    parser.add_argument("--json", action="store_true", help="print JSON, not a table")
    args = parser.parse_args()

    path = Path(args.log)
    report = summarise(read_rows(path))
    report["log"] = str(path)
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print_table(report, path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
