import AppKit
import Foundation
import LipiEditor
import Testing
@testable import LipiApp

/// The window shown before the document controller starts, and its
/// adoption by the first document (launch budget, PRD §9.1).
@Suite("Early first window")
@MainActor
struct EarlyWindowTests {
    func defaults() -> (UserDefaults, String) {
        let name = "LipiAppTests.EarlyWindow.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    // MARK: Policy

    @Test func showsUnlessTurnedOffOrWindowsMayBeRestored() {
        let (d, name) = defaults(); defer { d.removePersistentDomain(forName: name) }
        #expect(EarlyWindow.shouldShow(defaults: d))
        EarlyWindow.noteRestorableWindow(defaults: d)
        #expect(!EarlyWindow.shouldShow(defaults: d), "a file window was on screen when the process ended")
        d.set(true, forKey: "ApplePersistenceIgnoreState")
        #expect(EarlyWindow.shouldShow(defaults: d), "restoration is skipped")
        d.set(false, forKey: EarlyWindow.enabledKey)
        #expect(!EarlyWindow.shouldShow(defaults: d))
    }

    @Test func cleanQuitRecordsWhetherWindowsComeBack() {
        let (d, name) = defaults(); defer { d.removePersistentDomain(forName: name) }
        EarlyWindow.noteRestorableWindow(defaults: d)
        EarlyWindow.noteTermination(keepsWindows: false, hasFileWindows: true, defaults: d)
        #expect(EarlyWindow.shouldShow(defaults: d))
        EarlyWindow.noteTermination(keepsWindows: true, hasFileWindows: false, defaults: d)
        #expect(EarlyWindow.shouldShow(defaults: d), "untitled documents do not restore")
        EarlyWindow.noteTermination(keepsWindows: true, hasFileWindows: true, defaults: d)
        #expect(!EarlyWindow.shouldShow(defaults: d))
    }

    // MARK: Adoption

    @Test func untitledDocumentAdoptsTheWindowAsDrawn() {
        defer { EarlyWindow.reset() }
        let early = EarlyWindow.makePending(text: "# Launch text\n")
        let document = LipiDocument()
        defer { document.close() }
        document.makeWindowControllers()
        #expect(document.windowController === early.windowController)
        #expect(document.windowControllers.count == 1)
        #expect(early.windowController.document === document)
        #expect(document.windowController?.controller.rope.string == "# Launch text\n")
        #expect(early.windowController.window?.isRestorable == true)
        #expect(!document.isDocumentEdited)
        #expect(EarlyWindow.pending == nil)
        // Edits now reach the document.
        early.windowController.controller.insert("x")
        #expect(document.isDocumentEdited)
    }

    @Test func documentOpenedAtLaunchLoadsItsTextIntoTheWindow() throws {
        defer { EarlyWindow.reset() }
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("opened.md")
        try bytes("# Opened from Finder\n\nbody\n").write(to: url)
        let early = EarlyWindow.makePending(text: "")
        let document = try openDocument(url)
        defer { document.close() }
        #expect(document.windowController === early.windowController)
        #expect(document.windowController?.controller.rope.string == "# Opened from Finder\n\nbody\n")
        #expect(document.windowController?.controller.documentURL == url)
        #expect(!document.isDocumentEdited)
        // The next document makes its own window.
        let second = LipiDocument()
        defer { second.close() }
        second.makeWindowControllers()
        #expect(second.windowController !== early.windowController)
    }

    @Test func typedTextIsNeverReplacedByAnOpenedFile() throws {
        defer { EarlyWindow.reset() }
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("opened.md")
        try bytes("file\n").write(to: url)
        let early = EarlyWindow.makePending(text: "")
        early.windowController.controller.insert("typed")
        #expect(early.isEdited)
        let opened = try openDocument(url)
        defer { opened.close() }
        #expect(opened.windowController !== early.windowController)
        #expect(EarlyWindow.pending === early)
        // Settling makes the typed text an edited untitled document.
        var made: LipiDocument?
        let outcome = EarlyWindow.settleNow(hasDocuments: true) { made = LipiDocument(); return made }
        defer { made?.close() }
        #expect(outcome == .adopted)
        #expect(made?.windowController === early.windowController)
        #expect(made?.windowController?.controller.rope.string == "typed")
        #expect(made?.isDocumentEdited == true)
    }

    @Test func settlingAWindowNobodyAdopted() {
        defer { EarlyWindow.reset() }
        #expect(EarlyWindow.settleNow(hasDocuments: false) { nil } == .none)

        // Other documents opened (restored windows): the window closes.
        EarlyWindow.makePending(text: "")
        #expect(EarlyWindow.settleNow(hasDocuments: true) { Issue.record("no document expected"); return nil } == .closed)
        #expect(EarlyWindow.pending == nil)

        // Nothing opened at all: it becomes the untitled document.
        let early = EarlyWindow.makePending(text: "")
        var made: LipiDocument?
        #expect(EarlyWindow.settleNow(hasDocuments: false) { made = LipiDocument(); return made } == .adopted)
        defer { made?.close() }
        #expect(made?.windowController === early.windowController)
        #expect(made?.isDocumentEdited == false)

        // Typed in, and no document can be made: it stays.
        let typed = EarlyWindow.makePending(text: "")
        typed.windowController.controller.insert("keep me")
        #expect(EarlyWindow.settleNow(hasDocuments: true) { nil } == .kept)
        #expect(EarlyWindow.pending === typed)
    }
}
