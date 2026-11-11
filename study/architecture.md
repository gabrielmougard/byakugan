# Offline path: discover, crawl, classify, explain

This document describes the offline half of the framework. It takes a publisher site and produces one compact **page profile** per URL: IAB Content Taxonomy 3.1 labels with scores, keywords and entities, and brand-suitability flags. It can also produce an **evidence trace** on demand.

The online half, matching a page profile against creatives in a DSP, is in [matching.md](matching.md). The sources behind each design choice are in [literature.md](literature.md). The working prototype is in [`src/`](../docs/guide/code-map.md).

## 1. Requirements

| Requirement | How the design answers it |
|---|---|
| Works on mobile and desktop open web | Raw HTML, metadata and media references. No reliance on browser APIs or on IDs. AMP and mobile variants are normalised to one URL. |
| Understands text, images and video | One ontology for every modality. Media are first read through free text (alt, captions, titles). Only media without that text go to models (T3): SigLIP 2 zero-shot for images, built (2026-11-08, [study](siglip2_images.md)). Audio is out of scope: too little of it on the open web. |
| Starts from a publisher site | Discovery runs in cost order: URLs from the bid stream, then robots.txt, sitemaps, RSS, and links last (§3). |
| Cheap or deep, on demand | A cascade of tiers T0–T4 with a **budget per page**. The page stops as soon as it is settled (§5–6). |
| Not everything through an LLM | The LLM sees a condensed page and a shortlist of candidate labels, and only when cheaper tiers cannot settle the page or the page is worth it. |
| Explainable when asked | Every label carries evidence: tier, zone, verbatim quote, reason and weight. Quotes from T0–T2 are verbatim by construction; T4 quotes are checked against the page. A trace records the versions used (§7). |
| OCaml | The whole pipeline is OCaml. Transformer inference runs in a model-server sidecar (§10). |

## 2. Big picture

```
                 ┌──────────────── discovery (cost order) ────────────────┐
 bid requests ──►│ site.page URLs seen by the bidder (free, the inventory)  │
 robots.txt   ──►│ Sitemap: lines → sitemap index → news/video sitemaps     │
 RSS/Atom     ──►│ partner feeds                                             │
 links        ──►│ in-site links, bounded depth (fallback)                   │
                 └───────────────────────────┬────────────────────────────┘
                                             ▼
                          frontier: one queue per host, value-ordered,
                          robots.txt + crawl-delay, change-rate aware
                                             │
       ┌─────────────────────────────────────┼────────────────────────────────────┐
       │  T0  URL tokens + hints (no fetch) ──► settled? ──yes──► profile store    │
       │                                      │ no, and budget allows             │
       │  fetch raw HTML (render only if text too short) → extract → SimHash      │
       │  T1  lexicon over title/section/keywords/headings/body/alt  ──► settled? │
       │  T2  dense: static embeddings (OCaml) or small encoder head ─► settled?  │
       │  T3  media without free text: SigLIP 2 zero-shot, video titles ─► ...    │
       │  T4  LLM/VLM on condensed page + shortlist, quotes verified             │
       └───────────────────────────────────────┬──────────────────────────────────┘
                                               ▼
              profile store (Redis key per normalised URL; section and site
              aggregates) + audit store (evidence, versions, cost)
```

Each arrow down is paid for only if the page is not yet settled **and** the next tier fits the page's budget.

## 3. Discovery and crawling

### Sources, cheapest first
1. **The bid stream.** The bidder already sees `site.page`. Pages that show up in bid requests are exactly the inventory that can be bought, and request volume tells us what each URL is worth.
   - The online miss path (matching.md §2) enqueues unseen URLs, the same way a per-URL brand-safety cache queues its lookups.
2. **robots.txt `Sitemap:` lines**, then sitemap indexes, then **news sitemaps** (the last 2 days; title, language, publication date) and **video sitemaps** (title, description up to 2,048 characters, `video:tag`, `family_friendly`).
   - These are free **T0 hints**: the prototype's `Doc.parse_sitemap` classifies a news entry without ever fetching the page.
   - Parse the legacy `news:keywords`, `image:caption` and `image:title` when present.
3. **RSS/Atom** for partners without news sitemaps.
4. **In-site links**, breadth-first, bounded depth. Only for sites that provide none of the above.
5. **Common Crawl** (monthly, Parquet URL index) to backfill the long tail at cold start. It is weeks stale and many premium publishers block it.

### Politeness and identity
- **robots.txt per RFC 9309**:
  - longest-match rule wins
  - 24 h cache
  - 4xx means allow everything, 5xx means disallow everything
- Honour `crawl-delay`, even though the RFC omits it.
- Use one connection per host, with Mercator-style queues per host.
- **Identify ourselves** the way Criteo's crawler does:
  - a named user-agent token and an info page
  - published IP ranges
  - **Web Bot Auth** (RFC 9421 signatures)
  - a request for Cloudflare verified-bot status under **"Advertising & Marketing"**, not "AI Crawler"
- **Gate the LLM tier on publisher preferences:**
  - Honour IETF aipref `ai-use=n` and RSL `License:` restrictions for any tier that sends page text to an LLM.
  - Classic classifiers fall outside aipref's definition of "generative AI".

### Rendering
Fetch raw HTML. Render with a headless browser **only** when extraction returns too little text. About 40% of top landing pages need JS, and rendering costs 10–50× a plain fetch. Measure how often partner article pages need it before building a render farm.

### Change detection and refresh
- Send `ETag` / `If-Modified-Since` validators, which are free, but expect few 304 responses.
- Trust `lastmod` **per host**, and only after checking it against our own content hashes. Bing measured lastmod 18% wrong.
- Reclassify **only when the 64-bit SimHash of the extracted main text moves by more than 3 bits** (Manku et al. 2007; use `Int64` in OCaml).
- A classification is a pure function of (content hash, pipeline version). Memoise on that key, so an unchanged page is never paid for twice.
- **Refresh policy** (Cho & Garcia-Molina):
  - Estimate a change rate per URL.
  - Revisit articles often for about 48 h after publication, then back off.
  - Don't chase pages that change on every fetch, such as homepages and live blogs. Classify those at **section level** instead.

## 4. Extraction: one GET, every free signal

A single fetch yields, in order of cost:

| Signal | Prevalence | Use |
|---|---|---|
| `<title>`, meta description, Open Graph | OG on about 64% of pages | title and description zones |
| JSON-LD: `headline`, `keywords`, `articleSection`, `BreadcrumbList`, `VideoObject` (`transcript`) | JSON-LD on about 41% of pages; Yoast fills section and keywords | keyword and section zones; media text |
| `article:section`, `article:tag`, `news_keywords` | common on news CMSs | section and keyword zones |
| Headings and main-text paragraphs, with boilerplate removed | everywhere | headings and body zones |
| `img alt`, `figcaption`, iframe embeds (YouTube, Vimeo) | about 50% of alts are empty or 10 characters or fewer | media-text zone, plus the T3 work list |

How the prototype handles these:
- **Boilerplate.** It skips `nav`, `footer`, `aside`, `form` and `noscript` (`src/lib/doc.ml`). In the tests this stops a "Tennis" nav link and a "Wine club" footer from labelling a football report.
  - Production should port Boilerpipe-style link-density and text-density scoring (SIGIR 2023 benchmark: Boilerpipe F1 0.834, Trafilatura 0.883, plain HTML-to-text 0.738). Use Trafilatura as the offline reference.
- **Media.** It merges items that share a `src`, such as `og:video`, `VideoObject` and `<video>`. Each file is then described, and paid for, once.

The extracted page is a `Doc.t`:

```ocaml
type t = { url : string; hints : string list; content : content Lazy.t }
```

`content` is **lazy**. A tier that only needs the URL and hints never fetches, and the test suite asserts this (`Lazy.is_val`).

## 5. The cascade

| Tier | Input | Method | Typical cost per 1M pages | Explanation it gives |
|---|---|---|---|---|
| **T0** URL + hints | URL path tokens, sitemap/RSS hints, OpenRTB `site.keywords` | lexicon (n-gram lookup, O(tokens)) | < $0.01, **no fetch** | term + zone + verbatim quote |
| **T1** lexical | fetched head + body + media text | same lexicon over 7 weighted zones | $0.01–0.1, plus fetch (est. $1–5) | term + zone + quote |
| **T2** dense | title, description, sentences | **T2a:** static embeddings in pure OCaml (Model2Vec-style), or **T2b:** a fine-tuned small encoder head (ModernBERT / mmBERT / Qwen3-Embedding-0.6B) via sidecar | T2a < $0.05; T2b $1–30 | similarity + nearest page sentence |
| **T3** media | media **without** usable free text (alt shorter than 20 characters, no transcript), at most 3 per page | image: SigLIP 2 zero-shot (built, on the CPU). Video: oEmbed titles. Captions, OCR and video keyframes were dropped (2026-11-08) | images about $1–6 | model text (caption, transcript or tag) + lexicon term, marked as derived |
| **T4** System 2 | condensed page: head, first 15 sentences, media text, **plus the top-12 shortlist** | small LLM or VLM with JSON output, quotes required | cheapest model in batch: $75–160; mid-tier: $1,750–3,500 | verified quote, or "quote NOT on page" |

Design rules behind the table:
- **T0 and T1 use the same lexicon.**
  - **Zone weights:** title 3.0, section 2.5, URL / hint / keywords 2.0, description and headings 1.5, body and media text 1.0.
  - **Score** = 1 − exp(−raw/4). One body mention stays weak (0.22). A title plus a section hit is already 0.75.
- **The lexicon is the taxonomy enriched with terms.**
  - TELEClass-style: an LLM proposes class-indicative terms per node; Wikidata adds aliases and entities; people review the result.
  - Term weights are later refitted as log-odds from distilled labels. That is still a linear, readable model.
- **T2 is zero-shot against node prototypes** (node name + lexicon terms) through a Platt-calibrated cosine.
  - It closes the vocabulary gap (Ribeiro-Neto's "impedance"): the test page has no lexicon term at all, yet is settled as Soccer at 0.99.
  - In production T2b is a **704-way sigmoid head** distilled from T4 labels, following the WebOrganizer and FineWeb-Edu pattern.
- **T3 turns video into text, then reuses the lexicon, and scores images against the same taxonomy (SigLIP 2 zero-shot).** Either way a media decision carries its evidence like a text one. Fusion across modalities is late (ContextIQ).
- **T4 never chooses from all 704 labels.**
  - LLMs get 34% doing that (Kamen 2025). Cheaper tiers give 94.5% top-5 recall (IAB classifier), so T4 reranks their shortlist.
  - An ID outside the shortlist is dropped.
  - A quote that cannot be found on the page halves the confidence.
- **"System 1" decision models** such as Laya slot in after T2 for **low-cardinality typed decisions**:
  - suitability flags
  - risk level
  - the 37 tier-1 verticals
  - "send to System 2?"

  They need fine-tuning and temperature recalibration first, and are not a replacement for the 704-way head ([literature §7](literature.md#system-1-decision-models-laya-jev)).

## 6. Decision logic: when to stop, how much to spend

### When a page is settled
A page is **settled** when at least one label is ≥ `accept` and **no** label sits between `reject` and `accept`. The labels in that band are exactly the doubt the next tier is paid to remove (`Cascade.settled`).

### How tier outputs combine
| Mode | Used by | Rule |
|---|---|---|
| `Accumulate` | T0, T1 and T3, which read disjoint zones and modalities | noisy-OR. This equals adding raw lexical evidence under 1 − exp(−raw/k), so nothing is double counted. |
| `Override` | T2 and T4, calibrated models that read the whole text | the new score replaces the old one |

In both modes a label already ≥ `accept` is **frozen**: cheaper tiers decided it, and costlier ones skip it. The production version replaces this hand rule with a **learned stacker** (logistic regression over tier scores and agreement features), as recommended in Gupta et al. (ICLR 2024) and by agreement-based cascading.

### Budget per page
```ocaml
let value_budget ?(share = 0.01) ?(days = 7.) ~daily_impressions ~cpm () =
  share *. daily_impressions *. days *. cpm /. 1000.
```
- A page carrying 1,000 impressions a day at a $2 CPM may spend $0.14, which affords T4.
- A long-tail URL with 5 impressions a day gets $0.0007, which covers T0–T3 but not T4.
- Depth therefore follows money automatically. The test suite pins both cases.

### Presets
These live in `Cascade` and are just `{budget; accept; reject}` records:

| Preset | Budget | Behaviour | Use |
|---|---|---|---|
| `zero_fetch` | $0 | T0 only, never fetches | in the bid path for unknown URLs; sitemap triage |
| `standard` | $10⁻⁵ | T0–T2, CPU only | the bulk of inventory |
| `rich` | $5·10⁻⁴ | adds T3 media | video and gallery pages; thin-text pages |
| `deep` | $10⁻² with `accept` > 1 | nothing freezes and every affordable tier re-checks | golden sets, audits, disputes |

### Demand-driven escalation
Raise the depth for a page when demand needs it. Example: a strict-suitability deal is eligible for the page, but the Sensitive Topics scores sit in the doubt band. Escalate that page to T3/T4 instead of escalating everything.

### Thresholds with guarantees
These are later work:
- per-tier temperature scaling
- **Conformal Risk Control** for each page's label set, bounding the expected share of missed labels
- **Learn-then-Test** for deferral thresholds, clustered by IAB branch
- recalibration on drift, since news cycles break exchangeability

## 7. Ontology and explainability

### The ontology is the concept bottleneck
- IAB Content Taxonomy 3.1 (704 nodes, `cattax=9`) is the label space, including **Sensitive Topics** (`v9i3On`) for suitability.
- Every model output passes through named concepts. That makes explanations faithful by construction, unlike LLM rationales (Turpin et al. 2023).

### The evidence record
`src/lib/label.ml` defines it:

```ocaml
type evidence = { tier : string; zone : string; quote : string; why : string; weight : float }
type t = { id : Ontology.id; score : float; evidence : evidence list }
```

Rules that keep explanations honest:
1. T0–T2 quotes are **verbatim page text**. The test `quotes_on_page` checks every one against the page.
2. T3 evidence is marked `model-text`: it is the model's output (a caption or transcript), not page text.
3. T4 quotes are **checked mechanically** against the page (`Tier.judge`): verified, or "NOT on page, confidence halved".
4. Labels inherited through the hierarchy say so (`hierarchy/ontology: child label "Soccer"`). Online targeting therefore never walks the tree.

### Explain on demand
- The **online profile** is compact: `(id, score)` pairs plus keywords (`Label.compact`).
- With `explain=true`, the full evidence and trace go to the **audit store** (BigQuery or GCS), keyed by (normalised URL, content hash, pipeline version).
- The **pipeline version** hashes the taxonomy version, the lexicon commit, model IDs, calibration parameters and thresholds.
- Any profile can then be reproduced and diffed. This is what lets people see *why* the model was wrong and fix the lexicon, the thresholds or the training data.

Example trace from the prototype, a deep audit of a mixed-topic page:

```
tiers: t0-url+hints -> t1-lexical -> t2-dense -> t4-llm | spent $0.001006 | stop: no more tiers
  0.90  Food & Drink > Alcoholic Beverages
      (+1 earlier)
      [t1/title] term "wine": "Wine pairing for the big match"
      [t1/body] term "wine": "Which red wine goes with a football supper?"
      [t2/semantic] page cos 0.88, nearest sentence cos 1.00: "Wine pairing for the big match"
      [t4/llm] quote verified on page: "Which red wine goes with a football supper?"
```

Here T2 also scored "Cooking" at 0.97. The LLM did not select it, so it was dropped. Its Soccer claim cited a quote that is not on the page, so it was halved below `reject`. Its invented ID `9999` was ignored.

## 8. The learning loop

```
 T4 labels (shortlist, verified quotes) ─┐
 human gold set (adjudicated)          ─┼─► distil: T1 term weights (log-odds), T2 head (sigmoid over embeddings)
 disagreements between tiers           ─┘        │
                                                 ▼
                          recalibrate (temperature / CRC) on held-out gold
                                                 │
                          deferral rate falls; T4 budget moves to the hard tail
```

1. **Pick escalations by margin or committee disagreement** (Cache & Distil). Every LLM call is then also a useful training example.
2. **Use a two-stage teacher:** many cheap-LLM labels, then about 10⁵ strong-model labels (WebOrganizer). The whole labelling bill is in the hundreds of dollars.
3. **Expect** 60–90% fewer LLM calls on coarse labels and 17–30% on deep leaves (Online Cascade Learning). Brand-safety edge cases will keep escalating, and that is correct.
4. **Build a golden set** of 2–5k pages, stratified by publisher × vertical × language. Label it in `deep` mode and adjudicate by hand.
5. **Track these metrics:**
   - hierarchical micro and macro F1
   - shortlist recall@12, which caps what T4 can achieve
   - ECE per tier
   - deferral rate
   - $ per page and p95 latency
   - **Sensitive Topics recall at fixed precision**, because a missed unsafe page costs more than a missed topic

## 9. Cost model

Costs are per 1M pages. The ranges come from [literature.md](literature.md); est. marks our own arithmetic.

| Step | $ per 1M pages | Assumption |
|---|---|---|
| T0 URL + hints | < 0.01 | CPU, microseconds |
| Fetch raw HTML | 1–5 (est.) | about 100 KB per page; CPU for TLS and gzip, plus network-processing fees |
| JS render (fallback only) | 10–50× fetch | headless browser |
| T1 extraction + lexicon | 0.01–0.1 | CPU |
| T2a static embeddings (OCaml) | < 0.05 | CPU |
| T2b small encoder head | 1–30 | L4 GPU at about $0.7/h |
| Entity linking | 1–10 (est.) | ReFinED or GLiNER |
| T3 image embeddings (3 per page) | 1–6 | SigLIP 2-B on an L4 |
| T3 captions (3 per page) | 15–60 | Florence-2 |
| T3 OCR | 120–210 per 1M images | gate it behind a text-heavy probe |
| T4 cheapest LLM, batch | 75–160 | about 1K tokens in, 150 out, cached prefix |
| T4 mid-tier LLM | 1,750–3,500 | |
| **Blended** (T0–T2 on all, T3 on about 7%, cheapest LLM on 10%, mid-tier on 1%) | **about 25–60, plus fetch** | |

**These numbers say something unexpected.** Running the cheapest LLM over every *condensed* page is already affordable for a bidder that sees millions of URLs a month, not billions. So the cascade is not mainly about the LLM bill. It buys these:

1. **Freshness.** A news page gets a profile in milliseconds to seconds; a batch API can take hours.
2. **Determinism and explainability.** Most decisions are readable lexicon or concept decisions that can be replayed.
3. **Data control.** Most page text never leaves our infrastructure, which also respects aipref and RSL.
4. **Cheap re-classification.** A new lexicon or taxonomy version re-runs T0–T2 over the whole corpus for cents.
5. **Headroom.** Money is saved for mid-tier models, VLMs and ASR where they change the answer.
6. **Scale.** If we ever classify the whole bid stream (10⁸+ URLs), the cascade is the difference between affordable and not.

Fetching and rendering, not classifying, are likely to dominate the bill.

**First measurement (M0):** count distinct normalised `site.page` values per day and month in the bid logs, plus the share of impressions taken by the top N URLs. The head/tail shape decides how much `deep` we can afford.

## 10. OCaml implementation

### Prototype modules
Everything is in `src/lib`, about 900 lines, with no dependencies beyond `re` and `yojson`.

| Module | Role | Production replacement |
|---|---|---|
| `text.ml` | words (BERT's normaliser in C: Unicode case, accents, punctuation), sentences, quote clipping | `uuseg` for sentences |
| `ontology.ml` | IAB TSV loader, lexicon, ancestors, Wu-Palmer similarity, O(tokens) n-gram hits | same; load the full 3.1 TSV |
| `html.ml` | HTML5 parsing through vendored lexbor; a tolerant tag scanner for XML | done ([study](html_parser.md)) |
| `doc.ml` | `Doc.t` with lazy content; meta, OG, JSON-LD, breadcrumbs and media extraction; sitemap parsing; zones | add Boilerpipe-style scoring and `camlzip` for `.xml.gz` |
| `label.ml` | evidence, Accumulate/Override update, freezing, ancestor closure, explanations | learned stacker |
| `vec.ml` | cosine and the toy embedder of the tests | done: Model2Vec runs in C on ggml ([study](model2vec_c.md)) |
| `tier.ml` | T0–T4 constructors; LLM shortlist, prompt, JSON parsing, quote check | T2b, T3 and T4 call sidecars or a batch API |
| `cascade.ml` | presets, value budget, the run loop, traces | add per-tier calibration and a learned deferral rule |
| `matcher.ml`, `store.ml` | online matching and section/site backoff | see [matching.md](matching.md) |
| `slot.ml` | slot context: the page blended with nearby blocks according to format; suitability taken as the worst co-visible case | see [context_boundary.md](context_boundary.md) |

### Process layout
This mirrors Ahrefs, who run OCaml crawling at web scale.

```
 frontier (Redis) ─► fetchers: lwt + curl_lwt, I/O-bound, one per N hosts
                     │  raw HTML → GCS (WARC-like, for replay)
                     ▼
                    extract + T0–T2a: CPU-bound, one OCaml process per core (Domains are optional)
                     │  needs-model jobs
                     ▼
                    model sidecars: ONNX Runtime / Triton (encoders, SigLIP, ASR), GPU pool
                    T4: provider batch API with a cached static prompt prefix
                     ▼
                    profile writer: protobuf (ocaml-protoc-plugin via `buf generate`) → Redis + audit store
```

### Interfaces with a Go bidder
- **Profile schema.** Add a protobuf message under `protos/` and generate Go with `buf generate`. OCaml uses `ocaml-protoc-plugin` from the same `.proto`.
- **Redis key.** Use `contextual:<sha256(normalised URL)>`, the same pattern as a per-URL brand-safety cache (`<segments>:<sha256>`).
  - The URL normalisation **must match** the bidder's URL normalisation (DoubleVerify IQC rules) byte for byte. The prototype's `Url_key` is that port, checked against fixtures a Go implementation wrote.
- **Crawl requests from the bid path.** A Pub/Sub topic, mirroring a brand-safety prefetcher's queue but out of process.

## 11. Risks and open questions

- **Access.**
  - Some publishers block unknown bots.
  - Mitigation: partner allowlisting, verified-bot status and Web Bot Auth.
- **Taxonomy fit.**
  - Our lexicon must be good on the categories advertisers actually buy. Start with the 37 tier-1 nodes, Sensitive Topics, and the top tier-2 nodes by line-item demand.
  - Leaves can come later.
- **Languages.**
  - The lexicon and static embeddings are per language; mmBERT and multilingual static models cover the rest.
  - Detect language at T1. `content.language` is also in OpenRTB.
- **Truth.**
  - Calibration guarantees hold only against the gold set, and the teacher LLM is not ground truth.
  - Adjudicate disagreements by hand.
- **DoubleVerify overlap.**
  - DV stays the accredited brand-safety signal (MRC, property level).
  - Our classifier adds page-level topics, explanations and custom suitability.
  - Run both and compare before replacing anything.
