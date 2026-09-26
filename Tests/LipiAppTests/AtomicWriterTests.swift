import Darwin
import Foundation
import Testing
@testable import LipiApp

@Suite("AtomicWriter (§9.3)")
struct AtomicWriterTests {
    func writer(_ dir: TempDirectory) -> AtomicWriter {
        var options = AtomicWriter.Options()
        options.backupDirectory = dir.file("Backups")
        return AtomicWriter(options: options)
    }

    @Test func createsNewFileWithUmaskPermissions() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("new.md")
        let outcome = try writer(dir).write(bytes("# hi\n"), to: url)
        #expect(outcome.strategy == .created)
        #expect(try Data(contentsOf: url) == bytes("# hi\n"))
        let mask = umask(0); umask(mask)
        #expect(try FileStat.of(path: url.path).mode & 0o777 == 0o666 & ~mask)
        #expect(outcome.fingerprint.sha256 == FileFingerprint.hash(bytes("# hi\n")))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.url.path).filter { $0.contains("barelipi-") }
        #expect(leftovers.isEmpty)
    }

    @Test func replaceKeepsPermissionsXattrsFlagsAndCreationDate() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("doc.md")
        try bytes("old\n").write(to: url)
        chmod(url.path, 0o640)
        ExtendedAttributes.set("com.example.tag", bytes("blue"), path: url.path)
        let created = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
        chflags(url.path, UInt32(UF_HIDDEN))
        let before = try FileStat.of(path: url.path)

        let outcome = try writer(dir).write(bytes("new\n"), to: url)

        #expect(outcome.strategy == .atomicReplace)
        #expect(try Data(contentsOf: url) == bytes("new\n"))
        let after = try FileStat.of(path: url.path)
        #expect(after.inode != before.inode, "atomic replace installs a new inode")
        #expect(after.mode & 0o7777 == 0o640)
        #expect(after.flags & UInt32(UF_HIDDEN) != 0)
        let attributes = ExtendedAttributes.read(path: url.path)
        #expect(attributes["com.example.tag"] == bytes("blue"))
        #expect(attributes["com.apple.TextEncoding"] == bytes("utf-8;134217984"))
        #expect(attributes["com.apple.quarantine"] == nil)
        let createdAfter = try FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] as? Date
        #expect(createdAfter.map { abs($0.timeIntervalSince(created)) < 1 } == true)
    }

    @Test func symlinkIsResolvedAndKept() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        try FileManager.default.createDirectory(at: dir.file("real"), withIntermediateDirectories: true)
        let target = dir.file("real/target.md")
        try bytes("a\n").write(to: target)
        let link = dir.file("link.md")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "real/target.md")

        let outcome = try writer(dir).write(bytes("b\n"), to: link)

        #expect(outcome.resolvedURL.path == target.path)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "real/target.md")
        #expect(try Data(contentsOf: target) == bytes("b\n"))
    }

    @Test func danglingSymlinkCreatesTarget() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let link = dir.file("link.md")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "missing.md")
        let outcome = try writer(dir).write(bytes("x"), to: link)
        #expect(outcome.strategy == .created)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "missing.md")
        #expect(try Data(contentsOf: dir.file("missing.md")) == bytes("x"))
    }

    @Test func hardLinkedFileIsWrittenInPlace() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("a.md"), other = dir.file("b.md")
        try bytes("one\n").write(to: url)
        #expect(link(url.path, other.path) == 0)
        let inode = try FileStat.of(path: url.path).inode

        let outcome = try writer(dir).write(bytes("two\n"), to: url)

        #expect(outcome.strategy == .inPlace)
        let after = try FileStat.of(path: url.path)
        #expect(after.inode == inode)
        #expect(after.linkCount == 2)
        #expect(try Data(contentsOf: other) == bytes("two\n"), "the other link sees the new bytes")
        // The backup is removed after a successful write.
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: dir.file("Backups").path)) ?? []
        #expect(backups.isEmpty)
    }

    @Test func hardLinkReplacePolicyBreaksTheLink() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("a.md"), other = dir.file("b.md")
        try bytes("one\n").write(to: url)
        #expect(link(url.path, other.path) == 0)
        var options = AtomicWriter.Options()
        options.hardLinks = .replaceAtomically
        options.backupDirectory = dir.file("Backups")
        let outcome = try AtomicWriter(options: options).write(bytes("two\n"), to: url)
        #expect(outcome.strategy == .atomicReplace)
        #expect(try Data(contentsOf: other) == bytes("one\n"))
    }

    @Test func unwritableDirectoryFallsBackToInPlace() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let sub = dir.file("locked")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let url = sub.appendingPathComponent("doc.md")
        try bytes("old").write(to: url)
        chmod(sub.path, 0o555)
        defer { chmod(sub.path, 0o755) }

        let outcome = try writer(dir).write(bytes("new"), to: url)

        #expect(outcome.strategy == .inPlace)
        #expect(outcome.fallbackReason != nil)
        #expect(try Data(contentsOf: url) == bytes("new"))
    }

    @Test func immutableFileIsRefused() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("locked.md")
        try bytes("keep").write(to: url)
        chflags(url.path, UInt32(UF_IMMUTABLE))
        defer { chflags(url.path, 0) }
        #expect(throws: (any Error).self) { try writer(dir).write(bytes("new"), to: url) }
        chflags(url.path, 0)
        #expect(try Data(contentsOf: url) == bytes("keep"))
    }

    @Test func uncoordinatedWriteMatchesCoordinated() throws {
        let dir = try TempDirectory(); defer { dir.cleanUp() }
        let url = dir.file("doc.md")
        try bytes("a").write(to: url)
        var options = AtomicWriter.Options()
        options.coordinate = false
        options.fullSync = true
        let outcome = try AtomicWriter(options: options).write(bytes("b"), to: url)
        #expect(outcome.strategy == .atomicReplace)
        #expect(try Data(contentsOf: url) == bytes("b"))
    }
}
