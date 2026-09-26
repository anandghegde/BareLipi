import LipiCore

/// What an accessibility rotor steps through (§6.20).
public enum NavigationKind: CaseIterable, Sendable {
    case heading, link, table, image, codeBlock
}

/// One place a rotor can land: a source range and what to call it.
public struct NavigationTarget: Sendable, Hashable {
    public var range: Range<Int>
    public var label: String
}

extension EditorController {
    /// The document's headings, links, tables, images or code blocks in
    /// source order (headings, tables and code blocks at any depth).
    public func navigationTargets(_ kind: NavigationKind) -> [NavigationTarget] {
        NavigationTargets.collect(kind, index: blockIndex, rope: rope)
    }
}

enum NavigationTargets {
    static func collect(_ kind: NavigationKind, index: BlockIndex, rope: LipiRope) -> [NavigationTarget] {
        var out: [NavigationTarget] = []
        for i in 0..<index.count {
            let base = index.start(of: i)
            index.entries[i].block.forEachBlock { b in
                let range = (base + b.range.lowerBound)..<(base + b.range.upperBound)
                switch (kind, b.kind) {
                case (.heading, .heading(let level, _)):
                    out.append(NavigationTarget(range: range, label: "Heading level \(level), " + Outline.text(of: b.inlines)))
                case (.table, .table(let alignments)):
                    let rows = b.children.count
                    out.append(NavigationTarget(range: range, label: "Table, \(rows) rows, \(alignments.count) columns"))
                case (.codeBlock, .codeBlock(let info)):
                    let first = info.info.split(separator: " ").first.map(String.init) ?? ""
                    out.append(NavigationTarget(range: range, label: first.isEmpty ? "Code block" : "Code block, \(first)"))
                case (.link, _), (.image, _):
                    for inline in b.inlines {
                        inline.forEachInline { x in
                            let r = (base + x.range.lowerBound)..<(base + x.range.upperBound)
                            switch (kind, x.kind) {
                            case (.link, .link(let destination, _, _)):
                                let text = Outline.text(of: x.children)
                                out.append(NavigationTarget(range: r, label: text.isEmpty ? destination : text))
                            case (.image, .image(let destination, _)):
                                let alt = Outline.text(of: x.children)
                                out.append(NavigationTarget(range: r, label: alt.isEmpty ? "Image, \(destination)" : "Image, \(alt)"))
                            default:
                                break
                            }
                        }
                    }
                default:
                    break
                }
            }
        }
        return out
    }
}
