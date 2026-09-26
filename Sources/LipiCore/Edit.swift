/// The one and only way the source buffer changes: replace `range` with
/// `replacement`. Every command, IME commit, paste, drop, undo step and merge
/// result is expressed as one or more of these.
public struct Edit: Sendable, Equatable, Hashable {
    public var range: Range<SourceOffset>
    public var replacement: String

    public init(range: Range<SourceOffset>, replacement: String) {
        self.range = range
        self.replacement = replacement
    }

    public init(replacing bytes: Range<Int>, with replacement: String) {
        self.init(range: Range(bytes: bytes), replacement: replacement)
    }

    public static func insert(_ text: String, at offset: SourceOffset) -> Edit {
        Edit(range: offset..<offset, replacement: text)
    }

    public static func delete(_ range: Range<SourceOffset>) -> Edit {
        Edit(range: range, replacement: "")
    }

    /// Number of bytes inserted (replacement) and removed (range).
    public var insertedBytes: Int { replacement.utf8.count }
    public var removedBytes: Int { range.length }
    public var isNoOp: Bool { range.isEmpty && replacement.isEmpty }
}

/// What an applied edit did, in terms both the projection and any background
/// consumer can use to remap offsets they hold from an earlier generation.
public struct Delta: Sendable, Equatable, Hashable {
    /// Range in the *old* buffer that was replaced.
    public var oldRange: Range<SourceOffset>
    /// Range in the *new* buffer now occupied by the replacement.
    public var newRange: Range<SourceOffset>
    /// Buffer generation after the edit.
    public var generation: UInt64

    public init(oldRange: Range<SourceOffset>, newRange: Range<SourceOffset>, generation: UInt64) {
        self.oldRange = oldRange
        self.newRange = newRange
        self.generation = generation
    }

    /// Maps an offset from before the edit to after it. Offsets inside the
    /// replaced range collapse to the end of the replacement when `preferEnd`
    /// is true, otherwise to its start.
    public func map(_ offset: SourceOffset, preferEnd: Bool = true) -> SourceOffset {
        if offset < oldRange.lowerBound { return offset }
        if offset >= oldRange.upperBound {
            return offset + (newRange.length - oldRange.length)
        }
        return preferEnd ? newRange.upperBound : newRange.lowerBound
    }
}
