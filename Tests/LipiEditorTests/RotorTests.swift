import AppKit
import LipiCore
import LipiEditor
import Testing

@Suite("Accessibility rotors (§6.20)")
@MainActor
struct RotorTests {
    let text = "# Title\n\nSee [the site](https://a.b) and ![logo](l.png).\n\n> ## Quoted\n\n| a | b |\n| - | - |\n| c | d |\n\n```swift\nlet x = 1\n```\n\n[two](u)\n"

    @Test func targetsOfEachKind() {
        let c = EditorController(text: text)
        #expect(c.navigationTargets(.heading).map(\.label) == ["Heading level 1, Title", "Heading level 2, Quoted"])
        #expect(c.navigationTargets(.link).map(\.label) == ["the site", "two"])
        #expect(c.navigationTargets(.image).map(\.label) == ["Image, logo"])
        #expect(c.navigationTargets(.table).map(\.label) == ["Table, 2 rows, 2 columns"])
        #expect(c.navigationTargets(.codeBlock).map(\.label) == ["Code block, swift"])
    }

    @Test func rotorStepsForwardAndBackFromTheCaretOrItem() {
        let view = EditorView(controller: EditorController(text: text))
        let first = view.rotorTarget(.heading, after: nil, forward: true)
        #expect(first?.label == "Heading level 1, Title")
        // Ranges are in the accessibility text, where "# Title" reads "Title".
        #expect(first?.range == NSRange(location: 0, length: 5))
        let second = view.rotorTarget(.heading, after: first?.range, forward: true)
        #expect(second?.label == "Heading level 2, Quoted")
        #expect(view.rotorTarget(.heading, after: second?.range, forward: true) == nil)
        #expect(view.rotorTarget(.heading, after: second?.range, forward: false)?.label == "Heading level 1, Title")
        #expect(view.rotorTarget(.link, after: nil, forward: true, filter: "TWO")?.label == "two")
        #expect(view.accessibilityCustomRotors().count == 5)
    }
}
