import AppKit
import LipiExport
import PDFKit
import UniformTypeIdentifiers

/// File › Print… (Cmd-Opt-P; Cmd-P in the Typora preset) and File › Export ›
/// PDF… (P0-14, Phase 2). Both paginate the HTML export's page in the
/// theme's light counterpart with WebKit (`WebPDFRenderer`); the page is
/// built off the main thread, and the PDF's outline and its write through
/// `AtomicWriter` happen off it too.
extension LipiDocument {
    /// The print page, built on a background task from the main-thread snapshot.
    func printPage() async -> (html: String, title: String, headings: [PDFOutliner.Heading], missingImages: [String]) {
        let snapshot = exportSnapshot()
        let directory = fileURL?.deletingLastPathComponent()
        return await Task.detached(priority: .userInitiated) {
            let page = PrintExport(theme: snapshot.theme).page(markdown: snapshot.markdown, title: snapshot.title, documentDirectory: directory)
            return (page.html, snapshot.title, PrintExport.headings(markdown: snapshot.markdown), page.missingImages)
        }.value
    }

    @objc public func printMarkdown(_ sender: Any?) {
        Task { await runPrint() }
    }

    private func runPrint() async {
        let page = await printPage()
        let renderer = WebPDFRenderer()
        do {
            try await renderer.load(html: page.html)
        } catch {
            presentError(error)
            return
        }
        let operation = renderer.printOperation(printInfo: printInfo, title: page.title)
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
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { await self.exportPDFAndReport(to: url) }
        }
        if let window = windowController?.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func exportPDFAndReport(to url: URL) async {
        do {
            let missing = try await exportPDF(to: url)
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
    /// PDF, with a heading outline, to `url`. Returns the image sources
    /// that were not found.
    @discardableResult
    public func exportPDF(to url: URL) async throws -> [String] {
        let page = await printPage()
        let renderer = WebPDFRenderer()
        try await renderer.load(html: page.html)
        let pages = try await renderer.pdfData(printInfo: printInfo, title: page.title)
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
