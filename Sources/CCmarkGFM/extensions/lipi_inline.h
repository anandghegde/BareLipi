#ifndef LIPI_INLINE_H
#define LIPI_INLINE_H

#include "cmark-gfm-core-extensions.h"
#include <inlines.h>

/* Opt-in inline spans (PATCHES.md §7). Node types are declared in
 * lipi_cmark.h. */
cmark_syntax_extension *create_superscript_extension(void);
cmark_syntax_extension *create_highlight_extension(void);

/* Pandoc sub/superscript rules for a single delimiter `ch` at `d[pos]`:
 * an opener has non-space content and a lone closing `ch` before any
 * unescaped whitespace; a closer follows a non-space character. */
int lipi_script_can_open(const unsigned char *d, int len, int pos,
                         unsigned char ch);
int lipi_script_can_close(const unsigned char *d, int len, int pos,
                          unsigned char ch);

/* Wraps the nodes between two matched delimiters in a node of `type`. */
struct delimiter *lipi_insert_span(cmark_syntax_extension *self,
                                   cmark_inline_parser *inline_parser,
                                   struct delimiter *opener,
                                   struct delimiter *closer,
                                   cmark_node_type type);

#endif
