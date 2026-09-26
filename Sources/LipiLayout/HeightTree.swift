/// Prefix sums of block heights (§7.4 step 7). A Fenwick tree: updating one
/// height and finding the y of a block, or the block at a y, are O(log n);
/// inserting or removing blocks rebuilds in O(n), which for the largest
/// documents in §9.1 (60,000 entries) is well under a millisecond.
public struct HeightTree: Sendable {
    private var tree: [Double]
    private var heights: [Double]

    public init(heights: [Double] = []) {
        self.heights = heights
        tree = []
        rebuild()
    }

    public var count: Int { heights.count }
    public var total: Double { count == 0 ? 0 : prefix(count) }

    public func height(at index: Int) -> Double { heights[index] }

    /// y of the top of block `index` (sum of the heights before it).
    public func y(of index: Int) -> Double { prefix(index) }

    /// Sum of the first `n` heights.
    public func prefix(_ n: Int) -> Double {
        var sum = 0.0
        var i = n
        while i > 0 { sum += tree[i]; i -= i & (-i) }
        return sum
    }

    /// The block whose span contains `y` (the last block for y past the end,
    /// the first for negative y); nil when empty.
    public func index(at y: Double) -> Int? {
        guard count > 0 else { return nil }
        if y <= 0 { return 0 }
        var position = 0
        var remaining = y
        var step = 1
        while step * 2 <= count { step *= 2 }
        while step > 0 {
            let next = position + step
            if next <= count, tree[next] <= remaining {
                position = next
                remaining -= tree[next]
            }
            step /= 2
        }
        // `position` blocks have a prefix ≤ y, so y lies in block `position`.
        return min(position, count - 1)
    }

    public mutating func update(_ index: Int, height: Double) {
        let delta = height - heights[index]
        guard delta != 0 else { return }
        heights[index] = height
        var i = index + 1
        while i <= count { tree[i] += delta; i += i & (-i) }
    }

    /// Replaces all heights (structural change: entries added or removed).
    public mutating func replace(with newHeights: [Double]) {
        heights = newHeights
        rebuild()
    }

    private mutating func rebuild() {
        let n = heights.count
        tree = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { tree[i + 1] = heights[i] }
        var i = 1
        while i <= n {
            let j = i + (i & (-i))
            if j <= n { tree[j] += tree[i] }
            i += 1
        }
    }
}
