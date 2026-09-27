import CoreGraphics
import CoreText
import Foundation
import LipiCore

/// The picture of an image island (P0-07), in block coordinates.
public struct ImageChrome {
    public enum Content: Equatable {
        /// The decoded bitmap (a placeholder of the same size until it lands).
        case picture
        /// Size not known yet: a placeholder of estimated size.
        case placeholder
        /// Missing, undecodable or remote: a box with the alt text.
        case alt
    }

    public let image: DisplayImage
    public let base: ImageBase
    public let content: Content
    /// Where the picture (or placeholder, or alt box) is drawn.
    public let frame: CGRect
    /// The alt text line of an `.alt` box, drawn at `labelOrigin`.
    public let label: CTLine?
    public let labelOrigin: CGPoint
    /// Height of the part of the block above the picture (the revealed
    /// source); a background, if any, covers only that.
    public let sourceHeight: CGFloat
}

extension LayoutEngine {
    /// The size an image is drawn at (points): its pixel size taken as CSS
    /// pixels, or the `width` / `height` the tag sets (the other side kept
    /// in proportion), times its `zoom`, times the editor zoom; then scaled
    /// down to fit `column`, keeping the aspect ratio. With no pixel size
    /// (still decoding) the tag's sizes, else a 16:9 guess.
    public static func imageSize(for image: DisplayImage, pixels: CGSize?, column: CGFloat, zoom editorZoom: CGFloat) -> CGSize {
        func points(_ length: ImageLength?, of reference: CGFloat) -> CGFloat? {
            switch length {
            case .pixels(let v)?: return CGFloat(v) * editorZoom
            case .percent(let v)?: return reference * CGFloat(v) / 100
            case nil: return nil
            }
        }
        let natural = pixels.flatMap { $0.width > 0 && $0.height > 0 ? CGSize(width: $0.width * editorZoom, height: $0.height * editorZoom) : nil }
        let ratio = natural.map { $0.height / $0.width } ?? 9.0 / 16.0
        var w = points(image.width, of: column)
        var h = points(image.height, of: natural?.height ?? column * ratio)
        switch (w, h) {
        case (let w0?, nil): h = w0 * ratio
        case (nil, let h0?): w = h0 / ratio
        case (nil, nil):
            if let natural {
                w = natural.width; h = natural.height
            } else {
                w = min(column, 320 * editorZoom); h = w! * ratio
            }
        default: break
        }
        var size = CGSize(width: w!, height: h!)
        if let zoom = image.zoom, zoom > 0 {
            size.width *= CGFloat(zoom) / 100
            size.height *= CGFloat(zoom) / 100
        }
        if size.width > column, column > 0 {
            size.height *= column / size.width
            size.width = column
        }
        return CGSize(width: max(1, size.width.rounded()), height: max(1, size.height.rounded()))
    }

    /// An image island. Folded, the block's one character (U+FFFC) is as
    /// wide as the picture and sits on its bottom edge, so the caret goes
    /// before or after the picture; revealed, the source is laid out as
    /// usual and the picture drawn below it.
    static func layoutImage(_ block: DisplayBlock, image: DisplayImage, typesetter: Typesetter, measure: CGFloat, width: CGFloat,
                            indent: CGFloat, style: TextStyle, status: ImageStore.Status, base: ImageBase) -> BlockLayout {
        let scale = typesetter.scale
        let column = max(80, measure - indent) - 2 * style.paddingX
        let inner = width - 2 * style.paddingX
        let content: ImageChrome.Content
        var size: CGSize
        var label: CTLine? = nil
        switch status {
        case .ready(let pixels):
            content = .picture
            size = imageSize(for: image, pixels: pixels, column: column, zoom: scale.zoom)
        case .pending:
            content = .placeholder
            size = imageSize(for: image, pixels: nil, column: column, zoom: scale.zoom)
        case .failed, .remote:
            content = .alt
            let text = typesetter.attributedString("\u{1F5BC}\u{FE0E} " + image.label, role: .body, ink: .muted)
            let line = CTLineCreateWithAttributedString(text)
            let pad = scale.l(8)
            let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            size = CGSize(width: min(column, (textWidth + 2 * pad).rounded(.up)), height: typesetter.scale.style(for: .body).lineHeight + 2 * scale.l(4))
            label = CTLineCreateTruncatedLine(line, Double(max(1, size.width - 2 * pad)), .end,
                                              CTLineCreateWithAttributedString(typesetter.attributedString("\u{2026}", role: .body, ink: .muted))) ?? line
        }
        size.width = min(size.width, inner)

        var typesetCell = typesetter.typeset(block.cells[0], in: block, cellIndex: 0)
        let frame: CGRect
        let cellFrame: CGRect
        let height: CGFloat
        let sourceHeight: CGFloat
        if image.isFolded {
            typesetCell = folded(typesetCell, width: size.width)
            let cell = typeset(typesetCell, width: inner)
            let contentHeight = max(size.height, cell.height)
            frame = CGRect(x: style.paddingX, y: style.paddingY + contentHeight - size.height, width: size.width, height: size.height)
            cellFrame = CGRect(x: style.paddingX, y: style.paddingY + contentHeight - cell.height, width: inner, height: cell.height)
            height = contentHeight + 2 * style.paddingY
            sourceHeight = 0
            let chrome = ImageChrome(image: image, base: base, content: content, frame: frame, label: label,
                                     labelOrigin: labelOrigin(label, in: frame, scale: scale), sourceHeight: sourceHeight)
            return BlockLayout(id: block.id, layoutKey: block.layoutKey, role: block.role, style: style, context: block.context,
                               isRevealed: block.isRevealed, width: width, indent: indent, cells: [cell], cellFrames: [cellFrame],
                               table: nil, height: height, image: chrome)
        }
        let cell = typeset(typesetCell, width: inner)
        cellFrame = CGRect(x: style.paddingX, y: style.paddingY, width: inner, height: cell.height)
        sourceHeight = cell.height + 2 * style.paddingY
        let gap = scale.l(6)
        frame = CGRect(x: style.paddingX, y: sourceHeight + gap, width: size.width, height: size.height)
        height = frame.maxY + style.paddingY
        let chrome = ImageChrome(image: image, base: base, content: content, frame: frame, label: label,
                                 labelOrigin: labelOrigin(label, in: frame, scale: scale), sourceHeight: sourceHeight)
        return BlockLayout(id: block.id, layoutKey: block.layoutKey, role: block.role, style: style, context: block.context,
                           isRevealed: block.isRevealed, width: width, indent: indent, cells: [cell], cellFrames: [cellFrame],
                           table: nil, height: height, image: chrome)
    }

    /// What an island shows for a picture in `status`.
    static func content(for status: ImageStore.Status) -> ImageChrome.Content {
        switch status {
        case .ready: return .picture
        case .pending: return .placeholder
        case .failed, .remote: return .alt
        }
    }

    private static func labelOrigin(_ label: CTLine?, in frame: CGRect, scale: TypeScale) -> CGPoint {
        guard let label else { return .zero }
        var ascent: CGFloat = 0, descent: CGFloat = 0
        CTLineGetTypographicBounds(label, &ascent, &descent, nil)
        return CGPoint(x: frame.minX + scale.l(8), y: (frame.midY + (ascent - descent) / 2).rounded())
    }

    /// The folded cell: its U+FFFC reserves the picture's width.
    static func folded(_ cell: TypesetCell, width: CGFloat) -> TypesetCell {
        let text = NSMutableAttributedString(attributedString: cell.attributed)
        let ns = text.string as NSString
        let chip = ns.range(of: "\u{FFFC}")
        if chip.location != NSNotFound {
            let size = cell.style.size
            text.addAttribute(.ctRunDelegate, value: ChipDelegate.delegate(width: width, ascent: size * 0.8, descent: size * 0.2), range: chip)
            text.addAttribute(.ctForeground, value: CGColor.clear, range: chip)
        }
        var key = FNV()
        key.combine(Int(Int64(bitPattern: cell.key)))
        key.combine(Int(width))
        return TypesetCell(attributed: text, role: cell.role, style: cell.style, lineHeight: cell.lineHeight,
                           lineHeightClass: cell.lineHeightClass, decorations: [], alignment: cell.alignment,
                           isRightToLeft: cell.isRightToLeft, key: key.value)
    }
}
