/// The projected document: what the editor lays out and draws (PRD §6.1.1).
///
/// A `DisplayBlock` is one layout unit: a leaf block of the AST (paragraph,
/// heading, code block, table, rule…) with its container context folded in.
/// Blocks tile their top-level entry's source span, so every source byte
/// belongs to exactly one block, and within a block to exactly one cell.
/// Ordinary blocks have one cell; a table has one per table cell.

/// Character styling that the layout maps to fonts and colours.
public struct InlineStyle: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let emphasis = InlineStyle(rawValue: 1 << 0)
    public static let strong = InlineStyle(rawValue: 1 << 1)
    public static let strikethrough = InlineStyle(rawValue: 1 << 2)
    public static let code = InlineStyle(rawValue: 1 << 3)
    public static let link = InlineStyle(rawValue: 1 << 4)
    public static let image = InlineStyle(rawValue: 1 << 5)
    public static let math = InlineStyle(rawValue: 1 << 6)
    public static let html = InlineStyle(rawValue: 1 << 7)
    /// Markdown syntax shown while revealed: delimiters, markers, escapes.
    public static let syntax = InlineStyle(rawValue: 1 << 8)
    public static let footnoteReference = InlineStyle(rawValue: 1 << 9)
    /// A one-character stand-in for a folded link destination.
    public static let chip = InlineStyle(rawValue: 1 << 10)
    /// A `↵` shown for a revealed hard break.
    public static let lineBreak = InlineStyle(rawValue: 1 << 11)
    /// `~x~`, `^x^` and `==x==` (opt-in syntax).
    public static let `subscript` = InlineStyle(rawValue: 1 << 12)
    public static let superscript = InlineStyle(rawValue: 1 << 13)
    public static let highlight = InlineStyle(rawValue: 1 << 14)
}

/// A maximal run of display text (UTF-16 range) with one style.
public struct StyleRun: Sendable, Hashable {
    public var range: Range<Int>
    public var style: InlineStyle
    public init(range: Range<Int>, style: InlineStyle) {
        self.range = range
        self.style = style
    }
}

/// One text container of a display block.
public struct DisplayCell: Sendable, Hashable {
    /// Source bytes this cell owns, local to the entry. Includes hidden
    /// structure before and after the cell's own content.
    public var sourceRange: Range<Int>
    public var text: String
    public var runs: [StyleRun]
    public var map: OffsetMap

    public init(sourceRange: Range<Int>, text: String, runs: [StyleRun], map: OffsetMap) {
        self.sourceRange = sourceRange
        self.text = text
        self.runs = runs
        self.map = map
    }

    public static func empty(at offset: Int) -> DisplayCell {
        DisplayCell(sourceRange: offset..<offset, text: "", runs: [],
                    map: OffsetMap(segments: [], sourceRange: offset..<offset, displayLength: 0, displayLengthUTF8: 0))
    }

    /// Moves the cell's source side by `delta` bytes (its text is unchanged).
    mutating func shift(by delta: Int) {
        sourceRange = (sourceRange.lowerBound + delta)..<(sourceRange.upperBound + delta)
        map.shift(by: delta)
    }

    /// Display offset (UTF-16) of a local source offset.
    public func displayOffset(forSource offset: Int) -> Int {
        withUTF8 { map.sourceToDisplay(offset, utf8: $0) }
    }

    /// Local source offset of a display offset (UTF-16).
    public func sourceOffset(forDisplay offset: Int) -> Int {
        withUTF8 { map.displayToSource(offset, utf8: $0) }
    }

    @inline(__always)
    func withUTF8<R>(_ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        var text = self.text
        return text.withUTF8(body)
    }
}

/// Which kind of leaf the block projects.
public enum BlockRole: Sendable, Hashable {
    case paragraph
    case heading(level: Int)
    case code(info: String, isFenced: Bool)
    case html
    case thematicBreak
    case table
    case frontMatter
    case linkReferenceDefinition
}

/// How a list item's marker is drawn in the hanging-indent column.
public struct ListMarker: Sendable, Hashable {
    /// The literal marker as written, without trailing space (`-`, `3.`, `1)`).
    public var literal: String
    public var isOrdered: Bool
    /// Ordinal of the item within its list (1-based).
    public var ordinal: Int
    public var number: Int
    public var task: TaskState?
}

/// Container context of a display block.
public struct BlockContext: Sendable, Hashable {
    public var quoteDepth: Int = 0
    public var listDepth: Int = 0
    /// Set on the first leaf of a list item.
    public var marker: ListMarker? = nil
    /// Set on the first leaf of a footnote definition.
    public var footnoteLabel: String? = nil
    /// The definition's number in document order of first reference (§6.13);
    /// nil for a definition no reference uses.
    public var footnoteNumber: Int? = nil
    /// The first definition of a run of top-level definitions: the start of
    /// a footnotes region, drawn with a rule above it.
    public var footnoteRegionStart = false
    /// Any container this block sits in is loose (paragraph spacing applies).
    public var isLoose: Bool = false
    /// A problem shown beside the block (malformed front matter, §6.13).
    public var warning: String? = nil
    /// A `[toc]` placeholder showing the document's headings, one per line
    /// (`Projection.tableOfContents`).
    public var isTableOfContents = false
    public init() {}
}

/// Column and row structure of a table block.
public struct TableShape: Sendable, Hashable {
    public var alignments: [ColumnAlignment]
    public var columns: Int
    /// Cell index → (row, column); rows are in source order, row 0 the header.
    public var rows: Int
    public init(alignments: [ColumnAlignment], columns: Int, rows: Int) {
        self.alignments = alignments
        self.columns = columns
        self.rows = rows
    }
    public func cellIndex(row: Int, column: Int) -> Int { row * columns + column }
    public func position(ofCell index: Int) -> (row: Int, column: Int) { (index / columns, index % columns) }
}

public struct DisplayBlock: Sendable, Hashable {
    /// Identity of the projected leaf block.
    public var id: NodeID
    /// Source bytes this block owns, local to the entry; the union of its cells.
    public var sourceRange: Range<Int>
    public var role: BlockRole
    public var context: BlockContext
    /// The block is in the reveal set (markers shown at full strength).
    public var isRevealed: Bool
    public var cells: [DisplayCell]
    public var table: TableShape?
    /// A fenced code block with no closing fence: it runs to the end of its
    /// container (the code header shows an "unclosed" pill, §6.5).
    public var isUnclosedFence: Bool
    /// Deterministic hash of the visible content (text, runs, role, context,
    /// reveal state) for layout caching; independent of the block's position.
    public var layoutKey: UInt64
    /// A table's per-row content hashes, which `layoutKey` combines, so that
    /// re-projecting one row rehashes only that row. Empty for other blocks.
    var rowKeys: [UInt64] = []

    public init(id: NodeID, sourceRange: Range<Int>, role: BlockRole, context: BlockContext, isRevealed: Bool,
                cells: [DisplayCell], table: TableShape? = nil, isUnclosedFence: Bool = false) {
        self.id = id
        self.isUnclosedFence = isUnclosedFence
        self.sourceRange = sourceRange
        self.role = role
        self.context = context
        self.isRevealed = isRevealed
        self.cells = cells
        self.table = table
        self.layoutKey = 0
        if let table { rowKeys = (0..<table.rows).map(rowKey) }
        self.layoutKey = computeLayoutKey()
    }

    /// A table block whose cells differ from `old`'s only in `changedRows`
    /// (and in source offsets, which the key ignores).
    init(table old: DisplayBlock, sourceRange: Range<Int>, cells: [DisplayCell], changedRows: [Int]) {
        id = old.id
        self.sourceRange = sourceRange
        role = old.role
        context = old.context
        isRevealed = old.isRevealed
        isUnclosedFence = false
        self.cells = cells
        table = old.table
        rowKeys = old.rowKeys
        layoutKey = 0
        for r in changedRows { rowKeys[r] = rowKey(r) }
        layoutKey = computeLayoutKey()
    }

    /// The cell whose source range contains `offset` (local); the last cell
    /// for offsets at or past the end.
    public func cellIndex(containingSource offset: Int) -> Int {
        var lo = 0, hi = cells.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if cells[mid].sourceRange.lowerBound <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private func computeLayoutKey() -> UInt64 {
        var h = FNV1a()
        h.combine(role)
        h.combine(context)
        h.combine(isRevealed ? 1 : 0)
        if isUnclosedFence { h.combine(2) }
        if let table {
            h.combine(table.columns); h.combine(table.rows); for a in table.alignments { h.combine(a) }
            for k in rowKeys { h.combine(Int(bitPattern: UInt(k))) }
            return h.value
        }
        for cell in cells { h.combine(cell) }
        return h.value
    }

    private func rowKey(_ row: Int) -> UInt64 {
        var h = FNV1a()
        guard let table else { return 0 }
        let first = row * table.columns
        for c in first..<min(first + table.columns, cells.count) { h.combine(cells[c]) }
        return h.value
    }
}

/// A caret position in the projected document.
public struct DisplayPosition: Sendable, Hashable, Comparable {
    /// Index into `Projection.entries`.
    public var entry: Int
    /// Index into the entry's `blocks`.
    public var block: Int
    public var cell: Int
    /// UTF-16 offset in the cell's text.
    public var offset: Int

    public init(entry: Int, block: Int, cell: Int, offset: Int) {
        self.entry = entry
        self.block = block
        self.cell = cell
        self.offset = offset
    }

    public static func < (a: DisplayPosition, b: DisplayPosition) -> Bool {
        (a.entry, a.block, a.cell, a.offset) < (b.entry, b.block, b.cell, b.offset)
    }
}

/// 64-bit FNV-1a over Swift values, stable across processes (unlike `Hasher`).
struct FNV1a {
    var value: UInt64 = 0xCBF2_9CE4_8422_2325

    mutating func combine(_ byte: UInt8) {
        value ^= UInt64(byte)
        value = value &* 0x100_0000_01B3
    }
    mutating func combine(_ int: Int) {
        var v = UInt64(bitPattern: Int64(int))
        for _ in 0..<8 { combine(UInt8(truncatingIfNeeded: v)); v >>= 8 }
    }
    mutating func combine(_ s: String) {
        var s = s
        s.withUTF8 { for b in $0 { combine(b) } }
        combine(0xFF)
    }
    mutating func combine(_ cell: DisplayCell) {
        combine(cell.text)
        for run in cell.runs {
            combine(run.range.lowerBound); combine(run.range.upperBound); combine(Int(run.style.rawValue))
        }
        combine(0x1F)
    }
    mutating func combine(_ role: BlockRole) {
        switch role {
        case .paragraph: combine(1)
        case .heading(let level): combine(2); combine(level)
        case .code(let info, let isFenced): combine(3); combine(info); combine(isFenced ? 1 : 0)
        case .html: combine(4)
        case .thematicBreak: combine(5)
        case .table: combine(6)
        case .frontMatter: combine(7)
        case .linkReferenceDefinition: combine(8)
        }
    }
    mutating func combine(_ c: BlockContext) {
        combine(c.quoteDepth); combine(c.listDepth); combine(c.isLoose ? 1 : 0)
        if let m = c.marker {
            combine(m.literal); combine(m.isOrdered ? 1 : 0); combine(m.ordinal); combine(m.number)
            combine(m.task == nil ? 0 : m.task == .checked ? 2 : 1)
        } else { combine(-1) }
        if let f = c.footnoteLabel { combine(f) } else { combine(-1) }
        combine(c.footnoteNumber ?? -1); combine(c.footnoteRegionStart ? 1 : 0)
    }
    mutating func combine(_ a: ColumnAlignment) {
        switch a {
        case .none: combine(0)
        case .left: combine(1)
        case .center: combine(2)
        case .right: combine(3)
        }
    }
}
