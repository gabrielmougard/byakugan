#!/usr/bin/env bash
# Shadow reach count: per deal with a placement list (a list of sites or
# placements it may buy), the bid requests that list alone rejected, which a
# "placement list or context" rule could take instead.
#   deploy/reach.example.sh DAY OUT_DIR
# Copy to deploy/reach.sh (gitignored) and write extract() against your own
# logs. It writes six CSVs (with a header row) into OUT_DIR; this script then
# lists their pages in OUT_DIR/traffic.tsv for the crawler. Queue it
#   curl --data-binary @OUT_DIR/traffic.tsv "$CRAWLER/traffic"
# let the crawler fetch the pages, then run deploy/reach_report.example.py.
#
#   deals.csv              one row per deal, that day:
#                          deal_id, available (requests where it passed every
#                          filter), bids, impressions, revenue
#   deal_reach.csv         deal_id, rejected_in_footprint: requests its
#                          placement list rejected in the countries where it
#                          passes its other filters (>= 1% of its available
#                          requests come from them)
#   summary.csv            one row: requests_in_footprint, the requests with
#                          at least one such rejection
#   rejected_sample.csv    about 2,000 of those requests, drawn at random:
#                          request_id, page (its URL), deals (the deal_ids
#                          rejected, comma-separated, quoted)
#   rejected_outcomes.csv  the same requests: request_id, available_deals,
#                          deal_bids, served (true/false)
#   available_sample.csv   up to 20 random requests per deal where it passed
#                          every filter: deal_id, request_id, page, bid
#                          (true/false)
#
# Counts are for the whole day: if your logs are sampled, scale them up.
set -euo pipefail

day=${1:?DAY}
out=${2:?OUT_DIR}
mkdir -p "$out"

extract() {
  echo "extract(): write the six CSVs for $1 into $2 from your logs" >&2
  exit 1
}

extract "$day" "$out"

# The pages to crawl, as crawler POST /traffic lines: URL, sample rows on it.
python3 -I - "$out" > "$out/traffic.tsv" <<'EOF'
import collections, csv, sys
rows = collections.Counter()
for name in ("rejected_sample.csv", "available_sample.csv"):
    for r in csv.DictReader(open(f"{sys.argv[1]}/{name}")):
        rows[r["page"]] += 1
for page, n in rows.items():
    print(f"{page}\t{n}")
EOF
wc -l "$out"/*.csv "$out/traffic.tsv" >&2
