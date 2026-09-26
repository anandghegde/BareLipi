import CoreText
import Foundation
import LipiCore
import LipiLayout
import Testing

@Suite("Block layout")
struct BlockLayoutTests {
    let typesetter = makeTypesetter()
    let words = (0..<120).map { "word\($0)" }.joined(separator: " ")

    @Test func singleLine() {
        let block = layoutBlock("Short line.")
        #expect(block.lineCount == 1)
        #expect(block.height == 26)
        #expect(block.cells[0].lines[0].top == 0)
        #expect(block.cells[0].lines[0].width > 0)
        #expect(block.width == 480)
        #expect(block.spacingAfter == 13)
    }

    @Test func wrapsAtTheMeasureWithFixedLineHeights() {
        let block = layoutBlock(words, measure: 400)
        let cell = block.cells[0]
        #expect(cell.lines.count > 5)
        for (i, line) in cell.lines.enumerated() {
            #expect(line.top == CGFloat(i) * 26)
            #expect(line.height == 26)
            #expect(line.width - line.trailingWhitespace <= 400.5, "line \(i) is \(line.width) wide")
            #expect(line.x == 0)
        }
        #expect(cell.height == CGFloat(cell.lines.count) * 26)
        #expect(block.height == cell.height)
        // Lines tile the text.
        #expect(cell.lines.first?.range.lowerBound == 0)
        #expect(cell.lines.last?.range.upperBound == cell.length)
        for (a, b) in zip(cell.lines, cell.lines.dropFirst()) { #expect(a.range.upperBound == b.range.lowerBound) }
        // A narrower measure produces more lines.
        #expect(layoutBlock(words, measure: 300).lineCount > cell.lines.count)
    }

    @Test func baselinesSitInsideTheirLines() {
        let block = layoutBlock(words, measure: 400)
        for line in block.cells[0].lines {
            #expect(line.baseline > line.top && line.baseline < line.bottom)
            #expect(line.baseline == line.baseline.rounded())
        }
    }

    @Test func tallParagraphUsesTallLines() {
        let block = layoutBlock("ಕನ್ನಡ ಭಾಷೆ ಸಾಹಿತ್ಯ " + words, measure: 400)
        for line in block.cells[0].lines { #expect(line.height == 28) }
    }

    @Test func kannadaConjunctIsOneCaretStep() {
        // ಕ್ಷ = ಕ + ್ + ಷ (three scalars, one grapheme).
        let conjunct = "ಕ್ಷ" as NSString
        #expect(conjunct.length == 3)
        #expect(CaretGeometry.caretStops(in: conjunct) == 2)
        #expect(CaretGeometry.next(after: 0, in: conjunct) == 3)
        #expect(CaretGeometry.previous(before: 3, in: conjunct) == 0)
        #expect(CaretGeometry.cluster(at: 1, in: conjunct) == 0..<3)
        let word = "ಕ್ಷೇತ್ರ ಜ್ಞಾನ" as NSString  // 2 words: ಕ್ಷೇ ತ್ರ, ಜ್ಞಾ ನ
        #expect(CaretGeometry.caretStops(in: word) == 6)
        let devanagari = "क्षेत्र" as NSString
        #expect(CaretGeometry.caretStops(in: devanagari) == 3)
        let family = "👨‍👩‍👧‍👦x" as NSString
        #expect(CaretGeometry.caretStops(in: family) == 3)
    }

    @Test func caretRectsFollowClusterBoundaries() {
        let block = layoutBlock("ಕ್ಷೇತ್ರ end")
        let cell = block.cells[0]
        let start = CaretGeometry.rect(for: 0, in: cell)
        let afterCluster = CaretGeometry.rect(for: CaretGeometry.next(after: 0, in: cell.string), in: cell)
        #expect(start.minX == 0)
        #expect(afterCluster.minX > start.minX + 5)
        #expect(start.height == 28 && afterCluster.height == 28)
        // Hit testing the middle of the cluster lands on a cluster boundary.
        let hit = CaretGeometry.offset(at: CGPoint(x: afterCluster.minX / 2, y: 10), in: cell)
        #expect(hit == 0 || hit == 4, "hit \(hit)")
    }

    @Test func rightToLeftLinesFlushRight() {
        let arabic = (0..<40).map { _ in "العربية لغة" }.joined(separator: " ")
        let block = layoutBlock(arabic, measure: 400)
        let cell = block.cells[0]
        #expect(cell.typeset.isRightToLeft)
        #expect(cell.lines.count > 2)
        for line in cell.lines.dropLast() {
            #expect(line.isRightToLeft)
            #expect(approximately(line.x + line.width - line.trailingWhitespace, 400, within: 1.5), "line ends at \(line.x + line.width)")
        }
        // The caret at offset 0 is at the right edge.
        #expect(CaretGeometry.rect(for: 0, in: cell).minX > 300)
    }

    @Test func codeBlocksUseTheWideWidthAndPadding() {
        let block = layoutBlock("```swift\nlet x = 1\nlet y = 2\n```", measure: 400, wideWidth: 640)
        #expect(block.width == 640)
        #expect(block.hasBackground)
        #expect(block.style.paddingX == 12)
        #expect(block.cellFrames[0].minX == 12 && block.cellFrames[0].minY == 12)
        let lines = block.cells[0].lines
        #expect(lines.count == block.cells[0].string.components(separatedBy: "\n").count)
        #expect(block.height == block.cells[0].height + 24)
        for line in lines { #expect(line.height == 21) }
    }

    @Test func quoteAndListIndents() {
        let quote = layoutBlock("> quoted text", measure: 400)
        #expect(quote.context.quoteDepth == 1)
        #expect(quote.indent == 16)
        #expect(quote.width == 384)
        let item = layoutBlock("- item text", measure: 400)
        #expect(item.context.listDepth == 1)
        #expect(item.context.marker?.literal == "-")
        #expect(item.indent == 24)
        let nested = layoutBlock("- item\n    - nested", measure: 400, block: 1)
        #expect(nested.indent == 48)
        #expect(LayoutEngine.indent(for: nested.context, scale: typesetter.scale) == 48)
    }

    @Test func headingsAndRules() {
        let h1 = layoutBlock("# Title")
        #expect(h1.style.size == 34 && h1.height == 40 && h1.spacingBefore == 26)
        let rule = layoutBlock("---")
        #expect(rule.isThematicBreak)
        #expect(rule.height == 26)
    }

    @Test func emptyParagraphStillHasOneLine() {
        // A fenced block with no content lays out as one empty line.
        let block = layoutBlock("```\n```")
        #expect(block.cells[0].lines.count >= 1)
        #expect(block.cells[0].height >= 21)
        let caret = CaretGeometry.rect(for: 0, in: block.cells[0])
        #expect(caret.height == 21)
    }

    @Test func estimatedHeightIsCloseToMeasured() {
        let doc = Doc(words)
        let block = doc.block()
        let measured = LayoutEngine.layout(block, typesetter: typesetter, measure: 400, wideWidth: 400).height
        let estimated = LayoutEngine.estimatedHeight(of: block, typesetter: typesetter, measure: 400, zeroAdvance: typesetter.cascade.zeroAdvance(size: 17))
        #expect(estimated > measured * 0.5 && estimated < measured * 2, "estimated \(estimated) vs measured \(measured)")
    }

    @Test func hitTestingRoundTripsEveryCaretStop() {
        let block = layoutBlock("Some words wrap here and there, with ಕನ್ನಡ and عربي too. " + words, measure: 360)
        let cell = block.cells[0]
        var offset = 0
        var checked = 0
        while offset <= cell.length {
            let rect = CaretGeometry.rect(for: offset, in: cell)
            let probe = CGPoint(x: rect.minX + (cell.lines[cell.lineIndex(containing: offset)].isRightToLeft ? -0.5 : 0.5), y: rect.midY)
            let back = CaretGeometry.offset(at: probe, in: cell)
            let rect2 = CaretGeometry.rect(for: back, in: cell)
            #expect(approximately(rect2.minX, rect.minX, within: 1) && rect2.minY == rect.minY, "offset \(offset) → \(back)")
            checked += 1
            if offset == cell.length { break }
            offset = CaretGeometry.next(after: offset, in: cell.string)
        }
        #expect(checked > 100)
    }

    @Test func lineIndexLookups() {
        let block = layoutBlock(words, measure: 300)
        let cell = block.cells[0]
        #expect(cell.lineIndex(atY: -5) == 0)
        #expect(cell.lineIndex(atY: 26 * 2 + 1) == 2)
        #expect(cell.lineIndex(atY: 10_000) == cell.lines.count - 1)
        let wrap = cell.lines[1].range.lowerBound
        #expect(cell.lineIndex(containing: wrap) == 1)
        #expect(cell.lineIndex(containing: wrap, upstream: true) == 0)
        #expect(cell.lineIndex(containing: cell.length) == cell.lines.count - 1)
    }
}
