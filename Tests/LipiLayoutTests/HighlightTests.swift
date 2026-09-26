import Foundation
@testable import LipiHighlight
import Testing

@Suite("Syntax highlighting (P0-05)")
struct HighlightTests {
    /// Text of each span with its token, for readable expectations.
    func tokens(_ code: String, _ info: String) -> [(String, SyntaxToken)] {
        guard let grammar = GrammarBundle.grammar(forInfo: info) else { return [] }
        let utf16 = Array(code.utf16)
        return HighlightService.compute(code: code, grammar: grammar).map {
            (String(decoding: utf16[$0.range], as: UTF16.self), $0.token)
        }
    }

    func has(_ list: [(String, SyntaxToken)], _ text: String, _ token: SyntaxToken) -> Bool {
        list.contains { $0.0 == text && $0.1 == token }
    }

    @Test func bundleCoversAppendixA4() {
        #expect(GrammarBundle.all.count == 36)
        #expect(Set(GrammarBundle.all.map(\.id)).count == 36)
    }

    @Test(arguments: GrammarBundle.all.map(\.id))
    func everyGrammarLoadsAndItsQueryCompiles(id: String) throws {
        let grammar = try #require(GrammarBundle.grammar(id: id))
        #expect(grammar.language != nil)
        let query = try #require(grammar.query)
        #expect(query.patternCount > 0)
        // A few dropped patterns are tolerated (upstream queries drift from
        // their parsers); most of the query must survive.
        #expect(query.droppedPatterns * 4 < query.patternCount, "\(id) dropped \(query.droppedPatterns)/\(query.patternCount)")
    }

    @Test(arguments: [
        ("swift", "swift"), ("Swift", "swift"), ("py", "python"), ("{.python .numberLines}", "python"),
        ("language-rust", "rust"), ("c++", "cpp"), ("objective-c", "objc"), ("sh", "bash"),
        ("yml", "yaml"), ("tsx", "tsx"), ("ts", "typescript"), ("js", "javascript"), ("tex", "latex"),
        ("json title=x", "json"), ("c#", "c_sharp"), ("Makefile", "make"),
    ])
    func infoStringsSelectGrammars(info: String, id: String) {
        #expect(GrammarBundle.grammar(forInfo: info)?.id == id)
    }

    @Test func unknownInfoStringsHaveNoGrammar() {
        #expect(GrammarBundle.grammar(forInfo: "") == nil)
        #expect(GrammarBundle.grammar(forInfo: "mermaid") == nil)
        #expect(GrammarBundle.grammar(forInfo: "text") == nil)
    }

    @Test func captureNamesMapToThemeTokens() {
        #expect(SyntaxToken.forCapture("keyword") == .keyword)
        #expect(SyntaxToken.forCapture("keyword.control.conditional") == .keyword)
        #expect(SyntaxToken.forCapture("function.method.call") == .function)
        #expect(SyntaxToken.forCapture("string.special.url") == .string)
        #expect(SyntaxToken.forCapture("type.builtin") == .type)
        #expect(SyntaxToken.forCapture("number.float") == .number)
        #expect(SyntaxToken.forCapture("comment.documentation") == .comment)
        #expect(SyntaxToken.forCapture("variable.parameter") == nil)
        #expect(SyntaxToken.forCapture("punctuation.bracket") == nil)
        #expect(SyntaxToken.forCapture("diff.plus") == .inserted)
    }

    @Test func swiftTokens() {
        let t = tokens("// hi\nfunc greet(name: String) -> Int {\n    let x = 42\n    return \"é\\(name)\".count\n}\n", "swift")
        #expect(has(t, "// hi", .comment))
        #expect(has(t, "func", .keyword))
        #expect(has(t, "let", .keyword))
        #expect(has(t, "return", .keyword))
        #expect(has(t, "42", .number))
        #expect(t.contains { $0.1 == .string })
        #expect(has(t, "greet", .function))
    }

    @Test func pythonTokens() {
        let t = tokens("def f(x):\n    # note\n    return 'a' + str(1.5)\n", "python")
        #expect(has(t, "def", .keyword))
        #expect(has(t, "f", .function))
        #expect(has(t, "# note", .comment))
        #expect(has(t, "'a'", .string))
        #expect(has(t, "1.5", .number))
    }

    @Test func jsonTokens() {
        let t = tokens("{\"a\": [1, true, null, \"s\"]}", "json")
        #expect(has(t, "1", .number))
        #expect(t.contains { $0.0.contains("\"s\"") && $0.1 == .string })
    }

    @Test func diffLinesUseInsertedAndDeleted() {
        let t = tokens("--- a\n+++ b\n@@ -1 +1 @@\n-old\n+new\n", "diff")
        #expect(t.contains { $0.0.hasPrefix("+new") && $0.1 == .inserted })
        #expect(t.contains { $0.0.hasPrefix("-old") && $0.1 == .deleted })
    }

    @Test func offsetsAreUTF16() {
        // Astral characters are two UTF-16 units; spans after them must not drift.
        let t = tokens("let s = \"😀😀\"; let n = 7", "swift")
        #expect(has(t, "7", .number))
        #expect(t.filter { $0.0 == "let" }.count == 2)
    }

    @Test func spansAreSortedAndDisjoint() {
        for grammar in GrammarBundle.all {
            let spans = HighlightService.compute(code: "a = 1 # x\n\"s\" 'c' // y /* z */ <b>c</b>\n", grammar: grammar)
            for (a, b) in zip(spans, spans.dropFirst()) {
                #expect(a.range.upperBound <= b.range.lowerBound, "\(grammar.id)")
            }
        }
    }

    @Test func lookupSchedulesAndThenAnswersFromCache() {
        let service = HighlightService(capacity: 8)
        service.postsNotifications = false
        let grammar = GrammarBundle.grammar(forInfo: "swift")!
        let first = service.lookup(code: "let a = 1", grammar: grammar)
        #expect(!first.isExact)
        service.waitUntilIdle()
        let second = service.lookup(code: "let a = 1", grammar: grammar)
        #expect(second.isExact)
        #expect(second.spans.contains { $0.token == .keyword })
        #expect(second.stamp != first.stamp)
    }

    @Test func provisionalSpansKeepColoursAroundAnEdit() {
        let service = HighlightService(capacity: 8)
        service.postsNotifications = false
        let grammar = GrammarBundle.grammar(forInfo: "swift")!
        _ = service.highlight(code: "let a = 1\nlet b = 2", grammar: grammar)
        let code = "let a = 10\nlet b = 2"
        let edited = service.lookup(code: code, grammar: grammar)
        #expect(!edited.isExact)
        let utf16 = Array(code.utf16)
        let texts = edited.spans.map { String(decoding: utf16[$0.range], as: UTF16.self) }
        #expect(texts.filter { $0 == "let" }.count == 2)
        #expect(texts.contains("2"))
        service.waitUntilIdle()
    }
}
