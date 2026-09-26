import Foundation
import LipiLayout
import Testing

@Suite("Height tree")
struct HeightTreeTests {
    @Test func prefixSumsAndLookup() {
        var tree = HeightTree(heights: [10, 20, 30])
        #expect(tree.count == 3 && tree.total == 60)
        #expect(tree.y(of: 0) == 0 && tree.y(of: 1) == 10 && tree.y(of: 2) == 30)
        #expect(tree.index(at: -1) == 0)
        #expect(tree.index(at: 0) == 0)
        #expect(tree.index(at: 9.9) == 0)
        #expect(tree.index(at: 10) == 1)
        #expect(tree.index(at: 29.9) == 1)
        #expect(tree.index(at: 30) == 2)
        #expect(tree.index(at: 1000) == 2)
        tree.update(1, height: 5)
        #expect(tree.total == 45 && tree.y(of: 2) == 15)
        #expect(tree.index(at: 12) == 1 && tree.index(at: 15) == 2)
        tree.replace(with: [1, 1])
        #expect(tree.count == 2 && tree.total == 2 && tree.index(at: 1) == 1)
        #expect(HeightTree().index(at: 0) == nil)
        #expect(HeightTree().total == 0)
    }

    @Test func matchesALinearScan() {
        var rng = SystemRandomNumberGenerator()
        let heights = (0..<1000).map { _ in Double(Int.random(in: 1...80, using: &rng)) }
        var tree = HeightTree(heights: heights)
        var prefix = 0.0
        var y = 0.0
        while y < tree.total {
            let expected = heights.indices.first { i in
                let start = heights[..<i].reduce(0, +)
                return y >= start && y < start + heights[i]
            }
            #expect(tree.index(at: y) == expected)
            y += 37.5
        }
        for i in stride(from: 0, to: 1000, by: 97) { tree.update(i, height: 200) }
        for i in 0..<1000 {
            #expect(tree.y(of: i) == prefix)
            prefix += tree.height(at: i)
        }
        #expect(tree.total == prefix)
    }
}
