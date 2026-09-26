import CoreGraphics
import CoreText
import Foundation
import LipiCore

/// Draws placed entries into a y-down `CGContext` with `CTLineDraw`
/// (§7.4 step 9). The caller clips to the dirty rect; blocks outside it are
/// skipped.
public struct Renderer {
    public let typesetter: Typesetter
    public var colors: ThemeColors { typesetter.scale.theme.colors }

    public init(typesetter: Typesetter) {
        self.typesetter = typesetter
    }

    public func draw(_ placed: [PlacedEntry], layout: DocumentLayout, in ctx: CGContext, dirty: CGRect) {
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for entry in placed {
            for (b, block) in entry.layout.blocks.enumerated() {
                let top = entry.y + entry.layout.blockTops[b]
                let x0 = layout.x(of: block)
                let box = CGRect(x: x0, y: top, width: block.width, height: block.height)
                guard box.intersects(dirty) else { continue }
                drawBackground(block, box: box, layout: layout, in: ctx)
                drawGutter(block, box: box, layout: layout, in: ctx)
                if let table = block.table {
                    // Only the rows under the dirty rect (typeset on demand).
                    let rows = table.realizeRows(in: (dirty.minY - top)...(dirty.maxY - top))
                    drawGrid(table, rows: rows, origin: CGPoint(x: x0, y: top), in: ctx)
                    for r in rows {
                        for c in 0..<table.columns {
                            let i = table.cellIndex(row: r, column: c)
                            let frame = table.frame(ofCell: i).offsetBy(dx: x0, dy: top)
                            guard frame.intersects(dirty) || frame.height == 0 else { continue }
                            draw(table.cell(i), at: frame.origin, in: ctx, dirty: dirty)
                        }
                    }
                    continue
                }
                if let chrome = block.code {
                    drawCode(block, chrome: chrome, box: box, layout: layout, in: ctx, dirty: dirty)
                    continue
                }
                for (c, cell) in block.cells.enumerated() {
                    let frame = block.cellFrames[c].offsetBy(dx: x0, dy: top)
                    guard frame.intersects(dirty) || frame.height == 0 else { continue }
                    draw(cell, at: frame.origin, in: ctx, dirty: dirty)
                }
            }
        }
        ctx.restoreGState()
    }

    public func draw(_ cell: CellLayout, at origin: CGPoint, in ctx: CGContext, dirty: CGRect) {
        for decoration in cell.decorations {
            let rect = decoration.rect.offsetBy(dx: origin.x, dy: origin.y)
            switch decoration.kind {
            case .codePill, .chip:
                ctx.setFillColor(colors.codeBg.cgColor)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
                ctx.fillPath()
            case .strikethrough:
                ctx.setFillColor(colors.ink.cgColor)
                ctx.fill(rect)
            case .link:
                ctx.setFillColor(colors.accent.cgColor)
                ctx.fill(rect)
            case .highlight:
                ctx.setFillColor(colors.highlight.cgColor)
                ctx.fill(rect)
            case .marked:
                ctx.setFillColor(colors.ink.cgColor)
                ctx.fill(CGRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1))
            }
        }
        for line in cell.lines {
            let lineRect = CGRect(x: origin.x, y: origin.y + line.top, width: cell.width, height: line.height)
            guard lineRect.maxY >= dirty.minY, lineRect.minY <= dirty.maxY else { continue }
            ctx.textPosition = CGPoint(x: origin.x + line.x, y: origin.y + line.baseline)
            CTLineDraw(line.line, ctx)
        }
    }

    func drawBackground(_ block: BlockLayout, box: CGRect, layout: DocumentLayout, in ctx: CGContext) {
        if block.hasBackground {
            let color: ThemeColor = { if case .frontMatter = block.role { return colors.bgElevated } else { return colors.codeBg } }()
            ctx.setFillColor(color.cgColor)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.fillPath()
        }
        if block.isThematicBreak {
            ctx.setFillColor(colors.border.cgColor)
            ctx.fill(CGRect(x: box.minX, y: box.midY.rounded(), width: box.width, height: 1))
        }
        if block.context.quoteDepth > 0 {
            ctx.setFillColor(colors.border.cgColor)
            let step = typesetter.scale.l(16)
            for d in 0..<block.context.quoteDepth {
                let x = box.minX - block.indent + CGFloat(d) * step + 2
                ctx.fill(CGRect(x: x, y: box.minY, width: 3, height: box.height))
            }
        }
    }

    /// Header fill and grid lines of the table rows `rows`.
    func drawGrid(_ table: TableLayout, rows: Range<Int>, origin: CGPoint, in ctx: CGContext) {
        guard !rows.isEmpty else { return }
        let minX = origin.x, maxX = origin.x + table.width
        let minY = origin.y + table.rowY(rows.lowerBound), maxY = origin.y + table.rowY(rows.upperBound)
        if rows.lowerBound == 0 {
            ctx.setFillColor(colors.bgElevated.cgColor)
            ctx.fill(CGRect(x: minX, y: origin.y, width: table.width, height: table.rowHeight(0)))
        }
        ctx.setStrokeColor(colors.border.cgColor)
        ctx.setLineWidth(1)
        for r in rows.lowerBound...rows.upperBound {
            let y = origin.y + table.rowY(r)
            ctx.move(to: CGPoint(x: minX, y: y + 0.5)); ctx.addLine(to: CGPoint(x: maxX, y: y + 0.5))
        }
        for c in 0...table.columns {
            let x = origin.x + table.columnX(c)
            ctx.move(to: CGPoint(x: x + 0.5, y: minY)); ctx.addLine(to: CGPoint(x: x + 0.5, y: maxY))
        }
        ctx.strokePath()
    }

    /// Markers hang in the gutter, right-aligned to the text column (§8.2).
    func drawGutter(_ block: BlockLayout, box: CGRect, layout: DocumentLayout, in ctx: CGContext) {
        var marker: String? = nil
        if block.context.warning != nil {
            // Front matter that did not parse (§6.13).
            marker = Self.warningMarker
        } else if let m = block.context.marker {
            switch m.task {
            case .some(let task): marker = task == .checked ? "☑" : "☐"
            case .none: marker = m.isOrdered ? m.literal : "•"
            }
        } else if case .heading(let level) = block.role {
            marker = String(repeating: "#", count: level)
        } else if block.context.quoteDepth > 0, block.context.marker == nil {
            marker = nil
        } else if let label = block.context.footnoteLabel {
            // A definition: its number (or label) with the return link (§6.13).
            marker = Self.footnoteMarker(label: label, number: block.context.footnoteNumber)
            if block.context.footnoteRegionStart {
                // The footnotes region starts with a short rule.
                ctx.setFillColor(colors.border.cgColor)
                let y = (box.minY - max(block.spacingBefore, 8) / 2).rounded()
                ctx.fill(CGRect(x: box.minX, y: y, width: min(box.width, 160), height: 1))
            }
        }
        guard let marker, block.cellCount > 0, let first = block.cell(0).lines.first else { return }
        let text = typesetter.attributedString(marker, role: .gutterMarker)
        let line = CTLineCreateWithAttributedString(text)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.textPosition = CGPoint(x: box.minX - width - 8, y: box.minY + block.cellFrame(0).minY + first.baseline)
        CTLineDraw(line, ctx)
    }

    /// The gutter text of a block with a warning (malformed front matter).
    public static let warningMarker = "\u{26A0}\u{FE0E}"

    /// The gutter text of a footnote definition: `↩ 2.` (the arrow is the
    /// return link to the first reference).
    public static func footnoteMarker(label: String, number: Int?) -> String {
        "\u{21A9}\u{FE0E} " + (number.map { "\($0)." } ?? "[\(label)]")
    }

    /// A code block's header row, line numbers, and code; unwrapped code is
    /// clipped to its viewport and drawn at its sideways scroll (§6.5).
    func drawCode(_ block: BlockLayout, chrome: CodeChrome, box: CGRect, layout: DocumentLayout, in ctx: CGContext, dirty: CGRect) {
        if let header = LayoutEngine.codeHeader(of: block, typesetter: typesetter, options: layout.codeOptions),
           header.row.offsetBy(dx: box.minX, dy: box.minY).intersects(dirty) {
            ctx.textPosition = CGPoint(x: box.minX + header.labelOrigin.x, y: box.minY + header.labelOrigin.y)
            CTLineDraw(header.label, ctx)
            if let pill = header.pill {
                ctx.setStrokeColor(colors.warning.cgColor)
                ctx.setLineWidth(1)
                ctx.addPath(CGPath(roundedRect: pill.rect.offsetBy(dx: box.minX, dy: box.minY).insetBy(dx: 0.5, dy: 0.5),
                                   cornerWidth: 4, cornerHeight: 4, transform: nil))
                ctx.strokePath()
                ctx.textPosition = CGPoint(x: box.minX + pill.origin.x, y: box.minY + pill.origin.y)
                CTLineDraw(pill.line, ctx)
            }
            for item in header.buttons {
                ctx.textPosition = CGPoint(x: box.minX + item.origin.x, y: box.minY + item.origin.y)
                CTLineDraw(item.line, ctx)
            }
        }
        guard block.cellCount > 0 else { return }
        let cell = block.cell(0)
        let frame = block.cellFrames[0].offsetBy(dx: box.minX, dy: box.minY)
        if chrome.gutterWidth > 0, !chrome.lineStarts.isEmpty, !cell.lines.isEmpty {
            // Only the numbers of the lines under the dirty rect.
            let firstFragment = cell.lineIndex(atY: dirty.minY - frame.minY)
            let lastFragment = cell.lineIndex(atY: dirty.maxY - frame.minY)
            var k = chrome.lineStarts.partitioningIndex { $0 >= firstFragment }
            if k > 0 { k -= 1 }
            while k < chrome.lineStarts.count, chrome.lineStarts[k] <= lastFragment {
                let line = cell.lines[chrome.lineStarts[k]]
                let number = CTLineCreateWithAttributedString(typesetter.attributedString(String(k + 1), role: .codeBlock, ink: .muted))
                let width = CGFloat(CTLineGetTypographicBounds(number, nil, nil, nil))
                ctx.textPosition = CGPoint(x: frame.minX - typesetter.scale.l(10) - width, y: frame.minY + line.baseline)
                CTLineDraw(number, ctx)
                k += 1
            }
        }
        guard frame.intersects(dirty) || frame.height == 0 else { return }
        if chrome.wraps {
            draw(cell, at: frame.origin, in: ctx, dirty: dirty)
            return
        }
        let scroll = layout.codeScrollOffset(of: block)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: frame.minX, y: box.minY, width: chrome.viewportWidth, height: box.height))
        draw(cell, at: CGPoint(x: frame.minX - scroll, y: frame.minY), in: ctx, dirty: dirty)
        ctx.restoreGState()
    }
}

private extension Array {
    /// The first index whose element satisfies `predicate` (which must be
    /// false then true along the array).
    func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if predicate(self[mid]) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }
}
