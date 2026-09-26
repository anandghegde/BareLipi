/* math.c — inline TeX math extension for BareLipi.
 *
 * Pandoc's `tex_math_dollars` rules:
 *   - `$…$` is inline math. The opening `$` must be followed by a non-space
 *     character; the closing `$` must be preceded by a non-space character and
 *     must not be followed by a digit.
 *   - `$$…$$` is display math with no such restrictions.
 *   - A backslash-escaped `$` never opens or closes math.
 * The node keeps the raw TeX in an opaque payload; renderers wrap it.
 */
#include "lipi_math.h"
#include "lipi_cmark.h"

#include <cmark-gfm-extension_api.h>
#include <html.h>
#include <houdini.h>
#include <inlines.h>
#include <node.h>
#include <parser.h>
#include <render.h>
#include <string.h>

cmark_node_type CMARK_NODE_MATH;

typedef struct {
  cmark_chunk text;
  int display;
} lipi_math_payload;

static int is_ws(unsigned char c) {
  return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' ||
         c == '\v';
}

static int is_digit(unsigned char c) { return c >= '0' && c <= '9'; }

static cmark_node *match(cmark_syntax_extension *self, cmark_parser *parser,
                         cmark_node *parent, unsigned char character,
                         cmark_inline_parser *inline_parser) {
  cmark_chunk *chunk;
  const unsigned char *d;
  int len, pos, open, close = -1, end, i, display, column;
  cmark_node *node;
  lipi_math_payload *payload;

  if (character != '$')
    return NULL;

  chunk = cmark_inline_parser_get_chunk(inline_parser);
  d = chunk->data;
  len = chunk->len;
  pos = cmark_inline_parser_get_offset(inline_parser);

  display = pos + 1 < len && d[pos + 1] == '$';
  open = pos + (display ? 2 : 1);

  if (display) {
    for (i = open; i + 1 < len; i++) {
      if (d[i] == '\\') {
        i++;
        continue;
      }
      if (d[i] == '$' && d[i + 1] == '$') {
        close = i;
        break;
      }
    }
    if (close < 0)
      return NULL;
    end = close + 2;
  } else {
    if (open >= len || is_ws(d[open]) || d[open] == '$')
      return NULL;
    for (i = open; i < len; i++) {
      if (d[i] == '\\') {
        i++;
        continue;
      }
      if (d[i] == '$' && !is_ws(d[i - 1]) &&
          (i + 1 >= len || !is_digit(d[i + 1]))) {
        close = i;
        break;
      }
    }
    if (close < 0 || close == open)
      return NULL;
    end = close + 1;
  }

  node = cmark_node_new_with_mem(CMARK_NODE_MATH, parser->mem);
  cmark_node_set_syntax_extension(node, self);

  payload = (lipi_math_payload *)parser->mem->calloc(1, sizeof(*payload));
  payload->text = cmark_chunk_dup(chunk, open, close - open);
  cmark_chunk_to_cstr(parser->mem, &payload->text);
  payload->display = display;
  node->as.opaque = payload;

  column = cmark_inline_parser_get_column(inline_parser);
  node->start_line = node->end_line =
      cmark_inline_parser_get_line(inline_parser);
  node->start_column = column;
  node->end_column = column + (end - pos) - 1;
  node->lipi_start = pos;
  node->lipi_end = end;

  cmark_inline_parser_set_offset(inline_parser, end);
  return node;
}

static void opaque_free(cmark_syntax_extension *self, cmark_mem *mem,
                        cmark_node *node) {
  lipi_math_payload *payload = (lipi_math_payload *)node->as.opaque;
  if (payload) {
    cmark_chunk_free(mem, &payload->text);
    mem->free(payload);
    node->as.opaque = NULL;
  }
}

static const char *get_type_string(cmark_syntax_extension *extension,
                                   cmark_node *node) {
  return node->type == CMARK_NODE_MATH ? "math" : "<unknown>";
}

static int can_contain(cmark_syntax_extension *extension, cmark_node *node,
                       cmark_node_type child_type) {
  return 0;
}

static void html_render(cmark_syntax_extension *extension,
                        cmark_html_renderer *renderer, cmark_node *node,
                        cmark_event_type ev_type, int options) {
  lipi_math_payload *payload = (lipi_math_payload *)node->as.opaque;
  if (ev_type != CMARK_EVENT_ENTER || payload == NULL)
    return;
  if (payload->display) {
    cmark_strbuf_puts(renderer->html, "<span class=\"math display\">\\[");
    houdini_escape_html0(renderer->html, payload->text.data,
                         payload->text.len, 0);
    cmark_strbuf_puts(renderer->html, "\\]</span>");
  } else {
    cmark_strbuf_puts(renderer->html, "<span class=\"math inline\">\\(");
    houdini_escape_html0(renderer->html, payload->text.data,
                         payload->text.len, 0);
    cmark_strbuf_puts(renderer->html, "\\)</span>");
  }
}

static void commonmark_render(cmark_syntax_extension *extension,
                              cmark_renderer *renderer, cmark_node *node,
                              cmark_event_type ev_type, int options) {
  lipi_math_payload *payload = (lipi_math_payload *)node->as.opaque;
  const char *delim;
  if (ev_type != CMARK_EVENT_ENTER || payload == NULL)
    return;
  delim = payload->display ? "$$" : "$";
  renderer->out(renderer, node, delim, false, LITERAL);
  renderer->out(renderer, node, (const char *)payload->text.data, false,
                LITERAL);
  renderer->out(renderer, node, delim, false, LITERAL);
}

static void plaintext_render(cmark_syntax_extension *extension,
                             cmark_renderer *renderer, cmark_node *node,
                             cmark_event_type ev_type, int options) {
  lipi_math_payload *payload = (lipi_math_payload *)node->as.opaque;
  if (ev_type != CMARK_EVENT_ENTER || payload == NULL)
    return;
  renderer->out(renderer, node, (const char *)payload->text.data, false,
                LITERAL);
}

static void latex_render(cmark_syntax_extension *extension,
                         cmark_renderer *renderer, cmark_node *node,
                         cmark_event_type ev_type, int options) {
  lipi_math_payload *payload = (lipi_math_payload *)node->as.opaque;
  if (ev_type != CMARK_EVENT_ENTER || payload == NULL)
    return;
  renderer->out(renderer, node, payload->display ? "\\[" : "$", false,
                LITERAL);
  renderer->out(renderer, node, (const char *)payload->text.data, false,
                LITERAL);
  renderer->out(renderer, node, payload->display ? "\\]" : "$", false,
                LITERAL);
}

int lipi_math_get(cmark_node *node, const char **text, int *len,
                  int *display) {
  lipi_math_payload *payload;
  if (node == NULL || node->type != CMARK_NODE_MATH)
    return 0;
  payload = (lipi_math_payload *)node->as.opaque;
  if (payload == NULL)
    return 0;
  *text = (const char *)payload->text.data;
  *len = payload->text.len;
  *display = payload->display;
  return 1;
}

cmark_syntax_extension *create_math_extension(void) {
  cmark_syntax_extension *ext = cmark_syntax_extension_new("math");
  cmark_llist *special_chars = NULL;
  cmark_mem *mem = cmark_get_default_mem_allocator();

  cmark_syntax_extension_set_get_type_string_func(ext, get_type_string);
  cmark_syntax_extension_set_can_contain_func(ext, can_contain);
  cmark_syntax_extension_set_commonmark_render_func(ext, commonmark_render);
  cmark_syntax_extension_set_plaintext_render_func(ext, plaintext_render);
  cmark_syntax_extension_set_latex_render_func(ext, latex_render);
  cmark_syntax_extension_set_man_render_func(ext, plaintext_render);
  cmark_syntax_extension_set_html_render_func(ext, html_render);
  cmark_syntax_extension_set_opaque_free_func(ext, opaque_free);
  CMARK_NODE_MATH = cmark_syntax_extension_add_node(1);

  cmark_syntax_extension_set_match_inline_func(ext, match);

  special_chars = cmark_llist_append(mem, special_chars, (void *)'$');
  cmark_syntax_extension_set_special_inline_chars(ext, special_chars);

  return ext;
}
