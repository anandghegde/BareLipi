/// Monoid summary of a span of UTF-8 text, kept on every rope node so that
/// byte, UTF-16, scalar and line offsets can all be resolved in O(log n).
///
/// Line breaks are the ones cmark-gfm reads: `\n`, `\r\n` and a lone `\r`.
/// A break is counted at its first byte, so a `\r\n` is one break counted at
/// the `\r`. A span that starts with the `\n` of a pair whose `\r` ends the
/// span before it counts that `\n` on its own; `+` takes the double count
/// back off, which keeps the summary a monoid when a pair straddles two
/// leaves.
public struct TextSummary: Sendable, Equatable, Hashable {
    /// UTF-8 code units.
    public var bytes: Int
    /// UTF-16 code units (what AppKit and NSTextInputClient speak).
    public var utf16: Int
    /// Unicode scalar values.
    public var scalars: Int
    /// Line breaks (`\n`, `\r\n`, lone `\r`). A span with `lines == k` spans `k + 1` lines.
    public var lines: Int
    /// The span starts with `\n` (counted as a break of its own).
    public var startsWithLF: Bool
    /// The span ends with `\r`.
    public var endsWithCR: Bool

    public static let zero = TextSummary(bytes: 0, utf16: 0, scalars: 0, lines: 0)

    public init(bytes: Int, utf16: Int, scalars: Int, lines: Int, startsWithLF: Bool = false, endsWithCR: Bool = false) {
        self.bytes = bytes
        self.utf16 = utf16
        self.scalars = scalars
        self.lines = lines
        self.startsWithLF = startsWithLF
        self.endsWithCR = endsWithCR
    }

    /// Measures a string. O(n) in bytes; only ever called on chunk-sized text.
    /// Counts from UTF-8 lead bytes alone, which is valid because a Swift
    /// String is always well-formed UTF-8.
    @inlinable
    public init(measuring text: Substring) {
        var bytes = 0, utf16 = 0, scalars = 0, lines = 0
        var first: UInt8 = 0, last: UInt8 = 0
        @inline(__always) func scan(_ buf: UnsafeBufferPointer<UInt8>) {
            bytes = buf.count
            guard let f = buf.first, let l = buf.last else { return }
            first = f
            last = l
            var previous: UInt8 = 0
            for b in buf {
                if b & 0xC0 != 0x80 {
                    scalars &+= 1
                    utf16 &+= b >= 0xF0 ? 2 : 1
                    // CR always breaks; LF breaks unless it ends a CRLF.
                    if b == 0x0D || (b == 0x0A && previous != 0x0D) { lines &+= 1 }
                    previous = b
                }
            }
        }
        if text.utf8.withContiguousStorageIfAvailable(scan) == nil {
            Array(text.utf8).withUnsafeBufferPointer(scan)
        }
        self.init(bytes: bytes, utf16: utf16, scalars: scalars, lines: lines,
                  startsWithLF: first == 0x0A, endsWithCR: last == 0x0D)
    }

    @inlinable
    public init(measuring text: String) {
        self.init(measuring: text[...])
    }

    @inlinable
    public static func + (lhs: TextSummary, rhs: TextSummary) -> TextSummary {
        var s = lhs
        s += rhs
        return s
    }

    @inlinable
    public static func += (lhs: inout TextSummary, rhs: TextSummary) {
        // A `\r` ending the left span and a `\n` starting the right one are
        // one break, which both sides counted.
        if lhs.endsWithCR && rhs.startsWithLF { lhs.lines -= 1 }
        if lhs.bytes == 0 { lhs.startsWithLF = rhs.startsWithLF }
        if rhs.bytes != 0 { lhs.endsWithCR = rhs.endsWithCR }
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
