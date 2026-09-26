import AppKit
import LipiCore
import LipiEditor
import Testing
import UniformTypeIdentifiers
@testable import LipiApp

func pngData() -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - Asset policy

@Suite("Image assets")
@MainActor
struct AssetTests {
    @Test func frontMatterKeys() {
        let text = "---\ntitle: x\nassets: \"img/${filename}\"\ntypora-root-url: ..\n---\n# Doc\n"
        #expect(AssetPolicy.frontMatterValue("assets", in: text) == "img/${filename}")
        #expect(AssetPolicy.frontMatterValue("typora-root-url", in: text) == "..")
        #expect(AssetPolicy.frontMatterValue("title", in: "# no front matter\ntitle: x") == nil)
        #expect(AssetPolicy.frontMatterValue("assets", in: "---\nx: 1\n---\nassets: late\n") == nil)
        // Parsed, not scanned: TOML, nested keys and malformed blocks.
        #expect(AssetPolicy.frontMatterValue("assets", in: "+++\nassets = 'toml/img'\n+++\n") == "toml/img")
        #expect(AssetPolicy.frontMatterValue("assets", in: "---\nsite:\n  assets: nested\n---\n") == nil)
        #expect(AssetPolicy.frontMatterValue("assets", in: "---\nassets: [x\n---\n") == nil)
        #expect(AssetPolicy.frontMatterValue("assets", in: "---\nassets: >-\n  folded/\n  path\n---\n") == "folded/ path")
    }

    @Test func targetFolders() {
        let doc = URL(fileURLWithPath: "/w/notes/day.md")
        #expect(AssetPolicy.targetFolder(documentURL: doc, text: "# x").path == "/w/notes/assets")
        #expect(AssetPolicy.targetFolder(documentURL: doc, text: "---\nassets: pics/${filename}\n---\n").path == "/w/notes/pics/day")
        #expect(AssetPolicy.targetFolder(documentURL: doc, text: "---\ntypora-copy-images-to: ../media\n---\n").path == "/w/media")
        #expect(AssetPolicy.targetFolder(documentURL: doc, text: "---\nassets: /abs/img\n---\n").path == "/abs/img")
    }

    @Test func linkPaths() {
        let doc = URL(fileURLWithPath: "/w/notes/day.md")
        #expect(AssetPolicy.linkPath(for: URL(fileURLWithPath: "/w/notes/assets/a.png"), documentURL: doc, text: "") == "assets/a.png")
        #expect(AssetPolicy.linkPath(for: URL(fileURLWithPath: "/w/media/a.png"), documentURL: doc, text: "") == "../media/a.png")
        #expect(AssetPolicy.linkPath(for: URL(fileURLWithPath: "/w/media/a.png"), documentURL: doc,
                                     text: "---\ntypora-root-url: ..\n---\n") == "/media/a.png")
        #expect(AssetPolicy.linkPath(for: URL(fileURLWithPath: "/x/a.png"), documentURL: nil, text: "") == "/x/a.png")
    }

    @Test func namingAndCollisions() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second) = (2026, 9, 26, 14, 25, 1)
        let date = Calendar.current.date(from: parts)!
        let name = AssetPolicy.timestampName(date: date, data: Data("x".utf8), ext: "png")
        #expect(name.hasPrefix("2026-09-26-142501-") && name.hasSuffix(".png") && name.count == "2026-09-26-142501-abcdef.png".count)
        try Data("one".utf8).write(to: dir.file("a.png"))
        #expect(AssetPolicy.unusedURL(for: "a.png", in: dir.url, data: Data("one".utf8)) == (dir.file("a.png"), true))
        #expect(AssetPolicy.unusedURL(for: "a.png", in: dir.url, data: Data("two".utf8)).url == dir.file("a-1.png"))
    }

    @Test func tiffBecomesPNG() throws {
        let tiff = try #require(NSImage(data: pngData())?.tiffRepresentation)
        let (data, ext) = try #require(AssetPolicy.encode(tiff, type: .tiff))
        #expect(ext == "png")
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(AssetPolicy.encode(pngData(), type: .png)?.ext == "png")
    }

    @Test func pasteIntoSavedDocumentCopiesBesideIt() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("doc.md")
        try bytes("Text\n").write(to: url)
        let document = try openDocument(url)
        defer { document.close() }
        let wc = try #require(document.windowController)
        let original = dir.file("My Shot.png")
        try pngData().write(to: original)
        let paths = document.importImages([ImagePayload(.file(original)), ImagePayload(.data(pngData(), type: UTType.png.identifier))])
        #expect(paths.count == 2)
        #expect(paths.allSatisfy { $0.hasPrefix("assets/") && $0.hasSuffix(".png") })
        #expect(paths[0] == paths[1], "identical bytes reuse one file")
        #expect(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent(paths[0]).path))
        document.assets.naming = .original
        #expect(document.importImages([ImagePayload(.file(original))]) == ["assets/My Shot.png"])
        #expect(document.linkPath(forExistingImage: dir.file("pics/p.jpg")) == "pics/p.jpg")
        _ = wc
    }

    @Test func untitledImagesMoveOnFirstSave() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let document = LipiDocument()
        document.fileType = "net.daringfireball.markdown"
        document.makeWindowControllers()
        defer { document.close() }
        document.assets = AssetStore(unsavedRoot: dir.file("Unsaved"), documentURL: { [weak document] in document?.fileURL },
                                     text: { "" })
        let wc = try #require(document.windowController)
        let paths = document.importImages([ImagePayload(.data(pngData(), type: UTType.png.identifier))])
        #expect(paths.count == 1 && paths[0].hasPrefix("/") && paths[0].contains("/Unsaved/"), "absolute while untitled")
        wc.controller.insert("Look: " + EditorView.imageMarkdown(paths) + "\n")
        let url = dir.file("saved.md")
        try document.writeSafely(to: url, ofType: "net.daringfireball.markdown", for: .saveAsOperation)
        let saved = try String(contentsOf: url, encoding: .utf8)
        let name = (paths[0] as NSString).lastPathComponent
        #expect(saved == "Look: ![](assets/\(name))\n")
        #expect(FileManager.default.fileExists(atPath: dir.file("assets/\(name)").path))
        #expect(!FileManager.default.fileExists(atPath: paths[0]))
    }
}
