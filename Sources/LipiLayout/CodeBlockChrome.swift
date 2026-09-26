import CoreGraphics
import CoreText
import Foundation
import LipiCore
import LipiHighlight

/// View options of code blocks (§6.5 header toggles, §6.2 line numbers and
/// soft wrap). They apply to every code block of an editor.
public struct CodeBlockOptions: Sendable, Hashable {
    /// Numbers in a gutter inside the block.
    public var lineNumbers: Bool
    /// Soft wrap; off, long lines run past the block and it scrolls sideways.
    public var wrap: Bool

    public init(lineNumbers: Bool = false, wrap: Bool = true) {
        self.lineNumbers = lineNumbers
        self.wrap = wrap
    }
}

/// The buttons of a fenced code block's header row.
public enum CodeHeaderButton: Sendable, Hashable, CaseIterable {
    case copy, wrap, lineNumbers

    public var title: String {
        switch self {
        case .copy: return "Copy"
        case .wrap: return "Wrap"
        case .lineNumbers: return "Lines"
        }
    }

    /// Spoken and tooltip name.
    public var help: String {
        switch self {
        case .copy: return "Copy code"
        case .wrap: return "Toggle soft wrap in code blocks"
        case .lineNumbers: return "Toggle line numbers in code blocks"
        }
    }
}

/// What a laid-out code block draws around its text: the header row that
/// stands in for the opening fence line (`CodeFenceIsland`, §6.5) and the
/// line-number gutter.
public struct CodeChrome {
    /// Height of the header row (one code line; 0 while the fence is revealed).
    public let headerHeight: CGFloat
    /// Width of the line-number gutter (0 when numbers are off).
    public let gutterWidth: CGFloat
    /// The language label (the info string's first word, or "text").
    public let language: String
    public let isFenced: Bool
    public let isUnclosed: Bool
    /// Whether lines wrap; off, the cell is as wide as its longest line.
    public let wraps: Bool
    /// Width of the code's viewport inside the block (cell width when wrapping).
    public let viewportWidth: CGFloat
    /// Cell line index of each code line's first fragment, in order: line
    /// `k` of the code is numbered `k + 1`. Fence lines are not numbered.
    public let lineStarts: [Int]

    /// Whether the header row is showing (the fence is not revealed).
    public var hasHeader: Bool { headerHeight > 0 }
}

/// Where the parts of a code header sit, in block coordinates.
public struct CodeHeaderGeometry {
    public let row: CGRect
    public let label: CTLine
    public let labelOrigin: CGPoint
    public let pill: (rect: CGRect, line: CTLine, origin: CGPoint)?
    public let buttons: [(button: CodeHeaderButton, rect: CGRect, line: CTLine, origin: CGPoint)]
}

extension LayoutEngine {
    /// Lays out a code block: the header row (fenced, not revealed), the
    /// optional line-number gutter, and the code wrapped at the block width
    /// or unwrapped.
    static func layoutCode(_ block: DisplayBlock, info: String, isFenced: Bool, typesetter: Typesetter, width: CGFloat,
                           indent: CGFloat, style: TextStyle, options: CodeBlockOptions) -> BlockLayout {
        let typesetCell = typesetter.typeset(block.cells[0], in: block, cellIndex: 0)
        let header = isFenced && !block.isRevealed ? style.lineHeight : 0
        let codeRange = typesetter.codeRange(of: block.cells[0])
        let text = block.cells[0].text.utf16
        var codeLines = 0
        if let codeRange {
            var count = 1
            var k = text.index(text.startIndex, offsetBy: codeRange.lowerBound)
            let end = text.index(text.startIndex, offsetBy: codeRange.upperBound)
            while k < end {
                if text[k] == 0x0A, text.index(after: k) < end { count += 1 }
                k = text.index(after: k)
            }
            codeLines = count
        }
        var gutter: CGFloat = 0
        if options.lineNumbers, codeLines > 0 {
            let digits = max(2, String(codeLines).count)
            gutter = (CGFloat(digits) * typesetter.digitAdvance(role: .codeBlock) + typesetter.scale.l(14)).rounded(.up)
        }
        let viewport = max(40, width - 2 * style.paddingX - gutter)
        let cell = typeset(typesetCell, width: options.wrap ? viewport : unwrappedWidth)
        // Trailing spaces count: the caret can sit after them.
        let longest = cell.lines.reduce(0) { max($0, $1.x + $1.width) }
        let cellWidth = options.wrap ? viewport : max(viewport, (longest + 2).rounded(.up))

        // The first fragment of each code line (a fragment that starts the
        // text or follows a newline, inside the code range).
        var starts: [Int] = []
        if let codeRange, codeLines > 0 {
            starts.reserveCapacity(codeLines)
            let string = cell.string
            for (i, line) in cell.lines.enumerated() {
                let lo = line.range.lowerBound
                guard lo >= codeRange.lowerBound, lo < codeRange.upperBound || (lo == codeRange.upperBound && lo == codeRange.lowerBound) else { continue }
                if lo == codeRange.lowerBound || (lo > 0 && string.character(at: lo - 1) == 0x0A) { starts.append(i) }
            }
        }
        let frame = CGRect(x: style.paddingX + gutter, y: style.paddingY + header, width: cellWidth, height: cell.height)
        let height = cell.height + 2 * style.paddingY + header
        let word = info.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "{" }).first.map(String.init) ?? ""
        let chrome = CodeChrome(headerHeight: header, gutterWidth: gutter, language: word.isEmpty ? "text" : word,
                                isFenced: isFenced, isUnclosed: block.isUnclosedFence, wraps: options.wrap,
                                viewportWidth: viewport, lineStarts: starts)
        return BlockLayout(id: block.id, layoutKey: block.layoutKey, role: block.role, style: style, context: block.context,
                           isRevealed: block.isRevealed, width: width, indent: indent, cells: [cell], cellFrames: [frame],
                           table: nil, height: height, code: chrome)
    }

    /// Line width used for unwrapped code: wide enough that only newlines break.
    static let unwrappedWidth: CGFloat = 1_000_000

    /// The header row's parts for `block` (which must have a header).
    public static func codeHeader(of block: BlockLayout, typesetter: Typesetter, options: CodeBlockOptions) -> CodeHeaderGeometry? {
        guard let chrome = block.code, chrome.hasHeader else { return nil }
        let style = block.style
        let row = CGRect(x: 0, y: style.paddingY, width: block.width, height: chrome.headerHeight)
        func line(_ text: String, ink: InkToken? = .muted, color: ThemeColor? = nil) -> (CTLine, CGFloat, CGFloat) {
            let string = NSMutableAttributedString(attributedString: typesetter.attributedString(text, role: .footnote, ink: ink))
            if let color { typesetter.setColor(color, on: string, range: NSRange(location: 0, length: string.length)) }
            let ctLine = CTLineCreateWithAttributedString(string)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let w = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
            let baseline = (row.minY + (row.height - (ascent + descent)) / 2 + ascent).rounded()
            return (ctLine, w, baseline)
        }
        let (label, labelWidth, baseline) = line(chrome.language)
        let labelOrigin = CGPoint(x: style.paddingX, y: baseline)
        var pill: (rect: CGRect, line: CTLine, origin: CGPoint)? = nil
        if chrome.isUnclosed {
            let (p, w, b) = line("unclosed", ink: nil, color: typesetter.colors.warning)
            let x = style.paddingX + labelWidth + typesetter.scale.l(10)
            let rect = CGRect(x: x - 6, y: row.minY + 2, width: w + 12, height: row.height - 4)
            pill = (rect, p, CGPoint(x: x, y: b))
        }
        var buttons: [(button: CodeHeaderButton, rect: CGRect, line: CTLine, origin: CGPoint)] = []
        var right = block.width - style.paddingX
        let gap = typesetter.scale.l(6)
        for button in CodeHeaderButton.allCases.reversed() {
            let on: Bool = {
                switch button {
                case .copy: return false
                case .wrap: return options.wrap
                case .lineNumbers: return options.lineNumbers
                }
            }()
            let (l, w, b) = line(button.title, ink: on ? nil : .muted, color: on ? typesetter.colors.accent : nil)
            let rect = CGRect(x: right - w - 12, y: row.minY + 1, width: w + 12, height: row.height - 2)
            buttons.insert((button, rect, l, CGPoint(x: rect.minX + 6, y: b)), at: 0)
            right = rect.minX - gap
        }
        return CodeHeaderGeometry(row: row, label: label, labelOrigin: labelOrigin, pill: pill, buttons: buttons)
    }
}

extension Typesetter {
    /// UTF-16 range of a cell's code (its `.code` runs).
    func codeRange(of cell: DisplayCell) -> Range<Int>? {
        guard let first = cell.runs.first(where: { $0.style.contains(.code) && !$0.range.isEmpty }),
              let last = cell.runs.last(where: { $0.style.contains(.code) && !$0.range.isEmpty }) else { return nil }
        return first.range.lowerBound..<last.range.upperBound
    }

    /// Advance of the digit zero in `role`'s font.
    func digitAdvance(role: TextRole) -> CGFloat {
        let style = scale.style(for: role)
        let font = cascade.font(family: style.family, script: .latin, size: style.size)
        var glyph: CGGlyph = 0
        var char: UniChar = 0x30
        guard CTFontGetGlyphsForCharacters(font, &char, &glyph, 1) else { return style.size * 0.6 }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        return advance.width
    }
}

extension Typesetter {
    /// A code block as HTML for the pasteboard: `<pre><code>` with the
    /// syntax colours inline, so it pastes coloured into mail and documents.
    /// Highlighting here is synchronous (a user action, not the keystroke path).
    public func codeHTML(of block: DisplayBlock) -> String? {
        guard case .code(let info, let isFenced) = block.role, let code = codeText(of: block) else { return nil }
        let word = info.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "{" }).first.map(String.init) ?? ""
        var spans: [HighlightSpan] = []
        if isFenced, let highlighter, let grammar = GrammarBundle.grammar(forInfo: info) {
            spans = highlighter.highlight(code: code, grammar: grammar).sorted { $0.range.lowerBound < $1.range.lowerBound }
        }
        let utf16 = Array(code.utf16)
        func text(_ range: Range<Int>) -> String {
            var out = ""
            for c in String(decoding: utf16[range], as: UTF16.self) {
                switch c {
                case "&": out += "&amp;"
                case "<": out += "&lt;"
                case ">": out += "&gt;"
                case "\"": out += "&quot;"
                default: out.append(c)
                }
            }
            return out
        }
        let name = word.filter { $0.isLetter || $0.isNumber || "+-#_.".contains($0) }
        let language = name.isEmpty ? "" : " class=\"language-\(name)\""
        var html = "<pre style=\"background:\(colors.codeBg.hexString);color:\(colors.ink.hexString)\"><code\(language)>"
        var cursor = 0
        for span in spans {
            let lower = max(cursor, min(span.range.lowerBound, utf16.count))
            let upper = min(span.range.upperBound, utf16.count)
            guard lower < upper else { continue }
            if cursor < lower { html += text(cursor..<lower) }
            html += "<span style=\"color:\(color(of: span.token).hexString)\">\(text(lower..<upper))</span>"
            cursor = upper
        }
        if cursor < utf16.count { html += text(cursor..<utf16.count) }
        return html + "</code></pre>"
    }
}
