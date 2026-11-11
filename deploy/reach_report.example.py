"""Shadow reach report, from deploy/reach.example.sh's CSVs and the sampled
pages crawled with T4 off (OUT_DIR/traffic.tsv sent to crawler POST /traffic).

  python3 -I deploy/reach_report.example.py OUT_DIR CRAWLER_URL TAXONOMY_TSV > report.md

CRAWLER_URL is the crawl daemon (e.g. http://localhost:8081), TAXONOMY_TSV the
IAB Content Taxonomy (src/data/content_taxonomy_3.1.tsv). It also writes
OUT_DIR/context_reach.csv, per deal and view, for deploy/budgets.example.sh.

A deal's context is inferred from its placements: the categories of at least
25% of the pages where it passed every filter. A page's categories are read
two ways from its served (rich) labels:
- main topic: its best label found by a tier (not filled in by the hierarchy),
  ties broken by T2's raw page cosine. Robust to T2's saturated scores.
- any label >= 0.5: what Rule.Check (Go SDK, Matcher.refusal) sees.
A rejected request counts for a deal when its page carries one of the deal's
categories and no Sensitive Topics label >= 0.5. Added requests per deal =
in-footprint placement rejections (counted for the whole day) x its match
rate among the sampled rejected requests. Pages that could not be crawled are
assumed to match like the others. Revenue is in the bid log's price currency.
"""

import collections
import csv
import json
import re
import sys
import urllib.parse
import urllib.request

SENSITIVE = "v9i3On"
PRESENT = 0.5
SHARE = 0.25
COSINE = re.compile(r"page cos (-?[0-9.]+)")

out, crawler, taxonomy = sys.argv[1:4]


def rows(name):
    return list(csv.DictReader(open(f"{out}/{name}")))


def num(r, k):
    return float(r.get(k) or 0)


parent, name = {}, {}
for line in open(taxonomy).read().splitlines()[2:]:
    cols = line.split("\t")
    if len(cols) > 2 and cols[0]:
        parent[cols[0]] = cols[1] or None
        name[cols[0]] = cols[2]


def ancestors(i):
    chain = []
    while i:
        chain.append(i)
        i = parent.get(i)
    return chain


def at_tier(i, tier):
    chain = ancestors(i)
    return chain[-tier] if len(chain) >= tier else None


def path(i):
    return " > ".join(name.get(a, a) for a in reversed(ancestors(i)))


def served(page):
    """The rich level's labels, or None when the page is not stored."""
    query = urllib.parse.urlencode({"url": page})
    try:
        profile = json.load(urllib.request.urlopen(f"{crawler}/inspect?{query}", timeout=30))["profile"]
    except Exception:
        return None
    return next((l["labels"] for l in profile["levels"] if l["preset"] == "rich"), [])


def main_topic(labels):
    def key(l):
        cosines = [float(m.group(1)) for e in l["evidence"] for m in COSINE.finditer(e["why"])]
        return (l["score"], max(cosines, default=0.0))

    found = [l for l in labels if any(e["tier"] != "hierarchy" for e in l["evidence"]) and SENSITIVE not in ancestors(l["id"])]
    return max(found, key=key)["id"] if found else None


deals = {r["deal_id"]: r for r in rows("deals.csv")}
reach = {r["deal_id"]: r for r in rows("deal_reach.csv")}
summary = rows("summary.csv")[0]
rejected = rows("rejected_sample.csv")
outcome = {r["request_id"]: r for r in rows("rejected_outcomes.csv")}
available = rows("available_sample.csv")
labels = {p: served(p) for p in sorted({r["page"] for r in rejected} | {r["page"] for r in available})}
crawled = {p: l for p, l in labels.items() if l is not None}
present = {p: {l["id"] for l in ls if l["score"] >= PRESENT} for p, ls in crawled.items()}
main = {p: main_topic(ls) for p, ls in crawled.items()}
sensitive = {p: any(SENSITIVE in ancestors(i) for i in cats) for p, cats in present.items()}

views = {
    "main topic, tier 1": lambda p: {at_tier(main[p], 1)} - {None} if main[p] else set(),
    "main topic, tier 2": lambda p: {at_tier(main[p], 2)} - {None} if main[p] else set(),
    "any label >= 0.5, tier 1 (Rule.Check on today's labels)": lambda p: {at_tier(i, 1) for i in present[p]} - {SENSITIVE},
}

rejected_crawled = [r for r in rejected if r["page"] in crawled]
available_crawled = [r for r in available if r["page"] in crawled]
in_footprint = num(summary, "requests_in_footprint")
today = [outcome[r["request_id"]] for r in rejected if r["request_id"] in outcome]


def share(f):
    return 100 * sum(1 for o in today if f(o)) / max(1, len(today))


def bid_rate(rs):
    return 100 * sum(r["bid"] == "true" for r in rs) / max(1, len(rs))


print("# Shadow reach of contextual curated deals\n")
print(f"- Pages sampled {len(labels)}, crawled with T4 off {len(crawled)} ({100 * len(crawled) / len(labels):.0f}%); "
      f"Sensitive Topics >= 0.5 on {100 * sum(sensitive.values()) / len(crawled):.0f}% of them.")
print(f"- Requests a placement list alone stops for at least one deal: {in_footprint / 1e6:,.1f}M a day.")
print(f"- Those requests: no deal available {share(lambda o: o['available_deals'] == '0'):.0f}%, "
      f"deals available but none bids {share(lambda o: o['available_deals'] != '0' and o['deal_bids'] == '0'):.0f}%, "
      f"a deal bids {share(lambda o: o['deal_bids'] != '0'):.0f}%, an impression {share(lambda o: o['served'] == 'true'):.1f}%.\n")

context_rows = []
for title, view in views.items():
    cats = {p: view(p) for p in crawled}

    def targets(deal):
        own = [cats[r["page"]] for r in available_crawled if r["deal_id"] == deal]
        counts = collections.Counter(c for cs in own for c in cs)
        return {c for c, n in counts.items() if own and n >= SHARE * len(own)}

    def matches(page, rule):
        return bool(rule & cats[page]) and not sensitive[page]

    rules = {d: targets(d) for d in deals}
    per_deal = []
    for d, rule in rules.items():
        info = deals[d]
        seen = [r for r in rejected_crawled if d in r["deals"].split(",")]
        rate = sum(matches(r["page"], rule) for r in seen) / len(seen) if seen else 0.0
        added = num(reach.get(d, {}), "rejected_in_footprint") * rate
        imp_rate = num(info, "impressions") / num(info, "available") if num(info, "available") else 0.0
        per_deal.append((d, rule, len(seen), rate, added, added * imp_rate, info))
        if rule:
            context_rows.append(
                {
                    "view": title,
                    "deal_id": d,
                    "categories": "; ".join(sorted(path(c) for c in rule)),
                    "sampled": len(seen),
                    "match_rate": rate,
                    "added_requests": added,
                    "added_impressions": added * imp_rate,
                    "available": num(info, "available"),
                    "bids": num(info, "bids"),
                    "impressions": num(info, "impressions"),
                    "revenue": num(info, "revenue"),
                }
            )

    # One impression at most per unsold sampled request: it sells when any
    # matching deal fills it, 1 - prod(1 - p) with p a deal's impressions per
    # available request, at the deals' p-weighted mean price.
    impressions = revenue = 0.0
    for r in rejected_crawled:
        if outcome.get(r["request_id"], {}).get("served") == "true":
            continue
        rates = [(num(deals[d], "impressions") / num(deals[d], "available"), num(deals[d], "revenue") / num(deals[d], "impressions"))
                 for d in r["deals"].split(",")
                 if d in rules and matches(r["page"], rules[d]) and num(deals[d], "available") and num(deals[d], "impressions")]
        if rates:
            miss = 1.0
            for p, _ in rates:
                miss *= 1 - p
            impressions += 1 - miss
            revenue += (1 - miss) * sum(p * price for p, price in rates) / sum(p for p, _ in rates)
    scale = in_footprint / max(1, len(rejected_crawled))

    topical = [r for r in available_crawled if rules[r["deal_id"]]]
    on = [r for r in topical if matches(r["page"], rules[r["deal_id"]])]
    off = [r for r in topical if not matches(r["page"], rules[r["deal_id"]])]
    with_context = [x for x in per_deal if x[1]]
    print(f"## Context: {title}\n")
    print(f"- Deals with a context: {len(with_context)} of {len(rules)}, "
          f"{sum(len(x[1]) for x in with_context) / max(1, len(with_context)):.1f} categories each on average.")
    print(f"- Bid rate of those deals where they already pass every filter: on their context {bid_rate(on):.1f}% ({len(on)}), "
          f"off it {bid_rate(off):.1f}% ({len(off)}).")
    print(f"- Added (deal, request) pairs: {sum(x[4] for x in per_deal) / 1e6:,.0f}M a day, against "
          f"{sum(num(x[6], 'available') for x in per_deal) / 1e6:,.0f}M available now.")
    print(f"- Ceiling, one impression at most per unsold request, at each deal's impressions per available request: "
          f"{impressions * scale / 1e6:,.1f}M impressions, {revenue * scale:,.0f} revenue a day "
          f"(the deals serve {sum(num(x[6], 'impressions') for x in per_deal) / 1e6:,.1f}M, {sum(num(x[6], 'revenue') for x in per_deal):,.0f}).\n")
    print("| deal | context | sampled | match | added requests / day | available / day now | bid rate now | impressions / day now | added at today's rate |")
    print("|---|---|---|---|---|---|---|---|---|")
    for d, rule, n, rate, added, added_impressions, info in sorted(per_deal, key=lambda x: -num(x[6], "revenue"))[:12]:
        context = "; ".join(sorted(path(c) for c in rule)) or "-"
        bids = 100 * num(info, "bids") / num(info, "available") if num(info, "available") else 0.0
        print(f"| {d} | {context} | {n} | {100 * rate:.0f}% | {added / 1e6:.1f}M | {num(info, 'available') / 1e6:.1f}M | "
              f"{bids:.1f}% | {num(info, 'impressions') / 1e3:.0f}K | {added_impressions / 1e3:.0f}K |")
    print()

print("## Bid rate by page main topic (tier 1)\n")
print("| main topic | requests | bid rate |")
print("|---|---|---|")
by_topic = collections.defaultdict(list)
for r in available_crawled:
    by_topic[path(at_tier(main[r["page"]], 1)) if main[r["page"]] else "(none)"].append(r)
for topic, rs in sorted(by_topic.items(), key=lambda x: -len(x[1]))[:15]:
    print(f"| {topic} | {len(rs)} | {bid_rate(rs):.1f}% |")

with open(f"{out}/context_reach.csv", "w", newline="") as f:
    fields = ["view", "deal_id", "categories", "sampled", "match_rate", "added_requests",
              "added_impressions", "available", "bids", "impressions", "revenue"]
    w = csv.DictWriter(f, fields)
    w.writeheader()
    w.writerows(context_rows)
