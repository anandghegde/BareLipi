import AppKit
import CoreGraphics
import ImageIO
import LipiCore
@testable import LipiEditor
import LipiLayout
import Testing
import UniformTypeIdentifiers

@Suite("Images drawn inline (P0-07)")
@MainActor
struct InlineImageTests {
    /// A folder holding a `width`×`height` `pic.png`.
    func folder(width: Int = 200, height: Int = 100) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lipi-inline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent("pic.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))
        return dir
    }

    func view(_ text: String, in dir: URL, store: ImageStore) -> EditorView {
        let view = makeView(text)
        view.controller.layout.images = store
        view.controller.documentURL = dir.appendingPathComponent("doc.md")
        return view
    }

    func store() -> ImageStore {
        let store = ImageStore()
        store.postsNotifications = false
        return store
    }

    @Test func documentURLAndRootURLSetTheImageBase() throws {
        let dir = try folder()
        let view = view("---\ntypora-root-url: ../site\n---\n\n![a](/pic.png)\n", in: dir, store: store())
        let base = view.controller.layout.imageBase
        #expect(base.documentDirectory?.standardizedFileURL == dir.standardizedFileURL)
        #expect(base.root?.standardizedFileURL.path == dir.appendingPathComponent("../site").standardizedFileURL.path)
        view.controller.documentURL = nil
        #expect(view.controller.layout.imageBase == ImageBase())
    }

    @Test func aDecodedImageIsLaidOutAtItsSize() throws {
        let dir = try folder(width: 200, height: 100)
        let images = store()
        let view = view("Intro.\n\n![red](pic.png)\n\nOutro.\n", in: dir, store: images)
        view.controller.moveCaret(to: 0)
        _ = view.controller.layout.ensureLayout(1)
        images.waitUntilIdle()
        var changed = false
        view.controller.onImagesChanged = { changed = true }
        view.controller.imagesDidLoad()
        #expect(changed)
        let frame = try #require(view.controller.layout.imageFrame(entry: 1, block: 0))
        #expect(frame.size == CGSize(width: 200, height: 100))
    }

    @Test func theCaretGoesBeforeOrAfterAFoldedPicture() throws {
        let dir = try folder(width: 200, height: 100)
        let images = store()
        let text = "Intro.\n\n![red](pic.png)\n\nOutro.\n"
        let view = view(text, in: dir, store: images)
        _ = view.controller.layout.ensureLayout(1)
        images.waitUntilIdle()
        view.controller.imagesDidLoad()
        let layout = view.controller.layout
        let frame = try #require(layout.imageFrame(entry: 1, block: 0))
        let start = 8, end = 8 + "![red](pic.png)".utf8.count
        #expect(layout.sourceOffset(at: CGPoint(x: frame.minX + 20, y: frame.midY)) == start)
        #expect(layout.sourceOffset(at: CGPoint(x: frame.maxX - 20, y: frame.midY)) == end)
        #expect(layout.sourceOffset(at: CGPoint(x: frame.maxX + 40, y: frame.maxY - 4)) == end)
    }

    @Test func imagesAreAccessibilityChildrenWithTheirAltText() throws {
        let dir = try folder()
        let view = view("Intro.\n\n![A red square](pic.png)\n\n<img src=\"pic.png\" style=\"zoom:50%;\">\n\n![](https://x.org/a.png)\n",
                        in: dir, store: store())
        let images = view.accessibilityIslands(all: true).filter { $0.accessibilityRole() == .image }
        #expect(images.map { $0.accessibilityLabel() } == ["A red square", "Image", "Image"])
        #expect(images.allSatisfy { $0.accessibilityParent() as? EditorView === view })
        #expect(images[0].accessibilityFrame().width > 0)
    }

    @Test func sourceModeShowsNoPictures() throws {
        let dir = try folder()
        let view = view("![a](pic.png)\n\n<img src=\"pic.png\">\n", in: dir, store: store())
        #expect(view.accessibilityIslands(all: true).count == 2)
        view.controller.toggleSourceMode()
        #expect(view.accessibilityIslands(all: true).isEmpty)
        #expect(view.controller.projection.entries.allSatisfy { $0.blocks.allSatisfy { $0.image == nil } })
    }
}
