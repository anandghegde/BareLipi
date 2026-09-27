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

/// Minimal HTML attribute escaping for the values the resize command writes.
enum ImageHTML {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func unescape(_ s: String) -> String { HTMLImageTag.unescape(s) }

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
