import CoreGraphics
import Foundation
import LipiCore
import LipiFixtures
import LipiLayout

/// Editing inside one very large block: the 1 MB single paragraph and the
/// 256 KB line of the byte corpus. Each keystroke is a whole §7.4 pass
/// (buffer, parse, reveal, projection, layout update, caret rect, draw of
/// the screen around the caret), at the start, middle and end of the block.
/// `lipi-bench --huge` runs this section alone.
func hugeBlockBench(keystrokes: Int = 50) {
    print("")
    print("huge blocks: keystroke inside one very large block, viewport 1000 × 800 @2x")
    let theme = Theme.taalegari
    let typesetter = Typesetter(scale: TypeScale(theme: theme), cascade: FontCascade(theme: theme))
    let renderer = Renderer(typesetter: typesetter)
    let bitmap = CGContext(data: nil, width: 2000, height: 1600, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    bitmap.scaleBy(x: 2, y: 2)
    _ = typesetter.cascade.zeroAdvance(size: 17)

    for fixture in HugeBlockFixture.allCases {
        let name = fixture.rawValue
        let text = fixture.text()
        print("")
        print("\(name): \(text.utf8.count) bytes")
        var buffer = SourceBuffer(text)
        var parser = LipiParser(options: .editor)
        let policy = RevealPolicy()
        var projection = Projection()
        var result = Projection.UpdateResult()
        time("\(name): parse", iterations: 1) { parser.parse(buffer.rope) }
        time("\(name): project", iterations: 1) {
            result = projection.update(index: parser.index, rope: buffer.rope, reveal: .none)
        }
        let layout = DocumentLayout(typesetter: typesetter, viewportWidth: 1000)
        layout.update(projection: projection, result: result)
        if let (e, block) = projection.entries.enumerated().lazy.flatMap({ e in e.element.blocks.map { (e.offset, $0) } })
            .max(by: { $0.1.cells[0].text.utf16.count < $1.1.cells[0].text.utf16.count }) {
            var cell: TypesetCell!
            time("\(name): typeset cell (attributes)", iterations: 1) { cell = typesetter.typeset(block.cells[0], in: block, cellIndex: 0) }
            var lines = 0
            time("\(name): break lines (whole cell)", iterations: 1) { lines = LayoutEngine.typeset(cell, width: layout.measure).lines.count }
            print("  entry \(e): \(cell.length) UTF-16 units, \(lines) lines")
        }
        time("\(name): first screen layout + draw", iterations: 1) {
            let placed = layout.layoutIfNeeded(in: 0...800)
            renderer.draw(placed, layout: layout, in: bitmap, dirty: CGRect(x: 0, y: 0, width: 1000, height: 800))
        }
        print("  content height \(Int(layout.contentHeight)) pt")

        func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) }
        for (label, fraction) in [("start", 0.02), ("middle", 0.5), ("end", 0.98)] {
            var caret = buffer.rope.floorScalarBoundary(Int(Double(buffer.count) * fraction))
            var split = (parse: 0.0, project: 0.0, layout: 0.0, draw: 0.0)
            var worst = 0.0
            time("\(name): keystroke → screen drawn (\(label))", iterations: keystrokes) {
                for k in 0..<keystrokes {
                    let t0 = now()
                    let delta = buffer.apply(k % 5 == 4 ? .insert(" ", at: SourceOffset(caret)) : .insert("k", at: SourceOffset(caret)))
                    parser.apply(delta, then: buffer.rope)
                    caret += 1
                    let t1 = now()
                    let reveal = policy.revealSet(caret: caret, index: parser.index, rope: buffer.rope)
                    let update = projection.update(index: parser.index, rope: buffer.rope, reveal: reveal)
                    let t2 = now()
                    layout.update(projection: projection, result: update)
                    guard let rect = layout.caretRect(forSource: caret) else { return }
                    let t3 = now()
                    let screen = CGRect(x: 0, y: max(0, (rect.midY - 400).rounded()), width: 1000, height: 800)
                    let visible = layout.layoutIfNeeded(in: screen.minY...screen.maxY)
                    bitmap.saveGState()
                    bitmap.translateBy(x: 0, y: -screen.minY)
                    renderer.draw(visible, layout: layout, in: bitmap, dirty: screen)
                    bitmap.restoreGState()
                    let t4 = now()
                    split.parse += t1 - t0; split.project += t2 - t1; split.layout += t3 - t2; split.draw += t4 - t3
                    worst = max(worst, t4 - t0)
                }
            }
            let n = Double(keystrokes) * 1000
            print(String(format: "  per keystroke: parse %.0f µs, reveal+project %.0f µs, layout+caret %.0f µs, draw %.0f µs; max %.2f ms",
                         split.parse / n, split.project / n, split.layout / n, split.draw / n, worst / 1_000_000))
        }
        print("  content height \(Int(layout.contentHeight)) pt")
    }
}
