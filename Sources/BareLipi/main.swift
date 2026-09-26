import AppKit
import LipiCore

/// Placeholder shell: proves the SwiftPM executable links AppKit and LipiCore
/// and gives the Phase 0 spike a window to draw into. The real application
/// bundle (Info.plist, document types, icon) comes from the xcodegen project.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let rope = LipiRope("# BareLipi\n\nಬರೆ · ಲಿಪಿ\n")
        let label = NSTextField(labelWithString: "BareLipi — rope ready: \(rope.debugDescription)")
        label.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        label.alignment = .center

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "BareLipi"
        window.center()
        window.contentView = label
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
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
app.mainMenu = mainMenu

app.run()
