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
}
