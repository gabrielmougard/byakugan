# Roadmap

Open work, grouped by theme. What is built is described in the [README](README.md) and the [guide](docs/guide/quickstart.md); the research behind it is in `study/`, starting with the [offline path](study/architecture.md) and [online matching](study/matching.md). Each item says what is missing and links to the section that explains it.

## Classification quality

- **T4 shortlist recall.** T4 picks among T0–T3's 12 best labels, so their recall caps it. Target: recall@12 ≥ 0.95. The ranking is what to improve, not the shortlist's length ([golden report](study/golden_report.md#t4-shortlist)).
- **T2b.** A distilled 704-way sigmoid head behind a sidecar, trained on T4 labels. Decide self-hosted or hosted when it is built ([offline path §5](study/architecture.md#5-the-cascade)).
- **The distillation loop.** Pick escalations by margin or committee disagreement, then distil T4 labels into T1 term weights and the T2 head ([offline path §8](study/architecture.md#8-the-learning-loop)).
- **Learned decisions.** A stacker in place of the hand-written Accumulate/Override/freeze rule; Conformal Risk Control on label sets, Learn-then-Test for deferral thresholds, recalibration on drift ([offline path §6](study/architecture.md#thresholds-with-guarantees)).
- **Refit the per-language thresholds.** T1 saturation, accept and reject were fitted against T4 outcomes from an older crawl, on older shortlists. Recrawl the golden set with `--audit` and refit ([golden report](study/golden_report.md#t1-and-thresholds-per-language-t4-in-the-loop)).
- **Demand-driven escalation.** Go deeper on a page when a strict-suitability deal is eligible and its Sensitive Topics scores sit in the doubt band ([offline path §6](study/architecture.md#demand-driven-escalation)).
- **Main-content extraction.** Boilerpipe-style link- and text-density scoring, with Trafilatura as the offline reference. Today a `nav`/`aside`/`footer` skip list decides what is the article ([offline path §4](study/architecture.md#4-extraction-one-get-every-free-signal), [HTML extraction](study/html_parser.md#4-caveats)).
- **Text processing.** A Unicode sentence splitter in `text.ml` (`uuseg`), and entity linking (ReFinED or GLiNER) ([literature §7](study/literature.md#keywords-and-entities)).

## Matching and creatives

- **Ad Product Taxonomy 2.0** (`cattax=8`), so a creative's `product` is set ([matching §3](study/matching.md#3-the-creative-side)).
- **Creative profiles** from ad copy, landing page, images and video, classified `deep` with human review. Today they come from a text prompt only ([matching §3](study/matching.md#3-the-creative-side)).
- **Suitability per Sensitive Topics child.** A low/medium/high tolerance per topic, in place of the single `avoid_sensitive` flag ([matching §3](study/matching.md#3-the-creative-side)).
- **Policy rules compiled into blocks.** Alcohol never next to under-18 content, gambling rules per market ([matching §3](study/matching.md#3-the-creative-side)).
- **Product × page-category lift** from engagement logs. `affinity` is empty today, so lift is always 0 ([matching §5](study/matching.md#5-soft-score-relevance-then-learning)).
- **A learned score (v1).** A logistic regression on engagement with named features and format × device crosses, in place of the fixed 0.6 / 0.25 / 0.15 blend in `matcher.ml` ([matching §5](study/matching.md#v1-learn-the-blend)).
- **Abstain floor and bid modifier.** Below a floor, the non-contextual bid; above it, a capped m(score) fitted from score-bucketed engagement ([matching §5](study/matching.md#abstain), [§6](study/matching.md#6-using-the-score)).
- **A bandit over creatives (v2).** Thompson sampling or LinUCB, statistics shared through the taxonomy, propensities logged ([matching §5](study/matching.md#v2-explore)).
- **Profiles as segments** for curated deals: `pagecat` with `cattax=9`, or `site.content.data` with `segtax` ([matching §6](study/matching.md#6-using-the-score)).

## Placement and context boundary

- **Lab priors replaced by fits.** Fit and reach probabilities (a logistic on the matcher score, e^(−y/6) scroll decay), format weights, and outreach weighted by bid-log impressions per URL. Each is a `shortcut:` in the code ([Placement Lab](docs/guide/placement-lab.md#probabilities-are-priors-not-fits), [code map](docs/guide/code-map.md#deliberate-shortcuts)).
- **Measured block heights in the served profile.** The lab's Page view and the Prebid module measure them; the served profile still estimates them for a 390 px phone.
- **`sticky` and `fullscreen` geometry.** Check each format's spec, then fit ([context boundary §10](study/context_boundary.md#10-open-questions)).
- **The local-topic feature.** Fit it per format once slot geometry is logged. The page-topic feature has a first fit at site grain ([context boundary §8](study/context_boundary.md#8-does-matching-context-pay-a-first-look-at-site-grain)).
- **Prebid Server.** Check whether PBS core keeps `imp.ext.data` when it rewrites `imp.ext` per bidder. Prebid.js adapters on `ortbConverter` already carry it ([context boundary §10](study/context_boundary.md#10-open-questions)).

## Bidder integration

What a bidder must do to use the profiles. The Go SDK in `sdks/go/` covers the read path; its README shows the bidder's side.

- **Write profiles to the bidder's Redis** instead of the lab's Valkey ([matching §8](study/matching.md#8-running-it-in-ocaml-next-to-a-go-bidder)).
- **A deal's context in the deal configuration.** Targets, blocks, Sensitive Topics, minimum score and the "placement list or context" opt-in, built into a `contextual.Rule`.
- **Lookup and placement check.** The profile lookup with backoff in preprocessing, and the context rule as an OR inside the placement check, not a separate ANDed filter ([matching §2](study/matching.md#2-unknown-pages-back-off-dont-block)).
- **Crawl requests on every miss.** The Pub/Sub topic, the crawler's subscription, the publisher's permissions and the metrics, in the bidder's infrastructure.
- **Shadow mode first.** Count per deal what context would add before it changes any decision: the shadow reach count, measured in production.
- **Per-bid logs.** Each deal's `Decision` (verdict and deciding label), the profile version and lookup level, features, score, creative and propensity ([matching §9](study/matching.md#9-what-to-log-for-learning-and-debugging)).
- **The A/B test** of page context against slot context, crossed with format. Protocol, KPIs and power are written; it needs the steps above and the Prebid module on publishers' pages ([context boundary §9](study/context_boundary.md#9-the-ab-test-page-context-against-slot-context)).
- **A pacing-aware threshold** per deal through `Rule.MinScore`: lower when behind pace, higher when ahead.
- **An expansion floor.** Only placements above a publisher quality tier, and only pages that pass Sensitive Topics.
- **Context as a hard filter** for deals that require it (AND, not OR), as bitmasks over IAB ids if `Rule.Check` per deal gets too slow ([matching §7](study/matching.md#7-latency-and-data-structures)).
- **The matcher's score in the Go SDK.** The topic, keyword and product-lift blend, for creative relevance. It needs the taxonomy tree, and deal keywords normalised as the profile's are (`Text.words`) ([matching §8](study/matching.md#8-running-it-in-ocaml-next-to-a-go-bidder)).

## Crawling and freshness

- **Crawler identity.** An info page and published IP ranges, Web Bot Auth (RFC 9421), Cloudflare verified bot under "Advertising & Marketing", and a name publishers can allow in robots.txt. Some publishers refuse unknown crawlers ([offline path §3](study/architecture.md#politeness-and-identity)).
- **The news list from bid logs.** Derive `crawler --news` sites from the publishers with the most bid requests.
- **Traffic for news-sitemap pages.** They carry a publisher rank as their request count, not their own traffic, and the value budget spends on it.
- **Pub/Sub outside Google Cloud.** Crawl requests authenticate only through the emulator or the GKE metadata server today.
- **Sitemaps.** `.xml.gz` files (`camlzip`), per-host trust in `lastmod` checked against content hashes, and a better fallback than "same-host links with a long path" ([offline path §3](study/architecture.md#change-detection-and-refresh)).
- **Refresh signals.** Per-host trust in `ETag` and `Last-Modified`; a change hash that sees word order; check that the word SimHash moves on home pages over hours ([Placement Lab](docs/guide/placement-lab.md#refresh)).
- **Section profiles that age.** A page counts in its section until recrawled, however old: add a window or a decay. Date-first URLs make the year their section ([matching §2](study/matching.md#2-unknown-pages-back-off-dont-block)).
- **Homepage context.** Teasers near the slot and section-level refresh, if homepages carry a large share of impressions (see Evaluation).
- **RSL.** An Open License Protocol client for licenses behind a license server, which today always deny T4; RSL embedded in pages or feeds (`<script type="application/rsl+xml">`, the RSS module) ([robots.txt and AI-use gate §5](study/robots_matcher.md#5-limits)).
- **Raw HTML to object storage.** Closed WARC files go from the crawlers' volumes to GCS or similar for replay ([context boundary §7](study/context_boundary.md#7-what-is-built-2026-11-11)).

## Infrastructure and performance

- **T4 through a batch API** with a cached static prompt prefix. OpenRouter's `:batch` variants are listed at about half price, untested ([offline path §9](study/architecture.md#9-cost-model)).
- **ARM servers** (GKE Axion, Graviton). Build ggml with the int8 dot product; Debian's gcc targets ARMv8.0 by default ([SigLIP 2 §3](study/siglip2_images.md#3-speed)).
- **An audit store** (BigQuery or GCS) for the full evidence and trace, keyed by (URL, content hash, pipeline version) ([offline path §7](study/architecture.md#explain-on-demand)).
- **Valkey on the Pi cluster.** One CoreDNS replica per node: losing the node that runs the only one stalls Sentinel and aborts the failover. Valkey volumes off the SD cards, and a full-cluster restart with the Sentinel config fix ([deploy](docs/guide/deploy.md#valkey-shared-state-for-every-replica)).

## Evaluation

- **A human check of the golden set.** Judge 50 pages by hand in the lab and measure agreement with the LLM-adjudicated gold, before trusting finer calibrations to it ([offline path §11](study/architecture.md#11-risks-and-open-questions)).
- **Golden pages in every language.** Spanish has none and German few, so both share the fallback calibration and thresholds ([golden report](study/golden_report.md#calibration)).
- **Homepage share of impressions.** One query on the bidder's bid logs; a large share moves homepage context up.
- **Shadow reach over a week**, with a multi-day merge in `deploy/reach_report.example.py`, and with T4 on.
- **Comparison with a verification vendor** (DoubleVerify, for instance) on overlapping URLs ([offline path §11](study/architecture.md#11-risks-and-open-questions)).
