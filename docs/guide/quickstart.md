---
slug: /guide/quickstart
sidebar_label: Quick start
---

# Quick start

## Prerequisites

| Tool | Version used | Why |
|---|---|---|
| C and C++17 compiler | Apple clang 17 | Google's robots.txt matcher and lexbor (`src/vendor`, `src/stubs`) |
| `protoc` | 36 (Homebrew `protobuf`) | generates OCaml from `src/protos/` |
| CMake | 3.14 or newer | builds the vendored ggml |
| libzstd, pkg-config | system (Homebrew `zstd`) | profile compression |
| libjpeg-turbo, libpng, libwebp | system (Homebrew `jpeg-turbo libpng webp`) | decoding images for T3 |
| opam switch with OCaml | 5.5.1 | Domains, effects, Domainslib |
| dune | 3.8 or newer (3.24 tested) | builds OCaml, Reason and Melange |
| libcurl | system | `curl_lwt` binds it |
| Node.js | 20 or newer (23 tested) | esbuild bundle and this documentation site |
| Docker | Desktop 28 tested | a local Valkey, and the images in `deploy/` |

## Install once

```bash
brew install protobuf zstd pkg-config cmake jpeg-turbo libpng webp
opam install domainslib cohttp-lwt-unix curl_lwt digestif ocaml-protoc-plugin tls-lwt melange reason reason-react reason-react-ppx
npm --prefix src/frontend install
src/fetch-data.sh
```

`fetch-data.sh` downloads the three GGUF files the engine loads into `src/data/`, from the repository's GitHub release `models-v1`, and checks each against its SHA-256:
- two Model2Vec models (minishlab, MIT), as Q8_0 tables with their tokenizers: potion-base-32M for English pages (34 MB) and potion-multilingual-128M for the rest (143 MB);
- SigLIP 2 base's vision tower (Google, Apache-2.0), as Q8_0 (95 MB), at the revision the committed `siglip2_prototypes.gguf` was made from.

The IAB Content Taxonomy 3.1 is in git. `src/data/NOTICE` gives each file's source, licence and changes.

To build the GGUF files yourself, or for a Docker build, which converts them from the originals, fetch those from Hugging Face (about 2.1 GB) and convert them:

```bash
src/fetch-data.sh --from-source
eval $(opam env) && src/convert-models.sh
```

That is the only step that downloads the originals: Docker builds copy them from `src/data/` (`--build-context models=src/data`). Without the release, plain `fetch-data.sh` falls back to `--from-source`.

T4 is optional. To use it, put `OPENROUTER_API_KEY=...` in `src/.env`; the file is git-ignored.

## Build and test

```bash
dune build --root src @default @frontend
npm --prefix src/frontend run build
dune test --root src --force
```

The test suite doubles as a demo, and every scenario is asserted:

| Scenario | What it shows |
|---|---|
| News-sitemap entry, `zero_fetch` | settled from the URL and sitemap hints alone; the page is **never fetched** (lazy content asserted) |
| Match report with no lexicon term, `standard` | T0/T1 find nothing; T2 static embeddings close the vocabulary gap (Soccer 0.99); nav and footer links ignored; every quote is on the page |
| Video page, no transcript, `rich` | T3 text settles it; `og:video` and `VideoObject` merged so it is paid for once; T4 not called |
| Mixed-topic page, `deep` | the LLM reranks a shortlist, overrides T2's over-eager "Cooking", drops an invented ID and halves an unverifiable quote |
| Crime news, `standard` | T0+T1 settle Crime plus two Sensitive Topics; every creative is blocked with a suitability reason |
| Matching | ranked by readable reasons; an ancestor block and a targeting miss are both explained |
| Slot context | on one food guide, a scroll-through ad after the recipe section picks cookware while a fullscreen one picks beer; a co-visible "most read" crime headline blocks both, and moving it off-screen lifts the block |
| Store backoff | an unseen article inherits its section profile |
| The bidder's URL normalisation | 111 cases whose expected output the bidder's Go code wrote (`src/test/url_key.tsv`), and the `contextual:<sha256>` key |
| HTML5 parsing | implied end tags, character references, a `>` in an attribute, no-break spaces, a `<noscript>` pixel, formatting rebuilt as a browser does |
| Model2Vec (`test_m2v`) | both models' C tokenizers give Hugging Face's ids on 722 synthetic texts each; embeddings are unit length. Skipped when the GGUF files are missing |
| Value budget | a hot page affords T4; a long-tail page does not |
| robots.txt | through Google's matcher: our group beats `*`, the longest pattern wins, Allow wins ties, the deciding line is reported |
| AI-use gate | Content-Usage rules scoped to our group and matched by longest path; License scoping, including a License after another bot's group; RFC 9651 dictionary edge cases; Content Signals; RSL narrowest scope, prohibition and payment rules |
| Segments | boilerplate is kept for adjacency checks and flagged as not main |
| Profile JSON | a profile survives the store round trip and zstd; the serving protobuf decodes back |

The tests use a small fixture taxonomy and a toy embedding table, so they need neither `src/data/` nor the network.

The robots.txt benchmark and equivalence check runs on any directory of robots.txt files named `<host>.txt`:

```bash
dune build --root src --profile release ./bench/robots_bench.exe
src/_build/default/bench/robots_bench.exe path/to/robots-files
```

## Run the Placement Lab

The crawler and the online server share their state through Valkey:

```bash
docker run -d --name contextual-valkey -p 6379:6379 valkey/valkey:9.1.3
cd src
./_build/default/crawler/crawler.exe --site https://www.bbcgoodfood.com --llm z-ai/glm-5.3-flash   # :8081
./_build/default/online/online.exe                                                                # :8080
```

1. Open http://localhost:8080.
2. Crawl a page or a site from the left panel.
3. Pick a page.
4. Describe a creative in words.
5. Press **Simulate placement**.

The page shows a coloured bar between blocks where a slot could go, labelled P = fit × reach. The right panel shows how many crawled pages the creative reaches. [Placement Lab](placement-lab.md) explains what you see.

Drop `--llm` to run without T4. `--site` is optional: crawl orders can also come from the UI or [the API](api.md). A second crawler (`--port 8082`) on the same Valkey shares the work and the politeness schedule.

## Build this documentation

```bash
npm --prefix docs install --include=optional
npm --prefix docs start          # http://localhost:3000, live reload
npm --prefix docs run build      # static site in docs/build, fails on broken links
```

On macOS, `--include=optional` makes sure `fsevents` is installed. Without it, the dev server's file watcher needs one file handle per watched path, and it dies with `EMFILE: too many open files` under the default limit of 256.

The site renders `README.md`, `ROADMAP.md` and `study/` in place; only the guide pages live under `docs/guide/`.
