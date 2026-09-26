import CCmarkGFM

/// Which nodes show their Markdown syntax (PRD §6.1.2–6.1.3).
///
/// Every rule is caret-anchored, so all revealed nodes live in the top-level
/// block that contains the caret; `entry` names it so `Projection` can tell
/// which entries a change of caret affects.
public struct RevealSet: Sendable, Hashable {
    /// Source mode: everything visible, no folding.
    public var all = false
    /// Top-level block holding every revealed node; nil when nothing is revealed.
    public var entry: NodeID? = nil
    /// Block-level nodes showing their markers: headings, quotes, list items,
    /// fences, rules, front matter, footnote definitions.
    public var blocks: Set<NodeID> = []
    /// Inline nodes showing their delimiters.
    public var inlines: Set<NodeID> = []
    /// Links whose destination is shown in full rather than as a chip.
    public var expandedLinks: Set<NodeID> = []
    /// Absolute source offsets of backslash escapes and entities shown raw.
    public var escapes: Set<Int> = []

    public init() {}

    public static let none = RevealSet()
    public static var everything: RevealSet {
        var set = RevealSet()
        set.all = true
        return set
    }

    public var isEmpty: Bool {
        !all && blocks.isEmpty && inlines.isEmpty && expandedLinks.isEmpty && escapes.isEmpty
    }
}

/// The three reveal presets of §6.1.3.
public struct RevealPreset: Sendable, Hashable {
    public enum InlineDelimiters: Sendable, Hashable {
        /// Delimiters appear when the caret enters the node.
        case onEntry
        /// Delimiters are always visible in `syntax` colour (iA Writer).
        case always
    }
    public enum LinkDestination: Sendable, Hashable {
        /// Brackets and a chip on entry; the destination expands when entered.
        case chipThenFull
        /// The whole source on entry (Typora).
        case fullOnEntry
        /// Brackets always, destination always a chip.
        case alwaysChip
    }
    public enum BlockMarkers: Sendable, Hashable {
        /// Markers live in the gutter and never shift the text.
        case gutter
        /// Markers appear inline when revealed; the layout compensates the shift.
        case inline
    }

    public var inlineDelimiters: InlineDelimiters
    public var linkDestination: LinkDestination
    public var blockMarkers: BlockMarkers

    public init(inlineDelimiters: InlineDelimiters, linkDestination: LinkDestination, blockMarkers: BlockMarkers) {
        self.inlineDelimiters = inlineDelimiters
        self.linkDestination = linkDestination
        self.blockMarkers = blockMarkers
    }

    public static let balanced = RevealPreset(inlineDelimiters: .onEntry, linkDestination: .chipThenFull, blockMarkers: .gutter)
    public static let typoraCompatible = RevealPreset(inlineDelimiters: .onEntry, linkDestination: .fullOnEntry, blockMarkers: .inline)
    public static let stable = RevealPreset(inlineDelimiters: .always, linkDestination: .alwaysChip, blockMarkers: .gutter)
}

/// Computes the `RevealSet` for a caret position (PRD §6.1.2 rules).
public struct RevealPolicy: Sendable {
    public var preset: RevealPreset

    public init(preset: RevealPreset = .balanced) {
        self.preset = preset
    }

    /// The reveal set for a caret at absolute byte `caret`. Selection reveal
    /// follows the active end only, so callers pass that end.
    public func revealSet(caret: Int, index: BlockIndex, rope: LipiRope) -> RevealSet {
        var set = RevealSet()
        guard let i = index.entryIndex(containing: caret) else { return set }
        // Scan in the entry's local coordinates: rebasing a large block (a
        // table of thousands of cells) would cost more than the scan.
        let entryStart = index.start(of: i)
        let block = index.entries[i].block
        set.entry = block.id
        var scanner = Scanner(caret: caret - entryStart, base: entryStart, preset: preset, rope: rope, set: set)
        scanner.visit(block, isFirstLeafOfItem: false)
        return scanner.set
    }

    private struct Scanner {
        /// Caret, local to the entry.
        let caret: Int
        /// Absolute start of the entry; `rope` offsets are `base + local`.
        let base: Int
        let preset: RevealPreset
        let rope: LipiRope
        var set: RevealSet

        init(caret: Int, base: Int, preset: RevealPreset, rope: LipiRope, set: RevealSet) {
            self.caret = caret
            self.base = base
            self.preset = preset
            self.rope = rope
            self.set = set
        }

        func within(_ r: Range<Int>) -> Bool { caret >= r.lowerBound && caret <= r.upperBound }
        func inside(_ r: Range<Int>) -> Bool { caret >= r.lowerBound && caret < r.upperBound }

        /// First line of a block: from its start to its first newline.
        func onFirstLine(of r: Range<Int>) -> Bool {
            guard within(r) else { return false }
            let lineEnd = rope.lineRange(rope.line(at: base + r.lowerBound)).upperBound - base
            return caret <= min(lineEnd, r.upperBound)
        }

        mutating func visit(_ block: Block, isFirstLeafOfItem: Bool) {
            let r = block.range
            switch block.kind {
            case .heading, .thematicBreak, .frontMatter:
                if within(r) { set.blocks.insert(block.id) }
            case .blockQuote, .footnoteDefinition:
                if within(r) { set.blocks.insert(block.id) }
            case .listItem:
                if onFirstLine(of: r) { set.blocks.insert(block.id) }
            case .codeBlock(let info):
                if info.isFenced, within(r) {
                    let onOpening = caret < info.contentRange.lowerBound
                    let onClosing = info.isClosed && caret >= info.contentRange.upperBound
                    if onOpening || onClosing || info.contentRange.isEmpty { set.blocks.insert(block.id) }
                }
            case .paragraph:
                if block.isTableOfContents, within(r) { set.blocks.insert(block.id) }
            case .list, .table, .tableRow, .tableCell, .htmlBlock, .linkReferenceDefinition:
                break
            }
            guard within(r) || block.kind == .paragraph else { return }
            for inline in block.inlines { visit(inline, lineContext: r) }
            for child in block.children where within(child.range) {
                visit(child, isFirstLeafOfItem: false)
            }
        }

        mutating func visit(_ inline: Inline, lineContext: Range<Int>) {
            let r = inline.range
            switch inline.kind {
            case .text(let literal):
                if within(r) { scanEscapes(in: r, literal: literal, approximate: inline.isApproximate) }
                return
            case .softBreak:
                return
            case .lineBreak:
                // Caret on the line that ends with the break, or right after it.
                let lineStart = rope.lineRange(rope.line(at: base + r.lowerBound)).lowerBound - base
                if caret >= max(lineStart, lineContext.lowerBound), caret <= r.upperBound { set.inlines.insert(inline.id) }
                return
            case .code, .html, .math, .footnoteReference, .emphasis, .strong, .strikethrough, .image,
                 .subscript, .superscript, .highlight, .emoji, .attributes:
                if within(r) { set.inlines.insert(inline.id) }
            case .link(_, _, let isAutolink):
                guard !isAutolink, within(r) else { break }
                set.inlines.insert(inline.id)
                switch preset.linkDestination {
                case .fullOnEntry:
                    set.expandedLinks.insert(inline.id)
                case .chipThenFull:
                    let labelEnd = inline.children.last.map(\.range.upperBound) ?? r.lowerBound + 1
                    let bracket = closingBracket(after: labelEnd, before: r.upperBound)
                    if caret > bracket, caret < r.upperBound { set.expandedLinks.insert(inline.id) }
                case .alwaysChip:
                    break
                }
            }
            guard within(r) else { return }
            for child in inline.children { visit(child, lineContext: lineContext) }
        }

        /// Position after the `]` that closes a link label.
        func closingBracket(after start: Int, before end: Int) -> Int {
            var p = start
            let bytes = Array(rope.string(in: (base + start)..<(base + end)).utf8)
            for (i, b) in bytes.enumerated() where b == 0x5D { p = start + i + 1; break }
            return p
        }

        mutating func scanEscapes(in r: Range<Int>, literal: String, approximate: Bool) {
            guard !approximate else { return }
            var text = rope.string(in: (base + r.lowerBound)..<(base + r.upperBound))
            guard text != literal else { return }
            text.withUTF8 { bytes in
                TextScanner.forEachSequence(in: bytes, base: r.lowerBound) { range, _ in
                    if caret >= range.lowerBound && caret <= range.upperBound { set.escapes.insert(base + range.lowerBound) }
                }
            }
        }
    }
}

/// Finds backslash escapes and entities in raw text.
enum TextScanner {
    /// Calls `body` with the absolute range of every escape or entity in
    /// `bytes` (whose first byte sits at absolute offset `base`) and the
    /// decoded UTF-8 it stands for.
    static func forEachSequence(in bytes: UnsafeBufferPointer<UInt8>, base: Int,
                                _ body: (Range<Int>, [UInt8]) -> Void) {
        var p = 0
        let n = bytes.count
        var out = [UInt8](repeating: 0, count: 16)
        while p < n {
            let b = bytes[p]
            if b == 0x5C, p + 1 < n, isASCIIPunctuation(bytes[p + 1]) {
                body((base + p)..<(base + p + 2), [bytes[p + 1]])
                p += 2
            } else if b == 0x26 {
                var outLen: Int32 = 0
                let consumed = out.withUnsafeMutableBufferPointer { o in
                    lipi_decode_entity(bytes.baseAddress! + p, Int32(min(n - p, 40)), o.baseAddress, 16, &outLen)
                }
                if consumed > 0 {
                    body((base + p)..<(base + p + Int(consumed)), Array(out[0..<Int(outLen)]))
                    p += Int(consumed)
                } else {
                    p += 1
                }
            } else {
                p += 1
            }
        }
    }

    static func isASCIIPunctuation(_ b: UInt8) -> Bool {
        (b >= 0x21 && b <= 0x2F) || (b >= 0x3A && b <= 0x40) || (b >= 0x5B && b <= 0x60) || (b >= 0x7B && b <= 0x7E)
    }
}
