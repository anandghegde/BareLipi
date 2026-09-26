/* lipi.c — BareLipi additions to cmark-gfm (see PATCHES.md). */
#include <string.h>

#include "cmark-gfm.h"
#include "lipi_cmark.h"
#include "node.h"
#include "parser.h"
#include "references.h"
#include "syntax_extension.h"
#include "table.h"

#define NODE_MEM(node) cmark_node_mem(node)

void lipi_node_push_line(cmark_node *node, const lipi_line_info *entry) {
  if (node->lipi_line_count == node->lipi_line_cap) {
    int new_cap = node->lipi_line_cap ? node->lipi_line_cap * 2 : 4;
    lipi_line_info *grown = (lipi_line_info *)NODE_MEM(node)->calloc(
        (size_t)new_cap, sizeof(lipi_line_info));
    if (node->lipi_lines) {
      memcpy(grown, node->lipi_lines,
             (size_t)node->lipi_line_count * sizeof(lipi_line_info));
      NODE_MEM(node)->free(node->lipi_lines);
    }
    node->lipi_lines = grown;
    node->lipi_line_cap = new_cap;
  }
  node->lipi_lines[node->lipi_line_count++] = *entry;
}

void lipi_node_copy_lines_before(cmark_node *dst, cmark_node *src,
                                 int content_limit) {
  int i;
  for (i = 0; i < src->lipi_line_count; i++) {
    if (src->lipi_lines[i].content_offset >= content_limit)
      break;
    lipi_node_push_line(dst, &src->lipi_lines[i]);
  }
}

void lipi_node_push_refdef(cmark_node *root, const lipi_refdef *def) {
  if (root->lipi_refdef_count == root->lipi_refdef_cap) {
    int new_cap = root->lipi_refdef_cap ? root->lipi_refdef_cap * 2 : 4;
    lipi_refdef *grown = (lipi_refdef *)NODE_MEM(root)->calloc(
        (size_t)new_cap, sizeof(lipi_refdef));
    if (root->lipi_refdefs) {
      memcpy(grown, root->lipi_refdefs,
             (size_t)root->lipi_refdef_count * sizeof(lipi_refdef));
      NODE_MEM(root)->free(root->lipi_refdefs);
    }
    root->lipi_refdefs = grown;
    root->lipi_refdef_cap = new_cap;
  }
  root->lipi_refdefs[root->lipi_refdef_count++] = *def;
}

int lipi_node_get_start(cmark_node *node) { return node->lipi_start; }
int lipi_node_get_end(cmark_node *node) { return node->lipi_end; }
int lipi_node_get_flags(cmark_node *node) { return node->lipi_flags; }
int lipi_node_get_dropped(cmark_node *node) { return node->lipi_dropped; }
int lipi_node_get_internal_offset(cmark_node *node) {
  return node->internal_offset;
}
int lipi_node_get_html_block_type(cmark_node *node) {
  return node->type == CMARK_NODE_HTML_BLOCK ? node->lipi_html_block_type : 0;
}

int lipi_node_line_count(cmark_node *node) { return node->lipi_line_count; }

int lipi_node_line_at(cmark_node *node, int index, lipi_line_info *out) {
  if (index < 0 || index >= node->lipi_line_count)
    return 0;
  *out = node->lipi_lines[index];
  return 1;
}

int lipi_node_map_offset(cmark_node *node, int content_offset, int *line,
                         int *col) {
  int lo = 0, hi = node->lipi_line_count - 1, best = 0;
  const lipi_line_info *e;
  int c;
  if (node->lipi_line_count == 0)
    return 0;
  if (content_offset < 0)
    content_offset = 0;
  while (lo <= hi) {
    int mid = lo + (hi - lo) / 2;
    if (node->lipi_lines[mid].content_offset <= content_offset) {
      best = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  e = &node->lipi_lines[best];
  c = content_offset - e->content_offset;
  *line = e->line;
  if (c < e->pad)
    *col = e->prefix > 0 ? e->prefix - 1 : 0;
  else
    *col = e->prefix + (c - e->pad);
  return 1;
}

int lipi_node_refdef_count(cmark_node *document) {
  return document->lipi_refdef_count;
}

int lipi_node_refdef_at(cmark_node *document, int index,
                        lipi_refdef_info *out) {
  const lipi_refdef *d;
  if (index < 0 || index >= document->lipi_refdef_count)
    return 0;
  d = &document->lipi_refdefs[index];
  out->start_line = d->start_line;
  out->start_col = d->start_col;
  out->end_line = d->end_line;
  out->end_col = d->end_col;
  out->label = (const char *)d->label.data;
  out->label_len = d->label.len;
  out->url = (const char *)d->url.data;
  out->url_len = d->url.len;
  out->title = (const char *)d->title.data;
  out->title_len = d->title.len;
  return 1;
}

void lipi_parser_add_reference(cmark_parser *parser, const char *label,
                               int label_len, const char *url, int url_len,
                               const char *title, int title_len, int age) {
  cmark_chunk l = {(unsigned char *)label, label_len, 0};
  cmark_chunk u = {(unsigned char *)url, url_len, 0};
  cmark_chunk t = {(unsigned char *)title, title_len, 0};
  unsigned int before = parser->refmap->size;
  cmark_reference_create(parser->refmap, &l, &u, &t);
  if (age >= 0 && parser->refmap->size > before && parser->refmap->refs)
    parser->refmap->refs->age = (unsigned int)age;
}

int lipi_node_is_tasklist(cmark_node *node) {
  return node->type == CMARK_NODE_ITEM && node->extension != NULL &&
         node->extension->name != NULL &&
         strcmp(node->extension->name, "tasklist") == 0;
}

int lipi_node_get_bullet_char(cmark_node *list) {
  return list->type == CMARK_NODE_LIST ? list->as.list.bullet_char : 0;
}

int lipi_node_heading_is_setext(cmark_node *heading) {
  return heading->type == CMARK_NODE_HEADING ? heading->as.heading.setext : 0;
}

int lipi_node_code_is_fenced(cmark_node *code_block) {
  return code_block->type == CMARK_NODE_CODE_BLOCK ? code_block->as.code.fenced
                                                   : 0;
}

int lipi_node_code_fence_length(cmark_node *code_block) {
  return code_block->type == CMARK_NODE_CODE_BLOCK
             ? code_block->as.code.fence_length
             : 0;
}

int lipi_node_code_fence_offset(cmark_node *code_block) {
  return code_block->type == CMARK_NODE_CODE_BLOCK
             ? code_block->as.code.fence_offset
             : 0;
}

int lipi_node_code_fence_char(cmark_node *code_block) {
  return code_block->type == CMARK_NODE_CODE_BLOCK
             ? code_block->as.code.fence_char
             : 0;
}

const char *lipi_node_get_label(cmark_node *node, int *len) {
  if (node->type == CMARK_NODE_FOOTNOTE_DEFINITION ||
      node->type == CMARK_NODE_FOOTNOTE_REFERENCE) {
    *len = node->as.literal.len;
    return (const char *)node->as.literal.data;
  }
  *len = 0;
  return "";
}

int lipi_node_get_ext_type(cmark_node *node) {
  cmark_node_type t = node->type;
  if (t == CMARK_NODE_TABLE)
    return LIPI_EXT_TABLE;
  if (t == CMARK_NODE_TABLE_ROW)
    return LIPI_EXT_TABLE_ROW;
  if (t == CMARK_NODE_TABLE_CELL)
    return LIPI_EXT_TABLE_CELL;
  if (t == CMARK_NODE_STRIKETHROUGH)
    return LIPI_EXT_STRIKETHROUGH;
  if (t == CMARK_NODE_MATH)
    return LIPI_EXT_MATH;
  return LIPI_EXT_NONE;
}
