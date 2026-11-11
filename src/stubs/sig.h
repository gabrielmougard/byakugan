/* SigLIP 2 image embeddings in C on ggml: the vision tower of
   google/siglip2-base-patch16-naflex, from a GGUF written by src/siggguf.
   The graph follows hbd-siglip2.cpp (MIT, github.com/dbrain/hbd-siglip2.cpp),
   CPU only. Images are decoded with libjpeg-turbo, libpng and libwebp, which
   are hardened against hostile files; web images are untrusted input. */
#ifndef SIG_H
#define SIG_H

#include <stddef.h>

typedef struct sig_model sig_model;

/* NULL on failure, with a message in err. */
sig_model *sig_load(const char *gguf_path, char *err, size_t errlen);
void sig_free(sig_model *m);
int sig_dim(const sig_model *m);
int sig_patch_size(const sig_model *m);
/* logit = exp(scale) * cos(image, text) + bias, then a sigmoid. */
float sig_logit_scale(const sig_model *m);
float sig_logit_bias(const sig_model *m);

/* The largest image decoded: 16 megapixels, 48 MB of RGB. Twelve at once
   (4 workers x 3 images) stay well inside a crawler pod's 1 GiB. */
#define SIG_MAX_PIXELS 16000000L

/* JPEG, PNG or WebP bytes to RGB. NULL if undecodable or larger than
   max_pixels; free() the result. */
unsigned char *sig_decode(const unsigned char *bytes, size_t len, long max_pixels, int *width, int *height);

/* NaFlex preprocessing, as Hugging Face's Siglip2ImageProcessorFast: the
   largest size with at most max_patches patches keeping the aspect ratio,
   antialiased bilinear resize, (x / 255 - 0.5) / 0.5, patches of p x p x 3.
   Returns the pixel values (n_h * n_w rows of 3 * p * p floats; free() them). */
float *sig_preprocess(const unsigned char *rgb, int width, int height, int patch_size, int max_patches, int *n_h,
                      int *n_w);

/* The pooled image embedding, L2-normalised, into out (sig_dim floats).
   0 on success. Safe to call from several threads at once. */
int sig_encode(const sig_model *m, const float *pixels, int n_h, int n_w, int n_threads, float *out);

/* sig_decode + sig_preprocess + sig_encode. 0 on success, -1 if the image
   cannot be decoded, -2 if the model fails, -3 if it is narrower or shorter
   than min_side pixels (logos, icons, badges: not what a page is about). */
int sig_embed_image(const sig_model *m, const unsigned char *bytes, size_t len, int max_patches, int min_side,
                    int n_threads, float *out);

#endif
