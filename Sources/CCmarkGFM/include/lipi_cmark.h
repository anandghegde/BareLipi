/* lipi_cmark.h — BareLipi additions to the vendored cmark-gfm.
 *
 * These entry points expose the source-position bookkeeping that the lipi
 * patches add to the parser (see Sources/CCmarkGFM/PATCHES.md).  Everything
 * here is stable C that Swift's `LipiParser` builds its value AST from.
 */
#ifndef LIPI_CMARK_H
#define LIPI_CMARK_H

#include "cmark-gfm.h"
#include "cmark-gfm-extension_api.h"

#ifdef __cplusplus
extern "C" {
#endif

/** Parser option: leave footnote definitions where they were written and keep
 *  footnote references' labels instead of renumbering and relocating them. */
#define LIPI_OPT_KEEP_FOOTNOTES (1 << 20)

/** Node flag: the link is an autolink (`<…>` or a bare GFM URL/e-mail). */
#define LIPI_FLAG_AUTOLINK (1 << 0)
/** Node flag: the range was derived from decoded text and may be inexact. */
#define LIPI_FLAG_APPROX (1 << 1)
/** Node flag: a fenced code block was closed by a closing fence; the block's
 *  lipi_start/lipi_end are then the fence's 0-based byte columns on end_line. */
#define LIPI_FLAG_FENCE_CLOSED (1 << 2)

/** One appended line of a leaf block's content buffer. */
typedef struct {
  int line;           /**< 1-based source line number */
  int prefix;         /**< bytes of the source line consumed before the text */
  int pad;            /**< virtual spaces standing in for a partially consumed tab */
  int content_offset; /**< offset into the content buffer where the line begins */
  int len;            /**< bytes appended for this line, pad and newline included */
} lipi_line_info;

/** A link reference definition, as recorded on the document node. */
typedef struct {
  int start_line;    /**< 1-based */
  int start_col;     /**< 0-based byte column */
  int end_line;      /**< 1-based, exclusive end position */
  int end_col;       /**< 0-based byte column, exclusive */
  const char *label; /**< raw label text (not normalised) */
  int label_len;
  const char *url;   /**< raw destination */
  int url_len;
  const char *title; /**< raw title, delimiters included */
  int title_len;
} lipi_refdef_info;

/* Inline byte range, as offsets into the parent leaf block's content buffer. */
int lipi_node_get_start(cmark_node *node);
int lipi_node_get_end(cmark_node *node);
int lipi_node_get_flags(cmark_node *node);

/* Bytes dropped from the front of the block's content after the line map was
 * built (resolved reference definitions, a fence's info line). Add this to an
 * inline offset before mapping it through the line map. */
int lipi_node_get_dropped(cmark_node *node);
int lipi_node_get_internal_offset(cmark_node *node);
int lipi_node_get_html_block_type(cmark_node *node);

/* Line map of a leaf block. */
int lipi_node_line_count(cmark_node *node);
int lipi_node_line_at(cmark_node *node, int index, lipi_line_info *out);

/* Map a content offset (line-map coordinates) to a source line and 0-based
 * byte column. Returns 0 when the node has no line map. */
int lipi_node_map_offset(cmark_node *node, int content_offset, int *line,
                         int *col);

/* Link reference definitions recorded on the document node. */
int lipi_node_refdef_count(cmark_node *document);
int lipi_node_refdef_at(cmark_node *document, int index,
                        lipi_refdef_info *out);

/* Pre-populate the parser's reference map before feeding it. `age` orders
 * definitions with equal labels (lowest wins); pass -1 for the natural order. */
void lipi_parser_add_reference(cmark_parser *parser, const char *label,
                               int label_len, const char *url, int url_len,
                               const char *title, int title_len, int age);

/* Extension node types (valid after cmark_gfm_core_extensions_ensure_registered). */
extern cmark_node_type CMARK_NODE_STRIKETHROUGH;
extern cmark_node_type CMARK_NODE_MATH;

/* Math node contents. Returns 0 if `node` is not a math node. */
int lipi_math_get(cmark_node *node, const char **text, int *len, int *display);

/* 1 when the list item carries the task-list extension. */
int lipi_node_is_tasklist(cmark_node *node);

/* Block details that cmark-gfm keeps private. */
int lipi_node_get_bullet_char(cmark_node *list);
int lipi_node_heading_is_setext(cmark_node *heading);
int lipi_node_code_is_fenced(cmark_node *code_block);
int lipi_node_code_fence_length(cmark_node *code_block);
int lipi_node_code_fence_offset(cmark_node *code_block);
int lipi_node_code_fence_char(cmark_node *code_block);

/* Raw label of a footnote definition or reference (not NUL-terminated). */
const char *lipi_node_get_label(cmark_node *node, int *len);

/* Extension node kinds, so callers need not read the extension type globals. */
#define LIPI_EXT_NONE 0
#define LIPI_EXT_TABLE 1
#define LIPI_EXT_TABLE_ROW 2
#define LIPI_EXT_TABLE_CELL 3
#define LIPI_EXT_STRIKETHROUGH 4
#define LIPI_EXT_MATH 5
int lipi_node_get_ext_type(cmark_node *node);

/* Decode one HTML entity (`&amp;`, `&#38;`, `&#x26;`) at `src`, which must
 * start with `&`. Writes the UTF-8 of the decoded character(s) to `out` and
 * its length to `out_len`; returns the number of source bytes consumed
 * (including `&` and `;`) or 0 when `src` does not start a valid entity. */
int lipi_decode_entity(const uint8_t *src, int size, uint8_t *out, int out_cap,
                       int *out_len);

#ifdef __cplusplus
}
#endif

#endif
