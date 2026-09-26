# Patches to the vendored cmark-gfm

Upstream: [github/cmark-gfm](https://github.com/github/cmark-gfm) tag
`0.29.0.gfm.13` (commit `587a12bb54d95ac37241377e6ddc93ea0e45439b`).
`src/` and `extensions/` are upstream's directories with the build glue
(`CMakeLists.txt`, `*.in`, `*.re`, `main.c`) removed; the re2c output
(`scanners.c`, `ext_scanners.c`) is vendored as generated. Public headers
live in `include/` so SwiftPM can expose them; `src/config.h` is a
hand-written equivalent of the CMake-generated one for clang on macOS, and
`include/cmark-gfm_version.h` and the two `*_export.h` headers are the
generated files with the export macros defined as empty.

Every change to an upstream file is marked with a `lipi` comment. This file
is the index. To re-vendor, apply the sections below on top of the new
upstream and run `swift test`: the spec suites in
`Tests/LipiCoreTests/Fixtures` and the range invariants in
`Tests/LipiCoreTests/ParserTests.swift` exercise every patch.

## 1. Source-position tracking (the reason for vendoring)

cmark-gfm records 1-based line and column numbers per node. BareLipi needs
exact byte ranges, in source coordinates, for every block and inline, so it
can map an edit in the rope back onto the AST. The patches below add that
without changing what the parser accepts.

### `src/node.h`, `src/node.c`

- `struct cmark_node` gains `lipi_start`, `lipi_end` and `lipi_flags`
  (inline byte range relative to the parent leaf block's content buffer,
  delimiters included; flags below), `lipi_dropped` (bytes dropped from the
  front of `content` after the line map was built), `lipi_html_block_type`
  (the union member `as.html_block_type` aliases `as.literal` and is
  clobbered at finalize), a line map (`lipi_lines`, `lipi_line_count`,
  `lipi_line_cap`) and, on the document node only, the recorded link
  reference definitions (`lipi_refdefs`, count, capacity).
- `lipi_refdef` type: source line/column range plus the raw label,
  destination and title chunks.
- `S_free_nodes` releases the line map and the refdef chunks.
- `node.h` includes `lipi_cmark.h` for the `lipi_line_info` type.

### `src/lipi.c`, `include/lipi_cmark.h` (new)

The C surface that `Sources/LipiCore/Parser/CMarkBridge.swift` reads:

- `lipi_node_push_line`, `lipi_node_copy_lines_before`,
  `lipi_node_push_refdef`: private growable arrays (declared in `node.h`).
- Getters for the fields above, `lipi_node_line_count` /
  `lipi_node_line_at`, and `lipi_node_map_offset`, which turns a content
  offset (line-map coordinates) into a source line and 0-based byte column
  through a binary search of the line map, honouring the partial-tab pad.
- `lipi_node_refdef_count` / `lipi_node_refdef_at`, and
  `lipi_parser_add_reference`, which pre-populates a parser's reference map
  (with an `age` override so definitions from earlier blocks keep winning
  during an incremental re-parse).
- Accessors for details cmark keeps private: bullet char, setext flag,
  fence char/length/offset, task-list items, footnote labels, the
  extension node kind (`LIPI_EXT_*`) and `lipi_math_get`.
- `lipi_decode_entity`: decodes one `&…;` character reference with
  cmark's own entity table (`houdini_unescape_ent`) so the projection
  layer folds entities to exactly the characters the parser saw.
- Flags: `LIPI_FLAG_AUTOLINK` (link came from `<…>` or a bare GFM URL),
  `LIPI_FLAG_APPROX` (range derived from decoded text, may be inexact),
  `LIPI_FLAG_FENCE_CLOSED` (a closing fence was seen; the code block's
  `lipi_start`/`lipi_end` are then the fence's byte columns on its last
  line).
- Option: `LIPI_OPT_KEEP_FOOTNOTES` (1 << 20), see §3.

### `src/blocks.c`

- `add_line` appends a `lipi_line_info` entry to the container's line map
  for every line of content it adds: source line, prefix bytes consumed
  (container markers, indentation), partial-tab pad, and the content offset
  and length. Offsets are in pre-drop coordinates
  (`content.size + lipi_dropped`), because `resolve_reference_link_definitions`
  can run in the middle of a paragraph (a setext underline after a
  definition) and the map must stay in one coordinate space with
  `lipi_node_map_offset(node, dropped + inline_offset)`.
- `resolve_reference_link_definitions` records every resolved definition on
  the document node (`lipi_record_refdef`) with its exact source range and
  raw label/destination/title, and bumps `lipi_dropped` by the bytes it
  drops. `finalize` does the same for the info line dropped from a fenced
  code block.
- The closing-fence branch of `S_process_line` sets
  `LIPI_FLAG_FENCE_CLOSED` and stores the fence's byte columns.
- The HTML-block opener stores `lipi_html_block_type` beside
  `as.html_block_type`.
- `cmark_parse_document` skips `process_footnotes` under
  `LIPI_OPT_KEEP_FOOTNOTES`.
- `cmark_parser_reset` calls `cmark_inlines_init_special_characters`, and
  `cmark_manage_extensions_special_characters` passes the parser to the
  add/remove functions (§2).

### `src/inlines.c`, `src/inlines.h`

- `make_str`, `make_autolink`, `handle_backticks` (both the code span and
  the unmatched-backtick literal, whose upstream range pointed at the byte
  after the ticks), `handle_backslash` (hard break), `handle_newline`
  (soft/hard break, which owns the trailing whitespace before the newline),
  `handle_close_bracket` (links, images, footnote references) and
  `parse_inline`'s trailing-whitespace trim set `lipi_start`/`lipi_end`.
- `S_insert_emph` gives the emphasis node the delimiters it consumed (the
  opener's last `use_delims` bytes and the closer's first) and shrinks the
  opener/closer text nodes accordingly.
- `cmark_parse_reference_inline` takes three optional out-parameters that
  receive the raw label, destination and title chunks so `blocks.c` can
  record them.
- `cmark_node_unput` (the autolink extension hands back the text before an
  e-mail match) keeps `lipi_end` in step with the shortened literal.
- `scan_delims` uses `cmark_utf8proc_is_punctuation_or_symbol` (§4).
- Special-character tables moved onto the parser (§2).

### `src/iterator.c`

`cmark_consolidate_text_nodes` extends the surviving node's `lipi_end` to
the last merged node and propagates `LIPI_FLAG_APPROX`.

### `extensions/strikethrough.c`, `extensions/autolink.c`, `extensions/table.c`

- Strikethrough delimiter runs and the resulting node carry byte ranges.
- Autolink: `<…>`-less URL and e-mail matches (`www_match`, `url_match`,
  `email_match`) and the postprocess pass (`postprocess_text`) set ranges
  and `LIPI_FLAG_AUTOLINK`. The postprocess pass splits an already-decoded
  text node, so it can only map literal offsets back to source when the
  node is exact; otherwise it marks the pieces `LIPI_FLAG_APPROX`.
- Table: header cells are mapped back to their source line through the
  paragraph's line map; body cells get the byte columns of the cell text on
  the current line; the lines preceding the header keep their provenance
  when the table extension splits a paragraph
  (`lipi_node_copy_lines_before`).

## 2. Thread safety: per-parser special-character tables

Upstream keeps the inline scanner's `SPECIAL_CHARS` and `SKIP_CHARS` tables
in process globals that `cmark_manage_extensions_special_characters` toggles
on every parse. Two parsers with different extension sets on different
threads (the test suite runs suites in parallel; the editor will parse
previews off the main thread) race on them, which showed up as flipping
autolink/strikethrough failures and an out-of-range index.

- `src/parser.h`: `cmark_parser` gains `special_chars[256]` and
  `skip_chars[256]`.
- `src/inlines.c`/`.h`: the globals become `const` base tables;
  `cmark_inlines_init_special_characters(parser)` copies them in, and
  `cmark_inlines_add_special_character` /
  `cmark_inlines_remove_special_character` take the parser. The `subject`
  carries pointers to the active tables (`subject_from_buf` defaults to the
  base tables; `cmark_parse_inlines` points them at the parser's).

The remaining globals (`node.c`'s `enable_safety_checks` and `nextflag`,
`table.c`'s `CMARK_NODE__TABLE_VISITED`, the extension node-type ids) are
written only during `cmark_gfm_core_extensions_ensure_registered`, which
`CMarkBridge` runs once from a static initializer (dispatch-once semantics)
before the first parse.

## 3. Footnotes in place: `LIPI_OPT_KEEP_FOOTNOTES`

cmark-gfm's `process_footnotes` unlinks every footnote definition, renumbers
references and appends the used definitions to the end of the document. An
editor needs definitions where the author wrote them. With the option set,
`cmark_parse_document` skips that pass; definitions stay in the tree and
references keep their labels.

- `src/html.c`, `src/commonmark.c`: the footnote-reference renderers
  dereferenced `parent_footnote_def`, which is NULL when the pass is
  skipped. They fall back to the reference's own label.

## 4. CommonMark 0.31.2 conformance backports

cmark-gfm 0.29.0.gfm.13 implements CommonMark 0.29. Three spec changes are
needed to pass the 0.31.2 suite:

- `src/utf8.c`, `src/utf8.h`: `cmark_utf8proc_is_punctuation_or_symbol`,
  the P-or-S class table generated by upstream cmark 0.31.2. `scan_delims`
  in `src/inlines.c` uses it for left/right-flanking checks (0.31: Unicode
  symbols count like punctuation).
- `src/houdini_html_u.c`: numeric character references are limited to 7
  decimal or 6 hexadecimal digits (0.30), instead of 8 either way.
- `src/html.c`: nested `<strong>` renders as nested tags (0.30). cmark-gfm
  collapsed `<strong><strong>` into one element. The vendored GFM spec
  fixture (`Tests/LipiCoreTests/Fixtures/gfm-spec-0.29.txt`) carries the
  0.31.2 output for the nine emphasis examples this affects; the fixture's
  header comment lists the change.

## 5. Inline math extension (new)

`extensions/math.c`, `extensions/lipi_math.h`: `$…$` inline and `$$…$$`
display math following Pandoc's `tex_math_dollars` rules (opening `$` not
followed by whitespace, closing `$` not preceded by whitespace and not
followed by a digit, backslash-escaped `$` inert). The node type is
`CMARK_NODE_MATH`; the raw TeX is an opaque payload read through
`lipi_math_get`. Renderers emit `<span class="math inline">\(…\)</span>` /
`<span class="math display">\[…\]</span>` in HTML and the original
delimiters elsewhere. `extensions/core-extensions.c` registers it as
`"math"` alongside the GFM five; it is only attached to a parser when
`ParserOptions.Extensions.math` is set.

## 6. Build layout

- `include/CCmarkGFM.h`: umbrella header (public API, extension API, core
  extensions, `lipi_cmark.h`).
- `include/cmark-gfm.h`, `cmark-gfm-extension_api.h`,
  `cmark-gfm-core-extensions.h`: moved from `src/` and `extensions/`
  unchanged.
- `Package.swift` adds `src` and `extensions` as header search paths; the
  extensions include core headers with angle brackets, as upstream does.

## 7. Subscript, superscript and highlight (new, opt-in)

PRD §6.13. All three are off unless the Swift side asks for them, so the
GFM and CommonMark spec suites see an unchanged parser.

- `extensions/lipi_inline.c`, `extensions/lipi_inline.h` (new):
  - `^sup^` (`create_superscript_extension`, registered as
    `"superscript"`, node `CMARK_NODE_SUPERSCRIPT`) and `==highlight==`
    (`create_highlight_extension`, `"highlight"`,
    `CMARK_NODE_HIGHLIGHT`).
  - Sub/superscripts follow Pandoc: the opener is followed by a
    non-space, the content has no unescaped whitespace, and the closer is
    a single delimiter preceded by a non-space. A run of two or more `^`
    is literal. A `^` directly after `[` is left to the footnote
    reference scanner (`[^1]`).
  - Highlight uses `scan_delimiters` flanking like strikethrough and
    requires exactly two `=`.
  - Delimiter text nodes are chunk views into the input
    (`cmark_chunk_dup`) and carry `lipi_start`/`lipi_end` like other
    inlines (§1).
  - `lipi_insert_span` wraps the nodes between two delimiters of equal
    length in a new node; subscript uses it too.
  - HTML renders `<sub>`, `<sup>`, `<mark>`; CommonMark renders the
    original delimiters.
- `extensions/strikethrough.c`: `~sub~` lives here, not in its own
  extension, because special characters are dispatched to the first
  extension that registered them and `~` belongs to strikethrough. With
  `LIPI_OPT_SUBSCRIPT` (`1 << 21`, `include/lipi_cmark.h`) set, a single
  `~` uses the Pandoc subscript rules and closes into
  `CMARK_NODE_SUBSCRIPT`; `~~` is strikethrough as before. Without the
  option the file behaves as upstream (single-tilde strikethrough).
- `include/lipi_cmark.h`: `LIPI_OPT_SUBSCRIPT`, the three node types, and
  `LIPI_EXT_SUBSCRIPT` 6, `LIPI_EXT_SUPERSCRIPT` 7,
  `LIPI_EXT_HIGHLIGHT` 8 for `lipi_node_get_ext_type` (`src/lipi.c`).
- `extensions/core-extensions.c` registers `"superscript"` and
  `"highlight"`.
