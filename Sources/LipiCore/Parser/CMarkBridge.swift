import CCmarkGFM

/// One top-level block of a parsed region, as the bridge hands it to the parser.
struct RegionBlock {
    /// Start of the block's span, relative to the parsed bytes. The span runs
    /// from the block's first line to the next block's first line (trailing
    /// blank lines belong to the block before them). The first span starts at 0.
    var spanStart: Int
    /// The block, with ranges relative to `spanStart`.
    var block: Block
    /// Link reference definitions inside the block, in source order.
    var referenceDefinitions: [ReferenceDefinition]
    /// Whether the span's bytes contain `[`, i.e. whether its inlines could
    /// depend on the document's reference map.
    var hasBracket: Bool
}

/// Reference definition to pre-load into a region parse. Lower ages win.
struct SeedReference {
    var definition: ReferenceDefinition
    var age: Int32
}

/// Runs the vendored cmark-gfm and converts its tree into the value AST with
/// byte ranges. Everything here is synchronous and allocation-light: one
/// parser per call, one pass over the tree.
enum CMarkBridge {
    private static let ready: Bool = {
        cmark_gfm_core_extensions_ensure_registered()
        return true
    }()

    /// Parses `bytes` as a standalone document. Positions in the result are
    /// relative to `bytes`.
    static func parse(_ bytes: UnsafeBufferPointer<UInt8>, options: ParserOptions,
                      references: [SeedReference], ids: inout NodeIDGenerator) -> [RegionBlock] {
        _ = ready
        guard let parser = cmark_parser_new(options.cmarkOptions) else { return [] }
        defer { cmark_parser_free(parser) }
        attachExtensions(options.extensionNames, to: parser)
        seed(references, into: parser)
        feed(bytes, to: parser)
        guard let root = cmark_parser_finish(parser) else { return [] }
        defer { cmark_node_free(root) }

        var converter = Converter(bytes: bytes, lineStarts: lineStarts(of: bytes), ids: ids)
        converter.emoji = options.extensions.contains(.emojiShortcodes)
        converter.headingAttributes = options.extensions.contains(.headingAttributes)
        let result = converter.regionBlocks(from: root)
        ids = converter.ids
        return result
    }

    /// HTML for `markdown`, exactly as `cmark-gfm --unsafe` renders it. Used by
    /// the spec suites and by export.
    static func renderHTML(_ markdown: String, extensions: [String], cmarkOptions: Int32) -> String {
        _ = ready
        guard let parser = cmark_parser_new(cmarkOptions) else { return "" }
        defer { cmark_parser_free(parser) }
        attachExtensions(extensions, to: parser)
        var text = markdown
        text.withUTF8 { feed($0, to: parser) }
        guard let root = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(root) }
        guard let html = cmark_render_html(root, cmarkOptions, cmark_parser_get_syntax_extensions(parser)) else { return "" }
        defer { cmark_get_default_mem_allocator().pointee.free(html) }
        return String(cString: html)
    }

    private static func attachExtensions(_ names: [String], to parser: OpaquePointer) {
        for name in names {
            if let ext = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, ext)
            }
        }
    }

    private static func feed(_ bytes: UnsafeBufferPointer<UInt8>, to parser: OpaquePointer) {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return }
        base.withMemoryRebound(to: CChar.self, capacity: bytes.count) {
            cmark_parser_feed(parser, $0, bytes.count)
        }
    }

    private static func seed(_ references: [SeedReference], into parser: OpaquePointer) {
        for ref in references {
            let label = Array(ref.definition.label.utf8)
            let url = Array(ref.definition.destination.utf8)
            let title = Array(ref.definition.title.utf8)
            var buffer = label
            buffer.append(contentsOf: url)
            buffer.append(contentsOf: title)
            buffer.append(0)
            buffer.withUnsafeBufferPointer { raw in
                raw.baseAddress!.withMemoryRebound(to: CChar.self, capacity: raw.count) { p in
                    lipi_parser_add_reference(parser,
                                              p, Int32(label.count),
                                              p + label.count, Int32(url.count),
                                              p + label.count + url.count, Int32(title.count),
                                              ref.age)
                }
            }
        }
    }

    /// Byte offsets at which lines start, following cmark's line-ending rule
    /// (`\n`, `\r` or `\r\n`). Index 0 is always 0; a trailing terminator
    /// yields a final empty line.
    static func lineStarts(of bytes: UnsafeBufferPointer<UInt8>) -> [Int] {
        var starts = [0]
        var i = 0
        let n = bytes.count
        while i < n {
            let c = bytes[i]
            if c == 0x0A {
                starts.append(i + 1)
            } else if c == 0x0D {
                if i + 1 < n && bytes[i + 1] == 0x0A { i += 1 }
                starts.append(i + 1)
            }
            i += 1
        }
        return starts
    }
}

// MARK: - Tree conversion

private struct Converter {
    let bytes: UnsafeBufferPointer<UInt8>
    let lineStarts: [Int]
    var ids: NodeIDGenerator
    var emoji = false
    var headingAttributes = false

    var count: Int { bytes.count }

    // MARK: Positions

    /// Offset where 1-based `line` starts.
    func lineStart(_ line: Int32) -> Int {
        let i = Int(line) - 1
        if i < 0 { return 0 }
        return i < lineStarts.count ? lineStarts[i] : count
    }

    /// Offset where the line after `line` starts (or the end of the bytes).
    func lineEnd(_ line: Int32) -> Int {
        let i = Int(line)
        return i < lineStarts.count ? lineStarts[i] : count
    }

    /// End of `line`'s content, before its terminator.
    func lineContentEnd(_ line: Int32) -> Int {
        let s = lineStart(line)
        var e = lineEnd(line)
        if e > s && bytes[e - 1] == 0x0A { e -= 1 }
        if e > s && bytes[e - 1] == 0x0D { e -= 1 }
        return e
    }

    /// Offset of a 0-based byte `column` on `line`, clamped into the line.
    func offset(line: Int32, column: Int) -> Int {
        let s = lineStart(line)
        return min(max(s, s + column), lineEnd(line))
    }

    /// Index into `lineStarts` of the line containing `offset`.
    func lineIndex(containing offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    @inline(__always) func isSpaceOrTab(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 }
    @inline(__always) func isWhitespace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }

    func hasNonBlank(_ range: Range<Int>) -> Bool {
        var i = range.lowerBound
        while i < range.upperBound {
            if !isSpaceOrTab(bytes[i]) { return true }
            i += 1
        }
        return false
    }

    func containsBracket(_ range: Range<Int>) -> Bool {
        var i = range.lowerBound
        while i < range.upperBound {
            if bytes[i] == 0x5B { return true }
            i += 1
        }
        return false
    }

    // MARK: Line maps

    /// The lines that fed a leaf block's content buffer (see `lipi_line_info`).
    struct LineMap {
        var entries: [lipi_line_info]

        /// Source line and 0-based column of a content-buffer offset.
        func map(_ offset: Int) -> (line: Int32, column: Int) {
            var lo = 0, hi = entries.count - 1, best = 0
            let off = Int32(max(0, offset))
            while lo <= hi {
                let mid = (lo + hi) / 2
                if entries[mid].content_offset <= off { best = mid; lo = mid + 1 } else { hi = mid - 1 }
            }
            let e = entries[best]
            let c = off - e.content_offset
            if c < e.pad { return (e.line, e.prefix > 0 ? Int(e.prefix) - 1 : 0) }
            return (e.line, Int(e.prefix) + Int(c - e.pad))
        }
    }

    func lineMap(_ node: OpaquePointer) -> LineMap {
        let n = lipi_node_line_count(node)
        var entries: [lipi_line_info] = []
        entries.reserveCapacity(Int(n))
        var info = lipi_line_info()
        for i in 0..<n {
            lipi_node_line_at(node, i, &info)
            entries.append(info)
        }
        return LineMap(entries: entries)
    }

    /// Source offset of a content-buffer offset of a leaf block.
    func offset(in map: LineMap, contentOffset: Int) -> Int {
        let (line, column) = map.map(contentOffset)
        return offset(line: line, column: column)
    }

    // MARK: Strings

    func string(_ p: UnsafePointer<CChar>?) -> String {
        guard let p else { return "" }
        return String(cString: p)
    }

    func string(_ p: UnsafePointer<CChar>?, length: Int32) -> String {
        guard let p, length > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: p, count: Int(length)), as: UTF8.self)
    }

    func label(_ node: OpaquePointer) -> String {
        var len: Int32 = 0
        let p = lipi_node_get_label(node, &len)
        return string(p, length: len)
    }

    // MARK: Region assembly

    mutating func regionBlocks(from root: OpaquePointer) -> [RegionBlock] {
        var blocks: [Block] = []
        var child = cmark_node_first_child(root)
        while let node = child {
            if let b = block(node) { blocks.append(b) }
            child = cmark_node_next(node)
        }

        // Link reference definitions live on the document node; put them back
        // into the tree at the position they were written.
        let definitions = referenceDefinitions(of: root)
        for (definition, range) in definitions {
            let block = Block(id: ids.make(), range: range, kind: .linkReferenceDefinition(definition))
            Self.insert(block, into: &blocks)
        }

        var result: [RegionBlock] = []
        result.reserveCapacity(blocks.count)
        var previousSpanStart = 0
        var definitionIndex = 0
        for (k, var block) in blocks.enumerated() {
            var spanStart = k == 0 ? 0 : lineStarts[lineIndex(containing: block.range.lowerBound)]
            if spanStart < previousSpanStart { spanStart = previousSpanStart }
            let spanEnd = k + 1 < blocks.count
                ? max(spanStart, lineStarts[lineIndex(containing: blocks[k + 1].range.lowerBound)])
                : count
            var defs: [ReferenceDefinition] = []
            while definitionIndex < definitions.count, definitions[definitionIndex].1.lowerBound < spanEnd {
                defs.append(definitions[definitionIndex].0)
                definitionIndex += 1
            }
            block.shift(by: -spanStart)
            result.append(RegionBlock(spanStart: spanStart, block: block, referenceDefinitions: defs,
                                      hasBracket: containsBracket(spanStart..<spanEnd)))
            previousSpanStart = spanStart
        }
        return result
    }

    func referenceDefinitions(of root: OpaquePointer) -> [(ReferenceDefinition, Range<Int>)] {
        let n = lipi_node_refdef_count(root)
        guard n > 0 else { return [] }
        var out: [(ReferenceDefinition, Range<Int>)] = []
        out.reserveCapacity(Int(n))
        var info = lipi_refdef_info()
        for i in 0..<n {
            lipi_node_refdef_at(root, i, &info)
            let start = offset(line: info.start_line, column: Int(info.start_col))
            let end = max(start, offset(line: info.end_line, column: Int(info.end_col)))
            let def = ReferenceDefinition(label: string(info.label, length: info.label_len),
                                          destination: string(info.url, length: info.url_len),
                                          title: string(info.title, length: info.title_len))
            out.append((def, start..<end))
        }
        out.sort { $0.1.lowerBound < $1.1.lowerBound }
        return out
    }

    /// Inserts `def` into `blocks` (sorted by start) at its source position,
    /// descending into the container that holds it.
    static func insert(_ def: Block, into blocks: inout [Block]) {
        var i = blocks.count
        while i > 0 && blocks[i - 1].range.lowerBound > def.range.lowerBound { i -= 1 }
        if i > 0, blocks[i - 1].kind.isContainer, def.range.lowerBound < blocks[i - 1].range.upperBound {
            insert(def, into: &blocks[i - 1].children)
        } else {
            blocks.insert(def, at: i)
        }
    }

    // MARK: Blocks

    mutating func block(_ node: OpaquePointer) -> Block? {
        let type = cmark_node_get_type(node)
        let startLine = cmark_node_get_start_line(node)
        let startColumn = Int(cmark_node_get_start_column(node))
        let endLine = cmark_node_get_end_line(node)
        let endColumn = Int(cmark_node_get_end_column(node))

        switch type {
        case CMARK_NODE_PARAGRAPH:
            let map = lineMap(node)
            guard let last = map.entries.last else { return nil }
            let start = leafStart(node, map: map, line: startLine, column: startColumn)
            let range = start..<max(start, lineContentEnd(last.line))
            return Block(id: ids.make(), range: range, kind: .paragraph, inlines: leafInlines(node, map: map, bounds: range))

        case CMARK_NODE_HEADING:
            let map = lineMap(node)
            let isSetext = lipi_node_heading_is_setext(node) != 0
            let start = leafStart(node, map: map, line: startLine, column: startColumn)
            let end: Int
            if isSetext, let last = map.entries.last {
                end = lineContentEnd(last.line + 1)
            } else {
                end = lineContentEnd(startLine)
            }
            let range = start..<max(start, end)
            let level = Int(cmark_node_get_heading_level(node))
            var inlines = leafInlines(node, map: map, bounds: range)
            if headingAttributes { inlines = splitHeadingAttributes(inlines) }
            return Block(id: ids.make(), range: range, kind: .heading(level: level, isSetext: isSetext), inlines: inlines)

        case CMARK_NODE_CODE_BLOCK:
            return codeBlock(node, line: startLine, column: startColumn, endLine: endLine)

        case CMARK_NODE_HTML_BLOCK:
            let map = lineMap(node)
            let start = offset(line: startLine, column: startColumn - 1)
            let end = map.entries.last.map { lineContentEnd($0.line) } ?? lineContentEnd(startLine)
            return Block(id: ids.make(), range: start..<max(start, end),
                         kind: .htmlBlock(type: Int(lipi_node_get_html_block_type(node))))

        case CMARK_NODE_THEMATIC_BREAK:
            let start = offset(line: startLine, column: startColumn - 1)
            return Block(id: ids.make(), range: start..<max(start, lineContentEnd(startLine)), kind: .thematicBreak)

        case CMARK_NODE_BLOCK_QUOTE:
            return container(node, kind: .blockQuote, line: startLine, column: startColumn - 1,
                             endLine: endLine, endColumn: endColumn)

        case CMARK_NODE_LIST:
            let ordered = cmark_node_get_list_type(node) == CMARK_ORDERED_LIST
            let info = ListInfo(isOrdered: ordered,
                                start: ordered ? Int(cmark_node_get_list_start(node)) : 1,
                                delimiter: cmark_node_get_list_delim(node) == CMARK_PAREN_DELIM ? .parenthesis : .period,
                                bullet: ordered ? nil : UInt8(truncatingIfNeeded: lipi_node_get_bullet_char(node)),
                                isTight: cmark_node_get_list_tight(node) != 0)
            return container(node, kind: .list(info), line: startLine, column: startColumn - 1,
                             endLine: endLine, endColumn: endColumn)

        case CMARK_NODE_ITEM:
            var task: TaskState? = nil
            if lipi_node_is_tasklist(node) != 0 {
                task = cmark_gfm_extensions_get_tasklist_item_checked(node) ? .checked : .unchecked
            }
            return container(node, kind: .listItem(task: task), line: startLine, column: startColumn - 1,
                             endLine: endLine, endColumn: endColumn)

        case CMARK_NODE_FOOTNOTE_DEFINITION:
            let column = startColumn - 1 - Int(lipi_node_get_internal_offset(node))
            return container(node, kind: .footnoteDefinition(label: label(node)), line: startLine, column: column,
                             endLine: endLine, endColumn: endColumn)

        default:
            if lipi_node_get_ext_type(node) == LIPI_EXT_TABLE { return table(node) }
            return nil
        }
    }

    /// Start of a paragraph-like leaf: after any reference definitions that
    /// were removed from the front of its content.
    func leafStart(_ node: OpaquePointer, map: Converter.LineMap, line: Int32, column: Int) -> Int {
        let dropped = Int(lipi_node_get_dropped(node))
        if dropped > 0, !map.entries.isEmpty {
            return offset(in: map, contentOffset: dropped)
        }
        return offset(line: line, column: column - 1)
    }

    mutating func leafInlines(_ node: OpaquePointer, map: Converter.LineMap, bounds: Range<Int>) -> [Inline] {
        guard !map.entries.isEmpty else { return [] }
        let dropped = Int(lipi_node_get_dropped(node))
        return inlines(of: node, bounds: bounds) { [self] contentOffset in
            offset(in: map, contentOffset: contentOffset + dropped)
        }
    }

    /// The first byte of the four-column indent that opened an indented code block whose text
    /// starts at `offset`: the earliest whitespace byte on `line` from which only spaces and tabs
    /// lead to `offset` and whose column is at least four short of it. A tab shared with a
    /// container prefix stays outside the block.
    func indentStart(before offset: Int, line: Int32) -> Int {
        let lineStart = lineStart(line)
        var column = 0
        for i in lineStart..<offset { column = bytes[i] == 0x09 ? column + 4 - column % 4 : column + 1 }
        let target = column - 4
        var best = offset
        column = 0
        for i in lineStart..<offset {
            let byte = bytes[i]
            if byte == 0x20 || byte == 0x09 {
                if best == offset, column >= target { best = i }
            } else {
                best = offset
            }
            column = byte == 0x09 ? column + 4 - column % 4 : column + 1
        }
        return best
    }

    mutating func codeBlock(_ node: OpaquePointer, line: Int32, column: Int, endLine: Int32) -> Block {
        let map = lineMap(node)
        let fenced = lipi_node_code_is_fenced(node) != 0
        var start = offset(line: line, column: column - 1)
        if !fenced { start = indentStart(before: start, line: line) }
        var end = start
        var contentStart = start
        var contentEnd = start
        var closed = false
        if fenced {
            closed = (lipi_node_get_flags(node) & LIPI_FLAG_FENCE_CLOSED) != 0
            if closed {
                end = lineContentEnd(endLine)
                contentEnd = lineStart(endLine)
            } else if let last = map.entries.last {
                end = lineContentEnd(last.line)
                contentEnd = end
            } else {
                end = lineContentEnd(line)
                contentEnd = end
            }
            contentStart = map.entries.count > 1 ? lineStart(map.entries[1].line) : contentEnd
            contentStart = min(max(start, contentStart), max(start, contentEnd))
        } else {
            for entry in map.entries.reversed() {
                let lineStart = lineStart(entry.line)
                let contentEndOfLine = lineContentEnd(entry.line)
                let textStart = min(lineStart + Int(entry.prefix), contentEndOfLine)
                if hasNonBlank(textStart..<contentEndOfLine) {
                    end = contentEndOfLine
                    break
                }
            }
            if end < start { end = start }
            contentStart = start
            contentEnd = end
        }
        end = max(start, end)
        let info = CodeBlockInfo(isFenced: fenced,
                                 info: fenced ? string(cmark_node_get_fence_info(node)) : "",
                                 contentRange: contentStart..<max(contentStart, contentEnd),
                                 isClosed: closed)
        return Block(id: ids.make(), range: start..<end, kind: .codeBlock(info))
    }

    mutating func container(_ node: OpaquePointer, kind: BlockKind, line: Int32, column: Int,
                            endLine: Int32, endColumn: Int) -> Block {
        let start = offset(line: line, column: column)
        var children: [Block] = []
        var child = cmark_node_first_child(node)
        while let c = child {
            if let b = block(c) { children.append(b) }
            child = cmark_node_next(c)
        }
        // cmark's own end can include trailing blank lines; trim them, but never
        // end before the last child.
        var end = min(offset(line: endLine, column: endColumn), lineContentEnd(endLine))
        while end > start + 1 && isWhitespace(bytes[end - 1]) { end -= 1 }
        if let last = children.last { end = max(end, last.range.upperBound) }
        end = max(start, end)
        return Block(id: ids.make(), range: start..<end, kind: kind, children: children)
    }

    // MARK: Tables

    mutating func table(_ node: OpaquePointer) -> Block? {
        let columns = Int(cmark_gfm_extensions_get_table_columns(node))
        let raw = cmark_gfm_extensions_get_table_alignments(node)
        var alignments: [ColumnAlignment] = []
        alignments.reserveCapacity(columns)
        for i in 0..<columns {
            switch raw?[i] {
            case 0x6C: alignments.append(.left)
            case 0x63: alignments.append(.center)
            case 0x72: alignments.append(.right)
            default: alignments.append(.none)
            }
        }
        var rows: [Block] = []
        var child = cmark_node_first_child(node)
        while let c = child {
            if lipi_node_get_ext_type(c) == LIPI_EXT_TABLE_ROW { rows.append(tableRow(c)) }
            child = cmark_node_next(c)
        }
        guard let first = rows.first, let last = rows.last else { return nil }
        return Block(id: ids.make(), range: first.range.lowerBound..<max(first.range.lowerBound, last.range.upperBound),
                     kind: .table(alignments: alignments), children: rows)
    }

    mutating func tableRow(_ node: OpaquePointer) -> Block {
        let line = cmark_node_get_start_line(node)
        let isHeader = cmark_gfm_extensions_get_table_row_is_header(node) != 0
        let lineStart = lineStart(line)
        let contentEnd = lineContentEnd(line)
        var trimmedEnd = contentEnd
        while trimmedEnd > lineStart && isSpaceOrTab(bytes[trimmedEnd - 1]) { trimmedEnd -= 1 }
        var cells: [Block] = []
        var firstRawStart: Int? = nil
        var cursor = lineStart
        var child = cmark_node_first_child(node)
        while let cell = child {
            defer { child = cmark_node_next(cell) }
            guard lipi_node_get_ext_type(cell) == LIPI_EXT_TABLE_CELL else { continue }
            let a = min(max(lineStart, lineStart + Int(lipi_node_get_start(cell))), contentEnd)
            let b = min(max(a, lineStart + Int(lipi_node_get_end(cell))), contentEnd)
            if firstRawStart == nil { firstRawStart = a }
            var s = a, e = b
            while s < e && isSpaceOrTab(bytes[s]) { s += 1 }
            while e > s && isSpaceOrTab(bytes[e - 1]) { e -= 1 }
            if s < cursor {
                // A cell the extension padded onto a short row has no source; keep it at the row end.
                s = max(cursor, trimmedEnd)
                e = s
            }
            cursor = e
            // Cell text is the trimmed source with `\|` unescaped; map content
            // offsets back through that one transformation.
            var map: [Int] = []
            map.reserveCapacity(e - s + 1)
            var p = s
            while p < e {
                map.append(p)
                if bytes[p] == 0x5C && p + 1 < e && bytes[p + 1] == 0x7C { p += 2 } else { p += 1 }
            }
            map.append(e)
            let range = s..<e
            let inlines = inlines(of: cell, bounds: range) { contentOffset in
                map[min(max(contentOffset, 0), map.count - 1)]
            }
            cells.append(Block(id: ids.make(), range: range, kind: .tableCell, inlines: inlines))
        }
        var rowStart = cells.first?.range.lowerBound ?? lineStart
        if let raw = firstRawStart {
            var p = raw
            while p > lineStart && isSpaceOrTab(bytes[p - 1]) { p -= 1 }
            if p > lineStart && bytes[p - 1] == 0x7C { rowStart = p - 1 } else { rowStart = min(rowStart, p) }
        }
        var rowEnd = contentEnd
        while rowEnd > rowStart && isSpaceOrTab(bytes[rowEnd - 1]) { rowEnd -= 1 }
        if let last = cells.last { rowEnd = max(rowEnd, last.range.upperBound) }
        return Block(id: ids.make(), range: rowStart..<max(rowStart, rowEnd), kind: .tableRow(isHeader: isHeader), children: cells)
    }

    // MARK: Inlines

    mutating func inlines(of node: OpaquePointer, bounds: Range<Int>, map: (Int) -> Int) -> [Inline] {
        var out: [Inline] = []
        var child = cmark_node_first_child(node)
        while let c = child {
            if let inline = inline(c, bounds: bounds, map: map) { out.append(inline) }
            child = cmark_node_next(c)
        }
        return emoji ? splitEmoji(out) : out
    }

    mutating func inline(_ node: OpaquePointer, bounds: Range<Int>, map: (Int) -> Int) -> Inline? {
        let type = cmark_node_get_type(node)
        let kind: InlineKind
        switch type {
        case CMARK_NODE_TEXT: kind = .text(string(cmark_node_get_literal(node)))
        case CMARK_NODE_SOFTBREAK: kind = .softBreak
        case CMARK_NODE_LINEBREAK: kind = .lineBreak
        case CMARK_NODE_CODE: kind = .code(string(cmark_node_get_literal(node)))
        case CMARK_NODE_HTML_INLINE: kind = .html(string(cmark_node_get_literal(node)))
        case CMARK_NODE_EMPH: kind = .emphasis
        case CMARK_NODE_STRONG: kind = .strong
        case CMARK_NODE_LINK:
            kind = .link(destination: string(cmark_node_get_url(node)), title: string(cmark_node_get_title(node)),
                         isAutolink: (lipi_node_get_flags(node) & LIPI_FLAG_AUTOLINK) != 0)
        case CMARK_NODE_IMAGE:
            kind = .image(destination: string(cmark_node_get_url(node)), title: string(cmark_node_get_title(node)))
        case CMARK_NODE_FOOTNOTE_REFERENCE: kind = .footnoteReference(label: label(node))
        default:
            switch lipi_node_get_ext_type(node) {
            case LIPI_EXT_STRIKETHROUGH: kind = .strikethrough
            case LIPI_EXT_SUBSCRIPT: kind = .subscript
            case LIPI_EXT_SUPERSCRIPT: kind = .superscript
            case LIPI_EXT_HIGHLIGHT: kind = .highlight
            case LIPI_EXT_MATH:
                var text: UnsafePointer<CChar>? = nil
                var length: Int32 = 0
                var display: Int32 = 0
                lipi_math_get(node, &text, &length, &display)
                kind = .math(string(text, length: length), isDisplay: display != 0)
            default: return nil
            }
        }
        let s0 = Int(lipi_node_get_start(node))
        let e0 = max(s0, Int(lipi_node_get_end(node)))
        var start = map(s0)
        var end = map(e0)
        start = min(max(start, bounds.lowerBound), bounds.upperBound)
        end = min(max(end, start), bounds.upperBound)
        let range = start..<end
        let approximate = (lipi_node_get_flags(node) & LIPI_FLAG_APPROX) != 0
        let children = inlines(of: node, bounds: range, map: map)
        return Inline(id: ids.make(), range: range, kind: kind, children: children, isApproximate: approximate)
    }
}

// MARK: - Text-level syntax (emoji shortcodes, heading attributes)

extension Converter {
    /// Source bytes of `range` as an array.
    func slice(_ range: Range<Int>) -> ArraySlice<UInt8> {
        ArraySlice(bytes[range.clamped(to: 0..<count)])
    }

    /// Runs of adjacent text inlines (cmark splits text at special
    /// characters such as `:` and `-`): index ranges into `inlines` whose
    /// source spells their literal byte for byte.
    func exactTextRuns(_ inlines: [Inline]) -> [(indices: Range<Int>, range: Range<Int>, literal: String)] {
        var out: [(Range<Int>, Range<Int>, String)] = []
        var i = 0
        while i < inlines.count {
            guard case .text = inlines[i].kind, !inlines[i].isApproximate else { i += 1; continue }
            var j = i
            var literal = ""
            while j < inlines.count, case .text(let s) = inlines[j].kind, !inlines[j].isApproximate,
                  j == i || inlines[j].range.lowerBound == inlines[j - 1].range.upperBound {
                literal += s
                j += 1
            }
            let range = inlines[i].range.lowerBound..<inlines[j - 1].range.upperBound
            if slice(range).elementsEqual(literal.utf8) { out.append((i..<j, range, literal)) }
            i = j
        }
        return out
    }

    /// `:alias:` shortcodes inside text become `.emoji` inlines.
    mutating func splitEmoji(_ inlines: [Inline]) -> [Inline] {
        var result = inlines
        for run in exactTextRuns(inlines).reversed() {
            guard run.literal.utf8.count >= 3 else { continue }
            let found = EmojiShortcodes.matches(in: run.literal.utf8)
            guard !found.isEmpty else { continue }
            let base = run.range.lowerBound
            var pieces: [Inline] = []
            var p = base
            for (r, emoji) in found {
                let s = base + r.lowerBound, e = base + r.upperBound
                if s > p { pieces.append(textInline(p..<s)) }
                pieces.append(Inline(id: ids.make(), range: s..<e, kind: .emoji(emoji)))
                p = e
            }
            if p < run.range.upperBound { pieces.append(textInline(p..<run.range.upperBound)) }
            result.replaceSubrange(run.indices, with: pieces)
        }
        return result
    }

    mutating func textInline(_ range: Range<Int>) -> Inline {
        Inline(id: ids.make(), range: range, kind: .text(String(decoding: slice(range), as: UTF8.self)))
    }

    /// Pandoc `header_attributes`: a trailing `{#id .class key=value}` after
    /// whitespace ends a heading's text. It becomes an `.attributes` inline
    /// covering the whitespace and the braces.
    mutating func splitHeadingAttributes(_ inlines: [Inline]) -> [Inline] {
        guard let run = exactTextRuns(inlines).last, run.indices.upperBound == inlines.count else { return inlines }
        let text = Array(run.literal.utf8)
        guard text.last == 0x7D, let open = text.lastIndex(of: 0x7B), open > 0 else { return inlines }
        let inner = text[(open + 1)..<(text.count - 1)]
        guard Self.isAttributeList(inner) else { return inlines }
        var start = open
        while start > 0, text[start - 1] == 0x20 || text[start - 1] == 0x09 { start -= 1 }
        guard start < open, start > 0 else { return inlines }
        let base = run.range.lowerBound
        let pieces = [textInline(base..<(base + start)),
                      Inline(id: ids.make(), range: (base + start)..<run.range.upperBound,
                             kind: .attributes(String(decoding: inner, as: UTF8.self)))]
        var result = inlines
        result.replaceSubrange(run.indices, with: pieces)
        return result
    }

    /// `#id`, `.class`, `key=value` / `key="value"` and `-` tokens.
    static func isAttributeList(_ inner: ArraySlice<UInt8>) -> Bool {
        let tokens = inner.split(whereSeparator: { $0 == 0x20 || $0 == 0x09 })
        guard !tokens.isEmpty, !inner.contains(0x7B), !inner.contains(0x7D) else { return false }
        for t in tokens {
            guard let first = t.first else { return false }
            if first == 0x23 || first == 0x2E {
                if t.count < 2 { return false }
            } else if t.count == 1 && first == 0x2D {
                continue
            } else if let eq = t.firstIndex(of: 0x3D), eq > t.startIndex {
                continue
            } else {
                return false
            }
        }
        return true
    }
}
