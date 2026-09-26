import Foundation
import Testing
@testable import LipiCore

/// Conformance: HTML output must match the spec suites byte for byte, the way
/// cmark-gfm's own `spec_tests.py --no-normalize` checks its binary.
@Suite("Spec suites")
struct SpecTests {
    static let gfmGlobal = ["table", "strikethrough", "autolink", "tagfilter", "footnotes", "tasklist"]

    static func run(_ fixture: String, expectedCount: Int, global: [String] = []) throws {
        let examples = try SpecFixtures.load(fixture)
        #expect(examples.count == expectedCount, "\(fixture): loaded \(examples.count) examples")
        var failures: [String] = []
        for example in examples {
            let actual = LipiParser.renderHTML(example.markdown, extensions: example.extensions + global)
            // `<IGNORE>` marks examples whose output the upstream runner does not check.
            if example.html.trimmingCharacters(in: .whitespacesAndNewlines) == "<IGNORE>" { continue }
            if actual != example.html {
                failures.append("""
                    example \(example.number) (\(example.section), line \(example.line), extensions \(example.extensions)):
                    --- markdown ---
                    \(example.markdown.debugDescription)
                    --- expected ---
                    \(example.html.debugDescription)
                    --- actual ---
                    \(actual.debugDescription)
                    """)
            }
        }
        let report = "\(fixture): \(failures.count) of \(examples.count) failed\n" + failures.prefix(8).joined(separator: "\n")
        #expect(failures.isEmpty, Comment(rawValue: report))
    }

    @Test("CommonMark 0.31.2") func commonMark() throws {
        try Self.run("commonmark-0.31.2", expectedCount: 652)
    }

    @Test("GFM spec 0.29") func gfmSpec() throws {
        try Self.run("gfm-spec-0.29", expectedCount: 670)
    }

    @Test("GFM extensions") func gfmExtensions() throws {
        try Self.run("gfm-extensions", expectedCount: 30, global: Self.gfmGlobal)
    }

    @Test("GFM regression") func gfmRegression() throws {
        try Self.run("gfm-regression", expectedCount: 26)
    }

    @Test("fixture loader handles CR-only and tab arrows") func loader() {
        let text = "### S\n\n```````````````````````````````` example a b\nx→y\r\n.\n<p>x\ty</p>\n````````````````````````````````\n"
        let examples = SpecFixtures.parse(Array(text.utf8))
        #expect(examples.count == 1)
        #expect(examples[0].markdown == "x\ty\r\n")
        #expect(examples[0].html == "<p>x\ty</p>\n")
        #expect(examples[0].extensions == ["a", "b"])
        #expect(examples[0].section == "S")
    }
}
