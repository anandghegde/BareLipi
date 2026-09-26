import CCmarkGFM
import LipiCore

/// The Phase 1 syntax additions in HTML export (§6.13). Headings get the
/// editor's anchors as `id` (an explicit `{#id}` wins) and their `.class`
/// attributes, and the `{…}` block itself is dropped; a `[toc]` paragraph
/// becomes `TableOfContents.html()`; `:alias:` shortcodes in text become
/// emoji. The editor's parse decides which lines carry what, so the page
/// agrees with the outline and the live `[toc]`; cmark's tree is then edited
/// before it is rendered.
struct ExtendedSyntaxRewriter {
    struct Heading: Equatable {
        var id: String
        var classes: [String]
        /// Whether the heading's text ends in a `{#id .class}` block to drop.
        var hasAttributes: Bool
    }

    /// Headings by 1-based source line (no two headings start on one line).
    var headings: [Int: Heading] = [:]
    /// Lines of top-level `[toc]` paragraphs, as the editor shows them.
    var tocLines: Set<Int> = []
    var tocHTML = ""

    /// `extensions` are the export's; emoji and heading attributes are added
    /// for the editor's view of the document.
    init(markdown: String, extensions: ParserOptions.Extensions) {
        var parser = LipiParser(options: ParserOptions(extensions: extensions.union([.emojiShortcodes, .headingAttributes]),
                                                       keepFootnotes: true))
        parser.parse(markdown)
        let index = parser.index
        let starts = Self.lineStarts(Array(markdown.utf8))
        func line(_ offset: Int) -> Int {
            // The number of line starts at or before `offset`.
            var lo = 0, hi = starts.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if starts[mid] <= offset { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
        // Anchors come from `TableOfContents`, which walks the headings in
        // the order below, so the ids match the `[toc]` links.
        let toc = TableOfContents(index: index)
        var headings: [Int: Heading] = [:], tocLines: Set<Int> = []
        var k = 0
        for i in 0..<index.count {
            let top = index.entries[i].block
            if top.isTableOfContents {
                tocLines.insert(line(index.start(of: i) + top.range.lowerBound))
                continue
            }
            if case .heading = top.kind {} else if !top.kind.isContainer { continue }
            Headings.forEach(in: top) { block, _ in
                guard case .heading = block.kind, k < toc.items.count else { return }
                let item = toc.items[k]
                k += 1
                var hasAttributes = false
                if case .attributes = block.inlines.last?.kind { hasAttributes = true }
                headings[line(item.offset)] = Heading(id: item.anchor, classes: Headings.classes(of: block.inlines),
                                                      hasAttributes: hasAttributes)
            }
        }
        self.headings = headings
        self.tocLines = tocLines
        if !tocLines.isEmpty { tocHTML = toc.html() }
    }

    /// Offsets at which lines start, by cmark's rule (`\n`, `\r`, `\r\n`).
    static func lineStarts(_ bytes: [UInt8]) -> [Int] {
        var starts = [0]
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0D, i + 1 < bytes.count, bytes[i + 1] == 0x0A { i += 1 }
            if bytes[i] == 0x0A || bytes[i] == 0x0D { starts.append(i + 1) }
            i += 1
        }
        return starts
    }

    /// Edits cmark's document tree. Emoji are replaced only in text nodes
    /// outside autolinks: code spans, code blocks and math carry their text
    /// as literals, not text children, so they are never touched.
    func rewrite(_ root: OpaquePointer) {
        cmark_consolidate_text_nodes(root)
        var headingNodes: [OpaquePointer] = [], tocNodes: [OpaquePointer] = [], textNodes: [OpaquePointer] = []
        guard let iter = cmark_iter_new(root) else { return }
        var autolinks = 0
        while true {
            let event = cmark_iter_next(iter)
            if event == CMARK_EVENT_DONE { break }
            guard let node = cmark_iter_get_node(iter) else { continue }
            let type = cmark_node_get_type(node)
            if type == CMARK_NODE_LINK, lipi_node_get_flags(node) & LIPI_FLAG_AUTOLINK != 0 {
                autolinks += event == CMARK_EVENT_ENTER ? 1 : -1
                continue
            }
            guard event == CMARK_EVENT_ENTER else { continue }
            switch type {
            case CMARK_NODE_HEADING:
                headingNodes.append(node)
            case CMARK_NODE_PARAGRAPH where !tocLines.isEmpty && cmark_node_parent(node) == root:
                if tocLines.contains(Int(cmark_node_get_start_line(node))) { tocNodes.append(node) }
            case CMARK_NODE_TEXT where autolinks == 0:
                textNodes.append(node)
            default:
                break
            }
        }
        cmark_iter_free(iter)

        for node in headingNodes {
            guard let heading = headings[Int(cmark_node_get_start_line(node))] else { continue }
            if heading.hasAttributes { Self.dropAttributes(of: node) }
        }
        for node in textNodes { Self.replaceEmoji(in: node) }
        for node in headingNodes {
            guard let heading = headings[Int(cmark_node_get_start_line(node))] else { continue }
            Self.replace(node, with: heading)
        }
        for node in tocNodes {
            guard let html = cmark_node_new(CMARK_NODE_HTML_BLOCK) else { continue }
            cmark_node_set_literal(html, tocHTML)
            cmark_node_replace(node, html)
            cmark_node_free(node)
        }
    }

    /// Removes the trailing `{…}` block, and the blanks before it, from the
    /// heading's last text node.
    static func dropAttributes(of heading: OpaquePointer) {
        guard let last = cmark_node_last_child(heading), cmark_node_get_type(last) == CMARK_NODE_TEXT,
              let literal = cmark_node_get_literal(last) else { return }
        var text = String(cString: literal)
        guard text.hasSuffix("}"), let open = text.lastIndex(of: "{") else { return }
        text = String(text[..<open])
        while text.last == " " || text.last == "\t" { text.removeLast() }
        cmark_node_set_literal(last, text)
    }

    /// Shortcodes in a text node's literal replaced by their emoji.
    static func replaceEmoji(in node: OpaquePointer) {
        guard let literal = cmark_node_get_literal(node) else { return }
        let text = String(cString: literal)
        var colons = 0
        for b in text.utf8 where b == 0x3A { colons += 1; if colons == 2 { break } }
        guard colons == 2 else { return }
        let bytes = Array(text.utf8)
        let found = EmojiShortcodes.matches(in: bytes)
        guard !found.isEmpty else { return }
        var out = ""
        var at = 0
        for (range, emoji) in found {
            out += String(decoding: bytes[at..<range.lowerBound], as: UTF8.self)
            out += emoji
            at = range.upperBound
        }
        out += String(decoding: bytes[at...], as: UTF8.self)
        cmark_node_set_literal(node, out)
    }

    /// Swaps the heading for a custom inline carrying `<hN id class>` inside
    /// an empty custom block (a custom block's own tags would be put on lines
    /// of their own).
    static func replace(_ node: OpaquePointer, with heading: Heading) {
        guard let block = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK), let inline = cmark_node_new(CMARK_NODE_CUSTOM_INLINE) else { return }
        let level = cmark_node_get_heading_level(node)
        var open = "<h\(level) id=\"\(HTMLEscaping.escape(heading.id))\""
        if !heading.classes.isEmpty { open += " class=\"\(HTMLEscaping.escape(heading.classes.joined(separator: " ")))\"" }
        cmark_node_set_on_enter(inline, open + ">")
        cmark_node_set_on_exit(inline, "</h\(level)>")
        while let child = cmark_node_first_child(node) { cmark_node_append_child(inline, child) }
        cmark_node_append_child(block, inline)
        cmark_node_replace(node, block)
        cmark_node_free(node)
    }
}
