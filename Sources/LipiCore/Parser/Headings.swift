/// Heading text, anchors and traversal shared by the outline (§6.8) and the
/// `[toc]` block (§6.13).
public enum Headings {
    /// Rendered heading text: markup removed, emoji shortcodes as emoji,
    /// `{#id}` attributes dropped.
    public static func text(of inlines: [Inline]) -> String {
        var s = ""
        for inline in inlines {
            switch inline.kind {
            case .text(let t), .code(let t): s += t
            case .math(let t, _): s += t
            case .emoji(let e): s += e
            case .softBreak, .lineBreak: s += " "
            case .html, .footnoteReference, .attributes: break
            case .image, .emphasis, .strong, .strikethrough, .subscript, .superscript, .highlight, .link:
                s += text(of: inline.children)
            }
        }
        return s
    }

    /// GitHub's heading anchor: lowercased, punctuation removed except `-`
    /// and `_`, spaces to `-`.
    public static func slug(_ title: String) -> String {
        var out = ""
        for scalar in title.lowercased().unicodeScalars {
            let p = scalar.properties
            if scalar == " " { out.append("-") } else if scalar == "-" || scalar == "_" || p.isAlphabetic
                || p.generalCategory == .decimalNumber || p.generalCategory == .nonspacingMark
                || p.generalCategory == .spacingMark || p.generalCategory == .enclosingMark {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// The `#id` of a heading's `{#id .class}` attributes, if any.
    public static func explicitID(of inlines: [Inline]) -> String? {
        guard case .attributes(let raw) = inlines.last?.kind else { return nil }
        for token in raw.split(whereSeparator: { $0 == " " || $0 == "\t" }) where token.hasPrefix("#") && token.count > 1 {
            return String(token.dropFirst())
        }
        return nil
    }

    /// The classes of a heading's `{#id .class}` attributes.
    public static func classes(of inlines: [Inline]) -> [String] {
        guard case .attributes(let raw) = inlines.last?.kind else { return [] }
        return raw.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .filter { $0.hasPrefix(".") && $0.count > 1 }.map { String($0.dropFirst()) }
    }

    /// Every heading in `block` in document order: the block itself or
    /// headings nested in lists, block quotes and footnote definitions.
    public static func forEach(in block: Block, _ body: (Block, _ nested: Bool) -> Void) {
        if case .heading = block.kind { body(block, false); return }
        guard block.kind.isContainer, !isTable(block.kind) else { return }
        block.forEachBlock { b in
            if case .heading = b.kind { body(b, true) }
        }
    }

    private static func isTable(_ kind: BlockKind) -> Bool {
        if case .table = kind { return true }
        return false
    }

    /// Anchors for a document's headings, unique like GitHub's: an explicit
    /// `{#id}` is used as written; otherwise the slug, with `-1`, `-2`… for
    /// repeats.
    public struct AnchorAllocator: Sendable {
        private var seen: [String: Int] = [:]
        public init() {}
        public mutating func anchor(slug base: String, explicit: String?) -> String {
            if let explicit {
                seen[explicit] = seen[explicit] ?? 0
                return explicit
            }
            var slug = base
            if let n = seen[base] {
                var k = n
                repeat { k += 1; slug = "\(base)-\(k)" } while seen[slug] != nil
                seen[base] = k
            }
            seen[slug] = seen[slug] ?? 0
            return slug
        }
    }
}

extension Block {
    /// A paragraph that is exactly `[toc]` (any case): the table of contents
    /// placeholder (§6.13).
    public var isTableOfContents: Bool {
        guard case .paragraph = kind, !inlines.isEmpty, inlines.count <= 3 else { return false }
        var s = ""
        for inline in inlines {
            guard case .text(let t) = inline.kind else { return false }
            s += t
        }
        return range.count == 5 && s.lowercased() == "[toc]"
    }
}
