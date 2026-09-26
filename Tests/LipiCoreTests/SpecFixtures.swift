import Foundation
import Testing
@testable import LipiCore

/// One example from a cmark-style spec file.
struct SpecExample: Sendable {
    var number: Int
    var section: String
    var line: Int
    var markdown: String
    var html: String
    var extensions: [String]
}

/// Loads spec files exactly as cmark-gfm's `test/spec_tests.py` does:
/// 32-backtick fences, `.` separating markdown from HTML, `→` standing in
/// for a tab, `disabled` examples skipped, whitespace-stripped fence lines.
enum SpecFixtures {
    static func load(_ name: String) throws -> [SpecExample] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        return parse(Array(data))
    }

    static func parse(_ bytes: [UInt8]) -> [SpecExample] {
        let fence = [UInt8](repeating: 0x60, count: 32)
        let exampleTag = Array(" example".utf8)
        var examples: [SpecExample] = []
        var state = 0
        var number = 0
        var startLine = 0
        var section = ""
        var extensions: [String] = []
        var markdown: [UInt8] = []
        var html: [UInt8] = []

        var lineNumber = 0
        var lineStart = 0
        let n = bytes.count
        while lineStart < n {
            var lineEnd = lineStart
            while lineEnd < n && bytes[lineEnd] != 0x0A { lineEnd += 1 }
            let nextStart = min(lineEnd + 1, n)
            let line = Array(bytes[lineStart..<nextStart])
            lineNumber += 1
            lineStart = nextStart

            let stripped = strip(line)
            if stripped.starts(with: fence + exampleTag) {
                state = 1
                let rest = Array(stripped[(fence.count + exampleTag.count)...])
                extensions = String(decoding: rest, as: UTF8.self).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            } else if stripped == fence {
                state = 0
                number += 1
                if !extensions.contains("disabled") {
                    examples.append(SpecExample(number: number, section: section, line: startLine,
                                                markdown: String(decoding: arrows(markdown), as: UTF8.self),
                                                html: String(decoding: arrows(html), as: UTF8.self),
                                                extensions: extensions))
                }
                startLine = 0
                markdown = []
                html = []
            } else if stripped == [0x2E] {
                state = 2
            } else if state == 1 {
                if startLine == 0 { startLine = lineNumber - 1 }
                markdown += line
            } else if state == 2 {
                html += line
            } else if state == 0, let title = header(line) {
                section = title
            }
        }
        return examples
    }

    /// Python's `str.strip()` on ASCII whitespace.
    private static func strip(_ line: [UInt8]) -> [UInt8] {
        var lo = 0, hi = line.count
        func ws(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0B || b == 0x0C }
        while lo < hi && ws(line[lo]) { lo += 1 }
        while hi > lo && ws(line[hi - 1]) { hi -= 1 }
        return Array(line[lo..<hi])
    }

    /// `#+ ` at the start of a line.
    private static func header(_ line: [UInt8]) -> String? {
        var i = 0
        while i < line.count && line[i] == 0x23 { i += 1 }
        guard i > 0, i < line.count, line[i] == 0x20 else { return nil }
        return String(decoding: strip(Array(line[(i + 1)...])), as: UTF8.self)
    }

    /// `→` (U+2192) becomes a tab.
    private static func arrows(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if i + 2 < bytes.count, bytes[i] == 0xE2, bytes[i + 1] == 0x86, bytes[i + 2] == 0x92 {
                out.append(0x09)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }
}
