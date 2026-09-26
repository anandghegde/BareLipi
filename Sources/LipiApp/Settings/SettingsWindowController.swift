import AppKit

/// The Settings window (Cmd-,), made on first use: a toolbar-style tab
/// view with one pane per section. P0-11 adds Keys; other panes append
/// their own `NSTabViewItem` in `makePanes()`.
///
/// AppKit rather than the PRD's SwiftUI-in-NSHostingController: the app
/// does not link SwiftUI today, and loading it only for Settings would add
/// to a launch that is already over budget.
@MainActor
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    public static let shared = SettingsWindowController()

    public let tabs = NSTabViewController()

    public init() {
        tabs.tabStyle = .toolbar
        let window = NSWindow(contentViewController: tabs)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("Settings")
        super.init(window: window)
        window.delegate = self
        for item in Self.makePanes() { tabs.addTabViewItem(item) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func makePanes() -> [NSTabViewItem] {
        [pane(EditorSettingsPane(), "Editing", "pencil"),
         pane(CountsSettingsPane(), "Counts", "textformat.123"),
         pane(ImagesSettingsPane(), "Images", "photo"),
         pane(KeysSettingsPane(), "Keys", "keyboard")]
    }

    private static func pane(_ controller: NSViewController, _ label: String, _ symbol: String) -> NSTabViewItem {
        let item = NSTabViewItem(viewController: controller)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }

    /// Selects the pane labelled `label` (e.g. "Keys").
    public func select(_ label: String) {
        if let n = tabs.tabViewItems.firstIndex(where: { $0.label == label }) { tabs.selectedTabViewItemIndex = n }
    }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }
}
