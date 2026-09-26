import AppKit
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

    // MARK: The AppKit form

    @Test func formIsPrefilledFromTheDraft() {
        let c = EditorController(text: "x [a](u \"t\") y")
        c.select(4..<4)
        let form = LinkFormController(draft: c.linkDraft(pasteboard: "https://other"))
        #expect(form.labelField.stringValue == "a")
        #expect(form.urlField.stringValue == "u")
        #expect(form.titleField.stringValue == "t")
        #expect(form.draft == c.linkDraft())
    }

    @Test func formCommitReplacesTheExistingLinkAsOneUndoStep() {
        let text = "a\r\n\r\nx [a](u \"t\") y\r\n"
        let c = EditorController(text: text)
        c.select(10..<10)
        let form = LinkFormController(draft: c.linkDraft())
        var committed: LinkDraft?
        form.onCommit = { committed = $0 }
        form.labelField.stringValue = "b"
        form.urlField.stringValue = "https://v"
        form.titleField.stringValue = ""
        form.commit(nil)
        guard let committed else { Issue.record("no commit"); return }
        c.commitLink(committed)
        #expect(c.string == "a\r\n\r\nx [b](https://v) y\r\n")
        #expect(c.selection.head == 21)
        c.undo()
        #expect(c.string == text)
    }

    @Test func formInsertsFromThePasteboardURL() {
        let c = EditorController(text: "one\r\nsee the docs\r\n")
        c.select(9..<17)
        let form = LinkFormController(draft: c.linkDraft(pasteboard: "https://d.x"))
        var committed: LinkDraft?
        form.onCommit = { committed = $0 }
        form.titleField.stringValue = "Docs"
        form.commit(nil)
        c.commitLink(committed!)
        #expect(c.string == "one\r\nsee [the docs](https://d.x \"Docs\")\r\n")
    }

    @Test func formRemoveLinkUnlinks() {
        let c = EditorController(text: "x [a](u) y")
        c.select(3..<3)
        let form = LinkFormController(draft: c.linkDraft())
        var committed: LinkDraft?
        form.onCommit = { committed = $0 }
        form.removeLink(nil)
        c.commitLink(committed!)
        #expect(c.string == "x a y")
    }

    @Test func returnCommitsAndEscCancelsInAField() {
        let form = LinkFormController(draft: LinkDraft(label: "", destination: "", title: "", range: 0..<0, isExisting: false))
        var commits = 0, cancels = 0
        form.onCommit = { _ in commits += 1 }
        form.onCancel = { cancels += 1 }
        let editor = NSTextView()
        #expect(form.control(form.urlField, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(form.control(form.urlField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(!form.control(form.urlField, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        #expect(commits == 1 && cancels == 1)
    }

    @Test func formOffersRemoveOnlyForAnExistingLink() {
        func titles(_ d: LinkDraft) -> [String] {
            let form = LinkFormController(draft: d)
            var out: [String] = []
            var queue = [form.view]
            while !queue.isEmpty {
                let v = queue.removeFirst()
                if let b = v as? NSButton { out.append(b.title) }
                queue += v.subviews
            }
            return out
        }
        #expect(titles(LinkDraft(label: "a", destination: "u", title: "", range: 0..<8, isExisting: true)) == ["Remove Link", "Cancel", "Update"])
        #expect(titles(LinkDraft(label: "", destination: "", title: "", range: 0..<0, isExisting: false)) == ["Cancel", "Insert"])
    }
}
