# Golden set

383 judged pages with a stored profile, 383 re-fetched, 1173 judged labels.

## Served labels per preset (score >= 0.5)

| preset | hP | hR | hF1 | settled | out of budget | no more tiers | top false positives |
|---|---|---|---|---|---|---|---|
| zero_fetch | 1.000 | 0.015 | 0.030 | 0.0% | 100.0% | 0.0% |  |
| standard | 0.097 | 0.726 | 0.171 | 2.1% | 97.7% | 0.3% | Genres (136); Style & Fashion > Men's Fashion (92); Style & Fashion (90); Video Gaming > Video Game Genres (89) |
| rich | 0.153 | 0.773 | 0.255 | 60.6% | 0.0% | 39.4% | Genres (96); Video Gaming > Video Game Genres (77); Healthy Living (77); Video Gaming (76) |
| deep | 0.548 | 0.639 | 0.590 | 0.0% | 0.0% | 100.0% | Sensitive Topics (16); Style & Fashion > Men's Fashion > Men's Clothing > Men's Casual Wear (15); Style & Fashion > Men's Fashion > Men's Clothing (15); Style & Fashion > Men's Fashion (15) |

## Served labels per preset with today's calibration, T0-T3 only

Recomputed offline from the re-fetched pages; the table above is what the stored profiles serve.

| preset | hP | hR | hF1 | settled | out of budget | no more tiers |
|---|---|---|---|---|---|---|
| zero_fetch | 0.808 | 0.033 | 0.063 | 4.2% | 95.8% | 0.0% |
| standard | 0.448 | 0.320 | 0.373 | 70.2% | 28.7% | 1.0% |
| rich | 0.448 | 0.321 | 0.374 | 70.2% | 0.0% | 29.8% |
| deep | 0.577 | 0.106 | 0.179 | 0.0% | 0.0% | 100.0% |

## Accept and reject at rich

Per (accept, reject): the pages T4 would see (not settled), and the hP / hF1 of what settled pages serve without it.

| accept \ reject | 0.1 | 0.2 | 0.3 |
|---|---|---|---|
| 0.5 | T4 66.8%, hP 0.382, hF1 0.370 | T4 51.2%, hP 0.428, hF1 0.396 | T4 35.0%, hP 0.424, hF1 0.401 |
| 0.6 | T4 70.0%, hP 0.399, hF1 0.380 | T4 56.1%, hP 0.454, hF1 0.405 | T4 41.0%, hP 0.449, hF1 0.406 |
| 0.7 | T4 74.9%, hP 0.400, hF1 0.375 | T4 62.1%, hP 0.483, hF1 0.405 | T4 48.8%, hP 0.499, hF1 0.410 |
| 0.8 | T4 80.2%, hP 0.489, hF1 0.396 | T4 70.5%, hP 0.564, hF1 0.410 | T4 59.0%, hP 0.586, hF1 0.408 |

## T4 shortlist

recall@12: 0.648 (760 of 1173) judged labels; target >= 0.95

Gold labels among T0-T3's k best labels (deep, before T4): what a longer shortlist would buy.

| k | 12 | 16 | 24 | 48 | 96 |
|---|---|---|---|---|---|
| recall | 0.627 (736 of 1173) | 0.697 (818 of 1173) | 0.783 (918 of 1173) | 0.876 (1028 of 1173) | 0.931 (1092 of 1173) |

## Calibration

ECE (labels) over the scores a tier hands the cascade (>= 0.3); fits over every (page, category) pair.

| tier | now | ECE now | refit | ECE refit |
|---|---|---|---|---|
| T1 lexicon | 1 - exp(-raw / 4) | 0.414 (3280) | Platt on raw: a 0.13, b -2.54 | 0.185 (401) |
| T1 lexicon | | | 1 - exp(-raw / 23.4) | 0.085 (652) |
| T2 page cosine, English (potion-base-32M) | a 15.74, b -6.83 | 0.120 (515) | a 17.49, b -7.32 | 0.153 (580) |
| T2 page cosine, other languages (potion-multilingual-128M) | a 9.88, b -6.68 | 0.229 (95) | a 9.88, b -6.68 | 0.230 (95) |
| T2 page cosine, undeclared only (2 pages) | a 9.88, b -6.68 | - (0) | a 12.38, b -7.21 | - (0) |
| T2 page cosine, de only (27 pages) | a 9.88, b -6.68 | 0.139 (8) | a 10.74, b -7.51 | 0.336 (1) |
| T2 page cosine, fr only (76 pages) | a 10.63, b -6.89 | 0.244 (25) | a 10.63, b -6.89 | 0.244 (25) |
| T2 page cosine, it only (112 pages) | a 9.48, b -6.37 | 0.272 (87) | a 9.48, b -6.37 | 0.271 (86) |
| T2 page cosine, pt only (1 pages) | a 9.88, b -6.68 | - (0) | a 20.61, b -7.36 | - (0) |
| T2 page cosine, ru only (1 pages) | a 9.88, b -6.68 | - (0) | a 22.25, b -7.35 | 0.559 (1) |
| T2 sentence cosine (segments) | a 5.21, b -6.39 | - (0) | a 5.98, b -6.63 | - (0) |
| T3 SigLIP 2 logit | a 0.41, b -0.30 | 0.080 (43) | a 0.41, b -0.33 | 0.095 (42) |
| T3 SigLIP 2 logit, Sensitive Topics only | a 0.41, b -0.30 | - (0) | a 0.26, b -0.28 | 0.694 (1) |
| T4 confidence (shortlist) | T 1 | 0.081 (1189) | T 1.73 | 0.101 (1189) |

## Thresholds (T0-T3 scores, deep preset, before T4)

accept: lowest score from which 90% of labels are right; reject: at most 5% of right labels under it.

| | accept | reject | pages T4 would see |
|---|---|---|---|
| shared until 2026-11-10 | 0.80 | 0.30 | 97.4% |
| fitted | 0.953 | 0.007 | 100.0% |

What a cut costs: right labels a reject threshold drops, and the precision of what an accept threshold freezes.

| cut | 0.05 | 0.10 | 0.20 | 0.30 | 0.50 | 0.70 | 0.80 | 0.90 |
|---|---|---|---|---|---|---|---|---|
| right labels under it | 35.7% | 49.6% | 68.0% | 79.8% | 89.4% | 94.6% | 96.0% | 97.9% |
| precision at or above it | 15.3% | 23.1% | 33.5% | 42.7% | 57.7% | 66.5% | 70.6% | 83.3% |

Per language: the same fits on each language's pages, and what the shared 0.80 / 0.30 did there (see the next section for today's).

| language | pages | accept | reject | pages T4 would see at 0.80 / 0.30 | precision >= 0.80 | right labels < 0.30 |
|---|---|---|---|---|---|---|
| undeclared | 2 | 1.010 | 0.000 | 100.0% | nan% | 100.0% |
| de | 27 | 0.361 | 0.008 | 100.0% | nan% | 83.8% |
| en | 164 | 0.953 | 0.017 | 93.9% | 70.6% | 71.2% |
| fr | 76 | 0.475 | 0.003 | 100.0% | nan% | 88.0% |
| it | 112 | 0.681 | 0.005 | 100.0% | nan% | 92.1% |
| pt | 1 | 0.019 | 0.000 | 100.0% | nan% | 100.0% |
| ru | 1 | 0.019 | 0.000 | 100.0% | nan% | 100.0% |

## T1 and thresholds per language, T4 in the loop

rich with each (T1 saturation, accept, reject): settled pages serve their T0-T3 labels, the others what T4 served on the stored deep level. Fit: the best overall hF1 with T4 on at most 30% of all pages, allocated across languages.

| language | pages | now: saturation, accept, reject | hF1 | T4 | fitted | hP | hR | hF1 | T4 |
|---|---|---|---|---|---|---|---|---|---|
| en | 164 | 8, 0.50, 0.40 | 0.489 | 22.6% | 8, 0.50, 0.40 | 0.545 | 0.443 | 0.489 | 22.6% |
| it | 112 | 2, 0.80, 0.40 | 0.496 | 42.0% | 2, 0.80, 0.40 | 0.583 | 0.431 | 0.496 | 42.0% |
| fr | 76 | 12, 0.50, 0.40 | 0.520 | 26.3% | 12, 0.50, 0.40 | 0.690 | 0.417 | 0.520 | 26.3% |
| others | 31 | 12, 0.70, 0.40 | 0.575 | 32.3% | 12, 0.70, 0.40 | 0.607 | 0.546 | 0.575 | 32.3% |
| all | 383 | | 0.501 | 29.8% | | 0.577 | 0.442 | 0.501 | 29.8% |
