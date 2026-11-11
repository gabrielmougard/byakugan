#!/usr/bin/env bash
# Queue the pages the bidder saw the most bid requests for, busiest first:
#   deploy/traffic.example.sh
# Copy to deploy/traffic.sh (gitignored) and write pages() against your own
# logs, wherever they live. CRAWLER is the crawl daemon, directly or through
# the online server's proxy.
set -euo pipefail

crawler=${CRAWLER:-http://localhost:8081}

# One line per page, "url<TAB>bid requests per day", busiest first; a missing
# count counts 1. Variants of one page (tracking parameters, www.) may come
# separately: the crawler adds them up.
#   https://www.example.com/news/a-story	5120
#   https://www.example.com/sport/a-match?utm_source=x	870
pages() {
  echo "pages(): print url<TAB>requests lines from your bid logs" >&2
  exit 1
}

body=$(pages)
curl -sS --fail --data-binary @- "$crawler/traffic" <<< "$body"
echo
