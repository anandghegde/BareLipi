import TOMLKit
import Yams

/// The front matter keys BareLipi reads (§6.13), parsed with Yams (YAML) or
/// TOMLKit (TOML). The source is never rewritten; a block that does not
/// parse keeps `error` and is shown as source with a warning.
public struct FrontMatterData: Sendable, Equatable {
    public var kind: FrontMatterKind
    /// `title`: the outline's document title.
    public var title: String?
    /// `assets`: where pasted and dropped images go (§6.7).
    public var assets: String?
    /// Typora's `typora-copy-images-to` and `typora-root-url` (migration).
    public var typoraCopyImagesTo: String?
    public var typoraRootURL: String?
    /// `lang`: the document language (CJK face selection).
    public var lang: String?
    /// `math.macros` (or a top-level `math.macros` key) as TeX definitions:
    /// a string is taken as written, a map of name → body becomes one
    /// `\newcommand{name}{body}` per line.
    public var mathMacros: String?
    /// Why the block did not parse (with its document line); nil when it did.
    public var error: String?

    public var isMalformed: Bool { error != nil }

    public init(kind: FrontMatterKind) { self.kind = kind }

    /// Parses `content`, the text between the delimiter lines.
    public static func parse(_ content: String, kind: FrontMatterKind) -> FrontMatterData {
        var data = FrontMatterData(kind: kind)
        switch kind {
        case .yaml: data.readYAML(content)
        case .toml: data.readTOML(content)
        }
        return data
    }

    /// The front matter of a parsed document (entry 0), nil when it has none.
    public static func parse(index: BlockIndex, rope: LipiRope) -> FrontMatterData? {
        guard let content = content(index: index, rope: rope) else { return nil }
        return parse(content.text, kind: content.kind)
    }

    /// The front matter at the start of `text`, nil when it has none.
    public static func parse(document text: String) -> FrontMatterData? {
        let rope = LipiRope(text)
        guard let match = FrontMatter.detect(in: rope) else { return nil }
        return parse(between(Array(rope.string(in: 0..<match.contentEnd).utf8), kind: match.kind), kind: match.kind)
    }

    /// The text between the delimiters of the document's front matter.
    public static func content(index: BlockIndex, rope: LipiRope) -> (text: String, kind: FrontMatterKind)? {
        guard let first = index.entries.first, case .frontMatter(let kind) = first.block.kind else { return nil }
        return (between(Array(rope.string(in: 0..<first.block.range.upperBound).utf8), kind: kind), kind)
    }

    /// `block` (opening line through the closing line's content) without
    /// its delimiter lines.
    private static func between(_ block: [UInt8], kind: FrontMatterKind) -> String {
        var bytes = block
        guard let nl = bytes.firstIndex(of: 0x0A) else { return "" }
        bytes.removeSubrange(0...nl)
        let lastStart = (bytes.lastIndex(of: 0x0A).map { $0 + 1 }) ?? 0
        let last = Array(bytes[lastStart...]).filter { $0 != 0x0D }
        if FrontMatter.isDelimiter(last, kind: kind, closing: true) { bytes.removeSubrange(lastStart...) }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: YAML

    private mutating func readYAML(_ content: String) {
        let root: Node?
        do {
            root = try Yams.compose(yaml: content)
        } catch let e as YamlError {
            error = Self.describe(e)
            return
        } catch {
            self.error = "Front matter could not be read."
            return
        }
        guard let root else { return }
        guard root.mapping != nil else {
            error = "Front matter is not a list of keys and values."
            return
        }
        title = root["title"].flatMap(Self.scalar)
        assets = root["assets"].flatMap(Self.scalar)
        typoraCopyImagesTo = root["typora-copy-images-to"].flatMap(Self.scalar)
        typoraRootURL = root["typora-root-url"].flatMap(Self.scalar)
        lang = root["lang"].flatMap(Self.scalar)
        if let macros = root["math"]?["macros"] ?? root["math.macros"] {
            if let s = Self.scalar(macros) {
                mathMacros = s
            } else if let map = macros.mapping {
                var lines: [String] = []
                for (k, v) in map { if let name = k.string, let body = v.string { lines.append(Self.newcommand(name, body)) } }
                mathMacros = lines.isEmpty ? nil : lines.joined(separator: "\n")
            }
        }
    }

    private static func scalar(_ node: Node) -> String? {
        guard case .scalar(let s) = node else { return nil }
        return s.string.isEmpty ? nil : s.string
    }

    private static func describe(_ e: YamlError) -> String {
        switch e {
        case .scanner(_, let problem, let mark, _), .parser(_, let problem, let mark, _),
             .composer(_, let problem, let mark, _):
            // Line 1 of the content is line 2 of the document.
            return "YAML error on line \(mark.line + 1): \(problem)"
        case .duplicatedKeysInMapping(let duplicates, _):
            return "YAML error: duplicate key \(duplicates.map { "\"\($0)\"" }.joined(separator: ", "))"
        case .reader(let problem, _, _, _):
            return "YAML error: \(problem)"
        default:
            return "YAML error: \(e)"
        }
    }

    // MARK: TOML

    private mutating func readTOML(_ content: String) {
        let table: TOMLTable
        do {
            table = try TOMLTable(string: content)
        } catch let e as TOMLParseError {
            error = "TOML error on line \(e.source.begin.line + 1): \(e.description)"
            return
        } catch {
            self.error = "Front matter could not be read."
            return
        }
        func string(_ key: String) -> String? { table[key]?.string.flatMap { $0.isEmpty ? nil : $0 } }
        title = string("title")
        assets = string("assets")
        typoraCopyImagesTo = string("typora-copy-images-to")
        typoraRootURL = string("typora-root-url")
        lang = string("lang")
        if let macros = table["math"]?.table?["macros"] ?? table["math.macros"] {
            if let s = macros.string, !s.isEmpty {
                mathMacros = s
            } else if let map = macros.table {
                let lines = map.keys.compactMap { k in map[k]?.string.map { Self.newcommand(k, $0) } }
                mathMacros = lines.isEmpty ? nil : lines.joined(separator: "\n")
            }
        }
    }

    private static func newcommand(_ name: String, _ body: String) -> String {
        let n = name.hasPrefix("\\") ? name : "\\" + name
        return "\\newcommand{\(n)}{\(body)}"
    }
}
