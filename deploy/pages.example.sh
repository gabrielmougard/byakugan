#!/usr/bin/env bash
# How many pages the bidder looks up, how concentrated, how fresh: the
# numbers that size the crawl.
#   deploy/pages.example.sh FIRST_DAY LAST_DAY
# Copy to deploy/pages.sh (gitignored) and write report() against your own
# logs. Count pages by their key, the URL normalised as src/lib/url_key.ml does
# (Store.normalize), so variants of one page count once. The report is four
# tables:
#
#   per day        day, bid requests, raw URLs, pages, impressions
#   concentration  top K pages over the window (K = 1,000 ... 5,000,000):
#                  their share of requests and of impressions
#   freshness      per day after the first 7: pages first requested that day,
#                  and the share of the day's requests and impressions on
#                  pages first requested that day, within 1 day, within 6 days
#   first hours    pages first seen after the first 7 days, by requests in
#                  their first 48 h (< 100, 100-999, 1,000-9,999, >= 10,000):
#                  the share of those requests within 1, 2, 3, 6, 12, 24 h of
#                  the first one (needs event hours and 10 days)
#
#   illustrative output:
#   == per day
#   day         requests   raw_pages  pages     impressions
#   2026-10-07  1200000    310000     240000    25000
#   == concentration
#   top         request_share  impression_share
#   1000        0.21           0.18
set -euo pipefail

first=${1:?FIRST_DAY}
last=${2:?LAST_DAY}

report() {
  echo "report(): print the four tables for $1 to $2 from your logs" >&2
  exit 1
}

report "$first" "$last"
