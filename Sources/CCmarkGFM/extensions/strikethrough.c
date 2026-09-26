#include "strikethrough.h"
#include "lipi_cmark.h"
#include "lipi_inline.h"
#include <parser.h>
#include <render.h>

cmark_node_type CMARK_NODE_STRIKETHROUGH;
/* lipi: `~x~` subscript under LIPI_OPT_SUBSCRIPT (PATCHES.md §7). */
cmark_node_type CMARK_NODE_SUBSCRIPT;

static cmark_node *match(cmark_syntax_extension *self, cmark_parser *parser,
                         cmark_node *parent, unsigned char character,
                         cmark_inline_parser *inline_parser) {
  cmark_node *res = NULL;
  int left_flanking, right_flanking, punct_before, punct_after, delims;
  char buffer[101];

  if (character != '~')
    return NULL;

  delims = cmark_inline_parser_scan_delimiters(
      inline_parser, sizeof(buffer) - 1, '~',
      &left_flanking,
      &right_flanking, &punct_before, &punct_after);

  memset(buffer, '~', delims);
  buffer[delims] = 0;

  res = cmark_node_new_with_mem(CMARK_NODE_TEXT, parser->mem);
  cmark_node_set_literal(res, buffer);
  res->start_line = res->end_line = cmark_inline_parser_get_line(inline_parser);
  res->start_column = cmark_inline_parser_get_column(inline_parser) - delims;
  res->lipi_end = cmark_inline_parser_get_offset(inline_parser);
  res->lipi_start = res->lipi_end - delims;

  if ((parser->options & LIPI_OPT_SUBSCRIPT) && delims == 1) {
    /* lipi: Pandoc subscript; `~~` stays strikethrough. */
    cmark_chunk *chunk = cmark_inline_parser_get_chunk(inline_parser);
    int pos = res->lipi_start;
    int can_open = lipi_script_can_open(chunk->data, chunk->len, pos, '~');
    int can_close = lipi_script_can_close(chunk->data, chunk->len, pos, '~');
    if (can_open || can_close)
      cmark_inline_parser_push_delimiter(inline_parser, character, can_open,
                                         can_close, res);
  } else if ((left_flanking || right_flanking) &&
      (delims == 2 || (!(parser->options & CMARK_OPT_STRIKETHROUGH_DOUBLE_TILDE) && delims == 1))) {
    cmark_inline_parser_push_delimiter(inline_parser, character, left_flanking,
                                       right_flanking, res);
  }

  return res;
}

static delimiter *insert(cmark_syntax_extension *self, cmark_parser *parser,
                         cmark_inline_parser *inline_parser, delimiter *opener,
                         delimiter *closer) {
  cmark_node *strikethrough;
  cmark_node *tmp, *next;
  delimiter *delim, *tmp_delim;
  delimiter *res = closer->next;

  if ((parser->options & LIPI_OPT_SUBSCRIPT) &&
      opener->inl_text->as.literal.len == 1)
    return lipi_insert_span(self, inline_parser, opener, closer,
                            CMARK_NODE_SUBSCRIPT);

  strikethrough = opener->inl_text;

  if (opener->inl_text->as.literal.len != closer->inl_text->as.literal.len)
    goto done;

  if (!cmark_node_set_type(strikethrough, CMARK_NODE_STRIKETHROUGH))
    goto done;

  cmark_node_set_syntax_extension(strikethrough, self);

  tmp = cmark_node_next(opener->inl_text);

  while (tmp) {
    if (tmp == closer->inl_text)
      break;
    next = cmark_node_next(tmp);
    cmark_node_append_child(strikethrough, tmp);
    tmp = next;
  }

  strikethrough->end_column = closer->inl_text->start_column + closer->inl_text->as.literal.len - 1;
  strikethrough->lipi_end = closer->inl_text->lipi_end;
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

static const char *get_type_string(cmark_syntax_extension *extension,
                                   cmark_node *node) {
  if (node->type == CMARK_NODE_SUBSCRIPT)
    return "subscript";
  return node->type == CMARK_NODE_STRIKETHROUGH ? "strikethrough" : "<unknown>";
}

static int can_contain(cmark_syntax_extension *extension, cmark_node *node,
                       cmark_node_type child_type) {
  if (node->type != CMARK_NODE_STRIKETHROUGH &&
      node->type != CMARK_NODE_SUBSCRIPT)
    return false;

  return CMARK_NODE_TYPE_INLINE_P(child_type);
}

static void commonmark_render(cmark_syntax_extension *extension,
                              cmark_renderer *renderer, cmark_node *node,
                              cmark_event_type ev_type, int options) {
  renderer->out(renderer, node,
                node->type == CMARK_NODE_SUBSCRIPT ? "~" : "~~", false,
                LITERAL);
}

static void latex_render(cmark_syntax_extension *extension,
                         cmark_renderer *renderer, cmark_node *node,
                         cmark_event_type ev_type, int options) {
  // requires \usepackage{ulem}
  bool entering = (ev_type == CMARK_EVENT_ENTER);
  if (entering) {
    renderer->out(renderer, node, "\\sout{", false, LITERAL);
  } else {
    renderer->out(renderer, node, "}", false, LITERAL);
  }
}

static void man_render(cmark_syntax_extension *extension,
                       cmark_renderer *renderer, cmark_node *node,
                       cmark_event_type ev_type, int options) {
  bool entering = (ev_type == CMARK_EVENT_ENTER);
  if (entering) {
    renderer->cr(renderer);
    renderer->out(renderer, node, ".ST \"", false, LITERAL);
  } else {
    renderer->out(renderer, node, "\"", false, LITERAL);
    renderer->cr(renderer);
  }
}

static void html_render(cmark_syntax_extension *extension,
                        cmark_html_renderer *renderer, cmark_node *node,
                        cmark_event_type ev_type, int options) {
  bool entering = (ev_type == CMARK_EVENT_ENTER);
  if (node->type == CMARK_NODE_SUBSCRIPT) {
    cmark_strbuf_puts(renderer->html, entering ? "<sub>" : "</sub>");
    return;
  }
  if (entering) {
    cmark_strbuf_puts(renderer->html, "<del>");
  } else {
    cmark_strbuf_puts(renderer->html, "</del>");
  }
}

static void plaintext_render(cmark_syntax_extension *extension,
                             cmark_renderer *renderer, cmark_node *node,
                             cmark_event_type ev_type, int options) {
  renderer->out(renderer, node, "~", false, LITERAL);
}

cmark_syntax_extension *create_strikethrough_extension(void) {
  cmark_syntax_extension *ext = cmark_syntax_extension_new("strikethrough");
  cmark_llist *special_chars = NULL;

  cmark_syntax_extension_set_get_type_string_func(ext, get_type_string);
  cmark_syntax_extension_set_can_contain_func(ext, can_contain);
  cmark_syntax_extension_set_commonmark_render_func(ext, commonmark_render);
  cmark_syntax_extension_set_latex_render_func(ext, latex_render);
  cmark_syntax_extension_set_man_render_func(ext, man_render);
  cmark_syntax_extension_set_html_render_func(ext, html_render);
  cmark_syntax_extension_set_plaintext_render_func(ext, plaintext_render);
  CMARK_NODE_STRIKETHROUGH = cmark_syntax_extension_add_node(1);
  CMARK_NODE_SUBSCRIPT = cmark_syntax_extension_add_node(1);

  cmark_syntax_extension_set_match_inline_func(ext, match);
  cmark_syntax_extension_set_inline_from_delim_func(ext, insert);

  cmark_mem *mem = cmark_get_default_mem_allocator();
  special_chars = cmark_llist_append(mem, special_chars, (void *)'~');
  cmark_syntax_extension_set_special_inline_chars(ext, special_chars);

  cmark_syntax_extension_set_emphasis(ext, 1);

  return ext;
}
