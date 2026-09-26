import AppKit
import CoreText
import Foundation
import LipiCore
import LipiLayout
import Testing

@Suite("Typesetter")
struct TypesetterTests {
    let typesetter = makeTypesetter()

    func typeset(_ text: String, caret: Int = 0, cell: Int = 0, entry: Int = 0) -> (TypesetCell, DisplayBlock) {
        let doc = Doc(text, caret: caret)
        let block = doc.block(entry)
        return (typesetter.typeset(block.cells[cell], in: block, cellIndex: cell), block)
    }

    @Test func plainParagraph() {
        let (cell, _) = typeset("Plain text.")
        #expect(cell.role == .body)
        #expect(cell.lineHeight == 26)
        #expect(cell.lineHeightClass == .standard)
        #expect(!cell.isRightToLeft)
        #expect(cell.decorations.isEmpty)
        #expect(cell.attributed.string == "Plain text.")
        let fonts = runFonts(cell.attributed)
        #expect(fonts.count == 1)
        #expect(familyName(of: fonts[0].font) == typesetter.cascade.resolved[.body])
        #expect(CTFontGetSize(fonts[0].font) == 17)
        let ps = cell.attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(ps?.minimumLineHeight == 26 && ps?.maximumLineHeight == 26)
    }

    @Test func tallScriptRaisesTheWholeParagraph() {
        let (cell, _) = typeset("Latin then ಕನ್ನಡ then Latin.")
        #expect(cell.lineHeightClass == .tall)
        #expect(cell.lineHeight == 28)
        let fonts = runFonts(cell.attributed)
        let kannada = fonts.first { familyName(of: $0.font).contains("Kannada") }
        #expect(kannada != nil, "no Kannada glyph run: \(fonts.map { familyName(of: $0.font) })")
        #expect(approximately(CTFontGetSize(kannada?.font ?? fonts[0].font), 17 * 1.08, within: 0.25))
    }

    @Test func devanagariShapesThroughTheCascade() {
        let (cell, _) = typeset("ज्ञान and क्षेत्र")
        let fonts = runFonts(cell.attributed)
        #expect(fonts.contains { familyName(of: $0.font).contains("Devanagari") })
        #expect(cell.lineHeight == 28)
    }

    @Test func emphasisAndStrong() {
        let (cell, block) = typeset("a *em* and **strong** b")
        let runs = block.cells[0].runs
        let em = runs.first { $0.style.contains(.emphasis) }!
        let strong = runs.first { $0.style.contains(.strong) }!
        let emFont = cell.attributed.attribute(.font, at: em.range.lowerBound, effectiveRange: nil) as! CTFont
        let strongFont = cell.attributed.attribute(.font, at: strong.range.lowerBound, effectiveRange: nil) as! CTFont
        let plainFont = cell.attributed.attribute(.font, at: 0, effectiveRange: nil) as! CTFont
        #expect(isItalic(emFont))
        #expect(!isItalic(plainFont))
        #expect(weightTrait(of: strongFont) > weightTrait(of: plainFont))
        // Delimiters are hidden when the caret is elsewhere.
        #expect(cell.attributed.string == "a em and strong b")
    }

    @Test func codeSpanUsesMonoAndAPill() {
        let (cell, block) = typeset("call `foo()` now")
        let code = block.cells[0].runs.first { $0.style.contains(.code) }!
        let font = cell.attributed.attribute(.font, at: code.range.lowerBound, effectiveRange: nil) as! CTFont
        #expect(familyName(of: font) == typesetter.cascade.resolved[.mono])
        #expect(CTFontGetSize(font) == 15.5)  // 17 × 0.9 to the half point
        #expect(cell.decorations.contains { $0.kind == .codePill && $0.range == code.range })
    }

    @Test func strikethroughSetsAttributeAndDecoration() {
        let (cell, block) = typeset("~~gone~~ kept")
        let struck = block.cells[0].runs.first { $0.style.contains(.strikethrough) }!
        let value = cell.attributed.attribute(.strikethroughStyle, at: struck.range.lowerBound, effectiveRange: nil) as? Int
        #expect(value == NSUnderlineStyle.single.rawValue)
        #expect(cell.decorations.contains { $0.kind == .strikethrough })
    }

    @Test func subscriptSuperscriptAndHighlight() {
        var options = ParserOptions.editor
        options.extensions.formUnion([.subscript, .superscript, .highlight])
        let doc = Doc("H~2~O 2^10^ ==hi==", options: options)
        let block = doc.block(0)
        let cell = typesetter.typeset(block.cells[0], in: block, cellIndex: 0)
        #expect(cell.attributed.string == "H2O 210 hi")
        let runs = block.cells[0].runs
        let sub = runs.first { $0.style.contains(.subscript) }!
        let sup = runs.first { $0.style.contains(.superscript) }!
        #expect(cell.attributed.attribute(.superscript, at: sub.range.lowerBound, effectiveRange: nil) as? Int == -1)
        #expect(cell.attributed.attribute(.superscript, at: sup.range.lowerBound, effectiveRange: nil) as? Int == 1)
        let font = cell.attributed.attribute(.font, at: sup.range.lowerBound, effectiveRange: nil) as! CTFont
        #expect(CTFontGetSize(font) == (17 * 0.75).rounded())
        let mark = runs.first { $0.style.contains(.highlight) }!
        #expect(cell.decorations.contains { $0.kind == .highlight && $0.range == mark.range })
    }

    @Test func linkChipCarriesARunDelegateAndAttachment() {
        // Balanced preset: the destination folds to a chip while the caret is
        // in the label (caret 6 is inside "docs").
        let (cell, block) = typeset("see [docs](https://example.com) here", caret: 6)
        let chip = block.cells[0].runs.first { $0.style.contains(.chip) }
        #expect(chip != nil)
        guard let chip else { return }
        let at = chip.range.lowerBound
        #expect((cell.attributed.string as NSString).character(at: at) == 0xFFFC)
        #expect(cell.attributed.attribute(.lipiChip, at: at, effectiveRange: nil) != nil)
        #expect(cell.attributed.attribute(.ctRunDelegate, at: at, effectiveRange: nil) != nil)
        #expect(cell.attributed.attribute(.attachment, at: at, effectiveRange: nil) is NSTextAttachment)
        #expect(cell.decorations.contains { $0.kind == .chip })
        // The chip occupies about 1.5 em on the line.
        let line = CTLineCreateWithAttributedString(cell.attributed)
        let chipWidth = CTLineGetOffsetForStringIndex(line, at + 1, nil) - CTLineGetOffsetForStringIndex(line, at, nil)
        #expect(approximately(chipWidth, (17 * 1.5).rounded(), within: 1))
    }

    @Test func revealedSyntaxIsColouredNotHidden() {
        let (cell, block) = typeset("a *em* b", caret: 3)
        #expect(cell.attributed.string == "a *em* b")
        let syntax = block.cells[0].runs.first { $0.style.contains(.syntax) }!
        let color = cell.attributed.attribute(.ctForeground, at: syntax.range.lowerBound, effectiveRange: nil)
        #expect(color != nil)
        let cg = color as! CGColor
        #expect(cg == typesetter.colors.syntax.cgColor)
    }

    @Test func tableCellsGetRolesAndAlignment() {
        let text = "| a | b | c |\n| --- | ---: | :---: |\n| 1 | 2 | 3 |\n"
        let doc = Doc(text)
        let block = doc.block()
        #expect(block.table?.columns == 3 && block.table?.rows == 2)
        #expect(typesetter.role(of: block, cellIndex: 0) == .tableHeader)
        #expect(typesetter.role(of: block, cellIndex: 3) == .tableCell)
        let header = typesetter.typeset(block.cells[1], in: block, cellIndex: 1)
        #expect(header.alignment == .right)
        #expect(header.style.weight == .semibold)
        let centred = typesetter.typeset(block.cells[5], in: block, cellIndex: 5)
        #expect(centred.alignment == .center)
        let ps = centred.attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(ps?.alignment == .center)
    }

    @Test func rightToLeftParagraph() {
        let (cell, _) = typeset("العربية لغة جميلة")
        #expect(cell.isRightToLeft)
        #expect(cell.lineHeightClass == .standard)
    }

    @Test func cjkRunsCarryTheLanguageTag() {
        let ja = makeTypesetter(language: "ja")
        let doc = Doc("日本語の文章。")
        let block = doc.block()
        let cell = ja.typeset(block.cells[0], in: block, cellIndex: 0)
        #expect(cell.attributed.attribute(.ctLanguage, at: 0, effectiveRange: nil) as? String == "ja")
        let untagged = typesetter.typeset(block.cells[0], in: block, cellIndex: 0)
        #expect(untagged.attributed.attribute(.ctLanguage, at: 0, effectiveRange: nil) == nil)
    }

    @Test func headingsAndCodeBlocks() {
        let (h1, _) = typeset("# Title")
        #expect(h1.role == .heading(1))
        #expect(h1.lineHeight == 40)
        #expect(CTFontGetSize(runFonts(h1.attributed)[0].font) == 34)
        // The caret sits in the first paragraph, so the fence is folded.
        let (code, _) = typeset("intro\n\n```swift\nlet x = 1\n```", entry: 1)
        #expect(code.role == .codeBlock)
        #expect(code.attributed.string.hasPrefix("let x = 1"))
        #expect(familyName(of: runFonts(code.attributed)[0].font) == typesetter.cascade.resolved[.mono])
    }

    @Test func keysChangeWithTextRoleAndZoom() {
        let (a, _) = typeset("same text")
        let (b, _) = typeset("same text")
        let (c, _) = typeset("other text")
        #expect(a.key == b.key)
        #expect(a.key != c.key)
        let zoomed = makeTypesetter(zoom: 1.3)
        let doc = Doc("same text")
        let block = doc.block()
        #expect(zoomed.typeset(block.cells[0], in: block, cellIndex: 0).key != a.key)
    }

    @Test func gutterMarkerString() {
        let marker = typesetter.attributedString("##", role: .gutterMarker)
        #expect(marker.string == "##")
        #expect(marker.attribute(.font, at: 0, effectiveRange: nil) != nil)
        #expect((marker.attribute(.ctForeground, at: 0, effectiveRange: nil) as! CGColor) == typesetter.colors.muted.cgColor)
    }
}
