import AppKit
import LipiCore
import LipiEditor

/// The outline pane (§6.8): the document's headings in an `NSOutlineView`,
/// indented by level (a skipped level leaves a visible gap), the heading
/// holding the caret selected, click to jump, drag to reorder sections,
/// a context menu to promote, demote and copy a heading link, digits 1–6
/// to collapse to a level and a filter field.
@MainActor
public final class OutlineSidebar: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    final class Row: NSObject {
        let index: Int
        init(_ index: Int) { self.index = index }
    }

    private weak var controller: EditorController?
    /// Called to put the caret on a heading and scroll it to the top third.
    var jump: ((Int) -> Void)?
    /// Called when the pane wants focus back in the editor (Esc).
    var returnFocus: (() -> Void)?

    public private(set) var outline = Outline()
    /// Task progress per item: (done, total) over the item's section.
    public private(set) var tasks: [(done: Int, total: Int)] = []
    /// Headings deeper than this are hidden (collapse to level); 6 shows all.
    public var maxLevel = 6 { didSet { if maxLevel != oldValue { reloadRows() } } }
    public var filter = "" { didSet { if filter != oldValue { reloadRows() } } }

    let outlineView = FocusingOutlineView()
    let filterField = NSSearchField()
    private let scroll = NSScrollView()
    private var rows: [Row] = []
    private var scheduled = false
    private var textDirty = true
    private var selecting = false
    private static let dragType = NSPasteboard.PasteboardType("com.barelipi.outline-row")

    init(controller: EditorController) {
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        let column = NSTableColumn(identifier: .init("heading"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.indentationPerLevel = 0
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(clicked(_:))
        outlineView.registerForDraggedTypes([OutlineSidebar.dragType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.sidebar = self
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu
        outlineView.setAccessibilityLabel("Outline")
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        filterField.placeholderString = "Filter Headings"
        filterField.delegate = self
        filterField.controlSize = .small
        filterField.sendsSearchStringImmediately = true
        filterField.target = self
        filterField.action = #selector(filterChanged(_:))
        addSubview(filterField)
        addSubview(scroll)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Outline")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        filterField.frame = NSRect(x: 8, y: 8, width: max(0, bounds.width - 16), height: 22)
        scroll.frame = NSRect(x: 0, y: 36, width: bounds.width, height: max(0, bounds.height - 36))
    }

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    // MARK: Model

    func setNeedsUpdate(textChanged: Bool) {
        if textChanged { textDirty = true }
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in self?.update() }
    }

    /// Rebuilds after an edit and selects the heading holding the caret.
    public func update() {
        scheduled = false
        guard let controller else { return }
        if textDirty {
            textDirty = false
            let changed = outline.update(index: controller.blockIndex, rope: controller.rope)
            tasks = OutlineSidebar.taskCounts(outline, index: controller.blockIndex)
            if changed { reloadRows() } else { outlineView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<rows.count), columnIndexes: [0]) }
        }
        selectCurrent()
    }

    /// Visible item indexes, in order.
    public var visibleItems: [Int] { rows.map(\.index) }

    private func reloadRows() {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        rows = outline.items.indices.filter { k in
            let item = outline.items[k]
            if !needle.isEmpty { return item.title.localizedCaseInsensitiveContains(needle) }
            return item.level <= maxLevel
        }.map(Row.init)
        outlineView.reloadData()
        selectCurrent()
    }

    private func selectCurrent() {
        guard let controller else { return }
        var current = outline.current(at: controller.selection.head)
        // A hidden heading highlights its nearest visible ancestor.
        while let c = current, !rows.contains(where: { $0.index == c }) {
            current = (0..<c).last { outline.items[$0].level < outline.items[c].level }
        }
        let row = current.flatMap { c in rows.firstIndex { $0.index == c } }
        selecting = true
        if let row {
            if outlineView.selectedRow != row {
                outlineView.selectRowIndexes([row], byExtendingSelection: false)
                outlineView.scrollRowToVisible(row)
            }
        } else {
            outlineView.deselectAll(nil)
        }
        selecting = false
    }

    static func taskCounts(_ outline: Outline, index: BlockIndex) -> [(done: Int, total: Int)] {
        var out = Array(repeating: (done: 0, total: 0), count: outline.items.count)
        guard !out.isEmpty else { return out }
        var k = -1
        var chain: [Int] = []
        for i in 0..<index.count {
            let start = index.start(of: i)
            while k + 1 < outline.items.count, outline.items[k + 1].section.lowerBound <= start {
                k += 1
                while let last = chain.last, outline.items[last].level >= outline.items[k].level { chain.removeLast() }
                chain.append(k)
            }
            guard k >= 0 else { continue }
            var done = 0, total = 0
            index.entries[i].block.forEachBlock { b in
                if case .listItem(let task?) = b.kind {
                    total += 1
                    if task == .checked { done += 1 }
                }
            }
            guard total > 0 else { continue }
            for c in chain {
                out[c].done += done
                out[c].total += total
            }
        }
        return out
    }

    // MARK: Data source

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { item == nil ? rows.count : 0 }
    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { rows[index] }
    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let row = item as? Row, outline.items.indices.contains(row.index) else { return nil }
        let heading = outline.items[row.index]
        let id = NSUserInterfaceItemIdentifier("heading")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? HeadingCell ?? HeadingCell(identifier: id)
        let task = row.index < tasks.count ? tasks[row.index] : (0, 0)
        cell.configure(title: heading.title.isEmpty ? "Untitled" : heading.title, level: heading.level,
                       progress: task.1 > 0 ? "\(task.0) of \(task.1)" : nil)
        return cell
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {}

    @objc private func clicked(_ sender: Any?) {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard rows.indices.contains(row) else { return }
        jump?(rows[row].index)
    }

    /// Enter in the list jumps to the selected heading.
    func activateSelection() {
        let row = outlineView.selectedRow
        guard rows.indices.contains(row) else { return }
        jump?(rows[row].index)
    }

    // MARK: Drag to reorder

    public func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let row = item as? Row, filter.isEmpty else { return nil }
        let pb = NSPasteboardItem()
        pb.setString(String(row.index), forType: OutlineSidebar.dragType)
        return pb
    }

    public func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                            proposedChildIndex index: Int) -> NSDragOperation {
        guard item == nil, index != NSOutlineViewDropOnItemIndex, dragged(info) != nil else { return [] }
        return .move
    }

    public func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let k = dragged(info), let controller else { return false }
        let target = index < rows.count ? rows[index].index : nil
        return controller.moveSection(outline, k, before: target)
    }

    private func dragged(_ info: NSDraggingInfo) -> Int? {
        guard (info.draggingSource as? NSOutlineView) === outlineView,
              let s = info.draggingPasteboard.string(forType: OutlineSidebar.dragType), let k = Int(s),
              outline.items.indices.contains(k) else { return nil }
        return k
    }

    // MARK: Context menu

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard rows.indices.contains(row) else { return }
        let k = rows[row].index
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = k
            menu.addItem(item)
        }
        add("Promote", #selector(promote(_:)))
        add("Demote", #selector(demote(_:)))
        add("Promote with Subsections", #selector(promoteSection(_:)))
        add("Demote with Subsections", #selector(demoteSection(_:)))
        menu.addItem(.separator())
        add("Copy Link to Heading", #selector(copyLink(_:)))
    }

    @objc func promote(_ sender: NSMenuItem) { controller?.shiftSection(outline, sender.tag, by: -1) }
    @objc func demote(_ sender: NSMenuItem) { controller?.shiftSection(outline, sender.tag, by: 1) }
    @objc func promoteSection(_ sender: NSMenuItem) { controller?.shiftSection(outline, sender.tag, by: -1, subsections: true) }
    @objc func demoteSection(_ sender: NSMenuItem) { controller?.shiftSection(outline, sender.tag, by: 1, subsections: true) }

    @objc func copyLink(_ sender: NSMenuItem) {
        guard outline.items.indices.contains(sender.tag) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("#" + outline.items[sender.tag].slug, forType: .string)
    }

    // MARK: Filter

    @objc private func filterChanged(_ sender: NSSearchField) { filter = sender.stringValue }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            if !filterField.stringValue.isEmpty {
                filterField.stringValue = ""
                filter = ""
            } else {
                returnFocus?()
            }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if let first = rows.first { jump?(first.index) }
            return true
        case #selector(NSResponder.moveDown(_:)):
            window?.makeFirstResponder(outlineView)
            return true
        default:
            return false
        }
    }
}

/// The list: digits collapse to a level, Enter jumps, Esc returns to the editor.
@MainActor
final class FocusingOutlineView: NSOutlineView {
    weak var sidebar: OutlineSidebar?

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        if mods.isEmpty, let chars = event.charactersIgnoringModifiers, let digit = Int(chars), (0...6).contains(digit) {
            sidebar?.maxLevel = digit == 0 ? 6 : digit
            return
        }
        switch event.keyCode {
        case 36, 76: sidebar?.activateSelection()
        case 53: sidebar?.returnFocus?()
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
final class HeadingCell: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let progress = NSTextField(labelWithString: "")
    private var leading: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progress.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        progress.textColor = .secondaryLabelColor
        progress.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        addSubview(progress)
        textField = title
        leading = title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        NSLayoutConstraint.activate([
            leading,
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            progress.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            progress.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title text: String, level: Int, progress p: String?) {
        title.stringValue = text
        title.font = level == 1 ? .boldSystemFont(ofSize: NSFont.systemFontSize) : .systemFont(ofSize: NSFont.systemFontSize)
        // Indent by the heading's own level, so H1 → H3 shows a gap.
        leading.constant = 4 + CGFloat(level - 1) * 12
        progress.stringValue = p ?? ""
        progress.isHidden = p == nil
        setAccessibilityLabel(p.map { "\(text), heading level \(level), \($0) tasks done" } ?? "\(text), heading level \(level)")
    }
}
