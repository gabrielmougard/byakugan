#include "sig.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <png.h>
#include <turbojpeg.h>
#include <webp/decode.h>

#include "ggml-alloc.h"
#include "ggml-backend.h"
#include "ggml-cpu.h"
#include "ggml.h"
#include "gguf.h"

/* --- Decoding --------------------------------------------------------------- */

static int too_big(long w, long h, long max_pixels) { return w <= 0 || h <= 0 || w > 16384 || h > 16384 || w * h > max_pixels; }

/* The TurboJPEG 2.x calls: Debian ships 2.1, where the 3.x API does not exist. */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
static unsigned char *decode_jpeg(const unsigned char *bytes, size_t len, long max_pixels, int *w, int *h) {
  tjhandle tj = tjInitDecompress();
  int subsamp, colorspace;
  unsigned char *rgb = NULL;
  if (tj == NULL) return NULL;
  if (tjDecompressHeader3(tj, bytes, (unsigned long)len, w, h, &subsamp, &colorspace) == 0 && !too_big(*w, *h, max_pixels)
      && (rgb = malloc((size_t)*w * *h * 3)) != NULL
      && tjDecompress2(tj, bytes, (unsigned long)len, rgb, *w, 0, *h, TJPF_RGB, 0) != 0
      && tjGetErrorCode(tj) != TJERR_WARNING) {
    free(rgb);
    rgb = NULL;
  }
  tjDestroy(tj);
  return rgb;
}
#pragma GCC diagnostic pop

/* RGBA, then the alpha dropped as PIL's convert("RGB") does. */
static unsigned char *decode_png(const unsigned char *bytes, size_t len, long max_pixels, int *w, int *h) {
  png_image img;
  memset(&img, 0, sizeof img);
  img.version = PNG_IMAGE_VERSION;
  if (!png_image_begin_read_from_memory(&img, bytes, len)) return NULL;
  if (too_big(img.width, img.height, max_pixels)) {
    png_image_free(&img);
    return NULL;
  }
  img.format = PNG_FORMAT_RGBA;
  unsigned char *rgba = malloc(PNG_IMAGE_SIZE(img));
  if (rgba == NULL || !png_image_finish_read(&img, NULL, rgba, 0, NULL)) {
    png_image_free(&img);
    free(rgba);
    return NULL;
  }
  *w = (int)img.width;
  *h = (int)img.height;
  size_t n = (size_t)*w * *h;
  for (size_t i = 0; i < n; i++) memmove(rgba + 3 * i, rgba + 4 * i, 3);
  return rgba;
}

static unsigned char *decode_webp(const unsigned char *bytes, size_t len, long max_pixels, int *w, int *h) {
  if (!WebPGetInfo(bytes, len, w, h) || too_big(*w, *h, max_pixels)) return NULL;
  size_t size = (size_t)*w * *h * 3;
  unsigned char *rgb = malloc(size);
  if (rgb != NULL && WebPDecodeRGBInto(bytes, len, rgb, size, *w * 3) == NULL) {
    free(rgb);
    return NULL;
  }
  return rgb;
}

unsigned char *sig_decode(const unsigned char *b, size_t len, long max_pixels, int *w, int *h) {
  if (len >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return decode_jpeg(b, len, max_pixels, w, h);
  if (len >= 8 && memcmp(b, "\x89PNG\r\n\x1a\n", 8) == 0) return decode_png(b, len, max_pixels, w, h);
  if (len >= 12 && memcmp(b, "RIFF", 4) == 0 && memcmp(b + 8, "WEBP", 4) == 0) return decode_webp(b, len, max_pixels, w, h);
  return NULL;
}

/* --- Preprocessing ----------------------------------------------------------- */

static int scaled_size(double scale, int size, int patch) {
  int s = (int)ceil(size * scale / patch) * patch;
  return s < patch ? patch : s;
}

/* Hugging Face's get_image_size_for_max_num_patches. */
static void target_size(int h, int w, int patch, int max_patches, int *th, int *tw) {
  double lo = 1e-6, hi = 100.0;
  while (hi - lo >= 1e-5) {
    double mid = (lo + hi) / 2;
    if ((long)(scaled_size(mid, h, patch) / patch) * (scaled_size(mid, w, patch) / patch) <= max_patches) lo = mid;
    else hi = mid;
  }
  *th = scaled_size(lo, h, patch);
  *tw = scaled_size(lo, w, patch);
}

/* PyTorch's antialiased bilinear resize of a uint8 image, which is what
   Siglip2ImageProcessorFast runs (torchvision on a uint8 tensor): the weights
   of upsample_bilinear2d_aa (a triangle as wide as the scale when shrinking,
   cut at the borders, renormalised) as int16 fixed point, with one precision
   per axis from its largest weight. The float version of the same resize
   differs from it on 15% of the values, enough to cost 0.003 of cosine. */
typedef struct {
  int *first, *count, taps, precision;
  int16_t *k;
} filter;

static int make_filter(int in, int out, filter *f) {
  double scale = (double)in / out, support = scale >= 1 ? scale : 1, invscale = scale >= 1 ? 1 / scale : 1, wmax = 0;
  f->taps = (int)ceil(support) * 2 + 1;
  f->first = malloc(sizeof(int) * out);
  f->count = malloc(sizeof(int) * out);
  double *w = calloc((size_t)out * f->taps, sizeof(double));
  f->k = malloc(sizeof(int16_t) * out * f->taps);
  if (!f->first || !f->count || !w || !f->k) {
    free(w);
    return -1;
  }
  for (int i = 0; i < out; i++) {
    double center = scale * (i + 0.5), total = 0, *wi = w + (size_t)i * f->taps;
    int lo = (int)(center - support + 0.5), hi = (int)(center + support + 0.5);
    if (lo < 0) lo = 0;
    if (hi > in) hi = in;
    if (hi - lo > f->taps) hi = lo + f->taps;
    for (int j = 0; j < hi - lo; j++) {
      double x = fabs((j + lo - center + 0.5) * invscale);
      wi[j] = x < 1 ? 1 - x : 0;
      total += wi[j];
    }
    for (int j = 0; j < hi - lo; j++) {
      if (total != 0) wi[j] /= total;
      if (wi[j] > wmax) wmax = wi[j];
    }
    f->first[i] = lo;
    f->count[i] = hi - lo;
  }
  for (f->precision = 0; f->precision < 22; f->precision++)
    if ((int)(0.5 + wmax * (1 << (f->precision + 1))) >= (1 << 15)) break;
  for (size_t j = 0; j < (size_t)out * f->taps; j++) f->k[j] = (int16_t)(int)(0.5 + w[j] * (1 << f->precision));
  free(w);
  return 0;
}

static void free_filter(filter *f) {
  free(f->first);
  free(f->count);
  free(f->k);
}

/* One axis of an RGB image: along x (stride 3) or y (stride 3 * width). */
static void resize_pass(const unsigned char *src, unsigned char *dst, const filter *f, int lines, int out,
                        size_t src_step, size_t src_line, size_t dst_step, size_t dst_line) {
  for (int l = 0; l < lines; l++)
    for (int i = 0; i < out; i++) {
      const int16_t *k = f->k + (size_t)i * f->taps;
      for (int c = 0; c < 3; c++) {
        int acc = 1 << (f->precision - 1);
        for (int t = 0; t < f->count[i]; t++) acc += k[t] * src[l * src_line + (size_t)(f->first[i] + t) * src_step + c];
        acc >>= f->precision;
        dst[l * dst_line + i * dst_step + c] = (unsigned char)(acc < 0 ? 0 : acc > 255 ? 255 : acc);
      }
    }
}

/* Width first, rounded to uint8, then height; an axis that keeps its size is
   copied, as PyTorch skips it. */
static int resize(const unsigned char *src, int w, int h, unsigned char *dst, int tw, int th) {
  filter fx = {0}, fy = {0};
  unsigned char *mid = malloc((size_t)h * tw * 3);
  int rc = -1;
  if (mid == NULL || make_filter(w, tw, &fx) || make_filter(h, th, &fy)) goto done;
  if (tw == w) memcpy(mid, src, (size_t)h * w * 3);
  else resize_pass(src, mid, &fx, h, tw, 3, (size_t)w * 3, 3, (size_t)tw * 3);
  if (th == h) memcpy(dst, mid, (size_t)h * tw * 3);
  else resize_pass(mid, dst, &fy, tw, th, (size_t)tw * 3, 3, (size_t)tw * 3, 3);
  rc = 0;
done:
  free(mid);
  free_filter(&fx);
  free_filter(&fy);
  return rc;
}

float *sig_preprocess(const unsigned char *rgb, int w, int h, int patch, int max_patches, int *n_h, int *n_w) {
  int th, tw;
  target_size(h, w, patch, max_patches, &th, &tw);
  unsigned char *img = malloc((size_t)th * tw * 3);
  float *out = malloc(sizeof(float) * (size_t)th * tw * 3);
  if (img == NULL || out == NULL || resize(rgb, w, h, img, tw, th)) {
    free(img);
    free(out);
    return NULL;
  }
  *n_h = th / patch;
  *n_w = tw / patch;
  /* Patch (ph, pw) is one row: its pixels in raster order, channels last. */
  size_t k = 0;
  for (int ph = 0; ph < *n_h; ph++)
    for (int pw = 0; pw < *n_w; pw++)
      for (int y = ph * patch; y < (ph + 1) * patch; y++)
        for (int x = pw * patch; x < (pw + 1) * patch; x++)
          for (int c = 0; c < 3; c++) out[k++] = (img[((size_t)y * tw + x) * 3 + c] / 255.0f - 0.5f) / 0.5f;
  free(img);
  return out;
}

/* --- Model ------------------------------------------------------------------- */

typedef struct {
  struct ggml_tensor *ln1_w, *ln1_b, *qkv_w, *qkv_b, *o_w, *o_b, *ln2_w, *ln2_b, *up_w, *up_b, *down_w, *down_b;
} block;

struct sig_model {
  /* Matrices ggml can repack for the CPU's int8 instructions live in
     ctx_repack (buffer type CPU_REPACK), the rest in ctx. */
  struct ggml_context *ctx, *ctx_repack;
  ggml_backend_buffer_t buf, buf_repack;
  int hidden, heads, layers, patch, native; /* native: the position grid's side */
  float eps, scale, bias;
  struct ggml_tensor *patch_w, *patch_b, *pos, *post_w, *post_b;
  struct ggml_tensor *probe, *hq_w, *hq_b, *hk_w, *hk_b, *hv_w, *hv_b, *ho_w, *ho_b, *hln_w, *hln_b, *hup_w, *hup_b,
      *hdown_w, *hdown_b;
  block *blocks;
};

int sig_dim(const sig_model *m) { return m->hidden; }
int sig_patch_size(const sig_model *m) { return m->patch; }
float sig_logit_scale(const sig_model *m) { return m->scale; }
float sig_logit_bias(const sig_model *m) { return m->bias; }

void sig_free(sig_model *m) {
  if (m == NULL) return;
  if (m->buf) ggml_backend_buffer_free(m->buf);
  if (m->buf_repack) ggml_backend_buffer_free(m->buf_repack);
  if (m->ctx) ggml_free(m->ctx);
  if (m->ctx_repack) ggml_free(m->ctx_repack);
  free(m->blocks);
  free(m);
}

/* ggml's CPU_REPACK buffer type, when this CPU has the int8 dot-product or
   matrix-multiply instructions its Q8_0 kernels use (an Apple M-series core,
   Graviton, Axion; not a Cortex-A72). Weights put in it are interleaved at
   load time, and their matrix products run 1.5x faster
   (study/siglip2_images.md). Both checks are Arm features known at compile
   time: an x86-64 build never repacks. */
static ggml_backend_buffer_type_t repack_buffer_type(void) {
  if (!ggml_cpu_has_dotprod() && !ggml_cpu_has_matmul_int8()) return NULL;
  ggml_backend_dev_t dev = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
  if (dev == NULL) return NULL;
  ggml_backend_dev_get_extra_bufts_t extra =
      (ggml_backend_dev_get_extra_bufts_t)ggml_backend_reg_get_proc_address(ggml_backend_dev_backend_reg(dev),
                                                                          "ggml_backend_dev_get_extra_bufts");
  for (ggml_backend_buffer_type_t *b = extra ? extra(dev) : NULL; b && *b; b++)
    if (strcmp(ggml_backend_buft_name(*b), "CPU_REPACK") == 0) return *b;
  return NULL;
}

/* ggml logs a debug line per repacked tensor; keep warnings and errors. */
static void quiet_log(enum ggml_log_level level, const char *text, void *user) {
  static enum ggml_log_level last = GGML_LOG_LEVEL_NONE;
  (void)user;
  if (level != GGML_LOG_LEVEL_CONT) last = level;
  if (last >= GGML_LOG_LEVEL_WARN) fputs(text, stderr);
}

static struct ggml_tensor *weight(const sig_model *m, const char *name) {
  struct ggml_tensor *t = ggml_get_tensor(m->ctx, name);
  return t ? t : ggml_get_tensor(m->ctx_repack, name);
}

/* Tensor shapes from the GGUF header, then each tensor's bytes read into its
   backend buffer (repacked on the way in, for CPU_REPACK). */
static int load_weights(sig_model *m, struct gguf_context *g, struct ggml_context *meta, const char *path) {
  int64_t n = gguf_get_n_tensors(g);
  ggml_backend_buffer_type_t repack = repack_buffer_type();
  struct ggml_init_params p = {ggml_tensor_overhead() * (size_t)(n + 1), NULL, true};
  m->ctx = ggml_init(p);
  m->ctx_repack = ggml_init(p);
  if (m->ctx == NULL || m->ctx_repack == NULL) return -1;
  int n_repack = 0;
  for (int64_t i = 0; i < n; i++) {
    struct ggml_tensor *t = ggml_get_tensor(meta, gguf_get_tensor_name(g, i));
    int packed = repack && t->type == GGML_TYPE_Q8_0 && ggml_n_dims(t) == 2 && t->ne[1] % 4 == 0;
    ggml_set_name(ggml_dup_tensor(packed ? m->ctx_repack : m->ctx, t), t->name);
    n_repack += packed;
  }
  m->buf = ggml_backend_alloc_ctx_tensors_from_buft(m->ctx, ggml_backend_cpu_buffer_type());
  if (m->buf == NULL) return -1;
  if (n_repack > 0 && (m->buf_repack = ggml_backend_alloc_ctx_tensors_from_buft(m->ctx_repack, repack)) == NULL) return -1;
  FILE *f = fopen(path, "rb");
  if (f == NULL) return -1;
  size_t base = gguf_get_data_offset(g), cap = 0;
  void *tmp = NULL;
  int rc = 0;
  for (int64_t i = 0; rc == 0 && i < n; i++) {
    struct ggml_tensor *t = weight(m, gguf_get_tensor_name(g, i));
    size_t size = ggml_nbytes(t);
    if (size > cap && (tmp = realloc(tmp, cap = size)) == NULL) rc = -1;
    else if (fseeko(f, (off_t)(base + gguf_get_tensor_offset(g, i)), SEEK_SET) != 0 || fread(tmp, 1, size, f) != size) rc = -1;
    else ggml_backend_tensor_set(t, tmp, 0, size);
  }
  free(tmp);
  fclose(f);
  return rc;
}

static int key_u32(struct gguf_context *g, const char *k, int *out) {
  int64_t i = gguf_find_key(g, k);
  if (i < 0) return -1;
  *out = (int)gguf_get_val_u32(g, i);
  return 0;
}

static int key_f32(struct gguf_context *g, const char *k, float *out) {
  int64_t i = gguf_find_key(g, k);
  if (i < 0) return -1;
  *out = gguf_get_val_f32(g, i);
  return 0;
}

sig_model *sig_load(const char *path, char *err, size_t errlen) {
  sig_model *m = calloc(1, sizeof *m);
  if (m == NULL) return NULL;
  ggml_log_set(quiet_log, NULL);
  struct ggml_context *meta = NULL;
  struct gguf_init_params p = {true, &meta};
  struct gguf_context *g = gguf_init_from_file(path, p);
  int ok = g != NULL;
  if (!ok) snprintf(err, errlen, "%s: not a readable GGUF file", path);
  if (ok && (key_u32(g, "siglip2.vision.embedding_length", &m->hidden) || key_u32(g, "siglip2.vision.attention.head_count", &m->heads)
             || key_u32(g, "siglip2.vision.block_count", &m->layers) || key_u32(g, "siglip2.vision.patch_size", &m->patch)
             || key_u32(g, "siglip2.vision.num_patches", &m->native) || key_f32(g, "siglip2.vision.layer_norm_eps", &m->eps)
             || key_f32(g, "siglip2.logit_scale", &m->scale) || key_f32(g, "siglip2.logit_bias", &m->bias))) {
    snprintf(err, errlen, "%s: missing siglip2 metadata", path);
    ok = 0;
  }
  if (ok && load_weights(m, g, meta, path)) {
    snprintf(err, errlen, "%s: cannot load the weights", path);
    ok = 0;
  }
  if (g) gguf_free(g);
  if (meta) ggml_free(meta);
  m->native = (int)lround(sqrt(m->native));
  struct {
    struct ggml_tensor **dst;
    const char *name;
  } fixed[] = {{&m->patch_w, "v.patch_embd.weight"}, {&m->patch_b, "v.patch_embd.bias"}, {&m->pos, "v.position_embd.weight"},
               {&m->post_w, "v.post_ln.weight"},    {&m->post_b, "v.post_ln.bias"},    {&m->probe, "v.head.probe"},
               {&m->hq_w, "v.head.attn_q.weight"},  {&m->hq_b, "v.head.attn_q.bias"}, {&m->hk_w, "v.head.attn_k.weight"},
               {&m->hk_b, "v.head.attn_k.bias"},    {&m->hv_w, "v.head.attn_v.weight"}, {&m->hv_b, "v.head.attn_v.bias"},
               {&m->ho_w, "v.head.attn_o.weight"},  {&m->ho_b, "v.head.attn_o.bias"}, {&m->hln_w, "v.head.ln.weight"},
               {&m->hln_b, "v.head.ln.bias"},       {&m->hup_w, "v.head.ffn_up.weight"}, {&m->hup_b, "v.head.ffn_up.bias"},
               {&m->hdown_w, "v.head.ffn_down.weight"}, {&m->hdown_b, "v.head.ffn_down.bias"}};
  for (size_t i = 0; ok && i < sizeof fixed / sizeof fixed[0]; i++)
    if ((*fixed[i].dst = weight(m, fixed[i].name)) == NULL) {
      snprintf(err, errlen, "%s: missing tensor %s", path, fixed[i].name);
      ok = 0;
    }
  static const char *suffix[] = {"ln1.weight",  "ln1.bias",  "attn_qkv.weight", "attn_qkv.bias", "attn_o.weight",  "attn_o.bias",
                                 "ln2.weight",  "ln2.bias",  "ffn_up.weight",   "ffn_up.bias",   "ffn_down.weight", "ffn_down.bias"};
  if (ok && (m->blocks = calloc(m->layers, sizeof(block))) == NULL) ok = 0;
  for (int l = 0; ok && l < m->layers; l++)
    for (int s = 0; ok && s < 12; s++) {
      char name[64];
      snprintf(name, sizeof name, "v.blk.%d.%s", l, suffix[s]);
      if ((((struct ggml_tensor **)&m->blocks[l])[s] = weight(m, name)) == NULL) {
        snprintf(err, errlen, "%s: missing tensor %s", path, name);
        ok = 0;
      }
    }
  if (!ok) {
    sig_free(m);
    return NULL;
  }
  return m;
}

/* --- Graph -------------------------------------------------------------------- */

static struct ggml_tensor *layer_norm(struct ggml_context *c, struct ggml_tensor *x, struct ggml_tensor *w,
                                      struct ggml_tensor *b, float eps) {
  return ggml_add(c, ggml_mul(c, ggml_norm(c, x, eps), w), b);
}

static struct ggml_tensor *linear(struct ggml_context *c, struct ggml_tensor *x, struct ggml_tensor *w, struct ggml_tensor *b) {
  return ggml_add(c, ggml_mul_mat(c, w, x), b);
}

/* Softmax attention; q, k, v are (d_head, n_head, n_pos). Returns (hidden, n_q). */
static struct ggml_tensor *attention(struct ggml_context *c, struct ggml_tensor *q, struct ggml_tensor *k,
                                     struct ggml_tensor *v, int d_head, int n_head, int n_q) {
  q = ggml_permute(c, q, 0, 2, 1, 3);
  k = ggml_permute(c, k, 0, 2, 1, 3);
  v = ggml_cont(c, ggml_permute(c, v, 1, 2, 0, 3));
  struct ggml_tensor *kq = ggml_soft_max_ext(c, ggml_mul_mat(c, k, q), NULL, 1.0f / sqrtf((float)d_head), 0.0f);
  struct ggml_tensor *kqv = ggml_permute(c, ggml_mul_mat(c, v, kq), 0, 2, 1, 3);
  return ggml_cont_2d(c, kqv, d_head * n_head, n_q);
}

static struct ggml_tensor *mlp(struct ggml_context *c, struct ggml_tensor *x, struct ggml_tensor *up_w,
                               struct ggml_tensor *up_b, struct ggml_tensor *down_w, struct ggml_tensor *down_b) {
  return linear(c, ggml_gelu(c, linear(c, x, up_w, up_b)), down_w, down_b);
}

static struct ggml_tensor *encoder_block(struct ggml_context *c, const sig_model *m, const block *b, struct ggml_tensor *x,
                                         int n_pos) {
  int h = m->hidden, d = h / m->heads;
  size_t es = sizeof(float);
  struct ggml_tensor *qkv = linear(c, layer_norm(c, x, b->ln1_w, b->ln1_b, m->eps), b->qkv_w, b->qkv_b);
  struct ggml_tensor *q = ggml_view_3d(c, qkv, d, m->heads, n_pos, d * es, 3 * h * es, 0);
  struct ggml_tensor *k = ggml_view_3d(c, qkv, d, m->heads, n_pos, d * es, 3 * h * es, h * es);
  struct ggml_tensor *v = ggml_view_3d(c, qkv, d, m->heads, n_pos, d * es, 3 * h * es, 2 * h * es);
  x = ggml_add(c, linear(c, attention(c, q, k, v, d, m->heads, n_pos), b->o_w, b->o_b), x);
  return ggml_add(c, mlp(c, layer_norm(c, x, b->ln2_w, b->ln2_b, m->eps), b->up_w, b->up_b, b->down_w, b->down_b), x);
}

/* Siglip2MultiheadAttentionPoolingHead: a learnt probe attends over the
   patches, then a residual MLP. */
static struct ggml_tensor *pooling_head(struct ggml_context *c, const sig_model *m, struct ggml_tensor *x, int n_pos) {
  int h = m->hidden, d = h / m->heads;
  struct ggml_tensor *q = ggml_reshape_3d(c, linear(c, ggml_reshape_2d(c, m->probe, h, 1), m->hq_w, m->hq_b), d, m->heads, 1);
  struct ggml_tensor *k = ggml_reshape_3d(c, linear(c, x, m->hk_w, m->hk_b), d, m->heads, n_pos);
  struct ggml_tensor *v = ggml_reshape_3d(c, linear(c, x, m->hv_w, m->hv_b), d, m->heads, n_pos);
  struct ggml_tensor *a = linear(c, attention(c, q, k, v, d, m->heads, 1), m->ho_w, m->ho_b);
  return ggml_add(c, a, mlp(c, layer_norm(c, a, m->hln_w, m->hln_b, m->eps), m->hup_w, m->hup_b, m->hdown_w, m->hdown_b));
}

int sig_encode(const sig_model *m, const float *pixels, int n_h, int n_w, int n_threads, float *out) {
  int h = m->hidden, n_pos = n_h * n_w, feat = 3 * m->patch * m->patch, rc = -1;
  size_t graph_size = 4096;
  struct ggml_init_params p = {ggml_tensor_overhead() * graph_size + ggml_graph_overhead_custom(graph_size, false), NULL, true};
  struct ggml_context *c = ggml_init(p);
  ggml_gallocr_t alloc = NULL;
  ggml_backend_t cpu = NULL;
  if (c == NULL) return -1;
  struct ggml_cgraph *gf = ggml_new_graph_custom(c, graph_size, false);
  struct ggml_tensor *inp = ggml_new_tensor_2d(c, GGML_TYPE_F32, feat, n_pos);
  ggml_set_input(inp);
  struct ggml_tensor *x = linear(c, inp, m->patch_w, m->patch_b);
  /* The native position grid, resized to this image's grid as Hugging Face
     does (bilinear, antialiased). */
  struct ggml_tensor *pos = m->pos;
  if (n_h != m->native || n_w != m->native) {
    pos = ggml_permute(c, ggml_reshape_3d(c, pos, h, m->native, m->native), 2, 0, 1, 3);
    pos = ggml_interpolate(c, pos, n_w, n_h, h, 1, GGML_SCALE_MODE_BILINEAR | GGML_SCALE_FLAG_ANTIALIAS);
    pos = ggml_cont_2d(c, ggml_permute(c, pos, 1, 2, 0, 3), h, n_pos);
  }
  x = ggml_add(c, x, pos);
  for (int l = 0; l < m->layers; l++) x = encoder_block(c, m, &m->blocks[l], x, n_pos);
  x = pooling_head(c, m, layer_norm(c, x, m->post_w, m->post_b, m->eps), n_pos);
  ggml_set_output(x);
  ggml_build_forward_expand(gf, x);
  alloc = ggml_gallocr_new(ggml_backend_cpu_buffer_type());
  cpu = ggml_backend_cpu_init();
  if (alloc == NULL || cpu == NULL || !ggml_gallocr_alloc_graph(alloc, gf)) goto done;
  memcpy(inp->data, pixels, sizeof(float) * (size_t)feat * n_pos);
  ggml_backend_cpu_set_n_threads(cpu, n_threads > 0 ? n_threads : 1);
  if (ggml_backend_graph_compute(cpu, gf) != GGML_STATUS_SUCCESS) goto done;
  const float *e = x->data;
  double norm = 0;
  for (int i = 0; i < h; i++) norm += (double)e[i] * e[i];
  norm = sqrt(norm);
  for (int i = 0; i < h; i++) out[i] = norm > 0 ? (float)(e[i] / norm) : 0.0f;
  rc = 0;
done:
  if (cpu) ggml_backend_free(cpu);
  if (alloc) ggml_gallocr_free(alloc);
  ggml_free(c);
  return rc;
}

int sig_embed_image(const sig_model *m, const unsigned char *bytes, size_t len, int max_patches, int min_side,
                    int n_threads, float *out) {
  int w, h, n_h, n_w;
  unsigned char *rgb = sig_decode(bytes, len, SIG_MAX_PIXELS, &w, &h);
  if (rgb == NULL) return -1;
  if (w < min_side || h < min_side) {
    free(rgb);
    return -3;
  }
  float *pixels = sig_preprocess(rgb, w, h, m->patch, max_patches, &n_h, &n_w);
  free(rgb);
  if (pixels == NULL) return -2;
  int rc = sig_encode(m, pixels, n_h, n_w, n_threads, out);
  free(pixels);
  return rc ? -2 : 0;
}
