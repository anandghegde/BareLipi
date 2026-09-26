import AppKit
import LipiCore
import LipiEditor
import Testing
@testable import LipiApp

// MARK: - Locked documents

@Suite("Read-only and locked documents")
@MainActor
struct LockedDocumentTests {
    @Test func lockedDocumentRefusesEditsAndOffersUnlock() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("locked.md")
        try bytes("hello\n").write(to: url)
        let document = try openDocument(url)
        defer { document.close() }
        let wc = try #require(document.windowController)
        document.setFileLocked(true)
        #expect(document.isReadOnly)
        #expect(!wc.editor.isEditable)
        let bar = try #require(wc.content.bar(.locked))
        #expect(bar.actionTitles == ["Unlock", "Duplicate"])
        wc.content.hide(.locked)
        wc.controller.insert("x")
        #expect(wc.controller.string == "hello\n")
        #expect(!document.isDocumentEdited)
        #expect(wc.content.bar(.locked) != nil, "a refused edit brings the bar back")
        document.setFileLocked(false)
        #expect(wc.editor.isEditable)
        #expect(wc.content.bar(.locked) == nil)
    }

    @Test func finderLockedFileOpensLockedAndUnlocks() throws {
        let dir = try TempDirectory()
        let url = dir.file("uchg.md")
        try bytes("hello\n").write(to: url)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path)
            dir.cleanUp()
        }
        #expect(LipiDocument.isLocked(url))
        let document = try openDocument(url)
        defer { document.close() }
        let wc = try #require(document.windowController)
        #expect(document.isFileLocked)
        #expect(!wc.editor.isEditable)
        try #require(wc.content.bar(.locked)).perform("Unlock")
        #expect(!LipiDocument.isLocked(url))
        #expect(!document.isFileLocked)
        #expect(wc.editor.isEditable)
        wc.controller.insert("x")
        #expect(document.isDocumentEdited)
    }

    @Test func nonUTF8RefusesEditsUpFront() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("latin1.md")
        try Data([0x63, 0x61, 0x66, 0xE9, 0x0A]).write(to: url)
        let document = try openDocument(url)
        defer { document.close() }
        let wc = try #require(document.windowController)
        #expect(!wc.editor.isEditable)
        let before = wc.controller.buffer.generation
        wc.controller.insert("x")
        #expect(wc.controller.buffer.generation == before, "the buffer never changed")
        #expect(!document.isDocumentEdited)
        try #require(wc.content.bar(.encoding)).perform("Convert to UTF-8")
        #expect(wc.editor.isEditable)
    }
}
