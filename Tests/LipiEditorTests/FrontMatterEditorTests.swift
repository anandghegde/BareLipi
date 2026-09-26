import AppKit
import LipiCore
@testable import LipiEditor
import LipiLayout
import Testing

@Suite("Front matter in the editor (§6.13)")
@MainActor
struct FrontMatterEditorTests {
    @Test func parsedValuesFollowEdits() {
        let text = "---\ntitle: First\nassets: img\n---\n# Heading\n\nBody.\n"
        let c = EditorController(text: text)
        #expect(c.frontMatter?.title == "First")
        #expect(c.frontMatter?.assets == "img")
        #expect(c.documentTitle == "First")
        c.moveCaret(to: 13)
        c.insert("X")
        #expect(c.frontMatter?.title == "FiXrst")
        // Typing in the body leaves the front matter alone.
        c.moveCaret(to: c.count - 1)
        c.insert("y")
        #expect(c.frontMatter?.title == "FiXrst")
    }

    @Test func malformedIsSourceWithAWarningAndNeverRewritten() {
        let text = "---\ntitle: 'unclosed\n---\nBody.\n"
        let view = makeView(text)
        let c = view.controller
        c.moveCaret(to: c.count)
        #expect(c.frontMatter?.isMalformed == true)
        let block = c.projection.entries[0].blocks[0]
        #expect(block.context.warning?.hasPrefix("YAML error") == true)
        #expect(block.isRevealed)
        #expect(block.cells[0].text.hasPrefix("---\n"))
        #expect(c.string == text)

        // Fixing it hides the delimiters again (the caret is elsewhere).
        c.moveCaret(to: 20)
        c.insert("'")
        c.moveCaret(to: c.count)
        #expect(c.frontMatter?.isMalformed == false)
        #expect(c.frontMatter?.title == "unclosed")
        #expect(c.projection.entries[0].blocks[0].context.warning == nil)
        #expect(c.projection.entries[0].blocks[0].cells[0].text == "title: 'unclosed'")
        #expect(c.string == "---\ntitle: 'unclosed'\n---\nBody.\n")
    }

    @Test func removingTheFrontMatterClearsIt() {
        let c = EditorController(text: "---\nbad: [\n---\ntext\n")
        #expect(c.frontMatter?.isMalformed == true)
        c.replace(0..<14, with: "")
        #expect(c.frontMatter == nil)
        #expect(c.projection.frontMatterWarning == nil)
    }

    @Test func tomlFrontMatter() {
        let c = EditorController(text: "+++\ntitle = \"T\"\n[math]\nmacros = \"\\\\def\\\\x{y}\"\n+++\nx\n")
        #expect(c.frontMatter?.kind == .toml)
        #expect(c.frontMatter?.title == "T")
        #expect(c.frontMatter?.mathMacros == "\\def\\x{y}")
    }

    @Test func outlineTitle() {
        let rope = LipiRope("---\ntitle: Book\n---\n# One\n")
        var parser = LipiParser(options: .editor)
        parser.parse(rope)
        var outline = Outline(index: parser.index, rope: rope)
        #expect(outline.title == "Book")
        #expect(outline.items.map(\.title) == ["One"])
        let bad = LipiRope("---\ntitle: [\n---\n# One\n")
        parser.parse(bad)
        let changed = outline.update(index: parser.index, rope: bad)
        #expect(changed)
        #expect(outline.title == nil)
    }

    @Test func warningMarkerAndAccessibility() {
        #expect(Renderer.warningMarker == "\u{26A0}\u{FE0E}")
        let view = makeView("---\na: [\n---\nBody\n")
        view.controller.moveCaret(to: view.controller.count)
        let full = NSRange(location: 0, length: view.accessibilityText.string.length)
        let attributed = view.accessibilityAttributedString(for: full)
        var found = false
        attributed?.enumerateAttribute(NSAttributedString.Key.accessibilityAnnotationTextAttribute, in: NSRange(location: 0, length: attributed?.length ?? 0)) { v, _, _ in
            if v != nil { found = true }
        }
        #expect(found)
    }
}
