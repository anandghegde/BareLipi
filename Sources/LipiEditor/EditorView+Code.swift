import AppKit
import LipiLayout

extension EditorView {
    /// Mostly-sideways scrolling over unwrapped code scrolls the code
    /// block; anything else scrolls the document.
    public override func scrollWheel(with event: NSEvent) {
        let dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 8
        if abs(dx) > abs(event.scrollingDeltaY) {
            let point = convert(event.locationInWindow, from: nil)
            if controller.scrollCode(at: point, by: -dx) { return }
        }
        super.scrollWheel(with: event)
    }
}
