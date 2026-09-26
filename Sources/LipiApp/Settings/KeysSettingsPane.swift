import AppKit

/// Settings → Keys (P0-11, §6.11): every command with its shortcut,
/// searchable; record, clear or reset a binding, reset everything, pick
/// the preset, and see conflicts and keymap.json problems. Edits are
/// written to keymap.json, which the registry reloads from.
@MainActor
public final class KeysSettingsPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    /// One table row: a command, or a fixed key that only works in a
    /// context (table cell, list item, outline) and is not rebindable in
    /// Phase 1.
    public struct Row: Equatable {
        public var id: String?
        public var title: String
        public var place: String
        public var shortcut: String
        public var overridden = false
        public var conflict = false
    }

    /// Keys the editor and outline handle themselves, shown separately
    /// (§6.11 "context-scoped bindings").
    public static let contextRows: [Row] = [
        Row(title: "Next Cell", place: "In a table", shortcut: "⇥"),
        Row(title: "Previous Cell", place: "In a table", shortcut: "⇧⇥"),
        Row(title: "Line Break in Cell", place: "In a table", shortcut: "⌥↩"),
        Row(title: "Indent Item", place: "At a list item's start", shortcut: "⇥"),
        Row(title: "Outdent Item", place: "At a list item's start", shortcut: "⇧⇥"),
        Row(title: "Hard Break", place: "In the editor", shortcut: "⇧↩"),
        Row(title: "Move Block Up / Down", place: "In the editor", shortcut: "⌥↑ ⌥↓"),
        Row(title: "Select Enclosing Block", place: "In the editor", shortcut: "⎋"),
        Row(title: "Collapse to Level", place: "In the outline", shortcut: "1 – 6"),
    ]

    /// The rows for `query` (fuzzy on title and id, or a substring of the
    /// shortcut's glyphs), commands first, then the context keys.
    public static func rows(registry: CommandRegistry, query: String, appName: String = "BareLipi") -> [Row] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let conflicting = registry.conflictingIDs
        var out: [Row] = []
        for command in registry.commands {
            let shortcut = registry.keys(for: command.id).map(\.glyphs).joined(separator: "  ")
            let title = command.title(appName: appName)
            if !q.isEmpty, FuzzyMatcher.match(q, in: title) == nil, FuzzyMatcher.match(q, in: command.id) == nil,
               !(shortcut.localizedCaseInsensitiveContains(q)) {
                continue
            }
            out.append(Row(id: command.id, title: title, place: command.path(appName: appName), shortcut: shortcut,
                           overridden: registry.isOverridden(command.id), conflict: conflicting.contains(command.id)))
        }
        out += contextRows.filter { q.isEmpty || FuzzyMatcher.match(q, in: $0.title) != nil || $0.shortcut.contains(q) }
        return out
    }

    private let registry: CommandRegistry
    private let store: KeymapStore
    private var rows: [Row] = []
    private var observer: NSObjectProtocol?
    private var monitor: Any?
    private var recordingID: String?

    private let search = NSSearchField()
    private let presetPopup = NSPopUpButton()
    private let table = NSTableView()
    private let recordButton = NSButton(title: "Record Shortcut", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    private let resetAllButton = NSButton(title: "Reset All", target: nil, action: nil)
    private let openFileButton = NSButton(title: "Open keymap.json", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")

    public init(registry: CommandRegistry = .shared, store: KeymapStore = .shared) {
        self.registry = registry
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = "Keys"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 520))

        let presetLabel = NSTextField(labelWithString: "Preset:")
        presetPopup.addItems(withTitles: Keymap.presetNames)
        presetPopup.target = self
        presetPopup.action = #selector(choosePreset(_:))
        search.placeholderString = "Search commands or shortcuts"
        search.delegate = self
        search.target = self
        search.action = #selector(searchChanged(_:))
        let top = NSStackView(views: [presetLabel, presetPopup, NSView(), search])
        top.orientation = .horizontal
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        for (id, title, width) in [("title", "Command", 230.0), ("place", "Menu", 170.0), ("shortcut", "Shortcut", 140.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.target = self
        table.doubleAction = #selector(record(_:))
        table.setAccessibilityLabel("Commands and shortcuts")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        for (button, action) in [(recordButton, #selector(record(_:))), (clearButton, #selector(clearBinding(_:))),
                                 (resetButton, #selector(resetBinding(_:))), (resetAllButton, #selector(resetAll(_:))),
                                 (openFileButton, #selector(openKeymapFile(_:)))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        let buttons = NSStackView(views: [recordButton, clearButton, resetButton, NSView(), resetAllButton, openFileButton])
        buttons.orientation = .horizontal
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.isSelectable = true

        let stack = NSStackView(views: [top, scroll, buttons, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])
        view = root

        observer = NotificationCenter.default.addObserver(forName: .commandBindingsDidChange, object: registry, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    // MARK: Table

    private func reload() {
        let selected = selectedRow?.id
        rows = Self.rows(registry: registry, query: search.stringValue)
        table.reloadData()
        if let selected, let n = rows.firstIndex(where: { $0.id == selected }) {
            table.selectRowIndexes([n], byExtendingSelection: false)
        }
        presetPopup.selectItem(withTitle: registry.keymap.preset)
        let problems = KeymapStore.problemLines(of: registry)
        status.stringValue = recordingID != nil
            ? "Type the new shortcut. Esc cancels; Delete removes the shortcut."
            : problems.isEmpty ? "Bindings are saved to \(store.url.path)." : problems.joined(separator: "\n")
        status.textColor = problems.isEmpty || recordingID != nil ? .secondaryLabelColor : .systemRed
        updateButtons()
    }

    private var selectedRow: Row? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }

    private func updateButtons() {
        let id = selectedRow?.id
        recordButton.isEnabled = id != nil
        recordButton.title = recordingID != nil ? "Cancel" : "Record Shortcut"
        clearButton.isEnabled = id.map { !registry.keys(for: $0).isEmpty } ?? false
        resetButton.isEnabled = id.map { registry.isOverridden($0) } ?? false
        resetAllButton.isEnabled = !registry.keymap.overrides.isEmpty
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "title": text = item.title
        case "place": text = item.place
        default: text = recordingID != nil && recordingID == item.id ? "Type shortcut…" : item.shortcut
        }
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        if item.id == nil { field.textColor = .secondaryLabelColor }
        if tableColumn?.identifier.rawValue == "shortcut" {
            if item.overridden { field.font = .boldSystemFont(ofSize: NSFont.systemFontSize) }
            if item.conflict {
                field.textColor = .systemRed
                field.toolTip = conflictText(for: item.id)
                field.setAccessibilityValueDescription("conflicts with another command")
            }
        }
        return field
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        if recordingID != nil { stopRecording() }
        updateButtons()
    }

    private func conflictText(for id: String?) -> String? {
        guard let id else { return nil }
        let others = registry.conflicts.filter { $0.ids.contains(id) }.flatMap { c in
            c.ids.filter { $0 != id }.map { "\(c.chord.glyphs) is also \(registry[$0]?.title(appName: "BareLipi") ?? $0)" }
        }
        return others.joined(separator: "\n")
    }

    // MARK: Actions

    @objc private func searchChanged(_ sender: Any?) { reload() }
    public func controlTextDidChange(_ obj: Notification) { reload() }

    @objc private func choosePreset(_ sender: NSPopUpButton) {
        guard let name = sender.titleOfSelectedItem, name != registry.keymap.preset else { return }
        var keymap = registry.keymap
        keymap.preset = name
        save(keymap)
    }

    @objc private func record(_ sender: Any?) {
        if recordingID != nil { stopRecording(); return }
        guard let id = selectedRow?.id else { return }
        recordingID = id
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let key = event
            let swallow = MainActor.assumeIsolated { self?.recorded(key) ?? false }
            return swallow ? nil : event
        }
        reload()
    }

    /// Takes the next key-down while recording: Esc cancels, Delete
    /// clears, a chord with Command, Control or Option (or a function key)
    /// is bound; anything else beeps. True when the event is consumed.
    private func recorded(_ event: NSEvent) -> Bool {
        guard let id = recordingID else { return false }
        let mods = event.modifierFlags.intersection(KeyChord.relevantModifiers)
        if mods.isEmpty, event.keyCode == 53 { stopRecording(); return true }
        if mods.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
            stopRecording()
            bind(id, [])
            return true
        }
        guard let chord = KeyChord(event: event), !chord.modifiers.intersection([.command, .control, .option]).isEmpty || chord.isFunctionKey else {
            NSSound.beep()
            return true
        }
        stopRecording()
        bind(id, [chord])
        return true
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingID = nil
        reload()
    }

    @objc private func clearBinding(_ sender: Any?) {
        guard let id = selectedRow?.id else { return }
        bind(id, [])
    }

    @objc private func resetBinding(_ sender: Any?) {
        guard let id = selectedRow?.id else { return }
        var keymap = registry.keymap
        keymap.overrides[id] = nil
        save(keymap)
    }

    @objc private func resetAll(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Reset all shortcuts to the \(registry.keymap.preset) preset?"
        alert.addButton(withTitle: "Reset All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var keymap = registry.keymap
        keymap.overrides = [:]
        save(keymap)
    }

    @objc private func openKeymapFile(_ sender: Any?) {
        if !FileManager.default.fileExists(atPath: store.url.path) { save(registry.keymap) }
        NSWorkspace.shared.open(store.url)
    }

    private func bind(_ id: String, _ keys: [KeyChord]) {
        save(registry.keymap.binding(id, to: keys, defaults: registry.defaultBindings))
    }

    private func save(_ keymap: Keymap) {
        do {
            try store.save(keymap, to: registry)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
