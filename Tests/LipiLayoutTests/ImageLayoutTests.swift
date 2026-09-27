import CoreGraphics
import CoreText
import Foundation
import ImageIO
import LipiCore
@testable import LipiLayout
import Testing
import UniformTypeIdentifiers

/// Writes a `width`×`height` PNG into a fresh temporary folder.
func writePNG(width: Int, height: Int, name: String = "pic.png") throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lipi-images-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(dest))
    return url
}

@Suite("Image islands in layout (P0-07)")
struct ImageLayoutTests {
    func size(_ image: DisplayImage, pixels: CGSize?, column: CGFloat = 600, zoom: CGFloat = 1) -> CGSize {
        LayoutEngine.imageSize(for: image, pixels: pixels, column: column, zoom: zoom)
    }

    @Test("an image is drawn at its pixel size, scaled down to fit the column")
    func naturalSize() {
        let image = DisplayImage(source: "x.png")
        #expect(size(image, pixels: CGSize(width: 200, height: 100)) == CGSize(width: 200, height: 100))
        #expect(size(image, pixels: CGSize(width: 1200, height: 600)) == CGSize(width: 600, height: 300))
        #expect(size(image, pixels: CGSize(width: 200, height: 100), zoom: 1.5) == CGSize(width: 300, height: 150))
        #expect(size(image, pixels: CGSize(width: 3000, height: 10)) == CGSize(width: 600, height: 2))
    }

    @Test("width and height keep the aspect ratio when only one is set")
    func widthAndHeight() {
        let pixels = CGSize(width: 400, height: 200)
        #expect(size(DisplayImage(source: "x", width: .pixels(300)), pixels: pixels) == CGSize(width: 300, height: 150))
        #expect(size(DisplayImage(source: "x", height: .pixels(50)), pixels: pixels) == CGSize(width: 100, height: 50))
        #expect(size(DisplayImage(source: "x", width: .pixels(120), height: .pixels(90)), pixels: pixels) == CGSize(width: 120, height: 90))
        #expect(size(DisplayImage(source: "x", width: .percent(50)), pixels: pixels) == CGSize(width: 300, height: 150))
        // Too wide: scaled down as a whole.
        #expect(size(DisplayImage(source: "x", width: .pixels(1200), height: .pixels(100)), pixels: pixels) == CGSize(width: 600, height: 50))
    }

    @Test("zoom scales the picture, then it is fitted to the column")
    func zoom() {
        let pixels = CGSize(width: 400, height: 200)
        #expect(size(DisplayImage(source: "x", zoom: 50), pixels: pixels) == CGSize(width: 200, height: 100))
        #expect(size(DisplayImage(source: "x", zoom: 50, width: .pixels(300)), pixels: pixels) == CGSize(width: 150, height: 75))
        #expect(size(DisplayImage(source: "x", zoom: 300), pixels: pixels) == CGSize(width: 600, height: 300))
    }

    @Test("with no pixel size yet the estimate uses the tag's sizes, else 16:9")
    func estimate() {
        #expect(size(DisplayImage(source: "x"), pixels: nil) == CGSize(width: 320, height: 180))
        #expect(size(DisplayImage(source: "x"), pixels: nil, column: 160) == CGSize(width: 160, height: 90))
        #expect(size(DisplayImage(source: "x", width: .pixels(200), height: .pixels(50)), pixels: nil) == CGSize(width: 200, height: 50))
    }

    @Test("a folded island: one line as wide as the picture on its bottom edge")
    func foldedLayout() throws {
        let file = try writePNG(width: 240, height: 120)
        let store = ImageStore()
        store.postsNotifications = false
        let base = ImageBase(documentDirectory: file.deletingLastPathComponent())
        let doc = Doc("![a cat](pic.png)\n\nafter", caret: 22)
        let block = doc.block()
        let image = try #require(block.image)
        let typesetter = makeTypesetter()

        let pending = LayoutEngine.layout(block, typesetter: typesetter, measure: 600, wideWidth: 600, images: store, imageBase: base)
        #expect(pending.image?.content == .placeholder)
        store.waitUntilIdle()
        #expect(store.status(of: image, base: base) == .ready(CGSize(width: 240, height: 120)))
        #expect(store.bitmap(of: image, base: base) != nil)

        let ready = LayoutEngine.layout(block, typesetter: typesetter, measure: 600, wideWidth: 600, images: store, imageBase: base)
        let chrome = try #require(ready.image)
        #expect(chrome.content == .picture)
        #expect(chrome.frame.size == CGSize(width: 240, height: 120))
        #expect(ready.height >= 120)
        let cell = try #require(ready.cells.first)
        #expect(cell.lines.count == 1)
        #expect(approximately(cell.usedWidth, 240, within: 1), "the U+FFFC reserves the picture's width")
        let cellFrame = ready.cellFrames[0]
        #expect(approximately(cellFrame.maxY, chrome.frame.maxY, within: 1), "the line sits on the picture's bottom edge")
    }

    @Test("a revealed island shows the source above the picture")
    func revealedLayout() throws {
        let file = try writePNG(width: 100, height: 80)
        let store = ImageStore()
        store.postsNotifications = false
        let base = ImageBase(documentDirectory: file.deletingLastPathComponent())
        let block = Doc("![a](pic.png)\n\nafter", caret: 5).block()
        #expect(block.image?.isFolded == false)
        _ = store.status(of: block.image!, base: base)
        store.waitUntilIdle()
        let layout = LayoutEngine.layout(block, typesetter: makeTypesetter(), measure: 600, wideWidth: 600, images: store, imageBase: base)
        let chrome = try #require(layout.image)
        #expect(chrome.frame.size == CGSize(width: 100, height: 80))
        #expect(chrome.frame.minY > layout.cellFrames[0].maxY)
        #expect(chrome.sourceHeight > 0)
        #expect(approximately(layout.height, chrome.frame.maxY + layout.style.paddingY))
    }

    @Test("a missing file or a remote image shows the alt text")
    func missingAndRemote() throws {
        let store = ImageStore()
        store.postsNotifications = false
        let base = ImageBase(documentDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("lipi-none-\(UUID().uuidString)"))
        let missing = Doc("![Chart of sales](nowhere.png)\n\nafter", caret: 40).block()
        _ = store.status(of: missing.image!, base: base)
        store.waitUntilIdle()
        #expect(store.status(of: missing.image!, base: base) == .failed)
        let layout = LayoutEngine.layout(missing, typesetter: makeTypesetter(), measure: 600, wideWidth: 600, images: store, imageBase: base)
        let chrome = try #require(layout.image)
        #expect(chrome.content == .alt)
        let label = try #require(chrome.label)
        #expect(CTLineGetStringRange(label).length > "Chart of sales".utf16.count)
        #expect(chrome.frame.height > 0 && chrome.frame.width <= 600)

        let remote = Doc("![logo](https://example.com/l.png)\n\nafter", caret: 45).block()
        #expect(store.status(of: remote.image!, base: base) == .remote)
        #expect(store.bitmap(of: remote.image!, base: base) == nil)
        let remoteLayout = LayoutEngine.layout(remote, typesetter: makeTypesetter(), measure: 600, wideWidth: 600, images: store, imageBase: base)
        #expect(remoteLayout.image?.content == .alt)
    }

    @Test("a file that is not an image falls back to the alt text")
    func undecodable() throws {
        let dir = try writePNG(width: 1, height: 1).deletingLastPathComponent()
        try Data("not an image".utf8).write(to: dir.appendingPathComponent("bad.png"))
        let store = ImageStore()
        store.postsNotifications = false
        let image = DisplayImage(source: "bad.png", alt: "Bad")
        let base = ImageBase(documentDirectory: dir)
        _ = store.status(of: image, base: base)
        store.waitUntilIdle()
        #expect(store.status(of: image, base: base) == .failed)
    }

    @Test("the bitmap cache stays within its limits and keeps sizes")
    func boundedCache() throws {
        let dir = try writePNG(width: 64, height: 64, name: "0.png").deletingLastPathComponent()
        let data = try Data(contentsOf: dir.appendingPathComponent("0.png"))
        for i in 1..<6 { try data.write(to: dir.appendingPathComponent("\(i).png")) }
        let store = ImageStore()
        store.postsNotifications = false
        store.countLimit = 2
        let base = ImageBase(documentDirectory: dir)
        for i in 0..<6 { _ = store.status(of: DisplayImage(source: "\(i).png"), base: base) }
        store.waitUntilIdle()
        #expect(store.cachedBitmapCount <= 2)
        for i in 0..<6 {
            #expect(store.status(of: DisplayImage(source: "\(i).png"), base: base) == .ready(CGSize(width: 64, height: 64)))
        }
        // An evicted bitmap is decoded again on demand.
        #expect(store.bitmap(of: DisplayImage(source: "0.png"), base: base) == nil)
        store.waitUntilIdle()
        #expect(store.bitmap(of: DisplayImage(source: "0.png"), base: base) != nil)
    }

    @Test("root-relative sources resolve under the root folder")
    func rootRelative() throws {
        let file = try writePNG(width: 30, height: 20)
        let root = file.deletingLastPathComponent()
        let store = ImageStore()
        store.postsNotifications = false
        let base = ImageBase(documentDirectory: root.appendingPathComponent("sub"), root: root)
        let image = DisplayImage(source: "/pic.png")
        _ = store.status(of: image, base: base)
        store.waitUntilIdle()
        #expect(store.status(of: image, base: base) == .ready(CGSize(width: 30, height: 20)))
    }

    @Test("the document layout re-lays an island when its picture lands")
    @MainActor
    func documentLayoutPicksUpDecodes() throws {
        let file = try writePNG(width: 300, height: 150)
        let store = ImageStore()
        store.postsNotifications = false
        let doc = Doc("para\n\n![a](pic.png)\n\nafter", caret: 0)
        let layout = makeLayout(doc)
        layout.images = store
        layout.imageBase = ImageBase(documentDirectory: file.deletingLastPathComponent())
        let before = layout.ensureLayout(1).blocks[0]
        #expect(before.image?.content == .placeholder)
        store.waitUntilIdle()
        #expect(layout.imageLayoutsAreStale())
        _ = layout.invalidateImageBlocks()
        let after = layout.ensureLayout(1).blocks[0]
        #expect(after.image?.content == .picture)
        #expect(after.image?.frame.size == CGSize(width: 300, height: 150))
        #expect(!layout.imageLayoutsAreStale())
        let frame = try #require(layout.imageFrame(entry: 1, block: 0))
        #expect(frame.width == 300 && frame.height == 150)
    }
}
