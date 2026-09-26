import AppKit
import Foundation
import LipiCore
import LipiFixtures
import LipiLayout
import Testing

/// The ADR-002 spike: the same projected document through LipiLayout and a
/// headless TextKit 2 stack, compared on the go/no-go criteria.
@Suite("TextKit 2 comparison")
@MainActor
struct TextKit2ComparisonTests {
    let typesetter = makeTypesetter()
    let width: CGFloat = 640

    func both(_ text: String) -> (Doc, DocumentLayout, TextKit2Layout) {
        let doc = Doc(text)
        let lipi = DocumentLayout(typesetter: typesetter, viewportWidth: width + 2 * 32 + 56)
        var projection = Projection()
        let result = projection.update(index: doc.parser.index, rope: doc.rope, reveal: .none)
        lipi.update(projection: projection, result: result)
        lipi.layoutAll()
        let tk2 = TextKit2Layout(width: lipi.measure)
        tk2.load(projection, typesetter: typesetter)
        tk2.ensureLayoutToEnd()
        return (doc, lipi, tk2)
    }

    @Test func paragraphHeightsAgree() {
        let words = (0..<300).map { "word\($0)" }.joined(separator: " ")
        let (_, lipi, tk2) = both(words)
        let lines = lipi.ensureLayout(0).blocks[0].lineCount
        // Same fixed line height, same measure: TextKit 2 wraps to the same
        // number of lines give or take one.
        #expect(approximately(tk2.usedHeight, CGFloat(lines) * 26 + lipi.height(ofEntry: 0) - lipi.ensureLayout(0).blocks[0].height, within: 27))
    }

    @Test func caretRectsAgreeOnLatinText() {
        let (doc, lipi, tk2) = both("The quick brown fox jumps over the lazy dog, again and again until the line wraps around at the measure.")
        let cell = doc.projection.entries[0].blocks[0].cells[0]
        for offset in stride(from: 0, through: cell.text.utf16.count, by: 5) {
            let position = DisplayPosition(entry: 0, block: 0, cell: 0, offset: offset)
            let a = lipi.caretRect(at: position)
            let b = tk2.caretRect(forDocumentOffset: tk2.documentOffset(of: position))
            #expect(b != nil)
            guard let b else { continue }
            #expect(approximately(a.minX - lipi.textOrigin, b.minX, within: 1.5), "x at \(offset): \(a.minX - lipi.textOrigin) vs \(b.minX)")
            #expect(approximately(a.minY, b.minY, within: 1.5), "y at \(offset): \(a.minY) vs \(b.minY)")
        }
    }

    @Test func kannadaClusterStopsAgree() {
        let (doc, lipi, tk2) = both("ಕ್ಷೇತ್ರ ಜ್ಞಾನ")
        let cell = lipi.cell(at: DisplayPosition(entry: 0, block: 0, cell: 0, offset: 0))
        let lipiStops = CaretGeometry.caretStops(in: cell.string)
        var tk2Stops = 0
        let start = tk2.location(atOffset: 0)
        let end = tk2.location(atOffset: doc.projection.entries[0].blocks[0].cells[0].text.utf16.count)
        tk2.layoutManager.enumerateCaretOffsetsInLineFragment(at: start) { _, _, _, _ in tk2Stops += 1 }
        _ = end
        // TextKit reports leading and trailing edges per cluster.
        #expect(lipiStops == 6)
        #expect(tk2Stops == (lipiStops - 1) * 2 || tk2Stops == lipiStops || tk2Stops == lipiStops - 1, "TextKit 2 reported \(tk2Stops) caret offsets")
    }

    @Test func hitTestingAgrees() {
        let (doc, lipi, tk2) = both("Hit testing on a line of Latin text that wraps once or twice at this measure, ಕನ್ನಡ included.")
        let cell = doc.projection.entries[0].blocks[0].cells[0]
        var agreements = 0
        var total = 0
        for offset in stride(from: 0, through: cell.text.utf16.count, by: 3) {
            let position = DisplayPosition(entry: 0, block: 0, cell: 0, offset: offset)
            let rect = lipi.caretRect(at: position)
            let probe = CGPoint(x: rect.minX - lipi.textOrigin + 0.5, y: rect.midY)
            let a = lipi.position(at: CGPoint(x: rect.minX + 0.5, y: rect.midY))?.offset
            let b = tk2.documentOffset(at: probe)
            total += 1
            if let a, let b, abs(a - b) <= 1 { agreements += 1 }
        }
        #expect(agreements >= total * 9 / 10, "\(agreements)/\(total)")
    }

    @Test func incrementalReplaceKeepsRangesConsistent() {
        var doc = Doc("one\n\ntwo two two\n\nthree\n")
        let tk2 = TextKit2Layout(width: 400)
        tk2.load(doc.projection, typesetter: typesetter)
        let before = tk2.textStorage.string
        _ = doc.insert(" plus", at: 8)
        tk2.replaceEntry(1, with: doc.projection.entries[1], typesetter: typesetter)
        #expect(tk2.textStorage.string == before.replacingOccurrences(of: "two two two", with: "two plus two two"))
        #expect(tk2.entryRanges[2].lowerBound == tk2.entryRanges[1].upperBound + 1)
        #expect(tk2.entryRanges.last!.upperBound == tk2.length)
        tk2.ensureLayoutToEnd()
        #expect(tk2.usedHeight > 26 * 3)
    }

    @Test func tableIslandsAreLipiOnly() {
        let (doc, lipi, tk2) = both("| a | b |\n| --- | --- |\n| 1 | 2 |\n")
        #expect(lipi.ensureLayout(0).blocks[0].table != nil)
        // TextKit 2 sees tab-separated cells: a flat string, no grid.
        #expect(tk2.textStorage.string.contains("\t"))
        #expect(doc.projection.entries[0].blocks[0].table?.columns == 2)
    }
}
