/// The theme's code-highlight tokens (PRD §8.4 `syntax.*`), plus the diff
/// line kinds, which themes colour with `ok` and `error`.
public enum SyntaxToken: UInt8, Sendable, Hashable, CaseIterable {
    case keyword = 1
    case string
    case comment
    case number
    case type
    case function
    case inserted
    case deleted

    /// CSS class used by the HTML export (`<span class="tok-keyword">`).
    public var cssClass: String {
        switch self {
        case .keyword: return "tok-keyword"
        case .string: return "tok-string"
        case .comment: return "tok-comment"
        case .number: return "tok-number"
        case .type: return "tok-type"
        case .function: return "tok-function"
        case .inserted: return "tok-inserted"
        case .deleted: return "tok-deleted"
        }
    }

    /// Maps a highlights.scm capture name to a token. Grammars use both the
    /// tree-sitter names (`@function.method`, `@constant.builtin`) and the
    /// Neovim ones (`@keyword.conditional`, `@markup.heading`); the most
    /// specific rule wins, then the first dotted component. `nil` means the
    /// capture is drawn in the plain code colour (variables, punctuation,
    /// operators) and still shadows less specific captures of the same node.
    public static func forCapture(_ name: String) -> SyntaxToken? {
        if let exact = exact[name] { return exact }
        var prefix = Substring(name)
        while let dot = prefix.lastIndex(of: ".") {
            prefix = prefix[..<dot]
            if let hit = exact[String(prefix)] { return hit }
        }
        return nil
    }

    private static let exact: [String: SyntaxToken?] = [
        "comment": .comment, "comment.documentation": .comment,
        "string": .string, "string.special": .string, "character": .string, "escape": .string,
        "string.escape": .string, "string.regex": .string, "string.regexp": .string, "regex": .string,
        "text.uri": .string, "markup.link.url": .string, "markup.raw": .string, "text.literal": .string,
        "number": .number, "float": .number, "boolean": .number, "constant": .number, "constant.builtin": .number,
        "constant.numeric": .number, "number.float": .number, "constant.character": .string,
        "keyword": .keyword, "conditional": .keyword, "repeat": .keyword, "include": .keyword,
        "exception": .keyword, "storageclass": .keyword, "preproc": .keyword, "define": .keyword,
        "tag": .keyword, "markup.heading": .keyword, "text.title": .keyword, "label": .keyword,
        "keyword.operator": .keyword, "operator": nil,
        "type": .type, "type.builtin": .type, "constructor": .type, "namespace": .type, "module": .type,
        "attribute": .type, "tag.attribute": .type, "annotation": .type, "decorator": .type,
        "function": .function, "method": .function, "function.method": .function, "function.builtin": .function,
        "function.macro": .function, "macro": .function, "function.call": .function, "method.call": .function,
        "diff.plus": .inserted, "diff.addition": .inserted, "text.diff.add": .inserted, "markup.inserted": .inserted,
        "diff.minus": .deleted, "diff.deletion": .deleted, "text.diff.delete": .deleted, "markup.deleted": .deleted,
        "variable": nil, "property": nil, "field": nil, "parameter": nil, "punctuation": nil,
        "embedded": nil, "spell": nil, "nospell": nil, "none": nil, "text": nil, "markup": nil,
    ]
}

/// One highlighted range of a code block, in UTF-16 offsets from the start
/// of the code (the text between the fences).
public struct HighlightSpan: Sendable, Hashable {
    public var range: Range<Int>
    public var token: SyntaxToken

    public init(range: Range<Int>, token: SyntaxToken) {
        self.range = range
        self.token = token
    }
}
