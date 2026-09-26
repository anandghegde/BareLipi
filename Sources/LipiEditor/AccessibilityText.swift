import AppKit
import LipiCore

/// The text the accessibility text protocol speaks (§6.20): the projected
/// document as it reads with every block folded, not the Markdown source.
///
/// Cells are joined in document order: blocks by `\n`, table cells of one row
/// by `\t` and rows by `\n`. Offsets are UTF-16 units of `string`; each maps
/// to a `DisplayPosition` of the folded projection and from there, through
/// the cell's `OffsetMap`, to a source byte. The folded projection (rather
/// than the live one, whose markers appear around the caret) keeps the text
/// and its offsets stable while VoiceOver moves the caret; in source mode
/// the text is the source.
struct AccessibilityText {
    struct Unit {
        var entry: Int
        var block: Int
        var cell: Int
        /// Offset of the cell's first unit in `string`.
        var start: Int
        var length: Int
    }

    let projection: Projection
    let string: NSString
    let units: [Unit]
    /// Index into `units` of each entry's first cell.
    let entryUnits: [Int]
    /// Offset of the first unit of every `\n`-separated line.
    let lineStarts: [Int]

    init(projection: Projection) {
        self.projection = projection
        var text = ""
        var units: [Unit] = []
        var entryUnits: [Int] = []
        var lineStarts = [0]
        var offset = 0
        for (e, entry) in projection.entries.enumerated() {
            entryUnits.append(units.count)
            for (b, block) in entry.blocks.enumerated() {
                for (c, cell) in block.cells.enumerated() {
                    if !units.isEmpty {
                        let sameRow = block.table.map { c > 0 && $0.position(ofCell: c).row == $0.position(ofCell: c - 1).row } ?? false
                        text.append(sameRow ? "\t" : "\n")
                        offset += 1
                        if !sameRow { lineStarts.append(offset) }
                    }
                    var length = 0
                    for u in cell.text.utf16 {
                        length += 1
                        if u == 0x0A { lineStarts.append(offset + length) }
                    }
                    units.append(Unit(entry: e, block: b, cell: c, start: offset, length: length))
                    text.append(cell.text)
                    offset += length
                }
            }
        }
        string = text as NSString
        self.units = units
        self.entryUnits = entryUnits
        self.lineStarts = lineStarts
    }

    var length: Int { string.length }

    // MARK: Offsets

    /// Index of the unit holding `offset` (a separator belongs to the unit before it).
    func unitIndex(at offset: Int) -> Int {
        var lo = 0, hi = units.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if units[mid].start <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func position(at offset: Int) -> DisplayPosition? {
        guard !units.isEmpty else { return nil }
        let o = max(0, min(offset, length))
        let u = units[unitIndex(at: o)]
        return DisplayPosition(entry: u.entry, block: u.block, cell: u.cell, offset: min(o - u.start, u.length))
    }

    /// Index into `units` of a display cell.
    func unitIndex(entry: Int, block: Int, cell: Int) -> Int? {
        guard entry < entryUnits.count else { return nil }
        var i = entryUnits[entry]
        let blocks = projection.entries[entry].blocks
        for b in 0..<min(block, blocks.count) { i += blocks[b].cells.count }
        i += cell
        return i < units.count ? i : nil
    }

    func offset(of p: DisplayPosition) -> Int {
        guard let i = unitIndex(entry: p.entry, block: p.block, cell: p.cell) else { return length }
        return units[i].start + min(p.offset, units[i].length)
    }

    /// Absolute source byte of a text offset.
    func sourceOffset(at offset: Int) -> Int {
        position(at: offset).map(projection.sourceOffset(for:)) ?? 0
    }

    /// Text offset of an absolute source byte (hidden syntax maps to where it folds).
    func offset(forSource source: Int) -> Int {
        projection.position(forSource: source).map(offset(of:)) ?? 0
    }

    /// Absolute source byte where the text before `offset` ends: a range
    /// ending at a closing delimiter stops before it (`sourceOffset(at:)`
    /// resolves past markers, as a caret does).
    func sourceOffset(upstreamAt offset: Int) -> Int {
        guard let p = position(at: offset), p.offset > 0 else { return sourceOffset(at: offset) }
        let entry = projection.entries[p.entry]
        let segments = entry.blocks[p.block].cells[p.cell].map.segments
        // Last segment with display text that starts before the offset.
        var lo = 0, hi = segments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if Int(segments[mid].displayStart) < p.offset { lo = mid + 1 } else { hi = mid }
        }
        var i = lo - 1
        while i >= 0, segments[i].displayLength == 0 { i -= 1 }
        if i >= 0, Int(segments[i].displayEnd) == p.offset { return entry.start + Int(segments[i].sourceEnd) }
        return projection.sourceOffset(for: p)
    }

    func sourceRange(for range: NSRange) -> Range<Int> {
        let lo = sourceOffset(at: range.location)
        let hi = range.length == 0 ? lo : sourceOffset(upstreamAt: range.location + range.length)
        return lo..<max(lo, hi)
    }

    func range(forSource range: Range<Int>) -> NSRange {
        let lo = offset(forSource: range.lowerBound)
        let hi = range.isEmpty ? lo : offset(forSource: range.upperBound)
        return NSRange(location: lo, length: max(0, hi - lo))
    }

    // MARK: Lines

    func line(for offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// The line's units including its terminating newline.
    func range(forLine line: Int) -> NSRange? {
        guard line >= 0, line < lineStarts.count else { return nil }
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : length
        return NSRange(location: lineStarts[line], length: end - lineStarts[line])
    }

    /// `range` clamped to the text.
    func clamp(_ range: NSRange) -> NSRange {
        let lo = max(0, min(range.location, length))
        let hi = max(lo, min(range.location + max(range.length, 0), length))
        return NSRange(location: lo, length: hi - lo)
    }

    // MARK: Editing

    /// The smallest edit turning `string` into `new`: the changed range of
    /// the old text (UTF-16) and its replacement.
    func difference(to new: String) -> (range: NSRange, replacement: String)? {
        let a = string, b = new as NSString
        if a.isEqual(to: new) { return nil }
        var prefix = 0
        let limit = min(a.length, b.length)
        while prefix < limit, a.character(at: prefix) == b.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, a.character(at: a.length - 1 - suffix) == b.character(at: b.length - 1 - suffix) { suffix += 1 }
        // Keep surrogate pairs whole.
        if prefix > 0, prefix < a.length, UTF16.isTrailSurrogate(a.character(at: prefix)) { prefix -= 1 }
        if suffix > 0, UTF16.isTrailSurrogate(a.character(at: a.length - suffix)) { suffix -= 1 }
        let old = NSRange(location: prefix, length: a.length - suffix - prefix)
        let replacement = b.substring(with: NSRange(location: prefix, length: b.length - suffix - prefix))
        return (old, replacement)
    }
}

/// Keeps the folded projection behind `AccessibilityText` up to date,
/// lazily: nothing runs on the keystroke path until an assistive app asks.
@MainActor
final class AccessibilityModel {
    private var projection = Projection()
    private var cached: (generation: UInt64, sourceMode: Bool, preset: RevealPreset, text: AccessibilityText)?

    func text(for controller: EditorController) -> AccessibilityText {
        let generation = controller.buffer.generation
        let sourceMode = controller.mode == .source
        let preset = controller.projection.preset
        if let cached, cached.generation == generation, cached.sourceMode == sourceMode, cached.preset == preset {
            return cached.text
        }
        if projection.preset != preset || projection.sourceMode != sourceMode {
            projection = Projection(preset: preset)
            projection.sourceMode = sourceMode
        }
        projection.frontMatterWarning = controller.projection.frontMatterWarning
        projection.update(index: controller.blockIndex, rope: controller.rope, reveal: sourceMode ? .everything : RevealSet())
        let text = AccessibilityText(projection: projection)
        cached = (generation, sourceMode, preset, text)
        return text
    }
}
