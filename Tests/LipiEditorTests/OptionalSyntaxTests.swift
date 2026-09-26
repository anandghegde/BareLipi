import Foundation
import LipiCore
import LipiEditor
import Testing

@Suite("Optional syntax (§6.13)")
@MainActor
struct OptionalSyntaxTests {
    @Test func togglingReparsesAndKeepsTextSelectionAndUndo() {
        let c = EditorController(text: "x H~2~O 2^10^ ==hi==")
        _ = c.insert("y")
        let before = c.projection.displayText
        #expect(before.contains("~2~") == false)  // GFM: single-tilde strikethrough
        #expect(before.contains("2^10^"))
        #expect(before.contains("==hi=="))
        let caret = c.caret
        c.setOptionalSyntax(subscript: true, superscript: true, highlight: true)
        #expect(c.parserOptions.extensions.isSuperset(of: [.subscript, .superscript, .highlight]))
        #expect(c.projection.displayText == "yx H2O 210 hi")
        #expect(c.caret == caret)
        #expect(c.canUndo)
        c.setOptionalSyntax(subscript: false, superscript: false, highlight: false)
        #expect(c.projection.displayText == before)
    }

    @Test func highlightIsAnInlineStyleAfterTyping() {
        let c = EditorController(text: "")
        c.setOptionalSyntax(subscript: false, superscript: false, highlight: true)
        for ch in "a ==b== c" { _ = c.insert(String(ch)) }
        #expect(c.string == "a ==b== c")
        #expect(c.projection.displayText == "a b c")
    }
}

@Suite("Table of contents navigation (§6.13)")
@MainActor
struct TableOfContentsNavigationTests {
    @Test func clickingALineJumpsToItsHeading() {
        let text = "intro\n\n[toc]\n\n# One\n\n## Two\n\nbody\n"
        let c = EditorController(text: text)
        _ = c.prepare(CGRect(x: 0, y: 0, width: 800, height: 2000))
        let tocStart = text.utf8.count - "[toc]\n\n# One\n\n## Two\n\nbody\n".utf8.count
        let first = c.caretRect(forSource: tocStart)
        let line1 = CGPoint(x: first.minX + 20, y: first.midY)
        let line2 = CGPoint(x: first.minX + 40, y: first.midY + first.height * 1.1)
        #expect(c.tableOfContentsItem(at: line1)?.title == "One")
        #expect(c.tableOfContentsItem(at: line2)?.title == "Two")
        #expect(c.jumpToTableOfContentsItem(at: line2))
        #expect(c.caret == text.utf8.count - "## Two\n\nbody\n".utf8.count)
        // Not on a toc block.
        #expect(c.tableOfContentsItem(at: c.caretRect(forSource: 1).origin) == nil)
    }
}
