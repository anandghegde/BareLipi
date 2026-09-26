import AppKit
import LipiCore
import LipiEditor
import LipiLayout
import Testing
@testable import LipiApp

@Suite("Window chrome: status bar")
@MainActor
struct ChromeTests {
    private func window(_ text: String) -> DocumentWindowController {
        let controller = EditorController(text: text, viewportWidth: 800)
        return DocumentWindowController(controller: controller, theme: .paper, contentRect: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    @Test func formatNamesDocumentAndSelection() {
        let doc = TextCounts(words: 1234, characters: 6789, charactersExcludingSpaces: 5601)
        #expect(StatusBar.format(document: doc, selection: nil, wordsPerMinute: 275)
            == "1,234 words  ·  6,789 characters (5,601 without spaces)  ·  5 min read")
        let sel = TextCounts(words: 1, characters: 5, charactersExcludingSpaces: 5)
        #expect(StatusBar.format(document: doc, selection: sel, wordsPerMinute: 275)
            == "1 of 1,234 words  ·  5 characters (5 without spaces)  ·  1 min read")
        #expect(StatusBar.format(document: .zero, selection: nil, wordsPerMinute: 275)
            == "0 words  ·  0 characters (0 without spaces)  ·  0 min read")
    }

    @Test func statusBarFollowsEditsAndSelection() {
        let wc = window("# Hello\n\nOne two three.\n")
        wc.counts.update()
        #expect(wc.chrome.statusBar.text.hasPrefix("4 words"))
        wc.controller.moveCaret(to: wc.controller.count)
        wc.controller.insert(" Four")
        wc.counts.update()
        #expect(wc.chrome.statusBar.text.hasPrefix("5 words"))
        wc.controller.select(9..<16)
        wc.counts.update()
        #expect(wc.chrome.statusBar.text.hasPrefix("2 of 5 words"))
    }

    @Test func statusBarSitsBelowTheContent() {
        let wc = window("x")
        wc.chrome.layoutSubtreeIfNeeded()
        #expect(wc.chrome.statusBar.frame.minY == 600 - StatusBar.height)
        #expect(wc.content.frame.height == 600 - StatusBar.height)
        wc.chrome.isStatusBarHidden = true
        wc.chrome.layoutSubtreeIfNeeded()
        #expect(wc.content.frame.height == 600)
    }

    // MARK: Outline (§6.8)

    @Test func outlineShowsHeadingsAndFollowsTheCaret() {
        let text = "# A\n\n- [x] one\n- [ ] two\n\n### C\n\n- [x] three\n\n## B\n\ntext\n"
        let wc = window(text)
        #expect(!wc.isOutlineVisible)
        wc.toggleOutline(nil)
        #expect(wc.isOutlineVisible)
        let pane = wc.outlineSidebar
        #expect(pane.outline.items.map(\.title) == ["A", "C", "B"])
        #expect(pane.visibleItems == [0, 1, 2])
        #expect(pane.tasks.map(\.done) == [2, 1, 0])
        #expect(pane.tasks.map(\.total) == [3, 1, 0])
        wc.chrome.layoutSubtreeIfNeeded()
        #expect(pane.frame.width == 240)
        #expect(wc.content.frame.minX == 240)

        wc.controller.moveCaret(to: text.utf8.count - 2)
        pane.update()
        #expect(pane.outlineView.selectedRow == 2)
        pane.maxLevel = 2
        #expect(pane.visibleItems == [0, 2])
        pane.filter = "c"
        #expect(pane.visibleItems == [1])
        pane.filter = ""

        wc.jumpToHeading(1)
        #expect(wc.controller.selection.head == text.utf8.count - "### C\n\n- [x] three\n\n## B\n\ntext\n".utf8.count)
    }

    @Test func outlineTracksEditsAndRestores() {
        let wc = window("# One\n\ntext\n")
        wc.setOutlineVisible(true, focus: false)
        wc.controller.moveCaret(to: wc.controller.count)
        wc.controller.insert("\n## Two\n")
        wc.outlineSidebar.update()
        #expect(wc.outlineSidebar.outline.items.map(\.title) == ["One", "Two"])
        let state = wc.editorState()
        #expect(state.showsOutline == true)
        let other = window("# X\n")
        other.apply(state)
        #expect(other.isOutlineVisible)
        var hidden = state
        hidden.showsOutline = false
        other.apply(hidden)
        #expect(!other.isOutlineVisible)
    }
}

@Suite("Window chrome: zoom")
@MainActor
struct ZoomTests {
    @Test func zoomStepsTenPercentWithinRange() {
        let controller = EditorController(text: (0..<200).map { "Line \($0)\n" }.joined(), viewportWidth: 800)
        let wc = DocumentWindowController(controller: controller, theme: .paper, contentRect: NSRect(x: 0, y: 0, width: 800, height: 600))
        let height = controller.lineHeight
        wc.zoomIn(nil)
        #expect(abs(controller.zoom - 1.1) < 0.001)
        #expect(controller.lineHeight > height)
        for _ in 0..<20 { wc.zoomIn(nil) }
        #expect(abs(controller.zoom - 2.0) < 0.001)
        for _ in 0..<30 { wc.zoomOut(nil) }
        #expect(abs(controller.zoom - 0.6) < 0.001)
        wc.resetZoom(nil)
        #expect(abs(controller.zoom - 1) < 0.001)
        let item = NSMenuItem(title: "Actual Size", action: #selector(DocumentWindowController.resetZoom(_:)), keyEquivalent: "0")
        #expect(!wc.validateMenuItem(item))
    }
}
