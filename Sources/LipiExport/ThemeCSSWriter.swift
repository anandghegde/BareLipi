import Foundation
import LipiHighlight
import LipiLayout

/// Which palette an exported page uses.
public enum ExportThemeMode: String, Sendable, Hashable, CaseIterable {
    /// The window's theme, as the editor shows it.
    case window
    /// The window's theme and its Auto pair: light by default, dark under
    /// `prefers-color-scheme: dark`, following the reader's system.
    case lightAndDark

    public var title: String {
        switch self {
        case .window: return "Window's theme"
        case .lightAndDark: return "Light and dark (follows the reader)"
        }
    }
}

/// The theme as a self-contained stylesheet for the HTML export: the §8.4
/// palette as CSS custom properties, the theme's font stacks and measure,
/// and one rule per syntax token class.
public struct ThemeCSSWriter: Sendable {
    public var theme: Theme
    /// A second palette for readers in dark mode; `theme` is then the light one.
    public var dark: Theme?

    public init(theme: Theme, dark: Theme? = nil) {
        self.theme = theme
        self.dark = dark
    }

    /// The stylesheet for an export of a window in `theme`. A light / dark
    /// export keeps the window's fonts and measure and takes both palettes
    /// from the pair, so the text does not reflow when the reader's
    /// appearance flips.
    public init(theme: Theme, mode: ExportThemeMode) {
        switch mode {
        case .window:
            self.init(theme: theme)
        case .lightAndDark:
            let pair = ThemeCSSWriter.lightDarkPair(for: theme)
            var light = theme
            light.colors = pair.light.colors
            light.isDark = false
            self.init(theme: light, dark: pair.dark)
        }
    }

    /// The light and dark themes for a light / dark export: the theme and
    /// the one Auto switches to (§8.4: Taalegari and Kari, Bili and Neeli),
    /// with Increase Contrast carried over. A theme without a pair of the
    /// other appearance is paired with the default Taalegari or Kari.
    public static func lightDarkPair(for theme: Theme) -> (light: Theme, dark: Theme) {
        var other = theme.standard.pair
        if other.isDark == theme.isDark { other = theme.isDark ? .taalegari : .kari }
        if theme.isHighContrast { other = other.highContrast }
        return theme.isDark ? (other, theme) : (theme, other)
    }

    /// `--lipi-*` custom properties, in a stable order.
    public var variables: [(name: String, value: String)] { ThemeCSSWriter.variables(of: theme) }

    static func variables(of theme: Theme) -> [(name: String, value: String)] {
        let c = theme.colors
        var out: [(String, String)] = [
            ("bg", c.bg.css), ("bg-elevated", c.bgElevated.css), ("ink", c.ink.css), ("ink-2", c.ink2.css),
            ("muted", c.muted.css), ("syntax", c.syntax.css), ("border", c.border.css), ("code-bg", c.codeBg.css),
            ("accent", c.accent.css), ("accent-2", c.accent2.css), ("selection", c.selection.css),
            ("highlight", c.highlight.css), ("error", c.error.css), ("warning", c.warning.css), ("ok", c.ok.css),
        ]
        for (name, color) in c.code.all { out.append(("syntax-\(name)", color.css)) }
        return out.map { (name: "--lipi-\($0.0)", value: $0.1) }
    }

    public func css() -> String {
        let m = theme.metrics
        let vars = variables.map { "  \($0.name): \($0.value);" }.joined(separator: "\n")
        let body = ThemeCSSWriter.fontStack(theme.fonts.body, generic: ThemeCSSWriter.generic(theme.fonts.body))
        let heading = ThemeCSSWriter.fontStack(theme.fonts.heading, generic: ThemeCSSWriter.generic(theme.fonts.heading))
        let mono = ThemeCSSWriter.fontStack(theme.fonts.mono, generic: "monospace")
        let tokens = SyntaxToken.allCases.map { token in
            ".\(token.cssClass) { color: var(\(ThemeCSSWriter.variable(for: token))); }"
        }.joined(separator: "\n")
        let spacing = Int(m.paragraphSpacing)
        return """
        :root {
        \(vars)
          color-scheme: \(dark != nil ? "light dark" : theme.isDark ? "dark" : "light");
        }
        html { background: var(--lipi-bg); }
        body { margin: 0; background: var(--lipi-bg); color: var(--lipi-ink);
          font-family: \(body); font-size: \(Int(m.bodySize))px; line-height: \(Int(m.lineHeight))px;
          -webkit-text-size-adjust: 100%; text-rendering: optimizeLegibility; }
        ::selection { background: var(--lipi-selection); }
        .lipi-document { max-width: \(m.measure)ch; margin: 0 auto; padding: 48px \(Int(m.sideMargin))px 96px; }
        p, ul, ol, blockquote, pre, table { margin: 0 0 \(spacing)px; }
        h1, h2, h3, h4, h5, h6 { font-family: \(heading); line-height: 1.25; margin: 1.6em 0 0.5em; }
        h1 { font-size: 2em; } h2 { font-size: 1.5em; } h3 { font-size: 1.25em; } h4, h5, h6 { font-size: 1em; }
        a { color: var(--lipi-accent); }
        blockquote { border-left: 3px solid var(--lipi-border); padding-left: 1em; margin-left: 0; color: var(--lipi-ink-2); }
        hr { border: 0; border-top: 1px solid var(--lipi-border); margin: 2em 0; }
        code, pre, .math { font-family: \(mono); font-size: 0.88em; }
        code { background: var(--lipi-code-bg); border-radius: 4px; padding: 0.1em 0.3em; }
        pre { background: var(--lipi-code-bg); color: var(--lipi-syntax); border-radius: 6px; padding: 12px 16px;
          overflow-x: auto; line-height: 1.5; }
        pre code { background: none; padding: 0; font-size: 1em; }
        table { border-collapse: collapse; display: block; overflow-x: auto; }
        th, td { border: 1px solid var(--lipi-border); padding: 4px 10px; }
        th { background: var(--lipi-bg-elevated); }
        img { max-width: 100%; }
        del { color: var(--lipi-muted); }
        mark { background: var(--lipi-highlight); color: inherit; }
        .toc ul ul { margin: 0; }
        li > input[type=checkbox] { margin-right: 0.4em; }
        .footnotes { border-top: 1px solid var(--lipi-border); color: var(--lipi-ink-2); font-size: 0.9em; margin-top: 3em; }
        .math.display { display: block; text-align: center; margin: 0 0 \(spacing)px; }
        \(tokens)
        \(darkRule)@media print { html, body { background: none; } .lipi-document { max-width: none; padding: 0; } }
        """
    }

    /// The dark palette's properties for screens in dark mode (with a
    /// trailing newline), or nothing. Print keeps the light palette.
    var darkRule: String {
        guard let dark else { return "" }
        let vars = ThemeCSSWriter.variables(of: dark).map { "    \($0.name): \($0.value);" }.joined(separator: "\n")
        return "@media screen and (prefers-color-scheme: dark) {\n  :root {\n\(vars)\n    color-scheme: dark;\n  }\n}\n"
    }

    /// The custom property a token class is coloured with.
    static func variable(for token: SyntaxToken) -> String {
        switch token {
        case .inserted: return "--lipi-ok"
        case .deleted: return "--lipi-error"
        default: return "--lipi-syntax-\(token.cssClass.dropFirst(4))"
        }
    }

    /// `serif` for the serif stacks (their last resort is Georgia), else `sans-serif`.
    static func generic(_ names: [String]) -> String {
        names.contains { $0.contains("Serif") || $0 == "Georgia" || $0 == "Charter" } ? "serif" : "sans-serif"
    }

    /// Quoted family names, then a system fallback and the generic family.
    static func fontStack(_ names: [String], generic: String) -> String {
        var families = names.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }
        families.append(generic == "monospace" ? "ui-monospace" : "-apple-system")
        families.append(generic)
        return families.joined(separator: ", ")
    }
}

extension ThemeColor {
    /// `#RRGGBB`, or `rgba()` when translucent.
    var css: String {
        if alpha >= 1 { return hexString }
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "rgba(%d, %d, %d, %.3g)", byte(red), byte(green), byte(blue), alpha)
    }
}
