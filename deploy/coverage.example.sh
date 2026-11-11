#!/usr/bin/env bash
# Share of a day's impressions on pages the lab has a profile for:
#   deploy/coverage.example.sh
# Copy to deploy/coverage.sh (gitignored) and write pages() and total()
# against your own logs. Prints one JSON object:
#   {"pages": 100000, "covered_pages": 412, "count": 3912345,
#    "covered_count": 81234, "impressions": 4100000, "share": 0.0198}
set -euo pipefail

crawler=${CRAWLER:-http://localhost:8081}

# One line per page, "url<TAB>impressions that day", most first, as many
# pages as you want checked (100,000 is plenty); pages left out count as not
# covered.
#   https://www.example.com/news/a-story	1830
pages() {
  echo "pages(): print url<TAB>impressions lines from your logs" >&2
  exit 1
}

# The day's impressions on all pages: one number.
total() {
  echo "total(): print the day's impression count" >&2
  exit 1
}

total=$(total)
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
pages > "$dir/pages.tsv"
# The online proxy holds the body in memory; 100k pages at once OOM-kills it.
shopt -s nullglob
split -l 5000 "$dir/pages.tsv" "$dir/part-"
: > "$dir/responses"
for f in "$dir"/part-*; do
  curl -sS --fail --data-binary @"$f" "$crawler/coverage" >> "$dir/responses"
  printf '\n' >> "$dir/responses"
done
jq -s --argjson total "$total" '
  {pages: (map(.pages) | add), covered_pages: (map(.covered_pages) | add),
   count: (map(.count) | add), covered_count: (map(.covered_count) | add)}
  | . + {impressions: $total, share: (.covered_count / $total)}' "$dir/responses"
