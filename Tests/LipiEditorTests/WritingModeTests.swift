import AppKit
import LipiCore
import LipiEditor
import Testing

@Suite("Writing modes (§6.12)")
@MainActor
struct WritingModeTests {
    /// Sum of darkness (1 - brightness) over `rect` of the rendered view.
    private func ink(_ rep: NSBitmapImageRep, in rect: CGRect) -> Double {
        var sum = 0.0
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        for y in Int(r.minY)..<Int(r.maxY) {
            for x in stride(from: Int(r.minX), to: Int(r.maxX), by: 1) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                sum += 1 - c.brightnessComponent
            }
        }
        return sum
    }

    @Test func focusScopeIsTheBlockAroundTheCaret() {
        let c = EditorController(text: "One two.\n\nThree four.\n\n- item\n")
        c.moveCaret(to: 12)
        #expect(c.focusScope == 10..<21)
        c.moveCaret(to: 25)
        #expect(c.focusScope == 23..<29)
    }

    @Test func focusModeDimsOnlyOtherBlocks() {
        let view = makeView("First paragraph here.\n\nSecond paragraph here.\n\nThird paragraph here.\n")
        view.controller.moveCaret(to: 25)
        view.alwaysShowsCaret = false
        let first = view.controller.rects(forSource: 0..<21, visible: view.bounds).reduce(CGRect.null) { $0.union($1) }
        let second = view.controller.rects(forSource: 23..<45, visible: view.bounds).reduce(CGRect.null) { $0.union($1) }
        let plain = render(view)
        view.focusMode = true
        let band = view.focusBand(visible: view.bounds)
        #expect(band.contains(CGPoint(x: second.midX, y: second.midY)))
        #expect(!band.intersects(first))
        let focused = render(view)
        #expect(ink(focused, in: first) < ink(plain, in: first) * 0.5)
        #expect(abs(ink(focused, in: second) - ink(plain, in: second)) < 0.01)
    }

    @Test func typewriterKeepsTheCaretAtMidHeight() {
        let text = (0..<200).map { "Line \($0)" }.joined(separator: "\n\n") + "\n"
        let controller = EditorController(text: text, viewportWidth: 600)
        let view = EditorView(controller: controller, frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.documentView = view
        view.typewriterMode = true
        controller.moveCaret(to: controller.count / 2)
        let clip = scroll.contentView.bounds
        let caret = controller.caretRect(forSource: controller.caret)
        #expect(abs(caret.midY - clip.midY) <= 1)
        // The last line can reach mid-height too.
        controller.moveCaret(to: controller.count)
        let end = controller.caretRect(forSource: controller.caret)
        #expect(abs(end.midY - scroll.contentView.bounds.midY) <= 1)
        // Without it, the caret only scrolls into view.
        view.typewriterMode = false
        controller.moveCaret(to: controller.count / 4)
        let quarter = controller.caretRect(forSource: controller.caret)
        #expect(abs(quarter.midY - scroll.contentView.bounds.midY) > 20)
    }
}
