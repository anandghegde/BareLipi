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
        guard y.isFinite, y >= 0 else { return 0 }
        let i = min(y / typeset.lineHeight, CGFloat(lines.count))
        return min(max(Int(i), 0), lines.count - 1)
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
                case .highlight:
                    rect = CGRect(x: left, y: line.baseline - line.ascent, width: w, height: line.ascent + line.descent)
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

/// Row-lazy layout of a table island (§6.3: row layout is virtualized).
///
/// Only a bounded sample of rows is typeset when the table is laid out: the
/// header, the first rows and rows strided through the rest, which fix the
/// column widths. Every other row gets an estimated height (one line per
/// cell unless its text is longer than the column) and is typeset the first
/// time it is drawn, hit-tested or asked for a caret, like the
/// estimated-then-measured entries of `DocumentLayout`. A row measured
/// wider than its column widens that column into the table's free width;
/// columns never narrow within one layout, so the grid stays stable while
/// scrolling. At most `realizedRowCap` rows keep their typeset cells; the
/// least recently used are dropped (their measured heights stay).
///
/// Not thread-safe: a table layout mutates as rows are realized, on the
/// thread that owns its `DocumentLayout`.
public final class TableLayout {
    public let columns: Int
    public let rows: Int
    public let paddingX: CGFloat
    public let paddingY: CGFloat
    /// Column widths, padding included.
    public private(set) var columnWidths: [CGFloat]
    /// Rows this layout has typeset (not counting rows adopted from the
    /// previous layout of the same table).
    public private(set) var rowsTypeset = 0
    /// Upper bound on rows holding typeset cells.
    public let realizedRowCap: Int

    struct Row {
        let key: UInt64
        var cells: [CellLayout]
        /// Natural width of each cell, padding included, rounded up and capped.
        let natural: [CGFloat]
        var lastUse: UInt64
    }

    let block: DisplayBlock
    let typesetter: Typesetter
    /// Width available to the table.
    let available: CGFloat
    let maxColumn: CGFloat
    private var offsets: [CGFloat]
    private var heights: HeightTree
    private var measured: [Bool]
    private(set) var realized: [Int: Row] = [:]
    /// Rows of the previous layout of this table, adopted when their key
    /// still matches (typing in one row re-typesets only that row).
    private let inherited: [Int: Row]
    private var inheritedByKey: [UInt64: Row]? = nil
    private let inheritedRowCount: Int
    private var clock: UInt64 = 0
    private lazy var advance: CGFloat =
        typesetter.cascade.zeroAdvance(size: typesetter.scale.style(for: .tableCell).size) * 0.92

    /// Rows typeset to fix the column widths: header, the first
    /// `leadingSample`, and up to `stridedSample` spread through the rest.
    static let leadingSample = 96
    static let stridedSample = 32

    init(block: DisplayBlock, typesetter: Typesetter, width: CGFloat, paddingX px: CGFloat, paddingY py: CGFloat,
         previous: TableLayout?, growOnly: Bool) {
        let shape = block.table!
        columns = shape.columns
        rows = shape.rows
        paddingX = px
        paddingY = py
        self.block = block
        self.typesetter = typesetter
        available = width
        let minColumn = (typesetter.scale.style(for: .tableCell).size * 3).rounded() + 2 * px
        maxColumn = max(minColumn, width * 0.6)
        realizedRowCap = max(128, 8192 / max(1, columns))
        let columnCount = shape.columns
        let compatible = previous.map { $0.columns == columnCount && $0.available == width && $0.paddingX == px && $0.paddingY == py } ?? false
        inherited = compatible ? previous!.realized : [:]
        inheritedRowCount = compatible ? previous!.rows : -1
        heights = HeightTree()
        measured = []
        offsets = []

        var sample: [Int: Row] = [:]
        if compatible, growOnly, let previous {
            // The caret is in the table: keep its columns.
            columnWidths = previous.columnWidths
        } else {
            columnWidths = []
            var wanted = [CGFloat](repeating: minColumn, count: columns)
            for r in TableLayout.sampleRows(rows) {
                let row = naturalRow(r)
                for c in 0..<columns { wanted[c] = max(wanted[c], row.natural[c]) }
                sample[r] = row
            }
            columnWidths = TableLayout.fit(wanted, into: width, minColumn: minColumn)
        }
        offsets = TableLayout.prefix(columnWidths)
        if compatible, let previous, previous.rows == rows, previous.columnWidths == columnWidths {
            heights = previous.heights
            measured = previous.measured
        } else {
            heights = HeightTree(heights: (0..<rows).map { Double(estimate($0)) })
            measured = [Bool](repeating: false, count: rows)
        }
        for (r, row) in sample.sorted(by: { $0.key < $1.key }) { install(row, at: r) }
    }

    // MARK: Geometry

    public var width: CGFloat { offsets.last ?? 0 }
    /// Current height: measured rows plus the estimates of the others.
    public var height: CGFloat { CGFloat(heights.total) }
    public func columnX(_ c: Int) -> CGFloat { offsets[min(max(c, 0), columns)] }
    /// y of row `r`'s top; `rowY(rows)` is the table's height.
    public func rowY(_ r: Int) -> CGFloat { CGFloat(heights.prefix(min(max(r, 0), rows))) }
    public func rowHeight(_ r: Int) -> CGFloat { CGFloat(heights.height(at: r)) }
    /// Every row's current height (estimates for rows not measured yet).
    public var rowHeights: [CGFloat] { (0..<rows).map(rowHeight) }
    /// The row whose span contains `y` (clamped), without typesetting it.
    public func row(atY y: CGFloat) -> Int { heights.index(at: Double(y)) ?? 0 }
    public func isMeasured(row r: Int) -> Bool { measured[r] }
    public func isRealized(row r: Int) -> Bool { realized[r] != nil }
    public var realizedRowCount: Int { realized.count }
    /// Row and column of cell `i` (cells are stored row-major).
    public func position(ofCell i: Int) -> (row: Int, column: Int) { (i / columns, i % columns) }
    public func cellIndex(row: Int, column: Int) -> Int { row * columns + column }

    /// Frame of cell `i` relative to the table's top-left (padding
    /// included). Typesets the cell's row if needed, so the frame is exact.
    public func frame(ofCell i: Int) -> CGRect {
        let (r, c) = position(ofCell: i)
        realize(r)
        return CGRect(x: offsets[c] + paddingX, y: rowY(r) + paddingY,
                      width: columnWidths[c] - 2 * paddingX, height: rowHeight(r) - 2 * paddingY)
    }

    /// Cell `i`, typesetting its row if needed.
    public func cell(_ i: Int) -> CellLayout {
        let (r, c) = position(ofCell: i)
        return realize(r).cells[c]
    }

    /// Typesets the rows intersecting `range` (table y) and returns them.
    /// Rows are measured top-down, so each row's y is final before the next
    /// is found; the rows above the range keep their heights.
    @discardableResult
    public func realizeRows(in range: ClosedRange<CGFloat>) -> Range<Int> {
        guard rows > 0, range.upperBound >= 0, range.lowerBound <= height else { return 0..<0 }
        let first = row(atY: range.lowerBound)
        var r = first
        while r < rows, rowY(r) <= range.upperBound {
            realize(r)
            r += 1
        }
        return first..<max(r, first + 1)
    }

    /// Measures every row (typesetting each once; only the most recent
    /// `realizedRowCap` keep their cells).
    public func measureAll() {
        for r in 0..<rows where !measured[r] { realize(r) }
    }

    /// Cell index under `point` (table coordinates), else the nearest cell.
    /// Rows are typeset on the way, so an estimated row that grows when
    /// measured moves the answer to the row now under the point.
    public func cellIndex(at point: CGPoint) -> Int {
        guard rows > 0 else { return 0 }
        var r = row(atY: point.y)
        while true {
            realize(r)
            if r + 1 < rows, point.y >= rowY(r + 1) { r += 1 } else { break }
        }
        var c = 0
        while c < columns - 1, point.x >= offsets[c + 1] { c += 1 }
        return r * columns + c
    }

    // MARK: Rows

    /// The row's cells, typeset at the column widths (typesetting them now
    /// if needed).
    @discardableResult
    func realize(_ r: Int) -> Row {
        clock += 1
        if var row = realized[r] {
            row.lastUse = clock
            realized[r] = row
            return row
        }
        let key = rowKey(r)
        let row = adopt(r, key: key) ?? naturalRow(r, key: key)
        install(row, at: r)
        return realized[r]!
    }

    /// Places a row with natural widths: widens columns it overflows, wraps
    /// its cells at the column widths and records its height.
    private func install(_ source: Row, at r: Int) {
        var row = source
        clock += 1
        row.lastUse = clock
        let widened = widen(for: row.natural)
        for c in 0..<columns { row.cells[c] = fitted(row.cells[c], column: c) }
        realized[r] = row
        record(r, row)
        if !widened.isEmpty {
            for (other, var o) in realized where other != r {
                var changed = false
                for c in widened where !fits(o.cells[c], column: c) {
                    o.cells[c] = fitted(o.cells[c], column: c)
                    changed = true
                }
                if changed { realized[other] = o; record(other, o) }
            }
        }
        if realized.count > realizedRowCap { evict() }
    }

    private func record(_ r: Int, _ row: Row) {
        var h: CGFloat = 0
        for cell in row.cells { h = max(h, cell.height + 2 * paddingY) }
        heights.update(r, height: Double(h))
        measured[r] = true
    }

    /// A row of the previous layout with the same content, if any.
    private func adopt(_ r: Int, key: UInt64) -> Row? {
        if let row = inherited[r], row.key == key { return row }
        guard inheritedRowCount != rows, !inherited.isEmpty else { return nil }
        if inheritedByKey == nil {
            var byKey: [UInt64: Row] = [:]
            for row in inherited.values { byKey[row.key] = row }
            inheritedByKey = byKey
        }
        return inheritedByKey![key]
    }

    /// Typesets row `r` at unbounded width.
    private func naturalRow(_ r: Int, key: UInt64? = nil) -> Row {
        var cells: [CellLayout] = []
        var natural: [CGFloat] = []
        cells.reserveCapacity(columns)
        natural.reserveCapacity(columns)
        for c in 0..<columns {
            let i = r * columns + c
            let cell = LayoutEngine.typeset(typesetter.typeset(block.cells[i], in: block, cellIndex: i), width: .infinity)
            cells.append(cell)
            natural.append(min(maxColumn, (cell.usedWidth + 2 * paddingX).rounded(.up)))
        }
        rowsTypeset += 1
        return Row(key: key ?? rowKey(r), cells: cells, natural: natural, lastUse: 0)
    }

    /// Hash of the row's cell keys (text, runs, role and alignment).
    func rowKey(_ r: Int) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for c in 0..<columns {
            let i = r * columns + c
            h = (h ^ typesetter.key(for: block.cells[i], in: block, cellIndex: i)) &* 0x0000_0100_0000_01B3
        }
        return h
    }

    /// Whether `cell` is laid out correctly for column `c`: typeset at the
    /// column's inner width, or an unbounded single left-aligned line that
    /// fits it.
    private func fits(_ cell: CellLayout, column c: Int) -> Bool {
        let inner = columnWidths[c] - 2 * paddingX
        if cell.width == inner { return true }
        return cell.width.isInfinite && cell.isSingleLine && cell.usedWidth <= inner && cell.typeset.flushFactor == 0
    }

    private func fitted(_ cell: CellLayout, column c: Int) -> CellLayout {
        fits(cell, column: c) ? cell : LayoutEngine.typeset(cell.typeset, width: columnWidths[c] - 2 * paddingX)
    }

    /// Grows the columns `natural` overflows into the table's free width
    /// (never past `available`, never narrowing). Returns the columns widened.
    private func widen(for natural: [CGFloat]) -> [Int] {
        var slack = available - (offsets.last ?? 0)
        guard slack >= 1 else { return [] }
        var widened: [Int] = []
        for c in 0..<columns where natural[c] > columnWidths[c] {
            let grow = min(natural[c] - columnWidths[c], slack).rounded(.down)
            guard grow >= 1 else { continue }
            columnWidths[c] += grow
            slack -= grow
            widened.append(c)
        }
        if !widened.isEmpty { offsets = TableLayout.prefix(columnWidths) }
        return widened
    }

    /// Drops the typeset cells of the least recently used rows.
    private func evict() {
        let order = realized.sorted { $0.value.lastUse < $1.value.lastUse }
        let target = realizedRowCap * 3 / 4
        for (r, _) in order.prefix(max(0, realized.count - target)) { realized[r] = nil }
    }

    /// Height guess for an unmeasured row: one line per cell unless its text
    /// is longer than the column (exact for single-line rows).
    private func estimate(_ r: Int) -> CGFloat {
        let lineHeight = typesetter.scale.style(for: r == 0 ? .tableHeader : .tableCell).lineHeight
        var lines: CGFloat = 1
        for c in 0..<columns {
            let n = block.cells[r * columns + c].text.utf16.count
            let inner = max(1, columnWidths[c] - 2 * paddingX)
            lines = max(lines, (CGFloat(n) * advance / inner).rounded(.up))
        }
        return lines * lineHeight + 2 * paddingY
    }

    static func sampleRows(_ rows: Int) -> [Int] {
        let leading = min(rows, 1 + leadingSample)
        var result = Array(0..<leading)
        let rest = rows - leading
        if rest > 0 {
            let count = min(rest, stridedSample)
            for k in 0..<count { result.append(leading + (k * rest + rest / 2) / count) }
        }
        return result
    }

    /// Natural widths shrunk to fit `width`: the columns above their fair
    /// share lose width proportionally, then everything scales down.
    static func fit(_ wanted: [CGFloat], into width: CGFloat, minColumn: CGFloat) -> [CGFloat] {
        var widths = wanted
        let columns = widths.count
        let total = widths.reduce(0, +)
        guard total > width, columns > 0 else { return widths }
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
        return widths
    }

    static func prefix(_ widths: [CGFloat]) -> [CGFloat] {
        var result: [CGFloat] = [0]
        result.reserveCapacity(widths.count + 1)
        for w in widths { result.append(result.last! + w) }
        return result
    }
}

// MARK: - Blocks

/// One display block laid out at one width. Produced by `LayoutEngine` and
/// held by `LayoutCache`. Paragraph-like blocks are immutable once built; a
/// table typesets its rows lazily (`TableLayout`), so its height and the
/// lines it holds grow as rows are measured.
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
    public let table: TableLayout?
    private let storedCells: [CellLayout]
    private let storedFrames: [CGRect]
    private let storedHeight: CGFloat
    /// Space below a table's grid, inside the block's box.
    private let tableSpacing: CGFloat

    /// Height of the block's own box (padding included, spacing excluded).
    /// For a table it includes the estimates of rows not measured yet.
    public var height: CGFloat { table.map { $0.height + tableSpacing } ?? storedHeight }
    public var cellCount: Int { table.map { $0.rows * $0.columns } ?? storedCells.count }
    /// Lines typeset so far (a table counts only its realized rows).
    public var lineCount: Int {
        guard let table else { return storedCells.reduce(0) { $0 + $1.lines.count } }
        return table.realized.values.reduce(0) { sum, row in sum + row.cells.reduce(0) { $0 + $1.lines.count } }
    }
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
         width: CGFloat, indent: CGFloat, cells: [CellLayout], cellFrames: [CGRect], table: TableLayout?, height: CGFloat,
         tableSpacing: CGFloat = 0) {
        self.id = id
        self.layoutKey = layoutKey
        self.role = role
        self.style = style
        self.context = context
        self.isRevealed = isRevealed
        self.width = width
        self.indent = indent
        self.storedCells = cells
        self.storedFrames = cellFrames
        self.table = table
        self.storedHeight = height
        self.tableSpacing = tableSpacing
    }

    /// Cell `i`; a table typesets the cell's row if it is not yet.
    public func cell(_ i: Int) -> CellLayout { table?.cell(i) ?? storedCells[i] }

    /// Frame of cell `i` relative to the block's top-left (padding included).
    public func cellFrame(_ i: Int) -> CGRect { table?.frame(ofCell: i) ?? storedFrames[i] }

    /// Every cell. For a table this typesets every row: use `cell(_:)` or
    /// `TableLayout.realizeRows(in:)` outside tests.
    public var cells: [CellLayout] { (0..<cellCount).map(cell) }
    /// Every cell frame (typesets every row of a table, like `cells`).
    public var cellFrames: [CGRect] { (0..<cellCount).map(cellFrame) }

    /// Index of the cell whose frame contains `point` (block coordinates),
    /// else the nearest cell. A table typesets the rows it walks through.
    public func cellIndex(at point: CGPoint) -> Int {
        guard let table, cellCount > 1 else { return 0 }
        return table.cellIndex(at: point)
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

    /// Table island: column widths from the natural widths of a sample of
    /// rows, shrunk proportionally to fit, never shrunk while `growOnly`
    /// (the caret is inside). Rows outside the sample are typeset on demand
    /// (`TableLayout`). With `previous`, rows whose content did not change
    /// reuse their typeset cells.
    static func layoutTable(_ block: DisplayBlock, typesetter: Typesetter, width: CGFloat, indent: CGFloat, style: TextStyle,
                            previous: BlockLayout?, growOnly: Bool) -> BlockLayout {
        let table = TableLayout(block: block, typesetter: typesetter, width: width, paddingX: style.paddingX, paddingY: style.paddingY,
                                previous: previous?.table, growOnly: growOnly)
        return BlockLayout(id: block.id, layoutKey: block.layoutKey, role: block.role, style: style, context: block.context,
                           isRevealed: block.isRevealed, width: width, indent: indent, cells: [], cellFrames: [],
                           table: table, height: 0, tableSpacing: typesetter.scale.paragraphSpacing)
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
