import AppKit
import LipiCore
import LipiEditor
import LipiFixtures
import LipiLayout
import Testing

/// Draws the view headless into a bitmap the size of its bounds.
@MainActor
func render(_ view: EditorView) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    let cg = ctx.cgContext
    cg.translateBy(x: 0, y: view.bounds.height)
    cg.scaleBy(x: 1, y: -1)
    view.render(in: cg, dirty: view.bounds)
    return rep
}

@MainActor
func makeView(_ text: String, engine: LayoutEngineKind = .lipi, width: CGFloat = 800) -> EditorView {
    let controller = EditorController(text: text, engine: engine, viewportWidth: width)
    let view = EditorView(controller: controller, frame: NSRect(x: 0, y: 0, width: width, height: 600))
    view.caretBlinks = false
    view.alwaysShowsCaret = true
    return view
}

func nsRange(_ location: Int, _ length: Int = 0) -> NSRange { NSRange(location: location, length: length) }
let noRange = NSRange(location: NSNotFound, length: 0)

@Suite("Editor controller")
@MainActor
struct EditorControllerTests {
    @Test func typingRunsThePipeline() {
        let c = EditorController(text: "Hello world")
        c.moveCaret(to: 5)
        let change = c.insert(",")
        #expect(c.string == "Hello, world")
        #expect(c.caret == 6)
        #expect(change.textChanged && !change.structureChanged)
        #expect(change.caretRect.height > 0)
        #expect(change.caretRect.minX > c.layout.textOrigin)
        #expect(c.stats.keystrokes == 1)
        // The caret rect matches the layout's own answer.
        #expect(change.caretRect == c.layout.caretRect(forSource: 6))
    }

    @Test func newlineSplitsAnEntry() {
        let c = EditorController(text: "one two")
        c.moveCaret(to: 3)
        let change = c.insertNewline()
        #expect(c.string == "one\n two")
        let second = c.insert("\n")
        #expect(second.structureChanged)
        #expect(c.projection.entries.count == 2)
        #expect(c.layout.entryCount == 2)
        #expect(change.caretRect.minY <= second.caretRect.minY)
    }

    @Test func undoCoalescesTypingAndRestoresTheCaret() {
        let c = EditorController(text: "ab")
        c.moveCaret(to: 2)
        c.insert("c"); c.insert("d"); c.insert("e")
        #expect(c.string == "abcde")
        c.undo()
        #expect(c.string == "ab")
        #expect(c.caret == 2)
        c.redo()
        #expect(c.string == "abcde")
        #expect(c.caret == 5)
        // A caret move ends the typing group.
        c.insert("f"); c.moveCaret(to: 0); c.moveCaret(to: 6); c.insert("g")
        c.undo()
        #expect(c.string == "abcdef")
    }

    @Test func kannadaClusterDeletionAndMotion() {
        // ಕ್ಷೇತ್ರ is ಕ ್ ಷ ೇ ತ ್ ರ: two grapheme clusters (ಕ್ಷೇ and ತ್ರ).
        let word = "ಕ್ಷೇತ್ರ"
        let c = EditorController(text: word)
        #expect(c.count == word.utf8.count)
        c.moveCaret(to: c.count)
        c.deleteBackward()
        #expect(c.string == "ಕ್ಷೇ")
        #expect(c.caret == c.count)
        c.moveCaret(to: 0)
        c.move(.right)
        #expect(c.caret == c.count, "one right step crosses the whole cluster")
        c.move(.left)
        #expect(c.caret == 0)
        c.deleteForward()
        #expect(c.string == "")
    }

    @Test func devanagariAndEmojiClusters() {
        let text = "ज्ञान 👩‍👩‍👧 x"
        let c = EditorController(text: text)
        var stops = [0]
        while stops.last! < c.count { stops.append(c.nextCaretStop(after: stops.last!)) }
        // ज्ञा | न | space | family | space | x  → 6 clusters, 7 stops.
        #expect(stops.count == 7, "\(stops)")
        var back = [c.count]
        while back.last! > 0 { back.append(c.previousCaretStop(before: back.last!)) }
        #expect(back.reversed() == stops)
    }

    @Test func caretStepsOverFoldedSyntaxOneStopAtATime() {
        let c = EditorController(text: "a **bold** b")
        // Caret after "a " (offset 2): the next stops walk through the
        // revealed delimiters once the caret is inside the strong span.
        c.moveCaret(to: 2)
        var seen: [Int] = [2]
        for _ in 0..<12 {
            c.move(.right)
            if seen.last == c.caret { break }
            seen.append(c.caret)
        }
        #expect(seen.last == c.count)
        #expect(seen == Array(2...c.count), "\(seen)")
    }

    @Test func markedTextFreezesTheRevealSetAndCommits() {
        let c = EditorController(text: "see *it* now")
        c.moveCaret(to: c.count)
        c.setMarkedText("か", selected: nsRange(1))
        #expect(c.hasMarkedText)
        #expect(c.string == "see *it* nowか")
        #expect(c.marked?.range == 12..<15)
        c.setMarkedText("かん", selected: nsRange(2))
        #expect(c.string == "see *it* nowかん")
        #expect(c.marked?.range == 12..<18)
        #expect(c.caret == 18)
        // Composition with a partial selection inside the marked text.
        c.setMarkedText("感", selected: nsRange(0, 1))
        #expect(c.string == "see *it* now感")
        #expect(c.selection.range == 12..<15)
        c.unmarkText()
        #expect(!c.hasMarkedText)
        #expect(c.string == "see *it* now感")
        // Committing through insert replaces the composition.
        c.moveCaret(to: c.count)
        c.setMarkedText("k", selected: nsRange(1))
        c.insert("漢字")
        #expect(c.string == "see *it* now感漢字")
        #expect(!c.hasMarkedText)
    }

    @Test func verticalMotionKeepsTheGoalColumn() {
        let c = EditorController(text: "first line of text\n\nsecond\n\nthird line here", viewportWidth: 800)
        c.moveCaret(to: 10)
        let x = c.caretRect(forSource: 10).minX
        c.move(.down)
        #expect(c.projection.entryIndex(containing: c.caret) == 1)
        #expect(c.caret == 20 + 6, "snaps to the end of the short line")
        c.move(.down)
        #expect(c.projection.entryIndex(containing: c.caret) == 2)
        #expect(abs(c.caretRect(forSource: c.caret).minX - x) < 12)
        c.move(.up); c.move(.up)
        #expect(c.caret == 10)
        c.move(.up)
        #expect(c.caret == 0)
    }

    @Test func lineStartAndEndAndWords() {
        let c = EditorController(text: "alpha beta gamma\n\ndelta")
        c.moveCaret(to: 7)
        c.move(.lineEnd)
        #expect(c.caret == 16)
        c.move(.lineStart)
        #expect(c.caret == 0)
        c.move(.wordRight)
        #expect(c.caret == 5)
        c.move(.wordRight)
        #expect(c.caret == 10)
        c.move(.wordLeft)
        #expect(c.caret == 6)
        #expect(c.wordRange(at: 12) == 11..<16)
    }

    @Test func selectionRectsCoverTheSelectedText() {
        let c = EditorController(text: "The quick brown fox jumps over the lazy dog, again and again and again, until it wraps.", viewportWidth: 500)
        c.layout.layoutAll()
        c.select(4..<9)
        let rects = c.rects(forSource: 4..<9, visible: CGRect(x: 0, y: 0, width: 500, height: 600))
        #expect(rects.count == 1)
        #expect(rects[0].width > 20 && rects[0].height > 0)
        #expect(abs(rects[0].minX - c.caretRect(forSource: 4).minX) < 0.01)
        let all = c.rects(forSource: 0..<c.count, visible: CGRect(x: 0, y: 0, width: 500, height: 600))
        #expect(all.count >= 2, "the sentence wraps at 500 pt")
    }

    @Test func textKit2ModeRunsTheSamePipeline() {
        let c = EditorController(text: "# Title\n\nBody text here.\n\n- item", engine: .textkit2, viewportWidth: 800)
        #expect(c.textKit != nil)
        c.moveCaret(to: 13)
        let change = c.insert("X")
        #expect(c.string == "# Title\n\nBodyX text here.\n\n- item")
        #expect(change.caretRect.height > 0 && change.caretRect.minY > 0)
        let hit = c.sourceOffset(at: CGPoint(x: change.caretRect.minX + 0.5, y: change.caretRect.midY))
        #expect(hit == 14)
        c.insertNewline(); c.insertNewline()
        #expect(c.projection.entries.count == 4)
        #expect(c.textKit?.entryRanges.count == 4)
        #expect(c.contentHeight > 0)
        let rects = c.rects(forSource: 9..<13, visible: CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(rects.count == 1)
    }

    @Test func themeChangeRelaysOutEverything() {
        let c = EditorController(text: "Some text\n\nMore text")
        let before = c.caretRect(forSource: 12)
        c.setTheme(.paper, zoom: 1.5)
        let after = c.caretRect(forSource: 12)
        #expect(after.height > before.height)
    }
}

@Suite("Editor view")
@MainActor
struct EditorViewTests {
    @Test func insertTextAndSelectedRangeInUTF16() {
        let view = makeView("ಕನ್ನಡ text")
        view.insertText("A", replacementRange: noRange)
        #expect(view.controller.string == "Aಕನ್ನಡ text")
        #expect(view.selectedRange() == nsRange(1))
        view.controller.moveCaret(to: view.controller.count)
        // "Aಕನ್ನಡ text" is 1 + 5 + 5 UTF-16 units.
        #expect(view.selectedRange() == nsRange(11))
        view.insertText("!", replacementRange: nsRange(0, 1))
        #expect(view.controller.string == "!ಕನ್ನಡ text")
        #expect(view.selectedRange() == nsRange(1))
    }

    @Test func markedTextRoundTrip() {
        let view = makeView("abc")
        view.controller.moveCaret(to: 3)
        #expect(!view.hasMarkedText())
        #expect(view.markedRange() == noRange)
        view.setMarkedText("にほ", selectedRange: nsRange(2), replacementRange: noRange)
        #expect(view.hasMarkedText())
        #expect(view.markedRange() == nsRange(3, 2))
        #expect(view.selectedRange() == nsRange(5))
        view.setMarkedText(NSAttributedString(string: "日本"), selectedRange: nsRange(2), replacementRange: noRange)
        #expect(view.markedRange() == nsRange(3, 2))
        view.insertText("日本語", replacementRange: noRange)
        #expect(!view.hasMarkedText())
        #expect(view.controller.string == "abc日本語")
        #expect(view.selectedRange() == nsRange(6))
        let sub = view.attributedSubstring(forProposedRange: nsRange(3, 3), actualRange: nil)
        #expect(sub?.string == "日本語")
        let rect = view.firstRect(forCharacterRange: nsRange(3, 3), actualRange: nil)
        #expect(rect.width > 1 && rect.height > 0)
        let index = view.characterIndex(for: NSPoint(x: rect.minX + 1, y: rect.midY))
        #expect(index == 3)
    }

    @Test func keyboardCommandsGoThroughDoCommand() {
        let view = makeView("hello world")
        view.controller.moveCaret(to: 11)
        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(view.controller.string == "hello worl")
        view.doCommand(by: #selector(NSResponder.moveWordLeft(_:)))
        #expect(view.controller.caret == 6)
        view.doCommand(by: #selector(NSResponder.moveToEndOfLineAndModifySelection(_:)))
        #expect(view.selectedRange() == nsRange(6, 4))
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(view.controller.string == "hello \n")
        view.doCommand(by: #selector(NSResponder.selectAll(_:)))
        #expect(view.selectedRange() == nsRange(0, 7))
        view.undo(nil)
        #expect(view.controller.string == "hello worl")
    }

    @Test func accessibilityDescribesTheDocument() {
        let text = "# Heading\n\nParagraph with ಕನ್ನಡ."
        let view = makeView(text)
        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityRole() == .textArea)
        #expect(view.accessibilityValue() as? String == text)
        #expect(view.accessibilityNumberOfCharacters() == (text as NSString).length)
        view.setAccessibilitySelectedTextRange(nsRange(11, 9))
        #expect(view.accessibilitySelectedText() == "Paragraph")
        #expect(view.accessibilitySelectedTextRange() == nsRange(11, 9))
        #expect(view.accessibilityString(for: nsRange(2, 7)) == "Heading")
        #expect(view.accessibilityInsertionPointLineNumber() == 2)
        #expect(view.accessibilityLine(for: 0) == 0)
        #expect(view.accessibilityRange(forLine: 2) == nsRange(11, 21))
        let frame = view.accessibilityFrame(for: nsRange(11, 9))
        #expect(frame.width > 10 && frame.height > 10)
        let visible = view.accessibilityVisibleCharacterRange()
        #expect(visible.location == 0 && visible.length == (text as NSString).length)
        // ಕನ್ನಡ is 5 UTF-16 units; the cluster ನ್ನ is 3 of them.
        let cluster = view.accessibilityRange(for: 11 + 15 + 1)
        #expect(cluster.length == 3, "\(cluster)")
        view.setAccessibilityValue("new value")
        #expect(view.controller.string == "new value")
    }

    @Test func rendersTextSelectionAndCaret() {
        let view = makeView("# Title\n\nBody **bold** and `code`.\n\n| a | b |\n| --- | --- |\n| 1 | 2 |")
        let plain = render(view)
        let bg = view.controller.theme.colors.bg
        func isBackground(_ c: NSColor) -> Bool {
            abs(Double(c.redComponent) - bg.red) < 0.02 && abs(Double(c.greenComponent) - bg.green) < 0.02 && abs(Double(c.blueComponent) - bg.blue) < 0.02
        }
        var inked = 0
        for y in stride(from: 0, to: plain.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: plain.pixelsWide, by: 2) where !isBackground(plain.colorAt(x: x, y: y)!) { inked += 1 }
        }
        #expect(inked > 200, "text was drawn")
        // Selecting the body paints the selection colour behind it.
        view.controller.select(9..<13)
        let selected = render(view)
        // The selection colour is translucent; expect it blended over the background.
        let raw = view.controller.theme.colors.selection
        let sel = (red: raw.red * raw.alpha + bg.red * (1 - raw.alpha), green: raw.green * raw.alpha + bg.green * (1 - raw.alpha), blue: raw.blue * raw.alpha + bg.blue * (1 - raw.alpha))
        let rect = view.controller.rects(forSource: 9..<13, visible: view.bounds)[0]
        var selectedPixels = 0, total = 0
        for y in Int(rect.minY + 1)..<Int(rect.maxY - 1) {
            for x in Int(rect.minX + 1)..<Int(rect.maxX - 1) {
                total += 1
                let c = selected.colorAt(x: x, y: y)!
                if abs(Double(c.redComponent) - sel.red) < 0.05, abs(Double(c.greenComponent) - sel.green) < 0.05, abs(Double(c.blueComponent) - sel.blue) < 0.05 { selectedPixels += 1 }
            }
        }
        #expect(selectedPixels > total / 3, "\(selectedPixels) of \(total) pixels carry the selection colour")
        // The caret is a 2 pt bar in the caret colour.
        view.controller.moveCaret(to: 13)
        let withCaret = render(view)
        let caretRect = view.controller.caretRect(forSource: 13)
        let caretProbe = withCaret.colorAt(x: Int(caretRect.minX.rounded()), y: Int(caretRect.midY))!
        let caretColor = view.controller.theme.colors.caret
        #expect(abs(Double(caretProbe.redComponent) - caretColor.red) < 0.1 && abs(Double(caretProbe.greenComponent) - caretColor.green) < 0.1)
        #expect(view.keystrokeToDraw.isEmpty, "headless render does not count as a keystroke frame")
    }

    @Test func frameTracksContentHeightAndWidth() {
        let view = makeView(PerfFixture.lorem50k.text(), width: 1000)
        #expect(view.frame.height >= view.controller.contentHeight)
        let before = view.controller.layout.measure
        view.setFrameSize(NSSize(width: 500, height: view.frame.height))
        #expect(view.controller.layout.measure < before)
        view.prepareContent(in: NSRect(x: 0, y: 0, width: 500, height: 1200))
        #expect(view.controller.layout.stats.entriesLaidOut > 0)
        #expect(view.controller.layout.stats.entriesLaidOut < view.controller.projection.entries.count / 10)
    }

    @Test func textKit2ViewTypesAndDraws() {
        let view = makeView("Plain paragraph.\n\nSecond *one*.", engine: .textkit2)
        view.controller.moveCaret(to: 5)
        view.insertText("X", replacementRange: noRange)
        #expect(view.controller.string == "PlainX paragraph.\n\nSecond *one*.")
        let rep = render(view)
        #expect(rep.pixelsWide == 800)
        let rect = view.firstRect(forCharacterRange: nsRange(0, 5), actualRange: nil)
        #expect(rect.width > 10)
    }
}
