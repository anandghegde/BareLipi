/// Source-mode projection (PRD §6.2): every byte of an entry is shown as
/// written, in one display block per entry, with syntax colouring taken
/// from the AST. The offset map is the identity except for two structural
/// cases: a `\r` before `\n` is hidden (the pair is one line break), and a
/// non-final entry's last line terminator is hidden because the block
/// boundary already breaks the line.
struct SourceEntryProjector {
    let bytes: UnsafeBufferPointer<UInt8>
    let isLastEntry: Bool
    /// One style per source byte of the entry.
    private var styles: [InlineStyle]

    init(bytes: UnsafeBufferPointer<UInt8>, isLastEntry: Bool) {
        self.bytes = bytes
        self.isLastEntry = isLastEntry
        styles = [InlineStyle](repeating: [], count: bytes.count)
    }

    mutating func project(_ block: Block, spanLength: Int) -> [DisplayBlock] {
        paint(block)
        // The terminator of a non-final entry is the block boundary.
        var visibleEnd = spanLength
        if !isLastEntry, visibleEnd > 0, bytes[visibleEnd - 1] == 0x0A {
            visibleEnd -= 1
            if visibleEnd > 0, bytes[visibleEnd - 1] == 0x0D { visibleEnd -= 1 }
        }
        var builder = CellBuilder(bytes: bytes, start: 0)
        var p = 0
        while p < visibleEnd {
            if bytes[p] == 0x0D, p + 1 < spanLength, bytes[p + 1] == 0x0A {
                builder.hide(p..<(p + 1), .before)
                p += 1
                continue
            }
            let style = styles[p]
            var q = p + 1
            while q < visibleEnd, styles[q] == style, bytes[q] != 0x0D { q += 1 }
            builder.copy(p..<q, style)
            p = q
        }
        let cell = builder.finish(end: spanLength, resolve: .before)
        return [DisplayBlock(id: block.id, sourceRange: 0..<spanLength, role: .paragraph, context: BlockContext(),
                             isRevealed: true, cells: [cell])]
    }

    // MARK: Painting

    private mutating func add(_ r: Range<Int>, _ style: InlineStyle) {
        let lo = max(r.lowerBound, 0), hi = min(r.upperBound, styles.count)
        guard lo < hi else { return }
        for p in lo..<hi { styles[p].formUnion(style) }
    }

    private mutating func set(_ r: Range<Int>, _ style: InlineStyle) {
        let lo = max(r.lowerBound, 0), hi = min(r.upperBound, styles.count)
        guard lo < hi else { return }
        for p in lo..<hi { styles[p] = style }
    }

    private func lineEnd(from p: Int, limit: Int) -> Int {
        var q = p
        while q < limit, bytes[q] != 0x0A { q += 1 }
        return q
    }

    private mutating func paint(_ block: Block) {
        let r = block.range
        switch block.kind {
        case .paragraph:
            paintInlines(block.inlines)
        case .heading(_, let isSetext):
            let contentStart = block.inlines.first?.range.lowerBound ?? r.upperBound
            let contentEnd = block.inlines.last?.range.upperBound ?? contentStart
            add(r, .strong)
            if isSetext {
                add(contentEnd..<r.upperBound, .syntax)
            } else {
                add(r.lowerBound..<contentStart, .syntax)
                add(contentEnd..<r.upperBound, .syntax)
            }
            paintInlines(block.inlines)
        case .blockQuote:
            paintQuoteMarkers(r)
            for child in block.children { paint(child) }
        case .list:
            for child in block.children { paint(child) }
        case .listItem(let task):
            paintItemMarker(r, task: task)
            for child in block.children { paint(child) }
        case .footnoteDefinition:
            // `[^label]:`
            var q = r.lowerBound
            while q < r.upperBound, bytes[q] != 0x3A, bytes[q] != 0x0A { q += 1 }
            add(r.lowerBound..<min(q + 1, r.upperBound), .syntax)
            for child in block.children { paint(child) }
        case .codeBlock(let info):
            if info.isFenced {
                add(r.lowerBound..<info.contentRange.lowerBound, .syntax)
                add(info.contentRange, .code)
                add(info.contentRange.upperBound..<r.upperBound, .syntax)
            } else {
                add(r, .code)
            }
        case .htmlBlock:
            add(r, .html)
        case .thematicBreak, .linkReferenceDefinition:
            add(r, .syntax)
        case .frontMatter:
            let first = lineEnd(from: r.lowerBound, limit: r.upperBound)
            var lastStart = r.upperBound
            while lastStart > first, bytes[lastStart - 1] != 0x0A { lastStart -= 1 }
            add(r, .code)
            set(r.lowerBound..<first, .syntax)
            if lastStart > first { set(lastStart..<r.upperBound, .syntax) }
        case .table:
            add(r, .syntax)
            for row in block.children {
                for cell in row.children {
                    for inline in cell.inlines { set(inline.range, []) }
                    paintInlines(cell.inlines)
                }
            }
        case .tableRow, .tableCell:
            break
        }
    }

    /// `>` markers at the start of every line of a quote.
    private mutating func paintQuoteMarkers(_ r: Range<Int>) {
        var p = r.lowerBound
        // The first line starts at the quote's own marker.
        while p < r.upperBound {
            var q = p
            while q < r.upperBound, bytes[q] == 0x20 || bytes[q] == 0x09 || bytes[q] == 0x3E {
                if bytes[q] == 0x3E { add(q..<(q + 1), .syntax) }
                q += 1
            }
            p = lineEnd(from: q, limit: r.upperBound) + 1
        }
    }

    /// `-`, `1.`, and a task box at the start of an item.
    private mutating func paintItemMarker(_ r: Range<Int>, task: TaskState?) {
        var q = r.lowerBound
        while q < r.upperBound, bytes[q] != 0x20, bytes[q] != 0x09, bytes[q] != 0x0A, bytes[q] != 0x0D { q += 1 }
        add(r.lowerBound..<q, .syntax)
        guard task != nil else { return }
        while q < r.upperBound, bytes[q] == 0x20 || bytes[q] == 0x09 { q += 1 }
        if q + 3 <= r.upperBound, bytes[q] == 0x5B, bytes[q + 2] == 0x5D { add(q..<(q + 3), .syntax) }
    }

    private mutating func paintInlines(_ inlines: [Inline]) {
        for inline in inlines { paintInline(inline) }
    }

    private mutating func paintInline(_ inline: Inline) {
        let r = inline.range
        switch inline.kind {
        case .text:
            // Backslash escapes.
            var p = r.lowerBound
            while p + 1 < r.upperBound {
                if bytes[p] == 0x5C, TextScanner.isASCIIPunctuation(bytes[p + 1]) {
                    add(p..<(p + 1), .syntax)
                    p += 2
                } else {
                    p += 1
                }
            }
        case .softBreak:
            break
        case .lineBreak:
            var nl = r.lowerBound
            while nl < r.upperBound, bytes[nl] != 0x0A, bytes[nl] != 0x0D { nl += 1 }
            add(r.lowerBound..<nl, .syntax)
        case .code:
            paintDelimited(r, delimiter: 0x60, style: .code, max: Int.max)
        case .math(_, let isDisplay):
            paintDelimited(r, delimiter: 0x24, style: .math, max: isDisplay ? 2 : 1)
        case .html:
            add(r, .html)
        case .emphasis:
            paintContainer(inline, style: .emphasis)
        case .strong:
            paintContainer(inline, style: .strong)
        case .strikethrough:
            paintContainer(inline, style: .strikethrough)
        case .subscript:
            paintContainer(inline, style: .subscript)
        case .superscript:
            paintContainer(inline, style: .superscript)
        case .highlight:
            paintContainer(inline, style: .highlight)
        case .emoji:
            break
        case .attributes:
            add(r, .syntax)
        case .footnoteReference:
            add(r, .syntax)
        case .link(_, _, let isAutolink):
            if isAutolink {
                add(r, .link)
                if r.count >= 2, bytes[r.lowerBound] == 0x3C {
                    add(r.lowerBound..<(r.lowerBound + 1), .syntax)
                    add((r.upperBound - 1)..<r.upperBound, .syntax)
                }
                return
            }
            paintLink(inline)
        case .image:
            paintLink(inline)
        }
    }

    /// Bytes of the node not covered by a child are delimiters.
    private mutating func paintContainer(_ inline: Inline, style: InlineStyle) {
        add(inline.range, style)
        var p = inline.range.lowerBound
        for child in inline.children {
            add(p..<child.range.lowerBound, .syntax)
            paintInline(child)
            p = child.range.upperBound
        }
        add(p..<inline.range.upperBound, .syntax)
    }

    private mutating func paintDelimited(_ r: Range<Int>, delimiter: UInt8, style: InlineStyle, max: Int) {
        var n = 0
        while r.lowerBound + n < r.upperBound, bytes[r.lowerBound + n] == delimiter, n < max { n += 1 }
        var closeStart = r.upperBound
        var m = 0
        while closeStart > r.lowerBound + n, bytes[closeStart - 1] == delimiter, m < n { closeStart -= 1; m += 1 }
        add(r.lowerBound..<(r.lowerBound + n), .syntax)
        add((r.lowerBound + n)..<closeStart, style)
        add(closeStart..<r.upperBound, .syntax)
    }

    /// `[label](destination "title")`, `![alt](src)`, `[label][ref]`.
    private mutating func paintLink(_ inline: Inline) {
        let r = inline.range
        var p = r.lowerBound
        for child in inline.children {
            add(p..<child.range.lowerBound, .syntax)
            paintInline(child)
            p = child.range.upperBound
        }
        var bracket = p
        while bracket < r.upperBound, bytes[bracket] != 0x5D { bracket += 1 }
        if bracket < r.upperBound { bracket += 1 }
        add(p..<bracket, .syntax)
        guard bracket < r.upperBound else { return }
        if bytes[bracket] == 0x28, bytes[r.upperBound - 1] == 0x29, r.upperBound - bracket >= 2 {
            add(bracket..<(bracket + 1), .syntax)
            add((bracket + 1)..<(r.upperBound - 1), .link)
            add((r.upperBound - 1)..<r.upperBound, .syntax)
        } else {
            add(bracket..<r.upperBound, .syntax)
        }
    }
}

extension Projection {
    /// Cache keys for source-mode entries. Hybrid keys are 0, 1 or have bit 1
    /// set, so these never collide; the last entry keys differently because
    /// it keeps its final newline visible.
    func sourceRevealKey(isLast: Bool) -> Int { isLast ? -3 : -11 }

    func buildSource(entry: BlockEntry, start: Int, rope: LipiRope, isLast: Bool) -> [DisplayBlock] {
        var text = rope.string(in: start..<(start + entry.length))
        return text.withUTF8 { bytes in
            var projector = SourceEntryProjector(bytes: bytes, isLastEntry: isLast)
            return projector.project(entry.block, spanLength: entry.length)
        }
    }
}
