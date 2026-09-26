import AppKit
import LipiCore
import LipiEditor
import LipiLayout

// Phase 0 shell: a window with one EditorView in an NSScrollView. The real
// application bundle (Info.plist, document types, icon) comes from the
// xcodegen project; this SwiftPM executable is the spike and harness host.

let mainEntered = CACurrentMediaTime()
let processStarted = processStartTime()
let launchInterval = Signposts.launch.beginInterval("launch.firstFrame")
let options = Options.parse(CommandLine.arguments)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var editor: EditorView!
    var driver: MeasureDriver?

    func applicationDidFinishLaunching(_ notification: Notification) {
        var phases = LaunchPhases(appLaunch: CACurrentMediaTime() - mainEntered)
        let text: String
        var mark = CACurrentMediaTime()
        do { text = try options.text() } catch { Options.fail("cannot read \(options.path ?? "document"): \(error.localizedDescription)") }
        phases.documentLoad = CACurrentMediaTime() - mark
        let contentRect = NSRect(x: 0, y: 0, width: 1100, height: 760)
        mark = CACurrentMediaTime()
        let controller = EditorController(text: text, engine: options.engine, theme: options.theme, zoom: options.zoom, viewportWidth: contentRect.width)
        phases.controller = CACurrentMediaTime() - mark
        mark = CACurrentMediaTime()
        let scroll = NSScrollView(frame: contentRect)
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(cgColor: options.theme.colors.bg.cgColor) ?? .textBackgroundColor
        editor = EditorView(controller: controller, frame: NSRect(x: 0, y: 0, width: contentRect.width, height: contentRect.height))
        scroll.documentView = editor

        window = NSWindow(contentRect: contentRect, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = options.title
        window.contentView = scroll
        window.center()
        window.setFrameAutosaveName("BareLipi.main")
        window.appearance = NSAppearance(named: options.theme.isDark ? .darkAqua : .aqua)
        editor.onFirstDraw = { [weak self] in
            Signposts.launch.endInterval("launch.firstFrame", launchInterval)
            guard let self, let seconds = options.measureSeconds else { return }
            let now = CACurrentMediaTime()
            phases.firstDraw = now - phases.shown
            phases.mainToFirstFrame = now - mainEntered
            phases.preMain = processStarted.map { mainEntered - (now - Date().timeIntervalSince($0)) }
            phases.toFirstFrame = processStarted.map { Date().timeIntervalSince($0) }
            self.driver = MeasureDriver(view: self.editor, seconds: seconds, launch: phases)
            DispatchQueue.main.async { self.driver?.start() }
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        NSApp.activate()
        phases.window = CACurrentMediaTime() - mark
        phases.shown = CACurrentMediaTime()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            editor.controller.load(text)
            window.title = "BareLipi — \(url.lastPathComponent)"
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate

let mainMenu = NSMenu()
let appItem = NSMenuItem()
mainMenu.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit BareLipi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu

let fileItem = NSMenuItem()
mainMenu.addItem(fileItem)
let fileMenu = NSMenu(title: "File")
fileMenu.addItem(withTitle: "Open…", action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o")
fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
fileItem.submenu = fileMenu

let editItem = NSMenuItem()
mainMenu.addItem(editItem)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: #selector(EditorView.undo(_:)), keyEquivalent: "z")
let redo = editMenu.addItem(withTitle: "Redo", action: #selector(EditorView.redo(_:)), keyEquivalent: "z")
redo.keyEquivalentModifierMask = [.command, .shift]
editMenu.addItem(.separator())
editMenu.addItem(withTitle: "Cut", action: #selector(EditorView.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(EditorView.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(EditorView.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = editMenu
app.mainMenu = mainMenu

app.run()
