import CoreGraphics
import Foundation
import LipiCore

/// Caret and selection in source bytes. `anchor` is where the selection
/// started; `head` is the caret and moves with the keys.
public struct SelectionModel: Sendable, Hashable {
    public var anchor: Int
    public var head: Int
    /// Preferred x (document coordinates) kept across vertical caret moves.
    public var goalX: CGFloat? = nil

    public init(caret: Int) {
        anchor = caret
        head = caret
    }

    public init(anchor: Int, head: Int) {
        self.anchor = anchor
        self.head = head
    }

    public var caret: Int { head }
    public var range: Range<Int> { min(anchor, head)..<max(anchor, head) }
    public var isEmpty: Bool { anchor == head }
}

/// IME composition state. The reveal set is frozen while text is marked so
/// the projection does not fold or unfold syntax under the composer (§7.4).
public struct MarkedText: Sendable, Hashable {
    /// Source bytes of the composed text.
    public var range: Range<Int>
    public var reveal: RevealSet

    public init(range: Range<Int>, reveal: RevealSet) {
        self.range = range
        self.reveal = reveal
    }
}

/// What one pipeline run changed; the view invalidates and scrolls from it.
public struct EditorChange: Sendable {
    /// Caret rect in document coordinates after the change.
    public var caretRect: CGRect
    /// The source text changed (as opposed to a caret move).
    public var textChanged: Bool
    /// The number of top-level entries changed (layout tree resized).
    public var structureChanged: Bool
    /// Seconds spent in the pipeline (buffer → caret rect).
    public var seconds: Double
    /// Reveal/fold layout compensation (PRD §9.1): how far the caret's line
    /// moved in document space because syntax revealed or folded around a
    /// caret move. The view scrolls by this so the caret's screen y is
    /// unchanged. Zero for text edits.
    public var viewportShift: CGFloat = 0
}
