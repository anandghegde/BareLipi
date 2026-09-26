import Foundation

/// The PRD §9.1 fixture documents, generated deterministically.
public enum PerfFixture: String, CaseIterable, Sendable {
    case lorem50k = "lorem-50k"
    case words170k = "words-170k"
    case words500k = "words-500k"
    case tenMB = "10mb"
    case kannada20k = "kannada-20k"
    case mixedScripts = "mixed-scripts"
    case tables600x6 = "tables-600x6"
    case tables10kx10 = "tables-10kx10"
    case images200 = "images-200"
    case math500 = "math-500"
    case mermaid20 = "mermaid-20"
    case revealMatrix = "reveal-matrix"

    public var fileName: String { rawValue + ".md" }

    /// The fixture text. Generation is deterministic; results are cached per
    /// process because the largest ones take tens of milliseconds.
    public func text() -> String {
        FixtureCache.shared.text(for: self)
    }

    func generate() -> String {
        switch self {
        case .lorem50k:
            var g = LoremGenerator(seed: 0x5EED_0001, words: 50_000, headings: 200, tables: 40, fences: 60, math: 30, images: 20)
            return g.generate()
        case .words170k:
            var g = LoremGenerator(seed: 0x5EED_0002, words: 170_000, headings: 600, tables: 100, fences: 150, math: 60, images: 40)
            return g.generate()
        case .words500k:
            var g = LoremGenerator(seed: 0x5EED_0003, words: 500_000, headings: 1_800, tables: 300, fences: 400, math: 150, images: 100)
            return g.generate()
        case .tenMB:
            var g = LoremGenerator(seed: 0x5EED_0004, words: 1_700_000, headings: 6_000, tables: 1_000, fences: 1_200, math: 500, images: 300)
            return g.generate(targetBytes: 10 * 1024 * 1024)
        case .kannada20k:
            var g = ScriptGenerator(seed: 0x5EED_0010)
            return g.kannada(words: 20_000)
        case .mixedScripts:
            var g = ScriptGenerator(seed: 0x5EED_0011)
            return g.mixed(paragraphs: 400)
        case .tables600x6:
            var g = TableGenerator(seed: 0x5EED_0020)
            return g.table(rows: 600, columns: 6)
        case .tables10kx10:
            var g = TableGenerator(seed: 0x5EED_0021)
            return g.table(rows: 10_000, columns: 10)
        case .images200:
            var g = LoremGenerator(seed: 0x5EED_0030, words: 6_000, headings: 20, tables: 0, fences: 0, math: 0, images: 200)
            return g.generate()
        case .math500:
            var g = MathGenerator(seed: 0x5EED_0040)
            return g.document(formulas: 500)
        case .mermaid20:
            var g = MathGenerator(seed: 0x5EED_0041)
            return g.mermaid(diagrams: 20)
        case .revealMatrix:
            return RevealMatrix.text
        }
    }
}

final class FixtureCache: @unchecked Sendable {
    static let shared = FixtureCache()
    private let lock = NSLock()
    private var texts: [PerfFixture: String] = [:]

    func text(for fixture: PerfFixture) -> String {
        lock.lock()
        if let t = texts[fixture] { lock.unlock(); return t }
        lock.unlock()
        let generated = fixture.generate()
        lock.lock()
        texts[fixture] = generated
        lock.unlock()
        return generated
    }
}

// MARK: - Lorem

/// Latin prose with the block mix of lorem-50k.md: headings, tables, fences,
/// math, images, lists, quotes and inline markup in fixed proportions.
struct LoremGenerator {
    var rng: SplitMix64
    let words: Int
    let headings: Int
    let tables: Int
    let fences: Int
    let math: Int
    let images: Int

    init(seed: UInt64, words: Int, headings: Int, tables: Int, fences: Int, math: Int, images: Int) {
        rng = SplitMix64(seed: seed)
        self.words = words
        self.headings = headings
        self.tables = tables
        self.fences = fences
        self.math = math
        self.images = images
    }

    mutating func word() -> String { rng.pick(Words.latin) }

    mutating func sentence(words n: Int) -> String {
        var parts: [String] = []
        for i in 0..<n {
            var w = word()
            if i == 0 { w = w.prefix(1).uppercased() + w.dropFirst() }
            if i > 0, i < n - 1, rng.chance(0.08) { w += "," }
            parts.append(w)
        }
        return parts.joined(separator: " ") + rng.pick([".", ".", ".", "?", "!"])
    }

    /// A paragraph of about `n` words with occasional inline markup.
    mutating func paragraph(words n: Int) -> String {
        var out: [String] = []
        var remaining = n
        while remaining > 0 {
            let len = min(remaining, 6 + rng.below(14))
            var s = sentence(words: len)
            let roll = rng.below(100)
            if roll < 6 { s = s.replacingFirstWord { "**\($0)**" } }
            else if roll < 12 { s = s.replacingFirstWord { "*\($0)*" } }
            else if roll < 15 { s = s.replacingFirstWord { "`\($0)`" } }
            else if roll < 18 { s = s.replacingFirstWord { "[\($0)](https://example.com/\($0.lowercased()))" } }
            else if roll < 19 { s = s.replacingFirstWord { "~~\($0)~~" } }
            else if roll < 20 { s = s.replacingFirstWord { "$\($0.lowercased())_i$" } }
            out.append(s)
            remaining -= len
        }
        return out.joined(separator: " ")
    }

    mutating func generate(targetBytes: Int? = nil) -> String {
        var out = ""
        out.reserveCapacity(targetBytes ?? words * 7)
        var written = 0
        var headingsLeft = headings, tablesLeft = tables, fencesLeft = fences, mathLeft = math, imagesLeft = images
        var section = 0
        let wordsPerSection = max(1, words / max(1, headings))
        var listCounter = 0
        while written < words && (targetBytes == nil || out.utf8.count < targetBytes!) {
            if headingsLeft > 0 {
                section += 1
                let level = section == 1 ? 1 : (section % 7 == 0 ? 2 : (section % 3 == 0 ? 3 : 2))
                out += String(repeating: "#", count: level) + " " + sentence(words: 3 + rng.below(5)).dropLast() + "\n\n"
                headingsLeft -= 1
            }
            var sectionWords = 0
            while sectionWords < wordsPerSection, written < words {
                let roll = rng.below(100)
                if roll < 70 {
                    let n = 40 + rng.below(50)
                    out += paragraph(words: n) + "\n\n"
                    sectionWords += n; written += n
                } else if roll < 80 {
                    listCounter += 1
                    let ordered = listCounter % 3 == 0
                    let items = 3 + rng.below(4)
                    for i in 0..<items {
                        let n = 5 + rng.below(12)
                        let marker = ordered ? "\(i + 1). " : (listCounter % 4 == 0 ? (i % 2 == 0 ? "- [x] " : "- [ ] ") : "- ")
                        out += marker + sentence(words: n) + "\n"
                        sectionWords += n; written += n
                    }
                    out += "\n"
                } else if roll < 86 {
                    let n = 15 + rng.below(30)
                    out += "> " + paragraph(words: n) + "\n\n"
                    sectionWords += n; written += n
                } else if roll < 90, tablesLeft > 0 {
                    out += table(rows: 4 + rng.below(4), columns: 3 + rng.below(3))
                    tablesLeft -= 1
                } else if roll < 94, fencesLeft > 0 {
                    out += fence()
                    fencesLeft -= 1
                } else if roll < 97, mathLeft > 0 {
                    out += "$$\n" + formula() + "\n$$\n\n"
                    mathLeft -= 1
                } else if imagesLeft > 0 {
                    out += "![\(sentence(words: 3).dropLast())](images/figure-\(images - imagesLeft + 1).png)\n\n"
                    imagesLeft -= 1
                } else {
                    let n = 20 + rng.below(30)
                    out += paragraph(words: n) + "\n\n"
                    sectionWords += n; written += n
                }
            }
        }
        // Spend any quotas the word budget did not reach.
        while tablesLeft > 0 { out += table(rows: 5, columns: 4); tablesLeft -= 1 }
        while fencesLeft > 0 { out += fence(); fencesLeft -= 1 }
        while mathLeft > 0 { out += "$$\n" + formula() + "\n$$\n\n"; mathLeft -= 1 }
        while imagesLeft > 0 { out += "![figure](images/figure-\(images - imagesLeft + 1).png)\n\n"; imagesLeft -= 1 }
        while headingsLeft > 0 { out += "## " + sentence(words: 4).dropLast() + "\n\n" + paragraph(words: 30) + "\n\n"; headingsLeft -= 1 }
        return out
    }

    mutating func table(rows: Int, columns: Int) -> String {
        var out = "|"
        for _ in 0..<columns { out += " " + word().capitalized + " |" }
        out += "\n|"
        for c in 0..<columns { out += c % 3 == 2 ? " ---: |" : (c % 3 == 1 ? " :---: |" : " --- |") }
        out += "\n"
        for _ in 0..<rows {
            out += "|"
            for c in 0..<columns {
                out += c % 3 == 2 ? " \(rng.below(10_000)) |" : " " + sentence(words: 1 + rng.below(4)).dropLast() + " |"
            }
            out += "\n"
        }
        return out + "\n"
    }

    mutating func fence() -> String {
        let lang = rng.pick(["swift", "python", "js", "sh", ""])
        var out = "```\(lang)\n"
        for i in 0..<(3 + rng.below(10)) {
            out += "let \(word())\(i) = \(word())(\(rng.below(100)))  // \(sentence(words: 3))\n"
        }
        return out + "```\n\n"
    }

    mutating func formula() -> String {
        rng.pick([
            "\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}",
            "\\sum_{n=1}^{\\infty} \\frac{1}{n^2} = \\frac{\\pi^2}{6}",
            "e^{i\\pi} + 1 = 0",
            "\\nabla \\cdot \\mathbf{E} = \\frac{\\rho}{\\varepsilon_0}",
            "f(x) = \\begin{cases} 1 & x \\ge 0 \\\\ 0 & x < 0 \\end{cases}",
            "\\frac{\\partial u}{\\partial t} = \\alpha \\nabla^2 u",
        ])
    }
}

extension String {
    func replacingFirstWord(_ transform: (String) -> String) -> String {
        guard let space = firstIndex(of: " ") else { return transform(self) }
        return transform(String(self[..<space])) + self[space...]
    }
}

// MARK: - Scripts

struct ScriptGenerator {
    var rng: SplitMix64
    init(seed: UInt64) { rng = SplitMix64(seed: seed) }

    mutating func run(_ words: [String], count: Int, punctuation: [String] = [".", ",", ";"]) -> String {
        var parts: [String] = []
        for i in 0..<count {
            var w = rng.pick(words)
            if i < count - 1, !punctuation.isEmpty, rng.chance(0.07) { w += rng.pick(punctuation) }
            parts.append(w)
        }
        return parts.joined(separator: " ")
    }

    mutating func kannada(words: Int) -> String {
        var out = "# ಕನ್ನಡ ಪಠ್ಯ\n\n"
        var written = 0
        var section = 0
        while written < words {
            section += 1
            if section % 6 == 0 { out += "## " + run(Words.kannada, count: 3, punctuation: []) + "\n\n" }
            let roll = rng.below(10)
            if roll < 7 {
                let n = 40 + rng.below(60)
                var p = run(Words.kannada, count: n) + "."
                if rng.chance(0.3) { p += " " + String(1900 + rng.below(120)) + " " + run(Words.kannada, count: 4) + "." }
                if rng.chance(0.15) { p = p.replacingFirstWord { "**\($0)**" } }
                out += p + "\n\n"
                written += n
            } else if roll < 9 {
                for _ in 0..<(3 + rng.below(3)) {
                    let n = 4 + rng.below(8)
                    out += "- " + run(Words.kannada, count: n) + "\n"
                    written += n
                }
                out += "\n"
            } else {
                let n = 12 + rng.below(20)
                out += "> " + run(Words.kannada, count: n) + "\n\n"
                written += n
            }
        }
        return out
    }

    mutating func mixed(paragraphs: Int) -> String {
        var out = "---\ntitle: Mixed scripts\nlang: ja\n---\n\n# Scripts\n\n"
        let sets: [(String, [String], String)] = [
            ("Latin", Words.latin, " "), ("Kannada", Words.kannada, " "), ("Devanagari", Words.devanagari, " "),
            ("Tamil", Words.tamil, " "), ("Arabic", Words.arabic, " "), ("Hebrew", Words.hebrew, " "),
            ("Japanese", Words.japanese, ""), ("Chinese", Words.chinese, ""), ("Korean", Words.korean, " "),
            ("Emoji", Words.emoji, " "),
        ]
        for i in 0..<paragraphs {
            let (name, words, separator) = sets[i % sets.count]
            if i % sets.count == 0 { out += "## Round \(i / sets.count + 1)\n\n" }
            let n = 20 + rng.below(40)
            var parts: [String] = []
            for _ in 0..<n { parts.append(rng.pick(words)) }
            var p = parts.joined(separator: separator)
            if name == "Emoji" { p = run(Words.latin, count: 10) + " " + p }
            if rng.chance(0.3) { p += " " + run(Words.latin, count: 6) + "." }
            if rng.chance(0.2) { p += " " + rng.pick(Words.emoji) }
            out += p + "\n\n"
        }
        // Combining runs and ZWJ sequences appear in prose, not only in the
        // pathological set.
        out += "Stacked marks: e" + String(repeating: "\u{0301}", count: 8) + " and a" + String(repeating: "\u{0308}", count: 12) + ".\n\n"
        return out
    }
}

// MARK: - Tables

struct TableGenerator {
    var rng: SplitMix64
    init(seed: UInt64) { rng = SplitMix64(seed: seed) }

    mutating func table(rows: Int, columns: Int) -> String {
        var out = "# Table \(rows) × \(columns)\n\nA paragraph before the table.\n\n|"
        for c in 0..<columns { out += " Column \(c + 1) |" }
        out += "\n|"
        for c in 0..<columns { out += c % 3 == 2 ? " ---: |" : " --- |" }
        out += "\n"
        out.reserveCapacity(rows * columns * 12)
        for r in 0..<(rows - 1) {
            out += "|"
            for c in 0..<columns {
                switch c % 3 {
                case 0: out += " \(rng.pick(Words.latin)) \(rng.pick(Words.latin)) |"
                case 1: out += " \(rng.pick(Words.latin)) |"
                default: out += " \(r * columns + c) |"
                }
            }
            out += "\n"
        }
        return out + "\nA paragraph after the table.\n"
    }
}

// MARK: - Math and diagrams

struct MathGenerator {
    var rng: SplitMix64
    init(seed: UInt64) { rng = SplitMix64(seed: seed) }

    mutating func document(formulas: Int) -> String {
        var out = "# Formulas\n\n"
        var lorem = LoremGenerator(seed: 0x5EED_0042, words: 1, headings: 0, tables: 0, fences: 0, math: 0, images: 0)
        for i in 0..<formulas {
            if i % 25 == 0 { out += "## Set \(i / 25 + 1)\n\n" }
            out += lorem.paragraph(words: 12 + rng.below(20)) + "\n\n$$\n" + lorem.formula()
            if rng.chance(0.5) { out += " \\quad \\text{for } n = \(rng.below(100))" }
            out += "\n$$\n\n"
        }
        return out
    }

    mutating func mermaid(diagrams: Int) -> String {
        var out = "# Diagrams\n\n"
        for i in 0..<diagrams {
            out += "## Diagram \(i + 1)\n\n```mermaid\ngraph TD\n"
            let nodes = 4 + rng.below(6)
            for n in 0..<nodes {
                let next = (n + 1 + rng.below(max(1, nodes - n - 1))) % nodes
                out += "  N\(n)[\(rng.pick(Words.latin))] --> N\(next)\n"
            }
            out += "```\n\n"
        }
        return out
    }
}

// MARK: - Reveal matrix

enum RevealMatrix {
    static let text = """
    ---
    title: Reveal matrix
    lang: en
    ---

    # Heading one

    Setext heading
    ==============

    ## Heading two

    ### Heading three

    #### Heading four

    ##### Heading five

    ###### Heading six

    A paragraph with *emphasis*, **strong**, ***both***, ~~struck~~, `code`, a [link](https://example.com "Title"),
    a ![image](images/a.png), an autolink <https://example.com>, a bare https://example.org/path, a footnote[^1],
    inline math $x^2 + y^2$, inline <b>html</b>, an escape \\* and an entity &amp; and &copy;, then a hard break\\
    after the break, and a soft
    break in the same paragraph.

    > A block quote with **strong** text
    > that continues on a second line.
    >
    > > Nested quote.

    - Bullet one
    - Bullet two with *emphasis*
        - Nested bullet
    - Bullet three

    1. Ordered one
    2. Ordered two
       continued line
    3. Ordered three

    - [ ] Task open
    - [x] Task done

    - Loose item one

    - Loose item two

    ```swift
    let fenced = "code"
    ```

        indented code block

    <div class="html-block">
    raw html block
    </div>

    ---

    | Column | Number | Centred |
    | --- | ---: | :---: |
    | one | 1 | a |
    | two | 22 | bb |

    Term with reference [ref][ref-def] and a collapsed [ref-def][] link.

    [ref-def]: https://example.com/ref "Reference"

    [^1]: The footnote definition, with *emphasis*.

    $$
    \\int_0^1 x\\,dx = \\frac{1}{2}
    $$

    ಕನ್ನಡ ಪದ **ಕ್ಷೇತ್ರ** ಮತ್ತು हिन्दी शब्द *ज्ञान* and mixed script 2024.

    Final paragraph.

    """
}

// MARK: - Pathological inputs

public enum PathologicalFixture: String, CaseIterable, Sendable {
    case nestedQuotes1000 = "nested-quotes-1000"
    case paragraph1MB = "paragraph-1mb"
    case line100k = "line-100k"
    case refdefs10000 = "refdefs-10000"
    case footnotes5000 = "footnotes-5000"
    case unclosedFenceAt10 = "unclosed-fence-at-10"
    case emojiZWJ2000 = "emoji-zwj-2000"
    case combining64 = "combining-64"
    case invalidUTF8 = "invalid-utf8"
    case nulBytes = "nul-bytes"
    case crlf = "crlf"
    case cr = "cr"
    case utf16BOM = "utf16-bom"

    public var fileName: String { rawValue + ".md" }

    public func data() -> Data {
        var rng = SplitMix64(seed: 0x5EED_0100)
        switch self {
        case .nestedQuotes1000:
            return Data((String(repeating: "> ", count: 1000) + "deep\n").utf8)
        case .paragraph1MB:
            var s = ""
            s.reserveCapacity(1_100_000)
            while s.utf8.count < 1_048_576 { s += rng.pick(Words.latin) + " " }
            return Data((s + "\n").utf8)
        case .line100k:
            var s = ""
            while s.utf8.count < 100_000 { s += rng.pick(Words.latin) + " " }
            return Data((String(s.prefix(100_000)) + "\n").utf8)
        case .refdefs10000:
            var s = "Text with [link 5][ref5].\n\n"
            for i in 0..<10_000 { s += "[ref\(i)]: https://example.com/\(i) \"Title \(i)\"\n" }
            return Data(s.utf8)
        case .footnotes5000:
            var s = ""
            for i in 0..<5_000 { s += "Paragraph \(i) with a note[^\(i)].\n\n[^\(i)]: Note \(i).\n\n" }
            return Data(s.utf8)
        case .unclosedFenceAt10:
            var s = "Intro txt\n```swift\n"
            for i in 0..<2_000 { s += "let x\(i) = \(i)\n\nparagraph \(i) that is really prose\n\n" }
            return Data(s.utf8)
        case .emojiZWJ2000:
            var s = ""
            for i in 0..<2_000 { s += Words.emoji[i % Words.emoji.count] + (i % 40 == 39 ? "\n\n" : " ") }
            return Data(s.utf8)
        case .combining64:
            return Data(("Mark run: a" + String(repeating: "\u{0301}", count: 64) + " end.\n").utf8)
        case .invalidUTF8:
            var d = Data("Valid start.\n\nA paragraph with a bad byte here: ".utf8)
            d.append(0xFF)
            d.append(Data(" and again ".utf8))
            d.append(contentsOf: [0xC3])
            d.append(Data(" and a truncated sequence ".utf8))
            d.append(contentsOf: [0xE2, 0x82])
            d.append(Data(" at the end.\n".utf8))
            return d
        case .nulBytes:
            var d = Data("Before NUL ".utf8)
            d.append(0)
            d.append(Data(" after NUL\n\n# Heading with ".utf8))
            d.append(0)
            d.append(Data("\n".utf8))
            return d
        case .crlf:
            return Data("# CRLF file\r\n\r\nParagraph one\r\nstill one.\r\n\r\n- item\r\n- item\r\n".utf8)
        case .cr:
            return Data("# CR file\r\rParagraph one\rstill one.\r\r- item\r- item\r".utf8)
        case .utf16BOM:
            let s = "# UTF-16 with BOM\n\nಕನ್ನಡ and English.\n"
            var d = Data([0xFF, 0xFE])
            for unit in s.utf16 { d.append(UInt8(unit & 0xFF)); d.append(UInt8(unit >> 8)) }
            return d
        }
    }
}

// MARK: - Writing

public enum Fixtures {
    /// `Fixtures/perf` in the repository, located from this source file.
    public static var defaultDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/perf")
    }

    /// Writes every fixture (and the pathological set under `pathological/`)
    /// and returns the files written.
    @discardableResult
    public static func write(to directory: URL = defaultDirectory) throws -> [URL] {
        let fm = FileManager.default
        let pathological = directory.appendingPathComponent("pathological")
        try fm.createDirectory(at: pathological, withIntermediateDirectories: true)
        var written: [URL] = []
        for fixture in PerfFixture.allCases {
            let url = directory.appendingPathComponent(fixture.fileName)
            try Data(fixture.text().utf8).write(to: url)
            written.append(url)
        }
        for fixture in PathologicalFixture.allCases {
            let url = pathological.appendingPathComponent(fixture.fileName)
            try fixture.data().write(to: url)
            written.append(url)
        }
        return written
    }
}
