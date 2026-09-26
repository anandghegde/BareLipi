/// Maps a source offset from an old text to a new one through a diff, so the
/// caret stays on the same words when a file is reloaded from disk (§6.16).
/// Common prefix and suffix are cut first; what is left is diffed by lines
/// (Myers), and an offset on an unchanged line keeps its column.
public enum CaretRemap {
    /// The offset in `new` that corresponds to `offset` in `old` (UTF-8
    /// bytes), snapped to a scalar boundary.
    public static func map(_ offset: Int, from old: [UInt8], to new: [UInt8]) -> Int {
        let offset = max(0, min(offset, old.count))
        let shortest = min(old.count, new.count)
        var prefix = 0
        while prefix < shortest, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shortest - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        if offset <= prefix { return snap(offset, in: new) }
        if offset >= old.count - suffix { return snap(offset + new.count - old.count, in: new) }
        // Widen the middle to whole lines so the line diff sees complete lines.
        var start = prefix
        while start > 0, old[start - 1] != 0x0A { start -= 1 }
        let oldMid = Array(old[start..<(old.count - suffix)])
        let newMid = Array(new[start..<(new.count - suffix)])
        return snap(start + mapInMiddle(offset - start, oldMid, newMid), in: new)
    }

    /// Convenience over `String`s.
    public static func map(_ offset: Int, from old: String, to new: String) -> Int {
        map(offset, from: Array(old.utf8), to: Array(new.utf8))
    }

    private static func mapInMiddle(_ offset: Int, _ old: [UInt8], _ new: [UInt8]) -> Int {
        let oldLines = lineStarts(old), newLines = lineStarts(new)
        var ids: [ArraySlice<UInt8>: Int] = [:]
        func id(_ bytes: [UInt8], _ starts: [Int], _ i: Int) -> Int {
            let end = i + 1 < starts.count ? starts[i + 1] : bytes.count
            let line = bytes[starts[i]..<end]
            if let existing = ids[line] { return existing }
            ids[line] = ids.count
            return ids.count - 1
        }
        let a = oldLines.indices.map { id(old, oldLines, $0) }
        let b = newLines.indices.map { id(new, newLines, $0) }
        let line = (oldLines.lastIndex { $0 <= offset }) ?? 0
        let column = offset - oldLines[line]
        guard let pairs = matchedLines(a, b) else {
            // Too different to diff cheaply: keep the relative position.
            return old.isEmpty ? 0 : Int(Double(offset) / Double(old.count) * Double(new.count))
        }
        if let match = pairs.first(where: { $0.0 == line }) {
            let newEnd = match.1 + 1 < newLines.count ? newLines[match.1 + 1] : new.count
            return min(newLines[match.1] + column, newEnd)
        }
        // Inside a changed hunk: same distance into the replacement, clamped.
        let before = pairs.last { $0.0 < line }
        let after = pairs.first { $0.0 > line }
        let oldHunkStart = before.map { $0.0 + 1 < oldLines.count ? oldLines[$0.0 + 1] : old.count } ?? 0
        let newHunkStart = before.map { $0.1 + 1 < newLines.count ? newLines[$0.1 + 1] : new.count } ?? 0
        let newHunkEnd = after.map { newLines[$0.1] } ?? new.count
        return min(newHunkStart + (offset - oldHunkStart), max(newHunkStart, newHunkEnd))
    }

    private static func lineStarts(_ bytes: [UInt8]) -> [Int] {
        var starts = [0]
        for (i, byte) in bytes.enumerated() where byte == 0x0A && i + 1 < bytes.count { starts.append(i + 1) }
        return starts
    }

    /// Myers' O(ND) diff; returns the (old, new) index pairs of equal lines,
    /// or nil when the edit distance exceeds `limit`.
    static func matchedLines(_ a: [Int], _ b: [Int], limit: Int = 1000) -> [(Int, Int)]? {
        let n = a.count, m = b.count
        let maxD = min(n + m, limit)
        let offset = n + m + 1
        var v = [Int](repeating: 0, count: 2 * offset + 2)
        var trace: [[Int]] = []
        for d in 0...maxD {
            trace.append(Array(v[(offset - d - 1)...(offset + d + 1)]))
            for k in stride(from: -d, through: d, by: 2) {
                var x = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n, y < m, a[x] == b[y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n, y >= m { return backtrack(trace, d, n, m) }
            }
        }
        return nil
    }

    private static func backtrack(_ trace: [[Int]], _ final: Int, _ n: Int, _ m: Int) -> [(Int, Int)] {
        var pairs: [(Int, Int)] = []
        var x = n, y = m
        for d in stride(from: final, through: 0, by: -1) {
            let row = trace[d]
            func v(_ k: Int) -> Int { row[k + d + 1] }
            let k = x - y
            let previousK = (k == -d || (k != d && v(k - 1) < v(k + 1))) ? k + 1 : k - 1
            let previousX = d == 0 ? 0 : v(previousK)
            let previousY = d == 0 ? 0 : previousX - previousK
            while x > previousX, y > previousY { x -= 1; y -= 1; pairs.append((x, y)) }
            x = previousX
            y = previousY
        }
        return pairs.reversed()
    }

    private static func snap(_ offset: Int, in bytes: [UInt8]) -> Int {
        var o = max(0, min(offset, bytes.count))
        while o > 0, o < bytes.count, bytes[o] & 0xC0 == 0x80 { o -= 1 }
        return o
    }
}
