import Foundation
import LipiCore

/// How the editor presents the document: hybrid live preview (§6.1) or
/// plain source with syntax colouring (§6.2).
public enum EditorMode: Sendable, Hashable {
    case hybrid
    case source
}

/// Editor settings that change the bytes commands write (§6.1.5).
public struct EditorSettings: Sendable, Hashable {
    public enum HardBreak: Sendable, Hashable {
        /// `\` before the line terminator (default: editors strip trailing spaces).
        case backslash
        /// Two trailing spaces.
        case twoSpaces
    }

    /// Emphasis delimiter written by Cmd-I: `*` (default) or `_`.
    public var emphasisMarker: Character = "*"
    public var hardBreak: HardBreak = .backslash
    /// Auto-pair `*`, `_`, backtick, `[`, `(`, `$`, `"` and `“`.
    public var autoPair = true
    /// Settings → Complete tables on Enter (§6.1.5): `| a | b |` then Enter
    /// writes the delimiter row and an empty body row.
    public var completeTables = true

    public init(emphasisMarker: Character = "*", hardBreak: HardBreak = .backslash, autoPair: Bool = true,
                completeTables: Bool = true) {
        self.emphasisMarker = emphasisMarker
        self.hardBreak = hardBreak
        self.autoPair = autoPair
        self.completeTables = completeTables
    }
}

/// What a command does: edits in the coordinates of the document before the
/// command (non-overlapping, any order) and the selection afterwards, in
/// the coordinates after all edits.
public struct EditPlan: Sendable, Equatable {
    public var edits: [Edit]
    public var anchor: Int
    public var head: Int

    public init(edits: [Edit], anchor: Int, head: Int) {
        self.edits = edits
        self.anchor = anchor
        self.head = head
    }
}

/// Collects edits and maps positions from before them to after them.
struct PlanBuilder {
    private(set) var edits: [Edit] = []

    mutating func replace(_ r: Range<Int>, _ text: String) {
        guard !(r.isEmpty && text.isEmpty) else { return }
        edits.append(Edit(replacing: r, with: text))
    }

    mutating func insert(_ text: String, at p: Int) { replace(p..<p, text) }

    /// Maps `p` through the edits. At an insertion point, `after` puts the
    /// position after the inserted text; inside a replaced range it lands at
    /// the replacement's start (or end with `after`).
    func map(_ p: Int, after: Bool) -> Int {
        var shift = 0
        var inside: (lower: Int, inserted: Int)? = nil
        for e in edits {
            let r = e.range.byteRange
            if r.upperBound < p || (r.upperBound == p && !r.isEmpty) {
                shift += e.insertedBytes - r.count
            } else if r.isEmpty, r.lowerBound == p {
                if after { shift += e.insertedBytes }
            } else if r.lowerBound < p, p < r.upperBound {
                inside = (r.lowerBound, e.insertedBytes)
            }
        }
        if let inside { return inside.lower + shift + (after ? inside.inserted : 0) }
        return p + shift
    }

    func plan(anchor: Int, anchorAfter: Bool = false, head: Int, headAfter: Bool = true) -> EditPlan {
        EditPlan(edits: edits, anchor: map(anchor, after: anchorAfter), head: map(head, after: headAfter))
    }

    /// Caret at an explicit final offset.
    func plan(caret: Int) -> EditPlan { EditPlan(edits: edits, anchor: caret, head: caret) }
}

// MARK: - Line prefixes

/// The container and marker structure at the start of one source line.
struct LinePrefix {
    var start: Int
    /// Content end (before the terminator).
    var end: Int
    /// After `>` markers and the optional space after each.
    var quoteEnd: Int
    var quoteDepth = 0
    /// After the whitespace that follows the quote prefix.
    var indentEnd: Int
    var marker: Range<Int>? = nil
    var isOrdered = false
    var number = 0
    /// `.` or `)` for ordered markers, the bullet for unordered ones.
    var markerChar: UInt8 = 0x2D
    /// After the marker and its spacing.
    var markerEnd: Int
    /// The `[ ]` box of a task item.
    var task: Range<Int>? = nil
    /// After the task box and one space.
    var taskEnd: Int
    /// The `#` run of an ATX heading.
    var heading: Range<Int>? = nil
    /// Where the line's inline content starts.
    var contentStart: Int

    var hasMarker: Bool { marker != nil }
    var isBlank: Bool { contentStart >= end }
    /// Start of the structure a list/heading command rewrites.
    var structureStart: Int { marker?.lowerBound ?? heading?.lowerBound ?? indentEnd }
}

/// Read access to the document for commands: bytes, lines and the AST.
struct CommandDocument {
    let rope: LipiRope
    let index: BlockIndex

    var count: Int { rope.count }

    func byte(_ p: Int) -> UInt8 { rope.byte(at: p) }
    func string(_ r: Range<Int>) -> String { rope.string(in: r) }
    func bytes(_ r: Range<Int>) -> [UInt8] { Array(rope.string(in: r).utf8) }

    func lineStart(_ p: Int) -> Int { rope.lineStart(rope.line(at: min(max(p, 0), count))) }

    /// End of the line's content, before `\n` or `\r\n`.
    func lineContentEnd(_ p: Int) -> Int {
        let r = rope.lineRange(rope.line(at: min(max(p, 0), count)))
        var e = r.upperBound
        if e > r.lowerBound, byte(e - 1) == 0x0A {
            e -= 1
            if e > r.lowerBound, byte(e - 1) == 0x0D { e -= 1 }
        }
        return e
    }

    /// After the line's terminator (the next line's start).
    func lineEnd(_ p: Int) -> Int { rope.lineRange(rope.line(at: min(max(p, 0), count))).upperBound }

    /// The terminator of the line containing `p`, if it has one.
    func terminator(at p: Int) -> String? {
        let ce = lineContentEnd(p), e = lineEnd(p)
        return ce < e ? string(ce..<e) : nil
    }

    /// Line terminator to write near `p`: the line's own, else the previous
    /// line's, else `\n`.
    func eol(near p: Int) -> String {
        if let t = terminator(at: p) { return t }
        let s = lineStart(p)
        if s > 0, let t = terminator(at: s - 1) { return t }
        return "\n"
    }

    /// Starts of the lines a range touches. A non-empty range ending at a
    /// line start does not include that line.
    func lineStarts(in r: Range<Int>) -> [Int] {
        var hi = r.upperBound
        if !r.isEmpty, hi > r.lowerBound, hi == lineStart(hi) { hi -= 1 }
        var out: [Int] = []
        var p = lineStart(r.lowerBound)
        while true {
            out.append(p)
            let next = lineEnd(p)
            if next <= p || next > hi || next > count || (next == count && lineContentEnd(p) == count) { break }
            p = next
        }
        return out
    }

    func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 }

    func prefix(ofLineAt p: Int) -> LinePrefix {
        let start = lineStart(p)
        let end = lineContentEnd(p)
        let b = bytes(start..<end)
        let n = b.count
        var i = 0
        var depth = 0
        // `>` markers, each after up to three spaces, each followed by an optional space.
        while true {
            var j = i
            var spaces = 0
            while j < n, b[j] == 0x20, spaces < 3 { j += 1; spaces += 1 }
            guard j < n, b[j] == 0x3E else { break }
            i = j + 1
            depth += 1
            if i < n, isSpace(b[i]) { i += 1 }
        }
        let quoteEnd = start + i
        while i < n, isSpace(b[i]) { i += 1 }
        let indentEnd = start + i
        var pre = LinePrefix(start: start, end: end, quoteEnd: quoteEnd, quoteDepth: depth, indentEnd: indentEnd,
                             markerEnd: indentEnd, taskEnd: indentEnd, contentStart: indentEnd)
        // List marker.
        if i < n, b[i] == 0x2D || b[i] == 0x2A || b[i] == 0x2B, i + 1 == n || isSpace(b[i + 1]), !isThematicBreak(b[i...]) {
            pre.marker = (start + i)..<(start + i + 1)
            pre.markerChar = b[i]
            i += 1
        } else {
            var j = i
            var number = 0
            while j < n, j - i < 9, b[j] >= 0x30, b[j] <= 0x39 { number = number * 10 + Int(b[j] - 0x30); j += 1 }
            if j > i, j < n, b[j] == 0x2E || b[j] == 0x29, j + 1 == n || isSpace(b[j + 1]) {
                pre.marker = (start + i)..<(start + j + 1)
                pre.isOrdered = true
                pre.number = number
                pre.markerChar = b[j]
                i = j + 1
            }
        }
        if pre.marker != nil {
            var spaces = 0
            let afterMarker = i
            while i < n, isSpace(b[i]), spaces < 4 { i += 1; spaces += 1 }
            if i == n || spaces > 4 { i = min(afterMarker + 1, n) }
            pre.markerEnd = start + i
            pre.taskEnd = start + i
            pre.contentStart = start + i
            // Task box.
            if i + 2 < n, b[i] == 0x5B, b[i + 1] == 0x20 || b[i + 1] == 0x78 || b[i + 1] == 0x58, b[i + 2] == 0x5D,
               i + 3 == n || isSpace(b[i + 3]) {
                pre.task = (start + i)..<(start + i + 3)
                i += 3
                if i < n, isSpace(b[i]) { i += 1 }
                pre.taskEnd = start + i
                pre.contentStart = start + i
            }
        }
        // ATX heading.
        var h = i
        while h < n, b[h] == 0x23, h - i < 7 { h += 1 }
        if h > i, h - i <= 6, h == n || isSpace(b[h]) {
            pre.heading = (start + i)..<(start + h)
            while h < n, isSpace(b[h]) { h += 1 }
            pre.contentStart = start + h
        }
        return pre
    }

    func isThematicBreak(_ s: ArraySlice<UInt8>) -> Bool {
        guard let c = s.first(where: { !isSpace($0) }), c == 0x2D || c == 0x2A || c == 0x5F else { return false }
        var count = 0
        for b in s {
            if b == c { count += 1 } else if !isSpace(b) { return false }
        }
        return count >= 3
    }

    // MARK: AST

    /// Top-level blocks (absolute ranges) whose entries touch `r`.
    func topBlocks(touching r: Range<Int>) -> [Block] {
        guard let first = index.entryIndex(containing: r.lowerBound),
              let last = index.entryIndex(containing: r.upperBound) else { return [] }
        return (first...last).map { index.absoluteBlock(at: $0) }
    }

    /// Blocks with no block children (and tables, empty items, empty quotes)
    /// whose range touches `r`: both ends inclusive for an empty range.
    func leaves(touching r: Range<Int>) -> [Block] {
        var out: [Block] = []
        func touches(_ b: Range<Int>) -> Bool {
            r.isEmpty ? (b.lowerBound <= r.lowerBound && r.lowerBound <= b.upperBound)
                : (b.lowerBound < r.upperBound && b.upperBound > r.lowerBound)
        }
        func visit(_ b: Block) {
            guard touches(b.range) else { return }
            switch b.kind {
            case .table:
                out.append(b)
            case .tableRow, .tableCell:
                break
            default:
                if b.children.isEmpty { out.append(b) } else { b.children.forEach(visit) }
            }
        }
        topBlocks(touching: r).forEach(visit)
        return out
    }

    /// The chain of blocks containing `p` (inclusive ends), outermost first.
    func path(at p: Int) -> [Block] {
        guard let i = index.entryIndex(containing: p) else { return [] }
        var out: [Block] = []
        var current: Block? = index.absoluteBlock(at: i)
        while let b = current, b.range.lowerBound <= p, p <= b.range.upperBound {
            out.append(b)
            current = b.children.first { $0.range.lowerBound <= p && p <= $0.range.upperBound }
        }
        return out
    }

    /// Inline nodes containing `p` in the leaf at `p`, outermost first.
    func inlinePath(at p: Int, strict: Bool = false) -> [Inline] {
        guard let leaf = path(at: p).last else { return [] }
        var out: [Inline] = []
        func contains(_ r: Range<Int>) -> Bool { strict ? (r.lowerBound < p && p < r.upperBound) : (r.lowerBound <= p && p <= r.upperBound) }
        var list = leaf.inlines
        while let hit = list.first(where: { contains($0.range) }) {
            out.append(hit)
            list = hit.children
        }
        return out
    }

    /// True inside code (blocks and spans), math, HTML and front matter.
    func isCodeContext(_ p: Int) -> Bool {
        for b in path(at: p) {
            switch b.kind {
            case .codeBlock(let info):
                if !info.isFenced { return true }
                if p >= info.contentRange.lowerBound, p <= info.contentRange.upperBound { return true }
            case .htmlBlock, .frontMatter:
                return true
            default:
                break
            }
        }
        for inline in inlinePath(at: p, strict: true) {
            switch inline.kind {
            case .code, .math, .html: return true
            default: break
            }
        }
        return false
    }
}

// MARK: - Commands

/// The §6.1.5 commands as pure functions of (document, selection, settings).
/// Every command returns an `EditPlan` or nil when it does not apply.
struct MarkdownCommands {
    let doc: CommandDocument
    let selection: SelectionModel
    let settings: EditorSettings

    init(rope: LipiRope, index: BlockIndex, selection: SelectionModel, settings: EditorSettings) {
        doc = CommandDocument(rope: rope, index: index)
        self.selection = selection
        self.settings = settings
    }

    var range: Range<Int> { selection.range }

    // MARK: Inline wrap

    enum InlineKindTag { case strong, emphasis, strikethrough, code }

    private func matches(_ kind: InlineKind, _ tag: InlineKindTag) -> Bool {
        switch (kind, tag) {
        case (.strong, .strong), (.emphasis, .emphasis), (.strikethrough, .strikethrough), (.code, .code): return true
        default: return false
        }
    }

    /// Content range of a delimited inline (inside its delimiters).
    private func contentRange(of inline: Inline) -> Range<Int> {
        let r = inline.range
        if case .code = inline.kind {
            var lo = r.lowerBound, hi = r.upperBound
            var n = 0
            while lo < hi, doc.byte(lo) == 0x60 { lo += 1; n += 1 }
            var m = 0
            while hi > lo, doc.byte(hi - 1) == 0x60, m < n { hi -= 1; m += 1 }
            return lo..<hi
        }
        guard let first = inline.children.first, let last = inline.children.last else {
            let half = r.count / 2
            return (r.lowerBound + half)..<(r.lowerBound + half)
        }
        return first.range.lowerBound..<last.range.upperBound
    }

    private func findInline(_ tag: InlineKindTag, where test: (Inline) -> Bool) -> Inline? {
        for leaf in doc.leaves(touching: range) {
            var found: Inline? = nil
            func visit(_ inline: Inline) {
                if found != nil { return }
                if matches(inline.kind, tag), test(inline) { found = inline; return }
                inline.children.forEach(visit)
            }
            leaf.inlines.forEach(visit)
            if let found { return found }
        }
        return nil
    }

    private func delimiter(for tag: InlineKindTag, text: String) -> String {
        switch tag {
        case .strong: return "**"
        case .emphasis: return String(settings.emphasisMarker)
        case .strikethrough: return "~~"
        case .code:
            // Shortest backtick run not present in the text.
            var runs = Set<Int>()
            var run = 0
            for b in text.utf8 {
                if b == 0x60 { run += 1 } else { if run > 0 { runs.insert(run) }; run = 0 }
            }
            if run > 0 { runs.insert(run) }
            var n = 1
            while runs.contains(n) { n += 1 }
            return String(repeating: "`", count: n)
        }
    }

    func toggleInline(_ tag: InlineKindTag) -> EditPlan? {
        var b = PlanBuilder()
        let sel = range
        // Unwrap: the selection is a node of this kind (with or without its
        // delimiters), or the caret is inside one.
        let node: Inline?
        if sel.isEmpty {
            node = findInline(tag) { $0.range.lowerBound < sel.lowerBound && sel.lowerBound < $0.range.upperBound }
        } else {
            node = findInline(tag) { $0.range == sel || contentRange(of: $0) == sel }
        }
        if let node {
            let content = contentRange(of: node)
            var open = node.range.lowerBound..<content.lowerBound
            var close = content.upperBound..<node.range.upperBound
            if tag == .code, content.count >= 2, doc.byte(content.lowerBound) == 0x20, doc.byte(content.upperBound - 1) == 0x20 {
                open = open.lowerBound..<(open.upperBound + 1)
                close = (close.lowerBound - 1)..<close.upperBound
            }
            b.replace(close, "")
            b.replace(open, "")
            if sel.isEmpty {
                let caret = min(max(sel.lowerBound, open.upperBound), close.lowerBound)
                return b.plan(anchor: caret, head: caret)
            }
            return b.plan(anchor: open.upperBound, anchorAfter: false, head: close.lowerBound, headAfter: false)
        }
        if sel.isEmpty {
            let caret = sel.lowerBound
            if let word = wordRange(at: caret) {
                let text = doc.string(word)
                let (open, close) = pad(delimiter(for: tag, text: text), text: text, tag: tag)
                b.insert(close, at: word.upperBound)
                b.insert(open, at: word.lowerBound)
                return b.plan(caret: caret + open.utf8.count)
            }
            let d = delimiter(for: tag, text: "")
            b.insert(d + d, at: caret)
            return b.plan(caret: caret + d.utf8.count)
        }
        // Wrap the selection, trimmed of surrounding whitespace.
        var lo = sel.lowerBound, hi = sel.upperBound
        while lo < hi, isWhitespace(doc.byte(lo)) { lo += 1 }
        while hi > lo, isWhitespace(doc.byte(hi - 1)) { hi -= 1 }
        guard lo < hi else { return nil }
        let text = doc.string(lo..<hi)
        let (open, close) = pad(delimiter(for: tag, text: text), text: text, tag: tag)
        b.insert(close, at: hi)
        b.insert(open, at: lo)
        return b.plan(anchor: lo, anchorAfter: true, head: hi, headAfter: false)
    }

    /// Code spans pad with a space when the content starts or ends with a backtick.
    private func pad(_ d: String, text: String, tag: InlineKindTag) -> (String, String) {
        guard tag == .code, text.hasPrefix("`") || text.hasSuffix("`") else { return (d, d) }
        return (d + " ", " " + d)
    }

    private func isWhitespace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }

    /// Word characters: anything but whitespace and Markdown punctuation.
    private func isWordByte(_ b: UInt8) -> Bool {
        if isWhitespace(b) { return false }
        switch b {
        case 0x2A, 0x5F, 0x7E, 0x60, 0x5B, 0x5D, 0x28, 0x29, 0x3C, 0x3E, 0x21, 0x22, 0x2C, 0x2E, 0x3B, 0x3A, 0x3F: return false
        default: return true
        }
    }

    /// The word under the caret on its line, or nil on whitespace.
    func wordRange(at p: Int) -> Range<Int>? {
        let ls = doc.lineStart(p), le = doc.lineContentEnd(p)
        var lo = p, hi = p
        while lo > ls, isWordByte(doc.byte(lo - 1)) { lo -= 1 }
        while hi < le, isWordByte(doc.byte(hi)) { hi += 1 }
        return lo < hi ? lo..<hi : nil
    }

    // MARK: Block targets

    /// One block a structure command acts on: the first line of a leaf, or a
    /// blank caret line.
    struct Target {
        var leaf: Block?
        var line: LinePrefix
    }

    func targets() -> [Target] {
        var out: [Target] = []
        var seen = Set<Int>()
        for leaf in doc.leaves(touching: range) {
            switch leaf.kind {
            case .paragraph, .heading, .listItem, .blockQuote:
                let line = doc.prefix(ofLineAt: leaf.range.lowerBound)
                if seen.insert(line.start).inserted { out.append(Target(leaf: leaf, line: line)) }
            default:
                break
            }
        }
        if out.isEmpty, range.isEmpty {
            let line = doc.prefix(ofLineAt: range.lowerBound)
            let inCode = doc.leaves(touching: range).contains {
                if case .codeBlock = $0.kind { return true }
                if case .htmlBlock = $0.kind { return true }
                if case .frontMatter = $0.kind { return true }
                return false
            }
            if !inCode { out.append(Target(leaf: nil, line: line)) }
        }
        return out
    }

    private func headingLevel(_ t: Target) -> (level: Int, isSetext: Bool)? {
        if let leaf = t.leaf, case .heading(let level, let isSetext) = leaf.kind { return (level, isSetext) }
        return nil
    }

    /// The setext underline of a heading block: from the end of the last
    /// content line to the end of the underline.
    private func setextUnderline(_ leaf: Block) -> Range<Int> {
        let underlineStart = doc.lineStart(leaf.range.upperBound)
        var contentEnd = underlineStart
        if contentEnd > leaf.range.lowerBound { contentEnd = doc.lineContentEnd(underlineStart - 1) }
        return contentEnd..<doc.lineContentEnd(leaf.range.upperBound)
    }

    /// The closing `#` sequence of an ATX heading line, with its leading space.
    private func closingSequence(_ line: LinePrefix) -> Range<Int>? {
        var e = line.end
        while e > line.contentStart, doc.isSpace(doc.byte(e - 1)) { e -= 1 }
        var h = e
        while h > line.contentStart, doc.byte(h - 1) == 0x23 { h -= 1 }
        guard h < e else { return nil }
        if h == line.contentStart { return h..<line.end }
        guard doc.isSpace(doc.byte(h - 1)) else { return nil }
        var s = h
        while s > line.contentStart, doc.isSpace(doc.byte(s - 1)) { s -= 1 }
        return s..<line.end
    }

    /// Heading 1–6, or paragraph for level 0 (removes heading and list markers).
    func setHeading(_ level: Int) -> EditPlan? {
        var b = PlanBuilder()
        let ts = targets()
        guard !ts.isEmpty else { return nil }
        for t in ts {
            let line = t.line
            let hashes = level > 0 ? String(repeating: "#", count: level) + " " : ""
            if let (current, isSetext) = headingLevel(t), isSetext, let leaf = t.leaf {
                if level == 0 {
                    b.replace(setextUnderline(leaf), "")
                } else {
                    b.replace(setextUnderline(leaf), "")
                    b.insert(hashes, at: line.contentStart)
                }
                _ = current
                continue
            }
            if level == 0 {
                if let close = closingSequence(line), line.heading != nil { b.replace(close, "") }
                let from = line.marker?.lowerBound ?? line.heading?.lowerBound
                if let from, from < line.contentStart { b.replace(from..<line.contentStart, "") }
                continue
            }
            if let heading = line.heading, line.marker == nil {
                if heading.count != level { b.replace(heading.lowerBound..<line.contentStart, hashes) }
                continue
            }
            // Paragraphs and list items become headings; a list marker goes.
            let from = line.marker?.lowerBound ?? line.indentEnd
            b.replace(from..<line.contentStart, hashes)
        }
        return b.edits.isEmpty ? nil : keepSelection(b)
    }

    /// Promote (`delta` -1, towards H1) or demote (+1) headings, clamped to 1–6.
    func shiftHeading(by delta: Int) -> EditPlan? {
        var b = PlanBuilder()
        for t in targets() {
            guard let (level, isSetext) = headingLevel(t), let leaf = t.leaf else { continue }
            let next = min(max(level + delta, 1), 6)
            guard next != level else { continue }
            let hashes = String(repeating: "#", count: next)
            if isSetext {
                b.replace(setextUnderline(leaf), "")
                b.insert(hashes + " ", at: t.line.contentStart)
            } else if let heading = t.line.heading {
                b.replace(heading, hashes)
            }
        }
        return b.edits.isEmpty ? nil : keepSelection(b)
    }

    private func keepSelection(_ b: PlanBuilder) -> EditPlan {
        if selection.isEmpty { return b.plan(anchor: selection.head, anchorAfter: true, head: selection.head, headAfter: true) }
        let forward = selection.head >= selection.anchor
        return b.plan(anchor: selection.anchor, anchorAfter: !forward, head: selection.head, headAfter: forward)
    }

    enum ListKind { case bullet, ordered, task }

    private func isList(_ line: LinePrefix, _ kind: ListKind) -> Bool {
        switch kind {
        case .bullet: return line.hasMarker && !line.isOrdered && line.task == nil
        case .ordered: return line.hasMarker && line.isOrdered
        case .task: return line.task != nil
        }
    }

    /// Convert each target block to a list item of `kind`; if all already
    /// are, remove their markers.
    func toggleList(_ kind: ListKind) -> EditPlan? {
        let ts = targets()
        guard !ts.isEmpty else { return nil }
        var b = PlanBuilder()
        if ts.allSatisfy({ isList($0.line, kind) }) {
            for t in ts {
                let line = t.line
                if let marker = line.marker { b.replace(marker.lowerBound..<line.taskEnd, "") }
            }
            return keepSelection(b)
        }
        var ordinal = 0
        for t in ts {
            let line = t.line
            ordinal += 1
            if isList(line, kind) { continue }
            switch kind {
            case .bullet:
                if let marker = line.marker {
                    b.replace(marker.lowerBound..<line.taskEnd, "- ")
                } else {
                    b.insert("- ", at: line.indentEnd)
                }
            case .ordered:
                if let marker = line.marker {
                    b.replace(marker.lowerBound..<line.markerEnd, "\(ordinal). ")
                } else {
                    b.insert("\(ordinal). ", at: line.indentEnd)
                }
            case .task:
                if line.marker != nil {
                    let needsSpace = line.markerEnd == line.marker!.upperBound
                    b.insert(needsSpace ? " [ ] " : "[ ] ", at: line.markerEnd)
                } else {
                    b.insert("- [ ] ", at: line.indentEnd)
                }
            }
        }
        return b.edits.isEmpty ? nil : keepSelection(b)
    }

    /// List items whose first line the selection touches, plus the innermost
    /// item around the selection start.
    func items() -> [Block] {
        var out: [Block] = []
        var seen = Set<Int>()
        func visit(_ block: Block) {
            if case .listItem = block.kind {
                let lineStart = doc.lineStart(block.range.lowerBound)
                let lineEnd = doc.lineContentEnd(block.range.lowerBound)
                let touches = range.isEmpty ? (lineStart <= range.lowerBound && range.lowerBound <= lineEnd)
                    : (lineStart < range.upperBound && lineEnd >= range.lowerBound)
                if touches, seen.insert(block.range.lowerBound).inserted { out.append(block) }
            }
            block.children.forEach(visit)
        }
        doc.topBlocks(touching: range).forEach(visit)
        if let inner = doc.path(at: range.lowerBound).last(where: { if case .listItem = $0.kind { return true } else { return false } }),
           seen.insert(inner.range.lowerBound).inserted {
            out.append(inner)
        }
        return out.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// `[x]`/`[ ]` on the targeted task items: all checked → uncheck all;
    /// otherwise check the unchecked ones (an existing `[X]` stays).
    func toggleTaskDone() -> EditPlan? {
        let boxes = items().compactMap { doc.prefix(ofLineAt: $0.range.lowerBound).task }
        guard !boxes.isEmpty else { return nil }
        let checked = boxes.map { doc.byte($0.lowerBound + 1) != 0x20 }
        var b = PlanBuilder()
        let allChecked = !checked.contains(false)
        for (box, isChecked) in zip(boxes, checked) {
            let mark = (box.lowerBound + 1)..<(box.lowerBound + 2)
            if allChecked { b.replace(mark, " ") } else if !isChecked { b.replace(mark, "x") }
        }
        return keepSelection(b)
    }

    /// Indent (+1) or outdent (-1) the targeted items with their children.
    func indentItems(_ direction: Int) -> EditPlan? {
        var targets = items()
        // Drop items nested in another target: they move with it.
        targets = targets.filter { t in !targets.contains { $0.range != t.range && $0.range.lowerBound < t.range.lowerBound && t.range.upperBound <= $0.range.upperBound } }
        var b = PlanBuilder()
        for item in targets {
            let path = doc.path(at: item.range.lowerBound)
            guard let at = path.firstIndex(where: { $0.range == item.range && $0.kind == item.kind }), at > 0 else { continue }
            let list = path[at - 1]
            let line = doc.prefix(ofLineAt: item.range.lowerBound)
            let column = line.indentEnd - line.quoteEnd
            if direction > 0 {
                guard let i = list.children.firstIndex(where: { $0.range == item.range }), i > 0 else { continue }
                let sibling = doc.prefix(ofLineAt: list.children[i - 1].range.lowerBound)
                let target = sibling.markerEnd - sibling.quoteEnd
                let add = target - column
                guard add > 0 else { continue }
                for start in itemLines(item) {
                    let p = doc.prefix(ofLineAt: start)
                    if p.start == p.end || (p.isBlank && !p.hasMarker && p.quoteEnd == p.end) { continue }
                    b.insert(String(repeating: " ", count: add), at: p.quoteEnd)
                }
            } else {
                // Only nested items outdent: to the parent item's column.
                guard at >= 2, case .listItem = path[at - 2].kind else { continue }
                let parent = doc.prefix(ofLineAt: path[at - 2].range.lowerBound)
                let remove = column - (parent.indentEnd - parent.quoteEnd)
                guard remove > 0 else { continue }
                for start in itemLines(item) {
                    let p = doc.prefix(ofLineAt: start)
                    var q = p.quoteEnd
                    var removed = 0
                    while q < p.end, doc.byte(q) == 0x20, removed < remove { q += 1; removed += 1 }
                    if q < p.end, doc.byte(q) == 0x09, removed < remove { q += 1 }
                    if q > p.quoteEnd { b.replace(p.quoteEnd..<q, "") }
                }
            }
        }
        return b.edits.isEmpty ? nil : keepSelection(b)
    }

    private func itemLines(_ item: Block) -> [Int] {
        doc.lineStarts(in: doc.lineStart(item.range.lowerBound)..<max(item.range.upperBound, item.range.lowerBound))
    }

    /// Toggle a block quote over the lines of the touched top-level blocks.
    func toggleQuote() -> EditPlan? {
        let blocks = doc.topBlocks(touching: range).filter {
            range.isEmpty ? ($0.range.lowerBound <= range.lowerBound && range.lowerBound <= $0.range.upperBound)
                : ($0.range.lowerBound < range.upperBound && $0.range.upperBound > range.lowerBound)
        }
        var span: Range<Int>
        if let first = blocks.first, let last = blocks.last {
            span = doc.lineStart(first.range.lowerBound)..<last.range.upperBound
            if !range.isEmpty { span = min(span.lowerBound, doc.lineStart(range.lowerBound))..<max(span.upperBound, range.upperBound) }
        } else {
            span = doc.lineStart(range.lowerBound)..<range.upperBound
        }
        let lines = doc.lineStarts(in: span).map { doc.prefix(ofLineAt: $0) }
        var b = PlanBuilder()
        if lines.allSatisfy({ $0.quoteDepth > 0 || $0.start == $0.end }) && lines.contains(where: { $0.quoteDepth > 0 }) {
            for line in lines where line.quoteDepth > 0 {
                // Remove the first `>` and one space after it.
                var p = line.start
                while doc.byte(p) != 0x3E { p += 1 }
                var e = p + 1
                if e < line.end, doc.isSpace(doc.byte(e)) { e += 1 }
                b.replace(line.start..<e, "")
            }
        } else {
            for line in lines { b.insert(line.start == line.end ? ">" : "> ", at: line.start) }
        }
        return keepSelection(b)
    }

    // MARK: Block insertion

    /// Quote prefix (and list content indentation) to repeat on inserted lines.
    func continuation(_ line: LinePrefix) -> String {
        var s = doc.string(line.start..<line.quoteEnd)
        if let marker = line.marker {
            s += doc.string(line.quoteEnd..<marker.lowerBound) + String(repeating: " ", count: line.markerEnd - marker.lowerBound)
        } else {
            s += doc.string(line.quoteEnd..<line.indentEnd)
        }
        return s
    }

    /// Where a block inserted "after the current block" goes: the end of the
    /// last line of the leaf around the caret.
    private func afterCurrentBlock(_ p: Int) -> Int {
        if let leaf = doc.leaves(touching: p..<p).last { return doc.lineContentEnd(leaf.range.upperBound) }
        return doc.lineContentEnd(p)
    }

    private func fence(for text: String, char: Character = "`") -> String {
        var longest = 0, run = 0
        for c in text {
            if c == char { run += 1; longest = max(longest, run) } else { run = 0 }
        }
        return String(repeating: char, count: max(3, longest + 1))
    }

    /// Code fence: wrap the selected lines, or insert an empty fence with the
    /// caret on the info string.
    func codeFence() -> EditPlan? {
        wrapBlock(open: { fence(for: $0) }, caretOnOpening: true)
    }

    /// Math block: wrap the selected lines in `$$`, or insert `$$`, an empty
    /// line and `$$` with the caret inside.
    func mathBlock() -> EditPlan? {
        wrapBlock(open: { _ in "$$" }, caretOnOpening: false)
    }

    private func wrapBlock(open: (String) -> String, caretOnOpening: Bool) -> EditPlan? {
        var b = PlanBuilder()
        let first = doc.prefix(ofLineAt: range.lowerBound)
        let eol = doc.eol(near: range.lowerBound)
        let pre = doc.string(first.start..<first.quoteEnd)
        if !range.isEmpty {
            let lines = doc.lineStarts(in: range)
            let lo = lines.first!, hi = doc.lineContentEnd(lines.last!)
            let text = doc.string(lo..<hi)
            let f = open(text)
            let body = pre.isEmpty ? text : text
            b.replace(lo..<hi, pre + f + eol + (pre.isEmpty ? "" : "") + body + eol + pre + f)
            let bodyStart = lo + (pre + f + eol).utf8.count
            if caretOnOpening { return b.plan(caret: lo + (pre + f).utf8.count) }
            return EditPlan(edits: b.edits, anchor: bodyStart, head: bodyStart + body.utf8.count)
        }
        let f = open("")
        if first.isBlank && !first.hasMarker && first.heading == nil {
            // Blank line: the block replaces it.
            let middle = caretOnOpening ? "" : eol + pre
            b.replace(first.quoteEnd..<first.end, f + middle + eol + pre + f)
            let caret = first.quoteEnd + f.utf8.count + (caretOnOpening ? 0 : (eol + pre).utf8.count)
            return b.plan(caret: caret)
        }
        let at = afterCurrentBlock(range.lowerBound)
        let lead = caretOnOpening ? eol + pre : eol + pre.trimmingCharacters(in: .whitespaces) + eol + pre
        let middle = caretOnOpening ? "" : eol + pre
        b.insert(lead + f + middle + eol + pre + f, at: at)
        let caret = at + (lead + f).utf8.count + (caretOnOpening ? 0 : (eol + pre).utf8.count)
        return b.plan(caret: caret)
    }

    /// Thematic break: replace the selection, or insert on its own line.
    func thematicBreak() -> EditPlan? {
        var b = PlanBuilder()
        let eol = doc.eol(near: range.lowerBound)
        let line = doc.prefix(ofLineAt: range.lowerBound)
        if range.isEmpty, !(line.isBlank && !line.hasMarker && line.heading == nil) {
            let at = afterCurrentBlock(range.lowerBound)
            b.insert(eol + eol + "---", at: at)
            return b.plan(caret: at + (eol + eol + "---").utf8.count)
        }
        let lo = range.isEmpty ? line.quoteEnd : range.lowerBound
        let hi = range.isEmpty ? line.end : range.upperBound
        let before = doc.string(line.quoteEnd..<lo).trimmingCharacters(in: .whitespaces)
        let lastLine = doc.prefix(ofLineAt: hi)
        let after = doc.string(hi..<lastLine.end).trimmingCharacters(in: .whitespaces)
        var lead = ""
        if !before.isEmpty {
            lead = eol + eol
        } else if line.start > 0 {
            // A rule right under a paragraph line would be a setext underline.
            let previous = doc.prefix(ofLineAt: line.start - 1)
            if !(previous.isBlank && !previous.hasMarker) { lead = eol }
        }
        let trail = after.isEmpty ? "" : eol
        let text = lead + "---" + trail
        b.replace(lo..<hi, text)
        return b.plan(caret: lo + (lead + "---").utf8.count)
    }

    /// Hard line break per setting, continuing the line's container prefix.
    func hardBreak() -> EditPlan? {
        var b = PlanBuilder()
        let line = doc.prefix(ofLineAt: range.lowerBound)
        let eol = doc.eol(near: range.lowerBound)
        let mark = settings.hardBreak == .backslash ? "\\" : "  "
        let text = mark + eol + continuation(line)
        b.replace(range, text)
        return b.plan(caret: range.lowerBound + text.utf8.count)
    }

    /// Cmd-Enter: leave the innermost fence, table, quote or math block and
    /// start a paragraph after it.
    func exitBlock() -> EditPlan? {
        let p = range.upperBound
        var exit: Block? = nil
        for block in doc.path(at: p) {
            switch block.kind {
            case .codeBlock, .table, .blockQuote: exit = block
            case .paragraph:
                if block.inlines.contains(where: { if case .math(_, true) = $0.kind { return $0.range.lowerBound <= p && p <= $0.range.upperBound } else { return false } }) {
                    exit = block
                }
            default: break
            }
        }
        guard let exit else { return nil }
        var b = PlanBuilder()
        let end = doc.lineContentEnd(exit.range.upperBound)
        let eol = doc.eol(near: exit.range.lowerBound)
        // Keep the containers outside the exited block.
        let firstLine = doc.prefix(ofLineAt: exit.range.lowerBound)
        var outer = ""
        for byte in doc.bytes(firstLine.start..<exit.range.lowerBound) {
            outer += byte == 0x3E ? ">" : " "
        }
        if case .blockQuote = exit.kind {} else {
            outer = String(outer.reversed().drop(while: { $0 == " " }).reversed())
            if !outer.isEmpty { outer += " " }
        }
        let blank = outer.trimmingCharacters(in: .whitespaces)
        let text = eol + blank + eol + outer
        b.insert(text, at: end)
        return b.plan(caret: end + text.utf8.count)
    }

    /// `[label](destination "title")`, replacing the selection. With an
    /// empty destination the caret goes between the parentheses.
    func link(label: String?, destination: String, title: String?) -> EditPlan {
        link(label: label, destination: destination, title: title, replacing: range)
    }

    func link(label: String?, destination: String, title: String?, replacing range: Range<Int>) -> EditPlan {
        let label = label ?? doc.string(range)
        var b = PlanBuilder()
        let dest = formatDestination(destination)
        var text = "[" + label + "](" + dest
        if let title, !title.isEmpty { text += " \"" + title.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        text += ")"
        b.replace(range, text)
        if destination.isEmpty { return b.plan(caret: range.lowerBound + ("[" + label + "](").utf8.count) }
        return b.plan(caret: range.lowerBound + text.utf8.count)
    }

    /// `![alt](path)`, replacing the selection.
    func image(alt: String?, path: String) -> EditPlan {
        let alt = alt ?? doc.string(range)
        var b = PlanBuilder()
        let text = "![" + alt + "](" + formatDestination(path) + ")"
        b.replace(range, text)
        return b.plan(caret: range.lowerBound + text.utf8.count)
    }

    private func formatDestination(_ d: String) -> String {
        if d.contains(where: { $0 == " " || $0 == "(" || $0 == ")" || $0 == "<" }) {
            return "<" + d.replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E") + ">"
        }
        return d
    }

    // MARK: Smart Enter

    /// Enter with list, task and quote continuation, fence and math openers
    /// and `---` breaks. Nil means a plain line terminator.
    func smartNewline() -> EditPlan? {
        guard range.isEmpty else { return nil }
        let c = range.lowerBound
        let line = doc.prefix(ofLineAt: c)
        let eol = doc.eol(near: c)
        var b = PlanBuilder()
        let path = doc.path(at: c)

        // Fenced code: open an unclosed fence, keep indentation inside code.
        for block in path {
            guard case .codeBlock(let info) = block.kind else { continue }
            if info.isFenced, !info.isClosed, c == line.end, doc.lineStart(block.range.lowerBound) == line.start {
                let opening = doc.string(block.range.lowerBound..<line.end)
                let f = String(opening.prefix { $0 == "`" || $0 == "~" })
                let pre = continuation(line)
                b.insert(eol + pre + eol + pre + f, at: c)
                return b.plan(caret: c + (eol + pre).utf8.count)
            }
            if !info.isFenced || c > info.contentRange.lowerBound || c > doc.lineContentEnd(block.range.lowerBound) {
                return plainWithPrefix(doc.string(line.start..<min(line.indentEnd, c)), eol: eol)
            }
        }
        let content = doc.string(line.contentStart..<line.end)
        // `$$` then Enter opens a math block, unless it closes one.
        if c == line.end, content == "$$", line.marker == nil {
            let closes = doc.inlinePath(at: c).contains {
                if case .math(_, true) = $0.kind { return $0.range.lowerBound < line.start } else { return false }
            }
            if !closes {
                let pre = continuation(line)
                b.insert(eol + pre + eol + pre + "$$", at: c)
                return b.plan(caret: c + (eol + pre).utf8.count)
            }
        }
        // `---` then Enter: a break, not a setext underline.
        if c == line.end, line.marker == nil, line.heading == nil,
           doc.string(line.quoteEnd..<line.end).trimmingCharacters(in: .whitespaces) == "---",
           path.contains(where: { if case .heading(2, true) = $0.kind { return true } else { return false } }) {
            b.insert(eol, at: line.start)
            b.insert(eol, at: c)
            return b.plan(caret: c + (eol + eol).utf8.count)
        }
        // Lists.
        if let marker = line.marker, c >= line.contentStart || c == line.end {
            if line.contentStart >= line.end || doc.string(line.contentStart..<line.end).allSatisfy({ $0 == " " || $0 == "\t" }) {
                // Empty item: remove the marker; the list ends.
                b.replace(line.quoteEnd..<line.end, "")
                return b.plan(caret: line.quoteEnd)
            }
            let next = nextMarker(line)
            let spacing = doc.string(marker.upperBound..<line.markerEnd)
            let text = eol + doc.string(line.start..<marker.lowerBound) + next + (spacing.isEmpty ? " " : spacing) + (line.task != nil ? "[ ] " : "")
            b.insert(text, at: c)
            return b.plan(caret: c + text.utf8.count)
        }
        if line.marker == nil, !line.isBlank || line.quoteDepth == 0,
           let item = path.last(where: { if case .listItem = $0.kind { return true } else { return false } }),
           doc.lineStart(item.range.lowerBound) != line.start, line.heading == nil {
            let itemLine = doc.prefix(ofLineAt: item.range.lowerBound)
            if let marker = itemLine.marker, !line.isBlank {
                let spacing = doc.string(marker.upperBound..<itemLine.markerEnd)
                let text = eol + doc.string(itemLine.start..<marker.lowerBound) + nextMarker(itemLine)
                    + (spacing.isEmpty ? " " : spacing) + (itemLine.task != nil ? "[ ] " : "")
                b.insert(text, at: c)
                return b.plan(caret: c + text.utf8.count)
            }
        }
        // Quotes.
        if line.quoteDepth > 0, c >= line.quoteEnd {
            if line.isBlank {
                b.replace(line.start..<line.end, "")
                return b.plan(caret: line.start)
            }
            let text = eol + doc.string(line.start..<line.quoteEnd)
            b.insert(text, at: c)
            return b.plan(caret: c + text.utf8.count)
        }
        if eol != "\n" { return plainWithPrefix("", eol: eol) }
        return nil
    }

    private func plainWithPrefix(_ prefix: String, eol: String) -> EditPlan {
        var b = PlanBuilder()
        b.insert(eol + prefix, at: range.lowerBound)
        return b.plan(caret: range.lowerBound + (eol + prefix).utf8.count)
    }

    private func nextMarker(_ line: LinePrefix) -> String {
        guard line.isOrdered else { return String(UnicodeScalar(line.markerChar)) }
        return "\(line.number + 1)" + String(UnicodeScalar(line.markerChar))
    }
}
