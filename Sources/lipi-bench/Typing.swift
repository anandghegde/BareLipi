import CoreGraphics
import Foundation
import LipiCore
import LipiEditor
import LipiFixtures
import LipiLayout

/// Keystroke cost through `EditorController`, as the view runs it: insert,
/// then lay out and draw what changed on the 1200 × 800 @2x screen. Plain
/// prose, a document of footnotes and one of colour emoji, typing in the
/// middle. `lipi-bench --typing [--keys N] [--rounds R] [--only NAME]` runs
/// this section alone and prints the median and p90 per fixture (medians
/// over rounds).
@MainActor
func typingBench(keystrokes: Int = 400, rounds: Int = 5, only: String? = nil) {
    let size = CGSize(width: 1200, height: 800)
    let bitmap = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
    bitmap.scaleBy(x: 2, y: 2)
    bitmap.translateBy(x: 0, y: size.height)
    bitmap.scaleBy(x: 1, y: -1)
    let fixtures: [(String, String)] = [
        ("plain", PerfFixture.lorem50k.text()),
        ("kannada", PerfFixture.kannada20k.text()),
        ("footnotes", String(decoding: PathologicalFixture.footnotes5000.data(), as: UTF8.self)),
        ("emoji", String(decoding: PathologicalFixture.emojiZWJ2000.data(), as: UTF8.self)),
    ]
    print("")
    print("typing: EditorController keystroke → screen drawn, 1200 × 800 @2x, \(keystrokes) keys × \(rounds) rounds")
    for (name, text) in fixtures where only == nil || only == name {
        var medians: [Double] = [], p90s: [Double] = []
        for _ in 0..<rounds {
            let controller = EditorController(text: text, viewportWidth: size.width)
            var screen = CGRect.null
            var caret = CGRect.null
            // As `EditorView` does: the screen scrolls only when the caret
            // leaves it, and a change repaints its `redrawRect` when it has one.
            func draw(_ change: EditorChange) {
                var dirty = screen
                if screen.isNull || !screen.contains(change.caretRect) {
                    let y = max(0, (change.caretRect.midY - size.height / 2).rounded())
                    screen = CGRect(x: 0, y: y, width: size.width, height: size.height)
                    dirty = screen
                    controller.prepare(screen.insetBy(dx: 0, dy: -size.height))
                } else if let rect = controller.redrawRect(visible: screen) {
                    dirty = rect.union(caret).union(change.caretRect.insetBy(dx: -2, dy: -1)).intersection(screen).integral
                }
                caret = change.caretRect
                bitmap.saveGState()
                bitmap.translateBy(x: 0, y: -screen.minY)
                bitmap.clip(to: dirty)
                bitmap.setFillColor(controller.theme.colors.bg.cgColor)
                bitmap.fill(dirty)
                controller.draw(in: bitmap, dirty: dirty)
                bitmap.restoreGState()
            }
            // Middle of the document, at the end of a paragraph line.
            var offset = controller.rope.floorScalarBoundary(controller.count / 2)
            let line = controller.rope.line(at: offset)
            offset = max(controller.rope.lineRange(line).lowerBound, controller.rope.lineRange(line).upperBound - 1)
            draw(controller.moveCaret(to: offset))
            for _ in 0..<50 { draw(controller.insert("x")) }
            var samples: [Double] = []
            samples.reserveCapacity(keystrokes)
            for k in 0..<keystrokes {
                let t0 = DispatchTime.now().uptimeNanoseconds
                draw(controller.insert(k % 6 == 5 ? " " : "k"))
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000)
            }
            samples.sort()
            medians.append(samples[samples.count / 2])
            p90s.append(samples[samples.count * 9 / 10])
        }
        medians.sort(); p90s.sort()
        let label = "\(name): keystroke → screen drawn".padding(toLength: 46, withPad: " ", startingAt: 0)
        print(String(format: "%@ p50 %6.0f µs   p90 %6.0f µs   (%d bytes)", label, medians[rounds / 2], p90s[rounds / 2], text.utf8.count))
    }
}
