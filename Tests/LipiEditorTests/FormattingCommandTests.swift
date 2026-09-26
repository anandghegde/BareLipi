import LipiCore
import LipiEditor
import Testing

/// Splits `|` markers out of a test document: one marker is the caret, two
/// are the anchor and the head.
func parseMarked(_ s: String) -> (text: String, anchor: Int, head: Int) {
    var text = ""
    var marks: [Int] = []
    for ch in s {
        if ch == "|" { marks.append(text.utf8.count) } else { text.append(ch) }
    }
    precondition(marks.count == 1 || marks.count == 2, "need one or two | markers in \(s)")
    return (text, marks[0], marks.last!)
}

/// Renders a controller's document with its selection as `|` markers.
@MainActor
func withMarks(_ c: EditorController) -> String {
    var bytes = Array(c.string.utf8)
    let a = c.selection.anchor, h = c.selection.head
    let marks = a == h ? [a] : [a, h]
    for m in marks.sorted(by: >) { bytes.insert(UInt8(ascii: "|"), at: m) }
    return String(decoding: bytes, as: UTF8.self)
}

/// Runs `command` on `input` starting in hybrid and in source mode, and
/// expects the exact bytes and selection of `expected` in both, before and
/// after toggling the mode. Undo must restore the input and its selection,
/// redo the result.
@MainActor
func expectCommand(_ input: String, _ expected: String, settings: EditorSettings = EditorSettings(),
                   sourceLocation: SourceLocation = #_sourceLocation, _ command: (EditorController) -> Void) {
    let start = parseMarked(input)
    for startInSource in [false, true] {
        let c = EditorController(text: start.text)
        c.settings = settings
        if startInSource { c.toggleSourceMode() }
        c.select(min(start.anchor, start.head)..<max(start.anchor, start.head))
        command(c)
        let mode = startInSource ? "source" : "hybrid"
        #expect(withMarks(c) == expected, "\(mode) mode", sourceLocation: sourceLocation)
        c.toggleSourceMode()
        #expect(withMarks(c) == expected, "after toggling from \(mode)", sourceLocation: sourceLocation)
        guard parseMarked(expected).text != start.text else { continue }
        c.undo()
        #expect(withMarks(c) == input, "undo in \(mode)", sourceLocation: sourceLocation)
        c.redo()
        #expect(withMarks(c) == expected, "redo in \(mode)", sourceLocation: sourceLocation)
    }
}

@Suite("Formatting commands")
@MainActor
struct FormattingCommandTests {
    // MARK: Inline

    @Test func strongWrapsAndUnwrapsTheSelection() {
        expectCommand("a |bold| b", "a **|bold|** b") { $0.toggleStrong() }
        expectCommand("a **|bold|** b", "a |bold| b") { $0.toggleStrong() }
        expectCommand("a |**bold**| b", "a |bold| b") { $0.toggleStrong() }
    }

    @Test func strongWithoutSelectionWrapsTheWordOrInsertsAPair() {
        expectCommand("a bo|ld b", "a **bo|ld** b") { $0.toggleStrong() }
        expectCommand("a | b", "a **|** b") { $0.toggleStrong() }
        expectCommand("a **bo|ld** b", "a bo|ld b") { $0.toggleStrong() }
    }

    @Test func strongTrimsSurroundingWhitespace() {
        expectCommand("a| bold |b", "a **|bold|** b") { $0.toggleStrong() }
    }

    @Test func emphasisUsesTheConfiguredMarker() {
        expectCommand("|x|", "*|x|*") { $0.toggleEmphasis() }
        expectCommand("|x|", "_|x|_", settings: EditorSettings(emphasisMarker: "_")) { $0.toggleEmphasis() }
        expectCommand("*it|al*", "it|al") { $0.toggleEmphasis() }
    }

    @Test func strikethroughInACRLFDocument() {
        expectCommand("one\r\n|two|\r\n", "one\r\n~~|two|~~\r\n") { $0.toggleStrikethrough() }
        expectCommand("one\r\n~~t|wo~~\r\n", "one\r\nt|wo\r\n") { $0.toggleStrikethrough() }
    }

    @Test func codeSpanUsesTheShortestAbsentBacktickRun() {
        expectCommand("a |b`c| d", "a ``|b`c|`` d") { $0.toggleCodeSpan() }
        expectCommand("a |x| d", "a `|x|` d") { $0.toggleCodeSpan() }
        expectCommand("a |`x| d", "a `` |`x| `` d") { $0.toggleCodeSpan() }
        expectCommand("a `x|y` d", "a x|y d") { $0.toggleCodeSpan() }
    }

    @Test func inlineCommandsLeaveOtherDelimitersAlone() {
        expectCommand("_a_ |and| __b__\n\n* item\n", "_a_ **|and|** __b__\n\n* item\n") { $0.toggleStrong() }
    }

    @Test func linksAndImages() {
        expectCommand("|site|", "[site](https://x.y)|") { $0.insertLink(destination: "https://x.y") }
        expectCommand("|site|", "[site](|)") { $0.insertLink() }
        expectCommand("x |", "x [a](<my file.md> \"T\")|") { $0.insertLink(label: "a", destination: "my file.md", title: "T") }
        expectCommand("x |\r\n", "x ![cat](img/c.png)|\r\n") { $0.insertImage(alt: "cat", path: "img/c.png") }
    }

    // MARK: Headings

    @Test func headingLevels() {
        expectCommand("|Title", "# |Title") { $0.setHeading(level: 1) }
        expectCommand("## Tit|le", "### Tit|le") { $0.setHeading(level: 3) }
        expectCommand("|a\n\nb|", "|# a\n\n# b|") { $0.setHeading(level: 1) }
        expectCommand("- item|", "## item|") { $0.setHeading(level: 2) }
    }

    @Test func setextHeadingsInCRLF() {
        expectCommand("Setext|\r\n===\r\nnext\r\n", "## Setext|\r\nnext\r\n") { $0.setHeading(level: 2) }
        expectCommand("Setext|\r\n---\r\n\r\nnext\r\n", "Setext|\r\n\r\nnext\r\n") { $0.makeParagraph() }
    }

    @Test func paragraphRemovesHeadingAndListMarkers() {
        expectCommand("- item|", "item|") { $0.makeParagraph() }
        expectCommand("## Head ##|", "Head|") { $0.makeParagraph() }
        expectCommand("1. [x] done|", "done|") { $0.makeParagraph() }
    }

    @Test func promoteAndDemoteClamp() {
        expectCommand("### H|", "#### H|") { $0.demoteHeading() }
        expectCommand("### H|", "## H|") { $0.promoteHeading() }
        expectCommand("# H|", "# H|") { $0.promoteHeading() }
        expectCommand("###### H|", "###### H|") { $0.demoteHeading() }
        expectCommand("H|\r\n=\r\n", "## H|\r\n") { $0.demoteHeading() }
    }

    // MARK: Lists

    @Test func bulletAndOrderedListsToggle() {
        expectCommand("|a\n\nb|", "|- a\n\n- b|") { $0.toggleBulletList() }
        expectCommand("|- a\n\n- b|", "|a\n\nb|") { $0.toggleBulletList() }
        expectCommand("|a\n\nb|", "|1. a\n\n2. b|") { $0.toggleOrderedList() }
        expectCommand("1. a|", "- a|") { $0.toggleBulletList() }
        expectCommand("* a|", "1. a|") { $0.toggleOrderedList() }
        expectCommand("* a|\r\n", "a|\r\n") { $0.toggleBulletList() }
    }

    @Test func taskListsToggle() {
        expectCommand("- a|", "- [ ] a|") { $0.toggleTaskList() }
        expectCommand("- [ ] a|", "a|") { $0.toggleTaskList() }
        expectCommand("|a|\r\n", "|- [ ] a|\r\n") { $0.toggleTaskList() }
    }

    @Test func taskDoneTogglesAndPreservesUppercaseX() {
        expectCommand("- [ ] a|", "- [x] a|") { $0.toggleTaskDone() }
        expectCommand("- [x] a|", "- [ ] a|") { $0.toggleTaskDone() }
        expectCommand("|- [X] a\n- [ ] b|", "|- [X] a\n- [x] b|") { $0.toggleTaskDone() }
        expectCommand("|- [X] a\r\n- [x] b|", "|- [ ] a\r\n- [ ] b|") { $0.toggleTaskDone() }
        expectCommand("- plain|", "- plain|") { $0.toggleTaskDone() }
    }

    @Test func indentAndOutdentItems() {
        expectCommand("- a\n- b|", "- a\n  - b|") { $0.indentListItem() }
        expectCommand("- a\n  - b|", "- a\n- b|") { $0.outdentListItem() }
        expectCommand("- a\r\n- b|\r\n  - c\r\n", "- a\r\n  - b|\r\n    - c\r\n") { $0.indentListItem() }
        expectCommand("1. a\n2. b|", "1. a\n   2. b|") { $0.indentListItem() }
        // The first item has no previous sibling to nest under.
        expectCommand("- a|\n- b", "- a|\n- b") { $0.indentListItem() }
    }

    @Test func tabIndentsOnlyAtItemStart() {
        expectCommand("- a\n- |b", "- a\n  - |b") { $0.insertTab() }
        expectCommand("- a\n- b|", "- a\n- b\t|") { $0.insertTab() }
        expectCommand("- a\n  - |b", "- a\n- |b") { $0.insertBacktab() }
    }

    // MARK: Blocks

    @Test func quotesToggle() {
        expectCommand("a|", "> a|") { $0.toggleBlockQuote() }
        expectCommand("|a|", "|> a|") { $0.toggleBlockQuote() }
        expectCommand("> a|", "a|") { $0.toggleBlockQuote() }
        expectCommand("a\r\nb|", "> a\r\n> b|") { $0.toggleBlockQuote() }
    }

    @Test func codeFence() {
        expectCommand("text|", "text\n```|\n```") { $0.insertCodeFence() }
        expectCommand("a\n\n|", "a\n\n```|\n```") { $0.insertCodeFence() }
        expectCommand("a\r\n\r\n|", "a\r\n\r\n```|\r\n```") { $0.insertCodeFence() }
        expectCommand("|x\ny|", "```|\nx\ny\n```") { $0.insertCodeFence() }
        expectCommand("|a ``` b|", "````|\na ``` b\n````") { $0.insertCodeFence() }
    }

    @Test func mathBlock() {
        expectCommand("p|", "p\n\n$$\n|\n$$") { $0.insertMathBlock() }
        expectCommand("|", "$$\n|\n$$") { $0.insertMathBlock() }
        expectCommand("|x|\r\n", "$$\r\n|x|\r\n$$\r\n") { $0.insertMathBlock() }
    }

    @Test func thematicBreak() {
        expectCommand("a|", "a\n\n---|") { $0.insertThematicBreak() }
        expectCommand("a\n\n|", "a\n\n---|") { $0.insertThematicBreak() }
        expectCommand("|x|", "---|") { $0.insertThematicBreak() }
        expectCommand("a|\r\n", "a\r\n\r\n---|\r\n") { $0.insertThematicBreak() }
    }

    @Test func hardBreak() {
        expectCommand("a|b", "a\\\n|b") { $0.insertHardBreak() }
        expectCommand("a|b", "a  \n|b", settings: EditorSettings(hardBreak: .twoSpaces)) { $0.insertHardBreak() }
        expectCommand("- a|", "- a\\\n  |") { $0.insertHardBreak() }
        expectCommand("> x|\r\n", "> x\\\r\n> |\r\n") { $0.insertHardBreak() }
    }

    @Test func exitBlock() {
        expectCommand("```\ncode|\n```", "```\ncode\n```\n\n|") { $0.exitBlock() }
        expectCommand("> q|", "> q\n\n|") { $0.exitBlock() }
        expectCommand("$$\nx|\n$$", "$$\nx\n$$\n\n|") { $0.exitBlock() }
        expectCommand("```\r\nco|de\r\n```\r\nafter\r\n", "```\r\ncode\r\n```\r\n\r\n|\r\nafter\r\n") { $0.exitBlock() }
        expectCommand("plain|", "plain|") { $0.exitBlock() }
    }
}
