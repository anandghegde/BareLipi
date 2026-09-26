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

public struct ThemeColors: Sendable, Hashable {
    public var bg: ThemeColor
    public var bgElevated: ThemeColor
    public var ink: ThemeColor
    public var ink2: ThemeColor
    public var muted: ThemeColor
    public var syntax: ThemeColor
    public var border: ThemeColor
    public var codeBg: ThemeColor
    public var accent: ThemeColor
    public var selection: ThemeColor
    public var caret: ThemeColor

    public init(bg: ThemeColor, bgElevated: ThemeColor, ink: ThemeColor, ink2: ThemeColor, muted: ThemeColor,
                syntax: ThemeColor, border: ThemeColor, codeBg: ThemeColor, accent: ThemeColor, selection: ThemeColor,
                caret: ThemeColor) {
        self.bg = bg
        self.bgElevated = bgElevated
        self.ink = ink
        self.ink2 = ink2
        self.muted = muted
        self.syntax = syntax
        self.border = border
        self.codeBg = codeBg
        self.accent = accent
        self.selection = selection
        self.caret = caret
    }

    /// Text tokens and the backgrounds they are drawn on. The WCAG validator
    /// (`ThemeTests`) requires 4.5:1 for every pair.
    public var textPairs: [(name: String, text: ThemeColor, background: ThemeColor)] {
        [("ink/bg", ink, bg), ("ink2/bg", ink2, bg), ("muted/bg", muted, bg), ("syntax/bg", syntax, bg),
         ("accent/bg", accent, bg), ("ink/codeBg", ink, codeBg), ("ink2/codeBg", ink2, codeBg),
         ("muted/codeBg", muted, codeBg), ("ink/bgElevated", ink, bgElevated), ("ink2/bgElevated", ink2, bgElevated),
         ("muted/bgElevated", muted, bgElevated), ("ink/selection", ink, selection.over(bg))]
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

    public init(name: String, isDark: Bool, fonts: ThemeFonts, metrics: ThemeMetrics = ThemeMetrics(), colors: ThemeColors) {
        self.name = name
        self.isDark = isDark
        self.fonts = fonts
        self.metrics = metrics
        self.colors = colors
    }

    static let serifFonts = ThemeFonts(
        body: ["Source Serif 4", "Charter", "Georgia"],
        heading: ["Source Serif 4", "Charter", "Georgia"],
        mono: ["JetBrains Mono", "SF Mono", "Menlo"]
    )
    static let sansFonts = ThemeFonts(
        body: ["Inter", "Helvetica Neue"],
        heading: ["Inter", "Helvetica Neue"],
        mono: ["JetBrains Mono", "SF Mono", "Menlo"]
    )

    /// Warm light theme (the PRD's example: bg #F5EDDC, ink #2B2118).
    public static let paper = Theme(
        name: "Paper", isDark: false, fonts: serifFonts,
        colors: ThemeColors(
            bg: ThemeColor(hex: 0xF5EDDC), bgElevated: ThemeColor(hex: 0xFBF6EA), ink: ThemeColor(hex: 0x2B2118),
            ink2: ThemeColor(hex: 0x584A3D), muted: ThemeColor(hex: 0x6B5D4E), syntax: ThemeColor(hex: 0x6B5D4E),
            border: ThemeColor(hex: 0xD6C8AE), codeBg: ThemeColor(hex: 0xECE3CF), accent: ThemeColor(hex: 0x8A3B12),
            selection: ThemeColor(hex: 0xC9A86A, alpha: 0.35), caret: ThemeColor(hex: 0x2B2118)))

    /// Neutral light theme.
    public static let snow = Theme(
        name: "Snow", isDark: false, fonts: sansFonts,
        colors: ThemeColors(
            bg: ThemeColor(hex: 0xFFFFFF), bgElevated: ThemeColor(hex: 0xF7F7F8), ink: ThemeColor(hex: 0x1D1D1F),
            ink2: ThemeColor(hex: 0x4A4A4F), muted: ThemeColor(hex: 0x646469), syntax: ThemeColor(hex: 0x646469),
            border: ThemeColor(hex: 0xD9D9DE), codeBg: ThemeColor(hex: 0xF0F0F3), accent: ThemeColor(hex: 0x1F5FBF),
            selection: ThemeColor(hex: 0x3B82F6, alpha: 0.25), caret: ThemeColor(hex: 0x1D1D1F)))

    /// Warm dark theme.
    public static let ink = Theme(
        name: "Ink", isDark: true, fonts: serifFonts,
        colors: ThemeColors(
            bg: ThemeColor(hex: 0x1C1A17), bgElevated: ThemeColor(hex: 0x262320), ink: ThemeColor(hex: 0xEDE6D6),
            ink2: ThemeColor(hex: 0xC4BAA6), muted: ThemeColor(hex: 0xA79D8B), syntax: ThemeColor(hex: 0xA79D8B),
            border: ThemeColor(hex: 0x3E392F), codeBg: ThemeColor(hex: 0x27241F), accent: ThemeColor(hex: 0xE39A5E),
            selection: ThemeColor(hex: 0xC9A86A, alpha: 0.3), caret: ThemeColor(hex: 0xEDE6D6)))

    /// Neutral dark theme.
    public static let slate = Theme(
        name: "Slate", isDark: true, fonts: sansFonts,
        colors: ThemeColors(
            bg: ThemeColor(hex: 0x1E2126), bgElevated: ThemeColor(hex: 0x272B31), ink: ThemeColor(hex: 0xE6E8EB),
            ink2: ThemeColor(hex: 0xB8BDC5), muted: ThemeColor(hex: 0x9AA1AA), syntax: ThemeColor(hex: 0x9AA1AA),
            border: ThemeColor(hex: 0x3A4048), codeBg: ThemeColor(hex: 0x282C33), accent: ThemeColor(hex: 0x7FB3FF),
            selection: ThemeColor(hex: 0x3B82F6, alpha: 0.3), caret: ThemeColor(hex: 0xE6E8EB)))

    public static let all: [Theme] = [paper, snow, ink, slate]
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

    public static let zoomSteps: [CGFloat] = (6...20).map { CGFloat($0) / 10 }
    public static let defaultZoom: CGFloat = 1

    public init(theme: Theme, zoom: CGFloat = 1) {
        self.theme = theme
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
        return TypeScale(theme: theme, zoom: steps[j])
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
