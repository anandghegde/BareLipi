import AppKit
import LipiCore
import LipiLayout

extension NSAttributedString.Key {
    /// Heading level (1–6) of the text's block in the editor's accessibility
    /// attributed strings (§6.20); absent outside headings.
    public static let accessibilityHeadingLevel = NSAttributedString.Key("AXHeadingLevel")
    /// Set (to `true`) on inline and block code in accessibility attributed strings.
    public static let accessibilityCode = NSAttributedString.Key("AXLipiCode")
}

/// The accessibility text protocol over the projected text (§6.20).
///
/// Offsets are UTF-16 units of `AccessibilityText.string`, the document as it
/// reads folded; `NSTextInputClient` keeps speaking source UTF-16. Code
/// blocks and tables are also exposed as child elements (an `AXTextArea`
/// whose role description is the language; an `AXTable` of rows and cells).
extension EditorView {
    var accessibilityText: AccessibilityText { accessibilityModel.text(for: controller) }

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    public override func accessibilityRoleDescription() -> String? { "Markdown editor" }
    public override func accessibilityLabel() -> String? { "Document" }
    public override func accessibilityValue() -> Any? { accessibilityText.string as String }

    /// Applies the smallest edit between the projected text and `value`,
    /// mapped to source bytes; the rest of the source is untouched.
    public override func setAccessibilityValue(_ value: Any?) {
        guard let new = value as? String else { return }
        let text = accessibilityText
        guard let diff = text.difference(to: new) else { return }
        // Replacing all of the text replaces all of the source, hidden syntax included.
        let range = diff.range.length == text.length ? 0..<controller.count : text.sourceRange(for: diff.range)
        controller.replace(range, with: diff.replacement)
    }

    public override func accessibilityNumberOfCharacters() -> Int { accessibilityText.length }

    public override func accessibilitySelectedText() -> String? {
        let text = accessibilityText
        return text.string.substring(with: text.clamp(text.range(forSource: controller.selection.range)))
    }

    public override func setAccessibilitySelectedText(_ string: String?) {
        controller.replace(controller.selection.range, with: string ?? "")
    }

    public override func accessibilitySelectedTextRange() -> NSRange {
        accessibilityText.range(forSource: controller.selection.range)
    }

    public override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        let bytes = accessibilityText.sourceRange(for: range)
        if bytes.isEmpty { controller.moveCaret(to: bytes.lowerBound) } else { controller.select(bytes) }
    }

    public override func accessibilitySelectedTextRanges() -> [NSValue]? {
        [NSValue(range: accessibilitySelectedTextRange())]
    }

    public override func accessibilityString(for range: NSRange) -> String? {
        let text = accessibilityText
        return text.string.substring(with: text.clamp(range))
    }

    public override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        accessibilityAttributedText(for: range, in: accessibilityText)
    }

    public override func accessibilityFrame(for range: NSRange) -> NSRect {
        let bytes = accessibilityText.sourceRange(for: range)
        let rects = bytes.isEmpty ? [controller.caretRect(forSource: bytes.lowerBound)] : controller.rects(forSource: bytes, visible: bounds)
        guard var union = rects.first else { return screenRect(controller.caretRect(forSource: bytes.lowerBound)) }
        for rect in rects.dropFirst() { union = union.union(rect) }
        if union.width < 1 { union.size.width = 1 }
        return screenRect(union)
    }

    public override func accessibilityVisibleCharacterRange() -> NSRange {
        let text = accessibilityText
        guard let entries = visibleEntryRange, let first = text.entryUnits.indices.contains(entries.lowerBound) ? entries.lowerBound : nil
        else { return NSRange(location: 0, length: text.length) }
        let start = text.units[text.entryUnits[first]].start
        let lastEntry = min(entries.upperBound, text.entryUnits.count - 1)
        let endUnit = lastEntry + 1 < text.entryUnits.count ? text.entryUnits[lastEntry + 1] - 1 : text.units.count - 1
        let end = text.units[endUnit].start + text.units[endUnit].length
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Entries on screen (whole entries), by index.
    var visibleEntryRange: ClosedRange<Int>? {
        let visible = visibleRect.isEmpty || visibleRect.height > bounds.height ? bounds : visibleRect
        let entries = controller.projection
        guard let first = controller.sourceOffset(at: CGPoint(x: 0, y: visible.minY)).flatMap(entries.entryIndex(containing:)),
              let last = controller.sourceOffset(at: CGPoint(x: bounds.width, y: visible.maxY)).flatMap(entries.entryIndex(containing:))
        else { return nil }
        return min(first, last)...max(first, last)
    }

    public override func accessibilityInsertionPointLineNumber() -> Int {
        let text = accessibilityText
        return text.line(for: text.offset(forSource: controller.caret))
    }

    public override func accessibilityLine(for index: Int) -> Int { accessibilityText.line(for: index) }

    public override func accessibilityRange(forLine line: Int) -> NSRange {
        accessibilityText.range(forLine: line) ?? NSRange(location: NSNotFound, length: 0)
    }

    public override func accessibilityRange(for point: NSPoint) -> NSRange {
        let local = convert(window?.convertPoint(fromScreen: point) ?? point, from: nil)
        guard let offset = controller.sourceOffset(at: local) else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: accessibilityText.offset(forSource: offset), length: 0)
    }

    /// The grapheme cluster at `index` (the editor's caret stops, so Kannada
    /// conjuncts stay whole).
    public override func accessibilityRange(for index: Int) -> NSRange {
        let text = accessibilityText
        guard index >= 0, index < text.length else { return NSRange(location: NSNotFound, length: 0) }
        let unit = text.units[text.unitIndex(at: index)]
        let cellEnd = unit.start + unit.length
        guard index < cellEnd else { return NSRange(location: index, length: 1) }
        let end = text.offset(forSource: controller.nextCaretStop(after: text.sourceOffset(at: index)))
        if end > index, end <= cellEnd { return NSRange(location: index, length: end - index) }
        return text.string.rangeOfComposedCharacterSequence(at: index)
    }

    public override func accessibilityStyleRange(for index: Int) -> NSRange {
        let text = accessibilityText
        guard index >= 0, index < text.length, let p = text.position(at: index) else { return NSRange(location: NSNotFound, length: 0) }
        let unit = text.units[text.unitIndex(at: index)]
        let cell = text.projection.entries[p.entry].blocks[p.block].cells[p.cell]
        guard let run = cell.runs.first(where: { $0.range.contains(p.offset) }) else {
            return NSRange(location: index, length: 1)
        }
        return NSRange(location: unit.start + run.range.lowerBound, length: run.range.count)
    }

    // MARK: Attributes

    /// Attributes for `range`: font traits (heading, strong, emphasis,
    /// code), links, strikethrough, heading level and misspellings.
    func accessibilityAttributedText(for range: NSRange, in text: AccessibilityText) -> NSAttributedString {
        let range = text.clamp(range)
        let out = NSMutableAttributedString(string: text.string.substring(with: range))
        guard range.length > 0 else { return out }
        let base = controller.typesetter.scale
        var u = text.unitIndex(at: range.location)
        while u < text.units.count, text.units[u].start < range.upperBound {
            let unit = text.units[u]
            u += 1
            let entry = text.projection.entries[unit.entry]
            let block = entry.blocks[unit.block]
            let cell = block.cells[unit.cell]
            let cellRange = NSRange(location: unit.start, length: unit.length)
            guard let shown = cellRange.intersection(range), shown.length > 0 || unit.length == 0 else { continue }
            let local = NSRange(location: shown.location - range.location, length: shown.length)
            let role: TextRole
            var heading: Int? = nil
            switch block.role {
            case .heading(let level): role = .heading(level); heading = level
            case .code, .frontMatter: role = .codeBlock
            case .table: role = block.table.map { $0.position(ofCell: unit.cell).row == 0 } == true ? .tableHeader : .tableCell
            default: role = .body
            }
            let style = base.style(for: role)
            if local.length > 0 {
                out.addAttribute(.accessibilityFont, value: Self.fontAttributes(style: style, inline: []), range: local)
                if let heading { out.addAttribute(.accessibilityHeadingLevel, value: heading, range: local) }
                if case .code = block.role { out.addAttribute(.accessibilityCode, value: true, range: local) }
            }
            for run in cell.runs {
                let r = NSRange(location: unit.start + run.range.lowerBound, length: run.range.count)
                guard let hit = r.intersection(range), hit.length > 0 else { continue }
                let l = NSRange(location: hit.location - range.location, length: hit.length)
                let inline = run.style
                if !inline.intersection([.strong, .emphasis, .code]).isEmpty {
                    let s = inline.contains(.code) ? base.style(for: .inlineCode) : style
                    out.addAttribute(.accessibilityFont, value: Self.fontAttributes(style: s, inline: inline), range: l)
                }
                if inline.contains(.code) { out.addAttribute(.accessibilityCode, value: true, range: l) }
                if inline.contains(.strikethrough) { out.addAttribute(.accessibilityStrikethrough, value: true, range: l) }
                if inline.contains(.link) || inline.contains(.footnoteReference) {
                    let source = entry.start + cell.sourceOffset(forDisplay: run.range.lowerBound)
                    if let url = linkURL(at: source) { out.addAttribute(.accessibilityLink, value: url, range: l) }
                }
            }
        }
        if let misspelled = misspelledRanges {
            for bad in misspelled(text.sourceRange(for: range)) {
                let r = text.range(forSource: bad)
                guard let hit = r.intersection(range), hit.length > 0 else { continue }
                let l = NSRange(location: hit.location - range.location, length: hit.length)
                out.addAttribute(.accessibilityMisspelled, value: true, range: l)
                out.addAttribute(.accessibilityMarkedMisspelled, value: true, range: l)
            }
        }
        return out
    }

    /// `AXFont` dictionary for a text style with inline traits.
    static func fontAttributes(style: TextStyle, inline: InlineStyle) -> [NSAccessibility.FontAttributeKey: Any] {
        var font: NSFont = style.family == .mono || inline.contains(.code)
            ? .monospacedSystemFont(ofSize: style.size, weight: .regular)
            : .systemFont(ofSize: style.size, weight: style.weight == .regular ? .regular : .semibold)
        if inline.contains(.strong) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if inline.contains(.emphasis) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return [.fontName: font.fontName, .fontFamily: font.familyName ?? font.fontName,
                .visibleName: font.displayName ?? font.fontName, .fontSize: style.size]
    }

    /// Destination of the link (or footnote reference) whose source span
    /// holds `offset`, as a URL.
    func linkURL(at offset: Int) -> URL? {
        let index = controller.blockIndex
        guard let e = index.entryIndex(containing: offset) else { return nil }
        let base = index.start(of: e)
        let local = offset - base
        var found: URL? = nil
        index.entries[e].block.forEachBlock { b in
            guard found == nil, b.range.contains(local) || b.range.upperBound == local else { return }
            for inline in b.inlines {
                inline.forEachInline { x in
                    guard found == nil, x.range.contains(local) else { return }
                    switch x.kind {
                    case .link(let destination, _, _):
                        found = URL(string: destination) ?? URL(string: destination.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "")
                    case .footnoteReference(let label):
                        found = URL(string: "#fn-" + (label.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? label))
                    default:
                        break
                    }
                }
            }
        }
        return found
    }

    // MARK: Islands (code blocks and tables)

    public override func accessibilityChildren() -> [Any]? {
        accessibilityIslands()
    }

    /// Child elements for the code blocks and tables of the entries on
    /// screen (or of every entry when `all` is set: tests).
    public func accessibilityIslands(all: Bool = false) -> [NSAccessibilityElement] {
        guard controller.engine == .lipi else { return [] }
        let projection = controller.projection
        guard !projection.entries.isEmpty else { return [] }
        let range: ClosedRange<Int>
        if all {
            range = 0...(projection.entries.count - 1)
        } else {
            guard let visible = visibleEntryRange else { return [] }
            range = visible
        }
        let text = accessibilityText
        var out: [NSAccessibilityElement] = []
        for e in range where e < projection.entries.count {
            for (b, block) in projection.entries[e].blocks.enumerated() {
                switch block.role {
                case .code(let info, _):
                    let language = info.split(separator: " ").first.map(String.init) ?? ""
                    let value = cellText(entry: e, block: b, cell: 0, in: text) ?? block.cells.first?.text ?? ""
                    out.append(CodeIslandElement(view: self, position: DisplayPosition(entry: e, block: b, cell: 0, offset: 0),
                                                 language: language, value: value))
                case .table:
                    guard let shape = block.table else { continue }
                    let cells = (0..<block.cells.count).map { cellText(entry: e, block: b, cell: $0, in: text) ?? block.cells[$0].text }
                    out.append(TableIslandElement(view: self, entry: e, block: b, shape: shape, cells: cells))
                default:
                    break
                }
            }
        }
        return out
    }

    /// Folded text of a live display cell (the live cell may show syntax).
    private func cellText(entry: Int, block: Int, cell: Int, in text: AccessibilityText) -> String? {
        guard entry < text.projection.entries.count, block < text.projection.entries[entry].blocks.count,
              cell < text.projection.entries[entry].blocks[block].cells.count else { return nil }
        return text.projection.entries[entry].blocks[block].cells[cell].text
    }

    /// Screen frame of a live display cell.
    func accessibilityFrame(ofCell position: DisplayPosition) -> NSRect {
        guard position.entry < controller.projection.entries.count else { return .zero }
        return screenRect(controller.layout.cellFrame(at: position))
    }

    // MARK: Notifications

    /// Tells assistive apps that the text or the selection changed.
    func postAccessibilityChange(textChanged: Bool) {
        NSAccessibility.post(element: self, notification: textChanged ? .valueChanged : .selectedTextChanged)
    }
}

/// A fenced or indented code block: an `AXTextArea` whose role description
/// is the language (§6.5).
final class CodeIslandElement: NSAccessibilityElement {
    private weak var view: EditorView?
    let position: DisplayPosition
    let language: String

    @MainActor
    init(view: EditorView, position: DisplayPosition, language: String, value: String) {
        self.view = view
        self.position = position
        self.language = language
        super.init()
        setAccessibilityParent(view)
        setAccessibilityRole(.textArea)
        setAccessibilityRoleDescription(language.isEmpty ? "code block" : language)
        setAccessibilityLabel(language.isEmpty ? "Code block" : "Code block, \(language)")
        setAccessibilityValue(value)
        setAccessibilityNumberOfCharacters((value as NSString).length)
    }

    override func accessibilityFrame() -> NSRect {
        guard let view else { return .zero }
        let p = position
        return MainActor.assumeIsolated { view.accessibilityFrame(ofCell: p) }
    }

    override func isAccessibilityElement() -> Bool { true }
}

/// A table (§6.3): `AXTable` → `AXRow` → `AXCell`, the header row first.
final class TableIslandElement: NSAccessibilityElement {
    private weak var view: EditorView?
    let entry: Int
    let block: Int
    let shape: TableShape
    let cellTexts: [String]
    private var rowElements: [TableRowElement]?

    @MainActor
    init(view: EditorView, entry: Int, block: Int, shape: TableShape, cells: [String]) {
        self.view = view
        self.entry = entry
        self.block = block
        self.shape = shape
        cellTexts = cells
        super.init()
        setAccessibilityParent(view)
        setAccessibilityRole(.table)
        setAccessibilityLabel("Table, \(shape.rows) rows, \(shape.columns) columns")
        setAccessibilityRowCount(shape.rows)
        setAccessibilityColumnCount(shape.columns)
    }

    override func isAccessibilityElement() -> Bool { true }

    var rows: [TableRowElement] {
        if let rowElements { return rowElements }
        let made = (0..<shape.rows).map { TableRowElement(table: self, row: $0) }
        rowElements = made
        return made
    }

    override func accessibilityChildren() -> [Any]? { rows }
    override func accessibilityRows() -> [Any]? { rows }
    override func accessibilityVisibleRows() -> [Any]? { rows }
    override func accessibilityHeader() -> Any? { rows.first }
    override func accessibilityColumnHeaderUIElements() -> [Any]? { rows.first?.cells }

    func text(row: Int, column: Int) -> String {
        let i = shape.cellIndex(row: row, column: column)
        return i < cellTexts.count ? cellTexts[i] : ""
    }

    func frame(ofCell index: Int) -> NSRect {
        guard let view else { return .zero }
        let p = DisplayPosition(entry: entry, block: block, cell: index, offset: 0)
        return MainActor.assumeIsolated { view.accessibilityFrame(ofCell: p) }
    }

    override func accessibilityFrame() -> NSRect {
        let first = frame(ofCell: 0)
        let last = frame(ofCell: max(0, min(cellTexts.count, shape.rows * shape.columns) - 1))
        return first.union(last)
    }
}

final class TableRowElement: NSAccessibilityElement {
    private weak var table: TableIslandElement?
    let row: Int
    private(set) lazy var cells: [TableCellElement] = {
        guard let table else { return [] }
        return (0..<table.shape.columns).map { TableCellElement(table: table, row: self, column: $0) }
    }()

    init(table: TableIslandElement, row: Int) {
        self.table = table
        self.row = row
        super.init()
        setAccessibilityParent(table)
        setAccessibilityRole(.row)
        setAccessibilityIndex(row)
        setAccessibilityLabel(row == 0 ? "Header row" : "Row \(row)")
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityChildren() -> [Any]? { cells }

    override func accessibilityFrame() -> NSRect {
        guard let table else { return .zero }
        let first = table.shape.cellIndex(row: row, column: 0)
        return table.frame(ofCell: first).union(table.frame(ofCell: first + table.shape.columns - 1))
    }
}

final class TableCellElement: NSAccessibilityElement {
    private weak var table: TableIslandElement?
    let row: Int
    let column: Int

    init(table: TableIslandElement, row: TableRowElement, column: Int) {
        self.table = table
        self.row = row.row
        self.column = column
        super.init()
        setAccessibilityParent(row)
        setAccessibilityRole(.cell)
        setAccessibilityRowIndexRange(NSRange(location: row.row, length: 1))
        setAccessibilityColumnIndexRange(NSRange(location: column, length: 1))
        let text = table.text(row: row.row, column: column)
        setAccessibilityValue(text)
        let header = table.text(row: 0, column: column)
        setAccessibilityLabel(row.row == 0 || header.isEmpty ? text : "\(header): \(text)")
    }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityFrame() -> NSRect {
        table?.frame(ofCell: table?.shape.cellIndex(row: row, column: column) ?? 0) ?? .zero
    }
}
