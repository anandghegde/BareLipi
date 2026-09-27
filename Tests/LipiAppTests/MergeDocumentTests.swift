import AppKit
import LipiCore
import LipiEditor
import Testing
@testable import LipiApp

/// The conflict bar's Merge (P1-04) against real files.
@Suite("Three-way merge in the document")
@MainActor
struct MergeDocumentTests {
    /// Writes `theirs` to the file and delivers it as an external change.
    func change(_ document: LipiDocument, _ url: URL, to theirs: Data) throws {
        try theirs.write(to: url)
        let fingerprint = FileFingerprint(stat: try FileStat.of(path: url.path), bytes: theirs)
        document.handle(.modified(bytes: theirs, fingerprint: fingerprint))
    }

    @Test func cleanMergeIsOneUndoStepAndKeepsTheCaret() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("doc.md")
        try bytes("a\nb\nc\nd\ne\n").write(to: url)
        let document = try openDocument(url)
        defer { document.close() }
        let controller = document.windowController!.controller
        controller.moveCaret(to: 1)
        controller.insert("!")
        controller.moveCaret(to: 7)  // "|d"
        let theirs = bytes("a\nb\nC1\nC2\nd\ne\n")
        try change(document, url, to: theirs)
        let bar = try #require(document.windowController?.content.bar(.externalChange))
        #expect(bar.actionTitles == ["Keep Mine", "Take Theirs", "Merge"])
        bar.perform("Merge")
        #expect(controller.string == "a!\nb\nC1\nC2\nd\ne\n")
        #expect(controller.selection.head == 11, "the caret stays before d")
        #expect(document.windowController?.content.bar(.externalChange) == nil)
        #expect(document.isDocumentEdited)
        #expect(document.mergeBase?.string == "a\nb\nC1\nC2\nd\ne\n")
        #expect(document.fingerprint?.sha256 == FileFingerprint.hash(theirs))
        controller.undo()
        #expect(controller.string == "a!\nb\nc\nd\ne\n", "one undo step")
        controller.redo()
        try document.writeSafely(to: url, ofType: "net.daringfireball.markdown", for: .saveOperation)
        #expect(try Data(contentsOf: url) == bytes("a!\nb\nC1\nC2\nd\ne\n"))
    }

    @Test func conflictsGetMarkersInTheDocumentsLineEnding() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("crlf.md")
        try Data([0xEF, 0xBB, 0xBF] + Array("a\r\nb\r\nc\r\n".utf8)).write(to: url)
        let document = try openDocument(url)
        defer { document.close() }
        let controller = document.windowController!.controller
        controller.moveCaret(to: 4)
        controller.insert("!")
        try change(document, url, to: Data([0xEF, 0xBB, 0xBF] + Array("a\r\nbeta\r\nc\r\n".utf8)))
        try #require(document.windowController?.content.bar(.externalChange)).perform("Merge")
        #expect(controller.string == "a\r\n<<<<<<< Mine\r\nb!\r\n=======\r\nbeta\r\n>>>>>>> Theirs\r\nc\r\n")
        let bar = try #require(document.windowController?.content.bar(.externalChange))
        #expect(bar.message.hasPrefix("Merged with 1 conflict,"))
        #expect(bar.actionTitles == ["Next Conflict", "Done"])
        #expect(controller.selection.head == 3, "the caret goes to the conflict")
        controller.moveCaret(to: controller.count)
        bar.perform("Next Conflict")
        #expect(controller.selection.head == 3, "wraps round")
        controller.undo()
        #expect(controller.string == "a\r\nb!\r\nc\r\n")
        controller.redo()
        try document.writeSafely(to: url, ofType: "net.daringfireball.markdown", for: .saveOperation)
        #expect(try Data(contentsOf: url).starts(with: [0xEF, 0xBB, 0xBF, 0x61, 0x0D, 0x0A, 0x3C]), "BOM kept")
    }

    @Test func theBaseFollowsSaves() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("doc.md")
        try bytes("1\n2\n3\n4\n5\n").write(to: url)
        let document = try openDocument(url)
        defer { document.close() }
        let controller = document.windowController!.controller
        controller.moveCaret(to: 1)
        controller.insert("!")
        try document.writeSafely(to: url, ofType: "net.daringfireball.markdown", for: .saveOperation)
        #expect(document.mergeBase?.string == "1!\n2\n3\n4\n5\n")
        controller.moveCaret(to: controller.count - 1)
        controller.insert("!")
        // Another app reverts line 1 and edits line 3 of the saved file.
        try change(document, url, to: bytes("1\n2\nthree\n4\n5\n"))
        try #require(document.windowController?.content.bar(.externalChange)).perform("Merge")
        #expect(controller.string == "1\n2\nthree\n4\n5!\n")
    }

    @Test func keepMineMakesTheirsTheBase() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("doc.md")
        try bytes("1\n2\n3\n4\n5\n").write(to: url)
        let document = try openDocument(url)
        defer { document.close() }
        let controller = document.windowController!.controller
        controller.moveCaret(to: 1)
        controller.insert("!")
        try change(document, url, to: bytes("1\n2\n3\n4\nfive\n"))
        try #require(document.windowController?.content.bar(.externalChange)).perform("Keep Mine")
        #expect(document.mergeBase?.string == "1\n2\n3\n4\nfive\n")
        try change(document, url, to: bytes("1\n2\nthree\n4\nfive\n"))
        try #require(document.windowController?.content.bar(.externalChange)).perform("Merge")
        #expect(controller.string == "1!\n2\nthree\n4\n5\n", "mine's 5 still wins over their earlier five")
    }

    @Test func mergeIsDisabledForNonUTF8Theirs() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("doc.md")
        try bytes("cafe\n").write(to: url)
        let document = try openDocument(url)
        defer { document.close() }
        let controller = document.windowController!.controller
        controller.insert("x")
        try change(document, url, to: Data([0x63, 0x61, 0x66, 0xE9, 0x0A]))
        let bar = try #require(document.windowController?.content.bar(.externalChange))
        bar.perform("Merge")
        #expect(controller.string == "xcafe\n")
        #expect(document.windowController?.content.bar(.externalChange) != nil)
    }
}
