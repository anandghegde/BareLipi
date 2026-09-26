import AppKit
import Foundation
import LipiCore
@testable import LipiExport
import LipiHighlight
import LipiLayout
import Testing
@testable import LipiApp

@Suite("HTML export (P0-14)")
struct HTMLExportTests {
    let sample = """
        # Notes & 1 < 2

        Some *emphasis*, a [link](https://example.com) and `code`.

        | a | b |
        |---|---|
        | 1 | 2 |

        - [x] done

        ```swift
        let s = "<tag>" // a & b
        func greet() {}
        ```

        ```nosuchlanguage
        x < y
        ```

        Math $x^2$ and a note.[^1]

        [^1]: The note.

        """

    @Test func documentIsStandaloneUTF8() {
        let html = HTMLExporter(theme: .taalegari).document(markdown: sample, title: "My \"Notes\"")
        #expect(html.hasPrefix("<!doctype html>"))
        #expect(html.contains("<meta charset=\"utf-8\">"))
        #expect(html.contains("<title>My &quot;Notes&quot;</title>"))
        #expect(html.contains("<style>"))
        // Nothing loaded from elsewhere: no scripts, stylesheets or fonts.
        #expect(!html.contains("<script"))
        #expect(!html.contains("<link"))
        #expect(!html.contains("@import"))
        #expect(!html.contains("url("))
    }

    @Test func rendersGFMFootnotesAndMath() {
        let body = HTMLExporter(highlighter: nil).body(markdown: sample)
        #expect(body.contains("<h1>Notes &amp; 1 &lt; 2</h1>"))
        #expect(body.contains("<table>"))
        #expect(body.contains("checked"))
        #expect(body.contains("class=\"footnotes\""))
        #expect(body.contains("<span class=\"math inline\">"))
    }

    @Test func fencedCodeIsHighlightedAndEscaped() {
        let body = HTMLExporter(highlighter: HighlightService(capacity: 8)).body(markdown: sample)
        #expect(body.contains("<pre><code class=\"language-swift\">"))
        #expect(body.contains("<span class=\"tok-keyword\">let</span>"))
        #expect(body.contains("<span class=\"tok-string\">&quot;&lt;tag&gt;&quot;</span>"))
        #expect(body.contains("<span class=\"tok-comment\">// a &amp; b</span>"))
        #expect(body.contains("<span class=\"tok-function\">greet</span>"))
        // Unknown languages keep cmark's escaped text untouched.
        #expect(body.contains("<code class=\"language-nosuchlanguage\">x &lt; y\n</code>"))
    }

    @Test func highlightingKeepsTheCodeText() {
        let plain = HTMLExporter(highlighter: nil).body(markdown: sample)
        let coloured = HTMLExporter(highlighter: HighlightService(capacity: 8)).body(markdown: sample)
        let stripped = coloured.replacingOccurrences(of: "<span class=\"tok-[a-z]+\">", with: "", options: .regularExpression)
            .replacingOccurrences(of: "</span>", with: "")
        let plainStripped = plain.replacingOccurrences(of: "</span>", with: "")
            .replacingOccurrences(of: "<span class=\"math inline\">", with: "")
        #expect(stripped.replacingOccurrences(of: "<span class=\"math inline\">", with: "") == plainStripped)
    }

    @Test func markupHandlesSurrogatePairsAndOverlaps() {
        let code = "😀 \"a\""
        let spans = [HighlightSpan(range: 3..<6, token: .string), HighlightSpan(range: 4..<5, token: .keyword)]
        #expect(HTMLExporter.markup(code: code, spans: spans) == "😀 <span class=\"tok-string\">&quot;a&quot;</span>")
    }

    @Test(arguments: Theme.all.map(\.name))
    func cssCarriesThePalette(_ name: String) throws {
        let theme = try #require(Theme.named(name))
        let css = ThemeCSSWriter(theme: theme).css()
        #expect(css.contains("--lipi-bg: \(theme.colors.bg.hexString);"))
        #expect(css.contains("--lipi-ink: \(theme.colors.ink.hexString);"))
        #expect(css.contains("--lipi-syntax-keyword: \(theme.colors.code.keyword.hexString);"))
        #expect(css.contains("color-scheme: \(theme.isDark ? "dark" : "light")"))
        for token in SyntaxToken.allCases {
            #expect(css.contains(".\(token.cssClass) { color: var(--lipi-"))
        }
        #expect(css.contains(".tok-inserted { color: var(--lipi-ok); }"))
    }

    @Test func translucentColoursBecomeRGBA() {
        #expect(ThemeColor(hex: 0x336699, alpha: 0.5).css == "rgba(51, 102, 153, 0.5)")
        #expect(ThemeColor(hex: 0x336699).css == "#336699")
    }

    @MainActor
    @Test func documentExportWritesTheFile() async throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let source = dir.file("Report.md")
        try bytes("# Report\n\n```python\ndef f(): pass\n```\n").write(to: source)
        let document = LipiDocument()
        try document.read(from: source, ofType: "net.daringfireball.markdown")
        document.fileURL = source
        document.makeWindowControllers()
        defer { document.close() }
        document.windowController!.controller.setTheme(.kari)
        let target = dir.file("Report.html")
        try await document.exportHTML(to: target)
        let html = try String(contentsOf: target, encoding: .utf8)
        #expect(html.contains("<title>Report</title>"))
        #expect(html.contains("<h1>Report</h1>"))
        #expect(html.contains("<span class=\"tok-keyword\">def</span>"))
        #expect(html.contains("--lipi-bg: \(Theme.kari.colors.bg.hexString);"))
        #expect(!document.isDocumentEdited)
    }

    @MainActor
    @Test func fileMenuOffersHTMLExport() throws {
        _ = NSApplication.shared
        let menu = MainMenu.build()
        let file = try #require(menu.item(withTitle: "File")?.submenu)
        let export = try #require(file.item(withTitle: "Export")?.submenu)
        let html = try #require(export.item(withTitle: "HTML…"))
        #expect(html.action == #selector(LipiDocument.exportHTML(_:)))
        #expect(html.keyEquivalent == "e")
        #expect(html.keyEquivalentModifierMask == [.command, .shift])
    }
}
