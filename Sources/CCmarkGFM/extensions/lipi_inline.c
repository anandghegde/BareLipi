/* lipi_inline.c — opt-in inline extensions for BareLipi (PATCHES.md §7).
 *
 *   superscript  `^x^`   Pandoc rules: a single `^` on each side, the
 *                        content is not empty and holds no unescaped
 *                        whitespace (`\ ` is allowed).
 *   highlight    `==x==` exactly two `=` on each side, flanking like `~~`.
 *
 * Subscript `~x~` shares its delimiter with strikethrough, so it lives in
 * extensions/strikethrough.c behind LIPI_OPT_SUBSCRIPT; the scanning rule is
 * `lipi_script_can_open` below.
 */
#include "lipi_inline.h"
#include "lipi_cmark.h"

#include <cmark-gfm-extension_api.h>
#include <inlines.h>
#include <node.h>
#include <parser.h>
#include <render.h>
#include <string.h>

cmark_node_type CMARK_NODE_SUPERSCRIPT;
cmark_node_type CMARK_NODE_HIGHLIGHT;

static int is_ws(unsigned char c) {
  return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' ||
         c == '\v';
}

int lipi_script_can_open(const unsigned char *d, int len, int pos,
                         unsigned char ch) {
  int i;
  if (pos + 1 >= len || is_ws(d[pos + 1]) || d[pos + 1] == ch)
    return 0;
  for (i = pos + 1; i < len; i++) {
    unsigned char c = d[i];
    if (c == '\\' && i + 1 < len) {
      i++;
      continue;
    }
    if (is_ws(c))
      return 0;
    if (c == ch)
      return i + 1 >= len || d[i + 1] != ch;
  }
  return 0;
}

int lipi_script_can_close(const unsigned char *d, int len, int pos,
                          unsigned char ch) {
  (void)len;
  (void)ch;
  return pos > 0 && !is_ws(d[pos - 1]);
}

/* A text node over `d[pos, pos + run)`, with source positions. */
static cmark_node *delimiter_text(cmark_parser *parser,
                                  cmark_inline_parser *inline_parser,
                                  cmark_chunk *chunk, int pos, int run) {
  cmark_node *res = cmark_node_new_with_mem(CMARK_NODE_TEXT, parser->mem);
  int column = cmark_inline_parser_get_column(inline_parser);
  res->as.literal = cmark_chunk_dup(chunk, pos, run);
  res->start_line = res->end_line = cmark_inline_parser_get_line(inline_parser);
  res->start_column = column;
  res->end_column = column + run - 1;
  res->lipi_start = pos;
  res->lipi_end = pos + run;
  cmark_inline_parser_set_offset(inline_parser, pos + run);
  return res;
}

static cmark_node *superscript_match(cmark_syntax_extension *self,
                                     cmark_parser *parser, cmark_node *parent,
                                     unsigned char character,
                                     cmark_inline_parser *inline_parser) {
  cmark_chunk *chunk;
  const unsigned char *d;
  int len, pos, run, can_open, can_close;
  cmark_node *res;

  if (character != '^')
    return NULL;
  chunk = cmark_inline_parser_get_chunk(inline_parser);
  d = chunk->data;
  len = chunk->len;
  pos = cmark_inline_parser_get_offset(inline_parser);
  /* `[^label]` is a footnote reference; its text must stay one node. */
  if (pos > 0 && d[pos - 1] == '[')
    return NULL;
  run = 1;
  while (pos + run < len && d[pos + run] == '^')
    run++;
  res = delimiter_text(parser, inline_parser, chunk, pos, run);
  if (run != 1)
    return res;
  can_open = lipi_script_can_open(d, len, pos, '^');
  can_close = lipi_script_can_close(d, len, pos, '^');
  if (can_open || can_close)
    cmark_inline_parser_push_delimiter(inline_parser, '^', can_open,
                                       can_close, res);
  return res;
}

static cmark_node *highlight_match(cmark_syntax_extension *self,
                                   cmark_parser *parser, cmark_node *parent,
                                   unsigned char character,
                                   cmark_inline_parser *inline_parser) {
  int left_flanking, right_flanking, punct_before, punct_after, delims, end;
  cmark_node *res;

  if (character != '=')
    return NULL;
  delims = cmark_inline_parser_scan_delimiters(
      inline_parser, 100, '=', &left_flanking, &right_flanking, &punct_before,
      &punct_after);
  end = cmark_inline_parser_get_offset(inline_parser);
  cmark_inline_parser_set_offset(inline_parser, end - delims);
  res = delimiter_text(parser, inline_parser,
                       cmark_inline_parser_get_chunk(inline_parser),
                       end - delims, delims);
  if ((left_flanking || right_flanking) && delims == 2)
    cmark_inline_parser_push_delimiter(inline_parser, '=', left_flanking,
                                       right_flanking, res);
  return res;
}

delimiter *lipi_insert_span(cmark_syntax_extension *self,
                            cmark_inline_parser *inline_parser,
                            delimiter *opener, delimiter *closer,
                            cmark_node_type type) {
  cmark_node *span = opener->inl_text;
  cmark_node *tmp, *next;
  delimiter *delim, *tmp_delim;
  delimiter *res = closer->next;

  if (opener->inl_text->as.literal.len != closer->inl_text->as.literal.len)
    goto done;
  if (!cmark_node_set_type(span, type))
    goto done;
  cmark_node_set_syntax_extension(span, self);

  tmp = cmark_node_next(opener->inl_text);
  while (tmp) {
    if (tmp == closer->inl_text)
      break;
    next = cmark_node_next(tmp);
    cmark_node_append_child(span, tmp);
    tmp = next;
  }
  span->end_column = closer->inl_text->start_column +
                     closer->inl_text->as.literal.len - 1;
  span->lipi_end = closer->inl_text->lipi_end;
  cmark_node_free(closer->inl_text);

done:
  delim = closer;
  while (delim != NULL && delim != opener) {
    tmp_delim = delim->previous;
    cmark_inline_parser_remove_delimiter(inline_parser, delim);
    delim = tmp_delim;
  }
  cmark_inline_parser_remove_delimiter(inline_parser, opener);
  return res;
}

static delimiter *superscript_insert(cmark_syntax_extension *self,
                                     cmark_parser *parser,
                                     cmark_inline_parser *inline_parser,
                                     delimiter *opener, delimiter *closer) {
  return lipi_insert_span(self, inline_parser, opener, closer,
                          CMARK_NODE_SUPERSCRIPT);
}

static delimiter *highlight_insert(cmark_syntax_extension *self,
                                   cmark_parser *parser,
                                   cmark_inline_parser *inline_parser,
                                   delimiter *opener, delimiter *closer) {
  return lipi_insert_span(self, inline_parser, opener, closer,
                          CMARK_NODE_HIGHLIGHT);
}

static const char *get_type_string(cmark_syntax_extension *extension,
                                   cmark_node *node) {
  if (node->type == CMARK_NODE_SUPERSCRIPT)
    return "superscript";
  if (node->type == CMARK_NODE_HIGHLIGHT)
    return "highlight";
  return "<unknown>";
}

static int can_contain(cmark_syntax_extension *extension, cmark_node *node,
                       cmark_node_type child_type) {
  if (node->type != CMARK_NODE_SUPERSCRIPT &&
      node->type != CMARK_NODE_HIGHLIGHT)
    return false;
  return CMARK_NODE_TYPE_INLINE_P(child_type);
}

static void commonmark_render(cmark_syntax_extension *extension,
                              cmark_renderer *renderer, cmark_node *node,
                              cmark_event_type ev_type, int options) {
  renderer->out(renderer, node,
                node->type == CMARK_NODE_HIGHLIGHT ? "==" : "^", false,
                LITERAL);
}

static void plaintext_render(cmark_syntax_extension *extension,
                             cmark_renderer *renderer, cmark_node *node,
                             cmark_event_type ev_type, int options) {}

static void html_render(cmark_syntax_extension *extension,
                        cmark_html_renderer *renderer, cmark_node *node,
                        cmark_event_type ev_type, int options) {
  int entering = ev_type == CMARK_EVENT_ENTER;
  const char *tag = node->type == CMARK_NODE_HIGHLIGHT ? "mark" : "sup";
  cmark_strbuf_puts(renderer->html, entering ? "<" : "</");
  cmark_strbuf_puts(renderer->html, tag);
  cmark_strbuf_putc(renderer->html, '>');
}

static cmark_syntax_extension *make(const char *name, unsigned char c,
                                    cmark_match_inline_func match,
                                    cmark_inline_from_delim_func insert,
                                    cmark_node_type *type) {
  cmark_syntax_extension *ext = cmark_syntax_extension_new(name);
  cmark_mem *mem = cmark_get_default_mem_allocator();
  cmark_llist *special_chars = NULL;

  cmark_syntax_extension_set_get_type_string_func(ext, get_type_string);
  cmark_syntax_extension_set_can_contain_func(ext, can_contain);
  cmark_syntax_extension_set_commonmark_render_func(ext, commonmark_render);
  cmark_syntax_extension_set_plaintext_render_func(ext, plaintext_render);
  cmark_syntax_extension_set_latex_render_func(ext, plaintext_render);
  cmark_syntax_extension_set_man_render_func(ext, plaintext_render);
  cmark_syntax_extension_set_html_render_func(ext, html_render);
  *type = cmark_syntax_extension_add_node(1);
  cmark_syntax_extension_set_match_inline_func(ext, match);
  cmark_syntax_extension_set_inline_from_delim_func(ext, insert);
  special_chars = cmark_llist_append(mem, special_chars, (void *)(size_t)c);
  cmark_syntax_extension_set_special_inline_chars(ext, special_chars);
  cmark_syntax_extension_set_emphasis(ext, 1);
  return ext;
}

cmark_syntax_extension *create_superscript_extension(void) {
  return make("superscript", '^', superscript_match, superscript_insert,
              &CMARK_NODE_SUPERSCRIPT);
}

cmark_syntax_extension *create_highlight_extension(void) {
  return make("highlight", '=', highlight_match, highlight_insert,
              &CMARK_NODE_HIGHLIGHT);
}
