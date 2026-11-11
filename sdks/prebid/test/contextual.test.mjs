// node --test sdks/prebid/test: the browser's words and SimHash against the
// OCaml side's (test/simhash.tsv, written by src/sdkfixtures).
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {words, simhash} from '../libraries/contextual/index.js';

const rows = readFileSync(new URL('./simhash.tsv', import.meta.url), 'utf8').split('\n').filter(Boolean).map(l => l.split('\t'));

test('words match BERT normalisation', () => {
  assert.deepEqual(words('l’ÉCONOMIE dell’Inter «Macron» : città'), ['l', 'economie', 'dell', 'inter', 'macron', 'citta']);
});

test('SimHash matches the OCaml side', () => {
  assert.ok(rows.length >= 20);
  for (const [text, words_, hash] of rows) {
    assert.equal(words(text).join(' '), words_, text);
    assert.equal(simhash(text), hash, text);
  }
});
