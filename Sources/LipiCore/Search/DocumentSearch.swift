import Foundation

/// What in-document Find (P0-10) looks for: a literal or an ICU regular
/// expression (`NSRegularExpression`), optionally case-sensitive and
/// limited to whole words.
public struct FindQuery: Sendable, Hashable {
    public var pattern: String
    public var caseSensitive: Bool
    public var wholeWord: Bool
    public var isRegex: Bool

    public init(_ pattern: String, caseSensitive: Bool = false, wholeWord: Bool = false, isRegex: Bool = false) {
        self.pattern = pattern
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.isRegex = isRegex
    }

    public var isEmpty: Bool { pattern.isEmpty }
}

/// Where Find searches: the Markdown source (default) or the rendered text,
/// with syntax hidden ("search source or rendered text").
public enum FindScope: String, Sendable, Hashable, CaseIterable {
    case source
    case rendered
}

public enum FindError: Error, Equatable, Sendable {
    case invalidPattern(String)
}

/// A flat UTF-8 copy of a rope, taken once per text generation so that
/// every keystroke in the find field searches without walking the tree.
public struct SearchText: Sendable {
    public let bytes: [UInt8]

    public init(_ rope: LipiRope) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(rope.count)
        rope.forEachChunk { chunk in
            var chunk = chunk
            chunk.withUTF8 { bytes.append(contentsOf: $0) }
        }
        self.bytes = bytes
    }

    public init(_ string: String) { bytes = Array(string.utf8) }

    public var count: Int { bytes.count }
}

/// In-document search over source bytes. Matches are byte ranges, sorted
/// and non-overlapping, always on scalar boundaries.
public enum DocumentSearch {
    /// Every match of `query` in `text`.
    public static func matches(of query: FindQuery, in text: SearchText) throws -> [Range<Int>] {
        guard !query.isEmpty, !text.bytes.isEmpty else { return [] }
        if !query.isRegex, query.caseSensitive || query.pattern.utf8.allSatisfy({ $0 < 0x80 }) {
            return literalMatches(of: query, in: text.bytes)
        }
        return try regexMatches(of: query, in: text.bytes).map(\.range)
    }

    public static func matches(of query: FindQuery, in rope: LipiRope) throws -> [Range<Int>] {
        try matches(of: query, in: SearchText(rope))
    }

    /// Validates a pattern without searching (the find bar's error state).
    public static func validate(_ query: FindQuery) throws {
        guard query.isRegex, !query.isEmpty else { return }
        _ = try regex(for: query)
    }

    // MARK: Literal

    /// memmem over the bytes, or over an ASCII-folded copy when the search
    /// ignores case (the pattern is ASCII here; other patterns go through
    /// ICU so that Unicode case folding applies). UTF-8 is
    /// self-synchronising, so a hit always starts and ends on a scalar.
    static func literalMatches(of query: FindQuery, in bytes: [UInt8]) -> [Range<Int>] {
        var needle = Array(query.pattern.utf8)
        var folded: [UInt8]? = nil
        if !query.caseSensitive {
            needle = needle.map(lowerASCII)
            var copy = bytes
            copy.withUnsafeMutableBufferPointer { buf in
                for i in buf.indices {
                    let b = buf[i]
                    if b &- 0x41 < 26 { buf[i] = b | 0x20 }
                }
            }
            folded = copy
        }
        let n = needle.count
        var out: [Range<Int>] = []
        func scan(_ hay: UnsafeBufferPointer<UInt8>) {
            needle.withUnsafeBufferPointer { nd in
                guard let base = hay.baseAddress, let np = nd.baseAddress else { return }
                var start = 0
                while start + n <= hay.count {
                    guard let hit = memmem(base + start, hay.count - start, np, n) else { break }
                    let at = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
                    let r = at..<(at + n)
                    if !query.wholeWord || isWholeWord(r, in: bytes) {
                        out.append(r)
                        start = at + n
                    } else {
                        start = at + 1
                    }
                }
            }
        }
        if let folded { folded.withUnsafeBufferPointer(scan) } else { bytes.withUnsafeBufferPointer(scan) }
        return out
    }

    @inline(__always) static func lowerASCII(_ b: UInt8) -> UInt8 { b &- 0x41 < 26 ? b | 0x20 : b }

    // MARK: Regex

    struct RegexMatch {
        var range: Range<Int>
        var result: NSTextCheckingResult
    }

    static func regex(for query: FindQuery) throws -> NSRegularExpression {
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if !query.caseSensitive { options.insert(.caseInsensitive) }
        let pattern = query.isRegex ? query.pattern : NSRegularExpression.escapedPattern(for: query.pattern)
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            throw FindError.invalidPattern(query.pattern)
        }
    }

    static func nsString(_ bytes: [UInt8]) -> NSString {
        bytes.withUnsafeBufferPointer { buf -> NSString? in
            guard let base = buf.baseAddress else { return "" }
            return NSString(bytes: base, length: buf.count, encoding: NSUTF8StringEncoding)
        } ?? ""
    }

    static func regexMatches(of query: FindQuery, in bytes: [UInt8]) throws -> [RegexMatch] {
        let regex = try regex(for: query)
        let string = nsString(bytes)
        var converter = UTF16ToByte(bytes: bytes)
        var out: [RegexMatch] = []
        regex.enumerateMatches(in: string as String, options: [], range: NSRange(location: 0, length: string.length)) { result, _, _ in
            guard let result, result.range.length > 0 else { return }
            let lo = converter.byte(forUTF16: result.range.location)
            let hi = converter.byte(forUTF16: result.range.location + result.range.length)
            let r = lo..<hi
            if query.wholeWord && !isWholeWord(r, in: bytes) { return }
            out.append(RegexMatch(range: r, result: result))
        }
        return out
    }

    // MARK: Replacement

    /// The edits Replace All makes: one per match, in document order, in
    /// the coordinates of the unedited text. A regex query expands `$1`
    /// style templates; a literal query inserts `template` as is.
    public static func replaceAllEdits(of query: FindQuery, in text: SearchText, template: String) throws -> [Edit] {
        guard !query.isEmpty else { return [] }
        guard query.isRegex else {
            return try matches(of: query, in: text).map { Edit(replacing: $0, with: template) }
        }
        let regex = try regex(for: query)
        let string = nsString(text.bytes) as String
        return try regexMatches(of: query, in: text.bytes).map {
            Edit(replacing: $0.range, with: regex.replacementString(for: $0.result, in: string, offset: 0, template: template))
        }
    }

    /// The text replacing one match `range` of `query` in `rope`: the
    /// expanded template for a regex (evaluated on the match's lines, with
    /// transparent bounds so look-around sees its context), else `template`.
    /// Nil when the range is no longer a match.
    public static func replacement(for range: Range<Int>, of query: FindQuery, in rope: LipiRope, template: String) throws -> String? {
        guard query.isRegex else { return template }
        let regex = try regex(for: query)
        let lo = rope.lineRange(rope.line(at: range.lowerBound)).lowerBound
        let hi = max(rope.lineRange(rope.line(at: range.upperBound)).upperBound, range.upperBound)
        let window = rope.string(in: lo..<hi)
        let windowRope = LipiRope(window)
        let u0 = windowRope.utf16Offset(fromByte: range.lowerBound - lo)
        let u1 = windowRope.utf16Offset(fromByte: range.upperBound - lo)
        let target = NSRange(location: u0, length: u1 - u0)
        guard let result = regex.firstMatch(in: window, options: [.withTransparentBounds, .withoutAnchoringBounds], range: target),
              result.range == target else { return nil }
        return regex.replacementString(for: result, in: window, offset: 0, template: template)
    }

    // MARK: Whole word

    /// True when the scalars on either side of `range` are not word
    /// characters (letters, marks, digits, underscore) where the match's
    /// own edge is one; a match edge that is punctuation needs no boundary.
    static func isWholeWord(_ range: Range<Int>, in bytes: [UInt8]) -> Bool {
        guard !range.isEmpty else { return false }
        if let first = scalar(startingAt: range.lowerBound, in: bytes), isWordScalar(first),
           let before = scalar(endingAt: range.lowerBound, in: bytes), isWordScalar(before) { return false }
        if let last = scalar(endingAt: range.upperBound, in: bytes), isWordScalar(last),
           let after = scalar(startingAt: range.upperBound, in: bytes), isWordScalar(after) { return false }
        return true
    }

    static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
        if s.value < 0x80 {
            let v = s.value
            return (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) || v == 0x5F
        }
        let p = s.properties
        switch p.generalCategory {
        case .decimalNumber, .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return p.isAlphabetic
        }
    }

    static func scalar(startingAt i: Int, in bytes: [UInt8]) -> Unicode.Scalar? {
        guard i >= 0, i < bytes.count else { return nil }
        let b0 = bytes[i]
        let len = b0 < 0x80 ? 1 : b0 < 0xE0 ? 2 : b0 < 0xF0 ? 3 : 4
        guard i + len <= bytes.count else { return nil }
        var decoder = UTF8()
        var it = bytes[i..<(i + len)].makeIterator()
        if case .scalarValue(let s) = decoder.decode(&it) { return s }
        return nil
    }

    static func scalar(endingAt i: Int, in bytes: [UInt8]) -> Unicode.Scalar? {
        guard i > 0, i <= bytes.count else { return nil }
        var s = i - 1
        while s > 0, s > i - 4, bytes[s] & 0xC0 == 0x80 { s -= 1 }
        return scalar(startingAt: s, in: bytes)
    }
}

/// Converts increasing UTF-16 offsets to UTF-8 byte offsets in one pass.
struct UTF16ToByte {
    let bytes: [UInt8]
    var byte = 0
    var utf16 = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func byte(forUTF16 target: Int) -> Int {
        if target < utf16 { byte = 0; utf16 = 0 }
        var b = byte, u = utf16
        bytes.withUnsafeBufferPointer { buf in
            while u < target, b < buf.count {
                let c = buf[b]
                if c < 0x80 { b += 1; u += 1 }
                else if c < 0xE0 { b += 2; u += 1 }
                else if c < 0xF0 { b += 3; u += 1 }
                else { b += 4; u += 2 }
            }
        }
        byte = b; utf16 = u
        return min(b, bytes.count)
    }
}

// MARK: - Rendered-text search

extension DocumentSearch {
    /// Matches of `query` in the rendered text of `projection` (each display
    /// cell searched on its own, syntax hidden), mapped back to source byte
    /// ranges. A match whose ends map to the same source offset (inside
    /// hidden syntax) is dropped.
    public static func renderedMatches(of query: FindQuery, in projection: Projection) throws -> [Range<Int>] {
        guard !query.isEmpty else { return [] }
        try validate(query)
        var out: [Range<Int>] = []
        for entry in projection.entries {
            for block in entry.blocks {
                for cell in block.cells where !cell.text.isEmpty {
                    let text = SearchText(cell.text)
                    let hits = try matches(of: query, in: text)
                    guard !hits.isEmpty else { continue }
                    var converter = ByteToUTF16(bytes: text.bytes)
                    for hit in hits {
                        // The end maps from the last scalar's start (so hidden
                        // syntax after the match is not taken in) plus its length.
                        let last = lastScalarStart(before: hit.upperBound, in: text.bytes)
                        let u0 = converter.utf16(forByte: hit.lowerBound)
                        let uLast = converter.utf16(forByte: last)
                        let s0 = entry.start + cell.sourceOffset(forDisplay: u0)
                        let s1 = entry.start + cell.sourceOffset(forDisplay: uLast) + (hit.upperBound - last)
                        if s1 > s0 { out.append(s0..<s1) }
                    }
                }
            }
        }
        out.sort { $0.lowerBound < $1.lowerBound }
        return out
    }

    static func lastScalarStart(before end: Int, in bytes: [UInt8]) -> Int {
        var i = end - 1
        while i > 0, bytes[i] & 0xC0 == 0x80 { i -= 1 }
        return max(i, 0)
    }
}

/// Converts increasing UTF-8 byte offsets to UTF-16 offsets in one pass.
struct ByteToUTF16 {
    let bytes: [UInt8]
    var byte = 0
    var utf16 = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func utf16(forByte target: Int) -> Int {
        if target < byte { byte = 0; utf16 = 0 }
        while byte < target, byte < bytes.count {
            let c = bytes[byte]
            if c < 0x80 { byte += 1; utf16 += 1 }
            else if c < 0xE0 { byte += 2; utf16 += 1 }
            else if c < 0xF0 { byte += 3; utf16 += 1 }
            else { byte += 4; utf16 += 2 }
        }
        return utf16
    }
}
