/// YAML (`---` … `---`/`...`) and TOML (`+++` … `+++`) front matter at the
/// very start of a document. cmark never sees it; the parser records it as
/// the first `BlockIndex` entry and parses the rest of the document after it.
enum FrontMatter {
    struct Match: Equatable {
        var kind: FrontMatterKind
        /// End of the closing delimiter line's content.
        var contentEnd: Int
        /// Offset after the closing delimiter line's terminator; where cmark
        /// parsing starts.
        var spanEnd: Int
    }

    private struct Stop: Error {}

    /// Scans the document for front matter. Cheap unless the document starts
    /// with a delimiter line, in which case it reads forward to the closing
    /// delimiter (or the end of the document when there is none).
    static func detect(in rope: LipiRope) -> Match? {
        guard rope.count >= 3 else { return nil }
        let kind: FrontMatterKind
        switch (rope.byte(at: 0), rope.byte(at: 1), rope.byte(at: 2)) {
        case (0x2D, 0x2D, 0x2D): kind = .yaml
        case (0x2B, 0x2B, 0x2B): kind = .toml
        default: return nil
        }

        var pos = 0
        var lineNumber = 0
        var line: [UInt8] = []
        var tooLong = false
        var sawCR = false
        var match: Match? = nil

        do {
            try rope.forEachChunk { chunk in
                for b in chunk.utf8 {
                    if sawCR {
                        sawCR = false
                        if b == 0x0A {
                            if match != nil {
                                match!.spanEnd = pos + 1
                                throw Stop()
                            }
                            pos += 1
                            continue
                        }
                        if match != nil { throw Stop() }
                    }
                    if b == 0x0A || b == 0x0D {
                        let isDelimiter = !tooLong && Self.isDelimiter(line, kind: kind, closing: lineNumber > 0)
                        if lineNumber == 0 {
                            if !isDelimiter { throw Stop() }
                        } else if isDelimiter {
                            match = Match(kind: kind, contentEnd: pos, spanEnd: pos + 1)
                            if b == 0x0A { throw Stop() }
                        }
                        if b == 0x0D { sawCR = true }
                        lineNumber += 1
                        line.removeAll(keepingCapacity: true)
                        tooLong = false
                        pos += 1
                        continue
                    }
                    if line.count < 8 { line.append(b) } else { tooLong = true }
                    pos += 1
                }
            }
            // Reached the end without a terminator: the last line may close it.
            if match == nil, lineNumber > 0, !tooLong, Self.isDelimiter(line, kind: kind, closing: true) {
                match = Match(kind: kind, contentEnd: pos, spanEnd: pos)
            }
        } catch {}
        return match
    }

    /// Whether `line` (terminator excluded) is a delimiter line: exactly the
    /// three delimiter bytes, optionally followed by spaces or tabs.
    static func isDelimiter(_ line: [UInt8], kind: FrontMatterKind, closing: Bool) -> Bool {
        var end = line.count
        while end > 0 && (line[end - 1] == 0x20 || line[end - 1] == 0x09) { end -= 1 }
        guard end == 3 else { return false }
        let a = line[0], b = line[1], c = line[2]
        switch kind {
        case .yaml:
            if a == 0x2D && b == 0x2D && c == 0x2D { return true }
            return closing && a == 0x2E && b == 0x2E && c == 0x2E
        case .toml:
            return a == 0x2B && b == 0x2B && c == 0x2B
        }
    }
}
