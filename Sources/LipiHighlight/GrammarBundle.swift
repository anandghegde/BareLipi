import CTreeSitter
import CTreeSitterGrammars
import Foundation

/// A bundled tree-sitter grammar and its compiled highlights query.
public final class Grammar: @unchecked Sendable {
    /// Stable id (`swift`, `c_sharp`, `tsx`): the grammar directory name.
    public let id: String
    public let displayName: String
    /// Info-string words that select this grammar, lowercased.
    public let aliases: [String]
    /// Whether later patterns in the query override earlier ones for the
    /// same node (Neovim-style queries) rather than the reverse
    /// (tree-sitter-highlight's rule).
    let laterPatternsWin: Bool
    private let languageFunction: @Sendable () -> UnsafeRawPointer?
    private let lock = NSLock()
    private var compiled: HighlightQuery??

    init(_ id: String, _ displayName: String, _ aliases: [String], laterWins: Bool = false,
         _ language: @escaping @Sendable () -> UnsafeRawPointer?) {
        self.id = id
        self.displayName = displayName
        self.aliases = aliases
        laterPatternsWin = laterWins
        languageFunction = language
    }

    var language: OpaquePointer? { languageFunction().map { OpaquePointer($0) } }

    /// The highlights query, compiled on first use (a few ms for the large
    /// grammars). `nil` when the grammar has no query or it fails to compile.
    public var query: HighlightQuery? {
        lock.lock()
        defer { lock.unlock() }
        if let compiled { return compiled }
        var made: HighlightQuery? = nil
        if let language, let source = GrammarQueries.highlights[id], !source.isEmpty {
            made = HighlightQuery(language: language, source: source, laterPatternsWin: laterPatternsWin)
        }
        compiled = .some(made)
        return made
    }
}

/// The grammars bundled with the app (PRD Appendix A.4) and the info-string
/// lookup used by fenced code blocks.
public enum GrammarBundle {
    public static let all: [Grammar] = [
        Grammar("swift", "Swift", ["swift"]) { tree_sitter_swift() },
        Grammar("objc", "Objective-C", ["objc", "objective-c", "objectivec", "obj-c", "objective_c", "m", "mm"], laterWins: true) { tree_sitter_objc() },
        Grammar("c", "C", ["c", "h"]) { tree_sitter_c() },
        Grammar("cpp", "C++", ["cpp", "c++", "cc", "cxx", "hpp", "hxx", "hh"]) { tree_sitter_cpp() },
        Grammar("c_sharp", "C#", ["csharp", "c#", "cs", "c_sharp"]) { tree_sitter_c_sharp() },
        Grammar("java", "Java", ["java"]) { tree_sitter_java() },
        Grammar("kotlin", "Kotlin", ["kotlin", "kt", "kts"]) { tree_sitter_kotlin() },
        Grammar("go", "Go", ["go", "golang"]) { tree_sitter_go() },
        Grammar("rust", "Rust", ["rust", "rs"]) { tree_sitter_rust() },
        Grammar("python", "Python", ["python", "py", "python3", "py3", "gyp"]) { tree_sitter_python() },
        Grammar("ruby", "Ruby", ["ruby", "rb", "gemfile", "rake"]) { tree_sitter_ruby() },
        Grammar("php", "PHP", ["php", "php3", "php4", "php5", "phtml"]) { tree_sitter_php() },
        Grammar("javascript", "JavaScript", ["javascript", "js", "jsx", "mjs", "cjs", "node"]) { tree_sitter_javascript() },
        Grammar("typescript", "TypeScript", ["typescript", "ts", "mts", "cts"]) { tree_sitter_typescript() },
        Grammar("tsx", "TSX", ["tsx"]) { tree_sitter_tsx() },
        Grammar("json", "JSON", ["json", "jsonc", "json5", "geojson", "webmanifest"]) { tree_sitter_json() },
        Grammar("yaml", "YAML", ["yaml", "yml"], laterWins: true) { tree_sitter_yaml() },
        Grammar("toml", "TOML", ["toml"], laterWins: true) { tree_sitter_toml() },
        Grammar("html", "HTML", ["html", "htm", "xhtml"]) { tree_sitter_html() },
        Grammar("css", "CSS", ["css"]) { tree_sitter_css() },
        Grammar("scss", "SCSS", ["scss"], laterWins: true) { tree_sitter_scss() },
        Grammar("bash", "Bash", ["bash", "sh", "shell", "zsh", "ksh", "shellscript", "console", "shell-session"]) { tree_sitter_bash() },
        Grammar("fish", "Fish", ["fish"]) { tree_sitter_fish() },
        Grammar("lua", "Lua", ["lua"], laterWins: true) { tree_sitter_lua() },
        Grammar("haskell", "Haskell", ["haskell", "hs"]) { tree_sitter_haskell() },
        Grammar("elixir", "Elixir", ["elixir", "ex", "exs"]) { tree_sitter_elixir() },
        Grammar("dart", "Dart", ["dart"]) { tree_sitter_dart() },
        Grammar("dockerfile", "Dockerfile", ["dockerfile", "docker", "containerfile"]) { tree_sitter_dockerfile() },
        Grammar("make", "Makefile", ["make", "makefile", "mk", "mak", "gnumakefile"], laterWins: true) { tree_sitter_make() },
        Grammar("diff", "Diff", ["diff", "patch", "udiff"], laterWins: true) { tree_sitter_diff() },
        Grammar("latex", "LaTeX", ["latex", "tex", "sty", "cls"]) { tree_sitter_latex() },
        Grammar("xml", "XML", ["xml", "svg", "plist", "xsd", "xsl", "xslt", "rss", "atom"], laterWins: true) { tree_sitter_xml() },
        Grammar("r", "R", ["r", "rscript"]) { tree_sitter_r() },
        Grammar("julia", "Julia", ["julia", "jl"]) { tree_sitter_julia() },
        Grammar("zig", "Zig", ["zig"], laterWins: true) { tree_sitter_zig() },
        Grammar("graphql", "GraphQL", ["graphql", "gql"]) { tree_sitter_graphql() },
    ]

    private static let byAlias: [String: Grammar] = {
        var map: [String: Grammar] = [:]
        for grammar in all {
            for alias in grammar.aliases where map[alias] == nil { map[alias] = grammar }
        }
        return map
    }()

    /// The grammar a fence's info string names: its first word, lowercased,
    /// with Pandoc's `{.lang}` and `language-` prefixes removed.
    public static func grammar(forInfo info: String) -> Grammar? {
        guard let word = languageWord(info) else { return nil }
        return byAlias[word]
    }

    public static func grammar(id: String) -> Grammar? {
        all.first { $0.id == id }
    }

    static func languageWord(_ info: String) -> String? {
        var word = Substring(info.trimmingCharacters(in: .whitespaces))
        if word.hasPrefix("{") { word = word.dropFirst() }
        word = word.prefix { !$0.isWhitespace && $0 != "," && $0 != "}" && $0 != "{" }
        if word.hasPrefix(".") { word = word.dropFirst() }
        if word.lowercased().hasPrefix("language-") { word = word.dropFirst("language-".count) }
        return word.isEmpty ? nil : word.lowercased()
    }
}
