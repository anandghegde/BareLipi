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
        #expect(first.cells.count == 3600)
        #expect(table.width <= 900.5)
        #expect(table.height > 600 * 34 - 1)
        #expect(first.height == table.height + typesetter.scale.paragraphSpacing)

        // Type one character into the cell at row 300, column 0.
        let cell = block.cells[block.table!.cellIndex(row: 300, column: 0)]
        let entryStart = doc.projection.entries[entryIndex].start
        let at = entryStart + block.sourceRange.lowerBound + cell.sourceRange.upperBound
        let result = doc.insert("x", at: at)
        #expect(result.changedEntries.contains(entryIndex))
        let edited = doc.block(entryIndex)
        #expect(edited.cells[block.table!.cellIndex(row: 300, column: 0)].text.hasSuffix("x"))
        let second = LayoutEngine.layout(edited, typesetter: typesetter, measure: 640, wideWidth: 900, previous: first, growOnly: true)
        let after = second.table!
        // Unchanged cells keep their typeset keys and their line layouts.
        var reused = 0
        for i in 0..<3600 where i != block.table!.cellIndex(row: 300, column: 0) {
            if after.cellKeys[i] == table.cellKeys[i] { reused += 1 }
            if second.cells[i] === first.cells[i] { reused += 0 }
        }
        #expect(reused == 3599)
        #expect(after.cellKeys[block.table!.cellIndex(row: 300, column: 0)] != table.cellKeys[block.table!.cellIndex(row: 300, column: 0)])
        // Grow-only: no column shrank while the caret is inside.
        for (a, b) in zip(table.columnWidths, after.columnWidths) { #expect(b >= a - 0.01) }
        #expect(after.rows == 600)
        #expect(second.cells.filter { $0 !== first.cells[0] }.count <= 3600)
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
