/* OCaml side of sig.h (src/lib/siglip.ml). Image bytes are copied before
   the runtime is released, so the slow parts run alongside other domains. */

#include <stdlib.h>
#include <string.h>

#include <ggml.h>
#include <gguf.h>

#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>

#include "sig.h"

#define Sig_val(v) (*(sig_model **)Data_custom_val(v))

static void sig_finalize(value v) { sig_free(Sig_val(v)); }

static struct custom_operations sig_ops = {
    "contextual.siglip.model", sig_finalize, custom_compare_default, custom_hash_default,
    custom_serialize_default, custom_deserialize_default, custom_compare_ext_default, custom_fixed_length_default};

value ctx_sig_load(value path) {
  CAMLparam1(path);
  CAMLlocal1(v);
  char err[256] = "";
  char *p = caml_stat_strdup(String_val(path));
  caml_enter_blocking_section();
  sig_model *m = sig_load(p, err, sizeof err);
  caml_leave_blocking_section();
  caml_stat_free(p);
  if (m == NULL) caml_failwith(err);
  v = caml_alloc_custom(&sig_ops, sizeof(sig_model *), 0, 1);
  Sig_val(v) = m;
  CAMLreturn(v);
}

value ctx_sig_dim(value m) { return Val_int(sig_dim(Sig_val(m))); }

value ctx_sig_logit(value m) {
  CAMLparam1(m);
  CAMLlocal1(r);
  r = caml_alloc_tuple(2);
  Store_field(r, 0, caml_copy_double(sig_logit_scale(Sig_val(m))));
  Store_field(r, 1, caml_copy_double(sig_logit_bias(Sig_val(m))));
  CAMLreturn(r);
}

static value float_array(const float *x, int n) {
  value a = caml_alloc(n * Double_wosize, Double_array_tag);
  for (int i = 0; i < n; i++) Store_double_flat_field(a, i, x[i]);
  return a;
}

static value some(value v) {
  CAMLparam1(v);
  CAMLlocal1(s);
  s = caml_alloc(1, 0);
  Store_field(s, 0, v);
  CAMLreturn(s);
}

/* Ok embedding, or Error "undecodable" (not a JPEG, PNG or WebP the decoders
   accept) or "small" (under min_side pixels). */
value ctx_sig_embed(value m, value bytes, value max_patches, value min_side, value threads) {
  CAMLparam5(m, bytes, max_patches, min_side, threads);
  CAMLlocal1(out);
  sig_model *model = Sig_val(m);
  int dim = sig_dim(model), mp = Int_val(max_patches), ms = Int_val(min_side), nt = Int_val(threads);
  size_t len = caml_string_length(bytes);
  unsigned char *b = malloc(len ? len : 1);
  float *e = malloc(sizeof(float) * dim);
  if (b == NULL || e == NULL) {
    free(b);
    free(e);
    caml_raise_out_of_memory();
  }
  memcpy(b, String_val(bytes), len);
  caml_enter_blocking_section();
  int rc = sig_embed_image(model, b, len, mp, ms, nt, e);
  caml_leave_blocking_section();
  free(b);
  if (rc == -2) {
    free(e);
    caml_failwith("Siglip.embed: the model failed");
  }
  if (rc == 0) {
    out = caml_alloc(1, 0); /* Ok */
    Store_field(out, 0, float_array(e, dim));
  } else {
    out = caml_alloc(1, 1); /* Error */
    Store_field(out, 0, caml_copy_string(rc == -3 ? "small" : "undecodable"));
  }
  free(e);
  CAMLreturn(out);
}

/* For the parity tests: decoding and preprocessing alone, and the encoder on
   given pixel values. */
value ctx_sig_preprocess(value bytes, value patch, value max_patches) {
  CAMLparam3(bytes, patch, max_patches);
  CAMLlocal2(r, a);
  int w, h, n_h, n_w;
  unsigned char *rgb = sig_decode((const unsigned char *)String_val(bytes), caml_string_length(bytes), SIG_MAX_PIXELS, &w, &h);
  if (rgb == NULL) CAMLreturn(Val_none);
  float *px = sig_preprocess(rgb, w, h, Int_val(patch), Int_val(max_patches), &n_h, &n_w);
  free(rgb);
  if (px == NULL) caml_raise_out_of_memory();
  a = float_array(px, n_h * n_w * 3 * Int_val(patch) * Int_val(patch));
  free(px);
  r = caml_alloc_tuple(3);
  Store_field(r, 0, Val_int(n_h));
  Store_field(r, 1, Val_int(n_w));
  Store_field(r, 2, a);
  CAMLreturn(some(r));
}

value ctx_sig_encode(value m, value pixels, value n_h, value n_w, value threads) {
  CAMLparam5(m, pixels, n_h, n_w, threads);
  sig_model *model = Sig_val(m);
  size_t n = Wosize_val(pixels) / Double_wosize;
  int dim = sig_dim(model);
  float *px = malloc(sizeof(float) * (n ? n : 1)), *e = malloc(sizeof(float) * dim);
  if (px == NULL || e == NULL) {
    free(px);
    free(e);
    caml_raise_out_of_memory();
  }
  for (size_t i = 0; i < n; i++) px[i] = (float)Double_flat_field(pixels, i);
  caml_enter_blocking_section();
  int rc = sig_encode(model, px, Int_val(n_h), Int_val(n_w), Int_val(threads), e);
  caml_leave_blocking_section();
  free(px);
  if (rc) {
    free(e);
    caml_failwith("Siglip.encode: the model failed");
  }
  value out = float_array(e, dim);
  free(e);
  CAMLreturn(out);
}

/* The taxonomy's text embeddings (src/stubs/tools/siglip_prototypes.py):
   ids from "siglip2.labels", one row each in the "prototypes" tensor. */
value ctx_sig_prototypes(value path) {
  CAMLparam1(path);
  CAMLlocal4(r, ids, rows, row);
  struct ggml_context *ctx = NULL;
  struct gguf_init_params p = {false, &ctx};
  struct gguf_context *g = gguf_init_from_file(String_val(path), p);
  if (g == NULL) caml_failwith("Siglip.prototypes: not a readable GGUF file");
  int64_t k = gguf_find_key(g, "siglip2.labels");
  struct ggml_tensor *t = ggml_get_tensor(ctx, "prototypes");
  if (k < 0 || t == NULL || (t->type != GGML_TYPE_F16 && t->type != GGML_TYPE_F32)
      || (int64_t)gguf_get_arr_n(g, k) != t->ne[1]) {
    gguf_free(g);
    ggml_free(ctx);
    caml_failwith("Siglip.prototypes: expected siglip2.labels and a matching prototypes tensor");
  }
  int n = (int)t->ne[1], dim = (int)t->ne[0];
  float *buf = malloc(sizeof(float) * dim);
  if (buf == NULL) caml_raise_out_of_memory();
  ids = caml_alloc(n, 0);
  rows = caml_alloc(n, 0);
  for (int i = 0; i < n; i++) {
    Store_field(ids, i, caml_copy_string(gguf_get_arr_str(g, k, i)));
    if (t->type == GGML_TYPE_F16) ggml_fp16_to_fp32_row((const ggml_fp16_t *)((char *)t->data + i * t->nb[1]), buf, dim);
    else memcpy(buf, (char *)t->data + i * t->nb[1], sizeof(float) * dim);
    row = float_array(buf, dim);
    Store_field(rows, i, row);
  }
  free(buf);
  gguf_free(g);
  ggml_free(ctx);
  r = caml_alloc_tuple(2);
  Store_field(r, 0, ids);
  Store_field(r, 1, rows);
  CAMLreturn(r);
}
