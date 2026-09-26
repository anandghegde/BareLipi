import Foundation
import Testing
@testable import LipiCore

/// `SourceBuffer.applyBatch`, the one-pass index update and the concurrent
/// re-parse and projection behind Replace All.
@Suite("Batch edits")
struct BatchEditTests {
    /// Up to `count` disjoint random edits over `rope`, in random order.
    func randomBatch(_ rng: inout SplitMix64, in rope: LipiRope, count: Int) -> [Edit] {
        var points = Set<Int>()
        for _ in 0..<(count * 2) { points.insert(rope.floorScalarBoundary(Int(rng.next() % UInt64(rope.count + 1)))) }
        let sorted = points.sorted()
        var edits: [Edit] = []
        var k = 0
        while k + 1 < sorted.count && edits.count < count {
            let lo = sorted[k]
            // Mostly short replacements; sometimes a pure insertion.
            let hi = rng.next() % 4 == 0 ? lo : min(sorted[k + 1], lo + 12)
            let hiBoundary = rope.floorScalarBoundary(hi)
            let token = editTokens[Int(rng.next() % UInt64(editTokens.count))]
            edits.append(Edit(replacing: lo..<max(lo, hiBoundary), with: token))
            k += 2
        }
        edits.shuffle(using: &rng)
        return edits
    }

    func sequential(_ text: String, _ edits: [Edit]) -> String {
        var buffer = SourceBuffer(text)
        let ordered = edits.sorted {
            $0.range.lowerBound.byte != $1.range.lowerBound.byte ? $0.range.lowerBound.byte > $1.range.lowerBound.byte
                : $0.range.upperBound.byte > $1.range.upperBound.byte
        }
        for e in ordered { buffer.apply(e) }
        return buffer.rope.string
    }

    @Test("a batch gives the same bytes as the edits one at a time, and undoes and redoes in one step",
          arguments: Array(1...12) as [UInt64])
    func matchesSequential(seed: UInt64) throws {
        var rng = SplitMix64(seed: seed)
        let examples = try allExamples()
        var parts: [String] = []
        for _ in 0..<40 { parts.append(examples[Int(rng.next() % UInt64(examples.count))].markdown) }
        // Large enough for the rope's concurrent leaf build on some seeds.
        let text = parts.joined(separator: "\n") + (seed % 3 == 0 ? String(repeating: "Lorem ipsum ಕನ್ನಡ 🙂\n", count: 80_000) : "")
        var buffer = SourceBuffer(text)
        let edits = randomBatch(&rng, in: buffer.rope, count: 200)
        let expected = sequential(text, edits)
        let applied = buffer.applyBatch(edits)
        let deltas = try #require(applied)
        #expect(buffer.rope.string == expected)
        #expect(buffer.rope.validateStructure().isEmpty)
        #expect(deltas.count == edits.count)
        // Deltas run down the document and are valid one after another.
        for k in deltas.indices.dropFirst() { #expect(deltas[k].oldRange.upperBound <= deltas[k - 1].oldRange.lowerBound) }
        #expect(buffer.canUndo)
        let undo = buffer.undoStep()
        #expect(undo.deltas.count == edits.count)
        #expect(buffer.rope.string == text)
        #expect(!buffer.canUndo)
        buffer.redo()
        #expect(buffer.rope.string == expected)
        buffer.undo()
        #expect(buffer.rope.string == text)
    }

    @Test func overlappingOrAmbiguousBatchesAreRefused() {
        var buffer = SourceBuffer("abcdef")
        #expect(buffer.applyBatch([Edit(replacing: 0..<3, with: "x"), Edit(replacing: 2..<4, with: "y")]) == nil)
        #expect(buffer.applyBatch([.insert("1", at: SourceOffset(2)), .insert("2", at: SourceOffset(2))]) == nil)
        #expect(buffer.rope.string == "abcdef")
        #expect(!buffer.canUndo)
        // Touching edits are fine: an insertion at the end of a replacement.
        let deltas = buffer.applyBatch([Edit(replacing: 0..<2, with: "XY"), .insert("-", at: SourceOffset(2))])
        #expect(deltas?.count == 2)
        #expect(buffer.rope.string == "XY-cdef")
        #expect(buffer.applyBatch([]) == [])
    }

    @Test func aBatchInsideAGroupWithOtherEditsUndoesTogether() {
        var buffer = SourceBuffer("one two three")
        buffer.beginUndoGroup()
        buffer.apply(.insert("zero ", at: .zero))
        _ = buffer.applyBatch([Edit(replacing: 5..<8, with: "1"), Edit(replacing: 13..<18, with: "3")])
        buffer.apply(.insert("!", at: SourceOffset(buffer.count)))
        buffer.endUndoGroup()
        #expect(buffer.rope.string == "zero 1 two 3!")
        buffer.undo()
        #expect(buffer.rope.string == "one two three")
        buffer.redo()
        #expect(buffer.rope.string == "zero 1 two 3!")
        // A group that holds just the batch replays it in one pass.
        buffer.beginUndoGroup()
        _ = buffer.applyBatch([Edit(replacing: 0..<4, with: "0"), Edit(replacing: 7..<10, with: "2")])
        buffer.endUndoGroup()
        #expect(buffer.rope.string == "0 1 2 3!")
        buffer.undo()
        #expect(buffer.rope.string == "zero 1 two 3!")
    }

    @Test("a batch re-parses to what a full parse gives", arguments: Array(1...16) as [UInt64])
    func reparseMatchesFullParse(seed: UInt64) throws {
        var rng = SplitMix64(seed: seed &+ 100)
        let examples = try allExamples()
        var parts: [String] = []
        for _ in 0..<60 { parts.append(examples[Int(rng.next() % UInt64(examples.count))].markdown) }
        var buffer = SourceBuffer(parts.joined(separator: "\n"))
        var parser = LipiParser(options: .editor)
        parser.parse(buffer.rope)
        for step in 0..<4 {
            let edits = randomBatch(&rng, in: buffer.rope, count: 40)
            let applied = buffer.applyBatch(edits)
        let deltas = try #require(applied)
            parser.apply(deltas)
            parser.reparse(buffer.rope)
            var full = LipiParser(options: .editor)
            full.parse(buffer.rope)
            let a = parser.blocks, b = full.blocks
            let same = a.count == b.count && zip(a, b).allSatisfy { $0.isStructurallyEqual(to: $1) }
            #expect(same, "seed \(seed) step \(step): batch \(a.count) blocks vs full \(b.count)")
            #expect(parser.references == full.references)
            #expect(parser.index.length == buffer.count)
            var checker = RangeChecker(buffer.rope.string)
            checker.check(parser)
            #expect(checker.failures.isEmpty, Comment(rawValue: checker.failures.prefix(4).joined(separator: "; ")))
            // Undo goes back through the same batch path.
            let undo = buffer.undoStep()
            parser.apply(undo.deltas)
            parser.reparse(buffer.rope)
            var fullUndo = LipiParser(options: .editor)
            fullUndo.parse(buffer.rope)
            #expect(parser.blocks.count == fullUndo.blocks.count
                    && zip(parser.blocks, fullUndo.blocks).allSatisfy { $0.isStructurallyEqual(to: $1) })
            buffer.redo()
            parser.parse(buffer.rope)
            if !same { break }
        }
    }

    @Test func manyScatteredEditsKeepUntouchedBlocksAndIdentities() throws {
        let paragraph = "Lorem ipsum dolor sit amet, *consectetur* adipiscing elit.\n\n"
        let fence = "```swift\nlet dolor = 1\n```\n\n"
        let text = (0..<600).map { $0 % 10 == 0 ? fence : paragraph }.joined()
        var buffer = SourceBuffer(text)
        var parser = LipiParser(options: .editor)
        parser.parse(buffer.rope)
        let before = parser.blocks
        // Every third block gets "dolor" → "DOLOR".
        var edits: [Edit] = []
        var offset = 0
        for (i, block) in text.components(separatedBy: "\n\n").dropLast().enumerated() {
            if i % 3 == 0, let r = block.range(of: "dolor") {
                let lo = offset + block.utf8.distance(from: block.startIndex, to: r.lowerBound)
                edits.append(Edit(replacing: lo..<(lo + 5), with: "DOLOR"))
            }
            offset += block.utf8.count + 2
        }
        #expect(edits.count == 200)
        let applied = buffer.applyBatch(edits)
        let deltas = try #require(applied)
        parser.apply(deltas)
        #expect(parser.index.entries.filter(\.isDirty).count == 200)
        parser.reparse(buffer.rope)
        #expect(parser.stats.lastReparseEntries == 200)
        #expect(parser.stats.fullParses == 1)
        let after = parser.blocks
        #expect(after.count == before.count)
        for i in after.indices {
            #expect((after[i].id == before[i].id) == (i % 3 != 0), "block \(i)")
        }
        var full = LipiParser(options: .editor)
        full.parse(buffer.rope)
        #expect(zip(after, full.blocks).allSatisfy { $0.isStructurallyEqual(to: $1) })
        // Identities stay unique.
        #expect(Set(after.map(\.id)).count == after.count)
    }

    @Test func concurrentProjectionMatchesSerial() {
        let text = (0..<400).map { i in
            switch i % 4 {
            case 0: "# Heading \(i) with *emphasis*\n\n"
            case 1: "- item [link](http://x.y) `code`\n- two\n\n"
            case 2: "| a | b |\n|---|---|\n| \(i) | **x** |\n\n"
            default: "Para ಕನ್ನಡ 🙂 $x^2$ ~~gone~~ \(i)\n\n"
            }
        }.joined()
        var parser = LipiParser(options: .editor)
        let rope = LipiRope(text)
        parser.parse(rope)
        for sourceMode in [false, true] {
            var concurrent = Projection(preset: .balanced)
            var serial = Projection(preset: .balanced)
            concurrent.sourceMode = sourceMode
            serial.sourceMode = sourceMode
            concurrent.concurrentBuildThreshold = 1
            serial.concurrentBuildThreshold = .max
            let r1 = concurrent.update(index: parser.index, rope: rope, reveal: .none)
            let r2 = serial.update(index: parser.index, rope: rope, reveal: .none)
            #expect(r1.changedEntries == r2.changedEntries)
            #expect(concurrent.entries.count == serial.entries.count)
            #expect(zip(concurrent.entries, serial.entries).allSatisfy { $0.blocks == $1.blocks && $0.start == $1.start })
        }
    }
}
