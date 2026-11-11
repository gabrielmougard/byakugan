# Contextual Prebid module

A Prebid.js real-time data submodule that tells bidders what surrounds each ad slot, so a slot is judged on the content next to it rather than on the whole page ([context boundary](../../study/context_boundary.md)).

Before each auction it writes, for every ad unit whose element is on the page:

```json
"ortb2Imp": {"ext": {"data": {"ctx": {"v": 1, "vh": 844, "b": [["28b95a9f8d39808e", -0.42], ["0f0127458431a25e", 0.31]]}}}}
```

- `b`: the 12 blocks (paragraphs, headings, list items, quotes, captions of at least 20 characters) closest to the slot, within 3 viewports, as the 64-bit SimHash of their words and their offset from the slot's top in viewport heights (negative above, already read).
- `vh`: the viewport height in CSS pixels.

**No page text leaves the page**, about 100 bytes per slot. The bidder joins the hashes with the blocks of the page's crawled profile, matched within 3 differing bits: [Go SDK](../go/README.md) `Profile.AtSlot`.

## Files

They mirror Prebid.js's tree, so they copy into it as they are:

| File | What |
|---|---|
| `libraries/contextual/index.js` | `words` (BERT's basic normalisation), `simhash`, `slotContext`: no Prebid dependency |
| `modules/contextualRtdProvider.js` | the RTD submodule, `name: 'contextual'` |
| `test/contextual.test.mjs` | `npm test`: `words` and `simhash` against the crawler's own (`test/simhash.tsv`, written by `src/sdkfixtures`) |

## Use

```js
pbjs.setConfig({
  realTimeData: {
    auctionDelay: 20,
    dataProviders: [{name: 'contextual', waitForIt: true, params: {k: 12, reach: 3}}]
  }
});
```

The slot's element is the ad unit's `code`, or the div id at the end of its GPID (`/1234/home#div-gpt-ad-top`, set by the GPT Pre-Auction module).

## Reaching the bidder

- **Prebid.js adapters built on `ortbConverter`** pass `ortb2Imp` into `imp` unchanged: its default imp processor runs `mergeDeep(imp, bidRequest.ortb2Imp)`. Checked on 2026-11-11 for an adapter that defines only `request()` and `bidResponse()` hooks: `imp.ext.data.ctx` reaches the bid request with no adapter change.
- **Prebid Server:** the bidder adapter we read re-marshals the whole request and leaves `imp.ext` alone. Whether PBS core keeps `imp.ext.data` when it rewrites `imp.ext` per bidder is not verified yet.
