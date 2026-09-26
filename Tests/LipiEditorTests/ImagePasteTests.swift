import AppKit
import LipiCore
@testable import LipiEditor
import Testing
import UniformTypeIdentifiers

/// A 2×2 PNG.
func tinyPNG() -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .png, properties: [:])!
}

@MainActor
final class MockImageHandler: EditorImageHandler {
    var received: [[ImagePayload]] = []
    var paths: [String]
    init(paths: [String]) { self.paths = paths }
    func importImages(_ images: [ImagePayload]) -> [String] {
        received.append(images)
        return Array(paths.prefix(images.count))
    }
    func linkPath(forExistingImage url: URL) -> String { "rel/" + url.lastPathComponent }
}

@Suite("Image paste and drop")
@MainActor
struct ImagePasteTests {
    func board() -> NSPasteboard {
        let p = NSPasteboard(name: .init("lipi-test-\(UUID().uuidString)"))
        p.clearContents()
        return p
    }

    @Test func readsImageDataAndFiles() {
        let p = board()
        p.setData(tinyPNG(), forType: .png)
        #expect(EditorView.images(on: p) == [ImagePayload(.data(tinyPNG(), type: UTType.png.identifier))])

        // Image files, in order.
        p.clearContents()
        let a = URL(fileURLWithPath: "/tmp/a.png"), b = URL(fileURLWithPath: "/tmp/b b.jpeg")
        p.writeObjects([a as NSURL, b as NSURL])
        #expect(EditorView.images(on: p) == [ImagePayload(.file(a)), ImagePayload(.file(b))])

        // A non-image file among them: not an image paste.
        p.clearContents()
        p.writeObjects([a as NSURL, URL(fileURLWithPath: "/tmp/notes.md") as NSURL])
        #expect(EditorView.images(on: p).isEmpty)

        // Text offered first wins over a picture.
        p.clearContents()
        let item = NSPasteboardItem()
        item.setString("hello", forType: .string)
        item.setData(tinyPNG(), forType: .png)
        p.writeObjects([item])
        #expect(EditorView.images(on: p).isEmpty)
    }

    @Test func linkDestinations() {
        #expect(EditorView.linkDestination("assets/a.png") == "assets/a.png")
        #expect(EditorView.linkDestination("my assets/a (1).png") == "<my assets/a (1).png>")
        #expect(EditorView.imageMarkdown(["a.png", "b c.png"]) == "![](a.png)\n![](<b c.png>)")
    }

    @Test func pasteInsertsLinksAsOneUndoStep() {
        let view = makeView("Before after")
        let handler = MockImageHandler(paths: ["assets/x.png", "assets/y z.png"])
        view.imageHandler = handler
        view.controller.select(7..<12)  // "after"
        let p = board()
        p.writeObjects([URL(fileURLWithPath: "/tmp/x.png") as NSURL, URL(fileURLWithPath: "/tmp/y.png") as NSURL])
        #expect(view.pasteImages(from: p))
        #expect(handler.received.count == 1 && handler.received[0].count == 2)
        #expect(view.controller.string == "Before ![](assets/x.png)\n![](<assets/y z.png>)")
        view.controller.undo()
        #expect(view.controller.string == "Before after")
    }

    @Test func noImagesFallsThrough() {
        let view = makeView("x")
        view.imageHandler = MockImageHandler(paths: ["a.png"])
        let p = board()
        p.setString("text", forType: .string)
        #expect(!view.pasteImages(from: p))
        #expect(view.controller.string == "x")
    }

    @Test func refusedWhenNotEditable() {
        let view = makeView("x")
        let handler = MockImageHandler(paths: ["a.png"])
        view.imageHandler = handler
        var refused = 0
        view.controller.onRefusedEdit = { refused += 1 }
        view.isEditable = false
        let p = board()
        p.setData(tinyPNG(), forType: .png)
        #expect(view.pasteImages(from: p))
        #expect(handler.received.isEmpty, "nothing copied into the document's folder")
        #expect(view.controller.string == "x")
        #expect(refused == 1)
    }

    @Test func readOnlyControllerRefusesEveryEdit() {
        let c = EditorController(text: "abc")
        c.insert("1")
        #expect(c.canUndo)
        var refused = 0
        c.onRefusedEdit = { refused += 1 }
        c.isEditable = false
        #expect(!c.canUndo)
        c.insert("x")
        c.replace(0..<1, with: "y")
        c.perform(EditPlan(edits: [Edit(replacing: 0..<0, with: "z")], anchor: 0, head: 0))
        c.undo()
        c.setMarkedText("k", selected: NSRange(location: 1, length: 0))
        #expect(c.string == "1abc")
        #expect(refused == 5)
        c.isEditable = true
        c.undo()
        #expect(c.string == "abc")
    }
}
