#!/bin/sh
# Compiles the vendored lexbor modules an HTML parser needs into liblexbor.a,
# plus the dlllexbor.so dune expects beside it. Objects are named after their
# paths because lexbor reuses file names across directories (error.c, ...).
#   build-lexbor.sh <lexbor source dir> <C compiler and flags...>
set -eu
src=$1
shift
cc="$*"

sources=$(cd "$src" && find lexbor/core lexbor/dom lexbor/html lexbor/ns lexbor/tag lexbor/ports/posix -name '*.c' | sort)
pids=
for f in $sources; do
  $cc -c -O2 -w -DLEXBOR_STATIC -I"$src" "$src/$f" -o "$(echo "$f" | tr / _).o" &
  pids="$pids $!"
done
for pid in $pids; do wait "$pid"; done

objs=$(for f in $sources; do echo "$f" | tr / _; done | sed 's/$/.o/')
rm -f liblexbor.a
ar rcs liblexbor.a $objs
$cc -shared -o dlllexbor.so $objs
