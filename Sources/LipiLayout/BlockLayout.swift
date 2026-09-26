import CoreText
import Foundation
import LipiCore

// MARK: - Lines

/// One laid-out line of a cell. Coordinates are relative to the cell's
/// top-left corner with y growing downwards (the editor view is flipped).
public struct LineFragment {
    public let line: CTLine
    /// UTF-16 range in the cell text.
    public let range: Range<Int>
    public let top: CGFloat
    public let baseline: CGFloat
    /// Pen offset for the paragraph's flush (0 for left-aligned lines).
    public let x: CGFloat
    public let ascent: CGFloat
    public let descent: CGFloat
    public let width: CGFloat
    public let trailingWhitespace: CGFloat
    public let height: CGFloat

    public var bottom: CGFloat { top + height }
    public var isRightToLeft: Bool {
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], let first = runs.first else { return false }
        return CTRunGetStatus(first).contains(.rightToLeft)
    }
}

public struct DecorationRect {
    public let kind: DecorationKind
    public let rect: CGRect
    public let lineIndex: Int
}

/// A cell typeset at one width: the lines and everything drawn around them.
public final class CellLayout {
    public let typeset: TypesetCell
    public let width: CGFloat
    public let lines: [LineFragment]
    public let height: CGFloat
    public let decorations: [DecorationRect]
    /// Width of the widest line (natural width when `width` is unbounded).
    public let usedWidth: CGFloat

    init(typeset: TypesetCell, width: CGFloat, lines: [LineFragment], decorations: [DecorationRect]) {
        self.typeset = typeset
        self.width = width
        self.lines = lines
        self.height = lines.last?.bottom ?? typeset.lineHeight
        self.decorations = decorations
        self.usedWidth = lines.reduce(0) { max($0, $1.x + $1.width - $1.trailingWhitespace) }
    }

    public var string: NSString { typeset.attributed.string as NSString }
    public var length: Int { typeset.length }
    public var isSingleLine: Bool { lines.count == 1 }

    /// The line holding UTF-16 `offset`. An offset at a soft wrap belongs to
    /// the line after it unless `upstream` is set; the end of the text
    /// belongs to the last line.
    public func lineIndex(containing offset: Int, upstream: Bool = false) -> Int {
        guard lines.count > 1 else { return 0 }
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].range.upperBound <= offset { lo = mid + 1 } else { hi = mid }
        }
        if upstream, lo > 0, lines[lo].range.lowerBound == offset { return lo - 1 }
        if offset >= lines[lo].range.upperBound, lo < lines.count - 1 { return lo + 1 }
        return lo
    }

    public func lineIndex(atY y: CGFloat) -> Int {
        if y < 0 { return 0 }
        let i = Int(y / typeset.lineHeight)
        return min(max(i, 0), lines.count - 1)
    }
}

// MARK: - Typesetting

public enum LayoutEngine {
    /// Breaks `cell` into lines at `width` with `CTTypesetter`
    /// (`CTTypesetterSuggestLineBreak`: word boundaries first, then cluster
    /// boundaries when a word is longer than the measure).
    public static func typeset(_ cell: TypesetCell, width: CGFloat) -> CellLayout {
        let attributed = cell.attributed
        let length = attributed.length
        let lineHeight = cell.lineHeight
        var lines: [LineFragment] = []
        lines.reserveCapacity(max(1, Int(length / 60) + 1))
        let flush = cell.flushFactor

        func place(_ line: CTLine, range: Range<Int>, top: CGFloat) -> LineFragment {
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let trailing = CGFloat(CTLineGetTrailingWhitespaceWidth(line))
            let x = flush > 0 && width.isFinite ? CGFloat(CTLineGetPenOffsetForFlush(line, flush, Double(width))) : 0
            let baseline = (top + (lineHeight - (ascent + descent)) / 2 + ascent).rounded()
            return LineFragment(line: line, range: range, top: top, baseline: baseline, x: x, ascent: ascent, descent: descent,
                                width: lineWidth, trailingWhitespace: trailing, height: lineHeight)
        }

        if length == 0 {
            let line = CTLineCreateWithAttributedString(attributed)
            lines.append(place(line, range: 0..<0, top: 0))
        } else {
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            var start = 0
            var top: CGFloat = 0
            while start < length {
                var count = width.isFinite ? CTTypesetterSuggestLineBreak(typesetter, start, Double(width)) : length - start
                if count <= 0 { count = max(1, CTTypesetterSuggestClusterBreak(typesetter, start, Double(width))) }
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
                lines.append(place(line, range: start..<(start + count), top: top))
                start += count
                top += lineHeight
            }
            // A trailing newline opens an empty last line for the caret.
            if let last = attributed.string.utf16.last, last == 0x0A {
                let empty = CTLineCreateWithAttributedString(attributed.attributedSubstring(from: NSRange(location: length - 1, length: 0)))
                lines.append(place(empty, range: length..<length, top: top))
            }
        }
        let decorations = decorationRects(for: cell, lines: lines)
        return CellLayout(typeset: cell, width: width, lines: lines, decorations: decorations)
    }

    static func decorationRects(for cell: TypesetCell, lines: [LineFragment]) -> [DecorationRect] {
        guard !cell.decorations.isEmpty else { return [] }
        var result: [DecorationRect] = []
        for decoration in cell.decorations {
            for (i, line) in lines.enumerated() where line.range.overlaps(decoration.range) || (line.range.isEmpty && false) {
                let lo = max(line.range.lowerBound, decoration.range.lowerBound)
                let hi = min(line.range.upperBound, decoration.range.upperBound)
                guard lo < hi else { continue }
                let x0 = CGFloat(CTLineGetOffsetForStringIndex(line.line, lo, nil))
                let x1 = CGFloat(CTLineGetOffsetForStringIndex(line.line, hi, nil))
                let left = line.x + min(x0, x1)
                let w = abs(x1 - x0)
                let rect: CGRect
                switch decoration.kind {
                case .strikethrough:
                    let y = line.baseline - line.ascent * 0.32
                    rect = CGRect(x: left, y: y, width: w, height: 1)
                case .codePill, .chip, .marked:
                    let pad = cell.style.paddingX
                    rect = CGRect(x: left - pad, y: line.baseline - line.ascent - 1, width: w + 2 * pad, height: line.ascent + line.descent + 2)
                case .link:
                    rect = CGRect(x: left, y: line.baseline + 1.5, width: w, height: 1)
                }
                result.append(DecorationRect(kind: decoration.kind, rect: rect, lineIndex: i))
            }
        }
        return result
    }
}

extension TypesetCell {
    /// 0 left, 0.5 centre, 1 right; natural alignment follows the direction.
    var flushFactor: CGFloat {
        switch alignment {
        case .left: return 0
        case .center: return 0.5
        case .right: return 1
        case .none: return isRightToLeft ? 1 : 0
        }
    }
}

// MARK: - Tables

public struct TableLayout {
    public let columns: Int
    public let rows: Int
    public let columnWidths: [CGFloat]
    public let rowHeights: [CGFloat]
    public let cellKeys: [UInt64]
    public let paddingX: CGFloat
    public let paddingY: CGFloat

    public var width: CGFloat { columnWidths.reduce(0, +) }
    public var height: CGFloat { rowHeights.reduce(0, +) }
    public func columnX(_ c: Int) -> CGFloat { columnWidths.prefix(c).reduce(0, +) }
    public func rowY(_ r: Int) -> CGFloat { rowHeights.prefix(r).reduce(0, +) }
    /// Row and column of cell `i` (cells are stored row-major).
    public func position(ofCell i: Int) -> (row: Int, column: Int) { (i / columns, i % columns) }
    public func cellIndex(row: Int, column: Int) -> Int { row * columns + column }
}

// MARK: - Blocks

/// One display block laid out at one width. Produced by `LayoutEngine` and
/// held by `LayoutCache`; immutable once built.
public final class BlockLayout {
    public let id: NodeID
    public let layoutKey: UInt64
    public let role: BlockRole
    public let style: TextStyle
    public let context: BlockContext
    public let isRevealed: Bool
    /// Width the block was laid out for (content width, after the indent).
    public let width: CGFloat
    /// Leading indent from the text column (quote and list nesting).
    public let indent: CGFloat
    public let cells: [CellLayout]
    /// Frame of each cell relative to the block's top-left (padding included).
    public let cellFrames: [CGRect]
    public let table: TableLayout?
    /// Height of the block's own box (padding included, spacing excluded).
    public let height: CGFloat
    public var lineCount: Int { cells.reduce(0) { $0 + $1.lines.count } }
    public var spacingBefore: CGFloat { style.spacingBefore }
    public var spacingAfter: CGFloat { style.spacingAfter }
    public var isThematicBreak: Bool { if case .thematicBreak = role { return true } else { return false } }
    public var hasBackground: Bool {
        switch role {
        case .code, .frontMatter, .html: return true
        default: return false
        }
    }

    init(id: NodeID, layoutKey: UInt64, role: BlockRole, style: TextStyle, context: BlockContext, isRevealed: Bool,
         width: CGFloat, indent: CGFloat, cells: [CellLayout], cellFrames: [CGRect], table: TableLayout?, height: CGFloat) {
        self.id = id
        self.layoutKey = layoutKey
        self.role = role
        self.style = style
        self.context = context
        self.isRevealed = isRevealed
        self.width = width
        self.indent = indent
        self.cells = cells
        self.cellFrames = cellFrames
        self.table = table
        self.height = height
    }

    /// Index of the cell whose frame contains `point` (block coordinates),
    /// else the nearest cell.
    public func cellIndex(at point: CGPoint) -> Int {
        guard cells.count > 1, let table else { return 0 }
        var row = 0
        var y = cellFrames[0].minY
        while row < table.rows - 1, point.y >= y + table.rowHeights[row] { y += table.rowHeights[row]; row += 1 }
        var column = 0
        var x = cellFrames[0].minX
        while column < table.columns - 1, point.x >= x + table.columnWidths[column] { x += table.columnWidths[column]; column += 1 }
        return row * table.columns + column
    }
}

extension LayoutEngine {
    /// Indent of a block from the text column: 16 pt per quote level and
    /// 24 pt per list level (markers hang in the gutter, §8.2).
    public static func indent(for context: BlockContext, scale: TypeScale) -> CGFloat {
        let quote = CGFloat(context.quoteDepth) * scale.l(16)
        let list = CGFloat(context.listDepth) * scale.l(24)
        return quote + list
    }

    /// Lays out `block` for a text column of `measure` points; code blocks
    /// and tables may use `wideWidth` (editor width minus margins) instead.
    public static func layout(_ block: DisplayBlock, typesetter: Typesetter, measure: CGFloat, wideWidth: CGFloat,
                              previous: BlockLayout? = nil, growOnly: Bool = false) -> BlockLayout {
        let scale = typesetter.scale
        let indent = indent(for: block.context, scale: scale)
        let isWide: Bool = {
            switch block.role {
            case .code, .table, .html: return true
            default: return false
            }
        }()
        let width = max(80, (isWide ? max(measure, wideWidth) : measure) - indent)
        let style = scale.style(for: typesetter.role(of: block, cellIndex: 0))

        if block.table != nil {
            return layoutTable(block, typesetter: typesetter, width: width, indent: indent, style: style, previous: previous, growOnly: growOnly)
        }

        let typesetCell = typesetter.typeset(block.cells[0], in: block, cellIndex: 0)
        let cell = typeset(typesetCell, width: width - 2 * style.paddingX)
        let frame = CGRect(x: style.paddingX, y: style.paddingY, width: width - 2 * style.paddingX, height: cell.height)
        var height = cell.height + 2 * style.paddingY
        if block.isThematicBreak, block.cells[0].text.isEmpty { height = style.lineHeight }
        return BlockLayout(id: block.id, layoutKey: block.layoutKey, role: block.role, style: style, context: block.context,
                           isRevealed: block.isRevealed, width: width, indent: indent, cells: [cell], cellFrames: [frame],
                           table: nil, height: height)
    }

    /// Table island: natural column widths, shrunk proportionally to fit,
    /// never shrunk while `growOnly` (the caret is inside). With `previous`,
    /// only cells whose typeset key changed are measured again, and only the
    /// columns whose width changed are re-wrapped.
    static func layoutTable(_ block: DisplayBlock, typesetter: Typesetter, width: CGFloat, indent: CGFloat, style: TextStyle,
                            previous: BlockLayout?, growOnly: Bool) -> BlockLayout {
        let shape = block.table!
        let columns = shape.columns
        let rows = shape.rows
        let scale = typesetter.scale
        let px = style.paddingX
        let py = style.paddingY
        let minColumn = (scale.style(for: .tableCell).size * 3).rounded() + 2 * px
        let maxColumn = max(minColumn, width * 0.6)

        // Typeset every cell (reusing unchanged ones), measure at unbounded
        // width to learn the natural width.
        let prev = previous?.table
        let prevCells = previous?.cells ?? []
        let canReuse = prev != nil && prev!.columns == columns && prev!.rows == rows && prevCells.count == columns * rows
        var typesets: [TypesetCell] = []
        typesets.reserveCapacity(columns * rows)
        var natural: [CellLayout?] = Array(repeating: nil, count: columns * rows)
        var changed = [Bool](repeating: !canReuse, count: columns * rows)
        for i in 0..<(columns * rows) {
            let t = typesetter.typeset(block.cells[i], in: block, cellIndex: i)
            typesets.append(t)
            if canReuse, prev!.cellKeys[i] == t.key {
                natural[i] = prevCells[i]
            } else {
                changed[i] = true
                natural[i] = typeset(t, width: .infinity)
            }
        }
        // Natural column widths. Reused cells contribute their laid-out width
        // when they were single-line, else the previous column width.
        var wanted = [CGFloat](repeating: minColumn, count: columns)
        for i in 0..<(columns * rows) {
            let c = i % columns
            let cell = natural[i]!
            let w: CGFloat
            if changed[i] || cell.isSingleLine {
                w = cell.usedWidth + 2 * px
            } else {
                w = prev!.columnWidths[c]
            }
            wanted[c] = max(wanted[c], min(maxColumn, w.rounded(.up)))
        }
        if growOnly, let prev, prev.columns == columns {
            for c in 0..<columns { wanted[c] = max(wanted[c], prev.columnWidths[c]) }
        }
        var widths = wanted
        let total = widths.reduce(0, +)
        if total > width {
            // Shrink the columns above their fair share, proportionally.
            let fair = width / CGFloat(columns)
            let excess = total - width
            let shrinkable = widths.reduce(0) { $0 + max(0, $1 - fair) }
            if shrinkable > 0 {
                let ratio = min(1, excess / shrinkable)
                for c in 0..<columns where widths[c] > fair { widths[c] -= (widths[c] - fair) * ratio }
            }
            if widths.reduce(0, +) > width {
                let scaleDown = width / widths.reduce(0, +)
                for c in 0..<columns { widths[c] = max(minColumn, widths[c] * scaleDown) }
            }
            for c in 0..<columns { widths[c] = widths[c].rounded(.down) }
        }
        // Wrap the cells that do not fit on one line in their column.
        var cells: [CellLayout] = []
        cells.reserveCapacity(columns * rows)
        for i in 0..<(columns * rows) {
            let c = i % columns
            let inner = widths[c] - 2 * px
            let cell = natural[i]!
            let columnChanged = prev.map { $0.columnWidths[c] != widths[c] } ?? true
            if !changed[i], !columnChanged {
                cells.append(cell)
            } else if cell.isSingleLine, cell.usedWidth <= inner, typesets[i].flushFactor == 0 {
                // Natural layouts were measured unbounded, so they only stand
                // in for left-aligned cells; centred and right-aligned ones
                // are placed again at the column width.
                cells.append(cell)
            } else {
                cells.append(typeset(typesets[i], width: inner))
            }
        }
        var rowHeights = [CGFloat](repeating: 0, count: rows)
        for i in 0..<(columns * rows) {
            rowHeights[i / columns] = max(rowHeights[i / columns], cells[i].height + 2 * py)
        }
        var frames: [CGRect] = []
        frames.reserveCapacity(columns * rows)
        var y: CGFloat = 0
        for r in 0..<rows {
            var x: CGFloat = 0
            for c in 0..<columns {
                frames.append(CGRect(x: x + px, y: y + py, width: widths[c] - 2 * px, height: rowHeights[r] - 2 * py))
                x += widths[c]
            }
            y += rowHeights[r]
        }
        let table = TableLayout(columns: columns, rows: rows, columnWidths: widths, rowHeights: rowHeights,
                                cellKeys: typesets.map(\.key), paddingX: px, paddingY: py)
        return BlockLayout(id: block.id, layoutKey: block.layoutKey, role: block.role, style: style, context: block.context,
                           isRevealed: block.isRevealed, width: width, indent: indent, cells: cells, cellFrames: frames,
                           table: table, height: y + scale.paragraphSpacing)
    }

    /// Height guess for a block that has not been laid out (§7.4 step 7:
    /// line count × line height), so the scroll bar is stable.
    public static func estimatedHeight(of block: DisplayBlock, typesetter: Typesetter, measure: CGFloat, zeroAdvance: CGFloat) -> CGFloat {
        let scale = typesetter.scale
        let style = scale.style(for: typesetter.role(of: block, cellIndex: 0))
        let width = max(80, measure - indent(for: block.context, scale: scale) - 2 * style.paddingX)
        let charsPerLine = max(8, width / max(1, zeroAdvance * 0.92))
        if let table = block.table {
            var rows = [CGFloat](repeating: 1, count: table.rows)
            let columnWidth = max(8, charsPerLine / CGFloat(max(1, table.columns)))
            for (i, cell) in block.cells.enumerated() {
                let lines = max(1, ceil(CGFloat(cell.text.utf16.count) / columnWidth))
                rows[i / table.columns] = max(rows[i / table.columns], lines)
            }
            return rows.reduce(0) { $0 + $1 * style.lineHeight + 2 * style.paddingY } + scale.paragraphSpacing
        }
        var lines: CGFloat = 0
        for cell in block.cells {
            var count = 0
            var run = 0
            for u in cell.text.utf16 {
                if u == 0x0A { count += max(1, Int(ceil(CGFloat(run) / charsPerLine))); run = 0 } else { run += 1 }
            }
            count += max(1, Int(ceil(CGFloat(run) / charsPerLine)))
            lines += CGFloat(count)
        }
        return lines * style.lineHeight + 2 * style.paddingY
    }
}

extension DisplayBlock {
    var isThematicBreak: Bool { if case .thematicBreak = role { return true } else { return false } }
}
