import Foundation
import LipiCore

setvbuf(stdout, nil, _IONBF, 0)

/// Phase 0 micro-benchmarks for the rope. Run with `swift run -c release lipi-bench`.
/// Exit criterion (PRD §10, Phase 0): random insert into a 1 MB document under 5 µs.

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

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

var rng = SplitMix64(state: 7)
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
var parserRNG = SplitMix64(state: 11)
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
