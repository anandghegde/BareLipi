import AppKit
import Foundation
import LipiCore
import LipiEditor
import LipiLayout
import Testing

@Suite("Source mode")
@MainActor
struct SourceModeTests {
    private func displayText(_ c: EditorController) -> String {
        c.projection.entries.flatMap(\.blocks).flatMap(\.cells).map(\.text).joined(separator: "¶")
    }

    @Test func toggleSwitchesModeAndBack() {
        let c = EditorController(text: "# Title\n\nSome **bold** text.\n")
        #expect(c.mode == .hybrid)
        c.toggleSourceMode()
        #expect(c.mode == .source)
        c.toggleSourceMode()
        #expect(c.mode == .hybrid)
    }

    @Test func sourceModeShowsEveryByteButLineEnds() {
        let text = "# Title\n\nSome **bold** [l](u) text.\n"
        let c = EditorController(text: text)
        c.moveCaret(to: c.count)
        #expect(!displayText(c).contains("**"))
        c.toggleSourceMode()
        let shown = displayText(c).replacingOccurrences(of: "¶", with: "").replacingOccurrences(of: "\n", with: "")
        #expect(shown == text.replacingOccurrences(of: "\n", with: ""))
    }

    @Test func crlfIsHiddenNotRewritten() {
        let text = "a *b*\r\n\r\n- c\r\n"
        let c = EditorController(text: text)
        c.toggleSourceMode()
        #expect(!displayText(c).contains("\r"))
        #expect(c.string == text)
        c.moveCaret(to: 5)
        c.insertNewline()
        #expect(c.string == "a *b*\r\n\r\n\r\n- c\r\n")
    }

    @Test func syntaxIsColouredFromTheAST() {
        let c = EditorController(text: "# H *e* `c`")
        c.toggleSourceMode()
        let cell = c.projection.entries[0].blocks[0].cells[0]
        func style(at utf16: Int) -> InlineStyle? { cell.runs.first { $0.range.contains(utf16) }?.style }
        #expect(style(at: 0)?.contains(.syntax) == true, "heading marker")
        #expect(style(at: 2)?.contains(.strong) == true, "heading text")
        #expect(style(at: 4)?.contains(.syntax) == true, "emphasis delimiter")
        #expect(style(at: 5)?.contains(.emphasis) == true, "emphasis content")
        #expect(style(at: 9)?.contains(.code) == true, "code content")
        #expect(style(at: 10)?.contains(.syntax) == true, "code delimiter")
    }

    @Test func monospaceThemeInSourceMode() {
        let c = EditorController(text: "# Title\n\nbody\n")
        #expect(c.typesetter.scale.monospace == false)
        #expect(c.typesetter.scale.style(for: .heading(1)).family == .heading)
        c.toggleSourceMode()
        #expect(c.typesetter.scale.monospace)
        for role in [TextRole.body, .heading(1), .heading(3), .codeBlock, .blockQuote, .tableCell] {
            #expect(c.typesetter.scale.style(for: role).family == .mono)
        }
        let body = c.typesetter.scale.style(for: .body)
        #expect(c.typesetter.scale.style(for: .heading(1)).size == body.size)
        c.setTheme(c.theme)
        #expect(c.typesetter.scale.monospace, "a theme change keeps source mode's type")
        c.toggleSourceMode()
        #expect(c.typesetter.scale.monospace == false)
    }

    @Test func caretSelectionAndUndoSurviveTheToggle() {
        let c = EditorController(text: "one **two** three")
        c.insert("")
        c.select(4..<11)
        c.toggleStrong()
        #expect(c.string == "one two three")
        c.select(2..<9)
        c.toggleSourceMode()
        #expect(c.selection.range == 2..<9)
        #expect(c.canUndo)
        c.undo()
        #expect(c.string == "one **two** three")
        #expect(c.selection.range == 4..<11)
        c.toggleSourceMode()
        #expect(c.selection.range == 4..<11)
        c.redo()
        #expect(c.string == "one two three")
    }

    @Test func toggleKeepsTheAnchorLineInPlace() {
        let text = (0..<60).map { "## Heading \($0)\n\nParagraph **\($0)** with [a link](https://example.com/\($0)).\n" }.joined(separator: "\n")
        let c = EditorController(text: text, viewportWidth: 700)
        let anchor = c.string.utf8.count / 2
        let before = c.caretRect(forSource: anchor)
        let change = c.toggleSourceMode(anchor: anchor)
        let after = c.caretRect(forSource: anchor)
        #expect(abs((after.minY - before.minY) - change.viewportShift) < 0.5)
        let back = c.toggleSourceMode(anchor: anchor)
        #expect(abs(c.caretRect(forSource: anchor).minY - after.minY - back.viewportShift) < 0.5)
    }

    @Test func toggleDuringCompositionWaitsForCommit() {
        let c = EditorController(text: "x")
        c.moveCaret(to: 1)
        c.setMarkedText("か", selected: NSRange(location: 1, length: 0))
        c.toggleSourceMode()
        #expect(c.mode == .hybrid)
        c.unmarkText()
        #expect(c.mode == .source)
        c.setMarkedText("き", selected: NSRange(location: 1, length: 0))
        c.toggleSourceMode()
        #expect(c.mode == .source)
        c.insert("木")
        #expect(c.mode == .hybrid)
        #expect(c.string == "xか木")
    }

    @Test func softWrapStaysOn() {
        let long = String(repeating: "word ", count: 80)
        let c = EditorController(text: long, viewportWidth: 500)
        c.toggleSourceMode()
        #expect(c.caretRect(forSource: c.count).minY > c.caretRect(forSource: 0).minY)
    }

    @Test func typingInSourceModeRebuildsOnlyTheEditedEntry() {
        let text = (0..<50).map { "Paragraph \($0) with *emphasis*." }.joined(separator: "\n\n")
        let c = EditorController(text: text)
        c.toggleSourceMode()
        let before = c.projection.entries.map(\.id)
        c.moveCaret(to: 5)
        c.insert("x")
        #expect(c.projection.entries.count == before.count)
        #expect(Array(c.projection.entries.map(\.id).dropFirst()) == Array(before.dropFirst()))
    }

    @Test func commandKeyTogglesWithoutAMenu() throws {
        let view = makeView("# T\n")
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                                  windowNumber: 0, context: nil, characters: "/",
                                                  charactersIgnoringModifiers: "/", isARepeat: false, keyCode: 44))
        #expect(EditorView.binding(for: event)?.action == #selector(EditorView.toggleSourceMode(_:)))
        view.keyDown(with: event)
        #expect(view.controller.mode == .source)
        let bold = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                                                 windowNumber: 0, context: nil, characters: "∫",
                                                 charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11))
        #expect(EditorView.binding(for: bold)?.action == #selector(EditorView.insertMathBlock(_:)))
    }
}
