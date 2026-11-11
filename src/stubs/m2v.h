/* Model2Vec static embeddings in C: a model is one GGUF file (written by
   src/m2vgguf) holding the token table and the whole tokenizer.

   Tokenizers are ports of model2vec-rs (MIT) and of Hugging Face tokenizers'
   pipelines, and give the same token ids as `tokenizers` (checked against it,
   src/test/m2v_*.tsv):
     - WordPiece: BertNormalizer + BertPreTokenizer (potion-base-*);
     - Unigram: SentencePiece precompiled charsmap, punctuation isolation,
       whitespace collapsing, Metaspace (potion-multilingual-128M).

   A loaded model is read-only: any number of threads may use it at once. */

#ifndef M2V_H
#define M2V_H

#include <stddef.h>
#include <stdint.h>

typedef struct m2v_model m2v_model;

/* NULL on failure, with a message in err. */
m2v_model *m2v_load(const char *gguf_path, char *err, size_t errlen);
void m2v_free(m2v_model *m);

int m2v_dim(const m2v_model *m);
int m2v_vocab_size(const m2v_model *m);

/* Token ids of text (UTF-8; invalid bytes read as U+FFFD), as tokenizers'
   encode(text, add_special_tokens=False). Writes at most cap ids and
   returns how many there are. -1 when out of memory. */
long m2v_tokenize(const m2v_model *m, const char *text, size_t len, int32_t *ids, size_t cap);

/* Mean of the rows of the text's tokens, unknown tokens left out, then
   L2-normalised if the model says so. Zeros when no token is known.
   Returns -1 when out of memory, else 0. */
int m2v_embed(const m2v_model *m, const char *text, size_t len, float *out);

/* out[i * n_protos + j] = dot(vecs[i], protos[j]), one ggml matrix
   multiply on one thread. Returns 0, or -1 on failure. */
int m2v_dots(const float *protos, int n_protos, const float *vecs, int n, int dim, float *out);

#endif
