import AppKit
import Foundation
@testable import LipiEditor
import LipiHighlight
import LipiLayout
import Testing

@Suite("Code highlighting in the editor (P0-05)")
@MainActor
struct CodeHighlightEditorTests {
    @Test func landingHighlightsRedrawWithoutAPipelineRun() {
        let controller = EditorController(text: "Intro.\n\n```python\ndef unique_name_for_editor_test(): return 1\n```\n")
        var redraws = 0
        var changes = 0
        controller.onRedisplay = { redraws += 1 }
        controller.onChange = { _ in changes += 1 }
        _ = controller.layout.layoutIfNeeded(in: 0...800)
        let height = controller.contentHeight
        HighlightService.shared.waitUntilIdle()
        controller.highlightsDidChange()
        #expect(redraws == 1)
        #expect(changes == 0)
        #expect(controller.contentHeight == height)
    }

    @Test func documentsWithoutCodeIgnoreHighlightResults() {
        let controller = EditorController(text: "Just prose.\n")
        var redraws = 0
        controller.onRedisplay = { redraws += 1 }
        controller.highlightsDidChange()
        #expect(redraws == 0)
    }
}
