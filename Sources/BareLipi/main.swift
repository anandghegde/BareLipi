import AppKit
import LipiApp
import LipiCore
import LipiEditor
import LipiLayout

// SwiftPM shell: one EditorView in an NSScrollView, built by LipiApp's
// EditorHost exactly as the app bundle's document windows are, with the
// shared main menu. This executable is the harness host
// (`swift run -c release BareLipi --fixture kannada-20k --measure 6`); the
// shipping app with NSDocument, tabs and restoration is App/ (project.yml).

let mainEntered = CACurrentMediaTime()
let options = LaunchOptions.parse(CommandLine.arguments)
MainActor.assumeIsolated { LaunchTracker.shared.begin(options: options, mainEntered: mainEntered) }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var editor: EditorView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let tracker = LaunchTracker.shared
        tracker.didFinishLaunching()
        let text: String
        var mark = CACurrentMediaTime()
        do { text = try options.text() } catch { LaunchOptions.fail("cannot read \(options.path ?? "document"): \(error.localizedDescription)") }
        tracker.phases.documentLoad = CACurrentMediaTime() - mark
        let contentRect = NSRect(x: 0, y: 0, width: 1100, height: 760)
        mark = CACurrentMediaTime()
        let controller = EditorController(text: text, engine: options.engine, theme: options.theme, zoom: options.zoom, viewportWidth: contentRect.width)
        tracker.phases.controller = CACurrentMediaTime() - mark
        mark = CACurrentMediaTime()
        let (scroll, editor) = EditorHost.makeScrollView(controller: controller, theme: options.theme, frame: contentRect)
        self.editor = editor
        window = EditorHost.makeWindow(contentRect: contentRect)
        window.title = options.title
        window.contentView = scroll
        window.center()
        window.setFrameAutosaveName("BareLipi.main")
        window.appearance = NSAppearance(named: options.theme.isDark ? .darkAqua : .aqua)
        EditorHost.useEightBitBacking(for: window, editor: editor)
        tracker.attach(editor)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        NSApp.activate()
        tracker.phases.window = CACurrentMediaTime() - mark
        tracker.phases.shown = CACurrentMediaTime()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Opens a file into the one window, decoded byte-exactly (BOM and line
    /// endings kept in the text; non-UTF-8 shown via lossy decoding).
    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        editor.controller.load(TextCodec.decode(data).text)
        window.title = "BareLipi — \(url.lastPathComponent)"
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    app.delegate = delegate
    let mark = CACurrentMediaTime()
    MainMenu.install(documents: false)
    LaunchTracker.shared.phases.menu = CACurrentMediaTime() - mark
    app.run()
}
