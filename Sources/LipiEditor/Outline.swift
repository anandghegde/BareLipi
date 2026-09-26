import Foundation
import LipiCore

/// One heading in the outline (§6.8).
public struct OutlineItem: Sendable, Hashable {
    public var id: NodeID
    public var level: Int
    /// Rendered heading text (markup removed).
    public var title: String
    /// GitHub-style anchor, unique within the document (`intro`, `intro-1`).
    public var slug: String
    /// The heading block's source range.
    public var range: Range<Int>
    /// The section: from the heading's line to the next heading of the same
    /// or a higher level (or the end of the document).
    public var section: Range<Int>
    /// A heading inside a list, block quote or footnote (§6.8): shown and
    /// navigable, but its section is not moved as a unit.
    public var isNested = false
}

/// The document's outline: ATX and setext headings in order, including
/// those nested in lists, block quotes and footnote definitions. Headings
/// inside code fences and HTML blocks are not headings to the parser, so
/// they never appear. Titles are cached per block identity.
public struct Outline: Sendable {
    public private(set) var items: [OutlineItem] = []
    /// The document title: the front matter `title` (§6.13), nil when there
    /// is none or the front matter is malformed.
    public private(set) var title: String?
    private var titleKey: (id: NodeID, revision: UInt32, length: Int)?
    private var titles: [NodeID: (revision: UInt32, title: String, slug: String, explicit: String?)] = [:]

    public init() {}

    public init(index: BlockIndex, rope: LipiRope) {
        update(index: index, rope: rope)
    }

    /// Rebuilds from the parse. Returns true when titles or levels changed
    /// (not just offsets), so a view can skip reloading rows.
    @discardableResult
    public mutating func update(index: BlockIndex, rope: LipiRope) -> Bool {
        let oldTitle = title
        updateTitle(index: index, rope: rope)
        var next: [OutlineItem] = []
        var anchors = Headings.AnchorAllocator()
        next.reserveCapacity(items.count)
        var misses = 0
        for i in 0..<index.count {
            let entry = index.entries[i]
            let top = entry.block
            // Most entries are paragraphs: skip them without a closure call.
            if case .heading = top.kind {} else if !top.kind.isContainer { continue }
            let start = index.start(of: i)
            Headings.forEach(in: top) { block, nested in
                guard case .heading(let level, _) = block.kind else { return }
                let title: String, base: String, explicit: String?
                if let hit = titles[block.id], hit.revision == entry.revision, !entry.isDirty {
                    title = hit.title
                    base = hit.slug
                    explicit = hit.explicit
                } else {
                    title = Headings.text(of: block.inlines).trimmingCharacters(in: .whitespaces)
                    base = Headings.slug(title)
                    explicit = Headings.explicitID(of: block.inlines)
                    titles[block.id] = (entry.revision, title, base, explicit)
                    misses += 1
                }
                let slug = anchors.anchor(slug: base, explicit: explicit)
                let range = (start + block.range.lowerBound)..<(start + block.range.upperBound)
                next.append(OutlineItem(id: block.id, level: level, title: title, slug: slug, range: range,
                                        section: nested ? range.lowerBound..<(start + entry.length) : start..<rope.count,
                                        isNested: nested))
            }
        }
        // Section ends: the next heading at the same or a higher level.
        // Top-level sections end only at top-level headings (moving one
        // never splits a list); a nested section also ends with its block.
        var open: [Int] = []
        for k in next.indices where !next[k].isNested {
            while let last = open.last, next[last].level >= next[k].level {
                next[last].section = next[last].section.lowerBound..<next[k].section.lowerBound
                open.removeLast()
            }
            open.append(k)
        }
        for k in next.indices where next[k].isNested {
            var j = k + 1
            while j < next.count, next[j].range.lowerBound < next[k].section.upperBound {
                if next[j].level <= next[k].level {
                    next[k].section = next[k].section.lowerBound..<next[j].range.lowerBound
                    break
                }
                j += 1
            }
        }
        if misses > 0, titles.count > 2 * next.count + 64 {
            let live = Set(next.map(\.id))
            titles = titles.filter { live.contains($0.key) }
        }
        let changed = title != oldTitle || next.count != items.count
            || zip(next, items).contains { $0.title != $1.title || $0.level != $1.level || $0.slug != $1.slug }
        items = next
        return changed
    }

    private mutating func updateTitle(index: BlockIndex, rope: LipiRope) {
        guard let first = index.entries.first, first.block.kind.isFrontMatter else {
            title = nil
            titleKey = nil
            return
        }
        if let k = titleKey, k.id == first.block.id, k.revision == first.revision, k.length == first.length, !first.isDirty { return }
        titleKey = (first.block.id, first.revision, first.length)
        let data = FrontMatterData.parse(index: index, rope: rope)
        title = data?.isMalformed == false ? data?.title : nil
    }

    /// Index of the heading whose section holds `offset`: the last heading
    /// starting at or before it (binary search). Nil before the first.
    public func current(at offset: Int) -> Int? {
        var lo = 0, hi = items.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if items[mid].section.lowerBound <= offset { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }

    /// Items `k` and its subsections: `k` through the last item inside its section.
    public func subtree(_ k: Int) -> Range<Int> {
        var e = k + 1
        while e < items.count, items[e].level > items[k].level { e += 1 }
        return k..<e
    }

    /// GitHub's heading anchor: lowercased, punctuation removed except `-`
    /// and `_`, spaces to `-`.
    public static func slug(_ title: String) -> String { Headings.slug(title) }

    static func text(of inlines: [Inline]) -> String { Headings.text(of: inlines) }
}

// MARK: Section commands

extension MarkdownCommands {
    /// Moves outline item `k`'s section (with its subsections) so it starts
    /// where item `before` starts, or to the end of the document for nil.
    /// Moving into its own section is refused. One edit over the span
    /// between the two positions; each moved chunk ends with one blank line.
    func moveSection(_ outline: Outline, _ k: Int, before target: Int?) -> EditPlan? {
        let items = outline.items
        guard items.indices.contains(k), !items[k].isNested, target.map({ !items[$0].isNested }) ?? true else { return nil }
        let moving = items[k].section
        let to = target.map { items[$0].section.lowerBound } ?? doc.count
        guard to < moving.lowerBound || to > moving.upperBound else { return nil }
        let eol = doc.eol(near: moving.lowerBound)
        func trimmed(_ r: Range<Int>) -> (body: String, tail: String) {
            let s = doc.string(r)
            var body = Substring(s)
            while let last = body.last, last.isNewline || last == " " || last == "\t" { body = body.dropLast() }
            return (String(body), String(s[body.endIndex...]))
        }
        let span: Range<Int>, first: Range<Int>, second: Range<Int>
        if to < moving.lowerBound {
            span = to..<moving.upperBound
            first = moving
            second = to..<moving.lowerBound
        } else {
            span = moving.lowerBound..<to
            first = moving.upperBound..<to
            second = moving
        }
        let a = trimmed(first), b = trimmed(second)
        guard !a.body.isEmpty, !b.body.isEmpty else { return nil }
        // The span keeps the blank lines (or missing final newline) that
        // ended it.
        let lastTail = trimmed(to < moving.lowerBound ? moving : first).tail
        let text = a.body + eol + eol + b.body + lastTail
        var builder = PlanBuilder()
        builder.replace(span, text)
        let caret = to < moving.lowerBound ? span.lowerBound : span.lowerBound + (a.body + eol + eol).utf8.count
        return builder.plan(caret: caret)
    }

    /// Promote (`delta` -1) or demote (+1) outline item `k`, and its
    /// subsections when `subsections` is set. Nothing moves when any
    /// heading would leave 1–6. Setext headings become ATX.
    func shiftSection(_ outline: Outline, _ k: Int, by delta: Int, subsections: Bool) -> EditPlan? {
        let items = outline.items
        guard items.indices.contains(k) else { return nil }
        let range = subsections ? outline.subtree(k) : k..<(k + 1)
        guard items[range].allSatisfy({ (1...6).contains($0.level + delta) }) else { return nil }
        var b = PlanBuilder()
        for item in items[range] {
            let line = doc.prefix(ofLineAt: item.range.lowerBound)
            let hashes = String(repeating: "#", count: item.level + delta)
            if let heading = line.heading {
                b.replace(heading, hashes)
            } else {
                // Setext: drop the underline, prefix hashes.
                let underline = doc.lineStart(item.range.upperBound)
                let contentEnd = doc.lineContentEnd(underline - 1)
                b.replace(contentEnd..<doc.lineContentEnd(item.range.upperBound), "")
                b.insert(hashes + " ", at: line.contentStart)
            }
        }
        let p = selection.head
        return b.plan(anchor: p, anchorAfter: true, head: p, headAfter: true)
    }
}
