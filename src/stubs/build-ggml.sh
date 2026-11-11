#!/bin/sh
# Builds the vendored ggml (src/vendor/ggml) with its own CMake: CPU backend
# only, static, no host-specific instructions. Its three archives are merged
# into one libggml.a, so the link order between them cannot matter.
#   build-ggml.sh <ggml source dir>
set -eu
src=$1
build=ggml-build

cmake -S "$src" -B "$build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
  -DGGML_METAL=OFF -DGGML_BLAS=OFF -DGGML_ACCELERATE=OFF \
  -DGGML_BUILD_TESTS=OFF -DGGML_BUILD_EXAMPLES=OFF > ggml-build.log 2>&1 \
  || { cat ggml-build.log >&2; exit 1; }
cmake --build "$build" -j "$(getconf _NPROCESSORS_ONLN)" >> ggml-build.log 2>&1 \
  || { cat ggml-build.log >&2; exit 1; }

libs="$build/src/libggml.a $build/src/libggml-cpu.a $build/src/libggml-base.a"
rm -f libggml.a
if [ "$(uname)" = Darwin ]; then
  libtool -static -o libggml.a $libs 2>/dev/null
else
  { echo "create libggml.a"; for l in $libs; do echo "addlib $l"; done; echo save; echo end; } | ar -M
fi
