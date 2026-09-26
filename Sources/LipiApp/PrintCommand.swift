import AppKit
import LipiExport
import PDFKit
import UniformTypeIdentifiers

/// File › Print… (Cmd-Opt-P; Cmd-P in the Typora preset) and File › Export ›
/// PDF… (P0-14, Phase 2). Both paginate the HTML export's page with WebKit
/// (`WebPDFRenderer`) per the Print settings (`PrintOptions`: images, theme,
/// running header and footer); the page is built off the main thread, and
/// the PDF's outline and its write through `AtomicWriter` happen off it too.
extension LipiDocument {
    /// The print page and its header and footer, built on a background task
    /// from the main-thread snapshot.
    func printPage(options: PrintOptions) async
        -> (html: String, title: String, decoration: PageDecoration?, headings: [PDFOutliner.Heading], missingImages: [String]) {
        let snapshot = exportSnapshot()
        let directory = fileURL?.deletingLastPathComponent()
        return await Task.detached(priority: .userInitiated) {
            let export = PrintExport(theme: snapshot.theme, options: options, syntax: snapshot.syntax)
            let page = export.page(markdown: snapshot.markdown, title: snapshot.title, documentDirectory: directory)
            return (page.html, snapshot.title, export.decoration(title: snapshot.title),
                    PrintExport.headings(markdown: snapshot.markdown), page.missingImages)
        }.value
    }

    /// The Print and PDF choices in Settings → Print.
    static var printOptionsSetting: PrintOptions {
        get { AppSettings().printOptions }
        set { AppSettings().printOptions = newValue }
    }

    /// The PDF panel's accessory: images and theme, as HTML export's, and
    /// the running header and footer.
    static func pdfExportAccessory(_ options: PrintOptions = printOptionsSetting)
        -> (view: NSView, images: NSPopUpButton, theme: NSPopUpButton, header: NSButton, footer: NSButton) {
        let images = accessoryPopup(PrintImageMode.allCases.map { ($0.title, $0.rawValue) },
                                    selected: PrintImageMode.allCases.firstIndex(of: options.images) ?? 0, label: "Images")
        let theme = accessoryPopup(PrintThemeMode.allCases.map { ($0.title, $0.rawValue) },
                                   selected: PrintThemeMode.allCases.firstIndex(of: options.theme) ?? 0, label: "Theme")
        let header = NSButton(checkboxWithTitle: "Title at the top", target: nil, action: nil)
        header.state = options.header ? .on : .off
        let footer = NSButton(checkboxWithTitle: "Page numbers", target: nil, action: nil)
        footer.state = options.footer ? .on : .off
        let choices = NSStackView(views: [NSTextField(labelWithString: "Images:"), images,
                                          NSTextField(labelWithString: "Theme:"), theme])
        choices.orientation = .horizontal
        choices.setCustomSpacing(16, after: images)
        let pages = NSStackView(views: [header, footer])
        pages.orientation = .horizontal
        pages.spacing = 16
        let stack = NSStackView(views: [choices, pages])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        return (stack, images, theme, header, footer)
    }

    /// The options an accessory from `pdfExportAccessory()` shows.
    static func printOptions(from accessory: (view: NSView, images: NSPopUpButton, theme: NSPopUpButton, header: NSButton, footer: NSButton))
        -> PrintOptions {
        PrintOptions(images: (accessory.images.selectedItem?.representedObject as? String).flatMap(PrintImageMode.init(rawValue:)) ?? .embed,
                     theme: (accessory.theme.selectedItem?.representedObject as? String).flatMap(PrintThemeMode.init(rawValue:)) ?? .light,
                     header: accessory.header.state == .on, footer: accessory.footer.state == .on)
    }

    @objc public func printMarkdown(_ sender: Any?) {
        Task { await runPrint() }
    }

    private func runPrint() async {
        let page = await printPage(options: Self.printOptionsSetting)
        let renderer = WebPDFRenderer()
        do {
            try await renderer.load(html: page.html)
        } catch {
            presentError(error)
            return
        }
        let operation = renderer.printOperation(printInfo: printInfo, title: page.title, decoration: page.decoration)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsScaling, .showsPreview])
        _ = await renderer.run(operation, sheetOn: windowController?.window)
    }

    @objc public func exportPDF(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = exportTitle + ".pdf"
        if let directory = fileURL?.deletingLastPathComponent() { panel.directoryURL = directory }
        let accessory = Self.pdfExportAccessory()
        panel.accessoryView = accessory.view
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let options = Self.printOptions(from: accessory)
            Self.printOptionsSetting = options
            Task { await self.exportPDFAndReport(to: url, options: options) }
        }
        if let window = windowController?.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func exportPDFAndReport(to url: URL, options: PrintOptions) async {
        do {
            let missing = try await exportPDF(to: url, options: options)
            guard !missing.isEmpty else { return }
            let alert = NSAlert()
            alert.messageText = missing.count == 1 ? "1 image was not found" : "\(missing.count) images were not found"
            alert.informativeText = "The PDF leaves them out:\n" + missing.prefix(12).joined(separator: "\n")
                + (missing.count > 12 ? "\n…" : "")
            if let window = windowController?.window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
        } catch {
            presentError(error)
        }
    }

    /// Paginates the current text on the document's paper and writes the
    /// PDF, with a heading outline, to `url`; `options` defaults to the
    /// Print settings. Returns the image sources that were not found.
    @discardableResult
    public func exportPDF(to url: URL, options: PrintOptions? = nil) async throws -> [String] {
        let page = await printPage(options: options ?? Self.printOptionsSetting)
        let renderer = WebPDFRenderer()
        try await renderer.load(html: page.html)
        let pages = try await renderer.pdfData(printInfo: printInfo, title: page.title, decoration: page.decoration)
        try await Task.detached(priority: .userInitiated) {
            _ = try AtomicWriter().write(Self.finishedPDF(pages, title: page.title, headings: page.headings), to: url)
        }.value
        return page.missingImages
    }

    /// `pages` with the heading outline and the title and creator set.
    nonisolated static func finishedPDF(_ pages: Data, title: String, headings: [PDFOutliner.Heading]) -> Data {
        guard let document = PDFDocument(data: pages) else { return pages }
        PDFOutliner.addOutline(to: document, headings: headings)
        var attributes = document.documentAttributes ?? [:]
        attributes[PDFDocumentAttribute.titleAttribute] = title
        attributes[PDFDocumentAttribute.creatorAttribute] = "BareLipi"
        document.documentAttributes = attributes
        return document.dataRepresentation() ?? pages
    }
}
