# Vendored: Google's robots.txt parser and matcher

Third-party sources, kept unmodified. Our OCaml adapter lives in `src/stubs/`.

| Files | Origin | License |
|---|---|---|
| `robots.cc`, `robots.h` | [google/robotstxt](https://github.com/google/robotstxt) at commit `22b355ff855419e6a3ff8ff09c0ad7fdb17116f9` | Apache-2.0 |
| `compat/absl/**` | header-only shims for the slice of Abseil those files use, from [apeschar/robotstxt-ocaml](https://github.com/apeschar/robotstxt-ocaml) at commit `9b8df4a` (2026-07-22) | Apache-2.0 |
| `LICENSE` | Apache License 2.0, as shipped by apeschar/robotstxt-ocaml | |

SHA-256, checked on 2026-11-05 against both upstreams:
- `robots.cc`: `d05a7fa74c0e8b9fc440d15f4c3ae9a80873c0d950e569de2926303fd75ed473`
- `robots.h`: `912f3a5c6821f8a9a97269f9598b7f29ac1edf1ee20e173f1dd2d9ca48fb0bd5`

The OCaml wrapper and C++ stubs of apeschar/robotstxt-ocaml are not used. Its stubs call `AllowedByRobots`, which re-tokenises the whole robots.txt for every URL. `src/stubs/robots_stubs.cc` parses once and replays the parsed directives instead; see the comment at the top of that file.

To update:
1. Replace the files.
2. Update the commits and checksums above.
3. Run `dune test --root src --force` and the robots benchmark (`src/bench`). The benchmark also checks that every decision matches Google's one-shot matcher.
