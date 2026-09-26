import AppKit

/// Writing modes (§6.12): focus (F8) dims everything but the block around
/// the caret; typewriter (F9) keeps the caret line at mid-height.
extension EditorView {
    /// How strongly focus mode fades the text outside the focused block:
    /// the background is painted over it at this opacity.
    public static let focusDimming: CGFloat = 0.7

    @objc public func toggleFocusMode(_ sender: Any?) { focusMode.toggle() }
    @objc public func toggleTypewriterMode(_ sender: Any?) { typewriterMode.toggle() }

    /// The rows focus mode leaves undimmed (document coordinates, full
    /// width): the caret's block, or the caret's line between blocks.
    public func focusBand(visible: CGRect) -> CGRect {
        var band = CGRect.null
        if let scope = controller.focusScope {
            for rect in controller.rects(forSource: scope, visible: visible) { band = band.union(rect) }
        }
        if band.isNull { band = controller.caretRect(forSource: controller.caret) }
        return CGRect(x: bounds.minX, y: band.minY, width: bounds.width, height: band.height)
    }

    /// Paints the background at `focusDimming` over `dirty` outside the band.
    func dimOutsideFocus(in ctx: CGContext, dirty: CGRect) {
        let band = focusBand(visible: visibleRect.union(dirty))
        var dim = controller.theme.colors.bg
        dim.alpha = Double(Self.focusDimming)
        ctx.setFillColor(dim.cgColor)
        let above = CGRect(x: dirty.minX, y: dirty.minY, width: dirty.width, height: max(0, band.minY - dirty.minY))
        let below = CGRect(x: dirty.minX, y: max(dirty.minY, band.maxY), width: dirty.width, height: max(0, dirty.maxY - max(dirty.minY, band.maxY)))
        if band.isNull || band.height <= 0 {
            ctx.fill(dirty)
            return
        }
        if above.height > 0 { ctx.fill(above) }
        if below.height > 0 { ctx.fill(below) }
    }

    /// Blank space below the text in typewriter mode, so the last line can
    /// reach mid-height.
    var typewriterPadding: CGFloat {
        guard typewriterMode, let scroll = enclosingScrollView else { return 0 }
        return (scroll.contentSize.height / 2).rounded(.up)
    }

    /// Scrolls so the caret's line sits at the middle of the viewport (as
    /// far as the document's top allows).
    public func centerCaret(_ caretRect: CGRect? = nil) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let rect = caretRect ?? controller.caretRect(forSource: controller.caret)
        var origin = clip.bounds.origin
        origin.y = (rect.midY - clip.bounds.height / 2).rounded()
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }
}
