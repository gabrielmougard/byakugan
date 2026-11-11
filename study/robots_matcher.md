# robots.txt matching and the AI-use gate

**Question.** Should our pure-OCaml robots.txt parser be replaced by [apeschar/robotstxt-ocaml](https://github.com/apeschar/robotstxt-ocaml), the OCaml binding to Google's C++ reference matcher? Would it be faster? Should the aipref and RSL checks join it, and do they need C code too?

**Short answer.**
- **Yes, replace it.** Google's matcher now decides every robots.txt check. It runs through our own adapter rather than the published binding.
- **Faster than the binding as published:** about 4× per check. The binding re-parses the whole robots.txt on every URL.
- **Faster than our old parser on average, but not on every file:**
  - parsing: 19 µs instead of 370 µs;
  - URL checks: 8.3 µs instead of 10.0 µs on average. Big files are faster; on small news files it is up to 1.7× slower, at under 1.3 µs either way.
- **The real gain is correctness.** Google's matcher is the reference implementation of RFC 9309, and our old parser got 6 of 6 spec edge cases wrong.
- **The aipref and RSL checks need no C of their own.** Their robots.txt lines come out of the same C++ pass; everything else they do runs once per page or per license document.

Measured 2026-11-05 on an Apple M4. Rerun with `src/_build/default/bench/robots_bench.exe DIR` after `dune build --root src --profile release ./bench/robots_bench.exe`.

## 1. What is in the repo now

| Path | What |
|---|---|
| `src/vendor/robotstxt/` | Google's `robots.cc` and `robots.h`, unmodified, plus apeschar's header-only Abseil shims. Provenance and checksums are in its README |
| `src/stubs/robots_stubs.cc` | Our C++ adapter, which exposes four OCaml primitives |
| `src/stubs/compat/absl/container/fixed_array.h` | An Abseil-faithful `FixedArray` that shadows the vendored shim (see §3) |
| `src/lib/robots.ml` | The OCaml side: `parse`, `allowed`, `decision` (with the deciding line), plus group-scoped `delay`, `sitemaps`, `content_usage`, `signals` and `licenses` |
| `src/lib/ai_use.ml` | The T4 gate. It covers the aipref vocabulary, an RFC 9651 dictionary parser, Content Signals, and RSL document parsing and evaluation |
| `src/bench/` | The benchmark and equivalence check. It keeps the old matcher as `robots_re.ml`, for comparison only |

## 2. Why not use robotstxt-ocaml as published

- **It re-parses on every URL.** Its stubs call `RobotsMatcher::AllowedByRobots`, which tokenises the whole robots.txt for every URL: it splits lines, recognises keys while tolerating typos, and makes a heap copy of every percent-escaped Allow/Disallow value. That suits a one-off check, not a crawler that asks one robots.txt about many URLs.
- **Our adapter parses once.** It runs Google's parser one time with a recording handler. That handler keeps only the Allow/Disallow rules the matcher would evaluate for our user agent, each with the group state in force on its line.
- **Replay is exact by construction:**
  - Group bookkeeping depends on the agent, never on the URL.
  - So each check sets that recorded state and hands each rule to Google's own `HandleAllow` and `HandleDisallow`.
  - Priorities, the `/index.htm` rule and the final decision therefore stay Google's code.
- **Shared and allocation-free per check.** A parsed robots.txt is immutable and shared across domains; each domain keeps its own replay matcher. A check allocates nothing on the OCaml heap (`[@@noalloc]`). It fails closed: an internal error reads as "disallowed".
- **One pass gives everything else.** The same pass keeps every other directive with its group: Sitemap, Crawl-delay, Content-Usage, Content-Signal and License.

## 3. Benchmark

The corpus:
- 16 real robots.txt files fetched on 2026-11-05: news sites, Wikipedia, GitHub and Google, from 2 to 960 lines;
- 4,153 URLs: every Allow/Disallow pattern made concrete, in three variants, plus common article paths, all percent-encoded as real URLs are.

The three matchers compared:

| Name | What it is |
|---|---|
| **re** | the old pure-OCaml matcher: parse once, Re regexes |
| **oneshot** | Google's matcher called as robotstxt-ocaml calls it |
| **replay** | our adapter |

| robots.txt | lines | URLs | parse µs, re / replay | check ns, re / oneshot / replay |
|---|---|---|---|---|
| en.wikipedia.org | 712 | 1176 | 2239 / 78 | 28025 / 76756 / 23167 |
| github.com | 526 | 498 | 1419 / 35 | 7019 / 37526 / 5193 |
| www.google.com | 265 | 718 | 512 / 19 | 3552 / 18668 / 3031 |
| www.nytimes.com | 365 | 354 | 346 / 25 | 2790 / 22726 / 2651 |
| www.lemonde.fr | 960 | 111 | 480 / 42 | 472 / 42533 / 549 |
| www.bbc.co.uk | 218 | 183 | 150 / 14 | 611 / 12033 / 770 |
| edition.cnn.com | 140 | 126 | 75 / 12 | 486 / 9609 / 503 |
| www.theguardian.com | 105 | 144 | 104 / 8 | 748 / 7335 / 905 |
| www.skysports.com | 88 | 186 | 98 / 7 | 783 / 6134 / 1301 |
| www.esquire.com | 62 | 108 | 40 / 5 | 214 / 3323 / 241 |
| (6 more in the bench output) | | | | |
| **Mean** | | | **370 / 19** | **9959 / 35627 / 8285** |

**Equivalence.** Replay agreed with Google's one-shot matcher on all 4,153 URLs.

**Two optimisations got replay there:**
1. **Inline `FixedArray`.** The Abseil shim shipped with robotstxt-ocaml defines `absl::FixedArray` as a `std::vector`. `RobotsMatchStrategy::Matches` therefore made a heap allocation and zero-filled it for every rule it tested. Our header keeps up to 256 bytes inline and leaves elements uninitialised, as Abseil does. Mean per check dropped from 10.7 to 8.4 µs. This header also serves `oneshot` in the table above; as published, with the vector shim, `oneshot` measured about 38 µs.
2. **Keep only applicable rules.** Recording drops rules in groups that never apply to us and precomputes the group state for the rest. A check no longer re-runs user-agent matching. This mattered most on files listing many AI bots: Le Monde went from 3.7 µs to 0.55 µs, Spiegel from 0.98 µs to 0.08 µs.

**Throughput.** On this mix, which Wikipedia's 23 µs checks dominate, replay sustains 0.1 M checks/s on one domain, 0.5 M on 4 and 0.6 M on 8. On news-sized files a check costs 0.5–1.3 µs, about 1 M checks/s per domain.

**Where re is still faster.** On small files (Sky Sports, Guardian, Telegraph, BBC) re wins by up to 1.7×. The fixed cost of the native call, copying the URL and extracting the path is about 60 ns; beyond that, Google's `Matches` is O(path × pattern) per rule, while re runs one compiled automaton.

**This was never the bottleneck.** The crawler waits at least 1 s between requests to a host, and a fetch takes about 100 ms. A robots.txt check at 1 µs is 0.001% of that.

### Correctness: spec cases the old matcher got wrong

| Case | re | Google (now ours) |
|---|---|---|
| raw UTF-8 pattern, percent-encoded URL (`Disallow: /café` vs `/caf%C3%A9`) | allowed | disallowed |
| lower-case escape in pattern (`/a%3cb` vs `/a%3Cb`) | allowed | disallowed |
| typo `Dissallow:` | allowed | disallowed |
| missing colon (`Disallow /x`) | allowed | disallowed |
| user-agent line with a version (`ContextBot/1.0`) | allowed | disallowed |
| `Allow: /d/index.html` also allows `/d/` | disallowed | allowed |

None of these occurred in the 16-file corpus; Wikipedia, for example, lists each non-ASCII path both raw and percent-encoded. They are cases where we would have crawled a page the publisher meant to exclude, or the reverse.

## 4. The AI-use gate

T4 sends a condensed page to an LLM, so before it runs, the crawler asks whether the publisher allows that use (`Ai_use.t4`). The most restrictive answer wins.

| Signal | Where | Our use is | Spec |
|---|---|---|---|
| aipref | robots.txt `Content-Usage: [path] ai-use=n`, in the selected group, longest path; the page's `Content-Usage` header | `ai-use` ("AI Use") | draft-ietf-aipref-vocab-08 §4.2, -attach-05 §3 |
| Content Signals | robots.txt `Content-Signal: ai-input=no` | `ai-input` | Cloudflare; folded into RSL's usage vocabulary |
| RSL 1.0 | robots.txt `License:`, the page's `Link: <...>; rel="license"; type="application/rsl+xml"`, and `<link rel="license" type="application/rsl+xml">` | `ai-input` by a `commercial` user | RSL 1.0 §3–4 |

**How RSL is read**, conservatively as §3.1.1 requires:
- The narrowest `<content>` scope that covers the page decides.
- Any prohibition of `ai-input`, `ai-all` or `all` wins.
- If a `<permits>` list exists, it must name our use.
- Terms we cannot meet unattended count as "not licensed": payment other than `free`, attribution, a license server (OLP token), or geographic terms.
- A license that cannot be fetched or is not valid RSL also means "not licensed" (§4.3).
- When our group has no `License:` line, every `License:` line not in our group counts. The Guardian puts its line after AhrefsBot's group, and another bot's license can only deny T4 or change nothing.

**Unknown preference → allowed.** The vocabulary takes no position on defaults (vocab §5). A page with no signal at all lets T4 run.

**On the 36 lab pages:**
- **Guardian (15 pages):** denied. Its `license.xml` permits `ai-train ai-input` only on a paid subscription and prohibits `all`.
- **BBC Good Food (4):** allowed. Its `Content-signal: search=yes, ai-train=no` says nothing about `ai-input`.
- **Esquire and Sky Sports:** allowed, with no signal at all.

T4 calls dropped from 60 to 40. The verdict is stored in each profile (`t4_gate`) and shown in the front end.

**Why no C for this.** The robots.txt part (scoping and matching `Content-Usage`, `Content-Signal` and `License`) already comes out of the C++ pass. `Content-Usage` paths go through Google's own matcher, so wildcards behave exactly like Allow. The rest is decided once per page or per license document, next to a network fetch, and needs readable, testable code: header and dictionary parsing, XML, and policy. Moving it to C would add risk and save nothing measurable.

## 5. Limits

- No Open License Protocol client, so a license that needs a license-server token always denies T4.
- `Content-Signal` paths are not scoped (the value is read whole), and the signal is taken from our group, else from outside any group.
- Content Signals has no published grammar beyond `key=yes|no` pairs; anything else reads as unknown.
- Google's matcher expects percent-encoded URLs (RFC 3986). URLs from sitemaps and links are, but a raw UTF-8 URL would be matched as given.
