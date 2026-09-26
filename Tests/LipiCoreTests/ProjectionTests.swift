import Foundation
import Testing
@testable import LipiCore

// MARK: - Helpers

/// Parses `text` and projects it with `reveal`.
func project(_ text: String, preset: RevealPreset = .balanced, reveal: RevealSet = .none) -> (Projection, LipiParser, LipiRope) {
    let rope = LipiRope(text)
    var parser = LipiParser(options: .editor)
    parser.parse(rope)
    var projection = Projection(preset: preset)
    projection.update(index: parser.index, rope: rope, reveal: reveal)
    return (projection, parser, rope)
}

/// Projects `text` with the caret at `caret`.
func project(_ text: String, caret: Int, preset: RevealPreset = .balanced) -> Projection {
    let rope = LipiRope(text)
    var parser = LipiParser(options: .editor)
    parser.parse(rope)
    let reveal = RevealPolicy(preset: preset).revealSet(caret: caret, index: parser.index, rope: rope)
    var projection = Projection(preset: preset)
    projection.update(index: parser.index, rope: rope, reveal: reveal)
    return projection
}

/// Checks the tiling and round-trip invariants of a projection (see `OffsetMap`).
struct ProjectionChecker {
    let bytes: [UInt8]
    var failures: [String] = []

    init(_ text: String) { bytes = Array(text.utf8) }

    mutating func fail(_ message: String) { if failures.count < 30 { failures.append(message) } }

    mutating func check(_ projection: Projection) {
        if projection.length != bytes.count { fail("projection length \(projection.length) != \(bytes.count)") }
        var expectedStart = 0
        for (e, entry) in projection.entries.enumerated() {
            if entry.start != expectedStart { fail("entry \(e) starts at \(entry.start), expected \(expectedStart)") }
            expectedStart += entry.length
            check(entry, index: e)
        }
        if expectedStart != bytes.count { fail("entries cover \(expectedStart) bytes of \(bytes.count)") }
    }

    mutating func check(_ entry: ProjectedEntry, index e: Int) {
        if entry.blocks.isEmpty { fail("entry \(e) has no blocks"); return }
        var cursor = 0
        for (b, block) in entry.blocks.enumerated() {
            if block.sourceRange.lowerBound != cursor {
                fail("entry \(e) block \(b) starts at \(block.sourceRange.lowerBound), expected \(cursor)")
            }
            cursor = block.sourceRange.upperBound
            if block.cells.isEmpty { fail("entry \(e) block \(b) has no cells"); continue }
            if let table = block.table, block.cells.count != table.rows * table.columns {
                fail("entry \(e) block \(b): \(block.cells.count) cells for \(table.rows)×\(table.columns)")
            }
            var cellCursor = block.sourceRange.lowerBound
            for (c, cell) in block.cells.enumerated() {
                if cell.sourceRange.lowerBound != cellCursor {
                    fail("entry \(e) block \(b) cell \(c) starts at \(cell.sourceRange.lowerBound), expected \(cellCursor)")
                }
                cellCursor = cell.sourceRange.upperBound
                check(cell, entryStart: entry.start, where: "entry \(e) block \(b) cell \(c)")
            }
            if cellCursor != block.sourceRange.upperBound {
                fail("entry \(e) block \(b): cells end at \(cellCursor), block at \(block.sourceRange.upperBound)")
            }
        }
        if cursor != entry.length { fail("entry \(e): blocks end at \(cursor), span is \(entry.length)") }
    }

    mutating func check(_ cell: DisplayCell, entryStart: Int, where location: String) {
        let map = cell.map
        let text = Array(cell.text.utf8)
        if map.sourceRange != cell.sourceRange { fail("\(location): map range \(map.sourceRange) != \(cell.sourceRange)") }
        if map.displayLength != cell.text.utf16.count { fail("\(location): displayLength \(map.displayLength) != \(cell.text.utf16.count)") }
        if map.displayLengthUTF8 != text.count { fail("\(location): displayLengthUTF8 \(map.displayLengthUTF8) != \(text.count)") }
        var source = cell.sourceRange.lowerBound
        var display = 0
        var displayUTF8 = 0
        for (i, seg) in map.segments.enumerated() {
            if Int(seg.sourceStart) != source { fail("\(location) segment \(i): source \(seg.sourceStart) expected \(source)") }
            if Int(seg.displayStart) != display { fail("\(location) segment \(i): display \(seg.displayStart) expected \(display)") }
            if Int(seg.displayStartUTF8) != displayUTF8 { fail("\(location) segment \(i): utf8 \(seg.displayStartUTF8) expected \(displayUTF8)") }
            if seg.sourceLength <= 0 { fail("\(location) segment \(i): empty source") }
            source = Int(seg.sourceEnd)
            display = Int(seg.displayEnd)
            switch seg.kind {
            case .hidden:
                if seg.displayLength != 0 { fail("\(location) segment \(i): hidden with display width") }
            case .copied:
                let s = (entryStart + Int(seg.sourceStart))..<(entryStart + Int(seg.sourceEnd))
                let d = displayUTF8..<(displayUTF8 + Int(seg.sourceLength))
                guard s.upperBound <= bytes.count, d.upperBound <= text.count else {
                    fail("\(location) segment \(i): copied range out of bounds"); break
                }
                if !bytes[s].elementsEqual(text[d]) { fail("\(location) segment \(i): copied bytes differ") }
                let units = String(decoding: bytes[s], as: UTF8.self).utf16.count
                if Int(seg.displayLength) != units { fail("\(location) segment \(i): \(seg.displayLength) units, text has \(units)") }
                if seg.isASCII != bytes[s].allSatisfy({ $0 < 0x80 }) { fail("\(location) segment \(i): isASCII wrong") }
                displayUTF8 += Int(seg.sourceLength)
            case .replaced:
                if seg.displayLength <= 0 { fail("\(location) segment \(i): replaced with nothing") }
                // Advance UTF-8 by the units' encoded length.
                var p = displayUTF8
                var u = 0
                while p < text.count, u < Int(seg.displayLength) {
                    let b = text[p]
                    let len = b < 0x80 ? 1 : b < 0xE0 ? 2 : b < 0xF0 ? 3 : 4
                    u += len == 4 ? 2 : 1
                    p += len
                }
                displayUTF8 = p
            }
        }
        if source != cell.sourceRange.upperBound { fail("\(location): segments end at \(source), cell at \(cell.sourceRange.upperBound)") }
        if display != map.displayLength { fail("\(location): segments display \(display), cell \(map.displayLength)") }
        if displayUTF8 != text.count { fail("\(location): segments utf8 \(displayUTF8), text \(text.count)") }

        // Style runs are sorted, disjoint and inside the text.
        var runEnd = 0
        for run in cell.runs {
            if run.range.lowerBound < runEnd || run.range.isEmpty || run.range.upperBound > map.displayLength {
                fail("\(location): bad run \(run.range) (len \(map.displayLength))")
            }
            runEnd = run.range.upperBound
        }

        // Round trip and monotonicity. Offsets inside a surrogate pair are not
        // caret positions and floor to the scalar, so they are skipped.
        let units = Array(cell.text.utf16)
        var interior = Set<Int>()   // inside a multi-unit replacement (an entity decoding to several scalars)
        for seg in map.segments where seg.kind == .replaced && seg.displayLength > 1 {
            for δ in (Int(seg.displayStart) + 1)..<Int(seg.displayEnd) { interior.insert(δ) }
        }
        cell.withUTF8 { utf8 in
            var last = cell.sourceRange.lowerBound - 1
            for δ in 0...map.displayLength {
                if δ > 0, δ < units.count, (0xD800...0xDBFF).contains(units[δ - 1]) { continue }
                if interior.contains(δ) { continue }
                let s = map.displayToSource(δ, utf8: utf8)
                if s < cell.sourceRange.lowerBound || s > cell.sourceRange.upperBound {
                    fail("\(location): display \(δ) → source \(s) outside \(cell.sourceRange)"); continue
                }
                if s <= last && δ > 0 && map.displayLength > 0 {
                    // Boundary resolution may repeat a source offset only at zero-width positions.
                    if s < last { fail("\(location): display \(δ) → source \(s) < previous \(last)") }
                }
                last = s
                let back = map.sourceToDisplay(s, utf8: utf8)
                if back != δ { fail("\(location): display \(δ) → source \(s) → display \(back)") }
            }
            var lastDisplay = 0
            for s in cell.sourceRange.lowerBound...cell.sourceRange.upperBound {
                let δ = map.sourceToDisplay(s, utf8: utf8)
                if δ < lastDisplay || δ > map.displayLength { fail("\(location): source \(s) → display \(δ) not monotone") }
                lastDisplay = δ
            }
        }
    }
}

func checkInvariants(_ text: String, _ projection: Projection, _ context: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    var checker = ProjectionChecker(text)
    checker.check(projection)
    #expect(checker.failures.isEmpty, "\(context)\n\(checker.failures.joined(separator: "\n"))\nin: \(text.debugDescription)",
            sourceLocation: sourceLocation)
}

/// Text of every block, tab-separating table cells.
func blockTexts(_ projection: Projection) -> [String] {
    projection.blocks.map { $0.block.cells.map(\.text).joined(separator: "\t") }
}

/// The document as the layout would see it: block texts joined by newlines.
func displayText(_ text: String, caret: Int? = nil, preset: RevealPreset = .balanced) -> String {
    if let caret { return project(text, caret: caret, preset: preset).displayText }
    return project(text, preset: preset).0.displayText
}

func displayBlock(_ text: String) -> DisplayBlock { project(text).0.entries[0].blocks[0] }

/// Display ranges carrying `style`, adjacent ranges merged.
func run(_ block: DisplayBlock, _ style: InlineStyle) -> [Range<Int>] {
    var out: [Range<Int>] = []
    for r in block.cells[0].runs where r.style.contains(style) {
        if let last = out.last, last.upperBound == r.range.lowerBound {
            out[out.count - 1] = last.lowerBound..<r.range.upperBound
        } else {
            out.append(r.range)
        }
    }
    return out
}

let kitchenSink = """
---
title: Test
---

# Heading *one*

Plain **bold** and *em* and ~~gone~~ with `code` and $x^2$ and a\\* escape &amp; entity
soft wrapped line
hard break  
after break

> quoted **text**
> second line

- item one
- item *two*
  continued
  - nested
1. first
2. second

- [ ] todo
- [x] done

```swift
let x = 1
```

    indented code

Text with [link](http://example.com "title") and ![img](pic.png) and <http://auto.link> and [ref][r] and [^1].

[r]: http://ref.example
[^1]: footnote text

| a | b |
|---|:-:|
| 1 | **2** |
| 3 |

***

<div>
raw html
</div>

$$
E = mc^2
$$

Setext
======

ಕನ್ನಡ ಪಠ್ಯ **ಬೋಲ್ಡ್** 日本語 🙂 e\u{301} end
"""

// MARK: - Tests

@Suite("Projection invariants")
struct ProjectionInvariantTests {
    @Test("kitchen sink folded, revealed everywhere, and per caret")
    func kitchenSinkInvariants() {
        let (folded, parser, rope) = project(kitchenSink)
        checkInvariants(kitchenSink, folded, "folded")
        let (all, _, _) = project(kitchenSink, reveal: .everything)
        checkInvariants(kitchenSink, all, "everything")
        for preset in [RevealPreset.balanced, .typoraCompatible, .stable] {
            var projection = Projection(preset: preset)
            let policy = RevealPolicy(preset: preset)
            for caret in 0...kitchenSink.utf8.count {
                let reveal = policy.revealSet(caret: caret, index: parser.index, rope: rope)
                projection.update(index: parser.index, rope: rope, reveal: reveal)
                checkInvariants(kitchenSink, projection, "caret \(caret) preset \(preset)")
            }
        }
    }

    @Test("spec examples folded and revealed")
    func specExamples() throws {
        let examples = try ["commonmark-0.31.2", "gfm-extensions", "gfm-regression"].flatMap { try SpecFixtures.load($0) }
        var rng = SplitMix64(seed: 7)
        for example in examples {
            let text = example.markdown
            let (folded, parser, rope) = project(text)
            checkInvariants(text, folded, "example \(example.number) folded \(text.debugDescription)")
            let (all, _, _) = project(text, reveal: .everything)
            checkInvariants(text, all, "example \(example.number) everything")
            let n = text.utf8.count
            var projection = Projection(preset: .balanced)
            let policy = RevealPolicy(preset: .balanced)
            for _ in 0..<3 {
                let caret = n == 0 ? 0 : Int(rng.next() % UInt64(n + 1))
                let reveal = policy.revealSet(caret: caret, index: parser.index, rope: rope)
                projection.update(index: parser.index, rope: rope, reveal: reveal)
                checkInvariants(text, projection, "example \(example.number) caret \(caret)")
            }
        }
    }

    @Test("empty document projects one empty paragraph")
    func emptyDocument() {
        let (p, _, _) = project("")
        #expect(p.entries.count == 1)
        #expect(p.entries[0].blocks.count == 1)
        #expect(p.entries[0].blocks[0].cells[0].text == "")
        #expect(p.position(forSource: 0) == DisplayPosition(entry: 0, block: 0, cell: 0, offset: 0))
        #expect(p.sourceOffset(for: DisplayPosition(entry: 0, block: 0, cell: 0, offset: 0)) == 0)
    }
}

@Suite("Projection folding")
struct ProjectionFoldingTests {
    @Test("headings drop their markers and keep their level")
    func headings() {
        let block = displayBlock("## Title ##")
        #expect(block.cells[0].text == "Title")
        #expect(block.role == .heading(level: 2))
        #expect(displayText("Setext\n======") == "Setext")
        #expect(displayBlock("Setext\n------").role == .heading(level: 2))
    }

    @Test("inline delimiters fold to styled text")
    func inlineStyles() {
        let block = displayBlock("a **b** *c* ~~d~~ `e` $f$")
        #expect(block.cells[0].text == "a b c d e f")
        #expect(run(block, .strong) == [2..<3])
        #expect(run(block, .emphasis) == [4..<5])
        #expect(run(block, .strikethrough) == [6..<7])
        #expect(run(block, .code) == [8..<9])
        #expect(run(block, .math) == [10..<11])
        #expect(run(block, .syntax).isEmpty)
    }

    @Test("breaks: soft becomes a space, hard a newline")
    func breaks() {
        #expect(displayText("a\nb") == "a b")
        #expect(displayText("a  \nb") == "a\nb")
        #expect(displayText("a\\\nb") == "a\nb")
        #expect(displayText("> a\n> b") == "a b")
        #expect(displayText("a\r\nb") == "a b")
    }

    @Test("escapes and entities show the character they stand for")
    func escapesAndEntities() {
        #expect(displayText("a \\* b &amp; c &#x1F600; &nbsp;d") == "a * b & c 😀 \u{A0}d")
        #expect(displayText("not &an entity; nor \\a") == "not &an entity; nor \\a")
        #expect(displayText("a\u{0}b") == "a\u{FFFD}b")
    }

    @Test("links fold to their label, autolinks stay literal")
    func links() {
        let block = displayBlock("see [label](http://x \"t\") and <http://a.b> and [ref][r] and [short]\n\n[r]: /r\n[short]: /s")
        #expect(block.cells[0].text == "see label and <http://a.b> and ref and short")
        #expect(run(block, .link) == [4..<9, 14..<26, 31..<34, 39..<44])
        #expect(run(block, .syntax) == [14..<15, 25..<26])
        #expect(displayText("![alt text](pic.png)") == "alt text")
        #expect(run(displayBlock("![alt](p)"), .image) == [0..<3])
        #expect(displayText("[](x)") == "")
    }

    @Test("footnotes: references show the label, definitions carry it")
    func footnotes() {
        let (p, _, _) = project("text[^note]\n\n[^note]: the note")
        let blocks = p.blocks.map(\.block)
        #expect(blocks.count == 2)
        #expect(blocks[0].cells[0].text == "textnote")
        #expect(run(blocks[0], .footnoteReference) == [4..<8])
        #expect(blocks[1].cells[0].text == "the note")
        #expect(blocks[1].context.footnoteLabel == "note")
    }

    @Test("containers fold into context")
    func containers() {
        let (p, _, _) = project("> quote\n\n- one\n- two\n  more\n\n1. a\n2. b\n\n- [ ] todo\n- [x] done\n\n> - nested")
        let blocks = p.blocks.map(\.block)
        #expect(blockTexts(p) == ["quote", "one", "two more", "a", "b", "todo", "done", "nested"])
        #expect(blocks[0].context.quoteDepth == 1)
        #expect(blocks[1].context.marker?.literal == "-")
        #expect(blocks[1].context.listDepth == 1)
        #expect(blocks[3].context.marker == ListMarker(literal: "1.", isOrdered: true, ordinal: 1, number: 1, task: nil))
        #expect(blocks[4].context.marker?.number == 2)
        #expect(blocks[5].context.marker == ListMarker(literal: "- [ ]", isOrdered: false, ordinal: 1, number: 1, task: .unchecked))
        #expect(blocks[6].context.marker?.task == .checked)
        #expect(blocks[7].context.quoteDepth == 1)
        #expect(blocks[7].context.listDepth == 1)
        #expect(blocks[7].context.marker?.literal == "-")
        #expect(!blocks[1].context.isLoose)
        let loose = project("- a\n\n- b").0.blocks.map(\.block)
        #expect(loose[0].context.isLoose)
        // Only the first leaf of an item carries the marker.
        let two = project("- a\n\n  b").0.blocks.map(\.block)
        #expect(two.count == 2)
        #expect(two[0].context.marker != nil)
        #expect(two[1].context.marker == nil)
        #expect(two[1].context.listDepth == 1)
        // An empty item still shows up with its marker.
        let empty = project("- a\n-\n- c").0.blocks.map(\.block)
        #expect(empty.map { $0.cells[0].text } == ["a", "", "c"])
        #expect(empty[1].context.marker?.literal == "-")
    }

    @Test("code blocks keep their content verbatim")
    func code() {
        let fenced = displayBlock("```swift\nlet x = 1\n  y\n```")
        #expect(fenced.cells[0].text == "let x = 1\n  y")
        #expect(fenced.role == .code(info: "swift", isFenced: true))
        #expect(run(fenced, .code) == [0..<13])
        #expect(displayBlock("```\nopen").cells[0].text == "open")
        #expect(displayBlock("```\n```").cells[0].text == "")
        let indented = displayBlock("    a\n\tb\n      c")
        #expect(indented.cells[0].text == "a\nb\n  c")
        #expect(indented.role == .code(info: "", isFenced: false))
    }

    @Test("rules, html, front matter and definitions")
    func otherLeaves() {
        #expect(displayBlock("***").cells[0].text == "")
        #expect(displayBlock("***").role == .thematicBreak)
        let html = displayBlock("<div>\nhi\n</div>")
        #expect(html.cells[0].text == "<div>\nhi\n</div>")
        #expect(html.role == .html)
        let fm = project("---\ntitle: hi\nx: 1\n---\n\nbody").0.blocks.map(\.block)
        #expect(fm[0].role == .frontMatter)
        #expect(fm[0].cells[0].text == "title: hi\nx: 1")
        #expect(fm[1].cells[0].text == "body")
        let def = displayBlock("[r]: /url \"t\"")
        #expect(def.role == .linkReferenceDefinition)
        #expect(def.cells[0].text == "[r]: /url \"t\"")
        #expect(displayText("$$\nE = mc^2\n$$") == "\nE = mc^2\n")
    }

    @Test("tables become one cell per column, padded")
    func tables() {
        let (p, _, _) = project("| a | b |\n|---|:-:|\n| 1 | **2** |\n| 3 |\n| 4 | 5 | 6 |")
        let block = p.blocks[0].block
        let table = try! #require(block.table)
        #expect(table.columns == 2)
        #expect(table.rows == 4)
        #expect(table.alignments == [.none, .center])
        #expect(block.cells.map(\.text) == ["a", "b", "1", "2", "3", "", "4", "5"])
        #expect(block.cells[3].runs.first?.style == .strong)
        #expect(block.cells.count == table.rows * table.columns)
    }

    @Test("multi-byte text maps in UTF-16 units")
    func unicode() {
        let text = "ಕನ್ನಡ **日本** 🙂 e\u{301}!"
        let block = displayBlock(text)
        let display = block.cells[0]
        #expect(display.text == "ಕನ್ನಡ 日本 🙂 e\u{301}!")
        // Source offset of `日` (after "ಕನ್ನಡ **"): 15 bytes of Kannada, space, two stars.
        let kannada = "ಕನ್ನಡ".utf8.count
        #expect(display.displayOffset(forSource: kannada + 3) == "ಕನ್ನಡ ".utf16.count)
        // A caret after the emoji sits after two UTF-16 units.
        let emojiEnd = Array(text.utf8).firstIndex(of: 0x20)! // first space
        _ = emojiEnd
        let afterEmoji = text.utf8.count - "e\u{301}!".utf8.count - 1
        #expect(display.displayOffset(forSource: afterEmoji) == "ಕನ್ನಡ 日本 🙂".utf16.count)
        #expect(display.sourceOffset(forDisplay: "ಕನ್ನಡ 日本 🙂".utf16.count) == afterEmoji)
        // Inside the surrogate pair floors to the scalar start.
        #expect(display.sourceOffset(forDisplay: "ಕನ್ನಡ 日本 ".utf16.count + 1) == afterEmoji - 4)
    }
}

@Suite("Projection reveal")
struct ProjectionRevealTests {
    @Test("emphasis reveals its delimiters while the caret is inside")
    func emphasis() {
        let text = "a **b** c"
        #expect(displayText(text, caret: 0) == "a b c")
        #expect(displayText(text, caret: 2) == "a **b** c")
        #expect(displayText(text, caret: 4) == "a **b** c")
        #expect(displayText(text, caret: 7) == "a **b** c")
        #expect(displayText(text, caret: 8) == "a b c")
        let revealed = project(text, caret: 4).entries[0].blocks[0]
        #expect(run(revealed, .syntax) == [2..<4, 5..<7])
        #expect(run(revealed, .strong) == [2..<7])
        // A caret between the stars stays where it was put.
        let cell = revealed.cells[0]
        #expect(cell.sourceOffset(forDisplay: 3) == 3)
        #expect(cell.displayOffset(forSource: 3) == 3)
    }

    @Test("folded delimiters resolve the caret past them")
    func foldedCaret() {
        let cell = displayBlock("a **b** c").cells[0]
        // Display "a b c": after "a " the caret stands after the opening `**`.
        #expect(cell.sourceOffset(forDisplay: 2) == 4)
        #expect(cell.sourceOffset(forDisplay: 3) == 7)
        #expect(cell.displayOffset(forSource: 2) == 2)
        #expect(cell.displayOffset(forSource: 4) == 2)
        #expect(cell.displayOffset(forSource: 5) == 3)
        #expect(cell.displayOffset(forSource: 7) == 3)
    }

    @Test("link reveal stages: chip, then full destination")
    func linkStages() {
        let text = "see [label](http://x) now"
        #expect(displayText(text, caret: 0) == "see label now")
        #expect(displayText(text, caret: 6) == "see [label]\u{FFFC} now")
        #expect(displayText(text, caret: 13) == "see [label](http://x) now")
        #expect(displayText(text, caret: 21) == "see [label]\u{FFFC} now")
        #expect(displayText(text, caret: 22) == "see label now")
        #expect(displayText(text, caret: 6, preset: .typoraCompatible) == "see [label](http://x) now")
        #expect(displayText(text, caret: 0, preset: .stable) == "see [label]\u{FFFC} now")
        let chip = project(text, caret: 6).entries[0].blocks[0]
        #expect(run(chip, .chip) == [11..<12])
        #expect(chip.cells[0].sourceOffset(forDisplay: 12) == 21)
    }

    @Test("block markers: gutter presets keep text stable, Typora shows them inline")
    func blockMarkers() {
        let text = "# Title\n\n> quote\n\n- item"
        #expect(displayText(text, caret: 3) == "Title\nquote\nitem")
        #expect(project(text, caret: 3).entries[0].blocks[0].isRevealed)
        #expect(!project(text, caret: 12).entries[0].blocks[0].isRevealed)
        #expect(displayText(text, caret: 3, preset: .typoraCompatible) == "# Title\nquote\nitem")
        #expect(displayText(text, caret: 12, preset: .typoraCompatible) == "Title\n> quote\nitem")
        #expect(displayText(text, caret: 20, preset: .typoraCompatible) == "Title\nquote\n- item")
        #expect(displayText("# Title ##", caret: 2) == "Title ##")
        #expect(displayText("Setext\n===", caret: 2) == "Setext\n===")
    }

    @Test("fences, rules, escapes and hard breaks reveal on their line")
    func lineLocal() {
        #expect(displayText("```swift\nlet x\n```", caret: 2) == "```swift\nlet x\n```")
        #expect(displayText("```swift\nlet x\n```", caret: 10) == "let x")
        #expect(displayText("***", caret: 1) == "***")
        #expect(displayText("a \\* b", caret: 3) == "a \\* b")
        #expect(displayText("a \\* b", caret: 0) == "a * b")
        #expect(displayText("a &amp; b", caret: 4) == "a &amp; b")
        #expect(displayText("a  \nb", caret: 1) == "a  \nb")
        #expect(displayText("a  \nb", caret: 5) == "a\nb")
        #expect(displayText("---\nt: 1\n---", caret: 5) == "---\nt: 1\n---")
    }

    @Test("stable preset always shows delimiters")
    func stable() {
        #expect(displayText("a **b** `c`", preset: .stable) == "a **b** `c`")
        let block = project("a **b**", preset: .stable).0.entries[0].blocks[0]
        #expect(run(block, .syntax) == [2..<4, 5..<7])
    }

    @Test("source mode shows everything")
    func sourceMode() {
        let text = "# T\n\n> a **b**\n\n- [ ] c\n\n```\nx\n```"
        let (p, _, _) = project(text, reveal: .everything)
        #expect(p.displayText == "# T\n> a **b**\n- [ ] c\n```\nx\n```")
        checkInvariants(text, p)
    }
}

@Suite("Projection incremental update")
struct ProjectionUpdateTests {
    func sameBlocks(_ a: Projection, _ b: Projection) -> Bool {
        guard a.entries.count == b.entries.count else { return false }
        for (x, y) in zip(a.entries, b.entries) {
            guard x.start == y.start, x.length == y.length, x.blocks.count == y.blocks.count else { return false }
            for (p, q) in zip(x.blocks, y.blocks) {
                guard p.sourceRange == q.sourceRange, p.role == q.role, p.context == q.context, p.isRevealed == q.isRevealed,
                      p.table == q.table, p.cells == q.cells, p.layoutKey == q.layoutKey else { return false }
            }
        }
        return true
    }

    @Test("moving the caret rebuilds only the entries it leaves and enters")
    func caretMoves() {
        let text = "# One\n\nPara **bold**\n\n- item\n\nLast"
        let rope = LipiRope(text)
        var parser = LipiParser(options: .editor)
        parser.parse(rope)
        var projection = Projection()
        let policy = RevealPolicy()
        var r = projection.update(index: parser.index, rope: rope, reveal: policy.revealSet(caret: 2, index: parser.index, rope: rope))
        #expect(r.rebuilt == 4 && r.reused == 0)
        r = projection.update(index: parser.index, rope: rope, reveal: policy.revealSet(caret: 3, index: parser.index, rope: rope))
        #expect(r.rebuilt == 0 && r.reused == 4, "same reveal set: nothing rebuilt")
        r = projection.update(index: parser.index, rope: rope, reveal: policy.revealSet(caret: 14, index: parser.index, rope: rope))
        #expect(r.rebuilt == 2 && r.reused == 2, "leaving the heading, entering the emphasis")
        #expect(r.changedEntries == [0, 1])
        r = projection.update(index: parser.index, rope: rope, reveal: policy.revealSet(caret: 8, index: parser.index, rope: rope))
        #expect(r.rebuilt == 1 && r.reused == 3, "folding the emphasis")
        let fresh = project(text, caret: 8).entries
        #expect(sameBlocks(projection, project(text, caret: 8)))
        _ = fresh
    }

    @Test("edits rebuild the re-parsed entries and match a fresh projection")
    func randomEdits() throws {
        let examples = try SpecFixtures.load("commonmark-0.31.2")
        for seed in UInt64(1)...6 {
            var rng = SplitMix64(seed: seed)
            var parts: [String] = []
            for _ in 0..<16 { parts.append(examples[Int(rng.next() % UInt64(examples.count))].markdown) }
            var buffer = SourceBuffer(parts.joined(separator: "\n"))
            var parser = LipiParser(options: .editor)
            parser.parse(buffer.rope)
            var projection = Projection()
            let policy = RevealPolicy()
            projection.update(index: parser.index, rope: buffer.rope, reveal: .none)
            var totalRebuilt = 0
            for step in 0..<40 {
                let edit = randomEdit(&rng, in: buffer.rope)
                let delta = buffer.apply(edit)
                parser.apply(delta, then: buffer.rope)
                let caret = delta.newRange.upperBound.byte
                let reveal = policy.revealSet(caret: caret, index: parser.index, rope: buffer.rope)
                let result = projection.update(index: parser.index, rope: buffer.rope, reveal: reveal)
                totalRebuilt += result.rebuilt
                let text = buffer.rope.string(in: 0..<buffer.count)
                checkInvariants(text, projection, "seed \(seed) step \(step)")
                var fresh = LipiParser(options: .editor)
                fresh.parse(buffer.rope)
                var freshProjection = Projection()
                freshProjection.update(index: fresh.index, rope: buffer.rope,
                                       reveal: policy.revealSet(caret: caret, index: fresh.index, rope: buffer.rope))
                #expect(sameBlocks(projection, freshProjection), "seed \(seed) step \(step) edit \(edit)")
            }
            _ = totalRebuilt
        }
    }

    @Test("table row edits re-project one row and match a full rebuild")
    func tableRowPatches() {
        for seed in UInt64(1)...6 {
            var rng = SplitMix64(seed: seed)
            var buffer = SourceBuffer(tableDocument(rows: 40, seed: seed))
            var parser = LipiParser(options: .editor)
            parser.parse(buffer.rope)
            var projection = Projection()
            let policy = RevealPolicy()
            projection.update(index: parser.index, rope: buffer.rope, reveal: .none)
            var patched = 0
            for step in 0..<120 {
                let edit = tableRowEdit(&rng, index: parser.index, rope: buffer.rope)
                let delta = buffer.apply(edit)
                parser.apply(delta, then: buffer.rope)
                // Alternate between a caret reveal, reveal-all and no reveal.
                let caret = delta.newRange.upperBound.byte
                let reveal = step % 9 == 8 ? RevealSet.everything
                    : policy.revealSet(caret: caret, index: parser.index, rope: buffer.rope)
                let result = projection.update(index: parser.index, rope: buffer.rope, reveal: reveal)
                patched += result.rowPatched
                let text = buffer.rope.string(in: 0..<buffer.count)
                checkInvariants(text, projection, "seed \(seed) step \(step)")
                // Exactly what a full rebuild from the same index produces…
                var rebuilt = Projection()
                rebuilt.update(index: parser.index, rope: buffer.rope, reveal: reveal)
                let exact = projection.entries.map(\.blocks) == rebuilt.entries.map(\.blocks)
                #expect(exact, "seed \(seed) step \(step) edit \(edit)")
                // …and what a fresh parse projects.
                var fresh = LipiParser(options: .editor)
                fresh.parse(buffer.rope)
                var freshProjection = Projection()
                freshProjection.update(index: fresh.index, rope: buffer.rope,
                                       reveal: step % 9 == 8 ? .everything : policy.revealSet(caret: caret, index: fresh.index, rope: buffer.rope))
                #expect(sameBlocks(projection, freshProjection), "seed \(seed) step \(step) edit \(edit)")
                if !exact {
                    for (x, y) in zip(projection.entries, rebuilt.entries) where x.blocks != y.blocks {
                        let cx = x.blocks[0].cells, cy = y.blocks[0].cells
                        if let c = cx.indices.first(where: { $0 >= cy.count || cx[$0] != cy[$0] }) {
                            Issue.record("entry \(x.id) cell \(c) of \(cx.count)/\(cy.count):\n  patched \(cx[c])\n  rebuilt \(c < cy.count ? "\(cy[c])" : "-")")
                        } else {
                            Issue.record("entry \(x.id): cells equal; patched \(x.blocks[0].sourceRange) key \(x.blocks[0].layoutKey) rebuilt \(y.blocks[0].sourceRange) key \(y.blocks[0].layoutKey)")
                        }
                        break
                    }
                    break
                }
            }
            #expect(patched > 40, "seed \(seed): \(patched) row patches")
        }
    }

    @Test("positions round-trip through the document")
    func positions() {
        let text = "# One\n\nPara **bold** here\n\n| a | b |\n|---|---|\n| c | d |"
        let (p, _, _) = project(text)
        for offset in 0...text.utf8.count {
            let position = try! #require(p.position(forSource: offset))
            let back = p.sourceOffset(for: position)
            let again = try! #require(p.position(forSource: back))
            #expect(again == position, "offset \(offset) → \(position) → \(back) → \(again)")
        }
        let d = p.position(forSource: text.utf8.count - 2)!
        #expect(d.entry == 2 && d.block == 0 && d.cell == 3 && d.offset == 1)
    }
}
