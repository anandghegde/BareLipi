import Foundation

/// What the counts include (§6.18).
public struct CountOptions: Sendable, Hashable {
    /// Count code fences and indented code.
    public var includeCode: Bool
    /// Count inline and display math.
    public var includeMath: Bool
    /// Count every CJK character as a word instead of using the system's
    /// word segmentation.
    public var cjkByCharacter: Bool
    /// Reading speed for the reading time.
    public var wordsPerMinute: Int

    public init(includeCode: Bool = true, includeMath: Bool = true, cjkByCharacter: Bool = false, wordsPerMinute: Int = 275) {
        self.includeCode = includeCode
        self.includeMath = includeMath
        self.cjkByCharacter = cjkByCharacter
        self.wordsPerMinute = wordsPerMinute
    }
}

/// Words and characters of a piece of rendered text.
public struct TextCounts: Sendable, Hashable {
    public var words: Int
    /// Characters (grapheme clusters), spaces included; line breaks between
    /// blocks are not counted.
    public var characters: Int
    /// Characters that are not white space.
    public var charactersExcludingSpaces: Int

    public init(words: Int = 0, characters: Int = 0, charactersExcludingSpaces: Int = 0) {
        self.words = words
        self.characters = characters
        self.charactersExcludingSpaces = charactersExcludingSpaces
    }

    public static let zero = TextCounts()

    public static func + (a: TextCounts, b: TextCounts) -> TextCounts {
        TextCounts(words: a.words + b.words, characters: a.characters + b.characters,
                   charactersExcludingSpaces: a.charactersExcludingSpaces + b.charactersExcludingSpaces)
    }

    public static func += (a: inout TextCounts, b: TextCounts) { a = a + b }

    /// Whole minutes to read at `wordsPerMinute`, rounded up; 0 for no words.
    public func readingMinutes(wordsPerMinute: Int = 275) -> Int {
        guard words > 0 else { return 0 }
        let wpm = max(1, wordsPerMinute)
        return (words + wpm - 1) / wpm
    }

    /// Counts `text` the way the status bar does: words by the system's word
    /// segmentation (orthographic words for Indic scripts, dictionary
    /// segmentation for CJK), or CJK by character when asked.
    public static func of(_ text: String, cjkByCharacter: Bool = false) -> TextCounts {
        var counts = TextCounts()
        for ch in text {
            if ch.isNewline { continue }
            counts.characters += 1
            if !ch.isWhitespace { counts.charactersExcludingSpaces += 1 }
        }
        guard counts.charactersExcludingSpaces > 0 else { return counts }
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .localized]) { word, _, _, _ in
            guard let word else { return }
            if cjkByCharacter {
                var cjk = 0, other = false
                for scalar in word.unicodeScalars {
                    if TextCounts.isCJK(scalar) { cjk += 1 } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil { other = true }
                }
                if cjk > 0 {
                    counts.words += cjk + (other ? 1 : 0)
                    return
                }
            }
            counts.words += 1
        }
        return counts
    }

    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF,
             0x20000...0x2FA1F, 0x31F0...0x31FF, 0x1100...0x11FF:
            return true
        default:
            return false
        }
    }
}

/// Document and selection counts (§6.18), cached per top-level block so a
/// keystroke recounts only the block it touched. Front matter, link
/// reference definitions, HTML blocks and thematic breaks are not counted;
/// code and math follow `options`. Counts are over rendered text: markup,
/// link destinations and image sources are left out.
public struct DocumentCounter: Sendable {
    public var options: CountOptions {
        didSet { if options != oldValue { cache.removeAll() } }
    }
    private struct Key: Hashable { var id: NodeID; var revision: UInt32 }
    private var cache: [Key: TextCounts] = [:]

    public init(options: CountOptions = CountOptions()) {
        self.options = options
    }

    /// Cached entries (tests).
    public var cachedBlocks: Int { cache.count }

    /// Counts for the whole document.
    public mutating func document(index: BlockIndex, rope: LipiRope) -> TextCounts {
        var total = TextCounts()
        for i in 0..<index.count { total += entry(i, index: index, rope: rope) }
        if cache.count > 2 * index.count + 64 { prune(index) }
        return total
    }

    /// Counts for the text in `range`: whole top-level blocks come from the
    /// cache, blocks the range cuts are counted over their selected part.
    public mutating func selection(_ range: Range<Int>, index: BlockIndex, rope: LipiRope) -> TextCounts {
        guard !range.isEmpty, let first = index.entryIndex(containing: range.lowerBound),
              let last = index.entryIndex(containing: max(range.lowerBound, range.upperBound - 1)) else { return .zero }
        var total = TextCounts()
        for i in first...last {
            let block = index.entries[i].block
            let start = index.start(of: i)
            let lo = start + block.range.lowerBound, hi = start + block.range.upperBound
            if range.lowerBound <= lo && hi <= range.upperBound {
                total += entry(i, index: index, rope: rope)
            } else {
                var text = ""
                appendText(of: block, base: start, clip: range, rope: rope, to: &text)
                total += TextCounts.of(text, cjkByCharacter: options.cjkByCharacter)
            }
        }
        return total
    }

    private mutating func entry(_ i: Int, index: BlockIndex, rope: LipiRope) -> TextCounts {
        let e = index.entries[i]
        let key = Key(id: e.block.id, revision: e.revision)
        if !e.isDirty, let hit = cache[key] { return hit }
        var text = ""
        appendText(of: e.block, base: index.start(of: i), clip: nil, rope: rope, to: &text)
        let counts = TextCounts.of(text, cjkByCharacter: options.cjkByCharacter)
        if !e.isDirty { cache[key] = counts }
        return counts
    }

    private mutating func prune(_ index: BlockIndex) {
        var live = Set<Key>()
        for e in index.entries { live.insert(Key(id: e.block.id, revision: e.revision)) }
        cache = cache.filter { live.contains($0.key) }
    }

    // MARK: Rendered text

    /// Appends the rendered text of `block` (ranges relative to `base`),
    /// limited to `clip` (absolute) when given. Blocks are separated by a
    /// newline so words never join across them.
    private func appendText(of block: Block, base: Int, clip: Range<Int>?, rope: LipiRope, to text: inout String) {
        let abs = (base + block.range.lowerBound)..<(base + block.range.upperBound)
        if let clip, !abs.isEmpty, !(clip.overlaps(abs)) { return }
        switch block.kind {
        case .frontMatter, .linkReferenceDefinition, .htmlBlock, .thematicBreak:
            return
        case .codeBlock(let info):
            guard options.includeCode else { return }
            var r = (base + info.contentRange.lowerBound)..<(base + info.contentRange.upperBound)
            if let clip { r = r.clamped(to: clip) }
            guard !r.isEmpty else { return }
            text += "\n" + rope.string(in: r)
        case .paragraph, .heading, .tableCell:
            text += "\n"
            for inline in block.inlines { appendText(of: inline, base: base, clip: clip, to: &text) }
        default:
            for child in block.children { appendText(of: child, base: base, clip: clip, rope: rope, to: &text) }
        }
    }

    private func appendText(of inline: Inline, base: Int, clip: Range<Int>?, to text: inout String) {
        let abs = (base + inline.range.lowerBound)..<(base + inline.range.upperBound)
        if let clip, !clip.overlaps(abs) { return }
        switch inline.kind {
        case .text(let s), .code(let s):
            text += clipped(s, abs, clip)
        case .math(let s, _):
            if options.includeMath { text += clipped(s, abs, clip) }
        case .softBreak:
            text += " "
        case .lineBreak:
            text += "\n"
        case .emoji(let s):
            text += s
        case .html, .image, .footnoteReference, .attributes:
            return
        case .emphasis, .strong, .strikethrough, .subscript, .superscript, .highlight, .link:
            for child in inline.children { appendText(of: child, base: base, clip: clip, to: &text) }
        }
    }

    /// The part of `s` (the text of source `range`) inside `clip`. Exact when
    /// the source spells the text byte for byte; otherwise all of it when the
    /// clip covers the range's middle, else nothing.
    private func clipped(_ s: String, _ range: Range<Int>, _ clip: Range<Int>?) -> String {
        guard let clip, !(clip.lowerBound <= range.lowerBound && range.upperBound <= clip.upperBound) else { return s }
        let utf8 = Array(s.utf8)
        if utf8.count == range.count {
            let lo = max(clip.lowerBound, range.lowerBound) - range.lowerBound
            let hi = min(clip.upperBound, range.upperBound) - range.lowerBound
            guard lo < hi else { return "" }
            return String(decoding: utf8[lo..<hi], as: UTF8.self)
        }
        let mid = (range.lowerBound + range.upperBound) / 2
        return clip.contains(mid) ? s : ""
    }
}
