/**
 * The slot's surroundings as a bid request carries them: no page text, only
 * the SimHash of each block near the slot and its offset in viewports.
 * The bidder matches the hashes against the blocks of the page's crawled
 * profile (sdks/go Profile.AtSlot), so the slot is judged on what is around
 * it.
 *
 * words() and simhash() reproduce src/lib/text.ml (BERT's basic normaliser)
 * and src/lib/refresh.ml; test/simhash.tsv, written by the OCaml side, pins
 * them.
 */

/** Blocks the crawler's extractor segments a page into (src/lib/doc.ml). */
export const BLOCKS = 'h1,h2,h3,p,li,blockquote,figcaption';

/** BERT's rule: Unicode P*, plus every ASCII 33-126 that is not a letter or digit ($, +, <, ^). */
function isPunctuation(ch) {
  const c = ch.codePointAt(0);
  return (c >= 33 && c <= 47) || (c >= 58 && c <= 64) || (c >= 91 && c <= 96) || (c >= 123 && c <= 126) ||
    /\p{P}/u.test(ch);
}

/** The CJK ideograph blocks BERT splits into one word per character. */
function isCjk(c) {
  return (c >= 0x4e00 && c <= 0x9fff) || (c >= 0x3400 && c <= 0x4dbf) || (c >= 0x20000 && c <= 0x2a6df) ||
    (c >= 0x2a700 && c <= 0x2b73f) || (c >= 0x2b740 && c <= 0x2b81f) || (c >= 0x2b820 && c <= 0x2ceaf) ||
    (c >= 0xf900 && c <= 0xfaff) || (c >= 0x2f800 && c <= 0x2fa1f);
}

/**
 * Words as BERT's basic tokenizer sees them: control characters dropped, CJK
 * characters one word each, lowercase, accents stripped, punctuation as a
 * separator. "l’ÉCONOMIE" gives ["l", "economie"].
 */
export function words(text) {
  let spaced = '';
  for (const ch of text) {
    const c = ch.codePointAt(0);
    if (c === 0 || c === 0xfffd || (/[\p{Cc}\p{Cf}]/u.test(ch) && ch !== '\t' && ch !== '\n' && ch !== '\r')) continue;
    if (/\s/u.test(ch)) spaced += ' ';
    else if (isCjk(c)) spaced += ` ${ch} `;
    else spaced += ch;
  }
  const out = [];
  for (const token of spaced.split(' ')) {
    if (token === '') continue;
    let word = '';
    for (const ch of token.toLowerCase().normalize('NFD')) {
      if (/\p{Mn}/u.test(ch)) continue;
      if (isPunctuation(ch)) {
        if (word !== '') out.push(word);
        word = '';
      } else {
        word += ch;
      }
    }
    if (word !== '') out.push(word);
  }
  return out;
}

const MASK = (1n << 64n) - 1n;
const encoder = new TextEncoder();

function fnv1a(word) {
  let h = 0xcbf29ce484222325n;
  for (const b of encoder.encode(word)) h = ((h ^ BigInt(b)) * 0x100000001b3n) & MASK;
  return h;
}

/**
 * 64-bit SimHash of the text's words, as 16 hex digits: each word's FNV-1a
 * hash (over its UTF-8 bytes) votes on every bit, and a bit is set when more
 * words have it set than not. Only the words count:
 * simhash('The derby ends 2-1.') and simhash('the DERBY ends 2 1') are both
 * 'a767ac4cc601b1dd'.
 */
export function simhash(text) {
  const v = new Array(64).fill(0);
  for (const w of words(text)) {
    const h = fnv1a(w);
    for (let i = 0; i < 64; i++) v[i] += (h >> BigInt(i)) & 1n ? 1 : -1;
  }
  let r = 0n;
  for (let i = 0; i < 64; i++) if (v[i] > 0) r |= 1n << BigInt(i);
  return r.toString(16).padStart(16, '0');
}

/** A block's own text, as the extractor sees it: nested blocks left out. */
export function ownText(el) {
  let text = '';
  for (const node of el.childNodes) {
    if (node.nodeType === 3) text += node.nodeValue;
    else if (node.nodeType === 1 && !node.matches(BLOCKS) && !/^(SCRIPT|STYLE|NOSCRIPT)$/.test(node.tagName)) {
      text += ownText(node);
    }
  }
  return text;
}

const squash = s => s.replace(/[ \t\n\r\f]+/g, ' ').trim();

/**
 * The context of the slot whose element has id `slotId`, or null if it is
 * not on the page: the k blocks of at least 20 characters closest to it,
 * within `reach` viewports, as [simhash, offset] (offset from the slot's top
 * to the block's middle, in viewports, two decimals). Blocks inside the slot
 * and blocks not rendered are left out.
 *
 *   {v: 1, vh: 844, b: [['28b95a9f8d39808e', -0.42], ['0f0127458431a25e', 0.31]]}
 */
export function slotContext(doc, win, slotId, {k = 12, reach = 3} = {}) {
  const slot = doc.getElementById(slotId);
  if (!slot) return null;
  const vh = win.innerHeight || doc.documentElement.clientHeight;
  if (!vh) return null;
  const y = slot.getBoundingClientRect().top + win.scrollY;
  const near = [];
  for (const el of doc.querySelectorAll(BLOCKS)) {
    if (slot.contains(el)) continue;
    const text = squash(ownText(el));
    if (text.length < 20) continue;
    const r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) continue;
    const d = (r.top + win.scrollY + r.height / 2 - y) / vh;
    if (Math.abs(d) <= reach) near.push([d, text]);
  }
  near.sort((a, b) => Math.abs(a[0]) - Math.abs(b[0]));
  return {
    v: 1,
    vh: Math.round(vh),
    b: near.slice(0, k).map(([d, text]) => [simhash(text), Math.round(d * 100) / 100])
  };
}
