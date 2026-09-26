import LipiCore

/// Table editing (§6.1.5 Tables): cell navigation, row creation, header
/// completion, `<br>` and `\|` inside cells. Every command is an `EditPlan`:
/// one undo step, bytes outside the edit unchanged, the document's line
/// terminator on inserted rows, the container prefix (quote markers, list
/// indentation) repeated on them.
extension MarkdownCommands {
    /// Where the caret is in a table: the table block (absolute ranges), the
    /// row index among header and body rows, and the column.
    struct TableContext {
        var table: Block
        var row: Int
        var column: Int
        var rows: [Block] { table.children }
        var columns: Int {
            if case .table(let a) = table.kind { return max(1, a.count) }
            return 1
        }
    }

    /// The table cell around `p`, or nil outside table rows (the delimiter
    /// row and the container prefix are outside).
    func tableContext(at p: Int) -> TableContext? {
        let path = doc.path(at: p)
        guard let t = path.lastIndex(where: { if case .table = $0.kind { return true } else { return false } }),
              t + 1 < path.count, case .tableRow = path[t + 1].kind,
              let r = path[t].children.firstIndex(where: { $0.id == path[t + 1].id }) else { return nil }
        let row = path[t].children[r]
        let cells = realCells(row)
        guard !cells.isEmpty else { return nil }
        var column = cells.lastIndex(where: { $0.range.lowerBound <= p }) ?? 0
        if column + 1 < cells.count, p > cells[column].range.upperBound,
           doc.bytes(cells[column].range.upperBound..<p).contains(0x7C) {
            column += 1
        }
        return TableContext(table: path[t], row: r, column: column)
    }

    /// Cells with source: a short row's padding cells (ghost cells, §6.1.5)
    /// are empty and sit at the row end.
    func realCells(_ row: Block) -> [Block] {
        var out: [Block] = []
        for (i, cell) in row.children.enumerated() {
            if i > 0, cell.range.isEmpty, cell.range.lowerBound >= row.range.upperBound { break }
            out.append(cell)
        }
        return out
    }

    /// Container prefix for a new row after `row`: quote markers kept, list
    /// markers and indentation as spaces.
    private func rowContinuation(_ row: Block) -> String {
        let start = doc.lineStart(row.range.lowerBound)
        return String(doc.string(start..<row.range.lowerBound).map { $0 == ">" || $0 == "\t" ? $0 : " " })
    }

    /// The caret in an empty cell: after the first space following its pipe.
    private func emptyCellCaret(_ cell: Block, rowStart: Int) -> Int {
        var p = cell.range.lowerBound
        while p > rowStart, doc.byte(p - 1) == 0x20 { p -= 1 }
        return p < cell.range.lowerBound ? p + 1 : cell.range.lowerBound
    }

    /// Moves to column `k` of `row`: selects the cell's text, or puts the
    /// caret in an empty cell. A ghost cell gets its pipes written first.
    private func cellPlan(_ row: Block, _ k: Int) -> EditPlan {
        let cells = realCells(row)
        if k < cells.count {
            let cell = cells[k]
            if cell.range.isEmpty {
                let caret = emptyCellCaret(cell, rowStart: row.range.lowerBound)
                return EditPlan(edits: [], anchor: caret, head: caret)
            }
            return EditPlan(edits: [], anchor: cell.range.lowerBound, head: cell.range.upperBound)
        }
        var b = PlanBuilder()
        let end = row.range.upperBound
        let endsWithPipe = end > row.range.lowerBound && doc.byte(end - 1) == 0x7C
            && !(end - 2 >= row.range.lowerBound && doc.byte(end - 2) == 0x5C)
        var text = endsWithPipe ? "" : " |"
        for _ in cells.count...k { text += "  |" }
        b.insert(text, at: end)
        return b.plan(caret: end + text.utf8.count - 2)
    }

    /// Appends an empty row after the table's last row, caret in column `k`.
    private func appendRow(_ ctx: TableContext, column k: Int) -> EditPlan {
        let last = ctx.rows[ctx.rows.count - 1]
        // A header-only table ends with its delimiter row, on the next line.
        let lastLine = ctx.rows.count == 1 ? doc.lineEnd(last.range.upperBound) : last.range.upperBound
        let at = doc.lineContentEnd(lastLine)
        let eol = doc.eol(near: last.range.lowerBound)
        let pre = rowContinuation(last)
        var b = PlanBuilder()
        b.insert(eol + pre + "|" + String(repeating: "  |", count: ctx.columns), at: at)
        return b.plan(caret: at + (eol + pre).utf8.count + 2 + 3 * min(k, ctx.columns - 1))
    }

    /// Tab: next cell, the first cell of the next row, or a new row after
    /// the last cell. Shift-Tab: previous cell; stays put in the first cell.
    func tableTab(backward: Bool) -> EditPlan? {
        guard let ctx = tableContext(at: selection.head) else { return nil }
        if backward {
            if ctx.column > 0 { return cellPlan(ctx.rows[ctx.row], min(ctx.column, ctx.columns) - 1) }
            if ctx.row > 0 { return cellPlan(ctx.rows[ctx.row - 1], ctx.columns - 1) }
            return EditPlan(edits: [], anchor: selection.anchor, head: selection.head)
        }
        if ctx.column + 1 < ctx.columns { return cellPlan(ctx.rows[ctx.row], ctx.column + 1) }
        if ctx.row + 1 < ctx.rows.count { return cellPlan(ctx.rows[ctx.row + 1], 0) }
        return appendRow(ctx, column: 0)
    }

    /// Enter in a table: the cell below, a new row from the last row, or
    /// (in an empty last body row) leave the table for a paragraph below.
    /// Outside a table, `| a | b |` then Enter completes a table.
    func tableNewline() -> EditPlan? {
        if let ctx = tableContext(at: selection.head) {
            let k = min(ctx.column, ctx.columns - 1)
            if ctx.row + 1 < ctx.rows.count { return cellPlan(ctx.rows[ctx.row + 1], k) }
            let row = ctx.rows[ctx.row]
            if ctx.row > 0, realCells(row).allSatisfy({ $0.range.isEmpty }) {
                var b = PlanBuilder()
                let start = doc.lineStart(row.range.lowerBound)
                let pre = rowContinuation(row)
                let blank = String(pre.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
                let text = blank + doc.eol(near: start) + pre
                b.replace(start..<doc.lineContentEnd(row.range.upperBound), text)
                return b.plan(caret: start + text.utf8.count)
            }
            return appendRow(ctx, column: k)
        }
        return completeTable()
    }

    /// `| a | b |` then Enter at the line end: the delimiter row and one
    /// empty body row, caret in the first body cell.
    private func completeTable() -> EditPlan? {
        guard settings.completeTables, range.isEmpty else { return nil }
        let c = range.lowerBound
        let line = doc.prefix(ofLineAt: c)
        guard c == line.end, line.heading == nil, line.task == nil, !doc.isCodeContext(c),
              !doc.path(at: c).contains(where: { if case .table = $0.kind { return true } else { return false } }) else { return nil }
        let content = Array(doc.bytes(line.contentStart..<line.end).reversed().drop(while: { $0 == 0x20 || $0 == 0x09 }).reversed())
        guard content.count >= 2, content.first == 0x7C, content.last == 0x7C else { return nil }
        var pipes = 0
        var i = 0
        while i < content.count {
            if content[i] == 0x5C { i += 2; continue }
            if content[i] == 0x7C { pipes += 1 }
            i += 1
        }
        // The closing pipe must not be escaped.
        guard pipes >= 2, !(content.count >= 2 && content[content.count - 2] == 0x5C) else { return nil }
        let columns = pipes - 1
        // Already followed by a delimiter row: plain Enter.
        if doc.lineEnd(c) < doc.count {
            let next = doc.prefix(ofLineAt: doc.lineEnd(c))
            let rest = doc.string(next.quoteEnd..<next.end).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty, rest.contains("-"), rest.allSatisfy({ "|-: \t".contains($0) }) { return nil }
        }
        let eol = doc.eol(near: c)
        let pre = continuation(line)
        let delimiter = "|" + String(repeating: " --- |", count: columns)
        let body = "|" + String(repeating: "  |", count: columns)
        var b = PlanBuilder()
        b.insert(eol + pre + delimiter + eol + pre + body, at: c)
        return b.plan(caret: c + (eol + pre + delimiter + eol + pre).utf8.count + 2)
    }

    /// Opt-Enter in a cell: `<br>`.
    func tableLineBreak() -> EditPlan? {
        guard tableContext(at: range.lowerBound) != nil, tableContext(at: range.upperBound) != nil else { return nil }
        var b = PlanBuilder()
        b.replace(range, "<br>")
        return b.plan(caret: range.lowerBound + 4)
    }

    /// A `|` typed in a cell is written `\|` (unless it follows a `\`).
    var escapesPipe: Bool {
        let p = range.lowerBound
        guard tableContext(at: p) != nil else { return false }
        return p == 0 || doc.byte(p - 1) != 0x5C
    }
}
