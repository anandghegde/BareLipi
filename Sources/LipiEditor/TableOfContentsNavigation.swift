import AppKit
import LipiCore

/// Clicking a line of a live `[toc]` block jumps to its heading (§6.13).
extension EditorController {
    /// The heading shown on the `[toc]` line at `point`, if any.
    public func tableOfContentsItem(at point: CGPoint) -> TableOfContents.Item? {
        guard engine == .lipi, mode != .source, let toc = projection.tableOfContents,
              let position = layout.position(at: point), projection.entries.indices.contains(position.entry) else { return nil }
        let entry = projection.entries[position.entry]
        guard entry.blocks.indices.contains(position.block) else { return nil }
        let block = entry.blocks[position.block]
        guard block.context.isTableOfContents, block.cells.indices.contains(position.cell) else { return nil }
        return Self.tocItem(in: block.cells[position.cell].text, utf16Offset: position.offset, toc: toc)
    }

    /// Line `k` of the block's text is item `k`.
    static func tocItem(in text: String, utf16Offset: Int, toc: TableOfContents) -> TableOfContents.Item? {
        var line = 0
        for (i, unit) in text.utf16.enumerated() {
            if i >= utf16Offset { break }
            if unit == 0x0A { line += 1 }
        }
        return toc.items.indices.contains(line) ? toc.items[line] : nil
    }

    /// Moves the caret to the heading at `point` in a `[toc]` block.
    @discardableResult
    public func jumpToTableOfContentsItem(at point: CGPoint) -> Bool {
        guard let item = tableOfContentsItem(at: point) else { return false }
        if marked != nil { _ = unmarkText() }
        moveCaret(to: item.offset)
        return true
    }
}
