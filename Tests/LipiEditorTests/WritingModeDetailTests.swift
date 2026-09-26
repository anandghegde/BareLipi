import AppKit
import LipiCore
import QuartzCore
import Testing
@testable import LipiEditor

@Suite("Writing modes: sentence focus, transitions, typewriter line (§6.12)")
@MainActor
struct WritingModeDetailTests {
    @Test func sentenceScopeIsTheSentenceAroundTheCaret() {
        let text = "One two. Three four? Five.\n\n```\na. b.\n```\n"
        let c = EditorController(text: text)
        _ = c.moveCaret(to: 11)
        #expect(c.focusScope(.sentence) == 9..<20)
        #expect(c.focusScope(.block) == 0..<26)
        _ = c.moveCaret(to: 2)
        #expect(c.focusScope(.sentence) == 0..<8)
        // At a sentence's end (after the space), the next sentence.
        _ = c.moveCaret(to: 9)
        #expect(c.focusScope(.sentence) == 9..<20)
        _ = c.moveCaret(to: 26)
        #expect(c.focusScope(.sentence) == 21..<26)
        // Code keeps the block.
        _ = c.moveCaret(to: 33)
        #expect(c.focusScope(.sentence) == c.focusScope(.block))
    }

    @Test func sentenceFocusDimsTheRestOfTheParagraph() {
        let view = makeView("Alpha beta gamma. Delta epsilon zeta.\n")
        view.focusScopeKind = .sentence
        _ = view.controller.moveCaret(to: 3)
        view.alwaysShowsCaret = false
        let first = view.controller.rects(forSource: 0..<17, visible: view.bounds).reduce(CGRect.null) { $0.union($1) }
        let second = view.controller.rects(forSource: 18..<37, visible: view.bounds).reduce(CGRect.null) { $0.union($1) }
        let plain = render(view)
        view.focusMode = true
        let focused = render(view)
        #expect(ink(focused, in: second) < ink(plain, in: second) * 0.5)
        #expect(abs(ink(focused, in: first) - ink(plain, in: first)) < 0.01)
    }

    @Test func focusFadesOver120msUnlessReduceMotion() {
        let view = makeView("First.\n\nSecond.\n\nThird.\n")
        view.followsSystemDisplayOptions = false
        view.displayOptions = AccessibilityDisplayOptions()
        var now: CFTimeInterval = 100
        view.writingState.clock = { now }
        view.writingState.animatesOffscreen = true
        view.alwaysShowsCaret = false
        let first = view.controller.rects(forSource: 0..<6, visible: view.bounds).reduce(CGRect.null) { $0.union($1) }
        let third = view.controller.rects(forSource: 17..<23, visible: view.bounds).reduce(CGRect.null) { $0.union($1) }
        let plain = render(view)
        view.focusMode = true
        #expect(view.isFocusTransitioning)
        // At the start nothing is dimmed yet; halfway, part of it; at the end, all.
        #expect(abs(ink(render(view), in: third) - ink(plain, in: third)) < 0.01)
        now += 0.06
        let half = ink(render(view), in: third)
        #expect(half < ink(plain, in: third) * 0.9)
        now += 0.07
        view.focusTransitionTick()
        #expect(!view.isFocusTransitioning)
        let full = ink(render(view), in: third)
        #expect(full < half)
        // Moving to another block fades between them.
        _ = view.controller.moveCaret(to: 19)
        #expect(view.isFocusTransitioning)
        #expect(ink(render(view), in: third) < ink(plain, in: third) * 0.5)
        now += 0.2
        view.focusTransitionTick()
        #expect(abs(ink(render(view), in: third) - ink(plain, in: third)) < 0.01)
        #expect(ink(render(view), in: first) < ink(plain, in: first) * 0.5)
        // Typing never fades.
        _ = view.controller.insert("x")
        #expect(!view.isFocusTransitioning)
        // Reduce Motion: no transition.
        view.focusMode = false
        now += 0.2
        view.focusTransitionTick()
        view.displayOptions = AccessibilityDisplayOptions(reduceMotion: true)
        view.focusMode = true
        #expect(!view.isFocusTransitioning)
    }

    @Test func typewriterHoldsTheCaretAtTheChosenFraction() {
        let text = (0..<200).map { "Line \($0)" }.joined(separator: "\n\n") + "\n"
        let controller = EditorController(text: text, viewportWidth: 600)
        let view = EditorView(controller: controller, frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.documentView = view
        view.typewriterMode = true
        #expect(view.typewriterFraction == 0.5)
        view.typewriterFraction = 0.9
        #expect(view.typewriterFraction == 0.7)
        view.typewriterFraction = 0.3
        _ = controller.moveCaret(to: controller.count / 2)
        var clip = scroll.contentView.bounds
        var caret = controller.caretRect(forSource: controller.caret)
        #expect(abs(caret.midY - (clip.minY + clip.height * 0.3)) <= 1)
        // The last line reaches the line too.
        _ = controller.moveCaret(to: controller.count)
        clip = scroll.contentView.bounds
        caret = controller.caretRect(forSource: controller.caret)
        #expect(abs(caret.midY - (clip.minY + clip.height * 0.3)) <= 1)
        view.typewriterFraction = 0.7
        clip = scroll.contentView.bounds
        caret = controller.caretRect(forSource: controller.caret)
        #expect(abs(caret.midY - (clip.minY + clip.height * 0.7)) <= 1)
        // Easing is instant without a window (and under Reduce Motion).
        view.typewriterEases = true
        _ = controller.moveCaret(to: controller.count / 2)
        clip = scroll.contentView.bounds
        caret = controller.caretRect(forSource: controller.caret)
        #expect(abs(caret.midY - (clip.minY + clip.height * 0.7)) <= 1)
    }

    private func ink(_ rep: NSBitmapImageRep, in rect: CGRect) -> Double {
        var sum = 0.0
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        for y in Int(r.minY)..<Int(r.maxY) {
            for x in Int(r.minX)..<Int(r.maxX) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                sum += 1 - c.brightnessComponent
            }
        }
        return sum
    }
}
