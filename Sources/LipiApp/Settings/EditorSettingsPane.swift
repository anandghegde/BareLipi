import AppKit
import LipiEditor

/// Settings → Editing: auto-pairing, the emphasis marker Cmd-I writes, the
/// hard-break style Shift-Enter writes, table completion, and the default
/// code block wrap and line numbers.
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
    }
}
