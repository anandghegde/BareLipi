import CoreGraphics
import Foundation
import LipiCore
import LipiEditor
import LipiFixtures
import LipiLayout

/// Keystroke cost through `EditorController`, as the view runs it: insert,
/// then lay out and draw the 1200 × 800 @2x screen around the caret. Plain
/// prose, a document of footnotes and one of colour emoji, typing in the
/// middle. `lipi-bench --typing [--keys N] [--rounds R]` runs this section
/// alone and prints the median and p90 per fixture (medians over rounds).
@MainActor
func typingBench(keystrokes: Int = 400, rounds: Int = 5) {
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
    for (name, text) in fixtures {
        var medians: [Double] = [], p90s: [Double] = []
        for _ in 0..<rounds {
            let controller = EditorController(text: text, viewportWidth: size.width)
            func draw(around rect: CGRect) {
                let y = max(0, (rect.midY - size.height / 2).rounded())
                let screen = CGRect(x: 0, y: y, width: size.width, height: size.height)
                controller.prepare(screen.insetBy(dx: 0, dy: -size.height))
                bitmap.saveGState()
                bitmap.translateBy(x: 0, y: -y)
                bitmap.setFillColor(controller.theme.colors.bg.cgColor)
                bitmap.fill(screen)
                controller.draw(in: bitmap, dirty: screen)
                bitmap.restoreGState()
            }
            // Middle of the document, at the end of a paragraph line.
            var caret = controller.rope.floorScalarBoundary(controller.count / 2)
            let line = controller.rope.line(at: caret)
            caret = max(controller.rope.lineRange(line).lowerBound, controller.rope.lineRange(line).upperBound - 1)
            draw(around: controller.moveCaret(to: caret).caretRect)
            for _ in 0..<50 { draw(around: controller.insert("x").caretRect) }
            var samples: [Double] = []
            samples.reserveCapacity(keystrokes)
            for k in 0..<keystrokes {
                let t0 = DispatchTime.now().uptimeNanoseconds
                draw(around: controller.insert(k % 6 == 5 ? " " : "k").caretRect)
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
