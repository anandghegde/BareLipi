import AppKit
import LipiCore
@testable import LipiEditor
import Testing

/// Pathologically deep documents open, lay out, read aloud and take edits
/// (the AST caps nesting; see `DeepNestingTests`).
@Suite("Deep nesting in the editor")
@MainActor
struct DeepNestingEditorTests {
    nonisolated static let docs = [
        String(repeating: "> ", count: 3_000) + "a\n" + String(repeating: "> ", count: 3_000) + "b\n",
        String(repeating: "- ", count: 3_000) + "a\n",
        String(repeating: "*a ", count: 3_000) + "b" + String(repeating: " a*", count: 3_000) + "\n",
        String(repeating: "[", count: 3_000) + "a" + String(repeating: "](u)", count: 3_000) + "\n",
    ]

    @Test(arguments: 0..<docs.count)
    func opensReadsAndEdits(_ i: Int) {
        let text = Self.docs[i]
        let view = makeView(text, width: 400)
        let value = view.accessibilityValue() as? String ?? ""
        #expect(!value.isEmpty)
        _ = view.accessibilityAttributedString(for: NSRange(location: 0, length: min(200, value.utf16.count)))
        let middle = text.utf8.count / 2
        _ = view.controller.moveCaret(to: middle)
        _ = view.controller.insert("z")
        _ = view.controller.insertNewline()
        _ = view.controller.moveCaret(to: text.utf8.count)
        _ = view.controller.insertNewline()
        #expect(view.controller.string(in: 0..<1) == String(text.prefix(1)))
        _ = view.accessibilityValue()
    }
}
