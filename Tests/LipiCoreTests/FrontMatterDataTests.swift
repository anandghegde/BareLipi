@testable import LipiCore
import Testing

@Suite("Front matter values (§6.13)")
struct FrontMatterDataTests {
    @Test func yamlKeys() {
        let d = FrontMatterData.parse("""
        title: "A *day*"
        assets: img/${filename}
        typora-root-url: ..
        lang: ja
        math:
          macros: \\newcommand{\\R}{\\mathbb{R}}
        tags: [a, b]
        """, kind: .yaml)
        #expect(d.error == nil)
        #expect(d.title == "A *day*")
        #expect(d.assets == "img/${filename}")
        #expect(d.typoraRootURL == "..")
        #expect(d.lang == "ja")
        #expect(d.mathMacros == "\\newcommand{\\R}{\\mathbb{R}}")
    }

    @Test func yamlMacroMapAndDottedKey() {
        let map = FrontMatterData.parse("math:\n  macros:\n    R: \\mathbb{R}\n    \\N: \\mathbb{N}\n", kind: .yaml)
        #expect(map.mathMacros == "\\newcommand{\\R}{\\mathbb{R}}\n\\newcommand{\\N}{\\mathbb{N}}")
        let dotted = FrontMatterData.parse("math.macros: \\def\\e{\\varepsilon}\n", kind: .yaml)
        #expect(dotted.mathMacros == "\\def\\e{\\varepsilon}")
    }

    @Test func tomlKeys() {
        let d = FrontMatterData.parse("""
        title = "TOML title"
        assets = "pics"
        typora-copy-images-to = "../media"

        [math]
        macros = { R = "\\\\mathbb{R}" }
        """, kind: .toml)
        #expect(d.error == nil)
        #expect(d.title == "TOML title")
        #expect(d.assets == "pics")
        #expect(d.typoraCopyImagesTo == "../media")
        #expect(d.mathMacros == "\\newcommand{\\R}{\\mathbb{R}}")
    }

    @Test func malformedKeepsAnErrorAndNoValues() {
        let yaml = FrontMatterData.parse("title: x\nbad: [unclosed\n", kind: .yaml)
        #expect(yaml.isMalformed)
        #expect(yaml.title == nil)
        #expect(yaml.error?.hasPrefix("YAML error") == true)
        let dup = FrontMatterData.parse("a: 1\na: 2\n", kind: .yaml)
        #expect(dup.isMalformed)
        let list = FrontMatterData.parse("- just\n- a list\n", kind: .yaml)
        #expect(list.isMalformed)
        let toml = FrontMatterData.parse("title = \"x\"\nthis is not toml\n", kind: .toml)
        #expect(toml.isMalformed)
        #expect(toml.error?.contains("line 3") == true)
    }

    /// A date-time whose time part does not start with a digit (typing
    /// into `date = 2024-05-01T10:00:00Z`) tripped toml++'s
    /// `TOML_ASSERT_ASSUME` in `parse_time`: an abort in debug builds and
    /// undefined behaviour in release. It is now a parse error.
    @Test(arguments: [
        "date = 2024-05-01Tx0:00:00Z\n", "date = 2024-05-01T\n", "date = 2024-05-01 x\n",
        "date = 2024-05-01t:00\n", "d = 1979-05-27T*\n", "d = 1979-05-27T-07:00\n",
        "[a]\nd = 2024-05-01TZ\n",
    ])
    func malformedTOMLDateTimeIsAnError(_ source: String) {
        let d = FrontMatterData.parse(source, kind: .toml)
        #expect(d.isMalformed)
    }

    /// A line starting with a combining mark (typing Kannada into a TOML
    /// key) tripped the same kind of assert in `parse_key`.
    @Test(arguments: [
        "\u{0CCD} x = 1\n", "[params]\n\u{0CCD}  weigh\u{093C}ts = [1, 2, 3]\n",
        "[\u{0CCD}]\n", "a.\u{0CCD} = 1\n",
    ])
    func malformedTOMLKeyIsAnError(_ source: String) {
        let d = FrontMatterData.parse(source, kind: .toml)
        #expect(d.isMalformed)
    }

    @Test func emptyIsWellFormed() {
        #expect(!FrontMatterData.parse("", kind: .yaml).isMalformed)
        #expect(!FrontMatterData.parse("# only a comment\n", kind: .yaml).isMalformed)
        #expect(!FrontMatterData.parse("", kind: .toml).isMalformed)
    }

    @Test func fromADocument() {
        #expect(FrontMatterData.parse(document: "---\r\ntitle: CRLF\r\n---\r\nbody\r\n")?.title == "CRLF")
        #expect(FrontMatterData.parse(document: "+++\ntitle = 'T'\n+++\n")?.title == "T")
        #expect(FrontMatterData.parse(document: "---\ntitle: x\n...\nbody")?.title == "x")
        #expect(FrontMatterData.parse(document: "# no front matter\ntitle: x") == nil)
        #expect(FrontMatterData.parse(document: "---\ntitle: never closed\n") == nil)
    }

    @Test func fromTheParsedIndex() {
        let rope = LipiRope("---\ntitle: Indexed\n---\n# H\n")
        var parser = LipiParser(options: .editor)
        parser.parse(rope)
        #expect(FrontMatterData.parse(index: parser.index, rope: rope)?.title == "Indexed")
        #expect(FrontMatterData.content(index: parser.index, rope: rope)?.text == "title: Indexed\n")
    }

    @Test("malformed front matter is shown as source with a warning")
    func projectionShowsSource() {
        let text = "---\ntitle: [x\n---\nbody\n"
        let rope = LipiRope(text)
        var parser = LipiParser(options: .editor)
        parser.parse(rope)
        var projection = Projection()
        projection.update(index: parser.index, rope: rope, reveal: .none)
        let good = projection.blocks[0].block
        #expect(good.context.warning == nil)
        #expect(good.cells[0].text == "title: [x")

        projection.frontMatterWarning = "YAML error on line 2: bad"
        let result = projection.update(index: parser.index, rope: rope, reveal: .none)
        #expect(result.changedEntries == [0])
        let bad = projection.blocks[0].block
        #expect(bad.context.warning == "YAML error on line 2: bad")
        #expect(bad.isRevealed)
        #expect(bad.cells[0].text.hasPrefix("---\ntitle: [x\n---"))

        projection.frontMatterWarning = nil
        #expect(projection.update(index: parser.index, rope: rope, reveal: .none).changedEntries == [0])
        #expect(projection.blocks[0].block.context.warning == nil)
    }
}
