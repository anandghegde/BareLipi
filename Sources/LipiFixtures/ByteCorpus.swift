import Foundation

/// One file of the byte-preservation corpus (Phase 1 exit check): a name
/// and the exact bytes on disk.
public struct CorpusFile: Sendable {
    public var name: String
    public var data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }

    public init(name: String, _ text: String) {
        self.init(name: name, data: Data(text.utf8))
    }

    /// Valid UTF-8 (after an optional BOM). Anything else must open read-only.
    public var isUTF8: Bool {
        let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        return String(validating: body, as: UTF8.self) != nil
    }
}

/// The byte-preservation corpus. Checked-in files under `Fixtures/corpus`
/// are small, LF and UTF-8 (git never rewrites them: `-text`); every
/// byte-tricky variant (BOM, CRLF, CR, mixed endings, no final newline,
/// trailing whitespace, NUL, invalid UTF-8, very long lines) is generated
/// here, deterministically, and so is one file per example of the four spec
/// suites in `Tests/LipiCoreTests/Fixtures`.
public enum ByteCorpus {
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// `Fixtures/corpus` in the repository.
    public static var checkedInDirectory: URL { repositoryRoot.appendingPathComponent("Fixtures/corpus") }

    /// The CommonMark and GFM spec files.
    public static var specDirectory: URL { repositoryRoot.appendingPathComponent("Tests/LipiCoreTests/Fixtures") }

    public static let specSuites = ["commonmark-0.31.2", "gfm-spec-0.29", "gfm-extensions", "gfm-regression"]

    /// Every corpus file: checked-in files and their variants, the generated
    /// edge cases, the pathological fixtures and every spec example.
    public static func all() throws -> [CorpusFile] {
        try documents() + specExamples()
    }

    /// The corpus without the spec examples.
    public static func documents() throws -> [CorpusFile] {
        let files = try checkedIn()
        return files + files.flatMap(variants(of:)) + generated()
            + PathologicalFixture.allCases.map { CorpusFile(name: "pathological/" + $0.fileName, data: $0.data()) }
            + [PerfFixture.revealMatrix, .codeFences].map { CorpusFile(name: "perf/" + $0.fileName, $0.text()) }
    }

    /// The `.md` files under `Fixtures/corpus`, sorted by name.
    public static func checkedIn() throws -> [CorpusFile] {
        let urls = try FileManager.default.contentsOfDirectory(at: checkedInDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try urls.map { CorpusFile(name: $0.lastPathComponent, data: try Data(contentsOf: $0)) }
    }

    // MARK: Variants

    /// The byte-level variants of an LF file: CRLF, CR, mixed endings, a
    /// BOM (with LF and with CRLF), no final newline, trailing whitespace.
    public static func variants(of file: CorpusFile) -> [CorpusFile] {
        let lf = Array(file.data)
        let base = (file.name as NSString).deletingPathExtension
        func named(_ suffix: String, _ bytes: [UInt8]) -> CorpusFile {
            CorpusFile(name: "variants/\(base).\(suffix).md", data: Data(bytes))
        }
        var trimmed = lf
        while trimmed.last == 0x0A { trimmed.removeLast() }
        return [
            named("crlf", replacingLF(lf) { _ in [0x0D, 0x0A] }),
            named("cr", replacingLF(lf) { _ in [0x0D] }),
            named("mixed", replacingLF(lf) { k in [[0x0A], [0x0D, 0x0A], [0x0D]][k % 3] }),
            named("bom", bom + lf),
            named("bom-crlf", bom + replacingLF(lf) { _ in [0x0D, 0x0A] }),
            named("no-final-newline", trimmed),
            named("crlf-no-final-newline", replacingLF(trimmed) { _ in [0x0D, 0x0A] }),
            named("trailing-ws", replacingLF(lf) { k in (k % 2 == 0 ? Array("  ".utf8) : Array(" \t".utf8)) + [0x0A] }),
            named("tabs", lf.map { $0 == 0x20 ? 0x09 : $0 }.enumerated().map { k, b in b == 0x09 && k % 3 != 0 ? 0x20 : b }),
        ]
    }

    static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// `bytes` with the k-th LF replaced by `ending(k)`.
    static func replacingLF(_ bytes: [UInt8], _ ending: (Int) -> [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + bytes.count / 16)
        var k = 0
        for b in bytes {
            if b == 0x0A { out += ending(k); k += 1 } else { out.append(b) }
        }
        return out
    }

    // MARK: Generated edge cases

    public static func generated() -> [CorpusFile] {
        var files: [CorpusFile] = []
        func add(_ name: String, _ bytes: [UInt8]) { files.append(CorpusFile(name: "generated/" + name, data: Data(bytes))) }
        func add(_ name: String, _ text: String) { add(name, Array(text.utf8)) }

        // Empty, BOM and line-ending extremes.
        add("empty.md", [UInt8]())
        add("bom-only.md", bom)
        add("bom-twice.md", bom + bom + Array("# Two BOMs\n".utf8))
        add("bom-mid-file.md", "Before\n\u{FEFF}After a stray BOM\n")
        add("lf-only.md", "\n\n\n")
        add("crlf-only.md", "\r\n\r\n")
        add("cr-only.md", "\r\r\r")
        add("lf-cr.md", "a\n\rb\n\r")
        add("single-char.md", "x")
        add("mixed-structures.md", "# Head\r\n\r\n- a\n- b\r- c\r\n\r\n| x | y |\r\n|---|---|\n| 1 | 2 |\r\n\r\n```\r\ncode\ncode\r\n```\n\n> quote\r> more\n")
        add("cr-structures.md", "# Head\r\r1. one\r2. two\r   - nested\r\r| a | b |\r| - | - |\r| c | d |\r\r```js\rlet x = 1\r```\r\r> q\r")

        // Whitespace.
        add("trailing-whitespace.md", "# Whitespace\n\nTrailing spaces   \nhard break above  \nTab\tseparated\tvalues\t\n\t\tIndented with tabs\n\n-\ttab after marker\n\n    \n\t\n\nLast line with trailing tab\t\n")
        add("trailing-whitespace-crlf.md", "Line one  \r\nline two\t\r\n   \r\n\t\r\n- item \r\n  - nested\t \r\n")
        add("only-whitespace.md", "   \n\t\n  \t  ")
        add("nbsp-and-odd-spaces.md", "a\u{00A0}b\u{2003}c\u{200B}d\u{3000}e\n\u{00A0}\u{00A0}\n")

        // NUL and control bytes.
        add("nul-start-end.md", [0x00] + Array("# NUL at both ends\n".utf8) + [0x00])
        add("nul-in-structures.md", Array("# Head\u{0}ing\n\n`co\u{0}de` and **st\u{0}rong**\n\n| a\u{0} | b |\n| - | - |\n| \u{0} | c |\n\n```\n\u{0}\u{0}\n```\n".utf8))
        add("controls.md", Array("bell \u{7} backspace \u{8} vt \u{B} ff \u{C} esc \u{1B}[0m del \u{7F}\n".utf8))

        // Invalid UTF-8 and other encodings: open read-only, saved unchanged.
        add("invalid-lone-continuation.md", Array("ok ".utf8) + [0x80] + Array(" ok\n".utf8))
        add("invalid-ff.md", Array("# Title\n\n".utf8) + [0xFF, 0xFE, 0xFD] + Array("\n".utf8))
        add("invalid-truncated-at-eof.md", Array("ends mid-scalar ".utf8) + [0xE0, 0xB2])
        add("invalid-overlong.md", Array("overlong slash ".utf8) + [0xC0, 0xAF] + Array("\n".utf8))
        add("invalid-surrogate.md", Array("CESU surrogate ".utf8) + [0xED, 0xA0, 0x80] + Array("\n".utf8))
        add("invalid-crlf-bom.md", bom + Array("bom then bad\r\n".utf8) + [0xC3] + Array("\r\n".utf8))
        add("latin1.md", Array("caf".utf8) + [0xE9] + Array(" cr".utf8) + [0xE8] + Array("me\n".utf8))
        add("windows-1252-quotes.md", Array("He said ".utf8) + [0x93] + Array("hi".utf8) + [0x94, 0x20, 0x96, 0x0A])
        add("utf16be-bom.md", [0xFE, 0xFF] + "# UTF-16 BE\n".utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })

        // Very long lines.
        var rng = SplitMix64(seed: 0xB17E_0001)
        var long = ""
        while long.utf8.count < 256 * 1024 { long += rng.pick(Words.latin) + " " }
        add("long-line-256k.md", "# Long\n\n" + long + "\n")
        var kannada = ""
        while kannada.utf8.count < 64 * 1024 { kannada += rng.pick(Words.kannada) }
        add("long-line-kannada-nospace.md", kannada)
        add("long-table-row.md", "|" + (0..<400).map { " c\($0) " }.joined(separator: "|") + "|\n|" + String(repeating: "-|", count: 400) + "\n|" + (0..<400).map { " \($0) " }.joined(separator: "|") + "|\n")
        add("long-url.md", "[x](https://example.com/" + String(repeating: "a/b%20c?d=e&", count: 3000) + ")\n")
        add("long-emoji-zwj-line.md", String(repeating: "👨‍👩‍👧‍👦🏳️‍🌈👩🏽‍💻", count: 2000) + "\r\n")

        // Scripts in CRLF with a BOM, front matter in CRLF.
        add("scripts-bom-crlf.md", bom + Array("---\r\ntitle: ಕನ್ನಡ\r\n---\r\n\r\n# ಶೀರ್ಷಿಕೆ\r\n\r\nहिन्दी **ದಪ್ಪ** 👩‍👩‍👧 ಕ‍್\r\n".utf8))
        add("toml-cr.md", "+++\rtitle = \"cr\"\r+++\r\rBody\r")
        add("front-matter-unclosed.md", "---\ntitle: never closed\n\n# Heading\n")

        // Syntax Typora users write that sits at the edge of CommonMark.
        add("typora-img-variants.md", "<img src=\"a.png\" style=\"zoom:25%\">\n<IMG SRC='b.png' STYLE='zoom: 0.5'>\n<img src=\"c d.png\" alt=\"x\" style=\"width:100px;zoom:67%;\"/>\n\n![a](<b c.png>) ![](d.png =100x)\n")
        add("toc-variants.md", "[toc]\n\n[TOC]\n\n  [toc]  \n\n# A\n\n## B\n\n[toc] inline is text\n")
        add("math-edge.md", "$$\nunclosed math block\n\n$x$ $$y$$ $ z $ \\$ $$\n\n$$ inline $$\n")
        add("footnote-edge.md", "Ref[^a] [^missing] [^a].\n\n[^a]: Note\n[^b]:\n[^ c]: bad label\n\n[^a]: duplicate\n")
        add("escapes.md", "\\*not\\* \\_ \\` \\| \\\\ \\# \\[x\\](y) &amp; &#x1F600; &nbsp; &bogus;\n")
        return files
    }

    // MARK: Spec examples

    /// One file per example of the four spec suites, `→` replaced by a tab
    /// as the spec runners do.
    public static func specExamples(directory: URL = specDirectory) throws -> [CorpusFile] {
        try specSuites.flatMap { suite -> [CorpusFile] in
            let data = try Data(contentsOf: directory.appendingPathComponent(suite + ".txt"))
            return specExamples(in: Array(data)).enumerated().map { k, markdown in
                CorpusFile(name: "spec/\(suite)/example-\(String(format: "%04d", k + 1)).md", data: Data(markdown))
            }
        }
    }

    /// The Markdown of each ```` example ```` block in a cmark-style spec file.
    static func specExamples(in bytes: [UInt8]) -> [[UInt8]] {
        let fence = [UInt8](repeating: 0x60, count: 32)
        var examples: [[UInt8]] = []
        var state = 0  // 0 outside, 1 Markdown, 2 HTML
        var markdown: [UInt8] = []
        var start = 0
        while start < bytes.count {
            var end = start
            while end < bytes.count && bytes[end] != 0x0A { end += 1 }
            let next = min(end + 1, bytes.count)
            let line = Array(bytes[start..<next])
            let content = Array(bytes[start..<end]).drop { $0 == 0x20 }
            start = next
            if content.starts(with: fence + Array(" example".utf8)) {
                state = 1
                markdown = []
            } else if Array(content) == fence, state != 0 {
                examples.append(arrowsToTabs(markdown))
                state = 0
            } else if state == 1, Array(content) == [0x2E] {
                state = 2
            } else if state == 1 {
                markdown += line
            }
        }
        return examples
    }

    static func arrowsToTabs(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
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
