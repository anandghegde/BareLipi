import Testing
@testable import LipiCore

// MARK: - Deterministic generator

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Mixed-script alphabet: ASCII, newlines, CRLF, Kannada, Devanagari with
/// combining marks, Tamil, CJK, Arabic, emoji with ZWJ, 4-byte scalars.
let pieces: [String] = [
    "the ", "quick ", "brown\n", "fox\r\n", "\n", " ", "a", "Z",
    "ಬರೆ ", "ಲಿಪಿ\n", "ಕನ್ನಡ", "नमस्ते ", "क्षत्रिय", "தமிழ்", "日本語", "漢字\n",
    "مرحبا ", "e\u{301}", "\u{0915}\u{094D}\u{0937}", "👨‍👩‍👧‍👦", "🇮🇳", "𝔘𝔫𝔦", "🙂\n",
]

/// Line-break-heavy alphabet: lone `\r` (classic Mac), `\r\n` and `\n` in
/// every order, so pairs get split, joined and straddle leaves.
let lineBreakPieces: [String] = [
    "\r", "\n", "\r\n", "ab", "\rx", "y\r", "\n\r", "ಕ\r", "🙂", String(repeating: "w", count: 90),
]

func randomText(_ rng: inout SplitMix64, maxPieces: Int, from alphabet: [String] = pieces) -> String {
    let n = Int(rng.next() % UInt64(maxPieces + 1))
    var s = ""
    for _ in 0..<n { s += alphabet[Int(rng.next() % UInt64(alphabet.count))] }
    return s
}

/// A random byte offset that is a scalar boundary in `s`.
func randomBoundary(_ rng: inout SplitMix64, in s: String) -> Int {
    let scalars = s.unicodeScalars
    let n = scalars.count
    let k = Int(rng.next() % UInt64(n + 1))
    let idx = scalars.index(scalars.startIndex, offsetBy: k)
    return s.utf8.distance(from: s.utf8.startIndex, to: idx)
}

extension String {
    func byteIndex(_ b: Int) -> String.Index { utf8.index(utf8.startIndex, offsetBy: b) }
    func replacingBytes(_ r: Range<Int>, with t: String) -> String {
        var s = self
        s.replaceSubrange(byteIndex(r.lowerBound)..<byteIndex(r.upperBound), with: t)
        return s
    }
    func utf16Offset(ofByte b: Int) -> Int { utf16.distance(from: utf16.startIndex, to: byteIndex(b)) }
    func scalarOffset(ofByte b: Int) -> Int { unicodeScalars.distance(from: unicodeScalars.startIndex, to: byteIndex(b)) }
    /// Byte offsets just after each line break (`\n`, `\r\n`, lone `\r`), as cmark-gfm reads them.
    func lineBreakEnds() -> [Int] {
        let u = Array(utf8)
        var ends: [Int] = []
        var i = 0
        while i < u.count {
            if u[i] == 0x0D, i + 1 < u.count, u[i + 1] == 0x0A { i += 2; ends.append(i); continue }
            if u[i] == 0x0A || u[i] == 0x0D { ends.append(i + 1) }
            i += 1
        }
        return ends
    }
    /// Line breaks wholly before byte `b` (a `\r\n` counts once `b` is past its `\n`).
    func newlines(before b: Int) -> Int { lineBreakEnds().filter { $0 <= b }.count }
    func lineStartByte(_ line: Int) -> Int {
        if line == 0 { return 0 }
        let ends = lineBreakEnds()
        return line <= ends.count ? ends[line - 1] : utf8.count
    }
}

// MARK: - Property tests

@Suite("LipiRope properties")
struct LipiRopePropertyTests {
    static let seeds: [UInt64] = [1, 2, 3, 42, 0xDEAD_BEEF, 2026]

    @Test("random edits match a String model", arguments: seeds)
    func randomEditsMatchModel(seed: UInt64) throws {
        checkRandomEdits(seed: seed, alphabet: pieces)
    }

    @Test("random edits over lone CR, CRLF and LF match a String model", arguments: seeds)
    func randomLineBreakEditsMatchModel(seed: UInt64) throws {
        checkRandomEdits(seed: seed, alphabet: lineBreakPieces)
    }

    private func checkRandomEdits(seed: UInt64, alphabet: [String]) {
        var rng = SplitMix64(seed: seed)
        var model = randomText(&rng, maxPieces: 400, from: alphabet)
        var rope = LipiRope(model)
        #expect(rope.string == model)

        for step in 0..<600 {
            let op = rng.next() % 10
            switch op {
            case 0..<5: // insert, occasionally large to force leaf splits
                let big = rng.next() % 8 == 0
                let text = randomText(&rng, maxPieces: big ? 600 : 6, from: alphabet)
                let at = randomBoundary(&rng, in: model)
                model = model.replacingBytes(at..<at, with: text)
                rope.insert(text, at: at)
            case 5..<8: // delete
                let a = randomBoundary(&rng, in: model)
                let b = randomBoundary(&rng, in: model)
                let r = min(a, b)..<max(a, b)
                model = model.replacingBytes(r, with: "")
                rope.remove(r)
            default: // replace
                let a = randomBoundary(&rng, in: model)
                let b = randomBoundary(&rng, in: model)
                let r = min(a, b)..<max(a, b)
                let text = randomText(&rng, maxPieces: 10, from: alphabet)
                model = model.replacingBytes(r, with: text)
                rope.replace(r, with: text)
            }

            let problems = rope.validateStructure()
            #expect(problems.isEmpty, "step \(step): \(problems)")
            #expect(rope.count == model.utf8.count, "step \(step) bytes")
            #expect(rope.utf16Count == model.utf16.count, "step \(step) utf16")
            #expect(rope.scalarCount == model.unicodeScalars.count, "step \(step) scalars")
            #expect(rope.lineCount == model.newlines(before: model.utf8.count) + 1, "step \(step) lines")
            if step % 25 == 0 || step == 599 {
                #expect(rope.string == model, "step \(step) content")
                for _ in 0..<12 {
                    let b = randomBoundary(&rng, in: model)
                    let u = model.utf16Offset(ofByte: b)
                    #expect(rope.utf16Offset(fromByte: b) == u, "utf16 at \(b)")
                    #expect(rope.byteOffset(fromUTF16: u) == b, "byte from utf16 \(u)")
                    let sc = model.scalarOffset(ofByte: b)
                    #expect(rope.scalarOffset(fromByte: b) == sc)
                    #expect(rope.byteOffset(fromScalar: sc) == b)
                    let line = model.newlines(before: b)
                    #expect(rope.line(at: b) == line, "line at \(b)")
                    #expect(rope.lineStart(line) == model.lineStartByte(line), "lineStart \(line)")
                    #expect(rope.lineRange(line).contains(b) || rope.lineRange(line).upperBound == b, "lineRange \(line) holds \(b)")
                    #expect(rope.isScalarBoundary(at: b))
                    let a = randomBoundary(&rng, in: model)
                    let r = min(a, b)..<max(a, b)
                    #expect(rope.string(in: r) == String(model[model.byteIndex(r.lowerBound)..<model.byteIndex(r.upperBound)]))
                    #expect(rope.subrope(r).string == rope.string(in: r))
                }
            }
        }
        #expect(rope.string == model)
    }

    @Test("snapshots are unaffected by later edits")
    func persistence() {
        var rope = LipiRope(String(repeating: "abc\n", count: 2000))
        let snapshot = rope
        rope.insert("XYZ", at: 4000)
        rope.remove(0..<100)
        #expect(snapshot.count == 8000)
        #expect(snapshot.string == String(repeating: "abc\n", count: 2000))
        #expect(rope.count == 7903)
    }
}

// MARK: - Unit tests

@Suite("LipiRope basics")
struct LipiRopeBasicTests {
    @Test func empty() {
        let r = LipiRope()
        #expect(r.count == 0)
        #expect(r.lineCount == 1)
        #expect(r.string == "")
        #expect(r.isScalarBoundary(at: 0))
        #expect(r.lineRange(0) == 0..<0)
        #expect(r.validateStructure().isEmpty)
    }

    @Test func lineSemantics() {
        let r: LipiRope = "a\nbb\n"
        #expect(r.lineCount == 3)
        #expect(r.lineRange(0) == 0..<2)
        #expect(r.lineRange(1) == 2..<5)
        #expect(r.lineRange(2) == 5..<5)
        #expect(r.line(at: 0) == 0)
        #expect(r.line(at: 1) == 0)
        #expect(r.line(at: 2) == 1)
        #expect(r.line(at: 5) == 2)
        #expect(r.lineColumn(at: 4) == (1, 2))
    }

    @Test func loneCRAndCRLFAreLineBreaks() {
        let r: LipiRope = "a\rb\r\nc\n\rd"
        #expect(r.lineCount == 5)
        #expect(r.lineRange(0) == 0..<2)   // "a\r"
        #expect(r.lineRange(1) == 2..<5)   // "b\r\n"
        #expect(r.lineRange(2) == 5..<7)   // "c\n"
        #expect(r.lineRange(3) == 7..<8)   // "\r"
        #expect(r.lineRange(4) == 8..<9)   // "d"
        #expect(r.line(at: 1) == 0)
        #expect(r.line(at: 2) == 1)
        #expect(r.line(at: 4) == 1)        // between the CR and LF of a pair
        #expect(r.line(at: 5) == 2)
        #expect(r.line(at: 8) == 4)
        let classic: LipiRope = "one\rtwo\r"
        #expect(classic.lineCount == 3)
        #expect(classic.lineRange(1) == 4..<8)
        #expect(classic.lineRange(2) == 8..<8)
    }

    @Test func crlfStraddlingLeavesIsOneBreak() {
        // Typing `\n` after a `\r` that ends a leaf puts the `\n` at the
        // start of the next leaf; the pair must still be one break.
        var text = String(repeating: "a", count: 767) + "\r"
        text += String(repeating: "b", count: 2000)
        var r = LipiRope(text)
        var firstChunk = 0
        r.forEachChunk { if firstChunk == 0 { firstChunk = $0.utf8.count } }
        #expect(firstChunk == 768)
        #expect(r.lineCount == 2)
        r.insert("\n", at: 768)
        var chunks: [Substring] = []
        r.forEachChunk { chunks.append($0) }
        #expect(chunks[0].utf8.last == 0x0D && chunks[1].utf8.first == 0x0A)
        #expect(r.validateStructure().isEmpty)
        #expect(r.lineCount == 2)
        #expect(r.lineStart(1) == 769)
        #expect(r.line(at: 768) == 0)
        #expect(r.line(at: 769) == 1)
        #expect(r.lineRange(0) == 0..<769)
    }

    @Test func utf16SurrogateRoundsDown() {
        let r: LipiRope = "a🙂b"  // 🙂 is 4 bytes, 2 UTF-16 units
        #expect(r.utf16Count == 4)
        #expect(r.byteOffset(fromUTF16: 1) == 1)
        #expect(r.byteOffset(fromUTF16: 2) == 1)  // inside the pair
        #expect(r.byteOffset(fromUTF16: 3) == 5)
        #expect(r.utf16Offset(fromByte: 5) == 3)
        #expect(r.utf16Range(fromBytes: 1..<5) == 1..<3)
        #expect(r.byteRange(fromUTF16: 1..<3) == 1..<5)
    }

    @Test func scalarBoundaries() {
        let r: LipiRope = "ಬರೆ"  // 3 scalars, 3 bytes each
        #expect(r.count == 9)
        #expect(r.isScalarBoundary(at: 3))
        #expect(!r.isScalarBoundary(at: 4))
        #expect(r.floorScalarBoundary(5) == 3)
        #expect(r.floorScalarBoundary(99) == 9)
        #expect(r.byte(at: 0) == 0xE0)
    }

    @Test func largeDocumentShape() {
        let text = String(repeating: "The quick brown fox jumps over the lazy dog.\n", count: 23_000) // ~1 MB
        var r = LipiRope(text)
        #expect(r.count == text.utf8.count)
        #expect(r.validateStructure().isEmpty)
        #expect(r.height <= 8, "height \(r.height)")
        for i in 0..<200 { r.insert("x", at: (i * 5_003) % r.count) }
        #expect(r.validateStructure().isEmpty)
        #expect(r.count == text.utf8.count + 200)
        #expect(r.height <= 9)
    }

    @Test func crlfStaysTogetherAcrossChunks() {
        // A CRLF straddling the bulk chunk cut (768 bytes) must not be split.
        var text = String(repeating: "a", count: 767) + "\r\n"
        text += String(repeating: "b", count: 2000)
        let r = LipiRope(text)
        var chunks: [Substring] = []
        r.forEachChunk { chunks.append($0) }
        #expect(chunks.count >= 3)
        for (i, c) in chunks.enumerated() where i > 0 {
            let prevEndsWithCR = chunks[i - 1].utf8.last == 0x0D
            let startsWithLF = c.utf8.first == 0x0A
            #expect(!(prevEndsWithCR && startsWithLF), "CRLF split at chunk \(i)")
        }
        #expect(r.string == text)
        #expect(r.lineCount == 2)
    }
}

// MARK: - SourceBuffer

@Suite("SourceBuffer")
struct SourceBufferTests {
    @Test func applyUndoRedo() {
        var b = SourceBuffer("hello world")
        let d = b.apply(.insert(", brave", at: SourceOffset(5)))
        #expect(b.rope.string == "hello, brave world")
        #expect(d.newRange == SourceOffset(5)..<SourceOffset(12))
        #expect(b.generation == 1)
        b.apply(Edit(replacing: 0..<5, with: "goodbye"))
        #expect(b.rope.string == "goodbye, brave world")
        #expect(b.canUndo)
        b.undo()
        #expect(b.rope.string == "hello, brave world")
        b.undo()
        #expect(b.rope.string == "hello world")
        #expect(!b.canUndo)
        b.redo()
        #expect(b.rope.string == "hello, brave world")
        b.redo()
        #expect(b.rope.string == "goodbye, brave world")
        #expect(!b.canRedo)
        #expect(b.generation == 6)
    }

    @Test func undoGroups() {
        var b = SourceBuffer("")
        b.beginUndoGroup()
        b.apply(.insert("a", at: .zero))
        b.apply(.insert("b", at: SourceOffset(1)))
        b.apply(.insert("c", at: SourceOffset(2)))
        b.endUndoGroup()
        #expect(b.rope.string == "abc")
        b.undo()
        #expect(b.rope.string == "")
        b.redo()
        #expect(b.rope.string == "abc")
        b.apply([.insert("1", at: .zero), .insert("2", at: SourceOffset(1))])
        #expect(b.rope.string == "12abc")
        b.undo()
        #expect(b.rope.string == "abc")
    }

    @Test func newEditClearsRedo() {
        var b = SourceBuffer("x")
        b.apply(.insert("y", at: SourceOffset(1)))
        b.undo()
        #expect(b.canRedo)
        b.apply(.insert("z", at: SourceOffset(1)))
        #expect(!b.canRedo)
        #expect(b.rope.string == "xz")
    }

    @Test func deltaMapping() {
        let d = Delta(oldRange: SourceOffset(5)..<SourceOffset(8), newRange: SourceOffset(5)..<SourceOffset(10), generation: 1)
        #expect(d.map(SourceOffset(2)) == SourceOffset(2))
        #expect(d.map(SourceOffset(8)) == SourceOffset(10))
        #expect(d.map(SourceOffset(20)) == SourceOffset(22))
        #expect(d.map(SourceOffset(6)) == SourceOffset(10))
        #expect(d.map(SourceOffset(6), preferEnd: false) == SourceOffset(5))
    }

    @Test func snapshotIsolation() {
        var b = SourceBuffer("one")
        let snap = b.snapshot()
        b.apply(.insert(" two", at: SourceOffset(3)))
        #expect(snap.rope.string == "one")
        #expect(snap.generation == 0)
        #expect(b.snapshot().generation == 1)
    }
}
