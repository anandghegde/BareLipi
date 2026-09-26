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
/// incrementally from its previous layout after an edit.
public final class LayoutCache {
    private struct Entry {
        var layout: BlockLayout
        var lastUse: UInt64
    }

    private var entries: [LayoutKey: Entry] = [:]
    private var byNode: [NodeID: LayoutKey] = [:]
    private var clock: UInt64 = 0
    public let capacity: Int
    public private(set) var hits = 0
    public private(set) var misses = 0

    public init(capacity: Int = 600) {
        self.capacity = capacity
    }

    public var count: Int { entries.count }

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
        guard let key = byNode[id] else { return nil }
        return entries[key]?.layout
    }

    public func insert(_ layout: BlockLayout, for key: LayoutKey) {
        clock += 1
        entries[key] = Entry(layout: layout, lastUse: clock)
        byNode[layout.id] = key
        if entries.count > capacity { evict() }
    }

    public func invalidate(_ id: NodeID) {
        guard let key = byNode.removeValue(forKey: id) else { return }
        entries.removeValue(forKey: key)
    }

    public func removeAll() {
        entries.removeAll()
        byNode.removeAll()
    }

    /// Drops the least recently used quarter.
    private func evict() {
        let victims = entries.sorted { $0.value.lastUse < $1.value.lastUse }.prefix(capacity / 4)
        for (key, entry) in victims {
            entries.removeValue(forKey: key)
            if byNode[entry.layout.id] == key { byNode.removeValue(forKey: entry.layout.id) }
        }
    }
}
