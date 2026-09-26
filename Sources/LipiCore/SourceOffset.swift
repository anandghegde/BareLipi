/// A position in the source buffer, measured in UTF-8 bytes from the start of
/// the document. This is the caret's coordinate system and the only offset
/// type the editing model stores. Display and UTF-16 offsets are derived.
public struct SourceOffset: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public var byte: Int

    @inlinable public init(_ byte: Int) { self.byte = byte }
    @inlinable public static func < (a: SourceOffset, b: SourceOffset) -> Bool { a.byte < b.byte }
    @inlinable public static func + (a: SourceOffset, n: Int) -> SourceOffset { SourceOffset(a.byte + n) }
    @inlinable public static func - (a: SourceOffset, n: Int) -> SourceOffset { SourceOffset(a.byte - n) }
    @inlinable public static func - (a: SourceOffset, b: SourceOffset) -> Int { a.byte - b.byte }
    public static let zero = SourceOffset(0)
    public var description: String { "@\(byte)" }
}

extension Range where Bound == SourceOffset {
    @inlinable public var byteRange: Range<Int> { lowerBound.byte..<upperBound.byte }
    @inlinable public var length: Int { upperBound.byte - lowerBound.byte }
    @inlinable public init(bytes: Range<Int>) {
        self = SourceOffset(bytes.lowerBound)..<SourceOffset(bytes.upperBound)
    }
}
