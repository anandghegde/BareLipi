import AppKit
import LipiCore

/// The ADR-002 comparison engine: the same projected, typeset text laid out
/// by a headless `NSTextLayoutManager` over an `NSTextContentStorage`, no
/// `NSTextView`. Entries become paragraphs separated by newlines; a table's
/// cells are joined by tabs (TextKit 2 has no table layout of its own).
@MainActor
public final class TextKit2Layout {
    public let contentStorage: NSTextContentStorage
    public let layoutManager: NSTextLayoutManager
    public let container: NSTextContainer

    struct CellStart {
        var block: Int
        var cell: Int
        var start: Int
    }

    /// UTF-16 range of each entry in the document (without its separator).
    public private(set) var entryRanges: [Range<Int>] = []
    private var cellStarts: [[CellStart]] = []

    public init(width: CGFloat) {
        contentStorage = NSTextContentStorage()
        layoutManager = NSTextLayoutManager()
        container = NSTextContainer(size: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.textContainer = container
        contentStorage.addTextLayoutManager(layoutManager)
        contentStorage.primaryTextLayoutManager = layoutManager
    }

    public var textStorage: NSTextStorage { contentStorage.textStorage! }
    public var length: Int { textStorage.length }

    // MARK: Building

    func attributed(_ entry: ProjectedEntry, typesetter: Typesetter) -> (NSAttributedString, [CellStart]) {
        let result = NSMutableAttributedString()
        var starts: [CellStart] = []
        for (b, block) in entry.blocks.enumerated() {
            if b > 0 { result.append(NSAttributedString(string: "\n", attributes: lastAttributes(of: result))) }
            let style = typesetter.scale.style(for: typesetter.role(of: block, cellIndex: 0))
            for (c, cell) in block.cells.enumerated() {
                if c > 0, let table = block.table {
                    let separator = table.position(ofCell: c).column == 0 ? "\n" : "\t"
                    result.append(NSAttributedString(string: separator, attributes: lastAttributes(of: result)))
                }
                let typeset = typesetter.typeset(cell, in: block, cellIndex: c)
                starts.append(CellStart(block: b, cell: c, start: result.length))
                let piece = NSMutableAttributedString(attributedString: typeset.attributed)
                // Paragraph spacing lives in the paragraph style here.
                let whole = NSRange(location: 0, length: piece.length)
                if whole.length > 0, let ps = piece.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
                   let mutable = ps.mutableCopy() as? NSMutableParagraphStyle {
                    mutable.paragraphSpacing = style.spacingAfter
                    mutable.paragraphSpacingBefore = style.spacingBefore
                    mutable.headIndent = LayoutEngine.indent(for: block.context, scale: typesetter.scale)
                    mutable.firstLineHeadIndent = mutable.headIndent
                    piece.addAttribute(.paragraphStyle, value: mutable, range: whole)
                }
                result.append(piece)
            }
        }
        if result.length == 0 {
            result.append(typesetter.attributedString(" ", role: .body))
            result.deleteCharacters(in: NSRange(location: 0, length: 1))
        }
        return (result, starts)
    }

    private func lastAttributes(of string: NSAttributedString) -> [NSAttributedString.Key: Any] {
        guard string.length > 0 else { return [:] }
        return string.attributes(at: string.length - 1, effectiveRange: nil)
    }

    /// Replaces the whole document with `projection`.
    public func load(_ projection: Projection, typesetter: Typesetter) {
        let document = NSMutableAttributedString()
        entryRanges = []
        cellStarts = []
        for (i, entry) in projection.entries.enumerated() {
            if i > 0 { document.append(NSAttributedString(string: "\n", attributes: lastAttributes(of: document))) }
            let (piece, starts) = attributed(entry, typesetter: typesetter)
            entryRanges.append(document.length..<(document.length + piece.length))
            cellStarts.append(starts)
            document.append(piece)
        }
        contentStorage.performEditingTransaction {
            textStorage.setAttributedString(document)
        }
    }

    /// Replaces one entry's text (the §7.4 incremental edit).
    public func replaceEntry(_ i: Int, with entry: ProjectedEntry, typesetter: Typesetter) {
        let (piece, starts) = attributed(entry, typesetter: typesetter)
        let old = entryRanges[i]
        contentStorage.performEditingTransaction {
            textStorage.replaceCharacters(in: NSRange(location: old.lowerBound, length: old.count), with: piece)
        }
        let delta = piece.length - old.count
        entryRanges[i] = old.lowerBound..<(old.lowerBound + piece.length)
        cellStarts[i] = starts
        if delta != 0 {
            for j in (i + 1)..<entryRanges.count {
                entryRanges[j] = (entryRanges[j].lowerBound + delta)..<(entryRanges[j].upperBound + delta)
            }
        }
    }

    // MARK: Layout

    public func ensureLayout(toY y: CGFloat) {
        layoutManager.ensureLayout(for: CGRect(x: 0, y: 0, width: container.size.width, height: y))
    }

    public func ensureLayoutToEnd() {
        layoutManager.ensureLayout(for: contentStorage.documentRange)
    }

    public var usedHeight: CGFloat { layoutManager.usageBoundsForTextContainer.height }

    // MARK: Positions

    public func location(atOffset offset: Int) -> NSTextLocation {
        contentStorage.location(contentStorage.documentRange.location, offsetBy: offset)!
    }

    public func offset(of location: NSTextLocation) -> Int {
        contentStorage.offset(from: contentStorage.documentRange.location, to: location)
    }

    public func documentOffset(of position: DisplayPosition) -> Int {
        let starts = cellStarts[position.entry]
        let start = starts.first { $0.block == position.block && $0.cell == position.cell }?.start ?? 0
        return entryRanges[position.entry].lowerBound + start + position.offset
    }

    /// Caret frame at a document offset (`enumerateTextSegments` with an
    /// empty range and upstream affinity, the TextKit 2 idiom).
    public func caretRect(forDocumentOffset offset: Int) -> CGRect? {
        let location = self.location(atOffset: offset)
        guard let range = NSTextRange(location: location, end: location) else { return nil }
        var result: CGRect? = nil
        layoutManager.enumerateTextSegments(in: range, type: .standard, options: [.rangeNotRequired, .upstreamAffinity]) { _, frame, _, _ in
            result = frame
            return false
        }
        return result
    }

    /// Document offset nearest `point`.
    public func documentOffset(at point: CGPoint) -> Int? {
        guard let fragment = layoutManager.textLayoutFragment(for: point) else { return nil }
        let local = CGPoint(x: point.x - fragment.layoutFragmentFrame.minX, y: point.y - fragment.layoutFragmentFrame.minY)
        var chosen: NSTextLineFragment? = fragment.textLineFragments.last
        for line in fragment.textLineFragments where local.y < line.typographicBounds.maxY {
            chosen = line
            break
        }
        guard let line = chosen else { return nil }
        let index = line.characterIndex(for: CGPoint(x: local.x - line.typographicBounds.minX, y: local.y))
        let elementStart = offset(of: fragment.rangeInElement.location)
        return elementStart + max(0, index)
    }

    // MARK: Drawing

    public func draw(in ctx: CGContext, rect: CGRect) {
        guard let first = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: rect.minY)) else { return }
        layoutManager.enumerateTextLayoutFragments(from: first.rangeInElement.location, options: [.ensuresLayout]) { fragment in
            if fragment.layoutFragmentFrame.minY > rect.maxY { return false }
            fragment.draw(at: fragment.layoutFragmentFrame.origin, in: ctx)
            return true
        }
    }
}
