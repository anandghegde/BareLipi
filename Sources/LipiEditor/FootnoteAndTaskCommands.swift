import CoreGraphics
import Foundation
import LipiCore

/// Insert Footnote (§6.13) and clicking a task's checkbox (§6.13).
extension MarkdownCommands {
    /// The next free numeric footnote label: one past the largest `[^n]`
    /// written anywhere in the document.
    func nextFootnoteNumber() -> Int {
        let text = doc.string(0..<doc.count)
        var highest = 0
        var i = text.utf8.startIndex
        let bytes = text.utf8
        while let open = bytes[i...].firstIndex(of: UInt8(ascii: "[")) {
            var j = bytes.index(after: open)
            guard j < bytes.endIndex, bytes[j] == UInt8(ascii: "^") else { i = j; continue }
            j = bytes.index(after: j)
            var n = 0, digits = 0
            while j < bytes.endIndex, (0x30...0x39).contains(bytes[j]), digits < 9 {
                n = n * 10 + Int(bytes[j] - 0x30)
                digits += 1
                j = bytes.index(after: j)
            }
            if digits > 0, j < bytes.endIndex, bytes[j] == UInt8(ascii: "]") { highest = max(highest, n) }
            i = j
        }
        return highest + 1
    }

    /// Cmd-Opt-R: a `[^n]` reference after the selection and its `[^n]: `
    /// definition at the end of the document, with the caret there to type
    /// the note.
    func insertFootnote() -> EditPlan {
        let n = nextFootnoteNumber()
        let label = "[^\(n)]"
        let at = range.upperBound
        let end = doc.count
        let eol = doc.eol(near: max(0, end - 1))
        let text = doc.string(max(0, end - 2 * eol.utf8.count)..<end)
        let lead: String
        if end == 0 || text.hasSuffix(eol + eol) {
            lead = ""
        } else if text.hasSuffix(eol) {
            lead = eol
        } else {
            lead = eol + eol
        }
        var b = PlanBuilder()
        let definition = lead + label + ": "
        if at == end {
            b.insert(label + definition + eol, at: end)
        } else {
            b.insert(label, at: at)
            b.insert(definition + eol, at: end)
        }
        let caret = end + label.utf8.count + definition.utf8.count
        return b.plan(caret: caret)
    }

    /// Flips the `[ ]`/`[x]` box `box`.
    func toggleTaskBox(_ box: Range<Int>) -> EditPlan {
        let checked = doc.byte(box.lowerBound + 1) != 0x20
        var b = PlanBuilder()
        b.replace((box.lowerBound + 1)..<(box.lowerBound + 2), checked ? " " : "x")
        if selection.isEmpty { return b.plan(anchor: selection.head, anchorAfter: true, head: selection.head, headAfter: true) }
        let forward = selection.head >= selection.anchor
        return b.plan(anchor: selection.anchor, anchorAfter: !forward, head: selection.head, headAfter: forward)
    }
}

extension EditorController {
    /// Cmd-Opt-R: inserts a footnote reference and its definition.
    @discardableResult
    public func insertFootnote() -> EditorChange {
        if marked != nil { _ = unmarkText() }
        return perform(commands.insertFootnote())
    }

    /// The `[ ]` box of the task whose rendered checkbox (in the gutter) is
    /// at `point`; nil in source mode, off a checkbox, or while the item's
    /// line is revealed (its brackets are then ordinary text).
    public func taskBox(at point: CGPoint) -> Range<Int>? {
        guard mode != .source, let offset = sourceOffset(at: point) else { return nil }
        let c = commands
        let line = c.doc.prefix(ofLineAt: offset)
        guard let box = line.task else { return nil }
        let text = caretRect(forSource: line.contentStart)
        let lineStart = caretRect(forSource: line.start)
        // A revealed prefix pushes the text right of the line's start.
        guard abs(text.minX - lineStart.minX) < 0.5 else { return nil }
        guard point.y >= text.minY, point.y <= text.maxY,
              point.x < text.minX, point.x >= text.minX - 32 else { return nil }
        return box
    }

    /// Clicking a rendered checkbox toggles it as one undo step, without
    /// moving the caret. Returns whether `point` was on a checkbox.
    @discardableResult
    public func toggleTask(at point: CGPoint) -> Bool {
        guard let box = taskBox(at: point) else { return false }
        if marked != nil { _ = unmarkText() }
        perform(commands.toggleTaskBox(box))
        return true
    }
}
