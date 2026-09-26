import CoreText
import Foundation
import LipiCore
import LipiHighlight
@testable import LipiLayout
import Testing

@Suite("Code highlighting in layout (P0-05)")
@MainActor
struct CodeHighlightLayoutTests {
    let source = "Intro.\n\n```swift\nlet x = 42 // note\n```\n\nOutro.\n"

    func colour(at text: String, in attributed: NSAttributedString) -> CGColor? {
        let range = (attributed.string as NSString).range(of: text)
        guard range.location != NSNotFound else { return nil }
        return (attributed.attribute(.ctForeground, at: range.location, effectiveRange: nil) as! CGColor)
    }

    func same(_ a: CGColor?, _ b: ThemeColor) -> Bool {
        guard let a, let c = a.components, let d = b.cgColor.components, c.count == d.count else { return false }
        return zip(c, d).allSatisfy { abs($0 - $1) < 0.002 }
    }

    func codeBlock(_ doc: Doc) -> DisplayBlock {
        for entry in doc.projection.entries {
            for block in entry.blocks { if case .code = block.role { return block } }
        }
        fatalError("no code block")
    }

    @Test(arguments: Theme.all.map(\.name))
    func fencedCodeTakesTheThemeSyntaxColours(name: String) {
        let theme = Theme.named(name)!
        let service = HighlightService(capacity: 8)
        service.postsNotifications = false
        var typesetter = makeTypesetter(theme)
        typesetter.highlighter = service
        let doc = Doc(source)
        let block = codeBlock(doc)
        _ = service.highlight(code: "let x = 42 // note", grammar: GrammarBundle.grammar(forInfo: "swift")!)
        let cell = typesetter.typeset(block.cells[0], in: block, cellIndex: 0)
        let colors = theme.colors
        #expect(same(colour(at: "let", in: cell.attributed), colors.code.keyword))
        #expect(same(colour(at: "42", in: cell.attributed), colors.code.number))
        #expect(same(colour(at: "// note", in: cell.attributed), colors.code.comment))
    }

    @Test func withoutAHighlighterCodeKeepsOneInk() {
        var typesetter = makeTypesetter()
        typesetter.highlighter = nil
        let doc = Doc(source)
        let block = codeBlock(doc)
        let cell = typesetter.typeset(block.cells[0], in: block, cellIndex: 0)
        #expect(!same(colour(at: "let", in: cell.attributed), Theme.taalegari.colors.code.keyword))
        #expect(typesetter.highlightStamp(of: block) == 0)
    }

    @Test func unknownLanguagesAndIndentedCodeAreNotHighlighted() {
        let typesetter = makeTypesetter()
        let fenced = Doc("```mermaid\ngraph TD\n```\n")
        #expect(typesetter.highlightStamp(of: codeBlock(fenced)) == 0)
        let indented = Doc("    let x = 1\n")
        #expect(typesetter.highlightStamp(of: codeBlock(indented)) == 0)
    }

    @Test func landingHighlightsReplaceTheLayoutWithoutMovingIt() {
        let service = HighlightService(capacity: 8)
        service.postsNotifications = false
        var typesetter = makeTypesetter()
        typesetter.highlighter = service
        let doc = Doc(source)
        let layout = makeLayout(doc, typesetter: typesetter)
        let entry = doc.projection.entries.firstIndex { $0.blocks.contains { if case .code = $0.role { return true }; return false } }!
        let before = layout.ensureLayout(entry)
        let cellBefore = before.blocks[0].cell(0).typeset.attributed
        #expect(!same(colour(at: "let", in: cellBefore), Theme.taalegari.colors.code.keyword))

        service.waitUntilIdle()
        #expect(layout.invalidateCodeBlocks())
        let after = layout.ensureLayout(entry)
        #expect(after !== before)
        #expect(after.height == before.height)
        #expect(same(colour(at: "let", in: after.blocks[0].cell(0).typeset.attributed), Theme.taalegari.colors.code.keyword))
        // Entries without code keep their layout.
        let intro = layout.ensureLayout(0)
        layout.invalidateCodeBlocks()
        #expect(layout.ensureLayout(0) === intro)
    }
}
