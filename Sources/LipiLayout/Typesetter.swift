import AppKit
import CoreText
import LipiCore

// MARK: - Decorations

/// Things drawn around glyphs rather than by Core Text: the view paints them
/// from the rects `CellLayout` computes.
public enum DecorationKind: Sendable, Hashable {
    case strikethrough
    case codePill
    case chip
    case link
    case marked
}

public struct Decoration: Sendable, Hashable {
    public var range: Range<Int>
    public var kind: DecorationKind
    public init(range: Range<Int>, kind: DecorationKind) {
        self.range = range
        self.kind = kind
    }
}

/// Attributed text for one display cell with the paragraph metrics the
/// layout needs. Attributes carry both the Core Text and the AppKit keys so
/// the same string feeds `CTTypesetter` and `NSTextLayoutManager`.
public struct TypesetCell {
    public let attributed: NSAttributedString
    public let role: TextRole
    public let style: TextStyle
    /// Fixed line height after the Tall class (§8.3).
    public let lineHeight: CGFloat
    public let lineHeightClass: LineHeightClass
    public let decorations: [Decoration]
    public let alignment: ColumnAlignment
    public let isRightToLeft: Bool
    /// Hash of everything above; equal keys mean an identical layout at the
    /// same width, which the table layout uses to reuse cells.
    public let key: UInt64

    public var length: Int { attributed.length }
}

// MARK: - Attribute keys

extension NSAttributedString.Key {
    /// `CTFont` (toll-free `NSFont`): the same string as `kCTFontAttributeName`.
    public static let ctForeground = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
    public static let ctLanguage = NSAttributedString.Key(kCTLanguageAttributeName as String)
    public static let ctRunDelegate = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
    /// Marks a run as a chip so the renderer can draw its pill.
    public static let lipiChip = NSAttributedString.Key("lipi.chip")
}

// MARK: - Typesetter

/// Builds `TypesetCell`s from display blocks (§8.2 roles, §8.3 cascade).
public struct Typesetter {
    public let scale: TypeScale
    public let cascade: FontCascade

    public init(scale: TypeScale, cascade: FontCascade) {
        self.scale = scale
        self.cascade = cascade
    }

    public var colors: ThemeColors { scale.theme.colors }

    /// The §8.2 role of a cell.
    public func role(of block: DisplayBlock, cellIndex: Int) -> TextRole {
        switch block.role {
        case .paragraph:
            if block.context.footnoteLabel != nil { return .footnote }
            if block.context.quoteDepth > 0 { return .blockQuote }
            return .body
        case .heading(let level):
            return .heading(min(max(level, 1), 6))
        case .code, .html:
            return .codeBlock
        case .thematicBreak:
            return .body
        case .table:
            if let table = block.table, table.position(ofCell: cellIndex).row == 0 { return .tableHeader }
            return .tableCell
        case .frontMatter:
            return .frontMatter
        case .linkReferenceDefinition:
            return .footnote
        }
    }

    public func typeset(_ cell: DisplayCell, in block: DisplayBlock, cellIndex: Int) -> TypesetCell {
        let role = self.role(of: block, cellIndex: cellIndex)
        let style = scale.style(for: role)
        let text = cell.text
        let runs = scriptRuns(of: text)
        let tall = runs.contains { $0.script.lineHeightClass == .tall }
        let lineHeight = tall ? (style.lineHeight * scale.tallRatio).rounded(.up) : style.lineHeight
        let alignment: ColumnAlignment = {
            guard let table = block.table else { return .none }
            let column = table.position(ofCell: cellIndex).column
            return column < table.alignments.count ? table.alignments[column] : .none
        }()
        let isRTL = runs.first?.script.isRightToLeft ?? false

        let result = NSMutableAttributedString(string: text)
        let length = result.length
        let whole = NSRange(location: 0, length: length)

        // Paragraph style: fixed line height, alignment, natural direction.
        // Core Text accepts NSParagraphStyle under kCTParagraphStyleAttributeName
        // (the two keys are the same string), and TextKit 2 requires it.
        let ns = NSMutableParagraphStyle()
        ns.minimumLineHeight = lineHeight
        ns.maximumLineHeight = lineHeight
        ns.lineBreakMode = .byWordWrapping
        ns.baseWritingDirection = .natural
        ns.alignment = alignment.nsAlignment
        result.addAttribute(.paragraphStyle, value: ns, range: whole)
        setColor(scale.color(style.ink), on: result, range: whole)

        var decorations: [Decoration] = []
        var hasher = FNV()
        hasher.combine(text)
        hasher.combine(role.hashValue)
        hasher.combine(Int(scale.zoom * 100))

        // Non-font attributes of the inline runs.
        for run in cell.runs where !run.range.isEmpty {
            hasher.combine(run.range.lowerBound); hasher.combine(run.range.upperBound); hasher.combine(Int(run.style.rawValue))
            let range = NSRange(location: run.range.lowerBound, length: run.range.count)
            let s = run.style
            if s.contains(.syntax) { setColor(colors.syntax, on: result, range: range) }
            if s.contains(.html) || s.contains(.math) { setColor(colors.ink2, on: result, range: range) }
            if s.contains(.link) || s.contains(.image) { setColor(colors.accent, on: result, range: range) }
            if s.contains(.code) { decorations.append(Decoration(range: run.range, kind: .codePill)) }
            if s.contains(.strikethrough) {
                decorations.append(Decoration(range: run.range, kind: .strikethrough))
                result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            if s.contains(.footnoteReference) { result.addAttribute(.superscript, value: 1, range: range) }
            if s.contains(.chip) {
                decorations.append(Decoration(range: run.range, kind: .chip))
                setColor(colors.muted, on: result, range: range)
                result.addAttribute(.lipiChip, value: true, range: range)
                let width = (style.size * 1.5).rounded()
                result.addAttribute(.ctRunDelegate, value: ChipDelegate.delegate(width: width, ascent: style.size * 0.8, descent: style.size * 0.2), range: range)
                let attachment = NSTextAttachment()
                attachment.bounds = CGRect(x: 0, y: -style.size * 0.2, width: width, height: style.size)
                result.addAttribute(.attachment, value: attachment, range: range)
            }
        }

        // Fonts: one per (style run × script run) segment.
        var boundaries = Set<Int>([0, length])
        for run in cell.runs { boundaries.insert(run.range.lowerBound); boundaries.insert(run.range.upperBound) }
        for run in runs { boundaries.insert(run.range.lowerBound); boundaries.insert(run.range.upperBound) }
        let sorted = boundaries.filter { $0 >= 0 && $0 <= length }.sorted()
        var styleCursor = 0
        var scriptCursor = 0
        for (a, b) in zip(sorted, sorted.dropFirst()) where a < b {
            while styleCursor < cell.runs.count, cell.runs[styleCursor].range.upperBound <= a { styleCursor += 1 }
            while scriptCursor < runs.count, runs[scriptCursor].range.upperBound <= a { scriptCursor += 1 }
            let inline = styleCursor < cell.runs.count && cell.runs[styleCursor].range.lowerBound <= a ? cell.runs[styleCursor].style : []
            let script = scriptCursor < runs.count && runs[scriptCursor].range.lowerBound <= a ? runs[scriptCursor].script : .latin
            let font = self.font(for: inline, script: script, style: style)
            let range = NSRange(location: a, length: b - a)
            result.addAttribute(.font, value: font, range: range)
            if let language = cascade.language, script == .han || script == .hiragana || script == .katakana || script == .hangul {
                result.addAttribute(.ctLanguage, value: language, range: range)
            }
        }

        return TypesetCell(attributed: result, role: role, style: style, lineHeight: lineHeight,
                           lineHeightClass: tall ? .tall : .standard, decorations: decorations, alignment: alignment,
                           isRightToLeft: isRTL, key: hasher.value)
    }

    /// Font for an inline style inside a role, resolved through the cascade.
    public func font(for inline: InlineStyle, script: Script, style: TextStyle) -> CTFont {
        var family = style.family
        var weight = style.weight
        var size = style.size
        let italic = inline.contains(.emphasis)
        if inline.contains(.code) || inline.contains(.math) || inline.contains(.html) {
            family = .mono
            size = (style.size * 0.9 * 2).rounded() / 2
        }
        if inline.contains(.strong) { weight = weight == .regular ? .semibold : .bold }
        if inline.contains(.footnoteReference) || inline.contains(.chip) { size = (style.size * 0.75).rounded() }
        return cascade.font(family: family, script: script, weight: weight, italic: italic, size: size)
    }

    /// Plain body text in the theme font (gutter markers, status bar).
    public func attributedString(_ text: String, role: TextRole, ink: InkToken? = nil) -> NSAttributedString {
        let style = scale.style(for: role)
        let result = NSMutableAttributedString(string: text)
        let whole = NSRange(location: 0, length: result.length)
        setColor(scale.color(ink ?? style.ink), on: result, range: whole)
        for run in scriptRuns(of: text) {
            let font = cascade.font(family: style.family, script: run.script, weight: style.weight, size: style.size)
            result.addAttribute(.font, value: font, range: NSRange(location: run.range.lowerBound, length: run.range.count))
        }
        return result
    }

    func setColor(_ color: ThemeColor, on string: NSMutableAttributedString, range: NSRange) {
        string.addAttribute(.ctForeground, value: color.cgColor, range: range)
        string.addAttribute(.foregroundColor, value: NSColor(cgColor: color.cgColor) ?? .textColor, range: range)
    }
}

extension ColumnAlignment {
    var nsAlignment: NSTextAlignment {
        switch self {
        case .none: return .natural
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }
    var ctAlignment: CTTextAlignment {
        switch self {
        case .none: return .natural
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }
}

// MARK: - Chip run delegate

/// Reserves the width of a link chip in Core Text layout.
final class ChipDelegate {
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat

    init(width: CGFloat, ascent: CGFloat, descent: CGFloat) {
        self.width = width
        self.ascent = ascent
        self.descent = descent
    }

    static func delegate(width: CGFloat, ascent: CGFloat, descent: CGFloat) -> CTRunDelegate {
        let box = ChipDelegate(width: width, ascent: ascent, descent: descent)
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateCurrentVersion,
            dealloc: { pointer in Unmanaged<ChipDelegate>.fromOpaque(pointer).release() },
            getAscent: { pointer in Unmanaged<ChipDelegate>.fromOpaque(pointer).takeUnretainedValue().ascent },
            getDescent: { pointer in Unmanaged<ChipDelegate>.fromOpaque(pointer).takeUnretainedValue().descent },
            getWidth: { pointer in Unmanaged<ChipDelegate>.fromOpaque(pointer).takeUnretainedValue().width })
        return CTRunDelegateCreate(&callbacks, Unmanaged.passRetained(box).toOpaque())!
    }
}

// MARK: - Hashing

/// FNV-1a over the pieces that determine a cell's layout.
struct FNV {
    var value: UInt64 = 0xCBF2_9CE4_8422_2325

    mutating func combine(_ byte: UInt8) {
        value ^= UInt64(byte)
        value = value &* 0x100_0000_01B3
    }

    mutating func combine(_ int: Int) {
        var v = UInt64(bitPattern: Int64(int))
        for _ in 0..<8 { combine(UInt8(truncatingIfNeeded: v)); v >>= 8 }
    }

    mutating func combine(_ string: String) {
        for b in string.utf8 { combine(b) }
        combine(UInt8(0xFF))
    }
}
