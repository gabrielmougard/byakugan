/* OCaml side of m2v.h (src/lib/model2vec.ml), and the GGUF writer behind
   the converter (src/m2vgguf/m2vgguf.ml). */

#include <stdlib.h>
#include <string.h>

#include <ggml.h>
#include <gguf.h>

#include <caml/alloc.h>
#include <caml/bigarray.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>

#include "m2v_internal.h"

/* --- models ---------------------------------------------------------------- */

#define Model_val(v) (*(m2v_model **)Data_custom_val(v))

static void model_finalize(value v) { m2v_free(Model_val(v)); }

static struct custom_operations model_ops = {
    "contextual.m2v.model", model_finalize, custom_compare_default, custom_hash_default,
    custom_serialize_default, custom_deserialize_default, custom_compare_ext_default, custom_fixed_length_default};

value ctx_m2v_load(value path) {
  CAMLparam1(path);
  CAMLlocal1(v);
  char err[256] = "";
  char *p = caml_stat_strdup(String_val(path));
  caml_enter_blocking_section();
  m2v_model *m = m2v_load(p, err, sizeof err);
  caml_leave_blocking_section();
  caml_stat_free(p);
  if (m == NULL) caml_failwith(err);
  v = caml_alloc_custom(&model_ops, sizeof(m2v_model *), 0, 1);
  Model_val(v) = m;
  CAMLreturn(v);
}

value ctx_m2v_dim(value m) { return Val_int(m2v_dim(Model_val(m))); }

value ctx_m2v_tokenize(value m, value text) {
  CAMLparam2(m, text);
  CAMLlocal1(out);
  size_t len = caml_string_length(text);
  int32_t *ids = malloc(sizeof(int32_t) * (len + 4));
  if (ids == NULL) caml_raise_out_of_memory();
  long n = m2v_tokenize(Model_val(m), String_val(text), len, ids, len + 4);
  if (n > (long)(len + 4)) {
    int32_t *more = realloc(ids, sizeof(int32_t) * n);
    if (more == NULL) { free(ids); caml_raise_out_of_memory(); }
    ids = more;
    n = m2v_tokenize(Model_val(m), String_val(text), len, ids, n);
  }
  if (n < 0) { free(ids); caml_raise_out_of_memory(); }
  out = caml_alloc(n, 0);
  for (long i = 0; i < n; i++) Store_field(out, i, Val_int(ids[i]));
  free(ids);
  CAMLreturn(out);
}

/* texts embedded into an n x dim float32 Bigarray, runtime released. */
value ctx_m2v_embed_batch(value m, value texts) {
  CAMLparam2(m, texts);
  m2v_model *model = Model_val(m);
  size_t n = Wosize_val(texts), total = 0;
  int dim = m2v_dim(model);
  for (size_t i = 0; i < n; i++) total += caml_string_length(Field(texts, i));
  char *buf = malloc(total + 1);
  size_t *off = malloc(sizeof(size_t) * (n + 1));
  float *out = malloc(sizeof(float) * (n ? n : 1) * dim);
  if (buf == NULL || off == NULL || out == NULL) { free(buf); free(off); free(out); caml_raise_out_of_memory(); }
  off[0] = 0;
  for (size_t i = 0; i < n; i++) {
    size_t l = caml_string_length(Field(texts, i));
    memcpy(buf + off[i], String_val(Field(texts, i)), l);
    off[i + 1] = off[i] + l;
  }
  int rc = 0;
  caml_enter_blocking_section();
  for (size_t i = 0; i < n && rc == 0; i++) rc = m2v_embed(model, buf + off[i], off[i + 1] - off[i], out + i * dim);
  caml_leave_blocking_section();
  free(buf);
  free(off);
  if (rc) { free(out); caml_raise_out_of_memory(); }
  CAMLreturn(caml_ba_alloc_dims(CAML_BA_FLOAT32 | CAML_BA_C_LAYOUT | CAML_BA_MANAGED, 2, out, (intnat)n, (intnat)dim));
}

/* out.{i, j} = dot(vecs.{i}, protos.{j}); float32 C-layout Bigarrays. */
value ctx_m2v_dots(value protos, value vecs, value out) {
  CAMLparam3(protos, vecs, out);
  struct caml_ba_array *p = Caml_ba_array_val(protos), *v = Caml_ba_array_val(vecs), *o = Caml_ba_array_val(out);
  int dim = (int)p->dim[1], np = (int)p->dim[0], n = (int)v->dim[0];
  if (v->dim[1] != dim || o->dim[0] != n || o->dim[1] != np) caml_invalid_argument("Model2vec.dots: shapes");
  /* Data pointers taken now: the Bigarray headers may move once released. */
  float *pd = p->data, *vd = v->data, *od = o->data;
  caml_enter_blocking_section();
  int rc = n == 0 ? 0 : m2v_dots(pd, np, vd, n, dim, od);
  caml_leave_blocking_section();
  if (rc) caml_failwith("Model2vec.dots: ggml failed");
  CAMLreturn(Val_unit);
}

/* Words for the lexicon tiers (src/lib/text.ml). */
value ctx_m2v_words(value text) {
  CAMLparam1(text);
  CAMLlocal1(r);
  m2v_buf out = {0};
  if (m2v_words(String_val(text), caml_string_length(text), &out)) {
    free(out.b);
    caml_raise_out_of_memory();
  }
  r = caml_alloc_initialized_string(out.n, out.b ? out.b : "");
  free(out.b);
  CAMLreturn(r);
}

/* --- GGUF writer --------------------------------------------------------------- */

/* Up to MAX_TENSORS tensors: SigLIP 2 base's vision tower has 168. */
#define MAX_TENSORS 1024

typedef struct {
  struct gguf_context *g;
  struct ggml_context *ctx;
  void *bufs[MAX_TENSORS];
  int nbufs;
} writer;

#define Writer_val(v) (*(writer **)Data_custom_val(v))

static void writer_finalize(value v) {
  writer *w = Writer_val(v);
  if (w == NULL) return;
  gguf_free(w->g);
  ggml_free(w->ctx);
  for (int i = 0; i < w->nbufs; i++) free(w->bufs[i]);
  free(w);
}

static struct custom_operations writer_ops = {
    "contextual.m2v.gguf_writer", writer_finalize, custom_compare_default, custom_hash_default,
    custom_serialize_default, custom_deserialize_default, custom_compare_ext_default, custom_fixed_length_default};

value ctx_gguf_new(value unit) {
  CAMLparam1(unit);
  CAMLlocal1(v);
  writer *w = calloc(1, sizeof(writer));
  struct ggml_init_params params = {MAX_TENSORS * ggml_tensor_overhead(), NULL, true};
  if (w == NULL) caml_raise_out_of_memory();
  w->g = gguf_init_empty();
  w->ctx = ggml_init(params);
  v = caml_alloc_custom(&writer_ops, sizeof(writer *), 0, 1);
  Writer_val(v) = w;
  CAMLreturn(v);
}

value ctx_gguf_str(value w, value k, value s) {
  gguf_set_val_str(Writer_val(w)->g, String_val(k), String_val(s));
  return Val_unit;
}

value ctx_gguf_u32(value w, value k, value n) {
  gguf_set_val_u32(Writer_val(w)->g, String_val(k), (uint32_t)Long_val(n));
  return Val_unit;
}

value ctx_gguf_f32(value w, value k, value x) {
  gguf_set_val_f32(Writer_val(w)->g, String_val(k), (float)Double_val(x));
  return Val_unit;
}

value ctx_gguf_bool(value w, value k, value b) {
  gguf_set_val_bool(Writer_val(w)->g, String_val(k), Bool_val(b));
  return Val_unit;
}

value ctx_gguf_strs(value w, value k, value a) {
  size_t n = Wosize_val(a);
  const char **s = malloc(sizeof(char *) * (n ? n : 1));
  if (s == NULL) caml_raise_out_of_memory();
  for (size_t i = 0; i < n; i++) s[i] = String_val(Field(a, i));
  gguf_set_arr_str(Writer_val(w)->g, String_val(k), s, n);
  free(s);
  return Val_unit;
}

value ctx_gguf_i32s(value w, value k, value a) {
  size_t n = Wosize_val(a);
  int32_t *x = malloc(sizeof(int32_t) * (n ? n : 1));
  if (x == NULL) caml_raise_out_of_memory();
  for (size_t i = 0; i < n; i++) x[i] = (int32_t)Long_val(Field(a, i));
  gguf_set_arr_data(Writer_val(w)->g, String_val(k), GGUF_TYPE_INT32, x, n);
  free(x);
  return Val_unit;
}

value ctx_gguf_f64s(value w, value k, value a) {
  size_t n = Wosize_val(a) / Double_wosize;
  double *x = malloc(sizeof(double) * (n ? n : 1));
  if (x == NULL) caml_raise_out_of_memory();
  for (size_t i = 0; i < n; i++) x[i] = Double_flat_field(a, i);
  gguf_set_arr_data(Writer_val(w)->g, String_val(k), GGUF_TYPE_FLOAT64, x, n);
  free(x);
  return Val_unit;
}

value ctx_gguf_bytes(value w, value k, value s) {
  gguf_set_arr_data(Writer_val(w)->g, String_val(k), GGUF_TYPE_UINT8, String_val(s), caml_string_length(s));
  return Val_unit;
}

/* A float32 rows x cols table stored as "f32", "f16" or "q8_0". */
value ctx_gguf_table(value w, value name, value table, value type_name) {
  CAMLparam4(w, name, table, type_name);
  writer *wr = Writer_val(w);
  struct caml_ba_array *t = Caml_ba_array_val(table);
  int64_t rows = t->dim[0], cols = t->dim[1];
  const char *tn = String_val(type_name);
  enum ggml_type type = strcmp(tn, "f32") == 0 ? GGML_TYPE_F32 : strcmp(tn, "f16") == 0 ? GGML_TYPE_F16
                        : strcmp(tn, "q8_0") == 0 ? GGML_TYPE_Q8_0 : GGML_TYPE_COUNT;
  if (type == GGML_TYPE_COUNT) caml_invalid_argument("gguf table type: f32, f16 or q8_0");
  if (cols % ggml_blck_size(type)) caml_invalid_argument("gguf table: row length not a multiple of the block size");
  if (wr->nbufs == MAX_TENSORS) caml_failwith("gguf table: too many tables");
  size_t size = ggml_row_size(type, cols) * rows;
  void *dst = malloc(size);
  if (dst == NULL) caml_raise_out_of_memory();
  const float *src = t->data;
  caml_enter_blocking_section();
  if (type == GGML_TYPE_F32) memcpy(dst, src, size);
  else ggml_quantize_chunk(type, src, dst, 0, rows, cols, NULL);
  caml_leave_blocking_section();
  wr->bufs[wr->nbufs++] = dst;
  struct ggml_tensor *tensor = ggml_new_tensor_2d(wr->ctx, type, cols, rows);
  ggml_set_name(tensor, String_val(name));
  tensor->data = dst;
  gguf_add_tensor(wr->g, tensor);
  CAMLreturn(Val_unit);
}

value ctx_gguf_write(value w, value path) {
  if (!gguf_write_to_file(Writer_val(w)->g, String_val(path), false)) caml_failwith("gguf: cannot write file");
  return Val_unit;
}
