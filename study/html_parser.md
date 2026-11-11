# HTML extraction with lexbor

**Question.** Should page extraction move from our tolerant tag scanner (`src/lib/html.ml`) to [lexbor](https://github.com/lexbor/lexbor), a C HTML5 parser, vendored with OCaml stubs and flattened into a compact form? Is it faster?

**Short answer.**
- **Yes. It is faster and more correct.**
- **Faster:** on 36 real article pages (16.4 MB), tokens come out 3.3× faster (141 → 480 MB/s). Tokens plus `Doc` extraction run 2.6× faster (124 → 323 MB/s), about 1.4 ms per page.
- **More correct.** lexbor builds the tree a browser builds:
  - implied end tags close;
  - every character reference decodes (`&copy;`, not just six of them);
  - a `>` inside an attribute value no longer leaks into the text;
  - `<noscript>` and `<template>` content stays out, as in a browser running JavaScript.
- **What changed on our pages:**
  - titles are identical on all 36 pages;
  - 15 pages lose one boilerplate segment, a no-break space alone in a list item;
  - 5 pages gain one media item, a "Play video" icon. Its `src` is an SVG data URI holding a `>`, which cut the scanner's tag short;
  - one page drops 53 segments, among them 37 `"."` paragraphs that browsers do not render;
  - one page has four segments fixed: leaked markup (`"> Partners"`) and an undecoded `&copy;`.
- **XML keeps the scanner.** Sitemaps and RSL documents are XML, not HTML. An HTML5 parser would rewrite them, so `Html.tokenize` stays for them.

Measured 2026-11-05 on an Apple M4. To rerun, build with `dune build --root src --profile release ./bench/html_bench.exe`, then run `src/_build/default/bench/html_bench.exe DIR`, where DIR holds `*.html` pages.

## 1. What is in the repo now

| Path | What |
|---|---|
| `src/vendor/lexbor/` | lexbor v3.0.1, unmodified. Only the six modules an HTML parser needs: `core`, `dom`, `html`, `ns`, `tag`, `ports/posix`. That is 163 C files, 3 MB. Provenance is in its README |
| `src/stubs/build-lexbor.sh` | Compiles them into `liblexbor.a` with `-DLEXBOR_STATIC` (the define lexbor's own CMake uses), in parallel, about 5 s |
| `src/stubs/lexbor_stubs.c` | The adapter: parse, walk the tree once, return one flat event buffer |
| `src/lib/html.ml` | `parse_html` decodes that buffer into the same `Html.token` list the scanner produces, so `Doc` is unchanged. `tokenize` stays for XML |
| `src/bench/html_bench.ml` | The benchmark and the per-page comparison |

**Why a build script and not dune's `foreign_stubs`.** lexbor reuses file names across directories: `html/tree/error.c` and `html/tokenizer/error.c`, `dom/interfaces/element.c` and `html/interfaces/element.c`, and others. dune's foreign stubs name objects after their basenames, so these collide. The script names each object after its path instead, and builds one archive. Inside one archive, the linker resolves the modules' references to each other in any order.

## 2. The flat form

The C side parses with the OCaml runtime released, so other domains keep running. It walks the tree depth first without recursion, because crawled pages can nest arbitrarily deep. Only one OCaml string crosses the boundary:

| Event | Layout |
|---|---|
| element start | `'o'` name, attribute count, (attribute, value)* |
| element end | `'c'` (OCaml keeps the open names on a stack) |
| text | `'t'` text |
| script | `'s'` attribute count, (attribute, value)*, body |

Strings are a 32-bit little-endian length followed by the bytes. Three things keep it compact:
- **Attributes:** only the eleven the extractor reads are kept: `href rel type src alt title width height name property content`.
- **Styles:** `<style>` elements are dropped.
- **No-break spaces:** U+00A0 (what `&nbsp;` decodes to) becomes a plain space. Otherwise `Text` would glue the words on either side together, because bytes ≥ 0x80 count as word characters.

## 3. Benchmark

The corpus is 36 pages from the Guardian, Esquire, Sky Sports and BBC Good Food, the pages in the lab's local store. Times are the sum over all pages, each page repeated until 0.3 s.

| | Scanner | lexbor |
|---|---|---|
| Tokens, ms per page | 3.15 | 0.95 |
| Tokens, MB/s | 144 | 480 |
| Tokens + `Doc`, ms per page | 3.66 | 1.41 |
| Tokens + `Doc`, MB/s | 124 | 323 |

**Where the time goes now.** About a third of the 1.4 ms is building OCaml tokens and running `Doc`. A further gain would come from extracting segments in C directly. That is not worth it yet: classification costs far more per page than extraction.

## 4. Caveats

- **Charset.** Pages are still handed over as bytes and read as UTF-8. lexbor's encoding module (not vendored) could honour `<meta charset>` for Latin-1 pages.
- **Unicode case.** Fixed on 2026-11-08: lexicon matching now goes through BERT's normaliser (Unicode lowercase, accents stripped), so "État" in a page matches the term "état".
- **Not yet main-content extraction.** lexbor gives the right tree. Deciding which part of it is the article is still the `nav`/`aside`/`footer` skip list in `Doc`. Link- and text-density scoring is the next step ([roadmap](../ROADMAP.md#classification-quality)).
