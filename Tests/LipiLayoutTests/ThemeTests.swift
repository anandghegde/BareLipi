import Foundation
import LipiLayout
import Testing

@Suite("Themes (§8.1–8.2)")
struct ThemeTests {
    @Test func colourArithmetic() {
        let white = ThemeColor(hex: 0xFFFFFF)
        let black = ThemeColor(hex: 0x000000)
        #expect(approximately(white.relativeLuminance, 1, within: 0.001))
        #expect(approximately(black.relativeLuminance, 0, within: 0.001))
        #expect(approximately(white.contrastRatio(against: black), 21, within: 0.01))
        #expect(approximately(black.contrastRatio(against: white), 21, within: 0.01))
        #expect(ThemeColor(hex: 0x8A3B12).hexString == "#8A3B12")
        // Compositing a half-transparent white over black gives mid grey.
        let mixed = ThemeColor(hex: 0xFFFFFF, alpha: 0.5).over(black)
        #expect(approximately(mixed.red, 0.5, within: 0.01))
        #expect(mixed.alpha == 1)
    }

    @Test(arguments: Theme.all)
    func textPairsMeetWCAGAA(theme: Theme) {
        for pair in theme.colors.textPairs {
            let text = pair.text.over(pair.background)
            let ratio = text.contrastRatio(against: pair.background)
            #expect(ratio >= 4.5, "\(theme.name) \(pair.name): \(String(format: "%.2f", ratio)):1 (\(text.hexString) on \(pair.background.hexString))")
        }
        #expect(theme.colors.textPairs.count >= 10)
    }

    @Test(arguments: Theme.all)
    func darkThemesInvertLuminance(theme: Theme) {
        let bg = theme.colors.bg.relativeLuminance
        let ink = theme.colors.ink.relativeLuminance
        #expect(theme.isDark ? bg < ink : bg > ink)
        // Selection is translucent so the text stays readable through it.
        #expect(theme.colors.selection.alpha < 1)
    }

    @Test func typeTableAtDefaultZoom() {
        let scale = TypeScale(theme: .paper)
        #expect(scale.factor == 1)
        let body = scale.style(for: .body)
        #expect(body.size == 17 && body.lineHeight == 26 && body.spacingAfter == 13)
        let h1 = scale.style(for: .heading(1))
        #expect(h1.size == 34 && h1.lineHeight == 40 && h1.weight == .semibold && h1.spacingBefore == 26 && h1.spacingAfter == 12)
        let h2 = scale.style(for: .heading(2))
        #expect(h2.size == 28 && h2.lineHeight == 36 && h2.spacingBefore == 24 && h2.spacingAfter == 8)
        let h3 = scale.style(for: .heading(3))
        #expect(h3.size == 23 && h3.lineHeight == 30)
        let h6 = scale.style(for: .heading(6))
        #expect(h6.size == 17 && h6.ink == .ink2)
        let code = scale.style(for: .codeBlock)
        #expect(code.family == .mono && code.size == 14 && code.lineHeight == 21 && code.paddingX == 12 && code.paddingY == 12)
        let inlineCode = scale.style(for: .inlineCode)
        #expect(inlineCode.size == 15 && inlineCode.paddingX == 2)
        let cell = scale.style(for: .tableCell)
        #expect(cell.size == 15 && cell.lineHeight == 22 && cell.paddingX == 10 && cell.paddingY == 6)
        #expect(scale.style(for: .tableHeader).weight == .semibold)
        let quote = scale.style(for: .blockQuote)
        #expect(quote.ink == .ink2 && quote.indent == 16)
        let footnote = scale.style(for: .footnote)
        #expect(footnote.size == 14 && footnote.lineHeight == 20)
        let front = scale.style(for: .frontMatter)
        #expect(front.family == .mono && front.size == 13 && front.lineHeight == 18)
        #expect(scale.style(for: .gutterMarker).ink == .muted)
        #expect(scale.gutter == 56 && scale.sideMargin == 32)
        #expect(approximately(scale.tallRatio, 28 / 26, within: 0.0001))
    }

    @Test func zoomStepsAndRounding() {
        #expect(TypeScale.zoomSteps.first == 0.6 && TypeScale.zoomSteps.last == 2.0 && TypeScale.zoomSteps.count == 15)
        let zoomed = TypeScale(theme: .paper, zoom: 1.2)
        let body = zoomed.style(for: .body)
        #expect(body.size == 20.5)      // 17 × 1.2 = 20.4, half-point rounding
        #expect(body.lineHeight == 32)  // 26 × 1.2 = 31.2, rounded up
        #expect(TypeScale.clampZoom(0.1) == 0.6)
        #expect(TypeScale.clampZoom(9) == 2.0)
        #expect([1.2, 1.3].contains(TypeScale.clampZoom(1.25)))
        #expect(TypeScale(theme: .paper).zoomed(in: 1).zoom == 1.1)
        #expect(TypeScale(theme: .paper).zoomed(in: -1).zoom == 0.9)
        #expect(TypeScale(theme: .paper, zoom: 2).zoomed(in: 1).zoom == 2)
    }

    @Test func themeMetricsScaleTheTable() {
        var theme = Theme.paper
        theme.metrics.bodySize = 34
        let scale = TypeScale(theme: theme)
        #expect(scale.factor == 2)
        #expect(scale.style(for: .body).size == 34)
        #expect(scale.style(for: .heading(1)).lineHeight == 80)
    }
}
