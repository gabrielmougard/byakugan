# Images with SigLIP 2, in C

**Question.** Can T3 read the images publishers put on their pages, with SigLIP 2 zero-shot over the IAB taxonomy, in C on our vendored ggml, fast enough for the crawler? And what does it see on publishers' pages?

**Short answer.**
- **A C runtime for SigLIP 2's vision tower, on the ggml we vendor.** It covers [`google/siglip2-base-patch16-naflex`](https://huggingface.co/google/siglip2-base-patch16-naflex) (Apache-2.0), CPU only. The graph comes from [hbd-siglip2.cpp](https://github.com/dbrain/hbd-siglip2.cpp) (MIT), minus its CUDA kernels, HTTP server and ggml fork.
- **Hardened image decoders.** Images are decoded by the system's libjpeg-turbo, libpng and libwebp, not by `stb_image`. Its author says it is not meant for untrusted files, and web images are untrusted input. WebP is 45% of the images we decode, which `stb_image` cannot read.
- **Exact against Hugging Face.** With f32 weights the embedding's cosine with Hugging Face's is ≥ 0.999999 on all 8 test images, so decoding, NaFlex resizing and the graph match.
  - **One catch:** Hugging Face resizes with PyTorch's uint8 path, which our first float resize missed on 15% of pixel values, costing 0.003 of cosine.
  - **What we ship:** Q8_0 weights, 100 MB. Cosine 0.9969–0.9996, and zero-shot probabilities within 0.002 of f32.
- **Speed, one Apple M4 core:**
  - 247 ms per image at the model's default 256 patches;
  - 88 ms at 128 patches, the smallest size it was trained at;
  - 54 ms at 64 patches.

  That is with ggml's interleaved int8 kernels, 2.1–2.5× faster than our first version (§3). A Pi 4 core lacks the instructions they need. The Pi is not measured; our estimate is 3 to 5 s per image at 128 patches, the chart's default for the Pi.
- **Zero-shot without the text tower at runtime.** The 704 taxonomy nodes were embedded once with Hugging Face, each as three prompts averaged. They sit in a committed 1 MB file (`src/data/siglip2_prototypes.gguf`), so the crawler only runs the vision tower.
- **On publishers' images** (60 golden-sample pages, 148 images without alt text):
  - 92 embedded. 39 could not be decoded: 34 SVG logos and icons, 3 AVIF, 2 error pages. 14 were under 150 pixels (badges, logos).
  - 19 get a label at or above 0.3 with the hand-set calibration. Examples: Apartments on a property page, women's shoes on Gala, Skiing in The New Yorker, Bereavement on Bustle, Celebrity Homes.
  - Two doubtful labels stay in the doubt band, where the cascade escalates: a Terrorism label at 0.63 and Fan Conventions at 0.59.
- **Audio is dropped.** There is too little of it on the open web to be worth a tier. Video keeps its oEmbed titles.

Measured 2026-11-08 on an Apple M4.

## 1. What is in the repo now

| Path | What |
|---|---|
| `src/stubs/sig.c`, `sig.h` | decoding (JPEG, PNG, WebP), NaFlex preprocessing, the vision tower and its attention-pooling head on ggml |
| `src/stubs/sig_stubs.c`, `src/lib/siglip.ml` | OCaml bindings (the runtime is released while an image is embedded), prototypes, zero-shot |
| `src/siggguf/` | the converter: Hugging Face `model.safetensors` → GGUF, Q/K/V fused per layer, matrices Q8_0, norms and biases f32 |
| `src/stubs/tools/siglip_prototypes.py` | the taxonomy's text embeddings with Hugging Face, written to `src/data/siglip2_prototypes.gguf` (committed) |
| `src/stubs/tools/siglip_fixtures.py`, `src/test/test_siglip.ml`, `src/test/images/` | parity against Hugging Face on three CC0 photos from Wikimedia Commons and five derived images |
| `src/lib/tier.ml` (`Tier.images`), `src/lib/engine.ml` | the image tier and its calibration |
| `src/crawler/crawler.ml` (`see_images`) | images fetched (robots.txt and politeness as for pages), embedded on the pool, one ggml thread each |
| `src/bench/image_bench.ml` | the measurements below: publishers' images, and timing with `--time` |

The model is pinned to revision `b53b807d` in `fetch-data.sh`, because the committed prototypes are that revision's text embeddings.

## 2. Exactness

The Hugging Face reference is `Siglip2Model.get_image_features` with the processor's defaults (`max_num_patches` 256). Ours is `Siglip.embed`. Both embeddings are L2-normalised.

| Image | NaFlex grid | Q8_0 | f16 | f32 |
|---|---|---|---|---|
| `car.jpg` (500×375) | 14×18 | 0.99945 | 0.99971 | 1.000000 |
| `car.webp` | 14×18 | 0.99690 | 0.99996 | 1.000000 |
| `panorama.jpg` (500×60) | 6×42 | 0.99946 | 0.99999 | 0.999999 |
| `pasta.jpg` | 13×19 | 0.99927 | 0.99999 | 1.000000 |
| `pasta_alpha.png` (RGBA) | 13×19 | 0.99958 | 0.99999 | 1.000000 |
| `soccer.jpg` | 14×18 | 0.99897 | 0.99999 | 0.999999 |
| `soccer_gray.jpg` | 14×18 | 0.99944 | 0.99999 | 1.000000 |
| `tiny.jpg` (40×29, upscaled) | 14×18 | 0.99948 | 0.99999 | 0.999999 |

What it took:
- **The NaFlex grid** is Hugging Face's binary search for the largest size with at most 256 patches, keeping the aspect ratio. All 8 grids match.
- **The resize.** `Siglip2ImageProcessorFast` resizes a uint8 tensor with torchvision, and PyTorch's uint8 antialiased bilinear path works like this:
  - weights rounded to int16 fixed point, at one precision per axis set by the axis's largest weight;
  - width first, rounded to uint8, then height;
  - an axis that keeps its size is skipped.

  A float version of the same filter differs on 15% of the pixel values, by one level. That cost 0.003 of cosine with f32 weights. Ported exactly, the resize matches PyTorch on every value of the 8 test images.
- **The graph.** With f32 weights, on Hugging Face's own pixel values, the cosine is 1.000000. The position grid is resized in-graph with ggml's antialiased bilinear `interpolate`, as Hugging Face resizes it. The pooled vector comes from the attention-pooling head, not a mean.
- **Weights.** Q8_0 costs up to 0.003 of cosine and f16 0.0003. On the three photos, the zero-shot probabilities agree with f32 within 0.002, and the rankings are the same. We ship Q8_0: 100 MB against 186 MB for f16, and integer dot products, which a Pi 4 core runs faster.

## 3. Speed

**Where the time goes.** On one M4 core, at 256 patches, for the same photo:

| Size | Decode and resize | Encoder |
|---|---|---|
| 500×375 (77 KB) | 1.7 ms | 515 ms |
| 1280×960 (454 KB) | 7.3 ms | 519 ms |
| 4032×3024 (4.1 MB) | 54.5 ms | 514 ms |

The encoder is nearly all of it, and its time is ggml's matrix products, which are already SIMD. What changes their speed is which int8 instructions they get.

**Repacked weights.** ggml interleaves Q8_0 matrices for the CPU's int8 dot-product (`q8_0_4x4`) or matrix-multiply (`q8_0_4x8`, i8mm) instructions, but only for weights loaded into its `CPU_REPACK` buffer type. `sig_load` now does that when the CPU has either instruction, so the parity tests are unchanged. `image_bench --time` embeds four test images one after another, best of three runs each:

| Patches | 1 thread, plain | 1 thread, repacked | 4 threads, repacked |
|---|---|---|---|
| 256 (model default) | 511 ms | 247 ms | 70 ms |
| 128 | 219 ms | 88 ms | 25 ms |
| 64 | 119 ms | 54 ms | 18 ms |

**Which instructions, on which CPU.** Rebuilding ggml for three targets on the M4, one thread, 256 patches, before repacking:

| ggml built for | Encoder | Note |
|---|---|---|
| ARMv8.0 (what Debian's gcc targets by default, so our Docker image; a Pi 4's level) | 689 ms | no int8 dot product |
| Apple clang's default (dot product) | 510 ms | this repo's Mac build |
| `-mcpu=native` (dot product, i8mm, fp16, SME) | 601 ms | slower without repacking |

With repacking, the native build (i8mm, `4x8`) runs at 257 ms, no better than the dot-product build's 247 ms. Two consequences:
- **ARM servers (Graviton, Axion) gain 2–3× only if our image is built with the dot product enabled.** Debian's gcc targets ARMv8.0 by default, so that is a build flag for a server image.
- **A Pi 4 gains nothing.** Its Cortex-A72 has neither instruction, so ggml's plain NEON kernels are all there is. A Pi core is roughly 15 to 25 times slower than an M4 core at these products: 3 to 5 s per image at 128 patches, to be measured once the cluster is back. The chart sets `crawler.imagePatches: 128` for the Pi; 64 is below what NaFlex was trained on.

On the Pi, only doing less helps: fewer patches, fewer images per page, a cache for images seen before, and embedding only the pages whose text leaves doubt (§7).

The crawler embeds up to 3 images per page (`Tier.undescribed`), one ggml thread each, on its Domainslib pool. On the Pis, that can triple a page's CPU. The value budget, wired to traffic, keeps images for the pages worth them ([Placement Lab](../docs/guide/placement-lab.md#what-each-depth-level-means)).

## 4. Zero-shot and calibration

**Prototypes.** Each node is written as its name with its parent's, e.g. "Soccer (Sports)". The three prompts per node are:
- "This is a photo of …"
- "a photo about …"
- "an image related to …"

They are embedded with the text tower (padding to 64 tokens, as SigLIP was trained), normalised and averaged. The text tower and its 256K-token Gemma tokenizer stay in Python: the prototypes change only with the taxonomy or the prompts, and the crawler never needs them at runtime.

**Scores.** SigLIP gives each (image, prompt) pair its own sigmoid, `sigmoid(exp(scale) · cos + bias)`, so several nodes can hold, or none. For category names those probabilities run low:
- 0.1 to 0.4 for the clearest hits on publishers' images;
- 0.02 to 0.07 for the wrong ones (crowds read as Fan Conventions, portraits as Celebrity Deaths);
- 0.01 for Soccer on a beach soccer photo.

A hand-set Platt on the logit maps p = 0.1 to 0.8 (accept) and p = 0.03 to 0.3 (reject). Fitting it on the golden set is M2 work.

**Genres are left out.** IAB's Genres (TV, film and music genres) took the top spot on photos of people: Talk Show, Reality TV, Documentary, whatever the page was about. An image cannot tell a genre.

## 5. On publishers' images

`image_bench --pages 2 < src/data/golden_sample.tsv`: two pages on each of 34 hosts, robots.txt honoured, up to three images without alt text per page.

| | Images |
|---|---|
| Found | 148 on 60 pages |
| Refused by robots.txt | 3 |
| Not decodable | 39: SVG 34, AVIF 3 (despite our `Accept` header), an HTML error page 2 |
| Under 150 pixels | 14 |
| Embedded | 92: WebP 41, JPEG 32, PNG 19 |
| With a label ≥ 0.3 | 19 |

**Labels at or above 0.3, examples:**
- Real Estate > Apartments (0.98, 0.95) on the Standard's property pages;
- Women's Shoes and Footwear (0.95) on Gala;
- Celebrity Homes (0.96) on Gala and Le Figaro;
- Skiing (0.89) in The New Yorker;
- Bereavement (0.92) on Bustle;
- Debt Factoring (0.93, 0.99) on Il Giornale's business pages;
- Astrology (0.91, 0.80) on Corriere's horoscope pages, which the text tiers leave unlabelled.

**Two land in the doubt band:**
- Sensitive Topics > Terrorism (0.63) on a Le Figaro family-section photo;
- Fan Conventions (0.59) on a Corriere car page.

The cascade escalates such pages instead of accepting them. Image-only Sensitive Topics are the risk to watch on the golden set.

**Agreement with the text.** The image's tier-1 matches the text tiers' tier-1 on 9 of 18 labelled images. That is expected more than it is a defect. Images show something narrower than the article: a family on holiday on a business story, a desk on a student-housing story. The tier adds evidence; it does not replace the text.

## 6. Where it sits in the cascade

`t3-images` runs after the video tier and before T4. It costs $10⁻⁴ per image, so `rich` and `deep` run it and `standard` does not. Its labels accumulate with the others by noisy-OR, and each carries its evidence: zone `image`, the image URL as the quote, and SigLIP's own probability.

## 7. Caveats and next steps

- **Calibration** is hand-set on 92 images. The golden set should fit it, Sensitive Topics first.
- **SVG** is a quarter of the images without alt text. It is mostly logos and icons, so skipping it costs little.
- **AVIF** came back 3 times despite `Accept: image/webp,image/png,image/jpeg`. libavif would read it if it grows.
- **Pi throughput** is unmeasured, and the Pi gains nothing from repacking (§3).
- **Doing less:**
  - About 8% of the embedded images repeat within two pages of a host (logos, app badges). Re-crawls and homepages, which reuse their articles' lead images, repeat far more. A cache of embeddings in Valkey, 1.5 KB each and keyed by the image, would skip them.
  - Today every page's images are embedded before the cascade runs, because `deep` always runs every tier. Embedding them only when `rich` is still in doubt after the text tiers, as T4 already works with its dry run, would save most of the Pi's image work.
- **Video keyframes, captions and OCR** were dropped (2026-11-08): video keeps its oEmbed titles.
