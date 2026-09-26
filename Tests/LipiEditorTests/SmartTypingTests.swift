import LipiCore
import LipiEditor
import Testing

@Suite("Smart typing")
@MainActor
struct SmartTypingTests {
    // MARK: Enter

    @Test func enterContinuesLists() {
        expectCommand("- a|", "- a\n- |") { $0.insertNewline() }
        expectCommand("* a|", "* a\n* |") { $0.insertNewline() }
        expectCommand("1. a|", "1. a\n2. |") { $0.insertNewline() }
        expectCommand("3) x|", "3) x\n4) |") { $0.insertNewline() }
        expectCommand("- a|\r\n", "- a\r\n- |\r\n") { $0.insertNewline() }
        expectCommand("  - a|", "  - a\n  - |") { $0.insertNewline() }
    }

    @Test func enterContinuesTasksUnchecked() {
        expectCommand("- [x] a|", "- [x] a\n- [ ] |") { $0.insertNewline() }
        expectCommand("- [ ] a|\r\n", "- [ ] a\r\n- [ ] |\r\n") { $0.insertNewline() }
    }

    @Test func enterOnAnEmptyItemRemovesTheMarker() {
        expectCommand("- a\n- |", "- a\n|") { $0.insertNewline() }
        expectCommand("1. a\r\n2. |", "1. a\r\n|") { $0.insertNewline() }
        expectCommand("- [ ] a\n- [ ] |", "- [ ] a\n|") { $0.insertNewline() }
    }

    @Test func enterContinuesQuotes() {
        expectCommand("> a|", "> a\n> |") { $0.insertNewline() }
        expectCommand("> a\n> |", "> a\n|") { $0.insertNewline() }
        expectCommand("> a|\r\n", "> a\r\n> |\r\n") { $0.insertNewline() }
        expectCommand("> - a|", "> - a\n> - |") { $0.insertNewline() }
    }

    @Test func enterOpensFences() {
        expectCommand("```|", "```\n|\n```") { $0.insertNewline() }
        expectCommand("```swift|", "```swift\n|\n```") { $0.insertNewline() }
        expectCommand("~~~|\r\n", "~~~\r\n|\r\n~~~\r\n") { $0.insertNewline() }
        // Inside code: keep the line's indentation, nothing else.
        expectCommand("```\n  x|\n```", "```\n  x\n  |\n```") { $0.insertNewline() }
    }

    @Test func enterOpensMathBlocks() {
        expectCommand("$$|", "$$\n|\n$$") { $0.insertNewline() }
        expectCommand("$$|\r\n", "$$\r\n|\r\n$$\r\n") { $0.insertNewline() }
        // The closing `$$` of a math block is left alone.
        expectCommand("$$\nx\n$$|", "$$\nx\n$$\n|") { $0.insertNewline() }
    }

    @Test func enterAfterDashesInsertsARule() {
        expectCommand("Title\n---|", "Title\n\n---\n|") { $0.insertNewline() }
        expectCommand("Title\r\n---|", "Title\r\n\r\n---\r\n|") { $0.insertNewline() }
        expectCommand("a\n\n---|", "a\n\n---\n|") { $0.insertNewline() }
    }

    @Test func plainEnterMatchesTheDocumentLineEnding() {
        expectCommand("ab|", "ab\n|") { $0.insertNewline() }
        expectCommand("ab|\r\n", "ab\r\n|\r\n") { $0.insertNewline() }
        expectCommand("a|b", "a\n|b") { $0.insertNewline() }
    }

    @Test func eachConversionIsOneUndoStep() {
        let c = EditorController(text: "")
        for ch in "- a" { c.insert(String(ch)) }
        c.insertNewline()
        #expect(c.string == "- a\n- ")
        c.undo()
        #expect(c.string == "- a")
        #expect(c.caret == 3)
        c.redo()
        c.insertNewline()
        #expect(c.string == "- a\n")
        c.undo()
        #expect(c.string == "- a\n- ")
        #expect(c.caret == 6)
    }

    // MARK: Caret boundary rule (§6.1.4)

    private func text(_ c: EditorController, at offset: Int) -> String {
        c.displayBlock(atSource: offset)?.cells.map(\.text).joined() ?? ""
    }

    @Test func rightArrowFromInsideLeavesAndFolds() {
        let c = EditorController(text: "a **bold** b")
        c.moveCaret(to: 8)
        #expect(text(c, at: 8).contains("**"))
        c.move(.right)
        #expect(c.caret == 10)
        #expect(!text(c, at: 10).contains("**"), "the span folds after the closing delimiter")
    }

    @Test func leftArrowFromAfterReveals() {
        let c = EditorController(text: "a **bold** b")
        c.moveCaret(to: 10)
        #expect(!text(c, at: 10).contains("**"))
        c.move(.left)
        #expect(c.caret == 8)
        #expect(text(c, at: 8).contains("**"))
    }

    @Test func boundaryRuleCoversCodeLinksAndNesting() {
        let code = EditorController(text: "x `code` y")
        code.moveCaret(to: 7)
        code.move(.right)
        #expect(code.caret == 8)
        code.move(.left)
        #expect(code.caret == 7)

        let link = EditorController(text: "see [site](https://x.y) now")
        link.moveCaret(to: 9)
        link.move(.right)
        #expect(link.caret == 23)
        link.move(.left)
        #expect(link.caret == 9)

        let nested = EditorController(text: "***a*** b")
        nested.moveCaret(to: 4)
        nested.move(.right)
        #expect(nested.caret == 7)
        nested.move(.left)
        #expect(nested.caret == 4)
    }

    @Test func boundaryRuleInCRLFAndNotInSourceMode() {
        let c = EditorController(text: "*it*\r\nnext\r\n")
        c.moveCaret(to: 3)
        c.move(.right)
        #expect(c.caret == 4)
        c.toggleSourceMode()
        c.move(.left)
        #expect(c.caret == 3, "source mode steps one character")
        c.move(.right)
        #expect(c.caret == 4)
    }

    @Test func extendingSelectionIgnoresTheBoundaryJump() {
        let c = EditorController(text: "a **bold** b")
        c.moveCaret(to: 8)
        c.move(.right, extend: true)
        #expect(c.selection.anchor == 8)
        #expect(c.selection.head > 8)
    }
}
