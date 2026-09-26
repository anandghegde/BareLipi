import Foundation
import Testing
@testable import LipiCore

/// PRD §6.13: opt-in sub/superscript and highlight, emoji shortcodes,
/// heading attributes, `[toc]`.
@Suite("Extended syntax")
struct ExtendedSyntaxTests {
    static let all = ParserOptions(extensions: [.gfm, .footnotes, .math, .subscript, .superscript, .highlight,
                                                .emojiShortcodes, .headingAttributes], keepFootnotes: true)

    func html(_ s: String, _ ext: ParserOptions.Extensions) -> String {
        LipiParser.renderHTML(s, options: ParserOptions(extensions: ext))
    }

    /// Flattened `kind-name:source` pairs of the first block's inlines.
    func kinds(_ text: String, options: ParserOptions = all) -> [String] {
        let block = firstBlock(text, options: options)
        let bytes = Array(text.utf8)
        var out: [String] = []
        func walk(_ inlines: [Inline]) {
            for i in inlines {
                let src = String(decoding: bytes[i.range], as: UTF8.self)
                switch i.kind {
                case .subscript: out.append("sub:\(src)")
                case .superscript: out.append("sup:\(src)")
                case .highlight: out.append("mark:\(src)")
                case .strikethrough: out.append("del:\(src)")
                case .footnoteReference: out.append("fn:\(src)")
                case .emoji(let e): out.append("emoji:\(e):\(src)")
                case .attributes(let a): out.append("attrs:\(a):\(src)")
                default: break
                }
                walk(i.children)
            }
        }
        walk(block.inlines)
        return out
    }

    @Test func subscriptSuperscriptHighlightHTML() {
        #expect(html("H~2~O", [.subscript]) == "<p>H<sub>2</sub>O</p>\n")
        #expect(html("2^10^", [.superscript]) == "<p>2<sup>10</sup></p>\n")
        #expect(html("a ==b c== d", [.highlight]) == "<p>a <mark>b c</mark> d</p>\n")
        // Pandoc: no whitespace inside sub/superscripts.
        #expect(html("a~b c~", [.subscript]) == "<p>a~b c~</p>\n")
        #expect(html("a^b c^", [.superscript]) == "<p>a^b c^</p>\n")
        // Escaped spaces are allowed only as escapes; `~~` stays strikethrough.
        #expect(html("~~gone~~ H~2~O", [.subscript, .strikethrough]) == "<p><del>gone</del> H<sub>2</sub>O</p>\n")
        // Off by default: the text is left alone.
        #expect(html("H~2~O 2^10^ ==x==", .gfm) == "<p>H<del>2</del>O 2^10^ ==x==</p>\n")
        #expect(html("==x==", []) == "<p>==x==</p>\n")
    }

    @Test func footnotesStillWorkWithSuperscript() {
        let k = kinds("See[^1] and 2^n^.\n\n[^1]: note\n")
        #expect(k == ["fn:[^1]", "sup:^n^"])
    }

    @Test func extendedInlineRanges() {
        #expect(kinds("H~2~O") == ["sub:~2~"])
        #expect(kinds("x ==**b**== y") == ["mark:==**b**=="])
        #expect(kinds("a ~~s~~ b") == ["del:~~s~~"])
    }

    @Test func emojiShortcodes() {
        #expect(EmojiShortcodes.emoji(for: "smile") == "😄")
        #expect(EmojiShortcodes.emoji(for: "+1") == "👍")
        #expect(EmojiShortcodes.emoji(for: "nope-not-real") == nil)
        #expect(kinds("hi :smile: there :nope: :tada:") == ["emoji:😄::smile:", "emoji:🎉::tada:"])
        // Not in code spans, and off when the extension is.
        #expect(kinds("`:smile:`").isEmpty)
        #expect(kinds(":smile:", options: .gfm).isEmpty)
        // Adjacent shortcodes; a stray colon before one.
        #expect(EmojiShortcodes.matches(in: Array("a::smile::tada:".utf8)).map(\.emoji) == ["😄", "🎉"])
    }

    @Test func emojiCompletions() {
        let c = EmojiShortcodes.completions(for: "smi")
        #expect(c.first?.name.hasPrefix("smi") == true)
        #expect(c.count <= 12)
        #expect(Set(c.map(\.name)).count == c.count)
        #expect(EmojiShortcodes.completions(for: "").isEmpty)
        // Tag matches come after name matches.
        #expect(EmojiShortcodes.completions(for: "happy", limit: 50).contains { $0.name == "smile" })
    }

    @Test func headingAttributes() {
        let block = firstBlock("## Intro text {#intro .lead}\n")
        #expect(kinds("## Intro text {#intro .lead}\n") == ["attrs:#intro .lead: {#intro .lead}"])
        #expect(Headings.explicitID(of: block.inlines) == "intro")
        #expect(Headings.classes(of: block.inlines) == ["lead"])
        #expect(Headings.text(of: block.inlines) == "Intro text")
        // Not attributes: no space before, nothing before, or not an attribute list.
        #expect(kinds("## Intro{#intro}\n").isEmpty)
        #expect(kinds("## {#intro}\n").isEmpty)
        #expect(kinds("## Set {a, b}\n").isEmpty)
        #expect(kinds("Para {#x}\n").isEmpty)
    }

    @Test func anchors() {
        var a = Headings.AnchorAllocator()
        #expect(a.anchor(slug: "intro", explicit: nil) == "intro")
        #expect(a.anchor(slug: "intro", explicit: nil) == "intro-1")
        #expect(a.anchor(slug: "x", explicit: "custom") == "custom")
        #expect(a.anchor(slug: "custom", explicit: nil) == "custom-1")
        #expect(Headings.slug("Hello, World! 😄") == "hello-world-")
    }

    @Test func tocPlaceholder() {
        #expect(firstBlock("[toc]\n").isTableOfContents)
        #expect(firstBlock("[TOC]").isTableOfContents)
        #expect(!firstBlock("[toc] more\n").isTableOfContents)
        #expect(firstBlock(" [toc]\n").isTableOfContents)
        #expect(!firstBlock("# [toc]\n").isTableOfContents)
    }
}

@Suite("Extended syntax projection")
struct ExtendedSyntaxProjectionTests {
    func tiles(_ text: String) -> Bool {
        var checker = ProjectionChecker(text)
        checker.check(project(text).0)
        return checker.failures.isEmpty
    }

    @Test func emojiShowsTheGlyphUntilTheCaretIsIn() {
        #expect(displayText("hi :smile: x") == "hi 😄 x")
        #expect(displayText("hi :smile: x", caret: 5) == "hi :smile: x")
        #expect(tiles("hi :smile: x"))
    }

    @Test func headingAttributesAreHiddenUntilTheCaretIsIn() {
        #expect(displayText("# Intro {#start}") == "Intro")
        #expect(displayText("# Intro {#start}", caret: 10).contains("{#start}"))
        #expect(tiles("# Intro {#start}\n"))
    }
}
