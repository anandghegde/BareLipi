/// Immutable B-tree node. Persistence comes for free: every edit path-copies
/// the O(log n) nodes it touches and shares the rest, so a snapshot of the
/// rope handed to a background parse is just a retained root pointer.
///
/// Balancing follows xi-rope: leaves hold between `minLeaf` and `maxLeaf`
/// bytes (except a lone root leaf), internal nodes hold between `minChildren`
/// and `maxChildren` children (except the root, which may have two), and all
/// leaves sit at the same depth. `minLeaf` is 511 rather than 512 so that the
/// split window for an oversized leaf is always at least four bytes wide,
/// which guarantees it contains a scalar boundary.
final class RopeNode: @unchecked Sendable {
    static let maxLeaf = 1024
    static let minLeaf = 511
    static let bulkLeaf = 768  // fill target when building from a string
    static let maxChildren = 8
    static let minChildren = 4

    enum Body {
        case leaf(String)
        case internalNode([RopeNode])
    }

    let body: Body
    let summary: TextSummary
    let height: Int

    init(leaf text: String) {
        precondition(text.utf8.count <= RopeNode.maxLeaf, "leaf over maxLeaf")
        body = .leaf(text)
        summary = TextSummary(measuring: text)
        height = 0
    }

    init(children: [RopeNode]) {
        precondition(!children.isEmpty && children.count <= RopeNode.maxChildren)
        let h = children[0].height
        var s = TextSummary.zero
        for c in children {
            precondition(c.height == h, "children at mixed heights")
            s += c.summary
        }
        body = .internalNode(children)
        summary = s
        height = h + 1
    }

    static let empty = RopeNode(leaf: "")

    var isLeaf: Bool { if case .leaf = body { return true } else { return false } }

    var children: [RopeNode] {
        if case .internalNode(let c) = body { return c }
        return []
    }

    var leafText: String {
        if case .leaf(let s) = body { return s }
        preconditionFailure("not a leaf")
    }

    /// True when this node could be a child of a well-formed parent without
    /// violating the minimum-fill invariant.
    var isOkChild: Bool {
        switch body {
        case .leaf(let s): return s.utf8.count >= RopeNode.minLeaf
        case .internalNode(let c): return c.count >= RopeNode.minChildren
        }
    }

    // MARK: - Construction

    /// Builds a balanced tree from text by chunking at scalar boundaries.
    static func build(from text: Substring) -> RopeNode {
        if text.utf8.count <= maxLeaf { return RopeNode(leaf: String(text)) }
        var leaves: [RopeNode] = []
        leaves.reserveCapacity(text.utf8.count / bulkLeaf + 2)
        var rest = text
        while true {
            let n = rest.utf8.count
            if n <= maxLeaf {
                leaves.append(RopeNode(leaf: String(rest)))
                break
            }
            // Fill to 3/4 so the first edits into a chunk rarely split it, but
            // never leave a tail shorter than minLeaf.
            let cut = n - bulkLeaf >= minLeaf
                ? scalarBoundary(in: rest, atOrBefore: bulkLeaf)
                : splitPoint(for: rest)
            let idx = rest.utf8.index(rest.utf8.startIndex, offsetBy: cut)
            leaves.append(RopeNode(leaf: String(rest[..<idx])))
            rest = rest[idx...]
        }
        return fromNodes(leaves)
    }

    /// Packs same-height nodes into a tree, level by level.
    static func fromNodes(_ nodes: [RopeNode]) -> RopeNode {
        precondition(!nodes.isEmpty)
        var level = nodes
        while level.count > 1 {
            var next: [RopeNode] = []
            next.reserveCapacity(level.count / maxChildren + 1)
            var i = 0
            while i < level.count {
                let remaining = level.count - i
                let take: Int
                if remaining <= maxChildren {
                    take = remaining
                } else if remaining - maxChildren < minChildren {
                    // Avoid an underfull tail: split the last two groups evenly.
                    take = remaining / 2
                } else {
                    take = maxChildren
                }
                next.append(RopeNode(children: Array(level[i..<i + take])))
                i += take
            }
            level = next
        }
        return level[0]
    }

    /// Largest scalar boundary `<= target`, avoiding a split between CR and LF
    /// when the alternative is still positive.
    static func scalarBoundary(in text: Substring, atOrBefore target: Int) -> Int {
        let utf8 = text.utf8
        var cut = target
        var idx = utf8.index(utf8.startIndex, offsetBy: cut)
        while cut > 0 && !isScalarBoundary(utf8, idx) {
            cut -= 1
            idx = utf8.index(before: idx)
        }
        if cut > 1 && cut < utf8.count {
            let prev = utf8[utf8.index(before: idx)]
            if prev == 0x0D && utf8[idx] == 0x0A { cut -= 1 }
        }
        return cut
    }

    /// Split point for a leaf longer than `maxLeaf` (and shorter than
    /// `maxLeaf + minLeaf + 4`) such that both halves lie within
    /// `[minLeaf, maxLeaf]`. Prefers to split after a newline.
    static func splitPoint(for text: Substring) -> Int {
        let utf8 = text.utf8
        let n = utf8.count
        precondition(n > maxLeaf)
        let lo = Swift.max(minLeaf, n - maxLeaf)
        let hi = Swift.min(maxLeaf, n - minLeaf)
        precondition(hi - lo >= 3, "split window too narrow for \(n) bytes")
        // Prefer the last newline whose successor position is inside the window.
        var pos = hi
        var idx = utf8.index(utf8.startIndex, offsetBy: hi)
        while pos > lo {
            let before = utf8.index(before: idx)
            if utf8[before] == 0x0A { return pos }
            pos -= 1
            idx = before
        }
        // Otherwise the highest scalar boundary in the window; guaranteed to
        // exist because the window spans at least four positions.
        pos = hi
        idx = utf8.index(utf8.startIndex, offsetBy: hi)
        while pos > lo && !isScalarBoundary(utf8, idx) {
            pos -= 1
            idx = utf8.index(before: idx)
        }
        precondition(isScalarBoundary(utf8, idx), "no scalar boundary in split window")
        // Do not separate CR from LF if the position just before is also usable.
        if pos - 1 >= lo && pos < n {
            let prev = utf8[utf8.index(before: idx)]
            if prev == 0x0D && utf8[idx] == 0x0A { return pos - 1 }
        }
        return pos
    }

    @inline(__always)
    static func isScalarBoundary(_ utf8: Substring.UTF8View, _ idx: Substring.UTF8View.Index) -> Bool {
        idx == utf8.endIndex || (utf8[idx] & 0xC0) != 0x80
    }

    // MARK: - Concatenation

    static func concat(_ a: RopeNode, _ b: RopeNode) -> RopeNode {
        if a.summary.bytes == 0 { return b }
        if b.summary.bytes == 0 { return a }
        let h1 = a.height, h2 = b.height
        if h1 < h2 {
            let bc = b.children
            let merged = concat(a, bc[0])
            if merged.height == h2 - 1 {
                return mergeNodes([merged], Array(bc[1...]))
            }
            return mergeNodes(merged.children, Array(bc[1...]))
        } else if h1 == h2 {
            if a.isOkChild && b.isOkChild {
                return RopeNode(children: [a, b])
            }
            if h1 == 0 {
                return mergeLeaves(a, b)
            }
            return mergeNodes(a.children, b.children)
        } else {
            let ac = a.children
            let merged = concat(ac[ac.count - 1], b)
            if merged.height == h1 - 1 {
                return mergeNodes(Array(ac.dropLast()), [merged])
            }
            return mergeNodes(Array(ac.dropLast()), merged.children)
        }
    }

    private static func mergeNodes(_ l: [RopeNode], _ r: [RopeNode]) -> RopeNode {
        let n = l.count + r.count
        var all = l
        all.append(contentsOf: r)
        if n <= maxChildren {
            return RopeNode(children: all)
        }
        let splitAt = Swift.min(maxChildren, n - minChildren)
        let left = RopeNode(children: Array(all[..<splitAt]))
        let right = RopeNode(children: Array(all[splitAt...]))
        return RopeNode(children: [left, right])
    }

    /// Only called when at least one leaf is shorter than `minLeaf`, so the
    /// joined text is under `maxLeaf + minLeaf` and `splitPoint` applies.
    private static func mergeLeaves(_ a: RopeNode, _ b: RopeNode) -> RopeNode {
        let sa = a.leafText, sb = b.leafText
        let total = sa.utf8.count + sb.utf8.count
        if total <= maxLeaf {
            return RopeNode(leaf: sa + sb)
        }
        var joined = sa
        joined.append(sb)
        let cut = splitPoint(for: joined[...])
        let idx = joined.utf8.index(joined.utf8.startIndex, offsetBy: cut)
        let left = RopeNode(leaf: String(joined[..<idx]))
        let right = RopeNode(leaf: String(joined[idx...]))
        return RopeNode(children: [left, right])
    }

    // MARK: - Fast-path edit

    /// Outcome of a path-copying edit: a replacement node of the same height,
    /// or two nodes when the edited node had to split.
    enum EditResult {
        case one(RopeNode)
        case two(RopeNode, RopeNode)
    }

    /// Path-copying replacement for edits that stay inside one leaf, which is
    /// every keystroke. Returns nil when the general slice-and-concat path is
    /// needed: the range spans leaves, a non-root leaf would become underfull,
    /// or the replacement is too large to split into two leaves.
    static func fastReplace(_ node: RopeNode, _ range: Range<Int>, with text: String, isRoot: Bool) -> EditResult? {
        switch node.body {
        case .leaf(let s):
            let u = s.utf8
            let lo = u.index(u.startIndex, offsetBy: range.lowerBound)
            let hi = u.index(lo, offsetBy: range.count)
            precondition(lo == u.endIndex || (u[lo] & 0xC0) != 0x80, "lower bound splits a scalar")
            precondition(hi == u.endIndex || (u[hi] & 0xC0) != 0x80, "upper bound splits a scalar")
            var edited = String(s[..<lo])
            edited.reserveCapacity(s.utf8.count - range.count + text.utf8.count)
            edited.append(text)
            edited.append(contentsOf: s[hi...])
            let n = edited.utf8.count
            if n <= maxLeaf {
                if n >= minLeaf || isRoot { return .one(RopeNode(leaf: edited)) }
                return nil
            }
            // splitPoint needs a window of at least three positions.
            guard n <= 2 * maxLeaf - 3 else { return nil }
            let cut = splitPoint(for: edited[...])
            let idx = edited.utf8.index(edited.utf8.startIndex, offsetBy: cut)
            return .two(RopeNode(leaf: String(edited[..<idx])), RopeNode(leaf: String(edited[idx...])))

        case .internalNode(let kids):
            var offset = 0
            for (i, child) in kids.enumerated() {
                let len = child.summary.bytes
                let end = offset + len
                let isLast = i == kids.count - 1
                if range.lowerBound < end || (isLast && range.lowerBound == end) {
                    guard range.upperBound <= end else { return nil }
                    let local = (range.lowerBound - offset)..<(range.upperBound - offset)
                    guard let result = fastReplace(child, local, with: text, isRoot: false) else { return nil }
                    var newKids = kids
                    switch result {
                    case .one(let n):
                        newKids[i] = n
                    case .two(let a, let b):
                        newKids[i] = a
                        newKids.insert(b, at: i + 1)
                    }
                    if newKids.count <= maxChildren { return .one(RopeNode(children: newKids)) }
                    let splitAt = newKids.count - minChildren
                    return .two(
                        RopeNode(children: Array(newKids[..<splitAt])),
                        RopeNode(children: Array(newKids[splitAt...])))
                }
                offset = end
            }
            return nil
        }
    }

    // MARK: - Slicing

    /// The rope covering `range` (bytes, scalar-aligned) of this node.
    func slice(_ range: Range<Int>) -> RopeNode {
        if range.lowerBound == 0 && range.upperBound == summary.bytes { return self }
        if range.isEmpty { return RopeNode.empty }
        switch body {
        case .leaf(let s):
            let u = s.utf8
            let lo = u.index(u.startIndex, offsetBy: range.lowerBound)
            let hi = u.index(lo, offsetBy: range.count)
            precondition(lo == u.endIndex || (u[lo] & 0xC0) != 0x80, "lower bound splits a scalar")
            precondition(hi == u.endIndex || (u[hi] & 0xC0) != 0x80, "upper bound splits a scalar")
            return RopeNode(leaf: String(s[lo..<hi]))
        case .internalNode(let kids):
            var acc: RopeNode? = nil
            var offset = 0
            for child in kids {
                let len = child.summary.bytes
                let childRange = offset..<offset + len
                if childRange.upperBound > range.lowerBound && childRange.lowerBound < range.upperBound {
                    let lo = Swift.max(range.lowerBound, childRange.lowerBound) - offset
                    let hi = Swift.min(range.upperBound, childRange.upperBound) - offset
                    let piece = child.slice(lo..<hi)
                    acc = acc.map { RopeNode.concat($0, piece) } ?? piece
                }
                offset += len
                if offset >= range.upperBound { break }
            }
            return acc ?? RopeNode.empty
        }
    }

    // MARK: - Traversal

    /// Visits each leaf's text in order, optionally restricted to a byte range.
    func forEachLeaf(in range: Range<Int>? = nil, _ visit: (Substring) throws -> Void) rethrows {
        switch body {
        case .leaf(let s):
            guard let range else { try visit(s[...]); return }
            let u = s.utf8
            let lo = u.index(u.startIndex, offsetBy: range.lowerBound)
            let hi = u.index(lo, offsetBy: range.count)
            try visit(s[lo..<hi])
        case .internalNode(let kids):
            guard let range else {
                for k in kids { try k.forEachLeaf(in: nil, visit) }
                return
            }
            var offset = 0
            for child in kids {
                let len = child.summary.bytes
                let lo = Swift.max(range.lowerBound, offset)
                let hi = Swift.min(range.upperBound, offset + len)
                if lo < hi { try child.forEachLeaf(in: lo - offset..<hi - offset, visit) }
                offset += len
                if offset >= range.upperBound { break }
            }
        }
    }

    /// Structural check used by tests.
    func validate(isRoot: Bool = true) -> [String] {
        var problems: [String] = []
        switch body {
        case .leaf(let s):
            let n = s.utf8.count
            if n > RopeNode.maxLeaf { problems.append("leaf \(n) bytes > max") }
            if !isRoot && n < RopeNode.minLeaf { problems.append("leaf \(n) bytes < min") }
            if TextSummary(measuring: s) != summary { problems.append("leaf summary mismatch") }
        case .internalNode(let kids):
            if kids.count > RopeNode.maxChildren { problems.append("node has \(kids.count) children > max") }
            if !isRoot && kids.count < RopeNode.minChildren { problems.append("node has \(kids.count) children < min") }
            if isRoot && kids.count < 2 { problems.append("root has \(kids.count) child") }
            var s = TextSummary.zero
            for k in kids {
                if k.height != height - 1 { problems.append("child height \(k.height) under \(height)") }
                s += k.summary
                problems.append(contentsOf: k.validate(isRoot: false))
            }
            if s != summary { problems.append("internal summary mismatch") }
        }
        return problems
    }
}
