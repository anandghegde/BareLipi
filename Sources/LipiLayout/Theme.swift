import CoreGraphics
import Foundation

// MARK: - Colour tokens

/// An sRGB colour as a plain value (PRD §8.1). `CGColor` is made on demand so
/// themes stay `Sendable` and hashable.
public struct ThemeColor: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `0xRRGGBB`.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, alpha: alpha)
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    public var hexString: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    /// WCAG 2.x relative luminance.
    public var relativeLuminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// WCAG contrast ratio (≥ 1) between this colour and `other`.
    public func contrastRatio(against other: ThemeColor) -> Double {
        let a = relativeLuminance + 0.05
        let b = other.relativeLuminance + 0.05
        return max(a, b) / min(a, b)
    }

    /// `self` composited over `background` (source-over).
    public func over(_ background: ThemeColor) -> ThemeColor {
        let a = alpha
        return ThemeColor(red: red * a + background.red * (1 - a), green: green * a + background.green * (1 - a),
                          blue: blue * a + background.blue * (1 - a), alpha: 1)
    }
}

/// Code-highlight token colours (PRD §8.4 `syntax.*`). `ThemeTests` validates
/// each against `codeBg` at 4.5:1.
public struct SyntaxColors: Sendable, Hashable {
    public var keyword: ThemeColor
    public var string: ThemeColor
    public var comment: ThemeColor
    public var number: ThemeColor
    public var type: ThemeColor
    public var function: ThemeColor

    public init(keyword: ThemeColor, string: ThemeColor, comment: ThemeColor, number: ThemeColor, type: ThemeColor,
                function: ThemeColor) {
        self.keyword = keyword
        self.string = string
        self.comment = comment
        self.number = number
        self.type = type
        self.function = function
    }

    public var all: [(name: String, color: ThemeColor)] {
        [("keyword", keyword), ("string", string), ("comment", comment), ("number", number), ("type", type),
         ("function", function)]
    }
}

public struct ThemeColors: Sendable, Hashable {
    public var bg: ThemeColor
    public var bgElevated: ThemeColor
    public var ink: ThemeColor
    public var ink2: ThemeColor
    public var muted: ThemeColor
    /// Revealed Markdown syntax markers (`**`, `#`, fences).
    public var syntax: ThemeColor
    public var border: ThemeColor
    public var codeBg: ThemeColor
    public var accent: ThemeColor
    public var accent2: ThemeColor
    public var selection: ThemeColor
    /// Find-match and mark highlight.
    public var highlight: ThemeColor
    public var caret: ThemeColor
    public var error: ThemeColor
    public var warning: ThemeColor
    public var ok: ThemeColor
    /// Fenced-code token colours.
    public var code: SyntaxColors

    public init(bg: ThemeColor, bgElevated: ThemeColor, ink: ThemeColor, ink2: ThemeColor, muted: ThemeColor,
                syntax: ThemeColor, border: ThemeColor, codeBg: ThemeColor, accent: ThemeColor, accent2: ThemeColor,
                selection: ThemeColor, highlight: ThemeColor, caret: ThemeColor, error: ThemeColor, warning: ThemeColor,
                ok: ThemeColor, code: SyntaxColors) {
        self.bg = bg
        self.bgElevated = bgElevated
        self.ink = ink
        self.ink2 = ink2
        self.muted = muted
        self.syntax = syntax
        self.border = border
        self.codeBg = codeBg
        self.accent = accent
        self.accent2 = accent2
        self.selection = selection
        self.highlight = highlight
        self.caret = caret
        self.error = error
        self.warning = warning
        self.ok = ok
        self.code = code
    }

    /// Text tokens and the backgrounds they are drawn on. The WCAG validator
    /// (`ThemeTests`) requires 4.5:1 for every pair.
    public var textPairs: [(name: String, text: ThemeColor, background: ThemeColor)] {
        var pairs: [(name: String, text: ThemeColor, background: ThemeColor)] = [
            ("ink/bg", ink, bg), ("ink2/bg", ink2, bg), ("muted/bg", muted, bg), ("syntax/bg", syntax, bg),
            ("accent/bg", accent, bg), ("accent2/bg", accent2, bg), ("error/bg", error, bg), ("warning/bg", warning, bg),
            ("ok/bg", ok, bg), ("ink/codeBg", ink, codeBg), ("ink2/codeBg", ink2, codeBg),
            ("muted/codeBg", muted, codeBg), ("ink/bgElevated", ink, bgElevated), ("ink2/bgElevated", ink2, bgElevated),
            ("muted/bgElevated", muted, bgElevated), ("ink/selection", ink, selection.over(bg)),
            ("ink/highlight", ink, highlight.over(bg)),
        ]
        for token in code.all { pairs.append(("syntax.\(token.name)/codeBg", token.color, codeBg)) }
        return pairs
    }

    /// The Increase Contrast token set (§8.4): ink becomes pure black or
    /// white, muted and syntax take ink2, borders ink2 at 60 %, and the
    /// selection is pushed toward ink until it stands 3:1 off the background.
    public func highContrast(isDark: Bool) -> ThemeColors {
        var c = self
        c.ink = ThemeColor(hex: isDark ? 0xFFFFFF : 0x000000)
        c.muted = ink2
        c.syntax = ink2
        c.border = ThemeColor(red: ink2.red, green: ink2.green, blue: ink2.blue, alpha: 0.6)
        let base = selection.over(bg)
        var raised = base
        var t = 0.0
        while raised.contrastRatio(against: bg) < 3, t < 1 {
            t = min(1, t + 0.02)
            raised = ThemeColor(red: base.red + (c.ink.red - base.red) * t, green: base.green + (c.ink.green - base.green) * t,
                                blue: base.blue + (c.ink.blue - base.blue) * t)
        }
        c.selection = raised
        return c
    }
}

// MARK: - Fonts and metrics

public enum FontFamily: Sendable, Hashable, CaseIterable {
    case body, heading, mono
}

public struct ThemeFonts: Sendable, Hashable {
    /// Candidate family names in preference order; the first installed one
    /// wins. The PRD's bundled fonts (Source Serif 4, JetBrains Mono, Noto
    /// Kannada) are not in the repository yet, so system families follow.
    public var body: [String]
    public var heading: [String]
    public var mono: [String]
    /// Per-script overrides (PRD §8.3), tried before the cascade table.
    public var scripts: [Script: [String]]

    public init(body: [String], heading: [String], mono: [String], scripts: [Script: [String]] = [:]) {
        self.body = body
        self.heading = heading
        self.mono = mono
        self.scripts = scripts
    }

    public func candidates(for family: FontFamily) -> [String] {
        switch family {
        case .body: return body
        case .heading: return heading
        case .mono: return mono
        }
    }
}

public struct ThemeMetrics: Sendable, Hashable {
    public var bodySize: CGFloat = 17
    public var lineHeight: CGFloat = 26
    public var tallLineHeight: CGFloat = 28
    /// Measure in characters of the body font (× advance of digit zero).
    public var measure: Int = 72
    public var paragraphSpacing: CGFloat = 13
    public var gutter: CGFloat = 56
    public var sideMargin: CGFloat = 32
    public var minMeasure: CGFloat = 320
    public var maxMeasure: CGFloat = 720

    public init() {}
}

// MARK: - Theme

public struct Theme: Sendable, Hashable {
    public var name: String
    public var isDark: Bool
    public var fonts: ThemeFonts
    public var metrics: ThemeMetrics
    public var colors: ThemeColors
    /// The colours before `highContrast` substituted them.
    private var standardColors: ThemeColors?

    public init(name: String, isDark: Bool, fonts: ThemeFonts, metrics: ThemeMetrics = ThemeMetrics(), colors: ThemeColors) {
        self.name = name
        self.isDark = isDark
        self.fonts = fonts
        self.metrics = metrics
        self.colors = colors
    }

    /// The theme with its Increase Contrast token set applied (§8.4).
    public var highContrast: Theme {
        guard standardColors == nil else { return self }
        var t = self
        t.standardColors = colors
        t.colors = colors.highContrast(isDark: isDark)
        return t
    }

    /// The theme without the Increase Contrast substitutions.
    public var standard: Theme {
        guard let standardColors else { return self }
        var t = self
        t.colors = standardColors
        t.standardColors = nil
        return t
    }

    public var isHighContrast: Bool { standardColors != nil }

    static let serifFonts = ThemeFonts(
        body: ["Source Serif 4", "Charter", "Georgia"],
        heading: ["Source Serif 4", "Charter", "Georgia"],
        mono: ["JetBrains Mono", "SF Mono", "Menlo"]
    )
    static let plexFonts = ThemeFonts(
        body: ["IBM Plex Serif", "Charter", "Georgia"],
        heading: ["IBM Plex Serif", "Charter", "Georgia"],
        mono: ["IBM Plex Mono", "SF Mono", "Menlo"]
    )
    static let systemFonts = ThemeFonts(
        body: ["SF Pro Text", "Helvetica Neue"],
        heading: ["SF Pro Display", "Helvetica Neue"],
        mono: ["SF Mono", "Menlo"]
    )
    static let sansFonts = ThemeFonts(
        body: ["Inter", "Helvetica Neue"],
        heading: ["Inter", "Helvetica Neue"],
        mono: ["JetBrains Mono", "SF Mono", "Menlo"]
    )

    /// Kannada name shown beside the theme name (§8.4).
    public var nativeName: String {
        switch name {
        case "Taalegari": return "ತಾಳೆಗರಿ"
        case "Kari": return "ಕರಿ"
        case "Bili": return "ಬಿಳಿ"
        case "Neeli": return "ನೀಲಿ"
        default: return name
        }
    }

    /// The theme Auto switches to when the system appearance flips (§8.4):
    /// Taalegari and Kari, Bili and Neeli.
    public var pair: Theme {
        switch name {
        case "Taalegari": return .kari
        case "Kari": return .taalegari
        case "Bili": return .neeli
        case "Neeli": return .bili
        default: return self
        }
    }

    /// Case-insensitive lookup by Latin or Kannada name.
    public static func named(_ name: String) -> Theme? {
        let key = name.lowercased()
        return all.first { $0.name.lowercased() == key || $0.nativeName == name }
    }

    /// ತಾಳೆಗರಿ (palm leaf): warm parchment, the default light theme.
    public static let taalegari = Theme(
        name: "Taalegari", isDark: false, fonts: serifFonts,
        colors: ThemeColors(
            bg: ThemeColor(hex: 0xF5EDDC), bgElevated: ThemeColor(hex: 0xEFE4CF), ink: ThemeColor(hex: 0x2B2118),
            ink2: ThemeColor(hex: 0x5C4B3B), muted: ThemeColor(hex: 0x756049), syntax: ThemeColor(hex: 0x756049),
            border: ThemeColor(hex: 0xD9CBB0), codeBg: ThemeColor(hex: 0xEBDFC6), accent: ThemeColor(hex: 0xA63D2B),
            accent2: ThemeColor(hex: 0x8A6508), selection: ThemeColor(hex: 0xE4C98B), highlight: ThemeColor(hex: 0xF0D78C),
            caret: ThemeColor(hex: 0xA63D2B), error: ThemeColor(hex: 0x9B2C1E), warning: ThemeColor(hex: 0x8A6508),
            ok: ThemeColor(hex: 0x3E6B3A),
            code: SyntaxColors(keyword: ThemeColor(hex: 0x9B2C1E), string: ThemeColor(hex: 0x3E6B3A),
                               comment: ThemeColor(hex: 0x6E5A45), number: ThemeColor(hex: 0x80510A),
                               type: ThemeColor(hex: 0x5A4480), function: ThemeColor(hex: 0x2C5877))))

    /// ಕರಿ (charcoal): the default dark theme, Taalegari's pair.
    public static let kari = Theme(
        name: "Kari", isDark: true, fonts: plexFonts,
        colors: ThemeColors(
            bg: ThemeColor(hex: 0x121212), bgElevated: ThemeColor(hex: 0x1B1B1B), ink: ThemeColor(hex: 0xECEAE5),
            ink2: ThemeColor(hex: 0xB5B1A8), muted: ThemeColor(hex: 0x8C877D), syntax: ThemeColor(hex: 0x8C877D),
            border: ThemeColor(hex: 0x2C2C2C), codeBg: ThemeColor(hex: 0x1E1E1E), accent: ThemeColor(hex: 0xF2B84B),
            accent2: ThemeColor(hex: 0xF08A73), selection: ThemeColor(hex: 0x3D3322), highlight: ThemeColor(hex: 0x4A3A16),
            caret: ThemeColor(hex: 0xF2B84B), error: ThemeColor(hex: 0xFF7B6B), warning: ThemeColor(hex: 0xF2B84B),
            ok: ThemeColor(hex: 0x8FD18A),
            code: SyntaxColors(keyword: ThemeColor(hex: 0xF08A73), string: ThemeColor(hex: 0x8FD18A),
                               comment: ThemeColor(hex: 0x8C877D), number: ThemeColor(hex: 0xF2B84B),
                               type: ThemeColor(hex: 0x8CC4E8), function: ThemeColor(hex: 0xE6C98F))))

    /// ಬಿಳಿ (white): neutral light with system fonts.
    public static let bili = Theme(
        name: "Bili", isDark: false, fonts: systemFonts,
        colors: ThemeColors(
            bg: ThemeColor(hex: 0xFFFFFF), bgElevated: ThemeColor(hex: 0xF5F5F7), ink: ThemeColor(hex: 0x1D1D1F),
            ink2: ThemeColor(hex: 0x515154), muted: ThemeColor(hex: 0x6E6E73), syntax: ThemeColor(hex: 0x6E6E73),
            border: ThemeColor(hex: 0xD2D2D7), codeBg: ThemeColor(hex: 0xF2F2F4), accent: ThemeColor(hex: 0x0A5BD8),
            accent2: ThemeColor(hex: 0xB04D0E), selection: ThemeColor(hex: 0xB4D5FE), highlight: ThemeColor(hex: 0xFFE58A),
            caret: ThemeColor(hex: 0x0A5BD8), error: ThemeColor(hex: 0xC41E1E), warning: ThemeColor(hex: 0x8A5A00),
            ok: ThemeColor(hex: 0x1F7A3A),
            code: SyntaxColors(keyword: ThemeColor(hex: 0xA12A7C), string: ThemeColor(hex: 0x1F7A3A),
                               comment: ThemeColor(hex: 0x6A6A6F), number: ThemeColor(hex: 0xA8490D),
                               type: ThemeColor(hex: 0x0B6780), function: ThemeColor(hex: 0x0A55C8))))

    /// ನೀಲಿ (blue): dark navy, Bili's pair. `muted` is #808798 rather than the
    /// PRD's #7C8394, which measures 4.33:1 on bgElevated and 4.39:1 on codeBg.
    public static let neeli = Theme(
        name: "Neeli", isDark: true, fonts: sansFonts,
        colors: ThemeColors(
            bg: ThemeColor(hex: 0x14171F), bgElevated: ThemeColor(hex: 0x1B1F2A), ink: ThemeColor(hex: 0xD6DAE3),
            ink2: ThemeColor(hex: 0xA3A9B8), muted: ThemeColor(hex: 0x808798), syntax: ThemeColor(hex: 0x808798),
            border: ThemeColor(hex: 0x2A3040), codeBg: ThemeColor(hex: 0x1A1E28), accent: ThemeColor(hex: 0x8FB4FF),
            accent2: ThemeColor(hex: 0xF5C97A), selection: ThemeColor(hex: 0x2B3B5E), highlight: ThemeColor(hex: 0x4A4020),
            caret: ThemeColor(hex: 0x8FB4FF), error: ThemeColor(hex: 0xFF8A80), warning: ThemeColor(hex: 0xF5C97A),
            ok: ThemeColor(hex: 0x8BD5A0),
            code: SyntaxColors(keyword: ThemeColor(hex: 0xC9A0F2), string: ThemeColor(hex: 0x8BD5A0),
                               comment: ThemeColor(hex: 0x858CA0), number: ThemeColor(hex: 0xF5C97A),
                               type: ThemeColor(hex: 0x7FD4C8), function: ThemeColor(hex: 0x8FB4FF))))

    public static let all: [Theme] = [taalegari, kari, bili, neeli]
}

// MARK: - Type scale (PRD §8.2)

public enum FontWeight: Sendable, Hashable {
    case regular, semibold, bold

    /// Core Text weight trait (−1…1; regular 0, semibold 0.3, bold 0.4).
    public var trait: Double {
        switch self {
        case .regular: return 0
        case .semibold: return 0.3
        case .bold: return 0.4
        }
    }
}

public enum InkToken: Sendable, Hashable {
    case ink, ink2, muted
}

public enum TextRole: Sendable, Hashable {
    case body
    case heading(Int)
    case inlineCode
    case codeBlock
    case tableCell
    case tableHeader
    case blockQuote
    case footnote
    case frontMatter
    case gutterMarker
    case statusBar
}

public struct TextStyle: Sendable, Hashable {
    public var family: FontFamily
    public var size: CGFloat
    public var lineHeight: CGFloat
    public var weight: FontWeight
    public var ink: InkToken
    public var spacingBefore: CGFloat
    public var spacingAfter: CGFloat
    /// Horizontal and vertical padding inside a background (code block 12 pt,
    /// table cell 10 × 6 pt).
    public var paddingX: CGFloat
    public var paddingY: CGFloat
    /// Leading indent (block quote 16 pt).
    public var indent: CGFloat

    public init(family: FontFamily, size: CGFloat, lineHeight: CGFloat, weight: FontWeight = .regular, ink: InkToken = .ink,
                spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 0, paddingX: CGFloat = 0, paddingY: CGFloat = 0,
                indent: CGFloat = 0) {
        self.family = family
        self.size = size
        self.lineHeight = lineHeight
        self.weight = weight
        self.ink = ink
        self.spacingBefore = spacingBefore
        self.spacingAfter = spacingAfter
        self.paddingX = paddingX
        self.paddingY = paddingY
        self.indent = indent
    }
}

/// The §8.2 table scaled by the theme's body size and the zoom level.
public struct TypeScale: Sendable, Hashable {
    public let theme: Theme
    /// 0.6 … 2.0 in steps of 0.1 (Cmd-+/−/0).
    public let zoom: CGFloat
    /// Multiplier applied to every size in the table: bodySize / 17 × zoom.
    public let factor: CGFloat
    /// Source mode (§6.2): every role is the monospace family at body size,
    /// with no block spacing, padding or indent.
    public let monospace: Bool

    public static let zoomSteps: [CGFloat] = (6...20).map { CGFloat($0) / 10 }
    public static let defaultZoom: CGFloat = 1

    public init(theme: Theme, zoom: CGFloat = 1, monospace: Bool = false) {
        self.theme = theme
        self.monospace = monospace
        self.zoom = TypeScale.clampZoom(zoom)
        factor = theme.metrics.bodySize / 17 * self.zoom
    }

    public static func clampZoom(_ zoom: CGFloat) -> CGFloat {
        let steps = zoomSteps
        return steps.min(by: { abs($0 - zoom) < abs($1 - zoom) }) ?? 1
    }

    public func zoomed(in direction: Int) -> TypeScale {
        let steps = TypeScale.zoomSteps
        let i = steps.firstIndex(of: zoom) ?? 4
        let j = min(max(i + direction, 0), steps.count - 1)
        return TypeScale(theme: theme, zoom: steps[j], monospace: monospace)
    }

    /// Scaled size rounded to half points; line heights and spacings to whole points.
    func s(_ v: CGFloat) -> CGFloat { (v * factor * 2).rounded() / 2 }
    func l(_ v: CGFloat) -> CGFloat { (v * factor).rounded(.up) }

    /// Extra height a Tall paragraph gets over the standard line height, as a
    /// ratio (28/26 in the default metrics).
    public var tallRatio: CGFloat { theme.metrics.tallLineHeight / theme.metrics.lineHeight }

    public var paragraphSpacing: CGFloat { l(theme.metrics.paragraphSpacing) }
    public var gutter: CGFloat { theme.metrics.gutter }
    public var sideMargin: CGFloat { theme.metrics.sideMargin }

    public func style(for role: TextRole) -> TextStyle {
        if monospace {
            switch role {
            case .statusBar: break
            case .gutterMarker: return TextStyle(family: .mono, size: s(17), lineHeight: l(26), ink: .muted)
            default: return TextStyle(family: .mono, size: s(17), lineHeight: l(26))
            }
        }
        switch role {
        case .body:
            return TextStyle(family: .body, size: s(17), lineHeight: l(26), spacingAfter: paragraphSpacing)
        case .heading(let level):
            switch level {
            case 1: return TextStyle(family: .heading, size: s(34), lineHeight: l(40), weight: .semibold, spacingBefore: l(26), spacingAfter: l(12))
            case 2: return TextStyle(family: .heading, size: s(28), lineHeight: l(36), weight: .semibold, spacingBefore: l(24), spacingAfter: l(8))
            case 3: return TextStyle(family: .heading, size: s(23), lineHeight: l(30), weight: .semibold, spacingBefore: l(20), spacingAfter: l(8))
            case 4: return TextStyle(family: .heading, size: s(19), lineHeight: l(26), weight: .semibold, spacingBefore: l(16), spacingAfter: l(4))
            case 5: return TextStyle(family: .heading, size: s(17), lineHeight: l(26), weight: .semibold, spacingBefore: l(12), spacingAfter: l(4))
            default: return TextStyle(family: .heading, size: s(17), lineHeight: l(26), weight: .semibold, ink: .ink2, spacingBefore: l(12), spacingAfter: l(4))
            }
        case .inlineCode:
            return TextStyle(family: .mono, size: s(15), lineHeight: l(26), paddingX: 2)
        case .codeBlock:
            return TextStyle(family: .mono, size: s(14), lineHeight: l(21), spacingAfter: paragraphSpacing, paddingX: l(12), paddingY: l(12))
        case .tableCell:
            return TextStyle(family: .body, size: s(15), lineHeight: l(22), paddingX: l(10), paddingY: l(6))
        case .tableHeader:
            return TextStyle(family: .body, size: s(15), lineHeight: l(22), weight: .semibold, paddingX: l(10), paddingY: l(6))
        case .blockQuote:
            return TextStyle(family: .body, size: s(17), lineHeight: l(26), ink: .ink2, spacingAfter: paragraphSpacing, indent: l(16))
        case .footnote:
            return TextStyle(family: .body, size: s(14), lineHeight: l(20), ink: .ink2, spacingAfter: paragraphSpacing)
        case .frontMatter:
            return TextStyle(family: .mono, size: s(13), lineHeight: l(18), ink: .ink2, spacingAfter: paragraphSpacing, paddingX: l(12), paddingY: l(10))
        case .gutterMarker:
            return TextStyle(family: .body, size: s(17), lineHeight: l(26), ink: .muted)
        case .statusBar:
            return TextStyle(family: .body, size: 12, lineHeight: 16, ink: .ink2)
        }
    }

    public func color(_ token: InkToken) -> ThemeColor {
        switch token {
        case .ink: return theme.colors.ink
        case .ink2: return theme.colors.ink2
        case .muted: return theme.colors.muted
        }
    }
}
