import Foundation
import LipiCore
import LipiFixtures
import LipiLayout
import Testing

@Suite("Table island")
struct TableLayoutTests {
    let typesetter = makeTypesetter()

    @Test func smallTableGeometry() {
        let block = layoutBlock("| Name | Qty | Note |\n| --- | ---: | --- |\n| apple | 3 | crisp |\n| banana | 12 | soft |\n", measure: 480)
        let table = block.table!
        #expect(table.columns == 3 && table.rows == 3)
        #expect(block.cells.count == 9 && block.cellFrames.count == 9)
        #expect(table.columnWidths.count == 3 && table.rowHeights.count == 3)
        // Every row is one line of 22 pt plus 6 pt padding above and below.
        for h in table.rowHeights { #expect(abs(h - 34) < 0.001, "row height \(h)") }
        #expect(block.height == table.height + typesetter.scale.paragraphSpacing)
        #expect(table.width <= 480 + 0.5)
        // Cell frames sit inside their columns and rows.
        for (i, frame) in block.cellFrames.enumerated() {
            let (r, c) = table.position(ofCell: i)
            #expect(frame.minX >= table.columnX(c) - 0.01 && frame.maxX <= table.columnX(c + 1) + 0.01)
            #expect(frame.minY >= table.rowY(r) - 0.01 && frame.maxY <= table.rowY(r + 1) + 0.01)
        }
        // Right-aligned numbers end at the same x.
        let qty3 = block.cells[table.cellIndex(row: 1, column: 1)].lines[0]
        let qty12 = block.cells[table.cellIndex(row: 2, column: 1)].lines[0]
        #expect(approximately(qty3.x + qty3.width, qty12.x + qty12.width, within: 0.5))
        #expect(qty3.x > qty12.x)
    }

    @Test func longCellsWrapAndTheTableFitsTheWidth() {
        let long = (0..<30).map { "w\($0)" }.joined(separator: " ")
        let block = layoutBlock("| a | b |\n| --- | --- |\n| \(long) | \(long) |\n", measure: 400, wideWidth: 400)
        let table = block.table!
        #expect(table.width <= 400.5)
        #expect(table.rowHeights[1] > 34)
        #expect(block.cells[2].lines.count > 1)
        #expect(block.cells[2].lines.count == block.cells[3].lines.count)
    }

    @Test func sixHundredBySixLaysOutAndReusesUnchangedCells() {
        var doc = Doc(PerfFixture.tables600x6.text())
        let entryIndex = doc.projection.entries.firstIndex { $0.blocks[0].table != nil }!
        doc.move(to: doc.projection.entries[entryIndex].start)
        let block = doc.block(entryIndex)
        #expect(block.table?.rows == 600 && block.table?.columns == 6)
        let first = LayoutEngine.layout(block, typesetter: typesetter, measure: 640, wideWidth: 900)
        let table = first.table!
        // Only the width sample is typeset up front.
        #expect(table.rowsTypeset < 600 && table.realizedRowCount == table.rowsTypeset)
        #expect(!table.isRealized(row: 300))
        #expect(table.width <= 900.5)
        #expect(table.height > 600 * 34 - 1)
        #expect(first.height == table.height + typesetter.scale.paragraphSpacing)
        let target = table.cellIndex(row: 300, column: 0)
        table.realizeRows(in: table.rowY(280)...table.rowY(320))
        let widths = table.columnWidths

        // Type one character into the cell at row 300, column 0.
        let cell = block.cells[target]
        let entryStart = doc.projection.entries[entryIndex].start
        let at = entryStart + block.sourceRange.lowerBound + cell.sourceRange.upperBound
        let result = doc.insert("x", at: at)
        #expect(result.changedEntries.contains(entryIndex))
        let edited = doc.block(entryIndex)
        #expect(edited.cells[target].text.hasSuffix("x"))
        let second = LayoutEngine.layout(edited, typesetter: typesetter, measure: 640, wideWidth: 900, previous: first, growOnly: true)
        let after = second.table!
        after.realizeRows(in: after.rowY(280)...after.rowY(320))
        // Unchanged rows keep their line layouts; only the edited row is typeset.
        #expect(after.rowsTypeset == 1)
        for r in 281..<320 where r != 300 {
            for c in 0..<6 {
                let i = after.cellIndex(row: r, column: c)
                #expect(second.cell(i) === first.cell(i), "row \(r) column \(c)")
            }
        }
        #expect(second.cell(target) !== first.cell(target))
        #expect(second.cell(target).string.hasSuffix("x"))
        // Grow-only: no column shrank while the caret is inside.
        for (a, b) in zip(widths, after.columnWidths) { #expect(b >= a - 0.01) }
        #expect(after.rows == 600)
    }

    /// A 2,000-row table: short rows, except row 1,500 whose second cell is
    /// a long wrapping paragraph (so its estimated height is wrong).
    static let lazyTable: String = {
        var s = "| Name | Value | Note |\n| --- | --- | --- |\n"
        for i in 1...2000 {
            let value = i == 1500 ? (0..<60).map { "word\($0)" }.joined(separator: " ") : "v\(i)"
            s += "| r\(i) | \(value) | n |\n"
        }
        return s
    }()

    @Test func rowsOutsideTheViewportAreNotTypesetUntilNeeded() {
        let doc = Doc(TableLayoutTests.lazyTable)
        let layout = makeLayout(doc, width: 1200)
        _ = layout.layoutIfNeeded(in: 0...800)
        let table = layout.ensureLayout(0).blocks[0].table!
        #expect(table.rows == 2001)
        #expect(table.isRealized(row: 1) && table.isRealized(row: 20))
        #expect(!table.isRealized(row: 1200) && !table.isMeasured(row: 1200))
        #expect(table.realizedRowCount < 200)
        // Asking for a caret there typesets that row (and only it).
        let before = table.rowsTypeset
        _ = layout.caretRect(at: DisplayPosition(entry: 0, block: 0, cell: table.cellIndex(row: 1200, column: 1), offset: 1))
        #expect(table.isRealized(row: 1200) && table.isMeasured(row: 1200))
        #expect(table.rowsTypeset == before + 1)
        #expect(!table.isRealized(row: 1199))
    }

    @Test func caretAndHitTestInAnUnmeasuredRow() {
        let doc = Doc(TableLayoutTests.lazyTable)
        // Reference: every row measured.
        let full = makeLayout(doc, width: 1200)
        full.layoutAll()
        let lazy = makeLayout(doc, width: 1200)
        _ = lazy.layoutIfNeeded(in: 0...800)
        let table = lazy.ensureLayout(0).blocks[0].table!
        #expect(!table.isMeasured(row: 1500))
        let estimated = table.rowHeight(1500)
        let position = DisplayPosition(entry: 0, block: 0, cell: table.cellIndex(row: 1500, column: 1), offset: 200)
        let rect = lazy.caretRect(at: position)
        #expect(table.isMeasured(row: 1500))
        #expect(table.rowHeight(1500) != estimated)
        #expect(table.rowHeight(1500) > 34)
        #expect(rect == full.caretRect(at: position))
        #expect(lazy.contentHeight == lazy.y(ofEntry: 0) + lazy.height(ofEntry: 0) + lazy.bottomPadding)
        #expect(lazy.height(ofEntry: 0) == lazy.ensureLayout(0).height)

        // Hit test in a fresh layout that has not measured the row either.
        let fresh = makeLayout(doc, width: 1200)
        _ = fresh.layoutIfNeeded(in: 0...800)
        #expect(!fresh.ensureLayout(0).blocks[0].table!.isMeasured(row: 1500))
        let probe = CGPoint(x: rect.minX + 0.5, y: rect.midY)
        #expect(fresh.position(at: probe) == position)
        #expect(fresh.sourceOffset(at: probe) == doc.projection.sourceOffset(for: position))
        #expect(fresh.caretRect(at: position) == rect)
    }

    @Test func columnWidthsDoNotShrinkWhenLaterRowsAreMeasured() {
        let doc = Doc(TableLayoutTests.lazyTable)
        let layout = makeLayout(doc, width: 1200)
        _ = layout.layoutIfNeeded(in: 0...800)
        let table = layout.ensureLayout(0).blocks[0].table!
        let initial = table.columnWidths
        var previous = initial
        var y: CGFloat = 0
        while y < layout.contentHeight {
            _ = layout.layoutIfNeeded(in: y...(y + 800))
            for (a, b) in zip(previous, table.columnWidths) { #expect(b >= a) }
            previous = table.columnWidths
            y += 800
        }
        for r in 0..<table.rows { #expect(table.isMeasured(row: r)) }
        // Row 1,500 widened the second column into the free width.
        #expect(table.columnWidths[1] > initial[1])
        #expect(table.columnWidths[0] == initial[0] && table.columnWidths[2] == initial[2])
        #expect(table.width <= layout.wideWidth + 0.5)
        #expect(table.realizedRowCount <= table.realizedRowCap)
    }

    @Test func cellsAreIndividuallyAddressable() {
        let block = layoutBlock("| a | b |\n| --- | --- |\n| c | d |\n", measure: 480)
        let table = block.table!
        for i in 0..<4 {
            let frame = block.cellFrames[i]
            let probe = CGPoint(x: frame.midX, y: frame.midY)
            #expect(block.cellIndex(at: probe) == i, "cell \(i) at \(probe)")
        }
        #expect(block.cellIndex(at: CGPoint(x: -10, y: -10)) == 0)
        #expect(block.cellIndex(at: CGPoint(x: table.width + 50, y: table.height + 50)) == 3)
    }
}
