import CoreText
import Foundation
import LipiCore
import LipiFixtures
import LipiLayout
import Testing

/// Windowed line breaking of long cells and the incremental re-layout after
/// an edit, each checked against a fresh layout with one typesetter.
@Suite struct LongCellLayoutTests {
    /// A paragraph of `bytes` with inline markup, long words, CJK, emoji
    /// (unless `emoji` is off) and soft line breaks.
    static func paragraph(bytes: Int, seed: UInt64, emoji: Bool = true) -> String {
        var rng = SplitMix64(seed: seed)
        var text = ""
        while text.utf8.count < bytes {
            switch rng.below(40) {
            case 0: text += "*" + rng.pick(Words.latin) + " " + rng.pick(Words.latin) + "* "
            case 1: text += "`" + rng.pick(Words.latin) + "` "
            case 2: text += "[" + rng.pick(Words.latin) + "](https://example.com/" + rng.pick(Words.latin) + ") "
            case 3: text += "~~" + rng.pick(Words.latin) + "~~ "
            case 4: text += String(repeating: rng.pick(Words.latin), count: 12) + " "
            case 5: text += "漢字仮名交じり文 "
            case 6 where emoji: text += "👩🏽‍💻🎉 "
            case 7: text += rng.pick(Words.latin) + "\n"
            default: text += rng.pick(Words.latin) + " "
            }
        }
        return text
    }

    static func sameLines(_ a: CellLayout, _ b: CellLayout, sourceLocation: SourceLocation = #_sourceLocation) {
        if let i = (0..<min(a.lines.count, b.lines.count)).first(where: { a.lines[$0].range != b.lines[$0].range }) ?? (a.lines.count == b.lines.count ? nil : min(a.lines.count, b.lines.count)) {
            func text(_ l: CellLayout) -> String {
                guard i < l.lines.count else { return "(none)" }
                return "\(l.lines[i].range) \"" + l.string.substring(with: NSRange(location: l.lines[i].range.lowerBound, length: l.lines[i].range.count)) + "\""
            }
            Issue.record("line \(i) of \(a.lines.count)/\(b.lines.count): \(text(a)) ≠ \(text(b))", sourceLocation: sourceLocation)
            return
        }
        for (x, y) in zip(a.lines, b.lines) where x.top != y.top || x.baseline != y.baseline || abs(x.width - y.width) > 0.01 || abs(x.x - y.x) > 0.01 {
            Issue.record("line \(x.range) differs: top \(x.top)/\(y.top) baseline \(x.baseline)/\(y.baseline) width \(x.width)/\(y.width)",
                         sourceLocation: sourceLocation)
            return
        }
        #expect(a.height == b.height, sourceLocation: sourceLocation)
        #expect(a.decorations.map(\.lineIndex) == b.decorations.map(\.lineIndex), sourceLocation: sourceLocation)
        for (x, y) in zip(a.decorations, b.decorations) where !approximately(x.rect, y.rect) {
            Issue.record("decoration \(x.rect) ≠ \(y.rect)", sourceLocation: sourceLocation)
            return
        }
    }

    /// Caret rects and hit tests at `count` offsets spread through the cell.
    static func sameCarets(_ a: CellLayout, _ b: CellLayout, count: Int, rng: inout SplitMix64,
                           sourceLocation: SourceLocation = #_sourceLocation) {
        var offsets = [0, a.length]
        for _ in 0..<count { offsets.append(rng.below(a.length + 1)) }
        for offset in offsets {
            for upstream in [false, true] {
                let x = CaretGeometry.rect(for: offset, in: a, upstream: upstream)
                let y = CaretGeometry.rect(for: offset, in: b, upstream: upstream)
                if !approximately(x, y) {
                    Issue.record("caret at \(offset) (upstream \(upstream)): \(x) ≠ \(y)", sourceLocation: sourceLocation)
                    return
                }
            }
            let point = CaretGeometry.rect(for: offset, in: a).offsetBy(dx: 3, dy: 5).origin
            let hitA = CaretGeometry.offset(at: point, in: a), hitB = CaretGeometry.offset(at: point, in: b)
            if hitA != hitB {
                Issue.record("hit at \(point): \(hitA) ≠ \(hitB)", sourceLocation: sourceLocation)
                return
            }
        }
    }

    static func approximately(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01 && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
    }

    static func cell(_ text: String, typesetter: Typesetter) -> TypesetCell {
        let doc = Doc(text)
        return typesetter.typeset(doc.block().cells[0], in: doc.block(), cellIndex: 0)
    }

    /// Under about 10,000 UTF-16 units: one typesetter over a longer string
    /// stops forming emoji ZWJ sequences (see `emojiSequencesShapeInLongCells`).
    @Test(arguments: [0x11, 0x12, 0x13] as [UInt64])
    func windowedBreaksMatchOneTypesetter(seed: UInt64) {
        let typesetter = makeTypesetter()
        let cell = Self.cell(Self.paragraph(bytes: 8_000, seed: seed), typesetter: typesetter)
        var rng = SplitMix64(seed: seed)
        for width in [480, 173] as [CGFloat] {
            let whole = LayoutEngine.typeset(cell, width: width, windowLength: .max)
            // Small windows: reopened every few lines, grown for long words.
            for window in [200, 700, LayoutEngine.windowLength] {
                let windowed = LayoutEngine.typeset(cell, width: width, windowLength: window)
                Self.sameLines(windowed, whole)
                Self.sameCarets(windowed, whole, count: 200, rng: &rng)
            }
        }
    }

    @Test func longCellsAreWindowedByDefault() {
        let typesetter = makeTypesetter()
        let cell = Self.cell(Self.paragraph(bytes: 40_000, seed: 7, emoji: false), typesetter: typesetter)
        #expect(cell.length >= LayoutEngine.windowThreshold)
        let layout = LayoutEngine.typeset(cell, width: 480)
        // Windowed lines index their window, not the cell text.
        #expect(layout.lines.contains { $0.base > 0 })
        Self.sameLines(layout, LayoutEngine.typeset(cell, width: 480, windowLength: .max))
        var rng = SplitMix64(seed: 7)
        Self.sameCarets(layout, LayoutEngine.typeset(cell, width: 480, windowLength: .max), count: 300, rng: &rng)
    }

    /// One typesetter over a long string sets 👩🏽‍💻 as two glyphs (woman,
    /// laptop) where a short one forms the sequence; windows keep it one.
    @Test func emojiSequencesShapeInLongCells() {
        let typesetter = makeTypesetter()
        let cell = Self.cell(Self.paragraph(bytes: 40_000, seed: 7, emoji: false) + " 👩🏽‍💻 end", typesetter: typesetter)
        let layout = LayoutEngine.typeset(cell, width: 480)
        let at = cell.length - " end".utf16.count - "👩🏽‍💻".utf16.count
        let line = layout.lines[layout.lineIndex(containing: at)]
        let runs = CTLineGetGlyphRuns(line.line) as! [CTRun]
        let emoji = runs.first { CTRunGetStringRange($0).location + line.base == at }
        #expect(emoji.map(CTRunGetGlyphCount) == 1)
    }

    @Test func rightToLeftCellsKeepOneTypesetter() {
        let typesetter = makeTypesetter()
        let text = String(repeating: "lorem ipsum שלום עולם dolor sit amet ", count: 600)
        let cell = Self.cell(text, typesetter: typesetter)
        #expect(cell.length >= LayoutEngine.windowThreshold)
        #expect(LayoutEngine.typeset(cell, width: 480).lines.allSatisfy { $0.base == 0 })
    }

    /// Random edits inside a long paragraph: the layout made from the
    /// previous one equals a fresh layout after every edit.
    @Test(arguments: [0x21, 0x22] as [UInt64])
    func incrementalLayoutMatchesFreshLayout(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let typesetter = makeTypesetter()
        var doc = Doc(Self.paragraph(bytes: 36_000, seed: seed))
        var previous = LayoutEngine.layout(doc.block(), typesetter: typesetter, measure: 480, wideWidth: 480)
        let edits: [String] = ["k", " ", "lorem ", "*", "`", "\n", "漢", "🎉", String(repeating: "x", count: 90), "ipsum dolor sit amet "]
        for step in 0..<60 {
            let count = doc.buffer.count
            var at = doc.rope.floorScalarBoundary(rng.below(count))
            // Some edits near the ends of the paragraph.
            if step % 10 == 3 { at = doc.rope.floorScalarBoundary(min(count, rng.below(40))) }
            if step % 10 == 7 { at = doc.rope.floorScalarBoundary(max(0, count - 1 - rng.below(40))) }
            if rng.chance(0.3), at + 1 < count {
                let end = doc.rope.floorScalarBoundary(min(count - 1, at + 1 + rng.below(rng.chance(0.2) ? 400 : 6)))
                if end > at { doc.delete(at..<end) }
            } else {
                doc.insert(rng.pick(edits), at: at)
            }
            guard doc.projection.entries.count == 1, doc.projection.entries[0].blocks.count == 1,
                  case .paragraph = doc.block().role else { continue }
            let incremental = LayoutEngine.layout(doc.block(), typesetter: typesetter, measure: 480, wideWidth: 480, previous: previous)
            let fresh = LayoutEngine.layout(doc.block(), typesetter: typesetter, measure: 480, wideWidth: 480)
            #expect(incremental.height == fresh.height)
            Self.sameLines(incremental.cell(0), fresh.cell(0))
            Self.sameCarets(incremental.cell(0), fresh.cell(0), count: 40, rng: &rng)
            previous = incremental
        }
    }

    /// Typing in the middle of a 1 MB-class paragraph through `DocumentLayout`:
    /// the lines before and after the edit are the old ones, and the caret,
    /// the hit test and the height agree with a fresh layout.
    @Test func documentLayoutKeepsUnchangedLines() {
        let typesetter = makeTypesetter()
        var doc = Doc(Self.paragraph(bytes: 200_000, seed: 0x31))
        let layout = makeLayout(doc, typesetter: typesetter)
        let before = layout.cell(at: DisplayPosition(entry: 0, block: 0, cell: 0, offset: 0))
        let middle = doc.rope.floorScalarBoundary(doc.buffer.count / 2)
        for k in 0..<20 {
            let result = doc.insert(k % 5 == 4 ? " " : "k", at: middle + k)
            layout.update(projection: doc.projection, result: result)
            _ = layout.layoutIfNeeded(in: 0...800)
        }
        let after = layout.cell(at: DisplayPosition(entry: 0, block: 0, cell: 0, offset: 0))
        #expect(after !== before)
        #expect(after.lines[0].line === before.lines[0].line)
        #expect(after.lines.last!.line === before.lines.last!.line)

        let fresh = makeLayout(doc, typesetter: typesetter)
        Self.sameLines(after, fresh.cell(at: DisplayPosition(entry: 0, block: 0, cell: 0, offset: 0)))
        #expect(layout.contentHeight == fresh.contentHeight)
        for offset in [0, middle - 300, middle + 10, middle + 5000, doc.buffer.count] {
            #expect(layout.caretRect(forSource: offset) == fresh.caretRect(forSource: offset))
        }
        let point = CGPoint(x: 200, y: layout.caretRect(forSource: middle + 10)!.midY)
        #expect(layout.position(at: point) == fresh.position(at: point))
    }
}
