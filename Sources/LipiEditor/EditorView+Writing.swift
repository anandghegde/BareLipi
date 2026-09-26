import AppKit
import QuartzCore

/// What focus mode keeps bright (§6.12, Settings → Editing → Focus scope).
public enum FocusScopeKind: String, Sendable, CaseIterable {
    case block
    case sentence
}

/// Writing-mode settings and the focus transition in flight.
@MainActor
final class WritingModeState {
    /// A focused region: everything (focus off) or a scope (nil: the caret line).
    enum Region: Equatable {
        case all
        case scope(Range<Int>?)
    }

    struct Transition {
        var from: Region
        var to: Region
        var start: CFTimeInterval
        var duration: CFTimeInterval
    }

    var scopeKind: FocusScopeKind = .block
    var typewriterFraction: CGFloat = 0.5
    var typewriterEases = false
    /// The scope focus mode showed last, to notice the caret leaving it.
    var lastScope: Range<Int>??
    var transition: Transition?
    var timer: Timer?
    /// The clock transitions run on (tests replace it).
    var clock: () -> CFTimeInterval = { CACurrentMediaTime() }
    /// Transitions run only in a window unless this is set (tests).
    var animatesOffscreen = false

    /// Eased progress (ease-out) of `t`, 0...1.
    func progress(_ t: Transition) -> CGFloat {
        guard t.duration > 0 else { return 1 }
        let x = min(max((clock() - t.start) / t.duration, 0), 1)
        return CGFloat(1 - pow(1 - x, 3))
    }
}

/// Writing modes (§6.12): focus (F8) dims everything but the block or
/// sentence around the caret; typewriter (F9) holds the caret line at a
/// fixed fraction of the viewport height.
extension EditorView {
    /// How strongly focus mode fades the text outside the focused block:
    /// the background is painted over it at this opacity (text at 30 %).
    public static let focusDimming: CGFloat = 0.7
    /// Focus fades in, out and between scopes over this long (0 under Reduce Motion).
    public static let focusTransitionDuration: TimeInterval = 0.12
    /// Where typewriter mode may hold the caret line, as a fraction of the viewport.
    public static let typewriterRange: ClosedRange<CGFloat> = 0.3...0.7
    /// The optional typewriter scroll ease.
    public static let typewriterEaseDuration: TimeInterval = 0.08

    @objc public func toggleFocusMode(_ sender: Any?) { focusMode.toggle() }
    @objc public func toggleTypewriterMode(_ sender: Any?) { typewriterMode.toggle() }

    /// Block or sentence focus.
    public var focusScopeKind: FocusScopeKind {
        get { writingState.scopeKind }
        set {
            guard newValue != writingState.scopeKind else { return }
            writingState.scopeKind = newValue
            if focusMode { focusScopeMayHaveChanged(textChanged: false) }
            needsDisplay = true
        }
    }

    /// The caret line's height in the viewport in typewriter mode, 30–70 %
    /// (default 50 %).
    public var typewriterFraction: CGFloat {
        get { writingState.typewriterFraction }
        set {
            let f = min(max(newValue, Self.typewriterRange.lowerBound), Self.typewriterRange.upperBound)
            guard abs(f - writingState.typewriterFraction) > 0.0001 else { return }
            writingState.typewriterFraction = f
            guard typewriterMode else { return }
            syncFrameHeight()
            centerCaret()
        }
    }

    /// Typewriter scrolling eases over 80 ms instead of jumping (never under
    /// Reduce Motion).
    public var typewriterEases: Bool {
        get { writingState.typewriterEases }
        set { writingState.typewriterEases = newValue }
    }

    /// Whether a focus fade is running.
    public var isFocusTransitioning: Bool { writingState.transition != nil }

    // MARK: Focus

    /// The rows focus mode leaves undimmed (document coordinates, full
    /// width): the scope's rows, or the caret's line between blocks.
    public func focusBand(visible: CGRect) -> CGRect {
        band(of: controller.focusScope(focusScopeKind), visible: visible)
    }

    private func band(of scope: Range<Int>?, visible: CGRect) -> CGRect {
        var band = CGRect.null
        if let scope {
            for rect in controller.rects(forSource: scope, visible: visible) { band = band.union(rect) }
        }
        if band.isNull { band = controller.caretRect(forSource: controller.caret) }
        return CGRect(x: bounds.minX, y: band.minY, width: bounds.width, height: band.height)
    }

    /// The undimmed rects of a region: a full-width band for a block, the
    /// sentence's own line rects for a sentence; nil for everything.
    private func rects(of region: WritingModeState.Region, visible: CGRect) -> [CGRect]? {
        guard case .scope(let scope) = region else { return nil }
        if focusScopeKind == .sentence, let scope {
            let rects = controller.rects(forSource: scope, visible: visible)
            if !rects.isEmpty { return rects }
        }
        return [band(of: scope, visible: visible)]
    }

    func focusModeDidChange() {
        let scope = controller.focusScope(focusScopeKind)
        let previous = writingState.lastScope
        writingState.lastScope = focusMode ? .some(scope) : nil
        if focusMode {
            startFocusTransition(from: .all, to: .scope(scope))
        } else {
            startFocusTransition(from: .scope(previous ?? scope), to: .all)
        }
        needsDisplay = true
    }

    /// After a change with focus on: moving the caret into another scope
    /// fades between the two; typing only follows the scope as it grows.
    func focusScopeMayHaveChanged(textChanged: Bool) {
        let scope = controller.focusScope(focusScopeKind)
        guard let last = writingState.lastScope, last != scope else {
            writingState.lastScope = .some(scope)
            return
        }
        writingState.lastScope = .some(scope)
        if textChanged {
            writingState.transition = nil
            return
        }
        startFocusTransition(from: .scope(last), to: .scope(scope))
    }

    private func startFocusTransition(from: WritingModeState.Region, to: WritingModeState.Region) {
        let duration = displayOptions.duration(Self.focusTransitionDuration)
        guard duration > 0, window != nil || writingState.animatesOffscreen else {
            writingState.transition = nil
            return
        }
        writingState.transition = .init(from: from, to: to, start: writingState.clock(), duration: duration)
        guard writingState.timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.focusTransitionTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        writingState.timer = timer
    }

    /// Redraws while the fade runs; ends it when done.
    func focusTransitionTick() {
        needsDisplay = true
        if let t = writingState.transition, writingState.progress(t) < 1 { return }
        writingState.transition = nil
        writingState.timer?.invalidate()
        writingState.timer = nil
    }

    /// Paints the background over `dirty` outside the focused region, at
    /// `focusDimming`, or part way during a transition.
    func dimOutsideFocus(in ctx: CGContext, dirty: CGRect) {
        let visible = visibleRect.union(dirty)
        let alpha = Self.focusDimming
        guard let t = writingState.transition else {
            let focused = rects(of: .scope(controller.focusScope(focusScopeKind)), visible: visible) ?? []
            fillDim(ctx, dirty: dirty, alpha: alpha, clip: nil, clear: [focused])
            return
        }
        let p = writingState.progress(t)
        switch (rects(of: t.from, visible: visible), rects(of: t.to, visible: visible)) {
        case (nil, let to?):
            fillDim(ctx, dirty: dirty, alpha: alpha * p, clip: nil, clear: [to])
        case (let from?, nil):
            fillDim(ctx, dirty: dirty, alpha: alpha * (1 - p), clip: nil, clear: [from])
        case (let from?, let to?):
            fillDim(ctx, dirty: dirty, alpha: alpha, clip: nil, clear: [from, to])
            fillDim(ctx, dirty: dirty, alpha: alpha * p, clip: from, clear: [to])
            fillDim(ctx, dirty: dirty, alpha: alpha * (1 - p), clip: to, clear: [from])
        case (nil, nil):
            break
        }
    }

    /// Fills `dirty` (within `clip`) with the dimming color at `alpha`,
    /// except `clear`.
    private func fillDim(_ ctx: CGContext, dirty: CGRect, alpha: CGFloat, clip: [CGRect]?, clear: [[CGRect]]) {
        guard alpha > 0.001 else { return }
        if let clip, clip.allSatisfy({ !$0.intersects(dirty) }) { return }
        ctx.saveGState()
        if let clip { ctx.clip(to: clip) }
        ctx.beginTransparencyLayer(in: dirty, auxiliaryInfo: nil)
        var dim = controller.theme.colors.bg
        dim.alpha = Double(alpha)
        ctx.setFillColor(dim.cgColor)
        ctx.fill(dirty)
        ctx.setBlendMode(.clear)
        for rects in clear { ctx.fill(rects) }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    // MARK: Typewriter

    /// Blank space below the text in typewriter mode, so the last line can
    /// reach the typewriter line.
    var typewriterPadding: CGFloat {
        guard typewriterMode, let scroll = enclosingScrollView else { return 0 }
        return (scroll.contentSize.height * (1 - typewriterFraction)).rounded(.up)
    }

    /// Scrolls so the caret's line sits at `typewriterFraction` of the
    /// viewport height (as far as the document's top allows); eased over
    /// 80 ms when `typewriterEases` and motion is allowed.
    public func centerCaret(_ caretRect: CGRect? = nil) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let rect = caretRect ?? controller.caretRect(forSource: controller.caret)
        var origin = clip.bounds.origin
        origin.y = (rect.midY - clip.bounds.height * typewriterFraction).rounded()
        let target = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        let ease = typewriterEases ? displayOptions.duration(Self.typewriterEaseDuration) : 0
        if ease > 0, window != nil, abs(target.y - clip.bounds.minY) > 0.5 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = ease
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clip.animator().setBoundsOrigin(target)
            }
        } else {
            clip.scroll(to: target)
        }
        scroll.reflectScrolledClipView(clip)
    }
}
