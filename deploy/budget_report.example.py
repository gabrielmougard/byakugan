"""Budget-adjusted reach ceiling, from the shadow-reach report and the deals'
goals.

  python3 -I deploy/budget_report.example.py OUT_DIR GOALS_TSV DELIVERY_CSV REF_DAY [VIEW] > budgets.md

OUT_DIR holds context_reach.csv (written by reach_report.example.py).
GOALS_TSV is exported from your deal system, one line per deal under a header:
deal_id, units (impressions booked, free ones included; when empty,
budget / price x 1000), start_date, end_date (YYYY-MM-DD), price (per thousand
impressions), budget. DELIVERY_CSV has the daily impressions per deal
(deal_id, day, impressions; deploy/budgets.example.sh makes it). VIEW is one
of reach_report's context views (default "main topic, tier 1").

The reach ceiling assumes every added request can sell. A deal that already
delivers its budget gains nothing, so per deal the added impressions are capped
by its remaining goal and by how far behind pace it is, over at most 30 days.
"""

import csv
import datetime
import sys

out, goals_path, delivery_path, ref_day = sys.argv[1:5]
view = sys.argv[5] if len(sys.argv) > 5 else "main topic, tier 1"
ref = datetime.date.fromisoformat(ref_day)


def rows(name):
    return list(csv.DictReader(open(f"{out}/{name}")))


def date(s):
    return datetime.date.fromisoformat(s.split(" ")[0])


def num(r, k):
    return float(r.get(k) or 0)


goals = {}
for r in csv.DictReader(open(goals_path), delimiter="\t"):
    price = float(r["price"])
    units = float(r["units"]) if r["units"] else float(r["budget"]) / price * 1000
    goals[r["deal_id"]] = {
        "goal": int(units),
        "start": date(r["start_date"]),
        "end": date(r["end_date"]),
        "cpm": price,
    }

delivery = {}
for r in csv.DictReader(open(delivery_path)):
    delivery.setdefault(r["deal_id"], []).append((date(r["day"]), int(float(r["impressions"]))))

context = {
    r["deal_id"]: r for r in rows("context_reach.csv") if r["view"] == view
}

result = []
for deal, c in context.items():
    g = goals.get(deal)
    if not g or g["start"] > ref or g["end"] < ref:
        continue
    total_days = (g["end"] - g["start"]).days + 1
    elapsed = max(0, min(total_days, (ref - g["start"]).days + 1))
    remaining_days = max(0, (g["end"] - ref).days + 1)
    delivered = sum(n for day, n in delivery.get(deal, []) if g["start"] <= day <= min(ref, g["end"]))
    remaining = max(0, g["goal"] - delivered)
    pace = g["goal"] / total_days if total_days else 0.0
    run_rate = delivered / elapsed if elapsed else 0.0
    # gap: impressions a day behind an even pace; head: the added impressions
    # that fit in it; price: realised per impression, else the booked CPM.
    gap = max(0.0, pace - run_rate) if remaining else 0.0

    added = num(c, "added_impressions")
    impressions = num(c, "impressions")
    revenue = num(c, "revenue")
    price = revenue / impressions if impressions else g["cpm"] / 1000
    head = min(added, gap)
    horizon = min(remaining_days, 30)
    head_horizon = min(head * horizon, remaining)
    result.append(
        {
            "deal": deal,
            "goal": g["goal"],
            "delivered": delivered,
            "remaining": remaining,
            "remaining_days": remaining_days,
            "pace": pace,
            "run_rate": run_rate,
            "gap": gap,
            "added": added,
            "head": head,
            "head_horizon": head_horizon,
            "price": price,
            "value_day": head * price,
            "value_30d": head_horizon * price,
            "ceiling_day": added * price,
            "category": c["categories"],
        }
    )

active = [r for r in result if r["added"] > 0]
print("| deal | context | goal | delivered | remaining | days left | gap / day | added / day | budget-capped / day | revenue next 30 days |")
print("|---|---|---|---|---|---|---|---|---|---|")
for r in sorted(active, key=lambda x: -x["value_30d"])[:15]:
    print(
        f"| {r['deal']} | {r['category']} | {r['goal'] / 1e6:.1f}M | {r['delivered'] / 1e6:.2f}M | "
        f"{r['remaining'] / 1e6:.1f}M | {r['remaining_days']} | {r['gap'] / 1e3:.0f}K | "
        f"{r['added'] / 1e3:.0f}K | {r['head'] / 1e3:.0f}K | {r['value_30d']:,.0f} |"
    )
print()
print(f"- Deals with a context and a goal: {len(result)}, active and under pace at the reference day: "
      f"{sum(1 for r in result if r['gap'] > 1)}.")
print(f"- Added impressions/day at current win rates: {sum(r['added'] for r in result) / 1e6:.2f}M; "
      f"budget-limited: {sum(r['head'] for r in result) / 1e6:.2f}M.")
print(f"- Unconstrained ceiling: {sum(r['ceiling_day'] for r in result):,.0f} revenue a day. "
      f"Budget-limited: {sum(r['value_day'] for r in result):,.0f} a day, "
      f"{sum(r['value_30d'] for r in result):,.0f} over the next 30 days.")
print(f"- Remaining booked impressions on those deals: {sum(r['remaining'] for r in result) / 1e6:.0f}M.")
