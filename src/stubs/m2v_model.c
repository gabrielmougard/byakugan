/* Loading a Model2Vec GGUF file, embedding text, and dot products with ggml.
   The GGUF keys are written by src/m2vgguf/m2vgguf.ml. */

#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <ggml-cpu.h>
#include <ggml.h>
#include <gguf.h>

#include "m2v.h"
#include "m2v_internal.h"

static int fail(char *err, size_t errlen, const char *msg) {
  snprintf(err, errlen, "%s", msg);
  return -1;
}

static int64_t key(const struct gguf_context *g, const char *k, enum gguf_type type) {
  int64_t id = gguf_find_key(g, k);
  return id >= 0 && gguf_get_kv_type(g, id) == type ? id : -1;
}

static int load_added(m2v_model *m, const struct gguf_context *g) {
  int64_t texts = key(g, "m2v.added_tokens", GGUF_TYPE_ARRAY), ids = key(g, "m2v.added_ids", GGUF_TYPE_ARRAY);
  if (texts < 0 || ids < 0 || gguf_get_arr_n(g, texts) != gguf_get_arr_n(g, ids)) return -1;
  m->n_added = (int)gguf_get_arr_n(g, texts);
  m->added = calloc(m->n_added ? m->n_added : 1, sizeof(m2v_added));
  if (m->added == NULL) return -1;
  const int32_t *id = gguf_get_arr_data(g, ids);
  for (int i = 0; i < m->n_added; i++) {
    const char *t = gguf_get_arr_str(g, texts, i);
    m->added[i] = (m2v_added){strdup(t), strlen(t), id[i]};
    if (m->added[i].text == NULL || m->added[i].len == 0) return -1;
    m->added_first[(uint8_t)t[0]] = 1;
  }
  /* Longest first, then by content: a shorter token cannot shadow a longer
     one sharing its prefix. */
  for (int i = 1; i < m->n_added; i++)
    for (int j = i; j > 0; j--) {
      m2v_added *a = &m->added[j - 1], *b = &m->added[j];
      if (a->len > b->len || (a->len == b->len && strcmp(a->text, b->text) <= 0)) break;
      m2v_added t = *a; *a = *b; *b = t;
    }
  return 0;
}

static int load_tokenizer(m2v_model *m, const struct gguf_context *g, char *err, size_t errlen) {
  int64_t kind = key(g, "m2v.tokenizer", GGUF_TYPE_STRING), toks = key(g, "m2v.tokens", GGUF_TYPE_ARRAY),
          unk = key(g, "m2v.unk_id", GGUF_TYPE_UINT32);
  if (kind < 0 || toks < 0 || unk < 0) return fail(err, errlen, "m2v: missing tokenizer keys");
  const char *k = gguf_get_val_str(g, kind);
  m->kind = strcmp(k, "wordpiece") == 0 ? M2V_WORDPIECE : strcmp(k, "unigram") == 0 ? M2V_UNIGRAM : -1;
  if (m->kind < 0) return fail(err, errlen, "m2v: unknown tokenizer");
  m->unk_id = (int32_t)gguf_get_val_u32(g, unk);
  int n = (int)gguf_get_arr_n(g, toks);
  if (n != m->vocab) return fail(err, errlen, "m2v: vocabulary and table sizes differ");
  const char **keys = malloc(sizeof(char *) * n);
  size_t *lens = malloc(sizeof(size_t) * n);
  if (keys == NULL || lens == NULL) { free(keys); free(lens); return fail(err, errlen, "m2v: out of memory"); }
  for (int i = 0; i < n; i++) {
    keys[i] = gguf_get_arr_str(g, toks, i);
    lens[i] = strlen(keys[i]);
  }
  int rc = m2v_trie_build(&m->trie, keys, lens, n);
  if (rc == 0 && m->kind == M2V_WORDPIECE)
    for (int b = 0; b < 128; b++) {
      uint32_t node = m->trie.root[b];
      m->single_byte[b] = node == M2V_NONE ? -1 : m->trie.nodes[node].token;
    }
  free(keys);
  free(lens);
  if (rc) return fail(err, errlen, "m2v: out of memory");
  if (load_added(m, g)) return fail(err, errlen, "m2v: bad added tokens");

  if (m->kind == M2V_WORDPIECE) {
    int64_t prefix = key(g, "m2v.wordpiece.prefix", GGUF_TYPE_STRING), max = key(g, "m2v.wordpiece.max_chars", GGUF_TYPE_UINT32);
    if (prefix < 0 || max < 0) return fail(err, errlen, "m2v: missing WordPiece keys");
    m->max_chars = (int)gguf_get_val_u32(g, max);
    uint32_t node = 0;
    for (const char *p = gguf_get_val_str(g, prefix); *p && node != M2V_NONE; p++)
      node = m2v_trie_child(&m->trie, node, (uint8_t)*p);
    m->continuation = node;
    return 0;
  }
  int64_t scores = key(g, "m2v.unigram.scores", GGUF_TYPE_ARRAY), cmap = key(g, "m2v.unigram.charsmap", GGUF_TYPE_ARRAY),
          iso = key(g, "m2v.unigram.isolate", GGUF_TYPE_STRING);
  if (scores < 0 || cmap < 0 || iso < 0 || gguf_get_arr_type(g, scores) != GGUF_TYPE_FLOAT64 ||
      gguf_get_arr_n(g, scores) != (size_t)n || gguf_get_arr_type(g, cmap) != GGUF_TYPE_UINT8)
    return fail(err, errlen, "m2v: missing Unigram keys");
  m->scores = malloc(sizeof(double) * n);
  if (m->scores == NULL) return fail(err, errlen, "m2v: out of memory");
  memcpy(m->scores, gguf_get_arr_data(g, scores), sizeof(double) * n);
  double min = 0;
  for (int i = 0; i < n; i++)
    if (i == 0 || m->scores[i] < min) min = m->scores[i];
  m->unk_score = min - 10.0; /* tokenizers' K_UNK_PENALTY */
  for (const char *p = gguf_get_val_str(g, iso); *p; p++)
    if ((uint8_t)*p < 128) m->isolate[(uint8_t)*p] = 1;
  /* charsmap: u32 trie size in bytes, the Darts array, then the
     NUL-separated replacements. Copied, with a final NUL. */
  size_t cn = gguf_get_arr_n(g, cmap);
  const uint8_t *c = gguf_get_arr_data(g, cmap);
  if (cn >= 4) {
    uint32_t trie_bytes = c[0] | c[1] << 8 | c[2] << 16 | (uint32_t)c[3] << 24;
    if (4 + (size_t)trie_bytes > cn) return fail(err, errlen, "m2v: bad charsmap");
    m->charsmap_copy = malloc(cn + 1);
    if (m->charsmap_copy == NULL) return fail(err, errlen, "m2v: out of memory");
    memcpy(m->charsmap_copy, c, cn);
    m->charsmap_copy[cn] = 0;
    m->charsmap_trie = (const uint32_t *)(void *)(m->charsmap_copy + 4); /* little-endian hosts */
    m->charsmap_trie_n = trie_bytes / 4;
    m->charsmap_norm = (const char *)m->charsmap_copy + 4 + trie_bytes;
    m->charsmap_norm_n = cn - 4 - trie_bytes;
  }
  return 0;
}

m2v_model *m2v_load(const char *path, char *err, size_t errlen) {
  struct gguf_init_params params = {true, NULL};
  struct gguf_context *g = gguf_init_from_file(path, params);
  if (g == NULL) { fail(err, errlen, "m2v: cannot read GGUF"); return NULL; }
  m2v_model *m = calloc(1, sizeof(m2v_model));
  int64_t t = gguf_find_tensor(g, "embeddings"), norm = key(g, "m2v.normalize", GGUF_TYPE_BOOL);
  int ok = m != NULL && t >= 0 && norm >= 0;
  if (!ok) fail(err, errlen, "m2v: not a Model2Vec GGUF file");
  if (ok) {
    const int64_t *ne = gguf_get_tensor_ne(g, t);
    m->dim = (int)ne[0];
    m->vocab = (int)ne[1];
    m->type = gguf_get_tensor_type(g, t);
    m->row_size = ggml_row_size(m->type, m->dim);
    m->normalize = gguf_get_val_bool(g, norm);
    ok = load_tokenizer(m, g, err, errlen) == 0;
  }
  if (ok) {
    int fd = open(path, O_RDONLY);
    struct stat st;
    ok = fd >= 0 && fstat(fd, &st) == 0;
    size_t start = gguf_get_data_offset(g) + gguf_get_tensor_offset(g, t);
    ok = ok && start + m->row_size * (size_t)m->vocab <= (size_t)st.st_size;
    if (ok) {
      m->map_len = st.st_size;
      m->map = mmap(NULL, m->map_len, PROT_READ, MAP_SHARED, fd, 0);
      ok = m->map != MAP_FAILED;
      if (ok) m->table = (const uint8_t *)m->map + start;
      else m->map = NULL;
    }
    if (fd >= 0) close(fd);
    if (!ok) fail(err, errlen, "m2v: cannot map the table");
  }
  gguf_free(g);
  if (!ok) { m2v_free(m); return NULL; }
  return m;
}

void m2v_free(m2v_model *m) {
  if (m == NULL) return;
  for (int i = 0; i < m->n_added; i++) free(m->added[i].text);
  free(m->added);
  free(m->trie.nodes);
  free(m->scores);
  free(m->charsmap_copy);
  if (m->map) munmap(m->map, m->map_len);
  free(m);
}

int m2v_dim(const m2v_model *m) { return m->dim; }
int m2v_vocab_size(const m2v_model *m) { return m->vocab; }

/* Invalid UTF-8 replaced by U+FFFD per maximal invalid subpart, as Python's
   errors="replace" decodes it: the reference tokenizer only sees str. */
char *m2v_sanitize(const char *text, size_t len, size_t *out_len) {
  const uint8_t *s = (const uint8_t *)text;
  m2v_buf b = {0};
  size_t i = 0, run = 0;
  while (i < len) {
    uint8_t c = s[i];
    size_t n = 0;
    uint32_t lo = 0x80, hi = 0xBF;
    if (c < 0x80) n = 1;
    else if (c >= 0xC2 && c <= 0xDF) n = 2;
    else if (c >= 0xE0 && c <= 0xEF) { n = 3; if (c == 0xE0) lo = 0xA0; if (c == 0xED) hi = 0x9F; }
    else if (c >= 0xF0 && c <= 0xF4) { n = 4; if (c == 0xF0) lo = 0x90; if (c == 0xF4) hi = 0x8F; }
    size_t k = 1;
    if (n > 1)
      for (; k < n && i + k < len; k++) {
        uint8_t d = s[i + k];
        if (d < (k == 1 ? lo : 0x80) || d > (k == 1 ? hi : 0xBF)) break;
      }
    if (n == 0 || k < n) {
      if (run < i && m2v_buf_put(&b, text + run, i - run)) { free(b.b); return NULL; }
      if (m2v_buf_put(&b, "\xef\xbf\xbd", 3)) { free(b.b); return NULL; }
      i += n == 0 ? 1 : k;
      run = i;
    } else {
      i += n;
    }
  }
  if (b.b == NULL) {
    *out_len = len;
    return (char *)text;
  }
  if (run < len && m2v_buf_put(&b, text + run, len - run)) { free(b.b); return NULL; }
  *out_len = b.n;
  return b.b;
}

static int encode_text(const m2v_model *m, const char *text, size_t len, m2v_ids *ids) {
  size_t n;
  char *clean = m2v_sanitize(text, len, &n);
  if (clean == NULL) return -1;
  int rc = m2v_encode(m, clean, n, ids);
  if (clean != text) free(clean);
  return rc;
}

long m2v_tokenize(const m2v_model *m, const char *text, size_t len, int32_t *out, size_t cap) {
  m2v_ids ids = {0};
  if (encode_text(m, text, len, &ids)) { free(ids.v); return -1; }
  memcpy(out, ids.v, sizeof(int32_t) * (ids.n < cap ? ids.n : cap));
  free(ids.v);
  return (long)ids.n;
}

int m2v_embed(const m2v_model *m, const char *text, size_t len, float *out) {
  m2v_ids ids = {0};
  float *row = m->type == GGML_TYPE_F32 ? NULL : malloc(sizeof(float) * m->dim);
  if ((m->type != GGML_TYPE_F32 && row == NULL) || encode_text(m, text, len, &ids)) {
    free(ids.v); free(row);
    return -1;
  }
  ggml_to_float_t to_float = ggml_get_type_traits(m->type)->to_float;
  memset(out, 0, sizeof(float) * m->dim);
  int count = 0;
  for (size_t i = 0; i < ids.n; i++) {
    int32_t id = ids.v[i];
    if (id == m->unk_id || id < 0 || id >= m->vocab) continue;
    const void *src = m->table + (size_t)id * m->row_size;
    const float *r = row ? (to_float(src, row, m->dim), row) : src;
    for (int k = 0; k < m->dim; k++) out[k] += r[k];
    count++;
  }
  if (count) {
    double norm = 0;
    for (int k = 0; k < m->dim; k++) { out[k] /= count; norm += (double)out[k] * out[k]; }
    if (m->normalize && norm > 0)
      for (int k = 0; k < m->dim; k++) out[k] = (float)(out[k] / sqrt(norm));
  }
  free(ids.v);
  free(row);
  return 0;
}

int m2v_dots(const float *protos, int n_protos, const float *vecs, int n, int dim, float *out) {
  struct ggml_init_params params = {3 * ggml_tensor_overhead() + ggml_graph_overhead() + (1 << 20), NULL, true};
  struct ggml_context *ctx = ggml_init(params);
  if (ctx == NULL) return -1;
  struct ggml_tensor *a = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, dim, n_protos);
  struct ggml_tensor *b = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, dim, n);
  a->data = (void *)protos;
  b->data = (void *)vecs;
  struct ggml_tensor *c = ggml_mul_mat(ctx, a, b);
  c->data = out;
  struct ggml_cgraph *gf = ggml_new_graph(ctx);
  ggml_build_forward_expand(gf, c);
  int status = ggml_graph_compute_with_ctx(ctx, gf, 1);
  ggml_free(ctx);
  return status == GGML_STATUS_SUCCESS ? 0 : -1;
}
