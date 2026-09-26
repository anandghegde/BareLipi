import LipiCore
import LipiEditor
import Testing

@Suite("Outline (§6.8)")
@MainActor
struct OutlineTests {
    private func outline(_ text: String) -> Outline {
        EditorController(text: text).makeOutline()
    }

    @Test func headingsLevelsTitlesAndSections() {
        let text = "intro\n\n# One *big*\n\na\n\n## Two `x`\n\nb\n\nSetext\n------\n\n```\n# not a heading\n```\n\n# Three\n"
        let o = outline(text)
        #expect(o.items.map(\.title) == ["One big", "Two x", "Setext", "Three"])
        #expect(o.items.map(\.level) == [1, 2, 2, 1])
        let three = text.utf8.count - "# Three\n".utf8.count
        #expect(o.items[0].section == 7..<three)
        #expect(o.items[1].section.upperBound == o.items[2].section.lowerBound)
        #expect(o.items[2].section.upperBound == three)
        #expect(o.items[3].section.upperBound == text.utf8.count)
        #expect(o.subtree(0) == 0..<3)
        #expect(o.subtree(1) == 1..<2)
    }

    @Test func currentHeadingByBinarySearch() {
        let o = outline("pre\n\n# A\n\ntext\n\n## B\n\nmore")
        #expect(o.current(at: 0) == nil)
        #expect(o.current(at: 5) == 0)
        #expect(o.current(at: 12) == 0)
        #expect(o.current(at: 16) == 1)
        #expect(o.current(at: 100) == 1)
    }

    @Test func githubSlugs() {
        #expect(Outline.slug("Hello, World!") == "hello-world")
        #expect(Outline.slug("API v2.0 — notes_x") == "api-v20--notes_x")
        #expect(Outline.slug("ಕನ್ನಡ ಪಠ್ಯ") == "ಕನ್ನಡ-ಪಠ್ಯ")
        let o = outline("# Intro\n\n# Intro\n\n# Intro-1\n\n# Intro\n")
        #expect(o.items.map(\.slug) == ["intro", "intro-1", "intro-1-1", "intro-2"])
    }

    @Test func moveSectionUpAndDown() {
        let text = "# A\n\na\n\n## A1\n\nx\n\n# B\n\nb\n\n# C\n\nc\n"
        expectEdit("^" + text, "^# B\n\nb\n\n# A\n\na\n\n## A1\n\nx\n\n# C\n\nc\n") { c in
            #expect(c.moveSection(c.makeOutline(), 2, before: 0))
        }
        expectEdit("^" + text, "# B\n\nb\n\n^# A\n\na\n\n## A1\n\nx\n\n# C\n\nc\n") { c in
            #expect(c.moveSection(c.makeOutline(), 0, before: 3))
        }
        expectEdit("^" + text, "# B\n\nb\n\n# C\n\nc\n\n^# A\n\na\n\n## A1\n\nx\n") { c in
            #expect(c.moveSection(c.makeOutline(), 0, before: nil))
        }
    }

    @Test func moveTheLastSectionWithoutAFinalNewline() {
        expectEdit("^# A\r\n\r\na\r\n\r\n# B\r\nb", "^# B\r\nb\r\n\r\n# A\r\n\r\na") { c in
            #expect(c.moveSection(c.makeOutline(), 1, before: 0))
        }
    }

    @Test func moveIntoItselfIsRefused() {
        let c = EditorController(text: "# A\n\n## A1\n\n# B\n")
        let o = c.makeOutline()
        #expect(!c.moveSection(o, 0, before: 1))
        #expect(!c.moveSection(o, 0, before: 0))
        #expect(!c.moveSection(o, 0, before: 2))
        #expect(!c.moveSection(o, 2, before: nil))
        #expect(!c.canUndo)
    }

    @Test func promoteAndDemoteWithSubsections() {
        let text = "# A\n\n## B\n\nC\n---\n\n#### D\n\n# E\n"
        expectEdit(text + "^", "## A\n\n## B\n\nC\n---\n\n#### D\n\n# E\n^") { c in
            #expect(c.shiftSection(c.makeOutline(), 0, by: 1))
        }
        expectEdit(text + "^", "## A\n\n### B\n\n### C\n\n##### D\n\n# E\n^") { c in
            #expect(c.shiftSection(c.makeOutline(), 0, by: 1, subsections: true))
        }
        expectEdit(text + "^", "# A\n\n# B\n\nC\n---\n\n#### D\n\n# E\n^") { c in
            #expect(c.shiftSection(c.makeOutline(), 1, by: -1))
        }
        let c = EditorController(text: text)
        #expect(!c.shiftSection(c.makeOutline(), 0, by: -1))
    }

    @Test func nestedHeadingsInListsAndQuotes() {
        let text = "# Top\n\n- item\n\n  ## In list\n\n  more\n\n> ### Quoted\n\n| a |\n|---|\n| # no |\n\n# Next\n"
        let o = outline(text)
        #expect(o.items.map(\.title) == ["Top", "In list", "Quoted", "Next"])
        #expect(o.items.map(\.isNested) == [false, true, true, false])
        #expect(o.items.map(\.level) == [1, 2, 3, 1])
        let next = text.utf8.count - "# Next\n".utf8.count
        // The top-level section runs over the nested headings to the next top-level one.
        #expect(o.items[0].section == 0..<next)
        // A nested section ends with its container block.
        let quote = Array(text.utf8).firstIndex(of: UInt8(ascii: ">"))!
        #expect(o.items[1].section.upperBound <= quote)
        #expect(o.items[1].section.lowerBound == o.items[1].range.lowerBound)
        #expect(o.current(at: o.items[2].range.lowerBound) == 2)
    }

    @Test func nestedHeadingsAreNotMoved() {
        let c = EditorController(text: "# A\n\n- x\n\n  ## N\n\n# B\n")
        let o = c.makeOutline()
        #expect(o.items.count == 3)
        #expect(!c.moveSection(o, 1, before: 0))
        #expect(!c.moveSection(o, 0, before: 1))
        #expect(!c.canUndo)
        // Promote and demote reach headings inside containers.
        expectEdit("# A\n\n- x\n\n  ## N\n\n> ### Q\n^", "## A\n\n- x\n\n  ### N\n\n> #### Q\n^") { c in
            #expect(c.shiftSection(c.makeOutline(), 0, by: 1, subsections: true))
        }
        // The top-level section moves with its list, nested heading and all.
        expectEdit("^# A\n\n- x\n\n  ## N\n\n# B\n", "^# B\n\n# A\n\n- x\n\n  ## N\n") { c in
            #expect(c.moveSection(c.makeOutline(), 2, before: 0))
        }
    }

    @Test func explicitHeadingIDsAndEmojiInTheOutline() {
        let o = outline("# Intro {#start}\n\n# Party :tada:\n\n# Intro\n")
        #expect(o.items.map(\.title) == ["Intro", "Party 🎉", "Intro"])
        #expect(o.items.map(\.slug) == ["start", "party-", "intro"])
    }
}
