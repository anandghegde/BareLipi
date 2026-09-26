import AppKit
import LipiCore
import LipiLayout
import os

/// The editor surface (ADR-002): one flipped, layer-backed `NSView` that is
/// the document view of an `NSScrollView`, draws the visible blocks with
/// `Renderer`, and speaks `NSTextInputClient` and the accessibility text
/// protocol in source UTF-16 units.
public final class EditorView: NSView, @preconcurrency NSTextInputClient {
    public let controller: EditorController
    private let caret = CaretController()
    /// Seconds from each edit to the end of the draw that showed it, wall
    /// clock: includes the wait for the next display cycle.
    public private(set) var keystrokeToDraw: [Double] = []
    /// Main-thread work per edit: the pipeline plus the draw that showed it.
    public private(set) var keystrokeWork: [Double] = []
    /// Called once, after the first draw.
    public var onFirstDraw: (() -> Void)?
    private var hasDrawn = false
    private var pendingKeystroke: (start: DispatchTime, pipeline: Double, signpost: OSSignpostIntervalState)?
    private var mouseAnchor: Int?
    /// Draw the caret even when the view is not first responder (tests, bench).
    public var alwaysShowsCaret = false
    /// Find and Replace state; its matches are highlighted while active.
    public var findSession: FindSession?
    /// Stores pasted and dropped images and picks the paths links use
    /// (the document's `AssetStore`). Without one, images are not accepted.
    public weak var imageHandler: EditorImageHandler?

    public init(controller: EditorController, frame: NSRect = NSRect(x: 0, y: 0, width: 800, height: 600)) {
        self.controller = controller
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        autoresizingMask = [.width]
        controller.setViewportWidth(frame.width)
        controller.onChange = { [weak self] change in self?.didChange(change) }
        caret.onToggle = { [weak self] in self?.invalidateCaret() }
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        registerForDraggedTypes(EditorView.imageDragTypes)
        syncFrameHeight()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override var isOpaque: Bool { true }

    // MARK: Pipeline hooks

    private func didChange(_ change: EditorChange) {
        if change.textChanged, pendingKeystroke == nil {
            pendingKeystroke = (DispatchTime.now(), change.seconds, Signposts.editor.beginInterval("key.toDraw"))
        }
        caret.restart()
        syncFrameHeight()
        needsDisplay = true
        if change.viewportShift != 0, let clip = enclosingScrollView?.contentView {
            var origin = clip.bounds.origin
            origin.y += change.viewportShift
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
        scrollCaretToVisible(change.caretRect)
    }

    private func scrollCaretToVisible(_ rect: CGRect) {
        guard enclosingScrollView != nil else { return }
        let padded = rect.insetBy(dx: -8, dy: -controller.lineHeight)
        scrollToVisible(padded.intersection(bounds).isNull ? rect : padded)
    }

    private func invalidateCaret() {
        setNeedsDisplay(controller.caretRect(forSource: controller.caret).insetBy(dx: -2, dy: -1))
    }

    private func syncFrameHeight() {
        let minimum = enclosingScrollView?.contentSize.height ?? 0
        let height = max(controller.contentHeight + controller.lineHeight * 2, minimum).rounded(.up)
        if abs(frame.height - height) >= 0.5 { setFrameSize(NSSize(width: frame.width, height: height)) }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) >= 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            controller.setViewportWidth(newSize.width)
            needsDisplay = true
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { caret.stop() } else if window?.firstResponder === self { caret.restart() }
    }

    public override func becomeFirstResponder() -> Bool {
        caret.restart()
        needsDisplay = true
        return true
    }

    public override func resignFirstResponder() -> Bool {
        caret.stop()
        inputContext?.discardMarkedText()
        needsDisplay = true
        return true
    }

    // MARK: Layout ahead of scrolling (one screen of overscan, §7.4)

    public override func prepareContent(in rect: NSRect) {
        let anchorEntry = controller.engine == .lipi ? controller.layout.entryIndex(atY: visibleRect.minY) : nil
        let anchorY = anchorEntry.map { controller.layout.y(ofEntry: $0) }
        controller.prepare(rect)
        syncFrameHeight()
        // Entries measured above the viewport shift it; keep the first
        // visible entry where it was (caret-anchored reflow).
        if let anchorEntry, let anchorY, let clip = enclosingScrollView?.contentView {
            let delta = controller.layout.y(ofEntry: anchorEntry) - anchorY
            if abs(delta) >= 0.5 {
                var origin = clip.bounds.origin
                origin.y += delta
                clip.scroll(to: origin)
                enclosingScrollView?.reflectScrolledClipView(clip)
            }
        }
        super.prepareContent(in: rect)
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let drawStarted = DispatchTime.now()
        render(in: ctx, dirty: dirtyRect)
        if let pending = pendingKeystroke {
            pendingKeystroke = nil
            let now = DispatchTime.now()
            keystrokeToDraw.append(Double(now.uptimeNanoseconds - pending.start.uptimeNanoseconds) / 1e9)
            keystrokeWork.append(pending.pipeline + Double(now.uptimeNanoseconds - drawStarted.uptimeNanoseconds) / 1e9)
            Signposts.editor.endInterval("key.toDraw", pending.signpost)
        }
        if !hasDrawn {
            hasDrawn = true
            onFirstDraw?()
        }
    }

    /// Draws background, selection, text, marked-text underline and caret
    /// into a y-down context (also used headless by the tests and harness).
    public func render(in ctx: CGContext, dirty: CGRect) {
        let colors = controller.theme.colors
        ctx.setFillColor(colors.bg.cgColor)
        ctx.fill(dirty)
        drawFindHighlights(in: ctx, dirty: dirty)
        let selection = controller.selection
        if !selection.isEmpty {
            ctx.setFillColor(colors.selection.cgColor)
            for rect in controller.rects(forSource: selection.range, visible: dirty) where rect.intersects(dirty) {
                ctx.fill(rect)
            }
        }
        controller.draw(in: ctx, dirty: dirty)
        if let marked = controller.marked {
            ctx.setFillColor(colors.ink.cgColor)
            for rect in controller.rects(forSource: marked.range, visible: dirty) {
                ctx.fill(CGRect(x: rect.minX, y: rect.maxY - 2, width: max(rect.width, 2), height: 1.5))
            }
        }
        let focused = alwaysShowsCaret || window?.firstResponder === self
        if focused, caret.visible, selection.isEmpty || controller.hasMarkedText {
            var rect = controller.caretRect(forSource: controller.caret)
            rect.origin.x = (rect.origin.x - 1).rounded()
            rect.size.width = 2
            if rect.intersects(dirty) {
                ctx.setFillColor(colors.caret.cgColor)
                ctx.fill(rect)
            }
        }
    }

    public var caretBlinks: Bool {
        get { caret.blinks }
        set { caret.blinks = newValue; if !newValue { caret.stop() } }
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if !controller.hasMarkedText, mods == .shift, event.keyCode == 36 || event.keyCode == 76 {
            controller.insertHardBreak()
            return
        }
        if mods.contains(.command), performEditorKeyEquivalent(event) { return }
        if inputContext?.handleEvent(event) == true { return }
        interpretKeyEvents([event])
    }

    /// Handles the §6.1.5 command keys (and Cmd-/) itself, so they work
    /// without a menu. A menu item with the same key equivalent wins when the
    /// app has one (AppKit offers the event to the main menu first).
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        return performEditorKeyEquivalent(event) || super.performKeyEquivalent(with: event)
    }

    private func performEditorKeyEquivalent(_ event: NSEvent) -> Bool {
        guard let binding = Self.binding(for: event) else { return false }
        NSApp.sendAction(binding.action, to: self, from: self)
        return true
    }

    /// The binding a key event triggers, if any.
    public static func binding(for event: NSEvent) -> EditorKeyEquivalent? {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods.contains(.command) else { return nil }
        var key = (event.charactersIgnoringModifiers ?? "").lowercased()
        if event.keyCode == 36 || event.keyCode == 76 { key = "\r" }
        // Option can change the character on some layouts; fall back to the US key for the keyCode.
        if mods.contains(.option), let us = usKeys[event.keyCode] { key = us }
        return keyEquivalents.first { $0.key == key && $0.modifiers == mods }
    }

    private static let usKeys: [UInt16: String] = [
        32: "u", 31: "o", 7: "x", 12: "q", 8: "c", 11: "b", 27: "-", 24: "=", 34: "i",
    ]

    /// Every editor command with its key equivalent (§6.1.5, §6.2), for the
    /// app's Format menu. `action` is an `@objc` method on `EditorView`.
    public static let keyEquivalents: [EditorKeyEquivalent] = [
        .init("Source Mode", "/", [.command], #selector(toggleSourceMode(_:))),
        .init("Bold", "b", [.command], #selector(toggleStrong(_:))),
        .init("Italic", "i", [.command], #selector(toggleEmphasis(_:))),
        .init("Strikethrough", "x", [.command, .shift], #selector(toggleStrikethrough(_:))),
        .init("Code", "e", [.command], #selector(toggleCodeSpan(_:))),
        .init("Link", "k", [.command], #selector(insertLink(_:))),
        .init("Image", "i", [.command, .control], #selector(insertImage(_:))),
        .init("Heading 1", "1", [.command], #selector(setHeading1(_:))),
        .init("Heading 2", "2", [.command], #selector(setHeading2(_:))),
        .init("Heading 3", "3", [.command], #selector(setHeading3(_:))),
        .init("Heading 4", "4", [.command], #selector(setHeading4(_:))),
        .init("Heading 5", "5", [.command], #selector(setHeading5(_:))),
        .init("Heading 6", "6", [.command], #selector(setHeading6(_:))),
        .init("Paragraph", "0", [.command], #selector(makeParagraph(_:))),
        .init("Promote Heading", "=", [.command, .control], #selector(promoteHeading(_:))),
        .init("Demote Heading", "-", [.command, .control], #selector(demoteHeading(_:))),
        .init("Bulleted List", "u", [.command, .option], #selector(toggleBulletList(_:))),
        .init("Numbered List", "o", [.command, .option], #selector(toggleOrderedList(_:))),
        .init("Task List", "x", [.command, .option], #selector(toggleTaskList(_:))),
        .init("Toggle Task Done", "\r", [.command, .shift], #selector(toggleTaskDone(_:))),
        .init("Indent", "]", [.command], #selector(indentListItem(_:))),
        .init("Outdent", "[", [.command], #selector(outdentListItem(_:))),
        .init("Quote", "q", [.command, .option], #selector(toggleBlockQuote(_:))),
        .init("Code Block", "c", [.command, .option], #selector(insertCodeFence(_:))),
        .init("Math Block", "b", [.command, .option], #selector(insertMathBlock(_:))),
        .init("Horizontal Rule", "-", [.command, .option], #selector(insertThematicBreak(_:))),
        .init("Exit Block", "\r", [.command], #selector(exitBlock(_:))),
    ]

    public override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.moveLeft(_:)): controller.move(.left)
        case #selector(NSResponder.moveRight(_:)): controller.move(.right)
        case #selector(NSResponder.moveUp(_:)): controller.move(.up)
        case #selector(NSResponder.moveDown(_:)): controller.move(.down)
        case #selector(NSResponder.moveBackward(_:)): controller.move(.left)
        case #selector(NSResponder.moveForward(_:)): controller.move(.right)
        case #selector(NSResponder.moveLeftAndModifySelection(_:)): controller.move(.left, extend: true)
        case #selector(NSResponder.moveRightAndModifySelection(_:)): controller.move(.right, extend: true)
        case #selector(NSResponder.moveUpAndModifySelection(_:)): controller.move(.up, extend: true)
        case #selector(NSResponder.moveDownAndModifySelection(_:)): controller.move(.down, extend: true)
        case #selector(NSResponder.moveWordLeft(_:)), #selector(NSResponder.moveWordBackward(_:)): controller.move(.wordLeft)
        case #selector(NSResponder.moveWordRight(_:)), #selector(NSResponder.moveWordForward(_:)): controller.move(.wordRight)
        case #selector(NSResponder.moveWordLeftAndModifySelection(_:)): controller.move(.wordLeft, extend: true)
        case #selector(NSResponder.moveWordRightAndModifySelection(_:)): controller.move(.wordRight, extend: true)
        case #selector(NSResponder.moveToBeginningOfLine(_:)), #selector(NSResponder.moveToLeftEndOfLine(_:)): controller.move(.lineStart)
        case #selector(NSResponder.moveToEndOfLine(_:)), #selector(NSResponder.moveToRightEndOfLine(_:)): controller.move(.lineEnd)
        case #selector(NSResponder.moveToBeginningOfLineAndModifySelection(_:)), #selector(NSResponder.moveToLeftEndOfLineAndModifySelection(_:)):
            controller.move(.lineStart, extend: true)
        case #selector(NSResponder.moveToEndOfLineAndModifySelection(_:)), #selector(NSResponder.moveToRightEndOfLineAndModifySelection(_:)):
            controller.move(.lineEnd, extend: true)
        case #selector(NSResponder.moveToBeginningOfDocument(_:)): controller.move(.documentStart)
        case #selector(NSResponder.moveToEndOfDocument(_:)): controller.move(.documentEnd)
        case #selector(NSResponder.moveToBeginningOfDocumentAndModifySelection(_:)): controller.move(.documentStart, extend: true)
        case #selector(NSResponder.moveToEndOfDocumentAndModifySelection(_:)): controller.move(.documentEnd, extend: true)
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteBackwardByDecomposingPreviousCharacter(_:)): controller.deleteBackward()
        case #selector(NSResponder.deleteForward(_:)): controller.deleteForward()
        case #selector(NSResponder.deleteWordBackward(_:)):
            let caret = controller.caret
            controller.replace(controller.wordBoundary(before: caret)..<caret, with: "")
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            controller.insertNewline()
        case #selector(NSResponder.insertLineBreak(_:)): controller.insertHardBreak()
        case #selector(NSResponder.insertTab(_:)): controller.insertTab()
        case #selector(NSResponder.insertBacktab(_:)): controller.insertBacktab()
        case #selector(NSResponder.selectAll(_:)): controller.selectAll()
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): scrollPage(1)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): scrollPage(-1)
        default: super.doCommand(by: selector)
        }
    }

    private func scrollPage(_ direction: CGFloat) {
        guard let clip = enclosingScrollView?.contentView else { return }
        var origin = clip.bounds.origin
        origin.y = max(0, min(origin.y + direction * (clip.bounds.height - controller.lineHeight), frame.height - clip.bounds.height))
        clip.scroll(to: origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    // MARK: Commands (§6.1.5, §6.2)

    /// Cmd-/: hybrid ↔ source. The top visible line stays put.
    @objc public func toggleSourceMode(_ sender: Any?) {
        var anchor: Int? = nil
        if enclosingScrollView != nil {
            anchor = controller.sourceOffset(at: CGPoint(x: controller.layout.textOrigin, y: visibleRect.minY + 1))
        }
        controller.toggleSourceMode(anchor: anchor)
    }
    @objc public func toggleStrong(_ sender: Any?) { controller.toggleStrong() }
    @objc public func toggleEmphasis(_ sender: Any?) { controller.toggleEmphasis() }
    @objc public func toggleStrikethrough(_ sender: Any?) { controller.toggleStrikethrough() }
    @objc public func toggleCodeSpan(_ sender: Any?) { controller.toggleCodeSpan() }
    /// Cmd-K quick form: `[selection]()` with the caret in the parentheses.
    /// A popover can call `EditorController.insertLink(label:destination:title:)`.
    @objc public func insertLink(_ sender: Any?) { controller.insertLink() }
    /// Cmd-Ctrl-I: asks for an image file, then inserts `![selection](path)`.
    @objc public func insertImage(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.insertImage(path: imageHandler?.linkPath(forExistingImage: url) ?? url.path)
    }
    @objc public func setHeading1(_ sender: Any?) { controller.setHeading(level: 1) }
    @objc public func setHeading2(_ sender: Any?) { controller.setHeading(level: 2) }
    @objc public func setHeading3(_ sender: Any?) { controller.setHeading(level: 3) }
    @objc public func setHeading4(_ sender: Any?) { controller.setHeading(level: 4) }
    @objc public func setHeading5(_ sender: Any?) { controller.setHeading(level: 5) }
    @objc public func setHeading6(_ sender: Any?) { controller.setHeading(level: 6) }
    @objc public func makeParagraph(_ sender: Any?) { controller.makeParagraph() }
    @objc public func promoteHeading(_ sender: Any?) { controller.promoteHeading() }
    @objc public func demoteHeading(_ sender: Any?) { controller.demoteHeading() }
    @objc public func toggleBulletList(_ sender: Any?) { controller.toggleBulletList() }
    @objc public func toggleOrderedList(_ sender: Any?) { controller.toggleOrderedList() }
    @objc public func toggleTaskList(_ sender: Any?) { controller.toggleTaskList() }
    @objc public func toggleTaskDone(_ sender: Any?) { controller.toggleTaskDone() }
    @objc public func indentListItem(_ sender: Any?) { controller.indentListItem() }
    @objc public func outdentListItem(_ sender: Any?) { controller.outdentListItem() }
    @objc public func toggleBlockQuote(_ sender: Any?) { controller.toggleBlockQuote() }
    @objc public func insertCodeFence(_ sender: Any?) { controller.insertCodeFence() }
    @objc public func insertMathBlock(_ sender: Any?) { controller.insertMathBlock() }
    @objc public func insertThematicBreak(_ sender: Any?) { controller.insertThematicBreak() }
    @objc public func exitBlock(_ sender: Any?) { controller.exitBlock() }
    @objc public func insertHardBreak(_ sender: Any?) { controller.insertHardBreak() }

    @objc public func undo(_ sender: Any?) { controller.undo() }
    @objc public func redo(_ sender: Any?) { controller.redo() }
    @objc public override func selectAll(_ sender: Any?) { controller.selectAll() }

    @objc public func copy(_ sender: Any?) {
        let range = controller.selection.range
        guard !range.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(controller.string(in: range), forType: .string)
    }

    @objc public func cut(_ sender: Any?) {
        guard !controller.selection.isEmpty else { return }
        copy(sender)
        controller.replace(controller.selection.range, with: "")
    }

    @objc public func paste(_ sender: Any?) {
        if pasteImages(from: NSPasteboard.general) { return }
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        controller.insert(text)
    }

    public override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool { true }

    @objc public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return controller.canUndo
        case #selector(redo(_:)): return controller.canRedo
        case #selector(copy(_:)): return !controller.selection.isEmpty
        case #selector(cut(_:)): return isEditable && !controller.selection.isEmpty
        case #selector(paste(_:)): return isEditable
        case #selector(toggleSourceMode(_:)):
            item.state = controller.mode == .source ? .on : .off
            return true
        default: return true
        }
    }

    // MARK: Drag and drop (images, P0-07)

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { imageDragOperation(sender) }
    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { imageDragOperation(sender) }
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { performImageDrop(sender) }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let offset = controller.sourceOffset(at: point) else { return }
        if event.clickCount == 2 {
            let word = controller.wordRange(at: offset)
            controller.select(word)
            mouseAnchor = word.lowerBound
        } else if event.modifierFlags.contains(.shift) {
            controller.moveCaret(to: offset, extend: true)
            mouseAnchor = controller.selection.anchor
        } else {
            controller.moveCaret(to: offset)
            mouseAnchor = offset
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let anchor = mouseAnchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let offset = controller.sourceOffset(at: point) else { return }
        controller.select(anchor..<anchor)
        controller.moveCaret(to: offset, extend: true)
        autoscroll(with: event)
    }

    public override func mouseUp(with event: NSEvent) { mouseAnchor = nil }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    // MARK: NSTextInputClient

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if replacementRange.location != NSNotFound, !controller.hasMarkedText {
            controller.replace(controller.byteRange(fromUTF16: replacementRange), with: text)
        } else {
            controller.insert(text)
        }
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if replacementRange.location != NSNotFound, !controller.hasMarkedText {
            controller.select(controller.byteRange(fromUTF16: replacementRange))
        }
        controller.setMarkedText(text, selected: selectedRange)
    }

    public func unmarkText() {
        controller.unmarkText()
    }

    public func selectedRange() -> NSRange {
        controller.utf16Range(fromBytes: controller.selection.range)
    }

    public func markedRange() -> NSRange {
        guard let marked = controller.marked else { return NSRange(location: NSNotFound, length: 0) }
        return controller.utf16Range(fromBytes: marked.range)
    }

    public func hasMarkedText() -> Bool { controller.hasMarkedText }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let bytes = controller.byteRange(fromUTF16: range)
        actualRange?.pointee = controller.utf16Range(fromBytes: bytes)
        return NSAttributedString(string: controller.string(in: bytes))
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.markedClauseSegment, .underlineStyle]
    }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let bytes = controller.byteRange(fromUTF16: range)
        actualRange?.pointee = controller.utf16Range(fromBytes: bytes)
        var rect = controller.caretRect(forSource: bytes.lowerBound)
        if !bytes.isEmpty {
            let end = controller.caretRect(forSource: bytes.upperBound)
            if abs(end.minY - rect.minY) < 0.5 { rect = rect.union(end) }
        }
        rect.size.width = max(rect.width, 1)
        return screenRect(rect)
    }

    public func characterIndex(for point: NSPoint) -> Int {
        let local = convert(window?.convertPoint(fromScreen: point) ?? point, from: nil)
        guard let offset = controller.sourceOffset(at: local) else { return NSNotFound }
        return controller.utf16Offset(fromByte: offset)
    }

    public func attributedString() -> NSAttributedString { NSAttributedString(string: controller.string) }

    private func screenRect(_ rect: CGRect) -> NSRect {
        let inWindow = convert(rect, to: nil)
        return window?.convertToScreen(inWindow) ?? inWindow
    }

    // MARK: Accessibility (text area, UTF-16 units)

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    public override func accessibilityRoleDescription() -> String? { "Markdown editor" }
    public override func accessibilityLabel() -> String? { "Document" }
    public override func accessibilityValue() -> Any? { controller.string }

    public override func setAccessibilityValue(_ value: Any?) {
        guard let text = value as? String else { return }
        controller.replace(0..<controller.count, with: text)
    }

    public override func accessibilityNumberOfCharacters() -> Int { controller.utf16Count }

    public override func accessibilitySelectedText() -> String? {
        controller.string(in: controller.selection.range)
    }

    public override func accessibilitySelectedTextRange() -> NSRange {
        controller.utf16Range(fromBytes: controller.selection.range)
    }

    public override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        let bytes = controller.byteRange(fromUTF16: range)
        if bytes.isEmpty { controller.moveCaret(to: bytes.lowerBound) } else { controller.select(bytes) }
    }

    public override func accessibilityString(for range: NSRange) -> String? {
        controller.string(in: controller.byteRange(fromUTF16: range))
    }

    public override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        accessibilityString(for: range).map { NSAttributedString(string: $0) }
    }

    public override func accessibilityFrame(for range: NSRange) -> NSRect {
        let bytes = controller.byteRange(fromUTF16: range)
        let rects = bytes.isEmpty ? [controller.caretRect(forSource: bytes.lowerBound)] : controller.rects(forSource: bytes, visible: bounds)
        guard var union = rects.first else { return screenRect(controller.caretRect(forSource: bytes.lowerBound)) }
        for rect in rects.dropFirst() { union = union.union(rect) }
        if union.width < 1 { union.size.width = 1 }
        return screenRect(union)
    }

    public override func accessibilityVisibleCharacterRange() -> NSRange {
        // Whole entries: the first and last top-level blocks on screen.
        let visible = visibleRect.isEmpty || visibleRect.height > bounds.height ? bounds : visibleRect
        let entries = controller.projection.entries
        guard let first = controller.sourceOffset(at: CGPoint(x: 0, y: visible.minY)).flatMap(controller.projection.entryIndex(containing:)),
              let last = controller.sourceOffset(at: CGPoint(x: bounds.width, y: visible.maxY)).flatMap(controller.projection.entryIndex(containing:))
        else { return controller.utf16Range(fromBytes: 0..<controller.count) }
        let start = entries[min(first, last)].start
        let end = entries[max(first, last)].start + entries[max(first, last)].length
        return controller.utf16Range(fromBytes: start..<end)
    }

    public override func accessibilityInsertionPointLineNumber() -> Int {
        controller.rope.line(at: controller.caret)
    }

    public override func accessibilityLine(for index: Int) -> Int {
        controller.rope.line(at: controller.byteOffset(fromUTF16: index))
    }

    public override func accessibilityRange(forLine line: Int) -> NSRange {
        guard line >= 0, line < controller.rope.lineCount else { return NSRange(location: NSNotFound, length: 0) }
        return controller.utf16Range(fromBytes: controller.rope.lineRange(line))
    }

    public override func accessibilityRange(for point: NSPoint) -> NSRange {
        let index = characterIndex(for: point)
        return index == NSNotFound ? NSRange(location: NSNotFound, length: 0) : NSRange(location: index, length: 0)
    }

    public override func accessibilityRange(for index: Int) -> NSRange {
        let byte = controller.byteOffset(fromUTF16: index)
        let end = controller.nextCaretStop(after: byte)
        return controller.utf16Range(fromBytes: byte..<end)
    }
}

/// One editor command and its key equivalent, for building menus.
@MainActor
public struct EditorKeyEquivalent {
    public let title: String
    /// `NSMenuItem.keyEquivalent` (lowercase; `"\r"` for Return).
    public let key: String
    public let modifiers: NSEvent.ModifierFlags
    public let action: Selector

    init(_ title: String, _ key: String, _ modifiers: NSEvent.ModifierFlags, _ action: Selector) {
        self.title = title
        self.key = key
        self.modifiers = modifiers
        self.action = action
    }
}
