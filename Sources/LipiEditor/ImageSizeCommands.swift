import Foundation
import LipiCore

/// An image in the source that the resize commands act on (P0-07): a
/// Markdown `![alt](src "title")` or an HTML `<img …>` tag, inline or as an
/// HTML block. Size is stored the Typora way, `style="zoom:50%"`.
public struct ImageTarget: Sendable, Equatable {
    public enum Form: Sendable, Equatable { case markdown, html }

    /// Source bytes of the whole image.
    public var range: Range<Int>
    public var form: Form
    /// Zoom in percent from `style="zoom:…"`; nil when there is none.
    public var zoom: Int?
    /// True when the tag also sets `width` or `height`.
    public var hasSize: Bool

    /// Zoom presets offered by the image context menu.
    public static let zoomPresets = [25, 33, 50, 67, 100]
}

/// The attributes of one `<img …>` tag, keeping each one's source text so a
/// rewrite changes only the attributes it touches.
struct HTMLImageTag: Equatable {
    struct Attribute: Equatable {
        /// Whitespace before the attribute.
        var lead: String
        /// Lowercased name.
        var name: String
        /// Raw (entity-encoded) value; nil for a bare attribute.
        var value: String?
        /// The attribute's source text after `lead`.
        var text: String
    }

    /// `<img` as written (any case).
    var open: String
    var attributes: [Attribute]
    /// `>`, `/>` or ` />`: the rest of the tag.
    var close: String

    /// Parses `s`, which must be exactly one `<img …>` open tag.
    static func parse(_ s: String) -> HTMLImageTag? {
        let b = Array(s.utf8)
        guard let end = tagEnd(b, from: 0), end == b.count else { return nil }
        guard b.count >= 5, String(decoding: b[0..<4], as: UTF8.self).lowercased() == "<img" else { return nil }
        var i = 4
        guard isSpace(b[i]) || b[i] == 0x2F || b[i] == 0x3E else { return nil }
        var attributes: [Attribute] = []
        while true {
            let start = i
            while i < b.count, isSpace(b[i]) { i += 1 }
            guard i < b.count else { return nil }
            if b[i] == 0x3E || (b[i] == 0x2F && i + 1 < b.count && b[i + 1] == 0x3E) {
                guard (b[i] == 0x3E ? i + 1 : i + 2) == b.count else { return nil }
                return HTMLImageTag(open: String(decoding: b[0..<4], as: UTF8.self), attributes: attributes,
                                    close: String(decoding: b[start...], as: UTF8.self))
            }
            guard i > start else { return nil }
            let lead = String(decoding: b[start..<i], as: UTF8.self)
            let nameStart = i
            while i < b.count, isNameByte(b[i]) { i += 1 }
            guard i > nameStart else { return nil }
            let name = String(decoding: b[nameStart..<i], as: UTF8.self).lowercased()
            var j = i
            while j < b.count, isSpace(b[j]) { j += 1 }
            var value: String?
            if j < b.count, b[j] == 0x3D {
                j += 1
                while j < b.count, isSpace(b[j]) { j += 1 }
                guard j < b.count else { return nil }
                if b[j] == 0x22 || b[j] == 0x27 {
                    let q = b[j]
                    guard let close = b[(j + 1)...].firstIndex(of: q) else { return nil }
                    value = String(decoding: b[(j + 1)..<close], as: UTF8.self)
                    j = close + 1
                } else {
                    let vs = j
                    while j < b.count, !isSpace(b[j]), ![0x22, 0x27, 0x3D, 0x3C, 0x3E, 0x60].contains(b[j]) { j += 1 }
                    guard j > vs else { return nil }
                    value = String(decoding: b[vs..<j], as: UTF8.self)
                }
                i = j
            }
            attributes.append(Attribute(lead: lead, name: name, value: value,
                                        text: String(decoding: b[nameStart..<i], as: UTF8.self)))
        }
    }

    /// The end (exclusive) of the tag starting at `from` (`<`), skipping `>`
    /// inside quoted values; nil when unterminated.
    static func tagEnd(_ b: [UInt8], from: Int) -> Int? {
        var i = from
        var quote: UInt8? = nil
        while i < b.count {
            let c = b[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == 0x22 || c == 0x27 {
                quote = c
            } else if c == 0x3E {
                return i + 1
            }
            i += 1
        }
        return nil
    }

    static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C }
    static func isNameByte(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x3A
            || c == 0x2E || c == 0x2D
    }

    var text: String { open + attributes.map { $0.lead + $0.text }.joined() + close }

    func value(_ name: String) -> String? { attributes.first { $0.name == name }?.value }

    mutating func set(_ name: String, _ value: String) {
        let text = name + "=\"" + value + "\""
        if let i = attributes.firstIndex(where: { $0.name == name }) {
            attributes[i].value = value
            attributes[i].text = text
        } else {
            attributes.append(Attribute(lead: " ", name: name, value: value, text: text))
        }
    }

    mutating func remove(_ name: String) { attributes.removeAll { $0.name == name } }

    /// The `zoom` of the style attribute, in percent.
    var zoom: Int? {
        guard let style = value("style") else { return nil }
        return HTMLImageTag.declarations(style).first { $0.property == "zoom" }.flatMap { HTMLImageTag.percent($0.value) }
    }

    /// Sets (or with nil removes) the style's `zoom`, keeping its other
    /// declarations; an emptied style attribute is dropped.
    mutating func setZoom(_ zoom: Int?) {
        let style = value("style") ?? ""
        var decls = HTMLImageTag.declarations(style).filter { $0.property != "zoom" }.map(\.raw)
        if let zoom { decls.append("zoom:\(zoom)%") }
        if decls.isEmpty { remove("style") } else { set("style", decls.joined(separator: "; ") + ";") }
    }

    static func declarations(_ style: String) -> [(property: String, value: String, raw: String)] {
        style.split(separator: ";").compactMap { part in
            let raw = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            let pieces = raw.split(separator: ":", maxSplits: 1)
            let property = pieces[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pieces.count > 1 ? pieces[1].trimmingCharacters(in: .whitespaces) : ""
            return (property, value, raw)
        }
    }

    /// `50%` → 50, `0.5` → 50.
    static func percent(_ v: String) -> Int? {
        let t = v.replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("%") { return Double(t.dropLast()).map { Int($0.rounded()) } }
        return Double(t).map { Int(($0 * 100).rounded()) }
    }
}

/// Minimal HTML attribute escaping for the values the resize command writes.
enum ImageHTML {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }

    /// A Markdown link destination: in angle brackets when it has spaces or
    /// parentheses (as `EditorView.linkDestination`).
    static func destination(_ d: String) -> String {
        guard d.contains(where: { $0 == " " || $0 == "(" || $0 == ")" || $0 == "<" }) else { return d }
        return "<" + d.replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E") + ">"
    }

    /// Line breaks folded to spaces: an attribute written on one line.
    static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

extension MarkdownCommands {
    /// The image at source offset `p`, if any.
    func image(at p: Int) -> ImageTarget? {
        if let md = markdownImage(at: p) {
            return ImageTarget(range: md.range, form: .markdown, zoom: nil, hasSize: false)
        }
        guard let (range, tag) = htmlImage(at: p) else { return nil }
        return ImageTarget(range: range, form: .html, zoom: tag.zoom, hasSize: tag.value("width") != nil || tag.value("height") != nil)
    }

    private func markdownImage(at p: Int) -> Inline? {
        doc.inlinePath(at: p).last { if case .image = $0.kind { return true } else { return false } }
    }

    /// The `<img>` tag around `p` in an HTML block or an inline HTML node.
    private func htmlImage(at p: Int) -> (Range<Int>, HTMLImageTag)? {
        guard let leaf = doc.path(at: p).last else { return nil }
        let region: Range<Int>
        if case .htmlBlock = leaf.kind {
            region = leaf.range
        } else if let inline = doc.inlinePath(at: p).last(where: { if case .html = $0.kind { return true } else { return false } }) {
            region = inline.range
        } else {
            return nil
        }
        let b = doc.bytes(region)
        var i = 0
        while i + 4 <= b.count {
            if b[i] == 0x3C, String(decoding: b[i..<(i + 4)], as: UTF8.self).lowercased() == "<img",
               let end = HTMLImageTag.tagEnd(b, from: i) {
                let r = (region.lowerBound + i)..<(region.lowerBound + end)
                if r.lowerBound <= p, p <= r.upperBound {
                    guard let tag = HTMLImageTag.parse(String(decoding: b[i..<end], as: UTF8.self)) else { return nil }
                    return (r, tag)
                }
                if r.lowerBound > p { return nil }
                i = end
            } else {
                i += 1
            }
        }
        return nil
    }

    /// `![alt](…)`: the label's source bytes.
    private func altRange(of image: Inline) -> Range<Int> {
        let start = min(image.range.lowerBound + 2, image.range.upperBound)
        var depth = 0
        var p = start
        while p < image.range.upperBound {
            let b = doc.byte(p)
            if b == 0x5C { p += 2; continue }
            if b == 0x5B { depth += 1 }
            if b == 0x5D {
                if depth == 0 { return start..<p }
                depth -= 1
            }
            p += 1
        }
        return start..<start
    }

    /// Sets the zoom of the image at `p` to `zoom` percent, or with nil
    /// restores its original size. A Markdown image becomes
    /// `<img src alt [title] style="zoom:N%;" />`; an `<img>` tag gets its
    /// style's zoom set and `width` / `height` dropped, and turns back into
    /// Markdown when only `src`, `alt` and `title` remain. Only the image's
    /// bytes change. Nil when nothing would change.
    func setImageZoom(_ zoom: Int?, at p: Int) -> EditPlan? {
        let replacement: String
        let range: Range<Int>
        if let image = markdownImage(at: p), case .image(let src, let title) = image.kind {
            guard let zoom else { return nil }
            range = image.range
            let alt = ImageHTML.oneLine(doc.string(altRange(of: image)))
            var tag = "<img src=\"" + ImageHTML.escape(src) + "\" alt=\"" + ImageHTML.escape(alt) + "\""
            if !title.isEmpty { tag += " title=\"" + ImageHTML.escape(ImageHTML.oneLine(title)) + "\"" }
            replacement = tag + " style=\"zoom:\(zoom)%;\" />"
        } else if let (r, original) = htmlImage(at: p) {
            range = r
            var tag = original
            tag.remove("width")
            tag.remove("height")
            tag.setZoom(zoom)
            if zoom == nil, let src = tag.value("src"), tag.attributes.allSatisfy({ ["src", "alt", "title"].contains($0.name) }) {
                let alt = ImageHTML.unescape(tag.value("alt") ?? "")
                    .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[")
                    .replacingOccurrences(of: "]", with: "\\]")
                var md = "![" + alt + "](" + ImageHTML.destination(ImageHTML.unescape(src))
                if let title = tag.value("title"), !title.isEmpty {
                    md += " \"" + ImageHTML.unescape(title).replacingOccurrences(of: "\"", with: "\\\"") + "\""
                }
                replacement = md + ")"
            } else {
                replacement = tag.text
            }
        } else {
            return nil
        }
        guard replacement != doc.string(range) else { return nil }
        var b = PlanBuilder()
        b.replace(range, replacement)
        if selection.isEmpty { return b.plan(anchor: selection.head, anchorAfter: true, head: selection.head, headAfter: true) }
        let forward = selection.head >= selection.anchor
        return b.plan(anchor: selection.anchor, anchorAfter: !forward, head: selection.head, headAfter: forward)
    }
}

extension EditorController {
    /// The image at source offset `offset` (a Markdown image or an `<img>` tag).
    public func image(at offset: Int) -> ImageTarget? {
        commands.image(at: max(0, min(offset, buffer.count)))
    }

    /// Resizes the image at `offset` (see `MarkdownCommands.setImageZoom`)
    /// as one undo step; nil zoom restores the original size. Returns nil
    /// when there is no image there or nothing changes.
    @discardableResult
    public func setImageZoom(_ zoom: Int?, at offset: Int) -> EditorChange? {
        guard let plan = commands.setImageZoom(zoom, at: max(0, min(offset, buffer.count))) else { return nil }
        return perform(plan)
    }
}
