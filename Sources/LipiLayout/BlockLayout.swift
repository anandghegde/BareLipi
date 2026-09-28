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
    /// Cell offset of the line's string index 0. A line broken from a window
    /// of a long cell, or kept from the layout before an edit, indexes a
    /// string other than the cell text; `offset(for:)` and `index(atX:)`
    /// translate.
    public let base: Int
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

    /// Pen offset of cell offset `offset` (relative to `x`).
    public func offset(for offset: Int) -> CGFloat {
        CGFloat(CTLineGetOffsetForStringIndex(line, offset - base, nil))
    }

    /// Cell offset nearest to `x` (relative to `x` of the line).
    public func index(atX x: CGFloat) -> Int {
        let i = CTLineGetStringIndexForPosition(line, CGPoint(x: x, y: 0))
        return i == kCFNotFound ? range.lowerBound : i + base
    }

    /// The same line `delta` further into the cell, at a new top.
    func moved(by delta: Int, top: CGFloat, baseline: CGFloat) -> LineFragment {
        LineFragment(line: line, range: (range.lowerBound + delta)..<(range.upperBound + delta), base: base + delta, top: top,
                     baseline: baseline, x: x, ascent: ascent, descent: descent, width: width,
                     trailingWhitespace: trailingWhitespace, height: height)
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
    /// Window the lines were broken with (`Int.max`: one typesetter).
    let windowLength: Int

    init(typeset: TypesetCell, width: CGFloat, lines: [LineFragment], decorations: [DecorationRect], windowLength: Int = .max) {
        self.typeset = typeset
        self.windowLength = windowLength
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
    /// Cells at least this long (UTF-16 units) are broken through
    /// typesetters over windows of their text, and re-laid out after an
    /// edit from the lines of their previous layout. `CTTypesetterSuggestLineBreak`
    /// takes time in proportion to the text after the line's start, so one
    /// typesetter over a 1 MB paragraph made breaking it quadratic (83 s).
    public static let windowThreshold = 16_384
    /// Text a window starts with; it grows for a line that does not end well
    /// inside it.
    public static let windowLength = 4_096
    /// A window is replaced once less than this is left after a line's start.
    static let windowTail = 1_024
    /// A break this close to the cut end of a window is not trusted: line
    /// breaking looks a few characters ahead (UAX #14).
    static let windowMargin = 64

    /// Breaks `cell` into lines at `width` with `CTTypesetter`
    /// (`CTTypesetterSuggestLineBreak`: word boundaries first, then cluster
    /// boundaries when a word is longer than the measure).
    ///
    /// With `previous`, the layout of an earlier version of the same cell at
    /// the same width, the lines before the edit are kept and lines are
    /// re-broken from the one before the edit only until a new line starts
    /// where an old one did past the edit; the old lines after that point
    /// are moved by the length change instead of being typeset again. The
    /// result equals a fresh layout. `windowLength` overrides the window
    /// (`Int.max`: one typesetter over the whole cell); by default cells
    /// shorter than `windowThreshold` use one typesetter.
    public static func typeset(_ cell: TypesetCell, width: CGFloat, previous: CellLayout? = nil, windowLength: Int? = nil) -> CellLayout {
        let attributed = cell.attributed
        let length = attributed.length
        let lineHeight = cell.lineHeight
        let flush = cell.flushFactor
        var lines: [LineFragment] = []
        // Windows would resolve the paragraph direction per window, so cells
        // with right-to-left text keep one typesetter.
        let window = windowLength ?? (length >= windowThreshold && !cell.containsRightToLeft ? Self.windowLength : .max)

        func place(_ line: CTLine, range: Range<Int>, base: Int) -> LineFragment {
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let trailing = CGFloat(CTLineGetTrailingWhitespaceWidth(line))
            let x = flush > 0 && width.isFinite ? CGFloat(CTLineGetPenOffsetForFlush(line, flush, Double(width))) : 0
            // Tops are multiples of the line height, so a line moved by an
            // edit lands exactly where a fresh layout puts it.
            let top = CGFloat(lines.count) * lineHeight
            return LineFragment(line: line, range: range, base: base, top: top, baseline: baseline(top: top, ascent: ascent, descent: descent, lineHeight: lineHeight),
                                x: x, ascent: ascent, descent: descent, width: lineWidth, trailingWhitespace: trailing, height: lineHeight)
        }

        if length == 0 {
            let line = CTLineCreateWithAttributedString(attributed)
            lines.append(place(line, range: 0..<0, base: 0))
        } else {
            var breaker = LineBreaker(attributed: attributed, width: width, windowLength: window)
            var start = 0
            // Lines broken another way (one typesetter, other windows) may
            // be shaped differently: those are not kept.
            let reuse = previous.flatMap { $0.windowLength == window ? Reuse(from: $0, to: cell, width: width) : nil }
            if let reuse, let previous {
                lines.append(contentsOf: previous.lines[0..<reuse.keptLines])
                start = lines.last?.range.upperBound ?? 0
            }
            while start < length {
                if let reuse, let previous, start >= reuse.newEditEnd, let j = reuse.oldLine(startingAt: start - reuse.delta, in: previous) {
                    // Line breaks are back in step: the rest is the old
                    // lines, moved.
                    for old in previous.lines[j...] where !old.range.isEmpty {
                        let top = CGFloat(lines.count) * lineHeight
                        lines.append(old.moved(by: reuse.delta, top: top,
                                               baseline: baseline(top: top, ascent: old.ascent, descent: old.descent, lineHeight: lineHeight)))
                    }
                    start = length
                    break
                }
                let (line, count, base) = breaker.line(from: start)
                lines.append(place(line, range: start..<(start + count), base: base))
                start += count
            }
            // A trailing newline opens an empty last line for the caret.
            if CFStringGetCharacterAtIndex(CFAttributedStringGetString(attributed), length - 1) == 0x0A {
                let empty = CTLineCreateWithAttributedString(attributed.attributedSubstring(from: NSRange(location: length - 1, length: 0)))
                lines.append(place(empty, range: length..<length, base: length))
            }
        }
        let decorations = decorationRects(for: cell, lines: lines)
        return CellLayout(typeset: cell, width: width, lines: lines, decorations: decorations, windowLength: window)
    }

    static func baseline(top: CGFloat, ascent: CGFloat, descent: CGFloat, lineHeight: CGFloat) -> CGFloat {
        (top + (lineHeight - (ascent + descent)) / 2 + ascent).rounded()
    }

    static func decorationRects(for cell: TypesetCell, lines: [LineFragment]) -> [DecorationRect] {
        guard !cell.decorations.isEmpty, !lines.isEmpty else { return [] }
        var result: [DecorationRect] = []
        for decoration in cell.decorations {
            // First line ending after the decoration's start (lines tile the text).
            var lo = 0, hi = lines.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if lines[mid].range.upperBound <= decoration.range.lowerBound { lo = mid + 1 } else { hi = mid }
            }
            var i = lo
            while i < lines.count, lines[i].range.lowerBound < decoration.range.upperBound {
                defer { i += 1 }
                let line = lines[i]
                let lo = max(line.range.lowerBound, decoration.range.lowerBound)
                let hi = min(line.range.upperBound, decoration.range.upperBound)
                guard lo < hi else { continue }
                let x0 = line.offset(for: lo)
                let x1 = line.offset(for: hi)
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

/// Suggests line breaks from any line start of one cell, through one
/// typesetter over the whole text or over a window of it that moves along
/// with the lines. A window starts at a line start, so each line is shaped
/// and broken as a typesetter over the whole text would, as long as it ends
/// well before the window is cut.
struct LineBreaker {
    let attributed: NSAttributedString
    let string: CFString
    let length: Int
    let width: CGFloat
    let windowLength: Int
    private var typesetter: CTTypesetter?
    private var windowStart = 0
    private var windowEnd = 0

    init(attributed: NSAttributedString, width: CGFloat, windowLength: Int) {
        self.attributed = attributed
        string = CFAttributedStringGetString(attributed)
        length = attributed.length
        self.width = width
        // An unbounded width sets the whole text on one line.
        self.windowLength = width.isFinite ? max(windowLength, 2 * LayoutEngine.windowTail) : .max
    }

    /// The line starting at `start`, its length, and the cell offset of the
    /// line's string index 0.
    mutating func line(from start: Int) -> (CTLine, Int, Int) {
        if typesetter == nil || start < windowStart || start >= windowEnd
            || (windowEnd < length && windowEnd - start < LayoutEngine.windowTail) {
            open(at: start, span: windowLength)
        }
        while true {
            let local = start - windowStart
            var count = width.isFinite ? CTTypesetterSuggestLineBreak(typesetter!, local, Double(width)) : windowEnd - start
            if count <= 0 { count = max(1, CTTypesetterSuggestClusterBreak(typesetter!, local, Double(width))) }
            if windowEnd < length, start + count > windowEnd - LayoutEngine.windowMargin {
                // The line may run past the window: widen it and try again.
                open(at: start, span: 2 * (windowEnd - start))
                continue
            }
            return (CTTypesetterCreateLine(typesetter!, CFRange(location: local, length: count)), count, windowStart)
        }
    }

    private mutating func open(at start: Int, span: Int) {
        var end = span >= length - start ? length : start + span
        // Never cut a surrogate pair.
        if end < length, (0xDC00...0xDFFF).contains(CFStringGetCharacterAtIndex(string, end)) { end += 1 }
        windowStart = start
        windowEnd = end
        typesetter = start == 0 && end == length
            ? CTTypesetterCreateWithAttributedString(attributed)
            : CTTypesetterCreateWithAttributedString(attributed.attributedSubstring(from: NSRange(location: start, length: end - start)))
    }
}

/// What an edit left of a cell's previous layout: the text before the first
/// changed character and after the last one (with their attributes), and
/// how many of the old lines are certainly unchanged.
struct Reuse {
    /// Old lines kept as they are: those ending before the line holding the
    /// first change, less one, since a shorter first word can pull back onto
    /// the line before.
    let keptLines: Int
    /// New length minus old length.
    let delta: Int
    /// End of the changed text in the new cell (the unchanged suffix starts here).
    let newEditEnd: Int

    init?(from old: CellLayout, to new: TypesetCell, width: CGFloat) {
        let oldCell = old.typeset
        guard old.width == width, oldCell.lineHeight == new.lineHeight, oldCell.flushFactor == new.flushFactor,
              oldCell.length > 0, new.length > 0, !old.lines.isEmpty else { return nil }
        let a: CFString = CFAttributedStringGetString(oldCell.attributed)
        let b: CFString = CFAttributedStringGetString(new.attributed)
        let oldLength = oldCell.length, newLength = new.length
        var prefix = Reuse.commonPrefix(a, b, limit: min(oldLength, newLength))
        var suffix = Reuse.commonSuffix(a, b, oldLength: oldLength, newLength: newLength, limit: min(oldLength, newLength) - prefix)
        prefix = Reuse.sameAttributes(oldCell.attributed, new.attributed, from: 0, to: prefix, shift: 0)
        let delta = newLength - oldLength
        let suffixStart = oldLength - suffix
        suffix = oldLength - Reuse.sameAttributesBackward(oldCell.attributed, new.attributed, from: suffixStart, to: oldLength, shift: delta)
        let first = old.lineIndex(containing: prefix)
        keptLines = max(0, first - 1)
        self.delta = delta
        newEditEnd = newLength - suffix
    }

    /// Index of the old line that starts at old offset `offset` in the
    /// unchanged suffix, if one does.
    func oldLine(startingAt offset: Int, in old: CellLayout) -> Int? {
        let lines = old.lines
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].range.lowerBound < offset { lo = mid + 1 } else { hi = mid }
        }
        guard lo < lines.count, lines[lo].range.lowerBound == offset, !lines[lo].range.isEmpty else { return nil }
        return lo
    }

    static let chunk = 4_096

    static func commonPrefix(_ a: CFString, _ b: CFString, limit: Int) -> Int {
        var bufferA = [UniChar](repeating: 0, count: chunk), bufferB = [UniChar](repeating: 0, count: chunk)
        var done = 0
        while done < limit {
            let n = min(chunk, limit - done)
            CFStringGetCharacters(a, CFRange(location: done, length: n), &bufferA)
            CFStringGetCharacters(b, CFRange(location: done, length: n), &bufferB)
            if memcmp(bufferA, bufferB, n * 2) != 0 {
                var k = 0
                while bufferA[k] == bufferB[k] { k += 1 }
                return done + k
            }
            done += n
        }
        return limit
    }

    static func commonSuffix(_ a: CFString, _ b: CFString, oldLength: Int, newLength: Int, limit: Int) -> Int {
        var bufferA = [UniChar](repeating: 0, count: chunk), bufferB = [UniChar](repeating: 0, count: chunk)
        var done = 0
        while done < limit {
            let n = min(chunk, limit - done)
            CFStringGetCharacters(a, CFRange(location: oldLength - done - n, length: n), &bufferA)
            CFStringGetCharacters(b, CFRange(location: newLength - done - n, length: n), &bufferB)
            if memcmp(bufferA, bufferB, n * 2) != 0 {
                var k = 0
                while bufferA[n - 1 - k] == bufferB[n - 1 - k] { k += 1 }
                return done + k
            }
            done += n
        }
        return limit
    }

    /// The first old offset in `from..<to` where the attributes differ from
    /// the new cell's at the same offset plus `shift` (`to` when none do).
    static func sameAttributes(_ old: NSAttributedString, _ new: NSAttributedString, from: Int, to: Int, shift: Int) -> Int {
        var p = from
        while p < to {
            var ro = NSRange(), rn = NSRange()
            let ao = old.attributes(at: p, effectiveRange: &ro)
            let an = new.attributes(at: p + shift, effectiveRange: &rn)
            guard NSDictionary(dictionary: ao).isEqual(to: an) else { return p }
            p = min(ro.upperBound, rn.upperBound - shift)
        }
        return to
    }

    /// The last old offset in `from..<to` where the attributes differ from
    /// the new cell's, plus one (`from` when none do).
    static func sameAttributesBackward(_ old: NSAttributedString, _ new: NSAttributedString, from: Int, to: Int, shift: Int) -> Int {
        var p = to
        while p > from {
            var ro = NSRange(), rn = NSRange()
            let ao = old.attributes(at: p - 1, effectiveRange: &ro)
            let an = new.attributes(at: p - 1 + shift, effectiveRange: &rn)
            guard NSDictionary(dictionary: ao).isEqual(to: an) else { return p }
            p = max(ro.location, rn.location - shift)
        }
        return from
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
    /// Header row and line-number gutter of a code block.
    public let code: CodeChrome?
    /// The picture of an image island (P0-07).
    public let image: ImageChrome?

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
         tableSpacing: CGFloat = 0, code: CodeChrome? = nil, image: ImageChrome? = nil) {
        self.id = id
        self.code = code
        self.image = image
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
                              previous: BlockLayout? = nil, growOnly: Bool = false,
                              codeOptions: CodeBlockOptions = CodeBlockOptions(),
                              images: ImageStore? = nil, imageBase: ImageBase = ImageBase()) -> BlockLayout {
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

        if case .code(let info, let isFenced) = block.role {
            return layoutCode(block, info: info, isFenced: isFenced, typesetter: typesetter, width: width, indent: indent,
                              style: style, options: codeOptions)
        }

        if let image = block.image {
            return layoutImage(block, image: image, typesetter: typesetter, measure: measure, width: width, indent: indent,
                               style: style, status: images?.status(of: image, base: imageBase) ?? .pending, base: imageBase)
        }

        let typesetCell = typesetter.typeset(block.cells[0], in: block, cellIndex: 0)
        // A long cell keeps the lines of its previous layout that an edit
        // left alone (typing in a 1 MB paragraph re-breaks a few lines).
        var prior: CellLayout?
        if typesetCell.length >= windowThreshold, let previous, previous.table == nil, previous.code == nil, previous.image == nil,
           previous.cellCount == 1 {
            prior = previous.cell(0)
        }
        let cell = typeset(typesetCell, width: width - 2 * style.paddingX, previous: prior)
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
        if let image = block.image {
            let column = max(80, measure - indent(for: block.context, scale: scale)) - 2 * style.paddingX
            let size = imageSize(for: image, pixels: nil, column: column, zoom: scale.zoom)
            return (image.isFolded ? max(size.height, style.lineHeight) : size.height + style.lineHeight + scale.l(6)) + 2 * style.paddingY
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
