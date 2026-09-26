import Foundation
@testable import LipiCore
import Testing

@Suite("Document search")
struct DocumentSearchTests {
    func find(_ pattern: String, in text: String, caseSensitive: Bool = false, wholeWord: Bool = false, regex: Bool = false) throws -> [String] {
        let rope = LipiRope(text)
        return try DocumentSearch.matches(of: FindQuery(pattern, caseSensitive: caseSensitive, wholeWord: wholeWord, isRegex: regex), in: rope)
            .map { rope.string(in: $0) }
    }

    @Test func literalIgnoresCaseByDefault() throws {
        #expect(try find("the", in: "The cat and the THE") == ["The", "the", "THE"])
        #expect(try find("the", in: "The cat and the THE", caseSensitive: true) == ["the"])
    }

    @Test func matchesAreByteRangesAndDoNotOverlap() throws {
        let rope = LipiRope("aaaa ಕನ್ನಡ aa")
        let m = try DocumentSearch.matches(of: FindQuery("aa"), in: rope)
        #expect(m.count == 3)
        #expect(m[0] == 0..<2 && m[1] == 2..<4)
        let k = try DocumentSearch.matches(of: FindQuery("ನ್ನ"), in: rope)
        #expect(k.count == 1)
        #expect(rope.string(in: k[0]) == "ನ್ನ")
        #expect(rope.isScalarBoundary(at: k[0].lowerBound) && rope.isScalarBoundary(at: k[0].upperBound))
    }

    @Test func wholeWord() throws {
        #expect(try find("cat", in: "cat concat cat_x cats (cat)", wholeWord: true) == ["cat", "cat"])
        #expect(try find("ನ", in: "ನ ನಡ", wholeWord: true) == ["ನ"])
        // A punctuation edge needs no boundary.
        #expect(try find("-x", in: "a-x b-xy", wholeWord: true) == ["-x"])
    }

    @Test func nonASCIIIgnoresCaseThroughICU() throws {
        #expect(try find("Ärger", in: "ärger ÄRGER Ärger") == ["ärger", "ÄRGER", "Ärger"])
        #expect(try find("ΣΟΦΙΑ", in: "σοφια Σοφια") == ["σοφια", "Σοφια"])
    }

    @Test func regex() throws {
        #expect(try find(#"\d+"#, in: "a1 b22 c333", regex: true) == ["1", "22", "333"])
        #expect(try find("^#+ ", in: "# One\ntext\n## Two", regex: true) == ["# ", "## "])
        // Empty matches are skipped.
        #expect(try find("x*", in: "axxb", regex: true) == ["xx"])
        #expect(try find("ಕ.", in: "ಕನ್ನಡ ಕಾ", regex: true) == ["ಕನ", "ಕಾ"])
        #expect(throws: FindError.self) { try find("(", in: "(", regex: true) }
    }

    @Test func literalPatternsAreNotRegex() throws {
        #expect(try find("a.b", in: "a.b axb") == ["a.b"])
        #expect(try find("(ö)", in: "(Ö) (o)") == ["(Ö)"])
    }

    @Test func replaceAllChangesOnlyMatches() throws {
        let text = "one two one\r\nthree one"
        var rope = LipiRope(text)
        let edits = try DocumentSearch.replaceAllEdits(of: FindQuery("one"), in: SearchText(rope), template: "1")
        #expect(edits.count == 3)
        for e in edits.sorted(by: { $0.range.lowerBound.byte > $1.range.lowerBound.byte }) { rope.apply(e) }
        #expect(rope.string == "1 two 1\r\nthree 1")
    }

    @Test func regexReplacementExpandsTemplates() throws {
        var rope = LipiRope("x=1, y=22")
        let query = FindQuery(#"(\w)=(\d+)"#, isRegex: true)
        let edits = try DocumentSearch.replaceAllEdits(of: query, in: SearchText(rope), template: "$2:$1")
        for e in edits.reversed() { rope.apply(e) }
        #expect(rope.string == "1:x, 22:y")
        let one = LipiRope("a b=3 c")
        let r = try DocumentSearch.matches(of: query, in: one)[0]
        #expect(try DocumentSearch.replacement(for: r, of: query, in: one, template: "[$2]") == "[3]")
        // Look-behind sees text outside the match.
        let lb = FindQuery(#"(?<=b=)\d"#, isRegex: true)
        let r2 = try DocumentSearch.matches(of: lb, in: one)[0]
        #expect(try DocumentSearch.replacement(for: r2, of: lb, in: one, template: "9") == "9")
    }

    @Test func renderedScopeSkipsSyntax() throws {
        let rope = LipiRope("Some **bold** text and [link](http://bold.example)\n")
        var parser = LipiParser(options: .editor)
        parser.parse(rope)
        var projection = Projection()
        projection.update(index: parser.index, rope: rope, reveal: RevealSet())
        let rendered = try DocumentSearch.renderedMatches(of: FindQuery("bold"), in: projection)
        #expect(rendered.map { rope.string(in: $0) } == ["bold"])
        #expect(try DocumentSearch.matches(of: FindQuery("bold"), in: rope).count == 2)
        let across = try DocumentSearch.renderedMatches(of: FindQuery("bold text"), in: projection)
        #expect(across.map { rope.string(in: $0) } == ["bold** text"])
        #expect(try DocumentSearch.renderedMatches(of: FindQuery("**"), in: projection).isEmpty)
    }
}
