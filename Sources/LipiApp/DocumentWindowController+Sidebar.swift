import AppKit

/// Window-level commands added with the command registry (P0-11).
extension DocumentWindowController {
    /// Cmd-Shift-L (Appendix B): hides every sidebar pane, or shows the
    /// outline again. Phase 1 has one pane (the outline); the file tree and
    /// backlinks (Cmd-Ctrl-1, Cmd-Ctrl-3) arrive with workspaces in Phase 2.
    @objc public func toggleSidebarPanes(_ sender: Any?) {
        setOutlineVisible(!isOutlineVisible, focus: false)
    }

    /// Cmd-Shift-W: closes the window with all of its tabs, each asking to
    /// save as usual.
    @objc public func closeWindowAndTabs(_ sender: Any?) {
        guard let window else { return }
        for tab in window.tabbedWindows ?? [window] { tab.performClose(sender) }
    }

    func validateSidebarItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(toggleSidebarPanes(_:)):
            item.title = isOutlineVisible ? "Hide Sidebar" : "Show Sidebar"
            return true
        default: return nil
        }
    }
}
