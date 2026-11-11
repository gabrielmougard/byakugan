# lexbor (vendored subset)

HTML5 parser used by `src/lib/html.ml` through `src/stubs/lexbor_stubs.c`.

- Upstream: https://github.com/lexbor/lexbor
- Version: v3.0.1, commit `7e278c0188489bfce6b71ced0cc900cbb31e6244`
- License: Apache-2.0 (`LICENSE`, `NOTICE`)

Only the modules the HTML parser needs are copied, unmodified, from
`source/lexbor/`:

- `core`
- `dom`
- `html`
- `ns`
- `tag`
- `ports/posix`

`src/stubs/build-lexbor.sh` compiles them into one static archive with `-DLEXBOR_STATIC`, the definition lexbor's own CMake build uses for its static library.

To update, copy the same directories from a newer release and change the version above.
