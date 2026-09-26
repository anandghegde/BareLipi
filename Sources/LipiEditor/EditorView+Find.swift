import AppKit
import LipiCore

extension EditorView {
    /// Fills every visible match of the active find session under the text;
    /// the current match (the selection) gets the stronger colour.
    func drawFindHighlights(in ctx: CGContext, dirty: CGRect) {
        guard let find = findSession, find.isActive, !find.query.isEmpty else { return }
        let projection = controller.projection
        var lo = 0, hi = controller.count
        if let top = controller.sourceOffset(at: CGPoint(x: 0, y: dirty.minY)), let e = projection.entryIndex(containing: top) {
            lo = projection.entries[e].start
        }
        if let bottom = controller.sourceOffset(at: CGPoint(x: bounds.maxX, y: dirty.maxY)), let e = projection.entryIndex(containing: bottom) {
            hi = projection.entries[e].start + projection.entries[e].length
        }
        let visible = find.matches(intersecting: lo..<max(hi, lo + 1))
        guard !visible.isEmpty else { return }
        let current = controller.selection.range
        let dark = controller.theme.isDark
        let all = NSColor.systemYellow.withAlphaComponent(dark ? 0.28 : 0.35).cgColor
        let strong = NSColor.systemOrange.withAlphaComponent(dark ? 0.55 : 0.5).cgColor
        for match in visible {
            ctx.setFillColor(match == current ? strong : all)
            for rect in controller.rects(forSource: match, visible: dirty) where rect.intersects(dirty) {
                ctx.fill(rect.insetBy(dx: -1, dy: 0))
            }
        }
    }
}
