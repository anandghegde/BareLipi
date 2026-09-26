import AppKit
import LipiCore
import LipiEditor
import Testing
@testable import LipiApp

/// LipiDocument against real files: open, save, external changes.
@Suite("LipiDocument")
@MainActor
struct DocumentTests {
    func open(_ url: URL) throws -> LipiDocument {
        let document = LipiDocument()
        try document.read(from: url, ofType: "net.daringfireball.markdown")
        document.fileURL = url
        document.fileType = "net.daringfireball.markdown"
        document.makeWindowControllers()
        return document
    }

    @Test(arguments: TextCodecTests.fixtures.map(\.0))
    func openAndSaveIsByteIdentical(_ name: String) throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("\(name).md")
        let original = Data(TextCodecTests.fixtures.first { $0.0 == name }!.1)
        try original.write(to: url)
        let document = try open(url)
        defer { document.close() }
        try document.writeSafely(to: url, ofType: "net.daringfireball.markdown", for: .saveOperation)
        #expect(try Data(contentsOf: url) == original)
        #expect(document.fingerprint?.sha256 == FileFingerprint.hash(original))
    }

    @Test func editedCRLFFileKeepsItsLineEndings() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("crlf.md")
        try Data([0xEF, 0xBB, 0xBF] + Array("a\r\nb\r\n".utf8)).write(to: url)
        let document = try open(url)
        defer { document.close() }
        let controller = document.windowController!.controller
        controller.moveCaret(to: controller.count)
        controller.insert("c")
        #expect(document.isDocumentEdited)
        try document.writeSafely(to: url, ofType: "net.daringfireball.markdown", for: .saveOperation)
        #expect(try Data(contentsOf: url) == Data([0xEF, 0xBB, 0xBF] + Array("a\r\nb\r\nc".utf8)))
    }

    @Test func nonUTF8IsReadOnlyWithConversionBanner() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("latin1.md")
        let latin1 = Data([0x63, 0x61, 0x66, 0xE9, 0x0A])
        try latin1.write(to: url)
        let document = try open(url)
        defer { document.close() }
        #expect(document.isReadOnly)
        let bar = try #require(document.windowController?.content.bar(.encoding))
        #expect(bar.actionTitles == ["Convert to UTF-8"])
        try document.writeSafely(to: url, ofType: "net.daringfireball.markdown", for: .saveOperation)
        #expect(try Data(contentsOf: url) == latin1, "unconverted: original bytes")
        bar.perform("Convert to UTF-8")
        #expect(!document.isReadOnly)
        try document.writeSafely(to: url, ofType: "net.daringfireball.markdown", for: .saveOperation)
        #expect(try Data(contentsOf: url) == Data("café\n".utf8))
    }

    @Test func cleanDocumentReloadsSilentlyWithCaretRemapped() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("doc.md")
        try bytes("one\ntwo\nthree\n").write(to: url)
        let document = try open(url)
        defer { document.close() }
        let controller = document.windowController!.controller
        controller.moveCaret(to: 9)  // "t|hree"
        let theirs = bytes("zero\none\ntwo\nthree\n")
        try theirs.write(to: url)
        let fingerprint = FileFingerprint(stat: try FileStat.of(path: url.path), bytes: theirs)
        document.handle(.modified(bytes: theirs, fingerprint: fingerprint))
        #expect(controller.rope.string == "zero\none\ntwo\nthree\n")
        #expect(controller.selection.head == 14)
        #expect(!document.isDocumentEdited)
        #expect(document.windowController?.content.bars.isEmpty == true)
    }

    @Test func editedDocumentShowsConflictBar() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("doc.md")
        try bytes("mine\n").write(to: url)
        let document = try open(url)
        defer { document.close() }
        let controller = document.windowController!.controller
        controller.moveCaret(to: 4)
        controller.insert("!")
        let theirs = bytes("theirs\n")
        try theirs.write(to: url)
        let fingerprint = FileFingerprint(stat: try FileStat.of(path: url.path), bytes: theirs)
        document.handle(.modified(bytes: theirs, fingerprint: fingerprint))
        let bar = try #require(document.windowController?.content.bar(.externalChange))
        #expect(bar.message == "Changed on disk by another application")
        #expect(bar.actionTitles == ["Keep Mine", "Take Theirs", "Merge"])
        #expect(controller.rope.string == "mine!\n", "nothing replaced until the user chooses")
        bar.perform("Take Theirs")
        #expect(controller.rope.string == "theirs\n")
        #expect(!document.isDocumentEdited)
        #expect(document.windowController?.content.bar(.externalChange) == nil)
    }

    @Test func deletedAndErrorBars() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("doc.md")
        try bytes("x\n").write(to: url)
        let document = try open(url)
        defer { document.close() }
        document.handle(.deleted)
        #expect(document.windowController?.content.bar(.deleted)?.actionTitles == ["Save As…", "Close"])
        #expect(throws: (any Error).self) {
            try document.writeSafely(to: url, ofType: "net.daringfireball.markdown", for: .autosaveInPlaceOperation)
        }
        document.handle(.unreadable(message: "The volume is not available."))
        #expect(document.windowController?.content.bar(.fileError)?.actionTitles == ["Retry"])
        let moved = dir.file("moved.md")
        document.handle(.moved(to: moved))
        #expect(document.fileURL == moved)
    }

    @Test func restorableStateIsEncodedByTheDocument() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("doc.md")
        try bytes((0..<200).map { "line \($0)\n" }.joined()).write(to: url)
        let document = try open(url)
        defer { document.close() }
        document.windowController!.controller.moveCaret(to: 500)
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        document.encodeRestorableState(with: archiver)
        archiver.finishEncoding()
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        unarchiver.requiresSecureCoding = false
        #expect(RestorableEditorState.decode(from: unarchiver)?.head == 500)
    }

    @Test func documentConfiguration() {
        #expect(LipiDocument.autosavesInPlace)
        #expect(!LipiDocument.autosavesDrafts)
        #expect(LipiDocument.preservesVersions)
        #expect(NSStringFromClass(LipiDocument.self) == "LipiDocument")
    }
}
