#!/usr/bin/env python3
"""cost_report.py — daily AWS cost breakdown for the BSS Platform account.

Wraps Cost Explorer (`ce get-cost-and-usage`) because the AWS Console view
lags by a day and doesn't fit a terminal-based ops workflow. Read-only:
this tool never creates, modifies, or deletes AWS resources.

Usage:
    python tools/ops/cost_report.py
    python tools/ops/cost_report.py --days 14 --budget 50
    python tools/ops/cost_report.py --tag-key Environment --json
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import sys

import boto3

# Cost Explorer is a global service but its API only lives in us-east-1,
# regardless of which region the workloads themselves run in (ap-southeast-1).
CE_REGION = "us-east-1"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--days", type=int, default=7, help="Lookback window in days (default: 7)"
    )
    parser.add_argument(
        "--budget",
        type=float,
        default=30.0,
        help="Monthly budget in USD to compare against (default: 30, matches CLAUDE.md dev budget)",
    )
    parser.add_argument(
        "--tag-key",
        default="Environment",
        help="Cost allocation tag to group by, in addition to SERVICE (default: Environment)",
    )
    parser.add_argument("--profile", default=None, help="AWS CLI profile name")
    parser.add_argument(
        "--json", action="store_true", help="Print raw grouped totals as JSON instead of a table"
    )
    return parser.parse_args()


def get_cost_and_usage(client, start: str, end: str, group_by: list[dict]) -> dict:
    return client.get_cost_and_usage(
        TimePeriod={"Start": start, "End": end},
        Granularity="DAILY",
        Metrics=["UnblendedCost"],
        GroupBy=group_by,
    )


def sum_by_group(response: dict) -> dict[str, float]:
    totals: dict[str, float] = {}
    for day in response["ResultsByTime"]:
        for group in day["Groups"]:
            key = " / ".join(k for k in group["Keys"] if k) or "(untagged)"
            amount = float(group["Metrics"]["UnblendedCost"]["Amount"])
            totals[key] = totals.get(key, 0.0) + amount
    return totals


def print_table(title: str, totals: dict[str, float]) -> None:
    print(f"\n{title}")
    print("-" * len(title))
    if not totals:
        print("  (no cost recorded in this window)")
        return
    width = max(len(k) for k in totals) + 2
    for key, amount in sorted(totals.items(), key=lambda kv: kv[1], reverse=True):
        print(f"  {key:<{width}} ${amount:>10.4f}")


def main() -> int:
    args = parse_args()
    session = boto3.Session(profile_name=args.profile, region_name=CE_REGION)
    client = session.client("ce")

    end = dt.date.today()
    start = end - dt.timedelta(days=args.days)
    start_s, end_s = start.isoformat(), end.isoformat()

    by_service = sum_by_group(
        get_cost_and_usage(
            client, start_s, end_s, [{"Type": "DIMENSION", "Key": "SERVICE"}]
        )
    )
    by_tag = sum_by_group(
        get_cost_and_usage(
            client, start_s, end_s, [{"Type": "TAG", "Key": args.tag_key}]
        )
    )

    total = sum(by_service.values())
    # Naive monthly projection: today's daily average * 30. Good enough for a
    # budget sanity check, not for finance reporting.
    daily_avg = total / max(args.days, 1)
    projected_month = daily_avg * 30

    if args.json:
        print(
            json.dumps(
                {
                    "window": {"start": start_s, "end": end_s, "days": args.days},
                    "total_usd": round(total, 4),
                    "projected_month_usd": round(projected_month, 4),
                    "budget_usd": args.budget,
                    "by_service": by_service,
                    f"by_tag_{args.tag_key}": by_tag,
                },
                indent=2,
            )
        )
        return 0

    print(f"BSS Platform — cost report {start_s} .. {end_s} ({args.days}d)")
    print_table("By AWS service", by_service)
    print_table(f"By tag '{args.tag_key}'", by_tag)

    pct = (projected_month / args.budget * 100) if args.budget else 0
    print(f"\nTotal in window : ${total:.4f}")
    print(f"Daily average   : ${daily_avg:.4f}")
    print(f"Projected/month : ${projected_month:.4f}  ({pct:.0f}% of ${args.budget:.2f} budget)")
    if pct >= 100:
        print("⚠️  Projected spend is AT or ABOVE budget — check for a forgotten `terraform destroy`.")
    elif pct >= 80:
        print("⚠️  Projected spend is above 80% of budget.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
