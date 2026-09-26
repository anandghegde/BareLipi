import Foundation
import LipiCore
import LipiFixtures
import LipiLayout
import Testing

@Suite("Document layout")
struct DocumentLayoutTests {
    let text = """
    # Heading

    First paragraph with *emphasis* and `code` and a [link](https://example.com).

    > A quote that is long enough to wrap when the measure is narrow, so it has several lines of text in it.

    - one
    - two

    ```swift
    let x = 1
    ```

    | a | b |
    | --- | --- |
    | 1 | 2 |

    ಕನ್ನಡ ಪದ ಕ್ಷೇತ್ರ ಮತ್ತು हिन्दी शब्द ज्ञान.

    Last paragraph.
    """

    @Test func measureAndOriginFollowTheViewport() {
        let doc = Doc(text)
        let layout = makeLayout(doc, width: 1200)
        let scale = layout.scale
        let natural = min(max(72 * layout.zeroAdvance, 320), 720).rounded()
        #expect(layout.measure == natural)
        #expect(layout.textOrigin >= scale.sideMargin + scale.gutter)
        #expect(layout.wideWidth >= layout.measure)
        layout.setViewportWidth(500)
        #expect(abs(layout.measure - 380) < 0.001)  // 500 − 2 × 32 margin − 56 gutter
        #expect(abs(layout.textOrigin - 88) < 0.001)
        #expect(!layout.isLaidOut(0))
        layout.setViewportWidth(1200)
        #expect(layout.measure == natural)
    }

    @Test func heightsStartAsEstimatesAndBecomeMeasured() {
        let doc = Doc(text)
        let layout = makeLayout(doc, width: 900)
        let n = layout.entryCount
        #expect(n == doc.projection.entries.count)
        let estimated = (0..<n).map(layout.height(ofEntry:))
        for h in estimated { #expect(h > 0) }
        #expect(layout.contentHeight == estimated.reduce(0, +))
        layout.layoutAll()
        let measured = (0..<n).map(layout.height(ofEntry:))
        #expect(measured != estimated)
        for i in 0..<n { #expect(layout.isLaidOut(i)) }
        #expect(layout.contentHeight == measured.reduce(0, +))
        var y: CGFloat = 0
        for i in 0..<n {
            #expect(layout.y(ofEntry: i) == y)
            let entry = layout.ensureLayout(i)
            #expect(entry.height == measured[i])
            y += measured[i]
        }
        #expect(layout.stats.entriesLaidOut == n)
    }

    @Test func viewportLayoutTouchesOnlyVisibleEntries() {
        let doc = Doc(PerfFixture.lorem50k.text())
        let layout = makeLayout(doc, width: 1000)
        let placed = layout.layoutIfNeeded(in: 0...900)
        #expect(!placed.isEmpty)
        #expect(placed.first?.index == 0)
        #expect(placed.last!.y <= 900)
        #expect(layout.stats.entriesLaidOut == placed.count)
        #expect(layout.stats.entriesLaidOut < doc.projection.entries.count / 10)
        // Scrolling into the middle lays out from the entry at that y.
        let middle = layout.contentHeight / 2
        let placedMiddle = layout.layoutIfNeeded(in: middle...(middle + 900))
        // The first entry is chosen from estimated heights, so once measured it
        // may end above `middle`; it still starts at or before it.
        #expect(placedMiddle.first!.y <= middle)
        #expect(placedMiddle.last!.y + placedMiddle.last!.layout.height >= middle + 900 || placedMiddle.last!.index == layout.entryCount - 1)
        for (a, b) in zip(placedMiddle, placedMiddle.dropFirst()) { #expect(b.y == a.y + a.layout.height) }
    }

    @Test func caretAndHitTestRoundTrip() {
        let doc = Doc(text)
        let layout = makeLayout(doc, width: 900)
        layout.layoutAll()
        var checked = 0
        for (e, entry) in doc.projection.entries.enumerated() {
            for (b, block) in entry.blocks.enumerated() {
                for c in block.cells.indices {
                    let cell = layout.cell(at: DisplayPosition(entry: e, block: b, cell: c, offset: 0))
                    var offset = 0
                    while true {
                        let position = DisplayPosition(entry: e, block: b, cell: c, offset: offset)
                        let rect = layout.caretRect(at: position)
                        let rtl = cell.lines[cell.lineIndex(containing: offset)].isRightToLeft
                        let probe = CGPoint(x: rect.minX + (rtl ? -0.5 : 0.5), y: rect.midY)
                        let back = layout.position(at: probe)
                        #expect(back != nil)
                        if let back {
                            #expect(back.entry == e && back.block == b && back.cell == c, "\(position) → \(back)")
                            let rect2 = layout.caretRect(at: back)
                            #expect(approximately(rect2.minX, rect.minX, within: 1) && approximately(rect2.minY, rect.minY, within: 0.01), "\(position) → \(back)")
                        }
                        checked += 1
                        if offset >= cell.length { break }
                        offset = CaretGeometry.next(after: offset, in: cell.string)
                    }
                }
            }
        }
        #expect(checked > 150)
    }

    @Test func sourceOffsetsMapThroughTheProjection() {
        let doc = Doc(text)
        let layout = makeLayout(doc, width: 900)
        layout.layoutAll()
        let bytes = Array(text.utf8)
        var last = CGRect.null
        for offset in stride(from: 0, through: bytes.count, by: 7) {
            // Stay on scalar boundaries.
            guard offset == bytes.count || bytes[offset] & 0xC0 != 0x80 else { continue }
            guard let rect = layout.caretRect(forSource: offset) else { continue }
            #expect(rect.height >= 18 && rect.height <= 40)
            #expect(rect.minX >= layout.textOrigin - 1)
            if !last.isNull { #expect(rect.minY >= last.minY - 0.01, "caret went up at \(offset)") }
            last = rect
            if let back = layout.sourceOffset(at: CGPoint(x: rect.minX + 0.5, y: rect.midY)) {
                let position = doc.projection.position(forSource: offset)!
                let backPosition = doc.projection.position(forSource: back)!
                #expect(backPosition.entry == position.entry, "\(offset) → \(back)")
            }
        }
    }

    @Test func editKeepsOtherLayoutsAndReusesCachedBlocks() {
        var doc = Doc(text)
        let layout = makeLayout(doc, width: 900)
        // Put the caret in the quote (third entry) first, so the edit below
        // changes only that entry (leaving entry 0 would un-reveal the heading).
        let quote = doc.projection.entries[2]
        let moved = doc.move(to: quote.start + quote.length - 1)
        layout.update(projection: doc.projection, result: moved)
        layout.layoutAll()
        let n = layout.entryCount
        let before = (0..<n).map { layout.ensureLayout($0) }
        let heights = (0..<n).map(layout.height(ofEntry:))
        let result = doc.insert(" more words here", at: quote.start + quote.length - 1)
        #expect(result.changedEntries == [2])
        layout.update(projection: doc.projection, result: result)
        #expect(layout.entryCount == n)
        for i in 0..<n where i != 2 {
            #expect(layout.isLaidOut(i))
            #expect(layout.ensureLayout(i) === before[i])
            #expect(layout.height(ofEntry: i) == heights[i])
        }
        #expect(!layout.isLaidOut(2))
        // The changed entry keeps its old height as the estimate until laid out.
        #expect(layout.height(ofEntry: 2) == heights[2])
        let relaid = layout.ensureLayout(2)
        #expect(relaid !== before[2])
        #expect(layout.height(ofEntry: 2) == relaid.height)
        #expect(relaid.blocks[0].cells[0].string.contains("more words here"))
    }

    @Test func typingDoesNotAccumulateStaleLayoutsInTheCache() {
        var doc = Doc(text)
        let layout = makeLayout(doc, width: 900)
        let quote = doc.projection.entries[2]
        var caret = quote.start + quote.length - 1
        layout.update(projection: doc.projection, result: doc.move(to: caret))
        layout.layoutAll()
        let resting = layout.cache.count
        // Every keystroke re-parses the quote, which comes back with fresh
        // node ids; the layouts of the ids that vanished must go with them.
        for _ in 0..<40 {
            let result = doc.insert("x", at: caret)
            caret += 1
            layout.update(projection: doc.projection, result: result)
            layout.layoutAll()
            #expect(layout.cache.count <= resting + 1)
        }
        #expect(layout.ensureLayout(2).blocks[0].cells[0].string.contains(String(repeating: "x", count: 40)))
    }

    @Test func caretMoveRevealsWithoutRelayingOutOtherEntries() {
        var doc = Doc(text)
        let layout = makeLayout(doc, width: 900)
        layout.layoutAll()
        let cacheHits = layout.cache.hits
        let paragraph = doc.projection.entries[1]
        let result = doc.move(to: paragraph.start + 22)  // inside *emphasis*
        #expect(result.changedEntries.contains(1))
        layout.update(projection: doc.projection, result: result)
        let revealed = layout.ensureLayout(1)
        // `isRevealed` is the block-marker flag (headings, quotes, fences); a
        // paragraph reveals inline delimiters only, which shows in its text.
        #expect(revealed.blocks[0].cells[0].string.contains("*emphasis*"))
        #expect(layout.stats.entriesLaidOut == layout.entryCount + 1)
        // Moving back restores the folded layout from the cache.
        let back = doc.move(to: 0)
        layout.update(projection: doc.projection, result: back)
        _ = layout.ensureLayout(1)
        #expect(layout.cache.hits > cacheHits)
    }

    @Test func themeChangeInvalidatesEverything() {
        let doc = Doc(text)
        let layout = makeLayout(doc, width: 900)
        layout.layoutAll()
        let height = layout.contentHeight
        layout.setTypesetter(makeTypesetter(zoom: 1.5))
        #expect(layout.themeRevision == 1)
        #expect(!layout.isLaidOut(0))
        #expect(layout.contentHeight == height)  // estimates keep the old heights
        layout.layoutAll()
        #expect(layout.contentHeight > height * 1.2)
    }

    @Test func structuralEditsResizeTheTree() {
        var doc = Doc("one\n\ntwo\n\nthree\n")
        let layout = makeLayout(doc, width: 900)
        layout.layoutAll()
        #expect(layout.entryCount == 3)
        let result = doc.insert("\n\ninserted\n\n", at: 5)
        layout.update(projection: doc.projection, result: result)
        #expect(layout.entryCount == doc.projection.entries.count)
        #expect(layout.entryCount == 4)
        layout.layoutAll()
        #expect(layout.contentHeight == (0..<4).map(layout.height(ofEntry:)).reduce(0, +))
        let removal = doc.delete(0..<5)
        layout.update(projection: doc.projection, result: removal)
        #expect(layout.entryCount == doc.projection.entries.count)
        layout.layoutAll()
        #expect(layout.contentHeight > 0)
    }

    @Test func emptyDocument() {
        let doc = Doc("")
        let layout = makeLayout(doc, width: 900)
        #expect(layout.entryCount == doc.projection.entries.count)
        #expect(layout.layoutIfNeeded(in: 0...100).count == layout.entryCount)
        #expect(layout.position(at: CGPoint(x: 100, y: 100)) == nil || layout.entryCount > 0)
    }
}
