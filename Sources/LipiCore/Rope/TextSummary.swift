/// Monoid summary of a span of UTF-8 text, kept on every rope node so that
/// byte, UTF-16, scalar and line offsets can all be resolved in O(log n).
public struct TextSummary: Sendable, Equatable, Hashable {
    /// UTF-8 code units.
    public var bytes: Int
    /// UTF-16 code units (what AppKit and NSTextInputClient speak).
    public var utf16: Int
    /// Unicode scalar values.
    public var scalars: Int
    /// Number of "\n" characters. A span with `lines == k` spans `k + 1` lines.
    public var lines: Int

    public static let zero = TextSummary(bytes: 0, utf16: 0, scalars: 0, lines: 0)

    public init(bytes: Int, utf16: Int, scalars: Int, lines: Int) {
        self.bytes = bytes
        self.utf16 = utf16
        self.scalars = scalars
        self.lines = lines
    }

    /// Measures a string. O(n) in bytes; only ever called on chunk-sized text.
    /// Counts from UTF-8 lead bytes alone, which is valid because a Swift
    /// String is always well-formed UTF-8.
    @inlinable
    public init(measuring text: Substring) {
        var bytes = 0, utf16 = 0, scalars = 0, lines = 0
        @inline(__always) func scan(_ buf: UnsafeBufferPointer<UInt8>) {
            bytes = buf.count
            for b in buf {
                if b & 0xC0 != 0x80 {
                    scalars &+= 1
                    utf16 &+= b >= 0xF0 ? 2 : 1
                    if b == 0x0A { lines &+= 1 }
                }
            }
        }
        if text.utf8.withContiguousStorageIfAvailable(scan) == nil {
            Array(text.utf8).withUnsafeBufferPointer(scan)
        }
        self.init(bytes: bytes, utf16: utf16, scalars: scalars, lines: lines)
    }

    @inlinable
    public init(measuring text: String) {
        self.init(measuring: text[...])
    }

    @inlinable
    public static func + (lhs: TextSummary, rhs: TextSummary) -> TextSummary {
        TextSummary(
            bytes: lhs.bytes + rhs.bytes,
            utf16: lhs.utf16 + rhs.utf16,
            scalars: lhs.scalars + rhs.scalars,
            lines: lhs.lines + rhs.lines)
    }

    @inlinable
    public static func += (lhs: inout TextSummary, rhs: TextSummary) {
        lhs.bytes += rhs.bytes
        lhs.utf16 += rhs.utf16
        lhs.scalars += rhs.scalars
        lhs.lines += rhs.lines
    }
}

/// The dimension a rope offset is measured in. Used by the generic descent in
/// `LipiRope` so one traversal serves every conversion.
public enum TextDimension: Sendable {
    case bytes, utf16, scalars, lines

    @inlinable
    func measure(_ s: TextSummary) -> Int {
        switch self {
        case .bytes: s.bytes
        case .utf16: s.utf16
        case .scalars: s.scalars
        case .lines: s.lines
        }
    }
}
