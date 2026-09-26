import AppKit
import LipiCore
import LipiEditor

// MARK: - Fuzzy matching

/// Subsequence fuzzy matching for Quick Open (P0-10). Case-insensitive;
/// rewards matches at word starts (after `/`, `-`, `_`, `.`, space, or a
/// lower-to-upper case change), consecutive runs and matches inside the
/// last path component; penalises gaps.
public enum FuzzyMatcher {
    public struct Match: Sendable, Equatable {
        public var score: Int
        /// Matched character offsets in the candidate.
        public var positions: [Int]
    }

    public static func match(_ query: String, in candidate: String) -> Match? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return Match(score: 0, positions: []) }
        let chars = Array(candidate)
        let lower = chars.map { Character($0.lowercased()) }
        // Try the last path component first: a hit there beats one spread
        // over directories.
        let baseStart = (chars.lastIndex(of: "/") ?? -1) + 1
        if let m = greedy(q, chars, lower, from: baseStart) {
            return Match(score: m.score + 10 + (m.positions.first == baseStart ? 5 : 0), positions: m.positions)
        }
        return greedy(q, chars, lower, from: 0)
    }

    private static func greedy(_ q: [Character], _ chars: [Character], _ lower: [Character], from start: Int) -> Match? {
        var positions: [Int] = []
        var score = 0
        var qi = 0
        var i = start
        var previous = -2
        while qi < q.count, i < chars.count {
            if lower[i] == q[qi] {
                // Prefer a word-start occurrence of this character if one
                // comes before the next query character's first hit.
                var pick = i
                if !isWordStart(i, chars), previous != i - 1 {
                    var j = i + 1
                    let limit = qi + 1 < q.count ? (lower[(i + 1)...].firstIndex(of: q[qi + 1]) ?? chars.count) : chars.count
                    while j < min(limit, chars.count) {
                        if lower[j] == q[qi], isWordStart(j, chars) { pick = j; break }
                        j += 1
                    }
                }
                score += 1
                if isWordStart(pick, chars) { score += 8 }
                if pick == previous + 1 { score += 5 } else if previous >= 0 { score -= min(pick - previous - 1, 5) }
                if chars[pick] == q[qi] { score += 1 }  // exact case
                positions.append(pick)
                previous = pick
                qi += 1
                i = pick + 1
            } else {
                i += 1
            }
        }
        guard qi == q.count else { return nil }
        // Shorter candidates rank higher among equals.
        score -= min(chars.count / 16, 4)
        return Match(score: score, positions: positions)
    }

    private static func isWordStart(_ i: Int, _ chars: [Character]) -> Bool {
        guard i > 0 else { return true }
        let p = chars[i - 1], c = chars[i]
        if "/-_. ".contains(p) { return true }
        return p.isLowercase && c.isUppercase
    }
}

// MARK: - Model

/// One Quick Open row.
public struct QuickOpenItem: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case file(URL)
        /// A heading in an open document: the document's file (nil when
        /// untitled), the window's number and the heading's source offset.
        case heading(document: URL?, window: Int, offset: Int, level: Int)
        /// A menu command, by the path of titles to its item.
        case command(path: [String])
    }

    public var kind: Kind
    public var title: String
    public var subtitle: String
    public var isOpen: Bool
    /// 0 for the most recent document; nil for never-opened files.
    public var recency: Int?

    public init(kind: Kind, title: String, subtitle: String, isOpen: Bool = false, recency: Int? = nil) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.isOpen = isOpen
        self.recency = recency
    }
}

/// Quick Open's candidates and ranking. One field: files by fuzzy path,
/// `#` for headings, `>` for commands. Ranked by fuzzy score, then open
/// state and recency.
///
/// Phase 1 has no workspace (P0-09 is Phase 2), so "files" means open
/// documents, recent documents and the Markdown files in the open
/// documents' folders; headings come from open documents.
public struct QuickOpenModel: Sendable {
    public var files: [QuickOpenItem]
    public var headings: [QuickOpenItem]
    public var commands: [QuickOpenItem]
    public var limit = 200

    public init(files: [QuickOpenItem] = [], headings: [QuickOpenItem] = [], commands: [QuickOpenItem] = []) {
        self.files = files
        self.headings = headings
        self.commands = commands
    }

    public func results(for input: String) -> [QuickOpenItem] {
        var query = input
        let pool: [QuickOpenItem]
        var matchSubtitle = true
        if query.hasPrefix("#") {
            pool = headings
            query.removeFirst()
            matchSubtitle = false
        } else if query.hasPrefix(">") {
            pool = commands
            query.removeFirst()
            matchSubtitle = false
        } else {
            pool = files
        }
        query = query.trimmingCharacters(in: .whitespaces)
        var scored: [(item: QuickOpenItem, score: Int, order: Int)] = []
        for (order, item) in pool.enumerated() {
            let haystack = matchSubtitle ? item.subtitle : item.title
            guard let m = FuzzyMatcher.match(query, in: haystack) ?? (matchSubtitle ? nil : FuzzyMatcher.match(query, in: item.subtitle).map {
                FuzzyMatcher.Match(score: $0.score - 10, positions: $0.positions)
            }) else { continue }
            var score = m.score
            if item.isOpen { score += 6 }
            if let r = item.recency { score += max(0, 12 - r) }
            scored.append((item, score, order))
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
        return scored.prefix(limit).map(\.item)
    }

    // MARK: Gathering

    /// Markdown files under `folder`, at most `depth` levels down and
    /// `limit` files, skipping hidden folders and package dependencies.
    public static func markdownFiles(in folder: URL, depth: Int = 3, limit: Int = 2000) -> [URL] {
        let skip: Set<String> = ["node_modules", ".git", "build", "DerivedData", ".build", "Pods"]
        let extensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx", "txt"]
        var out: [URL] = []
        var queue: [(URL, Int)] = [(folder, 0)]
        let fm = FileManager.default
        while !queue.isEmpty, out.count < limit {
            let (dir, level) = queue.removeFirst()
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    if level < depth, !skip.contains(url.lastPathComponent) { queue.append((url, level + 1)) }
                } else if extensions.contains(url.pathExtension.lowercased()) {
                    out.append(url)
                    if out.count >= limit { break }
                }
            }
        }
        return out
    }

    /// The display path of `url`: relative to `base` when inside it, else
    /// with the home folder as `~`.
    public static func displayPath(_ url: URL, base: URL?) -> String {
        let path = url.standardizedFileURL.path
        if let base {
            let prefix = base.standardizedFileURL.path + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Headings of a projection, as items.
    @MainActor
    public static func headings(of controller: EditorController, document: URL?, window: Int, name: String) -> [QuickOpenItem] {
        var out: [QuickOpenItem] = []
        for entry in controller.projection.entries {
            for block in entry.blocks {
                guard case .heading(let level) = block.role else { continue }
                var text = block.cells.first?.text ?? ""
                text = String(text.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                out.append(QuickOpenItem(kind: .heading(document: document, window: window, offset: entry.start + block.sourceRange.lowerBound, level: level),
                                         title: String(repeating: "  ", count: max(0, level - 1)) + text,
                                         subtitle: name, isOpen: true))
            }
        }
        return out
    }

    /// Every enabled leaf item of `menu`, as a command.
    @MainActor
    public static func commands(in menu: NSMenu, path: [String] = [], enabledOnly: Bool = true) -> [QuickOpenItem] {
        var out: [QuickOpenItem] = []
        menu.update()
        for item in menu.items where !item.isSeparatorItem && !item.isHidden {
            let here = path + [item.title]
            if let sub = item.submenu {
                if sub === NSApp.servicesMenu || item.title == "Open Recent" { continue }
                out += commands(in: sub, path: here, enabledOnly: enabledOnly)
            } else if item.action != nil, item.isEnabled || !enabledOnly {
                var key = item.keyEquivalent.uppercased()
                if !key.isEmpty {
                    let m = item.keyEquivalentModifierMask
                    key = (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "") + (m.contains(.shift) ? "⇧" : "")
                        + (m.contains(.command) ? "⌘" : "") + (key == "\r" ? "↩" : key)
                }
                out.append(QuickOpenItem(kind: .command(path: here), title: item.title,
                                         subtitle: (path.dropFirst().isEmpty ? path : Array(path.dropFirst())).joined(separator: " › ")
                                            + (key.isEmpty ? "" : "   " + key)))
            }
        }
        return out
    }
}

// MARK: - Panel

/// The Quick Open palette (Cmd-P): an `NSPanel` with a search field over
/// an `NSTableView`. Enter opens, Cmd-Enter opens in a new tab, Opt-Enter
/// reveals the file in the Finder (the workspace tree is Phase 2), Esc closes.
@MainActor
public final class QuickOpenPanel: NSPanel, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    public private(set) var model: QuickOpenModel
    public private(set) var results: [QuickOpenItem] = []
    public let field = NSSearchField()
    public let table = NSTableView()
    /// Runs the chosen row; `newTab` for Cmd-Enter, `reveal` for Opt-Enter.
    public var onChoose: ((QuickOpenItem, _ newTab: Bool, _ reveal: Bool) -> Void)?

    public init(model: QuickOpenModel) {
        self.model = model
        super.init(contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
                   styleMask: [.titled, .fullSizeContentView, .utilityWindow], backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isFloatingPanel = true
        hidesOnDeactivate = true
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = false
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        build()
        rerank()
    }

    public override var canBecomeKey: Bool { true }

    private func build() {
        field.placeholderString = "Open file, # heading, > command"
        field.delegate = self
        field.font = .systemFont(ofSize: 17)
        field.focusRingType = .none
        field.setAccessibilityLabel("Quick Open")
        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 36
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(chooseClicked(_:))
        table.refusesFirstResponder = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let stack = NSStackView(views: [field, scroll])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        contentView = content
    }

    /// Re-ranks for the field's text and selects the first row.
    public func rerank() {
        results = model.results(for: field.stringValue)
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    public func setQuery(_ text: String) {
        field.stringValue = text
        rerank()
    }

    /// Shows the panel centred on `window`, near its top.
    public func show(over window: NSWindow?) {
        if let frame = window?.frame {
            setFrameOrigin(NSPoint(x: frame.midX - self.frame.width / 2, y: frame.maxY - self.frame.height - 80))
        } else {
            center()
        }
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
    }

    public override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }

    public override func cancelOperation(_ sender: Any?) { orderOut(nil) }

    /// Runs the selected row.
    public func choose(newTab: Bool = false, reveal: Bool = false) {
        let row = table.selectedRow
        guard row >= 0, row < results.count else { return }
        let item = results[row]
        orderOut(nil)
        onChoose?(item, newTab, reveal)
    }

    @objc private func chooseClicked(_ sender: Any?) { choose() }

    // MARK: Field

    public func controlTextDidChange(_ obj: Notification) { rerank() }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1); return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            choose(newTab: flags.contains(.command), reveal: flags.contains(.option))
            return true
        case #selector(NSResponder.cancelOperation(_:)): orderOut(nil); return true
        default: return false
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        let row = max(0, min(results.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    // MARK: Table

    public func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = results[row]
        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 13, weight: item.isOpen ? .semibold : .regular)
        title.lineBreakMode = .byTruncatingTail
        let subtitle = NSTextField(labelWithString: item.subtitle)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        return stack
    }
}

// MARK: - Controller

/// Gathers candidates and runs choices (the document controller's Cmd-P).
@MainActor
public enum QuickOpen {
    static var panel: QuickOpenPanel?

    /// Candidates from the running app.
    public static func model(documents: [NSDocument], recents: [URL], mainMenu: NSMenu?) -> QuickOpenModel {
        var files: [QuickOpenItem] = []
        var seen = Set<String>()
        let openURLs = documents.compactMap(\.fileURL).map(\.standardizedFileURL)
        let base = openURLs.first?.deletingLastPathComponent()
        func add(_ url: URL, recency: Int?) {
            let key = url.standardizedFileURL.path
            guard seen.insert(key).inserted else { return }
            let isOpen = openURLs.contains(url.standardizedFileURL)
            files.append(QuickOpenItem(kind: .file(url), title: url.lastPathComponent,
                                       subtitle: QuickOpenModel.displayPath(url, base: base), isOpen: isOpen, recency: recency))
        }
        for url in openURLs { add(url, recency: recents.firstIndex(of: url)) }
        for (i, url) in recents.enumerated() { add(url, recency: i) }
        var folders: [URL] = []
        for url in openURLs {
            let dir = url.deletingLastPathComponent()
            if !folders.contains(dir) { folders.append(dir) }
        }
        for dir in folders.prefix(4) {
            for url in QuickOpenModel.markdownFiles(in: dir) { add(url, recency: nil) }
        }
        var headings: [QuickOpenItem] = []
        for document in documents {
            guard let doc = document as? LipiDocument, let wc = doc.windowController else { continue }
            headings += QuickOpenModel.headings(of: wc.controller, document: doc.fileURL, window: wc.window?.windowNumber ?? 0,
                                                name: doc.displayName)
        }
        let commands = mainMenu.map { QuickOpenModel.commands(in: $0) } ?? []
        return QuickOpenModel(files: files, headings: headings, commands: commands)
    }

    /// Shows the palette over the key window.
    public static func show(prefix: String = "") {
        let target = NSApp.keyWindow ?? NSApp.mainWindow
        let controller = NSDocumentController.shared
        let model = model(documents: controller.documents, recents: controller.recentDocumentURLs, mainMenu: NSApp.mainMenu)
        let panel = QuickOpenPanel(model: model)
        panel.onChoose = { item, newTab, reveal in run(item, newTab: newTab, reveal: reveal, from: target) }
        self.panel = panel
        panel.setQuery(prefix)
        panel.show(over: target)
    }

    static func run(_ item: QuickOpenItem, newTab: Bool, reveal: Bool, from window: NSWindow?) {
        switch item.kind {
        case .file(let url):
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]); return }
            if newTab { window?.tabbingMode = .preferred }
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        case .heading(_, let number, let offset, _):
            guard let target = NSApp.window(withWindowNumber: number),
                  let wc = target.windowController as? DocumentWindowController else { return }
            target.makeKeyAndOrderFront(nil)
            wc.controller.moveCaret(to: offset)
            target.makeFirstResponder(wc.editor)
        case .command(let path):
            window?.makeKeyAndOrderFront(nil)
            guard let item = menuItem(at: path, in: NSApp.mainMenu), let action = item.action else { return }
            NSApp.sendAction(action, to: item.target, from: item)
        }
    }

    static func menuItem(at path: [String], in menu: NSMenu?) -> NSMenuItem? {
        var menu = menu
        var found: NSMenuItem?
        for title in path {
            found = menu?.items.first { $0.title == title }
            menu = found?.submenu
        }
        return found
    }
}

extension LipiDocumentController {
    /// Cmd-P: Quick Open.
    @objc public func showQuickOpen(_ sender: Any?) { QuickOpen.show() }
}
