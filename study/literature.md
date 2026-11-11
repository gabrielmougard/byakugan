# Literature and prior art

Checked on 2026-11-04. Research agents checked each entry against a primary source: the paper, RFC, spec, model card, opam page or official pricing page. Tags used below:

- **[UNVERIFIED]**: could not be checked; treat as a lead, not a fact.
- **(vendor claim)**: a first-party number with no published method.
- **est.**: our own arithmetic, not a published figure.

Each entry ends with where it fits in our design (see [architecture.md](architecture.md) for the full description of each tier):

| Key | Meaning |
|---|---|
| T0 | URL and pre-fetch hints (no fetch) |
| T1 | fetch, then lexical/ontology matching |
| T2 | small encoders and embeddings |
| T3 | media models: image, audio and video turned into text or vectors |
| T4 | LLM/VLM, the "System 2" tier |
| M | online page↔creative matching |

---

## 0. The literature in ten points

1. **A small summary carries most of the signal.** A summary of URL, title, meta, H1/H2 and the first 500 bytes (about 5% of the page) keeps 97–99% of full-page ad-matching relevance (Anagnostopoulos et al. 2007). The URL alone gets 76% accuracy against 78% for the full text (Kan & Thi 2005), or F 80–85 (Baykan et al. 2011). The cheapest tiers therefore do most of the work.
2. **Taxonomy plus lexical beats either alone.** Broder et al. 2007 score α·taxonomy + (1−α)·cosine, backing off through the lowest common ancestor.
3. **LLMs are poor at choosing among 700 labels cold, but good labellers and rerankers.** Zero-shot accuracy on IAB 2.2 is 34% (Kamen 2025). Distilling LLM labels into a 140M–600M encoder gives roughly 90% or better agreement with the teacher at under 1% of the cost (WebOrganizer, FineWeb-Edu, TELEClass).
4. **Nearest-label embedding is a strong candidate generator.** On synthetic Content Taxonomy 3.1 pages it gets 75% top-1 and 94.5% top-5 (IAB Tech Lab classifier, EmbeddingGemma-300M).
5. **Cascades remove 60–90% of LLM calls on coarse labels, but only 17–30% on hard ones** (Online Cascade Learning). Good calibration and quality estimates matter more than a clever router (Dekoninck et al. 2025; LLMRouterBench 2026).
6. **Text dominates topic classification.** On N24News, adding the image lifts full-body accuracy only from 88.9% to 91.1%, but lifts headline-only accuracy from 72.0% to 79.4%. Images matter when text is thin. About 7% of pages contain `<video>`.
7. **For multimodal, use separate experts and late fusion.** This matches jointly trained models (ContextIQ, WACV 2025). Turning each medium into text (ASR, OCR, captions, tags) adds about 4–6 average-precision points per modality.
8. **LLM rationales are not explanations** (Turpin et al. 2023). Faithful explanations come from additive models over named features. Here the IAB taxonomy itself is the concept bottleneck, backed by quotes that can be checked against the page (AIS).
9. **Learning from feedback adds 12–25% on top of relevance** (Chakrabarti 2008; LinUCB 2010). But matching the content and using an obtrusive format can cancel each other out (Goldfarb & Tucker 2011), which matters for rich-media and high-impact formats.
10. **The economics have changed.** At Nov-2026 batch prices, running the cheapest LLM over every condensed page costs about $75–160 per 1M pages. The cascade buys throughput, determinism, explainability, data control, and headroom to spend mid-tier models on the hard few percent. It is not only about the dollars.

---

## 1. Contextual advertising: information-retrieval classics

- **Ribeiro-Neto et al., "Impedance coupling in content-targeted advertising", SIGIR 2005.** https://doi.org/10.1145/1076034.1076119
  - Requiring the ad's keywords to appear on the page gave +60% average precision over plain cosine.
  - Expanding page vocabulary from similar pages added +50%.
  - Names the page/ad vocabulary gap ("impedance").
  - *Fits:* T1 and M. Our dense tier exists to close this gap; see the "vocabulary gap" test.
- **Yih, Goodman, Carvalho, "Finding advertising keywords on web pages", WWW 2006.** https://archives.iw3c2.org/www2006/programme/files/xhtml/533/fp533-yih/fp533-yih-xhtml.html
  - Logistic regression over candidate phrases. Top-1 score 30.06, against 23.57 for KEA and 13.01 for TF-IDF.
  - Query-log frequency was the strongest feature.
  - *Fits:* T1 keyword extraction needs a commercial prior, for us our own line-item and advertiser terms.
- **Broder, Fontoura, Josifovski, Riedel, "A semantic approach to contextual advertising", SIGIR 2007.** https://fontoura.org/papers/semsyn.pdf
  - Pages and ads go into a 6,000-node taxonomy using a Rocchio centroid classifier, which beat hierarchical SVM and logistic regression.
  - Score = α·TaxScore + (1−α)·cosine, with LCA backoff.
  - Classification precision: 70% for pages, 86% for ads. About 25% precision lift at mid recall.
  - *Fits:* the blueprint for T1/T2 plus M.
- **Anagnostopoulos, Broder, Gabrilovich, Josifovski, Riedel, "Just-in-time contextual advertising", CIKM 2007.** https://www.gabrilovich.com/publications/papers/Anagnostopoulos2007JIT.pdf
  - A summary of URL, title, meta, H1/H2 and the first 500 bytes keeps 97–99% of relevance.
  - *Fits:* the strongest evidence for a cascade that starts at T0/T1.
- **Murdock, Ciaramita, Plachouras, "A noisy-channel approach to contextual advertising", ADKDD 2007.** https://dblp1.uni-trier.de/rec/conf/adkdd/0001CP07.html
  - Translation features bridge the page/ad vocabulary gap.
  - *Fits:* superseded by embeddings.
- **Chakrabarti, Agarwal, Josifovski, "Contextual advertising by combining relevance with click feedback", WWW 2008.** https://archives.iw3c2.org/www2008/papers/pdf/p417-chakrabarti.pdf
  - Logistic regression over page/ad word matches, learned from clicks, kept in a form that inverted indexes can still serve.
  - +25% precision at 10% recall.
  - *Fits:* M, as the learned blend in `matcher.ml`.
- **Broder et al., "To swing or not to swing: learning when (not) to advertise", CIKM 2008.** https://dblp.uni-trier.de/rec/conf/cikm/BroderCFGJMMP08.html
  - A classifier learns when to show no ad at all.
  - *Fits:* M needs an explicit abstain.
- **Fan & Chang, "Sentiment-oriented contextual advertising", Knowledge and Information Systems 2010.** https://doi.org/10.1007/s10115-009-0222-2
  - Advertise against positive or neutral context only.
  - *Fits:* a suitability gate at T1/T2.

## 2. Modern contextual and ad-understanding work

- **ContextIQ (Anoki), Chaubey et al., WACV 2025.** https://arxiv.org/abs/2410.22233
  - One expert per modality:
    - BLIP-2 on 15-second segments
    - CLAP on 5-second audio chunks
    - MPNet on transcripts
    - YOLO, Places365, actions, NER, emotion, profanity and hate speech
  - Late fusion of z-scored modality scores, with scene detection for long video.
  - On MSR-VTT it is on par with Google Vertex. Audio, captions and metadata each add +4–6 AP.
  - No latency or cost figures are published.
  - *Fits:* the template for T3 video.
- **Hussain et al., "Automatic Understanding of Image and Video Advertisements", CVPR 2017.** https://arxiv.org/abs/1707.03067
  - 64,832 image ads and 3,477 video ads, labelled for topic, sentiment and symbolism.
  - *Fits:* creative-side labels.
- **MM-AU, Bose et al., ACM MM 2023.** https://arxiv.org/abs/2308.14052
  - 8.4K ad videos, with topic, tone and social message.
- **VideoAds (ICCV 2025)** https://arxiv.org/abs/2504.09282 and **AdsQA (ICCV 2025)** https://arxiv.org/abs/2509.08621
  - On VideoAds: Qwen2.5-VL-72B 73.35%, Gemini-1.5 Pro 69.66%, human experts 94.27%.
  - *Fits:* VLMs are usable at T4 for creatives, with review.
- **Ads relevance distilled from LLM labels**
  - Bing: https://arxiv.org/abs/2309.10621
  - Pinterest: https://arxiv.org/abs/2410.17152
  - eBay LLMDistill4Ads: https://arxiv.org/abs/2508.03628
  - Meituan (WWW 2026): https://arxiv.org/abs/2510.11056
  - The pattern is the same everywhere: an LLM teacher, then a small servable student.
  - *Fits:* the distillation loop from T4 into T2.
- **Kamen, "Order from Chaos", arXiv 2510.13885 (2025).** https://arxiv.org/abs/2510.13885
  - Ten LLMs classifying zero-shot into IAB 2.2: 34% accuracy, 41% F1 on average.
  - *Fits:* T4 must only rerank a shortlist; see `Tier.candidates`.
- **IAB Tech Lab `iab-taxonomy-classifier`.** https://github.com/IABTechLab/iab-taxonomy-classifier
  - 704 synthetic pages classified by nearest label embedding.
  - EmbeddingGemma-300M or bge-base: 75.0% top-1, 94.5% top-5. EmbeddingGemma at 256 dimensions: 72.0% / 92.8%.
  - *Fits:* the T2 baseline and candidate generator. Expect lower accuracy on real pages.
- **Jin et al., wiki2cat (TextGraphs @ NAACL 2021).** https://arxiv.org/abs/2102.06429
  - Builds IAB training text from the Wikipedia category graph.
  - *Fits:* cheap multilingual data for T1/T2.
- **Amazon DSP contextual whitepaper (Feb 2025).** https://ppc.land/content/files/2025/02/Amazon_DSP_AI_powered_contextual_techniques_technical_whitepaper.pdf
  - LLM content understanding with a product-category taxonomy and its own robots-respecting crawler. Reports +25% engagement (vendor claim).
- **Embedding retrieval: Huang et al., KDD 2020.** https://arxiv.org/abs/2006.11632
  - *Fits:* M. Our creative pool is small, so brute-force scoring is fine.
- **Contextual bandits**
  - LinUCB (Li et al., WWW 2010; https://arxiv.org/abs/1003.0146): +12.5% clicks.
  - Hill et al., KDD 2017 (https://arxiv.org/abs/1810.09558): multivariate creative bandit, +21% conversions.
  - "Bandits for taxonomies" (Pandey et al., SDM 2007).
  - *Fits:* M exploration. Log the propensities.

## 3. Industry systems

All of these are vendor claims, and none publishes per-URL accuracy or explanations.

| Vendor | What they say publicly |
|---|---|
| GumGum (Verity / Mindset Graph) | Text, image, video and audio, tone and sentiment. Claims "2.3× more memorable" (vendor claim). No method given. |
| Seedtag LIZ | "Neuroscience-based" AI, 40+ models, 100M+ URLs a day (vendor claim). |
| Peer39 | 4,300+ categories, sentiment, made-for-advertising (MFA) detection, CTV, 40+ languages. |
| IAS | Pre-bid page-level classification; video analysed through metadata, scripts and visuals. |
| DoubleVerify | "Universal Content Intelligence", AI plus human review. MRC accreditation covers **property-level** suitability, not page level. |
| Oracle Contextual Intelligence | Oracle left advertising on 30 Sep 2024 [UNVERIFIED: oracle.com returned 403]. |
| Silverpush Mirrors, Kerv | Video and frame-level suitability or shoppable products (vendor claims). |
| Illuma, Mantis | [UNVERIFIED] |
| Mixpeek | Multimodal IAB classification. Donated an open-source 2.x→3.x mapper to IAB Tech Lab in 2026. |

**Opening for us:** no vendor publishes accuracy or per-page explanations, so an explainable classifier is a real differentiator.

## 4. Standards and the ecosystem

- **IAB Tech Lab Content Taxonomy 3.1** (`cattax=9`). TSV: https://github.com/InteractiveAdvertisingBureau/Taxonomies/blob/main/Content%20Taxonomies/Content%20Taxonomy%203.1.tsv
  - 704 nodes, 37 tier-1, up to 4 tiers. 63 rows carry the SCD flag ("Special Category Data").
  - Has a tier-1 **Sensitive Topics** node (`v9i3On`) with 11 children inherited from GARM:
    - Adult
    - Arms
    - Crime & Harmful Acts
    - Death/Injury/Military Conflict
    - Debated Social Issues
    - Hate Speech
    - Drugs/Tobacco/Alcohol
    - Obscenity
    - Piracy
    - Spam
    - Terrorism
  - Released Dec 2024; the TSV was last touched in Jul 2025. There is no official 2.x→3.x mapping file; IAB points to its open-source mapper.
  - The prototype uses real IDs from this file.
- **Ad Product Taxonomy 2.0** (`cattax=8`, about 584 nodes): what a creative sells. TSV: https://github.com/InteractiveAdvertisingBureau/Taxonomies/blob/main/Ad%20Product%20Taxonomies/Ad%20Product%20Taxonomy%202.0.tsv
  - Examples: Footwear 1070, Beer 1004, Electric Vehicles 1571.
  - The repository README states CC BY 3.0.
- **OpenRTB 2.6 / AdCOM**
  - `site.cat`, `sectioncat`, `pagecat` and `cattax`; `keywords` or `kwarray`.
  - `site.content.*`: `url`, `title`, `cat`, `context`, `language`, `data[]` segments with `segtax`.
  - `bcat`/`acat`, and `bid.cat`.
  - *Fits:* T0 hints, and the fields we emit.
- **IAB Tech Lab 2025–2026 work**
  - **ARTF v1.0** (Agentic RTB Framework): gRPC containers that run inside the exchange, with actions such as `ACTIVATE_SEGMENTS` and `ACTIVATE_DEALS`.
  - **CoMP** (formerly LLM Content Ingest): terms for AI crawlers to access content.
  - **AdCP** (Ad Context Protocol, 15 Oct 2025; Yahoo, PubMatic, Scope3 and others) is *not* an IAB standard. It is agentic *buying* context on MCP/A2A, not page classification.
- **GARM** was shut down by the WFA on 8 Aug 2024. Its categories live on as IAB "Sensitive Topics". Audits now go through TAG and MRC.
- **Google Topics API**
  - 469-topic taxonomy v2, assigned by a **hostname-only** on-device classifier.
  - Privacy Sandbox retirement announced 17 Oct 2025.
  - *Lesson:* hostname-level classification is only T0 quality. The value is at page level.

## 5. Does context congruence actually work?

The evidence is mixed. Design for measurement, not belief.

- **Moorman et al., J. Advertising 2002.** https://doi.org/10.1080/00913367.2002.10673683 Congruent magazine ads were remembered better.
- **Zanjani et al., J. Advertising 2011.** https://doi.org/10.2753/JOA0091-3367400405 Congruence helped readers who were looking for information, not casual browsers.
- **Dahlén et al., J. Advertising 2008.** https://doi.org/10.2753/JOA0091-3367370305 Incongruent placements were sometimes processed more, depending on brand familiarity.
- **Goldfarb & Tucker, Marketing Science 2011.** https://doi.org/10.1287/mksc.1100.0583 Contextual match and obtrusive formats each lifted purchase intent, but **not together**, apparently because of privacy concerns. This is directly relevant to rich-media formats: A/B test relevance against format.
- **Kwon et al., JAR 2019 (meta-analysis).** https://doi.org/10.2501/JAR-2018-016 Context affects memory; the overall picture is mixed.
- **Rafieian & Yoganarasimhan, Marketing Science 2021.** https://doi.org/10.1287/mksc.2020.1235 [UNVERIFIED claim: behavioural data was more valuable than contextual data for CTR]

## 6. Crawling, discovery and extraction

- **Sitemaps protocol.** https://www.sitemaps.org/protocol.html
  - At most 50,000 URLs and 50 MB per file; indexes; `lastmod` in W3C datetime.
  - **Google extensions:**
    - news: title, language, publication date, last 2 days, at most 1,000 entries
    - video: title, description up to 2,048 characters, `video:tag`, `family_friendly`
    - image: only `image:loc` survives the 2022 cleanup; caption and title are dead
    - `news:keywords` is no longer documented, but still parse it when present
  - https://developers.google.com/search/docs/crawling-indexing/sitemaps/news-sitemap
  - *Fits:* T0 hints for free.
- **lastmod reliability.** Bing (2023): 84% of sitemaps set lastmod; 79% of values are correct, 18% wrong. Google uses lastmod only when "consistently and verifiably accurate". *Fits:* score each host's lastmod against our own content hashes.
- **Schonfeld & Shivakumar, "Sitemaps: above and beyond the crawl of duty", WWW 2009.** https://doi.org/10.1145/1526709.1526842 Of URLs seen by both, 78% were discovered first through sitemaps (figure from a secondary source).
- **RFC 9309, robots.txt (2022).** https://www.rfc-editor.org/rfc/rfc9309.html
  - Longest match wins.
  - Parse at least 500 KiB; cache for at most 24 h.
  - 4xx means allow; 5xx means disallow.
  - Crawl-delay is not in the RFC; honour it anyway, as ad-tech crawlers do.
- **Mercator, Heydon & Najork 1999.** https://doi.org/10.1023/A:1019213109274
  - A FIFO queue per host and 64-bit fingerprints. 8.5% exact duplicates.
  - *Fits:* our frontier design. IRLbot (WWW 2008) is web-scale engineering we can skip.
- **Cho & Garcia-Molina, "Effective page refresh policies" (TODS 2003) and "Estimating frequency of change" (TOIT 2003).** https://doi.org/10.1145/958942.958945 and https://doi.org/10.1145/857166.857170
  - Estimate a change rate per URL, and do not chase pages that change faster than they can be revisited.
  - Kolobov et al. (SIGIR 2019) add politeness constraints and release code and Bing data.
- **JS rendering.** Zyte (Oct 2026): 40.6% of top landing pages need JS; rendering costs 10–50× a fetch. No article-specific measurement exists. *Fits:* render only when extraction comes back short.
- **Near-duplicates**
  - SimHash: Charikar, STOC 2002.
  - Manku et al., WWW 2007 (https://doi.org/10.1145/1242572.1242592): 64-bit SimHash with Hamming distance k=3 at 8B pages.
  - MinHash: Broder 1997.
  - Henzinger, SIGIR 2006: combining both gives 0.79 precision.
  - *Fits:* SimHash of the **extracted main text** gates reclassification. Use `Int64`, because OCaml `int` is 63-bit.
- **Bevendorff et al., "An Empirical Comparison of Web Content Extraction Algorithms", SIGIR 2023.** https://doi.org/10.1145/3539618.3591920

  | Extractor | Mean F1 |
  |---|---|
  | Trafilatura | 0.883 |
  | Readability | 0.861 |
  | Resiliparse | 0.859 |
  | Boilerpipe | 0.834 |
  | plain HTML-to-text | 0.738 |

  Heuristic extractors win, and neural ones were "surprisingly bad". Trafilatura (ACL 2021): https://aclanthology.org/2021.acl-demo.15. Boilerpipe (WSDM 2010): https://doi.org/10.1145/1718487.1718542, using shallow features at almost no cost.
  - *Fits:* port Boilerpipe-style scoring to OCaml and use Trafilatura as the evaluation reference.
- **LLM-based extractors** such as ReaderLM-v2 (https://arxiv.org/abs/2503.01151) and Dripper/MinerU-HTML (https://arxiv.org/abs/2511.23119). Their scores depend heavily on the benchmark. *Fits:* last resort only.
- **Structured data prevalence**
  - Web Almanac 2024 (https://almanac.httparchive.org/en/2024/structured-data): JSON-LD on 41% of pages, Open Graph on 64%.
  - Web Data Commons (Oct 2024): 52% of pages carry structured data.
  - Yoast puts categories in `articleSection` and tags in `keywords`.
  - *Fits:* free T1 labels on WordPress publishers.
- **URL-only classification**
  - Kan & Thi, CIKM 2005 (https://www.comp.nus.edu.sg/~kanmy/papers/cp689-kan.pdf): 76.18% from the URL against 78.39% from full text.
  - Baykan et al., TWEB 2011 (https://doi.org/10.1145/1993053.1993057): F 80–85, or above 90% precision at 30–40% recall.
  - *Fits:* T0, run at the high-precision setting.
- **Common Crawl.** A monthly crawl of 2.1–2.6B pages with CDX and Parquet indexes. *Fits:* cold-start and long-tail backfill only. It is weeks old and premium news sites block CCBot.
- **Bot access, 2025–2026**
  - Cloudflare's verified-bot policy has an "Advertising & Marketing" category, separate from "AI Crawler": https://developers.cloudflare.com/bots/concepts/bot/verified-bots/categories/
  - Web Bot Auth: RFC 9421 signatures, IETF draft as of Oct 2026.
  - IETF aipref vocabulary (`train-ai`, `ai-use`, `search`): classifiers fall outside "generative AI", but an LLM tier that reads pages is plausibly `ai-use`.
  - RSL 1.0 `License:` line.
  - About 60% of reputable sites block at least one AI crawler (WWW 2026, https://arxiv.org/abs/2510.10315).
  - **Precedent:** Criteo's crawler page (https://criteo.com/criteo-crawler/) shows a named user agent, published IP ranges, crawl-delay up to 30 s, and refetching only when categories go stale.

## 7. Text ML: cheap to expensive

### Cascades and deferral
- **FrugalGPT, Chen, Zaharia, Zou, TMLR 2024.** https://arxiv.org/abs/2305.05176 A learned scorer escalates along an LLM chain; up to 98% cheaper (2023 prices).
- **Gupta et al., "Language Model Cascades: token-level uncertainty and beyond", ICLR 2024.** https://arxiv.org/abs/2404.10136 A learned deferral rule beats max-probability thresholds.
- **Nie et al., "Online Cascade Learning", ICML 2024.** https://proceedings.mlr.press/v235/nie24a.html
  - LogReg → BERT → LLM. The small models imitate the LLM online, with a no-regret bound.
  - Saves 70–90% of LLM cost on easy tasks, 17–30% on hard ones.
  - *Fits:* the closest blueprint for our page stream.
- **Ramírez et al., "Cache & Distil", Findings of ACL 2024.** https://aclanthology.org/2024.findings-acl.704 The student is retrained every 1K LLM labels; margin or committee-disagreement selection beats random. *Fits:* every escalation doubles as active learning.
- **Kolawole et al., Agreement-Based Cascading, TMLR 2025.** https://arxiv.org/abs/2407.02348 Defer when the ensemble at a tier disagrees. *Fits:* T1/T2 disagreement as a deferral feature.
- **AutoRelAnnotator, SIGIR 2026 eCom.** https://arxiv.org/abs/2606.25871 A production ads-relevance cascade: roughly accuracy-neutral at half the compute, plus 0.6 points from per-class isotonic calibration.
- **Further reading**
  - Dekoninck et al., ICML 2025 (https://arxiv.org/abs/2410.10347): quality estimators are "the critical factor".
  - LLMRouterBench 2026 (https://arxiv.org/abs/2601.07206): routers rarely beat simple baselines.
  - Zellinger & Thomson, TMLR 2025 (https://arxiv.org/abs/2501.09345): multi-tier thresholds.
  - Conformal Cascade (https://arxiv.org/abs/2607.25018): single-label coverage guarantee.
  - RouteLLM, Hybrid LLM and AutoMix target open-ended generation; skip them.

### Teach with an LLM, then distil
- **Gilardi et al., PNAS 2023.** https://doi.org/10.1073/pnas.2305016120 ChatGPT beat MTurk by about 25 points, at about 30× lower cost.
- **Wang et al., "Want to reduce labeling cost? GPT-3 can help", Findings of EMNLP 2021.** https://aclanthology.org/2021.findings-emnlp.354
- **Hsieh et al., "Distilling step-by-step", Findings of ACL 2023.** https://arxiv.org/abs/2305.02301 Rationales as extra training targets. Our analogue: the evidence spans the LLM cites.
- **WebOrganizer, Wettig et al., ICML 2025.** https://arxiv.org/abs/2502.10341
  - Labels from Llama 8B, then from 405B, distilled into a 140M gte-base with URL features.
  - 93.5% agreement with the teacher on topic.
  - *Fits:* **the best public template for our T2.**
- **FineWeb-Edu classifier.** https://huggingface.co/HuggingFaceFW/fineweb-edu-classifier 450K Llama-70B labels train a linear head on a frozen embedding (F1 0.82).
- **TELEClass, Zhang et al., WWW 2025.** https://arxiv.org/abs/2403.00165
  - An LLM enriches the taxonomy; a cheap classifier is trained from that.
  - Example-F1: 0.648 on Amazon-531 (GPT-4: 0.699), 0.863 on DBPedia-298 (GPT-4: 0.605).
  - Inference under $1, against $800–2,500 for GPT-4.
  - *Fits:* how we build the T1 lexicon and bootstrap T2.
- **Related:** LOTClass (https://arxiv.org/abs/2010.07245), TaxoClass (NAACL 2021) and SetFit (https://arxiv.org/abs/2209.11055: 8 examples per class match 3K).
- **GLiClass** (https://arxiv.org/abs/2508.07662) and GLiNER: label-count-insensitive zero-shot. *Fits:* shortlist reranker or fallback only.

### Cheap semantic models (T2)

| Model | Fact | Fits |
|---|---|---|
| **Model2Vec** potion-base-8M/32M (https://github.com/MinishLab/model2vec, MIT) | MTEB classification 70.3–71.7 (all-MiniLM-L6: 69.3); "up to 500× faster on CPU" | **T2a in pure OCaml**: a table lookup plus a mean (`vec.ml`) |
| Sentence-Transformers static multilingual (HF blog, Jan 2025) | 86.5% of multilingual-e5-small on classification, about 125× faster | multilingual T2a |
| EmbeddingGemma-300m (https://arxiv.org/abs/2509.20354) | MMTEB 61.15 at 768 dimensions, 58.23 at 128 | T2b; check the Gemma terms |
| Qwen3-Embedding-0.6B (https://arxiv.org/abs/2506.05176, Apache-2.0) | MMTEB 64.33 | best permissive small embedder |
| ModernBERT (https://arxiv.org/abs/2412.13663) / mmBERT (https://arxiv.org/abs/2509.06888) | 8K context, fast; mmBERT covers 1,800+ languages | fine-tuning backbones for the 704-way sigmoid head |
| Matryoshka (https://arxiv.org/abs/2205.13147); int8 and binary quantisation (HF blog 2024) | int8 keeps about 97% of retrieval quality at 4× smaller | page-embedding store and neural cache |

### "System 1" decision models (Laya, Jev)
- **Laya** (Convai Innovations, released 2026-09-18, Apache-2.0). https://huggingface.co/convaiinnovations/laya and https://github.com/NandhaKishorM/laya
  - **Architecture:** ModernBERT-large (395M) plus a decision head, 421M in total.
  - **Interface:** you ask typed questions over a text or JSON state:
    - `choice`
    - `score`, ordinal
    - `noul`, which returns P(true)

    All options are scored in one forward pass, with no generation.
  - **Training:** reinforcement learning against proper scoring rules, plus a soft teacher.
  - **Context:** 512 tokens; 1,024 for typed-decisions; 8,192 for the multilingual mmBERT variant.
  - **Latency on a T4:** about 33–40 ms per question, 7.2 ms batched.
  - **Calibration:** the cards say it ships over-confident. Refitting temperatures cut ECE from 0.466 to 0.081.
  - **The headline 0.766** is a checkpoint fine-tuned on the vendor's own synthetic benchmark. It is above the 0.735 "teacher ceiling" the card itself states.
  - **Zero-shot** it scores 0.362, below the 0.461 majority-class baseline.
  - **Label space:** keep `choice` under about 20 options. On Banking77 it scores 0.425 against Jev's 0.870. Multi-label is undocumented.
- **Jev** (TypeSafe AI, closed API). https://typesafe.ai Same question types, about $0.042 per million input tokens, up to 255 options.
- **Verdict:** the "System 1 / System 2" framing *is* our cascade (T0–T3 are System 1, T4 is System 2). Laya is the wrong model for the 704-node multi-label taxonomy over long pages. A fine-tuned ModernBERT or mmBERT with a 704-way sigmoid head is the same backbone, done right.
  - **Where Laya does fit:** after T2, as a fine-tuned and recalibrated head for low-cardinality typed decisions:
    - brand-suitability flags (`noul`)
    - risk level (`score`)
    - tier-1 vertical (`choice`, 37 options)
    - "does this page need System 2?"
  - New advertiser questions need no new head.
  - Skip Jev for bulk offline work: it is closed, sends data out, and costs about as much as nano LLMs.

### Calibration and guarantees
- **Temperature scaling** (Guo et al., ICML 2017; https://proceedings.mlr.press/v70/guo17a) by default; per-class isotonic for frequent labels.
- **Selective classification** (Geifman & El-Yaniv 2017; https://arxiv.org/abs/1705.08500): the accept threshold per tier.
- **Conformal Risk Control** (https://arxiv.org/abs/2208.02814) and **RCPS** (https://arxiv.org/abs/2101.02703): label-set thresholds with a bounded rate of missed labels.
- **Learn-then-Test** (https://arxiv.org/abs/2110.01052): joint thresholds with risk control.
- **Clustered conformal** (https://arxiv.org/abs/2306.09335): the long tail of IAB.
- **Trust or Escalate** (ICLR 2025; https://arxiv.org/abs/2407.18370): guaranteed agreement with humans.
- **Recipe:** temperature-scale each tier; use CRC for label sets; use Learn-then-Test for deferral thresholds, clustered by IAB branch; recalibrate on drift. The guarantees hold only against the gold labels you calibrated on.

### Keywords and entities
- **Cheap keyword extraction (T1):** YAKE (Information Sciences 2020) and TextRank (EMNLP 2004, https://aclanthology.org/W04-3252/). Both are easy to write in OCaml. KeyBERT is nearly free once T2 embeddings exist.
- **ReFinED** (https://aclanthology.org/2022.naacl-industry.24): single-pass entity linking at Wikidata scale, more than 60× faster than prior systems. *Fits:* the default T2 entity linker.
- **Other linkers:** ReLiK (Findings of ACL 2024) and GLiNER (zero-shot entity spans, Apache-2.0).
- **Wikidata** (CC0) is the backbone for entity IDs and aliases. We curate the mapping from Wikidata IDs to IAB nodes ourselves.

## 8. Explainability

- **Concept Bottleneck Models**
  - CBM (Koh et al., ICML 2020): predict named concepts, then the label from them.
  - Label-free CBM (ICLR 2023) and LaBo (CVPR 2023): concepts generated by an LLM.
  - Text Bottleneck Models (https://arxiv.org/abs/2310.19660).
  - CB-LLM (ICLR 2025, https://arxiv.org/abs/2412.07992): 0.945 on AG News against RoBERTa's 0.951.
  - *Verdict:* **the IAB taxonomy already is the concept set.** Score each node with named features (lexicon terms, entities, similarity to the enriched node description), then combine with an additive head. That is faithful by construction.
- **SPLADE** (SIGIR 2021, https://arxiv.org/abs/2107.05720): sparse, term-weighted vectors whose scores decompose per term.
- **Turpin et al., NeurIPS 2023.** https://arxiv.org/abs/2305.04388 Chain-of-thought omitted the biasing feature that cut accuracy by up to 36%. Reasoning models mention the hints they used less than 20% of the time (https://arxiv.org/abs/2505.05410). *Verdict:* rationales are claims.
- **AIS** (Rashkin et al., Computational Linguistics 2023; https://aclanthology.org/2023.cl-4.2/): judge attribution against the source. We check mechanically that a quoted span exists on the page (`Tier.judge`).
- **ERASER** (ACL 2020, https://arxiv.org/abs/1911.03429): offline test that removing the evidence should lower confidence.
- **Sparse autoencoders** on embeddings (https://arxiv.org/abs/2408.00657): later research, not v1.

## 9. Multimodal: image, audio, video

### Free media signals first
- **Alt text is sparse and noisy.** About 30% of `img` alts are empty, and about 50% are empty or 10 characters or fewer (Web Almanac 2025, https://almanac.httparchive.org/en/2025/accessibility). Use alt text only if it is at least 20 characters and not a filename; `Tier.undescribed` applies this rule.
- **Video is rare.** `<video>` appears on 6.7–7.7% of pages, and JSON-LD `VideoObject` on only 0.34% (Web Almanac 2024). YouTube embeds on 6.2% of home pages (WebAIM 2026). *Fits:* route those pages; don't run video models everywhere.
- **schema.org `VideoObject`** has a `transcript` field. When present, it replaces ASR.
- **YouTube Data API:** `topicDetails.topicCategories` (Wikipedia URLs), `tags`, a caption flag and `madeForKids`. Captions for videos we don't own **cannot** be downloaded. Downloading the media is restricted by YouTube's terms of service [not re-verified].
- **Podcasting 2.0** `podcast:transcript`; adoption is [UNVERIFIED].

### Image
- **CLIP** (https://arxiv.org/abs/2103.00020): prompt ensembles add 3.5–5 points.
- **SigLIP 2** (https://arxiv.org/abs/2502.14786): B, L, So400m and g sizes; multilingual. *Fits:* default T3 image encoder.
- **Perception Encoder** (NeurIPS 2025, Apache-2.0; https://arxiv.org/abs/2504.13181): the commercially safe choice.
- **Avoid commercially:** MobileCLIP and MobileCLIP2 (Apple research licence), jina-clip-v2 (CC BY-NC), ImageBind (CC BY-NC), Qwen2.5-VL-3B (non-commercial).
- **Florence-2** (https://arxiv.org/abs/2311.06242): 0.23B/0.77B, does captioning and OCR. *Fits:* the cheapest captioner for images without free text.
- **PaddleOCR 3.0** (https://arxiv.org/abs/2507.05595): about 1.75 s per image on CPU. **OCR costs about 100× an embedding**, so gate it behind a "text-heavy image" probe.
- **Small VLMs**
  - Qwen3-VL 2B/4B/8B (Apache-2.0, https://arxiv.org/abs/2511.21631): the default self-hosted T4.
  - Gemma 4 E2B/E4B (Apache-2.0): text, image and audio input.
  - SmolVLM (https://arxiv.org/abs/2504.05299): too weak for about 700 classes.
- **Image brand safety**
  - Marqo nsfw-image-detection-384: ViT-tiny, Apache-2.0.
  - UnsafeBench (https://arxiv.org/abs/2405.03486): standard classifiers reach only F1 0.6–0.7, so use it as our evaluation set.
  - ShieldGemma 2 (https://arxiv.org/abs/2504.01081) and LlavaGuard (ICML 2025) give rationales. *Fits:* T4 adjudicators for flagged images.
- **N24News** (https://arxiv.org/abs/2108.13327): text dominates; the image is decisive only for thin text.

### Audio
- **Open ASR Leaderboard** (https://arxiv.org/abs/2510.06961; A100):

  | Model | Avg WER | RTFx |
  |---|---|---|
  | Parakeet-TDT-0.6B-v3 | 6.32 | 3,333 |
  | Whisper large-v3 | 7.44 | 146 |

  Parakeet covers 25 European languages under CC-BY-4.0; Whisper covers everything else. Distil-Whisper is 5.8× faster. Moonshine (27M/61M) handles CPU short clips. faster-whisper small on CPU runs at about 15× real time.
- **Gate before ASR:** Silero VAD takes under 1 ms per chunk. inaSpeechSegmenter splits speech, music and noise.
- **Audio tagging**
  - The AudioSet ontology (632 classes, 527 labelled) is an **explainable intermediate ontology**: tags such as Gunshot, Siren and Crowd map to IAB and suitability.
  - EfficientAT (0.47–0.48 mAP from a small CNN), BEATs (50.6 mAP) and PANNs.
  - CLAP (LAION https://arxiv.org/abs/2211.06687; Microsoft https://arxiv.org/abs/2309.05767) for zero-shot sounds.
  - PE-AV (Dec 2025, https://arxiv.org/abs/2512.19687) for joint audio-video-text embeddings.

### Video
- **Shot detection:** PySceneDetect (CPU, adaptive detector F1 91.6 on BBC); TransNet V2 for gradual transitions.
- **Video encoders:** VideoPrism (B 114M / L 354M). InternVideo2 (6B) is too costly; X-CLIP is superseded.
- **Video LLMs:** Gemini samples video at 1 fps, about 300 tokens/s (about 100 at low resolution), and accepts public YouTube URLs. *Fits:* the sanctioned way to analyse YouTube pixels on valuable pages. Self-hosted Qwen3-VL-8B at 1 fps is the alternative.

## 10. OCaml ecosystem (opam, Nov 2026)

| Need | Pick | Why |
|---|---|---|
| HTML and XML | `lambdasoup` + `markup` | pure OCaml, follows the HTML5 spec. The prototype chose vendored lexbor (C) instead, for speed ([study](html_parser.md)) |
| HTTP | `curl` + `curl_lwt` 0.10.1 | libcurl brings TLS, HTTP/2, keep-alive, decompression and caps; it is Ahrefs' stack. `cohttp-eio` is HTTP/1.1 only; `piaf` is inactive |
| Concurrency | `lwt` 6.1 (matches `curl_lwt` and `redis-lwt`); one process per core for CPU stages | |
| JSON-LD and API | `yojson` 3.0 | |
| Protobuf | `ocaml-protoc-plugin` 6.3 | a protoc plugin, so it fits the repo's `buf generate` and CI drift check |
| Redis | `redis-lwt` | |
| `.xml.gz` sitemaps | `camlzip` 1.14 | |
| GCS | none: JSON API over libcurl with a metadata-server token | |
| Unicode | stdlib UTF + `uunf` + `uuseg` | `uutf`'s own page advises against using it |
| Static embeddings | `Unix.map_file` → Bigarray | |
| Transformers | ONNX Runtime or Triton **sidecar** | nothing on opam; `torch` is stale (libtorch 2.1); the `brot` tokenizer is alpha |

**Precedent:** Ahrefs runs "OCaml as the primary language for all crawling and data processing". They report 1.5M lines of OCaml, 4,000+ servers and 492.7B pages indexed (https://ocaml.org/success-stories/petabyte-scale-web-crawling-and-data-processing). Their open-source `devkit` is built on lwt, curl and yojson.

## 11. LLM prices (official pages, fetched 2026-11-04; $ per million tokens)

| Model | Input | Output | Batch in / out |
|---|---|---|---|
| Claude Haiku 5.5 (≤100K-token prompt) | 0.10 | 0.50 | 0.05 / 0.25 |
| Claude Haiku 4.5 | 1.00 | 5.00 | 0.50 / 2.50 |
| gemini-2.5-flash-lite | 0.10 | 0.40 | 0.05 / 0.20 |
| gemini-3.1-flash-lite | 0.25 | 1.50 | 0.125 / 0.75 |
| gpt-5-nano | 0.05 | 0.40 | 0.025 / 0.20 |
| gpt-5-mini | 0.25 | 2.00 | 0.125 / 1.00 |

Sources:
- Anthropic: https://platform.claude.com/docs/en/about-claude/pricing (cache hits 0.1×, stacking with batch)
- Google: https://aistudio.google.com/docs/pricing
- OpenAI: https://developers.openai.com/api/docs/pricing

Prices move: re-check before budgeting.
