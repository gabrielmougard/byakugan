/* OCaml bindings for warc_ffi (FastWARC behind a C ABI), for src/lib/warc.ml.
   Calls release the runtime lock: compressing or reading a record never
   blocks the other domains. */
#include <string.h>
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

typedef struct {
  unsigned char *uri; size_t uri_len;
  unsigned char *date; size_t date_len;
  int status;
  unsigned char *content_type; size_t content_type_len;
  unsigned char *headers; size_t headers_len;
  unsigned char *body; size_t body_len;
} ctx_record;

extern void ctx_warc_free(unsigned char *, size_t);
extern void ctx_warc_record_free(ctx_record *);
extern int ctx_warc_response(const unsigned char *, size_t, const unsigned char *, size_t, const unsigned char *,
                             size_t, unsigned char **, size_t *);
extern int ctx_warc_read(const unsigned char *, size_t, ctx_record *);
extern void *ctx_warc_open(const unsigned char *, size_t);
extern int ctx_warc_next(void *, ctx_record *);
extern void ctx_warc_close(void *);

/* A copy of an OCaml string the C side may read with the lock released. */
static unsigned char *dup(value s, size_t *n) {
  *n = caml_string_length(s);
  unsigned char *p = malloc(*n ? *n : 1);
  if (!p) caml_raise_out_of_memory();
  memcpy(p, String_val(s), *n);
  return p;
}

static value string_of(const unsigned char *p, size_t n) {
  value s = caml_alloc_string(n);
  if (n) memcpy(Bytes_val(s), p, n);
  return s;
}

/* { uri; date; status; content_type; headers; body } */
static value record_of(ctx_record *r) {
  CAMLparam0();
  CAMLlocal1(v);
  v = caml_alloc_tuple(6);
  Store_field(v, 0, string_of(r->uri, r->uri_len));
  Store_field(v, 1, string_of(r->date, r->date_len));
  Store_field(v, 2, Val_int(r->status));
  Store_field(v, 3, string_of(r->content_type, r->content_type_len));
  Store_field(v, 4, string_of(r->headers, r->headers_len));
  Store_field(v, 5, string_of(r->body, r->body_len));
  CAMLreturn(v);
}

CAMLprim value ctx_warc_response_ml(value uri, value date, value http) {
  CAMLparam3(uri, date, http);
  CAMLlocal1(res);
  size_t nu, nd, nh, n = 0;
  unsigned char *u = dup(uri, &nu), *d = dup(date, &nd), *h = dup(http, &nh), *out = NULL;
  caml_release_runtime_system();
  int rc = ctx_warc_response(u, nu, d, nd, h, nh, &out, &n);
  caml_acquire_runtime_system();
  free(u); free(d); free(h);
  if (rc != 0) caml_failwith("Warc.response");
  res = string_of(out, n);
  ctx_warc_free(out, n);
  CAMLreturn(res);
}

CAMLprim value ctx_warc_read_ml(value buf) {
  CAMLparam1(buf);
  CAMLlocal2(res, some);
  size_t n;
  unsigned char *b = dup(buf, &n);
  ctx_record r = {0};
  caml_release_runtime_system();
  int rc = ctx_warc_read(b, n, &r);
  caml_acquire_runtime_system();
  free(b);
  if (rc != 0) CAMLreturn(Val_none);
  res = record_of(&r);
  ctx_warc_record_free(&r);
  some = caml_alloc_some(res);
  CAMLreturn(some);
}

#define Reader_val(v) (*((void **)Data_custom_val(v)))

static void finalize_reader(value v) {
  if (Reader_val(v)) ctx_warc_close(Reader_val(v));
  Reader_val(v) = NULL;
}

static struct custom_operations reader_ops = {
  "contextual.warc.reader", finalize_reader, custom_compare_default, custom_hash_default,
  custom_serialize_default, custom_deserialize_default, custom_compare_ext_default, custom_fixed_length_default};

CAMLprim value ctx_warc_open_ml(value path) {
  CAMLparam1(path);
  CAMLlocal1(v);
  void *r = ctx_warc_open((const unsigned char *)String_val(path), caml_string_length(path));
  if (!r) caml_failwith("Warc.open_in: cannot open the file");
  v = caml_alloc_custom(&reader_ops, sizeof(void *), 0, 1);
  Reader_val(v) = r;
  CAMLreturn(v);
}

CAMLprim value ctx_warc_next_ml(value reader) {
  CAMLparam1(reader);
  CAMLlocal2(res, some);
  void *r = Reader_val(reader);
  if (!r) CAMLreturn(Val_none);
  ctx_record rec = {0};
  caml_release_runtime_system();
  int rc = ctx_warc_next(r, &rec);
  caml_acquire_runtime_system();
  if (rc < 0) caml_failwith("Warc.next: malformed record");
  if (rc == 0) CAMLreturn(Val_none);
  res = record_of(&rec);
  ctx_warc_record_free(&rec);
  some = caml_alloc_some(res);
  CAMLreturn(some);
}

CAMLprim value ctx_warc_close_ml(value reader) {
  CAMLparam1(reader);
  finalize_reader(reader);
  CAMLreturn(Val_unit);
}
