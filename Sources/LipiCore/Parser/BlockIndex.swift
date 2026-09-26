/// One top-level block and the bytes it owns.
public struct BlockEntry: Sendable {
    /// Bytes in the entry's span: from the block's first line up to the next
    /// entry's first line, so trailing blank lines belong to the block before
    /// them and the spans tile the document exactly.
    public var length: Int
    /// The block, with ranges relative to the span start.
    public var block: Block
    /// Link reference definitions written inside this span, in source order.
    public var referenceDefinitions: [ReferenceDefinition]
    /// The span contains `[`, so its inlines may depend on the reference map.
    var hasBracket: Bool
    /// Edited since the last parse; `block` is stale until re-parsed.
    public internal(set) var isDirty: Bool

    init(length: Int, block: Block, referenceDefinitions: [ReferenceDefinition] = [],
         hasBracket: Bool = true, isDirty: Bool = false) {
        self.length = length
        self.block = block
        self.referenceDefinitions = referenceDefinitions
        self.hasBracket = hasBracket
        self.isDirty = isDirty
    }
}

/// The top-level blocks of a document as a flat, editable sequence of spans.
///
/// Edits mark the spans they touch dirty; `LipiParser` re-parses dirty runs
/// with one clean neighbour on each side and splices the result back in.
/// Span starts are kept in a prefix array that is rebuilt on structural change
/// (O(entries), tens of microseconds even for very large documents).
public struct BlockIndex: Sendable {
    public private(set) var entries: [BlockEntry]
    private var starts: [Int]
    /// Total bytes covered by the entries; equals the document length once
    /// every delta has been applied.
    public private(set) var length: Int
    /// Set when the index can no longer be repaired incrementally.
    var needsFullParse: Bool

    public init() {
        entries = []
        starts = []
        length = 0
        needsFullParse = true
    }

    init(entries: [BlockEntry]) {
        self.entries = entries
        starts = []
        length = 0
        needsFullParse = false
        rebuildStarts()
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    /// Absolute start of entry `i`.
    public func start(of i: Int) -> Int { starts[i] }
    /// Absolute end (exclusive) of entry `i`'s span.
    public func end(of i: Int) -> Int { starts[i] + entries[i].length }

    /// The entry whose span contains `offset`; offsets at or past the end map
    /// to the last entry. `nil` only when the index is empty.
    public func entryIndex(containing offset: Int) -> Int? {
        guard !entries.isEmpty else { return nil }
        var lo = 0, hi = entries.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Entry `i`'s block with absolute ranges.
    public func absoluteBlock(at i: Int) -> Block {
        entries[i].block.shifted(by: starts[i])
    }

    /// All top-level blocks with absolute ranges.
    public var blocks: [Block] {
        entries.indices.map { absoluteBlock(at: $0) }
    }

    /// All reference definitions in document order.
    var referenceDefinitions: [ReferenceDefinition] {
        entries.flatMap(\.referenceDefinitions)
    }

    var hasDirtyEntries: Bool { entries.contains { $0.isDirty } }

    // MARK: Mutation

    /// Records an edit: the entries touching the replaced range collapse into
    /// one dirty entry whose length reflects the replacement.
    mutating func markDirty(_ delta: Delta) {
        guard !entries.isEmpty, !needsFullParse else {
            needsFullParse = true
            return
        }
        let old = delta.oldRange.byteRange
        let new = delta.newRange.byteRange
        guard let i = entryIndex(containing: old.lowerBound),
              let j = entryIndex(containing: max(old.lowerBound, old.upperBound - 1)) else {
            needsFullParse = true
            return
        }
        let newLength = (end(of: j) - start(of: i)) - old.count + new.count
        guard newLength >= 0 else {
            needsFullParse = true
            return
        }
        var merged = entries[i]
        merged.length = newLength
        merged.isDirty = true
        merged.hasBracket = true
        if j > i {
            for k in (i + 1)...j { merged.referenceDefinitions += entries[k].referenceDefinitions }
        }
        entries.replaceSubrange(i...j, with: CollectionOfOne(merged))
        rebuildStarts(from: i)
    }

    /// Flags entry `i` for re-parse without changing its length.
    mutating func markDirty(_ i: Int) {
        entries[i].isDirty = true
    }

    /// Replaces entries `range` with `replacement`.
    mutating func replace(_ range: ClosedRange<Int>, with replacement: [BlockEntry]) {
        entries.replaceSubrange(range, with: replacement)
        rebuildStarts(from: range.lowerBound)
    }

    mutating func replaceAll(with replacement: [BlockEntry]) {
        entries = replacement
        needsFullParse = false
        rebuildStarts()
    }

    /// The last maximal run of dirty entries that ends before `limit`.
    func lastDirtyCluster(before limit: Int) -> ClosedRange<Int>? {
        var hi = min(limit, entries.count) - 1
        while hi >= 0 && !entries[hi].isDirty { hi -= 1 }
        guard hi >= 0 else { return nil }
        var lo = hi
        while lo > 0 && entries[lo - 1].isDirty { lo -= 1 }
        return lo...hi
    }

    private mutating func rebuildStarts(from first: Int = 0) {
        // `starts[first - 1]` is still valid: entries before `first` are untouched.
        var offset = first > 0 ? starts[first - 1] + entries[first - 1].length : 0
        if starts.count != entries.count {
            starts.removeSubrange(min(first, starts.count)...)
            starts.append(contentsOf: repeatElement(0, count: entries.count - starts.count))
        }
        var i = first
        while i < entries.count {
            starts[i] = offset
            offset += entries[i].length
            i += 1
        }
        length = offset
    }
}
