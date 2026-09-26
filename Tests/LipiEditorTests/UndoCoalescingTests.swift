import Foundation
import LipiCore
import LipiEditor
import Testing

/// A controller whose clock the test advances by hand.
@MainActor
final class ClockedEditor {
    let c: EditorController
    var now: Double = 100

    init(_ text: String, source: Bool = false) {
        c = EditorController(text: text)
        if source { c.toggleSourceMode() }
        c.clock = { [unowned self] in self.now }
    }

    func type(_ s: String, gap: Double = 0.1) {
        for ch in s {
            now += gap
            c.insert(String(ch))
        }
    }
}

@Suite("Undo coalescing")
@MainActor
struct UndoCoalescingTests {
    @Test(arguments: [false, true])
    func typingCoalescesIntoOneStep(source: Bool) {
        let e = ClockedEditor("", source: source)
        e.type("abc")
        e.c.undo()
        #expect(e.c.string == "")
        #expect(e.c.caret == 0)
        e.c.redo()
        #expect(e.c.string == "abc")
        #expect(e.c.caret == 3)
    }

    @Test(arguments: [false, true])
    func aPauseStartsANewStep(source: Bool) {
        let e = ClockedEditor("", source: source)
        e.type("ab")
        e.now += 1.5
        e.type("c")
        e.c.undo()
        #expect(e.c.string == "ab")
        #expect(e.c.caret == 2)
        e.c.undo()
        #expect(e.c.string == "")
    }

    @Test func whitespaceAfterAWordStartsANewStep() {
        let e = ClockedEditor("")
        e.type("hello world")
        e.c.undo()
        #expect(e.c.string == "hello")
        #expect(e.c.caret == 5)
        e.c.undo()
        #expect(e.c.string == "")
    }

    @Test func aCaretJumpStartsANewStep() {
        let e = ClockedEditor("")
        e.type("ab")
        e.c.moveCaret(to: 0)
        e.type("x")
        #expect(e.c.string == "xab")
        e.c.undo()
        #expect(e.c.string == "ab")
        #expect(e.c.caret == 0)
        e.c.undo()
        #expect(e.c.string == "")
    }

    @Test func aCommandStartsANewStep() {
        let e = ClockedEditor("")
        e.type("ab")
        e.c.toggleStrong()
        #expect(e.c.string == "**ab**")
        e.type("c")
        #expect(e.c.string == "**abc**")
        e.c.undo()
        #expect(e.c.string == "**ab**")
        e.c.undo()
        #expect(e.c.string == "ab")
        #expect(e.c.caret == 2)
        e.c.undo()
        #expect(e.c.string == "")
    }

    @Test(arguments: [false, true])
    func undoRestoresTheSelection(source: Bool) {
        let e = ClockedEditor("abc def", source: source)
        e.c.select(0..<3)
        e.c.toggleStrong()
        #expect(e.c.string == "**abc** def")
        #expect(e.c.selection.range == 2..<5)
        e.c.undo()
        #expect(e.c.string == "abc def")
        #expect(e.c.selection.anchor == 0)
        #expect(e.c.selection.head == 3)
        e.c.redo()
        #expect(e.c.selection.range == 2..<5)
    }

    @Test func deletesCoalesceSeparatelyFromInserts() {
        let e = ClockedEditor("abcd")
        e.c.moveCaret(to: 4)
        e.type("e")
        for _ in 0..<3 {
            e.now += 0.1
            e.c.deleteBackward()
        }
        #expect(e.c.string == "ab")
        e.c.undo()
        #expect(e.c.string == "abcde")
        #expect(e.c.caret == 5)
        e.c.undo()
        #expect(e.c.string == "abcd")
        #expect(e.c.caret == 4)
    }

    @Test func crlfDocument() {
        let e = ClockedEditor("a\r\n")
        e.c.moveCaret(to: 3)
        e.type("bc")
        e.c.insertNewline()
        e.type("d")
        #expect(e.c.string == "a\r\nbc\r\nd")
        e.c.undo()
        #expect(e.c.string == "a\r\nbc\r\n")
        e.c.undo()
        #expect(e.c.string == "a\r\nbc")
        e.c.undo()
        #expect(e.c.string == "a\r\n")
        #expect(e.c.caret == 3)
    }

    @Test func compositionIsOneStep() {
        let e = ClockedEditor("x")
        e.c.moveCaret(to: 1)
        e.c.setMarkedText("k", selected: NSRange(location: 1, length: 0))
        e.c.setMarkedText("か", selected: NSRange(location: 1, length: 0))
        e.c.setMarkedText("かん", selected: NSRange(location: 2, length: 0))
        e.c.insert("漢")
        #expect(e.c.string == "x漢")
        e.c.undo()
        #expect(e.c.string == "x")
        #expect(e.c.caret == 1)
        e.c.redo()
        #expect(e.c.string == "x漢")
    }

    @Test func togglingModesKeepsTheHistory() {
        let e = ClockedEditor("")
        e.type("ab")
        e.c.toggleSourceMode()
        e.type("c", gap: 2)
        e.c.toggleSourceMode()
        e.c.undo()
        #expect(e.c.string == "ab")
        e.c.undo()
        #expect(e.c.string == "")
    }

    @Test func autoPairTypingIsOneStep() {
        let e = ClockedEditor("a ")
        e.c.moveCaret(to: 2)
        e.type("(x)")
        #expect(e.c.string == "a (x)")
        e.c.undo()
        #expect(e.c.string == "a ")
        #expect(e.c.caret == 2)
    }
}
