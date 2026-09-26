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
        if let table = block.table {
            let tableRect = CGRect(x: box.minX, y: box.minY, width: table.width, height: table.height)
            ctx.setFillColor(colors.bgElevated.cgColor)
            ctx.fill(CGRect(x: tableRect.minX, y: tableRect.minY, width: tableRect.width, height: table.rowHeights.first ?? 0))
            ctx.setStrokeColor(colors.border.cgColor)
            ctx.setLineWidth(1)
            var y = tableRect.minY
            for h in table.rowHeights {
                ctx.move(to: CGPoint(x: tableRect.minX, y: y + 0.5)); ctx.addLine(to: CGPoint(x: tableRect.maxX, y: y + 0.5))
                y += h
            }
            ctx.move(to: CGPoint(x: tableRect.minX, y: y + 0.5)); ctx.addLine(to: CGPoint(x: tableRect.maxX, y: y + 0.5))
            var x = tableRect.minX
            for w in table.columnWidths {
                ctx.move(to: CGPoint(x: x + 0.5, y: tableRect.minY)); ctx.addLine(to: CGPoint(x: x + 0.5, y: tableRect.maxY))
                x += w
            }
            ctx.move(to: CGPoint(x: x + 0.5, y: tableRect.minY)); ctx.addLine(to: CGPoint(x: x + 0.5, y: tableRect.maxY))
            ctx.strokePath()
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

    /// Markers hang in the gutter, right-aligned to the text column (§8.2).
    func drawGutter(_ block: BlockLayout, box: CGRect, layout: DocumentLayout, in ctx: CGContext) {
        var marker: String? = nil
        if let m = block.context.marker {
            switch m.task {
            case .some(let task): marker = task == .checked ? "☑" : "☐"
            case .none: marker = m.isOrdered ? m.literal : "•"
            }
        } else if case .heading(let level) = block.role {
            marker = String(repeating: "#", count: level)
        } else if block.context.quoteDepth > 0, block.context.marker == nil {
            marker = nil
        }
        guard let marker, let first = block.cells.first?.lines.first else { return }
        let text = typesetter.attributedString(marker, role: .gutterMarker)
        let line = CTLineCreateWithAttributedString(text)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.textPosition = CGPoint(x: box.minX - width - 8, y: box.minY + block.cellFrames[0].minY + first.baseline)
        CTLineDraw(line, ctx)
    }
}
