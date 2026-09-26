import AppKit
import LipiEditor
import LipiLayout
import Testing

@Suite("Accessibility display options (§6.20, §8.4)")
@MainActor
struct DisplayOptionsTests {
    @Test(arguments: Theme.all)
    func highContrastTokens(theme: Theme) {
        let hc = theme.highContrast
        let c = hc.colors
        #expect(hc.isHighContrast && !theme.isHighContrast)
        #expect(c.ink == ThemeColor(hex: theme.isDark ? 0xFFFFFF : 0x000000))
        #expect(c.muted == theme.colors.ink2 && c.syntax == theme.colors.ink2)
        #expect(c.border.alpha == 0.6)
        #expect(c.ink.contrastRatio(against: c.bg) >= 7, "\(theme.name) ink")
        #expect(c.selection.contrastRatio(against: c.bg) >= 3, "\(theme.name) selection")
        for pair in c.textPairs {
            let ratio = pair.text.over(pair.background).contrastRatio(against: pair.background)
            #expect(ratio >= 4.5, "\(theme.name) HC \(pair.name): \(ratio)")
        }
        #expect(hc.highContrast == hc)
        #expect(hc.standard == theme)
    }

    @Test func increaseContrastSwitchesTheEditorTheme() {
        let view = makeView("# Title")
        view.followsSystemDisplayOptions = false
        view.displayOptions = AccessibilityDisplayOptions()
        #expect(!view.controller.theme.isHighContrast)
        view.displayOptions.increaseContrast = true
        #expect(view.controller.theme.isHighContrast)
        #expect(view.controller.theme.colors.ink == ThemeColor(hex: 0x000000))
        // A theme change keeps high contrast; turning it off restores the tokens.
        view.controller.setTheme(.kari)
        #expect(view.controller.theme.colors.ink == ThemeColor(hex: 0xFFFFFF))
        view.displayOptions.increaseContrast = false
        #expect(view.controller.theme == .kari)
    }

    @Test func reduceMotionZeroesTransitions() {
        #expect(AccessibilityDisplayOptions().duration(AccessibilityDisplayOptions.transition) == 0.12)
        #expect(AccessibilityDisplayOptions(reduceMotion: true).duration(0.12) == 0)
    }
}
