/* Text to token ids, the way Hugging Face tokenizers does it for the
   Model2Vec models (see m2v.h). Ported from model2vec-rs's fast_wordpiece.rs
   and fast_unigram.rs (MIT), and spm_precompiled (Apache-2.0) for the
   SentencePiece charsmap. Input is valid UTF-8 (m2v_tokenize sanitizes). */

#include <stdlib.h>
#include <string.h>

#include "m2v_internal.h"
#include "m2v_tables.h"

/* --- buffers ------------------------------------------------------------ */

static int grow(void **p, size_t *cap, size_t need, size_t elt) {
  if (need <= *cap) return 0;
  size_t c = *cap ? *cap : 64;
  while (c < need) c *= 2;
  void *q = realloc(*p, c * elt);
  if (q == NULL) return -1;
  *p = q;
  *cap = c;
  return 0;
}

int m2v_ids_push(m2v_ids *a, int32_t x) {
  if (grow((void **)&a->v, &a->cap, a->n + 1, sizeof(int32_t))) return -1;
  a->v[a->n++] = x;
  return 0;
}

int m2v_buf_put(m2v_buf *a, const char *s, size_t n) {
  if (grow((void **)&a->b, &a->cap, a->n + n + 1, 1)) return -1;
  memcpy(a->b + a->n, s, n);
  a->n += n;
  a->b[a->n] = 0;
  return 0;
}

typedef struct {
  uint32_t *v;
  size_t n, cap;
} cps_t;

static int cps_push(cps_t *a, uint32_t c) {
  if (grow((void **)&a->v, &a->cap, a->n + 1, sizeof(uint32_t))) return -1;
  a->v[a->n++] = c;
  return 0;
}

/* --- UTF-8 -------------------------------------------------------------- */

static size_t utf8_len(uint8_t lead) { return lead < 0x80 ? 1 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : 4; }

static uint32_t utf8_get(const uint8_t *s, size_t *i) {
  uint8_t b = s[*i];
  size_t n = utf8_len(b);
  uint32_t c = n == 1 ? b : n == 2 ? b & 0x1F : n == 3 ? b & 0x0F : b & 0x07;
  for (size_t k = 1; k < n; k++) c = (c << 6) | (s[*i + k] & 0x3F);
  *i += n;
  return c;
}

static size_t utf8_put(uint32_t c, char *o) {
  if (c < 0x80) { o[0] = (char)c; return 1; }
  if (c < 0x800) { o[0] = (char)(0xC0 | c >> 6); o[1] = (char)(0x80 | (c & 0x3F)); return 2; }
  if (c < 0x10000) {
    o[0] = (char)(0xE0 | c >> 12); o[1] = (char)(0x80 | ((c >> 6) & 0x3F)); o[2] = (char)(0x80 | (c & 0x3F));
    return 3;
  }
  o[0] = (char)(0xF0 | c >> 18); o[1] = (char)(0x80 | ((c >> 12) & 0x3F));
  o[2] = (char)(0x80 | ((c >> 6) & 0x3F)); o[3] = (char)(0x80 | (c & 0x3F));
  return 4;
}

static int in_ranges(const m2v_range *r, int n, uint32_t c) {
  int lo = 0, hi = n - 1;
  while (lo <= hi) {
    int mid = (lo + hi) / 2;
    if (c < r[mid].lo) hi = mid - 1;
    else if (c > r[mid].hi) lo = mid + 1;
    else return 1;
  }
  return 0;
}

/* --- byte trie ------------------------------------------------------------ */

uint32_t m2v_trie_child(const m2v_trie *t, uint32_t node, uint8_t b) {
  if (node == 0) return t->root[b];
  for (uint32_t c = t->nodes[node].child; c != M2V_NONE; c = t->nodes[c].sibling) {
    if (t->nodes[c].label == b) return c;
    if (t->nodes[c].label > b) break;
  }
  return M2V_NONE;
}

typedef struct {
  const char *key;
  size_t len;
  int id;
} kv_t;

static int kv_cmp(const void *a, const void *b) {
  const kv_t *x = a, *y = b;
  size_t n = x->len < y->len ? x->len : y->len;
  int c = memcmp(x->key, y->key, n);
  if (c) return c;
  if (x->len != y->len) return x->len < y->len ? -1 : 1;
  return x->id - y->id;
}

/* Keys inserted in sorted order, so each node's children arrive in label
   order and a key listed twice ends on its last id, as the crates' maps do. */
int m2v_trie_build(m2v_trie *t, const char **keys, const size_t *lens, int n) {
  kv_t *kv = malloc(sizeof(kv_t) * (n ? n : 1));
  size_t total = 1, maxlen = 0;
  if (kv == NULL) return -1;
  for (int i = 0; i < n; i++) {
    kv[i] = (kv_t){keys[i], lens[i], i};
    total += lens[i];
    if (lens[i] > maxlen) maxlen = lens[i];
  }
  qsort(kv, n, sizeof(kv_t), kv_cmp);
  t->nodes = malloc(sizeof(m2v_tnode) * total);
  uint32_t *last = malloc(sizeof(uint32_t) * total), *path = malloc(sizeof(uint32_t) * (maxlen + 1));
  if (t->nodes == NULL || last == NULL || path == NULL) {
    free(kv); free(last); free(path);
    return -1;
  }
  for (int b = 0; b < 256; b++) t->root[b] = M2V_NONE;
  t->nodes[0] = (m2v_tnode){M2V_NONE, M2V_NONE, -1, 0};
  t->count = 1;
  path[0] = 0;
  const char *prev = NULL;
  size_t prev_len = 0;
  for (int i = 0; i < n; i++) {
    const char *k = kv[i].key;
    size_t len = kv[i].len, lcp = 0;
    if (len == 0) continue;
    while (prev && lcp < len && lcp < prev_len && k[lcp] == prev[lcp]) lcp++;
    for (size_t d = lcp; d < len; d++) {
      uint32_t node = t->count++, parent = path[d];
      uint8_t label = (uint8_t)k[d];
      t->nodes[node] = (m2v_tnode){M2V_NONE, M2V_NONE, -1, label};
      last[node] = M2V_NONE;
      if (parent == 0) t->root[label] = node;
      else if (last[parent] == M2V_NONE) t->nodes[parent].child = node;
      else t->nodes[last[parent]].sibling = node;
      if (parent != 0) last[parent] = node;
      path[d + 1] = node;
    }
    t->nodes[path[len]].token = kv[i].id;
    prev = k;
    prev_len = len;
  }
  free(kv); free(last); free(path);
  m2v_tnode *shrunk = realloc(t->nodes, sizeof(m2v_tnode) * t->count);
  if (shrunk) t->nodes = shrunk;
  return 0;
}

/* --- WordPiece (BERT) ----------------------------------------------------- */

static int ccc_of(uint32_t c) {
  int lo = 0, hi = M2V_CCC_TABLE_N - 1;
  while (lo <= hi) {
    int mid = (lo + hi) / 2;
    if (c < m2v_ccc_table[mid].cp) hi = mid - 1;
    else if (c > m2v_ccc_table[mid].cp) lo = mid + 1;
    else return m2v_ccc_table[mid].ccc;
  }
  return 0;
}

/* BertNormalizer on one non-ASCII character, from tables taken from the
   reference implementation, code point by code point. */
static int bert_normalize_char(uint32_t c, cps_t *out) {
  if (in_ranges(m2v_bert_drop, M2V_BERT_DROP_N, c)) return 0;
  if (in_ranges(m2v_bert_space, M2V_BERT_SPACE_N, c)) return cps_push(out, ' ');
  if (in_ranges(m2v_bert_cjk, M2V_BERT_CJK_N, c))
    return cps_push(out, ' ') || cps_push(out, c) || cps_push(out, ' ');
  if (c >= 0xAC00 && c <= 0xD7A3) {
    uint32_t s = c - 0xAC00;
    if (cps_push(out, 0x1100 + s / 588) || cps_push(out, 0x1161 + (s % 588) / 28)) return -1;
    return s % 28 ? cps_push(out, 0x11A7 + s % 28) : 0;
  }
  int lo = 0, hi = M2V_BERT_MAP_N - 1;
  while (lo <= hi) {
    int mid = (lo + hi) / 2;
    if (c < m2v_bert_map[mid].cp) hi = mid - 1;
    else if (c > m2v_bert_map[mid].cp) lo = mid + 1;
    else {
      const uint8_t *s = (const uint8_t *)m2v_bert_map_str + m2v_bert_map[mid].off;
      size_t i = 0;
      while (i < m2v_bert_map[mid].len)
        if (cps_push(out, utf8_get(s, &i))) return -1;
      return 0;
    }
  }
  return cps_push(out, c);
}

static int bert_normalize(const uint8_t *s, size_t len, cps_t *out) {
  size_t i = 0;
  while (i < len) {
    uint8_t b = s[i];
    if (b < 0x80) {
      i++;
      if (b == '\t' || b == '\n' || b == '\r') b = ' ';
      else if (b < 0x20 || b == 0x7F) continue;
      if (b >= 'A' && b <= 'Z') b += 'a' - 'A';
      if (cps_push(out, b)) return -1;
    } else if (bert_normalize_char(utf8_get(s, &i), out)) {
      return -1;
    }
  }
  /* NFD's canonical ordering, for the combining marks that survive accent
     stripping (non-spacing ones are gone). */
  for (size_t k = 1; k < out->n; k++) {
    int cc = ccc_of(out->v[k]);
    if (cc == 0) continue;
    size_t j = k;
    while (j > 0 && ccc_of(out->v[j - 1]) > cc) {
      uint32_t t = out->v[j]; out->v[j] = out->v[j - 1]; out->v[j - 1] = t;
      j--;
    }
  }
  return 0;
}

/* 0 = word, 1 = whitespace, 2 = punctuation, as BertPreTokenizer splits. */
static int bert_class(uint32_t c) {
  if (c < 0x80) {
    if (c == ' ' || (c >= '\t' && c <= '\r')) return 1;
    if ((c >= '!' && c <= '/') || (c >= ':' && c <= '@') || (c >= '[' && c <= '`') || (c >= '{' && c <= '~')) return 2;
    return 0;
  }
  if (in_ranges(m2v_bert_white, M2V_BERT_WHITE_N, c)) return 1;
  if (in_ranges(m2v_bert_punct, M2V_BERT_PUNCT_N, c)) return 2;
  return 0;
}

/* Greedy longest match; a word that cannot be fully matched, or has more
   than max_chars characters, is one unknown token. */
static int wordpiece(const m2v_model *m, const char *w, size_t len, size_t chars, m2v_ids *out) {
  if ((int)chars > m->max_chars) return m2v_ids_push(out, m->unk_id);
  if (len == 1) {
    int32_t id = m->single_byte[(uint8_t)w[0]];
    return m2v_ids_push(out, id >= 0 ? id : m->unk_id);
  }
  size_t mark = out->n, start = 0;
  while (start < len) {
    uint32_t node = start == 0 ? 0 : m->continuation;
    int32_t best = -1;
    size_t best_end = 0;
    for (size_t k = start; k < len && node != M2V_NONE; k++) {
      node = m2v_trie_child(&m->trie, node, (uint8_t)w[k]);
      if (node != M2V_NONE && m->trie.nodes[node].token >= 0) {
        best = m->trie.nodes[node].token;
        best_end = k + 1;
      }
    }
    if (best < 0) {
      out->n = mark;
      return m2v_ids_push(out, m->unk_id);
    }
    if (m2v_ids_push(out, best)) return -1;
    start = best_end;
  }
  return 0;
}

static int encode_bert(const m2v_model *m, const uint8_t *s, size_t len, m2v_ids *out) {
  cps_t cps = {0};
  m2v_buf word = {0};
  int rc = bert_normalize(s, len, &cps);
  size_t chars = 0;
  char tmp[4];
  for (size_t i = 0; rc == 0 && i <= cps.n; i++) {
    int cls = i == cps.n ? 1 : bert_class(cps.v[i]);
    if (cls == 0) {
      rc = m2v_buf_put(&word, tmp, utf8_put(cps.v[i], tmp));
      chars++;
      continue;
    }
    if (word.n) rc = wordpiece(m, word.b, word.n, chars, out);
    word.n = 0;
    chars = 0;
    if (rc == 0 && cls == 2) rc = wordpiece(m, tmp, utf8_put(cps.v[i], tmp), 1, out);
  }
  free(cps.v);
  free(word.b);
  return rc;
}

/* What the lexicon tiers match on: BertNormalizer (Unicode lowercase, accents
   stripped, controls dropped) and BertPreTokenizer's split (Unicode spaces and
   punctuation separate words), with the punctuation itself dropped. So
   "l’ÉCONOMIE" gives "l economie", "«Macron»" gives "macron", and a URL slug
   without accents meets the accented term. */
int m2v_words(const char *text, size_t len, m2v_buf *out) {
  size_t n;
  char *clean = m2v_sanitize(text, len, &n);
  if (clean == NULL) return -1;
  cps_t cps = {0};
  int rc = bert_normalize((const uint8_t *)clean, n, &cps), in_word = 0;
  if (clean != text) free(clean);
  char tmp[4];
  for (size_t i = 0; rc == 0 && i < cps.n; i++) {
    if (bert_class(cps.v[i]) != 0) {
      in_word = 0;
      continue;
    }
    if (!in_word && out->n) rc = m2v_buf_put(out, " ", 1);
    if (rc == 0) rc = m2v_buf_put(out, tmp, utf8_put(cps.v[i], tmp));
    in_word = 1;
  }
  free(cps.v);
  return rc;
}

/* --- graphemes (UAX #29, Unicode 16.0) ------------------------------------ */

static int gb_of(uint32_t c) {
  int lo = 0, hi = M2V_GB_TABLE_N - 1;
  while (lo <= hi) {
    int mid = (lo + hi) / 2;
    if (c < m2v_gb_table[mid].lo) hi = mid - 1;
    else if (c > m2v_gb_table[mid].hi) lo = mid + 1;
    else return m2v_gb_table[mid].gb;
  }
  return GB_OTHER;
}

enum { INCB_NONE, INCB_CONSONANT, INCB_EXTEND, INCB_LINKER };

static int incb_of(uint32_t c) {
  if (in_ranges(m2v_incb_linker, M2V_INCB_LINKER_N, c)) return INCB_LINKER;
  if (in_ranges(m2v_incb_consonant, M2V_INCB_CONSONANT_N, c)) return INCB_CONSONANT;
  if (in_ranges(m2v_incb_extend, M2V_INCB_EXTEND_N, c)) return INCB_EXTEND;
  return INCB_NONE;
}

/* End (exclusive) of the extended grapheme cluster starting at cps[i]. */
static size_t grapheme_end(const uint32_t *cps, size_t n, size_t i) {
  int prev = gb_of(cps[i]);
  int pict = in_ranges(m2v_extpict, M2V_EXTPICT_N, cps[i]); /* GB11: ExtPict Extend* ... */
  int pict_zwj = 0;
  int incb = incb_of(cps[i]) == INCB_CONSONANT ? 1 : 0; /* GB9c: 1 after a consonant, 2 once a linker follows */
  int ri = prev == GB_REGIONAL_INDICATOR;
  size_t j = i + 1;
  for (; j < n; j++) {
    uint32_t c = cps[j];
    int cur = gb_of(c), ic = incb_of(c), xp = in_ranges(m2v_extpict, M2V_EXTPICT_N, c);
    int join;
    if (prev == GB_CR && cur == GB_LF) join = 1;                                     /* GB3 */
    else if (prev == GB_CONTROL || prev == GB_CR || prev == GB_LF) join = 0;        /* GB4 */
    else if (cur == GB_CONTROL || cur == GB_CR || cur == GB_LF) join = 0;           /* GB5 */
    else if (prev == GB_L && (cur == GB_L || cur == GB_V || cur == GB_LV || cur == GB_LVT)) join = 1; /* GB6 */
    else if ((prev == GB_LV || prev == GB_V) && (cur == GB_V || cur == GB_T)) join = 1;               /* GB7 */
    else if ((prev == GB_LVT || prev == GB_T) && cur == GB_T) join = 1;             /* GB8 */
    else if (cur == GB_EXTEND || cur == GB_ZWJ) join = 1;                           /* GB9 */
    else if (cur == GB_SPACINGMARK) join = 1;                                       /* GB9a */
    else if (prev == GB_PREPEND) join = 1;                                          /* GB9b */
    else if (incb == 2 && ic == INCB_CONSONANT) join = 1;                           /* GB9c */
    else if (pict_zwj && xp) join = 1;                                              /* GB11 */
    else if (prev == GB_REGIONAL_INDICATOR && cur == GB_REGIONAL_INDICATOR) join = ri % 2 == 1; /* GB12, GB13 */
    else join = 0;                                                                  /* GB999 */
    if (!join) break;
    /* state for the next pair */
    if (ic == INCB_CONSONANT) incb = 1;
    else if (incb && ic == INCB_LINKER) incb = 2;
    else if (incb && ic == INCB_EXTEND) { /* keeps 1 or 2 */ }
    else incb = 0;
    pict_zwj = pict && cur == GB_ZWJ;
    if (xp) pict = 1;
    else if (cur != GB_EXTEND) pict = 0;
    ri = cur == GB_REGIONAL_INDICATOR ? ri + 1 : 0;
    prev = cur;
  }
  return j;
}

/* --- SentencePiece precompiled charsmap (spm_precompiled) ------------------ */

/* The replacement of the shortest prefix of key that has one, as
   spm_precompiled's transform does (it takes the first result). */
static const char *charsmap_transform(const m2v_model *m, const uint8_t *key, size_t len) {
  const uint32_t *a = m->charsmap_trie;
  size_t n = m->charsmap_trie_n, pos = 0;
  if (n == 0) return NULL;
#define OFFSET(u) (((u) >> 10) << (((u) & (1u << 9)) >> 6))
#define LABEL(u) ((u) & ((1u << 31) | 0xFFu))
#define HAS_LEAF(u) (((u) >> 8) & 1u)
#define VALUE(u) ((u) & ((1u << 31) - 1))
  uint32_t unit = a[0];
  pos ^= OFFSET(unit);
  for (size_t k = 0; k < len; k++) {
    uint8_t c = key[k];
    if (c == 0) break;
    pos ^= c;
    if (pos >= n) return NULL;
    unit = a[pos];
    if (LABEL(unit) != c) return NULL;
    pos ^= OFFSET(unit);
    if (pos >= n) return NULL;
    if (HAS_LEAF(unit)) {
      size_t v = VALUE(a[pos]);
      return v < m->charsmap_norm_n ? m->charsmap_norm + v : NULL;
    }
  }
  return NULL;
}

static int is_white(uint32_t c) {
  return (c >= 0x09 && c <= 0x0D) || c == 0x20 || c == 0x85 || c == 0xA0 || c == 0x1680 ||
         (c >= 0x2000 && c <= 0x200A) || c == 0x2028 || c == 0x2029 || c == 0x202F || c == 0x205F || c == 0x3000;
}

/* Precompiled, the Replace steps, Strip and Metaspace: the one pre-token
   the Unigram model sees. */
static int unigram_normalize(const m2v_model *m, const uint8_t *s, size_t len, m2v_buf *out) {
  cps_t cps = {0};
  size_t *off = malloc(sizeof(size_t) * (len + 1));
  m2v_buf pre = {0};
  int rc = off == NULL ? -1 : 0;
  for (size_t i = 0; rc == 0 && i < len;) {
    off[cps.n] = i;
    rc = cps_push(&cps, utf8_get(s, &i));
  }
  if (off) off[cps.n] = len;
  /* Precompiled: whole grapheme if under 6 bytes and mapped, else per char. */
  for (size_t g = 0; rc == 0 && g < cps.n;) {
    size_t e = grapheme_end(cps.v, cps.n, g);
    const uint8_t *gs = s + off[g];
    size_t gl = off[e] - off[g];
    const char *t = gl < 6 ? charsmap_transform(m, gs, gl) : NULL;
    if (t) rc = m2v_buf_put(&pre, t, strlen(t));
    else
      for (size_t k = g; rc == 0 && k < e; k++) {
        const uint8_t *cs = s + off[k];
        size_t cl = off[k + 1] - off[k];
        const char *u = charsmap_transform(m, cs, cl);
        rc = u ? m2v_buf_put(&pre, u, strlen(u)) : m2v_buf_put(&pre, (const char *)cs, cl);
      }
    g = e;
  }
  /* Isolating punctuation, then collapsing whitespace runs to one space
     (which subsumes the earlier " {2,}" rule), then Strip. */
  m2v_buf mid = {0};
  int space = 0;
  for (size_t i = 0; rc == 0 && i < pre.n;) {
    size_t at = i;
    uint32_t c = utf8_get((const uint8_t *)pre.b, &i);
    int padded = c < 0x80 && m->isolate[c];
    if (is_white(c) || padded) space = 1;
    if (is_white(c)) continue;
    if (space && mid.n) rc = m2v_buf_put(&mid, " ", 1);
    space = padded;
    if (rc == 0) rc = m2v_buf_put(&mid, pre.b + at, i - at);
  }
  /* Metaspace: spaces become U+2581, and one is prepended unless the text
     already starts with it. An empty text stays empty. */
  static const char meta[] = "\xe2\x96\x81";
  if (rc == 0 && mid.n) {
    if (!(mid.n >= 3 && memcmp(mid.b, meta, 3) == 0)) rc = m2v_buf_put(out, meta, 3);
    for (size_t i = 0; rc == 0 && i < mid.n; i++)
      rc = mid.b[i] == ' ' ? m2v_buf_put(out, meta, 3) : m2v_buf_put(out, mid.b + i, 1);
  }
  free(cps.v); free(off); free(pre.b); free(mid.b);
  return rc;
}

/* --- Unigram (Viterbi, as tokenizers' encode_optimized) -------------------- */

typedef struct {
  double score;
  uint32_t starts_at;
  int32_t id;
} best_t;

static int push_unknown(const m2v_model *m, const char *run, size_t len, m2v_ids *rev) {
  uint32_t node = 0;
  for (size_t k = 0; k < len && node != M2V_NONE; k++) node = m2v_trie_child(&m->trie, node, (uint8_t)run[k]);
  int32_t id = node != M2V_NONE && node != 0 ? m->trie.nodes[node].token : -1;
  return m2v_ids_push(rev, id >= 0 ? id : m->unk_id);
}

static int viterbi(const m2v_model *m, const char *text, size_t size, m2v_ids *out) {
  if (size == 0) return 0;
  best_t *best = malloc(sizeof(best_t) * (size + 1));
  m2v_ids rev = {0};
  if (best == NULL) return -1;
  for (size_t k = 0; k <= size; k++) best[k] = (best_t){0, M2V_NONE, 0};
  best[0].starts_at = 0;
  for (size_t at = 0; at < size;) {
    double here = best[at].score;
    size_t char_len = utf8_len((uint8_t)text[at]);
    int single = 0;
    uint32_t node = 0;
    for (size_t end = at; end < size;) {
      node = m2v_trie_child(&m->trie, node, (uint8_t)text[end]);
      if (node == M2V_NONE) break;
      end++;
      int32_t id = m->trie.nodes[node].token;
      if (id >= 0) {
        double cand = m->scores[id] + here;
        if (best[end].starts_at == M2V_NONE || cand > best[end].score) best[end] = (best_t){cand, (uint32_t)at, id};
        if (end - at == char_len) single = 1;
      }
    }
    if (!single) {
      double cand = m->unk_score + here;
      best_t *t = &best[at + char_len];
      if (t->starts_at == M2V_NONE || cand > t->score) *t = (best_t){cand, (uint32_t)at, m->unk_id};
    }
    at += char_len;
  }
  /* Back from the end, fusing runs of unknown pieces into one. */
  int rc = 0;
  size_t ends_at = size, run_end = 0;
  int in_run = 0;
  while (rc == 0 && ends_at > 0) {
    best_t p = best[ends_at];
    if (p.id == m->unk_id) {
      if (!in_run) { in_run = 1; run_end = ends_at; }
    } else {
      if (in_run) { rc = push_unknown(m, text + ends_at, run_end - ends_at, &rev); in_run = 0; }
      if (rc == 0) rc = m2v_ids_push(&rev, p.id);
    }
    ends_at = p.starts_at;
  }
  if (rc == 0 && in_run) rc = push_unknown(m, text, run_end, &rev);
  for (size_t k = rev.n; rc == 0 && k > 0; k--) rc = m2v_ids_push(out, rev.v[k - 1]);
  free(best);
  free(rev.v);
  return rc;
}

static int encode_unigram(const m2v_model *m, const uint8_t *s, size_t len, m2v_ids *out) {
  m2v_buf pre = {0};
  int rc = unigram_normalize(m, s, len, &pre);
  if (rc == 0) rc = viterbi(m, pre.b, pre.n, out);
  free(pre.b);
  return rc;
}

/* --- added tokens, then the model's pipeline on the text between them ----- */

static int encode_span(const m2v_model *m, const uint8_t *s, size_t len, m2v_ids *out) {
  if (len == 0) return 0;
  return m->kind == M2V_WORDPIECE ? encode_bert(m, s, len, out) : encode_unigram(m, s, len, out);
}

int m2v_encode(const m2v_model *m, const char *text, size_t len, m2v_ids *out) {
  const uint8_t *s = (const uint8_t *)text;
  size_t start = 0, i = 0;
  while (i < len) {
    const m2v_added *hit = NULL;
    if (m->added_first[s[i]])
      for (int k = 0; k < m->n_added && hit == NULL; k++)
        if (m->added[k].len <= len - i && memcmp(s + i, m->added[k].text, m->added[k].len) == 0) hit = &m->added[k];
    if (hit) {
      if (encode_span(m, s + start, i - start, out) || m2v_ids_push(out, hit->id)) return -1;
      i += hit->len;
      start = i;
    } else {
      i += utf8_len(s[i]);
    }
  }
  return encode_span(m, s + start, len - start, out);
}
