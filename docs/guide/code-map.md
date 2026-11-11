---
slug: /guide/code-map
sidebar_label: Code map
---

# Code map

Everything under `src/` is one dune project. `lib/` is pure OCaml and safe on any domain; `serve/` and the executables add Lwt, libcurl, Cohttp and Domainslib.

## `src/lib/`: the framework (library `contextual`)

| Module | Role |
|---|---|
| `text.ml` | words through BERT's normaliser in C (Unicode lowercase, accents stripped, Unicode punctuation and spaces as separators), whole-word matching, sentence split, quote clipping (UTF-8 safe) |
| `html.ml` | `parse_html`: HTML pages through lexbor (the stubs below), as tokens; `tokenize`: a tolerant tag scanner for XML (sitemaps, RSL) |
| `ontology.ml` | IAB TSV loader, lexicon, ancestors and paths, Wu-Palmer similarity, O(tokens) n-gram term hits |
| `doc.ml` | `Doc.t` with lazy content: meta, Open Graph, JSON-LD, breadcrumbs and media; segments in DOM order with a `main` flag and their `<article>`; ad containers by element id; sitemap parsing; the weighted zones T0/T1 read |
| `label.ml` | evidence records, the Accumulate/Override update with freezing, ancestor closure, explanations |
| `vec.ml` | dot, cosine, and the toy static embedder the tests use |
| `siglip.ml` | SigLIP 2 through the C runtime below: load the vision tower, embed an image (JPEG, PNG, WebP), the taxonomy prototypes, zero-shot |
| `model2vec.ml` | Model2Vec through the C runtime below: load a GGUF model, token ids, batch embedding, dot products with ggml |
| `tier.ml` | tier constructors: T0 URL + hints, T1 lexical, T2 dense, T3 video text and T3 images; and T4, with its shortlist, prompt, JSON parsing, quote check (`judge`) and dropping of labels outside the shortlist |
| `cascade.ml` | presets, `value_budget`, the run loop (stops when settled or out of budget), traces |
| `matcher.ml` | creative and page profiles; hard rules with reasons (blocks, suitability, targets); the soft score |
| `slot.ml` | slot context: page and nearby blocks blended by format; suitability as the worst co-visible case; `of_wire`: the blocks a bid request names, matched to the profile's by SimHash |
| `refresh.ml` | refresh state and schedule, SimHash (64-bit, over words), hubs |
| `warc.ml` | raw pages as WARC/1.1 through FastWARC (the stubs below): a record per fetch, read back alone, or a whole file for replay |
| `replay.ml` | an archived page made safe to show: headers forbidding scripts, `<base>`, no meta refresh, lazy images unwrapped |
| `url_key.ml` | the bidder's URL normalisation (DoubleVerify IQC rules over Go's `net/url.Parse`), byte for byte; `serving_key` = `contextual:<sha256>` |
| `store.ml` | the lab's page key (`Url_key.normalize`) and page → section → site backoff |
| `zstd.ml` | zstd compression of stored profiles (the stubs below) |
| `robots.ml` | robots.txt through Google's reference matcher (the stubs below): `parse` once, then `allowed` / `decision` (with the deciding line) per URL; group-scoped Crawl-delay, Sitemaps, `content_usage` (aipref), `signals` (Content Signals), `licenses` (RSL) |
| `ai_use.ml` | the T4 gate: aipref vocabulary over an RFC 9651 dictionary parser, Content Signals, RSL document parsing and evaluation, Link header and `<link>` discovery; `t4` combines them, most restrictive first |
| `profile.ml` | stored profile (levels, laid-out segments with their SimHash and story, ad slots, story labels), estimated block geometry, measured geometry, JSON in and out; `serving`: the protobuf `PageProfile` the bidder would read, with its labelled blocks and ad slots; `gpid_slot` |
| `engine.ml` | the full taxonomy, two Model2Vec models (English and multilingual, routed by the page's language) and the lexicon wired together: tiers per call and all four levels; the T4 dry run; segment labels in one batch per page; a creative from a prompt; slot odds and the best slot |

## `src/serve/`: shared by the executables (library `serve`)

| Module | Role |
|---|---|
| `web.ml` | Cohttp JSON helpers; `detach` (Domainslib job → Lwt promise) and `parallel` (`parallel_for` map); `fetch`, GET or POST through `curl_lwt` |
| `openrouter.ml` | API key from the environment or `.env`; model lookup with prices; reasoning switched to its cheapest setting; chat completion with `data_collection: deny` and cost reporting |
| `valkey.ml` | a small RESP2 client on Lwt: `valkey://host:port` or `sentinel://host:port/name`, which finds the primary through Sentinel and retries through a failover; AUTH and TLS from `VALKEY_PASSWORD` / `VALKEY_CA_CERT` |
| `archive.ml` | the crawler's raw pages: per-replica WARC files rolled and capped, the Valkey index of each page's latest record, reading one back, the latest record of each URL for replay |
| `lab.ml` | the shared state in Valkey: key layout, and the Lua scripts that queue (busiest pages first), claim (with politeness), release and reap; profiles (zstd), the serving key, summaries, stats, robots.txt and license caches |

## `src/stubs/`, `src/vendor/`, `src/protos/`: native code and the profile schema

| Path | Role |
|---|---|
| `src/vendor/robotstxt/` | Google's `robots.cc` / `robots.h` (unmodified, pinned commit, checksums) and apeschar's Abseil shims; see its README |
| `src/stubs/robots_stubs.cc` | our adapter: parses once, records the rules that apply to our agent with their group state, replays them into Google's matcher per URL; keeps other directives with their scope |
| `src/stubs/compat/absl/container/fixed_array.h` | inline-storage `FixedArray` shadowing the vendored `std::vector` shim |
| `src/vendor/lexbor/` | lexbor v3.0.1, the six modules an HTML5 parser needs, unmodified; see its README |
| `src/stubs/build-lexbor.sh` | compiles them into one archive, objects named after their paths (lexbor reuses file names) |
| `src/stubs/lexbor_stubs.c` | parses with the OCaml runtime released, walks the tree once, returns a flat event buffer |
| `src/stubs/zstd_stubs.c` | one-shot zstd compress / decompress (system `libzstd`) |
| `src/vendor/rust/` | FastWARC 2.0.1 (chatnoir-eu/chatnoir-resiliparse, Apache-2.0) and its 63 crates, `cargo vendor --versioned-dirs`, unmodified; `src/stubs/vendor-rust.sh` re-vendors them and writes `src/vendor/dune`, which lets dune copy the crates' `_`- and `.`-prefixed directories into its sandbox |
| `src/stubs/warc_ffi/` | the C ABI over FastWARC (Rust, `staticlib`): a `response` record as one gzip member, one record read back, a file iterated; built by `build-warc.sh` from the vendored crates only (`cargo --config` source replacement, offline) |
| `src/stubs/warc_stubs.c` | OCaml bindings for it, runtime released during compression and reading |
| `src/vendor/ggml/` | ggml v0.29.0, CPU backend only, unmodified; see its README |
| `src/stubs/build-ggml.sh` | builds it with its own CMake: static, no host-specific instructions, one merged archive |
| `src/stubs/m2v.h`, `m2v_text.c`, `m2v_model.c` | the Model2Vec runtime: GGUF loading, the WordPiece and Unigram tokenizers (Hugging Face's ids exactly), embedding, `mul_mat` similarity |
| `src/stubs/m2v_tables.h`, `tools/gen_m2v_tables.py` | Unicode tables taken from Hugging Face `tokenizers` code point by code point, and UAX #29 graphemes |
| `src/stubs/tools/m2v_fixtures.py` | expected token ids for `src/test/test_m2v.ml` |
| `src/stubs/sig.h`, `sig.c`, `sig_stubs.c` | the SigLIP 2 runtime: decoding with libjpeg-turbo, libpng and libwebp, NaFlex preprocessing (PyTorch's uint8 resize, exactly), the vision tower and its pooling head on ggml |
| `src/stubs/tools/siglip_prototypes.py`, `siglip_fixtures.py` | the taxonomy's SigLIP 2 text embeddings (`src/data/siglip2_prototypes.gguf`), and the expected image embeddings for `src/test/test_siglip.ml`, both from Hugging Face |
| `src/stubs/dune` | libraries `robotstxt_native`, `lexbor_native`, `zstd_native`, `m2v_native` (with ggml), `warc_native` (with FastWARC), linked by `contextual` |
| `src/protos/contextual/v1/profile.proto` | `PageProfile`, what the bidder reads; `ocaml-protoc-plugin` generates library `protos` at build time |

Why these designs and how they perform: [robots.txt matching and the AI-use gate](../../study/robots_matcher.md), [HTML extraction with lexbor](../../study/html_parser.md), [Model2Vec in C, on ggml](../../study/model2vec_c.md), [images with SigLIP 2, in C](../../study/siglip2_images.md).

## Executables

| Path | Role |
|---|---|
| `src/crawler/crawler.ml` | crawl daemon: workers that claim from the shared frontier, robots.txt, sitemap discovery, images fetched and embedded for T3, oEmbed, the AI-use gate, the three-phase T4, housekeeping (heartbeat, reaping), admin API ([HTTP APIs](api.md)) |
| `src/online/online.ml` | online server: incremental profile reload from Valkey, page and placement APIs (measured geometry), outreach, the archived page (`/replay`), static front end, crawler proxy |
| `src/frontend/Replay.re` | the Page view: the archived page in a sandboxed frame, segments aligned to its elements and measured, overlays (block scores, slots, context boundary) |
| `sdks/prebid/` | the Prebid.js real-time data module and its core library (words, SimHash, the blocks around a slot) |
| `deploy/context_fit.example.py` | engagement against site-context match per format, from your delivery logs and the site profiles ([context boundary §8](../../study/context_boundary.md#8-does-matching-context-pay-a-first-look-at-site-grain)) |
| `src/t4eval/t4eval.ml` | benchmark of T4 models against references ([T4 model choice](../../study/t4_models.md)) |
| `src/bench/robots_bench.ml` | robots.txt matchers timed and compared on a directory of real robots.txt files; checks the adapter against Google's one-shot matcher ([study](../../study/robots_matcher.md)) |
| `src/bench/html_bench.ml` | the tag scanner and lexbor timed and compared on a directory of real pages ([study](../../study/html_parser.md)) |
| `src/sdkfixtures/sdkfixtures.ml` | the SDKs' fixtures: for Go (`sdks/go/contextual/testdata`) Redis keys, section and site keys, the matcher's `refusal` on 3,000 served profiles, `Slot.context` at bid time on 2,000 and GPID slots on 1,000; for the Prebid module (`sdks/prebid/test`) words and SimHashes |
| `src/m2vgguf/m2vgguf.ml` | a Model2Vec model from Hugging Face (`tokenizer.json`, `model.safetensors`, `config.json`) as one GGUF file; refuses pipelines the C runtime does not reproduce |
| `src/lexgen/lexgen.ml` | lexicon candidates (LLM terms in five languages plus Wikidata aliases, per taxonomy node) and their LLM review per language (`--review`) |
| `src/metacov/metacov.ml` | how much metadata publishers give a crawler: robots.txt, sitemaps read as the crawler reads them, JSON-LD, Open Graph and meta tags on a golden sample's pages; no T4 |
| `src/test/test_contextual.ml` | the asserted scenarios ([Quick start](quickstart.md#build-and-test)) |
| `src/test/test_m2v.ml` | the C tokenizers against Hugging Face's token ids, when the GGUF models are present |
| `src/test/test_siglip.ml` | the C SigLIP 2 runtime against Hugging Face on the images in `src/test/images/` (three CC0 photos and derived formats), and a zero-shot sanity check |
| `src/siggguf/siggguf.ml` | SigLIP 2's vision tower from Hugging Face `model.safetensors` as one GGUF file (Q/K/V fused, matrices Q8_0) |
| `src/bench/image_bench.ml` | SigLIP 2 on publishers' images (a golden sample's pages, robots.txt honoured), and embedding time with `--time` ([study](../../study/siglip2_images.md)) |
| `src/frontend/Api.re` | ReasonReact front end: records mirroring the server's JSON (Melange compiles them to plain JS objects), and fetch that fails on HTTP errors |
| `src/frontend/Browser.re`, `Glossary.re`, `Ui.re` | typed browser APIs (hash, keys, storage, scrolling); every "?" explanation; the shared kit: viewport-fixed tooltip, toasts, chips, bars, cards, tabs, slot bars, page and placement hooks |
| `src/frontend/Overview.re`, `Pages.re`, `Simulate.re`, `Golden.re`, `Crawler.re`, `Main.re` | the five views and the hash-routed shell around them ([Placement Lab](placement-lab.md#what-the-front-end-shows)) |
| `src/fetch-data.sh`, `src/convert-models.sh` | download the taxonomy and the two Model2Vec models, then write their GGUF files |

## Profile JSON

One zstd-compressed JSON value per URL in Valkey at `ctx:profile:<normalised URL>`, 7.6× smaller than plain (70 KB → 9.3 KB on average). The `ctx:profiles` sorted set indexes them by `fetched_at`, which is how the online replicas spot new or re-crawled pages.

```json
{
  "url": "https://...", "key": "site.example/path", "site": "site.example",
  "title": "...", "fetched_at": 1793873484.6, "keywords": ["..."],
  "levels": [
    {"preset": "deep", "ran": ["t0-url+hints", "t1-lexical", "t2-dense", "t4-llm"],
     "spent": 0.000273, "stop": "no more tiers",
     "labels": [{"id": "533", "score": 0.99,
                 "evidence": [{"tier": "t4", "zone": "llm z-ai/glm-5.3-flash",
                               "quote": "...", "why": "quote verified on page", "weight": 0.99}]}]}
  ],
  "segments": [{"tag": "p", "text": "...", "main": true, "top": 3.4, "height": 0.21,
                "labels": [{"id": "216", "score": 0.91}]}],
  "t4_gate": "denied: RSL https://theguardian.com/license.xml: ai-input is prohibited"
}
```

Level labels include ancestors, added by the hierarchy with tier `hierarchy`. Segment labels keep the top 3 topics plus every Sensitive Topics label above 0.3, because suitability is never cut.

## The serving profile

What the bidder would read sits next to it, at `contextual:<sha256(normalised URL)>` with a 30-day expiry. The URL normalisation is the bidder's own. Each value is a protobuf `PageProfile` (`src/protos/contextual/v1/profile.proto`), 252 bytes on average:
- the `rich` level's labels, at most 20, highest score first;
- at most 20 keywords;
- `fetched_at`;
- the preset name.

To read one locally (`--raw` adds a newline, which the Python step strips):

```bash
valkey-cli --raw GET contextual:<sha256> \
  | python3 -c 'import sys; sys.stdout.buffer.write(sys.stdin.buffer.read()[:-1])' \
  | protoc --decode=contextual.v1.PageProfile -I src/protos contextual/v1/profile.proto
```

## Deliberate shortcuts

Every simplification with a known limit carries a `shortcut:` comment naming the limit and the upgrade path:

```bash
grep -rn "shortcut:" src --include=*.ml --include=*.re
```

The [roadmap](../../ROADMAP.md#placement-and-context-boundary) lists what replaces them.
