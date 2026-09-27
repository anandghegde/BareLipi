import AppKit
import ImageIO
import LipiEditor
import Testing
import UniformTypeIdentifiers
@testable import LipiApp

/// A `width`×`height` image encoded as `type`, with EXIF `orientation`.
func imageData(width: Int, height: Int, type: UTType = .png, orientation: Int = 1) -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    _ = CGImageDestinationFinalize(dest)
    return out as Data
}

/// Pixel size (before orientation) and type of encoded image `data`.
func pixelSize(_ data: Data) -> (width: Int, height: Int, type: String)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
          let type = CGImageSourceGetType(source) as String? else { return nil }
    return (w, h, type)
}

private func controls<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    view.subviews.flatMap { sub in ((sub as? T).map { [$0] } ?? []) + controls(type, in: sub) }
}

@Suite("Downscale on paste (P0-07)")
@MainActor
struct PasteDownscaleTests {
    @Test func wideImagesAreScaledDownKeepingFormatAndRatio() throws {
        let png = imageData(width: 1600, height: 900)
        let small = try #require(AssetPolicy.downscale(png, ext: "png", maxWidth: 800))
        let size = try #require(pixelSize(small))
        #expect(size.width == 800 && size.height == 450 && size.type == UTType.png.identifier)

        let jpeg = imageData(width: 1000, height: 500, type: .jpeg)
        let smallJPEG = try #require(AssetPolicy.downscale(jpeg, ext: "jpg", maxWidth: 400))
        let jpegSize = try #require(pixelSize(smallJPEG))
        #expect(jpegSize.width == 400 && jpegSize.height == 200 && jpegSize.type == UTType.jpeg.identifier)
    }

    @Test func narrowImagesOffAndUnwritableFormatsAreKept() {
        let png = imageData(width: 600, height: 300)
        #expect(AssetPolicy.downscale(png, ext: "png", maxWidth: 800) == nil)
        #expect(AssetPolicy.downscale(png, ext: "png", maxWidth: 600) == nil)
        #expect(AssetPolicy.downscale(imageData(width: 2000, height: 10), ext: "png", maxWidth: 0) == nil, "0 is off")
        #expect(AssetPolicy.downscale(Data("not an image".utf8), ext: "png", maxWidth: 10) == nil)
        #expect(AssetPolicy.downscale(png, ext: "webp", maxWidth: 100) == nil, "ImageIO cannot write WebP")
    }

    @Test func theWidthIsMeasuredAfterEXIFOrientation() throws {
        // Stored 400×1200 but rotated a quarter turn: displayed 1200 wide.
        let rotated = imageData(width: 400, height: 1200, type: .jpeg, orientation: 6)
        let small = try #require(AssetPolicy.downscale(rotated, ext: "jpg", maxWidth: 600))
        let size = try #require(pixelSize(small))
        #expect(size.width == 600 && size.height == 200, "the orientation is applied to the pixels")
        // Stored 1200×400 displayed 400 wide: kept.
        #expect(AssetPolicy.downscale(imageData(width: 1200, height: 400, type: .jpeg, orientation: 6), ext: "jpg", maxWidth: 600) == nil)
    }

    @Test func pastedAndDroppedImagesAreDownscaledWhenSet() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let docURL = dir.file("doc.md")
        let store = AssetStore(unsavedRoot: dir.file("Unsaved"), documentURL: { docURL }, text: { "" })
        store.maxWidth = 500
        let dropped = dir.file("wide.png")
        try imageData(width: 1000, height: 400).write(to: dropped)
        let paths = try store.store([ImagePayload(.data(imageData(width: 2000, height: 1000), type: UTType.png.identifier)),
                                     ImagePayload(.file(dropped)),
                                     ImagePayload(.data(imageData(width: 300, height: 100), type: UTType.png.identifier))])
        #expect(paths.count == 3)
        let sizes = paths.compactMap { pixelSize(try! Data(contentsOf: dir.url.appendingPathComponent($0))) }
        #expect(sizes.map(\.width) == [500, 500, 300])
        #expect(sizes.map(\.height) == [250, 200, 100])
    }

    @Test func offByDefault() throws {
        let defaults = UserDefaults(suiteName: "PasteDownscale-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        #expect(settings.imageMaxWidth == 0)
        settings.imageMaxWidth = 1200
        #expect(settings.imageMaxWidth == 1200)
        #expect(AppSettings.Key.imageMaxWidth == AssetStore.maxWidthKey)
        #expect(AppSettings.imageMaxWidths.first == 0)
    }

    @Test func theImagesPaneOffersTheWidths() throws {
        let defaults = UserDefaults(suiteName: "PasteDownscalePane-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.imageMaxWidth = 1600
        let pane = ImagesSettingsPane(settings: settings)
        let popup = try #require(controls(NSPopUpButton.self, in: pane.view).first { $0.itemTitles.contains("1600 px wide") })
        #expect(popup.titleOfSelectedItem == "1600 px wide")
        popup.selectItem(withTitle: "Off (keep full size)")
        _ = popup.target?.perform(popup.action, with: popup)
        #expect(settings.imageMaxWidth == 0)
    }

    @Test func theEditorResolvesImagesAgainstTheDocumentsFolder() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("doc.md")
        try Data("![a](pic.png)\n".utf8).write(to: url)
        let document = try openDocument(url)
        defer { document.close() }
        let controller = try #require(document.windowController?.editor.controller)
        #expect(controller.layout.imageBase.documentDirectory?.path == dir.url.path)
        let moved = dir.file("sub/doc.md")
        document.fileURL = moved
        #expect(controller.documentURL == moved)
        #expect(controller.layout.imageBase.documentDirectory?.path == dir.file("sub").path)
    }
}
