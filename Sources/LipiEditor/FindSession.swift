import AppKit
import LipiCore

/// In-document Find and Replace (P0-10) over one `EditorController`.
///
/// Matches are source byte ranges, recomputed lazily when the query, the
/// scope or the text generation changes. Moving to a match selects it, so
/// the reveal policy shows the syntax around it (a match inside a folded
/// link destination reveals its node while current). Replace and Replace
/// All go through `EditorController.perform`, one undo step each, and edit
/// nothing outside the matches.
@MainActor
public final class FindSession {
    public let controller: EditorController
    public var query = FindQuery("")
    public var scope: FindScope = .source
    /// Highlights are drawn only while the find bar is open.
    public var isActive = false

    private var cache: (generation: UInt64, query: FindQuery, scope: FindScope, matches: [Range<Int>])?
    private var textCache: (generation: UInt64, text: SearchText)?
    public private(set) var error: FindError?

    public init(controller: EditorController) {
        self.controller = controller
    }

    // MARK: Matches

    /// All matches, sorted, for the current query and text.
    public var matches: [Range<Int>] {
        let generation = controller.buffer.generation
        if let cache, cache.generation == generation, cache.query == query, cache.scope == scope { return cache.matches }
        let found: [Range<Int>]
        do {
            switch scope {
            case .source:
                found = try DocumentSearch.matches(of: query, in: searchText)
            case .rendered:
                var hidden = Projection(preset: controller.projection.preset)
                if !query.isEmpty { hidden.update(index: controller.blockIndex, rope: controller.rope, reveal: RevealSet()) }
                found = try DocumentSearch.renderedMatches(of: query, in: hidden)
            }
            error = nil
        } catch let e as FindError {
            error = e
            found = []
        } catch {
            found = []
        }
        cache = (generation, query, scope, found)
        return found
    }

    /// The text searched, copied once per generation.
    var searchText: SearchText {
        let generation = controller.buffer.generation
        if let textCache, textCache.generation == generation { return textCache.text }
        let text = SearchText(controller.rope)
        textCache = (generation, text)
        return text
    }

    public var count: Int { matches.count }

    /// Index of the match the selection is on, if any.
    public var currentIndex: Int? {
        let sel = controller.selection.range
        guard !sel.isEmpty else { return nil }
        let m = matches
        let i = firstIndex(in: m) { $0.lowerBound >= sel.lowerBound }
        return i < m.count && m[i] == sel ? i : nil
    }

    /// Matches intersecting `range` (for drawing the visible ones only).
    public func matches(intersecting range: Range<Int>) -> ArraySlice<Range<Int>> {
        let m = matches
        let lo = firstIndex(in: m) { $0.upperBound > range.lowerBound }
        let hi = firstIndex(in: m) { $0.lowerBound >= range.upperBound }
        return lo < hi ? m[lo..<hi] : []
    }

    /// First index where `pred` holds, `pred` being monotonic over `m`.
    private func firstIndex(in m: [Range<Int>], where pred: (Range<Int>) -> Bool) -> Int {
        var lo = 0, hi = m.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if pred(m[mid]) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }

    // MARK: Navigation

    /// Incremental search: selects the first match at or after the start of
    /// the selection (wrapping), as typing in the find field does.
    @discardableResult
    public func findFromSelection() -> Range<Int>? {
        let m = matches
        guard !m.isEmpty else { return nil }
        let start = controller.selection.range.lowerBound
        let i = firstIndex(in: m) { $0.lowerBound >= start }
        return select(m[i < m.count ? i : 0])
    }

    /// Enter / Cmd-G: the match after the selection, wrapping.
    @discardableResult
    public func next() -> Range<Int>? {
        let m = matches
        guard !m.isEmpty else { return nil }
        let sel = controller.selection.range
        let i = sel.isEmpty ? firstIndex(in: m) { $0.lowerBound >= sel.lowerBound }
                            : firstIndex(in: m) { $0.lowerBound >= sel.upperBound }
        return select(m[i < m.count ? i : 0])
    }

    /// Shift-Enter / Cmd-Shift-G: the match before the selection, wrapping.
    @discardableResult
    public func previous() -> Range<Int>? {
        let m = matches
        guard !m.isEmpty else { return nil }
        let start = controller.selection.range.lowerBound
        let i = firstIndex(in: m) { $0.upperBound > start } - 1
        return select(m[i >= 0 ? i : m.count - 1])
    }

    private func select(_ range: Range<Int>) -> Range<Int> {
        controller.select(range)
        return range
    }

    // MARK: Replace

    /// Replaces the current match (the selection, when it is one) and moves
    /// to the next; with no current match, moves to the next match only.
    /// Returns true when text was replaced.
    @discardableResult
    public func replaceCurrent(with template: String) -> Bool {
        guard let i = currentIndex else { next(); return false }
        let range = matches[i]
        let text: String
        do {
            guard let r = try DocumentSearch.replacement(for: range, of: query, in: controller.rope, template: template) else { return false }
            text = r
        } catch { return false }
        let end = range.lowerBound + text.utf8.count
        let before = controller.buffer.generation
        controller.perform(EditPlan(edits: [Edit(replacing: range, with: text)], anchor: end, head: end))
        guard controller.buffer.generation != before else { return false }
        next()
        return true
    }

    /// Replaces every match as one undo step and returns how many were
    /// replaced. Bytes outside the matches are never touched.
    @discardableResult
    public func replaceAll(with template: String) -> Int {
        let edits: [Edit]
        do {
            switch scope {
            case .source:
                edits = try DocumentSearch.replaceAllEdits(of: query, in: searchText, template: template)
            case .rendered:
                edits = try matches.map { r in
                    Edit(replacing: r, with: try DocumentSearch.replacement(for: r, of: query, in: controller.rope, template: template) ?? template)
                }
            }
        } catch { return 0 }
        guard !edits.isEmpty, controller.isEditable else {
            if !edits.isEmpty { controller.perform(EditPlan(edits: edits, anchor: 0, head: 0)) }  // reports the refusal
            return 0
        }
        // Keep the caret on the same text: shift it by the edits before it.
        let caret = controller.selection.range.lowerBound
        var shift = 0
        for e in edits where e.range.upperBound.byte <= caret { shift += e.insertedBytes - e.removedBytes }
        let inside = edits.first { $0.range.lowerBound.byte < caret && caret < $0.range.upperBound.byte }
        let target = inside.map { $0.range.lowerBound.byte + shift } ?? caret + shift
        controller.perform(EditPlan(edits: edits, anchor: target, head: target))
        return edits.count
    }
}
