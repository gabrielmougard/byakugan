#!/bin/sh
# Re-vendors warc_ffi's crates into ../vendor/rust (cargo vendor, untouched)
# and writes ../vendor/dune: dune leaves out of its sandbox the directories
# whose name starts with "." or "_", which some crates have (libc's _types/,
# CI files in .github/), and cargo checks every vendored file. Needs the
# network; builds never do.
#   sh stubs/vendor-rust.sh     (from src/)
set -eu
cd "$(dirname "$0")/../vendor"
rm -rf rust
cargo vendor --versioned-dirs --locked --manifest-path ../stubs/warc_ffi/Cargo.toml rust >/dev/null
{
  echo "; Written by src/stubs/vendor-rust.sh: the directories of the vendored"
  echo "; crates dune would otherwise leave out (names starting with . or _)."
  find rust -mindepth 2 -type d \( -name '.*' -o -name '_*' \) | sort | while read -r d; do
    echo "(subdir $(dirname "$d") (dirs :standard $(basename "$d")))"
  done
} > dune
