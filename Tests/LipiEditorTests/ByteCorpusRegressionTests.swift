import AppKit
import LipiCore
@testable import LipiEditor
import Testing

/// Bugs the byte-preservation corpus run (`ByteRoundTrip`) found in the
/// editor, one test each.
@Suite("Byte-preservation corpus regressions")
@MainActor
struct ByteCorpusRegressionTests {
    func offset(of needle: String, in text: String) -> Int {
        text.utf8.count - text[text.range(of: needle)!.lowerBound...].utf8.count
    }

    /// Word-left looked up the line of `offset - 1`, which splits the
    /// scalar before the caret when it is not ASCII (a precondition
    /// failure in the rope).
    @Test func wordLeftAfterAMultibyteScalar() {
        let text = "ಕನ್ನಡ ಲಿಪಿ\n"
        let c = EditorController(text: text)
        c.moveCaret(to: offset(of: "\n", in: text))
        c.move(.wordLeft)
        #expect(c.selection.head == offset(of: "ಲಿಪಿ", in: text))
        c.move(.wordLeft)
        #expect(c.selection.head == 0)
        #expect(c.string == text)
    }

    /// Deleting the blank line between a paragraph and a table makes the
    /// paragraph's last line the table's header; the paragraph cmark-gfm
    /// split off had no source position, so the block before it got an
    /// empty span and projecting it read out of bounds (a crash).
    @Test func deleteForwardJoiningAParagraphAndATable() {
        let text = "Before ಕ\n\nMixed x\n\n| ಭಾ*ಷ*ೆ | b |\n| --- | --- |\n| c | d |\n"
        let c = EditorController(text: text, viewportWidth: 800)
        c.moveCaret(to: offset(of: "\n\n|", in: text))
        c.deleteForward()
        #expect(c.string == "Before ಕ\n\nMixed x\n| ಭಾ*ಷ*ೆ | b |\n| --- | --- |\n| c | d |\n")
        _ = c.prepare(CGRect(x: 0, y: 0, width: 800, height: 600))
        c.undo()
        #expect(c.string == text)
    }

    /// Delete at a CRLF line break removed half of the pair when no display
    /// cell had a caret stop there (a bare `\r` or `\n` left behind).
    @Test(arguments: ["a\r\nb", "+++\r\ntitle = 'T'\r\n+++\r\n\r\nBody\r\n", "- a\r\n\r\n- b\r\n"])
    func deleteKeepsCRLFPairsWhole(_ text: String) {
        let bytes = Array(text.utf8)
        for k in bytes.indices where bytes[k] == 0x0D {
            let back = EditorController(text: text, viewportWidth: 800)
            back.moveCaret(to: k + 2)
            back.deleteBackward()
            #expect(back.string.components(separatedBy: "\r\n").allSatisfy { !$0.contains("\r") && !$0.contains("\n") })
            back.undo()
            #expect(back.string == text)
            let forward = EditorController(text: text, viewportWidth: 800)
            forward.moveCaret(to: k)
            forward.deleteForward()
            #expect(forward.string.components(separatedBy: "\r\n").allSatisfy { !$0.contains("\r") && !$0.contains("\n") })
            forward.undo()
            #expect(forward.string == text)
        }
    }

    /// Insert Footnote looked up the line of `count - 1`, which splits the
    /// last scalar of a document ending in non-ASCII text (a crash).
    @Test(arguments: ["Text ಕನ್ನಡ", "Line\r\nQuote \u{201D}", "😀"])
    func footnoteAtTheEndOfNonASCIIText(_ text: String) {
        let c = EditorController(text: text, viewportWidth: 800)
        c.moveCaret(to: text.utf8.count)
        c.insertFootnote()
        let eol = text.contains("\r\n") ? "\r\n" : "\n"
        #expect(c.string == text + "[^1]" + eol + eol + "[^1]: " + eol)
        c.undo()
        #expect(c.string == text)
    }

    /// A command that rewrote bytes with the same bytes (image zoom to the
    /// zoom it already has, a plan re-emitting unchanged text) still made
    /// an undo step, and undoing it changed nothing.
    @Test func editsThatChangeNothingMakeNoUndoStep() {
        let text = "<img src=\"a.png\" alt=\"ಕ\" style=\"zoom:25%;\" />\n\nText\n"
        let c = EditorController(text: text, viewportWidth: 800)
        c.setImageZoom(25, at: 5)
        #expect(c.string == text)
        #expect(!c.canUndo)
        _ = c.perform(EditPlan(edits: [Edit(replacing: 0..<4, with: "<img")], anchor: 2, head: 2))
        #expect(c.selection.head == 2)
        #expect(!c.canUndo)
        _ = c.perform(EditPlan(edits: [Edit(replacing: 0..<4, with: "<img"), Edit(replacing: text.utf8.count - 5..<text.utf8.count - 1, with: "Next")],
                               anchor: 0, head: 0))
        #expect(c.canUndo)
        c.undo()
        #expect(c.string == text)
        #expect(!c.canUndo)
    }

    /// Outline promote/demote read the line prefix to find a heading's `#`
    /// run, and that prefix does not know footnote definitions: an ATX
    /// heading after `[^2]: ` was taken for setext, and the "underline"
    /// removed was the heading's own line (overlapping edits).
    @Test(arguments: [
        ("x\n\n[^2]: # T\n", "x\n\n[^2]: ## T\n"),
        ("x\n\n[^2]: #\n", "x\n\n[^2]: ##\n"),
        ("[^2]: T\n    ---\n", "[^2]: ### T\n"),
        ("> T\n> ---\n", "> ### T\n"),
        ("- ಕ\r\n  ===\r\n", "- ## ಕ\r\n"),
    ])
    func outlineShiftInsideAFootnote(_ text: String, _ demoted: String) {
        let c = EditorController(text: text, viewportWidth: 800)
        let outline = c.makeOutline()
        #expect(outline.items.count == 1)
        #expect(c.shiftSection(outline, 0, by: 1))
        #expect(c.string == demoted)
        c.undo()
        #expect(c.string == text)
    }
}
