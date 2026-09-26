import AppKit
import LipiEditor
import LipiLayout
import os

/// Builds the editor's view stack the same way for the SwiftPM executable
/// and the app bundle: an `NSScrollView` whose document view is an
/// `EditorView`, with 8-bit layer contents.
@MainActor
public enum EditorHost {
    /// A scroll view hosting a new `EditorView` for `controller`.
    public static func makeScrollView(controller: EditorController, theme: Theme, frame: NSRect) -> (NSScrollView, EditorView) {
        let scroll = NSScrollView(frame: frame)
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(cgColor: theme.colors.bg.cgColor) ?? .textBackgroundColor
        let editor = EditorView(controller: controller, frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height))
        scroll.documentView = editor
        return (scroll, editor)
    }

    /// A titled, resizable window for the editor. `defer: true` leaves the
    /// window server backing until the window is first ordered in.
    public static func makeWindow(contentRect: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: contentRect, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        return window
    }

    /// Asks for 8-bit layer contents on the editor, its clip and scroll
    /// views and the window's content view. On an EDR display AppKit
    /// otherwise backs layers with 16-bit float (8 bytes per pixel), which
    /// was 128 MB of the Phase 0 baseline footprint on a 4K display; the
    /// editor draws sRGB/P3 text and fills, so 8 bits per channel lose
    /// nothing visible. Call after the views are in their window.
    public static func useEightBitBacking(for window: NSWindow, editor: NSView) {
        var views: [NSView] = []
        var view: NSView? = editor
        while let v = view { views.append(v); view = v.superview }
        for v in views {
            if v.layer == nil, v === editor { v.wantsLayer = true }
            v.layer?.contentsFormat = .RGBA8Uint
        }
        // The window's own backing store: 24-bit RGB plus alpha rather than
        // the extended-range depth AppKit picks for EDR screens.
        window.depthLimit = .twentyfourBitRGB
    }
}

/// `launch.firstFrame` bookkeeping shared by both hosts (PRD §9.1): marks
/// `main`, the phases up to the first draw of the first editor, closes the
/// signpost there and, under `--measure`, starts the `MeasureDriver`.
@MainActor
public final class LaunchTracker {
    public static let shared = LaunchTracker()

    public private(set) var mainEntered: Double = CACurrentMediaTime()
    public private(set) var processStarted: Date?
    public var phases = LaunchPhases(appLaunch: 0)
    public private(set) var options = LaunchOptions()
    private var interval: OSSignpostIntervalState?
    private var attached = false
    private var initialTextConsumed = false
    public private(set) var driver: MeasureDriver?

    /// Call first thing in `main`.
    public func begin(options: LaunchOptions, mainEntered: Double = CACurrentMediaTime()) {
        self.mainEntered = mainEntered
        self.options = options
        processStarted = processStartTime()
        interval = Signposts.launch.beginInterval("launch.firstFrame")
        LaunchPrewarm.start(theme: options.theme)
    }

    /// Call from `applicationDidFinishLaunching`, and when the first
    /// document is created: in the bundle `NSDocumentController` opens the
    /// untitled document inside `finishLaunching`, before the delegate hears
    /// of it, so whichever comes first ends the app-launch phase.
    public func didFinishLaunching() {
        guard phases.appLaunch == 0 else { return }
        phases.appLaunch = CACurrentMediaTime() - mainEntered
    }

    /// The text for the first untitled document when the command line named
    /// a fixture or a file (measurement runs); nil otherwise and afterwards.
    public func consumeInitialText() -> String? {
        guard !initialTextConsumed else { return nil }
        initialTextConsumed = true
        guard options.fixture != nil || options.path != nil else { return nil }
        let mark = CACurrentMediaTime()
        defer { phases.documentLoad = CACurrentMediaTime() - mark }
        return try? options.text()
    }

    /// Watches the first editor for its first draw.
    public func attach(_ editor: EditorView) {
        guard !attached else { return }
        attached = true
        let previous = editor.onFirstDraw
        editor.onFirstDraw = { [weak self, weak editor] in
            previous?()
            guard let self, let editor else { return }
            self.firstDraw(editor)
        }
    }

    private func firstDraw(_ editor: EditorView) {
        if let interval { Signposts.launch.endInterval("launch.firstFrame", interval) }
        interval = nil
        guard let seconds = options.measureSeconds else { return }
        let now = CACurrentMediaTime()
        phases.firstDraw = now - phases.shown
        phases.mainToFirstFrame = now - mainEntered
        phases.preMain = processStarted.map { mainEntered - (now - Date().timeIntervalSince($0)) }
        phases.toFirstFrame = processStarted.map { Date().timeIntervalSince($0) }
        driver = MeasureDriver(view: editor, seconds: seconds, launch: phases)
        DispatchQueue.main.async { self.driver?.start() }
    }
}
