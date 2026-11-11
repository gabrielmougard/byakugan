# Contextual Go SDK

What the bidder imports to read the contextual profiles the OCaml pipeline writes, and to check curated deals against them. This is integration option A of `study/matching.md` §8: OCaml writes, Go reads, and the rules exist twice, checked against one set of fixtures.

```go
import "github.com/gabrielmougard/byakugan/sdks/go/contextual"
```

Until this repo has a remote, the bidder points at a checkout:

```
require github.com/gabrielmougard/byakugan/sdks/go v0.0.0
replace github.com/gabrielmougard/byakugan/sdks/go => ../byakugan/sdks/go
```

## What it does

| | What | Cost per call |
|---|---|---|
| `Key(normalizedURL)` | the Redis key, `contextual:` + hex SHA-256 of the URL as the bidder's URL normalisation gives it | 83 ns, 2 allocations |
| `Reader.Lookup(ctx, normalizedURL, &profile)` | reads the profile through the bidder's own Redis client and decodes it | one Redis `GET` |
| `Reader.LookupWithBackoff(ctx, normalizedURL, &profile)` | the page's profile, else its top section's, else its site's (`Sections`, `SectionKey`): the mean of the pages crawled there, from 5 pages on; returns which `Level` it found | one `GET` per level tried |
| `Profile.Decode(b)` | the protobuf profile: labels (IAB 3.1 ids, scores) and fetch time | 83 ns, no allocation |
| `Rule.Check(&profile)` | a curated deal's context: eligible, blocked, unsuitable or off-target, with the deciding label | 9 ns, no allocation |
| `Profile.AtSlot(&slot, format, &out)` | a slot's own context: the blocks the bid request names around it, matched by SimHash, blended with the page per format (`GeometryOf`), Sensitive Topics as the worst co-visible case | 1.8 µs, 23 allocations (5 blocks) |
| `Profile.SlotOfGPID(gpid, &slot)` | the slot's surroundings from the GPID's div id and the crawler's estimated layout, when the request carries no `ctx` | |
| `CrawlRequests.Request(normalizedURL, pageURL)` | asks the crawler for a page that has no profile yet, through Pub/Sub, without blocking | a map lookup and a channel send |

Apple M4, `go test -bench . ./contextual`.

A `Rule` is the OCaml matcher's `refusal` (`src/lib/matcher.ml`):
- **Blocks:** none of these categories on the page.
- **AvoidSensitive:** no Sensitive Topics on the page.
- **Targets:** at least one of these categories on the page, when any are set.

A category counts with its descendants, from `MinScore` up (0.5 by default). That needs no taxonomy tree on the Go side: a profile carries every label's ancestors with at least its score, so a category is on the page exactly when its own id is.

The matcher's `score` (topic, keyword and product-lift blend for ranking creatives) is not ported. Curated deals only need eligibility; it comes with the third goal, creative relevance.

## In the bidder

Profiles must first be written to the Redis the bidder reads ([roadmap](../../ROADMAP.md#bidder-integration)). Then the bidder needs three things.

**1. A lookup in preprocessing, next to the other per-URL lookups.** `contextual.Cache` is a single `Get`, so the bidder's existing Redis client can serve it. Below, `BidRequest` stands for the bidder's own request type and `count` for its metrics.

```go
func enrichWithContextualProfile(ctx context.Context, req *BidRequest, reader contextual.Reader) {
	normalized, err := normalizeURL(req.Page) // the bidder's URL normalisation
	if err != nil {
		return
	}
	level, err := reader.LookupWithBackoff(ctx, normalized, &req.Contextual) // req.Contextual is a contextual.Profile
	if err != nil {
		count("contextual_lookup", "error")
		return
	}
	req.ContextualLevel = level
	switch level {
	case contextual.Page:
		count("contextual_lookup", "page")
	case contextual.Section, contextual.Site:
		count("contextual_lookup", "section") // a page not crawled yet: also send its crawl request (step 4)
	default:
		count("contextual_lookup", "miss")
	}
}
```

`Lookup` reuses the profile's label slice, so a pooled request decodes without allocating. `LookupWithBackoff` costs up to two more `GET`s when the page has no profile: `contextual.Cache` has no `MGET`. `Lookup` alone skips them. Use the same timeout as the other per-URL lookups; if one of them already normalises the page URL, normalising once and passing the result to both saves the second pass.

**2. A deal's context in its targeting.** A deal that opts in to "placement list or context" gets a `ContextRule *contextual.Rule`, built from its targets, blocks, Sensitive Topics choice and minimum score. Those fields belong in the bidder's deal configuration first, which is outside this SDK.

**3. "Placement list or context" in the placement check.** If deal filters are ANDed, a separate context filter could only shrink supply; the OR belongs inside the placement check:

```go
func placementOK(deal *Deal, req *BidRequest) bool {
	if deal.Placements.Contains(req.PlacementID) {
		return true
	}
	return deal.ContextRule != nil && req.ContextualLevel != contextual.NotFound &&
		deal.ContextRule.Check(&req.Contextual).Verdict == contextual.Eligible
}
```

**3b. The slot's own context, where the request says what surrounds it.** With the Prebid module ([sdks/prebid](../prebid/README.md)), `imp.ext.data.ctx` lists the blocks around the slot (SimHash, offset in viewports). `Profile.AtSlot` matches them to the profile's blocks (within 3 bits) and blends page and neighbourhood as the format says, worst case for Sensitive Topics, so a deal judges the slot rather than the whole URL. Without `ctx`, `Profile.SlotOfGPID` places the slot from the GPID's div id and the crawler's estimated layout:

```go
var slot contextual.Slot
ok := false
if raw := req.ImpExtData("ctx"); raw != nil { // imp.ext.data.ctx, as JSON
	ok = json.Unmarshal(raw, &slot) == nil
} else if req.GPID != "" {
	ok = req.Contextual.SlotOfGPID(req.GPID, &slot)
}
if ok {
	req.Contextual.AtSlot(&slot, formatName, &req.ContextualAtSlot) // check rules against this one
}
```

`AtSlot` allocates (about 2.8 KB in 23 allocations for five blocks, 1.8 µs); it runs only for requests with `ctx` or a known GPID. Which of page and slot context to use per deal is what the A/B test of [context boundary §9](../../study/context_boundary.md#9-the-ab-test-page-context-against-slot-context) settles.

**4. A crawl request on every miss.** Fresh pages, a new article for example, have no profile until the crawler finds them; meanwhile they get their section's or site's. `CrawlRequests` publishes the page URL to a Pub/Sub topic that the crawler pulls (`--pubsub projects/P/subscriptions/S`). It never blocks the bid, sends each page once, and a fixed pool of workers calls `Publish`. A Pub/Sub client with `Publish(ctx, data, attributes)` satisfies `contextual.Publisher`.

```go
requests := contextual.NewCrawlRequests(crawlRequestsClient, 2, 10_000) // a Pub/Sub publisher on the crawl-requests topic

if level != contextual.Page {
	switch requests.Request(normalized, req.Page) {
	case contextual.Queued:
		count("contextual_crawl_request", "queued")
	case contextual.AlreadyAsked:
		count("contextual_crawl_request", "already-asked")
	case contextual.Dropped:
		count("contextual_crawl_request", "dropped")
	}
}
```

`Failed()` counts the publishes Pub/Sub refused; report it with the queue metrics. Close it with the other dependencies. The topic, its subscription and the publisher's permissions belong with the bidder's infrastructure.

**Shadow mode first.** Ship step 3 with the context branch only counted per deal, not returned: how many requests context would add. That is the shadow reach count (`deploy/reach.example.sh`) measured in production, before any deal changes behaviour.

**Pacing.** `Rule.MinScore` per deal is the pacing-aware threshold θ: lower when the deal is behind pace, higher when ahead.

**Logging.** `Decision.Verdict` and `Decision.Label` give each verdict's reason, e.g. "off-target" or "blocked by 52 (0.81)", for per-bid logs.

## Tests

```bash
go -C sdks/go test -race ./...
go -C sdks/go test -run XXX -bench . ./contextual
```

The fixtures in `contextual/testdata` are written by the OCaml side, so both implementations answer the same cases:
- `keys.tsv`: the Redis key for every URL of the bidder's URL normalisation fixtures (`src/test/url_key.tsv`).
- `refusal.tsv`: 3,000 served profiles, built as the cascade builds them, with a random deal rule and the OCaml matcher's verdict.

Regenerate them after any change to the matcher, the label order or the profile format:

```bash
cd src && dune build ./sdkfixtures/sdkfixtures.exe && ./_build/default/sdkfixtures/sdkfixtures.exe -o ../sdks/go/contextual/testdata
```

`golangci-lint` passes.
