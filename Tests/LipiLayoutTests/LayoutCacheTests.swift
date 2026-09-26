import Foundation
import LipiCore
import LipiLayout
import Testing

@Suite("Layout cache")
struct LayoutCacheTests {
    func layout(_ i: Int) -> BlockLayout {
        layoutBlock("paragraph \(i)")
    }

    @Test func keysQuantiseWidthToQuarterPoints() {
        let a = LayoutKey(layoutKey: 1, width: 400.05, themeRevision: 0)
        let b = LayoutKey(layoutKey: 1, width: 400.1, themeRevision: 0)
        let c = LayoutKey(layoutKey: 1, width: 400.5, themeRevision: 0)
        let d = LayoutKey(layoutKey: 1, width: 400.05, themeRevision: 1)
        #expect(a == b && a != c && a != d)
    }

    @Test func hitsMissesAndInvalidation() {
        let cache = LayoutCache(capacity: 8)
        let first = layout(1)
        let key = LayoutKey(layoutKey: first.layoutKey, width: 480, themeRevision: 0)
        #expect(cache.layout(for: key) == nil)
        cache.insert(first, for: key)
        #expect(cache.layout(for: key) === first)
        #expect(cache.hits == 1 && cache.misses == 1)
        #expect(cache.previousLayout(of: first.id) === first)
        let wider = LayoutKey(layoutKey: first.layoutKey, width: 600, themeRevision: 0)
        #expect(cache.layout(for: wider) == nil)
        cache.invalidate(first.id)
        #expect(cache.layout(for: key) == nil)
        #expect(cache.previousLayout(of: first.id) == nil)
        cache.insert(first, for: key)
        cache.removeAll()
        #expect(cache.count == 0)
    }

    @Test func evictsLeastRecentlyUsed() {
        let cache = LayoutCache(capacity: 8)
        var keys: [LayoutKey] = []
        for i in 0..<8 {
            let l = layout(i)
            let key = LayoutKey(layoutKey: UInt64(i), width: 480, themeRevision: 0)
            keys.append(key)
            cache.insert(l, for: key)
        }
        // Touch the first four so the untouched ones are the victims.
        for key in keys.prefix(4) { _ = cache.layout(for: key) }
        cache.insert(layout(99), for: LayoutKey(layoutKey: 99, width: 480, themeRevision: 0))
        #expect(cache.count <= 8)
        for key in keys.prefix(4) { #expect(cache.layout(for: key) != nil) }
        #expect(keys[4..<8].filter { cache.layout(for: $0) == nil }.count >= 2)
    }
}
