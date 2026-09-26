import AppKit
import LipiCore
@testable import LipiEditor
import Testing

@Suite("Accessibility text over the projection (§6.20)")
@MainActor
struct AccessibilityTests {
    let doc = "# Title\n\nSome **bold** and *it* with [link](https://example.com/a) and `code` and ~~gone~~.\n\n| h1 | h2 |\n| -- | -- |\n| a | b |\n| c | d |\n\n```swift\nlet x = 1\n```\n"

    @Test func valueIsTheFoldedProjection() {
        let view = makeView(doc)
        let value = view.accessibilityValue() as? String ?? ""
        #expect(value.hasPrefix("Title\nSome bold and it with link"))
        #expect(value.contains("h1\th2\na\tb\nc\td"))
        #expect(value.hasSuffix("let x = 1"))
        #expect(!value.contains("**") && !value.contains("#") && !value.contains("```"))
    }

    @Test func valueStaysPutWhileTheCaretRevealsSyntax() {
        let view = makeView(doc)
        let before = view.accessibilityValue() as? String
        view.controller.moveCaret(to: 3)  // inside the heading: "# " is revealed on screen
        #expect(view.accessibilityValue() as? String == before)
        // The caret inside the revealed marker maps onto the heading text.
        #expect(view.accessibilitySelectedTextRange() == NSRange(location: 1, length: 0))
    }

    @Test func offsetsRoundTripThroughTheOffsetMap() {
        let view = makeView(doc)
        let text = view.accessibilityText
        let value = text.string
        let bold = value.range(of: "bold")
        let source = text.sourceRange(for: bold)
        #expect(view.controller.string(in: source) == "bold")
        #expect(text.range(forSource: source) == bold)
        view.setAccessibilitySelectedTextRange(bold)
        #expect(view.accessibilitySelectedText() == "bold")
        #expect(view.controller.selection.range == source)
        // Offsets in plain and styled text round-trip through the source.
        let span = value.range(of: "Some bold and it with")
        for o in span.location...(span.location + span.length) {
            #expect(text.offset(forSource: text.sourceOffset(at: o)) == o, "offset \(o)")
        }
    }

    @Test func attributesCarryHeadingEmphasisLinksCodeAndStrike() {
        let view = makeView(doc)
        let value = view.accessibilityText.string
        let all = NSRange(location: 0, length: value.length)
        let attributed = view.accessibilityAttributedString(for: all)!
        #expect(attributed.string == value as String)
        let title = value.range(of: "Title")
        #expect(attributed.attribute(.accessibilityHeadingLevel, at: title.location, effectiveRange: nil) as? Int == 1)
        #expect(attributed.attribute(.accessibilityHeadingLevel, at: value.range(of: "Some").location, effectiveRange: nil) == nil)
        func font(_ word: String) -> [NSAccessibility.FontAttributeKey: Any] {
            let r = value.range(of: word)
            let at = word.hasPrefix(" ") ? r.location + 1 : r.location
            return attributed.attribute(.accessibilityFont, at: at, effectiveRange: nil) as? [NSAccessibility.FontAttributeKey: Any] ?? [:]
        }
        let boldName = (font("bold")[.fontName] as? String ?? "").lowercased()
        let plainName = (font("Some")[.fontName] as? String ?? "").lowercased()
        #expect(boldName != plainName && boldName.contains("bold"), "\(boldName)")
        #expect((font(" it ")[.fontName] as? String ?? "").lowercased().contains("italic"))
        #expect(font("Title")[.fontSize] as? CGFloat ?? 0 > font("Some")[.fontSize] as? CGFloat ?? 0)
        let link = attributed.attribute(.accessibilityLink, at: value.range(of: "link").location, effectiveRange: nil) as? URL
        #expect(link?.absoluteString == "https://example.com/a")
        #expect(attributed.attribute(.accessibilityCode, at: value.range(of: "code").location, effectiveRange: nil) as? Bool == true)
        #expect(attributed.attribute(.accessibilityStrikethrough, at: value.range(of: "gone").location, effectiveRange: nil) as? Bool == true)
        // A sub-range starts its attributes at zero.
        let sub = view.accessibilityAttributedString(for: value.range(of: "bold"))!
        #expect(sub.string == "bold")
        #expect(sub.attribute(.accessibilityFont, at: 0, effectiveRange: nil) != nil)
    }

    @Test func misspellingsComeFromTheHook() {
        let view = makeView("Teh **cat** sat.")
        view.misspelledRanges = { range in
            // "Teh" at bytes 0..<3, if the requested range covers it.
            range.overlaps(0..<3) ? [0..<3] : []
        }
        let attributed = view.accessibilityAttributedString(for: NSRange(location: 0, length: 11))!
        #expect(attributed.string == "Teh cat sat")
        #expect(attributed.attribute(.accessibilityMarkedMisspelled, at: 1, effectiveRange: nil) as? Bool == true)
        #expect(attributed.attribute(.accessibilityMarkedMisspelled, at: 5, effectiveRange: nil) == nil)
    }

    @Test func editingThroughTheValueKeepsHiddenSyntax() {
        let view = makeView("# Title\n\nSome **bold** text.\n")
        var value = view.accessibilityValue() as? String ?? ""
        #expect(value == "Title\nSome bold text.")
        value = value.replacingOccurrences(of: "bold", with: "brave")
        view.setAccessibilityValue(value)
        #expect(view.controller.string == "# Title\n\nSome **brave** text.\n")
        // One undo step.
        view.controller.undo()
        #expect(view.controller.string == "# Title\n\nSome **bold** text.\n")
        view.setAccessibilitySelectedTextRange(NSRange(location: 6, length: 0))
        view.setAccessibilitySelectedText("Big ")
        #expect(view.controller.string == "# Title\n\nBig Some **bold** text.\n")
    }

    @Test func codeBlocksAndTablesAreChildren() {
        let view = makeView(doc)
        let islands = view.accessibilityIslands(all: true)
        #expect(islands.count == 2)
        let table = islands.first { $0.accessibilityRole() == .table }
        let code = islands.first { $0.accessibilityRole() == .textArea }
        #expect(code?.accessibilityRoleDescription() == "swift")
        #expect(code?.accessibilityValue() as? String == "let x = 1")
        #expect(code?.accessibilityParent() as? EditorView === view)
        #expect(table?.accessibilityRowCount() == 3)
        #expect(table?.accessibilityColumnCount() == 2)
        let rows = table?.accessibilityRows() as? [NSAccessibilityElement] ?? []
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.accessibilityRole() == .row })
        let cells = rows[2].accessibilityChildren() as? [NSAccessibilityElement] ?? []
        #expect(cells.map { $0.accessibilityValue() as? String } == ["c", "d"])
        #expect(cells[1].accessibilityRowIndexRange() == NSRange(location: 2, length: 1))
        #expect(cells[1].accessibilityColumnIndexRange() == NSRange(location: 1, length: 1))
        #expect(cells[1].accessibilityLabel() == "h2: d")
        let headers = table?.accessibilityColumnHeaderUIElements() as? [NSAccessibilityElement] ?? []
        #expect(headers.map { $0.accessibilityValue() as? String } == ["h1", "h2"])
        // On-screen children come from the visible entries.
        #expect(view.accessibilityChildren()?.count == 2)
    }

    @Test func headingNavigationLandsOnHeadingText() {
        let view = makeView("# One\n\npara\n\n## Two\n")
        let first = view.rotorTarget(.heading, after: nil, forward: true)
        #expect(first.map { view.accessibilityString(for: $0.range) } == "One")
        let second = view.rotorTarget(.heading, after: first?.range, forward: true)
        #expect(second.map { view.accessibilityString(for: $0.range) } == "Two")
        #expect(second.map { view.accessibilityAttributedString(for: $0.range)?.attribute(.accessibilityHeadingLevel, at: 0, effectiveRange: nil) as? Int } == 2)
    }

    @Test func sourceModeSpeaksTheSource() {
        let view = makeView("# Title\n\n**b**\n")
        view.controller.setMode(.source)
        #expect(view.accessibilityValue() as? String == "# Title\n\n**b**\n")
    }
}
