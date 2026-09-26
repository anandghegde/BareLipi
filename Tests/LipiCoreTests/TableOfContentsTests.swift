import Foundation
import Testing
@testable import LipiCore

@Suite("Table of contents (§6.13)")
struct TableOfContentsTests {
    let doc = "[toc]\n\n# Intro\n\n## Setup {#install}\n\n- item\n\n  ### Nested\n\n# Intro\n"

    func toc(_ text: String) -> TableOfContents {
        var parser = LipiParser(options: .editor)
        parser.parse(text)
        return TableOfContents(index: parser.index)
    }

    @Test func itemsLevelsAnchorsAndOffsets() {
        let t = toc(doc)
        #expect(t.items.map(\.title) == ["Intro", "Setup", "Nested", "Intro"])
        #expect(t.items.map(\.anchor) == ["intro", "install", "nested", "intro-1"])
        #expect(t.items.map(\.level) == [1, 2, 3, 1])
        let bytes = Array(doc.utf8)
        #expect(t.items.allSatisfy { bytes[$0.offset] == UInt8(ascii: "#") })
    }

    @Test func showsHeadingsInPlaceAndRevealsAtTheCaret() {
        let (p, _, _) = project(doc)
        #expect(p.tableOfContents?.items.count == 4)
        let block = p.entries[0].blocks[0]
        #expect(block.context.isTableOfContents)
        #expect(block.cells[0].text == "Intro\n\u{2003}\u{2003}Setup\n\u{2003}\u{2003}\u{2003}\u{2003}Nested\nIntro")
        var checker = ProjectionChecker(doc)
        checker.check(p)
        #expect(checker.failures.isEmpty)
        // The caret in the placeholder shows `[toc]`.
        let revealed = project(doc, caret: 2)
        #expect(revealed.entries[0].blocks[0].cells[0].text == "[toc]")
        #expect(!revealed.entries[0].blocks[0].context.isTableOfContents)
        // No placeholder, nothing computed.
        #expect(project("# A\n").0.tableOfContents == nil)
    }

    @Test func updatesWhenAHeadingChangesAndIsReusedOtherwise() {
        var buffer = SourceBuffer(doc)
        var parser = LipiParser(options: .editor)
        parser.parse(buffer.rope)
        var projection = Projection()
        projection.update(index: parser.index, rope: buffer.rope, reveal: .none)
        // Editing a paragraph: the toc entry is reused.
        let para = doc.utf8.count
        var delta = buffer.apply(.insert("\ntext\n", at: SourceOffset(para)))
        parser.apply(delta, then: buffer.rope)
        var result = projection.update(index: parser.index, rope: buffer.rope, reveal: .none)
        #expect(!result.changedEntries.contains(0))
        // Renaming a heading rebuilds it.
        let at = doc.utf8.count - "Intro\n".utf8.count
        delta = buffer.apply(.insert("More ", at: SourceOffset(at)))
        parser.apply(delta, then: buffer.rope)
        result = projection.update(index: parser.index, rope: buffer.rope, reveal: .none)
        #expect(result.changedEntries.contains(0))
        #expect(projection.entries[0].blocks[0].cells[0].text.hasSuffix("\nMore Intro"))
    }

    @Test func emptyDocumentShowsAPlaceholder() {
        #expect(displayText("[toc]\n\ntext").hasPrefix("Table of Contents"))
    }

    @Test func exportsNestedListsWithAnchors() {
        let t = toc(doc)
        #expect(t.markdown() == "- [Intro](#intro)\n  - [Setup](#install)\n    - [Nested](#nested)\n- [Intro](#intro-1)\n")
        #expect(t.html() == """
            <nav class="toc">
            <ul>
            <li><a href="#intro">Intro</a>
            <ul>
            <li><a href="#install">Setup</a>
            <ul>
            <li><a href="#nested">Nested</a></li>
            </ul>
            </li>
            </ul>
            </li>
            <li><a href="#intro-1">Intro</a></li>
            </ul>
            </nav>

            """)
        // A shallower heading after a deeper first one starts a new list.
        let odd = TableOfContents(items: [.init(level: 2, title: "B", anchor: "b", offset: 0),
                                          .init(level: 1, title: "A & <c>", anchor: "a", offset: 5)])
        #expect(odd.html() == "<nav class=\"toc\">\n<ul>\n<li><a href=\"#b\">B</a></li>\n</ul>\n<ul>\n<li><a href=\"#a\">A &amp; &lt;c&gt;</a></li>\n</ul>\n</nav>\n")
    }
}
