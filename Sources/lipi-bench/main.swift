import CoreGraphics
import Foundation
import LipiCore
import LipiFixtures
import LipiLayout

setvbuf(stdout, nil, _IONBF, 0)

/// Phase 0 micro-benchmarks. Run with `swift run -c release lipi-bench`.
/// Rope exit criterion (PRD §10, Phase 0): random insert into a 1 MB document
/// under 5 µs. The layout section at the end is the ADR-002 spike:
/// `LipiLayout` against headless TextKit 2 on the §9.1 fixtures.

@inline(never)
func time(_ label: String, iterations: Int, _ body: () -> Void) {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    let ns = Double(DispatchTime.now().uptimeNanoseconds - start)
    let per = ns / Double(iterations)
    let unit = per >= 1_000_000 ? String(format: "%.2f ms", per / 1_000_000)
        : per >= 1_000 ? String(format: "%.2f µs", per / 1_000)
        : String(format: "%.0f ns", per)
    let paddedLabel = label.padding(toLength: 46, withPad: " ", startingAt: 0)
    let paddedUnit = String(repeating: " ", count: max(0, 10 - unit.count)) + unit
    print("\(paddedLabel) \(paddedUnit) per op   (\(iterations) ops, \(String(format: "%.1f", ns / 1_000_000)) ms total)")
}

let line = "The quick brown fox jumps over the lazy dog. ಬರೆ ಲಿಪಿ ಕನ್ನಡ.\n"
let oneMB = String(repeating: line, count: 1_048_576 / line.utf8.count + 1)
print("document: \(oneMB.utf8.count) bytes, \(oneMB.unicodeScalars.count) scalars")

var rng = SplitMix64(seed: 7)
var rope = LipiRope()

time("build rope from 1 MB string", iterations: 1) { rope = LipiRope(oneMB) }
print("  height \(rope.height), lines \(rope.lineCount)")

var offsets: [Int] = []
for _ in 0..<100_000 { offsets.append(rope.floorScalarBoundary(Int(rng.next() % UInt64(rope.count)))) }

time("insert 1 char at random offset (1 MB)", iterations: 100_000) {
    for o in offsets { rope.insert("x", at: rope.floorScalarBoundary(o)) }
}
time("delete 1 char at random offset (1 MB)", iterations: 100_000) {
    for o in offsets { let b = rope.floorScalarBoundary(o); let e = rope.floorScalarBoundary(b + 1) ; if b < e { rope.remove(b..<e) } }
}
time("sequential typing at one caret (1 MB)", iterations: 100_000) {
    var caret = rope.count / 2
    for _ in 0..<100_000 { rope.insert("k", at: caret); caret += 1 }
}
// The rope changed under the earlier offsets; re-floor them for the read-only stages.
offsets = offsets.map { rope.floorScalarBoundary(min($0, rope.count)) }

time("byte -> utf16 offset", iterations: 100_000) {
    var acc = 0
    for o in offsets { acc &+= rope.utf16Offset(fromByte: o) }
    if acc == 42 { print(acc) }
}
time("byte -> line index", iterations: 100_000) {
    var acc = 0
    for o in offsets { acc &+= rope.line(at: o) }
    if acc == 42 { print(acc) }
}
time("line index -> byte", iterations: 100_000) {
    var acc = 0
    let lines = rope.lineCount
    for o in offsets { acc &+= rope.lineStart(o % lines) }
    if acc == 42 { print(acc) }
}
time("string(in:) 2 KB window", iterations: 10_000) {
    var acc = 0
    for o in offsets.prefix(10_000) {
        let lo = rope.floorScalarBoundary(min(o, rope.count - 2048))
        let hi = rope.floorScalarBoundary(lo + 2048)
        acc &+= rope.string(in: lo..<hi).utf8.count
    }
    if acc == 42 { print(acc) }
}
time("snapshot (copy) of rope", iterations: 1_000_000) {
    var keep: [LipiRope] = []
    keep.reserveCapacity(8)
    for i in 0..<1_000_000 { let s = rope; if i % 200_000 == 0 { keep.append(s) } }
    if keep.count == 42 { print(keep.count) }
}
time("full string materialisation", iterations: 10) {
    var acc = 0
    for _ in 0..<10 { acc &+= rope.string.utf8.count }
    if acc == 42 { print(acc) }
}
let problems = rope.validateStructure()
print(problems.isEmpty ? "structure valid" : "STRUCTURE PROBLEMS: \(problems)")

// MARK: - Parser

/// Phase 0 parser exit criterion (PRD §10): re-parse of a 2 KB block under 0.3 ms.
print("")
let paragraphLine = "Lorem ipsum *dolor* sit amet, `consectetur` adipiscing [elit](https://example.com), sed do eiusmod.\n"
let block2KB = String(repeating: paragraphLine, count: 2048 / paragraphLine.utf8.count) + "\n"
print("block: \(block2KB.utf8.count) bytes")
let blocks200 = String(repeating: block2KB, count: 100)
let markdownMB = String(repeating: block2KB, count: 1_048_576 / block2KB.utf8.count + 1)
print("markdown documents: \(blocks200.utf8.count) bytes, \(markdownMB.utf8.count) bytes")

var parser = LipiParser(options: .editor)
time("full parse 200 KB (100 blocks)", iterations: 20) {
    for _ in 0..<20 { parser.parse(blocks200) }
}
time("full parse 1 MB", iterations: 5) {
    for _ in 0..<5 { parser.parse(markdownMB) }
}

var buffer = SourceBuffer(markdownMB)
parser.parse(buffer.rope)
var parserRNG = SplitMix64(seed: 11)
var editOffsets: [Int] = []
for _ in 0..<2_000 { editOffsets.append(Int(parserRNG.next() % UInt64(buffer.count))) }
time("re-parse: 1-char insert, random 2 KB block", iterations: 2_000) {
    for o in editOffsets {
        let delta = buffer.apply(.insert("x", at: SourceOffset(buffer.rope.floorScalarBoundary(o))))
        parser.apply(delta, then: buffer.rope)
    }
}
print("  entries \(parser.index.count), last re-parse \(parser.stats.lastReparseBytes) bytes, \(parser.stats.lastReparseEntries) entries")
time("re-parse: typing at one caret", iterations: 2_000) {
    var caret = buffer.count / 2
    for _ in 0..<2_000 {
        let delta = buffer.apply(.insert("k", at: SourceOffset(caret)))
        parser.apply(delta, then: buffer.rope)
        caret += 1
    }
}
time("re-parse: blank line splits a block", iterations: 500) {
    for o in editOffsets.prefix(500) {
        let at = buffer.rope.floorScalarBoundary(o)
        let delta = buffer.apply(.insert("\n\n", at: SourceOffset(at)))
        parser.apply(delta, then: buffer.rope)
    }
}
print("  entries \(parser.index.count)")

// MARK: - Projection

/// Projection cost per keystroke: a caret move touches at most two entries;
/// an edit re-projects the re-parsed entries only.
print("")
var projection = Projection()
let policy = RevealPolicy()
time("project 1 MB from scratch", iterations: 5) {
    for _ in 0..<5 {
        projection = Projection()
        projection.update(index: parser.index, rope: buffer.rope, reveal: .none)
    }
}
var blockCount = 0
for e in projection.entries { blockCount += e.blocks.count }
print("  entries \(projection.entries.count), display blocks \(blockCount)")
time("caret move: reveal set + projection update", iterations: 2_000) {
    for o in editOffsets {
        let caret = buffer.rope.floorScalarBoundary(o)
        let reveal = policy.revealSet(caret: caret, index: parser.index, rope: buffer.rope)
        projection.update(index: parser.index, rope: buffer.rope, reveal: reveal)
    }
}
time("typing: parse + reveal + projection update", iterations: 2_000) {
    var caret = buffer.count / 3
    for _ in 0..<2_000 {
        let delta = buffer.apply(.insert("k", at: SourceOffset(caret)))
        parser.apply(delta, then: buffer.rope)
        caret += 1
        let reveal = policy.revealSet(caret: caret, index: parser.index, rope: buffer.rope)
        projection.update(index: parser.index, rope: buffer.rope, reveal: reveal)
    }
}
time("source ↔ display position lookup", iterations: 2_000) {
    var acc = 0
    for o in editOffsets {
        if let p = projection.position(forSource: o) { acc &+= projection.sourceOffset(for: p) }
    }
    if acc == 42 { print(acc) }
}

// MARK: - Layout (ADR-002 spike)

/// Resident memory (`phys_footprint`), the number Activity Monitor shows.
func physFootprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

func megabytes(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }

print("")
print("layout (ADR-002 spike): LipiLayout vs headless TextKit 2, viewport 1000 × 800 @2x")
let theme = Theme.paper
let typesetter = Typesetter(scale: TypeScale(theme: theme), cascade: FontCascade(theme: theme))
let renderer = Renderer(typesetter: typesetter)
let viewport = CGRect(x: 0, y: 0, width: 1000, height: 800)
let bitmap = CGContext(data: nil, width: 2000, height: 1600, bitsPerComponent: 8, bytesPerRow: 0,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
bitmap.scaleBy(x: 2, y: 2)
// Warm the font caches once so the first fixture is not charged for them.
_ = typesetter.cascade.zeroAdvance(size: 17)

for fixture in [PerfFixture.lorem50k, .kannada20k, .tables600x6] {
    let name = fixture.rawValue
    let text = fixture.text()
    print("")
    print("\(name): \(text.utf8.count) bytes")
    var buffer = SourceBuffer(text)
    var parser = LipiParser(options: .editor)
    let policy = RevealPolicy()
    var projection = Projection()
    var result = Projection.UpdateResult()
    let before = physFootprint()
    time("\(name): parse", iterations: 1) { parser.parse(buffer.rope) }
    time("\(name): project", iterations: 1) {
        result = projection.update(index: parser.index, rope: buffer.rope, reveal: .none)
    }
    let layout = DocumentLayout(typesetter: typesetter, viewportWidth: 1000)
    layout.update(projection: projection, result: result)
    var placed: [PlacedEntry] = []
    time("\(name): lipi first screen layout", iterations: 1) { placed = layout.layoutIfNeeded(in: 0...800) }
    // The first draw rasterises the glyphs into Core Text's cache; the second
    // is the steady state.
    time("\(name): lipi first screen draw (cold)", iterations: 1) {
        renderer.draw(placed, layout: layout, in: bitmap, dirty: viewport)
    }
    time("\(name): lipi first screen draw (warm)", iterations: 1) {
        renderer.draw(placed, layout: layout, in: bitmap, dirty: viewport)
    }
    time("\(name): lipi full layout", iterations: 1) { layout.layoutAll() }
    let afterLipi = physFootprint()
    print("  entries \(layout.entryCount), blocks laid out \(layout.stats.blocksLaidOut), content height \(Int(layout.contentHeight)) pt, "
          + "+\(megabytes(afterLipi - before)) resident")

    // A keystroke in the middle of the document: §7.4 steps 2–8 (buffer,
    // parser, reveal, projection, layout update, entry layout, caret rect)
    // and then step 9, drawing the screen around the caret.
    var caret = buffer.rope.floorScalarBoundary(buffer.count / 2)
    if fixture == .tables600x6 {
        // Land inside a cell on a body row: two bytes after the line start.
        var line = buffer.rope.line(at: caret)
        while buffer.rope.string(in: buffer.rope.lineRange(line)).contains("---") { line += 1 }
        caret = buffer.rope.lineRange(line).lowerBound + 2
    }
    if let entry = projection.position(forSource: caret)?.entry, projection.entries[entry].blocks.first?.table != nil {
        layout.growOnlyEntry = entry
    }
    var split = (parse: 0.0, project: 0.0, layout: 0.0, draw: 0.0)
    func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) }
    func keystroke(draw: Bool) {
        let t0 = now()
        let delta = buffer.apply(.insert("k", at: SourceOffset(caret)))
        parser.apply(delta, then: buffer.rope)
        caret += 1
        let t1 = now()
        let reveal = policy.revealSet(caret: caret, index: parser.index, rope: buffer.rope)
        let update = projection.update(index: parser.index, rope: buffer.rope, reveal: reveal)
        let t2 = now()
        layout.update(projection: projection, result: update)
        guard let rect = layout.caretRect(forSource: caret) else { return }
        let t3 = now()
        split.parse += t1 - t0; split.project += t2 - t1; split.layout += t3 - t2
        if draw {
            let screen = CGRect(x: 0, y: (rect.midY - 400).rounded(), width: 1000, height: 800)
            let visible = layout.layoutIfNeeded(in: screen.minY...screen.maxY)
            bitmap.saveGState()
            bitmap.translateBy(x: 0, y: -screen.minY)
            renderer.draw(visible, layout: layout, in: bitmap, dirty: screen)
            bitmap.restoreGState()
            split.draw += now() - t3
        }
    }
    time("\(name): lipi keystroke → caret rect", iterations: 200) { for _ in 0..<200 { keystroke(draw: false) } }
    split = (0, 0, 0, 0)
    time("\(name): lipi keystroke → screen drawn", iterations: 200) { for _ in 0..<200 { keystroke(draw: true) } }
    print(String(format: "  per keystroke: parse %.0f µs, reveal+project %.0f µs, layout+caret %.0f µs, draw %.0f µs; cache hits %d, misses %d",
                 split.parse / 200_000, split.project / 200_000, split.layout / 200_000, split.draw / 200_000, layout.cache.hits, layout.cache.misses))
    var probeRNG = SplitMix64(seed: 5)
    let probes = (0..<10_000).map { _ in buffer.rope.floorScalarBoundary(probeRNG.below(buffer.count)) }
    time("\(name): lipi caret rect (random offset)", iterations: 10_000) {
        var acc: CGFloat = 0
        for o in probes { acc += layout.caretRect(forSource: o)?.minY ?? 0 }
        if acc == 42 { print(acc) }
    }
    let points = probes.map { _ in CGPoint(x: CGFloat(probeRNG.below(1000)), y: CGFloat(probeRNG.below(Int(layout.contentHeight)))) }
    time("\(name): lipi hit test (random point)", iterations: 10_000) {
        var acc = 0
        for p in points { acc &+= layout.sourceOffset(at: p) ?? 0 }
        if acc == 42 { print(acc) }
    }

    // TextKit 2 on the same projection, at the same text-column width.
    let tk = TextKit2Layout(width: layout.measure)
    let beforeTK = physFootprint()
    time("\(name): tk2 load (attributed string)", iterations: 1) { tk.load(projection, typesetter: typesetter) }
    time("\(name): tk2 first screen layout", iterations: 1) { tk.ensureLayout(toY: 800) }
    time("\(name): tk2 first screen draw", iterations: 1) { tk.draw(in: bitmap, rect: viewport) }
    time("\(name): tk2 first screen draw (warm)", iterations: 1) { tk.draw(in: bitmap, rect: viewport) }
    time("\(name): tk2 full layout", iterations: 1) { tk.ensureLayoutToEnd() }
    let afterTK = physFootprint()
    print("  used height \(Int(tk.usedHeight)) pt, +\(megabytes(afterTK - beforeTK)) resident")
    func tkKeystroke(draw: Bool) {
        let delta = buffer.apply(.insert("k", at: SourceOffset(caret)))
        parser.apply(delta, then: buffer.rope)
        caret += 1
        let reveal = policy.revealSet(caret: caret, index: parser.index, rope: buffer.rope)
        let update = projection.update(index: parser.index, rope: buffer.rope, reveal: reveal)
        for i in update.changedEntries { tk.replaceEntry(i, with: projection.entries[i], typesetter: typesetter) }
        guard let position = projection.position(forSource: caret),
              let rect = tk.caretRect(forDocumentOffset: tk.documentOffset(of: position)) else { return }
        if draw {
            let screen = CGRect(x: 0, y: (rect.midY - 400).rounded(), width: 1000, height: 800)
            bitmap.saveGState()
            bitmap.translateBy(x: 0, y: -screen.minY)
            tk.draw(in: bitmap, rect: screen)
            bitmap.restoreGState()
        }
    }
    time("\(name): tk2 keystroke → caret rect", iterations: 200) { for _ in 0..<200 { tkKeystroke(draw: false) } }
    time("\(name): tk2 keystroke → screen drawn", iterations: 200) { for _ in 0..<200 { tkKeystroke(draw: true) } }
    time("\(name): tk2 caret rect (random offset)", iterations: 10_000) {
        var acc: CGFloat = 0
        for o in probes {
            if let p = projection.position(forSource: o) { acc += tk.caretRect(forDocumentOffset: tk.documentOffset(of: p))?.minY ?? 0 }
        }
        if acc == 42 { print(acc) }
    }
    let tkPoints = points.map { CGPoint(x: min($0.x, layout.measure - 1), y: min($0.y, tk.usedHeight - 1)) }
    time("\(name): tk2 hit test (random point)", iterations: 10_000) {
        var acc = 0
        for p in tkPoints { acc &+= tk.documentOffset(at: p) ?? 0 }
        if acc == 42 { print(acc) }
    }
}
