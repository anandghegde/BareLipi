import AppKit
import LipiEditor

/// The outline sidebar (§6.8) in a document window.
extension DocumentWindowController {
    /// The window's outline pane, made on first use.
    public var outlineSidebar: OutlineSidebar {
        if let pane = chrome.sidebar as? OutlineSidebar { return pane }
        let pane = OutlineSidebar(controller: controller)
        pane.isHidden = true
        pane.jump = { [weak self] k in self?.jumpToHeading(k) }
        pane.returnFocus = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.editor)
        }
        chrome.sidebar = pane
        return pane
    }

    public var isOutlineVisible: Bool { (chrome.sidebar as? OutlineSidebar).map { !$0.isHidden } ?? false }

    public func setOutlineVisible(_ visible: Bool, focus: Bool) {
        let pane = outlineSidebar
        pane.isHidden = !visible
        chrome.needsLayout = true
        chrome.layoutSubtreeIfNeeded()
        if visible {
            pane.setNeedsUpdate(textChanged: true)
            pane.update()
            if focus { window?.makeFirstResponder(pane.outlineView) }
        } else if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: pane) {
            window?.makeFirstResponder(editor)
        }
        onScroll?()
    }

    /// Cmd-Ctrl-2: shows the outline with the list focused (digits then
    /// collapse to a level); again focuses the filter field; again hides it.
    @objc public func toggleOutline(_ sender: Any?) {
        guard isOutlineVisible else {
            setOutlineVisible(true, focus: true)
            return
        }
        let pane = outlineSidebar
        if window?.firstResponder === pane.outlineView {
            window?.makeFirstResponder(pane.filterField)
        } else {
            setOutlineVisible(false, focus: false)
        }
    }

    /// Puts the caret at heading `k`'s start and scrolls it to the top third.
    public func jumpToHeading(_ k: Int) {
        let items = outlineSidebar.outline.items
        guard items.indices.contains(k) else { return }
        let start = items[k].range.lowerBound
        controller.moveCaret(to: start)
        let y = controller.caretRect(forSource: start).minY
        scroll(toY: max(0, y - scrollView.contentView.bounds.height / 3))
        window?.makeFirstResponder(editor)
    }
}
