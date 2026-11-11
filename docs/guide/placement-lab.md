---
slug: /guide/placement-lab
sidebar_label: Placement Lab
---

# Placement Lab

The lab is a working end-to-end version of the design in the [study](../../study/architecture.md). It crawls real publisher pages and classifies them at every depth level. You can then simulate where a creative described in words would fit, and how many crawled pages it would reach.

## Three processes and Valkey

| Process | Code | Role |
|---|---|---|
| Crawl daemon, port 8081 | `src/crawler/crawler.ml` | **Lwt** fetches through libcurl (`curl_lwt`), honouring robots.txt (RFC 9309), with one request per host per max(1 s, Crawl-delay). Sitemap discovery. T3: images without alt text embedded with SigLIP 2 (C, on the pool), oEmbed titles for embedded video. A **Domainslib** pool runs every depth preset and labels every page segment in parallel. Each profile goes to Valkey. Any number of replicas share the frontier, politeness schedule and caches there |
| Online server, port 8080 | `src/online/online.ml` | Every 3 s, loads new or re-crawled profiles from Valkey. Any number of replicas. Turns a text prompt into a creative profile. Scores every candidate slot of a page, or the best slot of every crawled page (outreach), on the pool. Serves the front end and proxies `/crawler/*` to the daemon |
| Front end | `src/frontend/*.re` | ReasonReact compiled by Melange, bundled by esbuild, served by the online server |
| Valkey | `src/serve/valkey.ml` (client), `src/serve/lab.ml` (keys, Lua scripts) | frontier, seen-set, per-origin politeness, profiles, robots.txt and RSL caches, stats. On the cluster: primary + replicas with Sentinel ([deploy guide](deploy.md#valkey-shared-state-for-every-replica)) |

```
 crawl order (UI / API / --site)
        │
        ▼
 Valkey frontier ──► claim a due origin ──► robots.txt ──► fetch (Lwt, curl_lwt) ──► release the origin
                                              │ HTML
                                              ▼
                               parse to Doc.t (pool)            ─┐
                               images (SigLIP 2) and video titles │ per page
                               T4 dry run: which prompts? (pool)  │
                               OpenRouter calls (Lwt)             │
                               4 presets + segment labels (pool) ─┘
                                              │
                                              ▼
                         Valkey: ctx:profile:<key>, ctx:profiles index
                                              │ new or re-crawled, every 3 s
                                              ▼
                     online server: creative from prompt, slot odds, outreach (pool)
                                              │ JSON
                                              ▼
                                   ReasonReact front end
```

## How Lwt and Domainslib work together

- **Lwt owns the main domain:** sockets, timers and libcurl's multi interface.
- **CPU work goes to the pool.** `Serve.Web.detach pool f x` posts `f x` to a Domainslib pool and returns an Lwt promise. The worker hands its result back through Lwt's notification pipe, the one thread-safe way into the event loop.
- **Parallelism inside a job.** `Web.parallel pool` gives an `Engine.map` that runs `Domainslib.Task.parallel_for`, over the segments of one page or over all pages for outreach.
- **Why not `lwt_domain`:** it was tried first, but it makes the pool type abstract, and nested `parallel_for` needs the pool itself.
- **No lazy values shared across domains.** A lazy value forced from two domains at once raises. So T2 prototypes are built eagerly, and each page's lazy content is forced once, in one job, before anything runs in parallel on it.

### T4 never blocks a worker

T4 needs the network, but the cascade is a pure function running on the pool. So the crawler runs it in three phases:

1. **Dry run on the pool.** `Engine.llm_prompts` runs every preset with a T4 that records its prompt and answers nothing. T4 is the last tier, so its prompt depends only on the tiers before it, and the dry run sees exactly what the real run will send.
2. **Lwt sends those prompts to OpenRouter** (`src/serve/openrouter.ml`):
   - JSON mode;
   - reasoning off;
   - only providers that do not retain prompts (`data_collection: deny`);
   - the billed cost is reported.
3. **The pool runs the cascade again** with the answers.

If any call fails, T4 is dropped for that page; an empty answer never zeroes the labels. `GET /status` reports calls, errors and dollars billed.

### The AI-use gate comes first

Before phase 1, `Ai_use.t4` decides whether the publisher lets this page's text go into a generative model. It reads three sources:
- aipref `ai-use`, from robots.txt `Content-Usage` rules and the page's `Content-Usage` header;
- Content Signals `ai-input`, from robots.txt;
- RSL licenses, named by robots.txt `License:`, the `Link` header or `<link rel="license">`. Licenses are fetched politely and cached.

The most restrictive answer wins. A denied page skips T4 at every level, and the verdict is stored in the profile and shown above the labels. Details and the evidence from real publishers: [robots.txt and the AI-use gate](../../study/robots_matcher.md#4-the-ai-use-gate).

## What each depth level means

| Level | Tiers that can run | Budget |
|---|---|---|
| `zero_fetch` | T0: URL and sitemap hints only | $0 |
| `standard` | T0–T2 | $0.00001 |
| `rich` | adds T3 when a page has images or video without free text (SigLIP 2 zero-shot, oEmbed titles), and T4 if the model is cheap enough | what the page earns, from `standard`'s $0.00001 up to $0.0005 |
| `deep` | everything, with nothing frozen. T4 only when the crawler runs with `--llm MODEL`. Stored only with `--audit` | $0.01 |

A page stops early once it is *settled*: one label is at or above `accept` and none sits between `reject` and `accept`. Both thresholds, and T1's saturation, depend on the page's language (`Engine.tunings`, fitted on the golden set). The crawler stores `zero_fetch`, `standard` and `rich` for every page, and `deep` with `--audit`, so the front end can compare them side by side.

**Spend follows traffic.** `rich` spends what the page earns: its bid requests per day (`/traffic`, or `requests` in `/crawl`) × an assumed 2% of bid requests becoming impressions × an assumed $25 eCPM, 1% of a week of it (`Cascade.value_budget`). About 4 requests a day afford T4; a page without traffic stays at `standard`. Images, the costliest step on the Pis, are fetched and embedded only when a level is still in doubt after the text tiers and can afford one, and their embeddings are cached in Valkey for 30 days. Which model runs T4, and why: [T4 model choice](../../study/t4_models.md).

## Refresh

Pages with bid traffic are fetched again (`src/lib/refresh.ml`):
- **when:** every 2 hours for 48 hours after publication, then after a day, doubling with each unchanged fetch up to 14 days;
- **cheaply:** with their last `ETag` and `Last-Modified`; a 304, or a main text whose 64-bit SimHash moved by at most 3 bits under the same pipeline version, is not reclassified, only kept another 30 days;
- **hubs** (home pages, live blogs, section fronts, pages that changed on each of their last 3 fetches) are not chased: their page key is dropped so the bidder uses their section's or site's profile, and they are fetched daily.

Each profile carries its pipeline version (`version`, `Engine.version`): a hash of the taxonomy, lexicon and model files, the calibration, the thresholds and T4's model.

## What the front end shows

Five views, each with its own address (`#/pages/<url>`, `#/golden/<url>`...), so a link opens the same page in the same view. Every "?" explains the term next to it on hover or focus; **Help** (or `?` anywhere) lists all of them.

- **Header:** the views; the depth level, ad format and "avoid Sensitive Topics" switch that every view uses (kept across reloads); the crawler's health; the theme (auto, light, dark).
- **Overview:** pages, sites, golden-set progress, the share of pages that settled and that carry a sensitive label, spend per page, and the crawler's queue. Then why the level stops (settled, out of budget, no more tiers), each level's agreement with the golden set, the main topics and categories, and a table per site. A topic or a site opens Pages filtered on it.
- **Pages:** search titles, URLs and categories; filter by site, golden-set state, sensitive labels and stop reason; sort; `j` / `k` to move. For the selected page:
  - **Labels:** every label any level found, with its score at each level (bold when served); click a row for its evidence: tier, zone, reason, the quote, or the image T3 read. On a judged page each label is marked right, wrong or missed.
  - **Page:** the page itself, as the crawler archived it (WARC), scripts off, at a phone's or a desktop's width. Every extracted block on screen is outlined and shaded by its score for a chosen label, by its worst Sensitive Topics score, as main content against boilerplate, or by story. The simulated creative's slots sit where the template's ad containers are (or after each main block when the HTML has none), with their P; click one for its context boundary: the decay kernel above and below and the co-visible window, drawn on the page. The layout measured here is what the slots are scored on.
  - **Extracted blocks:** the blocks in reading order with their labels and, for the simulated creative, a slot bar between blocks: P = fit × reach, red when blocked. A minimap shows the whole page and its slots; click a slot for its reasons, and the co-visible blocks that caused a block are outlined in red. Boilerplate is hidden unless asked or flagged.
  - **Cascade:** what each level ran (tier badges), spent and why it stopped; the T4 gate; the keywords; the stored profile and its cascade trace.
  - **Golden set:** the judging form below, for this page; plus copy URL and re-crawl.
- **Simulate:** a creative in words (or an example) becomes categories and keywords; outreach counts the pages with a slot at fit ≥ the threshold, with a histogram, a table per site and the 50 best pages. Picking one lists its slots; "Open in Pages" shows them on the page.
- **Golden set:** a queue (to judge, judged, all) and the judging form: the candidates with every level's score as a heat map and their evidence, a taxonomy search for what every level missed, and the page's text to read. Keys: `1`–`9` toggle a row, `Enter` saves and moves on, `d` resets to the deep level's ticks, `/` searches, `j` / `k` move. The side shows each level's hP, hR and hF1 against the judgements and the labels it most often gets wrong or misses.
- **Crawler:** queue, in flight, fetched, failed, stored and T4 spend; crawl a page, a site or a pasted list; the live replicas; the last 100 events, filterable, opening stored pages in Pages.

## Probabilities are priors, not fits

Every number below is a hand-set starting point, marked `shortcut:` in the code, until engagement data replaces it ([roadmap](../../ROADMAP.md#placement-and-context-boundary)).

| Quantity | Current prior | Replace with |
|---|---|---|
| Fit | logistic on the matcher score: 1 / (1 + e^(−12 (score − 0.25))) | the engagement regression in [matching §5](../../study/matching.md#5-soft-score-relevance-then-learning) |
| Reach | e^(−y/6), y in viewports from the top | measured scroll-depth curves per site |
| Block heights | estimated from text length on a 390 px phone | slot geometry sent by the Prebid adapter ([context boundary §5](../../study/context_boundary.md#5-vision-based-yes-for-what-is-seen-but-dont-render-offline)) |
| Page and short-text calibration | hand-set Platt per text length | fitted on the golden set |
| Outreach | counts pages | weight by bid-log impressions per URL |
