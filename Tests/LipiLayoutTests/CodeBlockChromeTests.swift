import CoreGraphics
import Foundation
import LipiCore
import LipiHighlight
@testable import LipiLayout
import Testing

@Suite("Code block header, gutter and wrap (P0-05)")
@MainActor
struct CodeBlockChromeTests {
    let fenced = "Intro.\n\n```swift\nlet a = 1\nlet b = 2\nlet c = 3\n```\n"

    func codeEntry(_ doc: Doc) -> Int {
        doc.projection.entries.firstIndex { $0.blocks.contains { if case .code = $0.role { return true }; return false } }!
    }

    func layoutCode(_ text: String, caret: Int = 0, options: CodeBlockOptions = CodeBlockOptions(),
                    typesetter: Typesetter = makeTypesetter()) -> BlockLayout {
        let doc = Doc(text, caret: caret)
        return LayoutEngine.layout(doc.block(codeEntry(doc)), typesetter: typesetter, measure: 480, wideWidth: 480, codeOptions: options)
    }

    @Test func headerRowStandsInForTheHiddenOpeningFence() {
        let block = layoutCode(fenced)
        let chrome = try! #require(block.code)
        #expect(chrome.hasHeader)
        #expect(chrome.language == "swift")
        #expect(!chrome.isUnclosed)
        #expect(block.cellFrame(0).minY == block.style.paddingY + block.style.lineHeight)
        #expect(block.cell(0).lines.count == 3)
        #expect(approximately(block.height, block.cell(0).height + 2 * block.style.paddingY + block.style.lineHeight))
    }

    @Test func revealedFenceHasNoHeader() {
        let caret = (fenced as NSString).range(of: "```swift").location + 3
        let block = layoutCode(fenced, caret: caret)
        let chrome = try! #require(block.code)
        #expect(!chrome.hasHeader)
        #expect(block.cellFrame(0).minY == block.style.paddingY)
        #expect(LayoutEngine.codeHeader(of: block, typesetter: makeTypesetter(), options: CodeBlockOptions()) == nil)
    }

    @Test func indentedCodeHasNoHeader() {
        let block = layoutCode("Intro.\n\n    let a = 1\n")
        #expect(block.code?.hasHeader == false)
        #expect(block.code?.isFenced == false)
    }

    @Test func unclosedFenceIsFlagged() {
        let doc = Doc("Intro.\n\n```swift\nlet a = 1\n")
        #expect(doc.block(codeEntry(doc)).isUnclosedFence)
        let block = layoutCode("Intro.\n\n```swift\nlet a = 1\n")
        #expect(block.code?.isUnclosed == true)
        let header = try! #require(LayoutEngine.codeHeader(of: block, typesetter: makeTypesetter(), options: CodeBlockOptions()))
        #expect(header.pill != nil)
        #expect(!Doc(fenced).block(codeEntry(Doc(fenced))).isUnclosedFence)
        // The flag is part of the layout key, so closing the fence re-lays it out.
        #expect(Doc("Intro.\n\n```swift\nlet a = 1\n```\n").block(1).layoutKey != doc.block(1).layoutKey)
    }

    @Test func headerButtonsSitRightToLeftInsideTheRow() {
        let block = layoutCode(fenced)
        let header = try! #require(LayoutEngine.codeHeader(of: block, typesetter: makeTypesetter(), options: CodeBlockOptions()))
        #expect(header.buttons.map(\.button) == [.copy, .wrap, .lineNumbers])
        for item in header.buttons { #expect(header.row.contains(CGPoint(x: item.rect.midX, y: item.rect.midY))) }
        #expect(header.buttons[0].rect.maxX <= header.buttons[1].rect.minX)
        #expect(header.buttons[2].rect.maxX <= block.width - block.style.paddingX + 0.5)
        #expect(header.labelOrigin.x == block.style.paddingX)
    }

    @Test func lineNumbersShiftTheCodeAndNumberOnlyCodeLines() {
        let plain = layoutCode(fenced)
        let numbered = layoutCode(fenced, options: CodeBlockOptions(lineNumbers: true))
        let chrome = try! #require(numbered.code)
        #expect(plain.code?.gutterWidth == 0)
        #expect(chrome.gutterWidth > 0)
        #expect(approximately(numbered.cellFrame(0).minX, plain.cellFrame(0).minX + chrome.gutterWidth))
        #expect(chrome.lineStarts == [0, 1, 2])
        #expect(numbered.cellFrame(0).maxX <= numbered.width - numbered.style.paddingX + 0.5)
    }

    @Test func lineNumbersCountLogicalLinesNotWrappedFragments() {
        let long = String(repeating: "word ", count: 60)
        let block = layoutCode("Intro.\n\n```\n\(long)\nshort\n```\n", options: CodeBlockOptions(lineNumbers: true))
        let chrome = try! #require(block.code)
        #expect(block.cell(0).lines.count > 2)
        #expect(chrome.lineStarts.count == 2)
        #expect(chrome.lineStarts[0] == 0)
        #expect(chrome.lineStarts[1] == block.cell(0).lines.count - 1)
    }

    @Test func wrapOffKeepsEachLineOnOneFragment() {
        let long = String(repeating: "token ", count: 60)
        let text = "Intro.\n\n```\n\(long)\nshort\n```\n"
        let wrapped = layoutCode(text)
        let unwrapped = layoutCode(text, options: CodeBlockOptions(wrap: false))
        let chrome = try! #require(unwrapped.code)
        #expect(wrapped.cell(0).lines.count > 2)
        #expect(unwrapped.cell(0).lines.count == 2)
        #expect(!chrome.wraps)
        #expect(unwrapped.cellFrame(0).width > chrome.viewportWidth)
        #expect(unwrapped.height < wrapped.height)
    }

    @Test func documentLayoutOptionsRelayOutAndHitTestTheHeader() {
        let doc = Doc(fenced)
        let layout = makeLayout(doc)
        let entry = codeEntry(doc)
        _ = layout.layoutIfNeeded(in: 0...2000)
        let before = layout.ensureLayout(entry).height
        layout.codeOptions.lineNumbers = true
        let placed = layout.layoutIfNeeded(in: 0...2000)
        #expect(layout.ensureLayout(entry).blocks[0].code?.gutterWidth ?? 0 > 0)
        #expect(layout.ensureLayout(entry).height == before)
        let buttons = layout.codeHeaderButtons(in: placed)
        #expect(buttons.count == 3)
        for (rect, button) in buttons {
            #expect(layout.codeHeaderButton(at: CGPoint(x: rect.midX, y: rect.midY))?.button == button)
        }
        // Away from the header there is no button.
        let caret = try! #require(layout.caretRect(forSource: (fenced as NSString).range(of: "let b").location))
        #expect(layout.codeHeaderButton(at: CGPoint(x: caret.midX, y: caret.midY)) == nil)
    }

    @Test func unwrappedCodeScrollsSidewaysAndMovesTheCaret() {
        let long = String(repeating: "token ", count: 80)
        let text = "Intro.\n\n```\n\(long)\n```\n"
        let doc = Doc(text)
        let layout = makeLayout(doc, width: 700)
        layout.codeOptions.wrap = false
        _ = layout.layoutIfNeeded(in: 0...2000)
        let offset = (text as NSString).range(of: "token").location + 30
        let before = try! #require(layout.caretRect(forSource: offset))
        let point = CGPoint(x: before.minX, y: before.midY)
        #expect(layout.isOverScrollableCode(point))
        #expect(layout.scrollCode(at: point, by: 100))
        let after = try! #require(layout.caretRect(forSource: offset))
        #expect(approximately(after.minX, before.minX - 100))
        // Hit testing follows the scroll.
        #expect(layout.sourceOffset(at: CGPoint(x: after.minX + 1, y: after.midY)) == offset)
        // Scrolling stops at the ends.
        #expect(layout.scrollCode(at: point, by: -10_000))
        #expect(approximately(try! #require(layout.caretRect(forSource: offset)).minX, before.minX))
        #expect(!layout.scrollCode(at: point, by: -10))
    }

    @Test func caretAtTheEndOfALongLineScrollsIntoView() {
        let long = String(repeating: "token ", count: 80)
        let text = "Intro.\n\n```\n\(long)\n```\n"
        let doc = Doc(text)
        let layout = makeLayout(doc, width: 700)
        layout.codeOptions.wrap = false
        _ = layout.layoutIfNeeded(in: 0...2000)
        let end = (text as NSString).range(of: long).upperBound
        let position = try! #require(doc.projection.position(forSource: end))
        #expect(layout.revealCodeCaret(at: position))
        let rect = try! #require(layout.caretRect(forSource: end))
        let block = layout.ensureLayout(position.entry).blocks[position.block]
        let viewportMaxX = layout.x(of: block) + block.cellFrame(0).minX + block.code!.viewportWidth
        #expect(rect.minX <= viewportMaxX)
        #expect(!layout.revealCodeCaret(at: position))
    }

    @Test func wrappingIgnoresScroll() {
        let doc = Doc("Intro.\n\n```\n\(String(repeating: "token ", count: 80))\n```\n")
        let layout = makeLayout(doc, width: 700)
        _ = layout.layoutIfNeeded(in: 0...2000)
        let block = layout.ensureLayout(codeEntry(doc)).blocks[0]
        #expect(layout.codeScrollOffset(of: block) == 0)
        #expect(!layout.isOverScrollableCode(CGPoint(x: layout.textOrigin + 40, y: layout.y(ofEntry: codeEntry(doc)) + 40)))
    }

    @Test func copyHTMLCarriesTheLanguageAndInlineColours() {
        let service = HighlightService(capacity: 8)
        service.postsNotifications = false
        var typesetter = makeTypesetter()
        typesetter.highlighter = service
        let doc = Doc("Intro.\n\n```swift\nlet a = 1 < 2 // \"x\" & y\n```\n")
        let block = doc.block(codeEntry(doc))
        #expect(typesetter.codeText(of: block)?.hasPrefix("let a = 1 < 2") == true)
        let html = try! #require(typesetter.codeHTML(of: block))
        #expect(html.hasPrefix("<pre style=\"background:#"))
        #expect(html.contains("<code class=\"language-swift\">"))
        #expect(html.contains("&lt;"))
        #expect(html.contains("&amp;"))
        #expect(html.contains("&quot;x&quot;"))
        #expect(html.contains("<span style=\"color:\(Theme.taalegari.colors.code.keyword.hexString)\">let</span>"))
        #expect(html.hasSuffix("</code></pre>"))
    }

    // MARK: Windowed highlighting

    @Test func highlightWindowRestrictsSpansToItsLines() {
        let code = String(repeating: "let a = 1\n", count: 40)
        let grammar = try! #require(GrammarBundle.grammar(forInfo: "swift"))
        let window = 10..<20
        let service = HighlightService(capacity: 4)
        service.postsNotifications = false
        let spans = service.highlight(code: code, grammar: grammar, window: window)
        let range = HighlightService.utf16Range(ofLines: window, in: code)
        #expect(!spans.isEmpty)
        #expect(spans.allSatisfy { $0.range.lowerBound >= range.lowerBound && $0.range.upperBound <= range.upperBound })
        let all = service.highlight(code: code, grammar: grammar)
        #expect(all.count > spans.count)
        #expect(HighlightService.lineCount(of: code) == 40)
        #expect(HighlightService.utf16Range(ofLines: 0..<1, in: code) == 0..<10)
    }

    @Test func longFencesAreHighlightedInAWindow() {
        let lines = HighlightService.windowedLineThreshold + 500
        let code = String(repeating: "let a = 1\n", count: lines)
        let doc = Doc("Intro.\n\n```swift\n\(code)```\n")
        var typesetter = makeTypesetter()
        let block = doc.block(codeEntry(doc))
        #expect(typesetter.codeWindow(of: block, code: code) == 0..<Typesetter.codeWindowLines)
        typesetter.codeWindows[block.id] = 2048..<3072
        #expect(typesetter.codeWindow(of: block, code: code) == 2048..<3072)
        let short = Doc(fenced)
        #expect(typesetter.codeWindow(of: short.block(codeEntry(short)), code: "let a = 1\n") == nil)
    }

    @Test func windowsCoverWholeChunks() {
        #expect(DocumentLayout.codeWindow(covering: 0...10) == 0..<Typesetter.codeWindowLines)
        #expect(DocumentLayout.codeWindow(covering: 3000...3100) == 2560..<(2560 + Typesetter.codeWindowLines))
        let wide = DocumentLayout.codeWindow(covering: 100...2000)
        #expect(wide.lowerBound == 0 && wide.upperBound > 2000 && wide.upperBound % 512 == 0)
    }

    @Test func scrollingALongFenceMovesItsWindow() {
        let lines = HighlightService.windowedLineThreshold + 1000
        let doc = Doc("Intro.\n\n```swift\n\(String(repeating: "let a = 1\n", count: lines))```\n")
        let service = HighlightService(capacity: 8)
        service.postsNotifications = false
        var typesetter = makeTypesetter()
        typesetter.highlighter = service
        let layout = makeLayout(doc, width: 700, typesetter: typesetter)
        let entry = codeEntry(doc)
        _ = layout.layoutIfNeeded(in: 0...800)
        let id = layout.ensureLayout(entry).blocks[0].id
        #expect(layout.typesetter.codeWindows[id] == nil)
        // Far down the fence: the window follows.
        let lineHeight = layout.ensureLayout(entry).blocks[0].style.lineHeight
        let y = layout.y(ofEntry: entry) + lineHeight * 4000
        _ = layout.layoutIfNeeded(in: y...(y + 800))
        let window = try! #require(layout.typesetter.codeWindows[id])
        #expect(window.contains(4000))
        #expect(window.lowerBound % 512 == 0)
        // Scrolling a little within it keeps the window.
        _ = layout.layoutIfNeeded(in: (y + lineHeight * 10)...(y + lineHeight * 10 + 800))
        #expect(layout.typesetter.codeWindows[id] == window)
    }
}
