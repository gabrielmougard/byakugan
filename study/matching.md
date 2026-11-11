# Online path: matching a page to a creative in a DSP

The offline path ([architecture.md](architecture.md)) leaves one compact profile per URL:

- IAB Content Taxonomy 3.1 labels with scores, ancestors included
- keywords
- Sensitive Topics scores

This document covers the other half: when a bid request arrives, which creatives may serve on this page, which serves best, and how much to bid. The reference implementation is [`src/lib/matcher.ml`](../src/lib/matcher.ml) and [`src/lib/store.ml`](../src/lib/store.ml).

## 1. Where matching sits in the bid flow

```
bid request (OpenRTB 2.6)
  │ site.page, site.keywords/kwarray, site.cat/pagecat(+cattax), content.*
  ▼
normalise URL ──► profile lookup: page → section → site      (Redis, < 1 ms)
  │                  │ miss
  │                  ├─► T0 inline on URL + site.keywords      (µs, no fetch)
  │                  └─► enqueue URL for crawl                 (Pub/Sub, async)
  ▼
candidate line items / deals  (existing filters: geo, device, format, domain, keywords …)
  ▼
contextual hard rules  (blocks, Sensitive Topics, targets)  ──► refusal reasons
  ▼
soft score per surviving creative  (topic, keywords, learned lift)  ──► reasons
  ▼
creative choice + bid modifier  ──► log (features, score, propensity) for learning
```

This is the pattern of a per-URL brand-safety cache in front of DoubleVerify's API:

- The bidder looks up `<segments>:<sha256(normalised URL)>` in a shared Redis.
- On a miss it never blocks the bid. It queues the URL and the cache fills behind the request.
- The contextual profile uses the same shape: key `contextual:<sha256(normalised URL)>`. The only difference is that a miss sends a crawl request instead of a DV call.

The profile above is page-level. For a slot inside the content (an interscroller or an in-article MPU), [context_boundary.md](context_boundary.md) blends it with nearby blocks, weighted by distance and by format. Suitability then takes the worst case over everything co-visible (`Slot.context`).

## 2. Unknown pages: back off, don't block

A URL nobody has crawled yet has three cheap fallbacks, in order:

1. **Section and site profiles** (built 2026-11-10). After `dailysport.example/football/2026/11/05/new-signing` itself, the lookup tries its top section `dailysport.example/football`, then its site `dailysport.example` (`Store.sections`, the Go SDK's `Sections` and `LookupWithBackoff`).
   - Only the top section: the bidder's Redis client may have no `MGET`, so each level costs one more `GET` on a miss, and most requests miss while the crawl is young.
   - A section's or a site's label score is the mean of its crawled pages' serving scores (a page without the label counts 0), written once 5 pages are in, under `contextual:section:<sha256(prefix)>`: a section's top page normalises to the same string as the section.
   - The crawler keeps them up to date page by page: each save adds the page's scores to its section's and site's running sums in Valkey and takes back what it added on its last crawl, in one Lua script.
   - A new article under `/football/` inherits Soccer before the crawler reaches it. On the golden crawl, 383 pages give 37 sections and sites with at least 5 pages.
   - URLs that start with a date give a "section" such as `ilpost.it/2026`, which is close to the site's profile.
2. **T0 inline.** URL tokens plus `site.keywords` / `kwarray` through the same lexicon. It needs no fetch and runs in microseconds (`Tier.url_and_hints`). Baykan et al. report 90%+ precision from URLs alone at the high-precision setting.
3. **Unknown.** Deals then follow their "deny if undefined" policy, exactly as keyword targeting handles requests without keywords.

## 3. The creative side

Creatives are few (hundreds to thousands, not millions), so **classify them deep**: every tier including T3 and T4, with human review.

- **Content labels for the creative.**
  - Run the same cascade over the ad copy, the **landing page**, image text and video frames and audio.
  - This yields IAB Content 3.1 labels in **the same label space as pages**. That shared space is what makes matching a set operation.
- **What the ad sells.** The IAB **Ad Product Taxonomy 2.0** category (`cattax=8`; e.g. 1070 Footwear, 1004 Beer, 1571 Electric Vehicles). This is the category the DSP reports in `bid.cat`.
- **Keywords and entities**, normalised the same way as page keywords.
- **Advertiser rules:**
  - `targets`: any-of; a descendant counts, so targeting Food & Drink matches Cooking.
  - `blocks`: none-of; descendants included, so blocking Sports also blocks Soccer.
  - **suitability:** `avoid_sensitive` in the prototype. In production, a per-topic tolerance for each Sensitive Topics child, GARM-style low/medium/high, which DV also exposes.
- **Policy rules from the product category.** Examples: alcohol never next to under-18 content; gambling restrictions per market. These compile into `blocks` when the creative is ingested.

```ocaml
type creative = {
  id : string;
  product : string;                    (* IAB Ad Product Taxonomy 2.0 id *)
  labels : (Ontology.id * float) list; (* creative + landing page, same cascade *)
  keywords : string list;
  targets : Ontology.id list;          (* any-of, descendants included *)
  blocks : Ontology.id list;           (* none-of, descendants included *)
  avoid_sensitive : bool;              (* IAB CT 3.1 "Sensitive Topics" *)
}
```

## 4. Hard rules first, each with a reason

`Matcher.refusal` applies these in order. A label counts once its score is at least 0.5, and the explanation names the **deepest** matching node.

1. **Block list:** `advertiser blocks Sports; page is Sports > Soccer (0.92)`.
2. **Brand suitability:** `brand suitability: page is Sensitive Topics > Crime & Harmful Acts … (0.89)`.
3. **Targeting:** `no targeted category on page`.

Every refusal is a sentence a trader can read, and it is logged. When a campaign under-delivers, the refusal log shows exactly which rule is starving it. This is the "understand the flaws" requirement applied online.

## 5. Soft score: relevance, then learning

### v0: the hand-set blend in the prototype
For creatives that pass the hard rules:

```
score = 0.6 · topic + 0.25 · keywords + 0.15 · lift
```

- **topic** = max over (page label p, creative label c) of s_p · s_c · WuPalmer(p, c).
  - WuPalmer is 2·depth(LCA) / (depth p + depth c): 1 for the same node, 0.67 for parent/child, 0.5 for siblings, 0 across roots.
  - This is Broder et al.'s taxonomy score with lowest-common-ancestor backoff, and the best pair is reported as the reason.
- **keywords** = the fraction of the creative's keywords found in the page's keywords. This is Ribeiro-Neto's "ad keywords present on page", the single strongest lexical feature.
- **lift** = a learned affinity of *product category × page category* from engagement logs (creative engagements, clicks, attention).
  - It is keyed by product category, not by creative, so a **new creative inherits** what its category already taught us.
  - This is how "beer on sport pages" can score without any topical overlap.
- **Optional dense term:** the cosine of int8 or Matryoshka-truncated page and creative embeddings (128–256 dimensions). It is reported as one number, the least explainable part, so it stays a minority weight.

### Prototype output
Test "creatives on the Arsenal page":

```
boots     0.621    topic Sports > Soccer ~ Sports > Soccer (0.83); keywords: premier league
beer      0.083    lift of product 1004 on Sports (0.55)
ev        blocked  advertiser blocks Sports; page is Sports > Soccer (0.92)
cookware  blocked  no targeted category on page
```

### v1: learn the blend
- Fit a logistic regression on engagement with the same named features plus format and device crosses (Chakrabarti et al. 2008: +25% precision over pure relevance).
- The weights stay readable: "a Soccer × Footwear pair adds 0.4 logits".

### v2: explore
- Choose among eligible creatives with Thompson sampling or LinUCB over the same features (Li et al. 2010: +12.5% clicks).
- Share statistics across the taxonomy (Pandey et al. 2007) so rare leaves borrow from their parents.
- **Log propensities**, so a new policy can be evaluated offline (IPS or doubly-robust) before it gets traffic.

### Abstain
If the best score is below a floor, don't force relevance: fall back to the line item's non-contextual bid, or skip. Broder et al. (2008) learned *when not to advertise*.

## 6. Using the score

| Use | How |
|---|---|
| Eligibility | the hard rules (§4) become filters in the deal/line-item filter pool |
| Creative choice | the highest-scoring creative, or a bandit sample (v2), among a line item's creatives |
| Bid modifier | bid = base × m(score), with m monotone and capped (e.g. 0.8×–1.3×), fitted from score-bucketed engagement |
| Curation (SSP side) | publish the profile as segments (`site.content.data` with `segtax`, or `pagecat` with `cattax=9`) so contextual deals can be activated downstream. |

**Measure before believing.** The congruence evidence is mixed. Goldfarb & Tucker (2011) found that contextual match and obtrusive formats each helped, **but not together**. For rich-media and high-impact formats, the A/B test has to cross relevance (on/off) with format. Expect the effect to depend on the format.

## 7. Latency and data structures

- **Profile:** at most about 20 `(id, score)` pairs, ancestors included, plus at most about 20 keywords. That is a few hundred bytes in Redis, read in one round trip under a configurable timeout, as a brand-safety lookup is.
- **Hard rules as bitmasks:**
  - Deal-side rules compile into one bitmask per IAB node over line items. This is the shape of a keyword include/exclude bitmask filter, with IAB IDs in place of keywords.
  - Because the page profile already contains ancestors, a block on "Sports" is a plain map lookup on "483".
  - The filter is O(labels on page), whatever the number of deals.
- **Soft score:** a 20 × 20 label-pair loop plus a short keyword intersection takes microseconds per creative, so brute force over a line item's creatives is fine.
- **Embeddings:** if the dense term is used, int8 at 128–256 dimensions makes the dot product negligible.

## 8. Running it in OCaml next to a Go bidder

The bidder is Go. The matcher is OCaml. Three ways to deploy it:

| Option | How | For | Against |
|---|---|---|---|
| **A. OCaml writes, Go reads** (recommended first) | The offline OCaml pipeline writes profiles to Redis. Go ports `refusal` + `score`: about 100 lines, the same features and weights, the coefficients loaded from a file the OCaml training job writes | no new hop in the bid path; reuses the brand-safety cache pattern (§1) | the scoring logic exists twice; keep it tiny and test both against one shared fixture file |
| **B. OCaml match sidecar** | Go calls an OCaml service over a Unix socket with `(profile, candidate ids)`; OCaml returns verdicts and reasons | a single implementation; all OCaml | an extra hop (~100–300 µs) and another service on call in the hot path |
| **C. Precompute page × line-item scores** | The OCaml job scores hot pages against active line items offline; Go reads `scores[li_id]` from the profile | the online path is a lookup | new line items need a rescoring sweep (minutes); scores go stale between sweeps |

**Recommendation:**

1. Start with **A + C**. Precompute scores for the hot head of URLs; the Go port of `refusal` covers the tail and new line items.
2. Keep `matcher.ml` as the reference implementation and the training-time scorer.
3. Move to **B** only if the matching logic grows beyond what is sensible to keep in two languages.

Whichever option is chosen, URL normalisation must be **identical** on both sides. The prototype's `Url_key` ports the bidder's URL normalisation (DV IQC rules) byte for byte, and writes keys with it.

## 9. What to log for learning and debugging

For every bid that went through contextual matching, log:

- the profile version and lookup level (page, section, site or T0-inline)
- the hard-rule outcome and its reason
- each feature (topic pair, keyword hits, lift) and the final score
- the creative chosen and its propensity
- the outcome: impression, engagement, click, attention

This is the training data for v1 and v2, and the audit trail for "why did this ad run here?"
