/// The document's headings for a `[toc]` block (PRD §6.13): shown live in
/// place of the placeholder and exported as a nested list with anchors.
/// Headings nested in lists and quotes are included, as in the outline, and
/// anchors are allocated the same way (explicit `{#id}` first, then unique
/// GitHub slugs).
public struct TableOfContents: Sendable, Hashable {
    public struct Item: Sendable, Hashable {
        public var level: Int
        public var title: String
        public var anchor: String
        /// Absolute source offset of the heading.
        public var offset: Int
        public init(level: Int, title: String, anchor: String, offset: Int) {
            self.level = level
            self.title = title
            self.anchor = anchor
            self.offset = offset
        }
    }

    public var items: [Item]

    public init(items: [Item]) { self.items = items }

    /// The headings of a parsed document.
    public init(index: BlockIndex) {
        var items: [Item] = []
        var anchors = Headings.AnchorAllocator()
        for i in 0..<index.count {
            let top = index.entries[i].block
            if case .heading = top.kind {} else if !top.kind.isContainer { continue }
            let start = index.start(of: i)
            Headings.forEach(in: top) { block, _ in
                guard case .heading(let level, _) = block.kind else { return }
                let title = Headings.text(of: block.inlines).trimmingCharacters(in: .whitespaces)
                let anchor = anchors.anchor(slug: Headings.slug(title), explicit: Headings.explicitID(of: block.inlines))
                items.append(Item(level: level, title: title, anchor: anchor, offset: start + block.range.lowerBound))
            }
        }
        self.items = items
    }

    /// Whether any top-level entry of `index` is a `[toc]` placeholder.
    public static func isNeeded(in index: BlockIndex) -> Bool {
        index.entries.contains { $0.hasBracket && $0.block.isTableOfContents }
    }

    /// Depth of item `k` in the nested list: its level relative to the
    /// shallowest heading, so a document of `##` headings starts at 0.
    public func depth(_ k: Int) -> Int {
        let top = items.map(\.level).min() ?? 1
        return items[k].level - top
    }

    /// What the placeholder shows: one line per heading, indented by depth.
    /// `lineBreak` separates lines.
    public func displayLines() -> [String] {
        items.indices.map { String(repeating: "\u{2003}\u{2003}", count: depth($0)) + items[$0].title }
    }

    /// Changes whenever what the block shows changes (not the offsets).
    public var displayKey: Int {
        var h = Hasher()
        for item in items { h.combine(item.level); h.combine(item.title) }
        return h.finalize() | 1
    }

    /// A nested Markdown list of links (`- [Title](#anchor)`), for export.
    public func markdown() -> String {
        var out = ""
        for k in items.indices {
            let title = items[k].title.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            out += String(repeating: "  ", count: depth(k)) + "- [\(title)](#\(items[k].anchor))\n"
        }
        return out
    }

    /// A nested `<ul>` of anchor links in `<nav class="toc">`, for HTML
    /// export (headings get `id` = the item's anchor).
    public func html() -> String {
        guard !items.isEmpty else { return "<nav class=\"toc\"></nav>\n" }
        var out = "<nav class=\"toc\">\n"
        var open: [Int] = []  // depths with an open <ul>; each has an open <li> but the last
        for k in items.indices {
            let d = depth(k)
            if let last = open.last, d > last {
                out += "\n<ul>\n"                       // a child list inside the open item
                open.append(d)
            } else if !open.isEmpty {
                out += "</li>\n"
                while let l = open.last, l > d {
                    open.removeLast()
                    out += "</ul>\n"
                    if let p = open.last, p >= d { out += "</li>\n" } else {
                        out += "<ul>\n"                   // shallower than its parent list: a new list
                        open.append(d)
                        break
                    }
                }
            } else {
                out += "<ul>\n"
                open.append(d)
            }
            out += "<li><a href=\"#\(escape(items[k].anchor))\">\(escape(items[k].title))</a>"
        }
        out += "</li>\n"
        while !open.isEmpty {
            open.removeLast()
            out += "</ul>\n"
            if !open.isEmpty { out += "</li>\n" }
        }
        return out + "</nav>\n"
    }

    private func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }
}
