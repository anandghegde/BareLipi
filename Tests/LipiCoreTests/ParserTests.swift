import Foundation
import Testing
@testable import LipiCore

// MARK: - Helpers

/// Markdown-shaped tokens for random edits: delimiters, markers, whitespace,
/// escapes, entities, definitions and a few multi-byte characters.
let editTokens: [String] = [
    "*", "**", "_", "__", "`", "``", "[", "]", "(", ")", "!", "#", "# ", "##", ">", "> ", "- ", "+ ", "1. ", "2) ",
    "\n", "\n\n", "\n\n\n", " ", "  ", "   ", "    ", "\t", "\r\n", "a", "foo", "bar baz", "|", "| a |", "~~", "~", "$", "$$",
    "\\", "\\*", "<", ">", "<b>", "</div>", "&amp;", "&#x1F600;", "[foo]: /url\n", "[foo]", "[foo][]", "![x](y)",
    "```\n", "~~~\n", "```swift\n", "---\n", "***\n", "===\n", "<div>\n", "<!-- c -->", "[^1]", "[^1]: note\n",
    "- [ ] ", "- [x] ", "http://x.y/z", "<a@b.c>", "ಕನ್ನಡ", "日本", "🙂", "e\u{301}",
]

func randomEdit(_ rng: inout SplitMix64, in rope: LipiRope) -> Edit {
    let count = rope.count
    let at = rope.floorScalarBoundary(count == 0 ? 0 : Int(rng.next() % UInt64(count + 1)))
    if count > 0 && rng.next() % 3 == 0 {
        let length = Int(rng.next() % 12) + 1
        let end = rope.floorScalarBoundary(min(count, at + length))
        if end > at { return Edit(replacing: at..<end, with: "") }
    }
    return Edit(replacing: at..<at, with: editTokens[Int(rng.next() % UInt64(editTokens.count))])
}

struct RangeChecker {
    let bytes: [UInt8]
    var failures: [String] = []
    var seen = Set<NodeID>()

    init(_ text: String) { bytes = Array(text.utf8) }

    mutating func fail(_ message: String) {
        if failures.count < 40 { failures.append(message) }
    }

    func byte(_ i: Int) -> UInt8? { i >= 0 && i < bytes.count ? bytes[i] : nil }
    func slice(_ r: Range<Int>) -> String { String(decoding: bytes[r.clamped(to: 0..<bytes.count)], as: UTF8.self) }

    mutating func check(_ parser: LipiParser) {
        let index = parser.index
        if index.length != bytes.count { fail("index length \(index.length) != \(bytes.count)") }
        var expectedStart = 0
        for i in index.entries.indices {
            if index.start(of: i) != expectedStart { fail("entry \(i) starts at \(index.start(of: i)), expected \(expectedStart)") }
            expectedStart += index.entries[i].length
            let block = index.absoluteBlock(at: i)
            if block.range.lowerBound < index.start(of: i) || block.range.upperBound > index.end(of: i) {
                fail("entry \(i) block \(block.range) outside span \(index.start(of: i))..<\(index.end(of: i))")
            }
            check(block, parent: 0..<bytes.count)
        }
    }

    mutating func check(_ block: Block, parent: Range<Int>) {
        if !seen.insert(block.id).inserted { fail("duplicate id \(block.id)") }
        let r = block.range
        if r.lowerBound < parent.lowerBound || r.upperBound > parent.upperBound {
            fail("\(block.kind) \(r) escapes parent \(parent)")
        }
        let first = byte(r.lowerBound)
        switch block.kind {
        case .heading(_, let isSetext):
            if !isSetext, first != 0x23 { fail("ATX heading at \(r) starts with \(slice(r).prefix(8).debugDescription)") }
        case .thematicBreak:
            if let f = first, f != 0x2D, f != 0x2A, f != 0x5F { fail("thematic break at \(r) starts with \(f)") }
        case .blockQuote:
            if first != 0x3E { fail("block quote at \(r) starts with \(slice(r).prefix(8).debugDescription)") }
        case .listItem:
            if let f = first, f != 0x2D, f != 0x2B, f != 0x2A, !(f >= 0x30 && f <= 0x39) {
                fail("list item at \(r) starts with \(slice(r).prefix(8).debugDescription)")
            }
        case .codeBlock(let info):
            if info.contentRange.lowerBound < r.lowerBound || info.contentRange.upperBound > r.upperBound {
                fail("code content \(info.contentRange) outside block \(r)")
            }
            if info.isFenced, let f = first, f != 0x60, f != 0x7E { fail("fence at \(r) starts with \(f)") }
        case .htmlBlock:
            if first != 0x3C { fail("html block at \(r) starts with \(slice(r).prefix(8).debugDescription)") }
        case .linkReferenceDefinition, .footnoteDefinition:
            if first != 0x5B { fail("\(block.kind) at \(r) starts with \(slice(r).prefix(8).debugDescription)") }
        case .frontMatter:
            if r.lowerBound != 0 { fail("front matter at \(r)") }
        case .paragraph:
            if let f = first, f == 0x20 || f == 0x09 || f == 0x0A || f == 0x0D {
                fail("paragraph at \(r) starts with whitespace: \(slice(r).prefix(8).debugDescription)")
            }
        default: break
        }
        var cursor = r.lowerBound
        for child in block.children {
            if child.range.lowerBound < cursor { fail("child \(child.kind) \(child.range) overlaps previous (cursor \(cursor)) in \(block.kind) \(r)") }
            cursor = max(cursor, child.range.upperBound)
            check(child, parent: r)
        }
        var inlineCursor = r.lowerBound
        for inline in block.inlines {
            if inline.range.lowerBound < inlineCursor { fail("inline \(inline.kind) \(inline.range) overlaps previous in \(block.kind) \(r)") }
            inlineCursor = max(inlineCursor, inline.range.upperBound)
            check(inline, parent: r)
        }
    }

    mutating func check(_ inline: Inline, parent: Range<Int>) {
        if !seen.insert(inline.id).inserted { fail("duplicate id \(inline.id)") }
        let r = inline.range
        if r.lowerBound < parent.lowerBound || r.upperBound > parent.upperBound {
            fail("inline \(inline.kind) \(r) escapes parent \(parent)")
        }
        if !inline.isApproximate {
            let first = byte(r.lowerBound)
            let last = r.isEmpty ? nil : byte(r.upperBound - 1)
            switch inline.kind {
            case .text(let literal):
                let source = slice(r)
                let plain = !source.utf8.contains(where: { $0 == 0x5C || $0 == 0x26 || $0 == 0x0A || $0 == 0x0D })
                if plain, source != literal {
                    fail("text \(r) literal \(literal.debugDescription) != source \(source.debugDescription)")
                }
            case .emphasis:
                if let f = first, f != 0x2A, f != 0x5F { fail("emphasis at \(r): \(slice(r).debugDescription)") }
                if let l = last, l != 0x2A, l != 0x5F { fail("emphasis end at \(r): \(slice(r).debugDescription)") }
            case .strong:
                if let f = first, f != 0x2A, f != 0x5F { fail("strong at \(r): \(slice(r).debugDescription)") }
                if r.count < 4 { fail("strong too short at \(r): \(slice(r).debugDescription)") }
            case .code:
                if first != 0x60 || last != 0x60 { fail("code span at \(r): \(slice(r).debugDescription)") }
            case .link(_, _, let isAutolink):
                if !isAutolink, first != 0x5B { fail("link at \(r): \(slice(r).debugDescription)") }
                if !isAutolink, let l = last, l != 0x29, l != 0x5D { fail("link end at \(r): \(slice(r).debugDescription)") }
            case .image:
                if first != 0x21 { fail("image at \(r): \(slice(r).debugDescription)") }
            case .strikethrough:
                if first != 0x7E || last != 0x7E { fail("strikethrough at \(r): \(slice(r).debugDescription)") }
            case .footnoteReference:
                if first != 0x5B || byte(r.lowerBound + 1) != 0x5E { fail("footnote ref at \(r): \(slice(r).debugDescription)") }
            case .math:
                if first != 0x24 || last != 0x24 { fail("math at \(r): \(slice(r).debugDescription)") }
            case .html:
                if first != 0x3C { fail("inline html at \(r): \(slice(r).debugDescription)") }
            case .softBreak, .lineBreak:
                if !r.isEmpty, !bytes[r].contains(where: { $0 == 0x0A || $0 == 0x0D }) {
                    fail("\(inline.kind) at \(r) has no newline: \(slice(r).debugDescription)")
                }
            }
        }
        var cursor = r.lowerBound
        for child in inline.children {
            if child.range.lowerBound < cursor { fail("inline child \(child.kind) \(child.range) overlaps previous in \(inline.kind) \(r)") }
            cursor = max(cursor, child.range.upperBound)
            check(child, parent: r)
        }
    }
}

func allExamples() throws -> [SpecExample] {
    try ["commonmark-0.31.2", "gfm-spec-0.29", "gfm-extensions", "gfm-regression"].flatMap { try SpecFixtures.load($0) }
}

func firstBlock(_ text: String, options: ParserOptions = .editor) -> Block {
    var parser = LipiParser(options: options)
    parser.parse(text)
    return parser.blocks[0]
}

// MARK: - Tests

@Suite("LipiParser")
struct ParserTests {
    @Test("ranges nest, tile and point at their markers on every spec example")
    func rangeInvariants() throws {
        var failures: [String] = []
        for example in try allExamples() {
            for options in [ParserOptions.editor, .commonMark] {
                var parser = LipiParser(options: options)
                parser.parse(example.markdown)
                var checker = RangeChecker(example.markdown)
                checker.check(parser)
                if !checker.failures.isEmpty {
                    failures.append("example \(example.number) (\(example.section)) \(example.markdown.debugDescription):\n  "
                                    + checker.failures.prefix(4).joined(separator: "\n  "))
                }
            }
        }
        let report = "\(failures.count) examples with range problems\n" + failures.prefix(12).joined(separator: "\n")
        #expect(failures.isEmpty, Comment(rawValue: report))
    }

    @Test("incremental re-parse equals a full parse under random edits", arguments: Array(1...16) as [UInt64])
    func incremental(seed: UInt64) throws {
        let examples = try allExamples()
        var rng = SplitMix64(seed: seed)
        var parts: [String] = []
        for _ in 0..<24 { parts.append(examples[Int(rng.next() % UInt64(examples.count))].markdown) }
        var buffer = SourceBuffer(parts.joined(separator: "\n"))
        var incremental = LipiParser(options: .editor)
        incremental.parse(buffer.rope)
        var totalReparsed = 0
        var totalBytes = 0
        for step in 0..<60 {
            let edit = randomEdit(&rng, in: buffer.rope)
            let delta = buffer.apply(edit)
            incremental.apply(delta, then: buffer.rope)
            totalReparsed += incremental.stats.lastReparseBytes
            totalBytes += buffer.count
            var full = LipiParser(options: .editor)
            full.parse(buffer.rope)
            let a = incremental.blocks, b = full.blocks
            let same = a.count == b.count && zip(a, b).allSatisfy { $0.isStructurallyEqual(to: $1) }
            #expect(same, "seed \(seed) step \(step) edit \(edit): incremental \(a.count) blocks vs full \(b.count)")
            #expect(incremental.references == full.references, "seed \(seed) step \(step): references differ")
            if !same {
                let firstDiff = zip(a, b).enumerated().first { !$0.element.0.isStructurallyEqual(to: $0.element.1) }
                if let d = firstDiff {
                    Issue.record("first difference at block \(d.offset):\n  incremental \(d.element.0)\n  full        \(d.element.1)")
                }
                break
            }
            var checker = RangeChecker(buffer.rope.string)
            checker.check(incremental)
            #expect(checker.failures.isEmpty, Comment(rawValue: "seed \(seed) step \(step): " + checker.failures.prefix(4).joined(separator: "; ")))
        }
        // Random structural edits (an unclosed fence swallows the rest of the file) make the
        // re-parsed volume data-dependent; `locality` checks the cost of ordinary edits.
        #expect(totalReparsed > 0 && totalBytes > 0)
    }

    @Test("a small edit re-parses a handful of blocks")
    func locality() {
        let paragraph = "Lorem ipsum *dolor* sit amet, `consectetur` adipiscing elit.\n\n"
        let text = String(repeating: paragraph, count: 400)
        var buffer = SourceBuffer(text)
        var parser = LipiParser(options: .editor)
        parser.parse(buffer.rope)
        #expect(parser.index.count == 400)
        let middle = buffer.count / 2
        let delta = buffer.apply(.insert("x", at: SourceOffset(buffer.rope.floorScalarBoundary(middle))))
        parser.apply(delta, then: buffer.rope)
        #expect(parser.stats.lastReparseEntries == 1)
        #expect(parser.stats.lastReparseBytes <= paragraph.utf8.count * 3 + 1)
        #expect(parser.stats.lastReparseHadReferencePass == false)
        #expect(parser.index.count == 400)
        #expect(parser.index.length == buffer.count)
        var full = LipiParser(options: .editor)
        full.parse(buffer.rope)
        #expect(zip(parser.blocks, full.blocks).allSatisfy { $0.isStructurallyEqual(to: $1) })
        // Untouched blocks keep their node identity across the edit.
        let firstID = parser.blocks[0].id
        let lastID = parser.blocks[399].id
        // Typing at the very start and the very end stays local too.
        let d1 = buffer.apply(.insert("# ", at: .zero))
        parser.apply(d1, then: buffer.rope)
        #expect(parser.stats.lastReparseEntries == 1)
        #expect(parser.stats.lastReparseBytes <= paragraph.utf8.count * 2 + 2)
        #expect(parser.blocks[0].kind == .heading(level: 1, isSetext: false))
        #expect(parser.blocks[399].id == lastID)
        let d2 = buffer.apply(.insert("tail", at: SourceOffset(buffer.count)))
        parser.apply(d2, then: buffer.rope)
        #expect(parser.stats.lastReparseEntries <= 2)
        #expect(parser.stats.lastReparseBytes <= paragraph.utf8.count * 2 + 4)
        #expect(parser.blocks.count == 401)
        #expect(parser.blocks[0].id != firstID)
        #expect(parser.index.length == buffer.count)
        var full2 = LipiParser(options: .editor)
        full2.parse(buffer.rope)
        #expect(parser.blocks.count == full2.blocks.count && zip(parser.blocks, full2.blocks).allSatisfy { $0.isStructurallyEqual(to: $1) })
    }

    @Test("editing a reference definition re-parses the links that use it")
    func referenceDefinitionEdit() {
        var buffer = SourceBuffer("[a]\n\nplain\n\n[a]: /one\n")
        var parser = LipiParser(options: .editor)
        parser.parse(buffer.rope)
        #expect(parser.references == [ReferenceDefinition(label: "a", destination: "/one", title: "")])
        if case .link(let destination, _, _) = parser.blocks[0].inlines[0].kind { #expect(destination == "/one") } else {
            Issue.record("expected a link, got \(parser.blocks[0].inlines)")
        }
        let defStart = buffer.rope.string.utf8.distance(from: buffer.rope.string.utf8.startIndex, to: buffer.rope.string.range(of: "/one")!.lowerBound.samePosition(in: buffer.rope.string.utf8)!)
        let delta = buffer.apply(Edit(replacing: defStart..<(defStart + 4), with: "/two"))
        parser.apply(delta, then: buffer.rope)
        #expect(parser.stats.lastReparseHadReferencePass)
        if case .link(let destination, _, _) = parser.blocks[0].inlines[0].kind { #expect(destination == "/two") } else {
            Issue.record("expected a link after the edit, got \(parser.blocks[0].inlines)")
        }
        // Removing the definition turns the link back into text.
        let delta2 = buffer.apply(Edit(replacing: (defStart - 5)..<buffer.count, with: ""))
        parser.apply(delta2, then: buffer.rope)
        #expect(parser.references.isEmpty)
        if case .text = parser.blocks[0].inlines[0].kind {} else { Issue.record("expected text, got \(parser.blocks[0].inlines)") }
        var full = LipiParser(options: .editor)
        full.parse(buffer.rope)
        #expect(parser.blocks.count == full.blocks.count && zip(parser.blocks, full.blocks).allSatisfy { $0.isStructurallyEqual(to: $1) })
    }

    @Test("first definition wins across regions")
    func referenceOrdering() {
        var buffer = SourceBuffer("[x]: /first\n\npara\n\n[x]\n\n[x]: /second\n")
        var parser = LipiParser(options: .editor)
        parser.parse(buffer.rope)
        func destination() -> String? {
            for block in parser.blocks {
                if case .paragraph = block.kind, let inline = block.inlines.first, case .link(let d, _, _) = inline.kind { return d }
            }
            return nil
        }
        #expect(destination() == "/first")
        let paraStart = 13
        let delta = buffer.apply(.insert("more ", at: SourceOffset(paraStart)))
        parser.apply(delta, then: buffer.rope)
        #expect(destination() == "/first")
        let linkStart = buffer.rope.string.utf8.count - 14
        let delta2 = buffer.apply(.insert("!", at: SourceOffset(linkStart)))
        parser.apply(delta2, then: buffer.rope)
        var full = LipiParser(options: .editor)
        full.parse(buffer.rope)
        #expect(zip(parser.blocks, full.blocks).allSatisfy { $0.isStructurallyEqual(to: $1) })
    }

    @Test("front matter")
    func frontMatter() {
        let yaml = "---\ntitle: x\n---\n# Heading\n"
        let b = firstBlock(yaml)
        #expect(b.kind == .frontMatter(.yaml))
        #expect(b.range == 0..<16)
        var parser = LipiParser(options: .editor)
        parser.parse(yaml)
        #expect(parser.blocks.count == 2)
        #expect(parser.blocks[1].kind == .heading(level: 1, isSetext: false))
        #expect(parser.blocks[1].range == 17..<26)

        #expect(firstBlock("+++\na = 1\n+++\ntext\n").kind == .frontMatter(.toml))
        #expect(firstBlock("---\ntitle: x\n...\ntext\n").kind == .frontMatter(.yaml))
        #expect(firstBlock("---\r\ntitle: x\r\n---\r\ntext\r\n").range == 0..<18)
        #expect(firstBlock("---  \ntitle: x\n---\t\ntext\n").kind == .frontMatter(.yaml))
        #expect(firstBlock("---\ntitle: x\n---").range == 0..<16)
        #expect(firstBlock("----\ntitle\n---\n").kind == .thematicBreak)
        #expect(firstBlock("---\nnot closed\n").kind == .thematicBreak)  // unterminated: other tools see a rule
        #expect(firstBlock("--- x\ntext\n---\n").kind != .frontMatter(.yaml))
        #expect(firstBlock("text\n---\n").kind == .heading(level: 2, isSetext: true))
        #expect(FrontMatter.detect(in: LipiRope("--")) == nil)
        #expect(FrontMatter.detect(in: LipiRope("")) == nil)

        // Editing inside the front matter keeps everything consistent.
        var buffer = SourceBuffer(yaml)
        parser.parse(buffer.rope)
        let delta = buffer.apply(.insert("author: y\n", at: SourceOffset(13)))
        parser.apply(delta, then: buffer.rope)
        #expect(parser.blocks[0].range == 0..<26)
        #expect(parser.blocks[1].range == 27..<36)
        let delta2 = buffer.apply(Edit(replacing: 23..<26, with: ""))  // remove closing delimiter
        parser.apply(delta2, then: buffer.rope)
        #expect(parser.blocks.map(\.kind) == [.thematicBreak, .paragraph, .heading(level: 1, isSetext: false)])
        #expect(parser.index.length == buffer.count)
        var full = LipiParser(options: .editor)
        full.parse(buffer.rope)
        #expect(zip(parser.blocks, full.blocks).allSatisfy { $0.isStructurallyEqual(to: $1) })
        let delta3 = buffer.apply(.insert("---\n", at: SourceOffset(23)))  // and put it back
        parser.apply(delta3, then: buffer.rope)
        #expect(parser.blocks.map(\.kind) == [.frontMatter(.yaml), .heading(level: 1, isSetext: false)])
    }

    @Test("math")
    func math() {
        let b = firstBlock("a $x^2$ b $$y$$ c $ d$ e \\$f$ g")
        let kinds = b.inlines.map(\.kind)
        #expect(kinds.contains(.math("x^2", isDisplay: false)))
        #expect(kinds.contains(.math("y", isDisplay: true)))
        #expect(kinds.filter { if case .math = $0 { return true } else { return false } }.count == 2)
        #expect(b.inlines[1].range == 2..<7)
        #expect(b.inlines[3].range == 10..<15)
        #expect(firstBlock("$5 and $6", options: .editor).inlines.allSatisfy { if case .math = $0.kind { return false } else { return true } })
        #expect(firstBlock("$x$", options: .gfm).inlines.count == 1)
    }

    @Test("tables")
    func tables() {
        let text = "| a | b |\n|:--|--:|\n| *c* | d \\| e |\n"
        let b = firstBlock(text)
        #expect(b.kind == .table(alignments: [.left, .right]))
        #expect(b.range == 0..<(text.utf8.count - 1))
        #expect(b.children.count == 2)
        #expect(b.children[0].kind == .tableRow(isHeader: true))
        #expect(b.children[0].range == 0..<9)
        #expect(b.children[1].kind == .tableRow(isHeader: false))
        let cells = b.children[1].children
        #expect(cells.count == 2)
        #expect(cells[0].range == 22..<25)
        #expect(cells[0].inlines.first?.kind == .emphasis)
        #expect(cells[0].inlines.first?.range == 22..<25)
        #expect(cells[1].range == 28..<34)
        #expect(cells[1].inlines.first?.kind == .text("d | e"))
        #expect(b.children[0].children[0].range == 2..<3)
        // Header-only tables and tables without leading pipes.
        let b2 = firstBlock("a | b\n--|--\n1 | 2")
        #expect(b2.children.count == 2)
        #expect(b2.children[0].range == 0..<5)
        #expect(b2.children[1].children[1].range == 16..<17)
    }

    @Test("lists, tasks, quotes and code")
    func containers() {
        let list = firstBlock("- [ ] one\n- [x] two\n\n  para\n")
        guard case .list(let info) = list.kind else { Issue.record("not a list: \(list.kind)"); return }
        #expect(info.isOrdered == false && info.bullet == UInt8(ascii: "-") && info.isTight == false)
        #expect(list.range == 0..<27)
        #expect(list.children.count == 2)
        #expect(list.children[0].kind == .listItem(task: .unchecked))
        #expect(list.children[0].range == 0..<9)
        #expect(list.children[1].kind == .listItem(task: .checked))
        #expect(list.children[1].range == 10..<27)
        #expect(list.children[1].children.count == 2)
        #expect(list.children[1].children[1].range == 23..<27)

        let ordered = firstBlock("3) a\n4) b\n")
        guard case .list(let oinfo) = ordered.kind else { Issue.record("not a list"); return }
        #expect(oinfo.isOrdered && oinfo.start == 3 && oinfo.delimiter == .parenthesis && oinfo.isTight)

        let quote = firstBlock("> a\n> > b\n>\n> c\n")
        #expect(quote.kind == .blockQuote)
        #expect(quote.range == 0..<15)
        #expect(quote.children.count == 3)
        #expect(quote.children[1].kind == .blockQuote)
        #expect(quote.children[1].range == 6..<9)

        let fenced = firstBlock("```swift\nlet x = 1\n```\n")
        guard case .codeBlock(let finfo) = fenced.kind else { Issue.record("not code"); return }
        #expect(finfo.isFenced && finfo.info == "swift" && finfo.isClosed)
        #expect(fenced.range == 0..<22)
        #expect(finfo.contentRange == 9..<19)

        let open = firstBlock("~~~\ncode\n")
        guard case .codeBlock(let oinfo2) = open.kind else { Issue.record("not code"); return }
        #expect(!oinfo2.isClosed)
        #expect(oinfo2.contentRange == 4..<8)
        #expect(open.range == 0..<8)

        let indented = firstBlock("    a\n\n    b\n\n")
        guard case .codeBlock(let iinfo) = indented.kind else { Issue.record("not code"); return }
        #expect(!iinfo.isFenced)
        #expect(indented.range == 0..<12)
        #expect(iinfo.contentRange == 0..<12)

        let setext = firstBlock("Title\n=====\n")
        #expect(setext.kind == .heading(level: 1, isSetext: true) && setext.range == 0..<11)
        let atx = firstBlock("## Title ##\n")
        #expect(atx.kind == .heading(level: 2, isSetext: false) && atx.range == 0..<11)
        #expect(atx.inlines.first?.range == 3..<8)
        let html = firstBlock("<div>\nx\n</div>\n\npara")
        #expect(html.kind == .htmlBlock(type: 6))
        #expect(html.range == 0..<14)
        let hr = firstBlock("  * * *  \n")
        #expect(hr.kind == .thematicBreak && hr.range == 2..<9)
    }

    @Test("footnotes and reference definitions keep their place")
    func footnotesAndDefinitions() {
        let text = "See[^n] and [r].\n\n[^n]: Note *here*.\n\n[r]: /u \"t\"\n"
        var parser = LipiParser(options: .editor)
        parser.parse(text)
        let blocks = parser.blocks
        #expect(blocks.count == 3)
        #expect(blocks[0].inlines[1].kind == .footnoteReference(label: "n"))
        #expect(blocks[0].inlines[1].range == 3..<7)
        #expect(blocks[0].inlines[3].kind == .link(destination: "/u", title: "t", isAutolink: false))
        #expect(blocks[0].inlines[3].range == 12..<15)
        #expect(blocks[1].kind == .footnoteDefinition(label: "n"))
        #expect(blocks[1].range == 18..<36)
        #expect(blocks[1].children.first?.kind == .paragraph)
        #expect(blocks[1].children.first?.range == 24..<36)
        #expect(blocks[2].kind == .linkReferenceDefinition(ReferenceDefinition(label: "r", destination: "/u", title: "\"t\"")))
        #expect(blocks[2].range == 38..<49)
        #expect(parser.references.count == 1)

        // A definition inside a container lands inside it.
        let quoted = firstBlock("> [a]: /x\n> [a]\n")
        #expect(quoted.kind == .blockQuote)
        #expect(quoted.children.count == 2)
        #expect(quoted.children[0].kind == .linkReferenceDefinition(ReferenceDefinition(label: "a", destination: "/x", title: "")))
        #expect(quoted.children[0].range == 2..<9)
        #expect(quoted.children[1].range == 12..<15)
    }

    @Test("inline ranges")
    func inlineRanges() {
        let b = firstBlock("a **b *c*** `d` <x@y.z> https://e.f ~~g~~ ![i](j \"k\") h\\*  \nl")
        let kinds = b.inlines.map(\.kind)
        #expect(b.inlines[1].kind == .strong && b.inlines[1].range == 2..<11)
        #expect(b.inlines[1].children[1].kind == .emphasis && b.inlines[1].children[1].range == 6..<9)
        #expect(b.inlines[3].kind == .code("d") && b.inlines[3].range == 12..<15)
        #expect(b.inlines[5].kind == .link(destination: "mailto:x@y.z", title: "", isAutolink: true) && b.inlines[5].range == 16..<23)
        #expect(b.inlines[7].kind == .link(destination: "https://e.f", title: "", isAutolink: true) && b.inlines[7].range == 24..<35)
        #expect(b.inlines[9].kind == .strikethrough && b.inlines[9].range == 36..<41)
        #expect(b.inlines[11].kind == .image(destination: "j", title: "k"))
        #expect(b.inlines[11].range == 42..<53)
        #expect(kinds.contains(.lineBreak))
        #expect(b.inlines.last?.kind == .text("l"))
        #expect(b.inlines.last?.range == 60..<61)
    }

    @Test("empty and whitespace documents")
    func degenerate() {
        var parser = LipiParser(options: .editor)
        parser.parse("")
        #expect(parser.blocks.isEmpty && parser.index.length == 0)
        parser.parse("\n\n  \n")
        #expect(parser.index.length == 5)
        var buffer = SourceBuffer("")
        parser.parse(buffer.rope)
        let delta = buffer.apply(.insert("# Hi", at: .zero))
        parser.apply(delta, then: buffer.rope)
        #expect(parser.blocks.first?.kind == .heading(level: 1, isSetext: false))
        let delta2 = buffer.apply(Edit(replacing: 0..<4, with: ""))
        parser.apply(delta2, then: buffer.rope)
        #expect(parser.blocks.isEmpty && parser.index.length == 0)
        let delta3 = buffer.apply(.insert("x", at: .zero))
        parser.apply(delta3, then: buffer.rope)
        #expect(parser.blocks.count == 1 && parser.blocks[0].kind == .paragraph)
    }

    @Test("HTML rendering honours options")
    func html() {
        #expect(LipiParser.renderHTML("~~a~~ | b\n", options: .commonMark) == "<p>~~a~~ | b</p>\n")
        #expect(LipiParser.renderHTML("~~a~~\n", options: .gfm) == "<p><del>a</del></p>\n")
        #expect(LipiParser.renderHTML("$x$\n", options: .editor).contains("math inline"))
        #expect(LipiParser.renderHTML("<script>x</script>\n", options: .gfm) == "&lt;script>x&lt;/script>\n")
    }
}
