import AppKit
import LipiLayout
import ObjectiveC

/// The running header and footer of Print and PDF export (P0-14, Phase 2):
/// the document title at the head of each page and "Page N of M" at the
/// foot, centred in the `@page` margins in the theme's muted colour and
/// body font. They are drawn by the print view for each page
/// (`drawPageBorder(with:)`), so they are text in the PDF, as selectable
/// as the page's own. A page printed in the window's theme also gets that
/// theme's background edge to edge: WebKit paints backgrounds only inside
/// the page's boxes, and the print system draws the page border before the
/// page, so the fill lies under the text.
public struct PageDecoration: Sendable, Hashable {
    /// The header; nil or empty draws none.
    public var title: String?
    /// Whether the footer carries "Page N of M".
    public var pageNumbers: Bool
    public var color: ThemeColor
    /// The font family (the theme's body family, as installed).
    public var fontFamily: String
    public var fontSize: CGFloat
    /// Fills the whole page before it is drawn; nil leaves the paper white.
    public var paperColor: ThemeColor?

    public init(title: String?, pageNumbers: Bool, color: ThemeColor, fontFamily: String, fontSize: CGFloat = 9,
                paperColor: ThemeColor? = nil) {
        self.title = title
        self.pageNumbers = pageNumbers
        self.color = color
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.paperColor = paperColor
    }

    /// `title` (when `header`) and page numbers (when `footer`) in `theme`'s
    /// muted colour and body font, on paper in its background when
    /// `fillsPaper`; nil when there is nothing to draw.
    public init?(theme: Theme, title: String, header: Bool, footer: Bool, fillsPaper: Bool = false) {
        guard header || footer || fillsPaper else { return nil }
        let family = InstalledFonts.first(of: theme.fonts.body) ?? NSFont.systemFont(ofSize: 9).familyName ?? "Helvetica"
        self.init(title: header ? title : nil, pageNumbers: footer, color: theme.colors.muted, fontFamily: family,
                  paperColor: fillsPaper ? theme.colors.bg : nil)
    }

    /// The header line: the title with runs of white space collapsed.
    public var headerText: String? {
        guard let title else { return nil }
        let text = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    /// The footer line for page `page` (1-based) of `count`.
    public func footerText(page: Int, of count: Int) -> String? {
        guard pageNumbers else { return nil }
        return count > 0 ? "Page \(page) of \(count)" : "Page \(page)"
    }

    /// The header's box on a page of `paper` size, in unflipped points
    /// (origin at the bottom left): between the side margins, centred in
    /// the top margin.
    public func headerRect(paper: CGSize) -> CGRect {
        let m = PrintExport.margins, height = lineHeight
        return CGRect(x: m.side, y: paper.height - m.top / 2 - height / 2, width: paper.width - 2 * m.side, height: height)
    }

    /// The footer's box, centred in the bottom margin.
    public func footerRect(paper: CGSize) -> CGRect {
        let m = PrintExport.margins, height = lineHeight
        return CGRect(x: m.side, y: m.bottom / 2 - height / 2, width: paper.width - 2 * m.side, height: height)
    }

    var font: NSFont {
        let descriptor = NSFontDescriptor(fontAttributes: [.family: fontFamily])
        return NSFont(descriptor: descriptor, size: fontSize) ?? .systemFont(ofSize: fontSize)
    }

    var lineHeight: CGFloat { ceil(fontSize * 1.5) }

    func attributed(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        let c = color
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha),
            .paragraphStyle: paragraph,
        ])
    }

    /// Draws page `page` of `count`'s header and footer into `context`,
    /// whose user space is the page's in unflipped points.
    public func draw(page: Int, of count: Int, paper: CGSize, in context: CGContext) {
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        if let paperColor {
            context.setFillColor(paperColor.cgColor)
            context.fill(CGRect(origin: .zero, size: paper))
        }
        if let header = headerText {
            attributed(header).draw(with: headerRect(paper: paper), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        if let footer = footerText(page: page, of: count) {
            attributed(footer).draw(with: footerRect(paper: paper), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    /// Draws the header and footer of the page the current print operation
    /// is on. Called from the print view's `drawPageBorder(with:)`, where
    /// the context's user space is the paper's with its origin at the
    /// bottom left.
    func drawCurrentPage(borderSize: NSSize) {
        guard let operation = NSPrintOperation.current, let context = NSGraphicsContext.current?.cgContext else { return }
        let range = operation.pageRange
        let page = operation.currentPage
        let count = range.location == NSNotFound ? 0 : range.location + range.length - 1
        context.saveGState()
        defer { context.restoreGState() }
        if NSGraphicsContext.current?.isFlipped == true {
            context.translateBy(x: 0, y: borderSize.height)
            context.scaleBy(x: 1, y: -1)
        }
        draw(page: page, of: max(count, page), paper: borderSize, in: context)
    }
}

/// Makes a print view draw a `PageDecoration` on each page: the view's
/// class is replaced (for this object only) by a subclass whose
/// `drawPageBorder(with:)` calls the original and then draws the header
/// and footer. WebKit's print view is private, so it is extended at run
/// time rather than subclassed in source.
enum PrintViewDecorator {
    private final class Box: NSObject {
        let decoration: PageDecoration
        init(_ decoration: PageDecoration) { self.decoration = decoration }
    }

    nonisolated(unsafe) private static let key = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    private static let lock = NSLock()
    static let prefix = "BareLipiDecorated_"

    /// Installs `decoration` on `view`. Returns false when the view's class
    /// could not be extended (nothing is then drawn).
    @discardableResult
    static func install(_ decoration: PageDecoration, on view: NSView) -> Bool {
        guard let subclass = decoratedClass(for: object_getClass(view)) else { return false }
        object_setClass(view, subclass)
        objc_setAssociatedObject(view, key, Box(decoration), .OBJC_ASSOCIATION_RETAIN)
        return true
    }

    /// The decoration `view` draws, if any.
    static func decoration(of view: NSView) -> PageDecoration? {
        (objc_getAssociatedObject(view, key) as? Box)?.decoration
    }

    private static func decoratedClass(for original: AnyClass?) -> AnyClass? {
        guard let original else { return nil }
        let originalName = NSStringFromClass(original)
        if originalName.hasPrefix(prefix) { return original }
        lock.lock()
        defer { lock.unlock() }
        let name = prefix + originalName
        if let existing = NSClassFromString(name) { return existing }
        let selector = #selector(NSView.drawPageBorder(with:))
        guard let method = class_getInstanceMethod(original, selector),
              let made = objc_allocateClassPair(original, name, 0) else { return nil }
        typealias DrawBorder = @convention(c) (AnyObject, Selector, NSSize) -> Void
        let inherited = unsafeBitCast(method_getImplementation(method), to: DrawBorder.self)
        let block: @convention(block) (AnyObject, NSSize) -> Void = { object, size in
            inherited(object, selector, size)
            (objc_getAssociatedObject(object, key) as? Box)?.decoration.drawCurrentPage(borderSize: size)
        }
        class_addMethod(made, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        objc_registerClassPair(made)
        return made
    }
}
