/// Value AST produced by `LipiParser` (PRD ADR-003).
///
/// Every node carries a byte range into the source. Inside a `BlockIndex`
/// entry the ranges are *local*: relative to the start of the entry's span, so
/// that edits earlier in the document shift a whole top-level block without
/// touching its subtree. `BlockIndex.absoluteBlock(at:)` rebases a block into
/// document coordinates when a consumer needs them.

/// Identity of a node. Stable across incremental re-parses for every node
/// outside the re-parsed region.
public struct NodeID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static func < (a: NodeID, b: NodeID) -> Bool { a.rawValue < b.rawValue }
    public var description: String { "#\(rawValue)" }
}

/// Hands out node identities. The parser owns one so identities are never
/// reused within a document.
public struct NodeIDGenerator: Sendable {
    private var next: UInt64 = 1
    public init() {}
    public mutating func make() -> NodeID {
        defer { next += 1 }
        return NodeID(rawValue: next)
    }
}

public enum ListDelimiter: Sendable, Hashable { case period, parenthesis }

public struct ListInfo: Sendable, Hashable {
    public var isOrdered: Bool
    /// Start number of an ordered list; 1 for bullet lists.
    public var start: Int
    public var delimiter: ListDelimiter
    /// Marker byte of a bullet list (`-`, `+` or `*`); `nil` for ordered lists.
    public var bullet: UInt8?
    public var isTight: Bool
}

public enum TaskState: Sendable, Hashable { case unchecked, checked }

public enum FrontMatterKind: Sendable, Hashable { case yaml, toml }

public enum ColumnAlignment: Sendable, Hashable { case none, left, center, right }

public struct CodeBlockInfo: Sendable, Hashable {
    public var isFenced: Bool
    /// Info string of a fenced block (`swift` in ```` ```swift ````); empty otherwise.
    public var info: String
    /// Range of the code text: the lines between the fences, or the whole block
    /// for indented code. Same coordinate system as the block's `range`.
    public var contentRange: Range<Int>
    /// True when a fenced block ends with a closing fence.
    public var isClosed: Bool
}

public struct ReferenceDefinition: Sendable, Hashable {
    /// Raw label as written between the brackets.
    public var label: String
    /// Raw destination as written (angle brackets and escapes intact).
    public var destination: String
    /// Raw title including its delimiters, or an empty string.
    public var title: String
}

public enum BlockKind: Sendable, Hashable {
    case paragraph
    case heading(level: Int, isSetext: Bool)
    case blockQuote
    case list(ListInfo)
    case listItem(task: TaskState?)
    case codeBlock(CodeBlockInfo)
    case htmlBlock(type: Int)
    case thematicBreak
    case table(alignments: [ColumnAlignment])
    case tableRow(isHeader: Bool)
    case tableCell
    case footnoteDefinition(label: String)
    case frontMatter(FrontMatterKind)
    case linkReferenceDefinition(ReferenceDefinition)

    /// Container blocks hold blocks; leaf blocks hold inlines.
    public var isContainer: Bool {
        switch self {
        case .blockQuote, .list, .listItem, .footnoteDefinition, .table, .tableRow: return true
        default: return false
        }
    }
}

public enum InlineKind: Sendable, Hashable {
    case text(String)
    case softBreak
    case lineBreak
    case code(String)
    case html(String)
    case emphasis
    case strong
    case strikethrough
    case link(destination: String, title: String, isAutolink: Bool)
    case image(destination: String, title: String)
    case footnoteReference(label: String)
    case math(String, isDisplay: Bool)
}

public struct Inline: Sendable, Hashable {
    public var id: NodeID
    /// Byte range including delimiters (`**`, backticks, brackets).
    public var range: Range<Int>
    public var kind: InlineKind
    public var children: [Inline]
    /// True when the range was recovered from decoded text (autolinks found in
    /// text containing entities) and may be off by the width of an escape.
    public var isApproximate: Bool

    public init(id: NodeID, range: Range<Int>, kind: InlineKind, children: [Inline] = [], isApproximate: Bool = false) {
        self.id = id
        self.range = range
        self.kind = kind
        self.children = children
        self.isApproximate = isApproximate
    }

    /// Equality that ignores node identity.
    public func isStructurallyEqual(to other: Inline) -> Bool {
        guard range == other.range, kind == other.kind, isApproximate == other.isApproximate,
              children.count == other.children.count else { return false }
        for (a, b) in zip(children, other.children) where !a.isStructurallyEqual(to: b) { return false }
        return true
    }
}

public struct Block: Sendable, Hashable {
    public var id: NodeID
    /// Byte range of the block's source, from its first marker to the end of
    /// its last line's content (line terminator excluded).
    public var range: Range<Int>
    public var kind: BlockKind
    public var children: [Block]
    public var inlines: [Inline]

    public init(id: NodeID, range: Range<Int>, kind: BlockKind, children: [Block] = [], inlines: [Inline] = []) {
        self.id = id
        self.range = range
        self.kind = kind
        self.children = children
        self.inlines = inlines
    }

    /// Equality that ignores node identity.
    public func isStructurallyEqual(to other: Block) -> Bool {
        guard range == other.range, kind == other.kind,
              children.count == other.children.count, inlines.count == other.inlines.count else { return false }
        for (a, b) in zip(inlines, other.inlines) where !a.isStructurallyEqual(to: b) { return false }
        for (a, b) in zip(children, other.children) where !a.isStructurallyEqual(to: b) { return false }
        return true
    }

    /// The same tree with every range shifted by `delta`.
    public func shifted(by delta: Int) -> Block {
        if delta == 0 { return self }
        var copy = self
        copy.shift(by: delta)
        return copy
    }

    mutating func shift(by delta: Int) {
        range = (range.lowerBound + delta)..<(range.upperBound + delta)
        if case .codeBlock(var info) = kind {
            info.contentRange = (info.contentRange.lowerBound + delta)..<(info.contentRange.upperBound + delta)
            kind = .codeBlock(info)
        }
        for i in children.indices { children[i].shift(by: delta) }
        for i in inlines.indices { inlines[i].shift(by: delta) }
    }

    /// Depth-first visit of this block and its descendants.
    public func forEachBlock(_ body: (Block) throws -> Void) rethrows {
        try body(self)
        for child in children { try child.forEachBlock(body) }
    }
}

extension Inline {
    mutating func shift(by delta: Int) {
        range = (range.lowerBound + delta)..<(range.upperBound + delta)
        for i in children.indices { children[i].shift(by: delta) }
    }

    public func forEachInline(_ body: (Inline) throws -> Void) rethrows {
        try body(self)
        for child in children { try child.forEachInline(body) }
    }
}
