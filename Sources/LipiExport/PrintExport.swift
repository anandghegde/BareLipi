import AppKit
import LipiCore
import LipiHighlight
import LipiLayout
import PDFKit

/// Print and PDF export (P0-14, Phase 2): the HTML export's page in a
/// light theme with print rules added (page margins, no clipped code or
/// tables, headings kept with what follows), paginated by WebKit
/// (`WebPDFRenderer`). The PDF export then gets an outline built from the
/// document's headings (`PDFOutliner`).
public struct PrintExport: Sendable {
    /// Page margins in points: top, sides, bottom (a little more at the
    /// foot, where the eye expects it).
    public static let margins = (top: 54.0, side: 54.0, bottom: 60.0)

    public var theme: Theme
    public var exporter: HTMLExporter

    /// `theme` is the window's theme; paper gets its light counterpart
    /// (Kari prints as Taalegari, Neeli as Bili) without Increase Contrast.
    public init(theme: Theme, highlighter: HighlightService? = .shared) {
        self.theme = PrintExport.printTheme(for: theme)
        exporter = HTMLExporter(theme: self.theme, highlighter: highlighter)
    }

    /// The light theme `theme` prints in.
    public static func printTheme(for theme: Theme) -> Theme {
        let standard = theme.standard
        return standard.isDark ? standard.pair.standard : standard
    }

    /// The page to paginate, images embedded (the web view is given no file
    /// access), and the image sources that were not found.
    public func page(markdown: String, title: String, documentDirectory: URL?) -> (html: String, missingImages: [String]) {
        // Embedding never writes beside `outputURL`; it only has to be a file URL.
        let images = ImageExport(mode: .embed, documentDirectory: documentDirectory,
                                 outputURL: (documentDirectory ?? URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathComponent("print.html"))
        let result = exporter.export(markdown: markdown, title: title, images: images)
        return (PrintExport.addingPrintStyle(to: result.html), result.missingImages)
    }

    /// The document's headings, in order, for the PDF outline.
    public static func headings(markdown: String) -> [PDFOutliner.Heading] {
        var parser = LipiParser(options: .editor)
        parser.parse(markdown)
        return TableOfContents(index: parser.index).items.map { PDFOutliner.Heading(level: $0.level, title: $0.title) }
    }

    /// Rules for paper, after the theme's so they win.
    public static var printCSS: String {
        let m = margins
        return """
        @page { margin: \(Int(m.top))pt \(Int(m.side))pt \(Int(m.bottom))pt; }
        html, body { background: #fff; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
        body { font-size: 11pt; line-height: 1.5; }
        .lipi-document { max-width: none; margin: 0; padding: 0; }
        h1, h2, h3, h4, h5, h6 { break-after: avoid; page-break-after: avoid; break-inside: avoid; }
        h1:first-child, h2:first-child, h3:first-child { margin-top: 0; }
        p, li, blockquote { orphans: 3; widows: 3; }
        pre { white-space: pre-wrap; overflow-wrap: anywhere; overflow: visible; }
        table { display: table; overflow: visible; max-width: 100%; }
        thead { display: table-header-group; }
        tr, img, figure, .math.display { break-inside: avoid; page-break-inside: avoid; }
        img { max-width: 100%; height: auto; }
        a { text-decoration: none; }
        .footnote-backref { display: none; }
        """
    }

    /// `html` with `printCSS` in a second `<style>` at the end of `<head>`.
    static func addingPrintStyle(to html: String) -> String {
        let style = "<style media=\"print\">\n\(printCSS)\n</style>\n"
        guard let head = html.range(of: "</head>") else { return style + html }
        var out = html
        out.insert(contentsOf: style, at: head.lowerBound)
        return out
    }
}

/// Adds a heading outline (bookmarks) to a PDF: each heading's text is
/// found in page order and linked to the top of its line, nested by level.
public enum PDFOutliner {
    public struct Heading: Sendable, Hashable {
        public var level: Int
        public var title: String
        public init(level: Int, title: String) {
            self.level = level
            self.title = title
        }
    }

    /// Sets `document`'s outline from `headings`; headings whose text is not
    /// found (an image-only heading) are left out. Returns how many were placed.
    @discardableResult
    public static func addOutline(to document: PDFDocument, headings: [Heading]) -> Int {
        let root = PDFOutline()
        var stack: [(level: Int, item: PDFOutline)] = []
        var after: PDFSelection?
        var placed = 0
        for heading in headings {
            let title = heading.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !title.isEmpty, let found = find(title, in: document, after: after),
                  let page = found.pages.first else { continue }
            after = found
            let bounds = found.bounds(for: page)
            let item = PDFOutline()
            item.label = title
            item.destination = PDFDestination(page: page, at: CGPoint(x: bounds.minX, y: min(bounds.maxY + 6, page.bounds(for: .mediaBox).maxY)))
            while let last = stack.last, last.level >= heading.level { stack.removeLast() }
            let parent = stack.last?.item ?? root
            parent.insertChild(item, at: parent.numberOfChildren)
            stack.append((heading.level, item))
            placed += 1
        }
        if placed > 0 { document.outlineRoot = root }
        return placed
    }

    /// The first occurrence of `title` after `after` set in a heading's type
    /// (larger or bolder than the text around it), else the first
    /// occurrence at all. A heading that wrapped is looked up by its first
    /// words, which sit on one line.
    static func find(_ title: String, in document: PDFDocument, after: PDFSelection?) -> PDFSelection? {
        var candidates = [title]
        let words = title.split(separator: " ")
        if words.count > 3 { candidates.append(words.prefix(3).joined(separator: " ")) }
        for text in candidates {
            var from = after
            var first: PDFSelection?
            for _ in 0..<64 {
                guard let match = document.findString(text, fromSelection: from, withOptions: []) else { break }
                if first == nil { first = match }
                if looksLikeHeading(match) { return match }
                from = match
            }
            if let first { return first }
        }
        return nil
    }

    /// Whether the selection's font is at least 1.1 × the page's body size or bold.
    static func looksLikeHeading(_ selection: PDFSelection) -> Bool {
        guard let text = selection.attributedString, text.length > 0,
              let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else { return false }
        if font.pointSize >= bodySize * 1.1 { return true }
        let name = font.fontName.lowercased()
        return font.fontDescriptor.symbolicTraits.contains(.bold) || name.contains("bold") || name.contains("semibold") || name.contains("black")
    }

    /// The theme's 16 px body text prints at 12 pt.
    static let bodySize: CGFloat = 12
}
