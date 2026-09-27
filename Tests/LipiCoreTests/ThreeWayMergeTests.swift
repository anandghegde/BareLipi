import Testing
@testable import LipiCore

@Suite("Line diff")
struct LineDiffTests {
    func lines(_ s: String) -> [String] {
        let b = Array(s.utf8)
        return LineDiff.lines(b).map { String(decoding: b[$0], as: UTF8.self) }
    }

    @Test func linesKeepTheirTerminators() {
        #expect(lines("") == [])
        #expect(lines("a") == ["a"])
        #expect(lines("a\n") == ["a\n"])
        #expect(lines("a\r\nb\rc\nd") == ["a\r\n", "b\r", "c\n", "d"])
        #expect(lines("\n\r\n\r") == ["\n", "\r\n", "\r"])
        #expect(lines("a\r\r\n") == ["a\r", "\r\n"])
    }

    /// Longest common subsequence length by dynamic programming.
    func lcsLength(_ a: [Int], _ b: [Int]) -> Int {
        var row = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var diagonal = 0
            for j in 0..<b.count {
                let up = row[j + 1]
                row[j + 1] = x == b[j] ? diagonal + 1 : max(row[j + 1], row[j])
                diagonal = up
            }
        }
        return row[b.count]
    }

    @Test("matches are a longest common subsequence", arguments: Array(1...40) as [UInt64])
    func matchesAreOptimal(_ seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        for _ in 0..<50 {
            let alphabet = Int(rng.next() % 5) + 1
            let a = (0..<Int(rng.next() % 30)).map { _ in Int(rng.next() % UInt64(alphabet)) }
            let b = (0..<Int(rng.next() % 30)).map { _ in Int(rng.next() % UInt64(alphabet)) }
            let pairs = LineDiff.matches(a, b)
            for (n, (i, j)) in pairs.enumerated() {
                #expect(a[i] == b[j])
                if n > 0 { #expect(i > pairs[n - 1].0 && j > pairs[n - 1].1) }
            }
            #expect(pairs.count == lcsLength(a, b), "a=\(a) b=\(b)")
        }
    }

    @Test func largeInputsDiffQuickly() {
        let a = (0..<20_000).map { $0 }
        var b = a
        for i in stride(from: 0, to: b.count, by: 97) { b[i] = -i - 1 }
        b.insert(contentsOf: [-1, -2, -3], at: 5_000)
        #expect(LineDiff.matches(a, b).count == a.count - (a.count + 96) / 97)
    }
}

@Suite("Three-way merge (P1-04)")
struct ThreeWayMergeTests {
    func merge(_ base: String, _ mine: String, _ theirs: String, newline: String = "\n") -> ThreeWayMerge {
        ThreeWayMerge(base: Array(base.utf8), mine: Array(mine.utf8), theirs: Array(theirs.utf8), newline: Array(newline.utf8))
    }

    func text(_ m: ThreeWayMerge) -> String { String(decoding: m.merged, as: UTF8.self) }

    @Test func cleanNonOverlappingChanges() {
        let m = merge("a\nb\nc\nd\ne\n", "A\nb\nc\nd\ne\n", "a\nb\nc\nd\nE\n")
        #expect(m.isClean)
        #expect(text(m) == "A\nb\nc\nd\nE\n")
        #expect(m.replacements == [.init(range: 8..<10, bytes: Array("E\n".utf8), isConflict: false)],
                "only theirs' region of mine is replaced")
    }

    @Test func identicalChangesOnBothSides() {
        let m = merge("a\nb\nc\n", "a\nB\nc\n", "a\nB\nc\n")
        #expect(m.isClean)
        #expect(m.replacements.isEmpty)
        #expect(text(m) == "a\nB\nc\n")
    }

    @Test func overlappingChangesConflict() {
        let m = merge("a\nb\nc\n", "a\nmine\nc\n", "a\ntheirs\nc\n")
        #expect(m.conflictCount == 1)
        #expect(text(m) == "a\n<<<<<<< Mine\nmine\n=======\ntheirs\n>>>>>>> Theirs\nc\n")
    }

    @Test func twoConflictsAndACleanChange() {
        let m = merge("1\n2\n3\n4\n5\n6\n7\n", "1\nx\n3\n4\n5\ny\n7\n", "1\nX\n3\nfour\n5\nY\n7\n")
        #expect(m.conflictCount == 2)
        #expect(text(m) == "1\n<<<<<<< Mine\nx\n=======\nX\n>>>>>>> Theirs\n3\nfour\n5\n<<<<<<< Mine\ny\n=======\nY\n>>>>>>> Theirs\n7\n")
        #expect(ThreeWayMerge.conflictStarts(in: m.merged) == [2, 51])
    }

    @Test func deleteAgainstEditConflicts() {
        let m = merge("a\nb\nc\n", "a\nc\n", "a\nB\nc\n")
        #expect(text(m) == "a\n<<<<<<< Mine\n=======\nB\n>>>>>>> Theirs\nc\n")
    }

    @Test func insertionsAtStartAndEnd() {
        let m = merge("a\nb\n", "top\na\nb\n", "a\nb\nbottom\n")
        #expect(m.isClean)
        #expect(text(m) == "top\na\nb\nbottom\n")
        let both = merge("a\n", "mine\na\n", "theirs\na\n")
        #expect(text(both) == "<<<<<<< Mine\nmine\n=======\ntheirs\n>>>>>>> Theirs\na\n")
    }

    @Test func deletions() {
        #expect(text(merge("a\nb\nc\nd\n", "b\nc\nd\n", "a\nb\nc\n")) == "b\nc\n")
        #expect(text(merge("a\nb\nc\n", "a\nc\n", "a\nc\n")) == "a\nc\n")
        #expect(text(merge("a\nb\nc\n", "a\nb\nc\n", "")) == "")
    }

    @Test func crlfIsPreservedAndMarkersUseTheDocumentsEnding() {
        let m = merge("a\r\nb\r\nc\r\n", "A\r\nb\r\nc\r\n", "a\r\nb\r\nC\r\n", newline: "\r\n")
        #expect(text(m) == "A\r\nb\r\nC\r\n")
        let c = merge("a\r\nb\r\n", "a\r\nmine\r\n", "a\r\ntheirs\r\n", newline: "\r\n")
        #expect(text(c) == "a\r\n<<<<<<< Mine\r\nmine\r\n=======\r\ntheirs\r\n>>>>>>> Theirs\r\n")
    }

    @Test func lineEndingChangeIsAChange() {
        // Theirs converted one line to CRLF; mine edited another.
        #expect(text(merge("a\nb\nc\n", "A\nb\nc\n", "a\nb\nc\r\n")) == "A\nb\nc\r\n")
        // Mixed and CR-only endings come through untouched.
        #expect(text(merge("a\rb\r\nc\n", "a\rB\r\nc\n", "a\rb\r\nc\nd")) == "a\rB\r\nc\nd")
    }

    @Test func noFinalNewline() {
        #expect(text(merge("a\nm\nb", "A\nm\nb", "a\nm\nB")) == "A\nm\nB")
        // Adjacent changes with no untouched line between them conflict, as in diff3.
        #expect(!merge("a\nb", "A\nb", "a\nB").isClean)
        #expect(text(merge("a\nb\nc", "A\nb\nc", "a\nb\nc\nd")) == "A\nb\nc\nd")
        // Both edit the unterminated last line: the closing marker does not
        // add a final newline the file never had.
        let m = merge("a\nb", "a\nmine", "a\ntheirs")
        #expect(text(m) == "a\n<<<<<<< Mine\nmine\n=======\ntheirs\n>>>>>>> Theirs")
    }

    @Test func emptyFiles() {
        #expect(text(merge("", "", "")) == "")
        #expect(text(merge("", "mine\n", "")) == "mine\n")
        #expect(text(merge("", "", "theirs\n")) == "theirs\n")
        #expect(text(merge("", "x\n", "x\n")) == "x\n")
        #expect(text(merge("", "mine\n", "theirs\n")) == "<<<<<<< Mine\nmine\n=======\ntheirs\n>>>>>>> Theirs\n")
        #expect(text(merge("a\n", "", "a\n")) == "")
    }

    @Test func multiByteTextIsLeftIntact() {
        let m = merge("ಕನ್ನಡ\nपाठ\n🙂\n", "ಕನ್ನಡ ಪಠ್ಯ\nपाठ\n🙂\n", "ಕನ್ನಡ\nपाठ\n🙂👍\n")
        #expect(text(m) == "ಕನ್ನಡ ಪಠ್ಯ\nपाठ\n🙂👍\n")
    }

    // MARK: Properties

    static let tokens: [[UInt8]] = ["a", "b", "ಕ", "\n", "\n", "\r\n", "\r", "x\n"].map { Array($0.utf8) }

    func soup(_ rng: inout SplitMix64) -> [UInt8] {
        (0..<Int(rng.next() % 24)).flatMap { _ in ThreeWayMergeTests.tokens[Int(rng.next() % UInt64(ThreeWayMergeTests.tokens.count))] }
    }

    @Test("theirs == base gives mine; mine == base gives theirs; mine == theirs gives it",
          arguments: Array(1...30) as [UInt64])
    func identities(_ seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        for _ in 0..<60 {
            let base = soup(&rng), other = soup(&rng)
            #expect(ThreeWayMerge(base: base, mine: other, theirs: base).merged == other)
            #expect(ThreeWayMerge(base: base, mine: other, theirs: base).replacements.isEmpty)
            #expect(ThreeWayMerge(base: base, mine: base, theirs: other).merged == other)
            let same = ThreeWayMerge(base: base, mine: other, theirs: other)
            #expect(same.merged == other && same.isClean)
        }
    }

    @Test("edits to separate regions merge cleanly, whatever the line endings",
          arguments: Array(1...30) as [UInt64])
    func separatedEditsMergeCleanly(_ seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        var fresh = 0
        func line(_ name: String) -> [UInt8] {
            let endings = ["\n", "\r\n", "\r"]
            return Array((name + endings[Int(rng.next() % 3)]).utf8)
        }
        let count = 8 + Int(rng.next() % 40)
        var base = (0..<count).map { line("l\($0)") }
        let unterminated = rng.next() % 2 == 0
        if unterminated { base[count - 1] = Array("last".utf8) }
        // Edit sites with at least one untouched line between them; the
        // last line is never edited.
        var mine = base.map { [$0] }, theirs = base.map { [$0] }, expected = base.map { [$0] }
        var index = Int(rng.next() % 3)
        var mineTurn = rng.next() % 2 == 0
        while index < count - 2 {
            let removeCount = Int(rng.next() % 3)
            let removed = min(removeCount, count - 2 - index)
            let inserted = (0..<Int(rng.next() % 3)).map { _ -> [UInt8] in fresh += 1; return line("new\(fresh)") }
            // Replace lines index..<index+removed with `inserted`, kept on the
            // first slot so indices stay aligned with base.
            var slots = Array(repeating: [[UInt8]](), count: max(removed, 1))
            slots[0] = inserted
            if removed == 0 { slots[0] = inserted + [base[index]] }
            for s in 0..<slots.count {
                expected[index + s] = slots[s]
                if mineTurn { mine[index + s] = slots[s] } else { theirs[index + s] = slots[s] }
            }
            mineTurn.toggle()
            index += max(removed, 1) + 1 + Int(rng.next() % 3)
        }
        func join(_ x: [[[UInt8]]]) -> [UInt8] { x.flatMap { $0.flatMap { $0 } } }
        let m = ThreeWayMerge(base: join(base.map { [$0] }), mine: join(mine), theirs: join(theirs))
        #expect(m.isClean)
        #expect(m.merged == join(expected))
        // Everything outside the replacements is mine's bytes, untouched.
        let mineBytes = join(mine)
        var at = 0
        for r in m.replacements {
            #expect(r.range.lowerBound >= at)
            at = r.range.upperBound
        }
        #expect(at <= mineBytes.count)
    }
}
