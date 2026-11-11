# Which LLM runs T4?

**Answer:** `z-ai/glm-5.3-flash` by default, at about $0.14 per 1,000 calls.
- Of the models that fit the cost ceiling, it agreed best with two frontier reference models.
- If cost matters most, use `qwen/qwen3.7-flash`: it is 3× cheaper but agrees less.
- If quality matters most and the budget allows, use `anthropic/claude-haiku-5.5`: it agrees best of all, at about twice the price.

Measured 2026-11-05 on OpenRouter's live catalogue (455 models) and on the 36 pages crawled by the Placement Lab. The total benchmark spend was about $0.43.

**Confirmed on the golden set (2026-11-09, §6):** against 342 judged pages, `z-ai/glm-5.3-flash` gives the deep level its best hierarchical F1 of six candidates (0.699, against 0.145 for T0–T3 alone) at $0.142 per 1,000 calls billed. `openai/gpt-6-luna` comes second (0.679); `qwen/qwen3.7-flash` is the cheapest ($0.037) at 0.620. The default stays.

## 1. The cost ceiling

T4 is the "System 2" tier. It only reranks a shortlist of 12 candidates that the cheaper tiers produced, and it must quote the page to justify each choice (architecture.md). Three limits apply:

| Limit | Where it comes from | Ceiling per call |
|---|---|---|
| Tier budget | T4's nominal cost in the cascade (`Tier.llm ~cost`); `rich` allows $0.0005 per page, `deep` $0.01 | ≤ $0.001; ≤ $0.0005 to run at `rich` |
| Page economics | `Cascade.value_budget`: 1% of 7 days of the page's revenue. At an assumed $25 eCPM that is $0.00175 per daily impression, with 2% of bid requests assumed to become impressions | $0.00015 pays off on any page with about 0.1 impression (about 4 bid requests) a day; $0.005 needs 3 impressions a day |
| Fleet budget | Whole cascade at $25–60 per million pages (README §7); assume about 30% of pages reach T4 | **≤ $0.0002 (about $0.20 per 1,000 calls)** |

The fleet budget is the binding limit.
- Frontier models cost about $4–5 per 1,000 calls. On 30% of a million pages that is about $1,400, against a target of $25–60.
- So frontier models are references, not candidates.

## 2. Method

`src/t4eval` does the following:
1. Re-fetches every crawled page and builds its **real** T4 prompt with a dry run of the `deep` preset. A prompt is about 3,800 characters: instructions, 12 candidate IDs with their IAB paths, and the condensed page.
2. Sends each prompt to every model through OpenRouter with:
   - temperature 0;
   - JSON mode;
   - `provider.data_collection = deny`, so page text only reaches providers that don't keep it;
   - usage accounting, which gives the billed dollars.
3. Turns reasoning off, or to its lowest effort where it is mandatory, for every candidate. Reasoning tokens are billed as output, and this task doesn't need them.
4. Runs the references at their default reasoning: Claude Sonnet 5.5 and GPT-6 Sol.

**Metrics:**
- **ok:** the answer could be parsed.
- **kept:** shortlist labels selected with confidence ≥ 0.5.
- **invented:** IDs outside the shortlist. `Tier.judge` drops these.
- **verified:** quotes found word for word on the page. `Tier.judge` halves the confidence of the others.
- **agree:** Jaccard overlap of the kept set with each reference's kept set, averaged over both references.
- **top1:** whether the most confident label matches the reference's.

```bash
cd src
./_build/default/t4eval/t4eval.exe --ref anthropic/claude-sonnet-5.5 --ref openai/gpt-6-sol MODEL...
```

## 3. Results

Sorted by agreement. The two reference rows compare each reference with the other, so 0.88 / 78% is the ceiling.

| model | $/M tokens in / out | ok | kept | invented | verified | agree | top1 | $ per 1k calls | tokens in / out | seconds p50 / p95 |
|---|---|---|---|---|---|---|---|---|---|---|
| `anthropic/claude-sonnet-5.5` (ref) | 2.00 / 10.00 | 36/36 | 2.1 | 0 | 98% | 0.88 | 78% | 4.928 | 1494 / 199 | 1.7 / 2.2 |
| `openai/gpt-6-sol` (ref) | 2.00 / 10.00 | 36/36 | 2.4 | 0 | 96% | 0.88 | 78% | 4.191 | 858 / 235 | 2.9 / 5.8 |
| `anthropic/claude-haiku-5.5` | 0.10 / 0.50 | 36/36 | 2.8 | 0 | 84% | **0.78** | 69% | 0.264 | 1492 / 235 | 1.3 / 1.9 |
| `google/gemini-3.1-flash-lite` | 0.25 / 1.50 | 36/36 | 3.0 | 0 | 99% | 0.76 | 67% | 0.504 | 912 / 188 | 1.1 / 1.7 |
| **`z-ai/glm-5.3-flash`** | 0.15 / 0.50 | 36/36 | 2.4 | 0 | 87% | **0.75** | **76%** | **0.136** | 891 / 164 | 1.4 / 4.4 |
| `qwen/qwen3.7-flash` | 0.03 / 0.13 | 35/36 | 2.1 | 0 | 95% | 0.66 | 61% | **0.042** | 931 / 120 | 1.5 / 2.3 |
| `openai/gpt-6-luna` | 0.10 / 0.50 | 36/36 | 2.1 | 0 | **100%** | 0.64 | **78%** | 0.141 | 858 / 96 | 1.5 / 2.6 |
| `openai/gpt-5-mini` | 0.25 / 2.00 | 36/36 | 3.5 | 0 | 92% | 0.62 | 74% | 0.511 | 858 / 151 | 2.3 / 3.1 |
| `qwen/qwen3.5-flash-02-23` | 0.07 / 0.26 | 35/36 | 2.7 | 0 | 73% | 0.56 | 69% | 0.087 | 931 / 112 | 1.2 / 1.9 |
| `google/gemini-2.5-flash-lite` | 0.10 / 0.40 | 29/36 | 7.7 | 0 | 94% | 0.51 | 56% | 0.251 | 913 / 407 | 1.2 / 3.5 |
| `deepseek/deepseek-v4-flash` | 0.09 / 0.18 | 25/36 | 2.0 | 0 | 86% | 0.47 | 51% | 0.118 | 888 / 152 | 1.7 / 3.5 |
| `mistralai/mistral-small-3.2-24b-instruct` | 0.07 / 0.20 | 29/36 | 4.3 | 0 | 94% | 0.43 | 58% | 0.146 | 937 / 243 | 2.2 / 7.1 |
| `openai/gpt-4.1-nano` | 0.10 / 0.40 | 36/36 | 3.6 | 0 | 96% | 0.36 | 57% | 0.140 | 859 / 139 | 1.7 / 4.3 |
| `openai/gpt-5-nano` | 0.05 / 0.40 | 36/36 | 1.7 | 1 | 79% | 0.32 | 36% | 0.076 | 858 / 85 | 1.3 / 1.7 |
| `mistralai/ministral-8b-2512` | 0.15 / 0.15 | 19/36 | 4.6 | 0 | 86% | 0.26 | 35% | 0.218 | 937 / 465 | 4.6 / 11.7 |

## 4. Choice

| Role | Model | Why |
|---|---|---|
| **Default** | `z-ai/glm-5.3-flash` | Best agreement under the $0.20 ceiling (0.75, top-1 76%), 36/36 answers. About $41 per million pages at 30% escalation |
| Budget | `qwen/qwen3.7-flash` | $0.042 per 1,000 calls (about $13 per million pages) with honest quotes (95%), but agreement drops to 0.66 |
| Primary label | `openai/gpt-6-luna` | Same price as the default; matches the references' top label as often as they match each other (78%), and every quote verified. Keeps fewer secondary labels, hence its lower Jaccard |
| Quality | `anthropic/claude-haiku-5.5` | Best agreement (0.78) at about twice the default's price (≈ $80 per million pages at 30%). Worth it where pages earn more |

**What disqualified the others:**
- `gemini-2.5-flash-lite` keeps 7.7 labels per page: it over-selects, and that becomes false targeting downstream.
- `deepseek-v4-flash`, `ministral-8b` and `mistral-small-3.2` fail to give a usable answer on 11–47% of pages.
- `gpt-5-nano` and `gpt-4.1-nano` are cheap but agree with the references only about a third of the time.

**What the default costs in practice:**
- T4 sits behind the cascade. In the lab, `deep` sends one call per page, and `rich` sends one only when T0–T3 left the page unsettled.
- The billed cost per call ($0.136 per 1,000) came in under what catalogue prices × tokens predict (about $0.22). So the crawler's estimate, which uses catalogue prices, is an upper bound.

## 5. Caveats

- **36 pages from 4 sites:** a difference of about 0.05 in agreement is within noise. §6 reruns it on the golden set.
- **Agreement measures likeness to the frontier references, not correctness.** The references disagree with each other on 22% of top labels, which is roughly the ceiling of what this test can tell apart. A hand-adjudicated golden set is the real yardstick.
- **Verified quotes matter after scoring:** the default's 87% means 13% of its labels get halved confidence from `Tier.judge`. `gpt-6-luna` loses nothing here.
- **The catalogue changes weekly:** rerun `t4eval` when a new flash-tier model lands. OpenRouter also lists `:batch` variants at about half price (for example `anthropic/claude-haiku-5.5:batch` at $0.05 / $0.25). They suit offline T4 but were not tested here.
- **Data policy:** `data_collection: deny` restricts routing to providers that don't keep prompts. Check publishers' aipref/RSL signals before T4 runs on their text (architecture.md, crawl ethics).

## 6. On the golden set

`t4eval --judgements data/golden_labels.tsv --cap 2.5 MODEL...` (2026-11-09): the 342 judged pages whose stored profile allows T4, read from `golden`'s page cache; each page's real deep T4 prompt with today's calibration (images off, as in the first benchmark); each model's answers fed back into the deep level, whose served labels (≥ 0.5) are scored against gold with hierarchical precision and recall. No frontier references: gold replaces them. Billed $0.52 in all.

| model | $/1k calls billed | ok | kept | verified | T4 hF1 | deep hP | deep hR | deep hF1 | tokens in / out | s p50 / p95 |
|---|---|---|---|---|---|---|---|---|---|---|
| **`z-ai/glm-5.3-flash`** | 0.142 | 334/342 | 2.2 | 94% | **0.706** | **0.845** | 0.596 | **0.699** | 756 / 132 | 1.3 / 11.8 |
| `openai/gpt-6-luna` | 0.129 | 332/342 | 2.1 | 98% | 0.682 | 0.832 | 0.573 | 0.679 | 716 / 111 | 2.0 / 4.7 |
| `anthropic/claude-haiku-5.5` | 0.253 | 331/342 | 2.3 | 95% | 0.676 | 0.810 | 0.573 | 0.671 | 1249 / 260 | 1.4 / 2.4 |
| `google/gemini-3.1-flash-lite` | 0.456 | 337/342 | 2.6 | 100% | 0.671 | 0.747 | **0.608** | 0.670 | 755 / 182 | 1.0 / 1.7 |
| `openai/gpt-5-mini` | 0.503 | 336/342 | 3.2 | 89% | 0.645 | 0.657 | 0.591 | 0.622 | 716 / 165 | 2.4 / 4.3 |
| `qwen/qwen3.7-flash` | **0.037** | 333/342 | 2.0 | 92% | 0.638 | 0.801 | 0.505 | 0.620 | 766 / 116 | 1.5 / 2.2 |

- **T4 is what makes deep good:** T0–T3 alone serve deep hF1 0.145 against this gold, rich 0.324 ([golden report](golden_report.md)); every candidate lifts deep to 0.62–0.70.
- **The default holds** on quality and cost. GPT-6 Luna is a close, cheaper-per-call second with the most verified quotes after Gemini.
- **Billing runs above the catalogue** for GLM: $0.142 per 1,000 calls against about $0.05 at the listed price, as on the golden crawl. The crawler's estimate now carries that factor (`t4_billed_over_catalogue`).
- **The gold is an LLM's** (DeepSeek V4.1 Flash, from the candidates a human would see), so these scores measure agreement with a strong judge, not ground truth. It was left out of the candidates for that reason.
- **Recall is capped by the shortlist:** T4 picks among 12 candidates that hold 72% of the gold labels ([golden report](golden_report.md#t4-shortlist)).
