import AppKit
import LipiCore
@testable import LipiEditor
import Testing

@Suite("Find and replace")
@MainActor
struct FindTests {
    func session(_ text: String, _ pattern: String) -> FindSession {
        let s = FindSession(controller: EditorController(text: text))
        s.query = FindQuery(pattern)
        return s
    }

    @Test func nextAndPreviousWrap() {
        let f = session("cat dog cat bird cat", "cat")
        #expect(f.count == 3)
        f.controller.moveCaret(to: 5)
        #expect(f.next() == 8..<11)
        #expect(f.currentIndex == 1)
        #expect(f.next() == 17..<20)
        #expect(f.next() == 0..<3)  // wraps
        #expect(f.previous() == 17..<20)  // wraps back
        #expect(f.previous() == 8..<11)
        #expect(f.controller.selection.range == 8..<11)
    }

    @Test func incrementalSearchStartsAtTheSelection() {
        let f = session("abc abd abe", "ab")
        f.controller.moveCaret(to: 5)
        #expect(f.findFromSelection() == 8..<10)
        f.query = FindQuery("abe")
        #expect(f.findFromSelection() == 8..<11)
        f.query = FindQuery("zz")
        #expect(f.findFromSelection() == nil)
        #expect(f.count == 0)
    }

    @Test func matchesFollowEdits() {
        let f = session("one one", "one")
        #expect(f.count == 2)
        f.controller.moveCaret(to: 7)
        f.controller.insert(" one")
        #expect(f.count == 3)
        f.controller.undo()
        #expect(f.count == 2)
    }

    @Test func invalidRegexReportsAnError() {
        let f = session("text", "")
        f.query = FindQuery("(", isRegex: true)
        #expect(f.count == 0)
        #expect(f.error == .invalidPattern("("))
        f.query = FindQuery("t", isRegex: true)
        #expect(f.count == 2)
        #expect(f.error == nil)
    }

    @Test func replaceCurrentThenNext() {
        let f = session("a cat, a cat", "cat")
        #expect(f.replaceCurrent(with: "dog") == false)  // selects the first match first
        #expect(f.controller.selection.range == 2..<5)
        #expect(f.replaceCurrent(with: "dog"))
        #expect(f.controller.string == "a dog, a cat")
        #expect(f.controller.selection.range == 9..<12)
        #expect(f.replaceCurrent(with: "dog"))
        #expect(f.controller.string == "a dog, a dog")
        f.controller.undo()
        #expect(f.controller.string == "a dog, a cat")
    }

    @Test func replaceAllIsOneUndoStepAndTouchesOnlyMatches() {
        let original = "# Title\r\n\nthe **the** [the](the.md) ಕನ್ನಡ the\n\n| the | x |\n|---|---|\n| a | the |\n"
        let f = session(original, "the")
        f.controller.moveCaret(to: original.utf8.count)
        let before = f.count
        #expect(before == 7)
        #expect(f.replaceAll(with: "THE-ಅ") == before)
        let expected = original.replacingOccurrences(of: "the", with: "THE-ಅ")
        #expect(f.controller.string == expected)
        #expect(f.controller.caret == expected.utf8.count)
        f.controller.undo()
        #expect(f.controller.string == original)
        f.controller.redo()
        #expect(f.controller.string == expected)
    }

    @Test func regexReplaceAll() {
        let f = session("x=1\ny=22\n", "")
        f.query = FindQuery(#"^(\w)=(\d+)$"#, isRegex: true)
        #expect(f.replaceAll(with: "$1: $2") == 2)
        #expect(f.controller.string == "x: 1\ny: 22\n")
        f.query = FindQuery(#"(\d+)"#, isRegex: true)
        f.controller.moveCaret(to: 0)
        f.next()
        #expect(f.replaceCurrent(with: "<$1>"))
        #expect(f.controller.string == "x: <1>\ny: 22\n")
    }

    @Test func renderedScope() {
        let f = session("Some **bold** and [bold](bold.md)\n", "bold")
        #expect(f.count == 3)
        f.scope = .rendered
        #expect(f.count == 2)
        #expect(f.replaceAll(with: "b") == 2)
        #expect(f.controller.string == "Some **b** and [b](bold.md)\n")
    }

    @Test func currentMatchRevealsItsSyntax() {
        let f = session("See [here](http://example.com/target) now.\n", "target")
        f.controller.moveCaret(to: f.controller.count)
        #expect(f.next() != nil)
        // The link destination is shown while the match is current.
        #expect(f.controller.projection.displayText.contains("target"))
    }

    @Test func highlightsOnlyVisibleMatches() {
        let text = (0..<400).map { "line \($0) needle\n" }.joined()
        let view = makeView(text)
        let f = FindSession(controller: view.controller)
        f.query = FindQuery("needle")
        f.isActive = true
        view.findSession = f
        #expect(f.count == 400)
        let slice = f.matches(intersecting: 0..<200)
        #expect(slice.count == f.matches.filter { $0.lowerBound < 200 }.count && slice.count < 20)
        // Drawing with highlights on leaves yellow under the first match.
        let rep = render(view)
        let rect = view.controller.rects(forSource: f.matches[0], visible: view.bounds)[0]
        let color = rep.colorAt(x: Int(rect.midX), y: Int(rect.minY + 1))!
        #expect(color.redComponent > 0.8 && color.blueComponent < 0.8)
    }

    @Test func refusedWhenNotEditable() {
        let f = session("cat cat", "cat")
        var refused = 0
        f.controller.onRefusedEdit = { refused += 1 }
        f.controller.isEditable = false
        #expect(f.replaceAll(with: "dog") == 0)
        f.next()
        #expect(f.replaceCurrent(with: "dog") == false)
        #expect(f.controller.string == "cat cat")
        #expect(refused == 2)
    }
}
