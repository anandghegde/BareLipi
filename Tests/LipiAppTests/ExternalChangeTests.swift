import Foundation
import Testing
@testable import LipiApp

@Suite("External change detection (§6.16)")
@MainActor
struct ExternalChangeTests {
    func monitor(for url: URL) throws -> ExternalChangeMonitor {
        let data = try Data(contentsOf: url)
        let known = FileFingerprint(stat: try FileStat.of(path: url.path), bytes: data)
        return ExternalChangeMonitor(url: url, known: known)
    }

    @Test func unchangedFileIsNone() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("a.md")
        try bytes("a\n").write(to: url)
        let m = try monitor(for: url)
        #expect(m.checkNow() == .none)
    }

    @Test func inPlaceModificationIsDeliveredOnce() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("a.md")
        try bytes("a\n").write(to: url)
        let m = try monitor(for: url)
        var delivered: [ExternalChange] = []
        m.onChange = { delivered.append($0) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes("more\n"))
        try handle.close()

        guard case .modified(let data, _) = m.checkNow() else { Issue.record("expected modified"); return }
        #expect(data == bytes("a\nmore\n"))
        #expect(m.checkNow() == .none, "the same change is not reported again")
        #expect(delivered.count == 1)
    }

    @Test func atomicReplacementByAnotherAppIsModified() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("a.md")
        try bytes("a\n").write(to: url)
        let m = try monitor(for: url)
        m.start(); defer { m.stop() }
        try bytes("theirs\n").write(to: url, options: .atomic)  // new inode
        guard case .modified(let data, _) = m.checkNow() else { Issue.record("expected modified"); return }
        #expect(data == bytes("theirs\n"))
    }

    @Test func touchIsMetadataOnly() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("a.md")
        try bytes("a\n").write(to: url)
        let m = try monitor(for: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: url.path)
        guard case .metadataOnly = m.checkNow() else { Issue.record("expected metadataOnly"); return }
        #expect(m.checkNow() == .none)
    }

    @Test func deletionIsDeliveredOncePerEvent() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("a.md")
        try bytes("a\n").write(to: url)
        let m = try monitor(for: url)
        var count = 0
        m.onChange = { if $0 == .deleted { count += 1 } }
        try FileManager.default.removeItem(at: url)
        #expect(m.checkNow() == .deleted)
        #expect(m.checkNow() == .none)
        #expect(count == 1)
    }

    @Test func moveIsFollowedByFileID() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("a.md"), moved = dir.file("renamed.md")
        try bytes("a\n").write(to: url)
        let m = try monitor(for: url)
        m.start(); defer { m.stop() }
        try FileManager.default.moveItem(at: url, to: moved)
        #expect(m.checkNow() == .moved(to: moved))
        #expect(m.url.path == moved.path)
        #expect(m.checkNow() == .none)
    }

    @Test func ownWritesAreIgnored() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("a.md")
        try bytes("a\n").write(to: url)
        let m = try monitor(for: url)
        m.start(); defer { m.stop() }
        var options = AtomicWriter.Options()
        options.coordinate = false
        let outcome = try AtomicWriter(options: options).write(bytes("mine\n"), to: url)
        m.acknowledge(outcome.fingerprint, url: outcome.resolvedURL)
        #expect(m.checkNow() == .none)
    }

    @Test func unreadableIsReported() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("a.md")
        try bytes("a\n").write(to: url)
        let m = try monitor(for: url)
        m.read = { _ in throw CocoaError(.fileReadNoPermission) }
        try bytes("b\n").write(to: url)
        guard case .unreadable = m.checkNow() else { Issue.record("expected unreadable"); return }
        #expect(m.checkNow() == .none, "an error is shown once per event")
    }

    @Test func vnodeEventsAreCoalescedAndDelivered() async throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("a.md")
        try bytes("a\n").write(to: url)
        let m = try monitor(for: url)
        m.coalesceInterval = 0.05
        var delivered: [ExternalChange] = []
        m.onChange = { delivered.append($0) }
        m.start(); defer { m.stop() }
        for i in 0..<3 {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes("\(i)\n"))
            try handle.close()
        }
        for _ in 0..<60 where delivered.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(delivered.count == 1)
        guard case .modified(let data, _) = delivered.first else { Issue.record("expected modified"); return }
        #expect(data == bytes("a\n0\n1\n2\n"))
    }

    @Test func trashCountsAsDeleted() {
        #expect(ExternalChangeResolver.isInTrash("/Users/x/.Trash/a.md"))
        #expect(!ExternalChangeResolver.isInTrash("/Users/x/Documents/a.md"))
    }
}

@Suite("Caret remap through a diff")
struct CaretRemapTests {
    @Test func insertionBeforeCaretShiftsIt() {
        #expect(CaretRemap.map(6, from: "hello world", to: "oh, hello world") == 10)
    }

    @Test func insertionAfterCaretKeepsIt() {
        #expect(CaretRemap.map(3, from: "hello world", to: "hello world!!!") == 3)
    }

    @Test func caretKeepsLineAndColumnWhenOtherLinesChange() {
        let old = "alpha\nbeta\ngamma\ndelta\n"
        let new = "ALPHA CHANGED\nbeta\nnew line\ngamma\ndelta\n"
        let caret = Array(old.utf8).count - "ta\n".utf8.count  // in "delta"
        let mapped = CaretRemap.map(caret, from: old, to: new)
        #expect(String(decoding: Array(new.utf8)[mapped...], as: UTF8.self) == "ta\n")
        // "gamma" line, column 2 — moved down by the inserted line.
        let g = Array(old.utf8).count - "mma\ndelta\n".utf8.count
        let mg = CaretRemap.map(g, from: old, to: new)
        #expect(String(decoding: Array(new.utf8)[mg...], as: UTF8.self) == "mma\ndelta\n")
    }

    @Test func caretInDeletedTextClampsToHunk() {
        let old = "keep\ngone line\nkeep too\n"
        let new = "keep\nkeep too\n"
        #expect(CaretRemap.map(8, from: old, to: new) == 5)
    }

    @Test func resultIsOnScalarBoundary() {
        let old = "ಕನ್ನಡ ಪಠ್ಯ"
        let new = "ಕನ್ನಡ"
        let mapped = CaretRemap.map(Array(old.utf8).count, from: old, to: new)
        #expect(mapped == Array(new.utf8).count)
        for offset in 0...Array(old.utf8).count {
            let m = CaretRemap.map(offset, from: old, to: "x" + new)
            #expect(String(Array(("x" + new).utf8)[..<m].map { Character(UnicodeScalar($0)) }).count >= 0)
            #expect(Array(("x" + new).utf8)[safe: m].map { $0 & 0xC0 != 0x80 } ?? true)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
