import AppKit
import LipiCore
import LipiEditor
import Testing
@testable import LipiApp

// MARK: - Find bar

@Suite("Find bar")
@MainActor
struct FindBarTests {
    @Test func showSearchReplaceAndClose() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("doc.md")
        try bytes("cat and cat and cat\n").write(to: url)
        let document = try openDocument(url)
        defer { document.close() }
        let wc = try #require(document.windowController)
        let bar = wc.showFindBar(replace: false)
        #expect(wc.content.accessory === bar)
        #expect(wc.findBar === bar)
        bar.findField.stringValue = "cat"
        bar.queryChanged(move: true)
        #expect(bar.session.count == 3)
        #expect(bar.countLabel.stringValue == "1 of 3")
        bar.findNext(nil)
        #expect(bar.countLabel.stringValue == "2 of 3")
        bar.findField.stringValue = "dog"
        bar.queryChanged(move: true)
        #expect(bar.countLabel.stringValue == "No results")

        bar.findField.stringValue = "cat"
        bar.queryChanged(move: true)
        wc.showFindAndReplace(nil)
        #expect(bar.showsReplace)
        #expect(bar.intrinsicContentSize.height == FindBar.rowHeight * 2)
        bar.replaceField.stringValue = "cow"
        bar.replaceAll(nil)
        #expect(bar.countLabel.stringValue == "Replaced 3")
        #expect(wc.controller.string == "cow and cow and cow\n")
        #expect(document.isDocumentEdited)

        bar.close(nil)
        #expect(wc.content.accessory == nil)
        #expect(!bar.session.isActive)
        // Cmd-G keeps working with the bar closed, on the last search.
        wc.controller.undo()
        wc.controller.moveCaret(to: 0)
        wc.findNextMatch(nil)
        #expect(wc.controller.selection.range == 0..<3)
    }

    @Test func seedsFromTheSelection() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("doc.md")
        try bytes("alpha beta alpha\n").write(to: url)
        let document = try openDocument(url)
        defer { document.close() }
        let wc = try #require(document.windowController)
        wc.controller.select(6..<10)
        let bar = wc.showFindBar(replace: false)
        #expect(bar.findField.stringValue == "beta")
        #expect(bar.session.count == 1)
    }

    @Test func statusStrings() {
        let s = FindSession(controller: EditorController(text: "a a"))
        #expect(FindBar.status(of: s) == "")
        s.query = FindQuery("a")
        #expect(FindBar.status(of: s) == "2 matches")
        s.query = FindQuery("[", isRegex: true)
        #expect(FindBar.status(of: s) == "Invalid pattern")
    }
}
