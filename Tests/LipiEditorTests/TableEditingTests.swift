import LipiCore
import LipiEditor
import Testing

/// `^` markers (tables use `|`): one is the caret, two the anchor and head.
func parseCarets(_ s: String) -> (text: String, anchor: Int, head: Int) {
    var text = ""
    var marks: [Int] = []
    for ch in s {
        if ch == "^" { marks.append(text.utf8.count) } else { text.append(ch) }
    }
    precondition(marks.count == 1 || marks.count == 2, "need one or two ^ markers in \(s)")
    return (text, marks[0], marks.last!)
}

@MainActor
func withCarets(_ c: EditorController) -> String {
    var bytes = Array(c.string.utf8)
    let a = c.selection.anchor, h = c.selection.head
    for m in (a == h ? [a] : [a, h]).sorted(by: >) { bytes.insert(UInt8(ascii: "^"), at: m) }
    return String(decoding: bytes, as: UTF8.self)
}

/// Like `expectCommand`, with `^` selection markers; `modes` limits the
/// starting modes. Undo restores the input (only its text with
/// `undoTextOnly`, for commands after a selection change) and redo the result.
@MainActor
func expectEdit(_ input: String, _ expected: String, settings: EditorSettings = EditorSettings(),
                modes: [EditorMode] = [.hybrid, .source], undoTextOnly: Bool = false,
                sourceLocation: SourceLocation = #_sourceLocation, _ command: (EditorController) -> Void) {
    let start = parseCarets(input)
    for mode in modes {
        let c = EditorController(text: start.text)
        c.settings = settings
        if mode == .source { c.toggleSourceMode() }
        c.select(min(start.anchor, start.head)..<max(start.anchor, start.head))
        command(c)
        #expect(withCarets(c) == expected, "\(mode) mode", sourceLocation: sourceLocation)
        guard parseCarets(expected).text != start.text else { continue }
        c.undo()
        if undoTextOnly {
            #expect(c.string == start.text, "undo in \(mode)", sourceLocation: sourceLocation)
        } else {
            #expect(withCarets(c) == input, "undo in \(mode)", sourceLocation: sourceLocation)
        }
        c.redo()
        #expect(withCarets(c) == expected, "redo in \(mode)", sourceLocation: sourceLocation)
    }
}

@Suite("Table editing")
@MainActor
struct TableEditingTests {
    static let t = "| a | b |\n| - | - |\n| c | d |\n"

    // MARK: Tab / Shift-Tab

    @Test func tabMovesToTheNextCellAndSelectsIt() {
        expectEdit("| a^ | b |\n| - | - |\n| c | d |\n", "| a | ^b^ |\n| - | - |\n| c | d |\n") { $0.insertTab() }
        expectEdit("| a | b^ |\n| - | - |\n| c | d |\n", "| a | b |\n| - | - |\n| ^c^ | d |\n") { $0.insertTab() }
        expectEdit("| ^a | b |\n| - | - |\n| c | d |\n", "| a | ^b^ |\n| - | - |\n| c | d |\n") { $0.insertTab() }
    }

    @Test func tabInThePaddingBetweenCellsCountsTheNextCell() {
        expectEdit("| a |^  b | c |\n| - | - | - |\n", "| a |  b | ^c^ |\n| - | - | - |\n") { $0.insertTab() }
    }

    @Test func tabInTheLastCellAddsARow() {
        expectEdit("| a | b |\n| - | - |\n| c | d^ |\n", "| a | b |\n| - | - |\n| c | d |\n| ^ |  |\n") { $0.insertTab() }
        expectEdit("| a | b |\n| - | - |\n| c | d^ |", "| a | b |\n| - | - |\n| c | d |\n| ^ |  |") { $0.insertTab() }
        expectEdit("| a | b |\r\n| - | - |\r\n| c | d^ |\r\n", "| a | b |\r\n| - | - |\r\n| c | d |\r\n| ^ |  |\r\n") { $0.insertTab() }
    }

    @Test func tabInAHeaderOnlyTableAddsTheRowAfterTheDelimiter() {
        expectEdit("| a | b^ |\n| - | - |\n\nnext", "| a | b |\n| - | - |\n| ^ |  |\n\nnext") { $0.insertTab() }
    }

    @Test func newRowsKeepTheContainerPrefix() {
        expectEdit("> | a | b |\n> | - | - |\n> | c | d^ |\n", "> | a | b |\n> | - | - |\n> | c | d |\n> | ^ |  |\n") { $0.insertTab() }
        expectEdit("- | a | b |\n  | - | - |\n  | c | d^ |\n", "- | a | b |\n  | - | - |\n  | c | d |\n  | ^ |  |\n") { $0.insertTab() }
    }

    @Test func shiftTabMovesBack() {
        expectEdit("| a | b |\n| - | - |\n| c | ^d |\n", "| a | b |\n| - | - |\n| ^c^ | d |\n") { $0.insertBacktab() }
        expectEdit("| a | b |\n| - | - |\n| ^c | d |\n", "| a | ^b^ |\n| - | - |\n| c | d |\n") { $0.insertBacktab() }
        expectEdit("| ^a | b |\n| - | - |\n", "| ^a | b |\n| - | - |\n") { $0.insertBacktab() }
    }

    @Test func tabIntoAnEmptyCellPutsTheCaretInside() {
        expectEdit("| a | b |\n| - | - |\n| c^ |   |\n", "| a | b |\n| - | - |\n| c | ^  |\n") { $0.insertTab() }
    }

    @Test func tabIntoAGhostCellWritesIt() {
        expectEdit("| a | b |\n| - | - |\n| c^ |\n", "| a | b |\n| - | - |\n| c | ^ |\n") { $0.insertTab() }
        expectEdit("| a | b | x |\n| - | - | - |\n| c^ |\n| e | f | g |", "| a | b | x |\n| - | - | - |\n| c | ^ |\n| e | f | g |") { $0.insertTab() }
    }

    @Test func tabOutsideTablesIsUnchanged() {
        expectEdit("a^", "a\t^") { $0.insertTab() }
        expectEdit("- a\n- ^b", "- a\n  - ^b") { $0.insertTab() }
    }

    // MARK: Enter

    @Test func enterMovesToTheCellBelow() {
        expectEdit("| a | b^ |\n| - | - |\n| c | d |\n", "| a | b |\n| - | - |\n| c | ^d^ |\n") { $0.insertNewline() }
        expectEdit("| a | b |\n| - | - |\n| ^c | d |\n| e | f |", "| a | b |\n| - | - |\n| c | d |\n| ^e^ | f |") { $0.insertNewline() }
    }

    @Test func enterInTheLastRowAddsARowInTheSameColumn() {
        expectEdit("| a | b |\n| - | - |\n| c | d^ |\n", "| a | b |\n| - | - |\n| c | d |\n|  | ^ |\n") { $0.insertNewline() }
        expectEdit("| a | b |\r\n| - | - |\r\n| ^c | d |", "| a | b |\r\n| - | - |\r\n| c | d |\r\n| ^ |  |") { $0.insertNewline() }
    }

    @Test func enterInAnEmptyLastRowLeavesTheTable() {
        expectEdit("| a | b |\n| - | - |\n| c | d |\n| ^ |  |\n", "| a | b |\n| - | - |\n| c | d |\n\n^\n") { $0.insertNewline() }
        expectEdit("> | a |\n> | - |\n> | ^ |", "> | a |\n> | - |\n>\n> ^") { $0.insertNewline() }
    }

    // MARK: Completion

    @Test func headerRowThenEnterCompletesTheTable() {
        expectEdit("| a | b |^", "| a | b |\n| --- | --- |\n| ^ |  |") { $0.insertNewline() }
        expectEdit("| a |^\r\nnext", "| a |\r\n| --- |\r\n| ^ |\r\nnext") { $0.insertNewline() }
        expectEdit("> | a | b |^", "> | a | b |\n> | --- | --- |\n> | ^ |  |") { $0.insertNewline() }
        expectEdit("- | x |^", "- | x |\n  | --- |\n  | ^ |") { $0.insertNewline() }
        expectEdit("| a \\| b |^", "| a \\| b |\n| --- |\n| ^ |") { $0.insertNewline() }
    }

    @Test func completionRespectsTheSetting() {
        var s = EditorSettings()
        s.completeTables = false
        expectEdit("| a | b |^", "| a | b |\n^", settings: s) { $0.insertNewline() }
    }

    @Test func noCompletionWhereItDoesNotApply() {
        expectEdit("| a | b^ |", "| a | b\n^ |") { $0.insertNewline() }
        expectEdit("```\n| a |^\n```", "```\n| a |\n^\n```") { $0.insertNewline() }
        expectEdit("| a |^\n| - |", "| a |\n| - |\n| ^ |") { $0.insertNewline() }
        expectEdit("a | b^", "a | b\n^") { $0.insertNewline() }
    }

    // MARK: Cell content

    @Test func pipeTypedInACellIsEscapedInHybridMode() {
        expectEdit("| a^ | b |\n| - | - |\n", "| a\\|^ | b |\n| - | - |\n", modes: [.hybrid]) { $0.insert("|") }
        expectEdit("| a^ | b |\n| - | - |\n", "| a|^ | b |\n| - | - |\n", modes: [.source]) { $0.insert("|") }
        expectEdit("| a\\^ | b |\n| - | - |\n", "| a\\|^ | b |\n| - | - |\n", modes: [.hybrid]) { $0.insert("|") }
        expectEdit("a^", "a|^", modes: [.hybrid]) { $0.insert("|") }
    }

    @Test func optionEnterInsertsABreakInACell() {
        expectEdit("| a | b^ |\n| - | - |\n", "| a | b<br>^ |\n| - | - |\n") { $0.insertCellLineBreak() }
        expectEdit("a^", "a\n^") { $0.insertCellLineBreak() }
    }

    @Test func navigationIsOneUndoStepWithEdits() {
        let c = EditorController(text: Self.t)
        c.moveCaret(to: 23)
        c.insertTab()
        #expect(c.string == Self.t)
        #expect(!c.canUndo)
        c.insertTab()
        #expect(c.string == Self.t + "|  |  |\n")
        c.undo()
        #expect(c.string == Self.t)
    }
}
