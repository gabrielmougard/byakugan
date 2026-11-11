#!/bin/sh
# Builds the C ABI over FastWARC (warc_ffi/) offline, from the crates in
# vendor/rust (cargo vendor --versioned-dirs), into libwarc_ffi.a, the
# dllwarc_ffi.so dune expects beside it, and warc_libs.sexp: the system
# libraries the Rust static library needs.
#   build-warc.sh <warc_ffi dir>
set -eu
crate=$1
target=$(pwd)/target
# The vendored crates, never the network nor ~/.cargo (dune does not copy a
# .cargo/ directory into its sandbox, so the replacement is given here).
vendor=$(cd "$crate/../../vendor/rust" && pwd)
cargo() {
  command cargo --config 'source.crates-io.replace-with="vendored"' --config "source.vendored.directory=\"$vendor\"" "$@"
}
# zstd-sys compiles C: on macOS, for the deployment target OCaml links for.
[ "$(uname)" = Darwin ] && export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-$(sw_vers -productVersion | cut -d. -f1).0}"
CARGO_TARGET_DIR=$target cargo build --offline --locked --release --quiet --manifest-path "$crate/Cargo.toml"
cp "$target/release/libwarc_ffi.a" libwarc_ffi.a
for so in "$target/release/libwarc_ffi.so" "$target/release/libwarc_ffi.dylib"; do
  [ -f "$so" ] && cp "$so" dllwarc_ffi.so
done
libs=$(CARGO_TARGET_DIR=$target cargo rustc --offline --locked --release --quiet --lib --crate-type staticlib \
  --manifest-path "$crate/Cargo.toml" -- --print native-static-libs 2>&1 |
  sed -n 's/.*native-static-libs: //p' | tail -n 1)
printf '(%s)' "$libs" > warc_libs.sexp
