/* One-shot zstd for the lab's stored profiles (src/lib/zstd.ml). */

#include <stdlib.h>
#include <zstd.h>
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

value ctx_zstd_compress(value src) {
  CAMLparam1(src);
  CAMLlocal1(out);
  size_t n = caml_string_length(src);
  size_t cap = ZSTD_compressBound(n);
  char *buf = malloc(cap);
  if (buf == NULL) caml_raise_out_of_memory();
  size_t r = ZSTD_compress(buf, cap, String_val(src), n, 3);
  if (ZSTD_isError(r)) {
    free(buf);
    caml_failwith(ZSTD_getErrorName(r));
  }
  out = caml_alloc_initialized_string(r, buf);
  free(buf);
  CAMLreturn(out);
}

value ctx_zstd_decompress(value src) {
  CAMLparam1(src);
  CAMLlocal1(out);
  size_t n = caml_string_length(src);
  unsigned long long size = ZSTD_getFrameContentSize(String_val(src), n);
  if (size == ZSTD_CONTENTSIZE_ERROR || size == ZSTD_CONTENTSIZE_UNKNOWN || size > Bsize_wsize(Max_wosize))
    caml_failwith("zstd: not a single frame of known size");
  out = caml_alloc_string(size);
  size_t r = ZSTD_decompress(Bytes_val(out), size, String_val(src), n);
  if (ZSTD_isError(r) || r != size) caml_failwith("zstd: corrupt frame");
  CAMLreturn(out);
}
