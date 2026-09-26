import AppKit
import Foundation
@testable import LipiExport
import Testing
@testable import LipiApp

@Suite("HTML export: math and images (P0-14)")
struct HTMLExportMathTests {
    func math(_ tex: String, display: Bool = false) -> String { TeXToMathML.math(tex, display: display) }

    @Test func formulasBecomeMathMLWithTheirSource() {
        let body = HTMLExporter(highlighter: nil).body(markdown: "Inline $a < b$ and\n\n$$\n\\frac{1}{2}\n$$\n")
        #expect(body.contains("<span class=\"math inline\" data-tex=\"a &lt; b\"><math xmlns=\"http://www.w3.org/1998/Math/MathML\" display=\"inline\">"))
        #expect(body.contains("<annotation encoding=\"application/x-tex\">a &lt; b</annotation>"))
        #expect(body.contains("<mi>a</mi><mo>&lt;</mo><mi>b</mi>"))
        #expect(body.contains("display=\"block\""))
        #expect(body.contains("<mfrac><mrow><mn>1</mn></mrow><mrow><mn>2</mn></mrow></mfrac>"))
        #expect(!body.contains("\\("))
        #expect(!body.contains("<script"))
    }

    @Test func mathInCodeIsLeftAlone() {
        let body = HTMLExporter(highlighter: nil).body(markdown: "`$x$` and\n\n```\n$y$\n```\n")
        #expect(!body.contains("<math"))
        #expect(body.contains("$y$"))
    }

    @Test func scriptsFractionsAndRoots() {
        #expect(math("x^2").contains("<msup><mi>x</mi><mn>2</mn></msup>"))
        #expect(math("x_i^2").contains("<msubsup><mi>x</mi><mi>i</mi><mn>2</mn></msubsup>"))
        #expect(math("x^{10}").contains("<msup><mi>x</mi><mrow><mn>10</mn></mrow></msup>"))
        // One digit per bare script, as in TeX.
        #expect(math("x^23").contains("<msup><mi>x</mi><mn>2</mn></msup><mn>3</mn>"))
        #expect(math("\\sqrt{x}").contains("<msqrt><mrow><mi>x</mi></mrow></msqrt>"))
        #expect(math("\\sqrt[3]{x}").contains("<mroot><mrow><mi>x</mi></mrow><mrow><mn>3</mn></mrow></mroot>"))
        #expect(math("f'(x)").contains("<msup><mi>f</mi><mo>′</mo></msup>"))
        #expect(math("\\binom{n}{k}").contains("<mfrac linethickness=\"0\">"))
    }

    @Test func symbolsOperatorsAndFunctions() {
        let m = math("\\alpha + \\Gamma \\leq \\infty - \\sin x")
        #expect(m.contains("<mi>α</mi>"))
        #expect(m.contains("<mi mathvariant=\"normal\">Γ</mi>"))
        #expect(m.contains("<mo>≤</mo>"))
        #expect(m.contains("<mi>∞</mi>"))
        #expect(m.contains("<mo>−</mo>"))
        #expect(m.contains("<mi>sin</mi>"))
        #expect(math("\\sum_{i=1}^n i").contains("<munderover><mo largeop=\"true\" movablelimits=\"true\">∑</mo>"))
        #expect(math("\\int_0^1 f").contains("<msubsup><mo largeop=\"true\">∫</mo>"))
        #expect(math("\\lim_{x \\to 0}").contains("<munder><mi>lim</mi>"))
    }

    @Test func fontsAccentsTextAndFences() {
        #expect(math("\\mathbb{R}").contains("<mi mathvariant=\"double-struck\">R</mi>"))
        #expect(math("\\mathbf{v}").contains("<mi mathvariant=\"bold\">v</mi>"))
        #expect(math("\\hat{x}").contains("<mover accent=\"true\"><mrow><mi>x</mi></mrow><mo stretchy=\"false\">^</mo></mover>"))
        #expect(math("\\text{if } x").contains("<mtext>if </mtext>"))
        let fenced = math("\\left( \\frac{a}{b} \\right]")
        #expect(fenced.contains("<mo fence=\"true\" stretchy=\"true\">(</mo>"))
        #expect(fenced.contains("<mo fence=\"true\" stretchy=\"true\">]</mo>"))
        #expect(math("\\left. x \\right|").contains("<mrow><mi>x</mi><mo fence=\"true\" stretchy=\"true\">|</mo></mrow>"))
    }

    @Test func environmentsBecomeTables() {
        let m = math("\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}")
        #expect(m.contains("<mtable><mtr><mtd><mrow><mi>a</mi></mrow></mtd><mtd><mrow><mi>b</mi></mrow></mtd></mtr><mtr>"))
        #expect(m.contains("<mo fence=\"true\" stretchy=\"true\">(</mo>"))
        let cases = math("f = \\begin{cases} 1 & x > 0 \\\\ 0 & \\text{otherwise} \\end{cases}")
        #expect(cases.contains("<mtable columnalign=\"left\">"))
        #expect(cases.components(separatedBy: "<mtr>").count == 3)
    }

    @Test func unknownCommandsAreNamedNotDropped() {
        let m = math("\\frobnicate{x} + 1")
        #expect(m.contains("<merror><mtext>\\frobnicate</mtext></merror>"))
        #expect(m.contains("<annotation encoding=\"application/x-tex\">\\frobnicate{x} + 1</annotation>"))
        #expect(TeXToMathML.unsupportedCommands(in: "\\frobnicate + \\alpha") == ["\\frobnicate"])
    }

    @Test func malformedInputStillMakesWellFormedMarkup() {
        for tex in ["{", "}", "x^", "\\frac{1}", "\\left(", "\\right)", "\\begin{pmatrix} a &", "\\", "a_{b^{c}", "''"] {
            let m = math(tex)
            let opens = m.components(separatedBy: "<mrow>").count
            let closes = m.components(separatedBy: "</mrow>").count
            #expect(opens == closes, "unbalanced for \(tex)")
            #expect(m.hasSuffix("</math>"))
            #expect(XMLParserCheck.isWellFormed(m), "not well-formed for \(tex): \(m)")
        }
    }
}

/// Parses a fragment as XML.
enum XMLParserCheck {
    static func isWellFormed(_ xml: String) -> Bool {
        XMLParser(data: Data(xml.utf8)).parse()
    }
}

@Suite("HTML export: images (P0-14)")
struct HTMLExportImageTests {
    let markdown = "![a](img/a.png) ![b](../shared/b%20c.jpg) ![r](https://example.com/r.png) ![m](missing.png)\n"

    func setUp() throws -> (TempDirectory, URL) {
        let dir = try TempDirectory()
        let docs = dir.url.appendingPathComponent("docs/img", isDirectory: true)
        let shared = dir.url.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: docs.appendingPathComponent("a.png"))
        try Data([0xFF, 0xD8, 0xFF]).write(to: shared.appendingPathComponent("b c.jpg"))
        return (dir, dir.url.appendingPathComponent("docs", isDirectory: true))
    }

    @Test func referenceRebasesRelativeLinksToThePageFolder() throws {
        let (dir, docs) = try setUp(); defer { dir.cleanUp() }
        let out = dir.url.appendingPathComponent("site/pages/Doc.html")
        let result = HTMLExporter(highlighter: nil).export(markdown: markdown, title: "Doc",
                                                           images: ImageExport(mode: .reference, documentDirectory: docs, outputURL: out))
        #expect(result.html.contains("<img src=\"../../docs/img/a.png\""))
        #expect(result.html.contains("<img src=\"../../shared/b%20c.jpg\""))
        #expect(result.html.contains("<img src=\"https://example.com/r.png\""))
        #expect(result.html.contains("<img src=\"missing.png\""))
        #expect(result.missingImages == ["missing.png"])
        #expect(result.copies.isEmpty)
        // Beside the document, links are unchanged.
        let beside = HTMLExporter(highlighter: nil).export(markdown: markdown, title: "Doc",
            images: ImageExport(mode: .reference, documentDirectory: docs, outputURL: docs.appendingPathComponent("Doc.html")))
        #expect(beside.html.contains("<img src=\"img/a.png\""))
        #expect(beside.html.contains("<img src=\"../shared/b%20c.jpg\""))
    }

    @Test func copyPlansFilesIntoASiblingFolder() throws {
        let (dir, docs) = try setUp(); defer { dir.cleanUp() }
        let out = dir.url.appendingPathComponent("out/Doc.html")
        let options = ImageExport(mode: .copy, documentDirectory: docs, outputURL: out)
        let result = HTMLExporter(highlighter: nil).export(markdown: markdown + "![again](img/a.png)\n", title: "Doc", images: options)
        #expect(options.assetsFolder.lastPathComponent == "Doc_files")
        #expect(result.html.contains("<img src=\"Doc_files/a.png\""))
        #expect(result.html.contains("<img src=\"Doc_files/b%20c.jpg\""))
        #expect(result.copies.count == 2)
        #expect(result.copies.map(\.destination.lastPathComponent).sorted() == ["a.png", "b c.jpg"])
        #expect(result.missingImages == ["missing.png"])
    }

    @Test func copyRenamesDifferentFilesWithTheSameName() {
        var used: [String: URL] = [:]
        let a = URL(fileURLWithPath: "/x/pic.png"), b = URL(fileURLWithPath: "/y/pic.png")
        #expect(HTMLExporter.uniqueName(for: a, used: &used) == "pic.png")
        #expect(HTMLExporter.uniqueName(for: b, used: &used) == "pic-2.png")
        #expect(HTMLExporter.uniqueName(for: a, used: &used) == "pic.png")
        #expect(HTMLExporter.uniqueName(for: b, used: &used) == "pic-2.png")
    }

    @Test func embedWritesDataURIs() throws {
        let (dir, docs) = try setUp(); defer { dir.cleanUp() }
        let result = HTMLExporter(highlighter: nil).export(markdown: markdown, title: "Doc",
            images: ImageExport(mode: .embed, documentDirectory: docs, outputURL: dir.url.appendingPathComponent("Doc.html")))
        #expect(result.html.contains("<img src=\"data:image/png;base64,\(Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString())\""))
        #expect(result.html.contains("<img src=\"data:image/jpeg;base64,"))
        #expect(result.html.contains("<img src=\"https://example.com/r.png\""))
        #expect(result.missingImages == ["missing.png"])
    }

    @Test func unsavedDocumentsLeaveRelativeLinksAlone() {
        let result = HTMLExporter(highlighter: nil).export(markdown: markdown, title: "Doc",
            images: ImageExport(mode: .embed, documentDirectory: nil, outputURL: URL(fileURLWithPath: "/tmp/Doc.html")))
        #expect(result.html.contains("<img src=\"img/a.png\""))
        #expect(result.missingImages.isEmpty)
    }

    @Test func localFileRecognisesSchemes() {
        let base = URL(fileURLWithPath: "/docs", isDirectory: true)
        #expect(HTMLExporter.localFile("https://a/b.png", relativeTo: base) == nil)
        #expect(HTMLExporter.localFile("data:image/png;base64,AA", relativeTo: base) == nil)
        #expect(HTMLExporter.localFile("//cdn/x.png", relativeTo: base) == nil)
        #expect(HTMLExporter.localFile("file:///tmp/x.png", relativeTo: base)?.path == "/tmp/x.png")
        #expect(HTMLExporter.localFile("/abs/x.png", relativeTo: base)?.path == "/abs/x.png")
        #expect(HTMLExporter.localFile("a/b%20c.png?v=2", relativeTo: base)?.path == "/docs/a/b c.png")
    }

    @MainActor
    @Test func documentExportCopiesImagesBesideThePage() async throws {
        let (dir, docs) = try setUp(); defer { dir.cleanUp() }
        let source = docs.appendingPathComponent("Doc.md")
        try bytes(markdown).write(to: source)
        let document = try openDocument(source)
        defer { document.close() }
        let target = dir.url.appendingPathComponent("Doc.html")
        let missing = try await document.exportHTML(to: target, images: .copy)
        #expect(missing == ["missing.png"])
        let folder = dir.url.appendingPathComponent("Doc_files")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.png").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("b c.jpg").path))
        let html = try String(contentsOf: target, encoding: .utf8)
        #expect(html.contains("<img src=\"Doc_files/a.png\""))
        // Exporting again overwrites the copies.
        _ = try await document.exportHTML(to: target, images: .copy)
    }
}
