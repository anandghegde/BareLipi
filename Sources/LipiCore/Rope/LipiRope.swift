/// Persistent UTF-8 rope with byte, UTF-16, scalar and line summaries.
///
/// Value semantics with structural sharing: copying a `LipiRope` is O(1) and
/// every mutation path-copies O(log n) nodes. All offsets in this API are
/// UTF-8 byte offsets unless the name says otherwise, and mutating offsets
/// must fall on scalar boundaries.
public struct LipiRope: Sendable {
    var root: RopeNode

    public init() { root = .empty }

    public init(_ text: String) { root = RopeNode.build(from: text[...]) }

    public init(_ text: Substring) { root = RopeNode.build(from: text) }

    init(root: RopeNode) { self.root = root }

    // MARK: - Measures

    public var summary: TextSummary { root.summary }
    /// UTF-8 length.
    public var count: Int { root.summary.bytes }
    public var utf16Count: Int { root.summary.utf16 }
    public var scalarCount: Int { root.summary.scalars }
    /// Number of lines, counting a trailing partial line: "a\nb" has 2, "a\n" has 2, "" has 1.
    public var lineCount: Int { root.summary.lines + 1 }
    public var isEmpty: Bool { count == 0 }
    public var endOffset: SourceOffset { SourceOffset(count) }

    // MARK: - Reading

    public var string: String {
        var s = ""
        s.reserveCapacity(count)
        root.forEachLeaf { s.append(contentsOf: $0) }
        return s
    }

    public func string(in range: Range<Int>) -> String {
        precondition(range.lowerBound >= 0 && range.upperBound <= count, "range out of bounds")
        var s = ""
        s.reserveCapacity(range.count)
        root.forEachLeaf(in: range) { s.append(contentsOf: $0) }
        return s
    }

    public func string(in range: Range<SourceOffset>) -> String { string(in: range.byteRange) }

    public func subrope(_ range: Range<Int>) -> LipiRope {
        precondition(range.lowerBound >= 0 && range.upperBound <= count, "range out of bounds")
        precondition(isScalarBoundary(at: range.lowerBound) && isScalarBoundary(at: range.upperBound))
        return LipiRope(root: root.slice(range))
    }

    /// Visits the rope's storage chunks in order. Chunks are at most 1,024 bytes
    /// and never split a scalar.
    public func forEachChunk(in range: Range<Int>? = nil, _ body: (Substring) throws -> Void) rethrows {
        try root.forEachLeaf(in: range, body)
    }

    public func byte(at offset: Int) -> UInt8 {
        precondition(offset >= 0 && offset < count, "offset out of bounds")
        var node = root
        var off = offset
        while case .internalNode(let kids) = node.body {
            for k in kids {
                if off < k.summary.bytes { node = k; break }
                off -= k.summary.bytes
            }
        }
        let u = node.leafText.utf8
        return u[u.index(u.startIndex, offsetBy: off)]
    }

    public func isScalarBoundary(at offset: Int) -> Bool {
        if offset <= 0 || offset >= count { return offset == 0 || offset == count }
        return (byte(at: offset) & 0xC0) != 0x80
    }

    /// Nearest scalar boundary at or before `offset`.
    public func floorScalarBoundary(_ offset: Int) -> Int {
        var o = Swift.min(Swift.max(offset, 0), count)
        while !isScalarBoundary(at: o) { o -= 1 }
        return o
    }

    // MARK: - Mutation

    /// Replaces `range` with `text`. Both bounds must be scalar boundaries.
    public mutating func replace(_ range: Range<Int>, with text: String) {
        precondition(range.lowerBound >= 0 && range.upperBound <= count, "range out of bounds")
        // Scalar-boundary checks happen at the leaf being cut, so they cost
        // no extra descent. Single-leaf edits take the path-copying fast path.
        if let result = RopeNode.fastReplace(root, range, with: text, isRoot: true) {
            switch result {
            case .one(let node): root = node
            case .two(let a, let b): root = RopeNode(children: [a, b])
            }
            return
        }
        let left = root.slice(0..<range.lowerBound)
        let right = root.slice(range.upperBound..<count)
        let middle = RopeNode.build(from: text[...])
        root = RopeNode.concat(RopeNode.concat(left, middle), right)
    }

    public mutating func insert(_ text: String, at offset: Int) {
        replace(offset..<offset, with: text)
    }

    public mutating func remove(_ range: Range<Int>) {
        replace(range, with: "")
    }

    public mutating func apply(_ edit: Edit) {
        replace(edit.range.byteRange, with: edit.replacement)
    }

    public mutating func append(_ text: String) {
        root = RopeNode.concat(root, RopeNode.build(from: text[...]))
    }

    public static func + (lhs: LipiRope, rhs: LipiRope) -> LipiRope {
        LipiRope(root: RopeNode.concat(lhs.root, rhs.root))
    }

    // MARK: - Offset conversion

    /// Measures the position where the `from` dimension first reaches `n`, in
    /// dimension `to`. For `.lines` as `from`, `n` is a line index and the
    /// position is the start of that line. A UTF-16 offset inside a surrogate
    /// pair rounds down to the scalar's start. A byte offset inside a scalar
    /// is a programming error.
    public func convert(_ n: Int, from: TextDimension, to: TextDimension) -> Int {
        precondition(n >= 0 && n <= from.measure(summary), "offset out of bounds")
        if from == to { return n }
        var node = root
        var remaining = n
        var acc = TextSummary.zero
        descend: while case .internalNode(let kids) = node.body {
            for k in kids {
                let m = from.measure(k.summary)
                if remaining <= m {
                    // For byte-like dimensions a position exactly at a child's end
                    // equals the next child's start, so descending is harmless.
                    node = k
                    continue descend
                }
                remaining -= m
                acc += k.summary
            }
            preconditionFailure("unreachable: offset within summary but not within children")
        }
        // Leaf scan over UTF-8 lead bytes: stop at the first scalar boundary
        // where the `from` measure equals `remaining`, or just before the
        // scalar that would overshoot it.
        var local = TextSummary.zero
        if remaining > 0 {
            @inline(__always) func scan(_ buf: UnsafeBufferPointer<UInt8>) {
                var i = 0
                let n = buf.count
                while i < n {
                    let b = buf[i]
                    let len = b < 0x80 ? 1 : b < 0xE0 ? 2 : b < 0xF0 ? 3 : 4
                    let step = TextSummary(bytes: len, utf16: len == 4 ? 2 : 1, scalars: 1, lines: b == 0x0A ? 1 : 0)
                    let cur = from.measure(local)
                    if cur == remaining { return }
                    if cur + from.measure(step) > remaining {
                        precondition(from != .bytes, "byte offset splits a scalar")
                        return
                    }
                    local += step
                    i += len
                }
            }
            let text = node.leafText
            if text.utf8.withContiguousStorageIfAvailable(scan) == nil {
                Array(text.utf8).withUnsafeBufferPointer(scan)
            }
        }
        return to.measure(acc + local)
    }

    public func utf16Offset(fromByte b: Int) -> Int { convert(b, from: .bytes, to: .utf16) }
    public func byteOffset(fromUTF16 u: Int) -> Int { convert(u, from: .utf16, to: .bytes) }
    public func scalarOffset(fromByte b: Int) -> Int { convert(b, from: .bytes, to: .scalars) }
    public func byteOffset(fromScalar s: Int) -> Int { convert(s, from: .scalars, to: .bytes) }

    /// Zero-based line index containing byte `offset`.
    public func line(at offset: Int) -> Int { convert(offset, from: .bytes, to: .lines) }

    /// Byte offset at which line `line` starts; `count` for the line after the last newline.
    public func lineStart(_ line: Int) -> Int {
        precondition(line >= 0 && line < lineCount, "line out of range")
        return convert(line, from: .lines, to: .bytes)
    }

    /// Byte range of `line`, including its trailing "\n" if it has one.
    public func lineRange(_ line: Int) -> Range<Int> {
        let start = lineStart(line)
        let end = line + 1 < lineCount ? lineStart(line + 1) : count
        return start..<end
    }

    /// Line and byte column of `offset`.
    public func lineColumn(at offset: Int) -> (line: Int, column: Int) {
        let l = line(at: offset)
        return (l, offset - lineStart(l))
    }

    /// Range of byte offsets covered by a UTF-16 range, as AppKit reports selections.
    public func byteRange(fromUTF16 range: Range<Int>) -> Range<Int> {
        byteOffset(fromUTF16: range.lowerBound)..<byteOffset(fromUTF16: range.upperBound)
    }

    public func utf16Range(fromBytes range: Range<Int>) -> Range<Int> {
        utf16Offset(fromByte: range.lowerBound)..<utf16Offset(fromByte: range.upperBound)
    }

    // MARK: - Diagnostics

    /// Structural invariant violations, empty when the tree is well formed.
    public func validateStructure() -> [String] { root.validate() }

    public var height: Int { root.height }
}

extension LipiRope: Equatable {
    public static func == (lhs: LipiRope, rhs: LipiRope) -> Bool {
        if lhs.root === rhs.root { return true }
        if lhs.summary != rhs.summary { return false }
        return lhs.string == rhs.string
    }
}

extension LipiRope: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { string }
    public var debugDescription: String {
        "LipiRope(bytes: \(count), utf16: \(utf16Count), scalars: \(scalarCount), lines: \(lineCount), height: \(height))"
    }
}

extension LipiRope: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self.init(value) }
}
