import AppKit
import Foundation
import LipiCore
import LipiLayout

/// The code block header (`CodeFenceIsland`, §6.5): Copy, Wrap and Lines,
/// and sideways scrolling of unwrapped code.
extension EditorController {
    /// The header button under `point` (view coordinates), if any.
    public func codeHeaderButton(at point: CGPoint) -> (entry: Int, block: Int, button: CodeHeaderButton)? {
        guard engine == .lipi else { return nil }
        return layout.codeHeaderButton(at: point)
    }

    /// Acts on a click at `point` if it is on a code header button. Returns
    /// whether it was.
    @discardableResult
    public func clickCodeHeader(at point: CGPoint, pasteboard: NSPasteboard = .general) -> Bool {
        guard let hit = codeHeaderButton(at: point) else { return false }
        switch hit.button {
        case .copy: copyCode(entry: hit.entry, block: hit.block, to: pasteboard)
        case .wrap: codeOptions.wrap.toggle()
        case .lineNumbers: codeOptions.lineNumbers.toggle()
        }
        return true
    }

    /// Soft wrap and line numbers of code blocks (editor-wide).
    public var codeOptions: CodeBlockOptions {
        get { layout.codeOptions }
        set {
            guard newValue != layout.codeOptions else { return }
            layout.codeOptions = newValue
            _ = refresh(textChanged: false, started: DispatchTime.now())
        }
    }

    /// The code of a code block, without its fences.
    public func codeText(entry: Int, block: Int) -> String? {
        guard entry < projection.entries.count, block < projection.entries[entry].blocks.count else { return nil }
        return typesetter.codeText(of: projection.entries[entry].blocks[block])
    }

    /// Puts a code block on the pasteboard as plain text and as HTML with
    /// its syntax colours.
    public func copyCode(entry: Int, block: Int, to pasteboard: NSPasteboard = .general) {
        guard let text = codeText(entry: entry, block: block) else { return }
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, .html], owner: nil)
        pasteboard.setString(text, forType: .string)
        if let html = typesetter.codeHTML(of: projection.entries[entry].blocks[block]) {
            pasteboard.setString(html, forType: .html)
        }
    }

    /// Scrolls the unwrapped code block under `point` sideways. Returns
    /// whether it moved (then the view redraws).
    @discardableResult
    public func scrollCode(at point: CGPoint, by dx: CGFloat) -> Bool {
        guard engine == .lipi, layout.scrollCode(at: point, by: dx) else { return false }
        onRedisplay?()
        return true
    }
}
