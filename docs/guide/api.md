---
slug: /guide/api
sidebar_label: HTTP APIs
---

# HTTP APIs

All bodies are JSON.
- Errors come back as `{"error": "..."}`, with status 400 for bad input and 404 for unknown pages or routes.
- The online server proxies every `/crawler/*` path to the crawl daemon, so the front end only talks to one origin.

## Crawl daemon (port 8081)

### `POST /crawl`

Queue pages, or discover a site.

```bash
curl -X POST localhost:8081/crawl -d '{"url": "https://www.esquire.com/uk/watches/", "force": true}'
curl -X POST localhost:8081/crawl -d '{"urls": ["https://a.example/1", "https://a.example/2"]}'
curl -X POST localhost:8081/crawl -d '{"site": "https://www.bbcgoodfood.com", "max_pages": 20}'
```

| Field | Meaning |
|---|---|
| `url`, `urls` | pages to crawl. Only `http(s)` is accepted |
| `force` | re-crawl even if the URL is already stored or queued |
| `requests` | the pages' bid requests per day, as `/traffic` gives them: `rich`'s budget follows it, and without it a page gets `standard`'s |
| `site` | discover pages through the site's robots.txt `Sitemap:` lines (else `/sitemap.xml`, else article-like links from the home page), newest `lastmod` first |
| `max_pages` | cap for `site`, default 30 |

The reply lists what was queued: `{"queued": ["https://..."]}`. Site discovery runs in the background and reports in `/status`.

### `POST /traffic`

Queue the pages the bidder sees most, busiest first. The body has one `url<TAB>bid requests per day` line per page; `deploy/traffic.example.sh` builds it from your bid logs. The counts are kept per page: they set `rich`'s budget and which pages are refreshed, and a stored page not yet on the refresh schedule is due at once.

```bash
printf 'https://www.example.com/a\t500\nhttps://www.example.com/b?utm_source=x\t40\n' | curl --data-binary @- localhost:8081/traffic
```

- **Variants add up.** URLs are keyed by the bidder's normalisation, so variants of one page (tracking parameters, `www.`) add up.
- **Order.** Each origin's queue is ordered by these counts; pages discovered otherwise count 0. Among the origins due for a fetch, the one whose next page is busiest goes first. Politeness still holds per origin.
- **Pages already seen** are not queued again. A page still waiting moves up if its new count is higher.

Reply: `{"pages": 199, "queued": 199}`.

### `POST /coverage`

The same lines; the reply says how much of that traffic lands on pages with a stored profile. `deploy/coverage.example.sh` sends a day's impressions from your bid logs.

```json
{"pages": 100000, "covered_pages": 412, "count": 3912345, "covered_count": 81234}
```

### `POST /sections`

Adds the pages stored before section and site profiles existed (their summary has no labels) to their section's and site's running sums, and writes the profiles that reach 5 pages. A second call adds nothing; do not run two at once.

```json
{"added": 383, "stored": 383}
```

### `GET /status`

```json
{
  "queued": 0, "in_flight": 0, "ok": 36, "failed": 0, "stored": 36,
  "replicas": [{"id": "crawler-56d98c9cd9-6f8sv", "crawled": 10}, {"id": "crawler-56d98c9cd9-5m4w9", "crawled": 4}],
  "recent": [{"url": "https://...", "outcome": "ok: 92 segments; zero_fetch out of budget, ...; T4 allowed: no stated preference, no RSL license", "at": 1793873484.6}],
  "llm": {"model": "z-ai/glm-5.3-flash", "calls": 60, "errors": 0, "spent_usd": 0.0097}
}
```

Every replica answers from Valkey, so the numbers are cluster-wide.
- `recent` keeps the last 100 outcomes. Each includes the page's T4 gate verdict, the replica that crawled it, and for a blocked URL the robots.txt line that blocked it.
- `replicas` lists the crawlers that sent a heartbeat in the last 30 s, with what each has crawled.
- `llm` is `null` without `--llm`.

### `GET /pages`

One summary per stored profile: `url`, `key` (the normalised URL), `site`, `title`, `fetched_at`, `segments`.

### `GET /inspect?url=...`

```json
{"profile": { ... }, "explain": {"zero_fetch": "tiers: ...", "standard": "...", "rich": "...", "deep": "..."}}
```

- `profile` is the stored profile (schema in [Code map](code-map.md#profile-json)).
- `explain` is the cascade trace for each preset, as text: tiers run, spend, stop reason, and every label with its latest evidence.

### `GET /record?url=...`

The page's latest raw record, if this replica holds its WARC file: the body as fetched, with `content-type`, `x-warc-date` and `x-warc-uri`. 404 when the page was never archived or another replica holds it.

### `POST /replay`

Classifies this replica's archived pages again, the latest record of each, without fetching them: after a new lexicon, calibration or model. Images and T4 still go out as for a fetch. It runs in the background and logs one event: `replayed N archived pages in S s (archive read in R s)`.

## Online server (port 8080)

`level` is one of `zero_fetch`, `standard`, `rich`, `deep` (default `standard`). `format` is a format class, by where the ad sits against the content: `fullscreen` (interstitials, takeovers), `scroll-through` (interscrollers, scroll reveals), `in-article` (MPUs, in-read video, native), `sticky` (anchors, overscrollers) or `banner` (leaderboards, skyscrapers, sidebars); default `scroll-through`.

### `GET /api/pages?level=standard`

Every crawled page, newest first: `url`, `site`, `title`, `fetched_at`, `segments`, `stop`, `spent`, `sensitive` (a served label, ≥ 0.5, under Sensitive Topics), `adjudicated` (in the golden set), and `labels`, the top 3 labels found at that level.

A label, wherever it appears:

```json
{"id": "533", "path": "Sports > Soccer", "score": 0.99, "sensitive": false,
 "evidence": [{"tier": "t4", "zone": "llm z-ai/glm-5.3-flash", "quote": "...", "why": "quote verified on page"}]}
```

`evidence` is only filled where it is useful: page-level labels carry their last 4 pieces of evidence, and segment and creative labels have none.

### `GET /api/page?url=...`

```json
{
  "url": "...", "site": "...", "title": "...",
  "levels": [{"preset": "standard", "ran": ["t0-url+hints", "t1-lexical", "t2-dense"],
              "spent": 0.000006, "stop": "settled", "labels": [ ...top 8, with evidence... ]}],
  "segments": [{"i": 12, "tag": "p", "text": "...", "main": true, "top": 3.4, "height": 0.21, "labels": [ ... ]}],
  "t4_gate": "allowed: no stated preference, no RSL license",
  "fetched_at": 1794226742.6, "keywords": ["serie a", "derby"],
  "gold": {"labels": [ ...the judge's labels... ], "closure": ["483", "533"]}
}
```

`gold` is `null` until the page is judged; `closure` adds every ancestor, as hierarchical F1 counts them.

`top` and `height` are in viewports. `main` is false for boilerplate: navigation, widgets, footers.

### `POST /api/placement`

Slot odds for one page.

```bash
curl -X POST localhost:8080/api/placement -d '{
  "prompt": "cast iron casserole dish for slow cooking family roasts",
  "format": "scroll-through", "level": "standard", "avoid_sensitive": true,
  "url": "https://www.bbcgoodfood.com/howto/guide/how-to-cook-turkey-crown"}'
```

```json
{
  "creative": {"labels": [{"path": "Food & Drink > Cooking", "score": 1.0, ...}], "keywords": ["casserole", "cooking", ...]},
  "profile": {"from": "page", "key": "bbcgoodfood.com/howto/guide/how-to-cook-turkey-crown"},
  "slots": [{"after": 114, "y": 4.2, "reach": 0.5, "fit": 0.88, "p": 0.44, "blocked": false,
             "reasons": ["topic Food & Drink > Cooking ~ Food & Drink > Cooking (0.69)"], "flagged": []}]
}
```

- **A page nobody crawled** gets its top section's profile, else its site's, as the bidder would (`"from": "section"` or `"site"`, `key` the prefix): the same labels at every level and a single page-level slot. Without either, HTTP 404.
- **Where slots can go:** where the page's template puts its ad containers (found in the HTML, or learned from the template's other pages); without any, one slot after each main paragraph, image or embed. `fullscreen` formats, and pages at `zero_fetch` (no blocks), get a single page-level slot (`after: -1`).
- **A slot's page is its story:** on a URL with several stories (live blogs, infinite scroll), a slot inside one takes that story's labels as its page.
- **`flagged`** lists the co-visible segments carrying a sensitive label.
- **`p` = `reach` × `fit`.** Both are priors ([Placement Lab](placement-lab.md#probabilities-are-priors-not-fits)).

Measured layout: add `"geometry": [[segment, top, height], ...]` in viewports, as the lab's Page view does from the rendered page; slots are then scored on it, and the reply says `"measured": true`. The reply also gives the format's `geometry` (`page_weight`, `reach_above`, `reach_below`, `co_visible`), and each slot its `ad`: the ad container's id when the page's template has one there.

### `GET /replay?url=...`

The archived page itself (the crawler replica that holds it serves the record), made safe to frame: `Content-Security-Policy: script-src 'none'; object-src 'none'; frame-src 'none'`, `<base href>` set to the original URL so styles and images load from the publisher, no meta refresh, lazy images unwrapped. 404 when the page was never archived.

### `POST /api/outreach`

Takes the same fields as `/api/placement`, without `url`, plus `threshold` (default 0.5).

```json
{
  "total": 36, "matched": 9, "creative": { ... },
  "histogram": [23, 1, 1, 1, 0, 0, 2, 2, 3, 2],
  "sites": [{"site": "skysports.com", "total": 9, "matched": 8}],
  "pages": [{"url": "...", "title": "...", "site": "...", "fit": 0.95, "after": 31, "blocked": false, "reason": "topic Sports ~ Sports (0.75)"}]
}
```

- `matched` counts pages whose best slot has fit ≥ `threshold`.
- `histogram` buckets every page's best fit into tenths.
- `pages` is the top 50 by fit.

## Golden set (online server)

| Route | What it does |
|---|---|
| `GET /api/adjudication?url=` | the page's candidates (the top 12 labels each level found itself, with every level's score and up to 3 pieces of evidence, plus the judge's additions) and its saved judgement or `null` |
| `POST /api/adjudication` | `{url, gold, rejected}`: save a judgement; unknown category ids are refused |
| `DELETE /api/adjudication?url=` | forget a page's judgement |
| `GET /api/adjudication.tsv` | every judgement: `url`, `gold` ids, `rejected` ids, time |
| `GET /api/golden` | each level's agreement with the judgements, scored on the stored profiles as `golden` does |
| `GET /api/taxonomy?q=` | up to 20 categories whose path contains `q` |

```json
{"judged": 383, "pages": 383,
 "levels": [{"preset": "deep", "p": 0.554, "r": 0.655, "f1": 0.600,
             "false_positives": [{"id": "v9i3On", "path": "Sensitive Topics", "n": 17}],
             "missed": [{"id": "533", "path": "Sports > Soccer", "n": 12}]}]}
```

`p`, `r` and `f1` are hierarchical and micro-averaged over served labels (≥ 0.5); they are `null` when nothing is judged. `false_positives` are the served labels most often outside gold, `missed` the gold labels most often not served (top 8 each).
