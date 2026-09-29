import AppKit
import LipiCore
import LipiEditor
import LipiFixtures
import Testing

/// A keystroke repaints only the band it changed (`EditorView.redrawRect`).
/// After every random edit, the view drawn incrementally, as AppKit would
/// through the invalidated rects, must match a fresh full draw pixel for pixel.
@Suite("Partial redraw")
@MainActor
struct PartialRedrawTests {
    static let document = """
    # Heading *one* with `code`

    Some **bold** and _italic_ text with a [link](https://example.com) and a footnote[^1].
    A second line of the same paragraph, long enough to wrap once it is typed into a little.

    > A quote with ~~strike~~, <span>html</span> and $x^2$ math.

    - [ ] task
    - [x] done
      1. nested item

    | a | b |
    |:--|--:|
    | 1 | two |

    ```swift
    let x = 42 // comment
    ```

    ---

    ಕನ್ನಡ ಪಠ್ಯ ಇಲ್ಲಿದೆ and العربية text 👩‍👩‍👧 🇮🇳 ✨ emoji.

    [^1]: The note[^2].
    [^2]: Another note.

    Last paragraph.
    """

    final class Canvas {
        let rep: NSBitmapImageRep
        let cg: CGContext
        init(size: CGSize, scale: CGFloat = 2) {
            rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
            cg.scaleBy(x: scale, y: scale)
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
        }
        var bytes: Data { Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh) }
    }

    /// Kannada stacks and colour emoji reach furthest past their lines.
    static let documents: [String] = [
        document,
        String(PerfFixture.kannada20k.text().prefix(2500)),
        String(String(decoding: PathologicalFixture.emojiZWJ2000.data(), as: UTF8.self).prefix(600)),
    ]

    @Test(arguments: 0..<3, [1, 2, 3] as [UInt64])
    func partialRepaintMatchesFullDraw(document: Int, seed: UInt64) {
        let view = makeView(Self.documents[document])
        let c = view.controller
        var rng = SplitMix64(seed: seed)
        var canvas = Canvas(size: view.bounds.size)
        view.render(in: canvas.cg, dirty: view.bounds)
        var partial = 0
        for step in 0..<120 {
            switch rng.below(20) {
            case 0..<11: c.insert(rng.pick(["k", "a", " ", "ಕ", "ಿ", "😀", "é", "W", "1", "*", "`", "[", "#", "|", "-", "^"]))
            case 11..<14: c.deleteBackward()
            case 14..<17: c.moveCaret(to: c.rope.floorScalarBoundary(rng.below(c.count + 1)))
            case 17: c.insert("\n")
            case 18:
                let a = c.rope.floorScalarBoundary(rng.below(c.count + 1))
                c.select(a..<c.rope.floorScalarBoundary(min(c.count, a + rng.below(12))))
            default: c.moveCaret(to: c.rope.floorScalarBoundary(max(0, c.selection.head - 1)))
            }
            if let rect = view.pendingRedraw, canvas.rep.pixelsHigh == Int(view.bounds.height * 2) {
                partial += rect.isNull ? 0 : 1
                canvas.cg.saveGState()
                canvas.cg.clip(to: rect)
                view.render(in: canvas.cg, dirty: rect)
                canvas.cg.restoreGState()
            } else {
                canvas = Canvas(size: view.bounds.size)
                view.render(in: canvas.cg, dirty: view.bounds)
            }
            let full = Canvas(size: view.bounds.size)
            view.render(in: full.cg, dirty: view.bounds)
            #expect(canvas.bytes == full.bytes, "step \(step): \(c.string.debugDescription)")
            if canvas.bytes != full.bytes { break }
        }
        // Most keystrokes take the partial path.
        #expect(partial > 30)
    }

    @Test func typingInvalidatesOneBand() {
        let view = makeView(Self.document)
        let c = view.controller
        c.moveCaret(to: (c.string as NSString).range(of: "Last paragraph").location + 4)
        let canvas = Canvas(size: view.bounds.size)
        view.render(in: canvas.cg, dirty: view.bounds)
        c.insert("x")
        let rect = try! #require(view.pendingRedraw)
        #expect(rect.height < view.bounds.height / 4)
        #expect(rect.contains(c.caretRect(forSource: c.caret)))
    }
}
