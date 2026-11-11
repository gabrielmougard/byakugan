---
slug: /guide/configuration
sidebar_label: Configuration
---

# Configuration

Every command takes paths relative to where it runs. The defaults assume you run it from `src/`.

## Crawl daemon: `crawler.exe [options] [url ...]`

| Flag | Default | Meaning |
|---|---|---|
| `--port` | 8081 | admin API port |
| `--data` | `data` | taxonomy, lexicon and embedding model |
| `--valkey` | `valkey://localhost:6379` | shared state: `valkey://host:port`, or `sentinel://host:port[,host:port]/name` to follow the primary through failovers |
| `--workers` | 8 | concurrent pages per replica (the chart uses 4 × 3 replicas) |
| `--site URL` | none | discover a site through its sitemaps at start (repeatable) |
| `--llm MODEL` | none | enables T4 with this OpenRouter model id, e.g. `z-ai/glm-5.3-flash` |
| `--env FILE` | `.env` | file holding `OPENROUTER_API_KEY=...`; the environment variable wins if set |
| `--image-patches N` | 256 | SigLIP 2 patch budget per image for T3; fewer is faster and coarser (128 is the smallest it was trained at, the chart's value for the Pi); 0 turns the image tier off |
| `--warc DIR` | `store/warc` | this replica's raw pages, as WARC files (`<replica>-<seq>.warc.gz`, rolled at 256 MiB) |
| `--warc-cap GIB` | 8 | the oldest of this replica's WARC files are deleted beyond this |
| `--audit` | off | also store the `deep` level (every tier, nothing settles, its own T4 call): for golden sets and audits |
| `url ...` | none | pages to queue at start |

Fixed politeness:
- one request per host per max(1 s, Crawl-delay);
- 20 s timeout per fetch, 10 s to connect;
- 5 MB cap per page;
- at most 5 redirects.

The user agent is `ContextBot/0.1 (contextual research prototype)`. robots.txt is honoured as follows:

| robots.txt response | Treated as |
|---|---|
| missing (4xx) | allow all |
| 5xx, or unreachable | disallow all |

## Valkey connection: environment

The crawler, online server and `t4eval` read two variables. Both apply to every connection, including those to Sentinel.

| Variable | Meaning |
|---|---|
| `VALKEY_PASSWORD` | sent with `AUTH` |
| `VALKEY_CA_CERT` | a PEM file: connect over TLS and verify the server against it |

Locally both are unset: plain TCP, no password. The chart sets both from the `valkey-auth` and `valkey-tls` Secrets ([Deploy](deploy.md#password-and-tls)).

## Online server: `online.exe [options]`

| Flag | Default | Meaning |
|---|---|---|
| `--port` | 8080 | API and front end |
| `--data` | `data` | same data as the crawler, used to turn prompts into creatives |
| `--valkey` | `valkey://localhost:6379` | where profiles are read, every 3 s; same forms as the crawler |
| `--web` | `frontend` | holds `index.html`, `style.css` and `dist/app.js` |
| `--crawler` | `http://localhost:8081` | where `/crawler/*` is proxied |
| `--replicas URL` | `--crawler` | one crawler replica's address, `{replica}` standing for its name: where `/replay` finds the replica that holds a page's WARC record |

## Lexicon candidates: `lexgen.exe [options] [ID...]`

| Flag | Default | Meaning |
|---|---|---|
| `--data`, `--env` | as above | taxonomy and the OpenRouter key |
| `--model ID` | `deepseek/deepseek-v4.1-flash-1017` | the model that writes or reviews the terms (reasoning off) |
| `--review LANG` | none | review `lexicon_candidates.tsv` in `LANG` (`en`, `it`, `fr`, `de`, `es`) instead of writing candidates |
| `ID ...` | the 37 tier-1 nodes and the Sensitive Topics; with `--review`, every node with candidates in `LANG` | nodes to write terms for or review |

It writes `id<TAB>term<TAB>weight<TAB>language<TAB>source` lines to stdout. With `--review LANG`, one call per node keeps, reweights or drops that node's candidates, never adds one, and writes `id<TAB>term<TAB>weight<TAB>LANG` lines for `lexicon.tsv`.

## T4 benchmark: `t4eval.exe [options] MODEL...`

| Flag | Default | Meaning |
|---|---|---|
| `--data`, `--valkey`, `--env` | as above | the crawled URLs are re-fetched; their real T4 prompts are rebuilt |
| `--ref MODEL` | none | reference model, run at default reasoning (repeatable) |
| `--judgements FILE` | none | the golden labels: only judged pages that allow T4, scored against gold (T4 hF1, deep hP / hR / hF1) |
| `--cache DIR` | `store/golden` | `golden`'s page cache, read before fetching |
| `--cap USD` | none | stop starting models once this much is billed |

It writes a Markdown table to stdout. Method and latest results: [T4 model choice](../../study/t4_models.md).

## Files

| Path | In git | Content |
|---|---|---|
| `src/data/content_taxonomy_3.1.tsv` | yes (CC BY 3.0, `NOTICE`) | IAB Content Taxonomy 3.1, 704 nodes |
| `src/data/potion-base-32M.*`, `potion-multilingual-128M.*` | no, `fetch-data.sh --from-source` | Model2Vec models as published (safetensors, `tokenizer.json`, `config.json`) |
| `src/data/potion-base-32M.gguf`, `potion-multilingual-128M.gguf` | no, `fetch-data.sh` (release) or `convert-models.sh` | what the engine loads: Q8_0 table and tokenizer in one file (34 MB, 143 MB) |
| `src/data/siglip2-base-patch16-naflex.gguf` | no, `fetch-data.sh` (release) or `convert-models.sh` | SigLIP 2's vision tower, Q8_0 (95 MB) |
| `src/data/siglip2_prototypes.gguf` | yes | SigLIP 2 text embeddings of every taxonomy node, for zero-shot image labels |
| `src/data/NOTICE`, `src/data/licenses/` | yes | source, licence and changes of each third-party file |
| `src/data/lexicon.tsv` | yes | T1's lexicon, `id<TAB>term<TAB>weight[<TAB>lang]`: the English hand lines for Sensitive Topics, then the reviewed candidates in five languages. A line with a language only fires on pages in that language or with none declared, and T2's prototypes for a language take its terms. The rest of T1's lexicon is generated from taxonomy names and fires everywhere |
| `src/data/lexicon_candidates.tsv` | yes | `lexgen` output, not loaded: `lexgen --review LANG` writes the kept lines for `lexicon.tsv` |
| `src/.env` | no | `OPENROUTER_API_KEY=...` |

## Constants worth knowing

| Where | What |
|---|---|
| `src/lib/cascade.ml` | presets: budget, default `accept` and `reject` |
| `src/lib/refresh.ml` | refresh schedule (2 h for 48 h, then 1 to 14 days), SimHash threshold (3 bits), what counts as a hub |
| `src/lib/engine.ml` | `code`, the hand-bumped part of the pipeline version; page and short-text calibration; T1 saturation, `accept` and `reject` per language (`tunings`); fit and reach priors; which tags can be followed by a slot |
| `src/lib/slot.ml` | per-format page weight and reach of context above and below a slot (mirrored in `sdks/go` `GeometryOf`) |
| `src/lib/refresh.ml` | refresh schedule, SimHash threshold (3 bits), hubs |
| `src/lib/engine.ml`, `story_chars` | 400: the main text an `<article>` needs to count as a story of its own |
| `src/lib/profile.ml` | viewport height (700 px) and block-height estimates |
| `src/crawler/crawler.ml` | expected T4 prompt and answer tokens (950 / 250), used to price a call against the budget; an assumed 2% of bid requests becoming impressions and an assumed $25 eCPM, which turn traffic into `rich`'s budget |
