import LipiCore
import Testing

@Suite("Counts (§6.18)")
struct CountTests {
    private func counts(_ text: String, _ options: CountOptions = CountOptions()) -> TextCounts {
        var parser = LipiParser(options: .editor)
        let rope = LipiRope(text)
        parser.parse(rope)
        var counter = DocumentCounter(options: options)
        return counter.document(index: parser.index, rope: rope)
    }

    private func selection(_ text: String, _ range: Range<Int>) -> TextCounts {
        var parser = LipiParser(options: .editor)
        let rope = LipiRope(text)
        parser.parse(rope)
        var counter = DocumentCounter()
        return counter.selection(range, index: parser.index, rope: rope)
    }

    @Test func plainText() {
        let c = TextCounts.of("Hello, brave new world.")
        #expect(c.words == 4)
        #expect(c.characters == 23)
        #expect(c.charactersExcludingSpaces == 20)
    }

    @Test func markupIsNotCounted() {
        let c = counts("# Title here\n\nSome **bold** and [a link](https://example.com/long/path) text.\n")
        #expect(c.words == 8)
        #expect(c.characters == "Title here".count + "Some bold and a link text.".count)
    }

    @Test func frontMatterIsExcludedAndCodeAndMathAreToggled() {
        let text = "---\ntitle: A long front matter title\n---\n\nOne two $x + y$\n\n```\nlet three = 3\n```\n"
        #expect(counts(text).words == 2 + 2 + 3)
        #expect(counts(text, CountOptions(includeCode: false)).words == 2 + 2)
        #expect(counts(text, CountOptions(includeCode: false, includeMath: false)).words == 2)
    }

    @Test func listsQuotesAndTablesCountTheirText() {
        let c = counts("- one\n- two three\n\n> four\n\n| five | six |\n| - | - |\n| seven | eight |\n")
        #expect(c.words == 8)
    }

    @Test func indicAndCJKWords() {
        #expect(TextCounts.of("ನಮಸ್ಕಾರ ಕನ್ನಡ").words == 2)
        #expect(TextCounts.of("नमस्ते दुनिया").words == 2)
        #expect(TextCounts.of("வணக்கம் உலகம்").words == 2)
        #expect(TextCounts.of("日本語", cjkByCharacter: true).words == 3)
        #expect(TextCounts.of("日本語").words >= 1)
        #expect(TextCounts.of("日本語").characters == 3)
    }

    @Test func readingTime() {
        #expect(TextCounts(words: 0).readingMinutes() == 0)
        #expect(TextCounts(words: 1).readingMinutes() == 1)
        #expect(TextCounts(words: 275).readingMinutes() == 1)
        #expect(TextCounts(words: 276).readingMinutes() == 2)
        #expect(TextCounts(words: 1000).readingMinutes(wordsPerMinute: 200) == 5)
    }

    @Test func selectionCountsOnlyTheSelectedText() {
        let text = "alpha beta gamma\n\ndelta **epsilon** zeta\n"
        #expect(selection(text, 6..<10).words == 1)
        #expect(selection(text, 0..<text.utf8.count).words == 6)
        // From "gamma" into "delta **epsilon**".
        let c = selection(text, 11..<35)
        #expect(c.words == 3)
        #expect(selection(text, 3..<3) == .zero)
    }

    @Test func cacheIsReusedAcrossEdits() {
        var buffer = SourceBuffer("one\n\ntwo three\n\nfour\n")
        var parser = LipiParser(options: .editor)
        parser.parse(buffer.rope)
        var counter = DocumentCounter()
        #expect(counter.document(index: parser.index, rope: buffer.rope).words == 4)
        #expect(counter.cachedBlocks == 3)
        let delta = buffer.apply(Edit(replacing: 5..<5, with: "and "))
        parser.apply(delta, then: buffer.rope)
        #expect(counter.document(index: parser.index, rope: buffer.rope).words == 5)
        #expect(counter.document(index: parser.index, rope: buffer.rope).words == 5)
        counter.options.includeCode = false
        #expect(counter.cachedBlocks == 0)
        #expect(counter.document(index: parser.index, rope: buffer.rope).words == 5)
    }
}
