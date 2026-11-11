/* Shared by m2v_model.c and m2v_text.c. */

#ifndef M2V_INTERNAL_H
#define M2V_INTERNAL_H

#include <stddef.h>
#include <stdint.h>

#include "m2v.h"

#define M2V_NONE 0xFFFFFFFFu

/* Byte trie of the vocabulary: children as sorted sibling lists, the root's
   as a direct table. */
typedef struct {
  uint32_t child, sibling;
  int32_t token; /* id ending here, or -1 */
  uint8_t label;
} m2v_tnode;

typedef struct {
  m2v_tnode *nodes; /* node 0 is the root */
  uint32_t count;
  uint32_t root[256];
} m2v_trie;

typedef struct {
  char *text;
  size_t len;
  int32_t id;
} m2v_added;

enum { M2V_WORDPIECE, M2V_UNIGRAM };

struct m2v_model {
  int kind;
  int dim, vocab;
  int normalize;
  int32_t unk_id;
  m2v_added *added; /* longest first */
  int n_added;
  uint8_t added_first[256];
  m2v_trie trie;
  /* WordPiece */
  uint32_t continuation; /* node reached by "##" */
  int32_t single_byte[128];
  int max_chars;
  /* Unigram */
  double *scores;
  double unk_score;
  const uint32_t *charsmap_trie; /* Darts double array */
  size_t charsmap_trie_n;
  const char *charsmap_norm; /* NUL-separated replacements */
  size_t charsmap_norm_n;
  uint8_t *charsmap_copy;
  char isolate[128]; /* ASCII characters padded with spaces */
  /* table */
  int type; /* enum ggml_type */
  size_t row_size;
  const uint8_t *table;
  void *map;
  size_t map_len;
};

typedef struct {
  int32_t *v;
  size_t n, cap;
} m2v_ids;

typedef struct {
  char *b;
  size_t n, cap;
} m2v_buf;

int m2v_ids_push(m2v_ids *a, int32_t x);
int m2v_buf_put(m2v_buf *a, const char *s, size_t n);

uint32_t m2v_trie_child(const m2v_trie *t, uint32_t node, uint8_t b);
int m2v_trie_build(m2v_trie *t, const char **keys, const size_t *lens, int n);

/* Token ids of valid UTF-8 text; 0, or -1 when out of memory. */
int m2v_encode(const m2v_model *m, const char *text, size_t len, m2v_ids *out);

/* Invalid UTF-8 replaced by U+FFFD. Returns text itself when it is valid,
   else a buffer to free; NULL when out of memory. */
char *m2v_sanitize(const char *text, size_t len, size_t *out_len);

/* The words of any text (invalid UTF-8 replaced by U+FFFD), joined by single
   spaces: 0, or -1 when out of memory. */
int m2v_words(const char *text, size_t len, m2v_buf *out);

#endif
