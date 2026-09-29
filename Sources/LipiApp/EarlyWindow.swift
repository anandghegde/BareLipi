import AppKit
import LipiEditor
import LipiLayout

/// The first document window, shown from `applicationWillFinishLaunching`
/// before AppKit's document machinery has started (PRD §9.1 launch budget).
///
/// `NSApplication.finishLaunching` spends 26–48 ms customising the main
/// menu, installing Open Recent and looking at saved state before
/// `NSDocumentController` makes the untitled document, and the window only
/// exists after that. Instead the app bundle builds a
/// `DocumentWindowController` for the launch text straight away, orders it
/// front and draws it, and the first `LipiDocument` that makes window
/// controllers adopts it with `addWindowController`. Nothing in the window
/// depends on the document until then, so it is the window the document
/// would have made, shown earlier:
///
/// - the untitled document keeps what is drawn (the command line's fixture
///   or file under `--measure`, otherwise empty);
/// - a document opened at launch (Finder, `open`, a restored window) loads
///   its text into the window instead, and `NSDocumentController` makes no
///   untitled document when a file is opened at launch, so no window is
///   left over;
/// - state restoration is predicted from this app's own record of the last
///   session (`shouldShow`): when windows may come back the early window is
///   not shown, so restored windows appear where they were. If restoration
///   happens anyway (the record was wrong), the first restored document
///   adopts the window and AppKit moves it to its saved frame;
/// - a window nobody adopted shortly after launch becomes an untitled
///   document when no document opened at all (AppKit tried to restore
///   windows it could not, say an edited untitled document after a crash,
///   and so made no untitled document either) or when it was typed in;
///   otherwise it closes.
///
/// `present` is shared with the SwiftPM executable, which shows its one
/// window the same way.
@MainActor
public final class EarlyWindow {
    /// The shown window waiting for its document; nil once adopted or discarded.
    public private(set) static var pending: EarlyWindow?

    /// Defaults key: false turns the early window off (a safety valve).
    public static let enabledKey = "EarlyFirstWindow"
    /// Defaults key: the last session may have left windows for AppKit to
    /// restore. Set while a document with a file is on screen, and cleared
    /// at a clean quit that does not keep windows.
    public static let restorableKey = "EarlyFirstWindowRestorable"
    /// How long after launch a window nobody adopted waits for a slow open.
    static let adoptionGrace: TimeInterval = 1

    public let windowController: DocumentWindowController
    /// The text was typed in before any document adopted the window.
    public private(set) var isEdited = false

    init(windowController: DocumentWindowController) {
        self.windowController = windowController
        let controller = windowController.controller
        let previous = controller.onChange
        controller.onChange = { [weak self] change in
            previous?(change)
            if change.textChanged { self?.isEdited = true }
        }
    }

    // MARK: Policy

    /// Whether to show a window before the document controller starts:
    /// not when turned off, and not when the last session may have left
    /// windows for state restoration (unless restoration is being skipped).
    public static func shouldShow(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: enabledKey) != nil, !defaults.bool(forKey: enabledKey) { return false }
        if defaults.bool(forKey: "ApplePersistenceIgnoreState") { return true }
        return !defaults.bool(forKey: restorableKey)
    }

    /// A document window with a file is on screen: if the process ends
    /// without a clean quit, AppKit restores it at the next launch.
    public static func noteRestorableWindow(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: restorableKey) else { return }
        defaults.set(true, forKey: restorableKey)
    }

    /// A clean quit: windows come back only when the system keeps them
    /// (System Settings › "Close windows when quitting an application" off,
    /// or Quit and Keep Windows) and one of them has a file (untitled
    /// documents are not autosaved as drafts, so they do not restore).
    public static func noteTermination(keepsWindows: Bool, hasFileWindows: Bool, defaults: UserDefaults = .standard) {
        defaults.set(keepsWindows && hasFileWindows, forKey: restorableKey)
    }

    // MARK: Showing

    /// App bundle: call from `applicationWillFinishLaunching`. Builds the
    /// document window for the launch text and draws its first frame now,
    /// unless `shouldShow` says restoration may bring other windows.
    @discardableResult
    public static func showForDocuments(defaults: UserDefaults = .standard) -> EarlyWindow? {
        guard pending == nil, shouldShow(defaults: defaults) else { return nil }
        let tracker = LaunchTracker.shared
        tracker.didFinishLaunching()
        let text = tracker.consumeInitialText() ?? ""
        var mark = CACurrentMediaTime()
        let controller = EditorController(text: text, engine: tracker.options.engine, theme: tracker.options.theme,
                                          zoom: tracker.options.zoom, viewportWidth: 1100)
        tracker.phases.controller = CACurrentMediaTime() - mark
        mark = CACurrentMediaTime()
        let windowController = DocumentWindowController(controller: controller, theme: tracker.options.theme)
        tracker.attach(windowController.editor)
        // What the untitled document's window says once it has one.
        windowController.window?.title = "Untitled"
        // Until a document owns it there is nothing to restore it from: a
        // window saved in this state makes the next launch "restore" it,
        // fail, and then open no untitled document either.
        windowController.window?.isRestorable = false
        let early = EarlyWindow(windowController: windowController)
        pending = early
        tracker.phases.window = CACurrentMediaTime() - mark
        tracker.phases.shown = CACurrentMediaTime()
        present(windowController.window!, firstResponder: windowController.editor)
        return early
    }

    /// Orders `window` front with `firstResponder` focused and draws it and
    /// commits the frame now, rather than at the end of the run loop turn,
    /// which during launch is after `finishLaunching` returns.
    public static func present(_ window: NSWindow, firstResponder: NSResponder?) {
        window.makeKeyAndOrderFront(nil)
        if let firstResponder { window.makeFirstResponder(firstResponder) }
        NSApp.activate()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    // MARK: Adoption

    /// Hands the pending window to the document making its window
    /// controllers, or nil when there is none (every document after the
    /// first, and every launch without an early window). A document that
    /// brings its own text (`replacesText`) does not take a window that was
    /// typed in; `settleNow` makes that text an untitled document instead.
    static func adopt(replacesText: Bool) -> EarlyWindow? {
        guard let early = pending, !(early.isEdited && replacesText) else { return nil }
        pending = nil
        early.windowController.window?.isRestorable = true
        return early
    }

    /// Call from `applicationDidFinishLaunching`: gives a slow open at
    /// launch `adoptionGrace` to adopt the window, then settles it.
    public static func settleAfterLaunch() {
        guard pending != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + adoptionGrace) {
            MainActor.assumeIsolated {
                _ = settleNow(hasDocuments: !NSDocumentController.shared.documents.isEmpty, makeDocument: untitledDocument)
            }
        }
    }

    /// A window nobody adopted. With no documents open, or with text typed
    /// in it, it becomes a document from `makeDocument` (whose
    /// `makeWindowControllers` adopts it); otherwise it closes. Returns what
    /// happened, for tests.
    static func settleNow(hasDocuments: Bool, makeDocument: () -> NSDocument?) -> Settlement {
        guard let early = pending else { return .none }
        if early.isEdited || !hasDocuments, let document = makeDocument() {
            document.makeWindowControllers()
            document.showWindows()
            if pending == nil { return .adopted }
        }
        // Never close a window with typed text; if no document could take
        // it, it stays open without one.
        guard !early.isEdited else { return .kept }
        pending = nil
        early.windowController.close()
        return .closed
    }

    /// A new untitled document registered with the document controller.
    private static func untitledDocument() -> NSDocument? {
        let controller = NSDocumentController.shared
        guard let type = controller.defaultType, let document = try? controller.makeUntitledDocument(ofType: type) else { return nil }
        controller.addDocument(document)
        return document
    }

    enum Settlement: Equatable { case none, adopted, kept, closed }

    // MARK: Test support

    /// Makes `text`'s window the pending one without showing it.
    @discardableResult
    static func makePending(text: String) -> EarlyWindow {
        let controller = EditorController(text: text, viewportWidth: 800)
        let windowController = DocumentWindowController(controller: controller, theme: .taalegari,
                                                        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600))
        windowController.window?.isRestorable = false
        let early = EarlyWindow(windowController: windowController)
        pending = early
        return early
    }

    /// Forgets the pending window.
    static func reset() { pending = nil }
}
