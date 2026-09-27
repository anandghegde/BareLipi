import Foundation
import LipiApp
import LipiFixtures
import Testing

/// The Phase 1 byte-preservation exit check (`ByteRoundTrip`) over the
/// corpus (`ByteCorpus`): every file opens and saves to the exact bytes
/// through `LipiDocument`, views and settings never touch the buffer, and
/// random editing commands change only the bytes their edits declare, with
/// undo restoring the original exactly. `swift run lipi-roundtrip <dir>`
/// runs the same check over any folder.
@Suite("Byte-preservation corpus")
@MainActor
struct ByteCorpusTests {
    nonisolated static let documents: [CorpusFile] = (try? ByteCorpus.documents()) ?? []
    nonisolated static let specExamples: [CorpusFile] = (try? ByteCorpus.specExamples()) ?? []
    nonisolated static let byName: [String: CorpusFile] = Dictionary(
        (documents + specExamples).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

    static let scratch: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lipi-corpus-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func check(_ name: String, _ options: ByteRoundTrip.Options) throws -> ByteCheckReport {
        let file = try #require(Self.byName[name])
        let report = ByteRoundTrip.check(name: name, data: file.data, options: options, scratch: Self.scratch)
        #expect(report.failures.isEmpty, Comment(rawValue: report.failures.joined(separator: "\n")))
        return report
    }

    @Test func corpusIsComplete() {
        #expect(Self.documents.count >= 100)
        #expect(Self.specExamples.count >= 1000)
        let names = Set(Self.documents.map(\.name))
        for expected in ["typora.md", "variants/typora.crlf.md", "variants/tables.cr.md", "variants/scripts.bom.md",
                         "generated/nul-in-structures.md", "generated/invalid-ff.md", "generated/long-line-256k.md",
                         "pathological/nested-quotes-1000.md"] {
            #expect(names.contains(expected), "missing \(expected)")
        }
        #expect(Self.documents.contains { !$0.isUTF8 })
    }

    /// Checked-in files, their byte variants, generated edge cases and the
    /// pathological fixtures: the full check, 40 random edits each.
    @Test(arguments: documents.map(\.name))
    func document(_ name: String) throws {
        #if DEBUG
        // A debug build's projector overflows the 8 MB main-thread stack
        // on ~900 nested containers (release handles 1000; README).
        if name == "pathological/nested-quotes-1000.md" {
            let file = try #require(Self.byName[name])
            #expect(ByteRoundTrip.checkCodec(file.data).isEmpty)
            return
        }
        #endif
        let file = try #require(Self.byName[name])
        let options = file.data.count > Self.heavy ? Self.heavyOptions : ByteRoundTrip.Options(steps: 40)
        let report = try check(name, options)
        if report.readOnly || options.steps == 0 {
            #expect(report.editsTried == 0)
        } else {
            #expect(report.editsTried > 0)
        }
    }

    /// Files over 64 KB (the 1 MB paragraph, the 256 KB line, 10,000
    /// reference definitions, …) re-typeset a huge block per edit: minutes
    /// each even in release, far more in debug. Here a debug build checks
    /// their decode → encode only, a release build the document, the views
    /// and a few edits; `swift run -c release lipi-roundtrip --corpus` runs
    /// them in full.
    static let heavy = 64 * 1024
    #if DEBUG
    static let heavyOptions = ByteRoundTrip.Options(steps: 0, document: false, views: false)
    #else
    static let heavyOptions = ByteRoundTrip.Options(steps: 4, render: false)
    #endif

    /// Every CommonMark / GFM spec example as a file: open → save, views,
    /// and a few edits (the documents above cover edits in depth).
    @Test(arguments: specExamples.map(\.name))
    func specExample(_ name: String) throws {
        _ = try check(name, ByteRoundTrip.Options(steps: 6, render: false))
    }
}
