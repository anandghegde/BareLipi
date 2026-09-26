import CoreText
import Foundation

/// Caret placement, hit testing and grapheme stepping over a `CellLayout`
/// (ADR-002: `CTLineGetOffsetForStringIndex`, `CTLineGetStringIndexForPosition`,
/// `CFStringGetRangeOfComposedCharactersAtIndex`). All rects are in cell
/// coordinates, y down.
public enum CaretGeometry {
    /// Caret rect for UTF-16 `offset`; `upstream` keeps an offset at a soft
    /// wrap on the line before it.
    public static func rect(for offset: Int, in cell: CellLayout, upstream: Bool = false) -> CGRect {
        let clamped = max(0, min(offset, cell.length))
        let i = cell.lineIndex(containing: clamped, upstream: upstream)
        let line = cell.lines[i]
        let x = line.x + CGFloat(CTLineGetOffsetForStringIndex(line.line, clamped, nil))
        return CGRect(x: x, y: line.top, width: 0, height: line.height)
    }

    /// UTF-16 offset nearest `point`. Points beyond a line's end snap to the
    /// end of that line (before a trailing newline or wrap).
    public static func offset(at point: CGPoint, in cell: CellLayout) -> Int {
        let i = cell.lineIndex(atY: point.y)
        let line = cell.lines[i]
        var index = CTLineGetStringIndexForPosition(line.line, CGPoint(x: point.x - line.x, y: 0))
        if index == kCFNotFound { index = line.range.lowerBound }
        if index >= line.range.upperBound, !line.range.isEmpty {
            // Keep the caret on this line: before a hard newline, or at the
            // last character boundary before a soft wrap.
            let string = cell.string
            let last = line.range.upperBound - 1
            if string.character(at: last) == 0x0A || i < cell.lines.count - 1 {
                index = line.range.upperBound - (string.character(at: last) == 0x0A ? 1 : 0)
                if index == line.range.upperBound, i < cell.lines.count - 1 { index = lastBoundary(before: index, in: string) }
            }
        }
        return max(0, min(index, cell.length))
    }

    /// Offset after the grapheme cluster starting at `offset` (ಕ್ಷ steps once).
    public static func next(after offset: Int, in string: NSString) -> Int {
        guard offset < string.length else { return offset }
        let range = CFStringGetRangeOfComposedCharactersAtIndex(string as CFString, offset)
        return range.location + range.length
    }

    /// Offset before the grapheme cluster ending at `offset`.
    public static func previous(before offset: Int, in string: NSString) -> Int {
        guard offset > 0 else { return 0 }
        let range = CFStringGetRangeOfComposedCharactersAtIndex(string as CFString, offset - 1)
        return range.location
    }

    /// The composed character range containing `offset`.
    public static func cluster(at offset: Int, in string: NSString) -> Range<Int> {
        guard string.length > 0 else { return 0..<0 }
        let range = CFStringGetRangeOfComposedCharactersAtIndex(string as CFString, min(offset, string.length - 1))
        return range.location..<(range.location + range.length)
    }

    /// Number of caret stops in `string` (one per grapheme cluster, plus the end).
    public static func caretStops(in string: NSString) -> Int {
        var count = 1
        var i = 0
        while i < string.length { i = next(after: i, in: string); count += 1 }
        return count
    }

    static func lastBoundary(before offset: Int, in string: NSString) -> Int {
        guard offset > 0 else { return 0 }
        // Trailing spaces at a soft wrap are invisible; the caret sits before them.
        var end = offset
        while end > 0, string.character(at: end - 1) == 0x20 { end -= 1 }
        return end
    }
}
