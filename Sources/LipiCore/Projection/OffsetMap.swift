/// Maps between a display cell's source bytes and its display text (PRD §6.1.1).
///
/// A cell's display text is built from segments that tile the cell's source
/// range in order. Each segment either copies its source bytes verbatim,
/// hides them (zero display width) or replaces them with a short stand-in
/// (a soft break becomes a space, an entity its character, a link
/// destination a chip). Offsets on the display side are UTF-16 units, the
/// coordinate system of `NSAttributedString`, Core Text and TextKit.
///
/// Invariants (checked by `ProjectionTests`):
/// - segments are sorted, contiguous and tile `sourceRange`;
/// - display offsets are monotone and sum to `displayLength`;
/// - every source offset maps to exactly one display offset;
/// - `sourceToDisplay(displayToSource(δ)) == δ` for every display offset δ
///   that is a caret position (not inside a surrogate pair or a multi-unit
///   replacement such as an entity that decodes to several scalars).
public struct MapSegment: Sendable, Hashable {
    public enum Kind: UInt8, Sendable {
        /// Display bytes are identical to the source bytes.
        case copied
        /// Nothing is displayed for the source bytes.
        case hidden
        /// The source bytes are displayed as a short stand-in string.
        case replaced
    }

    /// Which source offset a display caret at a hidden segment's boundary
    /// stands for. A run of hidden segments at one display offset resolves to
    /// the end of its last `.after` segment, or to the start of the run when
    /// none is `.after`.
    public enum Resolve: UInt8, Sendable {
        /// Block terminators, stripped whitespace, escape backslashes: the
        /// caret stays before the hidden bytes.
        case before
        /// Markers and delimiters: the caret moves past the hidden bytes.
        case after
    }

    public var sourceStart: Int32
    public var sourceLength: Int32
    /// UTF-16 offset in the cell's display text.
    public var displayStart: Int32
    public var displayLength: Int32
    /// UTF-8 offset in the cell's display text (for copied segments).
    public var displayStartUTF8: Int32
    public var kind: Kind
    public var resolve: Resolve
    /// Copied bytes are all ASCII, so byte and UTF-16 offsets coincide.
    public var isASCII: Bool

    public var sourceEnd: Int32 { sourceStart + sourceLength }
    public var displayEnd: Int32 { displayStart + displayLength }
    public var sourceRange: Range<Int> { Int(sourceStart)..<Int(sourceEnd) }
    public var displayRange: Range<Int> { Int(displayStart)..<Int(displayEnd) }
}

public struct OffsetMap: Sendable, Hashable {
    public private(set) var segments: [MapSegment]
    /// Source bytes this map covers (local to the enclosing entry).
    public let sourceRange: Range<Int>
    /// UTF-16 length of the display text.
    public let displayLength: Int
    /// UTF-8 length of the display text.
    public let displayLengthUTF8: Int

    public init(segments: [MapSegment], sourceRange: Range<Int>, displayLength: Int, displayLengthUTF8: Int) {
        self.segments = segments
        self.sourceRange = sourceRange
        self.displayLength = displayLength
        self.displayLengthUTF8 = displayLengthUTF8
    }

    /// The identity map over `text`, for source mode and tests.
    public init(identityOver text: String, sourceStart: Int) {
        let utf8 = text.utf8.count
        let utf16 = text.utf16.count
        let segment = MapSegment(sourceStart: Int32(sourceStart), sourceLength: Int32(utf8), displayStart: 0,
                                 displayLength: Int32(utf16), displayStartUTF8: 0, kind: .copied, resolve: .before,
                                 isASCII: utf8 == utf16)
        self.init(segments: utf8 == 0 ? [] : [segment], sourceRange: sourceStart..<(sourceStart + utf8),
                  displayLength: utf16, displayLengthUTF8: utf8)
    }

    // MARK: Lookup

    /// Index of the segment whose source range contains `offset`, or nil when
    /// `offset` is outside `sourceRange` or the map is empty.
    public func segmentIndex(containingSource offset: Int) -> Int? {
        guard !segments.isEmpty, offset >= sourceRange.lowerBound, offset < sourceRange.upperBound else { return nil }
        var lo = 0, hi = segments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if Int(segments[mid].sourceStart) <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Display offset (UTF-16) for source `offset`. `utf8` is the cell's
    /// display text. Offsets inside hidden or replaced bytes map to the
    /// segment's display start; offsets inside a multi-byte scalar map to the
    /// scalar's start.
    public func sourceToDisplay(_ offset: Int, utf8: UnsafeBufferPointer<UInt8>) -> Int {
        guard let i = segmentIndex(containingSource: offset) else {
            return offset < sourceRange.lowerBound ? 0 : displayLength
        }
        let seg = segments[i]
        let local = offset - Int(seg.sourceStart)
        switch seg.kind {
        case .hidden, .replaced:
            return Int(seg.displayStart)
        case .copied:
            if seg.isASCII { return Int(seg.displayStart) + local }
            return Int(seg.displayStart) + utf16Units(in: utf8, from: Int(seg.displayStartUTF8), bytes: local)
        }
    }

    /// Source offset for display `offset` (UTF-16). Boundaries next to hidden
    /// segments resolve per `MapSegment.Resolve`; an offset inside a
    /// surrogate pair maps to the scalar's start.
    public func displayToSource(_ offset: Int, utf8: UnsafeBufferPointer<UInt8>) -> Int {
        let δ = Int32(max(0, min(offset, displayLength)))
        // First segment whose display end is past δ.
        var lo = 0, hi = segments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if segments[mid].displayEnd > δ { hi = mid } else { lo = mid + 1 }
        }
        let i = lo
        if i < segments.count, segments[i].displayStart < δ {
            let seg = segments[i]
            switch seg.kind {
            case .replaced, .hidden:
                return Int(seg.sourceStart)
            case .copied:
                let local = Int(δ - seg.displayStart)
                if seg.isASCII { return Int(seg.sourceStart) + local }
                return Int(seg.sourceStart) + byteOffset(in: utf8, from: Int(seg.displayStartUTF8), utf16Units: local)
            }
        }
        // δ is a boundary. Collect the run of hidden segments sitting at it.
        var j = i
        while j > 0, segments[j - 1].displayLength == 0, segments[j - 1].displayStart == δ { j -= 1 }
        var result = j < segments.count ? Int(segments[j].sourceStart) : sourceRange.upperBound
        for k in j..<i where segments[k].resolve == .after { result = Int(segments[k].sourceEnd) }
        return result
    }

    /// True when a display caret can stand for `offset`: the offset is a
    /// segment boundary or inside a copied segment.
    public func isOccupiable(_ offset: Int) -> Bool {
        guard let i = segmentIndex(containingSource: offset) else { return offset == sourceRange.upperBound }
        let seg = segments[i]
        return seg.kind == .copied || Int(seg.sourceStart) == offset
    }

    // MARK: UTF-8 ↔ UTF-16 within copied bytes

    /// UTF-16 units in the scalars that fit in `bytes` bytes of `utf8` from `start`.
    @inline(__always)
    func utf16Units(in utf8: UnsafeBufferPointer<UInt8>, from start: Int, bytes: Int) -> Int {
        var units = 0
        var p = start
        let end = min(start + bytes, utf8.count)
        while p < end {
            let b = utf8[p]
            let len = b < 0x80 ? 1 : b < 0xE0 ? 2 : b < 0xF0 ? 3 : 4
            if p + len > end { break }
            units += len == 4 ? 2 : 1
            p += len
        }
        return units
    }

    /// Bytes in the scalars that fit in `utf16Units` units of `utf8` from `start`.
    @inline(__always)
    func byteOffset(in utf8: UnsafeBufferPointer<UInt8>, from start: Int, utf16Units: Int) -> Int {
        var units = 0
        var p = start
        while p < utf8.count, units < utf16Units {
            let b = utf8[p]
            let len = b < 0x80 ? 1 : b < 0xE0 ? 2 : b < 0xF0 ? 3 : 4
            let u = len == 4 ? 2 : 1
            if units + u > utf16Units { break }
            units += u
            p += len
        }
        return p - start
    }
}
