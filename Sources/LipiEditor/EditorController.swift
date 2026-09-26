import AppKit
import CoreText
import Foundation
import LipiCore
import LipiLayout

/// Which layout engine the controller runs (the ADR-002 spike switch).
public enum LayoutEngineKind: String, Sendable, CaseIterable {
    case lipi
    case textkit2
}

/// The editing model behind `EditorView`: source buffer, incremental parser,
/// reveal policy, projection and layout, run as the §7.4 keystroke pipeline
/// on the main thread. Every mutation is an `Edit`; every query is answered
/// from the projection and the layout without touching AppKit.
@MainActor
public final class EditorController {
    public struct Stats: Sendable {
        public var keystrokes = 0
        /// Seconds of the most recent pipeline run (buffer → caret rect).
        public var lastPipelineSeconds: Double = 0
    }

    public let engine: LayoutEngineKind
    public private(set) var buffer: SourceBuffer
    private var parser: LipiParser
    public let policy: RevealPolicy
    public private(set) var projection: Projection
    public private(set) var typesetter: Typesetter
    public private(set) var renderer: Renderer
    /// Block layout (ADR-002). Present in both modes: it owns the measure and
    /// text origin; in `.textkit2` mode it holds no entry layouts.
    public let layout: DocumentLayout
    public private(set) var textKit: TextKit2Layout?
    private var textKitEntryIDs: [NodeID] = []
    public private(set) var selection: SelectionModel
    public private(set) var marked: MarkedText?
    public private(set) var stats = Stats()
    /// Called after every pipeline run.
    public var onChange: ((EditorChange) -> Void)?
    private var typingGroupOpen = false

    public init(text: String = "", engine: LayoutEngineKind = .lipi, theme: Theme = .paper, zoom: CGFloat = 1,
                preset: RevealPreset = .balanced, viewportWidth: CGFloat = 800) {
        self.engine = engine
        buffer = SourceBuffer(text)
        parser = LipiParser(options: .editor)
        parser.parse(buffer.rope)
        policy = RevealPolicy(preset: preset)
        projection = Projection(preset: preset)
        typesetter = Typesetter(scale: TypeScale(theme: theme, zoom: zoom), cascade: FontCascade(theme: theme))
        renderer = Renderer(typesetter: typesetter)
        layout = DocumentLayout(typesetter: typesetter, viewportWidth: viewportWidth)
        selection = SelectionModel(caret: 0)
        if engine == .textkit2 { textKit = TextKit2Layout(width: layout.measure) }
        _ = refresh(textChanged: true, started: DispatchTime.now())
    }

    // MARK: Document

    public var rope: LipiRope { buffer.rope }
    public var count: Int { buffer.count }
    public var string: String { buffer.rope.string }
    public var caret: Int { selection.head }
    public var theme: Theme { typesetter.scale.theme }
    public var zoom: CGFloat { typesetter.scale.zoom }

    /// Replaces the whole document (open, revert). Clears the undo history.
    public func load(_ text: String) {
        buffer.reset(to: text)
        parser = LipiParser(options: .editor)
        parser.parse(buffer.rope)
        selection = SelectionModel(caret: 0)
        marked = nil
        typingGroupOpen = false
        _ = refresh(textChanged: true, started: DispatchTime.now())
    }

    public func setViewportWidth(_ width: CGFloat) {
        layout.setViewportWidth(width)
        textKit?.setWidth(layout.measure)
    }

    public func setTheme(_ theme: Theme, zoom: CGFloat? = nil) {
        typesetter = Typesetter(scale: TypeScale(theme: theme, zoom: zoom ?? self.zoom), cascade: FontCascade(theme: theme))
        renderer = Renderer(typesetter: typesetter)
        layout.setTypesetter(typesetter)
        if let textKit {
            textKit.setWidth(layout.measure)
            textKit.load(projection, typesetter: typesetter)
            textKitEntryIDs = projection.entries.map(\.id)
        }
        _ = refresh(textChanged: false, started: DispatchTime.now())
    }

    // MARK: The keystroke pipeline (§7.4)

    /// Replaces `range` (source bytes) with `text` and puts the caret after
    /// the replacement, or at `caretAfter`. Steps 1–8 of §7.4.
    @discardableResult
    public func replace(_ range: Range<Int>, with text: String, caretAfter: Int? = nil) -> EditorChange {
        let started = DispatchTime.now()
        let range = clamp(range)
        let delta = applyEdit(range, text, caretAfter: caretAfter)
        if var m = marked {
            m.range = delta.map(SourceOffset(m.range.lowerBound), preferEnd: false).byte..<delta.map(SourceOffset(m.range.upperBound)).byte
            marked = m.range.isEmpty ? nil : m
        }
        stats.keystrokes += 1
        return refresh(textChanged: true, started: started)
    }

    /// Steps 1–3: buffer, parser, caret. Leaves `marked` to the caller.
    private func applyEdit(_ range: Range<Int>, _ text: String, caretAfter: Int?) -> Delta {
        let delta = buffer.apply(Edit(replacing: range, with: text))
        parser.apply(delta, then: buffer.rope)
        selection = SelectionModel(caret: caretAfter ?? (range.lowerBound + text.utf8.count))
        return delta
    }

    /// Types `text` at the caret, replacing the selection (or the marked text).
    @discardableResult
    public func insert(_ text: String) -> EditorChange {
        let target = marked?.range ?? selection.range
        marked = nil
        let single = text.utf8.count <= 4 && !text.contains("\n")
        if single {
            if !typingGroupOpen { buffer.beginUndoGroup(); typingGroupOpen = true }
        } else {
            closeTypingGroup()
        }
        return replace(target, with: text)
    }

    @discardableResult
    public func insertNewline() -> EditorChange {
        closeTypingGroup()
        return replace(selection.range, with: "\n")
    }

    /// Deletes the selection, or the grapheme cluster before the caret.
    @discardableResult
    public func deleteBackward() -> EditorChange {
        closeTypingGroup()
        if !selection.isEmpty { return replace(selection.range, with: "") }
        let caret = selection.head
        guard caret > 0 else { return refresh(textChanged: false, started: DispatchTime.now()) }
        let start = previousCaretStop(before: caret)
        return replace(start..<caret, with: "")
    }

    /// Deletes the selection, or the grapheme cluster after the caret.
    @discardableResult
    public func deleteForward() -> EditorChange {
        closeTypingGroup()
        if !selection.isEmpty { return replace(selection.range, with: "") }
        let caret = selection.head
        guard caret < buffer.count else { return refresh(textChanged: false, started: DispatchTime.now()) }
        let end = nextCaretStop(after: caret)
        return replace(caret..<end, with: "", caretAfter: caret)
    }

    @discardableResult
    public func undo() -> EditorChange {
        typingGroupOpen = false
        marked = nil
        let started = DispatchTime.now()
        let deltas = buffer.undo()
        guard !deltas.isEmpty else { return refresh(textChanged: false, started: started) }
        for delta in deltas { parser.apply(delta, then: buffer.rope) }
        selection = SelectionModel(caret: deltas.last!.newRange.upperBound.byte)
        return refresh(textChanged: true, started: started)
    }

    @discardableResult
    public func redo() -> EditorChange {
        typingGroupOpen = false
        marked = nil
        let started = DispatchTime.now()
        let deltas = buffer.redo()
        guard !deltas.isEmpty else { return refresh(textChanged: false, started: started) }
        for delta in deltas { parser.apply(delta, then: buffer.rope) }
        selection = SelectionModel(caret: deltas.last!.newRange.upperBound.byte)
        return refresh(textChanged: true, started: started)
    }

    public var canUndo: Bool { buffer.canUndo }
    public var canRedo: Bool { buffer.canRedo }

    private func closeTypingGroup() {
        if typingGroupOpen { buffer.endUndoGroup(); typingGroupOpen = false }
    }

    /// Runs steps 4–8: reveal set, projection, layout update, caret rect.
    private func refresh(textChanged: Bool, started: DispatchTime) -> EditorChange {
        let reveal = marked?.reveal ?? policy.revealSet(caret: selection.head, index: parser.index, rope: buffer.rope)
        let result = projection.update(index: parser.index, rope: buffer.rope, reveal: reveal)
        let structure: Bool
        switch engine {
        case .lipi:
            structure = projection.entries.count != layout.entryCount
            layout.update(projection: projection, result: result)
        case .textkit2:
            structure = updateTextKit(result)
        }
        let rect = caretRect(forSource: selection.head)
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
        stats.lastPipelineSeconds = seconds
        let change = EditorChange(caretRect: rect, textChanged: textChanged, structureChanged: structure, seconds: seconds)
        onChange?(change)
        return change
    }

    private func updateTextKit(_ result: Projection.UpdateResult) -> Bool {
        guard let textKit else { return false }
        let ids = projection.entries.map(\.id)
        let changed = Set(result.changedEntries)
        var sameShape = ids.count == textKitEntryIDs.count
        if sameShape {
            for (i, id) in ids.enumerated() where id != textKitEntryIDs[i] && !changed.contains(i) { sameShape = false; break }
        }
        if sameShape {
            for i in result.changedEntries { textKit.replaceEntry(i, with: projection.entries[i], typesetter: typesetter) }
        } else {
            textKit.load(projection, typesetter: typesetter)
        }
        textKitEntryIDs = ids
        return !sameShape
    }

    // MARK: Selection and caret motion

    /// Moves the caret to `offset` (a source byte, snapped to a scalar
    /// boundary), extending the selection when `extend` is set.
    @discardableResult
    public func moveCaret(to offset: Int, extend: Bool = false, goalX: CGFloat? = nil) -> EditorChange {
        closeTypingGroup()
        let target = buffer.rope.floorScalarBoundary(max(0, min(offset, buffer.count)))
        if extend { selection.head = target } else { selection = SelectionModel(caret: target) }
        selection.goalX = goalX
        return refresh(textChanged: false, started: DispatchTime.now())
    }

    @discardableResult
    public func select(_ range: Range<Int>) -> EditorChange {
        closeTypingGroup()
        let r = clamp(range)
        selection = SelectionModel(anchor: r.lowerBound, head: r.upperBound)
        return refresh(textChanged: false, started: DispatchTime.now())
    }

    @discardableResult
    public func selectAll() -> EditorChange { select(0..<buffer.count) }

    public enum Motion {
        case left, right, up, down, wordLeft, wordRight, lineStart, lineEnd, documentStart, documentEnd
    }

    @discardableResult
    public func move(_ motion: Motion, extend: Bool = false) -> EditorChange {
        let caret = selection.head
        switch motion {
        case .left:
            if !extend, !selection.isEmpty { return moveCaret(to: selection.range.lowerBound) }
            return moveCaret(to: previousCaretStop(before: caret), extend: extend)
        case .right:
            if !extend, !selection.isEmpty { return moveCaret(to: selection.range.upperBound) }
            return moveCaret(to: nextCaretStop(after: caret), extend: extend)
        case .wordLeft: return moveCaret(to: wordBoundary(before: caret), extend: extend)
        case .wordRight: return moveCaret(to: wordBoundary(after: caret), extend: extend)
        case .documentStart: return moveCaret(to: 0, extend: extend)
        case .documentEnd: return moveCaret(to: buffer.count, extend: extend)
        case .lineStart, .lineEnd:
            let rect = caretRect(forSource: caret)
            let x: CGFloat = motion == .lineStart ? 0 : layout.textOrigin + layout.wideWidth + 4
            let target = sourceOffset(at: CGPoint(x: x, y: rect.midY)) ?? caret
            return moveCaret(to: target, extend: extend)
        case .up, .down:
            let rect = caretRect(forSource: caret)
            let goalX = selection.goalX ?? rect.minX
            let step = max(4, typesetter.scale.style(for: .body).lineHeight / 2)
            var probeY = motion == .up ? rect.minY - 1 : rect.maxY + 1
            var target: Int? = nil
            for _ in 0..<8 {
                guard probeY >= 0, probeY <= contentHeight else { break }
                if let o = sourceOffset(at: CGPoint(x: goalX, y: probeY)), o != caret {
                    let r = caretRect(forSource: o)
                    if motion == .up ? r.minY < rect.minY : r.minY > rect.minY { target = o; break }
                }
                probeY += motion == .up ? -step : step
            }
            guard let target else {
                return moveCaret(to: motion == .up ? 0 : buffer.count, extend: extend, goalX: goalX)
            }
            return moveCaret(to: target, extend: extend, goalX: goalX)
        }
    }

    /// Source offset one caret stop before `offset`: a grapheme cluster
    /// inside the display cell, or one scalar across hidden syntax and cell
    /// boundaries (ADR-002: `CFStringGetRangeOfComposedCharactersAtIndex`).
    public func previousCaretStop(before offset: Int) -> Int {
        guard offset > 0 else { return 0 }
        if let p = projection.position(forSource: offset), p.offset > 0 {
            let text = displayCell(at: p).text as NSString
            let d = CaretGeometry.previous(before: min(p.offset, text.length), in: text)
            let src = projection.sourceOffset(for: DisplayPosition(entry: p.entry, block: p.block, cell: p.cell, offset: d))
            if src < offset { return src }
        }
        return buffer.rope.floorScalarBoundary(offset - 1)
    }

    /// Source offset one caret stop after `offset`.
    public func nextCaretStop(after offset: Int) -> Int {
        let end = buffer.count
        guard offset < end else { return end }
        if let p = projection.position(forSource: offset) {
            let text = displayCell(at: p).text as NSString
            if p.offset < text.length {
                let d = CaretGeometry.next(after: p.offset, in: text)
                let src = projection.sourceOffset(for: DisplayPosition(entry: p.entry, block: p.block, cell: p.cell, offset: d))
                if src > offset { return min(src, end) }
            }
        }
        var o = offset + 1
        while o < end, !buffer.rope.isScalarBoundary(at: o) { o += 1 }
        return min(o, end)
    }

    /// Word boundaries on the source line (whitespace-delimited).
    public func wordBoundary(before offset: Int) -> Int {
        guard offset > 0 else { return 0 }
        let line = buffer.rope.lineRange(buffer.rope.line(at: max(0, offset - 1)))
        let start = line.lowerBound
        if offset <= start { return buffer.rope.floorScalarBoundary(offset - 1) }
        let bytes = Array(buffer.rope.string(in: start..<offset).utf8)
        var i = bytes.count
        while i > 0, isSpace(bytes[i - 1]) { i -= 1 }
        while i > 0, !isSpace(bytes[i - 1]) { i -= 1 }
        return start + i
    }

    public func wordBoundary(after offset: Int) -> Int {
        let end = buffer.count
        guard offset < end else { return end }
        let line = buffer.rope.lineRange(buffer.rope.line(at: offset))
        if offset >= line.upperBound - 1, offset < end, buffer.rope.byte(at: offset) == 0x0A { return offset + 1 }
        let bytes = Array(buffer.rope.string(in: offset..<line.upperBound).utf8)
        var i = 0
        while i < bytes.count, isSpace(bytes[i]) { i += 1 }
        while i < bytes.count, !isSpace(bytes[i]) { i += 1 }
        return offset + i
    }

    private func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }

    /// The word around `offset` (double-click selection).
    public func wordRange(at offset: Int) -> Range<Int> {
        let o = max(0, min(offset, buffer.count))
        var lo = o, hi = o
        if o < buffer.count, !isSpace(buffer.rope.byte(at: o)) { hi = wordBoundary(after: o) }
        if o > 0, !isSpace(buffer.rope.byte(at: o - 1)) { lo = wordBoundary(before: o) }
        return lo..<max(lo, hi)
    }

    // MARK: Marked text (IME)

    /// Replaces the marked text (or the selection) with `text` and marks it.
    /// `selected` is a UTF-16 range inside `text` for the caret.
    @discardableResult
    public func setMarkedText(_ text: String, selected: NSRange) -> EditorChange {
        closeTypingGroup()
        let started = DispatchTime.now()
        let target = clamp(marked?.range ?? selection.range)
        let reveal = marked?.reveal ?? policy.revealSet(caret: selection.head, index: parser.index, rope: buffer.rope)
        let start = target.lowerBound
        let end = start + text.utf8.count
        marked = text.isEmpty ? nil : MarkedText(range: start..<end, reveal: reveal)
        let utf16 = text.utf16
        let caretUTF16 = selected.location == NSNotFound ? utf16.count : min(selected.location + selected.length, utf16.count)
        let caret = start + String(utf16.prefix(caretUTF16))!.utf8.count
        _ = applyEdit(target, text, caretAfter: caret)
        if selected.location != NSNotFound, selected.length > 0, selected.location < utf16.count {
            let anchor = start + String(utf16.prefix(selected.location))!.utf8.count
            selection = SelectionModel(anchor: anchor, head: caret)
        }
        stats.keystrokes += 1
        return refresh(textChanged: true, started: started)
    }

    /// Commits the composition: the marked text stays as typed.
    @discardableResult
    public func unmarkText() -> EditorChange {
        guard marked != nil else { return refresh(textChanged: false, started: DispatchTime.now()) }
        marked = nil
        return refresh(textChanged: false, started: DispatchTime.now())
    }

    public var hasMarkedText: Bool { marked != nil }

    // MARK: Geometry

    public var contentHeight: CGFloat {
        switch engine {
        case .lipi: return layout.contentHeight
        case .textkit2: return (textKit?.usedHeight ?? 0) + layout.bottomPadding
        }
    }

    public var lineHeight: CGFloat { typesetter.scale.style(for: .body).lineHeight }

    /// Caret rect for a source offset, in document coordinates.
    public func caretRect(forSource offset: Int) -> CGRect {
        let fallback = CGRect(x: layout.textOrigin, y: 0, width: 0, height: lineHeight)
        switch engine {
        case .lipi:
            return layout.caretRect(forSource: offset) ?? fallback
        case .textkit2:
            guard let textKit, let position = projection.position(forSource: offset),
                  var rect = textKit.caretRect(forDocumentOffset: textKit.documentOffset(of: position)) else { return fallback }
            rect.origin.x += layout.textOrigin
            rect.size.width = 0
            return rect
        }
    }

    /// Source offset nearest a document point.
    public func sourceOffset(at point: CGPoint) -> Int? {
        switch engine {
        case .lipi:
            return layout.sourceOffset(at: point)
        case .textkit2:
            guard let textKit, let d = textKit.documentOffset(at: CGPoint(x: point.x - layout.textOrigin, y: point.y)),
                  let position = textKit.position(forDocumentOffset: d) else { return nil }
            return projection.sourceOffset(for: position)
        }
    }

    /// Lays out what `rect` (document coordinates) needs; returns the placed
    /// entries in `.lipi` mode.
    @discardableResult
    public func prepare(_ rect: CGRect) -> [PlacedEntry] {
        switch engine {
        case .lipi: return layout.layoutIfNeeded(in: rect.minY...rect.maxY)
        case .textkit2: textKit?.ensureLayout(toY: rect.maxY); return []
        }
    }

    /// Draws the document into a y-down context (§7.4 step 9).
    public func draw(in ctx: CGContext, dirty: CGRect) {
        switch engine {
        case .lipi:
            let placed = layout.layoutIfNeeded(in: dirty.minY...dirty.maxY)
            renderer.draw(placed, layout: layout, in: ctx, dirty: dirty)
        case .textkit2:
            guard let textKit else { return }
            ctx.saveGState()
            ctx.translateBy(x: layout.textOrigin, y: 0)
            textKit.draw(in: ctx, rect: dirty.offsetBy(dx: -layout.textOrigin, dy: 0))
            ctx.restoreGState()
        }
    }

    /// Rectangles covering a source range, limited to entries intersecting
    /// `visible` (document coordinates).
    public func rects(forSource range: Range<Int>, visible: CGRect) -> [CGRect] {
        guard !range.isEmpty else { return [] }
        switch engine {
        case .textkit2:
            guard let textKit, let a = projection.position(forSource: range.lowerBound),
                  let b = projection.position(forSource: range.upperBound) else { return [] }
            return textKit.selectionRects(forDocumentRange: textKit.documentOffset(of: a)..<textKit.documentOffset(of: b))
                .map { $0.offsetBy(dx: layout.textOrigin, dy: 0) }
        case .lipi:
            guard let a = projection.position(forSource: range.lowerBound),
                  let b = projection.position(forSource: range.upperBound) else { return [] }
            var rects: [CGRect] = []
            var p = a
            while p.entry < projection.entries.count, p <= b {
                let y = layout.y(ofEntry: p.entry)
                if y > visible.maxY { break }
                if y + layout.height(ofEntry: p.entry) < visible.minY {
                    p = DisplayPosition(entry: p.entry + 1, block: 0, cell: 0, offset: 0)
                    continue
                }
                let cell = layout.cell(at: p)
                let frame = layout.cellFrame(at: p)
                let sameStart = p.entry == a.entry && p.block == a.block && p.cell == a.cell
                let sameEnd = p.entry == b.entry && p.block == b.block && p.cell == b.cell
                let startOffset = sameStart ? a.offset : 0
                let endOffset = sameEnd ? b.offset : cell.length
                for line in cell.lines {
                    let lo = max(startOffset, line.range.lowerBound)
                    let hi = min(endOffset, line.range.upperBound)
                    guard lo < hi || (line.range.isEmpty && !sameEnd) else { continue }
                    let x0 = CaretGeometry.rect(for: lo, in: cell, upstream: false).minX
                    let x1 = hi >= line.range.upperBound && !sameEnd ? line.x + line.width : CaretGeometry.rect(for: hi, in: cell, upstream: true).minX
                    rects.append(CGRect(x: frame.minX + min(x0, x1), y: frame.minY + line.top, width: abs(x1 - x0), height: line.height))
                }
                if sameEnd { break }
                p = next(after: p)
            }
            return rects
        }
    }

    private func next(after p: DisplayPosition) -> DisplayPosition {
        let entry = projection.entries[p.entry]
        if p.cell + 1 < entry.blocks[p.block].cells.count { return DisplayPosition(entry: p.entry, block: p.block, cell: p.cell + 1, offset: 0) }
        if p.block + 1 < entry.blocks.count { return DisplayPosition(entry: p.entry, block: p.block + 1, cell: 0, offset: 0) }
        return DisplayPosition(entry: p.entry + 1, block: 0, cell: 0, offset: 0)
    }

    public func displayCell(at p: DisplayPosition) -> DisplayCell {
        projection.entries[p.entry].blocks[p.block].cells[p.cell]
    }

    // MARK: Unit conversion (NSTextInputClient and accessibility speak UTF-16)

    public func utf16Offset(fromByte b: Int) -> Int { buffer.rope.utf16Offset(fromByte: max(0, min(b, buffer.count))) }
    public func byteOffset(fromUTF16 u: Int) -> Int { buffer.rope.byteOffset(fromUTF16: max(0, min(u, buffer.rope.utf16Count))) }

    public func utf16Range(fromBytes range: Range<Int>) -> NSRange {
        let r = buffer.rope.utf16Range(fromBytes: clamp(range))
        return NSRange(location: r.lowerBound, length: r.count)
    }

    public func byteRange(fromUTF16 range: NSRange) -> Range<Int> {
        guard range.location != NSNotFound else { return selection.range }
        let lo = byteOffset(fromUTF16: range.location)
        let hi = byteOffset(fromUTF16: range.location + range.length)
        return lo..<max(lo, hi)
    }

    public var utf16Count: Int { buffer.rope.utf16Count }

    public func string(in range: Range<Int>) -> String { buffer.rope.string(in: clamp(range)) }

    private func clamp(_ range: Range<Int>) -> Range<Int> {
        let lo = buffer.rope.floorScalarBoundary(max(0, min(range.lowerBound, buffer.count)))
        let hi = buffer.rope.floorScalarBoundary(max(0, min(range.upperBound, buffer.count)))
        return lo..<max(lo, hi)
    }
}
