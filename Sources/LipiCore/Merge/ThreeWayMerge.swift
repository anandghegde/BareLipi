/// Line-based three-way merge (diff3, P1-04) of the text last read from or
/// written to disk (base), the editor's text (mine) and the file's new text
/// (theirs). Works on raw UTF-8 bytes: lines keep their own terminators, so
/// CRLF, CR, mixed endings and a missing final newline come through as they
/// were, and every byte outside a changed region of mine is left alone.
///
/// The result is a list of replacements in mine's byte coordinates: regions
/// only theirs changed take theirs' lines; regions both changed differently
/// become a conflict wrapped in `<<<<<<< Mine` / `=======` / `>>>>>>> Theirs`.
public struct ThreeWayMerge: Sendable, Equatable {
    /// A change to mine: `range` (bytes of mine, on line boundaries) becomes
    /// `bytes`.
    public struct Replacement: Sendable, Equatable {
        public var range: Range<Int>
        public var bytes: [UInt8]
        public var isConflict: Bool
    }

    public static let mineMarker = Array("<<<<<<< Mine".utf8)
    public static let separatorMarker = Array("=======".utf8)
    public static let theirsMarker = Array(">>>>>>> Theirs".utf8)

    /// Disjoint, in increasing order, never adjacent.
    public private(set) var replacements: [Replacement]
    /// The merged text: mine with the replacements applied.
    public private(set) var merged: [UInt8]

    public var conflictCount: Int { replacements.reduce(0) { $0 + ($1.isConflict ? 1 : 0) } }
    public var isClean: Bool { !replacements.contains { $0.isConflict } }

    /// Merges `theirs` into `mine` against their common ancestor `base`.
    /// `newline` terminates the conflict marker lines.
    public init(base: [UInt8], mine: [UInt8], theirs: [UInt8], newline: [UInt8] = [0x0A]) {
        let baseLines = LineDiff.lines(base), mineLines = LineDiff.lines(mine), theirLines = LineDiff.lines(theirs)
        // One id per distinct line content across the three texts.
        var table: [ArraySlice<UInt8>: Int] = [:]
        func ids(_ bytes: [UInt8], _ lines: [Range<Int>]) -> [Int] {
            lines.map { r in
                let line = bytes[r]
                if let id = table[line] { return id }
                table[line] = table.count
                return table.count - 1
            }
        }
        let o = ids(base, baseLines), a = ids(mine, mineLines), b = ids(theirs, theirLines)
        var toMine = [Int?](repeating: nil, count: o.count)
        var toTheirs = [Int?](repeating: nil, count: o.count)
        for (i, j) in LineDiff.matches(o, a) { toMine[i] = j }
        for (i, j) in LineDiff.matches(o, b) { toTheirs[i] = j }

        func byteRange(_ lines: [Range<Int>], _ r: Range<Int>, total: Int) -> Range<Int> {
            let lo = r.lowerBound < lines.count ? lines[r.lowerBound].lowerBound : total
            let hi = r.upperBound < lines.count ? lines[r.upperBound].lowerBound : total
            return lo..<hi
        }

        var replacements: [Replacement] = []
        func unstable(_ ro: Range<Int>, _ ra: Range<Int>, _ rb: Range<Int>) {
            let mineIDs = a[ra], theirIDs = b[rb], baseIDs = o[ro]
            let mineRange = byteRange(mineLines, ra, total: mine.count)
            if theirIDs.elementsEqual(baseIDs) || mineIDs.elementsEqual(theirIDs) { return }  // keep mine
            let theirBytes = Array(theirs[byteRange(theirLines, rb, total: theirs.count)])
            if mineIDs.elementsEqual(baseIDs) {
                replacements.append(Replacement(range: mineRange, bytes: theirBytes, isConflict: false))
                return
            }
            let mineBytes = Array(mine[mineRange])
            var out = ThreeWayMerge.mineMarker + newline
            out += mineBytes
            if !mineBytes.isEmpty, !LineDiff.endsWithTerminator(mineBytes) { out += newline }
            out += ThreeWayMerge.separatorMarker + newline
            out += theirBytes
            if !theirBytes.isEmpty, !LineDiff.endsWithTerminator(theirBytes) { out += newline }
            out += ThreeWayMerge.theirsMarker
            // The closing marker ends its line, except at the very end of a
            // text that had no final newline.
            let atEnd = mineRange.upperBound == mine.count
            let finalTerminated = mine.isEmpty ? (theirs.isEmpty || LineDiff.endsWithTerminator(theirs)) : LineDiff.endsWithTerminator(mine)
            if !atEnd || finalTerminated { out += newline }
            replacements.append(Replacement(range: mineRange, bytes: out, isConflict: true))
        }

        var i = 0, j = 0, k = 0  // positions in base, mine, theirs (lines)
        while true {
            var run = 0
            while i + run < o.count, toMine[i + run] == j + run, toTheirs[i + run] == k + run { run += 1 }
            if run > 0 {
                i += run; j += run; k += run
                continue
            }
            // The next base line present in all three ends the unstable chunk.
            var next = i
            while next < o.count, toMine[next] == nil || toTheirs[next] == nil { next += 1 }
            if next == o.count {
                if i < o.count || j < a.count || k < b.count { unstable(i..<o.count, j..<a.count, k..<b.count) }
                break
            }
            let nj = toMine[next]!, nk = toTheirs[next]!
            unstable(i..<next, j..<nj, k..<nk)
            i = next; j = nj; k = nk
        }

        var merged: [UInt8] = []
        merged.reserveCapacity(mine.count)
        var at = 0
        for r in replacements {
            merged += mine[at..<r.range.lowerBound]
            merged += r.bytes
            at = r.range.upperBound
        }
        merged += mine[at...]
        self.replacements = replacements
        self.merged = merged
    }

    /// Byte offsets of the `<<<<<<< ` lines in `bytes` (conflict starts).
    public static func conflictStarts(in bytes: [UInt8]) -> [Int] {
        let prefix = Array("<<<<<<< ".utf8)
        return LineDiff.lines(bytes).compactMap { r in
            bytes[r].starts(with: prefix) ? r.lowerBound : nil
        }
    }
}
