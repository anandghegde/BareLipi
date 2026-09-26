import AppKit
import Foundation
import LipiCore
@testable import LipiExport
import LipiHighlight
import LipiLayout
import PDFKit
import Testing
@testable import LipiApp

@Suite("Print and PDF export (P0-14 Phase 2)")
struct PDFExportTests {
    let sample = """
        # Field Notes

        Some *emphasis* and `inline code`.

        ## Code

        ```swift
        let greeting = "hello"
        ```

        | Name | Value |
        |------|-------|
        | alpha | 1 |

        ![dot](dot.png)

        ## Notes

        A claim.[^1]

        [^1]: The footnote text.

        """

    /// Letter paper, as a fresh print info on a US system.
    static func letter() -> NSPrintInfo {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792)
        info.orientation = .portrait
        return info
    }

    /// A 24 × 24 red PNG.
    static func png() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 24, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<24 { for y in 0..<24 { rep.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y) } }
        return rep.representation(using: .png, properties: [:])!
    }

    /// Image XObjects drawn on `page`, looking inside form XObjects.
    static func imageCount(_ page: PDFPage) -> Int {
        guard let ref = page.pageRef, let dictionary = ref.dictionary else { return 0 }
        func count(in resources: CGPDFDictionaryRef?, depth: Int) -> Int {
            var xobjects: CGPDFDictionaryRef?
            guard depth < 6, let resources, CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return 0 }
            var total = 0
            var refs: [CGPDFStreamRef] = []
            CGPDFDictionaryApplyBlock(xobjects, { _, object, _ in
                var stream: CGPDFStreamRef?
                if CGPDFObjectGetValue(object, .stream, &stream), let stream { refs.append(stream) }
                return true
            }, nil)
            for stream in refs {
                guard let dict = CGPDFStreamGetDictionary(stream) else { continue }
                var subtype: UnsafePointer<CChar>?
                guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype else { continue }
                switch String(cString: subtype) {
                case "Image": total += 1
                case "Form":
                    var inner: CGPDFDictionaryRef?
                    if CGPDFDictionaryGetDictionary(dict, "Resources", &inner) { total += count(in: inner, depth: depth + 1) }
                default: break
                }
            }
            return total
        }
        var resources: CGPDFDictionaryRef?
        _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
        return count(in: resources, depth: 0)
    }

    // MARK: The page

    @Test func darkThemesPrintInTheirLightPair() {
        #expect(PrintExport.printTheme(for: .kari).name == "Taalegari")
        #expect(PrintExport.printTheme(for: .neeli).name == "Bili")
        #expect(PrintExport.printTheme(for: .bili).name == "Bili")
        #expect(!PrintExport.printTheme(for: Theme.kari.highContrast).isDark)
        #expect(!PrintExport.printTheme(for: Theme.taalegari.highContrast).isHighContrast)
    }

    @Test func pageCarriesPrintRulesAndEmbeddedImages() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        try Self.png().write(to: dir.file("dot.png"))
        let page = PrintExport(theme: .kari, highlighter: HighlightService(capacity: 8))
            .page(markdown: sample + "![gone](gone.png)\n", title: "Field Notes", documentDirectory: dir.url)
        #expect(page.html.contains("@page { margin: 54pt 54pt 60pt; }"))
        #expect(page.html.contains("--lipi-bg: \(Theme.taalegari.colors.bg.hexString);"))
        // The print rules come after the theme's so they win.
        let theme = try #require(page.html.range(of: "--lipi-bg"))
        let rules = try #require(page.html.range(of: "@page"))
        #expect(theme.lowerBound < rules.lowerBound && rules.upperBound < page.html.range(of: "</head>")!.lowerBound)
        #expect(page.html.contains("<img src=\"data:image/png;base64,"))
        #expect(page.html.contains("<span class=\"tok-keyword\">let</span>"))
        #expect(page.missingImages == ["gone.png"])
    }

    @Test func headingsForTheOutline() {
        #expect(PrintExport.headings(markdown: sample) == [
            .init(level: 1, title: "Field Notes"), .init(level: 2, title: "Code"), .init(level: 2, title: "Notes"),
        ])
    }

    // MARK: Pagination

    @MainActor
    @Test func rendersSelectableTextImagesAndFootnotes() async throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        try Self.png().write(to: dir.file("dot.png"))
        let page = PrintExport(theme: .taalegari).page(markdown: sample, title: "Field Notes", documentDirectory: dir.url)
        let renderer = WebPDFRenderer()
        try await renderer.load(html: page.html)
        let data = try await renderer.pdfData(printInfo: Self.letter(), title: "Field Notes")
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount == 1)
        let text = try #require(pdf.string)
        for expected in ["Field Notes", "inline code", "let greeting = \"hello\"", "alpha", "The footnote text."] {
            #expect(text.contains(expected), "\(expected)")
        }
        let first = try #require(pdf.page(at: 0))
        #expect(first.bounds(for: .mediaBox).size == CGSize(width: 612, height: 792))
        #expect(Self.imageCount(first) >= 1)
        // Real margins: no text within 40 pt of the left or top edge.
        let selection = try #require(first.selection(for: first.bounds(for: .mediaBox)))
        let box = selection.bounds(for: first)
        #expect(box.minX >= 40 && box.maxY <= 792 - 40)
    }

    @MainActor
    @Test func longDocumentPaginatesAndGetsAnOutline() async throws {
        var markdown = ""
        for n in 1...40 {
            markdown += "## Section \(n)\n\n" + String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 12) + "\n\n"
            if n % 10 == 0 { markdown += "```python\n" + (1...30).map { "print(\($0))" }.joined(separator: "\n") + "\n```\n\n" }
        }
        let renderer = WebPDFRenderer()
        try await renderer.load(html: PrintExport(theme: .taalegari).page(markdown: markdown, title: "Long", documentDirectory: nil).html)
        let pages = try await renderer.pdfData(printInfo: Self.letter(), title: "Long")
        let finished = LipiDocument.finishedPDF(pages, title: "Long", headings: PrintExport.headings(markdown: markdown))
        let pdf = try #require(PDFDocument(data: finished))
        #expect(pdf.pageCount > 5)
        let root = try #require(pdf.outlineRoot)
        #expect(root.numberOfChildren == 40)
        #expect(root.child(at: 0)?.label == "Section 1")
        // Each entry points at the page its heading is on, in order.
        var previous = -1
        for n in 0..<40 {
            let page = try #require(root.child(at: n)?.destination?.page)
            #expect(page.string?.contains("Section \(n + 1)") == true)
            #expect(pdf.index(for: page) >= previous)
            previous = pdf.index(for: page)
        }
        #expect(pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Long")
    }

    @MainActor
    @Test func outlineNestsByLevel() throws {
        // A PDF with the headings as plain text, drawn by PDFKit's own view.
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        text.string = "Intro\nIntro text\nSetup\nDetails\nUsage\n"
        let data = text.dataWithPDF(inside: text.bounds)
        let pdf = try #require(PDFDocument(data: data))
        let placed = PDFOutliner.addOutline(to: pdf, headings: [
            .init(level: 1, title: "Intro"), .init(level: 2, title: "Setup"), .init(level: 3, title: "Details"),
            .init(level: 1, title: "Usage"), .init(level: 2, title: "Missing"),
        ])
        #expect(placed == 4)
        let root = try #require(pdf.outlineRoot)
        #expect(root.numberOfChildren == 2)
        #expect(root.child(at: 0)?.child(at: 0)?.child(at: 0)?.label == "Details")
        #expect(root.child(at: 1)?.label == "Usage" && root.child(at: 1)?.numberOfChildren == 0)
    }

    // MARK: The document commands

    @MainActor
    @Test func documentExportWritesAPDF() async throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        try Self.png().write(to: dir.file("dot.png"))
        let source = dir.file("Field Notes.md")
        try bytes(sample).write(to: source)
        let document = try openDocument(source)
        defer { document.close() }
        document.windowController!.controller.setTheme(.kari)
        let target = dir.file("Field Notes.pdf")
        let missing = try await document.exportPDF(to: target)
        #expect(missing.isEmpty)
        let pdf = try #require(PDFDocument(url: target))
        #expect(pdf.pageCount >= 1)
        #expect(pdf.string?.contains("The footnote text.") == true)
        #expect(pdf.outlineRoot?.child(at: 0)?.label == "Field Notes")
        #expect(pdf.outlineRoot?.child(at: 0)?.numberOfChildren == 2)
        #expect(!document.isDocumentEdited)
    }

    @MainActor
    @Test func fileMenuOffersPrintAndPDF() throws {
        _ = NSApplication.shared
        let menu = MainMenu.build()
        let file = try #require(menu.item(withTitle: "File")?.submenu)
        let print = try #require(file.item(withTitle: "Print…"))
        #expect(print.action == #selector(LipiDocument.printMarkdown(_:)))
        #expect(print.keyEquivalent == "p")
        #expect(print.keyEquivalentModifierMask == [.command, .option])
        let export = try #require(file.item(withTitle: "Export")?.submenu)
        #expect(export.item(withTitle: "PDF…")?.action == #selector(LipiDocument.exportPDF(_:)))
    }

    @MainActor
    @Test func printBindingsHaveNoConflicts() {
        let bareLipi = CommandRegistry(commands: CommandRegistry.standardCommands())
        #expect(bareLipi.keys(for: "file.print") == [KeyChord("p", [.command, .option])])
        #expect(bareLipi.keys(for: "file.quickOpen") == [KeyChord("p", .command)])
        #expect(!bareLipi.conflictingIDs.contains("file.print"))
        let typora = CommandRegistry(commands: CommandRegistry.standardCommands(), keymap: Keymap(preset: "Typora"))
        #expect(typora.keys(for: "file.print") == [KeyChord("p", .command)])
        #expect(typora.conflicts.isEmpty)
        #expect(CommandPalette.items(registry: bareLipi, enabled: nil, documents: true).contains { $0.keywords == "file.print" })
    }
}
