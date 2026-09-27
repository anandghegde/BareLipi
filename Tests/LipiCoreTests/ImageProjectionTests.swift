import Foundation
import Testing
@testable import LipiCore

@Suite("Projection: image islands (P0-07)")
struct ImageProjectionTests {
    @Test("an image-only paragraph folds to one U+FFFC carrying the image")
    func markdownImageFolds() throws {
        let block = displayBlock("![a cat](img/cat.png \"Tabby\")")
        #expect(block.cells[0].text == "\u{FFFC}")
        let image = try #require(block.image)
        #expect(image.source == "img/cat.png" && image.alt == "a cat" && image.title == "Tabby")
        #expect(image.isFolded && image.zoom == nil && image.width == nil)
    }

    @Test("the caret in the image reveals its source in link stages; the picture stays")
    func caretReveals() throws {
        let text = "![a cat](cat.png)\n\nafter"
        let expected = [0: "![a cat]\u{FFFC}", 5: "![a cat]\u{FFFC}", 11: "![a cat](cat.png)", 17: "![a cat]\u{FFFC}"]
        for (caret, shown) in expected {
            let block = project(text, caret: caret).entries[0].blocks[0]
            #expect(block.cells[0].text == shown, "caret \(caret)")
            let image = try #require(block.image)
            #expect(!image.isFolded)
        }
        let away = project(text, caret: 22).entries[0].blocks[0]
        #expect(away.cells[0].text == "\u{FFFC}" && away.image?.isFolded == true)
    }

    @Test("an <img> tag with zoom, width and height becomes an island")
    func htmlImage() throws {
        let block = displayBlock("<img src=\"a%20b.png\" alt=\"Chart\" style=\"zoom:50%;\" width=\"300\">")
        let image = try #require(block.image)
        #expect(image.source == "a%20b.png" && image.alt == "Chart")
        #expect(image.zoom == 50 && image.width == .pixels(300) && image.height == nil)
        #expect(block.cells[0].text == "\u{FFFC}")
        let styled = try #require(DisplayImage(htmlTag: "<img src='x.png' style='width: 40%; height:120px'>", isFolded: true))
        #expect(styled.width == .percent(40) && styled.height == .pixels(120))
        #expect(DisplayImage(htmlTag: "<img alt='no src'>", isFolded: true) == nil)
        #expect(DisplayImage(htmlTag: "<div>", isFolded: true) == nil)
    }

    @Test("the caret in an <img> block reveals the tag")
    func htmlImageReveals() {
        let block = project("<img src=\"x.png\">\n\nafter", caret: 3).entries[0].blocks[0]
        #expect(block.cells[0].text == "<img src=\"x.png\">")
        #expect(block.image?.isFolded == false)
    }

    @Test("an image among text stays in the text; a remote one is an island")
    func notIslands() {
        #expect(displayBlock("see ![a](x.png) here").image == nil)
        #expect(displayBlock("![a](x.png) ![b](y.png)").image == nil)
        #expect(displayBlock("![logo](https://example.com/l.png)").image?.isRemote == true)
    }

    @Test("source mode shows the Markdown, no islands")
    func sourceMode() {
        let (p, _, _) = project("![a](x.png)\n\n<img src=\"y.png\">", reveal: .everything)
        #expect(p.entries.allSatisfy { $0.blocks.allSatisfy { $0.image == nil } })
        #expect(p.displayText.contains("![a](x.png)"))
    }

    @Test("folded images keep the projection's tiling and round trip")
    func invariants() {
        for text in ["![a](x.png)", "para\n\n![a](x.png \"t\")\n\n<img src=x.png>\n", "  <img src=\"x\" width=10>\n"] {
            var checker = ProjectionChecker(text)
            checker.check(project(text).0)
            for caret in 0...text.utf8.count { checker.check(project(text, caret: caret)) }
            #expect(checker.failures.isEmpty, "\(text): \(checker.failures)")
        }
    }

    @Test("the layout key changes with the image")
    func layoutKey() {
        #expect(displayBlock("![a](x.png)").layoutKey != displayBlock("![a](y.png)").layoutKey)
    }

    @Test("lengths, labels and remote sources")
    func details() {
        #expect(ImageLength("300") == .pixels(300))
        #expect(ImageLength(" 300px ") == .pixels(300))
        #expect(ImageLength("50%") == .percent(50))
        #expect(ImageLength("auto") == nil && ImageLength("0") == nil)
        #expect(DisplayImage(source: "dir/my%20pic.png").label == "my pic.png")
        #expect(DisplayImage(source: "x.png", alt: "Alt").label == "Alt")
        #expect(DisplayImage(source: "//cdn/x.png").isRemote && !DisplayImage(source: "x.png").isRemote)
    }

    @Test("root-relative paths resolve under typora-root-url")
    func resolving() {
        let doc = URL(fileURLWithPath: "/docs/notes", isDirectory: true)
        let root = ImageSource.rootDirectory("../site", documentDirectory: doc)
        let rooted = URL(fileURLWithPath: "/docs/site/img/a.png").standardizedFileURL
        let exists: (URL) -> Bool = { $0.standardizedFileURL == rooted }
        #expect(ImageSource.resolve("/img/a.png", documentDirectory: doc, root: root, fileExists: exists)?.standardizedFileURL == rooted)
        #expect(ImageSource.resolve("a.png", documentDirectory: doc, root: root, fileExists: exists) == URL(fileURLWithPath: "/docs/notes/a.png"))
        #expect(ImageSource.resolve("/img/a.png", documentDirectory: doc, root: nil, fileExists: exists) == URL(fileURLWithPath: "/img/a.png"))
        #expect(ImageSource.resolve("https://x/a.png", documentDirectory: doc, root: root) == nil)
    }
}
