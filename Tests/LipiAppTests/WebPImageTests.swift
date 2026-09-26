import AppKit
import ImageIO
import LipiCore
import LipiEditor
import LipiExport
import Testing
import UniformTypeIdentifiers
@testable import LipiApp

/// A 1×1 lossless WebP (ImageIO decodes WebP but cannot write it).
func webpData() -> Data {
    Data(base64Encoded: "UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==")!
}

@Suite("WebP images and resized images (P0-07)")
@MainActor
struct WebPImageTests {
    @Test func fixtureIsAWebPImageIODecodes() throws {
        let source = try #require(CGImageSourceCreateWithData(webpData() as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.webP.identifier)
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width == 1)
    }

    @Test func webPIsKeptAsIs() throws {
        let (data, ext) = try #require(AssetPolicy.encode(webpData(), type: .webP))
        #expect(data == webpData() && ext == "webp")
        let fromFile = try #require(UTType(filenameExtension: "webp"))
        #expect(AssetPolicy.encode(webpData(), type: fromFile)?.ext == "webp")
    }

    @Test func pasteboardWebPIsAnImage() {
        let p = NSPasteboard(name: .init("lipi-test-\(UUID().uuidString)"))
        p.clearContents()
        let type = NSPasteboard.PasteboardType(UTType.webP.identifier)
        p.setData(webpData(), forType: type)
        #expect(EditorView.images(on: p) == [ImagePayload(.data(webpData(), type: UTType.webP.identifier))])
        p.clearContents()
        let file = URL(fileURLWithPath: "/tmp/shot.webp")
        p.writeObjects([file as NSURL])
        #expect(EditorView.images(on: p) == [ImagePayload(.file(file))])
    }

    @Test func pasteAndDropStoreWebPBesideTheDocument() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("doc.md")
        try bytes("Text\n").write(to: url)
        let document = try openDocument(url)
        defer { document.close() }
        let original = dir.file("Pic.webp")
        try webpData().write(to: original)
        let paths = document.importImages([ImagePayload(.file(original)),
                                           ImagePayload(.data(webpData(), type: UTType.webP.identifier))])
        #expect(paths.count == 2 && paths[0] == paths[1], "identical bytes reuse one file")
        #expect(paths[0].hasPrefix("assets/") && paths[0].hasSuffix(".webp"))
        #expect(try Data(contentsOf: dir.url.appendingPathComponent(paths[0])) == webpData())
        document.assets.naming = .original
        #expect(document.importImages([ImagePayload(.file(original))]) == ["assets/Pic.webp"])
    }

    @Test func untitledWebPMovesOnFirstSave() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let document = LipiDocument()
        document.fileType = "net.daringfireball.markdown"
        document.makeWindowControllers()
        defer { document.close() }
        document.assets = AssetStore(unsavedRoot: dir.file("Unsaved"), documentURL: { [weak document] in document?.fileURL },
                                     text: { "" })
        let wc = try #require(document.windowController)
        let paths = document.importImages([ImagePayload(.data(webpData(), type: UTType.webP.identifier))])
        #expect(paths.count == 1 && paths[0].hasSuffix(".webp") && paths[0].contains("/Unsaved/"))
        wc.controller.insert(EditorView.imageMarkdown(paths) + "\n")
        let url = dir.file("saved.md")
        try document.writeSafely(to: url, ofType: "net.daringfireball.markdown", for: .saveAsOperation)
        let name = (paths[0] as NSString).lastPathComponent
        #expect(try String(contentsOf: url, encoding: .utf8) == "![](assets/\(name))\n")
        #expect(try Data(contentsOf: dir.file("assets/\(name)")) == webpData())
    }

    @Test func exportLinksCopiesAndEmbedsWebPAndKeepsZoom() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let docs = dir.url.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs.appendingPathComponent("img"), withIntermediateDirectories: true)
        try webpData().write(to: docs.appendingPathComponent("img/a.webp"))
        let markdown = "![w](img/a.webp)\n\n<img src=\"img/a.webp\" alt=\"z\" style=\"zoom:50%;\" />\n\nand <img alt=\"i\" src=\"img/a.webp\" width=\"20\"> inline\n"
        let exporter = HTMLExporter(highlighter: nil)
        let out = dir.url.appendingPathComponent("out/Doc.html")

        let linked = exporter.export(markdown: markdown, title: "Doc",
                                     images: ImageExport(mode: .reference, documentDirectory: docs, outputURL: out))
        #expect(linked.html.contains("<img src=\"../docs/img/a.webp\" alt=\"w\" />"))
        #expect(linked.html.contains("<img src=\"../docs/img/a.webp\" alt=\"z\" style=\"zoom:50%;\" />"))
        #expect(linked.html.contains("<img alt=\"i\" src=\"../docs/img/a.webp\" width=\"20\">"))
        #expect(linked.missingImages.isEmpty)

        let copied = exporter.export(markdown: markdown, title: "Doc",
                                     images: ImageExport(mode: .copy, documentDirectory: docs, outputURL: out))
        #expect(copied.html.contains("<img src=\"Doc_files/a.webp\" alt=\"z\" style=\"zoom:50%;\" />"))
        #expect(copied.copies.map(\.destination.lastPathComponent) == ["a.webp"])

        let embedded = exporter.export(markdown: markdown, title: "Doc",
                                       images: ImageExport(mode: .embed, documentDirectory: docs, outputURL: out))
        let uri = "data:image/webp;base64,\(webpData().base64EncodedString())"
        #expect(embedded.html.contains("<img src=\"\(uri)\" alt=\"w\" />"))
        #expect(embedded.html.contains("<img src=\"\(uri)\" alt=\"z\" style=\"zoom:50%;\" />"))
        #expect(embedded.html.contains("<img alt=\"i\" src=\"\(uri)\" width=\"20\">"))
    }

    @Test func resizedImageExportsWithItsZoom() {
        let c = EditorController(text: "![shot](assets/s.webp)\n")
        c.setImageZoom(67, at: 3)
        let html = HTMLExporter(highlighter: nil).body(markdown: c.string)
        #expect(html.contains("<img src=\"assets/s.webp\" alt=\"shot\" style=\"zoom:67%;\" />"))
    }
}
