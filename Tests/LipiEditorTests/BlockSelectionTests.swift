import LipiCore
import LipiEditor
import Testing

@Suite("Block selection")
@MainActor
struct BlockSelectionTests {
    private func controller(_ marked: String) -> EditorController {
        let m = parseCarets(marked)
        let c = EditorController(text: m.text)
        c.select(min(m.anchor, m.head)..<max(m.anchor, m.head))
        return c
    }

    @Test func escInATightItemSelectsTheItem() {
        let c = controller("- a\n- b^\n")
        c.selectEnclosingBlock()
        #expect(withCarets(c) == "- a\n^- b^\n")
    }

    @Test func escSelectsAParagraphInALooseItemFirst() {
        let c = controller("- a\n\n  b^\n")
        c.selectEnclosingBlock()
        #expect(withCarets(c) == "- a\n\n  ^b^\n")
        c.selectEnclosingBlock()
        #expect(withCarets(c) == "^- a\n\n  b^\n")
    }

    @Test func escSelectsTheBlockAndWidensUpToTheTop() {
        let c = controller("# T\n\n- a\n- b^c\n  more\n- d\n\nz")
        #expect(c.blockSelection == nil)
        c.selectEnclosingBlock()
        #expect(c.blockSelection != nil)
        #expect(withCarets(c) == "# T\n\n- a\n^- bc\n  more^\n- d\n\nz")
        c.selectEnclosingBlock()
        #expect(withCarets(c) == "# T\n\n^- a\n- bc\n  more\n- d^\n\nz")
        c.selectEnclosingBlock()
        #expect(withCarets(c) == "# T\n\n^- a\n- bc\n  more\n- d^\n\nz")
    }

    @Test func escSelectsATableAsOneUnit() {
        let c = controller("x\n\n| a | b |\n| - | - |\n| c^ | d |\n\ny")
        c.selectEnclosingBlock()
        #expect(withCarets(c) == "x\n\n^| a | b |\n| - | - |\n| c | d |^\n\ny")
    }

    @Test func escSelectsAFence() {
        let c = controller("```swift\nlet ^x = 1\n```\n")
        c.selectEnclosingBlock()
        #expect(withCarets(c) == "^```swift\nlet x = 1\n```^\n")
    }

    @Test func movingTheCaretEndsTheBlockSelection() {
        let c = controller("a^b\n\ncd")
        c.selectEnclosingBlock()
        #expect(c.blockSelection == 0..<2)
        c.move(.right)
        #expect(c.blockSelection == nil)
        #expect(withCarets(c) == "ab^\n\ncd")
    }

    @Test func enterReentersTheBlock() {
        let c = controller("p\n\nq^r\n")
        c.selectEnclosingBlock()
        c.insertNewline()
        #expect(withCarets(c) == "p\n\n^qr\n")
        #expect(c.blockSelection == nil)
    }

    @Test func deleteRemovesTheBlockLines() {
        expectEdit("a\n\nb^\n\nc\n", "a\n\n^c\n", undoTextOnly: true) { $0.selectEnclosingBlock(); $0.deleteBackward() }
        expectEdit("a\n\nb^", "a^", undoTextOnly: true) { $0.selectEnclosingBlock(); $0.deleteBackward() }
        expectEdit("a^\n\nb", "^b", undoTextOnly: true) { $0.selectEnclosingBlock(); $0.deleteForward() }
        expectEdit("- a\n- b^\n- c\n", "- a\n^- c\n", undoTextOnly: true) { $0.selectEnclosingBlock(); $0.deleteBackward() }
        expectEdit("a\r\n\r\n| x |\r\n| - |\r\n| ^y |\r\n\r\nc", "a\r\n\r\n^c", undoTextOnly: true) { $0.selectEnclosingBlock(); $0.deleteBackward() }
        expectEdit("> q\n>\n> r^\n", "> q\n^", undoTextOnly: true) { $0.selectEnclosingBlock(); $0.deleteBackward() }
    }

    @Test func duplicateCopiesTheBlockAndSelectsTheCopy() {
        expectEdit("a^b\n\nc", "ab\n\n^ab^\n\nc", undoTextOnly: true) { $0.selectEnclosingBlock(); $0.duplicateBlock() }
        expectEdit("- a^\n- b", "- a\n^- a^\n- b", undoTextOnly: true) { $0.selectEnclosingBlock(); $0.duplicateBlock() }
        expectEdit("> x^\r\n", "> x\r\n>\r\n> ^x^\r\n", undoTextOnly: true) { $0.selectEnclosingBlock(); $0.duplicateBlock() }
        expectEdit("t^", "t\n\n^t^") { $0.duplicateBlock() }
    }

    @Test func duplicateKeepsTheBlockSelection() {
        let c = controller("a^\n")
        c.selectEnclosingBlock()
        c.duplicateBlock()
        #expect(c.blockSelection == 3..<4)
    }

    @Test func optionArrowsMoveTheBlockPastItsSibling() {
        expectEdit("a\n\nb^\n\nc\n", "^b^\n\na\n\nc\n", undoTextOnly: true) { $0.selectEnclosingBlock(); _ = $0.moveBlock(up: true) }
        expectEdit("a\n\nb^\n\nc\n", "a\n\nc\n\n^b^\n", undoTextOnly: true) { $0.selectEnclosingBlock(); _ = $0.moveBlock(up: false) }
        expectEdit("- a\n- b^\n- c", "- a\n- c\n^- b^", undoTextOnly: true) { c in
            c.selectEnclosingBlock(); _ = c.moveBlock(up: false)
        }
        expectEdit("a\r\n\r\nb^", "^b^\r\n\r\na", undoTextOnly: true) { $0.selectEnclosingBlock(); _ = $0.moveBlock(up: true) }
    }

    @Test func movingAtTheEdgeOrWithoutBlockSelectionDoesNothing() {
        let c = controller("a^\n\nb")
        #expect(!c.moveBlock(up: true))
        c.selectEnclosingBlock()
        #expect(c.moveBlock(up: true))
        #expect(c.string == "a\n\nb")
        #expect(c.blockSelection == 0..<1)
        c.moveBlock(up: false)
        #expect(c.string == "b\n\na")
        #expect(c.blockSelection == 3..<4)
        c.undo()
        #expect(c.string == "a\n\nb")
    }
}
