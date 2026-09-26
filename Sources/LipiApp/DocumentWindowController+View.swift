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

    public func validateViewItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(zoomIn(_:)): return controller.zoom < DocumentWindowController.zoomRange.upperBound - 0.001
        case #selector(zoomOut(_:)): return controller.zoom > DocumentWindowController.zoomRange.lowerBound + 0.001
        case #selector(resetZoom(_:)): return abs(controller.zoom - 1) > 0.001
        case #selector(toggleOutline(_:)):
            item.state = isOutlineVisible ? .on : .off
            return true
        default: return nil
        }
    }
}

extension DocumentWindowController: NSMenuItemValidation {
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        validateViewItem(menuItem) ?? true
    }
}
