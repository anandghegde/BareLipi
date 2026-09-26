import LipiCore

/// Block selection (§6.1.4): `Esc` selects the block around the caret as
/// one unit, repeated `Esc` selects the enclosing block. In that state
/// `Delete` removes the block's lines, `Cmd-Shift-D` duplicates it and
/// `Opt-Up`/`Opt-Down` move it past the adjacent sibling.
extension MarkdownCommands {
    /// A block's selectable source: from its first byte to the end of its
    /// last line's content.
    func blockRange(_ b: Block) -> Range<Int> {
        b.range.lowerBound..<max(b.range.upperBound, doc.lineContentEnd(b.range.upperBound))
    }

    /// Blocks around `p` that can be selected, innermost first; table rows
    /// and cells are part of their table, a list item's only paragraph is
    /// the item, and a block with the same range as its child is skipped.
    func selectableBlocks(at p: Int) -> [Block] {
        var out: [Block] = []
        let path = doc.path(at: p)
        for (k, b) in path.enumerated().reversed() {
            switch b.kind {
            case .tableRow, .tableCell: continue
            case .paragraph:
                // A tight item's only paragraph is the item.
                if k > 0, case .listItem = path[k - 1].kind, path[k - 1].children.count == 1 { continue }
            default: break
            }
            if let last = out.last, blockRange(last) == blockRange(b) { continue }
            out.append(b)
        }
        return out
    }

    /// The range `Esc` selects: the innermost block holding the selection,
    /// or the parent of the block selection `current`.
    func expandBlockSelection(from current: Range<Int>?) -> Range<Int>? {
        let p = current?.lowerBound ?? range.lowerBound
        let ranges = selectableBlocks(at: p).map(blockRange)
        guard !ranges.isEmpty else { return nil }
        if let current, let i = ranges.firstIndex(of: current) {
            return i + 1 < ranges.count ? ranges[i + 1] : current
        }
        return ranges.first { $0.lowerBound <= range.lowerBound && range.upperBound <= $0.upperBound } ?? ranges.last
    }

    private func isBlankLine(_ p: Int) -> Bool {
        doc.string(doc.lineStart(p)..<doc.lineContentEnd(p)).allSatisfy { $0 == " " || $0 == "\t" || $0 == ">" }
    }

    /// Removes a selected block: whole lines when nothing but container
    /// markers precede it on its first line, one blank separator with it.
    func deleteBlock(_ r: Range<Int>) -> EditPlan {
        var b = PlanBuilder()
        let start = doc.lineStart(r.lowerBound)
        guard doc.string(start..<r.lowerBound).allSatisfy({ $0 == " " || $0 == "\t" || $0 == ">" }) else {
            b.replace(r, "")
            return b.plan(caret: r.lowerBound)
        }
        var lo = start
        var hi = doc.lineEnd(r.upperBound)
        if hi == doc.lineContentEnd(r.upperBound) {
            // Last line of the document: take the terminator before it, and
            // a blank line before that.
            if lo > 0 {
                lo = doc.lineContentEnd(lo - 1)
                if doc.lineStart(lo) > 0, isBlankLine(lo) { lo = doc.lineContentEnd(doc.lineStart(lo) - 1) }
            }
        } else if lo > 0, isBlankLine(lo - 1), hi == doc.count || isBlankLine(hi) {
            // Keep one blank separator, not two (or a trailing one).
            if hi == doc.count { lo = doc.lineStart(lo - 1) } else { hi = doc.lineEnd(hi) }
        } else if lo == 0, hi < doc.count, isBlankLine(hi) {
            hi = doc.lineEnd(hi)
        }
        b.replace(lo..<hi, "")
        return b.plan(caret: lo)
    }

    /// Inserts a copy of the selected block after it and selects the copy.
    func duplicateBlock(_ r: Range<Int>) -> EditPlan? {
        guard let block = selectableBlocks(at: r.lowerBound).first(where: { blockRange($0) == r }) else { return nil }
        let start = doc.lineStart(r.lowerBound)
        let lead = String(doc.string(start..<r.lowerBound).map { $0 == ">" || $0 == "\t" ? $0 : " " })
        let eol = doc.eol(near: r.lowerBound)
        var separator = eol
        if case .listItem = block.kind {} else {
            separator += String(lead.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed()) + eol
        }
        let text = doc.string(r)
        var b = PlanBuilder()
        b.insert(separator + lead + text, at: r.upperBound)
        let copy = r.upperBound + (separator + lead).utf8.count
        return EditPlan(edits: b.edits, anchor: copy, head: copy + text.utf8.count)
    }

    /// Swaps the selected block with its previous (`up`) or next sibling
    /// and keeps it selected.
    func moveBlock(_ r: Range<Int>, up: Bool) -> EditPlan? {
        let path = doc.path(at: r.lowerBound)
        guard let k = path.lastIndex(where: { blockRange($0) == r }) else { return nil }
        let siblings: [Block]
        if k == 0 {
            guard let i = doc.index.entryIndex(containing: r.lowerBound) else { return nil }
            let j = up ? i - 1 : i + 1
            guard j >= 0, j < doc.index.count else { return nil }
            siblings = [doc.index.absoluteBlock(at: j)]
        } else {
            let children = path[k - 1].children
            guard let i = children.firstIndex(where: { $0.id == path[k].id }) else { return nil }
            let j = up ? i - 1 : i + 1
            guard j >= 0, j < children.count else { return nil }
            siblings = [children[j]]
        }
        let other = blockRange(siblings[0])
        switch siblings[0].kind {
        case .frontMatter: return nil
        default: break
        }
        let (a, bRange) = up ? (other, r) : (r, other)
        guard a.upperBound <= bRange.lowerBound else { return nil }
        let textA = doc.string(a), textB = doc.string(bRange), middle = doc.string(a.upperBound..<bRange.lowerBound)
        var b = PlanBuilder()
        b.replace(a.lowerBound..<bRange.upperBound, textB + middle + textA)
        let start = up ? a.lowerBound : a.lowerBound + (textB + middle).utf8.count
        let length = r.count
        return EditPlan(edits: b.edits, anchor: start, head: start + length)
    }
}
