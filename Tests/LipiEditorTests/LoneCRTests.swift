import LipiCore
import LipiEditor
import Testing

/// A lone `\r` ends a line for cmark-gfm (classic Mac files, mixed files), so
/// it ends one for the editor's commands too, and what they write uses it.
@Suite("Lone CR line breaks")
@MainActor
struct LoneCRTests {
    @Test func enterContinuesListsQuotesAndTasks() {
        expectCommand("- a|\r", "- a\r- |\r") { $0.insertNewline() }
        expectCommand("1. a\r2. b|\r", "1. a\r2. b\r3. |\r") { $0.insertNewline() }
        expectCommand("- [x] a|\r", "- [x] a\r- [ ] |\r") { $0.insertNewline() }
        expectCommand("> a|\r", "> a\r> |\r") { $0.insertNewline() }
        expectCommand("1. a\r2. |", "1. a\r|") { $0.insertNewline() }
        expectCommand("> a\r> |", "> a\r|") { $0.insertNewline() }
    }

    @Test func plainEnterWritesCR() {
        expectCommand("ab|\r", "ab\r|\r") { $0.insertNewline() }
        expectCommand("one\rtw|o", "one\rtw\r|o") { $0.insertNewline() }
        expectCommand("```|\r", "```\r|\r```\r") { $0.insertNewline() }
        expectCommand("$$|\r", "$$\r|\r$$\r") { $0.insertNewline() }
    }

    @Test func mixedFilesUseTheLinesOwnEnding() {
        expectCommand("a\r\n- b|\rc\n", "a\r\n- b\r- |\rc\n") { $0.insertNewline() }
        expectCommand("- a|\r\nb\r", "- a\r\n- |\r\nb\r") { $0.insertNewline() }
        expectCommand("x\n- a|\ry\r", "x\n- a\r- |\ry\r") { $0.insertNewline() }
    }

    @Test func blockCommandsTargetTheCRLine() {
        expectCommand("one\r\rtw|o\rthree\r", "one\r\r## tw|o\rthree\r") { $0.setHeading(level: 2) }
        expectCommand("one\r## tw|o\r", "one\rtw|o\r") { $0.makeParagraph() }
        expectCommand("|a\r\rb|\r", "|- a\r\r- b|\r") { $0.toggleBulletList() }
        expectCommand("- a\r- b|\r", "- a\r  - b|\r") { $0.indentListItem() }
        expectCommand("- [ ] a|\rb\r", "- [x] a|\rb\r") { $0.toggleTaskDone() }
    }

    @Test func tableRowsUseCR() {
        expectEdit("| a | b |\r| - | - |\r| c | d^ |\r", "| a | b |\r| - | - |\r| c | d |\r| ^ |  |\r") { $0.insertTab() }
        expectEdit("| a | b |\r| - | - |\r| c | d^ |\r", "| a | b |\r| - | - |\r| c | d |\r|  | ^ |\r") { $0.insertNewline() }
        expectEdit("| a |^\rnext", "| a |\r| --- |\r| ^ |\rnext") { $0.insertNewline() }
    }

    @Test func wordMotionStopsAtCR() {
        let c = EditorController(text: "ab\rcd ef\r")
        #expect(c.wordBoundary(after: 2) == 3)
        #expect(c.wordBoundary(after: 3) == 5)
        #expect(c.wordBoundary(before: 3) == 0)
        #expect(c.wordBoundary(before: 5) == 3)
    }

    @Test func typingInATableRowOfACRFile() {
        let c = EditorController(text: "| a | b |\r| - | - |\r| c | d |\r")
        c.moveCaret(to: 23)
        c.insert("x")
        #expect(c.string == "| a | b |\r| - | - |\r| cx | d |\r")
        c.undo()
        #expect(c.string == "| a | b |\r| - | - |\r| c | d |\r")
    }
}
