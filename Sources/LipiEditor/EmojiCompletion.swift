import AppKit
import LipiCore

/// A partial emoji shortcode before the caret: `:` plus at least two alias
/// characters (§6.13).
public struct EmojiQuery: Sendable, Hashable {
    /// From the `:` to the caret, in source bytes.
    public var range: Range<Int>
    /// The alias typed so far, without the colon.
    public var text: String
}

extension EditorController {
    /// The longest alias the completion looks back over.
    static let maxEmojiQuery = 32

    /// The shortcode being typed at the caret, if completing it makes sense:
    /// hybrid mode, an empty selection, no marked text, not in code, the `:`
    /// at a line start or after a space or punctuation (not `12:30` or
    /// `http:`), and at least one alias matching.
    public func emojiQuery() -> EmojiQuery? {
        guard mode == .hybrid, marked == nil, selection.isEmpty else { return nil }
        let rope = self.rope
        let caret = selection.head
        guard caret >= 3 else { return nil }
        if caret < rope.count {
            let next = rope.byte(at: caret)
            if EmojiShortcodes.isNameByte(next) || next == 0x3A { return nil }
        }
        var i = caret
        let floor = max(0, caret - Self.maxEmojiQuery)
        while i > floor, rope.byte(at: i - 1) != 0x3A {
            guard EmojiShortcodes.isNameByte(rope.byte(at: i - 1)) else { return nil }
            i -= 1
        }
        guard i > 0, rope.byte(at: i - 1) == 0x3A, caret - i >= 2 else { return nil }
        let colon = i - 1
        if colon > 0 {
            let p = rope.byte(at: colon - 1)
            let word = p >= 0x80 || (p >= 0x30 && p <= 0x39) || (p | 0x20 >= 0x61 && p | 0x20 <= 0x7A) || p == 0x5F
            if word { return nil }
        }
        if CommandDocument(rope: rope, index: blockIndex).isCodeContext(caret) { return nil }
        let name = rope.string(in: i..<caret)
        guard !EmojiShortcodes.completions(for: name, limit: 1).isEmpty else { return nil }
        return EmojiQuery(range: colon..<caret, text: name)
    }

    /// Replaces the partial shortcode with `:name:`, as one undo step.
    @discardableResult
    public func acceptEmoji(_ name: String, replacing query: EmojiQuery) -> EditorChange {
        closeTypingGroup()
        return replace(query.range, with: ":\(name):")
    }
}

/// The emoji completion list and the query it was made for.
@MainActor
final class EmojiCompletionState {
    var query: EmojiQuery?
    var entries: [EmojiShortcodes.Entry] = []
    var selected = 0
    var popover: EmojiCompletionPopover?
}

/// The completion list under the caret. It never takes focus: the editor
/// keeps the keyboard and forwards Up, Down, Return, Tab and Esc.
@MainActor
final class EmojiCompletionPopover: NSObject {
    private let popover = NSPopover()
    private let stack = NSStackView()
    private var rows: [NSTextField] = []

    init(animates: Bool) {
        super.init()
        popover.behavior = .applicationDefined
        popover.animates = animates
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stack.setAccessibilityLabel("Emoji suggestions")
        let controller = NSViewController()
        controller.view = stack
        popover.contentViewController = controller
    }

    func update(_ entries: [EmojiShortcodes.Entry], selected: Int) {
        rows.forEach { $0.removeFromSuperview() }
        rows = entries.enumerated().map { i, e in
            let row = NSTextField(labelWithString: "\(e.emoji)  :\(e.name):")
            row.drawsBackground = true
            row.backgroundColor = i == selected ? .selectedContentBackgroundColor : .clear
            row.textColor = i == selected ? .alternateSelectedControlTextColor : .labelColor
            row.setAccessibilityLabel("\(e.emoji) \(e.name.replacingOccurrences(of: "_", with: " "))")
            row.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
            stack.addArrangedSubview(row)
            return row
        }
    }

    var isShown: Bool { popover.isShown }

    func show(relativeTo rect: NSRect, of view: NSView) {
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    func close() { popover.close() }
}

extension EditorView {
    /// The aliases in the emoji completion list, or nil when it is closed.
    public var emojiCompletionNames: [String]? {
        emojiState.query == nil ? nil : emojiState.entries.map(\.name)
    }

    /// The highlighted alias in the completion list.
    public var selectedEmojiCompletion: String? {
        guard emojiState.query != nil, emojiState.entries.indices.contains(emojiState.selected) else { return nil }
        return emojiState.entries[emojiState.selected].name
    }

    /// After every change: typing opens or refreshes the list; moving the
    /// caret off the shortcode closes it.
    func updateEmojiCompletion(textChanged: Bool) {
        guard emojiState.query != nil || textChanged else { return }
        guard let query = controller.emojiQuery(),
              textChanged || query.range.lowerBound == emojiState.query?.range.lowerBound else {
            closeEmojiCompletion()
            return
        }
        if query == emojiState.query { return }
        let previous = emojiState.selected < emojiState.entries.count ? emojiState.entries[emojiState.selected].name : nil
        emojiState.query = query
        emojiState.entries = EmojiShortcodes.completions(for: query.text, limit: 8)
        emojiState.selected = previous.flatMap { name in emojiState.entries.firstIndex { $0.name == name } } ?? 0
        showEmojiCompletion()
    }

    private func showEmojiCompletion() {
        guard window != nil else { return }
        let popover = emojiState.popover ?? EmojiCompletionPopover(animates: displayOptions.duration(0.2) > 0)
        emojiState.popover = popover
        popover.update(emojiState.entries, selected: emojiState.selected)
        let anchor = controller.caretRect(forSource: emojiState.query?.range.lowerBound ?? controller.caret)
        if !popover.isShown {
            popover.show(relativeTo: anchor.insetBy(dx: 0, dy: -2), of: self)
        }
        announceEmojiSelection()
    }

    private func announceEmojiSelection() {
        guard let name = selectedEmojiCompletion, let e = EmojiShortcodes.emoji(for: name) else { return }
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: "\(e) \(name.replacingOccurrences(of: "_", with: " "))",
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    func closeEmojiCompletion() {
        emojiState.query = nil
        emojiState.entries = []
        emojiState.selected = 0
        let popover = emojiState.popover
        emojiState.popover = nil
        popover?.close()
    }

    /// Up and Down move through the list, Return and Tab accept, Esc closes
    /// it. Returns whether the key was handled.
    public func handleEmojiCompletionKey(_ keyCode: UInt16) -> Bool {
        guard let query = emojiState.query, !emojiState.entries.isEmpty else { return false }
        let n = emojiState.entries.count
        switch keyCode {
        case 125, 126:
            emojiState.selected = (emojiState.selected + (keyCode == 125 ? 1 : n - 1)) % n
            emojiState.popover?.update(emojiState.entries, selected: emojiState.selected)
            announceEmojiSelection()
        case 36, 76, 48:
            let name = emojiState.entries[emojiState.selected].name
            closeEmojiCompletion()
            controller.acceptEmoji(name, replacing: query)
        case 53:
            closeEmojiCompletion()
        default:
            return false
        }
        return true
    }
}
