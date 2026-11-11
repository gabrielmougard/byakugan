#!/usr/bin/env bash
# Compile only some sections, with the full preamble and every .bib, into
# .check/<first section>/check.pdf, so a section builds while others are
# still being written:
#   ./check.sh 05-cascade 09-evaluation
# References to sections not included print as ?? and are not errors.
set -euo pipefail
cd "$(dirname "$0")"
[ $# -gt 0 ] || { echo "usage: $0 SECTION..." >&2; exit 1; }
dir=.check/$1
mkdir -p "$dir"
{
  echo '\documentclass[11pt]{article}'
  echo '\input{preamble}'
  echo '\begin{document}'
  for s in "$@"; do echo "\\input{sections/$s}"; done
  echo '\bibliographystyle{plainnat}'
  echo '\bibliography{refs-related,refs-cascade,refs-boundary}'
  echo '\end{document}'
} > "check-$1.tex"
trap 'rm -f "check-$1.tex"' EXIT
tectonic -X compile --outdir "$dir" "check-$1.tex"
