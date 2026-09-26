import Foundation
import LipiCore
@testable import LipiExport
import LipiLayout
import Testing

@Suite("HTML export: Phase 1 syntax additions")
struct HTMLExportSyntaxTests {
    let exporter = HTMLExporter(highlighter: nil)

    @Test func headingsGetTheEditorsAnchors() {
        let markdown = "# Notes & more\n\n## Notes & more\n\n- ### In a list\n\n> Setext\n> ---\n"
        let body = exporter.body(markdown: markdown)
        #expect(body.contains("<h1 id=\"notes--more\">Notes &amp; more</h1>\n"))
        #expect(body.contains("<h2 id=\"notes--more-1\">Notes &amp; more</h2>\n"))
        #expect(body.contains("<li>\n<h3 id=\"in-a-list\">In a list</h3>\n</li>"))
        #expect(body.contains("<h2 id=\"setext\">Setext</h2>"))
        // The same ids as the `[toc]` and the outline.
        var parser = LipiParser(options: .editor)
        parser.parse(markdown)
        for item in TableOfContents(index: parser.index).items {
            #expect(body.contains("id=\"\(item.anchor)\""))
        }
    }

    @Test func attributesSetTheIdAndClassesAndAreDropped() {
        let body = exporter.body(markdown: "# Intro *here* now {#start .lead .wide}\n\n## Intro here\n\n## Plain {.note}\n")
        #expect(body.contains("<h1 id=\"start\" class=\"lead wide\">Intro <em>here</em> now</h1>"))
        #expect(body.contains("<h2 id=\"intro-here\">Intro here</h2>"))
        #expect(body.contains("<h2 id=\"plain\" class=\"note\">Plain</h2>"))
        #expect(!body.contains("{"))
    }

    @Test func attributeLikeTextThatIsNotAnAttributeBlockStays() {
        let body = exporter.body(markdown: "# Set {a, b}\n")
        #expect(body.contains("<h1 id=\"set-a-b\">Set {a, b}</h1>"))
    }

    @Test func tocBecomesANestedListOfLinks() {
        let markdown = "[TOC]\n\n# One\n\n## Two {#second}\n\n# Three :tada:\n"
        let body = exporter.body(markdown: markdown)
        #expect(!body.contains("[TOC]"))
        #expect(body.hasPrefix("<nav class=\"toc\">\n<ul>\n<li><a href=\"#one\">One</a>\n<ul>\n<li><a href=\"#second\">Two</a></li>\n</ul>\n</li>\n<li><a href=\"#three-\">Three 🎉</a></li>\n</ul>\n</nav>\n"))
        #expect(body.contains("<h2 id=\"second\">Two</h2>"))
        #expect(body.contains("<h1 id=\"three-\">Three 🎉</h1>"))
    }

    @Test func tocOnlyAsItsOwnTopLevelParagraph() {
        let body = exporter.body(markdown: "# A\n\nSee [toc] here.\n\n- [toc]\n\n`[toc]`\n")
        #expect(!body.contains("<nav"))
        #expect(body.contains("See [toc] here."))
        #expect(body.contains("<li>[toc]</li>"))
    }

    @Test func emojiShortcodesOutsideCodeAndMath() {
        let markdown = """
            Ship it :rocket: and :+1::smile:, not :nosuchemoji:.

            `:rocket:` and $a :rocket: b$

            ```
            :rocket:
            ```

            <https://example.com/:rocket:/x> [a :rocket: link](https://example.com/:smile:)

            | :rocket: |
            |---|
            | **:smile:** |

            """
        let body = exporter.body(markdown: markdown)
        #expect(body.contains("Ship it 🚀 and 👍😄, not :nosuchemoji:."))
        #expect(body.contains("<code>:rocket:</code>"))
        #expect(body.contains("data-tex=\"a :rocket: b\""))
        #expect(body.contains("<pre><code>:rocket:\n</code></pre>"))
        #expect(body.contains("<a href=\"https://example.com/:rocket:/x\">https://example.com/:rocket:/x</a>"))
        #expect(body.contains("<a href=\"https://example.com/:smile:\">a 🚀 link</a>"))
        #expect(body.contains("<th>🚀</th>"))
        #expect(body.contains("<strong>😄</strong>"))
    }

    @Test func optionalSyntaxFollowsTheSettings() {
        let markdown = "H~2~O, x^2^ and ==this==.\n"
        let off = exporter.body(markdown: markdown)
        #expect(!off.contains("<sub>") && !off.contains("<sup>") && !off.contains("<mark>"))
        let on = HTMLExporter(syntax: [.subscript, .superscript, .highlight, .table], highlighter: nil)
        #expect(on.options.extensions == HTMLExporter.parserOptions.extensions.union(HTMLExporter.optionalSyntax))
        let body = on.body(markdown: markdown)
        #expect(body.contains("H<sub>2</sub>O, x<sup>2</sup> and <mark>this</mark>."))
        #expect(on.document(markdown: markdown, title: "t").contains("mark { background: var(--lipi-highlight)"))
    }

    @Test func crlfSourcesStillMatchHeadings() {
        let body = exporter.body(markdown: "[toc]\r\n\r\n# A {#x}\r\n\r\ntext\r\n\r\n## B\r\n")
        #expect(body.contains("<h1 id=\"x\">A</h1>"))
        #expect(body.contains("<h2 id=\"b\">B</h2>"))
        #expect(body.contains("<a href=\"#x\">A</a>"))
    }
}

@Suite("HTML export: light and dark")
struct HTMLExportThemeModeTests {
    @Test func themesArePairedByAppearance() {
        #expect(ThemeCSSWriter.lightDarkPair(for: .taalegari).dark.name == "Kari")
        #expect(ThemeCSSWriter.lightDarkPair(for: .kari).light.name == "Taalegari")
        #expect(ThemeCSSWriter.lightDarkPair(for: .bili).dark.name == "Neeli")
        #expect(ThemeCSSWriter.lightDarkPair(for: .neeli).light.name == "Bili")
        let contrast = ThemeCSSWriter.lightDarkPair(for: Theme.neeli.highContrast)
        #expect(contrast.light.isHighContrast && contrast.dark.isHighContrast)
        var custom = Theme.bili
        custom.name = "Mine"
        #expect(ThemeCSSWriter.lightDarkPair(for: custom).dark.name == "Kari")
    }

    @Test func windowModeHasOnePalette() {
        let html = HTMLExporter(theme: .kari, highlighter: nil).document(markdown: "x", title: "t")
        #expect(!html.contains("prefers-color-scheme"))
        #expect(!html.contains("name=\"color-scheme\""))
        #expect(html.contains("color-scheme: dark;"))
        #expect(html.contains("--lipi-bg: #121212;"))
    }

    @Test func lightAndDarkEmitsAMediaQuery() throws {
        let html = HTMLExporter(theme: .kari, themeMode: .lightAndDark, highlighter: nil).document(markdown: "x", title: "t")
        #expect(html.contains("<meta name=\"color-scheme\" content=\"light dark\">"))
        #expect(html.contains("color-scheme: light dark;"))
        let media = try #require(html.range(of: "@media screen and (prefers-color-scheme: dark) {"))
        let light = html[..<media.lowerBound], dark = html[media.upperBound...]
        #expect(light.contains("--lipi-bg: #F5EDDC;"), "Taalegari by default")
        #expect(dark.contains("--lipi-bg: #121212;"), "Kari for dark readers")
        #expect(dark.contains("--lipi-syntax-keyword: #F08A73;"))
        // The window's fonts stay, so nothing reflows when the appearance flips.
        #expect(light.contains("IBM Plex Serif"))
        #expect(!html.contains("Source Serif 4"))
    }

    @Test func titlesAreDistinct() {
        #expect(Set(ExportThemeMode.allCases.map(\.title)).count == ExportThemeMode.allCases.count)
    }
}
