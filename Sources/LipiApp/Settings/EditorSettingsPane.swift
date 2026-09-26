import AppKit
import LipiEditor

/// Settings → Editing: auto-pairing, the emphasis marker Cmd-I writes, the
/// hard-break style Shift-Enter writes, table completion, the default code
/// block wrap and line numbers, and the writing modes (§6.12): focus scope,
/// typewriter line position and scroll ease (`WritingSettings`).
@MainActor
public final class EditorSettingsPane: SettingsFormPane {
    public override func buildRows() {
        let s = settings
        checkbox("Auto-pair brackets, quotes and markers", label: "Typing:", get: s.autoPair) { s.autoPair = $0 }
        checkbox("Complete tables on Enter", get: s.completeTables) { s.completeTables = $0 }
        popup("Emphasis marker:", [("*asterisks*", Character("*")), ("_underscores_", Character("_"))],
              get: s.emphasisMarker) { s.emphasisMarker = $0 }
        popup("Hard line break:", [("Backslash  \\", EditorSettings.HardBreak.backslash),
                                   ("Two trailing spaces", EditorSettings.HardBreak.twoSpaces)],
              get: s.hardBreak) { s.hardBreak = $0 }
        note("Written by Cmd-I and Shift-Return. Existing text keeps its markers.")
        checkbox("Wrap long lines", label: "Code blocks:", get: s.codeWrap) { s.codeWrap = $0 }
        checkbox("Show line numbers", get: s.codeLineNumbers) { s.codeLineNumbers = $0 }
        let defaults = s.defaults
        popup("Focus mode dims:", [("All but the current block", FocusScopeKind.block),
                                   ("All but the current sentence", FocusScopeKind.sentence)],
              get: WritingSettings.focusScope(defaults)) { WritingSettings.set($0.rawValue, forKey: WritingSettings.focusScopeKey, defaults) }
        let range = EditorView.typewriterRange
        slider("Typewriter line:", range: Double(range.lowerBound)...Double(range.upperBound), step: 0.05,
               get: Double(WritingSettings.typewriterFraction(defaults)),
               format: { "\(Int(($0 * 100).rounded())) %" }) {
            WritingSettings.set($0, forKey: WritingSettings.typewriterFractionKey, defaults)
        }
        checkbox("Ease typewriter scrolling", get: WritingSettings.typewriterEases(defaults)) {
            WritingSettings.set($0, forKey: WritingSettings.typewriterEaseKey, defaults)
        }
        note("How far down the window typewriter mode (F9) holds the caret line.")
    }
}
