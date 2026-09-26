import AppKit
import LipiCore

/// The note of a footnote reference, shown on hover or Cmd-Opt-Down
/// (§6.13). Read-only text; it never takes focus from the editor.
@MainActor
final class FootnotePopover: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    let reference: FootnoteReferenceHit
    let text: String
    private var onClose: (() -> Void)?

    init(reference: FootnoteReferenceHit, text: String, animates: Bool, onClose: @escaping () -> Void) {
        self.reference = reference
        self.text = text
        self.onClose = onClose
        super.init()
        popover.behavior = .transient
        popover.animates = animates
        popover.delegate = self
        let heading = reference.number.map { "Footnote \($0)" } ?? "Footnote [\(reference.label)]"
        let field = NSTextField(wrappingLabelWithString: text.isEmpty ? "(empty)" : text)
        field.isSelectable = false
        field.preferredMaxLayoutWidth = 340
        field.setAccessibilityLabel(heading)
        let title = NSTextField(labelWithString: heading)
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        title.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        let controller = NSViewController()
        controller.view = stack
        popover.contentViewController = controller
    }

    func show(relativeTo rect: NSRect, of view: NSView) {
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    func close() { popover.performClose(nil) }

    func popoverDidClose(_ notification: Notification) {
        let done = onClose
        onClose = nil
        done?()
    }
}

extension EditorView {
    /// Cmd-Opt-Down: shows the note of the footnote reference at the caret.
    @objc public func showFootnote(_ sender: Any?) {
        guard let ref = controller.footnoteReferenceAtCaret() else { NSSound.beep(); return }
        footnoteState.hovering = false
        presentFootnote(ref)
    }

    /// The text of the footnote popover on screen (or that would be, when
    /// the view has no window).
    public var shownFootnoteText: String? { footnoteState.shown?.text }

    func presentFootnote(_ ref: FootnoteReferenceHit) {
        if let shown = footnoteState.shown, shown.reference == ref { return }
        closeFootnote()
        let text = controller.footnoteText(label: ref.label) ?? "No definition for [^\(ref.label)]."
        let popover = FootnotePopover(reference: ref, text: text, animates: displayOptions.duration(0.2) > 0) { [weak self] in
            guard let self, self.footnoteState.shown?.reference == ref else { return }
            self.footnoteState.shown = nil
        }
        footnoteState.shown = popover
        guard window != nil else { return }
        let rects = controller.rects(forSource: ref.range, visible: visibleRect)
        var anchor = rects.reduce(CGRect.null) { $0.union($1) }
        if anchor.isNull { anchor = controller.caretRect(forSource: ref.range.upperBound) }
        popover.show(relativeTo: anchor.insetBy(dx: 0, dy: -2), of: self)
    }

    func closeFootnote() {
        footnoteState.pending?.cancel()
        footnoteState.pending = nil
        let shown = footnoteState.shown
        footnoteState.shown = nil
        shown?.close()
    }

    /// A click on a rendered reference jumps to its note; one on a note's
    /// `↩` returns to the first reference. Returns whether it was either.
    func handleFootnoteClick(at point: CGPoint) -> Bool {
        if let ref = controller.footnoteReference(at: point) {
            closeFootnote()
            return controller.jumpToFootnoteDefinition(label: ref.label)
        }
        if let def = controller.footnoteReturnLink(at: point) {
            closeFootnote()
            return controller.returnToFootnoteReference(label: def.label)
        }
        return false
    }

    /// Hovering a reference shows its note after a short dwell; leaving it
    /// closes a note shown by hovering.
    func footnoteHover(at point: CGPoint) {
        let ref = controller.footnoteReference(at: point)
        if let ref {
            if footnoteState.shown?.reference == ref || footnoteState.pendingRef == ref { return }
            footnoteState.pending?.cancel()
            footnoteState.pendingRef = ref
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.footnoteState.pendingRef == ref else { return }
                    self.footnoteState.pending = nil
                    self.footnoteState.pendingRef = nil
                    self.footnoteState.hovering = true
                    self.presentFootnote(ref)
                }
            }
            footnoteState.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        } else {
            footnoteState.pending?.cancel()
            footnoteState.pending = nil
            footnoteState.pendingRef = nil
            if footnoteState.hovering, footnoteState.shown != nil { closeFootnote() }
            footnoteState.hovering = false
        }
    }
}

/// The editor's footnote popover and hover state.
@MainActor
final class FootnoteViewState {
    var shown: FootnotePopover?
    var pending: DispatchWorkItem?
    var pendingRef: FootnoteReferenceHit?
    /// The shown popover came from hovering (so leaving closes it).
    var hovering = false
}
