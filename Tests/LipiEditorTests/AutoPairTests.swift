import LipiCore
import LipiEditor
import Testing

/// Types `keys` one character at a time into `input` (with a `|` caret) and
/// expects `expected`, starting in either mode and after toggling.
@MainActor
func expectTyping(_ input: String, _ keys: String, _ expected: String, autoPair: Bool = true,
                  sourceLocation: SourceLocation = #_sourceLocation) {
    expectCommand(input, expected, settings: EditorSettings(autoPair: autoPair), sourceLocation: sourceLocation) { c in
        for ch in keys { c.insert(String(ch)) }
    }
}

@Suite("Auto-pair")
@MainActor
struct AutoPairTests {
    @Test func pairsBeforeWhitespaceOrEndOfLine() {
        expectTyping("a |", "*", "a *|*")
        expectTyping("a | b", "(", "a (|) b")
        expectTyping("f|", "[", "f[|]")
        expectTyping("x |\r\n", "[", "x [|]\r\n")
        expectTyping("a |", "\"", "a \"|\"")
        expectTyping("a |", "\u{201C}", "a \u{201C}|\u{201D}")
        expectTyping("a |", "$", "a $|$")
        expectTyping("a |", "_", "a _|_")
    }

    @Test func doesNotPairBeforeText() {
        expectTyping("|x", "(", "(|x")
        expectTyping("a |x", "*", "a *|x")
    }

    @Test func symmetricDelimitersDoNotPairAfterAWord() {
        expectTyping("ab|", "_", "ab_|")
        expectTyping("ab|", "*", "ab*|")
        expectTyping("ab|", "\"", "ab\"|")
    }

    @Test func starAndUnderscoreDoNotPairAtLineStart() {
        expectTyping("|", "*", "*|")
        expectTyping("a\r\n|", "_", "a\r\n_|")
        expectTyping("> |", "*", "> *|")
    }

    @Test func typingTheCloserOvertypesIt() {
        expectTyping("a |", "*x*", "a *x*|")
        expectTyping("f|", "(x)", "f(x)|")
        expectTyping("a |\r\n", "[y]", "a [y]|\r\n")
    }

    @Test func backticksBuildAFence() {
        expectTyping("a |", "`", "a `|`")
        expectTyping("a |", "``", "a ``|")
        expectTyping("|", "```", "```|")
    }

    @Test func deleteOnAnEmptyPairRemovesBoth() {
        expectCommand("f|", "f|") { c in
            c.insert("(")
            c.deleteBackward()
        }
        expectCommand("a |\r\n", "a |\r\n") { c in
            c.insert("[")
            c.deleteBackward()
        }
        // Only pairs auto-pair made: a typed `()` deletes one character.
        expectCommand("f(|)", "f|)") { $0.deleteBackward() }
    }

    @Test func offInsideCodeAndMath() {
        expectTyping("```\n|\n```", "(", "```\n(|\n```")
        expectTyping("$$\nx |\n$$", "[", "$$\nx [|\n$$")
        expectTyping("a `x |` b", "(", "a `x (|` b")
        expectTyping("    code |", "(", "    code (|")
    }

    @Test func settingTurnsItOff() {
        expectTyping("a |", "(", "a (|", autoPair: false)
    }

    @Test func caretJumpForgetsTheCloser() {
        let c = EditorController(text: "a ")
        c.moveCaret(to: 2)
        c.insert("(")
        #expect(c.string == "a ()")
        c.moveCaret(to: 0)
        c.moveCaret(to: 3)
        c.insert(")")
        #expect(c.string == "a ())")
    }
}
