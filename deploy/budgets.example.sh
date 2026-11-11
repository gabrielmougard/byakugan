#!/usr/bin/env bash
# Deal budgets for the shadow-reach ceiling: what under-delivering deals could
# still take from contextual routing.
#   deploy/budgets.example.sh DAY OUT_DIR GOALS_TSV
# Copy to deploy/budgets.sh (gitignored) and write delivery() against your
# own logs. Needs OUT_DIR/context_reach.csv from reach_report.example.py.
#
# GOALS_TSV, from your deal configuration, one line per deal under a header:
#   deal_id  units  start_date  end_date  price  budget
# units: impressions booked, free ones included (empty: budget / price x 1000);
# dates YYYY-MM-DD; price per thousand impressions.
set -euo pipefail

day=${1:?DAY}
out=${2:?OUT_DIR}
goals=${3:?GOALS_TSV}
[ -f "$out/context_reach.csv" ] || { echo "run reach_report.example.py first" >&2; exit 1; }

# CSV with a header, one row per deal and day over the 120 days to DAY, for
# the deals in OUT_DIR/context_reach.csv:
#   deal_id,day,impressions
#   d-123,2026-10-01,5400
delivery() {
  echo "delivery(): print each deal's daily impressions up to $1 from your logs" >&2
  exit 1
}

delivery "$day" > "$out/delivery.csv"
python3 -I "$(dirname "$0")/budget_report.example.py" "$out" "$goals" "$out/delivery.csv" "$day"
