import CoreGraphics
import Foundation
import LipiCore

/// The layout of one projected entry: its blocks stacked with their spacing.
/// A table block grows as its rows are measured (`TableLayout`), so the
/// tops and the height are refreshed by `DocumentLayout` when that happens.
public final class EntryLayout {
    public let id: NodeID
    public let blocks: [BlockLayout]
    /// y of each block's box within the entry (spacing before applied).
    public private(set) var blockTops: [CGFloat]
    public private(set) var height: CGFloat
    /// Whether the first block takes its spacing before (every entry but the first).
    let spacesFirstBlock: Bool
    let hasTable: Bool

    init(id: NodeID, blocks: [BlockLayout], spacesFirstBlock: Bool) {
        self.id = id
        self.blocks = blocks
        self.spacesFirstBlock = spacesFirstBlock
        hasTable = blocks.contains { $0.table != nil }
        blockTops = []
        height = 0
        _ = refresh()
    }

    /// Recomputes the block tops and the height from the blocks' current
    /// heights; returns whether the height changed.
    func refresh() -> Bool {
        var tops: [CGFloat] = []
        tops.reserveCapacity(blocks.count)
        var y: CGFloat = 0
        for (b, block) in blocks.enumerated() {
            if spacesFirstBlock || b > 0 { y += block.spacingBefore }
            tops.append(y)
            y += block.height + block.spacingAfter
        }
        blockTops = tops
        defer { height = y }
        return y != height
    }

    /// Index of the block containing local `y` (clamped).
    public func blockIndex(atY y: CGFloat) -> Int {
        var i = 0
        while i + 1 < blocks.count, y >= blockTops[i + 1] { i += 1 }
        return i
    }
}

public struct PlacedEntry {
    public let index: Int
    /// Document y of the entry's top.
    public let y: CGFloat
    public let layout: EntryLayout
}

/// Lays out a `Projection` lazily: entries get an estimated height until they
/// are first needed, the visible ones are laid out through `LayoutCache`,
/// and a `HeightTree` keeps every entry's y (ADR-002, §7.4 step 7).
public final class DocumentLayout {
    public struct Stats: Sendable, Equatable {
        public var entriesLaidOut = 0
        public var blocksLaidOut = 0
        public var blocksFromCache = 0
    }

    public internal(set) var typesetter: Typesetter
    public let cache: LayoutCache
    public private(set) var themeRevision: UInt32 = 0
    public private(set) var projection = Projection()
    public private(set) var viewportWidth: CGFloat = 0
    /// Width of the text column (§8.2: 72 × advance of zero, 320–720 pt).
    public private(set) var measure: CGFloat = 0
    /// x of the text column's leading edge (side margin + gutter, centred).
    public private(set) var textOrigin: CGFloat = 0
    /// Width available to tables and code blocks: editor width minus margins.
    public private(set) var wideWidth: CGFloat = 0
    public private(set) var zeroAdvance: CGFloat = 0
    /// Extra space below the last entry (§6.1.6: up to one viewport).
    public var bottomPadding: CGFloat = 0
    /// Entry holding the caret when it sits in a table: its columns never shrink.
    public var growOnlyEntry: Int? = nil
    /// Line numbers and soft wrap of code blocks (the code header toggles).
    public var codeOptions = CodeBlockOptions() {
        didSet {
            guard codeOptions != oldValue else { return }
            themeRevision &+= 1
            invalidateAllLayouts()
        }
    }
    /// Sideways scroll of unwrapped code blocks, by block.
    var codeScroll: [NodeID: CGFloat] = [:]
    public private(set) var stats = Stats()

    var layouts: [EntryLayout?] = []
    private var tree = HeightTree()
    /// Layouts of entries replaced by the last `update`, kept for one round
    /// so tables can re-layout incrementally from them.
    private var stale: [Int: EntryLayout] = [:]

    public init(typesetter: Typesetter, cache: LayoutCache = LayoutCache(), viewportWidth: CGFloat = 800) {
        self.typesetter = typesetter
        self.cache = cache
        zeroAdvance = typesetter.cascade.zeroAdvance(size: typesetter.scale.style(for: .body).size)
        setViewportWidth(viewportWidth)
    }

    public var entryCount: Int { tree.count }
    public var scale: TypeScale { typesetter.scale }

    /// Total height: every entry's measured or estimated height plus padding.
    public var contentHeight: CGFloat { CGFloat(tree.total) + bottomPadding }

    // MARK: Configuration

    public func setViewportWidth(_ width: CGFloat) {
        let metrics = scale.theme.metrics
        viewportWidth = width
        let natural = min(max(CGFloat(metrics.measure) * zeroAdvance, metrics.minMeasure), metrics.maxMeasure).rounded()
        let available = width - 2 * scale.sideMargin - scale.gutter
        let newMeasure = max(120, min(natural, available.rounded()))
        let newOrigin = (scale.sideMargin + scale.gutter + max(0, (available - newMeasure) / 2)).rounded()
        let newWide = max(newMeasure, (width - newOrigin - scale.sideMargin).rounded())
        guard newMeasure != measure || newOrigin != textOrigin || newWide != wideWidth else { return }
        let widthChanged = newMeasure != measure || newWide != wideWidth
        measure = newMeasure
        textOrigin = newOrigin
        wideWidth = newWide
        if widthChanged { invalidateAllLayouts() }
    }

    public func setTypesetter(_ typesetter: Typesetter) {
        let windows = self.typesetter.codeWindows
        self.typesetter = typesetter
        self.typesetter.codeWindows = windows
        themeRevision &+= 1
        zeroAdvance = typesetter.cascade.zeroAdvance(size: typesetter.scale.style(for: .body).size)
        cache.removeAll()
        let width = viewportWidth
        viewportWidth = -1
        setViewportWidth(width)
        invalidateAllLayouts()
    }

    /// Forgets every entry layout but keeps the measured heights as estimates
    /// (a width change: everything is re-laid out lazily, §7.4).
    public func invalidateAllLayouts() {
        for i in layouts.indices { layouts[i] = nil }
        stale.removeAll()
    }

    /// Drops the laid-out entries holding a fenced code block so they pick
    /// up new highlight results (`HighlightService.didHighlight`). Heights
    /// stay: colour never moves text. Returns whether any entry was dropped.
    @discardableResult
    public func invalidateCodeBlocks() -> Bool {
        var any = false
        for i in layouts.indices where layouts[i] != nil && i < projection.entries.count {
            let hasCode = projection.entries[i].blocks.contains {
                if case .code(_, true) = $0.role { return true }
                return false
            }
            if hasCode {
                layouts[i] = nil
                any = true
            }
        }
        return any
    }

    // MARK: Projection updates

    /// Adopts a new projection. Entries the projection reused keep their
    /// layout; changed entries keep their old height as the estimate until
    /// they are laid out again.
    public func update(projection new: Projection, result: Projection.UpdateResult) {
        let old = projection
        var oldByID: [NodeID: Int] = [:]
        oldByID.reserveCapacity(old.entries.count)
        for (i, entry) in old.entries.enumerated() { oldByID[entry.id] = i }
        let changed = Set(result.changedEntries)
        let sameShape = new.entries.count == old.entries.count
        var newLayouts: [EntryLayout?] = []
        var heights: [Double] = []
        newLayouts.reserveCapacity(new.entries.count)
        heights.reserveCapacity(new.entries.count)
        stale.removeAll()
        // Re-parsed blocks come back with fresh node ids, so the cached
        // layouts of ids that vanished can never hit again. Drop them now;
        // otherwise a paragraph typed into for a while leaves one stale
        // layout per keystroke in the cache until the LRU bound evicts it.
        var newIDs = Set<NodeID>(minimumCapacity: new.entries.count)
        for entry in new.entries { newIDs.insert(entry.id) }
        for (j, entry) in old.entries.enumerated() where !newIDs.contains(entry.id) {
            guard let layout = layouts[j] else { continue }
            for block in layout.blocks { cache.invalidate(block.id) }
        }
        carryCodeState(from: old, to: new, changed: result.changedEntries, oldByID: oldByID, sameShape: sameShape)
        for (i, entry) in new.entries.enumerated() {
            if !changed.contains(i), let j = oldByID[entry.id] {
                newLayouts.append(layouts[j])
                heights.append(tree.height(at: j))
            } else if let j = oldByID[entry.id] ?? (sameShape && i < old.entries.count ? i : nil), j < old.entries.count {
                if let previous = layouts[j] { stale[i] = previous }
                newLayouts.append(nil)
                heights.append(tree.height(at: j))
            } else {
                newLayouts.append(nil)
                heights.append(Double(estimatedHeight(of: entry)))
            }
        }
        projection = new
        layouts = newLayouts
        if heights.count == tree.count {
            for (i, h) in heights.enumerated() { tree.update(i, height: h) }
        } else {
            tree.replace(with: heights)
        }
    }

    func estimatedHeight(of entry: ProjectedEntry) -> CGFloat {
        entry.blocks.reduce(0) { sum, block in
            let style = scale.style(for: typesetter.role(of: block, cellIndex: 0))
            return sum + style.spacingBefore + style.spacingAfter
                + LayoutEngine.estimatedHeight(of: block, typesetter: typesetter, measure: measure, zeroAdvance: zeroAdvance)
        }
    }

    // MARK: Layout

    public func y(ofEntry i: Int) -> CGFloat { CGFloat(tree.y(of: i)) }
    public func height(ofEntry i: Int) -> CGFloat { CGFloat(tree.height(at: i)) }
    public func entryIndex(atY y: CGFloat) -> Int? { tree.index(at: Double(y)) }
    public func isLaidOut(_ i: Int) -> Bool { layouts[i] != nil }

    /// The layout of entry `i`, made now if needed.
    @discardableResult
    public func ensureLayout(_ i: Int) -> EntryLayout {
        if let layout = layouts[i] { return layout }
        let entry = projection.entries[i]
        let previous = stale.removeValue(forKey: i)
        var blocks: [BlockLayout] = []
        blocks.reserveCapacity(entry.blocks.count)
        for (b, block) in entry.blocks.enumerated() {
            let isWide: Bool = {
                switch block.role {
                case .code, .table, .html: return true
                default: return false
                }
            }()
            var blockKey = block.layoutKey
            if case .code(_, true) = block.role {
                // Highlight results arrive later than the text; they change
                // colours, which Core Text bakes into the lines.
                let stamp = typesetter.highlightStamp(of: block)
                if stamp != 0 { blockKey = (blockKey ^ stamp) &* 0x100_0000_01B3 }
            }
            let key = LayoutKey(layoutKey: blockKey, width: isWide ? max(measure, wideWidth) : measure, themeRevision: themeRevision)
            let layout: BlockLayout
            if let cached = cache.layout(for: key) {
                layout = cached
                stats.blocksFromCache += 1
            } else {
                var prior = cache.previousLayout(of: block.id)
                if prior == nil, let previous, b < previous.blocks.count, previous.blocks[b].table != nil, block.table != nil {
                    prior = previous.blocks[b]
                }
                layout = LayoutEngine.layout(block, typesetter: typesetter, measure: measure, wideWidth: wideWidth,
                                             previous: prior, growOnly: growOnlyEntry == i, codeOptions: codeOptions)
                cache.insert(layout, for: key)
                stats.blocksLaidOut += 1
            }
            blocks.append(layout)
        }
        let layout = EntryLayout(id: entry.id, blocks: blocks, spacesFirstBlock: i > 0)
        layouts[i] = layout
        tree.update(i, height: Double(layout.height))
        stats.entriesLaidOut += 1
        return layout
    }

    /// Lays out every entry intersecting `range` (document y) and returns
    /// them placed. Heights measured here move the entries after them.
    public func layoutIfNeeded(in range: ClosedRange<CGFloat>) -> [PlacedEntry] {
        guard tree.count > 0 else { return [] }
        var i = tree.index(at: Double(range.lowerBound)) ?? 0
        var result: [PlacedEntry] = []
        while i < tree.count {
            let y = CGFloat(tree.y(of: i))
            if y > range.upperBound { break }
            var layout = ensureLayout(i)
            if moveCodeWindows(i, layout, entryY: y, visible: range) { layout = ensureLayout(i) }
            if layout.hasTable {
                // Measure the table rows on screen; the ones above keep
                // their heights, so the entry's top does not move.
                for (b, block) in layout.blocks.enumerated() {
                    guard let table = block.table else { continue }
                    let top = y + layout.blockTops[b]
                    table.realizeRows(in: (range.lowerBound - top)...(range.upperBound - top))
                    sync(i, layout)
                }
            }
            result.append(PlacedEntry(index: i, y: y, layout: layout))
            i += 1
        }
        return result
    }

    /// Lays out the whole document and measures every table row
    /// (benchmarks, scroll-to-end measurement).
    public func layoutAll() {
        for i in 0..<tree.count {
            let layout = ensureLayout(i)
            guard layout.hasTable else { continue }
            for block in layout.blocks { block.table?.measureAll() }
            sync(i, layout)
        }
    }

    /// Carries height changes of an entry's tables (rows measured on
    /// demand) into the height tree.
    private func sync(_ i: Int, _ layout: EntryLayout) {
        guard layout.hasTable, layout.refresh() else { return }
        tree.update(i, height: Double(layout.height))
    }

    /// Placed layout of one entry.
    public func placed(_ i: Int) -> PlacedEntry {
        PlacedEntry(index: i, y: CGFloat(tree.y(of: i)), layout: ensureLayout(i))
    }

    // MARK: Geometry

    /// Document x of a block's leading edge.
    public func x(of block: BlockLayout) -> CGFloat { textOrigin + block.indent }

    /// Frame of the cell at `position` in document coordinates. A table
    /// row that is not typeset yet is typeset first, so the frame is exact.
    public func cellFrame(at position: DisplayPosition) -> CGRect {
        let entry = ensureLayout(position.entry)
        let block = entry.blocks[position.block]
        var frame = block.cellFrame(position.cell)
        sync(position.entry, entry)
        frame.origin.x += x(of: block) - codeScrollOffset(of: block)
        frame.origin.y += CGFloat(tree.y(of: position.entry)) + entry.blockTops[position.block]
        return frame
    }

    public func cell(at position: DisplayPosition) -> CellLayout {
        let entry = ensureLayout(position.entry)
        let cell = entry.blocks[position.block].cell(position.cell)
        sync(position.entry, entry)
        return cell
    }

    /// Caret rect for a display position, in document coordinates.
    public func caretRect(at position: DisplayPosition, upstream: Bool = false) -> CGRect {
        let frame = cellFrame(at: position)
        let cell = self.cell(at: position)
        var rect = CaretGeometry.rect(for: position.offset, in: cell, upstream: upstream)
        rect.origin.x += frame.minX
        rect.origin.y += frame.minY
        return rect
    }

    /// Caret rect for an absolute source offset.
    public func caretRect(forSource offset: Int) -> CGRect? {
        guard let position = projection.position(forSource: offset) else { return nil }
        return caretRect(at: position)
    }

    /// Display position nearest `point` (document coordinates).
    public func position(at point: CGPoint) -> DisplayPosition? {
        guard let i = tree.index(at: Double(point.y)) else { return nil }
        let entry = ensureLayout(i)
        let localY = point.y - CGFloat(tree.y(of: i))
        let b = entry.blockIndex(atY: localY)
        let block = entry.blocks[b]
        let blockPoint = CGPoint(x: point.x - x(of: block) + codeScrollOffset(of: block), y: localY - entry.blockTops[b])
        // Typesets the table rows it walks through; measuring a row moves
        // only the blocks and entries after it, never this block's top.
        let c = block.cellIndex(at: blockPoint)
        let frame = block.cellFrame(c)
        let cell = block.cell(c)
        sync(i, entry)
        let cellPoint = CGPoint(x: blockPoint.x - frame.minX, y: blockPoint.y - frame.minY)
        let offset = CaretGeometry.offset(at: cellPoint, in: cell)
        return DisplayPosition(entry: i, block: b, cell: c, offset: offset)
    }

    /// Source offset nearest `point`.
    public func sourceOffset(at point: CGPoint) -> Int? {
        guard let position = position(at: point) else { return nil }
        return projection.sourceOffset(for: position)
    }
}
