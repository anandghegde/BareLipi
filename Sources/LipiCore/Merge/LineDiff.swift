/// Line splitting and a longest-common-subsequence diff for the three-way
/// merge (P1-04). Lines are byte ranges that keep their own terminator (LF,
/// CRLF or a lone CR), so comparing and re-assembling them never changes a
/// byte; only the last line may have no terminator.
public enum LineDiff {
    /// The lines of `bytes`, each including its terminator. Empty input has
    /// no lines; "a\n" has one; "a\nb" has two.
    public static func lines(_ bytes: [UInt8]) -> [Range<Int>] {
        var lines: [Range<Int>] = []
        var start = 0
        var i = 0
        let n = bytes.count
        while i < n {
            let byte = bytes[i]
            if byte == 0x0A {
                lines.append(start..<(i + 1))
                start = i + 1
            } else if byte == 0x0D {
                if i + 1 < n, bytes[i + 1] == 0x0A { i += 1 }
                lines.append(start..<(i + 1))
                start = i + 1
            }
            i += 1
        }
        if start < n { lines.append(start..<n) }
        return lines
    }

    /// Whether `bytes` ends with a line terminator.
    public static func endsWithTerminator(_ bytes: some BidirectionalCollection<UInt8>) -> Bool {
        guard let last = bytes.last else { return false }
        return last == 0x0A || last == 0x0D
    }

    /// Index pairs `(i, j)` with `a[i] == b[j]`, increasing in both, forming
    /// a longest common subsequence of `a` and `b`. Myers' O((N+M)D) algorithm
    /// in linear space (the middle-snake bisection), after trimming the
    /// common prefix and suffix at each level.
    public static func matches<T: Equatable>(_ a: [T], _ b: [T]) -> [(Int, Int)] {
        var myers = Myers(a: a, b: b)
        myers.run(0, a.count, 0, b.count)
        return myers.out
    }
}

private struct Myers<T: Equatable> {
    let a: [T]
    let b: [T]
    var out: [(Int, Int)] = []

    mutating func run(_ aLo: Int, _ aHi: Int, _ bLo: Int, _ bHi: Int) {
        var aLo = aLo, bLo = bLo, aHi = aHi, bHi = bHi
        while aLo < aHi, bLo < bHi, a[aLo] == b[bLo] {
            out.append((aLo, bLo))
            aLo += 1
            bLo += 1
        }
        var suffix = 0
        while aHi > aLo, bHi > bLo, a[aHi - 1] == b[bHi - 1] {
            aHi -= 1
            bHi -= 1
            suffix += 1
        }
        if aLo < aHi, bLo < bHi, let (x, y) = bisect(aLo, aHi, bLo, bHi),
           (x, y) != (aLo, bLo), (x, y) != (aHi, bHi) {
            run(aLo, x, bLo, y)
            run(x, aHi, y, bHi)
        }
        for i in 0..<suffix { out.append((aHi + i, bHi + i)) }
    }

    /// The split point (absolute) of an optimal path through the middle
    /// snake, or nil when the ranges have nothing in common.
    func bisect(_ aLo: Int, _ aHi: Int, _ bLo: Int, _ bHi: Int) -> (Int, Int)? {
        let n = aHi - aLo, m = bHi - bLo
        let maxD = (n + m + 1) / 2
        let vOff = maxD, vLen = 2 * maxD + 2
        var v1 = [Int](repeating: -1, count: vLen)
        var v2 = [Int](repeating: -1, count: vLen)
        v1[vOff + 1] = 0
        v2[vOff + 1] = 0
        let delta = n - m
        let front = delta & 1 != 0
        var k1start = 0, k1end = 0, k2start = 0, k2end = 0
        for d in 0..<maxD {
            var k1 = -d + k1start
            while k1 <= d - k1end {
                let k1o = vOff + k1
                var x1 = (k1 == -d || (k1 != d && v1[k1o - 1] < v1[k1o + 1])) ? v1[k1o + 1] : v1[k1o - 1] + 1
                var y1 = x1 - k1
                while x1 < n, y1 < m, a[aLo + x1] == b[bLo + y1] {
                    x1 += 1
                    y1 += 1
                }
                v1[k1o] = x1
                if x1 > n {
                    k1end += 2
                } else if y1 > m {
                    k1start += 2
                } else if front {
                    let k2o = vOff + delta - k1
                    if k2o >= 0, k2o < vLen, v2[k2o] != -1, x1 >= n - v2[k2o] {
                        return (aLo + x1, bLo + y1)
                    }
                }
                k1 += 2
            }
            var k2 = -d + k2start
            while k2 <= d - k2end {
                let k2o = vOff + k2
                var x2 = (k2 == -d || (k2 != d && v2[k2o - 1] < v2[k2o + 1])) ? v2[k2o + 1] : v2[k2o - 1] + 1
                var y2 = x2 - k2
                while x2 < n, y2 < m, a[aHi - 1 - x2] == b[bHi - 1 - y2] {
                    x2 += 1
                    y2 += 1
                }
                v2[k2o] = x2
                if x2 > n {
                    k2end += 2
                } else if y2 > m {
                    k2start += 2
                } else if !front {
                    let k1o = vOff + delta - k2
                    if k1o >= 0, k1o < vLen, v1[k1o] != -1 {
                        let x1 = v1[k1o]
                        let y1 = vOff + x1 - k1o
                        if x1 >= n - x2 { return (aLo + x1, bLo + y1) }
                    }
                }
                k2 += 2
            }
        }
        return nil
    }
}
