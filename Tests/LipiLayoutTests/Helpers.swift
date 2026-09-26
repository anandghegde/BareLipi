import CoreText
import Foundation
import LipiCore
import LipiLayout
import Testing

/// A parsed, projected document with the §7.4 pipeline up to the projection.
struct Doc {
    var buffer: SourceBuffer
    var parser: LipiParser
    var projection: Projection
    let policy: RevealPolicy
    var caret: Int

    init(_ text: String, caret: Int = 0, preset: RevealPreset = .balanced, options: ParserOptions = .editor) {
        buffer = SourceBuffer(text)
        parser = LipiParser(options: options)
        parser.parse(buffer.rope)
        policy = RevealPolicy(preset: preset)
        projection = Projection(preset: preset)
        self.caret = caret
        let reveal = policy.revealSet(caret: caret, index: parser.index, rope: buffer.rope)
        _ = projection.update(index: parser.index, rope: buffer.rope, reveal: reveal)
    }

    var rope: LipiRope { buffer.rope }
    var text: String { buffer.rope.string(in: 0..<buffer.count) }

    @discardableResult
    mutating func move(to caret: Int) -> Projection.UpdateResult {
        self.caret = caret
        let reveal = policy.revealSet(caret: caret, index: parser.index, rope: buffer.rope)
        return projection.update(index: parser.index, rope: buffer.rope, reveal: reveal)
    }

    @discardableResult
    mutating func insert(_ s: String, at offset: Int) -> Projection.UpdateResult {
        let delta = buffer.apply(.insert(s, at: SourceOffset(offset)))
        parser.apply(delta, then: buffer.rope)
        return move(to: offset + s.utf8.count)
    }

    @discardableResult
    mutating func delete(_ range: Range<Int>) -> Projection.UpdateResult {
        let delta = buffer.apply(.delete(SourceOffset(range.lowerBound)..<SourceOffset(range.upperBound)))
        parser.apply(delta, then: buffer.rope)
        return move(to: range.lowerBound)
    }

    /// The first display block of entry `entry`.
    func block(_ entry: Int = 0, _ block: Int = 0) -> DisplayBlock { projection.entries[entry].blocks[block] }
}

func makeTypesetter(_ theme: Theme = .taalegari, zoom: CGFloat = 1, language: String? = nil) -> Typesetter {
    Typesetter(scale: TypeScale(theme: theme, zoom: zoom), cascade: FontCascade(theme: theme, language: language))
}

func makeLayout(_ doc: Doc, width: CGFloat = 900, typesetter: Typesetter = makeTypesetter()) -> DocumentLayout {
    let layout = DocumentLayout(typesetter: typesetter, viewportWidth: width)
    var projection = Projection(preset: doc.projection.preset)
    let result = projection.update(index: doc.parser.index, rope: doc.rope, reveal: doc.policy.revealSet(caret: doc.caret, index: doc.parser.index, rope: doc.rope))
    layout.update(projection: projection, result: result)
    return layout
}

/// Lays out one block of `text` (its first top-level entry) at `measure`.
func layoutBlock(_ text: String, caret: Int = 0, measure: CGFloat = 480, wideWidth: CGFloat = 480,
                 typesetter: Typesetter = makeTypesetter(), entry: Int = 0, block: Int = 0) -> BlockLayout {
    let doc = Doc(text, caret: caret)
    return LayoutEngine.layout(doc.block(entry, block), typesetter: typesetter, measure: measure, wideWidth: wideWidth)
}

func familyName(of font: CTFont) -> String { CTFontCopyFamilyName(font) as String }

/// Fonts of every glyph run of `attributed` when set on one line.
func runFonts(_ attributed: NSAttributedString) -> [(range: Range<Int>, font: CTFont)] {
    let line = CTLineCreateWithAttributedString(attributed)
    var result: [(Range<Int>, CTFont)] = []
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let range = CTRunGetStringRange(run)
        let attributes = CTRunGetAttributes(run) as! [NSAttributedString.Key: Any]
        let font = attributes[.font] as! CTFont
        result.append((range.location..<(range.location + range.length), font))
    }
    return result
}

func weightTrait(of font: CTFont) -> Double {
    let traits = CTFontCopyTraits(font) as! [CFString: Any]
    return traits[kCTFontWeightTrait] as? Double ?? 0
}

func isItalic(_ font: CTFont) -> Bool {
    CTFontGetSymbolicTraits(font).contains(.traitItalic) || CTFontGetMatrix(font).c != 0
}

func approximately(_ a: CGFloat, _ b: CGFloat, within tolerance: CGFloat = 0.5) -> Bool { abs(a - b) <= tolerance }
