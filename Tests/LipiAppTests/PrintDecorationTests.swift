import AppKit
import Foundation
import LipiCore
@testable import LipiExport
import LipiHighlight
import LipiLayout
import PDFKit
import Testing
@testable import LipiApp

private func scratchDefaults() -> UserDefaults {
    let name = "BareLipiTests.print.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func controls<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    var out: [T] = []
    for sub in view.subviews {
        if let hit = sub as? T { out.append(hit) }
        out += controls(type, in: sub)
    }
    return out
}

@Suite("Print and PDF: header, footer, images and theme")
struct PrintDecorationTests {
    static func longMarkdown(sections: Int = 12) -> String {
        var markdown = ""
        for n in 1...sections {
            markdown += "## Section \(n)\n\n" + String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 14) + "\n\n"
        }
        return markdown
    }

    /// The selection of `text` on `page`, if it is there.
    static func find(_ text: String, on page: PDFPage, in pdf: PDFDocument) -> PDFSelection? {
        pdf.findString(text, withOptions: []).first { $0.pages.first == page }
    }

    // MARK: The header and footer text

    @Test func headerAndFooterText() {
        let decoration = PageDecoration(title: "  Field\n  Notes ", pageNumbers: true, color: Theme.taalegari.colors.muted, fontFamily: "Helvetica")
        #expect(decoration.headerText == "Field Notes")
        #expect(decoration.footerText(page: 2, of: 5) == "Page 2 of 5")
        #expect(decoration.footerText(page: 3, of: 0) == "Page 3")
        let plain = PageDecoration(title: nil, pageNumbers: false, color: Theme.taalegari.colors.muted, fontFamily: "Helvetica")
        #expect(plain.headerText == nil && plain.footerText(page: 1, of: 1) == nil)
        #expect(PageDecoration(title: " ", pageNumbers: false, color: Theme.taalegari.colors.muted, fontFamily: "Helvetica").headerText == nil)
    }

    @Test func decorationFollowsTheOptionsAndTheme() throws {
        let both = try #require(PrintExport(theme: .kari).decoration(title: "Notes"))
        // Kari prints as Taalegari by default: its muted colour and body font.
        #expect(both.color == Theme.taalegari.colors.muted)
        #expect(both.fontFamily == InstalledFonts.first(of: Theme.taalegari.fonts.body) ?? both.fontFamily)
        #expect(both.headerText == "Notes" && both.pageNumbers && both.paperColor == nil)
        let footerOnly = try #require(PrintExport(theme: .bili, options: PrintOptions(header: false)).decoration(title: "Notes"))
        #expect(footerOnly.headerText == nil && footerOnly.pageNumbers)
        #expect(PrintExport(theme: .bili, options: PrintOptions(header: false, footer: false)).decoration(title: "Notes") == nil)
        // The window's dark theme fills the paper even with nothing to write.
        let dark = try #require(PrintExport(theme: .kari, options: PrintOptions(theme: .window, header: false, footer: false)).decoration(title: "Notes"))
        #expect(dark.paperColor == Theme.kari.colors.bg && dark.color == Theme.kari.colors.muted)
    }

    @Test func headerAndFooterSitInTheMargins() {
        let decoration = PageDecoration(title: "T", pageNumbers: true, color: Theme.taalegari.colors.muted, fontFamily: "Helvetica")
        let paper = CGSize(width: 612, height: 792)
        let m = PrintExport.margins
        let header = decoration.headerRect(paper: paper), footer = decoration.footerRect(paper: paper)
        #expect(header.minY > paper.height - m.top && header.maxY < paper.height)
        #expect(footer.minY > 0 && footer.maxY < m.bottom)
        #expect(header.minX == m.side && header.maxX == paper.width - m.side)
    }

    /// Stamps pages of a PDF drawn here and reads them back with PDFKit.
    @Test func stampsSelectableTextOnAGeneratedPDF() throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        let decoration = PageDecoration(title: "Stamped Title", pageNumbers: true, color: Theme.bili.colors.muted, fontFamily: "Helvetica")
        for n in 1...3 {
            context.beginPDFPage(nil)
            decoration.draw(page: n, of: 3, paper: box.size, in: context)
            context.endPDFPage()
        }
        context.closePDF()
        let pdf = try #require(PDFDocument(data: data as Data))
        #expect(pdf.pageCount == 3)
        for n in 0..<3 {
            let page = try #require(pdf.page(at: n))
            let footer = try #require(Self.find("Page \(n + 1) of 3", on: page, in: pdf))
            let header = try #require(Self.find("Stamped Title", on: page, in: pdf))
            #expect(footer.bounds(for: page).maxY < PrintExport.margins.bottom)
            #expect(header.bounds(for: page).minY > 792 - PrintExport.margins.top)
            // Centred between the side margins.
            #expect(abs(footer.bounds(for: page).midX - 306) < 2)
        }
    }

    // MARK: Pagination

    @MainActor
    @Test func everyPageGetsTheTitleAndItsNumber() async throws {
        let export = PrintExport(theme: .taalegari)
        let renderer = WebPDFRenderer()
        try await renderer.load(html: export.page(markdown: Self.longMarkdown(), title: "Long Notes", documentDirectory: nil).html)
        let data = try await renderer.pdfData(printInfo: PDFExportTests.letter(), title: "Long Notes",
                                              decoration: export.decoration(title: "Long Notes"))
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount >= 3)
        for n in 0..<pdf.pageCount {
            let page = try #require(pdf.page(at: n))
            let footer = try #require(Self.find("Page \(n + 1) of \(pdf.pageCount)", on: page, in: pdf))
            let header = try #require(Self.find("Long Notes", on: page, in: pdf))
            #expect(footer.bounds(for: page).maxY < PrintExport.margins.bottom)
            #expect(header.bounds(for: page).minY > 792 - PrintExport.margins.top)
            // Muted, not the body's ink.
            let colour = footer.attributedString?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            if let rgb = colour?.usingColorSpace(.sRGB) {
                #expect(abs(rgb.redComponent - Theme.taalegari.colors.muted.red) < 0.02)
            }
        }
        // The body text is still there and still first on the page.
        #expect(pdf.page(at: 0)?.string?.contains("Section 1") == true)
    }

    @MainActor
    @Test func headerAndFooterCanBeTurnedOff() async throws {
        let export = PrintExport(theme: .taalegari, options: PrintOptions(header: false, footer: false))
        let renderer = WebPDFRenderer()
        try await renderer.load(html: export.page(markdown: Self.longMarkdown(sections: 4), title: "Quiet", documentDirectory: nil).html)
        let data = try await renderer.pdfData(printInfo: PDFExportTests.letter(), title: "Quiet", decoration: export.decoration(title: "Quiet"))
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.string?.contains("Page 1") == false)
        #expect(pdf.string?.contains("Quiet") == false)
    }

    @MainActor
    @Test func windowThemePrintsDarkPaperWithTheTextOnTop() async throws {
        let export = PrintExport(theme: .kari, options: PrintOptions(theme: .window))
        let html = export.page(markdown: Self.longMarkdown(sections: 2), title: "Dark", documentDirectory: nil).html
        #expect(html.contains("--lipi-bg: \(Theme.kari.colors.bg.hexString);"))
        #expect(html.contains("background: transparent;"))
        let renderer = WebPDFRenderer()
        try await renderer.load(html: html)
        let data = try await renderer.pdfData(printInfo: PDFExportTests.letter(), title: "Dark", decoration: export.decoration(title: "Dark"))
        let pdf = try #require(PDFDocument(data: data))
        let page = try #require(pdf.page(at: 0))
        let image = page.thumbnail(of: NSSize(width: 306, height: 396), for: .mediaBox)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        // Sampled in points of the page, top left origin, whatever the bitmap's scale.
        func brightness(_ x: Double, _ y: Double) -> CGFloat {
            let sx = Double(bitmap.pixelsWide) / 612, sy = Double(bitmap.pixelsHigh) / 792
            return bitmap.colorAt(x: Int(x * sx), y: Int(y * sy))?.usingColorSpace(.sRGB)?.brightnessComponent ?? 1
        }
        // Corners, margins and the top of the text area (which WebKit leaves unpainted) are the theme's background…
        for (x, y) in [(4.0, 4.0), (608, 4), (4, 788), (608, 788), (100, 24), (20, 400), (590, 400), (300, 64)] { #expect(brightness(x, y) < 0.2, "\(x), \(y)") }
        // …and the light text is drawn over it.
        var light = 0
        for x in stride(from: 60.0, to: 550, by: 3) { for y in stride(from: 80.0, to: 280, by: 3) where brightness(x, y) > 0.6 { light += 1 } }
        #expect(light > 50)
    }

    // MARK: Images

    @Test func imagesCanBeLeftOutForTheirAltText() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        try PDFExportTests.png().write(to: dir.file("dot.png"))
        let markdown = "Before ![A red dot](dot.png) and ![](gone.png) after.\n"
        let page = PrintExport(theme: .taalegari, options: PrintOptions(images: .omit), highlighter: nil)
            .page(markdown: markdown, title: "T", documentDirectory: dir.url)
        #expect(!page.html.contains("<img"))
        #expect(page.html.contains("Before <span class=\"image-alt\">A red dot</span> and  after."))
        #expect(page.missingImages.isEmpty)
        let embedded = PrintExport(theme: .taalegari, highlighter: nil).page(markdown: markdown, title: "T", documentDirectory: dir.url)
        #expect(embedded.html.contains("<img src=\"data:image/png;base64,"))
        #expect(embedded.missingImages == ["gone.png"])
    }

    @Test func altTextReplacementKeepsEscapes() {
        #expect(PrintExport.replacingImagesWithAltText(#"<p><img src="a.png" alt="a &amp; &quot;b&quot;" title="t" /></p>"#)
            == #"<p><span class="image-alt">a &amp; &quot;b&quot;</span></p>"#)
        #expect(PrintExport.replacingImagesWithAltText("<p>No images</p>") == "<p>No images</p>")
    }

    @Test func optionalSyntaxReachesThePrintPage() {
        let page = PrintExport(theme: .taalegari, syntax: [.highlight], highlighter: nil)
            .page(markdown: "Some ==marked== text\n", title: "T", documentDirectory: nil)
        #expect(page.html.contains("<mark>marked</mark>"))
    }

    // MARK: Settings and the save panel

    @MainActor
    @Test func settingsDefaultAndRoundTrip() {
        let s = AppSettings(defaults: scratchDefaults())
        #expect(s.printOptions == PrintOptions())
        #expect(s.pdfImages == .embed && s.pdfTheme == .light && s.pdfHeader && s.pdfFooter)
        s.pdfImages = .omit
        s.pdfTheme = .window
        s.pdfHeader = false
        #expect(s.printOptions == PrintOptions(images: .omit, theme: .window, header: false, footer: true))
        s.printOptions = PrintOptions(images: .embed, theme: .light, header: true, footer: false)
        let again = AppSettings(defaults: s.defaults)
        #expect(again.pdfImages == .embed && again.pdfTheme == .light && again.pdfHeader && !again.pdfFooter)
        #expect(s.defaults.string(forKey: "export.pdf.theme") == "light")
    }

    @MainActor
    @Test func printPaneWritesThrough() throws {
        let s = AppSettings(defaults: scratchDefaults())
        s.pdfTheme = .window
        let pane = PrintSettingsPane(settings: s)
        let theme = try #require(controls(NSPopUpButton.self, in: pane.view).first { $0.itemTitles.contains(PrintThemeMode.light.title) })
        #expect(theme.titleOfSelectedItem == PrintThemeMode.window.title)
        theme.selectItem(withTitle: PrintThemeMode.light.title)
        _ = theme.target?.perform(theme.action, with: theme)
        #expect(s.pdfTheme == .light)
        let images = try #require(controls(NSPopUpButton.self, in: pane.view).first { $0.itemTitles.contains(PrintImageMode.omit.title) })
        images.selectItem(withTitle: PrintImageMode.omit.title)
        _ = images.target?.perform(images.action, with: images)
        #expect(s.pdfImages == .omit)
        let footer = try #require(controls(NSButton.self, in: pane.view).first { $0.title.contains("Page numbers") })
        #expect(footer.state == .on)
        footer.performClick(nil)
        #expect(!s.pdfFooter && s.pdfHeader)
    }

    @MainActor
    @Test func pdfPanelAccessoryShowsAndReadsTheOptions() {
        let options = PrintOptions(images: .omit, theme: .window, header: false, footer: true)
        let accessory = LipiDocument.pdfExportAccessory(options)
        #expect(accessory.images.titleOfSelectedItem == PrintImageMode.omit.title)
        #expect(accessory.theme.titleOfSelectedItem == PrintThemeMode.window.title)
        #expect(accessory.header.state == .off && accessory.footer.state == .on)
        #expect(LipiDocument.printOptions(from: accessory) == options)
        accessory.theme.selectItem(withTitle: PrintThemeMode.light.title)
        accessory.header.state = .on
        #expect(LipiDocument.printOptions(from: accessory) == PrintOptions(images: .omit, theme: .light, header: true, footer: true))
    }

    @MainActor
    @Test func documentExportUsesTheGivenOptions() async throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let source = dir.file("Paged Notes.md")
        try bytes(Self.longMarkdown(sections: 6) + "![a dot](dot.png)\n").write(to: source)
        let document = try openDocument(source)
        defer { document.close() }
        let plain = dir.file("plain.pdf")
        let missing = try await document.exportPDF(to: plain, options: PrintOptions(images: .omit, header: false, footer: false))
        #expect(missing.isEmpty, "left-out images are not missing")
        let plainPDF = try #require(PDFDocument(url: plain))
        #expect(plainPDF.string?.contains("Page 1 of") == false)
        #expect(plainPDF.string?.contains("a dot") == true)
        let paged = dir.file("paged.pdf")
        #expect(try await document.exportPDF(to: paged, options: PrintOptions()) == ["dot.png"])
        let pagedPDF = try #require(PDFDocument(url: paged))
        let last = try #require(pagedPDF.page(at: pagedPDF.pageCount - 1))
        #expect(last.string?.contains("Page \(pagedPDF.pageCount) of \(pagedPDF.pageCount)") == true)
        #expect(last.string?.contains("Paged Notes") == true)
        // The outline still finds the headings, not the running header.
        #expect(pagedPDF.outlineRoot?.numberOfChildren == 6)
    }
}
