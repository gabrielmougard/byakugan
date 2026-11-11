/* HTML5 parsing with lexbor (vendor/lexbor) for src/lib/html.ml.

   The page is parsed with the OCaml runtime released, the tree is walked
   once, and only a flat event buffer crosses back into OCaml:

     'o' name n (attr value)*   element start, n kept attributes
     'c'                        element end
     't' text                   text node
     's' n (attr value)* body   script element and its text

   Strings and counts are 32-bit little endian lengths; strings follow as
   bytes. Only the attributes the extractor reads are kept, style elements
   are dropped, and U+00A0 (no-break space, what &nbsp; decodes to) becomes
   a plain space in text and attribute values, so it separates words.

   <p id=x>a&nbsp;b</p>, inside the html, head and body events the parser
   adds around it, with [n] a 32-bit length or count:

     'o' [1]p [1] [2]id [1]x   't' [3]a b   'c' */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <lexbor/dom/interfaces/text.h>
#include <lexbor/html/html.h>

#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>

typedef struct {
  char *data;
  size_t len, cap;
  int failed;
} out_t;

static void put(out_t *o, const void *p, size_t n) {
  if (o->failed) return;
  if (o->len + n > o->cap) {
    size_t cap = o->cap ? o->cap : 1 << 16;
    while (cap < o->len + n) cap *= 2;
    char *data = realloc(o->data, cap);
    if (data == NULL) {
      o->failed = 1;
      return;
    }
    o->data = data;
    o->cap = cap;
  }
  memcpy(o->data + o->len, p, n);
  o->len += n;
}

static void put_u32(out_t *o, size_t v) {
  unsigned char b[4] = {v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff};
  put(o, b, 4);
}

static void put_str(out_t *o, const lxb_char_t *s, size_t n) {
  put_u32(o, n);
  put(o, s, n);
}

static void put_text(out_t *o, const lxb_char_t *s, size_t n) {
  size_t at = o->len, from = 0;
  put_u32(o, 0);
  for (size_t i = 0; i + 1 < n; i++)
    if (s[i] == 0xC2 && s[i + 1] == 0xA0) {
      put(o, s + from, i - from);
      put(o, " ", 1);
      from = ++i + 1;
    }
  put(o, s + from, n - from);
  if (o->failed) return;
  size_t len = o->len - at - 4;
  unsigned char b[4] = {len & 0xff, (len >> 8) & 0xff, (len >> 16) & 0xff, (len >> 24) & 0xff};
  memcpy(o->data + at, b, 4);
}

static const char *const kept[] = {"href",  "rel",    "type", "src",      "alt",     "title", "width",
                                   "height", "name", "property", "content", "lang", "id"};

static int is_kept(const lxb_char_t *name, size_t n) {
  for (size_t i = 0; i < sizeof kept / sizeof *kept; i++)
    if (strlen(kept[i]) == n && memcmp(kept[i], name, n) == 0) return 1;
  return 0;
}

static void put_attrs(out_t *o, lxb_dom_element_t *el) {
  size_t count = 0, n;
  for (lxb_dom_attr_t *a = lxb_dom_element_first_attribute(el); a; a = lxb_dom_element_next_attribute(a))
    if (is_kept(lxb_dom_attr_local_name(a, &n), n)) count++;
  put_u32(o, count);
  for (lxb_dom_attr_t *a = lxb_dom_element_first_attribute(el); a; a = lxb_dom_element_next_attribute(a)) {
    const lxb_char_t *name = lxb_dom_attr_local_name(a, &n);
    if (!is_kept(name, n)) continue;
    put_str(o, name, n);
    size_t vn;
    const lxb_char_t *v = lxb_dom_attr_value(a, &vn);
    put_text(o, v ? v : (const lxb_char_t *)"", v ? vn : 0);
  }
}

static void put_script(out_t *o, lxb_dom_node_t *node) {
  put(o, "s", 1);
  put_attrs(o, lxb_dom_interface_element(node));
  size_t total = 0;
  for (lxb_dom_node_t *c = node->first_child; c; c = c->next)
    if (c->type == LXB_DOM_NODE_TYPE_TEXT) total += lxb_dom_interface_text(c)->char_data.data.length;
  put_u32(o, total);
  for (lxb_dom_node_t *c = node->first_child; c; c = c->next)
    if (c->type == LXB_DOM_NODE_TYPE_TEXT) {
      lexbor_str_t *s = &lxb_dom_interface_text(c)->char_data.data;
      put(o, s->data, s->length);
    }
}

/* Depth first without recursion: crawled pages can nest arbitrarily deep. */
static void flatten(lxb_dom_node_t *root, out_t *o) {
  lxb_dom_node_t *n = root->first_child;
  while (n != NULL) {
    if (n->type == LXB_DOM_NODE_TYPE_ELEMENT && n->local_name == LXB_TAG_SCRIPT) {
      put_script(o, n);
    } else if (n->type == LXB_DOM_NODE_TYPE_ELEMENT && n->local_name != LXB_TAG_STYLE) {
      size_t len;
      const lxb_char_t *name = lxb_dom_element_local_name(lxb_dom_interface_element(n), &len);
      put(o, "o", 1);
      put_str(o, name, len);
      put_attrs(o, lxb_dom_interface_element(n));
      if (n->first_child != NULL) {
        n = n->first_child;
        continue;
      }
      put(o, "c", 1);
    } else if (n->type == LXB_DOM_NODE_TYPE_TEXT) {
      lexbor_str_t *s = &lxb_dom_interface_text(n)->char_data.data;
      put(o, "t", 1);
      put_text(o, s->data, s->length);
    }
    while (n->next == NULL) {
      n = n->parent;
      if (n == root) return;
      put(o, "c", 1);
    }
    n = n->next;
  }
}

value ctx_lexbor_flatten(value html) {
  CAMLparam1(html);
  CAMLlocal1(result);
  size_t n = caml_string_length(html);
  lxb_char_t *page = malloc(n + 1);
  if (page == NULL) caml_raise_out_of_memory();
  memcpy(page, String_val(html), n);
  out_t o = {NULL, 0, 0, 0};

  caml_enter_blocking_section();
  lxb_html_document_t *doc = lxb_html_document_create();
  /* As a browser with JavaScript on: <noscript> content stays raw text, so a
     tracking pixel in a <noscript> in <head> is not moved into the body. */
  if (doc != NULL) lxb_html_document_scripting_set(doc, true);
  int parsed = doc != NULL && lxb_html_document_parse(doc, page, n) == LXB_STATUS_OK;
  if (parsed) flatten(lxb_dom_interface_node(doc), &o);
  if (doc != NULL) lxb_html_document_destroy(doc);
  free(page);
  caml_leave_blocking_section();

  if (!parsed || o.failed) {
    free(o.data);
    caml_failwith("lexbor: cannot parse");
  }
  result = caml_alloc_initialized_string(o.len, o.data);
  free(o.data);
  CAMLreturn(result);
}
