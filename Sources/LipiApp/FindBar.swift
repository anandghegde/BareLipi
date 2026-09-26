import AppKit
import LipiCore
import LipiEditor

/// The in-document find bar (P0-10, ADR "FindBar: NSView with
/// NSSearchField"): docked above the editor, incremental, with the match
/// count, Enter / Shift-Enter for next and previous, Esc to close (the
/// selection stays on the current match), options for case, whole word,
/// regular expression and source or rendered text, and a replace row
/// (Cmd-Opt-F) with Replace and Replace All.
@MainActor
public final class FindBar: NSView, NSSearchFieldDelegate, NSTextFieldDelegate {
    public let session: FindSession
    public let editor: EditorView
    public let findField = NSSearchField()
    public let replaceField = NSTextField()
    public let countLabel = NSTextField(labelWithString: "")
    let caseButton = FindBar.toggle("Aa", tip: "Match Case")
    let wordButton = FindBar.toggle("W", tip: "Whole Words")
    let regexButton = FindBar.toggle(".*", tip: "Regular Expression")
    let scopePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var replaceRow: NSStackView!
    private var pendingRecount = false
    /// Called when the bar closes (Esc, Done).
    public var onClose: (() -> Void)?

    public static let rowHeight: CGFloat = 32

    public private(set) var showsReplace = false {
        didSet {
            replaceRow.isHidden = !showsReplace
            invalidateIntrinsicContentSize()
            superview?.needsLayout = true
        }
    }

    public init(editor: EditorView) {
        self.editor = editor
        if let existing = editor.findSession {
            session = existing
        } else {
            session = FindSession(controller: editor.controller)
            editor.findSession = session
        }
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: FindBar.rowHeight))
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        build()
        let previous = editor.controller.onChange
        editor.controller.onChange = { [weak self] change in
            previous?(change)
            if change.textChanged { self?.scheduleRecount() }
        }
        findField.stringValue = session.query.pattern
        caseButton.state = session.query.caseSensitive ? .on : .off
        wordButton.state = session.query.wholeWord ? .on : .off
        regexButton.state = session.query.isRegex ? .on : .off
        scopePopup.selectItem(at: session.scope == .source ? 0 : 1)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Find")
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: FindBar.rowHeight * (showsReplace ? 2 : 1))
    }

    private static func toggle(_ title: String, tip: String) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.setButtonType(.pushOnPushOff)
        b.bezelStyle = .recessed
        b.controlSize = .small
        b.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        b.toolTip = tip
        b.setAccessibilityLabel(tip)
        b.refusesFirstResponder = true
        return b
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .push
        b.controlSize = .small
        b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        b.refusesFirstResponder = true
        return b
    }

    private func build() {
        findField.placeholderString = "Find"
        findField.delegate = self
        findField.sendsSearchStringImmediately = true
        findField.controlSize = .small
        findField.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
        findField.setAccessibilityLabel("Find")
        replaceField.placeholderString = "Replace"
        replaceField.delegate = self
        replaceField.controlSize = .small
        replaceField.font = findField.font
        replaceField.setAccessibilityLabel("Replace")
        countLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        for b in [caseButton, wordButton, regexButton] {
            b.target = self
            b.action = #selector(optionsChanged(_:))
        }
        scopePopup.addItems(withTitles: ["Source", "Rendered"])
        scopePopup.controlSize = .small
        scopePopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        scopePopup.target = self
        scopePopup.action = #selector(optionsChanged(_:))
        scopePopup.toolTip = "Search the Markdown source or the rendered text"
        scopePopup.refusesFirstResponder = true

        let previous = button("‹", #selector(findPrevious(_:)))
        previous.toolTip = "Previous (Shift-Return)"
        previous.setAccessibilityLabel("Previous match")
        let next = button("›", #selector(findNext(_:)))
        next.toolTip = "Next (Return)"
        next.setAccessibilityLabel("Next match")
        let done = button("Done", #selector(close(_:)))

        let findRow = NSStackView(views: [findField, countLabel, previous, next, caseButton, wordButton, regexButton, scopePopup, done])
        findRow.spacing = 6
        findRow.setCustomSpacing(10, after: countLabel)
        findRow.setCustomSpacing(10, after: next)
        findRow.setCustomSpacing(10, after: scopePopup)
        replaceRow = NSStackView(views: [replaceField, button("Replace", #selector(replace(_:))), button("All", #selector(replaceAll(_:)))])
        replaceRow.spacing = 6
        replaceRow.isHidden = true
        let rows = NSStackView(views: [findRow, replaceRow])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4
        rows.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.topAnchor.constraint(equalTo: topAnchor),
            findRow.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -20),
            replaceRow.leadingAnchor.constraint(equalTo: findRow.leadingAnchor),
            replaceField.widthAnchor.constraint(equalTo: findField.widthAnchor),
            findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
    }

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    // MARK: Showing

    /// Opens the bar (with the replace row when `replace`), seeds the field
    /// from a one-line selection, and focuses the find field.
    public func activate(replace: Bool) {
        if replace { showsReplace = true }
        session.isActive = true
        let sel = editor.controller.selection.range
        if !sel.isEmpty, sel.count < 1000 {
            let text = editor.controller.string(in: sel)
            if !text.contains("\n") { findField.stringValue = text }
        }
        queryChanged(move: false)
        window?.makeFirstResponder(findField)
        findField.currentEditor()?.selectAll(nil)
        if replace { replaceRow.isHidden = false }
    }

    // MARK: Actions

    @objc public func findNext(_ sender: Any?) {
        session.isActive = true
        session.next()
        refresh()
    }

    @objc public func findPrevious(_ sender: Any?) {
        session.isActive = true
        session.previous()
        refresh()
    }

    @objc public func replace(_ sender: Any?) {
        session.replaceCurrent(with: replaceField.stringValue)
        refresh()
    }

    @objc public func replaceAll(_ sender: Any?) {
        let n = session.replaceAll(with: replaceField.stringValue)
        refresh()
        countLabel.stringValue = n == 1 ? "Replaced 1" : "Replaced \(n)"
    }

    /// Esc or Done: hides the bar and returns to the editor; the current
    /// match stays selected.
    @objc public func close(_ sender: Any?) {
        session.isActive = false
        editor.needsDisplay = true
        onClose?()
        editor.window?.makeFirstResponder(editor)
    }

    @objc private func optionsChanged(_ sender: Any?) { queryChanged(move: true) }

    /// Rebuilds the query from the controls; incremental search moves the
    /// selection to the first match at or after it.
    func queryChanged(move: Bool) {
        session.query = FindQuery(findField.stringValue, caseSensitive: caseButton.state == .on,
                                  wholeWord: wordButton.state == .on, isRegex: regexButton.state == .on)
        session.scope = scopePopup.indexOfSelectedItem == 1 ? .rendered : .source
        if move { session.findFromSelection() }
        refresh()
    }

    /// Updates the count ("3 of 12", "No results", "Invalid pattern") and redraws.
    public func refresh() {
        countLabel.stringValue = FindBar.status(of: session)
        editor.needsDisplay = true
    }

    /// The count text: "3 of 12", "12 matches", "No results", "Invalid pattern".
    static func status(of session: FindSession) -> String {
        guard !session.query.isEmpty else { return "" }
        let count = session.count
        if session.error != nil { return "Invalid pattern" }
        if count == 0 { return "No results" }
        if let i = session.currentIndex { return "\(i + 1) of \(count)" }
        return count == 1 ? "1 match" : "\(count) matches"
    }

    private func scheduleRecount() {
        guard session.isActive, !pendingRecount else { return }
        pendingRecount = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.pendingRecount = false
            self?.refresh()
        }
    }

    // MARK: Field delegate

    public func controlTextDidChange(_ note: Notification) {
        guard (note.object as? NSSearchField) === findField else { return }
        queryChanged(move: true)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if control === replaceField {
                replace(nil)
            } else if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                findPrevious(nil)
            } else {
                findNext(nil)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close(nil)
            return true
        default:
            return false
        }
    }
}

// MARK: - Window integration

extension DocumentWindowController {
    /// The window's find bar, while it is open.
    public var findBar: FindBar? { content.accessory as? FindBar }

    /// Opens (or focuses) the find bar.
    @discardableResult
    public func showFindBar(replace: Bool) -> FindBar {
        let bar = findBar ?? FindBar(editor: editor)
        bar.onClose = { [weak self] in self?.content.accessory = nil }
        if content.accessory !== bar { content.accessory = bar }
        bar.activate(replace: replace)
        return bar
    }

    /// Cmd-F.
    @objc public func showFind(_ sender: Any?) { showFindBar(replace: false) }
    /// Cmd-Opt-F.
    @objc public func showFindAndReplace(_ sender: Any?) { showFindBar(replace: true) }

    /// Cmd-G: works with the bar closed, using the last search.
    @objc public func findNextMatch(_ sender: Any?) {
        if let bar = findBar { bar.findNext(sender) } else { editor.findSession?.next() }
    }

    /// Cmd-Shift-G.
    @objc public func findPreviousMatch(_ sender: Any?) {
        if let bar = findBar { bar.findPrevious(sender) } else { editor.findSession?.previous() }
    }

    /// Puts the selection in the find field without opening the bar.
    @objc public func useSelectionForFind(_ sender: Any?) {
        let range = controller.selection.range
        guard !range.isEmpty else { return }
        let session = editor.findSession ?? FindSession(controller: controller)
        editor.findSession = session
        session.query.pattern = controller.string(in: range)
        findBar?.findField.stringValue = session.query.pattern
        findBar?.refresh()
    }
}
