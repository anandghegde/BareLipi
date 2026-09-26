import Foundation
import LipiCore

/// Cache key: the block's content hash (role, context, reveal, cells and
/// runs), the width it was laid out for, and the theme revision.
public struct LayoutKey: Hashable, Sendable {
    public var layoutKey: UInt64
    public var widthQuarterPoints: Int32
    public var themeRevision: UInt32

    public init(layoutKey: UInt64, width: CGFloat, themeRevision: UInt32) {
        self.layoutKey = layoutKey
        self.widthQuarterPoints = Int32((width * 4).rounded())
        self.themeRevision = themeRevision
    }
}

/// Bounded LRU of `BlockLayout`s (§7.5: evicts beyond about four screens).
/// Layouts are also findable by node id so a table can be re-laid out
/// incrementally from its previous layout after an edit. The bound is on
/// entries and on weight (lines laid out), so a 600 × 6 table counts as
/// thousands of paragraphs, and a node keeps at most two versions (its
/// folded and revealed layouts), so typing in a block does not pile up
/// one layout per keystroke.
public final class LayoutCache {
    private struct Entry {
        var layout: BlockLayout
        var lastUse: UInt64
        var weight: Int
    }

    private var entries: [LayoutKey: Entry] = [:]
    /// Keys of a node's cached layouts, most recent last.
    private var byNode: [NodeID: [LayoutKey]] = [:]
    private var clock: UInt64 = 0
    public let capacity: Int
    /// Upper bound on the total number of lines held.
    public let weightCapacity: Int
    public private(set) var weight = 0
    public private(set) var hits = 0
    public private(set) var misses = 0

    public init(capacity: Int = 600, weightCapacity: Int = 20_000) {
        self.capacity = capacity
        self.weightCapacity = weightCapacity
    }

    public var count: Int { entries.count }

    static func weight(of layout: BlockLayout) -> Int {
        layout.cells.reduce(0) { $0 + max(1, $1.lines.count) }
    }

    public func layout(for key: LayoutKey) -> BlockLayout? {
        clock += 1
        guard var entry = entries[key] else { misses += 1; return nil }
        hits += 1
        entry.lastUse = clock
        entries[key] = entry
        return entry.layout
    }

    /// The most recent layout of node `id` regardless of key.
    public func previousLayout(of id: NodeID) -> BlockLayout? {
        guard let key = byNode[id]?.last else { return nil }
        return entries[key]?.layout
    }

    public func insert(_ layout: BlockLayout, for key: LayoutKey) {
        clock += 1
        remove(key)
        let w = LayoutCache.weight(of: layout)
        entries[key] = Entry(layout: layout, lastUse: clock, weight: w)
        weight += w
        var keys = byNode[layout.id] ?? []
        keys.append(key)
        while keys.count > 2 { remove(keys.removeFirst()) }
        byNode[layout.id] = keys
        if entries.count > capacity || weight > weightCapacity { evict() }
    }

    public func invalidate(_ id: NodeID) {
        guard let keys = byNode.removeValue(forKey: id) else { return }
        for key in keys { removeEntry(key) }
    }

    public func removeAll() {
        entries.removeAll()
        byNode.removeAll()
        weight = 0
    }

    private func removeEntry(_ key: LayoutKey) {
        if let entry = entries.removeValue(forKey: key) { weight -= entry.weight }
    }

    private func remove(_ key: LayoutKey) {
        guard let entry = entries[key] else { return }
        removeEntry(key)
        if var keys = byNode[entry.layout.id] {
            keys.removeAll { $0 == key }
            if keys.isEmpty { byNode.removeValue(forKey: entry.layout.id) } else { byNode[entry.layout.id] = keys }
        }
    }

    /// Drops the least recently used entries: a quarter of the count, and
    /// more until the weight fits three quarters of its bound.
    private func evict() {
        let victims = entries.sorted { $0.value.lastUse < $1.value.lastUse }
        var dropped = 0
        for (key, _) in victims {
            if dropped >= capacity / 4 && weight <= weightCapacity * 3 / 4 { break }
            remove(key)
            dropped += 1
        }
    }
}
