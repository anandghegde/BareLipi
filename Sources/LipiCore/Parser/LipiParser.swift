import CCmarkGFM
import Dispatch

/// Which cmark-gfm syntax extensions and options a parse uses.
public struct ParserOptions: Sendable, Hashable {
    public struct Extensions: OptionSet, Sendable, Hashable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }

        public static let table = Extensions(rawValue: 1 << 0)
        public static let strikethrough = Extensions(rawValue: 1 << 1)
        public static let autolink = Extensions(rawValue: 1 << 2)
        public static let tagfilter = Extensions(rawValue: 1 << 3)
        public static let tasklist = Extensions(rawValue: 1 << 4)
        public static let footnotes = Extensions(rawValue: 1 << 5)
        /// `$…$` / `$$…$$` TeX math (BareLipi addition, Pandoc rules).
        public static let math = Extensions(rawValue: 1 << 6)
        /// `~x~` subscript, Pandoc rules (opt-in). Strikethrough then needs `~~`.
        public static let `subscript` = Extensions(rawValue: 1 << 7)
        /// `^x^` superscript, Pandoc rules (opt-in).
        public static let superscript = Extensions(rawValue: 1 << 8)
        /// `==x==` highlight (opt-in).
        public static let highlight = Extensions(rawValue: 1 << 9)
        /// `:alias:` emoji shortcodes as `.emoji` inlines (AST only; HTML keeps the text).
        public static let emojiShortcodes = Extensions(rawValue: 1 << 10)
        /// Pandoc `{#id .class}` after a heading's text as an `.attributes` inline (AST only).
        public static let headingAttributes = Extensions(rawValue: 1 << 11)

        /// The five extensions GitHub enables.
        public static let gfm: Extensions = [.table, .strikethrough, .autolink, .tagfilter, .tasklist]

        var names: [String] {
            var out: [String] = []
            if contains(.table) { out.append("table") }
            if contains(.strikethrough) || contains(.subscript) { out.append("strikethrough") }
            if contains(.autolink) { out.append("autolink") }
            if contains(.tagfilter) { out.append("tagfilter") }
            if contains(.tasklist) { out.append("tasklist") }
            if contains(.footnotes) { out.append("footnotes") }
            if contains(.math) { out.append("math") }
            if contains(.superscript) { out.append("superscript") }
            if contains(.highlight) { out.append("highlight") }
            return out
        }
    }

    public var extensions: Extensions
    /// Keep footnote definitions and references where they were written
    /// instead of renumbering and relocating them (what an editor wants).
    public var keepFootnotes: Bool

    public init(extensions: Extensions, keepFootnotes: Bool = false) {
        self.extensions = extensions
        self.keepFootnotes = keepFootnotes
    }

    /// What BareLipi edits with: GFM, footnotes and math, positions preserved.
    public static let editor = ParserOptions(extensions: [.gfm, .footnotes, .math, .emojiShortcodes, .headingAttributes],
                                             keepFootnotes: true)
    /// GitHub's rendering behaviour.
    public static let gfm = ParserOptions(extensions: .gfm)
    /// Plain CommonMark.
    public static let commonMark = ParserOptions(extensions: [])

    var extensionNames: [String] { extensions.names }

    var cmarkOptions: Int32 {
        var options = CMarkOption.unsafe
        if extensions.contains(.footnotes) { options |= CMarkOption.footnotes }
        if keepFootnotes { options |= Int32(LIPI_OPT_KEEP_FOOTNOTES) }
        if extensions.contains(.subscript) { options |= Int32(LIPI_OPT_SUBSCRIPT) }
        return options
    }
}

/// cmark-gfm option bits (`cmark-gfm.h`), spelled out so Swift need not
/// import the macros.
enum CMarkOption {
    static let footnotes: Int32 = 1 << 13
    static let unsafe: Int32 = 1 << 17
}

/// Counters for tests and the bench harness.
public struct ParseStats: Sendable, Equatable {
    /// cmark runs (full parses included).
    public var regionParses = 0
    /// Bytes handed to cmark across all runs.
    public var bytesParsed = 0
    /// Full-document parses.
    public var fullParses = 0
    /// Bytes handed to cmark by the most recent `reparse`.
    public var lastReparseBytes = 0
    /// Entries replaced by the most recent `reparse`.
    public var lastReparseEntries = 0
    /// Whether the most recent `reparse` needed a second pass because the
    /// document's reference definitions changed.
    public var lastReparseHadReferencePass = false
    /// Table rows re-parsed in place (without re-parsing their table), all runs.
    public var tableRowReparses = 0
}

/// Markdown parser over the vendored cmark-gfm with incremental re-parse.
///
/// `parse` builds a `BlockIndex` for the whole document; `apply(_:)` records
/// edits; `reparse` re-parses only the dirty spans plus one clean neighbour on
/// each side, widening until the neighbours parse identically to before.
/// Link reference definitions are seeded into every region parse so reference
/// links resolve as they would in the whole document.
public struct LipiParser: Sendable {
    public let options: ParserOptions
    public private(set) var index: BlockIndex
    public private(set) var stats = ParseStats()
    /// Every reference definition in the document, in source order.
    public private(set) var references: [ReferenceDefinition] = []
    private var ids = NodeIDGenerator()

    public init(options: ParserOptions = .editor) {
        self.options = options
        index = BlockIndex()
    }

    /// Top-level blocks with absolute ranges. Stale for dirty entries until
    /// the next `reparse`.
    public var blocks: [Block] { index.blocks }

    // MARK: Full parse

    public mutating func parse(_ text: String) {
        parse(LipiRope(text))
    }

    public mutating func parse(_ rope: LipiRope) {
        let entries = parseRegion(rope, 0..<rope.count, allowFrontMatterOverflow: true) ?? []
        index.replaceAll(with: entries)
        references = index.referenceDefinitions
        stats.fullParses += 1
        stats.lastReparseBytes = rope.count
        stats.lastReparseEntries = entries.count
        stats.lastReparseHadReferencePass = false
        assert(index.length == rope.count)
    }

    // MARK: Incremental

    /// Records an edit. Call once per delta, in order, then `reparse`.
    public mutating func apply(_ delta: Delta) {
        index.markDirty(delta)
    }

    /// Records several edits, in the order they were applied. Deltas that
    /// run down the document without overlapping (what
    /// `SourceBuffer.applyBatch` returns) are all valid in the coordinates
    /// from before the first, and are recorded in one pass over the index.
    public mutating func apply(_ deltas: [Delta]) {
        var descending = deltas.count > 1
        if descending {
            for k in deltas.indices.dropFirst()
            where deltas[k].oldRange.upperBound > deltas[k - 1].oldRange.lowerBound {
                descending = false
                break
            }
        }
        if descending {
            index.markDirty(ascending: deltas.reversed())
        } else {
            for delta in deltas { index.markDirty(delta) }
        }
    }

    /// Records an edit and immediately re-parses.
    public mutating func apply(_ delta: Delta, then rope: LipiRope) {
        apply(delta)
        reparse(rope)
    }

    /// Re-parses whatever is dirty so the index matches `rope`.
    public mutating func reparse(_ rope: LipiRope) {
        if index.needsFullParse || index.isEmpty || index.length != rope.count {
            parse(rope)
            return
        }
        guard index.hasDirtyEntries else {
            stats.lastReparseBytes = 0
            stats.lastReparseEntries = 0
            stats.lastReparseHadReferencePass = false
            return
        }
        let before = stats
        stats.lastReparseHadReferencePass = false
        let oldReferences = references
        if !reparseDirtyClusters(rope) { fallBack(rope, before); return }
        var newReferences = index.referenceDefinitions
        if newReferences != oldReferences {
            // Reference links anywhere may now resolve differently.
            stats.lastReparseHadReferencePass = true
            for i in index.entries.indices where index.entries[i].hasBracket {
                index.markDirty(i)
            }
            references = newReferences
            if !reparseDirtyClusters(rope) { fallBack(rope, before); return }
            newReferences = index.referenceDefinitions
        }
        references = newReferences
        stats.lastReparseBytes = stats.bytesParsed - before.bytesParsed
        assert(index.length == rope.count)
        assert(!index.hasDirtyEntries)
    }

    private mutating func fallBack(_ rope: LipiRope, _ before: ParseStats) {
        parse(rope)
        stats.lastReparseBytes = stats.bytesParsed - before.bytesParsed
    }

    /// Re-parses each dirty run, back to front. Returns false when the
    /// document must be parsed as a whole instead.
    private mutating func reparseDirtyClusters(_ rope: LipiRope) -> Bool {
        // The concurrent pass can change the entry count, so the serial
        // loop's limit is taken after it.
        var replaced = reparseClustersConcurrently(rope)
        var limit = index.count
        while let cluster = index.lastDirtyCluster(before: limit) {
            if cluster.count == 1, index.entries[cluster.lowerBound].pendingRowEdit != nil,
               reparseTableRow(cluster.lowerBound, in: rope) {
                replaced += 1
                limit = cluster.lowerBound
                continue
            }
            guard let range = reparseCluster(cluster, in: rope, replaced: &replaced) else { return false }
            limit = range.lowerBound
        }
        stats.lastReparseEntries = replaced
        return true
    }

    /// Dirty runs at which `reparse` parses the runs' regions concurrently.
    var concurrentClusterThreshold = 8

    /// One dirty run's speculative re-parse (see `reparseClustersConcurrently`).
    private struct Speculation: Sendable {
        var entries: [BlockEntry]
        var bytes: Int
    }

    /// When many runs are dirty (Replace All), parses each run with its two
    /// clean neighbours on all cores at once and splices every run whose
    /// neighbours came back unchanged in one pass over the index: the first
    /// attempt of `reparseCluster`, done in parallel. Runs that need widening
    /// stay dirty for the serial loop. Table-row edits are left to it too.
    /// Returns the entries replaced.
    private mutating func reparseClustersConcurrently(_ rope: LipiRope) -> Int {
        let entries = index.entries
        var clusters: [ClosedRange<Int>] = []
        var i = 0
        while i < entries.count {
            guard entries[i].isDirty else { i += 1; continue }
            var j = i
            while j + 1 < entries.count && entries[j + 1].isDirty { j += 1 }
            if !(i == j && entries[i].pendingRowEdit != nil) { clusters.append(i...j) }
            i = j + 1
        }
        guard clusters.count >= concurrentClusterThreshold else { return 0 }

        // Each run gets its own identity range, sized well past what its
        // bytes can produce; a run that overflows it is discarded.
        var bases: [UInt64] = []
        var strides: [UInt64] = []
        var next = ids.peek
        for c in clusters {
            let lo = c.lowerBound > 0 ? c.lowerBound - 1 : c.lowerBound
            let hi = c.upperBound < index.count - 1 ? c.upperBound + 1 : c.upperBound
            let stride = UInt64(4 * (index.end(of: hi) - index.start(of: lo)) + 64)
            bases.append(next)
            strides.append(stride)
            next += stride
        }
        ids = NodeIDGenerator(startingAt: next)

        let refs = Self.referenceList(index)
        let snapshot = index
        let runs = clusters, idBases = bases, idCounts = strides
        let options = options
        var results = [Speculation?](repeating: nil, count: clusters.count)
        results.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let out = buffer
            DispatchQueue.concurrentPerform(iterations: clusters.count) { k in
                out[k] = Self.speculate(runs[k], index: snapshot, rope: rope, options: options, refs: refs,
                                        firstID: idBases[k], idCount: idCounts[k])
            }
        }

        var items: [(range: ClosedRange<Int>, entries: [BlockEntry])] = []
        var replaced = 0
        for (k, result) in results.enumerated() {
            guard let result else { continue }
            items.append((clusters[k], result.entries))
            replaced += result.entries.count
            stats.regionParses += 1
            stats.bytesParsed += result.bytes
        }
        index.replace(ascending: items)
        return replaced
    }

    /// `reparseCluster`'s first attempt at `cluster`, on a snapshot: nil when
    /// either clean neighbour parsed differently.
    private static func speculate(_ cluster: ClosedRange<Int>, index: BlockIndex, rope: LipiRope,
                                  options: ParserOptions, refs: [(start: Int, definitions: [ReferenceDefinition])],
                                  firstID: UInt64, idCount: UInt64) -> Speculation? {
        let lo = cluster.lowerBound, hi = cluster.upperBound
        let anchorLo: Int? = lo > 0 ? lo - 1 : nil
        let anchorHi: Int? = hi < index.count - 1 ? hi + 1 : nil
        let region = index.start(of: anchorLo ?? lo)..<index.end(of: anchorHi ?? hi)
        var ids = NodeIDGenerator(startingAt: firstID)
        var stats = ParseStats()
        let seeds = seedReferences(outside: region, refs: refs, length: index.length)
        guard let parsed = parseRegion(rope, region, allowFrontMatterOverflow: region.upperBound == rope.count,
                                       options: options, seeds: seeds, ids: &ids, stats: &stats),
              ids.peek - firstID <= idCount else { return nil }
        if let a = anchorLo {
            guard let first = parsed.first, matches(first, index.entries[a]) else { return nil }
        }
        if let b = anchorHi {
            guard let last = parsed.last, parsed.count > (anchorLo != nil ? 1 : 0),
                  matches(last, index.entries[b]) else { return nil }
        }
        var replacement = parsed
        if anchorHi != nil { replacement.removeLast() }
        if anchorLo != nil { replacement.removeFirst() }
        return Speculation(entries: replacement, bytes: stats.bytesParsed)
    }

    /// Re-parses one dirty run with its clean neighbours, widening as needed.
    /// Returns the index range that now holds the re-parsed entries, or nil
    /// when the region grew to the whole document.
    private mutating func reparseCluster(_ cluster: ClosedRange<Int>, in rope: LipiRope,
                                         replaced: inout Int) -> ClosedRange<Int>? {
        var lo = cluster.lowerBound
        var hi = cluster.upperBound
        var anchorLo = cleanAnchor(before: &lo)
        var anchorHi = cleanAnchor(after: &hi)
        // Each failed anchor absorbs twice as many entries as the last, so a
        // structural edit that reaches far (an unclosed fence, say) costs a
        // bounded number of region parses.
        var loStep = 1
        var hiStep = 1

        while true {
            let regionStart = index.start(of: anchorLo ?? lo)
            let regionEnd = index.end(of: anchorHi ?? hi)
            guard let parsed = parseRegion(rope, regionStart..<regionEnd,
                                           allowFrontMatterOverflow: regionEnd == rope.count) else {
                return nil
            }

            var widened = false
            if let a = anchorLo {
                if let first = parsed.first, Self.matches(first, index.entries[a]) {
                    // keep
                } else {
                    lo = max(a - loStep + 1, 0)
                    loStep *= 2
                    anchorLo = cleanAnchor(before: &lo)
                    widened = true
                }
            }
            if let b = anchorHi {
                let bothAnchored = anchorLo != nil && !widened
                if let last = parsed.last, parsed.count > (bothAnchored ? 1 : 0), Self.matches(last, index.entries[b]) {
                    // keep
                } else {
                    hi = min(b + hiStep - 1, index.count - 1)
                    hiStep *= 2
                    anchorHi = cleanAnchor(after: &hi)
                    widened = true
                }
            }
            if widened {
                if anchorLo == nil && anchorHi == nil && lo == 0 && hi == index.count - 1 { return nil }
                continue
            }

            var replacement = parsed
            if anchorHi != nil { replacement.removeLast() }
            if anchorLo != nil { replacement.removeFirst() }
            replaced += replacement.count
            index.replace(lo...hi, with: replacement)
            return lo...(lo + max(replacement.count, 1) - 1)
        }
    }

    /// Re-parses the one edited body row of table entry `i` and splices it in,
    /// keeping the table's and every other row's node identity. The row is
    /// parsed behind the table's own header and delimiter lines, so cmark sees
    /// the same column count and alignments; rows of a GFM table are
    /// independent of each other, so that parse is the row's parse in the
    /// whole document. Returns false (index untouched) when the edit may do
    /// more than change the row: a newline was typed, the line no longer
    /// continues the table, or it involves footnotes; the caller then
    /// re-parses the entry as usual.
    private mutating func reparseTableRow(_ i: Int, in rope: LipiRope) -> Bool {
        let entry = index.entries[i]
        guard let edit = entry.pendingRowEdit, case .table(let alignments) = entry.block.kind else { return false }
        let rows = entry.block.children
        let k = edit.row
        guard k >= 1, k < rows.count, case .tableRow(isHeader: false) = rows[k].kind else { return false }
        let start = index.start(of: i)
        let end = start + entry.length
        // Both rows start before the edit, so their absolute positions still hold.
        let headerEnd = rope.lineRange(rope.line(at: start + rows[1].range.lowerBound)).lowerBound
        let line = rope.lineRange(rope.line(at: start + rows[k].range.lowerBound))
        guard headerEnd > start, line.upperBound <= end else { return false }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(headerEnd - start + line.count)
        rope.forEachChunk(in: start..<headerEnd) { bytes.append(contentsOf: $0.utf8) }
        let rowOffset = bytes.count
        rope.forEachChunk(in: line) { bytes.append(contentsOf: $0.utf8) }
        // The line must still end after the inserted bytes: no newline typed.
        let lineContentEnd = line.upperBound - (bytes.last == 0x0A ? 1 : 0)
        guard lineContentEnd >= start + edit.oldRange.lowerBound + edit.newCount else { return false }
        if options.extensions.contains(.footnotes) {
            var p = rowOffset
            while p + 1 < bytes.count {
                if bytes[p] == 0x5B && bytes[p + 1] == 0x5E { return false }
                p += 1
            }
        }
        stats.regionParses += 1
        stats.bytesParsed += bytes.count
        let seeds = seedReferences(outside: start..<end)
        let parsed = bytes.withUnsafeBufferPointer {
            CMarkBridge.parse($0, options: options, references: seeds, ids: &ids)
        }
        guard parsed.count == 1, parsed[0].spanStart == 0, parsed[0].referenceDefinitions.isEmpty,
              case .table(let newAlignments) = parsed[0].block.kind, newAlignments == alignments,
              parsed[0].block.children.count == 2,
              parsed[0].block.range.lowerBound == entry.block.range.lowerBound,
              parsed[0].block.children[0].isStructurallyEqual(to: rows[0]) else { return false }
        var row = parsed[0].block.children[1]
        guard row.range.lowerBound >= rowOffset, case .tableRow(isHeader: false) = row.kind else { return false }
        row.shift(by: (line.lowerBound - start) - rowOffset)

        let delta = edit.newCount - edit.oldRange.count
        var updated = index.take(i)
        updated.block.children[k] = row
        var r = k + 1
        while r < updated.block.children.count {
            updated.block.children[r].shift(by: delta)
            r += 1
        }
        let first = updated.block.children[0].range.lowerBound
        let last = updated.block.children[updated.block.children.count - 1].range.upperBound
        updated.block.range = updated.block.range.lowerBound..<max(first, last)
        updated.isDirty = false
        updated.pendingRowEdit = nil
        updated.hasBracket = edit.hadBracket || parsed[0].hasBracket
        updated.tableRowEdit = TableRowEdit(row: k, lengthDelta: delta, baseRevision: updated.revision)
        updated.revision &+= 1
        index.update(i, with: updated)
        stats.tableRowReparses += 1
        return true
    }

    /// The clean entry before `lo`, absorbing dirty ones into the cluster.
    private func cleanAnchor(before lo: inout Int) -> Int? {
        while lo > 0 {
            if !index.entries[lo - 1].isDirty { return lo - 1 }
            lo -= 1
        }
        return nil
    }

    private func cleanAnchor(after hi: inout Int) -> Int? {
        while hi < index.count - 1 {
            if !index.entries[hi + 1].isDirty { return hi + 1 }
            hi += 1
        }
        return nil
    }

    private static func matches(_ new: BlockEntry, _ old: BlockEntry) -> Bool {
        !old.isDirty && new.length == old.length
            && new.referenceDefinitions == old.referenceDefinitions
            && new.block.isStructurallyEqual(to: old.block)
    }

    // MARK: Region parse

    /// Parses `range` of `rope` as a document, returning span entries that
    /// tile it. Returns nil when front matter extends past the region (the
    /// caller must widen).
    private mutating func parseRegion(_ rope: LipiRope, _ range: Range<Int>,
                                      allowFrontMatterOverflow: Bool) -> [BlockEntry]? {
        Self.parseRegion(rope, range, allowFrontMatterOverflow: allowFrontMatterOverflow, options: options,
                         seeds: seedReferences(outside: range), ids: &ids, stats: &stats)
    }

    private static func parseRegion(_ rope: LipiRope, _ range: Range<Int>, allowFrontMatterOverflow: Bool,
                                    options: ParserOptions, seeds: [SeedReference],
                                    ids: inout NodeIDGenerator, stats: inout ParseStats) -> [BlockEntry]? {
        var entries: [BlockEntry] = []
        var start = range.lowerBound
        if start == 0, let fm = FrontMatter.detect(in: rope) {
            guard fm.spanEnd <= range.upperBound || allowFrontMatterOverflow else { return nil }
            let spanEnd = min(fm.spanEnd, range.upperBound)
            let block = Block(id: ids.make(), range: 0..<min(fm.contentEnd, spanEnd), kind: .frontMatter(fm.kind))
            entries.append(BlockEntry(length: spanEnd, block: block, referenceDefinitions: [], hasBracket: false))
            start = spanEnd
        }
        guard start < range.upperBound || entries.isEmpty else { return entries }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(range.upperBound - start)
        rope.forEachChunk(in: start..<range.upperBound) { bytes.append(contentsOf: $0.utf8) }
        stats.regionParses += 1
        stats.bytesParsed += bytes.count

        let regionBlocks = bytes.withUnsafeBufferPointer {
            CMarkBridge.parse($0, options: options, references: seeds, ids: &ids)
        }

        // Tile the region: the first span absorbs any leading bytes, the last
        // runs to the end of the region.
        if regionBlocks.isEmpty {
            if !entries.isEmpty {
                entries[entries.count - 1].length += bytes.count
            } else if bytes.count > 0 {
                // Blank document: one empty paragraph-less span keeps offsets tiling.
                let block = Block(id: ids.make(), range: 0..<0, kind: .paragraph)
                entries.append(BlockEntry(length: bytes.count, block: block, referenceDefinitions: [],
                                          hasBracket: false))
            }
            return entries
        }
        entries.reserveCapacity(entries.count + regionBlocks.count)
        for (k, rb) in regionBlocks.enumerated() {
            let spanEnd = k + 1 < regionBlocks.count ? regionBlocks[k + 1].spanStart : bytes.count
            entries.append(BlockEntry(length: spanEnd - rb.spanStart, block: rb.block,
                                      referenceDefinitions: rb.referenceDefinitions, hasBracket: rb.hasBracket))
        }
        return entries
    }

    /// Reference definitions from entries outside `range`, aged so earlier
    /// definitions win over the region's own and the region's win over later ones.
    private func seedReferences(outside range: Range<Int>) -> [SeedReference] {
        guard !index.isEmpty, range != 0..<index.length else { return [] }
        return Self.seedReferences(outside: range, refs: Self.referenceList(index), length: index.length)
    }

    /// The entries that define references: their starts and definitions.
    private static func referenceList(_ index: BlockIndex) -> [(start: Int, definitions: [ReferenceDefinition])] {
        var list: [(start: Int, definitions: [ReferenceDefinition])] = []
        for i in index.entries.indices where !index.entries[i].referenceDefinitions.isEmpty {
            list.append((index.start(of: i), index.entries[i].referenceDefinitions))
        }
        return list
    }

    private static func seedReferences(outside range: Range<Int>,
                                       refs: [(start: Int, definitions: [ReferenceDefinition])],
                                       length: Int) -> [SeedReference] {
        guard range != 0..<length else { return [] }
        var seeds: [SeedReference] = []
        var age: Int32 = 0
        for (s, definitions) in refs {
            if s >= range.lowerBound && s < range.upperBound { continue }
            let after = s >= range.upperBound
            for def in definitions {
                seeds.append(SeedReference(definition: def, age: after ? (1 << 30) + age : age))
                age += 1
            }
        }
        return seeds
    }

    // MARK: HTML

    /// HTML for `markdown` as `cmark-gfm --unsafe` with `options` renders it.
    public static func renderHTML(_ markdown: String, options: ParserOptions = .gfm) -> String {
        CMarkBridge.renderHTML(markdown, extensions: options.extensionNames, cmarkOptions: options.cmarkOptions)
    }

    /// HTML with an explicit extension list, matching the spec runner's
    /// per-example `extensions` (`footnotes` also sets the footnotes option).
    public static func renderHTML(_ markdown: String, extensions: [String]) -> String {
        var cmarkOptions = CMarkOption.unsafe
        if extensions.contains("footnotes") { cmarkOptions |= CMarkOption.footnotes }
        return CMarkBridge.renderHTML(markdown, extensions: extensions, cmarkOptions: cmarkOptions)
    }
}
