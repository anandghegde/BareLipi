import AppKit
import Foundation
import LipiEditor
import Testing
@testable import LipiApp

@Suite("Writing modes: settings and zen restoration (§6.12)")
@MainActor
struct WritingSettingsTests {
    private func window() -> DocumentWindowController {
        let controller = EditorController(text: "# A\n\nOne. Two.\n", viewportWidth: 800)
        return DocumentWindowController(controller: controller, theme: .taalegari, contentRect: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    @Test func zenModeIsRestoredWithTheWindow() throws {
        let wc = window()
        wc.setOutlineVisible(true, focus: false)
        wc.toggleZenMode(nil)
        let state = wc.editorState()
        #expect(state.zenMode == true)
        #expect(state.showsOutline == true)
        // Through the coder, as NSDocument restoration stores it.
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        state.encode(to: archiver)
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        let decoded = try #require(RestorableEditorState.decode(from: unarchiver))
        let other = window()
        other.apply(decoded)
        #expect(other.isZenMode)
        #expect(!other.isOutlineVisible)
        #expect(other.chrome.statusBar.isHidden)
        // Leaving zen puts back the outline from before zen.
        other.toggleZenMode(nil)
        #expect(other.isOutlineVisible)
        #expect(!other.chrome.statusBar.isHidden)
        // Re-applying state (zoom, syntax changes) never toggles zen.
        other.apply(other.editorState())
        #expect(!other.isZenMode)
        // Older state without the field leaves zen off.
        let plain = window()
        plain.apply(RestorableEditorState(anchor: 0, head: 0, scrollAnchor: 0, scrollOffset: 0))
        #expect(!plain.isZenMode)
    }

    @Test func settingsReadDefaultsAndApply() throws {
        let defaults = try #require(UserDefaults(suiteName: "WritingSettingsTests-\(UUID().uuidString)"))
        #expect(WritingSettings.focusScope(defaults) == .block)
        #expect(WritingSettings.typewriterFraction(defaults) == 0.5)
        #expect(!WritingSettings.typewriterEases(defaults))
        defaults.set("sentence", forKey: WritingSettings.focusScopeKey)
        defaults.set(0.95, forKey: WritingSettings.typewriterFractionKey)
        defaults.set(true, forKey: WritingSettings.typewriterEaseKey)
        let wc = window()
        WritingSettings.apply(to: wc.editor, defaults)
        #expect(wc.editor.focusScopeKind == .sentence)
        #expect(wc.editor.typewriterFraction == 0.7)
        #expect(wc.editor.typewriterEases)
    }
}
