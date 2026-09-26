import AppKit

/// The Cmd-K link popover (§6.1.5): an `NSPopover` with text, URL and
/// title fields. Return commits, Esc cancels, focus stays in the popover
/// until it closes (§6.11). AppKit only, like the rest of the app (no
/// SwiftUI at launch).
@MainActor
final class LinkPopover: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    let form: LinkFormController
    private var onClose: (() -> Void)?

    init(draft: LinkDraft, animates: Bool, commit: @escaping (LinkDraft) -> Void, onClose: @escaping () -> Void) {
        self.onClose = onClose
        form = LinkFormController(draft: draft)
        super.init()
        popover.behavior = .transient
        popover.animates = animates
        popover.delegate = self
        form.onCommit = { [weak self] d in
            commit(d)
            self?.popover.performClose(nil)
        }
        form.onCancel = { [weak self] in self?.popover.performClose(nil) }
        popover.contentViewController = form
    }

    func show(relativeTo rect: NSRect, of view: NSView) {
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    func close() { popover.performClose(nil) }

    func popoverDidShow(_ notification: Notification) {
        form.focusFirstField()
    }

    func popoverDidClose(_ notification: Notification) {
        let done = onClose
        onClose = nil
        done?()
    }
}

/// The popover's form: three labelled fields and Remove / Cancel /
/// Insert (Update) buttons. `draft` reads the fields back into the draft
/// the popover was opened with (its range and `isExisting` unchanged).
@MainActor
public final class LinkFormController: NSViewController, NSTextFieldDelegate {
    private let initial: LinkDraft
    public let labelField = NSTextField()
    public let urlField = NSTextField()
    public let titleField = NSTextField()
    public var onCommit: ((LinkDraft) -> Void)?
    public var onCancel: (() -> Void)?

    public init(draft: LinkDraft) {
        initial = draft
        super.init(nibName: nil, bundle: nil)
        labelField.stringValue = draft.label
        urlField.stringValue = draft.destination
        titleField.stringValue = draft.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public var draft: LinkDraft {
        var d = initial
        d.label = labelField.stringValue
        d.destination = urlField.stringValue
        d.title = titleField.stringValue
        return d
    }

    public override func loadView() {
        func row(_ name: String, _ field: NSTextField, placeholder: String?) -> [NSView] {
            let label = NSTextField(labelWithString: name + ":")
            label.alignment = .right
            field.placeholderString = placeholder
            field.setAccessibilityLabel(name)
            field.delegate = self
            field.lineBreakMode = .byTruncatingTail
            field.cell?.isScrollable = true
            field.cell?.wraps = false
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
            return [label, field]
        }
        let grid = NSGridView(views: [
            row("Text", labelField, placeholder: nil),
            row("URL", urlField, placeholder: "https://"),
            row("Title", titleField, placeholder: "Optional"),
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing

        var buttons: [NSView] = []
        if initial.isExisting {
            let remove = NSButton(title: "Remove Link", target: self, action: #selector(removeLink(_:)))
            remove.bezelStyle = .push
            buttons.append(remove)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        buttons.append(spacer)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let commit = NSButton(title: initial.isExisting ? "Update" : "Insert", target: self, action: #selector(commit(_:)))
        commit.keyEquivalent = "\r"
        buttons += [cancel, commit]
        let buttonRow = NSStackView(views: buttons)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let stack = NSStackView(views: [grid, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        stack.addConstraint(buttonRow.widthAnchor.constraint(equalTo: grid.widthAnchor))
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.group)
        stack.setAccessibilityLabel(initial.isExisting ? "Edit Link" : "Insert Link")
        view = stack
    }

    /// The text field when it is empty, otherwise the URL.
    func focusFirstField() {
        let field = initial.label.isEmpty ? labelField : urlField
        view.window?.makeFirstResponder(field)
    }

    @objc public func commit(_ sender: Any?) { onCommit?(draft) }

    @objc public func cancel(_ sender: Any?) { onCancel?() }

    /// Commits the draft with an empty destination, which unlinks it.
    @objc public func removeLink(_ sender: Any?) {
        var d = draft
        d.destination = ""
        onCommit?(d)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commit(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel(nil)
            return true
        default:
            return false
        }
    }
}
