import AppKit
import LipiCore
import LipiEditor
import LipiLayout

/// One document window (§6.19): notice bars above an `NSScrollView` hosting
/// the `EditorView`, built the way the SwiftPM shell builds it. Tabs are
/// preferred; Cmd-T opens a new untitled document in a tab of this window.
@MainActor
public final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    public let editor: EditorView
    public let content: DocumentContentView
    /// Sidebar, content and status bar (§6.8, §6.18).
    public let chrome: DocumentChromeView
    let counts: CountsModel
    public var controller: EditorController { editor.controller }
    /// Called when the viewport scrolls (restorable state).
    var onScroll: (() -> Void)?
    /// What zen mode hid and must put back (§6.12); nil outside zen mode.
    var zenRestore: ZenRestore?

    public init(controller: EditorController, theme: Theme, contentRect: NSRect = NSRect(x: 0, y: 0, width: 1100, height: 760)) {
        let (scroll, editor) = EditorHost.makeScrollView(controller: controller, theme: theme, frame: contentRect)
        self.editor = editor
        content = DocumentContentView(scrollView: scroll, frame: contentRect)
        chrome = DocumentChromeView(content: content, frame: contentRect)
        counts = CountsModel(controller: controller, bar: chrome.statusBar)
        let window = EditorHost.makeWindow(contentRect: contentRect)
        window.contentView = chrome
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "BareLipi.document"
        window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        window.initialFirstResponder = editor
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true
        EditorHost.useEightBitBacking(for: window, editor: editor)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipScrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        let previous = controller.onChange
        controller.onChange = { [weak self] change in
            previous?(change)
            self?.editorDidChange(change)
        }
        counts.setNeedsUpdate(textChanged: true)
        observeOptionalSyntax()
        observeWritingSettings()
    }

    private func editorDidChange(_ change: EditorChange) {
        counts.setNeedsUpdate(textChanged: change.textChanged)
        if let outline = chrome.sidebar as? OutlineSidebar { outline.setNeedsUpdate(textChanged: change.textChanged) }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func clipScrolled(_ note: Notification) { onScroll?() }

    public var scrollView: NSScrollView { content.scrollView }

    // MARK: Tabs

    /// Cmd-T and the tab bar's + button: a new untitled document in a tab.
    public override func newWindowForTab(_ sender: Any?) {
        guard let window,
              let document = try? NSDocumentController.shared.openUntitledDocumentAndDisplay(false) else { return }
        document.makeWindowControllers()
        guard let tab = document.windowControllers.first?.window else { return }
        window.addTabbedWindow(tab, ordered: .above)
        tab.makeKeyAndOrderFront(sender)
    }

    // MARK: Viewport

    /// Caret, selection and scroll anchor, for restoration.
    public func editorState() -> RestorableEditorState {
        let visible = scrollView.contentView.bounds
        let anchor = controller.sourceOffset(at: CGPoint(x: controller.layout.textOrigin + 1, y: visible.minY + 1)) ?? 0
        let lineTop = controller.caretRect(forSource: anchor).minY
        let selection = controller.selection
        var state = RestorableEditorState(anchor: selection.anchor, head: selection.head, scrollAnchor: anchor,
                                          scrollOffset: Double(visible.minY - lineTop))
        state.showsOutline = zenRestore?.outline ?? isOutlineVisible
        state.focusMode = editor.focusMode
        state.typewriter = editor.typewriterMode
        state.zenMode = isZenMode
        state.zenWasFullScreen = zenRestore?.fullScreen
        return state
    }

    /// Puts the caret, selection and viewport back.
    public func apply(_ state: RestorableEditorState) {
        let s = state.clamped(to: controller.count)
        if let shows = s.showsOutline, shows != isOutlineVisible { setOutlineVisible(shows, focus: false) }
        if let focus = s.focusMode { editor.focusMode = focus }
        if let typewriter = s.typewriter { editor.typewriterMode = typewriter }
        if s.zenMode == true, !isZenMode { enterZenMode(wasFullScreen: s.zenWasFullScreen ?? false) }
        controller.moveCaret(to: s.anchor)
        if s.head != s.anchor { controller.moveCaret(to: s.head, extend: true) }
        let lineTop = controller.caretRect(forSource: s.scrollAnchor).minY
        scroll(toY: lineTop + CGFloat(s.scrollOffset))
    }

    /// Replaces the text with `text` read from disk (§6.16 silent reload):
    /// the caret and selection are remapped through a diff of old and new,
    /// and the viewport keeps its position.
    public func reload(text: String) {
        let old = Array(controller.rope.string.utf8)
        let new = Array(text.utf8)
        let selection = controller.selection
        let y = scrollY
        let anchor = CaretRemap.map(selection.anchor, from: old, to: new)
        let head = CaretRemap.map(selection.head, from: old, to: new)
        controller.load(text)
        controller.moveCaret(to: anchor)
        if head != anchor { controller.moveCaret(to: head, extend: true) }
        scroll(toY: y)
    }

    /// The viewport's top in document coordinates.
    public var scrollY: CGFloat { scrollView.contentView.bounds.minY }

    /// Scrolls the viewport's top to `y`, laying out what it needs and
    /// clamping to the document.
    public func scroll(toY y: CGFloat) {
        let clip = scrollView.contentView
        controller.prepare(CGRect(x: 0, y: y, width: clip.bounds.width, height: clip.bounds.height * 2))
        let height = max(editor.frame.height, controller.contentHeight + controller.lineHeight * 2)
        if editor.frame.height < height { editor.setFrameSize(NSSize(width: editor.frame.width, height: height.rounded(.up))) }
        let maxY = max(0, editor.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, min(y, maxY))))
        scrollView.reflectScrolledClipView(clip)
    }
}
