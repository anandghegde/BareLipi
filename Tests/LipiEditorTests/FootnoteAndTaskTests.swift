import AppKit
import LipiCore
import LipiEditor
import Testing

@Suite("Insert footnote and task checkboxes (§6.13)")
@MainActor
struct FootnoteAndTaskTests {
    @Test func insertFootnoteWritesBothHalves() {
        expectCommand("One| two.\n", "One[^1] two.\n\n[^1]: |\n") { $0.insertFootnote() }
        expectCommand("Hi|", "Hi[^1]\n\n[^1]: |\n") { $0.insertFootnote() }
        expectCommand("See[^1].|\n\n[^1]: a\n", "See[^1].[^2]\n\n[^1]: a\n\n[^2]: |\n") { $0.insertFootnote() }
        expectCommand("Text|\n\n", "Text[^1]\n\n[^1]: |\n") { $0.insertFootnote() }
        // After a selection, and past the highest numeric label.
        expectCommand("|word| x[^7]\n", "word[^8] x[^7]\n\n[^8]: |\n") { $0.insertFootnote() }
        expectCommand("A|\r\nB\r\n", "A[^1]\r\nB\r\n\r\n[^1]: |\r\n") { $0.insertFootnote() }
    }

    @Test func insertedFootnoteParses() {
        let c = EditorController(text: "Claim.\n")
        c.moveCaret(to: 5)
        c.insertFootnote()
        c.insert("Source.")
        var labels: [String] = []
        for i in 0..<c.blockIndex.count {
            c.blockIndex.entries[i].block.forEachBlock { b in
                if case .footnoteDefinition(let label) = b.kind { labels.append(label) }
            }
        }
        #expect(labels == ["1"])
        #expect(c.string == "Claim[^1].\n\n[^1]: Source.\n")
    }

    private func checkboxPoint(_ view: EditorView, contentStart: Int) -> CGPoint {
        let text = view.controller.caretRect(forSource: contentStart)
        return CGPoint(x: text.minX - 12, y: text.midY)
    }

    @Test func clickingACheckboxTogglesIt() {
        let view = makeView("Intro\n\n- [ ] task one\n- [x] task two\n")
        view.controller.prepare(view.bounds)
        view.controller.moveCaret(to: 0)
        let first = checkboxPoint(view, contentStart: 13)
        #expect(view.controller.toggleTask(at: first))
        #expect(view.controller.string == "Intro\n\n- [x] task one\n- [x] task two\n")
        #expect(view.controller.caret == 0)
        let second = checkboxPoint(view, contentStart: 28)
        #expect(view.controller.toggleTask(at: second))
        #expect(view.controller.string == "Intro\n\n- [x] task one\n- [ ] task two\n")
        view.controller.undo()
        #expect(view.controller.string == "Intro\n\n- [x] task one\n- [x] task two\n")
        // Clicking the text itself is not a checkbox click.
        let text = view.controller.caretRect(forSource: 15)
        #expect(!view.controller.toggleTask(at: CGPoint(x: text.midX, y: text.midY)))
    }

    @Test func noCheckboxInSourceModeOrOnARevealedLine() {
        let view = makeView("Intro\n\n- [ ] task\n")
        view.controller.prepare(view.bounds)
        view.controller.moveCaret(to: 15)
        let point = CGPoint(x: view.controller.caretRect(forSource: 7).minX + 2, y: view.controller.caretRect(forSource: 13).midY)
        #expect(!view.controller.toggleTask(at: point))
        view.controller.toggleSourceMode()
        #expect(view.controller.taskBox(at: point) == nil)
        #expect(view.controller.string == "Intro\n\n- [ ] task\n")
    }
}
