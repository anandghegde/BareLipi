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
    /// Hybrid (§6.1) or source (§6.2) presentation. Edits are identical in both.
    public private(set) var mode: EditorMode = .hybrid
    /// Settings the commands read (emphasis marker, hard break, auto-pair).
    public var settings = EditorSettings()
    /// Seconds on a monotonic clock; injectable so tests can drive undo coalescing.
    public var clock: () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
    /// Typing coalesces into one undo step until this pause (seconds).
    public var coalescingInterval: Double = 1

    private enum TypingKind { case insert, delete, ime }
    private var typingKind: TypingKind? = nil
    private var lastTypingTime: Double = 0
    private var lastTypedWasWhitespace = false
    private var lastTypingCaret = 0
    /// Offsets of closers inserted by auto-pair that typing may over-type.
    private var pairClosers: [(offset: Int, closer: String, opener: String)] = []
    private var pendingModeToggle = false
    private var pendingToggleAnchor: Int? = nil

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
    /// The parsed document: top-level blocks with local ranges (counts, outline).
    public var blockIndex: BlockIndex { parser.index }
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
        typingKind = nil
        pairClosers.removeAll()
        _ = refresh(textChanged: true, started: DispatchTime.now())
    }

    public func setViewportWidth(_ width: CGFloat) {
        layout.setViewportWidth(width)
        textKit?.setWidth(layout.measure)
    }

    public func setTheme(_ theme: Theme, zoom: CGFloat? = nil) {
        rebuildTypesetter(theme: theme, zoom: zoom ?? self.zoom)
        _ = refresh(textChanged: false, started: DispatchTime.now())
    }

    private func rebuildTypesetter(theme: Theme, zoom: CGFloat) {
        typesetter = Typesetter(scale: TypeScale(theme: theme, zoom: zoom, monospace: mode == .source), cascade: FontCascade(theme: theme))
        renderer = Renderer(typesetter: typesetter)
        layout.setTypesetter(typesetter)
        if let textKit {
            textKit.setWidth(layout.measure)
            textKit.load(projection, typesetter: typesetter)
            textKitEntryIDs = projection.entries.map(\.id)
        }
    }

    // MARK: Source mode (§6.2)

    /// Switches between hybrid and source mode. Caret, selection and undo
    /// history carry over; the line holding `anchor` (the view passes the
    /// top visible source offset; default the caret) keeps its screen
    /// position through `EditorChange.viewportShift`. During IME composition
    /// the toggle waits for the commit.
    @discardableResult
    public func toggleSourceMode(anchor: Int? = nil) -> EditorChange {
        if marked != nil {
            pendingModeToggle.toggle()
            pendingToggleAnchor = anchor
            return refresh(textChanged: false, started: DispatchTime.now())
        }
        return setMode(mode == .hybrid ? .source : .hybrid, anchor: anchor)
    }

    /// Sets the mode (see `toggleSourceMode`).
    @discardableResult
    public func setMode(_ newMode: EditorMode, anchor: Int? = nil) -> EditorChange {
        let started = DispatchTime.now()
        guard newMode != mode else { return refresh(textChanged: false, started: started) }
        if marked != nil {
            pendingModeToggle = true
            pendingToggleAnchor = anchor
            return refresh(textChanged: false, started: started)
        }
        let pin = max(0, min(anchor ?? selection.head, buffer.count))
        let before = caretRect(forSource: pin)
        mode = newMode
        projection.sourceMode = newMode == .source
        rebuildTypesetter(theme: theme, zoom: zoom)
        return refresh(textChanged: false, started: started, pinned: (pin, before))
    }

    /// Applies a toggle requested while composing, once the composition ends.
    private func applyPendingToggle(_ change: EditorChange) -> EditorChange {
        guard pendingModeToggle, marked == nil else { return change }
        pendingModeToggle = false
        let anchor = pendingToggleAnchor
        pendingToggleAnchor = nil
        return setMode(mode == .hybrid ? .source : .hybrid, anchor: anchor)
    }

    // MARK: The keystroke pipeline (§7.4)

    /// Replaces `range` (source bytes) with `text` and puts the caret after
    /// the replacement, or at `caretAfter`. Steps 1–8 of §7.4.
    @discardableResult
    public func replace(_ range: Range<Int>, with text: String, caretAfter: Int? = nil) -> EditorChange {
        let started = DispatchTime.now()
        let range = clamp(range)
        let ownGroup = !buffer.isUndoGroupOpen
        if ownGroup { buffer.beginUndoGroup(selection: undoSelection) }
        let delta = applyEdit(range, text, caretAfter: caretAfter)
        if var m = marked {
            m.range = delta.map(SourceOffset(m.range.lowerBound), preferEnd: false).byte..<delta.map(SourceOffset(m.range.upperBound)).byte
            marked = m.range.isEmpty ? nil : m
        }
        if ownGroup { buffer.endUndoGroup(selection: undoSelection) }
        remapPairClosers(delta)
        lastTypingCaret = selection.head
        stats.keystrokes += 1
        return refresh(textChanged: true, started: started)
    }

    /// Steps 1–3: buffer, parser, caret. Leaves `marked` to the caller.
    private func applyEdit(_ range: Range<Int>, _ text: String, caretAfter: Int?) -> Delta {
        blockSelectionRange = nil
        let delta = buffer.apply(Edit(replacing: range, with: text))
        parser.apply(delta, then: buffer.rope)
        selection = SelectionModel(caret: caretAfter ?? (range.lowerBound + text.utf8.count))
        return delta
    }

    /// Types `text` at the caret, replacing the selection (or committing the
    /// marked text). Single characters coalesce into one undo step (see
    /// `beginTyping`); auto-pair (§6.1.5) applies here.
    @discardableResult
    public func insert(_ text: String) -> EditorChange {
        if let m = marked {
            marked = nil
            let change = replace(m.range, with: text)
            closeTypingGroup()
            return applyPendingToggle(change)
        }
        // §6.1.5 Tables: a literal `|` typed in a cell is written `\|`.
        let text = text == "|" && mode == .hybrid && commands.escapesPipe ? "\\|" : text
        let single = text.utf8.count <= 4 && !text.contains("\n") && !text.contains("\r")
        guard single else {
            closeTypingGroup()
            return replace(selection.range, with: text)
        }
        let caret = selection.head
        if selection.isEmpty, let i = pairClosers.firstIndex(where: { $0.offset == caret && $0.closer == text }),
           string(in: caret..<(caret + text.utf8.count)) == text {
            // Over-type the closer auto-pair inserted.
            pairClosers.remove(at: i)
            beginTyping(.insert, text: text)
            selection = SelectionModel(caret: caret + text.utf8.count)
            lastTypingCaret = selection.head
            return refresh(textChanged: false, started: DispatchTime.now())
        }
        if selection.isEmpty, let closer = autoPairCloser(for: text, at: caret) {
            beginTyping(.insert, text: text)
            let change = replace(caret..<caret, with: text + closer, caretAfter: caret + text.utf8.count)
            pairClosers.append((caret + text.utf8.count, closer, text))
            return change
        }
        beginTyping(.insert, text: text)
        return replace(selection.range, with: text)
    }

    /// Enter: list, task and quote continuation, fence, math and rule
    /// openers (§6.1.5 smart typing), else a line terminator matching the
    /// document's. One undo step.
    @discardableResult
    public func insertNewline() -> EditorChange {
        if marked != nil { _ = unmarkText() }
        // Enter in a block selection re-enters the block (§6.1.4).
        if let r = blockSelection { return moveCaret(to: r.lowerBound) }
        closeTypingGroup()
        if let plan = commands.tableNewline() ?? commands.smartNewline() { return perform(plan) }
        let eol = CommandDocument(rope: buffer.rope, index: parser.index).eol(near: selection.range.lowerBound)
        return replace(selection.range, with: eol)
    }

    /// Deletes the selection, or the grapheme cluster before the caret (both
    /// halves of an empty auto-paired pair).
    @discardableResult
    public func deleteBackward() -> EditorChange {
        if let r = blockSelection { return perform(commands.deleteBlock(r)) }
        if !selection.isEmpty { closeTypingGroup(); return replace(selection.range, with: "") }
        let caret = selection.head
        guard caret > 0 else { return refresh(textChanged: false, started: DispatchTime.now()) }
        if let pair = pairClosers.first(where: { $0.offset == caret }), caret >= pair.opener.utf8.count,
           string(in: (caret - pair.opener.utf8.count)..<caret) == pair.opener,
           string(in: caret..<(caret + pair.closer.utf8.count)) == pair.closer {
            beginTyping(.delete, text: "")
            return replace((caret - pair.opener.utf8.count)..<(caret + pair.closer.utf8.count), with: "")
        }
        let start = previousCaretStop(before: caret)
        beginTyping(.delete, text: "")
        return replace(start..<caret, with: "")
    }

    /// Deletes the selection, or the grapheme cluster after the caret.
    @discardableResult
    public func deleteForward() -> EditorChange {
        if let r = blockSelection { return perform(commands.deleteBlock(r)) }
        if !selection.isEmpty { closeTypingGroup(); return replace(selection.range, with: "") }
        let caret = selection.head
        guard caret < buffer.count else { return refresh(textChanged: false, started: DispatchTime.now()) }
        let end = nextCaretStop(after: caret)
        beginTyping(.delete, text: "")
        return replace(caret..<end, with: "", caretAfter: caret)
    }

    /// Reverts the last undo step and restores the selection from before it.
    @discardableResult
    public func undo() -> EditorChange {
        closeTypingGroup()
        marked = nil
        pairClosers.removeAll()
        let started = DispatchTime.now()
        let step = buffer.undoStep()
        guard !step.deltas.isEmpty else { return refresh(textChanged: false, started: started) }
        for delta in step.deltas { parser.apply(delta) }
        parser.reparse(buffer.rope)
        selection = restored(step.selection) ?? SelectionModel(caret: step.deltas.last!.newRange.upperBound.byte)
        lastTypingCaret = selection.head
        return refresh(textChanged: true, started: started)
    }

    /// Replays the last undone step and restores the selection after it.
    @discardableResult
    public func redo() -> EditorChange {
        closeTypingGroup()
        marked = nil
        pairClosers.removeAll()
        let started = DispatchTime.now()
        let step = buffer.redoStep()
        guard !step.deltas.isEmpty else { return refresh(textChanged: false, started: started) }
        for delta in step.deltas { parser.apply(delta) }
        parser.reparse(buffer.rope)
        selection = restored(step.selection) ?? SelectionModel(caret: step.deltas.last!.newRange.upperBound.byte)
        lastTypingCaret = selection.head
        return refresh(textChanged: true, started: started)
    }

    private func restored(_ s: SourceBuffer.UndoSelection?) -> SelectionModel? {
        guard let s else { return nil }
        let clampOffset = { (o: Int) in self.buffer.rope.floorScalarBoundary(max(0, min(o, self.buffer.count))) }
        return SelectionModel(anchor: clampOffset(s.anchor), head: clampOffset(s.head))
    }

    private var undoSelection: SourceBuffer.UndoSelection {
        SourceBuffer.UndoSelection(anchor: selection.anchor, head: selection.head)
    }

    public var canUndo: Bool { buffer.canUndo }
    public var canRedo: Bool { buffer.canRedo }

    /// Ends the open typing group (a caret jump, a command, undo).
    private func closeTypingGroup() {
        guard typingKind != nil else { return }
        typingKind = nil
        buffer.endUndoGroup(selection: undoSelection)
    }

    /// Opens or continues a typing group. A new step starts after a pause of
    /// `coalescingInterval`, when whitespace follows a word, when the kind of
    /// typing changes, or when the caret moved since the last keystroke.
    private func beginTyping(_ kind: TypingKind, text: String) {
        let now = clock()
        let isWhitespace = !text.isEmpty && text.allSatisfy(\.isWhitespace)
        if let current = typingKind {
            if current != kind || now - lastTypingTime > coalescingInterval || selection.head != lastTypingCaret
                || (kind == .insert && isWhitespace && !lastTypedWasWhitespace) {
                closeTypingGroup()
            }
        }
        if typingKind == nil {
            if buffer.isUndoGroupOpen { buffer.endUndoGroup(selection: undoSelection) }
            buffer.beginUndoGroup(selection: undoSelection)
            typingKind = kind
        }
        lastTypingTime = now
        lastTypedWasWhitespace = isWhitespace
    }

    // MARK: Commands (§6.1.5)

    private var commands: MarkdownCommands {
        MarkdownCommands(rope: buffer.rope, index: parser.index, selection: selection, settings: settings)
    }

    /// Applies a command's edits as one undo step that restores the
    /// selection from before it, then sets the selection the plan names.
    @discardableResult
    public func perform(_ plan: EditPlan) -> EditorChange {
        let started = DispatchTime.now()
        if marked != nil { marked = nil }
        closeTypingGroup()
        pairClosers.removeAll()
        blockSelectionRange = nil
        let clampOffset = { (o: Int) in self.buffer.rope.floorScalarBoundary(max(0, min(o, self.buffer.count))) }
        guard !plan.edits.isEmpty else {
            // A pure selection change (table cell navigation, block selection).
            selection = SelectionModel(anchor: clampOffset(plan.anchor), head: clampOffset(plan.head))
            lastTypingCaret = selection.head
            return refresh(textChanged: false, started: started)
        }
        buffer.beginUndoGroup(selection: undoSelection)
        let ordered = plan.edits.sorted {
            $0.range.lowerBound.byte != $1.range.lowerBound.byte ? $0.range.lowerBound.byte > $1.range.lowerBound.byte
                : $0.range.upperBound.byte > $1.range.upperBound.byte
        }
        for edit in ordered { parser.apply(buffer.apply(edit)) }
        parser.reparse(buffer.rope)
        selection = SelectionModel(anchor: clampOffset(plan.anchor), head: clampOffset(plan.head))
        buffer.endUndoGroup(selection: undoSelection)
        lastTypingCaret = selection.head
        stats.keystrokes += 1
        return refresh(textChanged: true, started: started)
    }

    private func run(_ plan: EditPlan?) -> EditorChange {
        guard let plan else {
            closeTypingGroup()
            return refresh(textChanged: false, started: DispatchTime.now())
        }
        return perform(plan)
    }

    /// Cmd-B: wrap the selection or word in `**`, or unwrap strong text.
    @discardableResult public func toggleStrong() -> EditorChange { run(commands.toggleInline(.strong)) }
    /// Cmd-I: emphasis with `settings.emphasisMarker`.
    @discardableResult public func toggleEmphasis() -> EditorChange { run(commands.toggleInline(.emphasis)) }
    /// Cmd-Shift-X: `~~` strikethrough.
    @discardableResult public func toggleStrikethrough() -> EditorChange { run(commands.toggleInline(.strikethrough)) }
    /// Cmd-E: code span with the shortest backtick run absent from the text.
    @discardableResult public func toggleCodeSpan() -> EditorChange { run(commands.toggleInline(.code)) }

    /// Cmd-K: `[label](destination "title")` over the selection (label
    /// defaults to the selected text). An empty destination leaves the caret
    /// between the parentheses.
    @discardableResult
    public func insertLink(label: String? = nil, destination: String = "", title: String? = nil) -> EditorChange {
        run(commands.link(label: label, destination: destination, title: title))
    }

    /// What the Cmd-K popover starts from: the link under the selection
    /// (label, destination, title), or the selected text as the label and
    /// `pasteboard` as the destination when it is a URL.
    public func linkDraft(pasteboard: String? = nil) -> LinkDraft {
        commands.linkDraft(pasteboard: pasteboard)
    }

    /// Writes the popover's link over `draft.range` (one undo step).
    @discardableResult
    public func commitLink(_ draft: LinkDraft) -> EditorChange {
        if marked != nil { _ = unmarkText() }
        return perform(commands.commitLink(draft))
    }

    /// Cmd-Ctrl-I: `![alt](path)` over the selection.
    @discardableResult
    public func insertImage(alt: String? = nil, path: String) -> EditorChange {
        run(commands.image(alt: alt, path: path))
    }

    /// Cmd-1…6 sets the heading level of every selected block; Cmd-0
    /// (level 0) makes them paragraphs, removing heading and list markers.
    @discardableResult public func setHeading(level: Int) -> EditorChange { run(commands.setHeading(max(0, min(level, 6)))) }
    /// Cmd-0.
    @discardableResult public func makeParagraph() -> EditorChange { setHeading(level: 0) }
    /// Cmd-Ctrl-=: one heading level up (towards H1), clamped.
    @discardableResult public func promoteHeading() -> EditorChange { run(commands.shiftHeading(by: -1)) }
    /// Cmd-Ctrl--: one heading level down (towards H6), clamped.
    @discardableResult public func demoteHeading() -> EditorChange { run(commands.shiftHeading(by: 1)) }
    /// Cmd-Opt-U.
    @discardableResult public func toggleBulletList() -> EditorChange { run(commands.toggleList(.bullet)) }
    /// Cmd-Opt-O.
    @discardableResult public func toggleOrderedList() -> EditorChange { run(commands.toggleList(.ordered)) }
    /// Cmd-Opt-X.
    @discardableResult public func toggleTaskList() -> EditorChange { run(commands.toggleList(.task)) }
    /// Cmd-Shift-Enter: check or uncheck the selected task items.
    @discardableResult public func toggleTaskDone() -> EditorChange { run(commands.toggleTaskDone()) }
    /// Cmd-]: indent the selected list items (with their children).
    @discardableResult public func indentListItem() -> EditorChange { run(commands.indentItems(1)) }
    /// Cmd-[: outdent the selected list items.
    @discardableResult public func outdentListItem() -> EditorChange { run(commands.indentItems(-1)) }
    /// Cmd-Opt-Q.
    @discardableResult public func toggleBlockQuote() -> EditorChange { run(commands.toggleQuote()) }
    /// Cmd-Opt-C.
    @discardableResult public func insertCodeFence() -> EditorChange { run(commands.codeFence()) }
    /// Cmd-Opt-B.
    @discardableResult public func insertMathBlock() -> EditorChange { run(commands.mathBlock()) }
    /// Cmd-Opt--.
    @discardableResult public func insertThematicBreak() -> EditorChange { run(commands.thematicBreak()) }
    /// Cmd-Enter: leave the fence, table, quote or math block around the caret.
    @discardableResult public func exitBlock() -> EditorChange { run(commands.exitBlock()) }
    /// Shift-Enter: hard line break per `settings.hardBreak`.
    @discardableResult public func insertHardBreak() -> EditorChange {
        if marked != nil { _ = unmarkText() }
        return run(commands.hardBreak())
    }

    /// Tab: the next table cell (a new row after the last one), indents a
    /// list item when the caret is at its content start, otherwise types a tab.
    @discardableResult
    public func insertTab() -> EditorChange {
        if marked == nil, let plan = commands.tableTab(backward: false) { return perform(plan) }
        if selection.isEmpty, !isAtItemStart { return insert("\t") }
        return indentListItem()
    }

    /// Shift-Tab: the previous table cell, or outdents a list item when the
    /// caret is at its content start.
    @discardableResult
    public func insertBacktab() -> EditorChange {
        if marked == nil, let plan = commands.tableTab(backward: true) { return perform(plan) }
        if selection.isEmpty, !isAtItemStart { return refresh(textChanged: false, started: DispatchTime.now()) }
        return outdentListItem()
    }

    /// Opt-Enter: `<br>` inside a table cell, otherwise Enter.
    @discardableResult
    public func insertCellLineBreak() -> EditorChange {
        if marked != nil { _ = unmarkText() }
        if let plan = commands.tableLineBreak() { return perform(plan) }
        return insertNewline()
    }

    private var isAtItemStart: Bool {
        let line = CommandDocument(rope: buffer.rope, index: parser.index).prefix(ofLineAt: selection.head)
        return line.hasMarker && selection.head >= line.markerEnd && selection.head <= line.contentStart
    }

    // MARK: Block selection (§6.1.4)

    private var blockSelectionRange: Range<Int>?

    /// The selected block's source while the selection is a block
    /// selection (`Esc`); nil once the selection or the text changes.
    public var blockSelection: Range<Int>? {
        guard let r = blockSelectionRange, selection.anchor == r.lowerBound, selection.head == r.upperBound else { return nil }
        return r
    }

    /// Esc: selects the block around the selection as one unit; again, the
    /// block around that. No-op outside blocks.
    @discardableResult
    public func selectEnclosingBlock() -> EditorChange {
        if marked != nil { _ = unmarkText() }
        guard let r = commands.expandBlockSelection(from: blockSelection) else {
            closeTypingGroup()
            return refresh(textChanged: false, started: DispatchTime.now())
        }
        blockSelectionRange = r
        return select(r)
    }

    /// Cmd-Shift-D: duplicates the selected block (or the block around the
    /// caret) and selects the copy.
    @discardableResult
    public func duplicateBlock() -> EditorChange {
        if marked != nil { _ = unmarkText() }
        guard let r = blockSelection ?? commands.expandBlockSelection(from: nil),
              let plan = commands.duplicateBlock(r) else { return run(nil) }
        let change = perform(plan)
        blockSelectionRange = selection.range
        return change
    }

    /// Opt-Up / Opt-Down in a block selection: moves the block past its
    /// previous or next sibling. Returns false outside a block selection.
    @discardableResult
    public func moveBlock(up: Bool) -> Bool {
        guard let r = blockSelection else { return false }
        if let plan = commands.moveBlock(r, up: up) {
            perform(plan)
            blockSelectionRange = selection.range
        }
        return true
    }

    // MARK: Auto-pair

    private static let pairs: [String: String] = ["*": "*", "_": "_", "`": "`", "[": "]", "(": ")", "$": "$", "\"": "\"", "\u{201C}": "\u{201D}"]

    /// The closer to insert after `text` typed at `caret`, or nil.
    private func autoPairCloser(for text: String, at caret: Int) -> String? {
        guard settings.autoPair, let closer = Self.pairs[text] else { return nil }
        let rope = buffer.rope
        if caret < rope.count {
            let next = rope.byte(at: caret)
            guard next == 0x20 || next == 0x09 || next == 0x0A || next == 0x0D else { return nil }
        }
        let previous: UInt8? = caret > 0 ? rope.byte(at: caret - 1) : nil
        if text == closer, let p = previous {
            // Symmetric delimiters do not pair after a word character.
            if p >= 0x80 || (p >= 0x30 && p <= 0x39) || (p | 0x20 >= 0x61 && p | 0x20 <= 0x7A) { return nil }
        }
        if text == "`", previous == 0x60 { return nil }
        if text == "*" || text == "_" {
            // At the start of a line's content these start list markers and rules.
            let doc = CommandDocument(rope: rope, index: parser.index)
            let lineStart = doc.lineStart(caret)
            if doc.bytes(lineStart..<caret).allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x3E }) { return nil }
        }
        if CommandDocument(rope: rope, index: parser.index).isCodeContext(caret) { return nil }
        return closer
    }

    private func remapPairClosers(_ delta: Delta) {
        guard !pairClosers.isEmpty else { return }
        let old = delta.oldRange.lowerBound.byte..<delta.oldRange.upperBound.byte
        pairClosers = pairClosers.compactMap { entry in
            if entry.offset > old.lowerBound, entry.offset < old.upperBound { return nil }
            if entry.offset < old.lowerBound { return entry }
            if entry.offset == old.lowerBound, !old.isEmpty { return nil }
            return (entry.offset + delta.newRange.length - old.count, entry.closer, entry.opener)
        }
    }

    /// Runs steps 4–8: reveal set, projection, layout update, caret rect.
    private func refresh(textChanged: Bool, started: DispatchTime, pinned: (offset: Int, rect: CGRect)? = nil) -> EditorChange {
        let reveal: RevealSet
        if mode == .source {
            reveal = .everything
        } else if let m = marked {
            reveal = m.reveal
        } else {
            reveal = boundaryAdjusted(policy.revealSet(caret: selection.head, index: parser.index, rope: buffer.rope), caret: selection.head)
        }
        // Where the caret would land under the current (pre-reveal) layout.
        let expected = pinned.map(\.rect) ?? (textChanged ? nil : caretRect(forSource: selection.head))
        let result = projection.update(index: parser.index, rope: buffer.rope, reveal: reveal)
        let structure: Bool
        switch engine {
        case .lipi:
            structure = projection.entries.count != layout.entryCount
            // Columns of the table being typed in never shrink (§6.1.4).
            if let p = projection.position(forSource: selection.head), projection.entries[p.entry].blocks[p.block].table != nil {
                layout.growOnlyEntry = p.entry
            } else {
                layout.growOnlyEntry = nil
            }
            layout.update(projection: projection, result: result)
        case .textkit2:
            structure = updateTextKit(result)
        }
        let rect = caretRect(forSource: selection.head)
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
        stats.lastPipelineSeconds = seconds
        var change = EditorChange(caretRect: rect, textChanged: textChanged, structureChanged: structure, seconds: seconds)
        if let pinned {
            change.viewportShift = caretRect(forSource: pinned.offset).minY - pinned.rect.minY
        } else if let expected, !result.changedEntries.isEmpty {
            change.viewportShift = rect.minY - expected.minY
        }
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
        pairClosers.removeAll()
        let target = buffer.rope.floorScalarBoundary(max(0, min(offset, buffer.count)))
        if extend { selection.head = target } else { selection = SelectionModel(caret: target) }
        selection.goalX = goalX
        return refresh(textChanged: false, started: DispatchTime.now())
    }

    @discardableResult
    public func select(_ range: Range<Int>) -> EditorChange {
        closeTypingGroup()
        pairClosers.removeAll()
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
            if !extend, mode == .hybrid, let inside = boundaryStop(leftFrom: caret) { return moveCaret(to: inside) }
            return moveCaret(to: previousCaretStop(before: caret), extend: extend)
        case .right:
            if !extend, !selection.isEmpty { return moveCaret(to: selection.range.upperBound) }
            if !extend, mode == .hybrid, let after = boundaryStop(rightFrom: caret) { return moveCaret(to: after) }
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
        if marked == nil { closeTypingGroup() }
        if typingKind != .ime {
            closeTypingGroup()
            if buffer.isUndoGroupOpen { buffer.endUndoGroup(selection: undoSelection) }
            buffer.beginUndoGroup(selection: undoSelection)
            typingKind = .ime
        }
        pairClosers.removeAll()
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
        lastTypingCaret = selection.head
        if marked == nil { closeTypingGroup() }
        let change = refresh(textChanged: true, started: started)
        return marked == nil ? applyPendingToggle(change) : change
    }

    /// Commits the composition: the marked text stays as typed.
    @discardableResult
    public func unmarkText() -> EditorChange {
        guard marked != nil else { return refresh(textChanged: false, started: DispatchTime.now()) }
        marked = nil
        closeTypingGroup()
        return applyPendingToggle(refresh(textChanged: false, started: DispatchTime.now()))
    }

    // MARK: Caret boundary rule (§6.1.4)

    /// Delimited inline spans containing `p` (inclusive), with the offset
    /// where each one's closing delimiter starts.
    private func delimitedSpans(at p: Int) -> [(inline: Inline, closeStart: Int)] {
        let doc = CommandDocument(rope: buffer.rope, index: parser.index)
        guard let leaf = doc.path(at: p).last else { return [] }
        var out: [(Inline, Int)] = []
        func visit(_ list: [Inline]) {
            for inline in list where inline.range.lowerBound < p && p <= inline.range.upperBound {
                if let close = closeStart(of: inline) { out.append((inline, close)) }
                visit(inline.children)
            }
        }
        visit(leaf.inlines)
        return out
    }

    private func closeStart(of inline: Inline) -> Int? {
        let r = inline.range
        switch inline.kind {
        case .emphasis, .strong, .strikethrough:
            return inline.children.last?.range.upperBound
        case .code, .math:
            let delimiter: UInt8 = { if case .code = inline.kind { return 0x60 } else { return 0x24 } }()
            var e = r.upperBound
            while e > r.lowerBound, buffer.rope.byte(at: e - 1) == delimiter { e -= 1 }
            return e > r.lowerBound && e < r.upperBound ? e : nil
        case .link(_, _, let isAutolink):
            guard !isAutolink else { return nil }
            return inline.children.last?.range.upperBound ?? r.lowerBound + 1
        case .image:
            return inline.children.last?.range.upperBound ?? r.lowerBound + 2
        default:
            return nil
        }
    }

    /// A caret right after a span's closing delimiter leaves it folded.
    private func boundaryAdjusted(_ reveal: RevealSet, caret: Int) -> RevealSet {
        guard !reveal.inlines.isEmpty else { return reveal }
        var reveal = reveal
        for span in delimitedSpans(at: caret) where span.inline.range.upperBound == caret {
            reveal.inlines.remove(span.inline.id)
            reveal.expandedLinks.remove(span.inline.id)
        }
        return reveal
    }

    /// Right-arrow from just before a closing delimiter: after the delimiter
    /// (of every span closing there).
    private func boundaryStop(rightFrom caret: Int) -> Int? {
        var target = caret
        while let span = delimitedSpans(at: target).last(where: { $0.closeStart == target && $0.inline.range.upperBound > target }) {
            target = span.inline.range.upperBound
        }
        return target == caret ? nil : target
    }

    /// Left-arrow from just after a span: before its closing delimiter.
    private func boundaryStop(leftFrom caret: Int) -> Int? {
        var target = caret
        while let span = delimitedSpans(at: target).first(where: { $0.inline.range.upperBound == target && $0.closeStart < target }) {
            target = span.closeStart
        }
        return target == caret ? nil : target
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

    /// The display block holding a source offset, if any.
    public func displayBlock(atSource offset: Int) -> DisplayBlock? {
        guard let p = projection.position(forSource: offset) else { return nil }
        return projection.entries[p.entry].blocks[p.block]
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
