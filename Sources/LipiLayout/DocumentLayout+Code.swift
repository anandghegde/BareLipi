import CoreGraphics
import Foundation
import LipiCore
import LipiHighlight

/// Code block state kept by the document layout: header hit testing,
/// sideways scrolling of unwrapped code, and the highlight windows of very
/// long fences (§6.5).
extension DocumentLayout {
    /// A block under a document point, with the point in block coordinates.
    struct BlockHit {
        var entry: Int
        var block: Int
        var layout: BlockLayout
        var local: CGPoint
    }

    func blockHit(at point: CGPoint) -> BlockHit? {
        guard let i = entryIndex(atY: point.y) else { return nil }
        let entry = ensureLayout(i)
        let localY = point.y - y(ofEntry: i)
        let b = entry.blockIndex(atY: localY)
        let block = entry.blocks[b]
        let local = CGPoint(x: point.x - x(of: block), y: localY - entry.blockTops[b])
        guard local.y >= 0, local.y <= block.height, local.x >= 0, local.x <= block.width else { return nil }
        return BlockHit(entry: i, block: b, layout: block, local: local)
    }

    /// The header button of a code block under `point` (document coordinates).
    public func codeHeaderButton(at point: CGPoint) -> (entry: Int, block: Int, button: CodeHeaderButton)? {
        guard let hit = blockHit(at: point),
              let header = LayoutEngine.codeHeader(of: hit.layout, typesetter: typesetter, options: codeOptions) else { return nil }
        for item in header.buttons where item.rect.insetBy(dx: -2, dy: -2).contains(hit.local) {
            return (hit.entry, hit.block, item.button)
        }
        return nil
    }

    /// Header button rects of the code blocks in `placed`, in document
    /// coordinates (cursor rects, accessibility).
    public func codeHeaderButtons(in placed: [PlacedEntry]) -> [(rect: CGRect, button: CodeHeaderButton)] {
        var result: [(rect: CGRect, button: CodeHeaderButton)] = []
        for entry in placed {
            for (b, block) in entry.layout.blocks.enumerated() {
                guard let header = LayoutEngine.codeHeader(of: block, typesetter: typesetter, options: codeOptions) else { continue }
                let origin = CGPoint(x: x(of: block), y: entry.y + entry.layout.blockTops[b])
                for item in header.buttons { result.append((item.rect.offsetBy(dx: origin.x, dy: origin.y), item.button)) }
            }
        }
        return result
    }

    // MARK: Unwrapped code

    /// How far an unwrapped code block is scrolled sideways (0 when it wraps).
    public func codeScrollOffset(of block: BlockLayout) -> CGFloat {
        guard let chrome = block.code, !chrome.wraps, let offset = codeScroll[block.id] else { return 0 }
        return min(max(0, offset), maxCodeScroll(block, chrome))
    }

    private func maxCodeScroll(_ block: BlockLayout, _ chrome: CodeChrome) -> CGFloat {
        max(0, block.cellFrame(0).width - chrome.viewportWidth)
    }

    /// Scrolls the unwrapped code block under `point` sideways by `dx`.
    /// Returns whether it moved.
    @discardableResult
    public func scrollCode(at point: CGPoint, by dx: CGFloat) -> Bool {
        guard let hit = blockHit(at: point), let chrome = hit.layout.code, !chrome.wraps else { return false }
        let old = codeScrollOffset(of: hit.layout)
        let new = min(max(0, old + dx), maxCodeScroll(hit.layout, chrome))
        codeScroll[hit.layout.id] = new
        return new != old
    }

    /// Whether `point` is over a code block that scrolls sideways.
    public func isOverScrollableCode(_ point: CGPoint) -> Bool {
        guard let hit = blockHit(at: point), let chrome = hit.layout.code, !chrome.wraps else { return false }
        return maxCodeScroll(hit.layout, chrome) > 0
    }

    /// Scrolls an unwrapped code block so the caret at `position` shows.
    /// Returns whether it moved.
    @discardableResult
    public func revealCodeCaret(at position: DisplayPosition) -> Bool {
        guard position.entry < projection.entries.count else { return false }
        let entry = ensureLayout(position.entry)
        guard position.block < entry.blocks.count else { return false }
        let block = entry.blocks[position.block]
        guard let chrome = block.code, !chrome.wraps else { return false }
        let x = CaretGeometry.rect(for: position.offset, in: block.cell(position.cell), upstream: false).minX
        let old = codeScrollOffset(of: block)
        let margin = min(scale.l(24), chrome.viewportWidth / 4)
        var new = old
        if x - new < 0 { new = x - margin }
        if x - new > chrome.viewportWidth - 2 { new = x - chrome.viewportWidth + margin }
        new = min(max(0, new), maxCodeScroll(block, chrome))
        codeScroll[block.id] = new
        return new != old
    }

    // MARK: Carrying state across edits

    /// Re-parsed blocks come back with new ids: hand the highlight window
    /// and sideways scroll of each changed block to its successor at the
    /// same place, and forget those of blocks that are gone.
    func carryCodeState(from old: Projection, to new: Projection, changed: [Int], oldByID: [NodeID: Int], sameShape: Bool) {
        guard !typesetter.codeWindows.isEmpty || !codeScroll.isEmpty else { return }
        for i in changed where i < new.entries.count {
            guard let j = oldByID[new.entries[i].id] ?? (sameShape && i < old.entries.count ? i : nil), j < old.entries.count else { continue }
            let before = old.entries[j].blocks, after = new.entries[i].blocks
            for k in 0..<min(before.count, after.count) where before[k].id != after[k].id {
                if let window = typesetter.codeWindows[before[k].id] { typesetter.codeWindows[after[k].id] = window }
                if let offset = codeScroll[before[k].id] { codeScroll[after[k].id] = offset }
            }
        }
        // Pruned only once it has grown, so typing never pays for a walk.
        guard typesetter.codeWindows.count + codeScroll.count > 64 else { return }
        var live = Set<NodeID>()
        for entry in new.entries { for block in entry.blocks { live.insert(block.id) } }
        typesetter.codeWindows = typesetter.codeWindows.filter { live.contains($0.key) }
        codeScroll = codeScroll.filter { live.contains($0.key) }
    }

    // MARK: Highlight windows

    /// Moves the highlight window of each very long fence of entry `i` to
    /// cover `visible` plus one screen either side (§6.5), in chunks so
    /// scrolling re-highlights rarely. Returns whether the entry must be
    /// laid out again.
    func moveCodeWindows(_ i: Int, _ layout: EntryLayout, entryY: CGFloat, visible: ClosedRange<CGFloat>) -> Bool {
        var moved = false
        for (b, block) in layout.blocks.enumerated() {
            guard let chrome = block.code, chrome.lineStarts.count > HighlightService.windowedLineThreshold else { continue }
            let cell = block.cell(0)
            let top = entryY + layout.blockTops[b] + block.cellFrame(0).minY
            let screen = visible.upperBound - visible.lowerBound
            let first = codeLine(atFragment: cell.lineIndex(atY: visible.lowerBound - screen - top), chrome.lineStarts)
            let last = codeLine(atFragment: cell.lineIndex(atY: visible.upperBound + screen - top), chrome.lineStarts)
            let current = typesetter.codeWindows[block.id] ?? 0..<Typesetter.codeWindowLines
            guard first < current.lowerBound || last + 1 > current.upperBound else { continue }
            typesetter.codeWindows[block.id] = Self.codeWindow(covering: first...last)
            moved = true
        }
        if moved { layouts[i] = nil }
        return moved
    }

    /// The code line whose fragments include cell line `fragment`.
    private func codeLine(atFragment fragment: Int, _ starts: [Int]) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= fragment { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// A window of whole 512-line chunks, at least `codeWindowLines` long,
    /// covering `lines`.
    static func codeWindow(covering lines: ClosedRange<Int>) -> Range<Int> {
        let chunk = 512
        let lower = (lines.lowerBound / chunk) * chunk
        let upper = max(lower + Typesetter.codeWindowLines, ((lines.upperBound + chunk) / chunk) * chunk)
        return lower..<upper
    }
}
