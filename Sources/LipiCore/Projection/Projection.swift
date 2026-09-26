import CCmarkGFM

/// `Projection` maps `(SourceBuffer, AST, RevealSet)` to display blocks with
/// offset maps (PRD §6.1.1, §7.4 step "Project").
///
/// The projection is kept per top-level block ("entry"). An entry is rebuilt
/// only when its block was re-parsed (new `NodeID`) or its reveal state
/// changed; every other entry keeps its display blocks and only its absolute
/// start moves. Display blocks use entry-local source offsets, so a block's
/// layout cache key does not change when text before it is edited.
public struct ProjectedEntry: Sendable {
    public var id: NodeID
    /// Absolute start of the entry's span.
    public var start: Int
    public var length: Int
    var revealKey: Int
    /// Display blocks in order; their source ranges tile `0..<length`.
    public var blocks: [DisplayBlock]
}

public struct Projection: Sendable {
    public var preset: RevealPreset
    public private(set) var entries: [ProjectedEntry] = []
    public private(set) var reveal = RevealSet()
    /// Bytes covered; equals the document length after `update`.
    public private(set) var length = 0

    public struct UpdateResult: Sendable, Equatable {
        public var rebuilt = 0
        public var reused = 0
        /// Indices of entries whose display blocks changed.
        public var changedEntries: [Int] = []

        public init(rebuilt: Int = 0, reused: Int = 0, changedEntries: [Int] = []) {
            self.rebuilt = rebuilt
            self.reused = reused
            self.changedEntries = changedEntries
        }
    }

    public init(preset: RevealPreset = .balanced) {
        self.preset = preset
    }

    // MARK: Update

    /// Brings the projection in line with `index` (which must be clean) and
    /// `reveal`.
    @discardableResult
    public mutating func update(index: BlockIndex, rope: LipiRope, reveal: RevealSet) -> UpdateResult {
        var old: [NodeID: ProjectedEntry] = [:]
        old.reserveCapacity(entries.count)
        for e in entries { old[e.id] = e }

        var result = UpdateResult()
        var new: [ProjectedEntry] = []
        new.reserveCapacity(index.count)
        for i in index.entries.indices {
            let entry = index.entries[i]
            let start = index.start(of: i)
            let key = revealKey(for: entry.block.id, reveal: reveal)
            if !entry.isDirty, var kept = old[entry.block.id], kept.length == entry.length, kept.revealKey == key {
                kept.start = start
                new.append(kept)
                result.reused += 1
                continue
            }
            let blocks = build(entry: entry, start: start, rope: rope, reveal: reveal)
            new.append(ProjectedEntry(id: entry.block.id, start: start, length: entry.length, revealKey: key, blocks: blocks))
            result.changedEntries.append(new.count - 1)
            result.rebuilt += 1
        }
        if new.isEmpty {
            // An empty document still has one place to put the caret.
            if let kept = entries.first, entries.count == 1, kept.length == 0, kept.id == NodeID(rawValue: 0) {
                new = [kept]
                result.reused = 1
            } else {
                var builder = CellBuilder(bytes: UnsafeBufferPointer(start: nil, count: 0), start: 0)
                let cell = builder.finish(end: 0, resolve: .after)
                let block = DisplayBlock(id: NodeID(rawValue: 0), sourceRange: 0..<0, role: .paragraph, context: BlockContext(),
                                         isRevealed: false, cells: [cell])
                new = [ProjectedEntry(id: NodeID(rawValue: 0), start: 0, length: 0, revealKey: 0, blocks: [block])]
                result.changedEntries = [0]
                result.rebuilt = 1
            }
        }
        entries = new
        length = index.length
        self.reveal = reveal
        return result
    }

    private func revealKey(for id: NodeID, reveal: RevealSet) -> Int {
        if reveal.all { return 1 }
        guard reveal.entry == id, !reveal.isEmpty else { return 0 }
        var h = Hasher()
        h.combine(reveal)
        return h.finalize() | 2
    }

    private func build(entry: BlockEntry, start: Int, rope: LipiRope, reveal: RevealSet) -> [DisplayBlock] {
        var text = rope.string(in: start..<(start + entry.length))
        return text.withUTF8 { bytes in
            var projector = EntryProjector(bytes: bytes, entryStart: start, preset: preset, reveal: reveal)
            return projector.project(entry.block, spanLength: entry.length)
        }
    }

    // MARK: Lookup

    /// Index of the entry whose span contains absolute `offset`; the last
    /// entry for offsets at or past the end. Nil when empty.
    public func entryIndex(containing offset: Int) -> Int? {
        guard !entries.isEmpty else { return nil }
        var lo = 0, hi = entries.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if entries[mid].start <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Display position of an absolute source offset.
    public func position(forSource offset: Int) -> DisplayPosition? {
        guard let e = entryIndex(containing: offset) else { return nil }
        let entry = entries[e]
        let local = min(max(offset - entry.start, 0), entry.length)
        let b = blockIndex(in: entry, containingLocal: local)
        let block = entry.blocks[b]
        let c = block.cellIndex(containingSource: local)
        let cell = block.cells[c]
        return DisplayPosition(entry: e, block: b, cell: c, offset: cell.displayOffset(forSource: local))
    }

    /// Absolute source offset of a display position.
    public func sourceOffset(for position: DisplayPosition) -> Int {
        let entry = entries[position.entry]
        let cell = entry.blocks[position.block].cells[position.cell]
        return entry.start + cell.sourceOffset(forDisplay: position.offset)
    }

    func blockIndex(in entry: ProjectedEntry, containingLocal offset: Int) -> Int {
        let blocks = entry.blocks
        var lo = 0, hi = blocks.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if blocks[mid].sourceRange.lowerBound <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// All display blocks with their absolute entry start, in order.
    public var blocks: [(start: Int, block: DisplayBlock)] {
        var out: [(Int, DisplayBlock)] = []
        for e in entries { for b in e.blocks { out.append((e.start, b)) } }
        return out
    }

    /// Display text of the whole document, blocks separated by newlines (tests).
    public var displayText: String {
        var lines: [String] = []
        for e in entries {
            for b in e.blocks {
                if b.table != nil {
                    lines.append(b.cells.map(\.text).joined(separator: "\t"))
                } else {
                    lines.append(b.cells.first?.text ?? "")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Entry projection

/// Builds the display blocks of one top-level block.
struct EntryProjector {
    let bytes: UnsafeBufferPointer<UInt8>
    let entryStart: Int
    let preset: RevealPreset
    let reveal: RevealSet
    var blocks: [DisplayBlock] = []
    /// Next local source byte not yet owned by a display block.
    var cursor = 0

    init(bytes: UnsafeBufferPointer<UInt8>, entryStart: Int, preset: RevealPreset, reveal: RevealSet) {
        self.bytes = bytes
        self.entryStart = entryStart
        self.preset = preset
        self.reveal = reveal
    }

    var showAll: Bool { reveal.all }
    func isRevealed(_ id: NodeID) -> Bool { showAll || reveal.blocks.contains(id) }
    func isInlineRevealed(_ id: NodeID) -> Bool {
        showAll || preset.inlineDelimiters == .always || reveal.inlines.contains(id)
    }
    func isEscapeRevealed(localOffset: Int) -> Bool { showAll || reveal.escapes.contains(entryStart + localOffset) }
    /// Container markers are copied into the text when the preset puts them
    /// inline and the block is revealed, or in source mode.
    func markersInline(revealed: Bool) -> Bool { showAll || (preset.blockMarkers == .inline && revealed) }

    mutating func project(_ block: Block, spanLength: Int) -> [DisplayBlock] {
        var context = BlockContext()
        walk(block, context: &context, containerRevealed: false, firstLeafContainer: nil)
        if blocks.isEmpty {
            var builder = CellBuilder(bytes: bytes, start: 0)
            let cell = builder.finish(end: spanLength, resolve: .after)
            blocks.append(DisplayBlock(id: block.id, sourceRange: 0..<spanLength, role: .paragraph, context: BlockContext(),
                                       isRevealed: false, cells: [cell]))
        } else if cursor < spanLength {
            // Trailing terminator and blank lines belong to the last block.
            extendLastBlock(to: spanLength)
        }
        return blocks
    }

    private mutating func extendLastBlock(to end: Int) {
        var last = blocks.removeLast()
        var cell = last.cells.removeLast()
        var builder = CellBuilder(bytes: bytes, resuming: cell)
        cell = builder.finish(end: end, resolve: .before)
        last.cells.append(cell)
        last = DisplayBlock(id: last.id, sourceRange: last.sourceRange.lowerBound..<end, role: last.role,
                            context: last.context, isRevealed: last.isRevealed, cells: last.cells, table: last.table)
        blocks.append(last)
        cursor = end
    }

    /// `firstLeafContainer`: a list item or footnote definition whose first
    /// leaf has not been emitted yet (it carries the marker).
    private mutating func walk(_ block: Block, context: inout BlockContext, containerRevealed: Bool,
                               firstLeafContainer: Block?) {
        switch block.kind {
        case .blockQuote:
            var inner = context
            inner.quoteDepth += 1
            let revealed = containerRevealed || isRevealed(block.id)
            if block.children.isEmpty {
                emitEmptyLeaf(block, context: inner, revealed: revealed, firstLeafContainer: firstLeafContainer)
                return
            }
            var first = firstLeafContainer
            for child in block.children {
                walk(child, context: &inner, containerRevealed: revealed, firstLeafContainer: first)
                first = nil
            }
        case .list(let info):
            var inner = context
            inner.listDepth += 1
            inner.isLoose = context.isLoose || !info.isTight
            var ordinal = 0
            for child in block.children {
                ordinal += 1
                var itemContext = inner
                if case .listItem(let task) = child.kind {
                    let literal = markerLiteral(of: child.range, task: task)
                    itemContext.marker = ListMarker(literal: literal, isOrdered: info.isOrdered, ordinal: ordinal,
                                                    number: info.start + ordinal - 1, task: task)
                }
                walk(child, context: &itemContext, containerRevealed: containerRevealed, firstLeafContainer: child)
            }
        case .listItem, .footnoteDefinition:
            var inner = context
            if case .footnoteDefinition(let label) = block.kind { inner.footnoteLabel = label }
            let revealed = containerRevealed || isRevealed(block.id)
            if block.children.isEmpty {
                emitEmptyLeaf(block, context: inner, revealed: revealed, firstLeafContainer: block)
                return
            }
            var first: Block? = block
            for child in block.children {
                walk(child, context: &inner, containerRevealed: first != nil ? revealed : containerRevealed,
                     firstLeafContainer: first)
                first = nil
                inner.marker = nil
                inner.footnoteLabel = nil
            }
        case .table(let alignments):
            emitTable(block, alignments: alignments, context: context, revealed: containerRevealed)
        case .tableRow, .tableCell:
            break
        default:
            emitLeaf(block, context: context, revealed: containerRevealed || isRevealed(block.id),
                     firstLeafContainer: firstLeafContainer)
        }
    }

    /// `-`, `1.`, `- [ ]` as written at the start of an item.
    private func markerLiteral(of range: Range<Int>, task: TaskState?) -> String {
        let end = min(range.upperBound, range.lowerBound + 24)
        var q = range.lowerBound
        while q < end, !isSpace(bytes[q]), bytes[q] != 0x0A { q += 1 }
        var literal = String(decoding: UnsafeBufferPointer(rebasing: bytes[range.lowerBound..<q]), as: UTF8.self)
        if task != nil {
            var r = q
            while r < end, isSpace(bytes[r]) { r += 1 }
            if r + 3 <= end, bytes[r] == 0x5B, bytes[r + 2] == 0x5D {
                literal += " " + String(decoding: UnsafeBufferPointer(rebasing: bytes[r..<(r + 3)]), as: UTF8.self)
            }
        }
        return literal
    }

    // MARK: Leaves

    private mutating func emitEmptyLeaf(_ block: Block, context: BlockContext, revealed: Bool, firstLeafContainer: Block?) {
        var builder = CellBuilder(bytes: bytes, start: cursor)
        emitPrefix(&builder, upTo: block.range.upperBound, revealed: revealed)
        let cell = builder.finish(end: block.range.upperBound, resolve: .after)
        blocks.append(DisplayBlock(id: block.id, sourceRange: cursor..<block.range.upperBound, role: .paragraph,
                                   context: context, isRevealed: revealed, cells: [cell]))
        cursor = block.range.upperBound
    }

    /// Hides (or, with inline markers, shows) the structure between the
    /// previous block and `contentStart`: terminators, blank lines, container
    /// prefixes and this block's own marker.
    private func emitPrefix(_ builder: inout CellBuilder, upTo contentStart: Int, revealed: Bool) {
        let start = builder.cursor
        guard contentStart > start else { return }
        if markersInline(revealed: revealed) {
            // Everything up to the last line start stays hidden; the markers
            // on the block's own first line become syntax.
            var lineStart = contentStart
            while lineStart > start, bytes[lineStart - 1] != 0x0A { lineStart -= 1 }
            builder.hide(start..<lineStart, .before)
            builder.copy(lineStart..<contentStart, .syntax)
        } else {
            builder.hide(start..<contentStart, .after)
        }
    }

    private mutating func emitLeaf(_ block: Block, context: BlockContext, revealed: Bool, firstLeafContainer: Block?) {
        let r = block.range
        var builder = CellBuilder(bytes: bytes, start: cursor)
        var role: BlockRole = .paragraph
        let end = max(r.upperBound, cursor)

        switch block.kind {
        case .paragraph:
            emitPrefix(&builder, upTo: r.lowerBound, revealed: revealed)
            emitInlines(block.inlines, &builder, style: [])
            builder.hide(builder.cursor..<end, .before)
        case .heading(let level, let isSetext):
            role = .heading(level: level)
            let contentStart = block.inlines.first?.range.lowerBound ?? r.upperBound
            let contentEnd = block.inlines.last?.range.upperBound ?? contentStart
            if isSetext {
                emitPrefix(&builder, upTo: contentStart, revealed: revealed)
            } else {
                emitPrefix(&builder, upTo: r.lowerBound, revealed: revealed)
                // `# ` lives in the gutter; the Typora preset shows it inline.
                if markersInline(revealed: revealed) {
                    builder.copy(r.lowerBound..<contentStart, .syntax)
                } else {
                    builder.hide(r.lowerBound..<contentStart, .after)
                }
            }
            emitInlines(block.inlines, &builder, style: [])
            // Closing `##` or the setext underline.
            if contentEnd < end {
                if revealed { builder.copy(contentEnd..<end, .syntax) } else { builder.hide(contentEnd..<end, .before) }
            }
        case .codeBlock(let info):
            role = .code(info: info.info, isFenced: info.isFenced)
            emitPrefix(&builder, upTo: r.lowerBound, revealed: revealed)
            if info.isFenced {
                var contentEnd = info.contentRange.upperBound
                if info.isClosed, contentEnd > info.contentRange.lowerBound, bytes[contentEnd - 1] == 0x0A {
                    contentEnd -= 1
                    if contentEnd > info.contentRange.lowerBound, bytes[contentEnd - 1] == 0x0D { contentEnd -= 1 }
                }
                let opening = r.lowerBound..<info.contentRange.lowerBound
                if revealed { builder.copy(opening, .syntax) } else { builder.hide(opening, .after) }
                builder.copy(info.contentRange.lowerBound..<contentEnd, .code)
                let closing = contentEnd..<end
                if revealed { builder.copy(closing, .syntax) } else { builder.hide(closing, .before) }
            } else {
                emitIndentedCode(r, &builder)
            }
        case .htmlBlock:
            role = .html
            emitPrefix(&builder, upTo: r.lowerBound, revealed: revealed)
            builder.copy(r, .html)
        case .thematicBreak:
            role = .thematicBreak
            emitPrefix(&builder, upTo: r.lowerBound, revealed: revealed)
            if revealed { builder.copy(r, .syntax) } else { builder.hide(r, .before) }
        case .frontMatter(let kind):
            role = .frontMatter
            emitPrefix(&builder, upTo: r.lowerBound, revealed: revealed)
            emitFrontMatter(r, kind: kind, &builder, revealed: revealed)
        case .linkReferenceDefinition:
            role = .linkReferenceDefinition
            emitPrefix(&builder, upTo: r.lowerBound, revealed: revealed)
            builder.copy(r, .syntax)
        default:
            emitPrefix(&builder, upTo: r.lowerBound, revealed: revealed)
            emitInlines(block.inlines, &builder, style: [])
        }
        let cell = builder.finish(end: end, resolve: .before)
        blocks.append(DisplayBlock(id: block.id, sourceRange: cursor..<end, role: role, context: context,
                                   isRevealed: revealed, cells: [cell]))
        cursor = end
    }

    private func emitIndentedCode(_ r: Range<Int>, _ builder: inout CellBuilder) {
        var p = r.lowerBound
        while p < r.upperBound {
            // Up to four columns of indentation are structure.
            var q = p
            var columns = 0
            while q < r.upperBound, columns < 4 {
                if bytes[q] == 0x20 { columns += 1; q += 1 }
                else if bytes[q] == 0x09 { columns = 4; q += 1 }
                else { break }
            }
            builder.hide(p..<q, .after)
            var lineEnd = q
            while lineEnd < r.upperBound, bytes[lineEnd] != 0x0A { lineEnd += 1 }
            if lineEnd < r.upperBound { lineEnd += 1 }
            builder.copy(q..<lineEnd, .code)
            p = lineEnd
        }
    }

    private func emitFrontMatter(_ r: Range<Int>, kind: FrontMatterKind, _ builder: inout CellBuilder, revealed: Bool) {
        var firstLineEnd = r.lowerBound
        while firstLineEnd < r.upperBound, bytes[firstLineEnd] != 0x0A { firstLineEnd += 1 }
        if firstLineEnd < r.upperBound { firstLineEnd += 1 }
        var lastLineStart = r.upperBound
        while lastLineStart > firstLineEnd, bytes[lastLineStart - 1] != 0x0A { lastLineStart -= 1 }
        let lastLine = Array(UnsafeBufferPointer(rebasing: bytes[lastLineStart..<r.upperBound]))
        let hasClosing = lastLineStart > firstLineEnd && FrontMatter.isDelimiter(lastLine, kind: kind, closing: true)
        var contentEnd = r.upperBound
        if hasClosing {
            contentEnd = lastLineStart - 1
            if contentEnd > firstLineEnd, bytes[contentEnd - 1] == 0x0D { contentEnd -= 1 }
        }
        let opening = r.lowerBound..<min(firstLineEnd, contentEnd)
        if revealed { builder.copy(opening, .syntax) } else { builder.hide(opening, .after) }
        builder.copy(opening.upperBound..<max(opening.upperBound, contentEnd), .code)
        if hasClosing {
            if revealed { builder.copy(contentEnd..<r.upperBound, .syntax) } else { builder.hide(contentEnd..<r.upperBound, .before) }
        }
    }

    // MARK: Tables

    private mutating func emitTable(_ block: Block, alignments: [ColumnAlignment], context: BlockContext, revealed: Bool) {
        let columns = max(alignments.count, 1)
        var cells: [DisplayCell] = []
        var rows = 0
        let blockStart = cursor
        for row in block.children {
            guard case .tableRow = row.kind else { continue }
            rows += 1
            var rowCells = row.children.filter { if case .tableCell = $0.kind { return true } else { return false } }
            if rowCells.count > columns { rowCells.removeLast(rowCells.count - columns) }
            let rowEnd = max(row.range.upperBound, rowCells.last?.range.upperBound ?? row.range.upperBound)
            for column in 0..<columns {
                var builder = CellBuilder(bytes: bytes, start: cursor)
                if column < rowCells.count {
                    let cell = rowCells[column]
                    emitPrefix(&builder, upTo: cell.range.lowerBound, revealed: revealed)
                    emitInlines(cell.inlines, &builder, style: [])
                    let cellEnd = max(cell.range.upperBound, builder.cursor)
                    cells.append(builder.finish(end: cellEnd, resolve: .before))
                    cursor = cellEnd
                } else {
                    // A short row: the padded cell sits at the row end.
                    builder.hide(cursor..<rowEnd, .after)
                    cells.append(builder.finish(end: rowEnd, resolve: .after))
                    cursor = rowEnd
                }
            }
        }
        let end = max(block.range.upperBound, cursor)
        if cells.isEmpty {
            var builder = CellBuilder(bytes: bytes, start: cursor)
            cells.append(builder.finish(end: end, resolve: .after))
            rows = 1
        } else if cursor < end {
            var last = cells.removeLast()
            var builder = CellBuilder(bytes: bytes, resuming: last)
            last = builder.finish(end: end, resolve: .before)
            cells.append(last)
        }
        cursor = end
        blocks.append(DisplayBlock(id: block.id, sourceRange: blockStart..<end, role: .table, context: context,
                                   isRevealed: revealed, cells: cells,
                                   table: TableShape(alignments: alignments, columns: columns, rows: rows)))
    }

    // MARK: Inlines

    private func emitInlines(_ inlines: [Inline], _ builder: inout CellBuilder, style: InlineStyle) {
        for inline in inlines { emitInline(inline, &builder, style: style) }
    }

    private func emitInline(_ inline: Inline, _ builder: inout CellBuilder, style: InlineStyle) {
        let r = inline.range
        if r.lowerBound > builder.cursor { builder.hide(builder.cursor..<r.lowerBound, .before) }
        switch inline.kind {
        case .text(let literal):
            emitText(r, literal: literal, approximate: inline.isApproximate, &builder, style: style)
        case .softBreak:
            builder.replace(r, with: .space, style: style)
        case .lineBreak:
            // `  \n` or `\\\n`, possibly followed by the next line's container prefix.
            var nl = r.lowerBound
            while nl < r.upperBound, bytes[nl] != 0x0A, bytes[nl] != 0x0D { nl += 1 }
            var nlEnd = nl
            if nlEnd < r.upperBound, bytes[nlEnd] == 0x0D { nlEnd += 1 }
            if nlEnd < r.upperBound, bytes[nlEnd] == 0x0A { nlEnd += 1 }
            if isInlineRevealed(inline.id) {
                builder.copy(r.lowerBound..<nl, style.union(.syntax).union(.lineBreak))
            } else {
                builder.hide(r.lowerBound..<nl, .before)
            }
            if nl < nlEnd { builder.replace(nl..<nlEnd, with: .newline, style: style) }
            builder.hide(nlEnd..<r.upperBound, .after)
        case .code:
            emitDelimited(inline, &builder, delimiter: 0x60, style: style.union(.code), max: Int.max)
        case .math(_, let isDisplay):
            emitDelimited(inline, &builder, delimiter: 0x24, style: style.union(.math), max: isDisplay ? 2 : 1)
        case .html:
            builder.copy(r, style.union(.html))
        case .emphasis:
            emitContainer(inline, &builder, style: style.union(.emphasis))
        case .strong:
            emitContainer(inline, &builder, style: style.union(.strong))
        case .strikethrough:
            emitContainer(inline, &builder, style: style.union(.strikethrough))
        case .footnoteReference:
            let revealed = isInlineRevealed(inline.id)
            // `[^label]`
            let labelStart = min(r.lowerBound + 2, r.upperBound)
            let labelEnd = max(labelStart, r.upperBound - 1)
            if revealed {
                builder.copy(r.lowerBound..<labelStart, style.union(.syntax))
                builder.copy(labelStart..<labelEnd, style.union(.footnoteReference))
                builder.copy(labelEnd..<r.upperBound, style.union(.syntax))
            } else {
                builder.hide(r.lowerBound..<labelStart, .after)
                builder.copy(labelStart..<labelEnd, style.union(.footnoteReference))
                builder.hide(labelEnd..<r.upperBound, .after)
            }
        case .link(_, _, let isAutolink):
            if isAutolink {
                emitContainer(inline, &builder, style: style.union(.link), delimitersAlwaysVisible: true)
            } else {
                emitLink(inline, &builder, style: style.union(.link))
            }
        case .image:
            emitLink(inline, &builder, style: style.union(.image))
        }
        if builder.cursor < r.upperBound { builder.hide(builder.cursor..<r.upperBound, .before) }
    }

    /// Emphasis-like nodes: bytes not covered by children are delimiters.
    private func emitContainer(_ inline: Inline, _ builder: inout CellBuilder, style: InlineStyle,
                               delimitersAlwaysVisible: Bool = false) {
        let r = inline.range
        let revealed = delimitersAlwaysVisible || isInlineRevealed(inline.id)
        let firstChild = inline.children.first?.range.lowerBound ?? r.upperBound
        emitSyntax(r.lowerBound..<firstChild, &builder, revealed: revealed, style: style, resolve: .after)
        for child in inline.children {
            if child.range.lowerBound > builder.cursor {
                emitSyntax(builder.cursor..<child.range.lowerBound, &builder, revealed: revealed, style: style, resolve: .after)
            }
            emitInline(child, &builder, style: style)
        }
        emitSyntax(builder.cursor..<r.upperBound, &builder, revealed: revealed, style: style, resolve: .after)
    }

    private func emitSyntax(_ range: Range<Int>, _ builder: inout CellBuilder, revealed: Bool, style: InlineStyle,
                            resolve: MapSegment.Resolve) {
        guard !range.isEmpty else { return }
        if revealed { builder.copy(range, style.union(.syntax)) } else { builder.hide(range, resolve) }
    }

    /// Code spans and math: `n` delimiter bytes on each side.
    private func emitDelimited(_ inline: Inline, _ builder: inout CellBuilder, delimiter: UInt8, style: InlineStyle, max: Int) {
        let r = inline.range
        var n = 0
        while r.lowerBound + n < r.upperBound, bytes[r.lowerBound + n] == delimiter, n < max { n += 1 }
        let open = r.lowerBound..<min(r.lowerBound + n, r.upperBound)
        var closeStart = r.upperBound
        var m = 0
        while closeStart > open.upperBound, bytes[closeStart - 1] == delimiter, m < n { closeStart -= 1; m += 1 }
        let close = closeStart..<r.upperBound
        let revealed = isInlineRevealed(inline.id)
        emitSyntax(open, &builder, revealed: revealed, style: style, resolve: .after)
        builder.copy(open.upperBound..<close.lowerBound, style)
        emitSyntax(close, &builder, revealed: revealed, style: style, resolve: .after)
    }

    /// `[label](destination "title")`, `![alt](src)`, `[label][ref]`, `[label]`.
    private func emitLink(_ inline: Inline, _ builder: inout CellBuilder, style: InlineStyle) {
        let r = inline.range
        let revealed = isInlineRevealed(inline.id)
        let expanded = showAll || reveal.expandedLinks.contains(inline.id)
            || (revealed && preset.linkDestination == .fullOnEntry)
        let isImage = r.lowerBound < r.upperBound && bytes[r.lowerBound] == 0x21
        let labelStart = inline.children.first?.range.lowerBound ?? min(r.lowerBound + (isImage ? 2 : 1), r.upperBound)
        let labelEnd = inline.children.last?.range.upperBound ?? labelStart
        // Position after the `]` closing the label.
        var bracket = labelEnd
        while bracket < r.upperBound, bytes[bracket] != 0x5D { bracket += 1 }
        if bracket < r.upperBound { bracket += 1 }
        let destination = bracket..<r.upperBound

        emitSyntax(r.lowerBound..<labelStart, &builder, revealed: revealed, style: style, resolve: .after)
        for child in inline.children {
            if child.range.lowerBound > builder.cursor {
                emitSyntax(builder.cursor..<child.range.lowerBound, &builder, revealed: revealed, style: style, resolve: .after)
            }
            emitInline(child, &builder, style: style)
        }
        emitSyntax(builder.cursor..<bracket, &builder, revealed: revealed, style: style, resolve: .after)
        guard !destination.isEmpty else { return }
        if expanded {
            builder.copy(destination, style.union(.syntax))
        } else if revealed || (preset.linkDestination == .alwaysChip && style.contains(.link)) {
            builder.replace(destination, with: .chip, style: style.union(.chip))
        } else {
            builder.hide(destination, .after)
        }
    }

    /// Text with escapes and entities folded to the characters they stand for.
    private func emitText(_ r: Range<Int>, literal: String, approximate: Bool, _ builder: inout CellBuilder,
                          style: InlineStyle) {
        guard !approximate, !r.isEmpty else { builder.copy(r, style); return }
        // Fast path: no `\`, `&` or NUL means no transformation.
        var plain = true
        for p in r where bytes[p] == 0x5C || bytes[p] == 0x26 || bytes[p] == 0 { plain = false; break }
        if plain { builder.copy(r, style); return }

        let mark = builder.mark()
        var s = r.lowerBound
        var producedLiteral: [UInt8] = []
        producedLiteral.reserveCapacity(r.count)
        var p = r.lowerBound
        let n = r.upperBound
        var out = [UInt8](repeating: 0, count: 16)
        while p < n {
            let b = bytes[p]
            if b == 0x5C, p + 1 < n, TextScanner.isASCIIPunctuation(bytes[p + 1]) {
                flush(&builder, s..<p, style, &producedLiteral)
                if isEscapeRevealed(localOffset: p) {
                    builder.copy(p..<(p + 1), style.union(.syntax))
                } else {
                    builder.hide(p..<(p + 1), .before)
                }
                builder.copy((p + 1)..<(p + 2), style)
                producedLiteral.append(bytes[p + 1])
                p += 2
                s = p
            } else if b == 0x26 {
                var outLen: Int32 = 0
                let consumed = out.withUnsafeMutableBufferPointer { o in
                    lipi_decode_entity(bytes.baseAddress! + p, Int32(min(n - p, 40)), o.baseAddress, 16, &outLen)
                }
                if consumed > 0 {
                    flush(&builder, s..<p, style, &producedLiteral)
                    let decoded = Array(out[0..<Int(outLen)])
                    if isEscapeRevealed(localOffset: p) {
                        builder.copy(p..<(p + Int(consumed)), style.union(.syntax))
                    } else {
                        builder.replace(p..<(p + Int(consumed)), withBytes: decoded, style: style)
                    }
                    producedLiteral.append(contentsOf: decoded)
                    p += Int(consumed)
                    s = p
                } else {
                    p += 1
                }
            } else if b == 0 {
                flush(&builder, s..<p, style, &producedLiteral)
                builder.replace(p..<(p + 1), with: .replacementCharacter, style: style)
                producedLiteral.append(contentsOf: [0xEF, 0xBF, 0xBD])
                p += 1
                s = p
            } else {
                p += 1
            }
        }
        flush(&builder, s..<n, style, &producedLiteral)
        // The parser's literal is the ground truth; if our scan disagrees
        // (an unusual construct), show the raw bytes rather than mislead.
        if !literalMatches(producedLiteral, literal) {
            builder.reset(to: mark)
            builder.copy(r, style)
        }
    }

    private func flush(_ builder: inout CellBuilder, _ range: Range<Int>, _ style: InlineStyle, _ literal: inout [UInt8]) {
        guard !range.isEmpty else { return }
        builder.copy(range, style)
        literal.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[range]))
    }

    private func literalMatches(_ produced: [UInt8], _ literal: String) -> Bool {
        var literal = literal
        return literal.withUTF8 { l in
            if l.count == produced.count { return l.elementsEqual(produced) }
            // cmark strips leading/trailing spaces of line-final text; accept
            // a produced literal that has the parser's as a trimmed core.
            return trimmed(produced).elementsEqual(l)
        }
    }

    private func trimmed(_ b: [UInt8]) -> ArraySlice<UInt8> {
        var lo = 0, hi = b.count
        while lo < hi, b[lo] == 0x20 || b[lo] == 0x09 { lo += 1 }
        while hi > lo, b[hi - 1] == 0x20 || b[hi - 1] == 0x09 { hi -= 1 }
        return b[lo..<hi]
    }

    @inline(__always) private func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 }
}

// MARK: - Cell builder

/// Accumulates display text, style runs and map segments for one cell.
struct CellBuilder {
    enum Replacement {
        case space, newline, chip, replacementCharacter
        var bytes: [UInt8] {
            switch self {
            case .space: return [0x20]
            case .newline: return [0x0A]
            case .chip: return [0xEF, 0xBF, 0xBC]           // U+FFFC OBJECT REPLACEMENT CHARACTER
            case .replacementCharacter: return [0xEF, 0xBF, 0xBD]
            }
        }
    }

    struct Mark {
        var text: Int
        var utf16: Int
        var segments: Int
        var runs: Int
        var cursor: Int
    }

    let bytes: UnsafeBufferPointer<UInt8>
    let start: Int
    private(set) var cursor: Int
    private var text: [UInt8] = []
    private var utf16 = 0
    private var segments: [MapSegment] = []
    private var runs: [StyleRun] = []

    init(bytes: UnsafeBufferPointer<UInt8>, start: Int) {
        self.bytes = bytes
        self.start = start
        cursor = start
    }

    /// Continues a finished cell so more source can be appended to it.
    init(bytes: UnsafeBufferPointer<UInt8>, resuming cell: DisplayCell) {
        self.bytes = bytes
        start = cell.sourceRange.lowerBound
        cursor = cell.sourceRange.upperBound
        text = Array(cell.text.utf8)
        utf16 = cell.map.displayLength
        segments = cell.map.segments
        runs = cell.runs
    }

    func mark() -> Mark { Mark(text: text.count, utf16: utf16, segments: segments.count, runs: runs.count, cursor: cursor) }

    mutating func reset(to m: Mark) {
        text.removeSubrange(m.text...)
        utf16 = m.utf16
        segments.removeSubrange(m.segments...)
        runs.removeSubrange(m.runs...)
        cursor = m.cursor
    }

    private mutating func fillGap(to offset: Int) {
        if offset > cursor { hide(cursor..<offset, .before) }
    }

    mutating func hide(_ r: Range<Int>, _ resolve: MapSegment.Resolve) {
        fillGap(to: r.lowerBound)
        guard !r.isEmpty else { return }
        segments.append(MapSegment(sourceStart: Int32(r.lowerBound), sourceLength: Int32(r.count), displayStart: Int32(utf16),
                                   displayLength: 0, displayStartUTF8: Int32(text.count), kind: .hidden, resolve: resolve,
                                   isASCII: true))
        cursor = r.upperBound
    }

    mutating func copy(_ r: Range<Int>, _ style: InlineStyle) {
        fillGap(to: r.lowerBound)
        guard !r.isEmpty else { return }
        var units = 0
        var ascii = true
        for p in r {
            let b = bytes[p]
            if b >= 0x80 { ascii = false }
            if b & 0xC0 != 0x80 { units += b >= 0xF0 ? 2 : 1 }
        }
        segments.append(MapSegment(sourceStart: Int32(r.lowerBound), sourceLength: Int32(r.count), displayStart: Int32(utf16),
                                   displayLength: Int32(units), displayStartUTF8: Int32(text.count), kind: .copied,
                                   resolve: .before, isASCII: ascii))
        text.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[r]))
        addRun(utf16..<(utf16 + units), style)
        utf16 += units
        cursor = r.upperBound
    }

    mutating func replace(_ r: Range<Int>, with replacement: Replacement, style: InlineStyle) {
        replace(r, withBytes: replacement.bytes, style: style)
    }

    mutating func replace(_ r: Range<Int>, withBytes replacement: [UInt8], style: InlineStyle) {
        fillGap(to: r.lowerBound)
        guard !r.isEmpty else { return }
        var units = 0
        for b in replacement where b & 0xC0 != 0x80 { units += b >= 0xF0 ? 2 : 1 }
        segments.append(MapSegment(sourceStart: Int32(r.lowerBound), sourceLength: Int32(r.count), displayStart: Int32(utf16),
                                   displayLength: Int32(units), displayStartUTF8: Int32(text.count), kind: .replaced,
                                   resolve: .before, isASCII: false))
        text.append(contentsOf: replacement)
        addRun(utf16..<(utf16 + units), style)
        utf16 += units
        cursor = r.upperBound
    }

    private mutating func addRun(_ range: Range<Int>, _ style: InlineStyle) {
        guard !range.isEmpty else { return }
        if let last = runs.last, last.style == style, last.range.upperBound == range.lowerBound {
            runs[runs.count - 1].range = last.range.lowerBound..<range.upperBound
        } else {
            runs.append(StyleRun(range: range, style: style))
        }
    }

    /// Closes the cell at `end`, hiding any bytes not yet accounted for.
    mutating func finish(end: Int, resolve: MapSegment.Resolve) -> DisplayCell {
        if end > cursor { hide(cursor..<end, resolve) }
        let map = OffsetMap(segments: segments, sourceRange: start..<max(end, cursor), displayLength: utf16,
                            displayLengthUTF8: text.count)
        return DisplayCell(sourceRange: start..<max(end, cursor), text: String(decoding: text, as: UTF8.self), runs: runs, map: map)
    }
}
