import AppKit
import LipiCore

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Documents are opened by NSDocumentController once LipiDocument lands.
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }
}
