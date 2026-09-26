#ifndef LIPI_MATH_H
#define LIPI_MATH_H

#include "cmark-gfm-core-extensions.h"

/* Inline TeX math: `$…$` (inline) and `$$…$$` (display), Pandoc rules.
 * The node type is CMARK_NODE_MATH (declared in lipi_cmark.h). */
cmark_syntax_extension *create_math_extension(void);

#endif
