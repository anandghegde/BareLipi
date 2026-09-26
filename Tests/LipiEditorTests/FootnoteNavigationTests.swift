import AppKit
import LipiCore
import LipiEditor
import LipiLayout
import Testing

@Suite("Footnote numbers, popover and jumps (§6.13)")
@MainActor
struct FootnoteNavigationTests {
    static let text = "Intro claim[^src] and more[^b].\n\nPlain.\n\n[^b]: Second *note*.\n\n[^src]: First note.\n\n    code in note\n"

    @Test func referencesAndDefinitions() {
        let c = EditorController(text: Self.text)
        let refs = c.footnoteReferences()
        #expect(refs.map(\.label) == ["src", "b"])
        #expect(refs.map(\.number) == [1, 2])
        #expect(refs[0].range == 11..<17)
        #expect(c.footnoteReference(containing: 14)?.label == "src")
        #expect(c.footnoteReference(containing: 17)?.label == "src")
        #expect(c.footnoteReference(containing: 5) == nil)
        let def = c.footnoteDefinition(label: "SRC")
        #expect(def?.label == "src")
        #expect(def?.number == 1)
        #expect(def.map { c.string(in: $0.contentStart..<($0.contentStart + 5)) } == "First")
        #expect(c.footnoteDefinition(label: "missing") == nil)
    }

    @Test func popoverTextIsTheNotesPlainText() {
        let c = EditorController(text: Self.text)
        #expect(c.footnoteText(label: "b") == "Second note.")
        #expect(c.footnoteText(label: "src") == "First note.\n\ncode in note")
        #expect(c.footnoteText(label: "nope") == nil)
    }

    @Test func showFootnoteUsesTheReferenceAtTheCaret() {
        let view = makeView(Self.text)
        view.controller.moveCaret(to: 28)
        view.showFootnote(nil)
        #expect(view.shownFootnoteText == "Second note.")
        // Typing closes it.
        view.controller.insert("x")
        #expect(view.shownFootnoteText == nil)
        view.controller.moveCaret(to: 13)
        view.showFootnote(nil)
        #expect(view.shownFootnoteText == "First note.\n\ncode in note")
    }

    @Test func showFootnoteIsACommandOnCmdOptDown() {
        let binding = EditorView.keyEquivalents.first { $0.action == #selector(EditorView.showFootnote(_:)) }
        #expect(binding?.key == "\u{F701}")
        #expect(binding?.modifiers == [.command, .option])
    }

    @Test func clickingAReferenceJumpsAndTheReturnLinkComesBack() {
        let view = makeView(Self.text)
        view.controller.prepare(view.bounds)
        view.controller.moveCaret(to: 0)
        let c = view.controller
        let ref = c.footnoteReferences()[1]
        // The rendered reference shows its number, a single glyph.
        let rect = c.rects(forSource: ref.range, visible: view.bounds).reduce(CGRect.null) { $0.union($1) }
        #expect(!rect.isNull)
        let hit = c.footnoteReference(at: CGPoint(x: rect.midX, y: rect.midY))
        #expect(hit?.label == "b")
        #expect(c.jumpToFootnoteDefinition(label: "b"))
        let def = c.footnoteDefinition(label: "b")!
        #expect(c.caret == def.contentStart)
        #expect(c.string == Self.text)

        // The ↩ in the gutter of another note (not the caret's, which is revealed).
        let other = c.footnoteDefinition(label: "src")!
        let textRect = c.caretRect(forSource: other.contentStart)
        let back = CGPoint(x: textRect.minX - 30, y: textRect.midY)
        #expect(c.footnoteReturnLink(at: back)?.label == "src")
        #expect(c.returnToFootnoteReference(label: "src"))
        #expect(c.caret == 17)
        #expect(c.string == Self.text)
    }

    @Test func noHitsInSourceMode() {
        let view = makeView(Self.text)
        view.controller.prepare(view.bounds)
        view.controller.moveCaret(to: 0)
        view.controller.toggleSourceMode()
        let r = view.controller.caretRect(forSource: 13)
        #expect(view.controller.footnoteReference(at: CGPoint(x: r.midX, y: r.midY)) == nil)
    }

    @Test func gutterMarkerCarriesTheReturnLink() {
        #expect(Renderer.footnoteMarker(label: "x", number: 3) == "\u{21A9}\u{FE0E} 3.")
        #expect(Renderer.footnoteMarker(label: "x", number: nil) == "\u{21A9}\u{FE0E} [x]")
    }
}
