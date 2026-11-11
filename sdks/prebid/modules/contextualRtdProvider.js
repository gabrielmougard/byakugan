/**
 * Real-time data submodule: before each auction, writes the surroundings of
 * every ad unit's slot into ortb2Imp.ext.data.ctx (libraries/contextual).
 * Bidder adapters built on ortbConverter pass ortb2Imp through to imp
 * unchanged, so no adapter change is needed. No page text leaves the page.
 *
 *   pbjs.setConfig({realTimeData: {dataProviders: [
 *     {name: 'contextual', params: {k: 12, reach: 3}}]}});
 *
 *   requestBids ─▶ RTD: getBidRequestData, before the auction
 *     │
 *     └─ each ad unit
 *          ├─ slot element: the GPID's div id, else the ad unit's code
 *          ├─ blocks (h1-h3, p, li, blockquote, figcaption) outside the slot,
 *          │  rendered, own text of 20+ characters
 *          ├─ d = (block middle - slot top) / viewport height; keep |d| <= reach
 *          ├─ the k nearest by |d|, each as [simhash(text), d to two decimals]
 *          └─ ortb2Imp.ext.data.ctx = {v: 1, vh, b: [[hash, d], ...]}
 *              (no slot element or viewport, or an error: no ctx for that unit)
 *     │
 *   callback() ─▶ the auction
 */
import {submodule} from '../src/hook.js';
import {deepSetValue, deepAccess} from '../src/utils.js';
import {slotContext} from '../libraries/contextual/index.js';

/** GPID "/1234/home#div-gpt-ad-top" gives "div-gpt-ad-top"; without a '#', the ad unit's code. */
function slotId(adUnit) {
  const gpid = deepAccess(adUnit, 'ortb2Imp.ext.gpid');
  if (typeof gpid === 'string' && gpid.includes('#')) return gpid.split('#').pop();
  return adUnit.code;
}

export const contextualSubmodule = {
  name: 'contextual',
  init: () => true,
  getBidRequestData(reqBidsConfigObj, callback, config) {
    const params = (config && config.params) || {};
    for (const adUnit of reqBidsConfigObj.adUnits || []) {
      try {
        const ctx = slotContext(document, window, slotId(adUnit), params);
        if (ctx) deepSetValue(adUnit, 'ortb2Imp.ext.data.ctx', ctx);
      } catch (e) {
        // Never hold the auction back for context.
      }
    }
    callback();
  }
};

submodule('realTimeData', contextualSubmodule);
