#!/usr/bin/env bash
# A golden-set sample, from your own traffic:
#   deploy/golden.example.sh > sample.tsv
# Copy to deploy/golden.sh (gitignored) and write sample() against your own
# logs. Your sample goes in src/data/golden_sample.tsv (gitignored, with its
# labels in golden_labels.tsv); src/data/golden_sample.example.tsv and
# golden_labels.example.tsv show the format with made-up pages.
#
# Pages drawn per publisher in proportion to their traffic make the golden
# set look like what the bidder sees; a draw that hashes the URL makes it
# reproducible. Drop query strings and fragments: they carry click and
# visitor ids, and the same page with other parameters would be drawn twice.
#
# Queue it with
#   curl --data-binary @sample.tsv "$CRAWLER/traffic"
# then judge the pages in the lab (Golden set view) or with
# deploy/adjudicate.py.
set -euo pipefail

# One URL per line:
#   https://www.example.com/news/a-story
#   https://www.example.org/recipes/a-recipe
sample() {
  echo "sample(): print one URL per line, drawn from your traffic" >&2
  exit 1
}

sample
