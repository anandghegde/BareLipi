import LipiCore
import LipiEditor
import Testing

@Suite("Link popover model")
@MainActor
struct LinkDraftTests {
    private func draft(_ marked: String, pasteboard: String? = nil) -> LinkDraft {
        let m = parseMarked(marked)
        let c = EditorController(text: m.text)
        c.select(min(m.anchor, m.head)..<max(m.anchor, m.head))
        return c.linkDraft(pasteboard: pasteboard)
    }

    @Test func selectionBecomesTheLabel() {
        let d = draft("see |the docs| now")
        #expect(d.label == "the docs")
        #expect(d.destination == "")
        #expect(d.range == 4..<12)
        #expect(!d.isExisting)
    }

    @Test func pasteboardURLPrefillsTheDestination() {
        #expect(draft("a|b|", pasteboard: "https://example.com/x?y=1").destination == "https://example.com/x?y=1")
        #expect(draft("a|b|", pasteboard: " www.example.com \n").destination == "www.example.com")
        #expect(draft("a|b|", pasteboard: "mailto:a@b.c").destination == "mailto:a@b.c")
        #expect(draft("a|b|", pasteboard: "not a url").destination == "")
        #expect(draft("a|b|", pasteboard: "https://").destination == "")
        #expect(draft("a|b|", pasteboard: "javascript:alert(1)").destination == "")
        #expect(draft("a|b|", pasteboard: nil).destination == "")
    }

    @Test func existingLinkUnderTheCaretIsPrefilled() {
        let d = draft("x [the **site**](https://a.b \"Home\")| y", pasteboard: "https://other")
        #expect(d.isExisting)
        #expect(d.label == "the **site**")
        #expect(d.destination == "https://a.b")
        #expect(d.title == "Home")
        #expect(d.range == 2..<36)
        #expect(draft("x [a](u|) y").label == "a")
        #expect(draft("x [a [b] c](u|) y").label == "a [b] c")
        #expect(!draft("x <https://a.b|> y").isExisting)
    }

    @Test func commitEditsTheExistingLink() {
        expectCommand("x [a](https://old|) y", "x [b](https://new \"T\")| y") { c in
            var d = c.linkDraft()
            d.label = "b"; d.destination = "https://new"; d.title = "T"
            c.commitLink(d)
        }
    }

    @Test func commitWithAnEmptyDestinationUnlinks() {
        expectCommand("x [a *b*](u|) y", "x a *b*| y") { c in
            var d = c.linkDraft()
            d.destination = ""
            c.commitLink(d)
        }
    }

    @Test func commitWrapsTheSelection() {
        expectCommand("x |site| y", "x [site](https://s.t)| y") { c in
            c.commitLink(c.linkDraft(pasteboard: "https://s.t"))
        }
        expectCommand("x | y", "x [new](<a b>)| y") { c in
            var d = c.linkDraft()
            d.label = "new"; d.destination = "a b"
            c.commitLink(d)
        }
    }

    @Test func commitInACRLFDocumentKeepsOtherBytes() {
        expectCommand("a\r\n[l](u|)\r\nb", "a\r\n[l](v)|\r\nb") { c in
            var d = c.linkDraft()
            d.destination = "v"
            c.commitLink(d)
        }
    }
}
