# Where does an ad's context stop?

**The question.** An ad sits at one spot on a page. Should the whole page count as its context, or only the content near the slot, as the reader *sees* it at that moment? In other words, should context be "vision-based"?

**Short answer.** There is no single boundary. Context works at three scales, and each scale does a different job. The ad format decides how much each scale counts. For brand safety the worst case always wins: it is never averaged away.

| Scale | What it captures | Its job |
|---|---|---|
| **Page.** The *article that contains the slot*, which is not always the whole URL. | Why the reader came, and their mindset. | Relevance prior; page-level suitability. |
| **Neighbourhood.** Main-content blocks around the slot, weighted down with distance. Content above the slot (already read) counts more than content below (not yet seen). | What the reader just read: priming. | Relevance for formats that sit inside the content. |
| **Co-visible window.** Everything on screen with the ad, *including* comments, "most read" widgets and sidebars. | What a screenshot of the ad would show. | Suitability, taken as the worst case. |

## 1. Five rules

1. **Relevance blends, suitability takes the maximum.** A sensitive signal anywhere in the window blocks the ad. It is never diluted by benign text around it.
2. **The format sets the mix** (§3). A full-screen interstitial has no spatial anchor, so page context dominates. An interscroller opens inside the text, so the paragraphs just read dominate.
3. **Above counts more than below.** Priming needs exposure: the reader has scrolled past what is above the slot and has not yet seen what is below. Treat this as a hypothesis grounded in priming research and confirm it by fitting the model (§6).
4. **Boilerplate removal is right for topic and wrong for safety.**
   - A "Most read: man stabbed" widget is noise for deciding what the article is about. It is also a real adjacency risk.
   - So keep those blocks, mark them `main = false`, and use them only for suitability.
   - The current extractor (`doc.ml`) drops `nav`, `footer` and `aside` for topic labelling. Block segmentation (§5) must keep them for this purpose.
5. **"Page" means the article, not the URL.** Infinite scroll, live blogs and multi-article URLs put several stories on one URL. The page-level prior must come from the story the slot sits in.

## 2. What the evidence says

- **Priming needs exposure.** Yi (1990), *J. Consumer Research* 17(2):215–222 (https://ideas.repec.org/a/oup/jconrs/v17y1990i2p215-22.html).
  - Surrounding content made certain product attributes more accessible, and that changed brand attitudes.
  - This argues for the content the reader has just consumed, which is the neighbourhood above the slot.
- **Congruence helps memory, incongruence grabs attention.** Simola, Kivikangas, Kuisma & Krause (2013), *Applied Cognitive Psychology* 27(4):429–442.
  - In eye-tracking, incongruent ads drew more attention, while congruent ads were better recognised the next day.
  - So the "right" context depends on the campaign's goal: brand recall favours local congruence, attention may favour contrast.
  - Porta et al. (2013, *Online Information Review*, https://www.emeraldinsight.com/doi/full/10.1108/OIR-01-2012-0001) found online results on congruity contradictory.
- **Attention spills from articles to ads.** Simonov, Valletti & Veiga, eye-tracking experiment (https://papers.ssrn.com/sol3/papers.cfm?abstract_id=3836531).
  - Articles that hold attention raise attention to the ads on the same page, and ad attention raises recall and purchase.
  - So *how engaging* the surrounding content is matters, not only its topic. Dwell time is a context feature too.
- **Adjacency harm is worse for intrusive formats.** Spillover study, *J. Current Issues & Research in Advertising* 2021 (https://digitalcommons.unf.edu/unf_faculty_publications/1353).
  - Even accidental placement next to offensive content made consumers believe the brand approved of it, but *only when the ad was perceived as intrusive*.
  - So the co-visible window matters more for rich-media and high-impact formats, such as interscrollers and interstitials, than for banners.
- **Misalignment costs purchase intent.** Magna and Channel Factory, n=5,845 (https://www.mediapost.com/publications/article/381801/magna-trial-finds-consumers-hold-brands-responsibl.html).
  - When ads did not fit their surroundings, purchase intent fell and consumers held the brand accountable.
  - Counterpoint, industry-funded: IAB with Magid (2020) found that ads in professional news raise trust in the brand.
- **Section-level context has precedent.** AdSense "section targeting" (`<!-- google_ad_section_start -->`, `(weight=ignore)`) let publishers mark which part of a page should drive ad selection and which to ignore, such as menus and comments (https://www.simplified.guide/google-adsense/section-targeting). Whether Google still supports it today is unconfirmed.
- **Vision-based segmentation.** VIPS (Cai, Yu, Wen & Ma, MSR-TR-2003-79, https://www.microsoft.com/en-us/research/publication/vips-a-vision-based-page-segmentation-algorithm/).
  - Segments a page the way a reader sees it, using visual separators instead of DOM structure.
  - Yu et al. (WWW 2003, https://archives.iw3c2.org/www2003/cdrom/papers/refereed/p300/p300-Yu.html) showed that VIPS segments beat both DOM-based segments and whole documents for retrieval.

## 3. The format sets the boundary

Formats are classes of position against the content, not product names; each ad format maps onto one (`Slot.formats`). The weights are starting priors (`Slot.geometry`), to be replaced by fitted values.

| Format class | Examples | Position relative to content | Page weight | Neighbourhood | Co-visible window |
|---|---|---|---|---|---|
| `fullscreen` | interstitials, takeovers | full screen, no spatial anchor | 0.9 | weak | the page it covers |
| `scroll-through` | interscrollers, scroll reveals | opens inside the article as the reader scrolls | 0.4 | strong: the paragraphs just read | yes |
| `in-article` | MPUs, in-read video, native units | between paragraphs | 0.6 | moderate | yes |
| `sticky` | anchors, overscrollers | stays on screen while the text scrolls under it | 0.6 (default) | to measure | yes |
| `banner` | leaderboards, skyscrapers, sidebars | next to widgets, not the article | 0.6 today; about 0.8 expected | its neighbours are widgets, so use them for suitability only | yes, and widgets dominate |

## 4. The model

Offsets are measured in **viewport heights** from the slot, because a viewport is what a reader sees at once on any device. Negative offsets are above the slot (already read); positive offsets are below (not seen yet).

```
kernel(d)    = exp(-|d| / reach_above)   if d < 0
               exp(-|d| / reach_below)   if d > 0        (reach_above > reach_below)

local(n)     = Σ_main-blocks kernel(d_b) · s_b(n) / Σ_main-blocks kernel(d_b)
relevance(n) = w_format · page(n) + (1 − w_format) · local(n)

suitability(n ∈ Sensitive Topics) = max( page(n), max over blocks with |d_b| ≤ 1 of s_b(n) )
```

In the prototype, `Slot.context` returns a `Matcher.page`, so the matcher is unchanged. The test is a weekend food guide whose page-level labels favour wine; the slot sits 0.3 viewport below the recipe section.

```
== food guide, scroll-through right after the recipe ==
  cookware  0.341    topic Food & Drink > Cooking ~ Food & Drink > Cooking (0.57)
  beer      0.317    topic Food & Drink ~ Food & Drink > Alcoholic Beverages (0.53)

== food guide, fullscreen ==
  beer      0.423    topic Food & Drink > Alcoholic Beverages ~ Food & Drink > Alcoholic Beverages (0.70)
  cookware  0.308    topic Food & Drink ~ Food & Drink > Cooking (0.51)

== same slot, crime headline in a co-visible widget ==
  beer      blocked  brand suitability: page is Sensitive Topics > Crime & Harmful Acts … (0.90)
  cookware  blocked  brand suitability: page is Sensitive Topics > Crime & Harmful Acts … (0.90)
```

The same page and the same creatives give a different winner per format. Moving the crime widget 2.5 viewports away, off screen, lifts the block; the test asserts all three cases.

## 5. Vision-based: yes for what is seen, but don't render offline

Rendering every page in a headless browser costs 10–50× a fetch. Ways to place the slot and its neighbours, cheapest first:

1. **Find the slot in the template, offline, for free.**
   - The GPID (`imp.ext.gpid`, set by Prebid's GPT Pre-Auction module; https://docs.prebid.org/features/pbAdSlot.html) usually carries the ad-server path plus the **div ID**.
   - Find that div in the crawled HTML to get its DOM position among the content blocks.
   - In-article slots sit at fixed template positions ("after paragraph 3"). Learn the position once per (site, template, GPID) and reuse it for every page of that template.
   - Lazily injected slots are not in the raw HTML. Use the next option for those.
2. **On mobile, DOM order is roughly visual order.** Pages are a single column, so DOM distance converted with an average block height per template gives viewport offsets. No rendering is needed.
3. **Measure at auction time; the browser has already rendered the page.**
   - A bidder's Prebid.js adapter runs on the page when the auction starts. It can attach to `ortb2Imp.ext.data`:
     - the slot's position;
     - for the k nearest blocks, a hash of each block's text (a SimHash of the normalised paragraph) and its offset.
   - That is about 100 bytes. **No page text leaves the page**: the hashes join the block labels computed offline.
   - This is true vision-based context on the real device and real layout, essentially for free.
   - In-read slots are usually requested close to the viewport, so the geometry is accurate when it matters.
4. **On desktop multi-column layouts, segment visually (VIPS-style) once per template.**
   - Render *one* page per template, not every page, to separate the main column from sidebars and widgets.
   - Then reuse that block map through DOM paths for every page of the template.
5. **After the impression, observe for learning and audit.**
   - A measurement pixel, or a rich-media creative where it renders in the page, can record which blocks were actually co-visible.
   - This feeds learning and post-bid audit, not the bid decision itself.

Avoid offline rendering of every page and screenshot VLMs per impression. Neither is needed.

## 6. What changes offline, and how we settle the question

**Segmentation.**
- Split each crawled page into blocks:
  - heading-delimited sections of main text
  - images with their captions
  - embeds
  - non-main widgets: comments, related and most-read lists, sidebars
- Label each block with the same cascade. Per block, T0–T2 are cheap; T3 and T4 stay at page level.
- The profile gains a few hundred bytes per page: block hash, DOM order, `main` flag and the top 3 labels.
- Only pages with in-content slots need this.

**Explanations name the block:**
- "Cooking 0.63: the section 0.3 viewport above the slot says …"
- "Blocked: the 'Most read' widget 0.4 viewport below the slot shows 'Man arrested after fatal stabbing'."

**Let the data set the boundary.**
- Log both page-level and slot-level contexts for every impression.
- Give the engagement model ([matching.md §5](matching.md#5-soft-score-relevance-then-learning)) *two* topic features, page-topic match and local-topic match, per format. Their fitted weights are the empirical answer to "how much does nearby content matter", per format.
- **A/B test:** page context against slot context, crossed with format, with KPIs chosen per objective:
  - for brand lift and recall, expect local congruence to help (Simola; Moorman);
  - for attention and engagement, contrast may win (Simola; Dahlén).
- **Safety:** compare co-visible sensitive incidents with and without the window rule.

## 7. What is built (2026-11-11)

- **The page itself in the lab.** The crawler keeps every page it classifies as a WARC record (FastWARC, vendored Rust behind a C ABI: `src/stubs/warc_ffi`), one gzip member per record, about 64 KB a page, indexed in Valkey. The lab's Page view shows the archived page, scripts off, at phone or desktop width, aligns each extracted block to its element, and draws block scores, slots, the decay kernel and the co-visible window on top. The layout measured there goes back to the placement API: slots are scored on real geometry.
- **Slots from the template (§5, option 1).** The extractor records ad containers by element id (`div-gpt-ad-*`, `ad-slot`, `mpu`, `leaderboard`...) and their place among the blocks; on the golden sample 177 of 383 pages have some. Positions are learned per template (site, top section, URL depth), counted in main blocks, so a page whose slots are injected by script gets its template's. Placement then uses those slots instead of "after every paragraph".
- **Measured at auction time (§5, option 3).** `sdks/prebid`: a real-time data module writes the 12 blocks nearest each slot, as SimHash and offset, into `ortb2Imp.ext.data.ctx`. Its SimHash is the crawler's, byte for byte (fixtures written by the OCaml side). Adapters on `ortbConverter` carry `ortb2Imp` unchanged; checked on a Prebid.js adapter built on `ortbConverter`. The served profile now carries its labelled blocks (SimHash, `main`, labels with ancestors, estimated position) and ad containers; the Go SDK's `Profile.AtSlot` matches the request's blocks within 3 bits and computes the slot's context exactly as `Slot.context` does (2,000 fixtures), and `Profile.SlotOfGPID` stands in from the estimated layout when the request has no `ctx`.
- **Page = story (§1, rule 5).** Each block knows its innermost `<article>`; stories (an article with at least 400 characters of main text) get their own labels, and a slot inside one takes it as its page.

## 8. Does matching context pay? A first look at site grain

`deploy/context_fit.example.py` runs this fit on your own delivery data: 30 days of delivery reporting (impressions and engagements per domain, format and advertiser category) joined with the site profiles (sites with at least 5 crawled pages). The advertiser's category maps onto IAB Content Taxonomy 3.1 ids; the match is the site's mean score for them. Per format, a binomial GLM, logit(ER) = α[category] + β · match, with category fixed effects; β's 90% interval from resampling sites. Delivery is reported per site, so this is the page-topic feature of §6 at site grain; the local-topic feature needs the slot geometry the Prebid module logs (§9).

**Reading β.** An interval above 0 says matching site context lifts engagement for that format. One below 0 says the reverse, which is what Simola et al. found for attention (incongruent ads draw more of it), and what Goldfarb & Tucker found for obtrusive formats. An interval across 0 says nothing. Three limits keep even a clear β from settling anything:
- **Site, not page or slot.** Delivery is reported per domain. A site's mean profile is a blunt context.
- **Observational.** Campaigns choose their sites; category fixed effects absorb how engaging each vertical's creatives are, not who bought where.
- **One KPI.** Engagements count interactions with the creative, which favours attention over congruence; brand recall, where congruence should help, is not measured here.

So the question goes to an experiment.

## 9. The A/B test: page context against slot context

**Unit.** The bid request, by a hash of its id, inside deals that opted in to "placement list or context" and whose requests carry `ortb2Imp.ext.data.ctx` (pages with the Prebid module). Request-level assignment needs no user identifier.

**Arms**, crossed with format class (`scroll-through`, `in-article`, `fullscreen`):
- **Page:** `Rule.Check` on the page's profile (today's behaviour).
- **Slot:** `Rule.Check` on `Profile.AtSlot`: page and nearby blocks blended per format, co-visible blocks for suitability.
- **Control** (5%): no context, placement list only; it sets the baseline for both lifts.

**KPI per objective,** fixed before launch:
- engagement campaigns: engagement rate (creative interactions per impression);
- awareness (CPM, CPX): 3-second exposure rate and dwell time, and brand-lift studies where a campaign runs one;
- performance: CTR and post-click engaged sessions;
- suitability, every campaign: co-visible Sensitive Topics incidents per 100,000 impressions, from a post-impression audit sample;
- guardrails: win rate, delivery pace and revenue per thousand requests per deal, which stop an arm that starves a deal.

**Power.** Impressions per arm to detect a relative engagement lift Δ over a baseline engagement rate p0 at α = 0.05 (two-sided), power 0.8: n = (1.96 + 0.84)² · [p0(1 − p0) + p1(1 − p1)] / (p1 − p0)², with p1 = p0 · (1 + Δ). For assumed baselines:

| p0 (assumed) | +5% | +10% | +20% |
|---|---|---|---|
| 1.0% | 0.64M | 0.16M | 0.04M |
| 0.5% | 1.28M | 0.33M | 0.09M |
| 0.2% | 3.21M | 0.82M | 0.22M |

Impressions cluster by page and creative, so plan on twice these (design effect about 2) and analyse with a logistic model with campaign fixed effects and errors clustered by page. Divide by the daily impressions of the opted-in deals with `ctx` for the test's length; formats with a low baseline need longer or a pooled in-article cell.

**Then fit.** The same logs (page labels, slot blocks, offsets, format, outcome) fit the two features of §6, page-topic match and local-topic match per format, with `reach_above` and `reach_below` profiled by likelihood: the empirical answer to how far context reaches.

## 10. Open questions

- **Exact format geometry.** `sticky` and `fullscreen` units differ by vendor: does one cover content, does it appear between page views? Check each format's spec before mapping it to a class.
- **The Prebid path.** Settled for Prebid.js: adapters on `ortbConverter` carry `ortb2Imp.ext.data` with no release (§7). Open: whether Prebid Server core keeps `imp.ext.data` when it rewrites `imp.ext` per bidder, and how fast publishers add an RTD module.
- **Session context.** For interstitials shown between page views, the previous page may be the better context. But that is user history, which brings TCF consent obligations. Stay on the current page unless consent covers it.
- **Context drifts.** Sticky and refreshing slots see different content at render time than at bid time. Bid-time geometry is only an approximation, and post-impression observation (§5, option 5) measures the gap.
