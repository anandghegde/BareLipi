#ifndef CMARK_INLINES_H
#define CMARK_INLINES_H

#ifdef __cplusplus
extern "C" {
#endif

#include "references.h"

cmark_chunk cmark_clean_url(cmark_mem *mem, cmark_chunk *url);
cmark_chunk cmark_clean_title(cmark_mem *mem, cmark_chunk *title);

CMARK_GFM_EXPORT
void cmark_parse_inlines(cmark_parser *parser,
                         cmark_node *parent,
                         cmark_map *refmap,
                         int options);

/* lipi: the three trailing out-parameters (may be NULL) receive the raw
 * label, destination and title chunks (views into `input`). */
bufsize_t cmark_parse_reference_inline(cmark_mem *mem, cmark_chunk *input,
                                       cmark_map *refmap,
                                       cmark_chunk *out_label,
                                       cmark_chunk *out_url,
                                       cmark_chunk *out_title);

/* lipi: the special-character tables live on the parser. */
void cmark_inlines_init_special_characters(cmark_parser *parser);
void cmark_inlines_add_special_character(cmark_parser *parser, unsigned char c, bool emphasis);
void cmark_inlines_remove_special_character(cmark_parser *parser, unsigned char c, bool emphasis);

#ifdef __cplusplus
}
#endif

#endif
