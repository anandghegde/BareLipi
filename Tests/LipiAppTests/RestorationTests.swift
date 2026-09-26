import AppKit
import LipiEditor
import LipiLayout
import Testing
@testable import LipiApp

@Suite("Restorable state and notice bars")
@MainActor
struct RestorationTests {
    @Test func stateRoundTripsThroughAKeyedArchiver() throws {
        let state = RestorableEditorState(anchor: 12, head: 40, scrollAnchor: 300, scrollOffset: 7.5)
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        state.encode(to: archiver)
        archiver.finishEncoding()
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        unarchiver.requiresSecureCoding = true
        #expect(RestorableEditorState.decode(from: unarchiver) == state)
    }

    @Test func missingStateDecodesToNil() throws {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.finishEncoding()
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        #expect(RestorableEditorState.decode(from: unarchiver) == nil)
    }

    @Test func stateIsClampedToTheText() {
        let s = RestorableEditorState(anchor: 500, head: -3, scrollAnchor: 900, scrollOffset: 1).clamped(to: 100)
        #expect(s.anchor == 100)
        #expect(s.head == 0)
        #expect(s.scrollAnchor == 100)
    }

    @Test func windowControllerAppliesAndReportsState() {
        let text = (0..<400).map { "Line \($0) of the document.\n" }.joined()
        let controller = EditorController(text: text, viewportWidth: 800)
        let wc = DocumentWindowController(controller: controller, theme: .taalegari, contentRect: NSRect(x: 0, y: 0, width: 800, height: 600))
        let target = RestorableEditorState(anchor: 2000, head: 2010, scrollAnchor: 0, scrollOffset: 1500)
        wc.apply(target)
        let state = wc.editorState()
        #expect(state.anchor == 2000)
        #expect(state.head == 2010)
        #expect(wc.scrollY > 1000)
        // Re-applying the reported state lands on the same viewport.
        let y = wc.scrollY
        wc.scroll(toY: 0)
        wc.apply(state)
        #expect(abs(wc.scrollY - y) < 2)
        #expect(wc.window?.tabbingMode == .preferred)
    }

    @Test func reloadRemapsCaretAndKeepsScroll() {
        let text = (0..<300).map { "Line \($0)\n" }.joined()
        let controller = EditorController(text: text, viewportWidth: 800)
        let wc = DocumentWindowController(controller: controller, theme: .taalegari, contentRect: NSRect(x: 0, y: 0, width: 800, height: 600))
        let caret = text.utf8.distance(from: text.startIndex, to: text.range(of: "Line 250\n")!.lowerBound) + 5  // before "250"
        controller.moveCaret(to: caret)
        wc.scroll(toY: 2000)
        let y = wc.scrollY
        wc.reload(text: "# Added on disk\n\n" + text)
        let new = Array(controller.rope.string.utf8)
        #expect(String(decoding: new[controller.selection.head...], as: UTF8.self).hasPrefix("250\n"))
        #expect(abs(wc.scrollY - y) < 1)
    }

    @Test func noticeBarsStackAndRunActions() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let content = DocumentContentView(scrollView: scroll, frame: scroll.frame)
        var taken = ""
        content.show(NoticeBar(kind: .externalChange, message: "Changed on disk by another application", actions: [
            NoticeBar.Action("Keep Mine") { taken = "mine" },
            NoticeBar.Action("Take Theirs") { taken = "theirs" },
            NoticeBar.Action("Merge", isEnabled: false) { taken = "merge" },
        ]))
        content.show(NoticeBar(kind: .encoding, message: "enc", actions: []))
        content.layout()
        #expect(content.bars.map(\.kind) == [.externalChange, .encoding])
        #expect(scroll.frame.minY == NoticeBar.height * 2)
        let bar = content.bar(.externalChange)!
        #expect(bar.actionTitles == ["Keep Mine", "Take Theirs", "Merge"])
        bar.perform("Merge")
        #expect(taken == "")
        bar.perform("Take Theirs")
        #expect(taken == "theirs")
        content.hide(.externalChange)
        content.layout()
        #expect(content.bars.count == 1)
        #expect(scroll.frame.minY == NoticeBar.height)
    }
}
