import LipiCore
import LipiEditor
import Testing

@Suite("Optional syntax (§6.13)")
@MainActor
struct OptionalSyntaxTests {
    @Test func togglingReparsesAndKeepsTextSelectionAndUndo() {
        let c = EditorController(text: "x H~2~O 2^10^ ==hi==")
        _ = c.insert("y")
        let before = c.projection.displayText
        #expect(before.contains("~2~") == false)  // GFM: single-tilde strikethrough
        #expect(before.contains("2^10^"))
        #expect(before.contains("==hi=="))
        let caret = c.caret
        c.setOptionalSyntax(subscript: true, superscript: true, highlight: true)
        #expect(c.parserOptions.extensions.isSuperset(of: [.subscript, .superscript, .highlight]))
        #expect(c.projection.displayText == "yx H2O 210 hi")
        #expect(c.caret == caret)
        #expect(c.canUndo)
        c.setOptionalSyntax(subscript: false, superscript: false, highlight: false)
        #expect(c.projection.displayText == before)
    }

    @Test func highlightIsAnInlineStyleAfterTyping() {
        let c = EditorController(text: "")
        c.setOptionalSyntax(subscript: false, superscript: false, highlight: true)
        for ch in "a ==b== c" { _ = c.insert(String(ch)) }
        #expect(c.string == "a ==b== c")
        #expect(c.projection.displayText == "a b c")
    }
}
