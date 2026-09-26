import AppKit
import LipiCore
import Testing
@testable import LipiEditor

@Suite("Typewriter padding: every line reaches the typewriter line (§6.12)")
@MainActor
struct TypewriterPaddingTests {
    private func makeScrolled(_ text: String, height: CGFloat = 400) -> (EditorView, NSScrollView) {
        let controller = EditorController(text: text, viewportWidth: 600)
        let view = EditorView(controller: controller, frame: NSRect(x: 0, y: 0, width: 600, height: height))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: height))
        scroll.documentView = view
        return (view, scroll)
    }

    private func caretOffset(_ view: EditorView, _ scroll: NSScrollView) -> CGFloat {
        let caret = view.controller.caretRect(forSource: view.controller.caret)
        let clip = scroll.contentView.bounds
        return caret.midY - (clip.minY + clip.height * view.typewriterFraction)
    }

    private let lines = (0..<200).map { "Line \($0)" }.joined(separator: "\n\n") + "\n"

    @Test func theFirstLineReachesEveryPosition() {
        let (view, scroll) = makeScrolled(lines)
        view.typewriterMode = true
        for fraction in [0.3, 0.5, 0.7] as [CGFloat] {
            view.typewriterFraction = fraction
            _ = view.controller.moveCaret(to: 0)
            #expect(abs(caretOffset(view, scroll)) <= 1, "first line at \(fraction)")
            _ = view.controller.moveCaret(to: 8)
            #expect(abs(caretOffset(view, scroll)) <= 1, "second line at \(fraction)")
            _ = view.controller.moveCaret(to: view.controller.count)
            #expect(abs(caretOffset(view, scroll)) <= 1, "last line at \(fraction)")
        }
        // The padding lies above y = 0: the text keeps its coordinates.
        #expect(view.topPadding == (400 * 0.7).rounded(.up))
        #expect(view.bounds.minY == -view.topPadding && view.frame.minY == -view.topPadding)
        #expect(view.frame.maxY >= view.controller.contentHeight + 400 * 0.3)
    }

    @Test func aShortDocumentReachesThePositionToo() {
        let (view, scroll) = makeScrolled("Only line.\n\nSecond.\n")
        view.typewriterFraction = 0.6
        view.typewriterMode = true
        #expect(abs(caretOffset(view, scroll)) <= 1)
        _ = view.controller.moveCaret(to: view.controller.count)
        #expect(abs(caretOffset(view, scroll)) <= 1)
    }

    @Test func thePaddingGoesAwayWithTypewriterMode() {
        let (view, scroll) = makeScrolled(lines)
        let plainHeight = view.frame.height
        view.typewriterMode = true
        _ = view.controller.moveCaret(to: 0)
        #expect(scroll.contentView.bounds.minY < 0)
        view.typewriterMode = false
        #expect(view.topPadding == 0 && view.bounds.minY == 0)
        #expect(abs(view.frame.height - plainHeight) < 1)
        #expect(scroll.contentView.bounds.minY == 0)
        // The caret is where it was on screen, without padding: the top.
        let caret = view.controller.caretRect(forSource: 0)
        #expect(scroll.contentView.convert(caret, from: view).minY == caret.minY)
        #expect(caret.minY < 40)
    }

    @Test func resizingTheViewportResizesThePadding() {
        let (view, scroll) = makeScrolled(lines)
        view.typewriterFraction = 0.5
        view.typewriterMode = true
        #expect(view.topPadding == 200)
        scroll.setFrameSize(NSSize(width: 600, height: 600))
        #expect(view.topPadding == 300)
        _ = view.controller.moveCaret(to: 0)
        #expect(abs(caretOffset(view, scroll)) <= 1)
    }

    @Test func clicksAndTheCaretLandOnTheRightLineInThePadding() throws {
        let (view, scroll) = makeScrolled(lines)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = scroll
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.typewriterFraction = 0.4
        view.typewriterMode = true
        _ = view.controller.moveCaret(to: view.controller.count)
        _ = view.controller.moveCaret(to: 0)
        // The first line sits 40 % down the window (window y is up).
        let first = view.controller.caretRect(forSource: 0)
        let y = 400 - 400 * 0.4
        #expect(abs(view.convert(NSPoint(x: first.minX, y: first.midY), to: nil).y - y) <= 1)
        // A click on the second line, found from the window alone.
        let second = view.controller.caretRect(forSource: 8)
        let at = NSPoint(x: view.controller.layout.textOrigin + 30, y: y - (second.midY - first.midY))
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: at, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                    clickCount: 1, pressure: 1))
        view.mouseDown(with: event)
        view.mouseUp(with: event)
        #expect((8...14).contains(view.controller.caret))
        // A click in the blank padding above the text goes to the first line.
        let above = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 100, y: 390), modifierFlags: [],
                                                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: above)
        view.mouseUp(with: above)
        #expect(view.controller.caret <= 6)
    }

    @Test func revealsNearTheTopKeepTheCaretOnTheLine() {
        let text = "Intro.\n\n```swift\nlet a = 1\n```\n\n# Heading\n\n" + lines
        let (view, scroll) = makeScrolled(text)
        view.typewriterFraction = 0.5
        view.typewriterMode = true
        _ = view.controller.moveCaret(to: 0)
        let fence = (text as NSString).range(of: "let a").location
        _ = view.controller.moveCaret(to: fence)
        #expect(abs(caretOffset(view, scroll)) <= 1)
        _ = view.controller.moveCaret(to: (text as NSString).range(of: "Heading").location)
        #expect(abs(caretOffset(view, scroll)) <= 1)
        _ = view.controller.moveCaret(to: 2)
        #expect(abs(caretOffset(view, scroll)) <= 1)
    }
}
