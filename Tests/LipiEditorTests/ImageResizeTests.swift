import AppKit
import LipiCore
@testable import LipiEditor
import Testing

@Suite("Image resizing (P0-07)")
@MainActor
struct ImageResizeTests {
    func offset(of needle: String, in text: String) -> Int {
        text.utf8.count - text[text.range(of: needle)!.lowerBound...].utf8.count
    }

    @Test func markdownImageBecomesAZoomedTagAsOneUndoStep() {
        let text = "Intro\r\n\r\nSee ![a *b*](<assets/p q.png> \"T \\\"x\\\"\") here\r\nEnd\r\n"
        let c = EditorController(text: text)
        c.moveCaret(to: 0)
        let at = offset(of: "a *b*", in: text)
        #expect(c.image(at: at) == ImageTarget(range: offset(of: "![", in: text)..<offset(of: " here", in: text),
                                               form: .markdown, zoom: nil, hasSize: false))
        #expect(c.setImageZoom(50, at: at) != nil)
        let tag = "<img src=\"assets/p q.png\" alt=\"a *b*\" title=\"T &quot;x&quot;\" style=\"zoom:50%;\" />"
        #expect(c.string == "Intro\r\n\r\nSee " + tag + " here\r\nEnd\r\n")
        #expect(c.selection.range == 0..<0)
        #expect(c.image(at: offset(of: "zoom", in: c.string))?.zoom == 50)
        c.undo()
        #expect(c.string == text)
    }

    @Test func tagZoomChangesOnlyTheTag() {
        let before = "A\r\n\r\n"
        let after = "\r\n\r\nB <img src=\"b.png\"> c\r\n"
        let tag = "<img width=\"300\" src=\"x.png\" STYLE='border:0; zoom: 0.5' height=200>"
        let c = EditorController(text: before + tag + after)
        let at = before.utf8.count + 6
        #expect(c.image(at: at) == ImageTarget(range: before.utf8.count..<(before + tag).utf8.count, form: .html,
                                               zoom: 50, hasSize: true))
        c.setImageZoom(67, at: at)
        #expect(c.string == before + "<img src=\"x.png\" style=\"border:0; zoom:67%;\">" + after)
        // Original keeps the other style, so the tag stays HTML.
        c.setImageZoom(nil, at: at)
        #expect(c.string == before + "<img src=\"x.png\" style=\"border:0;\">" + after)
        // The inline tag in the next paragraph.
        let inline = offset(of: "b.png", in: c.string)
        #expect(c.image(at: inline)?.form == .html)
        c.setImageZoom(25, at: inline)
        #expect(c.string.hasSuffix("\r\n\r\nB <img src=\"b.png\" style=\"zoom:25%;\"> c\r\n"))
    }

    @Test func originalSizeRoundTripsToMarkdown() {
        let text = "![alt [1]](<my pics/a.png> \"Title\")\n"
        let c = EditorController(text: text)
        c.setImageZoom(33, at: 3)
        #expect(c.string == "<img src=\"my pics/a.png\" alt=\"alt [1]\" title=\"Title\" style=\"zoom:33%;\" />\n")
        c.setImageZoom(100, at: 3)
        #expect(c.string == "<img src=\"my pics/a.png\" alt=\"alt [1]\" title=\"Title\" style=\"zoom:100%;\" />\n")
        c.setImageZoom(nil, at: 3)
        #expect(c.string == "![alt \\[1\\]](<my pics/a.png> \"Title\")\n")
        // Already original: nothing to do.
        #expect(c.setImageZoom(nil, at: 3) == nil)
        // Extra attributes keep the tag.
        let d = EditorController(text: "<img class=\"wide\" src=\"a.png\" style=\"zoom:50%\">\n")
        d.setImageZoom(nil, at: 3)
        #expect(d.string == "<img class=\"wide\" src=\"a.png\">\n")
    }

    @Test func onlyImagesAreTargets() {
        let c = EditorController(text: "[link](a.png) `![x](y.png)` <b>bold</b>\n\n<div><img src=\"z.png\"></div>\n")
        #expect(c.image(at: 2) == nil)
        #expect(c.image(at: 17) == nil)
        #expect(c.image(at: 32) == nil)
        #expect(c.setImageZoom(50, at: 2) == nil)
        let z = offset(of: "z.png", in: c.string)
        #expect(c.image(at: z)?.form == .html)
        #expect(c.image(at: offset(of: "<div>", in: c.string)) == nil)
    }

    @Test func contextMenuOffersPresetsAndApplies() throws {
        let view = makeView("Look ![](a.png) now\n")
        let menu = try #require(view.imageMenu(at: 7))
        #expect(menu.items.map(\.title) == ["Zoom 25 %", "Zoom 33 %", "Zoom 50 %", "Zoom 67 %", "Zoom 100 %", "", "Original Size"])
        #expect(menu.items.last?.state == .on)
        view.zoomImage(menu.items[2])
        #expect(view.controller.string == "Look <img src=\"a.png\" alt=\"\" style=\"zoom:50%;\" /> now\n")
        let again = try #require(view.imageMenu(at: 7))
        #expect(again.items[2].state == .on && again.items.last?.state == .off)
        #expect(view.imageMenu(at: 1) == nil)
        view.isEditable = false
        #expect(view.imageMenu(at: 7)?.items.allSatisfy { $0.isSeparatorItem || !$0.isEnabled } == true)
    }

    @Test func tagParser() throws {
        let tag = try #require(HTMLImageTag.parse("<IMG src=a.png alt='x > y' data-x\n/>"))
        #expect(tag.attributes.map(\.name) == ["src", "alt", "data-x"])
        #expect(tag.value("alt") == "x > y" && tag.value("src") == "a.png")
        #expect(tag.text == "<IMG src=a.png alt='x > y' data-x\n/>")
        #expect(HTMLImageTag.parse("<imgx src=a>") == nil)
        #expect(HTMLImageTag.parse("<img src=\"a>") == nil)
        #expect(HTMLImageTag.percent("50%") == 50 && HTMLImageTag.percent("0.25") == 25 && HTMLImageTag.percent("x") == nil)
    }
}
