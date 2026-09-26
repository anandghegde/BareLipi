import CoreGraphics
import Foundation
import LipiCore

/// A footnote reference in the document: `[^label]` at `range`.
public struct FootnoteReferenceHit: Sendable, Equatable {
    public var label: String
    /// Source range of the whole `[^label]`.
    public var range: Range<Int>
    /// The number shown for it; nil when the label has no definition.
    public var number: Int?
}

/// A footnote definition: `[^label]: …` at `range`.
public struct FootnoteDefinitionHit: Sendable, Equatable {
    public var label: String
    public var range: Range<Int>
    /// Where the note's text starts (after `[^label]: `).
    public var contentStart: Int
    public var number: Int?
}

/// Footnote navigation (§6.13): hover or Cmd-Opt-Down shows a reference's
/// note, clicking a reference jumps to its definition, and the `↩` in a
/// definition's gutter returns to the first reference.
extension EditorController {
    /// Every footnote reference, in document order.
    public func footnoteReferences() -> [FootnoteReferenceHit] {
        var out: [FootnoteReferenceHit] = []
        let index = blockIndex
        let numbers = projection.footnotes
        for i in 0..<index.count {
            let base = index.start(of: i)
            index.entries[i].block.forEachBlock { b in
                for inline in b.inlines {
                    inline.forEachInline { x in
                        guard case .footnoteReference(let label) = x.kind else { return }
                        let r = (base + x.range.lowerBound)..<(base + x.range.upperBound)
                        out.append(FootnoteReferenceHit(label: label, range: r, number: numbers.number(for: label)))
                    }
                }
            }
        }
        return out
    }

    /// The reference whose `[^label]` contains `offset` (its end included).
    public func footnoteReference(containing offset: Int) -> FootnoteReferenceHit? {
        let index = blockIndex
        guard let i = index.entryIndex(containing: offset) else { return nil }
        let base = index.start(of: i)
        let numbers = projection.footnotes
        var hit: FootnoteReferenceHit?
        index.entries[i].block.forEachBlock { b in
            guard hit == nil else { return }
            for inline in b.inlines {
                inline.forEachInline { x in
                    guard hit == nil, case .footnoteReference(let label) = x.kind else { return }
                    let r = (base + x.range.lowerBound)..<(base + x.range.upperBound)
                    if r.contains(offset) || r.upperBound == offset {
                        hit = FootnoteReferenceHit(label: label, range: r, number: numbers.number(for: label))
                    }
                }
            }
        }
        return hit
    }

    /// The definition of `label` (matched as cmark does: case-insensitive,
    /// whitespace collapsed); the first one when several exist.
    public func footnoteDefinition(label: String) -> FootnoteDefinitionHit? {
        let key = FootnoteNumbering.normalize(label)
        return firstDefinition { FootnoteNumbering.normalize($0) == key }
    }

    /// The definition whose span contains `offset`.
    func footnoteDefinition(containing offset: Int) -> FootnoteDefinitionHit? {
        let index = blockIndex
        guard let i = index.entryIndex(containing: offset) else { return nil }
        var found: FootnoteDefinitionHit?
        definitions(in: i) { def in
            if def.range.contains(offset) { found = def }
        }
        return found
    }

    private func firstDefinition(where match: (String) -> Bool) -> FootnoteDefinitionHit? {
        let index = blockIndex
        for i in 0..<index.count {
            var found: FootnoteDefinitionHit?
            definitions(in: i) { def in
                if found == nil, match(def.label) { found = def }
            }
            if let found { return found }
        }
        return nil
    }

    private func definitions(in i: Int, _ body: (FootnoteDefinitionHit) -> Void) {
        let index = blockIndex
        let base = index.start(of: i)
        let numbers = projection.footnotes
        index.entries[i].block.forEachBlock { b in
            guard case .footnoteDefinition(let l) = b.kind else { return }
            let range = (base + b.range.lowerBound)..<(base + b.range.upperBound)
            let content = b.children.first.map { base + $0.range.lowerBound } ?? range.upperBound
            body(FootnoteDefinitionHit(label: l, range: range, contentStart: content, number: numbers.number(for: l)))
        }
    }

    /// The note's text as the popover shows it: each paragraph's plain text,
    /// other blocks as written. Nil when `label` has no definition.
    public func footnoteText(label: String) -> String? {
        guard let def = footnoteDefinition(label: label),
              let i = blockIndex.entryIndex(containing: def.range.lowerBound) else { return nil }
        let base = blockIndex.start(of: i)
        var parts: [String]?
        blockIndex.entries[i].block.forEachBlock { b in
            guard parts == nil, case .footnoteDefinition = b.kind,
                  base + b.range.lowerBound == def.range.lowerBound else { return }
            var out: [String] = []
            for child in b.children {
                if case .paragraph = child.kind {
                    out.append(Outline.text(of: child.inlines))
                } else {
                    let r = (base + child.range.lowerBound)..<(base + child.range.upperBound)
                    out.append(string(in: r).trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            parts = out
        }
        return (parts ?? []).joined(separator: "\n\n")
    }

    /// The rendered reference under `point`; nil in source mode and while
    /// the caret is in it (it is then revealed and a click edits it).
    public func footnoteReference(at point: CGPoint) -> FootnoteReferenceHit? {
        guard mode != .source, let offset = sourceOffset(at: point),
              let hit = footnoteReference(containing: offset) else { return nil }
        if selection.range.overlaps(hit.range) || hit.range.contains(selection.head) || hit.range.upperBound == selection.head {
            return nil
        }
        let rects = rects(forSource: hit.range, visible: .infinite)
        guard rects.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(point) }) else { return nil }
        return hit
    }

    /// The definition whose gutter `↩` is at `point` (the return link).
    public func footnoteReturnLink(at point: CGPoint) -> FootnoteDefinitionHit? {
        guard mode != .source, let offset = sourceOffset(at: point),
              let def = footnoteDefinition(containing: offset) else { return nil }
        let text = caretRect(forSource: def.contentStart)
        let start = caretRect(forSource: def.range.lowerBound)
        // Revealed: `[^label]: ` is on screen and the gutter is empty.
        guard abs(text.minX - start.minX) < 0.5, abs(text.minY - start.minY) < 0.5 else { return nil }
        guard point.y >= text.minY, point.y <= text.maxY,
              point.x < text.minX, point.x >= text.minX - 72 else { return nil }
        return def
    }

    /// Moves the caret to the start of `label`'s note. Returns false when it
    /// has no definition.
    @discardableResult
    public func jumpToFootnoteDefinition(label: String) -> Bool {
        guard let def = footnoteDefinition(label: label) else { return false }
        if marked != nil { _ = unmarkText() }
        moveCaret(to: def.contentStart)
        return true
    }

    /// Moves the caret just after the first reference to `label`.
    @discardableResult
    public func returnToFootnoteReference(label: String) -> Bool {
        let key = FootnoteNumbering.normalize(label)
        guard let ref = footnoteReferences().first(where: { FootnoteNumbering.normalize($0.label) == key }) else { return false }
        if marked != nil { _ = unmarkText() }
        moveCaret(to: ref.range.upperBound)
        return true
    }

    /// The reference at the caret (or just before it), for Cmd-Opt-Down.
    public func footnoteReferenceAtCaret() -> FootnoteReferenceHit? {
        footnoteReference(containing: selection.head)
    }
}
