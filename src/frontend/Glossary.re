/* The explanations behind every "?" in the lab, and the help drawer. */

let depth = "How far the cascade may go on a page. Each level is a budget per page; the crawler stores all four, so the same page can be compared at every level.";
let format = "The ad format. It sets how much the whole page counts against the content right around the slot, and how far down a slot still gets seen.";
let avoid = "Block any slot on a page, or next to a block, that carries an IAB Sensitive Topics label (crime, conflict, adult content...).";

let level =
  fun
  | "zero_fetch" => "T0 only: the URL and sitemap or OpenRTB hints, without fetching the page. Free."
  | "standard" => "T0-T2: URL, lexicon on the page text, static embeddings. Budget $0.00001 a page."
  | "rich" => "Adds T3 (images through SigLIP 2, video titles) when text is thin, and T4 if it is cheap enough. Budget $0.0005 a page. This is what the bidder serves."
  | "deep" => "Every tier, nothing frozen or settled early, T4 when the crawler runs with --llm. Budget $0.01 a page. For audits and the golden set."
  | other => other;

let tierName = t =>
  switch (String.index_opt(t, '-')) {
  | Some(i) => String.sub(t, 0, i)
  | None => t
  };

let tier = t =>
  switch (tierName(t)) {
  | "t0" => "T0, URL and hints: category terms in the URL path, sitemap tags and OpenRTB hints. No fetch."
  | "t1" => "T1, lexicon: weighted terms per category matched in the title, headings, body and metadata."
  | "t2" => "T2, dense: page and sentence embeddings (Model2Vec) against each category's prototype, Platt-calibrated on the golden set."
  | "t3" => "T3, media: images without alt text read by SigLIP 2 zero-shot, and oEmbed titles of embedded video."
  | "t4" => "T4, LLM: reranks a 12-label shortlist and must quote the page. An unverified quote halves the confidence; an invented id is dropped."
  | "hierarchy" => "Filled in from a child label: a page about Soccer is also about Sports."
  | other => other
  };

let stop =
  fun
  | "settled" => "Settled: one label at or above accept (0.80) and none between reject (0.30) and accept. The next tier is not worth paying for."
  | "out of budget" => "Out of budget: the next tier would cost more than this level allows."
  | "no more tiers" => "No more tiers: every tier allowed at this level ran."
  | other => other;

let score = "Calibrated confidence, 0 to 1, that the page is about the category. Labels at 0.5 or more are served.";
let evidence = "Why the label is there: the tier, the page zone, a verbatim quote and the reason. T0-T2 quotes are page text by construction; T4 quotes are checked against the page.";
let t4Gate = "Whether the publisher lets its text go into a generative model (aipref, Content Signals, RSL licenses). A denied page never reaches T4.";
let sensitive = "IAB Sensitive Topics: the brand-suitability branch. Shown in red.";
let spent = "What the tiers cost on this page at this level (T4 at the catalogue price).";
let segments = "The page's blocks in reading order, each labelled on its own. Slots go between main blocks.";
let boilerplate = "Navigation, 'most read' widgets and footers. Hidden unless you ask, or unless they cause a block.";
let keywords = "Terms extracted from the page, served with the labels so deals can match on words too.";
let minimap = "The page from top to bottom, in viewports. Grey: main text; light: boilerplate; bars: slots, coloured by P.";
let matrix = "Every label any level found itself, with its score at each level. The current level's column is highlighted; bold scores are served (0.5 or more).";
let verdict = "Against the golden set, at the current level: right (served, and gold implies it), wrong (served, not in gold), or missed (a gold label the level does not serve). Ancestors count, as in hierarchical F1.";

let creative = "Describe the ad in words. It becomes a creative profile, categories and keywords, matched against each page's context.";
let fit = "How well the creative matches the context at the slot: a logistic on the matcher score (taxonomy distance, keywords, product lift). A prior until engagement data replaces it.";
let reach = "Chance the slot is seen: e^(-y/6), y in viewports from the top. A prior.";
let p = "P = fit x reach, the slot's odds. Red is low, green is high.";
let blocked = "A hard rule refused the slot: an advertiser block, a Sensitive Topics label nearby, or no targeted category on the page.";
let flagged = "Blocks next to the slot that carry a sensitive label and caused the block, outlined in red.";
let outreach = "Over every crawled page, the best slot for this creative. Counts pages, not impressions.";
let threshold = "Minimum fit for a page to count as reached.";
let histogram = "Crawled pages by their best slot's fit, in 10% bins.";

let golden = "Hand-checked labels for a sample of pages: the yardstick for every calibration and for the T4 model choice.";
let gold = "The categories the judge says the page is about. Ancestors are implied: Soccer counts for Sports.";
let candidates = "The top 12 labels each level found itself, plus the judge's own additions. Untick the wrong ones, add what every level missed.";
let defaults = "An unjudged page starts with what the deep level scored 0.5 or more.";
let hp = "Hierarchical precision: of the served labels (ancestors added), the share that is in gold (ancestors added).";
let hr = "Hierarchical recall: of the gold labels (ancestors added), the share the level serves.";
let hf1 = "Harmonic mean of hierarchical precision and recall.";
let falsePositives = "Labels the level serves most often that the judge rejected.";
let missed = "Gold labels the level most often fails to serve.";
let shortcuts = "j / k: next / previous page. 1-9: toggle a row. Enter: save and next. d: reset to the deep defaults. /: search the taxonomy.";

let queued = "Pages waiting in the shared frontier, across every origin.";
let inFlight = "Pages a crawler has claimed and is fetching or classifying.";
let ok = "Pages fetched and classified since the counters started.";
let failed = "Fetches refused or broken: HTTP errors, robots.txt, timeouts.";
let stored = "Profiles in Valkey: what the online server and the bidder can read.";
let replicas = "Crawler processes that sent a heartbeat in the last 30 s, with what each crawled.";
let llm = "T4 calls to OpenRouter since the crawler started, and what they billed.";
let crawlPage = "Fetch and classify one page now, even if it is already stored.";
let crawlSite = "Discover a site through its sitemaps (or its home page links) and queue up to N pages, newest first.";
let bulk = "One URL per line. Already seen pages are skipped.";

let settledShare = "Share of pages where this level stopped because it was sure, not because it ran out of budget or tiers.";
let topCategories = "The categories pages are mainly about at this level: each page's best headline label, grouped.";

let all = [|
  ("Depth level", depth),
  ("zero_fetch", level("zero_fetch")),
  ("standard", level("standard")),
  ("rich", level("rich")),
  ("deep", level("deep")),
  ("T0", tier("t0")),
  ("T1", tier("t1")),
  ("T2", tier("t2")),
  ("T3", tier("t3")),
  ("T4", tier("t4")),
  ("Hierarchy", tier("hierarchy")),
  ("Settled", stop("settled")),
  ("Out of budget", stop("out of budget")),
  ("No more tiers", stop("no more tiers")),
  ("Score", score),
  ("Evidence", evidence),
  ("T4 gate", t4Gate),
  ("Sensitive Topics", sensitive),
  ("Format", format),
  ("Avoid Sensitive Topics", avoid),
  ("Fit", fit),
  ("Reach", reach),
  ("P", p),
  ("Blocked", blocked),
  ("Outreach", outreach),
  ("Golden set", golden),
  ("Gold", gold),
  ("hP / hR / hF1", hp ++ " " ++ hr),
  ("Shortcuts", shortcuts),
|];

let replay = "The page as the crawler fetched it (its WARC record), scripts off, at a phone's or a desktop's width. Each block the extractor found is outlined and shaded: by its score for the chosen label, by its worst Sensitive Topics score, or as main content against boilerplate.";
let measured = "Measured: slots are scored on the layout rendered here. Estimated: block heights guessed from text length on a 390 px phone.";
let boundary = "Where the slot's context stops. The page counts with a weight set by the format; the blocks around count with a weight that decays with distance, slower above (already read) than below (not yet seen). Anything sensitive in the co-visible window blocks the ad: suitability takes the worst case.";
let coVisible = "Co-visible window: what is on screen with the ad, one viewport above and below. A sensitive block here blocks the slot.";
let adSlot = "An ad container found in the page's HTML by its element id (GPT's div-gpt-ad-*, ad-slot, mpu...), the id a GPID ends with. Learned: the template's usual position, for pages whose slots are injected by script.";
let heuristicSlot = "No ad container in the HTML: candidate slots after each main paragraph, image or embed.";
