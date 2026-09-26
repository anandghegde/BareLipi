import AppKit
import LipiEditor

/// View commands of a document window: zoom (§6.20).
extension DocumentWindowController {
    public static let zoomRange: ClosedRange<CGFloat> = 0.6...2.0

    /// Cmd-+: 10 % larger, up to 200 %.
    @objc public func zoomIn(_ sender: Any?) { setZoom(controller.zoom + 0.1) }
    /// Cmd--: 10 % smaller, down to 60 %.
    @objc public func zoomOut(_ sender: Any?) { setZoom(controller.zoom - 0.1) }
    /// Cmd-0: 100 %.
    @objc public func resetZoom(_ sender: Any?) { setZoom(1) }

    /// Scales the type scale, keeping the line at the top of the viewport
    /// and the selection where they were.
    public func setZoom(_ zoom: CGFloat) {
        let r = DocumentWindowController.zoomRange
        let z = min(max((zoom * 10).rounded() / 10, r.lowerBound), r.upperBound)
        guard abs(z - controller.zoom) > 0.001 else { return }
        let state = editorState()
        controller.setTheme(controller.theme, zoom: z)
        apply(state)
    }

    // MARK: Zen mode (§6.12)

    public var isZenMode: Bool { zenRestore != nil }

    /// Cmd-Ctrl-Shift-F: full screen with the outline and status bar hidden;
    /// again, everything as it was.
    @objc public func toggleZenMode(_ sender: Any?) {
        guard let window else { return }
        let fullScreen = window.styleMask.contains(.fullScreen)
        if let restore = zenRestore {
            zenRestore = nil
            chrome.isStatusBarHidden = restore.statusBarHidden
            if restore.outline { setOutlineVisible(true, focus: false) }
            if !restore.fullScreen, fullScreen { window.toggleFullScreen(sender) }
        } else {
            zenRestore = ZenRestore(outline: isOutlineVisible, statusBarHidden: chrome.isStatusBarHidden, fullScreen: fullScreen)
            if isOutlineVisible { setOutlineVisible(false, focus: false) }
            chrome.isStatusBarHidden = true
            if !fullScreen, window.isVisible { window.toggleFullScreen(sender) }
            window.makeFirstResponder(editor)
        }
        chrome.layoutSubtreeIfNeeded()
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        // Leaving full screen by other means (Esc, the green button) ends zen mode.
        if let restore = zenRestore, !restore.fullScreen { toggleZenMode(nil) }
    }

    public func validateViewItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(zoomIn(_:)): return controller.zoom < DocumentWindowController.zoomRange.upperBound - 0.001
        case #selector(zoomOut(_:)): return controller.zoom > DocumentWindowController.zoomRange.lowerBound + 0.001
        case #selector(resetZoom(_:)): return abs(controller.zoom - 1) > 0.001
        case #selector(toggleOutline(_:)):
            item.state = isOutlineVisible ? .on : .off
            return true
        case #selector(toggleZenMode(_:)):
            item.state = isZenMode ? .on : .off
            return true
        default: return nil
        }
    }
}

extension DocumentWindowController: NSMenuItemValidation {
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        validateViewItem(menuItem) ?? validateSidebarItem(menuItem) ?? true
    }
}

/// The window chrome zen mode hides, to restore on the way out.
struct ZenRestore {
    var outline: Bool
    var statusBarHidden: Bool
    var fullScreen: Bool
}
