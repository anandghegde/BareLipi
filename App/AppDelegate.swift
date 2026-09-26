import AppKit
import LipiApp

/// The shipping app (ADR-008): `NSDocumentController` opens `LipiDocument`s
/// (declared in project.yml's document types), each in a tabbed document
/// window. Launch options are the SwiftPM shell's (`--fixture`, `--measure`),
/// parsed leniently so Finder and Xcode arguments are ignored.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let mainEntered = CACurrentMediaTime()
        LaunchTracker.shared.begin(options: LaunchOptions.parse(CommandLine.arguments, lenient: true), mainEntered: mainEntered)
        MeasureDriver.host = "bundle"
        let app = NSApplication.shared
        // The first NSDocumentController instantiated becomes the shared one.
        _ = LipiDocumentController()
        let delegate = AppDelegate()
        app.delegate = delegate
        let mark = CACurrentMediaTime()
        app.mainMenu = MainMenu.build(appName: "BareLipi", documents: true)
        LaunchTracker.shared.phases.menu = CACurrentMediaTime() - mark
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchTracker.shared.didFinishLaunching()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
