import AppKit
import Foundation
@testable import LipiEditor
import LipiLayout
import Testing

@Suite("Code block header in the editor (P0-05)")
@MainActor
struct CodeBlockHeaderTests {
    let text = "Intro.\n\n```swift\nlet a = 1 < 2\nlet b = 3\n```\n\nOutro.\n"

    func buttons(_ controller: EditorController) -> [(rect: CGRect, button: CodeHeaderButton)] {
        controller.layout.codeHeaderButtons(in: controller.layout.layoutIfNeeded(in: 0...2000))
    }

    func center(of button: CodeHeaderButton, _ controller: EditorController) -> CGPoint {
        let rect = buttons(controller).first { $0.button == button }!.rect
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    @Test func copyPutsPlainTextAndColouredHTMLOnThePasteboard() {
        let controller = EditorController(text: text)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("lipi.test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(controller.clickCodeHeader(at: center(of: .copy, controller), pasteboard: pasteboard))
        let plain = pasteboard.string(forType: .string)
        #expect(plain?.hasPrefix("let a = 1 < 2\nlet b = 3") == true)
        #expect(plain?.contains("```") == false)
        let html = pasteboard.string(forType: .html) ?? ""
        #expect(html.contains("<code class=\"language-swift\">"))
        #expect(html.contains("&lt;"))
        #expect(html.contains("<span style=\"color:#"))
        // Copying leaves the caret and the document alone.
        #expect(controller.caret == 0)
        #expect(controller.string == text)
    }

    @Test func wrapAndLinesTogglesRunThePipeline() {
        let controller = EditorController(text: text)
        var changes = 0
        controller.onChange = { _ in changes += 1 }
        #expect(controller.codeOptions == CodeBlockOptions())
        #expect(controller.clickCodeHeader(at: center(of: .lineNumbers, controller)))
        #expect(controller.codeOptions.lineNumbers)
        #expect(changes == 1)
        #expect(controller.clickCodeHeader(at: center(of: .wrap, controller)))
        #expect(!controller.codeOptions.wrap)
        #expect(changes == 2)
        // Clicking elsewhere is not a header click.
        #expect(!controller.clickCodeHeader(at: CGPoint(x: controller.layout.textOrigin + 4, y: 4)))
        #expect(changes == 2)
    }

    @Test func noHeaderWhileTheFenceIsRevealedOrInSourceMode() {
        let controller = EditorController(text: text)
        _ = controller.moveCaret(to: (text as NSString).range(of: "```swift").location + 2)
        #expect(buttons(controller).isEmpty)
        let source = EditorController(text: text)
        _ = source.toggleSourceMode()
        #expect(buttons(source).isEmpty)
    }

    @Test func sidewaysScrollSurvivesTypingInTheBlock() {
        let long = String(repeating: "token ", count: 80)
        let doc = "Intro.\n\n```\n\(long)\nnext\n```\n"
        let controller = EditorController(text: doc, viewportWidth: 700)
        controller.codeOptions.wrap = false
        let offset = (doc as NSString).range(of: "token").location + 30
        _ = controller.moveCaret(to: offset)
        let before = controller.caretRect(forSource: offset)
        var redraws = 0
        controller.onRedisplay = { redraws += 1 }
        #expect(controller.scrollCode(at: CGPoint(x: before.minX, y: before.midY), by: 60))
        #expect(redraws == 1)
        let scrolled = controller.caretRect(forSource: offset)
        #expect(abs(scrolled.minX - (before.minX - 60)) < 0.5)
        // Typing re-parses the block (new ids); the caret is still in view,
        // so the scroll stays.
        _ = controller.insert("x")
        #expect(abs(controller.caretRect(forSource: offset).minX - scrolled.minX) < 0.5)
        // Moving to the start of a line brings the code back to its left edge.
        _ = controller.moveCaret(to: (doc as NSString).range(of: "next").location + 1)
        #expect(abs(controller.caretRect(forSource: offset).minX - before.minX) < 0.5)
    }

    @Test func editingAtTheEndOfALongLineRevealsTheCaret() {
        let long = String(repeating: "token ", count: 80)
        let doc = "Intro.\n\n```\n\(long)\n```\n"
        let controller = EditorController(text: doc, viewportWidth: 700)
        controller.codeOptions.wrap = false
        let end = (doc as NSString).range(of: long).upperBound
        let change = controller.moveCaret(to: end)
        #expect(change.caretRect.maxX <= 700)
    }
}
