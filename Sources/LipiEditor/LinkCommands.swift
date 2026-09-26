import Foundation
import LipiCore

/// What the Cmd-K link popover (§6.1.5) edits: prefilled from the link
/// under the caret, or from the selection and a URL on the pasteboard.
public struct LinkDraft: Sendable, Equatable {
    public var label: String
    public var destination: String
    public var title: String
    /// Source bytes the committed link replaces: the existing link, or the selection.
    public var range: Range<Int>
    /// True when editing a link that is already in the document.
    public var isExisting: Bool

    public init(label: String, destination: String, title: String, range: Range<Int>, isExisting: Bool) {
        self.label = label
        self.destination = destination
        self.title = title
        self.range = range
        self.isExisting = isExisting
    }

    /// A pasteboard string that should prefill the destination: one token
    /// with a URL scheme, or starting `www.`.
    public static func url(fromPasteboard s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
              !s.contains(where: { $0.isWhitespace }), s.count < 2048 else { return nil }
        if s.lowercased().hasPrefix("www.") { return s }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "ftp", "file", "tel"].contains(scheme) else { return nil }
        if scheme == "http" || scheme == "https" { guard url.host?.isEmpty == false else { return nil } }
        return s
    }
}

extension MarkdownCommands {
    /// The non-autolink link around the selection, outermost first wins.
    private func linkUnderSelection() -> Inline? {
        for inline in doc.inlinePath(at: range.lowerBound) {
            guard case .link(_, _, false) = inline.kind else { continue }
            if inline.range.lowerBound <= range.lowerBound, range.upperBound <= inline.range.upperBound { return inline }
        }
        return nil
    }

    /// The label source of `[label](…)`: from after `[` to the matching `]`.
    private func labelRange(of link: Inline) -> Range<Int> {
        let start = link.range.lowerBound + 1
        var depth = 0
        var p = start
        while p < link.range.upperBound {
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

    func linkDraft(pasteboard: String?) -> LinkDraft {
        if let link = linkUnderSelection(), case .link(let destination, let title, _) = link.kind {
            return LinkDraft(label: doc.string(labelRange(of: link)), destination: destination, title: title,
                             range: link.range, isExisting: true)
        }
        let url = LinkDraft.url(fromPasteboard: pasteboard) ?? ""
        return LinkDraft(label: doc.string(range), destination: url, title: "", range: range, isExisting: false)
    }

    /// Commits a draft. An existing link with an empty destination is
    /// removed, keeping its label.
    func commitLink(_ draft: LinkDraft) -> EditPlan {
        let r = min(draft.range.lowerBound, doc.count)..<min(draft.range.upperBound, doc.count)
        if draft.isExisting, draft.destination.trimmingCharacters(in: .whitespaces).isEmpty {
            var b = PlanBuilder()
            b.replace(r, draft.label)
            return b.plan(caret: r.lowerBound + draft.label.utf8.count)
        }
        return link(label: draft.label, destination: draft.destination.trimmingCharacters(in: .whitespaces),
                    title: draft.title.isEmpty ? nil : draft.title, replacing: r)
    }
}
